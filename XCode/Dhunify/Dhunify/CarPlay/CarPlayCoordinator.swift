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
//   - Trending / Popular: HomeViewModel.sections[0] / [1] via the
//     container's shared instance — same cache the iPhone Home screen
//     uses, no duplicate API calls
//   - Playlists: PlaylistManager.shared (UserDefaults, per-profile)
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

/// In-memory thumbnail cache shared across every CPListItem. NSCache
/// handles eviction under memory pressure automatically. 100MB ceiling
/// keeps long drives from ballooning if the user scrolls deep feeds.
private let carPlayImageCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.totalCostLimit = 100 * 1024 * 1024
    return cache
}()

/// Fixed square used for every CarPlay thumbnail. 120pt matches
/// Apple's CarPlay HIG guidance for list-row artwork and guarantees
/// every row renders at the same visual weight.
private let carPlayArtworkSize = CGSize(width: 120, height: 120)

/// Static placeholder shown when a playlist has no cached thumbnail.
/// Generated once at launch — diagonal indigo→purple gradient with a
/// centered SF Symbol music note. Avoids bundling an image asset just
/// for this fallback.
private let carPlayPlaylistPlaceholder: UIImage = {
    let size = carPlayArtworkSize
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
        let colors = [
            UIColor.systemIndigo.cgColor,
            UIColor.systemPurple.cgColor
        ]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 1]
        ) {
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
        let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .semibold)
        if let icon = UIImage(systemName: "music.note", withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) {
            let rect = CGRect(
                x: (size.width - icon.size.width) / 2,
                y: (size.height - icon.size.height) / 2,
                width: icon.size.width,
                height: icon.size.height
            )
            icon.draw(in: rect)
        }
    }
}()

@MainActor
final class CarPlayCoordinator: NSObject {

    // MARK: - Dependencies

    private weak var interfaceController: CPInterfaceController?
    private let playerViewModel: PlayerViewModel
    private let homeViewModel: HomeViewModel
    private let container: AppContainer

    // MARK: - Templates

    /// "Home" — YT-Music-style sectioned list (Continue / Speed Dial /
    /// Quick Picks / Mood / Trending / Latest Hindi). First tab.
    private let homeTemplate = CPListTemplate(title: "Home", sections: [])
    /// "Last Played" — Resume row + Recently Played + Top Played.
    private let lastPlayedTemplate = CPListTemplate(title: "Last Played", sections: [])
    /// "Mashup" — 🔥 Bollywood Mashups list (moved out of Explore).
    private let mashupTemplate = CPListTemplate(title: "Mashup", sections: [])
    /// "Mood" — 6-tile static grid. No dynamic mood logic.
    private let moodTemplate = CPGridTemplate(title: "Mood", gridButtons: [])
    /// "Explore" — Continue Mashup Session row (when detected).
    /// Not in the tab bar; opened from Home grid.
    private let exploreTemplate = CPListTemplate(title: "Explore", sections: [])
    /// "Library" — user playlists (renamed from Playlists, logic unchanged).
    private let libraryTemplate = CPListTemplate(title: "Library", sections: [])
    /// "Downloads" — offline songs from DownloadManager. Tapped rows
    /// play directly from the local file URL (PlayerViewModel honours
    /// `Song.localFileURL` automatically — no new playback path).
    private let downloadsTemplate = CPListTemplate(title: "Downloads", sections: [])

    /// Root tab bar — constructed once and handed to
    /// `CPInterfaceController.setRootTemplate` exactly once.
    let rootTemplate: CPTabBarTemplate

    // MARK: - Async state

    private var homeLoadTask: Task<Void, Never>?
    /// One in-flight fetch per playlist id so rapid taps don't fan out.
    private var playlistSongTasks: [UUID: Task<Void, Never>] = [:]
    /// UserDefaults key for the most-recent search queries (strings).
    private static let recentSearchesKey = "dhunify.carplay.recentSearches"
    /// Max recent queries kept on disk.
    private static let recentSearchesLimit = 5
    /// Static tap-to-run queries shown in the Search template.
    /// CarPlay audio apps can't use CPSearchTemplate on iOS 26 (not in
    /// the allowed-push list for the audio entitlement), so we drop the
    /// keyboard entirely and surface a curated preset list instead.
    private static let suggestedSearchQueries: [String] = [
        "bollywood mashup 2025",
        "love mashup",
        "driving songs bollywood",
        "lofi chill hindi",
        "hanuman bhajan",
        "bollywood party songs",
    ]

    // MARK: - Init

