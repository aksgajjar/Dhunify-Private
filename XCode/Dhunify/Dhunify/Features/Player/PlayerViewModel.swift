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
import MediaPlayer
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
    private var wantsToPlay: Bool = false
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
    /// One-shot guard so the recovery path can't loop if the fresh
    /// URL also stalls. Cleared on every new `loadCurrentSong`.
    @ObservationIgnored nonisolated(unsafe) private var stallRecoveryAttempted: Bool = false
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

    // MARK: - Init

    init(queue: [Song] = [], currentIndex: Int = 0) {
        self.queue = queue
        self.currentIndex = max(0, min(currentIndex, max(queue.count - 1, 0)))

        // Start playback as soon as AVPlayerItem reaches readyToPlay.
        // Default is `true`, which makes AVPlayer buffer extra data
        // before playing — adds 1-3s startup lag on long tracks.
        // Disabled here: AVPlayer still continues buffering while
        // playing, but doesn't delay first sample.
        player.automaticallyWaitsToMinimizeStalling = false
        playerB.automaticallyWaitsToMinimizeStalling = false
        preloaderPlayer.automaticallyWaitsToMinimizeStalling = false
        preloaderPlayer.volume = 0

        configureAudioSession()
        observeInterruptions()
        observeTimeControl()
        observeStopAllAudio()
        setupRemoteCommands()
        loadCurrentSong()
    }

    func setQueue(_ queue: [Song], startIndex: Int, categorySeed: String? = nil) {
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
                    self.isPlaying = true
                    self.clearPlayFeedback()
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
                    // Unexpected pause (user didn't tap pause) within
                    // the recovery window on an IP-bound URL = likely
                    // IP change. Recovery gate decides whether to act.
                    self.maybeTriggerStallRecovery(reason: "paused")
                case .waitingToPlayAtSpecifiedRate:
                    let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
                    Self.logger.info("⏯️ timeControlStatus → WAITING (\(reason))")
                    self.maybeTriggerStallRecovery(reason: "waiting:\(reason)")
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

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard
            let rawType = typeRaw,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

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

    // MARK: - Loading

    private func loadCurrentSong() {
        isLoadingCurrentSong = true
        // Stall-recovery window restarts with each new load. `playbackStartedAt`
        // gets set to the instant `.playing` first fires for this load.
        playbackStartedAt = nil
        stallRecoveryAttempted = false
        // IMMEDIATELY stop old audio — no gap.
        player.pause()
        player.volume = volume // reset from any crossfade
        player.replaceCurrentItem(with: nil)

        // Cancel any pending YT webm→mp4 fallback watchdog from a prior
        // load so it can't fire against the new song.
        ytFallbackWatchdog?.cancel()
        ytFallbackWatchdog = nil
        pendingYTFallbackURL = nil
        ytFallbackUsed = false

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
        // window after the index change. The matching slot (if any) for
        // the new current song is consumed below, so it's allowed to
        // survive this pass.
        evictStalePreloadedItems(keepSongID: targetID)

        // Tear down previous item observers.
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        // Drop the old end-of-item observer so a stale notification
        // from the previous item (e.g., fired during item teardown)
        // can't trigger handlePlaybackEnded and race the new load.
        if let observer = endOfItemObserver {
            NotificationCenter.default.removeObserver(observer)
            endOfItemObserver = nil
        }
        playbackError = nil

        guard let song = currentSong else {
            isPlaying = false
            currentTime = 0
            duration = 0
            progress = 0
            dominantColor = .appSurface
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
            return
        }

        // Reset preload state for this new song.
        hasPreloadedNext = false

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
            // Preloaded URLs are only honoured for non-YouTube tracks.
            // Rule: always resolve YouTube fresh at play time because
            // googlevideo URLs are IP + session-signed and go stale.
            if let preloaded = preloadedURL,
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
                        isLoadingCurrentSong = false
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
            // Stability guard: IP-bound googlevideo URLs carry an `ip=`
            // query param that locks them to the device's current egress
            // IP. The URL 403s the moment the IP shifts (Wi-Fi ↔ LTE
            // hand-off, VPN toggle, captive portal switch), which is a
            // real failure mode on tracks longer than ~15 minutes but a
            // non-issue on short tracks. Short tracks keep the fast
            // path. Long / unknown-duration tracks pay one extra round
            // trip for a stable URL. On failure we keep the original —
            // graceful degradation over hard stop.
            // Only re-resolve when BOTH:
            //   - duration is known AND > 1200s (≈20min+), and
            //   - the current URL is IP-bound (carries `ip=`).
            // Short tracks keep the fast path untouched. Unknown duration
            // (== 0) is treated as "could be short" → no extra round trip.
            if song.isYouTubeSource,
               Self.urlIsIPBound(finalURL) {
                let guardDuration = self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration
                if guardDuration > 1200 {
                    Self.logger.info("⚠️ IP-bound URL on long track dur=\(Int(guardDuration))s — attempting stable re-resolve")
                    do {
                        let stable = try await YouTubeStreamResolver.shared.resolveStable(videoID: song.youtubeID, expectedDuration: guardDuration)
                        finalURL = stable.url
                        pendingYTFallbackURL = stable.fallbackURL
                        if stable.duration > 0 { self.ytStreamDuration = stable.duration }
                        Self.logger.info("✅ stable URL replaced host=\(stable.url.host ?? "?")")
                    } catch {
                        Self.logger.info("⚠️ stable re-resolve failed, keeping IP-bound URL: \(error.localizedDescription)")
                    }
                }
            }

            // Hard block: long IP-bound streams are known to stall mid-
            // playback when the CDN rejects the bound IP. If we reach
            // this point still IP-bound on a long track, the stable
            // re-resolve above already failed — there is no recovery
            // path left. Fail fast instead of handing AVPlayer a URL
            // that will stick in buffering then pause.
            // HLS is exempt: segments are signed per-chunk so the IP
            // binding failure mode doesn't apply.
            let blockDuration = self.ytStreamDuration > 0 ? self.ytStreamDuration : song.duration
            if song.isYouTubeSource,
               !Self.urlIsHLS(finalURL),
               Self.urlIsIPBound(finalURL),
               blockDuration > 1200 {
                Self.logger.error("❌ BLOCKED: long IP-bound stream — not playable")
                self.playbackError = "This long track is not playable. Try another version."
                self.isLoadingCurrentSong = false
                self.isPlaying = false
                return
            }

            Self.logger.info("🎵 [3/5] Final URL: \(finalURL.host ?? "?") (\(finalURL.absoluteString.count) chars)")

            // Stream directly — AVPlayer handles progressive buffering.
            // The download-before-play experiment stalled on googlevideo
            // CDNs; streaming is the stable path that was working before.
            let playURL = finalURL

            // Resolver can take a beat on first play; if the user skipped
            // to another track while we were resolving, drop this result
            // so we don't race a newer loadCurrentSong's item install.
            guard self.currentSong?.youtubeID == song.youtubeID else {
                Self.logger.info("🎵 Song changed during resolve — aborting install for \(song.youtubeID)")
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
            // Safety: if the preloaded item reached .failed while
            // buffering (bad network, expired URL, 403), drop it and
            // fall through to a fresh `AVPlayerItem(url:)` build.
            let item: AVPlayerItem
            if let preItem = self.takePreloadedItem(songID: song.youtubeID, allowFailed: false) {
                item = preItem
                Self.logger.info("🔮 Installing preloaded AVPlayerItem (YT=\(song.isYouTubeSource), status=\(item.status.rawValue))")
            } else {
                if self.takePreloadedItem(songID: song.youtubeID, allowFailed: true) != nil {
                    Self.logger.info("🔮 Preloaded item was .failed — falling back to fresh load")
                }
                item = AVPlayerItem(url: playURL)
            }
            // Ask AVPlayer to buffer only a small amount ahead before
            // readyToPlay. Smaller forward buffer = faster first-
            // sample-out, fewer bytes before readyToPlay fires.
            // AVPlayer keeps refilling during playback so short stalls
            // self-heal. Long YT tracks drop to 1s to trim further;
            // low bitrate (48-128kbps) means 1s of audio is only
            // ~6-16KB and is plenty to transition into refill mode.
            let longYT = song.isYouTubeSource && warmupDuration > 1200
            item.preferredForwardBufferDuration = longYT ? 1 : 2
            Self.logger.info("🎵 [3b/5] AVPlayerItem URL scheme=\(playURL.scheme ?? "?") isFile=\(playURL.isFileURL) bufferSec=\(longYT ? 1 : 2)")

            // KVO: observe item.status to know when it's ready or failed.
            itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch playerItem.status {
                    case .readyToPlay:
                        let dur = playerItem.duration.seconds
                        Self.logger.info("🎵 [4/5] READY — duration: \(dur)s")
                        if dur.isFinite, dur > 0 {
                            self.duration = dur
                        }
                        self.isBuffering = false
                        self.isLoadingCurrentSong = false
                        // Auto-play when ready. playImmediately skips
                        // AVPlayer's buffer-fill heuristic — starts
                        // now even if only a small buffer is present.
                        if self.wantsToPlay {
                            Self.logger.info("🎵 [5/5] Auto-playing at \(self.playbackSpeed)x...")
                            self.player.playImmediately(atRate: self.playbackSpeed)
                            self.isPlaying = true
                            self.updateNowPlayingPlaybackState()
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
                        self.isLoadingCurrentSong = false
                        self.clearPlayFeedback(animated: false)
                    case .unknown:
                        Self.logger.info("🎵 Status: unknown (buffering...)")
                    @unknown default:
                        break
                    }
                }
            }

            // Apply EQ audio mix if configured.
            if let mix = await EQManager.shared.createAudioMix(for: item) {
                item.audioMix = mix
            }

            // Set the item on the player.
            player.replaceCurrentItem(with: item)
            player.volume = volume
            observeEndOfItem(item)
            installTimeObserver()

            // Kick playback immediately instead of waiting for the
            // KVO readyToPlay callback. Setting `player.rate` before
            // the item is ready is safe — AVPlayer latches the rate
            // and starts producing audio as soon as the first samples
            // arrive (automaticallyWaitsToMinimizeStalling=false above
            // keeps it from over-buffering first). Typically shaves
            // 1-3s off perceived startup latency. The KVO observer
            // still fires readyToPlay to clear isBuffering and is
            // idempotent w.r.t. the rate set here.
            if wantsToPlay {
                player.rate = playbackSpeed
                Self.logger.info("🎵 Eager play dispatched (status=\(item.status.rawValue))")
            }

            Self.logger.info("🎵 Item installed — rate: \(self.player.rate), wantsToPlay: \(self.wantsToPlay)")

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

    /// Stall-recovery gate. Called from time-control observers when
    /// the player drops out of `.playing` (to `.paused` or `.waiting`)
    /// unexpectedly. All conditions must pass or we no-op:
    ///   1. User still wants playback (guards against tap-pause).
    ///   2. Playback actually started for this load (else it's a
    ///      startup stall, handled elsewhere).
    ///   3. Within 30s of first `.playing` — the IP-change failure
    ///      window. Later stalls are usually cause-unknown and a
    ///      fresh URL won't help.
    ///   4. Current item URL carries `ip=` — the only case where a
    ///      fresh resolve is meaningful.
    ///   5. Not already attempted for this load — one shot per load.
    private func maybeTriggerStallRecovery(reason: String) {
        guard wantsToPlay,
              !stallRecoveryAttempted,
              let startedAt = playbackStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed < 30 else { return }
        guard let song = currentSong, song.isYouTubeSource else { return }
        guard let asset = player.currentItem?.asset as? AVURLAsset,
              Self.urlIsIPBound(asset.url) else { return }
        // Long-track-only: short tracks with IP-bound URLs don't usually
        // outlive the IP binding, so recovery churn isn't worth it.
        let stallDuration = ytStreamDuration > 0 ? ytStreamDuration : song.duration
        guard stallDuration > 1200 else { return }

        stallRecoveryAttempted = true
        let resumeAt = currentTime
        Self.logger.info("⚠️ stall \(reason) at \(Int(elapsed))s on IP-bound long-track — re-resolving stable")
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

    private func performStallRecovery(for song: Song, resumeAt: TimeInterval) {
        Task { @MainActor [weak self] in
            guard let self else { return }
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
            // User skipped during the re-resolve window → drop result.
            guard self.currentSong?.youtubeID == song.youtubeID else { return }
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
            item.preferredForwardBufferDuration = 2
            if let mix = await EQManager.shared.createAudioMix(for: item) {
                item.audioMix = mix
            }

            self.itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] pi, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch pi.status {
                    case .readyToPlay:
                        self.isBuffering = false
                        if resumeAt > 0 {
                            let t = CMTime(seconds: resumeAt, preferredTimescale: 600)
                            self.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        if self.wantsToPlay {
                            self.player.playImmediately(atRate: self.playbackSpeed)
                            self.isPlaying = true
                            self.updateNowPlayingPlaybackState()
                        }
                        // Playback stable on the replacement item — release
                        // the one-shot latch. The elapsed<30s window on
                        // `maybeTriggerStallRecovery` still prevents repeat
                        // firings, so this can't drive a loop.
                        Self.logger.info("✅ recovered long-track playback")
                        self.stallRecoveryAttempted = false
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

            self.player.replaceCurrentItem(with: item)
            self.observeEndOfItem(item)
            self.installTimeObserver()
            if self.wantsToPlay {
                self.player.rate = self.playbackSpeed
            }
        }
    }

    /// Replace current AVPlayerItem with the mp4 fallback URL. Tears
    /// down the existing status observer and wires a fresh one. Called
    /// from the status=.failed branch and the 3s watchdog. Marked used
    /// so it can't recurse.
    private func swapToYTFallback(url: URL, song: Song) {
        ytFallbackUsed = true
        pendingYTFallbackURL = nil
        ytFallbackWatchdog?.cancel()
        ytFallbackWatchdog = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch playerItem.status {
                case .readyToPlay:
                    let dur = playerItem.duration.seconds
                    Self.logger.info("🎵 [fallback] READY — duration: \(dur)s")
                    if dur.isFinite, dur > 0 { self.duration = dur }
                    self.isBuffering = false
                    self.isLoadingCurrentSong = false
                    if self.wantsToPlay {
                        self.player.playImmediately(atRate: self.playbackSpeed)
                        self.isPlaying = true
                        self.updateNowPlayingPlaybackState()
                    }
                case .failed:
                    let err = playerItem.error?.localizedDescription ?? "unknown"
                    Self.logger.error("🎵 [fallback] FAILED: \(err)")
                    self.playbackError = err
                    self.isBuffering = false
                    self.isPlaying = false
                    self.isLoadingCurrentSong = false
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        Task { @MainActor in
            if let mix = await EQManager.shared.createAudioMix(for: item) {
                item.audioMix = mix
            }
            self.player.replaceCurrentItem(with: item)
            self.observeEndOfItem(item)
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
    /// Guards against overlapping `loadCurrentSong` calls. Without this
    /// the sequence nextTrack() → loadCurrentSong() → play() spawns a
    /// second loadCurrentSong because `player.currentItem` is still
    /// nil when play() inspects it, producing duplicate stream
    /// resolves and a race between two AVPlayerItem installs.
    private var isLoadingCurrentSong = false

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
        currentTime = secs

        // Pick up duration if it wasn't known at load time.
        if duration <= 0, let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
        }

        progress = duration > 0 ? min(max(secs / duration, 0), 1) : 0
        updateNowPlayingPlaybackState()

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

    private func preloadNextSong() {
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
                    item.preferredForwardBufferDuration = 1
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
            item.preferredForwardBufferDuration = 2
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
            if preloaderPlayer.currentItem === slot.item {
                preloaderPlayer.replaceCurrentItem(with: nil)
            }
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

        guard player.currentItem != nil else {
            // Avoid stacking a second loadCurrentSong on top of an
            // in-flight one. The KVO observer on item.status will
            // pick up `wantsToPlay` and start playback as soon as
            // the pending load reaches .readyToPlay.
            if isLoadingCurrentSong {
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let clamped = max(0, min(progress, 1))
        let targetSeconds = duration * clamped
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = targetSeconds
                self.progress = clamped
                self.updateNowPlayingPlaybackState()
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

    /// Posts `.dhunifyQueueNearEnd` when ≤2 songs remain after the
    /// current one so observers (CarPlay) can silently refill the queue.
    private func maybeSignalQueueNearEnd() {
        let remaining = queue.count - 1 - currentIndex
        guard remaining >= 0, remaining <= 2 else { return }
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
            itemB.preferredForwardBufferDuration = 2
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

            if let incomingItem = self.playerB.currentItem {
                self.player.replaceCurrentItem(with: incomingItem)
                self.player.volume = v
                self.player.seek(to: incomingTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                self.player.rate = self.playbackSpeed
                self.observeEndOfItem(incomingItem)

                // Refresh duration for the new item so UI + progress work.
                let d = incomingItem.duration.seconds
                if d.isFinite, d > 0 { self.duration = d }
            }

            self.playerB.replaceCurrentItem(with: nil)
            self.playerB.volume = 0

            // Advance logical queue state without running loadCurrentSong
            // (that would re-resolve the URL and re-create the item).
            self.currentIndex = nextIdx
            self.hasPreloadedNext = false
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

        // Lock screen shows Next / Previous, not ±15s skip. Disable
        // skip commands so iOS renders the track-transport glyphs that
        // wire to nextTrackCommand / previousTrackCommand above.
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
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
