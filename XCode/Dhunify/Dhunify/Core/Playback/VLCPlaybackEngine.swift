//
//  VLCPlaybackEngine.swift
//  Dhunify
//
//  STAGE 2a — real VLC playback engine for the YouTube-progressive path.
//
//  AVPlayer can't sustain a fast start on YouTube's raw fragmented itag139
//  (it scans the whole moov before ready). VLC plays the IP-bound progressive
//  URL directly and is audible in ~1-2s. This engine owns a VLCMediaPlayer and
//  reports state/time/end back to PlayerViewModel via main-actor callbacks so
//  the existing UI bindings (currentTime / duration / progress / isPlaying /
//  now-playing) keep working unchanged.
//
//  Scope: YT progressive only. AVPlayer still owns file:// offline + HLS +
//  JioSaavn. Gated behind PlayerViewModel.vlcSmokeTest — flip false to fall
//  back to the AVPlayer faststart path.
//

import Foundation
import os
import VLCKitSPM

final class VLCPlaybackEngine: NSObject, VLCMediaPlayerDelegate {
    private let player = VLCMediaPlayer()
    private static let log = Logger(subsystem: "com.dhunify", category: "vlcengine")

    /// (currentSeconds, durationSeconds) — fired on every VLC time tick.
    var onTime: (@MainActor (Double, Double) -> Void)?
    /// VLC's `isPlaying` flipped — drives `isPlaying` + buffering UI.
    var onPlaying: (@MainActor (Bool) -> Void)?
    /// Track reached its natural end — caller advances the queue.
    var onEnded: (@MainActor () -> Void)?
    /// VLC hit a genuine playback error (bad/blocked URL, network
    /// failure, unsupported stream). Unlike AVPlayer, VLC has no
    /// `.failed` KVO the rest of PlayerViewModel already reacts to, so
    /// without this bridge a VLC-side failure was silent — no audio,
    /// no error, no fallback. Caller should route to a more resilient
    /// source (e.g. the backend proxy stream).
    var onError: (@MainActor () -> Void)?

    override init() {
        super.init()
        player.delegate = self
    }

    // MARK: - Transport

    // googlevideo validates the byte-fetch User-Agent against the
    // InnerTube client that resolved the URL. VLC's default UA
    // (`VLC/x.x LibVLC/x.x`) doesn't match, and the connection just
    // hangs (no VLC .error, no audio) until the caller's watchdog gives
    // up. Must match YouTubeStreamResolver's IOS client UA exactly.
    private static let googlevideoUserAgent =
        "com.google.ios.youtube/20.14.3 (iPhone16,2; U; CPU iOS 18_3_1 like Mac OS X)"

    func load(url: URL, autoplay: Bool, rate: Float, volume: Float) {
        player.stop()
        let media = VLCMedia(url: url)
        media.addOption(":http-user-agent=\(Self.googlevideoUserAgent)")
        player.media = media
        setVolume(volume)
        Self.log.info("🟣 VLC engine load \(url.host ?? "?", privacy: .public) autoplay=\(autoplay)")
        if autoplay { player.play() }
        if rate != 1.0 { player.rate = rate }
    }

    func play() { player.play() }

    func pause() { if player.canPause { player.pause() } }

    func stop() {
        player.stop()
        player.media = nil
    }

    func seek(toSeconds seconds: Double) {
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    func setRate(_ rate: Float) { player.rate = rate }

    /// Maps the app's 0...1 volume onto VLC's 0...100 (100 = original level).
    func setVolume(_ v: Float) {
        player.audio?.volume = Int32((max(0, min(v, 1)) * 100).rounded())
    }

    // MARK: - Readouts

    /// VLC's OWN view of whether audio is flowing. PlayerViewModel's
    /// `isPlaying` is optimistic (set the instant the user taps Play) and
    /// survives across loads, so it can't be used to detect a silent
    /// failure — this can.
    var isActuallyPlaying: Bool { player.isPlaying }

    /// Raw VLC state, for diagnostics on a failed/stalled load.
    var stateDescription: String {
        switch player.state {
        case .stopped: return "stopped"
        case .opening: return "opening"
        case .buffering: return "buffering"
        case .ended: return "ended"
        case .error: return "error"
        case .playing: return "playing"
        case .paused: return "paused"
        default: return "other(\(player.state.rawValue))"
        }
    }

    private var currentSeconds: Double { Double(player.time.intValue) / 1000.0 }

    private var durationSeconds: Double {
        let ms = player.media?.length.intValue ?? 0
        return ms > 0 ? Double(ms) / 1000.0 : 0
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let playing = player.isPlaying
        let ended = player.state == .ended
        let errored = player.state == .error
        Task { @MainActor in
            self.onPlaying?(playing)
            if ended { self.onEnded?() }
            if errored { self.onError?() }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let cur = currentSeconds
        let dur = durationSeconds
        Task { @MainActor in self.onTime?(cur, dur) }
    }
}
