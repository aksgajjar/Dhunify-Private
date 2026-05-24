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
            let resumed = await self?.continueIfAlreadyPlaying() ?? false
            // Push Now Playing whenever we either kept an in-flight
            // session going or auto-resumed the last saved snapshot.
            // Browse tree stays on top only when nothing is playable.
            if resumed || container.playerViewModel.isPlaying {
                self?.coordinator?.pushNowPlaying()
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        carPlayLogger.info("🚗 didDisconnect — CarPlay scene torn down")
        let vm = AppContainer.shared.playerViewModel
        // Persist position + queue snapshot now so a later reconnect
        // (minutes or hours later, app may be killed in between) can
        // restore the exact track + offset. Periodic 5s save covers
        // the common case but a disconnect can land between ticks.
        if vm.currentTime > 1 {
            LastPlayedPersistence.savePosition(vm.currentTime)
        }
        if !vm.queue.isEmpty {
            LastPlayedPersistence.saveQueue(vm.queue, currentIndex: vm.currentIndex)
        }
        // Pause playback so the phone goes silent when the car is
        // unplugged. Position is already captured above; resume on
        // reconnect arms pendingResumeSeconds / direct seek().
        vm.pause()
        // Stability: clear the load lock so a reconnect can't race a
        // stale in-flight load/resolve.
        vm.resetForCarPlayDisconnect()
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

    /// Auto-resume the last saved track on CarPlay connect. Returns
    /// `true` if playback was (re)started so the caller can push the
    /// Now Playing template. Two branches:
    ///   A. Player still has `currentSong` (app stayed alive while
    ///      CarPlay was unplugged) — direct seek + play, the item is
    ///      already past `.readyToPlay` so pendingResumeSeconds KVO
    ///      won't refire.
    ///   B. Player is idle (app killed during the gap) — restore from
    ///      `LastPlayedPersistence.loadQueueIfFresh()` and arm
    ///      `pendingResumeSeconds` like the Home → Continue tile.
    /// Freshness cap (24h) is enforced by `loadQueueIfFresh`.
    @discardableResult
    private func continueIfAlreadyPlaying() async -> Bool {
        let vm = AppContainer.shared.playerViewModel
        let savedPos = LastPlayedPersistence.loadPosition()

        // Branch A — app alive, song still loaded.
        if let current = vm.currentSong {
            carPlayLogger.info("🚗 Reconnect — same song still loaded: \(current.title)")
            await activateAudioSession()

            // YouTube googlevideo URLs are IP-bound and expire (~6h).
            // Reusing the existing AVPlayerItem after a disconnect gap
            // replays a stale URL that 403s or stalls mid-playback —
            // worst on long (>1200s) tracks. Force a fresh resolve via
            // setQueue → loadCurrentSong (re-runs the resolver, prefers
            // the HLS manifest for >1200s) instead of seeking the stale
            // item. pendingResumeSeconds is consumed by the .readyToPlay
            // KVO on the fresh item to restore position.
            if current.isYouTubeSource {
                if savedPos > 3 {
                    vm.pendingResumeSeconds = savedPos
                    carPlayLogger.info("🚗 Reconnect → fresh YT resolve, arm resume @ \(Int(savedPos))s")
                }
                vm.setQueue(vm.queue, startIndex: vm.currentIndex, categorySeed: "CarPlayResume")
                vm.play()
                return true
            }

            // Non-YouTube (local/file) URLs are stable — the existing
            // item is safe to reuse; seek + play directly.
            if savedPos > 3, vm.duration > 0, savedPos < vm.duration - 5 {
                vm.seek(to: savedPos / vm.duration)
                carPlayLogger.info("🚗 Reconnect → seek to \(Int(savedPos))s")
            }
            vm.play()
            return true
        }

        // Branch B — app was killed during the gap. Restore from disk
        // if the snapshot is within the freshness window.
        guard let saved = LastPlayedPersistence.loadQueueIfFresh(),
              !saved.queue.isEmpty,
              saved.queue.indices.contains(saved.index) else {
            carPlayLogger.info("🚗 No fresh queue snapshot — waiting for user tap")
            return false
        }
        carPlayLogger.info("🚗 Reconnect — restoring queue from snapshot, song=\(saved.queue[saved.index].title)")
        await activateAudioSession()
        if savedPos > 3 {
            vm.pendingResumeSeconds = savedPos
            carPlayLogger.info("🚗 Reconnect → arm resume @ \(Int(savedPos))s")
        }
        vm.setQueue(saved.queue, startIndex: saved.index, categorySeed: "CarPlayResume")
        vm.play()
        return true
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
        guard let current = vm.currentSong else { return }

        // Delegate to the shared SimilarTrackProvider so CarPlay refill
        // and the iPhone QueueRefillCoordinator share one code path —
        // identical artist-anchored search + LanguagePreference filter
        // (90% Hindi / 10% Gujarati / 0% English) regardless of which
        // surface triggered the near-end signal.
        let existingIDs = Set(vm.queue.map { $0.youtubeID })
        let batch = await SimilarTrackProvider.shared.similarTracks(
            for: current,
            mood: vm.categorySeed,
            excludingIDs: existingIDs,
            batchSize: 20
        )
        guard !batch.isEmpty else { return }
        vm.appendToQueue(batch.shuffled())
    }
}
