//
//  QueueRefillCoordinator.swift
//  Dhunify
//
//  iPhone-side observer for `.dhunifyQueueNearEnd`. Mirrors what
//  `CarPlaySceneDelegate` already does for CarPlay — listens for the
//  near-end signal, asks `SimilarTrackProvider` for a fresh batch of
//  similar, language-filtered tracks, and appends them to the queue.
//
//  Held by `AppContainer` so it has app lifetime; self-contained so it
//  can be replaced with a smarter strategy (WATCH_NEXT, backend
//  recommend) later without touching PlayerViewModel.
//

import Foundation

@MainActor
final class QueueRefillCoordinator {

    private var observer: NSObjectProtocol?
    private var isRefilling = false

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .dhunifyQueueNearEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refill()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refill() async {
        guard !isRefilling else { return }
        isRefilling = true
        defer { isRefilling = false }

        let vm = AppContainer.shared.playerViewModel
        guard let current = vm.currentSong else { return }

        let existingIDs = Set(vm.queue.map { $0.youtubeID })
        let mood = vm.categorySeed
        let batch = await SimilarTrackProvider.shared.similarTracks(
            for: current,
            mood: mood,
            excludingIDs: existingIDs,
            batchSize: 20
        )
        guard !batch.isEmpty else { return }
        vm.appendToQueue(batch.shuffled())
    }
}
