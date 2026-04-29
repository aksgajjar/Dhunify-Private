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
        carPlayLogger.info("🚗 didConnect fired — CarPlay tap reached scene delegate")
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
        carPlayLogger.info("🚗 Coordinator built — setting root template")
        interfaceController.setRootTemplate(
            coordinator.rootTemplate,
            animated: false
        ) { success, error in
            if let error {
                carPlayLogger.error("🚗 setRootTemplate FAILED: \(error.localizedDescription)")
            } else {
                carPlayLogger.info("🚗 Root template set success=\(success)")
            }
        }

        observeQueueNearEnd()
        Task { [weak self] in
            await self?.continueIfAlreadyPlaying()
            // Push Now Playing on top of the browse tree only when the
            // player is actually playing on connect. If the phone was
            // idle, keep the driver on the browse list so nothing
            // starts without explicit user input.
            if container.playerViewModel.isPlaying {
                self?.coordinator?.pushNowPlaying()
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        carPlayLogger.info("🚗 didDisconnect — CarPlay scene torn down")
        // Stability: force-detach any in-flight AVPlayerItem and clear
        // the load lock so a reconnect can't race a stale load/resolve.
        AppContainer.shared.playerViewModel.resetForCarPlayDisconnect()
        // Drop our reference — the remote command handlers and
        // PlayerViewModel stay alive on AppContainer.shared.
        self.interfaceController = nil
        self.coordinator = nil
        if let observer = queueNearEndObserver {
            NotificationCenter.default.removeObserver(observer)
            queueNearEndObserver = nil
        }
    }

    // MARK: - Connect flow

    /// No auto-start on CarPlay connect. If the phone is already
    /// playing when the car powers up, keep playing (and re-activate
    /// the audio session so the route survives). Otherwise leave the
    /// player idle and let the driver tap a song in the browse tree.
    private func continueIfAlreadyPlaying() async {
        let vm = AppContainer.shared.playerViewModel

        guard vm.isPlaying, vm.currentSong != nil else {
            carPlayLogger.info("🚗 Idle on connect — waiting for user tap")
            return
        }

        carPlayLogger.info("🚗 Already playing — continuing \(vm.currentSong?.title ?? "?")")
        // Re-activate audio session so wireless CarPlay route takes
        // over cleanly. Playback itself is already live; we just make
        // sure the route negotiation doesn't silently drop it.
        await activateAudioSession()
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
        // Prefer the category the user started from (e.g. a Hindi
        // section's underlying query), falling back to the current
        // song's artist so refill stays in the same musical
        // neighborhood. All refill queries are forced to include the
        // word "hindi" — the user listens exclusively to Hindi songs
        // and YT search on a non-language-tagged seed routinely returns
        // mixed-language results.
        let rawQuery: String
        if let seed = vm.categorySeed, !seed.isEmpty {
            rawQuery = seed
        } else if let artist = vm.currentSong?.artist, !artist.isEmpty {
            rawQuery = "\(artist) hindi songs"
        } else {
            rawQuery = "latest hindi songs"
        }
        // Ensure "hindi" is present somewhere in the query — appending
        // it is a no-op when the seed already mentions the language.
        let query: String = rawQuery.lowercased().contains("hindi")
            ? rawQuery
            : "\(rawQuery) hindi"

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
