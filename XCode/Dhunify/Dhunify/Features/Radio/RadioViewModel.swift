//
//  RadioViewModel.swift
//  Dhunify
//

import AVFoundation
import Foundation
import MediaPlayer
import UIKit
import os

private let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "Radio")

@MainActor
@Observable
final class RadioViewModel {

    /// Process-wide flag checked by non-Radio surfaces (e.g. the
    /// CarPlay playback watchdog) so they can avoid interfering with
    /// an active radio stream.
    nonisolated(unsafe) static var isAnyRadioPlaying: Bool = false

    let stations: [RadioStation] = RadioStation.all
    var currentStation: RadioStation? = nil
    var isPlaying: Bool = false
    var selectedCategory: RadioCategory = .hindi
    var statusMessage: String? = nil

    private let player = AVPlayer()
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var stopAllAudioObserver: NSObjectProtocol?
    private var connectionTimeoutTask: Task<Void, Never>?

    var filteredStations: [RadioStation] {
        stations.filter { $0.category == selectedCategory }
    }

    init() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = p.timeControlStatus == .playing
                if p.timeControlStatus == .playing {
                    self.statusMessage = nil
                }
            }
        }
        stopAllAudioObserver = NotificationCenter.default.addObserver(
            forName: .dhunifyStopAllAudio,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, note.object as AnyObject? !== self else { return }
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    func play(station: RadioStation) {
        // Toggle if tapping same station.
        if currentStation?.id == station.id, isPlaying {
            stop()
            return
        }

        // Directly silence the song player. The notification path
        // was unreliable in practice — observers fire on the next
        // run loop, so by the time PlayerViewModel.pause() ran our
        // AVPlayer was already producing sound, and the user heard
        // both streams overlapping. Calling pause() synchronously on
        // the same main-actor tick guarantees no overlap.
        AppContainer.shared.playerViewModel.pause()
        // Still post the notification for anyone else that observes
        // dhunifyStopAllAudio (e.g. future surfaces).
        NotificationCenter.default.post(name: .dhunifyStopAllAudio, object: self)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            logger.error("📻 Audio session: \(error.localizedDescription)")
        }

        guard let url = URL(string: station.streamURL) else {
            statusMessage = "Invalid station URL"
            return
        }
        logger.info("📻 Playing: \(station.name) — \(station.streamURL)")

        currentStation = station
        statusMessage = "Connecting..."
        let item = AVPlayerItem(url: url)

        // Observe item status for errors.
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch playerItem.status {
                case .failed:
                    let err = playerItem.error?.localizedDescription ?? "Stream error"
                    logger.warning("📻 Failed: \(err)")
                    self.connectionTimeoutTask?.cancel()
                    self.statusMessage = "Station unavailable, trying next..."
                    self.tryNextStation(in: station.category, after: station)
                case .readyToPlay:
                    logger.info("📻 Ready: \(station.name)")
                    self.connectionTimeoutTask?.cancel()
                    self.statusMessage = nil
                default:
                    break
                }
            }
        }

        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        Self.isAnyRadioPlaying = true

        // Hijack the transport commands so CarPlay / lock-screen next /
        // prev advance the radio station instead of triggering a song
        // queue jump (which would play two audio sources at once).
        setupRadioRemoteCommands()
        updateNowPlayingForRadio(station: station)

        // Guard against streams that silently hang (TCP open but no
        // bytes flowing). Without this the KVO never fires .failed
        // and the user sees "Connecting..." forever.
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.currentStation?.id == station.id,
                      self.statusMessage != nil else { return }
                logger.warning("📻 Timeout: \(station.name)")
                self.statusMessage = "Station unavailable, trying next..."
                self.tryNextStation(in: station.category, after: station)
            }
        }
    }

    func stop() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentStation = nil
        statusMessage = nil
        itemStatusObservation?.invalidate()
        Self.isAnyRadioPlaying = false

        // Wipe the Now Playing card that was showing the station. The
        // song player will rewrite its own info the next time it plays.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        // Restore song-queue semantics to the transport commands so
        // next / prev target the song player again.
        AppContainer.shared.playerViewModel.setupRemoteCommands()
    }

    /// Writes station metadata (name, category, artwork) into the
    /// shared MPNowPlayingInfoCenter so CarPlay / lock screen show the
    /// live station instead of the last played song.
    private func updateNowPlayingForRadio(station: RadioStation) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = station.name
        info[MPMediaItemPropertyArtist] = station.category.rawValue + " Radio"
        info[MPMediaItemPropertyAlbumTitle] = station.description
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0

        if let thumb = station.thumbnailURL, let url = URL(string: thumb) {
            Task { [weak self] in
                guard let data = try? await URLSession.shared.data(from: url).0,
                      let img = UIImage(data: data) else { return }
                await MainActor.run {
                    guard let self, self.currentStation?.id == station.id else { return }
                    let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    current[MPMediaItemPropertyArtwork] = art
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                }
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Station navigation (CarPlay transport → station)

    /// Advances to the next or previous station. Walks within the
    /// current category first, then hops to the next category at the
    /// end so `Next` from the last Hindi station lands on the first
    /// Gujarati station (and so on). Full catalog wraps around.
    func advanceStation(direction: Int) {
        guard let current = currentStation else { return }

        // Canonical ordering: group stations by category in the
        // RadioCategory.allCases order, concat them. This gives a
        // deterministic flat list that cycles across categories.
        let ordered = RadioCategory.allCases.flatMap { cat in
            stations.filter { $0.category == cat }
        }
        guard !ordered.isEmpty,
              let idx = ordered.firstIndex(where: { $0.id == current.id }) else {
            return
        }
        let count = ordered.count
        let nextIdx = ((idx + direction) % count + count) % count
        play(station: ordered[nextIdx])
    }

    private func setupRadioRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, let station = self.currentStation else { return }
                self.play(station: station)
            }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in self?.stop() }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPlaying {
                    self.stop()
                } else if let station = self.currentStation {
                    self.play(station: station)
                }
            }
            return .success
        }

        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in self?.advanceStation(direction: 1) }
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in self?.advanceStation(direction: -1) }
            return .success
        }

        // Radio streams are live — seek / skip intervals don't apply.
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
    }

    /// If a stream fails, auto-try the next station in the same category.
    private func tryNextStation(in category: RadioCategory, after failedStation: RadioStation) {
        let group = stations.filter { $0.category == category }
        guard let idx = group.firstIndex(where: { $0.id == failedStation.id }) else { return }
        let nextIdx = (idx + 1) % group.count
        let next = group[nextIdx]
        // Don't loop forever if all fail.
        if next.id == failedStation.id {
            statusMessage = "All stations unavailable"
            return
        }
        logger.info("📻 Auto-trying: \(next.name)")
        play(station: next)
    }
}
