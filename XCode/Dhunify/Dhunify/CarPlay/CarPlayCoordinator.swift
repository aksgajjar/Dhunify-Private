//
//  CarPlayCoordinator.swift
//  Dhunify
//
//  Owns the CarPlay template tree and wires list taps + search into the
//  shared PlayerViewModel. Template construction is synchronous so the
//  root can be installed on CPInterfaceController immediately on scene
//  connect (CarPlay shows a blank screen if the root is set late).
//
//  Data sources:
//   - Recently Played: RecentlyPlayedManager.shared (sync, UserDefaults)
//   - Favorites: SongStore.fetchLibrary (downloaded library, local
//     SwiftData — fast async, paints empty-state until first fetch lands)
//   - Search: SearchSongsUseCase via CPSearchTemplateDelegate, capped
//     to 12 results for driving safety
//
//  Playback is never touched directly — every tap goes through the
//  existing `setQueue` + `play` API on PlayerViewModel.
//

import AVFoundation
internal import CarPlay
import Foundation
import Observation
import os
import UIKit

private let coordinatorLogger = Logger(subsystem: "com.diphoria.Dhunify", category: "CarPlayCoord")

@MainActor
final class CarPlayCoordinator: NSObject {

    // MARK: - Dependencies

    private weak var interfaceController: CPInterfaceController?
    private let playerViewModel: PlayerViewModel
    private let songStore: any SongStore
    private let searchSongsUseCase: SearchSongsUseCase

    // MARK: - Templates

    private let recentsTemplate = CPListTemplate(title: "Recently Played", sections: [])
    private let favoritesTemplate = CPListTemplate(title: "Favorites", sections: [])
    private let searchTemplate = CPSearchTemplate()

    /// Root tab bar — constructed once and handed to
    /// `CPInterfaceController.setRootTemplate` exactly once.
    let rootTemplate: CPTabBarTemplate

    // MARK: - Async state

    private var libraryTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Cached search results indexed by CPListItem identity (via userInfo)
    /// so `selectedResult` can rebuild the queue for next/prev playback.
    private var lastSearchResults: [Song] = []

    // MARK: - Init

    init(interfaceController: CPInterfaceController, container: AppContainer) {
        self.interfaceController = interfaceController
        self.playerViewModel = container.playerViewModel
        self.songStore = container.songStore
        self.searchSongsUseCase = container.searchSongsUseCase

        recentsTemplate.tabTitle = "Recent"
        recentsTemplate.tabImage = UIImage(systemName: "clock.fill")
        recentsTemplate.emptyViewTitleVariants = ["No recent plays"]
        recentsTemplate.emptyViewSubtitleVariants = ["Play a song to see it here"]

        favoritesTemplate.tabTitle = "Favorites"
        favoritesTemplate.tabImage = UIImage(systemName: "heart.fill")
        favoritesTemplate.emptyViewTitleVariants = ["No favorites yet"]
        favoritesTemplate.emptyViewSubtitleVariants = ["Download songs on your phone to see them here"]

        searchTemplate.tabTitle = "Search"
        searchTemplate.tabImage = UIImage(systemName: "magnifyingglass")

        rootTemplate = CPTabBarTemplate(templates: [
            recentsTemplate,
            favoritesTemplate,
            searchTemplate,
        ])

        super.init()

        searchTemplate.delegate = self

        // Seed Recently Played synchronously so the tab shows content on
        // first render. CarPlay shows a blank pane if updateSections is
        // called during the tab's first layout pass.
        refreshRecents()
        observeRecents()

        // Library is fetched async (SwiftData) — paints empty-state
        // until the fetch returns, usually within a few dozen ms.
        refreshFavorites()
    }

    deinit {
        libraryTask?.cancel()
        searchTask?.cancel()
    }

    // MARK: - Recently Played

    /// Re-registers `withObservationTracking` after each change so the
    /// tab updates whenever a new song is added to RecentlyPlayedManager.
    private func observeRecents() {
        withObservationTracking {
            _ = RecentlyPlayedManager.shared.songs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshRecents()
                self?.observeRecents()
            }
        }
    }

    private func refreshRecents() {
        let songs = Array(RecentlyPlayedManager.shared.songs.prefix(20))
        let items = makeListItems(from: songs, seed: "Recently Played")
        recentsTemplate.updateSections([CPListSection(items: items)])
    }

    // MARK: - Favorites (downloaded library)

    private func refreshFavorites() {
        libraryTask?.cancel()
        libraryTask = Task { [weak self] in
            guard let self else { return }
            let songs = (try? await self.songStore.fetchLibrary()) ?? []
            guard !Task.isCancelled else { return }
            self.applyFavorites(songs)
        }
    }

    private func applyFavorites(_ songs: [Song]) {
        let items = makeListItems(from: songs, seed: "Favorites")
        favoritesTemplate.updateSections([CPListSection(items: items)])
    }

    // MARK: - Row construction

    /// Builds tap-to-play CPListItems. Each row installs the entire
    /// `songs` array as the queue so CarPlay next/prev steps through the
    /// list the user was looking at.
    private func makeListItems(from songs: [Song], seed: String) -> [CPListItem] {
        songs.enumerated().map { index, song in
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.handler = { [weak self] _, completion in
                self?.play(queue: songs, startIndex: index, seed: seed)
                completion()
            }
            return item
        }
    }

    // MARK: - Playback dispatch

    private func play(queue: [Song], startIndex: Int, seed: String) {
        coordinatorLogger.info("🚗 Play tap — seed=\(seed, privacy: .public) idx=\(startIndex) count=\(queue.count)")
        playerViewModel.setQueue(queue, startIndex: startIndex, categorySeed: seed)
        playerViewModel.play()
        pushNowPlaying()
    }

    /// Pushes `CPNowPlayingTemplate.shared` on top of whatever list the
    /// user tapped from. Guards against double-push if it's already top.
    func pushNowPlaying() {
        guard let controller = interfaceController else { return }
        if controller.topTemplate === CPNowPlayingTemplate.shared { return }
        controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, error in
            if let error {
                coordinatorLogger.error("🚗 pushTemplate failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - CPSearchTemplateDelegate

extension CarPlayCoordinator: CPSearchTemplateDelegate {

    /// Fires on every keystroke. Debounced 300ms to avoid spamming the
    /// backend, cancelled on each new keystroke so stale results never
    /// land in the list.
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            lastSearchResults = []
            completionHandler([])
            return
        }

        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }

            let songs = (try? await self.searchSongsUseCase.execute(query: trimmed)) ?? []
            guard !Task.isCancelled else { return }

            let capped = Array(songs.prefix(12))
            self.lastSearchResults = capped

            let items = capped.map { song -> CPListItem in
                let item = CPListItem(text: song.title, detailText: song.artist)
                item.userInfo = song
                return item
            }
            completionHandler(items)
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        guard let song = item.userInfo as? Song else {
            completionHandler()
            return
        }
        // Use the full capped result set as the queue so next/prev steps
        // through the search results, not a single-song queue.
        let startIndex = lastSearchResults.firstIndex(where: { $0.youtubeID == song.youtubeID }) ?? 0
        play(queue: lastSearchResults, startIndex: startIndex, seed: "Search")
        completionHandler()
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        // User tapped the on-screen search button. updatedSearchText has
        // already delivered the current results; nothing else to do.
    }

    func searchTemplateButtonPressed(_ searchTemplate: CPSearchTemplate) {
        // Fires when a search-trigger button is tapped inside a list
        // template. Not used — search is its own tab here.
    }
}