    init(interfaceController: CPInterfaceController, container: AppContainer) {
        self.interfaceController = interfaceController
        self.playerViewModel = container.playerViewModel
        self.homeViewModel = container.homeViewModel
        self.container = container

        homeTemplate.tabTitle = "Home"
        homeTemplate.tabImage = UIImage(systemName: "house.fill")
        homeTemplate.emptyViewTitleVariants = ["Loading…"]

        lastPlayedTemplate.tabTitle = "Last Played"
        lastPlayedTemplate.tabImage = UIImage(systemName: "clock.arrow.circlepath")
        lastPlayedTemplate.emptyViewTitleVariants = ["Nothing yet"]
        lastPlayedTemplate.emptyViewSubtitleVariants = ["Play a song to see it here"]

        mashupTemplate.tabTitle = "Mashup"
        mashupTemplate.tabImage = UIImage(systemName: "waveform")
        mashupTemplate.emptyViewTitleVariants = ["Loading mashups…"]

        moodTemplate.tabTitle = "Mood"
        // Grid tiles are installed below via buildMoodGrid().

        // Explore is NOT in the tab bar anymore — opened from Home grid.
        exploreTemplate.tabTitle = "Explore"
        exploreTemplate.tabImage = UIImage(systemName: "sparkles")
        exploreTemplate.emptyViewTitleVariants = ["Nothing yet"]

        libraryTemplate.tabTitle = "Library"
        libraryTemplate.tabImage = UIImage(systemName: "music.note.list")
        libraryTemplate.emptyViewTitleVariants = ["No playlists"]
        libraryTemplate.emptyViewSubtitleVariants = ["Create a playlist on your phone to see it here"]

        downloadsTemplate.tabTitle = "Downloads"
        downloadsTemplate.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        downloadsTemplate.emptyViewTitleVariants = ["No downloads yet"]
        downloadsTemplate.emptyViewSubtitleVariants = ["Your downloaded content will appear here"]

        // Each list template gets a magnifying-glass nav-bar button that
        // pushes a CPListTemplate-based "Search" screen (Recent +
        // Suggested). CPSearchTemplate is not allowed on iOS 26 audio
        // apps — the system rejects it at pushTemplate with an
        // NSInvalidArgumentException, so we avoid it entirely.
        rootTemplate = CPTabBarTemplate(templates: [
            homeTemplate,
            lastPlayedTemplate,
            mashupTemplate,
            moodTemplate,
            libraryTemplate,
        ])

        super.init()

        // Wire the search button onto every tab so the driver can
        // invoke search from any context without backing out.
        let searchButton = CPBarButton(image: UIImage(systemName: "magnifyingglass") ?? UIImage()) { [weak self] _ in
            self?.presentSearch()
        }
        homeTemplate.trailingNavigationBarButtons = [searchButton]
        lastPlayedTemplate.trailingNavigationBarButtons = [searchButton]
        mashupTemplate.trailingNavigationBarButtons = [searchButton]
        moodTemplate.trailingNavigationBarButtons = [searchButton]
        exploreTemplate.trailingNavigationBarButtons = [searchButton]
        libraryTemplate.trailingNavigationBarButtons = [searchButton]
        downloadsTemplate.trailingNavigationBarButtons = [searchButton]

        // Mood — 6 static tiles. Built once; no dynamic logic.
        buildMoodGrid()

        // Last Played — Resume row + Recents + Top Played. Sync from UserDefaults.
        refreshLastPlayed()
        observeLastPlayed()

        // Explore — Continue Mashup Session row (when detected).
        refreshExplore()
        // Mashup tab — 🔥 Bollywood Mashups loaded from three parallel queries.
        refreshMashup()
        loadMashups()

        // Kick HomeViewModel.loadAll in the background too so other
        // surfaces stay warm; the existing disk cache serves iPhone
        // Home in the meantime.
        homeLoadTask = Task { [weak self] in
            await self?.homeViewModel.loadAll()
        }

        // Home — sectioned list, observation-driven.
        refreshHome()
        observeHome()

        // Library (was Playlists) — sync from UserDefaults via PlaylistManager.
        refreshPlaylists()
        observePlaylists()

        // Downloads — local files from DownloadManager.
        refreshDownloads()
        observeDownloads()
    }

    deinit {
        homeLoadTask?.cancel()
        for (_, task) in playlistSongTasks { task.cancel() }
    }

    // MARK: - Home tab

    /// Mirrors the Explore-tab Continue-Mashup-Session detection. Used
    /// by the Home grid to show an amber live-state dot on the Mashup
    /// tile when a session is active. Keeps state logic in one shape
    /// across surfaces.
    private func hasContinueMashupSession() -> Bool {
        let recents = RecentlyPlayedManager.shared.songs
        guard !recents.isEmpty else { return false }
        let mashupCount = recents.prefix(10).filter {
            $0.title.lowercased().contains("mashup")
        }.count
        guard mashupCount >= 2 else { return false }
        guard let hoursAgo = Self.lastPlayedHoursAgo(), hoursAgo < 24 else { return false }
        return true
    }

    /// Creates + pushes a fresh CPListTemplate mirroring a tab's content.
    /// Falls back to a placeholder row when the section set is empty so
    /// the driver always sees a valid screen.
    private func pushCloneList(
        title: String,
        sections: [CPListSection],
        emptyText: String,
        on controller: CPInterfaceController
    ) {
        let resolved: [CPListSection] = sections.isEmpty
            ? [CPListSection(items: [Self.placeholderItem(text: emptyText)])]
            : sections
        let clone = CPListTemplate(title: title, sections: resolved)
        clone.trailingNavigationBarButtons = [makeSearchButton()]
        controller.pushTemplate(clone, animated: true) { _, error in
            if let error {
                coordinatorLogger.error("🚗 Home→\(title) push failed: \(error.localizedDescription)")
            }
        }
    }

    /// Fires resume playback via the same LastPlayedPersistence path the
    /// Last Played tab's "Resume" row uses. No-op if nothing fresh is saved.
    private func continueFromResume() {
        guard let saved = LastPlayedPersistence.loadQueueIfFresh(),
              !saved.queue.isEmpty,
              saved.queue.indices.contains(saved.index) else {
            coordinatorLogger.info("🚗 Continue tap — no fresh queue")
            return
        }
        play(queue: saved.queue, startIndex: saved.index, seed: "Resume")
    }

    /// Fresh search-button factory — each template needs its own
    /// CPBarButton instance (CPBarButton isn't safely sharable across
    /// pushes on all iOS versions).
    private func makeSearchButton() -> CPBarButton {
        CPBarButton(image: UIImage(systemName: "magnifyingglass") ?? UIImage()) { [weak self] _ in
            self?.presentSearch()
        }
    }

    // MARK: - Home tab — YT-Music-style sectioned list

