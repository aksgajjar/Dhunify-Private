//
//  DhunifyShortcuts.swift
//  Dhunify
//
//  App Intents surface for Siri, Shortcuts, Spotlight, and the Action
//  Button. Uses AppEntity-based parameters so the Shortcuts app shows
//  real pickers (playlist dropdown, section enum) instead of free-text
//  prompts. All intents route through AppContainer.shared so they
//  share the same PlayerViewModel as CarPlay and the in-app player.
//

import AppIntents
import Foundation

// MARK: - Playlist entity

/// AppEntity wrapper so Shortcuts can render a real dropdown of the
/// user's playlists. `id` is the UUID string of the underlying
/// `UserPlaylist` — resolved back through PlaylistManager on run.
struct PlaylistEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Playlist")
    }

    static var defaultQuery = PlaylistQuery()

    let id: String
    let name: String
    let emoji: String
    let songCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(emoji) \(name)",
            subtitle: "\(songCount) \(songCount == 1 ? "song" : "songs")"
        )
    }

    @MainActor
    init(_ playlist: UserPlaylist) {
        self.id = playlist.id.uuidString
        self.name = playlist.name
        self.emoji = playlist.emoji
        self.songCount = playlist.songCount
    }
}

/// Feeds Shortcuts the live list of playlists from PlaylistManager.
/// `suggestedEntities` powers the picker; `entities(for:)` resolves the
/// chosen id back to an entity on run.
struct PlaylistQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        let all = PlaylistManager.shared.currentPlaylists
        let wanted = Set(identifiers)
        return all
            .filter { wanted.contains($0.id.uuidString) }
            .map { PlaylistEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        PlaylistManager.shared.currentPlaylists.map { PlaylistEntity($0) }
    }
}

// MARK: - Home section enum

/// AppEnum so the "Play Section" intent shows a dropdown of the three
/// home surfaces rather than a free-text box. Named `DhunifyShortcutSection`
/// to avoid clashing with `HomeSection` in HomeViewModel, which is a
/// different in-app struct.
enum DhunifyShortcutSection: String, AppEnum {
    case trending
    case popular
    case recentlyPlayed

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Home Section")
    }

    static var caseDisplayRepresentations: [DhunifyShortcutSection: DisplayRepresentation] = [
        .trending: DisplayRepresentation(title: "Trending"),
        .popular: DisplayRepresentation(title: "Popular"),
        .recentlyPlayed: DisplayRepresentation(title: "Recently Played"),
    ]
}

// MARK: - Play song

struct PlaySongIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a song on Dhunify"
    static let description = IntentDescription(
        "Search Dhunify for a song and start playing the top result."
    )

    static let openAppWhenRun: Bool = true

    @Parameter(title: "Song name")
    var songName: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = AppContainer.shared
        let repository = container.songRepository

        let results: [Song]
        do {
            results = try await repository.search(query: songName)
        } catch {
            return .result(
                dialog: IntentDialog("I couldn't reach Dhunify right now. Please try again.")
            )
        }

        guard let first = results.first else {
            return .result(
                dialog: IntentDialog("I couldn't find any songs for \(songName) on Dhunify.")
            )
        }

        container.playerViewModel.setQueue(results, startIndex: 0)
        container.playerViewModel.play()

        return .result(
            dialog: IntentDialog("Playing \(first.title) by \(first.artist) on Dhunify.")
        )
    }
}

// MARK: - Resume last song

struct PlayLastSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Dhunify"
    static let description = IntentDescription(
        "Resume the last song you played on Dhunify."
    )

    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = AppContainer.shared
        let vm = container.playerViewModel

        // Prefer the full saved queue (with index) so next/prev keep
        // working after resume. Falls back to the single last-played
        // song if the queue snapshot is stale or missing.
        let queue: [Song]
        let startIndex: Int
        let currentSong: Song
        if let snapshot = LastPlayedPersistence.loadQueueIfFresh() {
            queue = snapshot.queue
            startIndex = snapshot.index
            currentSong = snapshot.queue[snapshot.index]
        } else if let song = LastPlayedPersistence.load() {
            queue = [song]
            startIndex = 0
            currentSong = song
        } else {
            return .result(
                dialog: IntentDialog("I don't have a recent Dhunify song to resume.")
            )
        }

        // Arm the resume position BEFORE setQueue. PlayerViewModel
        // consumes pendingResumeSeconds inside its readyToPlay KVO
        // handler, so the seek runs only once the AVPlayerItem is
        // actually loaded — no timing guesses.
        let savedPosition = LastPlayedPersistence.loadPosition()
        if savedPosition > 3 {
            vm.pendingResumeSeconds = savedPosition
        }

        vm.setQueue(queue, startIndex: startIndex)
        vm.play()

        return .result(
            dialog: IntentDialog("Resuming \(currentSong.title) by \(currentSong.artist).")
        )
    }
}

// MARK: - Play liked songs

struct PlayLikedSongsIntent: AppIntent {
    static let title: LocalizedStringResource = "Play liked songs on Dhunify"
    static let description = IntentDescription(
        "Play all the songs you've liked on Dhunify."
    )

    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let likes = LibraryStore.shared.likedSongs
        guard !likes.isEmpty else {
            return .result(
                dialog: IntentDialog("You haven't liked any songs on Dhunify yet.")
            )
        }

