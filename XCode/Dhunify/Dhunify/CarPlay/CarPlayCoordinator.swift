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

    // MARK: - Templates

    /// "Home" — top-level 6-tile grid with shortcut buttons. First tab.
    private let homeTemplate = CPGridTemplate(title: "Home", gridButtons: [])
    /// "Drive" — Resume row + Recently Played + Top Played.
    private let driveTemplate = CPListTemplate(title: "Drive", sections: [])
    /// "Mashup" — 🔥 Bollywood Mashups list (moved out of Explore).
    private let mashupTemplate = CPListTemplate(title: "Mashup", sections: [])
    /// "Mood" — 6-tile static grid. No dynamic mood logic.
    private let moodTemplate = CPGridTemplate(title: "Mood", gridButtons: [])
    /// "Explore" — Continue Mashup Session row (when detected).
    /// Not in the tab bar; opened from Home grid.
    private let exploreTemplate = CPListTemplate(title: "Explore", sections: [])
    /// "Library" — user playlists (renamed from Playlists, logic unchanged).
    private let libraryTemplate = CPListTemplate(title: "Library", sections: [])

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

        homeTemplate.tabTitle = "Home"
        homeTemplate.tabImage = UIImage(systemName: "house.fill")

        driveTemplate.tabTitle = "Drive"
        driveTemplate.tabImage = UIImage(systemName: "car.fill")
        driveTemplate.emptyViewTitleVariants = ["Nothing yet"]
        driveTemplate.emptyViewSubtitleVariants = ["Play a song to see it here"]

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

        // Each list template gets a magnifying-glass nav-bar button that
        // pushes a CPListTemplate-based "Search" screen (Recent +
        // Suggested). CPSearchTemplate is not allowed on iOS 26 audio
        // apps — the system rejects it at pushTemplate with an
        // NSInvalidArgumentException, so we avoid it entirely.
        rootTemplate = CPTabBarTemplate(templates: [
            homeTemplate,
            driveTemplate,
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
        driveTemplate.trailingNavigationBarButtons = [searchButton]
        mashupTemplate.trailingNavigationBarButtons = [searchButton]
        moodTemplate.trailingNavigationBarButtons = [searchButton]
        exploreTemplate.trailingNavigationBarButtons = [searchButton]
        libraryTemplate.trailingNavigationBarButtons = [searchButton]

        // Home — 6 static shortcut tiles.
        buildHomeGrid()

        // Mood — 6 static tiles. Built once; no dynamic logic.
        buildMoodGrid()

        // Drive — Resume row + Recents + Top Played. Sync from UserDefaults.
        refreshDrive()
        observeDrive()

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

        // Library (was Playlists) — sync from UserDefaults via PlaylistManager.
        refreshPlaylists()
        observePlaylists()
    }

    deinit {
        homeLoadTask?.cancel()
        for (_, task) in playlistSongTasks { task.cancel() }
    }

    // MARK: - Home tab

    /// Fixed 6-shortcut grid. Signature-Glow treatment (option A):
    /// every tile shares a dark graphite base and differs only by the
    /// radial glow color behind its glyph. Symbols picked for clarity
    /// (option D) — richer, more readable at a glance than the old set.
    private static let homeTiles: [(title: String, symbol: String, action: HomeAction, glow: UIColor)] = [
        ("Continue", "play.circle.fill",         .continueResume,
         UIColor(red: 1.00, green: 0.28, blue: 0.32, alpha: 1)),   // red
        ("Mashup",   "music.note.list",          .openMashup,
         UIColor(red: 0.68, green: 0.35, blue: 0.96, alpha: 1)),   // purple
        ("Drive",    "steeringwheel",            .openDrive,
         UIColor(red: 0.30, green: 0.60, blue: 1.00, alpha: 1)),   // blue
        ("Mood",     "heart.circle.fill",        .openMood,
         UIColor(red: 1.00, green: 0.40, blue: 0.66, alpha: 1)),   // pink
        ("Explore",  "safari.fill",              .openExplore,
         UIColor(red: 1.00, green: 0.70, blue: 0.20, alpha: 1)),   // amber
        ("Library",  "rectangle.stack.fill",     .openLibrary,
         UIColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)),   // green
    ]

    private enum HomeAction {
        case continueResume
        case openMashup
        case openDrive
        case openMood
        case openExplore
        case openLibrary
    }

    private func buildHomeGrid() {
        let hasResume = LastPlayedPersistence.loadQueueIfFresh() != nil
        let hasMashupSession = hasContinueMashupSession()

        let buttons: [CPGridButton] = Self.homeTiles.map { tile in
            // Live-state dot per tile (option 5). Only dynamic actions
            // get a colored indicator; the rest render without a dot.
            let dotColor: UIColor? = {
                switch tile.action {
                case .continueResume:
                    return hasResume
                        ? UIColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1)
                        : nil
                case .openMashup:
                    return hasMashupSession
                        ? UIColor(red: 1.00, green: 0.70, blue: 0.20, alpha: 1)
                        : nil
                default:
                    return nil
                }
            }()
            let icon = Self.homeTileImage(
                symbolName: tile.symbol,
                glowColor: tile.glow,
                dotColor: dotColor
            )
            let action = tile.action
            return CPGridButton(
                titleVariants: [tile.title],
                image: icon
            ) { [weak self] _ in
                self?.handleHomeTile(action)
            }
        }
        homeTemplate.updateGridButtons(buttons)
    }

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

    /// Renders a Signature-Glow home tile (options A+D+1+2+3+4+5):
    ///   • rounded 28pt corner square, 160×160
    ///   • graphite vertical gradient base (unified across tiles)
    ///   • STUDIO LIGHTING — radial glow offset to upper-center so the
    ///     tile reads as lit from above; bottom inner shadow for depth
    ///   • HAIRLINE BORDER — 0.5pt white@10% stroke separating tile
    ///     from the dark CarPlay canvas
    ///   • Top inner highlight (1.5pt white@22%) for glass feel
    ///   • GLYPH DROP-HALO — soft accent-colored shadow under the glyph
    ///     so the icon reads as lit-from-within rather than stamped on
    ///   • DUOTONE GLYPH — palette config `[white, glow@75%]`; icons
    ///     with two render layers pick up the accent on the secondary
    ///     layer, single-layer symbols fall back to white
    ///   • LIVE-STATE DOT — optional 14pt accent circle in the top-
    ///     right corner for dynamic actions (Continue/Mashup)
    /// Grid buttons are the only per-tile styling lever CarPlay exposes,
    /// so the image does all the visual heavy-lifting.
    private static func homeTileImage(
        symbolName: String,
        glowColor: UIColor,
        dotColor: UIColor? = nil
    ) -> UIImage {
        let size = CGSize(width: 160, height: 160)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 28)
            let space = CGColorSpaceCreateDeviceRGB()

            cg.saveGState()
            cg.addPath(path.cgPath)
            cg.clip()

            // 1. Graphite base — unified dark gradient.
            let baseTop = UIColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1)
            let baseBottom = UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
            if let grad = CGGradient(
                colorsSpace: space,
                colors: [baseTop.cgColor, baseBottom.cgColor] as CFArray,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(
                    grad,
                    start: .zero,
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
            }

            // 2. Studio-lighting radial glow — shifted to the upper
            //    third so the glow reads as top-lit (physical light
            //    source above-camera). Slightly wider + brighter than
            //    the old centered version.
            let glowColors = [
                glowColor.withAlphaComponent(0.70).cgColor,
                glowColor.withAlphaComponent(0.28).cgColor,
                glowColor.withAlphaComponent(0.0).cgColor,
            ]
            if let radial = CGGradient(
                colorsSpace: space,
                colors: glowColors as CFArray,
                locations: [0, 0.55, 1]
            ) {
                let lightCenter = CGPoint(x: size.width / 2, y: size.height * 0.38)
                cg.drawRadialGradient(
                    radial,
                    startCenter: lightCenter,
                    startRadius: 0,
                    endCenter: lightCenter,
                    endRadius: size.width * 0.68,
                    options: []
                )
            }

            // 3. Bottom inner shadow — vertical fade to black over the
            //    lower half, reinforcing the top-lit feel.
            let shadowColors = [
                UIColor.black.withAlphaComponent(0.0).cgColor,
                UIColor.black.withAlphaComponent(0.35).cgColor,
            ]
            if let shadow = CGGradient(
                colorsSpace: space,
                colors: shadowColors as CFArray,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(
                    shadow,
                    start: CGPoint(x: 0, y: size.height * 0.55),
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
            }

            cg.restoreGState()

            // 4. Hairline outer border — 0.5pt white@10%, inset by
            //    half the stroke width so the line sits cleanly on
            //    the rounded rect edge.
            let borderRect = rect.insetBy(dx: 0.25, dy: 0.25)
            let border = UIBezierPath(roundedRect: borderRect, cornerRadius: 28)
            UIColor.white.withAlphaComponent(0.10).setStroke()
            border.lineWidth = 0.5
            border.stroke()

            // 5. Top hairline highlight for glass feel.
            let inset: CGFloat = 14
            let highlight = UIBezierPath()
            highlight.move(to: CGPoint(x: inset, y: 3))
            highlight.addLine(to: CGPoint(x: size.width - inset, y: 3))
            UIColor.white.withAlphaComponent(0.22).setStroke()
            highlight.lineWidth = 1.5
            highlight.lineCapStyle = .round
            highlight.stroke()

            // 6. Duotone SF Symbol with glyph drop-halo.
            //    Palette: primary white + secondary accent@75%. Single-
            //    layer symbols fall back to monochrome white.
            let baseCfg = UIImage.SymbolConfiguration(pointSize: 72, weight: .bold)
            let palette = UIImage.SymbolConfiguration(paletteColors: [
                .white,
                glowColor.withAlphaComponent(0.75)
            ])
            let config = baseCfg.applying(palette)
            if let icon = UIImage(systemName: symbolName, withConfiguration: config) {
                let iconRect = CGRect(
                    x: (size.width - icon.size.width) / 2,
                    y: (size.height - icon.size.height) / 2,
                    width: icon.size.width,
                    height: icon.size.height
                )
                cg.saveGState()
                // Accent halo — soft blur under the glyph. Renders as
                // a lit-from-within feel matched to the tile glow.
                cg.setShadow(
                    offset: .zero,
                    blur: 18,
                    color: glowColor.withAlphaComponent(0.85).cgColor
                )
                icon.draw(in: iconRect)
                cg.restoreGState()
            }

            // 7. Live-state dot — top-right corner, accent-colored,
            //    white inner ring for contrast, soft matching blur so
            //    it reads as a glowing indicator.
            if let dotColor {
                let dotSize: CGFloat = 14
                let dotRect = CGRect(
                    x: size.width - dotSize - 12,
                    y: 12,
                    width: dotSize,
                    height: dotSize
                )
                cg.saveGState()
                cg.setShadow(
                    offset: .zero,
                    blur: 8,
                    color: dotColor.withAlphaComponent(0.9).cgColor
                )
                dotColor.setFill()
                UIBezierPath(ovalIn: dotRect).fill()
                cg.restoreGState()

                let ring = UIBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1))
                UIColor.white.withAlphaComponent(0.85).setStroke()
                ring.lineWidth = 1.2
                ring.stroke()
            }
        }
    }

    /// Routes each Home grid tap. For navigation tiles we push a fresh
    /// clone template (CarPlay templates can only appear in one location
    /// — pushing a tab template as child is invalid). Continue fires
    /// resume playback directly.
    private func handleHomeTile(_ action: HomeAction) {
        guard let controller = interfaceController else { return }
        switch action {
        case .continueResume:
            continueFromResume()
        case .openMashup:
            pushCloneList(title: "Mashup", sections: computeMashupSections(),
                          emptyText: "Loading mashups…", on: controller)
        case .openDrive:
            pushCloneList(title: "Drive", sections: computeDriveSections(),
                          emptyText: "Play a song to see it here", on: controller)
        case .openMood:
            let clone = CPGridTemplate(title: "Mood", gridButtons: computeMoodButtons())
            clone.trailingNavigationBarButtons = [makeSearchButton()]
            controller.pushTemplate(clone, animated: true) { _, error in
                if let error {
                    coordinatorLogger.error("🚗 Home→Mood push failed: \(error.localizedDescription)")
                }
            }
        case .openExplore:
            pushCloneList(title: "Explore", sections: computeExploreSections(),
                          emptyText: "Nothing to resume yet", on: controller)
        case .openLibrary:
            pushCloneList(title: "Library", sections: computeLibrarySections(),
                          emptyText: "Create a playlist on your phone to see it here",
                          on: controller)
        }
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
    /// Drive tab's "Resume" row uses. No-op if nothing fresh is saved.
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

    // MARK: - Drive tab

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

    /// Re-registers `withObservationTracking` so the Drive tab refreshes
    /// whenever a new song is added to RecentlyPlayedManager. Also bumps
    /// the play counter for the newly-prepended song.
    private func observeDrive() {
        withObservationTracking {
            _ = RecentlyPlayedManager.shared.songs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.bumpTopPlayedIfNeeded()
                self?.refreshDrive()
                self?.refreshExplore()
                // Home grid's live-state dots (Continue, Mashup)
                // depend on recents + lastPlayed freshness — rebuild
                // the grid so indicators stay accurate.
                self?.buildHomeGrid()
                self?.observeDrive()
            }
        }
    }

    /// Increment the top-played counter for the current head of Recents
    /// when it changes. Called from `observeDrive` so playback never
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

    private func refreshDrive() {
        let sections = computeDriveSections()
        if sections.isEmpty {
            driveTemplate.updateSections([
                CPListSection(items: [
                    Self.placeholderItem(text: "Play a song to see it here")
                ])
            ])
        } else {
            driveTemplate.updateSections(sections)
        }
    }

    /// Builds the Drive tab sections fresh. Exposed so Home grid's "Drive"
    /// button can push a standalone clone — CarPlay templates can only
    /// live in one place, so shortcuts need their own instance.
    private func computeDriveSections() -> [CPListSection] {
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
        let items = lists.map { playlist -> CPListItem in
            let subtitle = Self.playlistSubtitle(playlist)
            let item = CPListItem(
                text: "\(playlist.emoji) \(playlist.name)",
                detailText: subtitle
            )
            // Always show artwork. Prefer a thumbnail from the first
            // song if it's already cached in RecentlyPlayed (no new API
            // call). Otherwise fall back to the gradient placeholder so
            // every row has the same visual weight.
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
}