    /// Re-registers `withObservationTracking` so the Home tab refreshes
    /// whenever any of its data sources change.
    private func observeHome() {
        withObservationTracking {
            _ = RecentlyPlayedManager.shared.songs
            _ = PlaylistManager.shared.playlists
            _ = LibraryStore.shared.likedSongs
            _ = homeViewModel.sections
            _ = homeViewModel.latestHindi
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshHome()
                self?.observeHome()
            }
        }
    }

    private func refreshHome() {
        let sections = computeHomeSections()
        if sections.isEmpty {
            homeTemplate.updateSections([
                CPListSection(items: [
                    Self.placeholderItem(text: "Loading…")
                ])
            ])
        } else {
            homeTemplate.updateSections(sections)
        }
    }

    private func computeHomeSections() -> [CPListSection] {
        var sections: [CPListSection] = []

        // 1. Continue — single row when LastPlayedPersistence has a fresh queue.
        if let saved = LastPlayedPersistence.loadQueueIfFresh(),
           !saved.queue.isEmpty,
           saved.queue.indices.contains(saved.index) {
            let current = saved.queue[saved.index]
            let item = CPListItem(
                text: Self.cleanTitle(current.title),
                detailText: "Resume • \(current.artist)"
            )
            Self.loadImage(from: current.thumbnailURL, into: item)
            let queue = saved.queue
            let idx = saved.index
            item.handler = { [weak self] _, completion in
                self?.play(queue: queue, startIndex: idx, seed: "Resume")
                completion()
            }
            sections.append(CPListSection(items: [item], header: "Continue", sectionIndexTitle: nil))
        }

        // 2. Speed Dial — Liked tile + first 6 user playlists. Always shown.
        sections.append(CPListSection(
            items: speedDialItems(),
            header: "Speed Dial",
            sectionIndexTitle: nil
        ))

        // 3. Quick Picks — top 10 from RecentlyPlayed. Omitted if empty.
        let recents = RecentlyPlayedManager.shared.songs
        let quickPicks = Array(recents.prefix(10))
        if !quickPicks.isEmpty {
            sections.append(CPListSection(
                items: makeListItems(from: quickPicks, seed: "Home:QuickPicks"),
                header: "Quick picks",
                sectionIndexTitle: nil
            ))
        }

        // 4. Mood — static 6 tiles, always shown. Same dispatch as legacy Mood tab.
        sections.append(CPListSection(
            items: moodSectionItems(),
            header: "Mood",
            sectionIndexTitle: nil
        ))

        // 5. Trending now — first HomeViewModel section. Omitted while empty.
        if let trending = homeViewModel.sections.first, !trending.songs.isEmpty {
            let songs = Array(trending.songs.prefix(10))
            sections.append(CPListSection(
                items: makeListItems(from: songs, seed: "Home:Trending"),
                header: "Trending now",
                sectionIndexTitle: nil
            ))
        }

        // 6. Latest Hindi — also from HomeViewModel. Omitted while empty.
        let hindi = Array(homeViewModel.latestHindi.prefix(10))
        if !hindi.isEmpty {
            sections.append(CPListSection(
                items: makeListItems(from: hindi, seed: "Home:LatestHindi"),
                header: "Latest Hindi",
                sectionIndexTitle: nil
            ))
        }

        return sections
    }

    /// Speed Dial rows — Liked Songs virtual tile (always present) + the
    /// first 6 user playlists in `PlaylistManager.shared.currentPlaylists`
    /// order (matches Library tab order).
    private func speedDialItems() -> [CPListItem] {
        var items: [CPListItem] = []

        // Row 1 — Liked Songs.
        let likedCount = LibraryStore.shared.likedSongs.count
        let likedItem = CPListItem(
            text: "Liked Songs",
            detailText: "\(likedCount) \(likedCount == 1 ? "song" : "songs")"
        )
        likedItem.setImage(Self.likedTileImage())
        likedItem.handler = { [weak self] _, completion in
            self?.openLikedSongs()
            completion()
        }
        items.append(likedItem)

        // Rows 2…7 — first 6 playlists.
        let playlists = PlaylistManager.shared.currentPlaylists.prefix(6)
        for playlist in playlists {
            items.append(playlistListItem(playlist))
        }

        return items
    }

    /// Single-row builder shared by Speed Dial + Library tab so the row
    /// shape stays in lockstep across both surfaces.
    private func playlistListItem(_ playlist: UserPlaylist) -> CPListItem {
        let subtitle = Self.playlistSubtitle(playlist)
        let item = CPListItem(
            text: "\(playlist.emoji) \(playlist.name)",
            detailText: subtitle
        )
        item.setImage(carPlayPlaylistPlaceholder)
        if let firstID = playlist.songIDs.first,
           let cachedSong = RecentlyPlayedManager.shared.songs.first(where: { $0.youtubeID == firstID }) {
            Self.loadImage(from: cachedSong.thumbnailURL, into: item)
        }
        item.handler = { [weak self] _, completion in
            self?.openPlaylist(playlist)
            completion()
        }
        return item
    }

    /// Mood section rows — same titles + queries + symbols as the legacy
    /// `moodTiles` static. Each tap routes to the existing
    /// `playMoodTile(title:query:)` dispatch, identical to the old grid.
    private func moodSectionItems() -> [CPListItem] {
        Self.moodTiles.map { tile in
            let item = CPListItem(text: tile.title, detailText: nil)
            item.setImage(Self.moodTileImage(symbolName: tile.symbol))
            item.handler = { [weak self] _, completion in
                self?.playMoodTile(title: tile.title, query: tile.query)
                completion()
            }
            return item
        }
    }

    /// Pushes a CPListTemplate of the user's liked songs. Empty-state
    /// row guides them to the heart button on Now Playing.
    private func openLikedSongs() {
        guard let controller = interfaceController else { return }
        let liked = LibraryStore.shared.likedSongs
        let template: CPListTemplate
        if liked.isEmpty {
            template = CPListTemplate(
                title: "Liked Songs",
                sections: [CPListSection(items: [
                    Self.placeholderItem(text: "No liked songs yet — tap the heart on Now Playing to save")
                ])]
            )
        } else {
            let items = makeListItems(from: liked, seed: "LikedSongs")
            template = CPListTemplate(
                title: "Liked Songs",
                sections: [CPListSection(items: items)]
            )
        }
        template.trailingNavigationBarButtons = [makeSearchButton()]
        controller.pushTemplate(template, animated: true) { _, error in
            if let error {
                coordinatorLogger.error("🚗 openLikedSongs push failed: \(error.localizedDescription)")
            }
        }
    }

    /// Renders a 120pt pink-tinted heart over the same placeholder canvas
    /// playlists use, so the Liked tile reads at identical visual weight.
    private static func likedTileImage() -> UIImage {
        let size = carPlayArtworkSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Dark base (matches playlist placeholder visual weight).
            UIColor(red: 0.10, green: 0.05, blue: 0.12, alpha: 1).setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))
            let cfg = UIImage.SymbolConfiguration(pointSize: 60, weight: .semibold)
            if let icon = UIImage(systemName: "heart.fill", withConfiguration: cfg)?
                .withTintColor(.systemPink, renderingMode: .alwaysOriginal) {
                let rect = CGRect(
                    x: (size.width - icon.size.width) / 2,
                    y: (size.height - icon.size.height) / 2,
                    width: icon.size.width,
                    height: icon.size.height
                )
                icon.draw(in: rect)
            }
        }
    }

    // MARK: - Last Played tab

    /// UserDefaults key for the per-song play-count dictionary that
    /// powers the "Top Played" section. Lives here (not on a shared
    /// manager) so playback code stays untouched — we observe
    /// `RecentlyPlayedManager.songs` and bump the count whenever its
    /// head changes. Simple and self-contained.
    private static let topPlayedKey = "dhunify.carplay.topPlayedCounts"
    /// Last `songs[0].youtubeID` we observed. Used to detect the edge
    /// case where a fresh play prepends the same song twice in a row
    /// (iOS dedupes, so the ID doesn't flip — no increment needed).
    private var lastRecentHeadID: String?

    /// Re-registers `withObservationTracking` so the Last Played tab refreshes
    /// whenever a new song is added to RecentlyPlayedManager. Also bumps
    /// the play counter for the newly-prepended song.
    private func observeLastPlayed() {
        withObservationTracking {
            _ = RecentlyPlayedManager.shared.songs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.bumpTopPlayedIfNeeded()
                self?.refreshLastPlayed()
                self?.refreshExplore()
                // Home grid's live-state dots (Continue, Mashup)
                // depend on recents + lastPlayed freshness — rebuild
                // the grid so indicators stay accurate.
                self?.refreshHome()
                self?.observeLastPlayed()
            }
        }
    }

    /// Increment the top-played counter for the current head of Recents
    /// when it changes. Called from `observeLastPlayed` so playback never
    /// needs to know about this counter.
    private func bumpTopPlayedIfNeeded() {
        guard let head = RecentlyPlayedManager.shared.songs.first else { return }
        guard head.youtubeID != lastRecentHeadID else { return }
        lastRecentHeadID = head.youtubeID
        var counts = UserDefaults.standard
            .dictionary(forKey: Self.topPlayedKey) as? [String: Int] ?? [:]
        counts[head.youtubeID, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: Self.topPlayedKey)
    }

    private func refreshLastPlayed() {
        let sections = computeLastPlayedSections()
        if sections.isEmpty {
            lastPlayedTemplate.updateSections([
                CPListSection(items: [
                    Self.placeholderItem(text: "Play a song to see it here")
                ])
            ])
        } else {
            lastPlayedTemplate.updateSections(sections)
        }
    }

    /// Builds the Last Played tab sections fresh. Exposed so Home grid's
    /// Last Played shortcut can push a standalone clone — CarPlay templates
    /// can only live in one place, so shortcuts need their own instance.
    private func computeLastPlayedSections() -> [CPListSection] {
        var sections: [CPListSection] = []

        // Section 1 — Resume (only if within 24h of last play).
        if let saved = LastPlayedPersistence.loadQueueIfFresh(),
           !saved.queue.isEmpty,
           saved.queue.indices.contains(saved.index) {
            let current = saved.queue[saved.index]
            let item = CPListItem(
                text: "Resume",
                detailText: Self.cleanTitle(current.title)
            )
            Self.loadImage(from: current.thumbnailURL, into: item)
            let queue = saved.queue
            let idx = saved.index
            item.handler = { [weak self] _, completion in
                self?.play(queue: queue, startIndex: idx, seed: "Resume")
                completion()
            }
            sections.append(CPListSection(
                items: [item],
                header: "Resume last session",
                sectionIndexTitle: nil
            ))
        }

        // Section 2 — Recently played (no transformation).
        let recents = RecentlyPlayedManager.shared.songs
        let recentItems = makeListItems(from: recents, seed: "Recently Played")
        if !recentItems.isEmpty {
            sections.append(CPListSection(
                items: recentItems,
                header: "Recently played",
                sectionIndexTitle: nil
            ))
        }

        // Section 3 — Top played (by local counter, dedup against Recents
        // isn't applied — drivers WANT their top tracks visible even if
        // they were just played).
        let topItems = makeListItems(from: topPlayedSongs(), seed: "Top Played")
        if !topItems.isEmpty {
            sections.append(CPListSection(
                items: topItems,
                header: "Top played",
                sectionIndexTitle: nil
            ))
        }

        return sections
    }

    /// Resolves the top N most-played songs from the UserDefaults counter
    /// by matching IDs back to the Recents cache (only songs we still
    /// have metadata for can be rendered). Cheap — runs once per
    /// observation tick.
    private func topPlayedSongs(limit: Int = 10) -> [Song] {
        let counts = UserDefaults.standard
            .dictionary(forKey: Self.topPlayedKey) as? [String: Int] ?? [:]
        guard !counts.isEmpty else { return [] }
        let recents = RecentlyPlayedManager.shared.songs
        let byID = Dictionary(uniqueKeysWithValues: recents.map { ($0.youtubeID, $0) })
        let ranked = counts
            .sorted { $0.value > $1.value }
            .compactMap { byID[$0.key] }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Mood tab

    /// Static 6-tile definition. Query, title and SF Symbol picked once
    /// at compile time — no runtime switching, no engine, no calendar
    /// logic. Drivers get the same tiles every time they open the tab.
    private static let moodTiles: [(title: String, query: String, symbol: String)] = [
        ("Drive",      "bollywood driving songs",  "car.fill"),
        ("Chill",      "lofi chill hindi",         "cup.and.saucer.fill"),
        ("Devotional", "hanuman bhajan",           "sparkles"),
        ("Romantic",   "romantic bollywood songs", "heart.fill"),
        ("Party",      "bollywood party songs",    "party.popper.fill"),
        ("Throwback",  "90s bollywood hits",       "clock.arrow.circlepath"),
    ]

    /// Builds the CPGridTemplate buttons once. Tap handler fires a
    /// search + setQueue + play via the same path every other CarPlay
    /// tap uses — no new playback surface.
    private func buildMoodGrid() {
        moodTemplate.updateGridButtons(computeMoodButtons())
    }

    /// Exposed button builder — Home grid's "Mood" shortcut pushes a
    /// fresh CPGridTemplate clone using these buttons.
    private func computeMoodButtons() -> [CPGridButton] {
        Self.moodTiles.map { tile in
            let icon = Self.moodTileImage(symbolName: tile.symbol)
            return CPGridButton(
                titleVariants: [tile.title],
                image: icon
            ) { [weak self] _ in
                self?.playMoodTile(title: tile.title, query: tile.query)
            }
        }
    }

    /// Renders a 88pt SF Symbol onto a 120×120 tinted square so every
    /// mood tile has identical visual weight. CarPlay requires a non-
    /// optional UIImage here — a symbol-only image without a background
    /// sometimes clips on specific head units, so we draw into a fixed
    /// canvas.
    private static func moodTileImage(symbolName: String) -> UIImage {
        let size = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let config = UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
            guard let icon = UIImage(systemName: symbolName, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            let rect = CGRect(
                x: (size.width - icon.size.width) / 2,
                y: (size.height - icon.size.height) / 2,
                width: icon.size.width,
                height: icon.size.height
            )
            icon.draw(in: rect)
        }
    }

    /// Resolves the mood query via the shared search use-case and hands
    /// the result set to the player. Runs asynchronously so the grid
    /// tap itself never blocks — driver sees the Now Playing template
    /// push the moment results arrive.
    private func playMoodTile(title: String, query: String) {
        coordinatorLogger.info("🚗 Mood tap — \(title, privacy: .public) q=\(query, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            let useCase = AppContainer.shared.searchSongsUseCase
            do {
                let songs = try await useCase.execute(query: query)
                let capped = Array(songs.prefix(20))
                guard !capped.isEmpty else { return }
                self.play(queue: capped, startIndex: 0, seed: "Mood:\(title)")
            } catch {
                coordinatorLogger.error("🚗 Mood '\(title, privacy: .public)' fetch failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Explore tab

    /// Static 3-query set for Bollywood mashups. No new API — reuses the
    /// shared searchSongsUseCase. Queries picked to balance recency
    /// (2024/2025) against a thematic query ("love songs") so the merged
    /// pool has both fresh and evergreen picks.
    private static let exploreMashupQueries: [String] = [
        "bollywood mashup 2025",
        "bollywood mashup 2024",
        "bollywood mashup love songs",
    ]

    /// Last loaded Bollywood mashups (already dedup'd + ranked). Drives
    /// the first section of Explore. Empty until `loadExploreMashups`
    /// completes.
    private var loadedMashups: [Song] = []

    /// Rebuilds the Explore tab. Holds only the "Continue Mashup Session"
    /// row when detected — Bollywood Mashups now live in the Mashup tab.
    private func refreshExplore() {
        let sections = computeExploreSections()
        if sections.isEmpty {
            exploreTemplate.updateSections([
                CPListSection(items: [
                    Self.placeholderItem(text: "Nothing to resume yet")
                ])
            ])
        } else {
            exploreTemplate.updateSections(sections)
        }
    }

    /// Exposed section builder — Home grid's "Explore" shortcut pushes a
    /// clone built from this.
    private func computeExploreSections() -> [CPListSection] {
        var sections: [CPListSection] = []
        if let continueItem = continueMashupSessionItem() {
            sections.append(CPListSection(
                items: [continueItem],
                header: "Continue",
                sectionIndexTitle: nil
            ))
        }
        return sections
    }

    /// Rebuilds the Mashup tab from `loadedMashups`. Shows a placeholder
    /// until the first load completes.
    private func refreshMashup() {
        let sections = computeMashupSections()
        if sections.isEmpty {
            mashupTemplate.updateSections([
                CPListSection(items: [
                    Self.placeholderItem(text: "Loading mashups…")
                ])
            ])
        } else {
            mashupTemplate.updateSections(sections)
        }
    }

    /// Exposed section builder — Home grid's "Mashup" shortcut pushes a
    /// clone built from this.
    private func computeMashupSections() -> [CPListSection] {
        guard !loadedMashups.isEmpty else { return [] }
        let items = makeMashupListItems(from: loadedMashups)
        return [CPListSection(
            items: items,
            header: "🔥 Bollywood Mashups",
            sectionIndexTitle: nil
        )]
    }

    /// Fires all three mashup queries in parallel, merges in original
    /// order (preserves "latest-first" from YouTube search ordering),
    /// dedups by youtubeID, caps combined pool at 40, then picks:
    ///   - top 5 by viewCount desc (items with known viewCount)
    ///   - + top 5 latest from the combined-order pool (not already in)
    /// Final list is capped at 10.
    private func loadMashups() {
        Task { [weak self] in
            guard let self else { return }
            let useCase = AppContainer.shared.searchSongsUseCase
            let queries = Self.exploreMashupQueries

            var combined: [Song] = []
            await withTaskGroup(of: (Int, [Song]).self) { group in
                for (idx, q) in queries.enumerated() {
                    group.addTask {
                        do {
                            let r = try await useCase.execute(query: q)
                            return (idx, r)
                        } catch {
                            return (idx, [])
                        }
                    }
                }
                var bucket: [Int: [Song]] = [:]
                for await (idx, songs) in group { bucket[idx] = songs }
                for idx in 0..<queries.count {
                    combined.append(contentsOf: bucket[idx] ?? [])
                }
            }

            // Dedup by youtubeID, preserve original order, cap pool at 40.
            var seen = Set<String>()
            let pool = combined.filter { song in
                guard !seen.contains(song.youtubeID) else { return false }
                seen.insert(song.youtubeID)
                return true
            }.prefix(40)

            // Top 5 by views (items with known viewCount only).
            let byViews = pool
                .filter { ($0.viewCount ?? 0) > 0 }
                .sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
                .prefix(5)

            let viewsIDs = Set(byViews.map { $0.youtubeID })

            // Top 5 latest from pool order, excluding already-picked.
            let latest = pool
                .filter { !viewsIDs.contains($0.youtubeID) }
                .prefix(5)

            // Merge → dedup → cap 10.
            var merged: [Song] = []
            var mergedIDs = Set<String>()
            for s in byViews + latest where !mergedIDs.contains(s.youtubeID) {
                merged.append(s)
                mergedIDs.insert(s.youtubeID)
                if merged.count >= 10 { break }
            }

            let final = merged
            await MainActor.run {
                self.loadedMashups = final
                self.refreshMashup()
            }
        }
    }

    /// Builds CPListItems for the mashup section with the custom
    /// subtitle "Artist • 120M views • 1h 20m" (views dropped if
    /// unknown). Tap handler plays the mashup list starting at the
    /// tapped index via the same `play` dispatch as everywhere else.
    private func makeMashupListItems(from songs: [Song]) -> [CPListItem] {
        let seed = "Explore:Mashups"
        return songs.enumerated().map { index, song in
            let title = Self.cleanTitle(song.title)
            let subtitle = Self.rowSubtitle(song)
            let item = CPListItem(text: title, detailText: subtitle)
            Self.loadImage(from: song.thumbnailURL, into: item)
            item.handler = { [weak self] _, completion in
                self?.play(queue: songs, startIndex: index, seed: seed)
                completion()
            }
            return item
        }
    }

    /// "Artist • 120M views • 1h 20m" — drops the views segment when
    /// `viewCount` is nil/zero or the song is non-YT-source. Drops the
    /// duration segment when `duration <= 0`. Falls back to "Artist".
    /// Used by every CarPlay row builder so subtitles stay consistent
    /// across Home / Last Played / Mashup / Library / Downloads / Search.
    private static func rowSubtitle(_ song: Song) -> String {
        var parts: [String] = [song.artist]
        if song.isYouTubeSource, let v = song.viewCount, v > 0 {
            parts.append("\(formatViewCount(v)) views")
        }
        if song.duration > 0 {
            parts.append(formatDuration(song.duration))
        }
        return parts.joined(separator: " • ")
    }

    /// Shortens view counts to "1.2M" / "120M" / "1.5B" for compact
    /// CarPlay row display. Simple thresholds — no locale formatting.
    private static func formatViewCount(_ v: Int64) -> String {
        let d = Double(v)
        switch v {
        case 1_000_000_000...:
            return String(format: "%.1fB", d / 1_000_000_000)
        case 1_000_000...:
            let m = d / 1_000_000
            return m >= 100 ? "\(Int(m))M" : String(format: "%.1fM", m)
        case 1_000...:
            return String(format: "%.1fK", d / 1_000)
        default:
            return "\(v)"
        }
    }

    /// "4 min" / "1h 20m" — same shape as formatSubtitle for row parity.
    private static func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        if total >= 3600 {
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }
        return "\(max(1, total / 60)) min"
    }

    /// Builds the "▶ Continue Mashup Session" row if the user has been
    /// actively listening to mashups. Detection:
    ///   - Last 10 recents contain ≥2 titles with "mashup"
    ///   - Last play was within 24h (via LastPlayedPersistence freshness)
    /// Tap fires a fresh search + setQueue (never reuses old queue).
    private func continueMashupSessionItem() -> CPListItem? {
        let recents = RecentlyPlayedManager.shared.songs
        guard !recents.isEmpty else { return nil }
        let lastTen = recents.prefix(10)
        let mashupCount = lastTen.filter {
            $0.title.lowercased().contains("mashup")
        }.count
        guard mashupCount >= 2 else { return nil }

        guard let hoursAgo = Self.lastPlayedHoursAgo(), hoursAgo < 24 else {
            return nil
        }

        let subtitle = "Last played • \(hoursAgo <= 0 ? "just now" : "\(hoursAgo)h ago")"
        let icon = UIImage(systemName: "play.circle.fill")
        let item = CPListItem(
            text: "▶ Continue Mashup Session",
            detailText: subtitle,
            image: icon
        )
        item.handler = { [weak self] _, completion in
            self?.startMashupSession()
            completion()
        }
        return item
    }

    /// Reads the profile-scoped `lastPlayedAt` timestamp written by
    /// `LastPlayedPersistence.saveQueue` and returns whole-hours ago.
    /// Returns nil if nothing has been saved yet.
    private static func lastPlayedHoursAgo() -> Int? {
        let profileID = ProfileManager.shared.currentProfile?.id.uuidString ?? "default"
        let key = "dhunify.lastPlayed.\(profileID).lastPlayedAt"
        let ts = UserDefaults.standard.double(forKey: key)
        guard ts > 0 else { return nil }
        let delta = Date().timeIntervalSince1970 - ts
        guard delta >= 0 else { return 0 }
        return Int(delta / 3600)
    }

    /// Fetches a fresh "bollywood mashup 2025" queue and plays it.
    /// Does NOT reuse any existing queue — the user is starting a new
    /// session on the same theme.
    private func startMashupSession() {
        Task { [weak self] in
            guard let self else { return }
            let useCase = AppContainer.shared.searchSongsUseCase
            do {
                let songs = try await useCase.execute(query: "bollywood mashup 2025")
                let capped = Array(songs.prefix(20))
                guard !capped.isEmpty else { return }
                await MainActor.run {
                    self.play(queue: capped, startIndex: 0, seed: "MashupSession")
                }
            } catch {
                coordinatorLogger.error("🚗 Mashup session fetch failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Playlists

    /// Re-subscribe to PlaylistManager changes. Same pattern as recents.
    private func observePlaylists() {
        withObservationTracking {
            _ = PlaylistManager.shared.playlists
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshPlaylists()
                self?.observePlaylists()
            }
        }
    }

    private func refreshPlaylists() {
        let sections = computeLibrarySections()
        if sections.isEmpty {
            libraryTemplate.updateSections([
                CPListSection(items: [
                    Self.placeholderItem(text: "Create a playlist on your phone to see it here")
                ])
            ])
        } else {
            libraryTemplate.updateSections(sections)
        }
    }

    /// Exposed section builder — Home grid's "Library" shortcut pushes a
    /// clone built from this.
    private func computeLibrarySections() -> [CPListSection] {
        let lists = PlaylistManager.shared.currentPlaylists
        let items = lists.map { playlistListItem($0) }
        guard !items.isEmpty else { return [] }
        return [CPListSection(items: items)]
    }

    /// Pushes a CPListTemplate for the playlist and kicks off an async
    /// song fetch. Template appears immediately with an empty state; rows
    /// populate when songs resolve so the tap never blocks the driver.
    private func openPlaylist(_ playlist: UserPlaylist) {
        guard let controller = interfaceController else { return }
        let detailTemplate = CPListTemplate(title: playlist.name, sections: [])
        detailTemplate.emptyViewTitleVariants = ["Loading songs…"]
        controller.pushTemplate(detailTemplate, animated: true) { _, error in
            if let error {
                coordinatorLogger.error("🚗 pushPlaylist failed: \(error.localizedDescription)")
            }
        }
        fetchPlaylistSongs(playlist: playlist, into: detailTemplate)
    }

    private func fetchPlaylistSongs(playlist: UserPlaylist, into template: CPListTemplate) {
        playlistSongTasks[playlist.id]?.cancel()
        playlistSongTasks[playlist.id] = Task { [weak self] in
            guard let self else { return }
            let songs = await Self.loadSongs(for: playlist.songIDs)
            guard !Task.isCancelled else { return }
            let items = self.makeListItems(from: songs, seed: "Playlist:\(playlist.name)")
            template.updateSections([CPListSection(items: items)])
            if songs.isEmpty {
                template.emptyViewTitleVariants = ["No songs"]
                template.emptyViewSubtitleVariants = ["Add songs from your phone"]
            }
        }
    }

    /// Parallel /song/<id> fetch — same as PlaylistDetailView but we do
    /// it here so CarPlay stays standalone (no UI-layer coupling).
    private static func loadSongs(for ids: [String]) async -> [Song] {
        struct SongDTO: Decodable {
            let title: String; let artist: String; let thumbnailURL: String
            let youtubeID: String; let duration: TimeInterval
        }
        return await withTaskGroup(of: (Int, Song?).self) { group in
            for (idx, songID) in ids.enumerated() {
                group.addTask {
                    guard var components = URLComponents(string: Config.backendBaseURL) else { return (idx, nil) }
                    components.path = "/song/\(songID)"
                    guard let url = components.url else { return (idx, nil) }
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        let dto = try JSONDecoder().decode(SongDTO.self, from: data)
                        return (idx, Song(title: dto.title, artist: dto.artist, thumbnailURL: dto.thumbnailURL, youtubeID: dto.youtubeID, duration: dto.duration))
                    } catch {
                        return (idx, nil)
                    }
                }
            }
            var buf: [(Int, Song)] = []
            for await (idx, song) in group {
                if let song { buf.append((idx, song)) }
            }
            return buf.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: - Row construction

    /// Builds tap-to-play CPListItems with artwork + "artist • duration"
    /// subtitle. Dedupes by youtubeID and caps at 20 — CarPlay HIG
    /// favors glanceable lists over dense scroll. Each row installs the
    /// deduped/capped array as the queue so next/prev steps through
    /// exactly what the driver sees.
    private func makeListItems(from songs: [Song], seed: String) -> [CPListItem] {
        var seen = Set<String>()
        let deduped = songs.filter { song in
            guard !seen.contains(song.youtubeID) else { return false }
            seen.insert(song.youtubeID)
            return true
        }
        let capped = Array(deduped.prefix(20))
        return capped.enumerated().map { index, song in
            let cleanedTitle = Self.cleanTitle(song.title)
            let subtitle = Self.rowSubtitle(song)
            let item = CPListItem(text: cleanedTitle, detailText: subtitle)
            Self.loadImage(from: song.thumbnailURL, into: item)
            item.handler = { [weak self] _, completion in
                self?.play(queue: capped, startIndex: index, seed: seed)
                completion()
            }
            return item
        }
    }

    /// Playlist subtitle: "3 songs • 12 min" when we can resolve
    /// durations from RecentlyPlayed cache, otherwise just the count.
    /// No new API calls — only reads what's already in memory.
    private static func playlistSubtitle(_ playlist: UserPlaylist) -> String {
        let count = playlist.songCount
        let countStr = "\(count) \(count == 1 ? "song" : "songs")"
        let recents = RecentlyPlayedManager.shared.songs
        let resolved: [TimeInterval] = playlist.songIDs.compactMap { id in
            recents.first(where: { $0.youtubeID == id })?.duration
        }
        guard !resolved.isEmpty, resolved.count == playlist.songIDs.count else {
            return countStr
        }
        let total = Int(resolved.reduce(0, +))
        let durationStr: String
        if total >= 3600 {
            durationStr = "\(total / 3600)h \((total % 3600) / 60)m"
        } else {
            durationStr = "\(max(1, total / 60)) min"
        }
        return "\(countStr) • \(durationStr)"
    }

    /// Strips common YouTube padding ("(Official Video)", "[HD]", etc.)
    /// so rows show the actual song name rather than being clipped by
    /// CarPlay's truncation. Cheap regex pass — runs once per row at
    /// construction.
    private static func cleanTitle(_ title: String) -> String {
        let patterns = [
            #"\s*\(Official.*?\)"#,
            #"\s*\[Official.*?\]"#,
            #"\s*\(Lyric.*?\)"#,
            #"\s*\[Lyric.*?\]"#,
            #"\s*\(Full.*?Video\)"#,
            #"\s*\(Full.*?Song\)"#,
            #"\s*\|\s*Official.*"#,
            #"\s*\(HD\)"#,
            #"\s*\[HD\]"#,
            #"\s*\(4K\)"#,
            #"\s*\[4K\]"#,
            #"\s*\(Audio\)"#,
            #"\s*\[Audio\]"#
        ]
        var out = title
        for p in patterns {
            out = out.replacingOccurrences(
                of: p,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Resizes + center-crops an image to `carPlayArtworkSize` so every
    /// CPListItem renders at the same visual weight regardless of the
    /// source thumbnail's aspect ratio. Aspect-fill crop keeps the
    /// subject centered and prevents stretching. `nonisolated` so the
    /// detached thumbnail loader can call it without hopping back to
    /// the main actor.
    nonisolated private static func normalizeArtwork(_ image: UIImage) -> UIImage {
        let target = carPlayArtworkSize
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            let src = image.size
            guard src.width > 0, src.height > 0 else {
                image.draw(in: CGRect(origin: .zero, size: target))
                return
            }
            let scale = max(target.width / src.width, target.height / src.height)
            let w = src.width * scale
            let h = src.height * scale
            let x = (target.width - w) / 2
            let y = (target.height - h) / 2
            image.draw(in: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    /// Non-tappable placeholder row for empty sections. Keeps the list
    /// from showing a blank CarPlay pane — drivers get one line of
    /// guidance instead.
    private static func placeholderItem(text: String) -> CPListItem {
        let item = CPListItem(text: text, detailText: nil)
        item.isEnabled = false
        return item
    }

    /// Async thumbnail loader backed by `carPlayImageCache`. Returns
    /// immediately from cache if available; otherwise fires a detached
    /// download, normalizes to a fixed square (aspect-fill crop), and
    /// flips `item.setImage` on main when it arrives. No main-thread
    /// block, no new API surface — reuses the same thumbnail URL the
    /// Song model already carries.
    private static func loadImage(from urlString: String, into item: CPListItem) {
        let key = urlString as NSString
        if let cached = carPlayImageCache.object(forKey: key) {
            item.setImage(cached)
            return
        }
        guard let url = URL(string: urlString) else { return }
        Task.detached(priority: .utility) { [weak item] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let raw = UIImage(data: data) else { return }
            let normalized = normalizeArtwork(raw)
            let cost = Int(normalized.size.width * normalized.size.height * 4)
            carPlayImageCache.setObject(normalized, forKey: key, cost: cost)
            await MainActor.run {
                item?.setImage(normalized)
            }
        }
    }

    // MARK: - Playback dispatch

    private func play(queue: [Song], startIndex: Int, seed: String) {
        coordinatorLogger.info("🚗 Play tap — seed=\(seed, privacy: .public) idx=\(startIndex) count=\(queue.count)")
        playerViewModel.setQueue(queue, startIndex: startIndex, categorySeed: seed)
        playerViewModel.play()
        pushNowPlaying()
    }

    /// Pushes a CPListTemplate-based Search screen with two sections:
    ///   1. Recent (up to 5 saved queries, tap-to-run)
    ///   2. Suggested (static curated queries, tap-to-run)
    /// No text input — iOS 26 audio apps can't push CPSearchTemplate,
    /// so the driver picks from the list instead.
    private func presentSearch() {
        guard let controller = interfaceController else { return }
        let template = CPListTemplate(
            title: "Search",
            sections: buildSearchSections()
        )
        controller.pushTemplate(template, animated: true) { _, error in
            if let error {
                coordinatorLogger.error("🚗 presentSearch push failed: \(error.localizedDescription)")
            }
        }
    }

    /// Assembles the Recent + Suggested sections for the Search screen.
    /// Recent is omitted when the user has no prior queries.
    private func buildSearchSections() -> [CPListSection] {
        var sections: [CPListSection] = []
        let recents = recentSearchItems()
        if !recents.isEmpty {
            sections.append(CPListSection(
                items: recents,
                header: "Recent",
                sectionIndexTitle: nil
            ))
        }
        sections.append(CPListSection(
            items: suggestedSearchItems(),
            header: "Suggested",
            sectionIndexTitle: nil
        ))
        return sections
    }

    /// Rows for the static suggested-query list. Tap runs the query via
    /// the same path as a recent-search tap.
    private func suggestedSearchItems() -> [CPListItem] {
        let icon = UIImage(systemName: "magnifyingglass")
        return Self.suggestedSearchQueries.map { query in
            let item = CPListItem(text: query, detailText: nil, image: icon)
            item.handler = { [weak self] _, completion in
                self?.runRecentSearch(query: query)
                completion()
            }
            return item
        }
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

    // MARK: - Recent searches

    /// Loads up to `recentSearchesLimit` prior queries from UserDefaults.
    private func loadRecentSearches() -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? []
        return Array(stored.prefix(Self.recentSearchesLimit))
    }

    /// Prepends `query` to recents (dedup case-insensitive) and caps at limit.
    private func saveRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = loadRecentSearches()
        list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > Self.recentSearchesLimit {
            list = Array(list.prefix(Self.recentSearchesLimit))
        }
        UserDefaults.standard.set(list, forKey: Self.recentSearchesKey)
    }

    /// Builds CPListItems for the Recent section in the Search screen.
    /// Tapping a row runs that query and pushes a new CPListTemplate
    /// with results.
    private func recentSearchItems() -> [CPListItem] {
        let recents = loadRecentSearches()
        guard !recents.isEmpty else { return [] }
        let icon = UIImage(systemName: "clock.arrow.circlepath")
        return recents.map { query in
            let item = CPListItem(text: query, detailText: nil, image: icon)
            item.handler = { [weak self] _, completion in
                self?.runRecentSearch(query: query)
                completion()
            }
            return item
        }
    }

    /// Runs `query` through the search use-case, saves it to recents,
    /// and pushes a results CPListTemplate on top of the Search screen.
    /// Shared by both Recent and Suggested row taps.
    private func runRecentSearch(query: String) {
        Task { [weak self] in
            guard let self else { return }
            let useCase = AppContainer.shared.searchSongsUseCase
            do {
                let songs = try await useCase.execute(query: query)
                await MainActor.run {
                    let top = Array(songs.prefix(15))
                    guard !top.isEmpty else { return }
                    self.saveRecentSearch(query)
                    let items = self.makeListItems(from: top, seed: "Search:\(query)")
                    let template = CPListTemplate(
                        title: query,
                        sections: [CPListSection(items: items)]
                    )
                    self.interfaceController?.pushTemplate(template, animated: true) { _, error in
                        if let error {
                            coordinatorLogger.error("🚗 recent-search push failed: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                coordinatorLogger.error("🚗 recent-search failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Downloads tab

    /// Re-registers `withObservationTracking` so the Downloads tab refreshes
    /// whenever `DownloadManager.downloadedVersion` bumps (after any
    /// insert or delete). Counter pattern — observers re-call
    /// `fetchDownloaded()` on change.
    private func observeDownloads() {
        withObservationTracking {
            _ = container.downloadManager.downloadedVersion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDownloads()
                self?.observeDownloads()
            }
        }
    }

    private func refreshDownloads() {
        let sections = computeDownloadsSections()
        if sections.isEmpty {
            downloadsTemplate.updateSections([
                CPListSection(items: [
                    Self.placeholderItem(text: "Your downloaded content will appear here")
                ])
            ])
        } else {
            downloadsTemplate.updateSections(sections)
        }
    }

    private func computeDownloadsSections() -> [CPListSection] {
        let downloaded = container.downloadManager.fetchDownloaded()
        guard !downloaded.isEmpty else { return [] }
        let songs = downloaded.map { $0.toSong() }
        let items = makeListItems(from: songs, seed: "Downloads")
        return [CPListSection(
            items: items,
            header: "Downloaded (\(songs.count))",
            sectionIndexTitle: nil
        )]
    }
}