        let container = AppContainer.shared
        container.playerViewModel.setQueue(likes, startIndex: 0, categorySeed: "Liked Songs")
        container.playerViewModel.play()

        return .result(
            dialog: IntentDialog("Playing your liked songs on Dhunify.")
        )
    }
}

// MARK: - Play playlist (AppEntity-based)

/// Plays a user playlist selected from the Shortcuts picker. Uses the
/// entity's UUID to resolve the underlying UserPlaylist, then fetches
/// each songID via `/song/<id>` in parallel — same path as
/// PlaylistDetailView so Shortcut playback starts at UI speed.
struct PlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a playlist on Dhunify"
    static let description = IntentDescription(
        "Pick a Dhunify playlist and start playing its songs."
    )

    static let openAppWhenRun: Bool = true

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uuid = UUID(uuidString: playlist.id),
              let resolved = PlaylistManager.shared.playlist(for: uuid) else {
            return .result(
                dialog: IntentDialog("I couldn't find that playlist.")
            )
        }

        guard !resolved.songIDs.isEmpty else {
            return .result(
                dialog: IntentDialog("Playlist \(resolved.name) is empty.")
            )
        }

        let songs = await Self.resolveSongs(resolved.songIDs)
        guard !songs.isEmpty else {
            return .result(
                dialog: IntentDialog("I couldn't load any songs from \(resolved.name) right now.")
            )
        }

        let container = AppContainer.shared
        container.playerViewModel.setQueue(songs, startIndex: 0, categorySeed: "Playlist:\(resolved.name)")
        container.playerViewModel.play()

        return .result(
            dialog: IntentDialog("Playing \(resolved.name) on Dhunify.")
        )
    }

    /// Parallel /song/<id> fetch. Order preserved by playlist `songIDs`.
    /// Song init wrapped in MainActor.run because `Song` is main-actor
    /// isolated and we're hopping in from detached TaskGroup children.
    private static func resolveSongs(_ ids: [String]) async -> [Song] {
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
                        return await MainActor.run {
                            (idx, Song(
                                title: dto.title,
                                artist: dto.artist,
                                thumbnailURL: dto.thumbnailURL,
                                youtubeID: dto.youtubeID,
                                duration: dto.duration
                            ))
                        }
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
}

// MARK: - Play home section

/// Plays one of the home surfaces (Trending / Popular / Recently
/// Played). Reads in-memory data only — no new network fetches. The
/// shared HomeViewModel is hydrated by the iPhone Home screen + CarPlay
/// coordinator, so the data is always current when this intent runs.
struct PlayHomeSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a section on Dhunify"
    static let description = IntentDescription(
        "Pick a home section and play its songs on Dhunify."
    )

    static let openAppWhenRun: Bool = true

    @Parameter(title: "Section")
    var section: DhunifyShortcutSection

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = AppContainer.shared

        let songs: [Song]
        let label: String
        switch section {
        case .trending:
            songs = container.homeViewModel.sections.first?.songs ?? []
            label = "Trending"
        case .popular:
            let all = container.homeViewModel.sections
            songs = all.count > 1 ? all[1].songs : []
            label = "Popular"
        case .recentlyPlayed:
            songs = RecentlyPlayedManager.shared.songs
            label = "Recently Played"
        }

        guard !songs.isEmpty else {
            return .result(
                dialog: IntentDialog("\(label) is empty right now. Open Dhunify on your phone to load music.")
            )
        }

        container.playerViewModel.setQueue(songs, startIndex: 0, categorySeed: "Shortcut:\(label)")
        container.playerViewModel.play()

        return .result(
            dialog: IntentDialog("Playing \(label) on Dhunify.")
        )
    }
}

// MARK: - Pause

struct PausePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Dhunify"
    static let description = IntentDescription("Pause whatever Dhunify is currently playing.")

    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppContainer.shared.playerViewModel.pause()
        return .result(dialog: IntentDialog("Dhunify paused."))
    }
}

// MARK: - Shortcuts provider

struct DhunifyShortcutsProvider: AppShortcutsProvider {
    // Order matters: iOS / CarPlay Siri surfaces the FIRST shortcut when
    // a generic media trigger fires. PlayLastSongIntent goes first so
    // CarPlay connects → resumes last song without prompting for input.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayLastSongIntent(),
            phrases: [
                "Play music on \(.applicationName)",
                "Play \(.applicationName)",
                "Resume \(.applicationName)",
                "Continue playing on \(.applicationName)",
                "Keep playing \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Play a song on \(.applicationName)",
                "Search \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "play.circle.fill"
        )

        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play a playlist on \(.applicationName)",
                "Play playlist on \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )

        AppShortcut(
            intent: PlayLikedSongsIntent(),
            phrases: [
                "Play liked songs on \(.applicationName)",
                "Play my likes on \(.applicationName)",
                "Play favorites on \(.applicationName)",
                "Play my liked songs on \(.applicationName)"
            ],
            shortTitle: "Liked Songs",
            systemImageName: "heart.fill"
        )

        AppShortcut(
            intent: PlayHomeSectionIntent(),
            phrases: [
                "Play a section on \(.applicationName)",
                "Play section on \(.applicationName)"
            ],
            shortTitle: "Play Section",
            systemImageName: "square.grid.2x2.fill"
        )

        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Stop \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
    }
}
