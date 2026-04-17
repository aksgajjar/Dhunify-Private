//
//  CarPlaySceneDelegate.swift
//  Dhunify
//
//  Handles the CarPlay scene lifecycle. On connect, it wires the
//  shared CPNowPlayingTemplate as the root template and starts the
//  CarPlayNowPlayingUpdater so MPNowPlayingInfoCenter always reflects
//  the current PlayerViewModel state. Transport controls (play,
//  pause, next, previous, skip +/- 15s) are driven through
//  MPRemoteCommandCenter handlers the PlayerViewModel already
//  registers at launch.
//

import AVFoundation
internal import CarPlay
import Foundation
import os
import UIKit

private let carPlayLogger = Logger(subsystem: "com.diphoria.Dhunify", category: "CarPlay")

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var coordinator: CarPlayCoordinator?
    private var queueNearEndObserver: NSObjectProtocol?
    private var isRefillingQueue = false

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        let container = AppContainer.shared

        // Ensure the PlayerViewModel is alive (which registers remote
        // command handlers) and start mirroring its state into Now
        // Playing for CarPlay + lock-screen consumers.
        _ = container.playerViewModel
        container.startCarPlayUpdater()

        CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = false

        // Build the browse tree (Recently Played / Favorites / Search)
        // and set it as the root immediately. Coordinator init is sync —
        // no awaits — so CarPlay never sees a blank window.
        let coordinator = CarPlayCoordinator(
            interfaceController: interfaceController,
            container: container
        )
        self.coordinator = coordinator
        interfaceController.setRootTemplate(
            coordinator.rootTemplate,
            animated: false
        ) { _, _ in }

        observeQueueNearEnd()
        Task { [weak self] in
            await self?.startOrResumePlayback()
            // Push Now Playing on top of the tab bar once playback
            // actually starts so the driver lands on the scrubber UI,
            // not a browse list. They can pop back to browse anytime.
            if container.playerViewModel.isPlaying {
                self?.coordinator?.pushNowPlaying()
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        // Drop our reference — the remote command handlers and
        // PlayerViewModel stay alive on AppContainer.shared so music
        // keeps playing after CarPlay disconnects (e.g., engine off).
        self.interfaceController = nil
        self.coordinator = nil
        if let observer = queueNearEndObserver {
            NotificationCenter.default.removeObserver(observer)
            queueNearEndObserver = nil
        }
    }

    // MARK: - Auto-start flow

    /// Resumes the last queue if it was played within the last 24 hours,
    /// otherwise seeds a fresh queue of romantic hindi love songs and
    /// starts playback automatically.
    private func startOrResumePlayback() async {
        let vm = AppContainer.shared.playerViewModel

        // Already playing from a prior launch — don't interrupt.
        if vm.isPlaying, vm.currentSong != nil {
            carPlayLogger.info("🚗 Already playing — skip auto-start")
            return
        }

        // Re-activate audio session explicitly. On wireless CarPlay
        // cold-launch the session state can be stale; forcing a
        // re-activation ensures AVPlayer has an active route before we
        // ask it to play. Retry up to 3 times — the CarPlay route can
        // be mid-negotiation on the first tick and throw.
        await activateAudioSession()

        // Paused song already loaded in memory — just resume. Avoids
        // re-seeding the queue and losing the current position, which
        // matters on wireless CarPlay reconnects where the phone was
        // mid-session before the car radio came online.
        if !vm.isPlaying, vm.currentSong != nil {
            carPlayLogger.info("🚗 Resume paused song: \(vm.currentSong?.title ?? "?")")
            vm.play()
            startPlaybackWatchdog()
            return
        }

        // 1. Prefer the saved queue if it's still fresh (<24h old).
        if let saved = LastPlayedPersistence.loadQueueIfFresh() {
            carPlayLogger.info("🚗 Restoring saved queue (\(saved.queue.count) songs, idx=\(saved.index))")
            vm.setQueue(saved.queue, startIndex: saved.index)
            vm.play()
            startPlaybackWatchdog()
            return
        }

        // 2. Fall back to the single last-played song. This covers the
        //    case where only a `Song` was persisted (older app versions,
        //    or a session that never progressed past one track).
        if let lastSong = LastPlayedPersistence.load() {
            carPlayLogger.info("🚗 Restoring single last-played: \(lastSong.title)")
            vm.setQueue([lastSong], startIndex: 0)
            vm.play()
            startPlaybackWatchdog()
            // Kick the refill so CarPlay doesn't end up on a 1-song
            // queue with no way forward.
            NotificationCenter.default.post(name: .dhunifyQueueNearEnd, object: vm)
            return
        }

        // 3. Nothing persisted → seed a fresh queue.
        carPlayLogger.info("🚗 No saved state — seeding fresh queue")
        await seedRomanticQueue()
        startPlaybackWatchdog()
    }

    /// Tries to activate the shared AVAudioSession in `.playback` mode
    /// up to 3 times with a 1s gap. Wireless CarPlay routes can still
    /// be negotiating when the scene first connects, so a single attempt
    /// sometimes throws — letting the retry cover that window.
    private func activateAudioSession() async {
        for attempt in 1...3 {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true, options: [])
                carPlayLogger.info("🚗 Audio session ACTIVE on attempt \(attempt)")
                return
            } catch {
                carPlayLogger.error("🚗 Audio session activate attempt \(attempt) FAILED: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        carPlayLogger.error("🚗 Audio session activation exhausted retries — continuing anyway")
    }

    /// Polls for up to ~15s and retries `play()` if the player is still
    /// stalled. Wireless CarPlay cold-connect sometimes lands in a
    /// state where the item is buffered but rate stays at 0, and a
    /// second `play()` call is enough to wake it up.
    private func startPlaybackWatchdog() {
        Task { @MainActor in
            let vm = AppContainer.shared.playerViewModel
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // If the user started a radio station in the meantime,
                // stop prodding the song player — it would overlap the
                // live radio stream.
                if RadioViewModel.isAnyRadioPlaying {
                    carPlayLogger.info("🚗 Watchdog: radio owns audio, backing off")
                    return
                }
                guard vm.currentSong != nil else { return }
                if vm.isPlaying {
                    carPlayLogger.info("🚗 Playback confirmed (attempt \(attempt))")
                    return
                }
                carPlayLogger.warning("🚗 Still silent after \(attempt * 3)s — retry play()")
                vm.play()
            }
            carPlayLogger.error("🚗 Playback watchdog gave up")
        }
    }

    private func seedRomanticQueue() async {
        let useCase = AppContainer.shared.searchSongsUseCase
        // Retry up to 5 times. Wireless CarPlay often takes several
        // seconds before the phone's network stack is actually usable;
        // a single attempt on cold-launch frequently lost the race.
        for attempt in 1...5 {
            do {
                let songs = try await useCase.execute(query: "romantic hindi love songs")
                guard !songs.isEmpty else {
                    carPlayLogger.info("🚗 Seed attempt \(attempt): empty result")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                let shuffled = songs.shuffled()
                AppContainer.shared.playerViewModel.setQueue(
                    shuffled,
                    startIndex: 0,
                    categorySeed: "romantic hindi love songs"
                )
                AppContainer.shared.playerViewModel.play()
                carPlayLogger.info("🚗 Seeded queue (\(shuffled.count) songs) on attempt \(attempt)")
                return
            } catch {
                carPlayLogger.error("🚗 Seed attempt \(attempt) failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        carPlayLogger.error("🚗 Seed exhausted retries — trying offline library fallback")
        await seedFromOfflineLibrary()
    }

    /// Last-resort fallback: if every network seed attempt failed (car
    /// has no data connection yet), use the user's downloaded library
    /// so the car at least plays *something* on connect.
    private func seedFromOfflineLibrary() async {
        let store = AppContainer.shared.songStore
        guard let library = try? await store.fetchLibrary(),
              !library.isEmpty else {
            carPlayLogger.error("🚗 Offline library empty — nothing to play")
            return
        }
        let shuffled = library.shuffled()
        AppContainer.shared.playerViewModel.setQueue(
            shuffled,
            startIndex: 0,
            categorySeed: "offline library"
        )
        AppContainer.shared.playerViewModel.play()
        carPlayLogger.info("🚗 Seeded from offline library (\(shuffled.count) songs)")
    }

    // MARK: - Continuous play

    private func observeQueueNearEnd() {
        queueNearEndObserver = NotificationCenter.default.addObserver(
            forName: .dhunifyQueueNearEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refillQueue()
            }
        }
    }

    private func refillQueue() async {
        guard !isRefillingQueue else { return }
        isRefillingQueue = true
        defer { isRefillingQueue = false }

        let vm = AppContainer.shared.playerViewModel
        // Prefer the category the user started from (e.g. "Romantic
        // Hits"), falling back to the current song's artist so refill
        // stays in the same musical neighborhood. Generic trending
        // query is the last-resort fallback.
        let query: String
        if let seed = vm.categorySeed, !seed.isEmpty {
            query = seed
        } else if let artist = vm.currentSong?.artist, !artist.isEmpty {
            query = "\(artist) songs"
        } else {
            query = "hindi hits 2025"
        }

        let useCase = AppContainer.shared.searchSongsUseCase
        do {
            let songs = try await useCase.execute(query: query)
            guard !songs.isEmpty else { return }
            // Shuffle so continuous play feels random within the
            // category rather than playing a fixed top-N order.
            vm.appendToQueue(songs.shuffled())
        } catch {
            // Leave the queue as-is; the next song-end tick will retry.
        }
    }
}
