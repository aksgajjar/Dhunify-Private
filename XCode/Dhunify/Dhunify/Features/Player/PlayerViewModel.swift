//
//  PlayerViewModel.swift
//  Dhunify
//
//  Queue-aware AVPlayer wrapper. Owns the audio session, drives the
//  Now Playing / Remote Command infrastructure, and advances the queue
//  according to shuffle / repeat settings.
//

import Foundation
import AVFoundation
import AVKit
import MediaPlayer
import Network
import SwiftUI
import UIKit
import os

// MARK: - Haptics helper

private enum Haptics {
    static func play() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
}

extension Notification.Name {
    static let dhunifyStopAllAudio = Notification.Name("dhunify.stopAllAudio")
    static let dhunifyQueueNearEnd = Notification.Name("dhunify.queueNearEnd")
}

enum RepeatMode {
    case off
    case one
    case all
}

@MainActor
@Observable
final class PlayerViewModel {

    // Nonisolated so non-main-actor contexts (Task bodies, closure
    // captures) can hit `Self.logger` without crossing the actor
    // boundary. os.Logger is Sendable, so this is safe.
    nonisolated private static let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "Player")

    // MARK: - Queue state

    private(set) var queue: [Song]
    private(set) var currentIndex: Int

    var currentSong: Song? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    // MARK: - Playback state

    var isPlaying: Bool = false
    /// True while the URL is resolving or the AVPlayerItem is not yet
    /// .readyToPlay. The play button binds to this to show a spinner
    /// so a tap feels instant even while the stream is still being
    /// resolved in the background.
    var isBuffering: Bool = false
    /// UI-only "instant response" flag. Flips true the instant the
    /// user taps play and stays true until `timeControlStatus` actually
    /// reaches `.playing`. The play button binds to
    /// `isPlaying || playPendingFeedback` so the pause icon appears
    /// without delay, and pulses subtly while audio is still starting.
    /// Does NOT affect any audio logic — purely perception layer.
    var playPendingFeedback: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var progress: Double = 0
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    /// Extracted from the current song's artwork. Drives the tinted
    /// background of the full player and the accent line on the mini player.
    var dominantColor: Color = .appSurface

    // MARK: - Lyrics

    var lyrics: String = ""
    var lyricsLoading: Bool = false
    var showLyrics: Bool = false

    // MARK: - Equalizer

    var showEqualizer: Bool = false
    var shuffledIndices: [Int] = []
    var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }
    var playbackSpeed: Float = 1.0 {
        didSet {
            if isPlaying { player.rate = playbackSpeed }
        }
    }

    static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5]

    // MARK: - Playback infrastructure

    var playbackError: String? = nil

    private let player = AVPlayer()

    // MARK: - Gapless preload (background buffer-warmer)

    /// Silent AVPlayer used only to pre-buffer the next track's item.
    /// When `preloadNextSong` constructs an AVPlayerItem, we attach it
    /// here so AVPlayer kicks off its internal range requests and the
    /// first ~1s of media data is already in the item's buffer by the
    /// time the user advances. At swap time we detach from this player
    /// and `replaceCurrentItem` onto the main `player` — the item keeps
    /// its buffer state across the move, producing a near-instant
    /// transition even for 20-120 min tracks.
    ///
    /// volume=0 + rate=0 = no audio output while warming.
    private let preloaderPlayer = AVPlayer()

    // MARK: - Crossfade (dual-player)

    private let playerB = AVPlayer()
    private var crossfadeActive = false
    @ObservationIgnored nonisolated(unsafe) private var crossfadeTask: Task<Void, Never>?
    /// How long the overlap between the outgoing and incoming track lasts.
    var crossfadeDuration: Double = 3.0

    /// Persisted across launches via UserDefaults.
    var crossfadeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "dhunify_crossfade") }
        set { UserDefaults.standard.set(newValue, forKey: "dhunify_crossfade") }
    }
    @ObservationIgnored nonisolated(unsafe) private var progressTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var endOfItemObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    private var artworkTaskID: UUID?
    private var wasPlayingBeforeInterruption = false
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var timeObserverToken: Any?
    @ObservationIgnored nonisolated(unsafe) private var stopAllAudioObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var airPlayRouteObserver: NSObjectProtocol?
    /// Cached artwork image for the currently-loaded song. Used by the
    /// AirPlay route handler to push artwork into `AVPlayerItem.externalMetadata`
    /// when an Apple TV / AirPlay receiver becomes active mid-playback,
    /// without re-downloading the image. Lock-screen / CarPlay paths
    /// continue to use `MPNowPlayingInfoCenter` and are untouched.
    @ObservationIgnored private var lastArtworkImage: UIImage?
    @ObservationIgnored private var lastArtworkSongID: String?
    private var wantsToPlay: Bool = false
    /// True while an in-flight `player.seek(...)` has not yet hit its
    /// completion handler. The periodic time observer reads this and
    /// skips its tick so a stale `player.currentTime()` reading from
    /// before the seek lands can't snap the UI back to the old
    /// position.
    private var isSeeking: Bool = false
    /// Timestamp of the most recent successful `seek()` completion.
    /// Stall-recovery uses this to apply a 5s grace window after user
    /// scrubs — large HLS jumps put AVPlayer into `.waiting` for
    /// several seconds while a new segment range is fetched, which
    /// would otherwise trip the 8s recovery debounce and snap the UI
    /// to 0 via `replaceCurrentItem`.
    @ObservationIgnored nonisolated(unsafe) private var lastSeekFinishedAt: Date?
    /// Safety watchdog for `playPendingFeedback`. If `.playing` never
    /// fires (resolver error, network stall) the flag would stick, so
    /// we force-clear it after 5s. The normal clear path is
    /// `observeTimeControl`'s `.playing` branch.
    @ObservationIgnored nonisolated(unsafe) private var playFeedbackTimeout: Task<Void, Never>?

    /// Timestamp of the first `.playing` transition for the current
    /// load. Used by stall-recovery to decide whether we're still in
    /// the "first 30 seconds" window where IP-bound URL failures are
    /// most likely (IP shift between resolve and first frame). Nil
    /// means actual playback hasn't started yet.
    @ObservationIgnored nonisolated(unsafe) private var playbackStartedAt: Date?
    /// Single source of truth for the YouTube stream's duration as
    /// reported by the resolver. Authoritative for probe-skip, the
    /// stability guard, stall-recovery gating, and telemetry — since
    /// `Song.duration` is frequently 0 for tracks scraped via search.
    /// Reset on every new load; populated by the YT resolve path.
    @ObservationIgnored private var ytStreamDuration: TimeInterval = 0

    // Retain the prebuffering loader for the lifetime of the current item.
    // AVURLAsset only holds a weak delegate reference.
    private var currentLoader: PrebufferingResourceLoader?
    private var crossfadeLoader: PrebufferingResourceLoader?

    // YouTube long-track webm→mp4 safety fallback. When resolver picks a
    // webm/opus stream (smaller, faster startup for 1-2hr tracks), it
    // also computes an mp4 fallback URL. If AVPlayer can't open webm
    // within a short window, swap to this URL in-place.
    private var pendingYTFallbackURL: URL?
    private var ytFallbackWatchdog: Task<Void, Never>?
    private var ytFallbackUsed: Bool = false
    /// One-shot guard for the backend yt-dlp fallback. When the
    /// client-side InnerTube chain returns an unplayable URL (403 /
    /// "permission denied" / "no stream"), we swap the AVPlayerItem to
    /// the backend's proxy stream URL once per load. Loop-proof: never
    /// re-fires on the replacement item, and resets only on a fresh
    /// `loadCurrentSong`.
    private var backendFallbackUsed: Bool = false
    /// Watchdog for AVPlayerItems that never reach `.readyToPlay` and
    /// never surface `.failed`. HLS manifests with path-segment IP
    /// binding (`/ip/<addr>/`) routinely 403 on segment fetches but
    /// AVPlayer hangs in `.unknown` rather than failing cleanly, so the
    /// `.failed` branch (where backend fallback lives) never fires.
    /// This task fires after a fixed delay and triggers the same
    /// backend fallback path. Cancelled on `.readyToPlay`, `.failed`,
    /// and on every fresh load.
    @ObservationIgnored nonisolated(unsafe) private var unknownStatusWatchdog: Task<Void, Never>?

    // MARK: - Network adaptive

    /// NWPathMonitor watching for cellular ↔ wifi ↔ constrained changes.
    /// Lets the player widen the buffer + cap the HLS bitrate when the
    /// driver is on a weak link, so songs ride out forest / tunnel
    /// dead zones instead of freezing.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// Debounce task: scheduled when AVPlayer enters a stall and
    /// cancelled when it returns to playing. If the timer fires before
    /// playback resumes, we kick the stall-recovery re-resolve path.
    /// Replaces the previous "fire on every .waiting / .paused" wiring
    /// which would have churned now that
    /// `automaticallyWaitsToMinimizeStalling=true` makes those events
    /// routine during normal rebuffer.
    @ObservationIgnored nonisolated(unsafe) private var stallDebounceTask: Task<Void, Never>?
    /// Cooldown timestamp for stall recovery — prevents tight loops
    /// while still allowing repeated recoveries through long drives.
    @ObservationIgnored nonisolated(unsafe) private var lastRecoveryAt: Date?
    /// Cooldown timestamp for path-change-driven re-resolves.
    @ObservationIgnored nonisolated(unsafe) private var lastPathChangeRecoveryAt: Date?
    /// Latest snapshot of the network path. Read on the main actor to
    /// pick buffer / peak-bitrate settings for new items.
    @ObservationIgnored private var isOnCellular: Bool = false
    @ObservationIgnored private var isConstrainedNetwork: Bool = false

    // MARK: - Init

    init(queue: [Song] = [], currentIndex: Int = 0) {
        self.queue = queue
        self.currentIndex = max(0, min(currentIndex, max(queue.count - 1, 0)))

        // Fast-start: hand AVPlayer the URL and play as soon as ANY
        // bytes arrive. `automaticallyWaitsToMinimizeStalling=true`
        // combined with a 30-60 s preferredForwardBufferDuration
        // caused AVPlayer to sit in `WaitingToMinimizeStallsReason`
        // for 5-15 s before READY on long progressive YT tracks.
        // Reactive recovery (`.failed` → backend, 8 s watchdog, stall
        // recovery via `resolveFresh`, network path-change re-resolve)
        // remains in place, so mid-track stalls still recover.
        // EXPERIMENT (long-progressive readiness): Safari plays the same
        // long googlevideo URL after ~10-15s. Reverting to Apple-default
        // wait behaviour to let long progressive items buffer enough to
        // reach .readyToPlay naturally instead of fast-starting on an
        // empty buffer. Revert to `false` if this regresses short-track
        // startup latency.
        player.automaticallyWaitsToMinimizeStalling = true
        playerB.automaticallyWaitsToMinimizeStalling = true
        preloaderPlayer.automaticallyWaitsToMinimizeStalling = true
        preloaderPlayer.volume = 0

        configureAudioSession()
        observeInterruptions()
        observeTimeControl()
        observeStopAllAudio()
        observeAirPlayRoute()
        setupRemoteCommands()
        startNetworkPathMonitor()
        loadCurrentSong()
    }

    func setQueue(_ queue: [Song], startIndex: Int, categorySeed: String? = nil) {
        cpdiag("setQueue count=\(queue.count) startIndex=\(startIndex) seed=\(categorySeed ?? "nil")")
        NotificationCenter.default.post(name: .dhunifyStopAllAudio, object: self)
        self.queue = queue
        self.currentIndex = max(0, min(startIndex, max(queue.count - 1, 0)))
        self.shuffledIndices = []
        self.isShuffled = false
        if let seed = categorySeed, !seed.isEmpty {
            self.categorySeed = seed
        }
        wantsToPlay = true
        // Fire resolver prefetch for the starting track (and the one
        // after) BEFORE loadCurrentSong so the resolver cache is warm
        // by the time loadCurrentSong's YouTube branch runs.
        // loadCurrentSong itself still does a fresh resolve — the
        // resolver's in-memory cache (Phase 1) makes that cheap when
        // the prefetch landed first.
        scheduleYTPrefetch()
        loadCurrentSong()
        // Fire an immediate near-end check so that starting on (or
        // near) the last track triggers a background refill — without
        // this, tapping the last song in a section leaves the next
        // button with nothing to advance to.
        maybeSignalQueueNearEnd()
    }

    /// Category/search context used when refilling the queue for
    /// continuous playback. Set by dashboard surfaces so CarPlay can
    /// pull more songs from the same section the user started from.
    var categorySeed: String?

    /// Absolute seconds to seek to once the next AVPlayerItem reaches
    /// .readyToPlay. Set by the Resume App Intent before setQueue so
    /// CarPlay restarts continue from saved position instead of 0.
    /// Cleared after a single successful seek so it never carries over.
    var pendingResumeSeconds: TimeInterval?

    /// Restore queue state without auto-playing. Used on app launch to
    /// show the last song in the mini player without starting audio.
    func restoreQueue(_ queue: [Song], startIndex: Int) {
        self.queue = queue
        self.currentIndex = max(0, min(startIndex, max(queue.count - 1, 0)))
        self.shuffledIndices = []
        self.isShuffled = false
        wantsToPlay = false

        guard let song = currentSong else { return }
        duration = song.duration
        currentTime = 0
        progress = 0
        setupNowPlaying()
    }

    deinit {
        crossfadeTask?.cancel()
        progressTask?.cancel()
        stallDebounceTask?.cancel()
        pathMonitor?.cancel()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let observer = endOfItemObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = stopAllAudioObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = airPlayRouteObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            Self.logger.info("🔊 Audio session: category=\(session.category.rawValue) active=true")
        } catch {
            Self.logger.error("🔊 Audio session FAILED: \(error.localizedDescription)")
        }
    }

    /// Observe player.timeControlStatus to know when playback actually
    /// starts producing audio output vs. buffering vs. paused.
    private func observeTimeControl() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    Self.logger.info("⏯️ timeControlStatus → PLAYING")
                    self.tmark("AUDIBLE (timeControlStatus → playing)")
                    self.transitionStart = nil // one-shot per load; ignore resume noise
                    self.isPlaying = true
                    self.clearPlayFeedback()
                    // Healthy playback — cancel any pending recovery
                    // debounce so a brief rebuffer doesn't escalate to
                    // a full re-resolve.
                    self.cancelStallRecoveryCheck()
                    if self.playbackStartedAt == nil {
                        self.playbackStartedAt = Date()
                        // Telemetry: first-audio moment per load. Not
                        // re-fired on resume-after-pause.
                        if let song = self.currentSong {
                            let dur = self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration
                            PlaybackTelemetry.shared.logPlaybackStart(
                                songID: song.youtubeID,
                                durationSec: Int(dur)
                            )
                        }
                    }
                case .paused:
                    Self.logger.info("⏯️ timeControlStatus → PAUSED")
                    self.isPlaying = false
                    // Schedule a debounced recovery check. If wantsToPlay
                    // is false (user tapped pause), the gate inside
                    // `maybeTriggerStallRecovery` no-ops. Otherwise an
                    // 8-second timer arms a re-resolve.
                    self.scheduleStallRecoveryCheck(reason: "paused")
                case .waitingToPlayAtSpecifiedRate:
                    let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
                    Self.logger.info("⏯️ timeControlStatus → WAITING (\(reason))")
                    // With automaticallyWaitsToMinimizeStalling=true,
                    // this fires on every normal rebuffer. Debounce so
                    // we only escalate to a re-resolve when the stall
                    // outlasts the buffer's natural recovery.
                    self.scheduleStallRecoveryCheck(reason: "waiting:\(reason)")
                @unknown default:
                    break
                }
            }
        }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract Sendable primitives out of the non-Sendable
            // `Notification` here, then hand them to the main-actor VM.
            // Crossing the Sendable boundary with `note` itself would
            // warn under Swift 6 strict concurrency.
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }
    }

    private func observeStopAllAudio() {
        stopAllAudioObserver = NotificationCenter.default.addObserver(
            forName: .dhunifyStopAllAudio,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Don't stop ourselves — only stop if another source posted.
            guard let self, note.object as AnyObject? !== self else { return }
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
    }

    // MARK: - AirPlay external metadata
    //
    // Apple TV / AirPlay-audio receivers render Now Playing UI from
    // `AVPlayerItem.externalMetadata`, NOT from `MPNowPlayingInfoCenter`.
    // The lock-screen / CarPlay path stays on `MPNowPlayingInfoCenter`
    // and is intentionally left alone. We only attach external metadata
    // while an AirPlay route is the active output, and clear it when
    // the route reverts to local playback so we don't leak metadata
    // into unrelated AVPlayer sessions.

    private func observeAirPlayRoute() {
        airPlayRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAirPlayRouteChange()
            }
        }
    }

    private func isAirPlayRouteActive() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { output in
            switch output.portType {
            case .airPlay:
                return true
            default:
                return false
            }
        }
    }

    private func handleAirPlayRouteChange() {
        cpdiag("routeChange")
        if isAirPlayRouteActive() {
            applyExternalMetadataForAirPlay()
        } else {
            clearExternalMetadataForAirPlay()
        }
    }

    private func applyExternalMetadataForAirPlay() {
        guard let item = player.currentItem, let song = currentSong else { return }

        var items: [AVMetadataItem] = []

        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = song.title as NSString
        title.extendedLanguageTag = "und"
        items.append(title)

        let artist = AVMutableMetadataItem()
        artist.identifier = .commonIdentifierArtist
        artist.value = song.artist as NSString
        artist.extendedLanguageTag = "und"
        items.append(artist)

        if
            lastArtworkSongID == song.youtubeID,
            let image = lastArtworkImage,
            let data = image.jpegData(compressionQuality: 0.85)
        {
            let art = AVMutableMetadataItem()
            art.identifier = .commonIdentifierArtwork
            art.value = data as NSData
            art.dataType = "public.jpeg"
            art.extendedLanguageTag = "und"
            items.append(art)
        }

        item.externalMetadata = items
    }

    private func clearExternalMetadataForAirPlay() {
        player.currentItem?.externalMetadata = []
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard
            let rawType = typeRaw,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        cpdiag("interruption type=\(type == .began ? "BEGAN" : "ENDED")")
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            pause()

        case .ended:
            guard let rawOptions = optionsRaw else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume), wasPlayingBeforeInterruption {
                play(userInitiated: false)
            }
            wasPlayingBeforeInterruption = false

        @unknown default:
            break
        }
    }

    // MARK: - Network adaptive playback

    /// Forward-buffer target. 2 s — minimal, lets playback start fast
    /// while AVPlayer keeps reading ahead on its own. The 30-60 s
    /// network-adaptive cap that lived here was the root cause of the
    /// `WaitingToMinimizeStallsReason` startup latency seen on long
    /// progressive YT tracks. Reactive recovery handles mid-track
    /// failures so the deep buffer was over-defensive.
    private var preferredForwardBufferDurationForCurrentNetwork: TimeInterval {
        // EXPERIMENT (long-progressive readiness): 0 = automatic, lets
        // AVPlayer choose its own buffer depth (Safari-like). Was 2,
        // which paired with autoWait=false to fast-start on a near-empty
        // buffer. Revert to 2 if this regresses startup.
        return 0
    }

    /// 0 = no cap. AVPlayer picks freely. The cellular 64 kbps cap
    /// that lived here only affected HLS variants, never progressive
    /// streams (which dominate this app's load), so it offered no
    /// real protection while contributing to the slow-start tuning.
    private var preferredPeakBitRateForCurrentNetwork: Double {
        return 0
    }

    /// Starts the NWPathMonitor watcher. Updates `isOnCellular` /
    /// `isConstrainedNetwork`, then re-applies adaptive settings on the
    /// current AVPlayerItem and (for YouTube tracks) kicks a single
    /// re-resolve so the IP-bound URL gets refreshed when the device
    /// hops between 5G ↔ LTE or WiFi ↔ cell.
    private func startNetworkPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            let constrained = path.isConstrained || path.isExpensive
            Task { @MainActor [weak self] in
                self?.handleNetworkPathChange(isCellular: cellular, isConstrained: constrained)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func handleNetworkPathChange(isCellular: Bool, isConstrained: Bool) {
        let prevCellular = isOnCellular
        let prevConstrained = isConstrainedNetwork
        isOnCellular = isCellular
        isConstrainedNetwork = isConstrained
        let changed = prevCellular != isCellular || prevConstrained != isConstrained
        guard changed else { return }
        Self.logger.info("🌐 path changed cellular=\(isCellular) constrained=\(isConstrained)")
        applyNetworkAdaptiveSettings()
        // On hop from one bearer to another (most common on highway),
        // YouTube IP-bound URLs lose their binding and stall a few
        // seconds later. Force a single re-resolve now — cooldown
        // protects against churn if the path flaps.
        if let last = lastPathChangeRecoveryAt,
           Date().timeIntervalSince(last) < 30 { return }
        lastPathChangeRecoveryAt = Date()
        guard wantsToPlay,
              let song = currentSong, song.isYouTubeSource,
              let asset = player.currentItem?.asset as? AVURLAsset,
              Self.urlIsIPBound(asset.url) else { return }
        Self.logger.info("🌐 path change on IP-bound YT URL — re-resolving")
        performStallRecovery(for: song, resumeAt: currentTime)
    }

    /// Pushes the current network's adaptive settings onto the active
    /// AVPlayerItem. Safe to call repeatedly — both properties are
    /// idempotent.
    private func applyNetworkAdaptiveSettings() {
        guard let item = player.currentItem else { return }
        item.preferredForwardBufferDuration = preferredForwardBufferDurationForCurrentNetwork
        item.preferredPeakBitRate = preferredPeakBitRateForCurrentNetwork
    }

    // MARK: - Loading

    /// True iff `token` is still the active load generation AND `item`
    /// is still the player's installed item. Every async player callback
    /// guards on this so a superseded load or a swapped-out item can't
    /// mutate shared player state.
    private func loadStillCurrent(_ token: Int, _ item: AVPlayerItem) -> Bool {
        token == loadToken && item === player.currentItem
    }

    // DIAGNOSTIC (CP-diag, temporary, behavior-free): transition timing.
    // Emits T+ms from load start → url finalized → item installed →
    // readyToPlay → audible, to localize the next-song delay. Pure logging;
    // remove after Phase 1 diagnosis. Touches no playback behavior.
    private var transitionStart: DispatchTime?
    private func tmark(_ label: String) {
        guard let s = transitionStart else { return }
        let ms = (DispatchTime.now().uptimeNanoseconds &- s.uptimeNanoseconds) / 1_000_000
        Self.logger.info("⏱️ T+\(ms)ms \(label)")
    }

    // DIAGNOSTIC (CarPlay regression, temporary, behavior-free): one-line
    // player/route state snapshot to localize where a next-track stalls while
    // CarPlay is attached. Pure logging; remove after diagnosis.
    private func cpdiag(_ at: String) {
        let route = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }.joined(separator: ",")
        Self.logger.info("🚗DIAG \(at) | isLoadingItem=\(self.isLoadingItem) loadingSongID=\(self.loadingSongID ?? "nil") loadToken=\(self.loadToken) idx=\(self.currentIndex) q=\(self.queue.count) hasItem=\(self.player.currentItem != nil) tcs=\(self.player.timeControlStatus.rawValue) wantsToPlay=\(self.wantsToPlay) route=[\(route)]")
    }

    private func loadCurrentSong() {
        let loadTargetID = currentSong?.youtubeID
        cpdiag("loadCurrentSong ENTER target=\(loadTargetID ?? "nil")")
        // Re-entrancy + cooldown apply only to the SAME song. A request
        // for a DIFFERENT song must supersede the in-flight load —
        // otherwise a load abandoned at the staleness guard or the
        // unknown-hang watchdog (both bail when currentSong changed
        // without clearing isLoadingItem) wedges the lock forever and
        // every later load is rejected here.
        if isLoadingItem, loadingSongID == loadTargetID {
            cpdiag("loadCurrentSong SKIP same-song-already-loading")
            Self.logger.info("⛔️ loadCurrentSong skipped — same song already loading")
            return
        }
        if Date().timeIntervalSince(lastLoadTime) <= 0.8, loadingSongID == loadTargetID {
            cpdiag("loadCurrentSong SKIP cooldown")
            Self.logger.info("⛔️ loadCurrentSong skipped — cooldown active")
            return
        }
        if isLoadingItem {
            Self.logger.info("↻ superseding stale load (\(self.loadingSongID ?? "nil")) → \(loadTargetID ?? "nil")")
        }
        lastLoadTime = Date()
        loadToken &+= 1
        let loadGen = loadToken
        isLoadingItem = true
        loadingSongID = loadTargetID
        transitionStart = .now()
        tmark("load start")
        // Stall-recovery state restarts with each new load.
        // `playbackStartedAt` gets set to the instant `.playing` first
        // fires; `lastRecoveryAt` is cleared so the 30s cooldown
        // doesn't carry over to a fresh song.
        playbackStartedAt = nil
        lastRecoveryAt = nil
        cancelStallRecoveryCheck()

        // Tear down ALL observers + watchdogs BEFORE detaching the
        // outgoing item. Detaching first (replaceCurrentItem(nil)) while
        // the status observer or end-of-item notification are still live
        // lets a teardown-time callback fire against the outgoing item
        // and mutate shared player state — the stale-callback corruption.
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let observer = endOfItemObserver {
            NotificationCenter.default.removeObserver(observer)
            endOfItemObserver = nil
        }
        ytFallbackWatchdog?.cancel()
        ytFallbackWatchdog = nil
        pendingYTFallbackURL = nil
        ytFallbackUsed = false
        backendFallbackUsed = false
        unknownStatusWatchdog?.cancel()
        unknownStatusWatchdog = nil

        // Observers gone — now safe to stop + detach the outgoing item.
        player.pause()
        player.volume = volume // reset from any crossfade
        player.replaceCurrentItem(with: nil)

        // Drop stale preload state if it was for a different song. Keep
        // it intact when the user advances to the preload target — the
        // YT/JIO fast paths below will consume it.
        let targetID = queue.indices.contains(currentIndex) ? queue[currentIndex].youtubeID : nil
        if preloadedSongID != targetID {
            preloadedURL = nil
            preloadedSongID = nil
            preloadedYTFallback = nil
            preloadedYTDuration = nil
        }
        // Evict preloaded items that are no longer in the [next, next+1]
        // window after the index change.
        evictStalePreloadedItems(keepSongID: targetID)

        playbackError = nil

        guard let song = currentSong else {
            isPlaying = false
            currentTime = 0
            duration = 0
            progress = 0
            dominantColor = .appSurface
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            isLoadingItem = false
            loadingSongID = nil
            return
        }

        Task { @MainActor [weak self, youtubeID = song.youtubeID, thumb = song.thumbnailURL] in
            let color = await DominantColorExtractor.extract(from: thumb)
            // Drop the result if the user already skipped to a different track.
            guard let self, self.currentSong?.youtubeID == youtubeID else { return }
            self.dominantColor = color
        }

        loadLyrics(for: song)

        guard let streamURL = buildStreamURL(for: song) else {
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            playbackError = "Could not build playback URL"
            isLoadingItem = false
            loadingSongID = nil
            return
        }

        // Reset preload state for this new song.
        hasPreloadedNext = false
        hasPrefetchedNextL2 = false

        Self.logger.info("🎵 [1/5] Loading: \(song.title)")
        Self.logger.info("🎵 [2/5] Stream URL: \(streamURL.absoluteString)")

        // Reset state.
        duration = song.duration
        currentTime = 0
        progress = 0

        // Ensure audio session is active.
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            Self.logger.info("🔊 Audio session active")
        } catch {
            Self.logger.error("🔊 setActive failed: \(error.localizedDescription)")
        }

        setupNowPlaying()
        LastPlayedPersistence.save(song: song)
        LastPlayedPersistence.saveQueue(queue, currentIndex: currentIndex)
        RecentlyPlayedManager.shared.add(song: song)

        // Show buffering UI until the item becomes .readyToPlay.
        isBuffering = true

        // Use preloaded URL if available (resolved at 70% of previous song),
        // otherwise resolve the 302 redirect via URLSession. YT songs
        // stream via backend byte-proxy (no 302), so skip the probe.
        //
        // @MainActor: this Task mutates `self` state (ytStreamDuration,
        // pendingYTFallbackURL, etc.) and drives AVPlayer, both main-
        // thread work. Inheriting main actor makes logger + property
        // access same-isolation without suspension overhead.
        Task { @MainActor in
            // `var` (not `let`) because the stability guard below may
            // replace it with a re-resolved non-IP-bound URL before we
            // hand it to AVPlayer.
            var finalURL: URL
            // Single source of truth is the stored property on self.
            // Reset here so the prior track's duration can't leak into
            // this load's probe-skip / guard / telemetry decisions.
            self.ytStreamDuration = 0

            // L2 disk cache fast path. When a previous play (or a
            // Wi-Fi pre-download) wrote this song's audio to
            // `Caches/audio/`, we skip every InnerTube round trip and
            // hand AVPlayer a `file://` URL. Local files are
            // IP-independent + survive any signal state, so the
            // IP-bound stability guard, the long-track block, and the
            // unknown-hang watchdog all become no-ops below
            // (`urlIsIPBound` / `urlIsHLS` return false on file URLs).
            if let l2 = await AudioDiskCache.shared.cachedFileURL(for: song.youtubeID) {
                finalURL = l2
                self.ytStreamDuration = song.duration
                Self.logger.info("⚡️ L2 disk cache hit \(song.youtubeID, privacy: .public)")
            } else if let preloaded = preloadedURL,
               preloadedSongID == song.youtubeID,
               !song.isYouTubeSource {
                finalURL = preloaded
                preloadedURL = nil
                preloadedSongID = nil
                Self.logger.info("🔮 Using preloaded URL")
            } else if song.isYouTubeSource {
                // Reset prior fallback state.
                ytFallbackWatchdog?.cancel()
                ytFallbackWatchdog = nil
                pendingYTFallbackURL = nil
                ytFallbackUsed = false

                // Tier 1 (YT): fast path — use preloaded URL if matching.
                if let preloaded = preloadedURL,
                   preloadedSongID == song.youtubeID {
                    finalURL = preloaded
                    pendingYTFallbackURL = preloadedYTFallback
                    self.ytStreamDuration = preloadedYTDuration ?? 0
                    preloadedURL = nil
                    preloadedSongID = nil
                    preloadedYTFallback = nil
                    preloadedYTDuration = nil
                    Self.logger.info("🔮 Using preloaded YT URL host=\(finalURL.host ?? "?") fallback=\(self.pendingYTFallbackURL != nil) dur=\(Int(self.ytStreamDuration))s")
                } else {
                    // Resolve googlevideo URL on-device via InnerTube.
                    // Must stream directly from iPhone — googlevideo
                    // URLs are IP-locked, so any proxy breaks playback.
                    // Surface error instead of handing AVPlayer a broken
                    // fallback URL on resolver failure.
                    let missReason: String
                    if preloadedURL == nil {
                        missReason = "none"
                    } else if preloadedSongID != song.youtubeID {
                        missReason = "stale(wanted=\(song.youtubeID) had=\(preloadedSongID ?? "nil"))"
                    } else {
                        missReason = "?"
                    }
                    Self.logger.info("🔮 YT preload MISS reason=\(missReason)")
                    Self.logger.info("🧪 DBG YT path start id=\(song.youtubeID)")
                    do {
                        let resolved = try await YouTubeStreamResolver.shared.resolve(videoID: song.youtubeID, expectedDuration: song.duration)
                        finalURL = resolved.url
                        pendingYTFallbackURL = resolved.fallbackURL
                        self.ytStreamDuration = resolved.duration
                        Self.logger.info("🧪 DBG YT resolver OK host=\(resolved.url.host ?? "?") fallback=\(resolved.fallbackURL != nil) dur=\(Int(resolved.duration))s")
                    } catch {
                        let nse = error as NSError
                        Self.logger.error("🧪 DBG YT resolver FAILED domain=\(nse.domain) code=\(nse.code) desc=\(error.localizedDescription)")
                        playbackError = "Couldn't resolve this track. Try another."
                        isLoadingItem = false
                        loadingSongID = nil
                        self.clearPlayFeedback(animated: false)
                        preloadedURL = nil
                        preloadedSongID = nil
                        preloadedYTFallback = nil
                        preloadedYTDuration = nil
                        return
                    }
                    preloadedURL = nil
                    preloadedSongID = nil
                    preloadedYTFallback = nil
                    preloadedYTDuration = nil
                }
            } else if let cached = ResolvedURLCache.shared.get(song.youtubeID) {
                finalURL = cached
                preloadedURL = nil
                preloadedSongID = nil
                Self.logger.info("⚡️ Resolved-URL cache hit")
            } else {
                let resolved = await resolveRedirect(streamURL)
                finalURL = resolved
                if resolved.host != streamURL.host {
                    ResolvedURLCache.shared.set(song.youtubeID, url: resolved)
                }
                preloadedURL = nil
                preloadedSongID = nil
            }

            // Route YouTube playback through the local byte-range relay. The
            // relay resolves a fresh itag-139/140 URL server-side and serves a
            // range-correct, fully-stitched body, so AVPlayer never touches the
            // IP-bound googlevideo URL directly. Skip file:// (L2 offline cache
            // still plays locally). Relay URLs carry no `ip` param and aren't
            // HLS, so the IP-bound stability guard, the reactive `.failed`
            // re-resolve, and the stall watchdog below all self-disable.
            // PHASE RESET: play the reliable BACKEND stream for YouTube. Direct
            // googlevideo is IP-bound and leaves AVPlayer stuck in `.unknown`;
            // the LAN relay hit iOS Local Network privacy. The backend proxies
            // audio/mp4 from its own egress IP → AVPlayer reaches `.readyToPlay`
            // reliably. Skip file:// (L2 offline plays locally). (Relay override
            // is retired here; relay infra stays dormant behind `relayPlaybackMode`.)
            // DUAL-PATH gate. HLS PRIMARY: when the resolver returned an HLS
            // manifest (official music videos — IOS client yields hlsManifestUrl
            // anonymously), hand it straight to AVPlayer for native, instant
            // playback. Do NOT override it to the progressive backend.
            // Progressive (long mixes/jukeboxes — no HLS) routes through the
            // worker-stitched backend (guaranteed floor). `.failed`/watchdog
            // still fall back to the backend, so HLS failures are covered.
            if song.isYouTubeSource, !finalURL.isFileURL, Self.urlIsHLS(finalURL) {
                Self.logger.info("🎵 HLS primary id=\(song.youtubeID, privacy: .public) host=\(finalURL.host ?? "?")")
            } else if song.isYouTubeSource, !finalURL.isFileURL,
               let fstreamURL = Self.fstreamURL(youtubeID: song.youtubeID) {
                // Faststart-remuxed progressive MP4 (moov-at-front) → AVPlayer
                // ready on the first ~256 KB. Prewarmed next-track builds are
                // cached → instant. `.failed`/watchdog still fall back to the
                // worker backend (swapToBackendYTStream), so a build miss is safe.
                Self.logger.info("⚡️ Faststart playback id=\(song.youtubeID, privacy: .public) → \(fstreamURL.absoluteString, privacy: .public)")
                finalURL = fstreamURL
            } else if Self.relayPlaybackMode, song.isYouTubeSource, !finalURL.isFileURL,
                      let relayURL = Self.relayStreamURL(youtubeID: song.youtubeID) {
                Self.logger.info("🔀 Relay playback id=\(song.youtubeID, privacy: .public) → \(relayURL.absoluteString, privacy: .public)")
                finalURL = relayURL
            }
            // Direct-play philosophy: hand the resolved URL to AVPlayer
            // without preemptive validation. IP-bound googlevideo URLs
            // play fine on stable networks; the failure mode (egress IP
            // shift mid-track → 403) is rare and handled reactively by
            // the `.failed` branch (swap to backend) and the 8s
            // unknown-status watchdog. Pre-rejecting all IP-bound URLs
            // wasted 600-1200 ms per load and over-blocked playable
            // long tracks. HLS still preferred when the resolver
            // returns it (see YouTubeStreamResolver hlsManifestUrl
            // branch); this is just the no-pre-validation fall-through.
            if song.isYouTubeSource,
               Self.urlIsIPBound(finalURL),
               !Self.urlIsHLS(finalURL) {
                let ipDuration = self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration
                Self.logger.info("⚠️ IP-bound URL accepted dur=\(Int(ipDuration))s — playing directly, reactive recovery on .failed")
            }

            Self.logger.info("🎵 [3/5] Final URL: \(finalURL.host ?? "?") (\(finalURL.absoluteString.count) chars)")

            // Stream directly — AVPlayer handles progressive buffering.
            // The download-before-play experiment stalled on googlevideo
            // CDNs; streaming is the stable path that was working before.
            let playURL = finalURL
            tmark("url finalized (resolve + relay override done)")

            // Resolver can take a beat on first play; if the user skipped
            // to another track while we were resolving, drop this result
            // so we don't race a newer loadCurrentSong's item install.
            // Single-flight install: only the LATEST load may mutate player
            // state. A newer loadCurrentSong bumps `loadToken`, so any stale
            // resolve (even for the same song) aborts here instead of racing
            // an AVPlayerItem install onto the active relay playback.
            guard self.currentSong?.youtubeID == song.youtubeID,
                  loadGen == self.loadToken else {
                self.cpdiag("install ABORT stale (gen=\(loadGen) cur=\(self.loadToken))")
                Self.logger.info("🎵 Stale load — aborting install for \(song.youtubeID) (gen=\(loadGen) cur=\(self.loadToken))")
                return
            }

            // ───── DEBUG TRACE (STRICT DEBUG MODE) ─────
            // Pre-flight metadata logging only. The HTTP probe used to
            // live here and blocked the hand-off to AVPlayer by 1-2s
            // because of the `await URLSession.shared.data(for:)` call.
            // The probe is now dispatched AFTER item install, in a
            // detached Task, so playback start is no longer gated on it.
            if song.isYouTubeSource {
                let comps = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)
                let expire = comps?.queryItems?.first(where: { $0.name == "expire" })?.value
                let ip = comps?.queryItems?.first(where: { $0.name == "ip" })?.value ?? "none"
                let mime = comps?.queryItems?.first(where: { $0.name == "mime" })?.value ?? "?"
                let nowTs = Date().timeIntervalSince1970
                let expireTs = expire.flatMap(TimeInterval.init) ?? 0
                let secondsLeft = expireTs > 0 ? Int(expireTs - nowTs) : -1
                Self.logger.info("🧪 DBG pre-AVPlayer host=\(finalURL.host ?? "?")")
                Self.logger.info("🧪 DBG pre-AVPlayer mime=\(mime) expire=\(expire ?? "nil") secondsLeft=\(secondsLeft)")
                Self.logger.info("🧪 DBG pre-AVPlayer ipParam=\(ip)")
                Self.logger.info("🧪 DBG pre-AVPlayer fullURL=\(finalURL.absoluteString)")
            }
            // ───────────────────────────────────────────

            // Race-to-first-bytes warmup. Fires a background range GET
            // for the first 512KB of the audio stream BEFORE AVPlayer
            // touches the URL. This primes CDN edge caches, warms the
            // TLS/HTTP-2 connection to the googlevideo host, and pulls
            // the moov atom into hot network caches — shaving startup
            // time on long tracks where moov size dominates. Fire-and-
            // forget: never awaited, never surfaces errors. Only runs
            // for YT long tracks (> 1200s); short tracks are already
            // near-instant and don't need the extra RTT.
            let warmupDuration = self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration
            // Skip warmup for HLS: a range GET on an .m3u8 manifest
            // pulls ~a few KB of playlist text, not an moov atom —
            // zero latency win, pointless network work.
            if song.isYouTubeSource, warmupDuration > 1200, !Self.urlIsHLS(finalURL) {
                let warmupURL = finalURL
                Task.detached(priority: .userInitiated) {
                    var req = URLRequest(url: warmupURL)
                    req.httpMethod = "GET"
                    req.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
                    req.timeoutInterval = 10
                    let started = Date()
                    do {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        Self.logger.info("⚡️ warmup HTTP \(status) \(data.count)B in \(ms)ms")
                    } catch {
                        // Silent. Warmup is best-effort — failure has no
                        // impact on AVPlayer's own fetch which runs in
                        // parallel anyway.
                        Self.logger.info("⚡️ warmup failed: \(error.localizedDescription)")
                    }
                }
            }

            self.currentLoader = nil
            // Gapless preload: reuse prebuilt + pre-buffered
            // AVPlayerItem if it matches the current song and hasn't
            // failed. Extended to YouTube — the Phase 1 resolver cache
            // already skips IP-bound URLs, so the preloaded item's
            // URL is IP-neutral and safe to hold across the ~20-60s
            // between preload and play.
            //
            // At swap time we detach the item from `preloaderPlayer`
            // so the main `player` becomes its sole owner. The item's
            // buffer state persists across this move — that's what
            // produces the near-instant transition for long tracks.
            //
            // Gapless preload: reuse the pre-buffered AVPlayerItem when
            // one was warmed for this song. `takePreloadedItem` detaches
            // the warmer player first (line ~2017) so the item moves
            // cleanly to the main player; its buffer state survives the
            // move and produces a near-instant transition into
            // .readyToPlay for long tracks. Safety: if the preload
            // reached .failed during buffering, drop the slot and fall
            // through to a fresh build.
            // Always build a FRESH AVPlayerItem per install. Reusing a
            // pre-warmed item that was associated with `preloaderPlayer`
            // is unsafe on iOS 26 and a source of stale-state bugs; the
            // small gapless win isn't worth the lifecycle risk. Consume
            // (and discard) any warmed slot for this song so it detaches
            // from the warmer and can't be reused elsewhere.
            _ = self.takePreloadedItem(songID: song.youtubeID, allowFailed: true)
            // Vanilla item, default AppleCoreMedia UA. (CP5 precise-timing-off
            // reverted: no measurable readyToPlay win — the delay is worker
            // first-byte / moov-at-EOF latency, not AVFoundation's scan.)
            let item = AVPlayerItem(url: playURL)
            // Adaptive forward buffer: 60 s on cellular / constrained
            // networks (forest, tunnels), 30 s on WiFi. Combined with
            // `automaticallyWaitsToMinimizeStalling=true` this lets
            // playback ride out signal blackouts without freezing.
            // Peak-bitrate cap on cellular pulls HLS variants down to
            // ~64 kbps so the buffer fills even on weak signal.
            // Startup latency unaffected — every play path uses
            // `playImmediately(atRate:)`, which fires as soon as the
            // first sample lands regardless of buffer level.
            item.preferredForwardBufferDuration = preferredForwardBufferDurationForCurrentNetwork
            item.preferredPeakBitRate = preferredPeakBitRateForCurrentNetwork
            Self.logger.info("🎵 [3b/5] AVPlayerItem URL scheme=\(playURL.scheme ?? "?") isFile=\(playURL.isFileURL) bufferSec=\(self.preferredForwardBufferDurationForCurrentNetwork) peakBR=\(self.preferredPeakBitRateForCurrentNetwork)")

            // KVO: observe item.status to know when it's ready or failed.
            itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Identity + generation guard: ignore a status
                    // callback from a load that was superseded, or from
                    // an item no longer installed on the player. Without
                    // this a stale item's late .readyToPlay/.failed
                    // mutates the current item's state.
                    guard self.loadStillCurrent(loadGen, playerItem) else {
                        Self.logger.info("⏭️ stale status callback ignored (gen=\(loadGen))")
                        return
                    }
                    switch playerItem.status {
                    case .readyToPlay:
                        let dur = playerItem.duration.seconds
                        Self.logger.info("🎵 [4/5] READY — duration: \(dur)s")
                        self.tmark("readyToPlay")
                        // Item produced a status — kill the unknown-hang
                        // watchdog so it can't fire after the fact.
                        self.unknownStatusWatchdog?.cancel()
                        self.unknownStatusWatchdog = nil
                        if dur.isFinite, dur > 0 {
                            self.duration = dur
                        }
                        self.isBuffering = false
                        self.isLoadingItem = false
                        self.loadingSongID = nil
                        // Auto-play when ready. playImmediately skips
                        // AVPlayer's buffer-fill heuristic — starts
                        // now even if only a small buffer is present.
                        if self.wantsToPlay {
                            Self.logger.info("🎵 [5/5] Auto-playing at \(self.playbackSpeed)x...")
                            self.player.playImmediately(atRate: self.playbackSpeed)
                            self.isPlaying = true
                            self.updateNowPlayingPlaybackState()
                        }
                        // Resume-from-saved-position: only fires when
                        // an external surface (App Intent) armed it
                        // before setQueue. Skip entirely if the item
                        // didn't report a finite, positive duration —
                        // seeking against an indefinite/NaN duration
                        // can land outside the playable range.
                        if let resumeAt = self.pendingResumeSeconds {
                            self.pendingResumeSeconds = nil
                            let rawDur = playerItem.duration
                            let durSecs = rawDur.isIndefinite ? .nan : rawDur.seconds
                            if !durSecs.isFinite || durSecs <= 0 {
                                Self.logger.info("⏪ Resume skipped — item duration unreliable")
                            } else if resumeAt > 3, resumeAt < durSecs - 5 {
                                let target = CMTime(seconds: resumeAt, preferredTimescale: 600)
                                self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        self.currentTime = resumeAt
                                        self.progress = resumeAt / durSecs
                                        self.updateNowPlayingPlaybackState()
                                    }
                                }
                                Self.logger.info("⏪ Resume seek armed → \(Int(resumeAt))s of \(Int(durSecs))s")
                            } else {
                                Self.logger.info("⏪ Resume skipped — position \(Int(resumeAt))s out of valid window")
                            }
                        }
                        // Fire-and-forget mirror into hot cache AFTER
                        // playback is live. JioSaavn only — YT URLs are
                        // IP/session-bound and mirror unreliably.
                        if !playURL.isFileURL, song.youtubeID.hasPrefix("jio_") {
                            HotCacheManager.shared.cache(songID: song.youtubeID, from: playURL)
                        }
                    case .failed:
                        let err = playerItem.error?.localizedDescription ?? "unknown"
                        Self.logger.error("🎵 FAILED: \(err)")
                        // Item failed cleanly — no need for the
                        // unknown-hang watchdog any more.
                        self.unknownStatusWatchdog?.cancel()
                        self.unknownStatusWatchdog = nil
                        // webm/opus safety fallback — if an mp4 fallback
                        // was armed for this load, swap to it instead of
                        // surfacing the error.
                        if !self.ytFallbackUsed,
                           let fb = self.pendingYTFallbackURL,
                           song.isYouTubeSource {
                            Self.logger.info("🎵 webm failed → fallback mp4")
                            self.swapToYTFallback(url: fb, song: song)
                            return
                        }
                        // Backend yt-dlp fallback — covers 403 /
                        // "permission denied" / "no stream" errors that
                        // the client-side InnerTube chain produces when
                        // YouTube hands back an IP-bound URL or a
                        // LOGIN_REQUIRED response. One-shot per load,
                        // resumes from currentTime so the user doesn't
                        // restart from 0:00.
                        if !self.backendFallbackUsed, song.isYouTubeSource {
                            Self.logger.info("🎵 client resolve failed → backend yt-dlp fallback")
                            let resumeAt = self.currentTime
                            self.swapToBackendYTStream(song: song, resumeAt: resumeAt)
                            return
                        }
                        // ───── DEBUG TRACE (STRICT DEBUG MODE) ─────
                        if let e = playerItem.error as NSError? {
                            Self.logger.error("🧪 DBG AVPlayerItem.error domain=\(e.domain) code=\(e.code)")
                            Self.logger.error("🧪 DBG AVPlayerItem.error localized=\(e.localizedDescription)")
                            for (k, v) in e.userInfo {
                                Self.logger.error("🧪 DBG AVPlayerItem.userInfo[\(k)]=\(String(describing: v))")
                            }
                            if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
                                Self.logger.error("🧪 DBG AVPlayerItem.underlying domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
                            }
                        }
                        if let errLog = playerItem.errorLog() {
                            for ev in errLog.events {
                                Self.logger.error("🧪 DBG errorLog: status=\(ev.errorStatusCode) domain=\(ev.errorDomain) comment=\(ev.errorComment ?? "nil") uri=\(ev.uri ?? "nil")")
                            }
                        }
                        if let accessLog = playerItem.accessLog() {
                            for ev in accessLog.events {
                                Self.logger.info("🧪 DBG accessLog: uri=\(ev.uri ?? "nil") transferDuration=\(ev.transferDuration) bytesTransferred=\(ev.numberOfBytesTransferred)")
                            }
                        }
                        // ───────────────────────────────────────────
                        self.playbackError = err
                        self.isBuffering = false
                        self.isPlaying = false
                        self.isLoadingItem = false
                        self.loadingSongID = nil
                        self.clearPlayFeedback(animated: false)
                    case .unknown:
                        Self.logger.info("🎵 Status: unknown (buffering...)")
                    @unknown default:
                        break
                    }
                }
            }

            // Install the item synchronously so AVPlayer can start
            // loading the asset (moov, first chunks) in parallel with
            // EQ mix setup. `EQManager.createAudioMix` awaits
            // `asset.loadTracks`; awaiting it BEFORE replaceCurrentItem
            // blocks playback start on long progressive items because
            // loadTracks must fetch + parse the full moov atom before
            // returning. Detach the warmer first — iOS 26 rejects an
            // AVPlayerItem still associated with another AVPlayer.
            preloaderPlayer.replaceCurrentItem(with: nil)
            player.replaceCurrentItem(with: item)
            tmark("item installed (replaceCurrentItem)")
            player.volume = volume
            observeEndOfItem(item)
            installTimeObserver()

            // PHASE RESET — break the deferred-load deadlock. A paused player
            // with `automaticallyWaitsToMinimizeStalling=true` was not loading
            // the item, so `.readyToPlay` never fired, so the deferred play
            // never ran → item stuck `.unknown` forever (across every source;
            // URLSession warmup loaded fine because it doesn't wait). Nudging
            // playback now forces AVPlayer to start loading; it begins audio on
            // the first samples and the `.readyToPlay` observer still applies
            // resume/telemetry. No eager rate before install — only here.
            if wantsToPlay {
                player.playImmediately(atRate: playbackSpeed)
            }

            // EQ audio mix is best-effort and applied after install so
            // it never gates AVPlayer's status transitions.
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                if let mix = await EQManager.shared.createAudioMix(for: item) {
                    item.audioMix = mix
                }
            }

            // L2 disk cache writeback. Background-download the same
            // URL into `Caches/audio/` so the next replay of this
            // song bypasses the network entirely. Best-effort: failure
            // has zero impact on the now-playing item. Skipped when:
            //   - We're already playing from a local file URL.
            //   - URL is HLS — `.m3u8` only stores the manifest, not
            //     audio bytes; would defeat the cache. Long YT tracks
            //     hit this path; AVPlayer's own segment buffer covers
            //     them at runtime.
            // Only cache SHORT tracks. Long mixes (40-90 min) pulling the FULL
            // file in the background doubled googlevideo traffic through the
            // worker for no playback benefit (AVPlayer's own rolling buffer
            // already covers play-time). Cap at 15 min: short songs still cache
            // fully for instant offline replay; long mixes just stream.
            let l2Duration = self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration
            if !playURL.isFileURL, !Self.urlIsHLS(playURL), l2Duration <= 900 {
                let cacheURL = playURL
                let cacheID = song.youtubeID
                Task.detached(priority: .background) {
                    _ = await AudioDiskCache.shared.store(songID: cacheID, sourceURL: cacheURL)
                }
            }

            // Unknown-status hang watchdog. HLS manifests with
            // path-segment IP binding (manifest.googlevideo.com /ip/.../)
            // can leave AVPlayer stuck in `.unknown` indefinitely when
            // segment fetches 403 — `.failed` never fires, so the
            // backend fallback in the `.failed` branch never gets a
            // chance to run. If we don't reach `.readyToPlay` within
            // 8 s on a YouTube load, force the backend swap so the
            // user gets audio instead of an infinite spinner. One-shot
            // per load, gated by `backendFallbackUsed`.
            unknownStatusWatchdog?.cancel()
            if song.isYouTubeSource {
                let watchdogItem = item
                unknownStatusWatchdog = Task { [weak self] in
                    // EXPERIMENT: 30s (was 8s). Safari needs ~10-15s to
                    // ready a long progressive moov; 8s guillotined valid
                    // loads before readiness. Revert to 8s after the test.
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard let self else { return }
                        // Keyed to THIS load's item identity + generation,
                        // not just the song — a superseded load's watchdog
                        // can't fire a backend swap on the new item.
                        guard self.loadStillCurrent(loadGen, watchdogItem) else { return }
                        guard self.wantsToPlay, !self.backendFallbackUsed else { return }
                        guard watchdogItem.status != .readyToPlay,
                              watchdogItem.status != .failed else { return }
                        // Relay mode: the backend swap is suppressed, so the
                        // old recovery path was a no-op — a stalled load left
                        // isLoadingItem stuck forever (player poisoned until
                        // app restart, esp. on CarPlay-originated loads). The
                        // watchdog now FORCE-CLEARS the wedged loading state so
                        // a subsequent play/next can proceed. Only fires when
                        // genuinely stuck (status still not ready/failed at 30s),
                        // so it can't abort a valid (slower) long-track load.
                        if Self.relayPlaybackMode {
                            self.cpdiag("WATCHDOG force-clear (stuck \(watchdogItem.status.rawValue))")
                            Self.logger.info("🚗DIAG WATCHDOG recovery — load stuck >30s for \(song.youtubeID); force-clearing loading state")
                            self.isLoadingItem = false
                            self.loadingSongID = nil
                            self.isBuffering = false
                            self.playbackError = "Couldn't start this track — tap play to retry."
                        } else {
                            Self.logger.info("⏰ unknown-hang watchdog → backend fallback for \(song.youtubeID)")
                            self.swapToBackendYTStream(song: song, resumeAt: self.currentTime)
                        }
                    }
                }
            }

            // No eager play. Starting `player.rate` before the item is
            // `.readyToPlay` produces the PLAYING→WAITING(NoItemToPlay)
            // churn and races the deferred-start path. Playback is now
            // driven solely by the `.readyToPlay` KVO above
            // (`playImmediately`), which still starts the instant the
            // item is ready. `wantsToPlay` carries the intent.
            Self.logger.info("🎵 Item installed (gen=\(loadGen), deferred start, wantsToPlay: \(self.wantsToPlay))")

            // EXPERIMENT: readiness telemetry. Polls the installed item
            // once/sec for up to 30s, logging buffer growth + status +
            // exact time-to-readyToPlay. Generation/identity guarded and
            // self-terminating on ready/failed/supersede. Remove after
            // the long-progressive readiness experiment concludes.
            let probeItem = item
            let probeStart = Date()
            Task { [weak self] in
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let stop = await MainActor.run { () -> Bool in
                        guard let self else { return true }
                        guard self.loadStillCurrent(loadGen, probeItem) else { return true }
                        let elapsed = Date().timeIntervalSince(probeStart)
                        let buffered = probeItem.loadedTimeRanges
                            .map { CMTimeGetSeconds($0.timeRangeValue.duration) }
                            .reduce(0, +)
                        Self.logger.info("🧪 RDY t=\(String(format: "%.1f", elapsed))s status=\(probeItem.status.rawValue) buffered=\(String(format: "%.1f", buffered))s empty=\(probeItem.isPlaybackBufferEmpty) likely=\(probeItem.isPlaybackLikelyToKeepUp) full=\(probeItem.isPlaybackBufferFull)")
                        if probeItem.status == .readyToPlay {
                            Self.logger.info("🧪 RDY ✅ time-to-readyToPlay=\(String(format: "%.1f", elapsed))s")
                            return true
                        }
                        if probeItem.status == .failed {
                            Self.logger.info("🧪 RDY ❌ failed at \(String(format: "%.1f", elapsed))s err=\(probeItem.error?.localizedDescription ?? "nil")")
                            return true
                        }
                        return false
                    }
                    if stop { break }
                }
            }

            // Async diagnostic probe. Runs AFTER the AVPlayer hand-off
            // so it never blocks playback start. Skipped for tracks
            // longer than 300s (5min) — probe telemetry rarely adds
            // value for long tracks and the request competes with
            // AVPlayer's own range requests for CDN bandwidth.
            if song.isYouTubeSource {
                let probeCheckDuration = self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration
                if probeCheckDuration > 300 {
                    Self.logger.info("🧪 DBG probe SKIPPED (streamDuration=\(Int(probeCheckDuration))s > 300s)")
                } else {
                    Task.detached(priority: .background) {
                        let probeStart = Date()
                        var probeReq = URLRequest(url: finalURL)
                        probeReq.httpMethod = "GET"
                        probeReq.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                        probeReq.timeoutInterval = 8
                        do {
                            let (data, response) = try await URLSession.shared.data(for: probeReq)
                            let ms = Int(Date().timeIntervalSince(probeStart) * 1000)
                            if let http = response as? HTTPURLResponse {
                                let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
                                let cl = http.value(forHTTPHeaderField: "Content-Length") ?? "?"
                                let cr = http.value(forHTTPHeaderField: "Content-Range") ?? "?"
                                Self.logger.info("🧪 DBG probe HTTP \(http.statusCode) in \(ms)ms bytes=\(data.count)")
                                Self.logger.info("🧪 DBG probe CT=\(ct) CL=\(cl) CR=\(cr)")
                                if data.count >= 8 {
                                    let sig = data.subdata(in: 4..<8)
                                    let sigStr = String(data: sig, encoding: .ascii) ?? "?"
                                    Self.logger.info("🧪 DBG probe sig4-8=\(sigStr)")
                                }
                            } else {
                                Self.logger.error("🧪 DBG probe got non-HTTP response")
                            }
                        } catch {
                            let nse = error as NSError
                            Self.logger.error("🧪 DBG probe FAILED domain=\(nse.domain) code=\(nse.code) desc=\(error.localizedDescription)")
                        }
                    }
                }
            }

            // webm/opus watchdog — if a fallback mp4 URL is armed and
            // AVPlayer hasn't reached readyToPlay within 3s, swap to
            // the mp4 fallback. Handles silent webm container failures
            // on iOS (AVPlayer sometimes hangs in .unknown instead of
            // transitioning to .failed).
            if song.isYouTubeSource, let fb = pendingYTFallbackURL {
                ytFallbackWatchdog?.cancel()
                ytFallbackWatchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    guard self.currentSong?.youtubeID == song.youtubeID else { return }
                    if self.ytFallbackUsed { return }
                    let status = self.player.currentItem?.status ?? .unknown
                    if status != .readyToPlay {
                        Self.logger.info("🎵 webm watchdog (\(status.rawValue)) → fallback mp4")
                        self.swapToYTFallback(url: fb, song: song)
                    }
                }
            }
        }
    }

    /// Stall-recovery gate. Called from `scheduleStallRecoveryCheck`
    /// after a debounce when the player has been stuck in `.paused` or
    /// `.waiting` long enough to exceed AVPlayer's natural rebuffer.
    /// Conditions:
    ///   1. User still wants playback (guards against tap-pause).
    ///   2. Playback actually started for this load (startup stalls go
    ///      through the unknown-status / fallback paths instead).
    ///   3. Source is YouTube AND current URL is IP-bound — only case
    ///      where a fresh `resolveStable` produces a different URL.
    ///      For non-YT sources (JioSaavn, backend `/stream`, downloads)
    ///      we rely on AVPlayer's auto-rebuffer
    ///      (`automaticallyWaitsToMinimizeStalling=true`).
    ///   4. Cooldown: at least 30s since the last recovery so we never
    ///      churn even if the fresh URL is also weak.
    private func maybeTriggerStallRecovery(reason: String) {
        guard wantsToPlay,
              playbackStartedAt != nil else { return }
        // User-initiated seek window. Large HLS jumps can keep
        // AVPlayer in `.waiting` for >8s while a new segment range
        // lands; without this guard the debounce would fire a
        // re-resolve + replaceCurrentItem and snap the UI to 0.
        if isSeeking { return }
        if let lastSeek = lastSeekFinishedAt,
           Date().timeIntervalSince(lastSeek) < 5 { return }
        if let last = lastRecoveryAt,
           Date().timeIntervalSince(last) < 30 { return }
        guard let song = currentSong, song.isYouTubeSource else { return }
        guard let asset = player.currentItem?.asset as? AVURLAsset,
              Self.urlIsIPBound(asset.url) else { return }

        let stallDuration = ytStreamDuration > 0 ? ytStreamDuration : song.duration
        lastRecoveryAt = Date()
        let resumeAt = currentTime
        Self.logger.info("⚠️ stall \(reason) on IP-bound URL — re-resolving stable")
        PlaybackTelemetry.shared.logStall(
            songID: song.youtubeID,
            durationSec: Int(stallDuration),
            reason: reason
        )
        PlaybackTelemetry.shared.logRecoveryTriggered(
            songID: song.youtubeID,
            durationSec: Int(stallDuration)
        )
        performStallRecovery(for: song, resumeAt: resumeAt)
    }

    /// Arm an 8-second timer. If `cancelStallRecoveryCheck` doesn't
    /// fire before then, `maybeTriggerStallRecovery` runs. 8 s is
    /// chosen to outlast AVPlayer's typical rebuffer window (~3-5 s)
    /// while still feeling responsive on the road.
    private func scheduleStallRecoveryCheck(reason: String) {
        stallDebounceTask?.cancel()
        stallDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.maybeTriggerStallRecovery(reason: reason)
        }
    }

    /// Cancels any pending recovery debounce. Called from the
    /// `.playing` branch when AVPlayer recovers on its own.
    private func cancelStallRecoveryCheck() {
        stallDebounceTask?.cancel()
        stallDebounceTask = nil
    }

    private func performStallRecovery(for song: Song, resumeAt: TimeInterval) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Capture the load generation at entry. The re-resolve below
            // awaits; a skip/new load during that window must drop this
            // recovery so it can't install a stale item or mutate state.
            let loadGen = self.loadToken
            let fresh: YouTubeStream
            do {
                // Use resolveStable — walks the client chain and rejects
                // IP-bound URLs, so the replacement won't share the same
                // failure mode (IP binding shift mid-playback).
                let recoveryDuration = self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration
                fresh = try await YouTubeStreamResolver.shared.resolveStable(videoID: song.youtubeID, expectedDuration: recoveryDuration)
            } catch {
                Self.logger.error("⚠️ stall recovery resolve failed: \(error.localizedDescription)")
                let durInt = Int(self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration)
                PlaybackTelemetry.shared.logRecoveryOutcome(
                    songID: song.youtubeID, durationSec: durInt, succeeded: false
                )
                return
            }
            // Superseded during the re-resolve window (skip / new load)
            // → drop result. The generation guard closes the TOCTOU
            // between this check and the synchronous install below.
            guard loadGen == self.loadToken,
                  self.currentSong?.youtubeID == song.youtubeID else { return }
            // Defensive: resolveStable rejects IP-bound URLs internally.
            // If one slipped through, abort recovery — replacing would
            // reproduce the exact failure mode we're recovering from.
            if Self.urlIsIPBound(fresh.url) {
                Self.logger.error("⚠️ resolveStable returned IP-bound URL — aborting recovery")
                let durInt = Int(self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration)
                PlaybackTelemetry.shared.logRecoveryOutcome(
                    songID: song.youtubeID, durationSec: durInt, succeeded: false
                )
                return
            }
            Self.logger.info("✅ stall recovery — new URL host=\(fresh.url.host ?? "?")")

            self.itemStatusObservation?.invalidate()
            self.itemStatusObservation = nil
            if let token = self.timeObserverToken {
                self.player.removeTimeObserver(token)
                self.timeObserverToken = nil
            }

            let item = AVPlayerItem(url: fresh.url)
            item.preferredForwardBufferDuration = preferredForwardBufferDurationForCurrentNetwork
            item.preferredPeakBitRate = preferredPeakBitRateForCurrentNetwork

            self.itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] pi, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Identity + generation guard — a superseded recovery
                    // item's late callback cannot mutate the current load.
                    guard self.loadStillCurrent(loadGen, pi) else { return }
                    switch pi.status {
                    case .readyToPlay:
                        self.isBuffering = false
                        if resumeAt > 0 {
                            let t = CMTime(seconds: resumeAt, preferredTimescale: 600)
                            // Indefinite tolerance — fresh HLS manifest
                            // may not have the exact keyframe in its
                            // initial seekableTimeRanges. Frame-accurate
                            // seek there clamps near 0; nearest-keyframe
                            // lands cleanly.
                            self.player.seek(to: t, toleranceBefore: .indefinite, toleranceAfter: .indefinite)
                        }
                        if self.wantsToPlay {
                            self.player.playImmediately(atRate: self.playbackSpeed)
                            self.isPlaying = true
                            self.updateNowPlayingPlaybackState()
                        }
                        // Playback stable on the replacement item.
                        // Cooldown on `maybeTriggerStallRecovery`
                        // (30 s since `lastRecoveryAt`) prevents a
                        // recovery loop even though the latch is gone.
                        Self.logger.info("✅ recovered long-track playback")
                        let durInt = Int(self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration)
                        PlaybackTelemetry.shared.logRecoveryOutcome(
                            songID: song.youtubeID, durationSec: durInt, succeeded: true
                        )
                    case .failed:
                        Self.logger.error("⚠️ stall recovery item failed: \(pi.error?.localizedDescription ?? "unknown")")
                        let durInt = Int(self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration)
                        PlaybackTelemetry.shared.logRecoveryOutcome(
                            songID: song.youtubeID, durationSec: durInt, succeeded: false
                        )
                    default: break
                    }
                }
            }

            // Install synchronously (no await between the supersede guard
            // above and this install → TOCTOU closed), then apply EQ. No
            // eager rate: playback starts only from the .readyToPlay
            // branch above, matching the main/backend/fallback paths.
            self.player.replaceCurrentItem(with: item)
            self.observeEndOfItem(item)
            self.installTimeObserver()
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                if let mix = await EQManager.shared.createAudioMix(for: item) {
                    item.audioMix = mix
                }
            }
        }
    }

    /// Replace current AVPlayerItem with the mp4 fallback URL. Tears
    /// down the existing status observer and wires a fresh one. Called
    /// from the status=.failed branch and the 3s watchdog. Marked used
    /// so it can't recurse.
    /// Backend yt-dlp fallback. Builds a backend proxy URL for the
    /// current YT video, replaces the AVPlayerItem in place, and seeks
    /// to `resumeAt` once the new item is ready so playback resumes
    /// from the same timestamp. The backend endpoint is expected to
    /// stream / redirect to a fresh, IP-stable audio URL on demand.
    /// One-shot per load via `backendFallbackUsed`.
    private func swapToBackendYTStream(song: Song, resumeAt: TimeInterval) {
        // Relay mode: never swap to the backend yt-dlp stream. The relay is the
        // single source of truth and re-resolves itself; a swap here would
        // replace the live relay item and hijack player state.
        if Self.relayPlaybackMode {
            Self.logger.info("⛔️ backend yt-dlp fallback suppressed (relay mode)")
            return
        }
        backendFallbackUsed = true
        let loadGen = loadToken
        unknownStatusWatchdog?.cancel()
        unknownStatusWatchdog = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        // Backend `/stream?id=yt_{id}` 302-redirects to a Cloudflare
        // Worker that proxies audio/mp4 bytes from googlevideo. The
        // Worker uses its own egress IP, so the IP-bound URL trap
        // that breaks the on-device InnerTube path doesn't apply.
        let rawID = song.youtubeID.hasPrefix("yt_") ? song.youtubeID : "yt_\(song.youtubeID)"
        guard var components = URLComponents(string: Config.backendBaseURL) else {
            Self.logger.error("🎵 [backend-fallback] invalid backendBaseURL")
            playbackError = "Unable to play this track"
            isBuffering = false
            isPlaying = false
            isLoadingItem = false
            return
        }
        components.path = "/stream"
        components.queryItems = [URLQueryItem(name: "id", value: rawID)]
        guard let url = components.url else {
            Self.logger.error("🎵 [backend-fallback] failed to build URL for \(rawID)")
            playbackError = "Unable to play this track"
            isBuffering = false
            isPlaying = false
            isLoadingItem = false
            return
        }
        Self.logger.info("🎵 [backend-fallback] swap → \(url.absoluteString) resumeAt=\(Int(resumeAt))s")

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = preferredForwardBufferDurationForCurrentNetwork
            item.preferredPeakBitRate = preferredPeakBitRateForCurrentNetwork

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.loadStillCurrent(loadGen, playerItem) else {
                    Self.logger.info("⏭️ stale backend status callback ignored (gen=\(loadGen))")
                    return
                }
                switch playerItem.status {
                case .readyToPlay:
                    let dur = playerItem.duration.seconds
                    Self.logger.info("🎵 [backend-fallback] READY — duration: \(dur)s")
                    if dur.isFinite, dur > 0 { self.duration = dur }
                    self.isBuffering = false
                    self.isLoadingItem = false
                    // Seek to last-known position before resuming so the
                    // user doesn't start over.
                    let rawDur = playerItem.duration
                    let durSecs = rawDur.isIndefinite ? .nan : rawDur.seconds
                    if resumeAt > 1, durSecs.isFinite, durSecs > 0, resumeAt < durSecs - 1 {
                        let target = CMTime(seconds: resumeAt, preferredTimescale: 600)
                        self.player.seek(to: target, toleranceBefore: .indefinite, toleranceAfter: .indefinite) { [weak self] _ in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.currentTime = resumeAt
                                if durSecs > 0 { self.progress = resumeAt / durSecs }
                                self.updateNowPlayingPlaybackState()
                                if self.wantsToPlay {
                                    self.player.playImmediately(atRate: self.playbackSpeed)
                                    self.isPlaying = true
                                    self.updateNowPlayingPlaybackState()
                                }
                            }
                        }
                    } else if self.wantsToPlay {
                        self.player.playImmediately(atRate: self.playbackSpeed)
                        self.isPlaying = true
                        self.updateNowPlayingPlaybackState()
                    }
                case .failed:
                    let err = playerItem.error?.localizedDescription ?? "unknown"
                    Self.logger.error("🎵 [backend-fallback] FAILED: \(err)")
                    self.playbackError = err
                    self.isBuffering = false
                    self.isPlaying = false
                    self.isLoadingItem = false
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        // Install the item synchronously so AVPlayer starts driving
        // status transitions (.unknown → .readyToPlay/.failed) and the
        // KVO observer above can clear isLoadingItem. EQ mix is
        // best-effort and applied after attach; awaiting it here can
        // stall on `asset.loadTracks` for backend URLs (302 redirect +
        // fragmented MP4 parse), leaving the player wedged in
        // .unknown forever.
        self.player.replaceCurrentItem(with: item)
        self.observeEndOfItem(item)
        // Backend's own unknown-hang watchdog. The backend stream can
        // also stall in .unknown (CDN 403 / proxy timeout). Since this
        // is the last-resort source, surface an error + clear the load
        // lock instead of hanging forever — nothing left to fall to.
        let backendItem = item
        unknownStatusWatchdog?.cancel()
        unknownStatusWatchdog = Task { [weak self] in
            // EXPERIMENT: 30s (was 8s) — match the main-load watchdog so
            // the backend leg also gets a realistic readiness window.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                guard self.loadStillCurrent(loadGen, backendItem) else { return }
                guard backendItem.status != .readyToPlay,
                      backendItem.status != .failed else { return }
                Self.logger.error("⏰ backend-fallback unknown-hang — surfacing error")
                self.playbackError = "This track is unavailable right now"
                self.isBuffering = false
                self.isPlaying = false
                self.isLoadingItem = false
                self.loadingSongID = nil
            }
        }
        Task { @MainActor in
            if let mix = await EQManager.shared.createAudioMix(for: item) {
                item.audioMix = mix
            }
        }
    }

    private func swapToYTFallback(url: URL, song: Song) {
        // Relay mode: never swap to the webm→mp4 fallback URL. The relay always
        // serves itag-139/140 m4a; a swap here would replace the live relay
        // item with a googlevideo URL and hijack player state.
        if Self.relayPlaybackMode {
            Self.logger.info("⛔️ webm→mp4 fallback suppressed (relay mode)")
            return
        }
        ytFallbackUsed = true
        let loadGen = loadToken
        pendingYTFallbackURL = nil
        ytFallbackWatchdog?.cancel()
        ytFallbackWatchdog = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = preferredForwardBufferDurationForCurrentNetwork
            item.preferredPeakBitRate = preferredPeakBitRateForCurrentNetwork
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.loadStillCurrent(loadGen, playerItem) else {
                    Self.logger.info("⏭️ stale fallback status callback ignored (gen=\(loadGen))")
                    return
                }
                switch playerItem.status {
                case .readyToPlay:
                    let dur = playerItem.duration.seconds
                    Self.logger.info("🎵 [fallback] READY — duration: \(dur)s")
                    if dur.isFinite, dur > 0 { self.duration = dur }
                    self.isBuffering = false
                    self.isLoadingItem = false
                    self.loadingSongID = nil
                    if self.wantsToPlay {
                        self.player.playImmediately(atRate: self.playbackSpeed)
                        self.isPlaying = true
                        self.updateNowPlayingPlaybackState()
                    }
                    if let resumeAt = self.pendingResumeSeconds {
                        self.pendingResumeSeconds = nil
                        let rawDur = playerItem.duration
                        let durSecs = rawDur.isIndefinite ? .nan : rawDur.seconds
                        if !durSecs.isFinite || durSecs <= 0 {
                            Self.logger.info("⏪ [fallback] Resume skipped — item duration unreliable")
                        } else if resumeAt > 3, resumeAt < durSecs - 5 {
                            let target = CMTime(seconds: resumeAt, preferredTimescale: 600)
                            self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    self.currentTime = resumeAt
                                    self.progress = resumeAt / durSecs
                                    self.updateNowPlayingPlaybackState()
                                }
                            }
                            Self.logger.info("⏪ [fallback] Resume seek armed → \(Int(resumeAt))s of \(Int(durSecs))s")
                        } else {
                            Self.logger.info("⏪ [fallback] Resume skipped — position \(Int(resumeAt))s out of valid window")
                        }
                    }
                case .failed:
                    let err = playerItem.error?.localizedDescription ?? "unknown"
                    Self.logger.error("🎵 [fallback] FAILED: \(err)")
                    self.playbackError = err
                    self.isBuffering = false
                    self.isPlaying = false
                    self.isLoadingItem = false
                    self.loadingSongID = nil
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        // Install synchronously so AVPlayer starts driving status
        // transitions and the item becomes `player.currentItem` (the
        // identity the KVO guard checks). Awaiting EQ's `asset.loadTracks`
        // before install can wedge the item in .unknown forever. EQ is
        // best-effort and applied after attach.
        self.player.replaceCurrentItem(with: item)
        self.observeEndOfItem(item)
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            if let mix = await EQManager.shared.createAudioMix(for: item) {
                item.audioMix = mix
            }
        }
    }

    /// Install AVPlayer's periodic time observer — this is the RELIABLE
    /// way to track currentTime. Replaces the Task-based timer which
    /// didn't fire properly because it wasn't tied to the player.
    private func installTimeObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handleTimeUpdate(time)
            }
        }
    }

    private var hasPreloadedNext = false
    /// One-shot guard for the L2 disk pre-download per load. Reset in
    /// `loadCurrentSong` and on track-advance helpers.
    private var hasPrefetchedNextL2 = false
    private var preloadedURL: URL?
    private var preloadedSongID: String?
    /// Tier 1 preload — YT fallback mp4 URL captured at resolve time so
    /// the main load path can arm the webm→mp4 watchdog when using the
    /// preloaded URL.
    private var preloadedYTFallback: URL?
    /// Tier 1 preload — resolved stream duration. Captured here because
    /// the Song.duration metadata coming off YouTube search is unreliable
    /// for long videos (sometimes 0, sometimes clamped). The probe-skip
    /// decision uses this when available.
    private var preloadedYTDuration: TimeInterval?
    /// Tier 2 preload — AVPlayerItem prebuilt against the resolved CDN
    /// URL, keyed by queue index. On skip the matching slot is installed
    /// directly via `player.replaceCurrentItem`, saving ~1-2s of URL
    /// resolve + item construction. Two slots so both the immediate
    /// next (index+1) and the one after (index+2) are prebuilt.
    ///
    /// AVPlayer can only hold one `currentItem` at a time, so only the
    /// index+1 slot attaches to `preloaderPlayer` for buffer warmup.
    /// The index+2 slot is held cold — built but not warmed — and gets
    /// promoted into the warmer when the user advances.
    private struct PreloadedItemSlot {
        let songID: String
        let item: AVPlayerItem
    }
    private var preloadedItems: [Int: PreloadedItemSlot] = [:]
    private let maxPreloadSlots = 2
    /// Single source of truth guarding overlapping `loadCurrentSong`
    /// calls. Rapid Next taps or the sequence nextTrack() →
    /// loadCurrentSong() → play() can otherwise fire multiple loads in
    /// the same main-actor hop, producing duplicate stream resolves
    /// and racing AVPlayerItem installs. All load entry points use
    /// this same guard; every early-exit and completion path resets it.
    private var isLoadingItem = false
    /// youtubeID of the song the in-flight load is resolving. Lets the
    /// `isLoadingItem` lock distinguish a same-song duplicate (skip)
    /// from a different-song request (supersede). Cleared on every
    /// terminal load path.
    private var loadingSongID: String?
    /// Monotonic load generation, bumped at the start of every
    /// `loadCurrentSong`. Async callbacks (status KVO, watchdogs, seek
    /// completions) capture the value live at dispatch and must re-check
    /// it — together with item identity — before mutating shared player
    /// state. A superseded load's late callback bails instead of
    /// corrupting the current item (root of the PLAYING→WAITING wedge).
    private var loadToken: Int = 0

    /// Rate-limits rapid `loadCurrentSong` calls (spam Next, mood tap,
    /// preload overlap). A 0.8s cooldown coalesces bursts into a single
    /// load without needing to plumb debouncing into every caller.
    private var lastLoadTime: Date = .distantPast

    /// Phase 2 prefetch handles. Each setQueue() cancels the previous
    /// batch so a fast queue change (tap A → tap B before A loads)
    /// doesn't leave resolver Tasks for the abandoned queue running
    /// in the background.
    @ObservationIgnored nonisolated(unsafe) private var prefetchTasks: [Task<Void, Never>] = []

    /// Fire resolver prefetch for the current track and the next one,
    /// populating YouTubeStreamResolver's in-memory cache so the
    /// loadCurrentSong path hits cache instead of doing a fresh
    /// InnerTube round trip. Inflight coalescing inside the resolver
    /// guarantees that a subsequent `resolve()` from loadCurrentSong
    /// rides on this Task rather than spawning a duplicate.
    /// Phase 1 (safe preload): once per track, ~60% through, fire ONE
    /// best-effort background HEAD at the relay for the NEXT song so the relay
    /// resolves + caches its yt-dlp URL before the user taps next. Metadata
    /// warm only — builds no AVPlayerItem, never touches `player`, never
    /// autoplays. Failure is silent and cannot affect live playback.
    private var relayWarmedForSongID: String?
    private var fstreamWarmedForSongID: String?

    /// Prewarm the next track's faststart build on Fly so it's cached and
    /// instant when the queue advances. HEAD triggers Fly's resolve +
    /// concurrent-subrange download + remux without transferring the body.
    /// Best-effort, no player mutation, silent failure — cannot affect live
    /// playback (mirrors `prewarmNextRelay`).
    private func prewarmNextFstream() {
        guard let idx = nextIndex(), queue.indices.contains(idx) else { return }
        let next = queue[idx]
        guard next.isYouTubeSource,
              let url = Self.fstreamURL(youtubeID: next.youtubeID) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 90
        let sid = next.youtubeID
        Task.detached(priority: .utility) {
            _ = try? await URLSession.shared.data(for: req)
            Self.logger.info("⚡️ fstream prewarm \(sid, privacy: .public)")
        }
    }

    private func prewarmNextRelay() {
        guard let idx = nextIndex(), queue.indices.contains(idx) else { return }
        let next = queue[idx]
        guard next.isYouTubeSource,
              let url = Self.relayStreamURL(youtubeID: next.youtubeID) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let sid = next.youtubeID
        Task.detached(priority: .utility) {
            _ = try? await URLSession.shared.data(for: req)
            Self.logger.info("🔥 relay prewarm HEAD \(sid, privacy: .public)")
        }
    }

    private func scheduleYTPrefetch() {
        for t in prefetchTasks { t.cancel() }
        prefetchTasks.removeAll()

        let candidates = [currentIndex, currentIndex + 1]
        for idx in candidates where queue.indices.contains(idx) {
            let song = queue[idx]
            guard song.isYouTubeSource else { continue }
            let t = Task.detached(priority: .userInitiated) {
                _ = try? await YouTubeStreamResolver.shared.resolve(videoID: song.youtubeID, expectedDuration: song.duration)
            }
            prefetchTasks.append(t)
        }
    }

    private func handleTimeUpdate(_ time: CMTime) {
        let secs = time.seconds
        guard secs.isFinite else { return }
        // Suppress observer writes while a seek is in flight — otherwise
        // a stale player.currentTime() reading would snap the UI back
        // to the pre-seek position.
        guard !isSeeking else { return }
        currentTime = secs

        // Pick up duration if it wasn't known at load time.
        if duration <= 0, let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
        }

        progress = duration > 0 ? min(max(secs / duration, 0), 1) : 0
        updateNowPlayingPlaybackState()

        // Phase 1 safe preload: warm the relay for the next track once we're
        // ~60% through. Best-effort, no player mutation (see prewarmNextRelay).
        if Self.relayPlaybackMode, progress >= 0.6,
           let cur = currentSong?.youtubeID, relayWarmedForSongID != cur {
            relayWarmedForSongID = cur
            prewarmNextRelay()
        }

        // Faststart prewarm: build the next track on Fly at ~40% so it's
        // cached → instant when the queue advances. One-shot per song,
        // best-effort, no player mutation.
        if progress >= 0.4,
           let cur = currentSong?.youtubeID, fstreamWarmedForSongID != cur {
            fstreamWarmedForSongID = cur
            prewarmNextFstream()
        }

        // Save position every ~5 seconds for resume.
        if Int(secs) % 5 == 0 && secs > 1 {
            LastPlayedPersistence.savePosition(secs)
        }

        // Pre-load next song at 30% playback — lowered from 40% to
        // widen the window where a mid-track skip still hits preload.
        // Long tracks (>10min) additionally fire at the 6s mark so the
        // preload finishes early in the 10+ minute listening window;
        // waiting for 30% of a 1hr track would be useless.
        let longTrackEarly = duration > 600 && secs >= 6
        if (progress >= 0.3 || longTrackEarly), !hasPreloadedNext, duration > 0 {
            hasPreloadedNext = true
            preloadNextSong()
        }

        // L2 disk pre-download: when current track is past 50% AND we
        // are on Wi-Fi (or unconstrained), fetch the next track's
        // bytes into `Caches/audio/` so a sudden dead zone on advance
        // still plays from disk. Cellular path skipped — preload
        // already buffers ~60 s ahead in memory, and downloading a
        // full track over LTE would burn data even when the user
        // never advances. One-shot per load via `hasPrefetchedNextL2`.
        if progress >= 0.5,
           !hasPrefetchedNextL2,
           duration > 0,
           !isOnCellular,
           !isConstrainedNetwork {
            hasPrefetchedNextL2 = true
            prefetchNextOnWiFi()
        }

        // End-of-track volume behavior.
        if duration > 5 && (duration - secs) <= crossfadeDuration && (duration - secs) > 0 {
            if crossfadeEnabled {
                // Dual-player crossfade — volume handled inside startCrossfade.
                if !crossfadeActive { startCrossfade() }
            } else {
                // Legacy single-player fade-out.
                let fade = Float((duration - secs) / crossfadeDuration)
                player.volume = volume * fade
            }
        } else if !crossfadeActive, player.volume != volume {
            player.volume = volume
        }
    }

    /// L2 disk pre-download for the next track. Resolves the URL via
    /// the existing in-memory resolver cache (cheap if already warmed
    /// by `preloadNextSong`) then writes the audio bytes to the L2
    /// disk cache. Wi-Fi only — caller is expected to have gated on
    /// `!isOnCellular && !isConstrainedNetwork`.
    private func prefetchNextOnWiFi() {
        guard let nextIdx = nextIndex(), queue.indices.contains(nextIdx) else {
            return
        }
        let nextSong = queue[nextIdx]
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            // Skip work entirely if already on disk.
            if await AudioDiskCache.shared.cachedFileURL(for: nextSong.youtubeID) != nil {
                return
            }
            // Resolve URL.
            let resolvedURL: URL?
            if nextSong.isYouTubeSource {
                resolvedURL = (try? await YouTubeStreamResolver.shared
                    .resolve(videoID: nextSong.youtubeID, expectedDuration: nextSong.duration))?.url
            } else {
                resolvedURL = await self.resolveBackendStreamURL(for: nextSong)
            }
            guard let url = resolvedURL else { return }
            // HLS manifests are tiny pointers — caching the .m3u8
            // doesn't store audio bytes. Skip; the in-memory preload
            // already buffers the first segments.
            if await Self.urlIsHLS(url) { return }
            _ = await AudioDiskCache.shared.store(songID: nextSong.youtubeID, sourceURL: url)
        }
    }

    /// Resolves the backend `/stream?id=` URL through its 302 redirect
    /// to the underlying CF Worker / CDN URL so we can hand a stable
    /// fetchable URL to `AudioDiskCache.store`.
    private nonisolated func resolveBackendStreamURL(for song: Song) async -> URL? {
        guard var components = URLComponents(string: Config.backendBaseURL) else { return nil }
        components.path = "/stream"
        components.queryItems = [URLQueryItem(name: "id", value: song.youtubeID)]
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        // Don't follow — let URLSession surface the Location so we can
        // download from the underlying URL directly. URLSession follows
        // by default; we use `data(for:)` and inspect the final URL.
        req.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  let finalURL = http.url else { return url }
            return finalURL
        } catch {
            return url
        }
    }

    private func preloadNextSong() {
        // Legacy preload stays disabled regardless of relay mode — it raced
        // AVPlayerItem installs. (Decoupled from relayPlaybackMode.)
        if !Self.legacyPreloadEnabled { return }
        // Don't kick off preload work while the main player is mid-load.
        // Two resolver chains in flight fight each other on the network
        // and can race AVPlayerItem installs. Caller re-fires the 30%
        // preload gate on later time-ticks, so skipping here is safe.
        guard !isLoadingItem else {
            Self.logger.info("⛔️ preloadNextSong skipped — main load in progress")
            return
        }
        // Compute both target slots. offset==0 = index+1 (attaches to
        // warmer for buffer heat), offset==1 = index+2 (cold prebuild).
        let targetIdx1 = nextIndex()
        let targetIdx2 = nextNextIndex()

        // Only the +1 slot stores an AVPlayerItem. +2 is bytes-only
        // (URL resolve + first-128KB range GET), no item, no slot —
        // that way +2 stays lightweight but its URL is resolver-cached
        // and the CDN connection is warm, so a fast double-skip still
        // hits a warm path without paying 2x AVPlayerItem memory cost.
        let keepIndices: Set<Int> = targetIdx1.map { [$0] } ?? []
        evictPreloadedItems(keepingIndices: keepIndices)

        // Reset Tier 1 URL-preload slot. This is still single-slot
        // because only the immediate next (index+1) goes through the YT
        // resolver fast path in loadCurrentSong.
        preloadedURL = nil
        preloadedYTFallback = nil
        preloadedYTDuration = nil
        if let nextIdx = targetIdx1, queue.indices.contains(nextIdx) {
            preloadedSongID = queue[nextIdx].youtubeID
        } else {
            preloadedSongID = nil
        }

        // Detach warmer if the index+1 slot was evicted above — we're
        // about to reassign it below on successful resolve.
        if let nextIdx = targetIdx1,
           preloadedItems[nextIdx] == nil {
            preloaderPlayer.replaceCurrentItem(with: nil)
        }

        if let idx = targetIdx1, queue.indices.contains(idx) {
            let song = queue[idx]
            Self.logger.info("🔮 Preloading +1: \(song.title)")
            preloadOne(song: song, queueIndex: idx, attachToWarmer: true, updateURLSlot: true)
        }
        if let idx = targetIdx2, queue.indices.contains(idx), idx != targetIdx1 {
            let song = queue[idx]
            Self.logger.info("🔮 Preloading +2 (bytes-only): \(song.title)")
            preloadOneBytes(song: song)
        }
    }

    /// Lightweight +2 prefetch. Resolves the stream URL (populates the
    /// YT resolver cache / warms the JIO 302), then fires a single
    /// range GET to open a TLS/HTTP-2 connection to the CDN host and
    /// pull the moov atom + first audio frames into edge cache. No
    /// AVPlayerItem is built — a double-skip into this slot will
    /// construct the item fresh, but URL resolve is a cache hit and
    /// the first-samples fetch rides on the warmed connection, so the
    /// second track starts near-instant without paying the memory +
    /// buffering cost of a full preloaded item.
    ///
    /// Range size adapts to track duration. Longer tracks have larger
    /// moov / init segments, so a slightly larger warmup buys more of
    /// the metadata block that AVPlayer blocks on before readyToPlay.
    /// Capped at 256KB — anything above that is wasted when the user
    /// doesn't skip twice.
    private func preloadOneBytes(song: Song) {
        let songID = song.youtubeID
        let start = Date()

        if song.isYouTubeSource {
            Task(priority: .userInitiated) {
                do {
                    let resolved = try await YouTubeStreamResolver.shared.resolve(videoID: songID, expectedDuration: song.duration)
                    // YT duration from resolver is authoritative — Song.duration
                    // is often 0 for tracks scraped from YouTube search.
                    let dur = resolved.duration > 0 ? resolved.duration : song.duration
                    let rangeHeader = Self.warmupRangeHeader(for: dur)
                    var req = URLRequest(url: resolved.url)
                    req.httpMethod = "GET"
                    req.setValue(rangeHeader, forHTTPHeaderField: "Range")
                    req.timeoutInterval = 10
                    do {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        Self.logger.info("🔮 +2 bytes-warm YT HTTP \(status) \(data.count)B in \(ms)ms dur=\(Int(dur))s range=\(rangeHeader) id=\(songID)")
                    } catch {
                        Self.logger.info("🔮 +2 bytes-warm YT failed: \(error.localizedDescription)")
                    }
                } catch {
                    Self.logger.info("🔮 +2 resolve YT failed: \(error.localizedDescription)")
                }
            }
            return
        }

        guard let url = buildStreamURL(for: song) else { return }
        let rangeHeader = Self.warmupRangeHeader(for: song.duration)
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let resolved = await self.resolveRedirect(url)
            var req = URLRequest(url: resolved)
            req.httpMethod = "GET"
            req.setValue(rangeHeader, forHTTPHeaderField: "Range")
            req.timeoutInterval = 10
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.logger.info("🔮 +2 bytes-warm JIO HTTP \(status) \(data.count)B in \(ms)ms dur=\(Int(song.duration))s range=\(rangeHeader) id=\(songID)")
            } catch {
                Self.logger.info("🔮 +2 bytes-warm JIO failed: \(error.localizedDescription)")
            }
        }
    }

    /// Adaptive range header for the +2 bytes-warm. Short tracks get a
    /// small warm (128KB) because their moov atom is small and extra
    /// bytes would just waste CDN bandwidth. Tracks > 1hr bump to 256KB
    /// — their init segment / moov atom is larger and AVPlayer won't
    /// reach readyToPlay until the full moov is parsed. Cap at 256KB.
    private static func warmupRangeHeader(for duration: TimeInterval) -> String {
        if duration > 3600 { return "bytes=0-262144" }  // > 1hr: 256KB
        return "bytes=0-131072"                          // default: 128KB
    }

    /// Preload one queue slot. Resolves URL, builds AVPlayerItem,
    /// optionally attaches to `preloaderPlayer` for buffer warmup, and
    /// stores the built item in `preloadedItems[queueIndex]`.
    /// - `attachToWarmer`: only one slot at a time can warm (AVPlayer
    ///   holds a single currentItem). The immediate next (index+1) wins.
    /// - `updateURLSlot`: whether this preload should populate the
    ///   single-slot `preloadedURL`/`preloadedYTFallback`/
    ///   `preloadedYTDuration` used by loadCurrentSong's fast path.
    ///   True only for index+1.
    private func preloadOne(song: Song, queueIndex: Int, attachToWarmer: Bool, updateURLSlot: Bool) {
        let preloadStart = Date()
        let songID = song.youtubeID

        if song.isYouTubeSource {
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let resolved = try await YouTubeStreamResolver.shared.resolve(videoID: songID, expectedDuration: song.duration)
                    // Re-check the slot is still wanted for this song.
                    guard self.queue.indices.contains(queueIndex),
                          self.queue[queueIndex].youtubeID == songID else { return }
                    if updateURLSlot, self.preloadedSongID == songID {
                        self.preloadedURL = resolved.url
                        self.preloadedYTFallback = resolved.fallbackURL
                        self.preloadedYTDuration = resolved.duration
                    }
                    let ms = Int(Date().timeIntervalSince(preloadStart) * 1000)
                    Self.logger.info("🔮 Preloaded YT URL [\(queueIndex)] in \(ms)ms host=\(resolved.url.host ?? "?") fallback=\(resolved.fallbackURL != nil) dur=\(Int(resolved.duration))s")

                    let item = AVPlayerItem(url: resolved.url)
                    item.preferredForwardBufferDuration = preferredForwardBufferDurationForCurrentNetwork
                    item.preferredPeakBitRate = preferredPeakBitRateForCurrentNetwork
                    if let mix = await EQManager.shared.createAudioMix(for: item) {
                        item.audioMix = mix
                    }
                    guard self.queue.indices.contains(queueIndex),
                          self.queue[queueIndex].youtubeID == songID else { return }
                    self.storePreloadedItem(item, songID: songID, at: queueIndex, attachToWarmer: attachToWarmer)
                    Self.logger.info("🔮 Preloaded YT AVPlayerItem [\(queueIndex)] warmer=\(attachToWarmer)")
                } catch {
                    Self.logger.info("🔮 Preload YT [\(queueIndex)] failed: \(error.localizedDescription)")
                }
            }
            return
        }

        // JIO / backend path.
        guard let url = buildStreamURL(for: song) else { return }
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let resolved = await self.resolveRedirect(url)
            guard self.queue.indices.contains(queueIndex),
                  self.queue[queueIndex].youtubeID == songID else { return }
            if updateURLSlot, self.preloadedSongID == songID {
                self.preloadedURL = resolved
            }
            let ms = Int(Date().timeIntervalSince(preloadStart) * 1000)
            Self.logger.info("🔮 Preloaded JIO URL [\(queueIndex)] in \(ms)ms host=\(resolved.host ?? "?")")

            let item = AVPlayerItem(url: resolved)
            item.preferredForwardBufferDuration = preferredForwardBufferDurationForCurrentNetwork
            item.preferredPeakBitRate = preferredPeakBitRateForCurrentNetwork
            if let mix = await EQManager.shared.createAudioMix(for: item) {
                item.audioMix = mix
            }
            guard self.queue.indices.contains(queueIndex),
                  self.queue[queueIndex].youtubeID == songID else { return }
            self.storePreloadedItem(item, songID: songID, at: queueIndex, attachToWarmer: attachToWarmer)
            Self.logger.info("🔮 Preloaded JIO AVPlayerItem [\(queueIndex)] warmer=\(attachToWarmer)")
        }
    }

    // MARK: - Preloaded-item slot helpers

    /// Queue index two positions ahead (handles shuffle + repeatMode).
    /// Returns nil when we're at the tail of a non-repeating queue.
    private func nextNextIndex() -> Int? {
        if isShuffled {
            guard let pos = shuffledIndices.firstIndex(of: currentIndex) else { return nil }
            let target = pos + 2
            if target < shuffledIndices.count { return shuffledIndices[target] }
            if repeatMode == .all, !shuffledIndices.isEmpty {
                return shuffledIndices[target % shuffledIndices.count]
            }
            return nil
        } else {
            let target = currentIndex + 2
            if target < queue.count { return target }
            if repeatMode == .all, !queue.isEmpty { return target % queue.count }
            return nil
        }
    }

    /// Consume the preloaded item whose songID matches. Searches all
    /// slots (since an index+2 slot becomes the next current after a
    /// skip-skip). Detaches from warmer if present.
    /// - `allowFailed`: when true, returns only failed items (used by
    ///   the fallback branch to detect-and-evict a dead preload).
    private func takePreloadedItem(songID: String, allowFailed: Bool) -> AVPlayerItem? {
        for (idx, slot) in preloadedItems where slot.songID == songID {
            let failed = slot.item.status == .failed
            if allowFailed != failed { continue }
            preloadedItems.removeValue(forKey: idx)
            // Always detach the warmer before handing the item back.
            // iOS 26 rejects re-attachment if any previous association
            // persists — identity check (===) can miss items that were
            // briefly warmer but have since been replaced.
            preloaderPlayer.replaceCurrentItem(with: nil)
            return slot.item
        }
        return nil
    }

    /// Drop slots whose queue index isn't in `keepingIndices`. Used when
    /// currentIndex changes to prune items the user skipped past.
    private func evictPreloadedItems(keepingIndices: Set<Int>) {
        for idx in preloadedItems.keys where !keepingIndices.contains(idx) {
            if let slot = preloadedItems.removeValue(forKey: idx),
               preloaderPlayer.currentItem === slot.item {
                preloaderPlayer.replaceCurrentItem(with: nil)
            }
        }
    }

    /// Drop slots whose stored songID isn't the consume-target. Invoked
    /// from loadCurrentSong's reset path: the target song's slot is
    /// consumed a few lines later; everything else is stale.
    private func evictStalePreloadedItems(keepSongID: String?) {
        for (idx, slot) in preloadedItems where slot.songID != keepSongID {
            preloadedItems.removeValue(forKey: idx)
            if preloaderPlayer.currentItem === slot.item {
                preloaderPlayer.replaceCurrentItem(with: nil)
            }
        }
    }

    /// Store a freshly-built AVPlayerItem. Enforces `maxPreloadSlots` by
    /// evicting the slot whose queue index is farthest from `currentIndex`
    /// if we'd exceed the cap. Optionally attaches to `preloaderPlayer`.
    private func storePreloadedItem(_ item: AVPlayerItem, songID: String, at queueIndex: Int, attachToWarmer: Bool) {
        preloadedItems[queueIndex] = PreloadedItemSlot(songID: songID, item: item)

        if preloadedItems.count > maxPreloadSlots {
            let victim = preloadedItems.keys
                .filter { $0 != queueIndex }
                .max(by: { abs($0 - currentIndex) < abs($1 - currentIndex) })
            if let v = victim, let slot = preloadedItems.removeValue(forKey: v),
               preloaderPlayer.currentItem === slot.item {
                preloaderPlayer.replaceCurrentItem(with: nil)
            }
        }

        if attachToWarmer {
            preloaderPlayer.replaceCurrentItem(with: item)
        }
    }

    /// Drop every preload slot and detach the warmer. Called from stop().
    private func clearAllPreloadedItems() {
        preloaderPlayer.replaceCurrentItem(with: nil)
        preloadedItems.removeAll()
    }

    /// Follow redirects via URLSession (GET, not HEAD — some backends
    /// don't respond to HEAD). Reads zero bytes; we only care about
    /// the final response.url.
    private func resolveRedirect(_ url: URL) async -> URL {
        // Create a session config that follows redirects (default).
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            var request = URLRequest(url: url)
            // Use GET with a Range header to avoid downloading the full file.
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let (_, response) = try await session.data(for: request)
            if let finalURL = response.url, finalURL.host != url.host {
                Self.logger.info("🔗 Redirect: \(url.host ?? "") → \(finalURL.host ?? "")")
                return finalURL
            }
        } catch {
            Self.logger.warning("🔗 Redirect resolve failed: \(error.localizedDescription)")
        }
        return url
    }

    /// Wraps an upstream CDN URL (googlevideo, saavncdn) in the audio
    /// Worker endpoint so bytes are mirrored into R2 the first time
    /// and served from the CF edge on subsequent plays. Returns nil if
    /// the id or URL can't be encoded cleanly; callers fall back to the
    /// raw upstream URL in that case.
    /// True if the URL carries an `ip=` query param — googlevideo's
    /// way of locking a signed URL to a specific client IP. Such URLs
    /// 403 when the device's egress IP changes.
    /// Relay base for YouTube playback. AVPlayer streams every YouTube track
    /// through the local byte-range relay (`/stream?id=<videoID>`) instead of
    /// a direct googlevideo URL: the relay resolves a fresh itag-139/140 URL
    /// server-side, stitches bounded subranges into a complete body, and
    /// re-resolves transparently on URL expiry — sidestepping AppleCoreMedia's
    /// direct-googlevideo incompatibility.
    static let relayStreamBase = "http://192.168.1.76:8081"

    /// PHASE 1 RECOVERY: relay-first playback is DISABLED (false).
    ///
    /// When true, every YouTube track was forced through the LAN relay and the
    /// reactive fallbacks (backend yt-dlp swap, webm→mp4) were suppressed. In
    /// the field the LAN relay hit iOS Local Network privacy (-1009 "Local
    /// network prohibited") and ECONNREFUSED (-1004), and with fallbacks
    /// suppressed a relay miss became a HARD FAILURE that poisoned player state.
    ///
    /// false restores the proven path: play the resolved URL and, on failure,
    /// gracefully fall back (webm→mp4, backend stream) — "music always plays".
    /// Re-enable relay only in a later phase with a working fallback in place.
    static let relayPlaybackMode = false

    /// Legacy aggressive next-track preload stays OFF independently of
    /// `relayPlaybackMode` — it raced AVPlayerItem installs. Decoupled so
    /// turning relay off does not resurrect it.
    static let legacyPreloadEnabled = false

    /// Build the relay playback URL for a YouTube videoID. `song.youtubeID`
    /// carries a `yt_` prefix; the relay expects the bare 11-char ID, so strip
    /// it (matching the resolver's own normalization). The ID is URL-safe by
    /// construction; URLComponents percent-encodes defensively.
    static func relayStreamURL(youtubeID rawID: String) -> URL? {
        let id = rawID.hasPrefix("yt_") ? String(rawID.dropFirst(3)) : rawID
        var components = URLComponents(string: relayStreamBase)
        components?.path = "/stream"
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        return components?.url
    }

    /// Backend stream URL — `Config.backendBaseURL/stream?id=yt_<id>`. The
    /// backend (Cloudflare Worker) proxies audio/mp4 from ITS OWN egress IP,
    /// so the IP-bound googlevideo trap (which leaves AVPlayer stuck in
    /// `.unknown`) and iOS Local Network privacy (LAN relay) do not apply.
    /// This is the reliable, AVPlayer-friendly source — the stable baseline.
    static func backendStreamURL(youtubeID rawID: String) -> URL? {
        let id = rawID.hasPrefix("yt_") ? rawID : "yt_\(rawID)"
        guard var components = URLComponents(string: Config.backendBaseURL) else { return nil }
        components.path = "/stream"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    /// Faststart stream URL — `Config.flyBaseURL/fstream?id=yt_<id>`. Fly grabs
    /// itag139 via concurrent subranges and `ffmpeg -movflags +faststart`
    /// repackages it into a moov-at-front progressive MP4, so AVPlayer reaches
    /// `.readyToPlay` on the first ~256 KB (instant) instead of scanning the
    /// whole fragmented file. Prewarmed → cached on Fly → instant.
    static func fstreamURL(youtubeID rawID: String) -> URL? {
        let id = rawID.hasPrefix("yt_") ? rawID : "yt_\(rawID)"
        guard var components = URLComponents(string: Config.flyBaseURL) else { return nil }
        components.path = "/fstream"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    static func urlIsIPBound(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "ip" }) ?? false
    }

    /// True if the URL points at an HLS manifest. Path extension or
    /// mime query param is `m3u8`. HLS manifests on googlevideo sign
    /// their segments individually, so IP-binding / long-track stall
    /// failure modes don't apply — this is the stable path for 20+
    /// min YouTube audio.
    static func urlIsHLS(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        let mime = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "mime" })?
            .value?
            .lowercased() ?? ""
        return mime.contains("mpegurl")
    }

    static func wrapInWorker(id: String, upstream: URL) -> URL? {
        guard var comps = URLComponents(string: "\(Config.audioWorkerURL)/stream/\(id)") else {
            return nil
        }
        comps.queryItems = [URLQueryItem(name: "src", value: upstream.absoluteString)]
        return comps.url
    }

    private func buildStreamURL(for song: Song) -> URL? {
        // Prefer explicitly-downloaded local file.
        if let local = song.localFileURL,
           let url = URL(string: local),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // Hot-cache hit: a previous play already mirrored the bytes to
        // Caches/hot/{id}.m4a, so we can hand AVPlayer a file URL and
        // skip the network entirely.
        if let hot = HotCacheManager.shared.localURL(for: song.youtubeID) {
            return hot
        }
        // Backend endpoint that 302s to the real CDN URL. Client follows
        // the redirect (resolveRedirect) to capture the final CDN URL,
        // then hands that direct CDN URL to AVPlayer — so audio bytes
        // never flow through the backend. Worker proxy removed: audio
        // must come from the source CDN for stability + low latency.
        guard var components = URLComponents(string: Config.backendBaseURL) else {
            return nil
        }
        let base = components.path
        components.path = base.hasSuffix("/") ? base + "stream" : base + "/stream"
        let quality = UserDefaults.standard.string(forKey: "audioQuality") ?? "320"
        components.queryItems = [
            URLQueryItem(name: "id", value: song.youtubeID),
            URLQueryItem(name: "q", value: quality),
        ]
        return components.url
    }

    // MARK: - Playback controls

    /// Flip the UI-only pending-play flag. Fires a 5s safety watchdog
    /// that clears the flag if `.playing` never arrives (resolver
    /// error, network stall). No audio effect.
    ///
    /// - `userInitiated`: gates the light impact haptic. Only true for
    ///   direct taps / remote-command plays, not auto-resume paths
    ///   (interruption .ended) — we don't want a phantom tick when
    ///   the app resumes itself after a call ends.
    ///
    /// Haptic fires only on the first flip of a pending window so a
    /// rapid double-tap during startup doesn't buzz twice.
    private func triggerPlayFeedback(userInitiated: Bool = true) {
        let firstFlip = !playPendingFeedback
        withAnimation(.easeOut(duration: 0.15)) {
            playPendingFeedback = true
        }
        // Delay ~15ms so the tap vibrates on the same render frame as
        // the animated icon swap + glow — a firing-immediately haptic
        // arrives ahead of the pixel update and feels fractionally
        // "early". The gating already happened above (firstFlip +
        // userInitiated), so the scheduled fire can't be duplicated
        // even if another tap lands inside this window.
        if userInitiated, firstFlip {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                Haptics.light()
            }
        }
        playFeedbackTimeout?.cancel()
        playFeedbackTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.playPendingFeedback, !self.isPlaying {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.playPendingFeedback = false
                }
            }
        }
    }

    private func clearPlayFeedback(animated: Bool = true) {
        playFeedbackTimeout?.cancel()
        playFeedbackTimeout = nil
        guard playPendingFeedback else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                playPendingFeedback = false
            }
        } else {
            playPendingFeedback = false
        }
    }

    func play(userInitiated: Bool = true) {
        triggerPlayFeedback(userInitiated: userInitiated)
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        // Mutual exclusion with Radio: if the user starts a song while
        // a station is live, stop the radio first so the two AVPlayers
        // don't mix. Radio listens for `.dhunifyStopAllAudio` and
        // tears itself down synchronously on the same run-loop tick.
        NotificationCenter.default.post(name: .dhunifyStopAllAudio, object: self)
        wantsToPlay = true
        cpdiag("play() ENTER")

        guard player.currentItem != nil else {
            // Avoid stacking a second loadCurrentSong on top of an
            // in-flight one. The KVO observer on item.status will
            // pick up `wantsToPlay` and start playback as soon as
            // the pending load reaches .readyToPlay.
            if isLoadingItem {
                cpdiag("play() EARLY-RETURN load-in-flight")
                Self.logger.info("▶️ play() — load already in flight, will auto-start on readyToPlay")
                return
            }
            loadCurrentSong()
            return
        }

        let status = player.currentItem?.status
        Self.logger.info("▶️ play() — itemStatus: \(status?.rawValue ?? -1), rate: \(self.player.rate)")

        if status == .readyToPlay {
            player.playImmediately(atRate: playbackSpeed)
            isPlaying = true
            updateNowPlayingPlaybackState()
        } else {
            // Item not ready yet — wantsToPlay flag will trigger play
            // when the KVO observer fires .readyToPlay.
            Self.logger.info("▶️ play() deferred — waiting for readyToPlay")
        }
    }

    func pause() {
        wantsToPlay = false
        clearPlayFeedback()
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    func togglePlayPause() {
        Haptics.play()
        isPlaying ? pause() : play()
    }

    /// Appends a song to the end of the queue without interrupting playback.
    func addToQueue(song: Song) {
        guard !queue.isEmpty else {
            setQueue([song], startIndex: 0)
            play()
            return
        }
        // Skip if already present to avoid accidental duplicates.
        guard !queue.contains(where: { $0.youtubeID == song.youtubeID }) else { return }
        queue.append(song)
        LastPlayedPersistence.saveQueue(queue, currentIndex: currentIndex)
    }

    /// Removes every queued song except the currently playing one.
    func clearQueueExceptCurrent() {
        guard let current = currentSong else {
            queue = []
            currentIndex = 0
            return
        }
        queue = [current]
        currentIndex = 0
        LastPlayedPersistence.saveQueue(queue, currentIndex: currentIndex)
    }

    /// Inserts a song right after the current track in the queue.
    func playNext(song: Song) {
        guard !queue.isEmpty else {
            setQueue([song], startIndex: 0)
            play()
            return
        }
        let insertAt = currentIndex + 1
        var q = queue
        // Remove duplicate if already in queue.
        q.removeAll { $0.youtubeID == song.youtubeID }
        let safeInsert = min(insertAt, q.count)
        q.insert(song, at: safeInsert)
        queue = q
    }

    /// Stops playback completely and clears the current item.
    func stop() {
        wantsToPlay = false
        clearPlayFeedback(animated: false)
        player.pause()
        player.replaceCurrentItem(with: nil)
        clearAllPreloadedItems()
        isPlaying = false
        currentTime = 0
        duration = 0
        progress = 0
        queue = []
        currentIndex = 0
        isLoadingItem = false
        loadingSongID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Lightweight hook for CarPlay disconnect. Clears only the load
    /// lock so a subsequent reconnect can't race a stale in-flight
    /// load. Leaves the player, current item, and audio session intact
    /// — playback continues on phone speaker / headphones exactly like
    /// Spotify / Apple Music.
    func resetForCarPlayDisconnect() {
        isLoadingItem = false
        loadingSongID = nil
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let clamped = max(0, min(progress, 1))
        let targetSeconds = duration * clamped
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        // Indefinite tolerance lets AVPlayer land on the nearest keyframe
        // instead of forcing a frame-accurate fetch. On progressive YT
        // URLs (and HLS chunks) this avoids an exact-byte range request
        // that would otherwise stall the buffer for multi-minute jumps.
        isSeeking = true
        player.seek(to: target, toleranceBefore: .indefinite, toleranceAfter: .indefinite) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = targetSeconds
                self.progress = clamped
                self.updateNowPlayingPlaybackState()
                // Long jumps can transition AVPlayer to `.paused` /
                // `.waitingToPlayAtSpecifiedRate` while it backfills.
                // The user expected playback to continue, so re-issue
                // the rate command if that's still their intent.
                if self.wantsToPlay, !self.isPlaying {
                    self.player.playImmediately(atRate: self.playbackSpeed)
                }
                self.isSeeking = false
                self.lastSeekFinishedAt = Date()
            }
        }
    }

    /// Jumps forward by `seconds`. Clamps to the track's duration so
    /// we don't seek past the end.
    func skipForward(seconds: Double = 15) {
        guard duration > 0 else { return }
        let target = max(0, min(currentTime + seconds, duration))
        seek(to: target / duration)
    }

    /// Jumps backward by `seconds`. Clamps to 0 so we don't seek to a
    /// negative time.
    func skipBackward(seconds: Double = 15) {
        guard duration > 0 else { return }
        let target = max(0, min(currentTime - seconds, duration))
        seek(to: target / duration)
    }

    // MARK: - Queue navigation

    func nextTrack() {
        cpdiag("nextTrack ENTER")
        Haptics.light()
        cancelCrossfade()
        guard !queue.isEmpty else { return }
        guard let target = nextIndex() else {
            // End of queue with repeat off. Instead of dead-ending
            // (which strands CarPlay users with silence), request a
            // refill and loop back to the first track so playback
            // continues uninterrupted.
            NotificationCenter.default.post(name: .dhunifyQueueNearEnd, object: self)
            currentIndex = isShuffled ? (shuffledIndices.first ?? 0) : 0
            loadCurrentSong()
            play()
            return
        }
        currentIndex = target
        loadCurrentSong()
        play()
        maybeSignalQueueNearEnd()
    }

    /// Appends `songs` (deduped by youtubeID) to the end of the current
    /// queue. Used by continuous-play surfaces like CarPlay that want to
    /// keep music going once the user reaches the tail of the queue.
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let existingIDs = Set(queue.map { $0.youtubeID })
        let unique = songs.filter { !existingIDs.contains($0.youtubeID) }
        guard !unique.isEmpty else { return }
        queue.append(contentsOf: unique)
        LastPlayedPersistence.saveQueue(queue, currentIndex: currentIndex)
    }

    /// Posts `.dhunifyQueueNearEnd` when ≤5 songs remain after the
    /// current one so observers (iPhone QueueRefillCoordinator + CarPlay)
    /// can silently top up the queue with similar tracks. Threshold is
    /// generous on purpose — `SimilarTrackProvider` is single-flight per
    /// anchor, so multiple near-end fires for the same song collapse to
    /// one fetch, and the bigger window absorbs rapid skipping without
    /// stranding the user at the tail.
    private func maybeSignalQueueNearEnd() {
        let remaining = queue.count - 1 - currentIndex
        guard remaining >= 0, remaining <= 5 else { return }
        NotificationCenter.default.post(name: .dhunifyQueueNearEnd, object: self)
    }

    func previousTrack() {
        Haptics.light()
        cancelCrossfade()
        guard !queue.isEmpty else { return }

        // Standard music-player behavior: past 3s, restart instead of
        // jumping to the previous track.
        if currentTime > 3 {
            seekToStart()
            return
        }

        guard let target = previousIndex() else {
            seekToStart()
            return
        }
        currentIndex = target
        loadCurrentSong()
        play()
    }

    private func seekToStart() {
        let zero = CMTime.zero
        player.seek(to: zero, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = 0
        progress = 0
        updateNowPlayingPlaybackState()
    }

    private func nextIndex() -> Int? {
        if isShuffled {
            guard let pos = shuffledIndices.firstIndex(of: currentIndex) else { return nil }
            let nextPos = pos + 1
            if nextPos < shuffledIndices.count { return shuffledIndices[nextPos] }
            return repeatMode == .all ? shuffledIndices.first : nil
        } else {
            let nextPos = currentIndex + 1
            if nextPos < queue.count { return nextPos }
            return repeatMode == .all ? 0 : nil
        }
    }

    private func previousIndex() -> Int? {
        if isShuffled {
            guard let pos = shuffledIndices.firstIndex(of: currentIndex) else { return nil }
            let prevPos = pos - 1
            if prevPos >= 0 { return shuffledIndices[prevPos] }
            return repeatMode == .all ? shuffledIndices.last : nil
        } else {
            let prevPos = currentIndex - 1
            if prevPos >= 0 { return prevPos }
            return repeatMode == .all ? queue.count - 1 : nil
        }
    }

    // MARK: - Shuffle / repeat

    func toggleShuffle() {
        Haptics.tick()
        isShuffled.toggle()
        if isShuffled {
            var indices = Array(queue.indices)
            indices.shuffle()
            if let pos = indices.firstIndex(of: currentIndex), pos != 0 {
                indices.swapAt(0, pos)
            }
            shuffledIndices = indices
        } else {
            shuffledIndices = []
        }
    }

    func toggleRepeat() {
        Haptics.tick()
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - End of track

    private func observeEndOfItem(_ item: AVPlayerItem) {
        if let previous = endOfItemObserver {
            NotificationCenter.default.removeObserver(previous)
            endOfItemObserver = nil
        }

        endOfItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }
    }

    private func handlePlaybackEnded() {
        // Guard against `AVPlayerItemDidPlayToEndTime` firing for
        // items that never actually played. When an item fails
        // (bad stream, expired CDN token, network drop) iOS can
        // still post an end-of-time notification, which would
        // otherwise chain nextTrack() → load → fail → end → next
        // and rip through the whole queue in seconds with no audio.
        let played = currentTime
        let total = duration
        let hasRealEnd = total > 0 && played >= max(total - 1.5, total * 0.9)
        guard hasRealEnd else {
            Self.logger.warning("🎵 Ignoring end-of-time (played=\(played)s of \(total)s) — item did not play through")
            // Surface a hint to the user and stop the auto-advance
            // loop. They can manually tap next / another song.
            playbackError = "Unable to play this track"
            isPlaying = false
            return
        }
        switch repeatMode {
        case .one:
            seekToStart()
            play()
        case .off, .all:
            nextTrack()
        }
    }

    // MARK: - Crossfade

    /// Called from the periodic time observer when the outgoing track is
    /// inside its last `crossfadeDuration` seconds. Loads the next song
    /// into the secondary player at volume 0, then linearly fades the
    /// two players over `crossfadeDuration` seconds before swapping the
    /// incoming item onto the primary player.
    private func startCrossfade() {
        guard crossfadeEnabled,
              !crossfadeActive,
              let nextIdx = nextIndex(),
              queue.indices.contains(nextIdx) else { return }

        let nextSong = queue[nextIdx]
        crossfadeActive = true

        crossfadeTask?.cancel()
        crossfadeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Resolve next-song URL — reuse prewarmed if present.
            let finalURL: URL
            if self.preloadedSongID == nextSong.youtubeID,
               let preloaded = self.preloadedURL {
                finalURL = preloaded
                self.preloadedURL = nil
                self.preloadedSongID = nil
            } else {
                guard let streamURL = self.buildStreamURL(for: nextSong) else {
                    self.crossfadeActive = false
                    return
                }
                if nextSong.isYouTubeSource {
                    // No /stream fallback — googlevideo URLs are IP-locked;
                    // proxying breaks playback. Abort crossfade on resolver
                    // failure instead of handing AVPlayer a broken URL.
                    guard let clientURL = try? await YouTubeStreamResolver.shared
                        .resolve(videoID: nextSong.youtubeID).url else {
                        self.crossfadeActive = false
                        return
                    }
                    finalURL = clientURL
                } else if let cached = ResolvedURLCache.shared.get(nextSong.youtubeID) {
                    finalURL = cached
                } else {
                    finalURL = await self.resolveRedirect(streamURL)
                }
            }

            guard self.crossfadeActive else { return }

            // Stream directly into the crossfade player — matches the
            // main load path so the two players stay behaviourally
            // identical.
            self.crossfadeLoader = nil
            let itemB = AVPlayerItem(url: finalURL)
            itemB.preferredForwardBufferDuration = preferredForwardBufferDurationForCurrentNetwork
            itemB.preferredPeakBitRate = preferredPeakBitRateForCurrentNetwork
            if !finalURL.isFileURL, nextSong.youtubeID.hasPrefix("jio_") {
                HotCacheManager.shared.cache(songID: nextSong.youtubeID, from: finalURL)
            }
            if let mix = await EQManager.shared.createAudioMix(for: itemB) {
                itemB.audioMix = mix
            }

            self.playerB.replaceCurrentItem(with: itemB)
            self.playerB.volume = 0
            self.playerB.play()

            // Linear volume ramp over crossfadeDuration seconds.
            let steps = 30
            let interval = self.crossfadeDuration / Double(steps)
            let v = self.volume

            for i in 0...steps {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled || !self.crossfadeActive { break }
                let p = Float(Double(i) / Double(steps))
                self.player.volume  = max(0, v * (1 - p))
                self.playerB.volume = min(v, v * p)
            }

            guard self.crossfadeActive else { return }

            // Swap: move playerB's item onto the primary player so the
            // rest of the app (time observer, now-playing, mini player)
            // keeps pointing at `self.player` without any rewiring.
            let incomingTime = self.playerB.currentTime()
            self.player.pause()

            // Tear down end-of-item observer for the outgoing item so a
            // stale notification can't fire against the new item.
            if let obs = self.endOfItemObserver {
                NotificationCenter.default.removeObserver(obs)
                self.endOfItemObserver = nil
            }

            if let incomingItem = self.playerB.currentItem,
               let incomingURL = (incomingItem.asset as? AVURLAsset)?.url {
                // iOS 26 forbids sharing AVPlayerItem across AVPlayer
                // instances. Build a fresh item from the resolved URL
                // and tear down playerB before the hand-off.
                let freshBuffer = incomingItem.preferredForwardBufferDuration
                let freshMix = incomingItem.audioMix

                self.playerB.replaceCurrentItem(with: nil)

                // The hand-off is a track change → new load generation, so
                // a later loadCurrentSong supersedes it and the status
                // observer below is gated like every other install path.
                self.loadToken &+= 1
                let loadGen = self.loadToken

                // Tear down the outgoing item's status observer BEFORE
                // detaching it (no stale callback during teardown).
                self.itemStatusObservation?.invalidate()
                self.itemStatusObservation = nil

                let freshItem = AVPlayerItem(url: incomingURL)
                freshItem.preferredForwardBufferDuration = freshBuffer
                freshItem.audioMix = freshMix

                let resumeTime = incomingTime
                self.isBuffering = true
                // Deferred playback: no rate-before-ready. The fresh item
                // is cold (does not inherit playerB's buffer), so start
                // only from .readyToPlay — accepts a small gap for a
                // correct, wedge-free swap. Guarded by generation+identity.
                self.itemStatusObservation = freshItem.observe(\.status, options: [.new, .initial]) { [weak self] pi, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.loadStillCurrent(loadGen, pi) else { return }
                        switch pi.status {
                        case .readyToPlay:
                            self.isBuffering = false
                            let d = pi.duration.seconds
                            if d.isFinite, d > 0 { self.duration = d }
                            if resumeTime.isValid, resumeTime.seconds > 0 {
                                self.player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                            }
                            if self.wantsToPlay {
                                self.player.playImmediately(atRate: self.playbackSpeed)
                                self.isPlaying = true
                                self.updateNowPlayingPlaybackState()
                            }
                        case .failed:
                            Self.logger.error("⚠️ crossfade item failed: \(pi.error?.localizedDescription ?? "unknown")")
                            self.isBuffering = false
                            self.isPlaying = false
                        default:
                            break
                        }
                    }
                }

                self.player.replaceCurrentItem(with: freshItem)
                self.player.volume = v
                self.observeEndOfItem(freshItem)
            } else {
                self.playerB.replaceCurrentItem(with: nil)
            }

            self.playerB.volume = 0

            // Advance logical queue state without running loadCurrentSong
            // (that would re-resolve the URL and re-create the item).
            self.currentIndex = nextIdx
            self.hasPreloadedNext = false
            self.hasPrefetchedNextL2 = false
            self.isPlaying = true
            self.setupNowPlaying()
            self.updateNowPlayingPlaybackState()
            LastPlayedPersistence.saveQueue(self.queue, currentIndex: self.currentIndex)
            self.maybeSignalQueueNearEnd()

            self.crossfadeActive = false
        }
    }

    /// Aborts any in-progress crossfade and restores the primary player
    /// to its nominal volume. Called on manual next/prev so the user
    /// doesn't hear a half-faded skip.
    private func cancelCrossfade() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        crossfadeActive = false
        playerB.pause()
        playerB.replaceCurrentItem(with: nil)
        playerB.volume = 0
        player.volume = volume
    }

    // MARK: - Now Playing

    private func setupNowPlaying() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPMediaItemPropertyPlaybackDuration] = duration > 0 ? duration : song.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        loadArtwork(for: song)

        // If an AirPlay output is already active when the song changes,
        // push title/artist into the new AVPlayerItem's externalMetadata
        // immediately so the receiver doesn't show a blank card while the
        // artwork download is in flight. Artwork gets patched in later
        // by `loadArtwork`.
        if isAirPlayRouteActive() {
            applyExternalMetadataForAirPlay()
        }
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for song: Song) {
        guard let url = URL(string: song.thumbnailURL) else { return }

        let taskID = UUID()
        artworkTaskID = taskID

        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else { return }
                await MainActor.run {
                    guard let self else { return }
                    // Discard stale artwork if the song changed mid-flight.
                    guard self.artworkTaskID == taskID else { return }
                    guard self.currentSong?.youtubeID == song.youtubeID else { return }

                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info

                    // Cache the loaded image for the AirPlay route
                    // handler. Only refresh externalMetadata when an
                    // AirPlay output is currently active — otherwise we
                    // leave the AVPlayerItem untouched.
                    self.lastArtworkImage = image
                    self.lastArtworkSongID = song.youtubeID
                    if self.isAirPlayRouteActive() {
                        self.applyExternalMetadataForAirPlay()
                    }
                }
            } catch {
                // Artwork is non-essential; a failed download just means
                // the lock screen shows the system default.
            }
        }
    }

    // MARK: - Remote commands

    /// Registers the player's remote-command handlers on
    /// `MPRemoteCommandCenter`. Exposed so RadioViewModel can restore
    /// song-queue semantics when radio playback stops.
    func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.play() }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.pause() }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Self.logger.info("🚗DIAG remote NEXT command fired")
            Task { @MainActor in self.nextTrack() }
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.previousTrack() }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let self,
                let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else {
                return .commandFailed
            }
            let requested = positionEvent.positionTime
            Task { @MainActor in
                guard self.duration > 0 else { return }
                self.seek(to: requested / self.duration)
            }
            return .success
        }

        // ±30s skip — wired for CarPlay, lock screen, and Siri
        // ("skip forward 30 seconds"). skipForward/skipBackward already
        // clamp to [0, duration] so over/underflow is impossible.
        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            Task { @MainActor in self.skipForward(seconds: interval) }
            return .success
        }

        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            Task { @MainActor in self.skipBackward(seconds: interval) }
            return .success
        }

        // Shuffle / repeat — required for CarPlay's dedicated
        // CPNowPlayingShuffleButton / CPNowPlayingRepeatButton to
        // forward taps. The buttons' own handlers also call
        // toggleShuffle / toggleRepeat directly, so these targets are
        // belt-and-braces for head units that route through
        // MPRemoteCommandCenter instead of the button closure.
        center.changeShuffleModeCommand.removeTarget(nil)
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let requested = (event as? MPChangeShuffleModeCommandEvent)?.shuffleType
            Task { @MainActor in
                let wantOn = (requested ?? (self.isShuffled ? .off : .items)) != .off
                if wantOn != self.isShuffled { self.toggleShuffle() }
            }
            return .success
        }

        center.changeRepeatModeCommand.removeTarget(nil)
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let requested = (event as? MPChangeRepeatModeCommandEvent)?.repeatType
            Task { @MainActor in
                let target: RepeatMode
                if let requested {
                    switch requested {
                    case .off: target = .off
                    case .one: target = .one
                    case .all: target = .all
                    @unknown default: target = .off
                    }
                } else {
                    switch self.repeatMode {
                    case .off: target = .all
                    case .all: target = .one
                    case .one: target = .off
                    }
                }
                while self.repeatMode != target { self.toggleRepeat() }
            }
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changeShuffleModeCommand.isEnabled = true
        center.changeRepeatModeCommand.isEnabled = true
    }

    // MARK: - Lyrics loading

    private func loadLyrics(for song: Song) {
        guard song.hasLyrics else {
            lyrics = ""
            lyricsLoading = false
            return
        }
        lyricsLoading = true
        lyrics = ""
        let lyricsId = song.lyricsId
        let youtubeID = song.youtubeID
        Task { @MainActor [weak self] in
            let fetched = (try? await JioSaavnLyricsClient.fetchLyrics(lyricsId: lyricsId)) ?? ""
            guard let self, self.currentSong?.youtubeID == youtubeID else { return }
            self.lyrics = fetched
            self.lyricsLoading = false
        }
    }
}
