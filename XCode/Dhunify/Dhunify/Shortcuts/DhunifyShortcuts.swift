//
//  DhunifyShortcuts.swift
//  Dhunify
//
//  App Intents surface for Siri, Shortcuts, Spotlight, and the Action
//  Button. All three intents route through AppContainer.shared so
//  they share the same PlayerViewModel as CarPlay and the in-app
//  player — Siri "Play X on Dhunify" and a CarPlay play/pause both
//  touch the same state machine.
//

import AppIntents
import Foundation

// MARK: - Play song

struct PlaySongIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a song on Dhunify"
    static let description = IntentDescription(
        "Search Dhunify for a song and start playing the top result."
    )

    // Most intents that initiate media playback should open the app
    // so the playback surface is visible — Apple's guidance for media
    // intents invoked via Siri.
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
        guard let song = LastPlayedPersistence.load() else {
            return .result(
                dialog: IntentDialog("I don't have a recent Dhunify song to resume.")
            )
        }

        let container = AppContainer.shared
        container.playerViewModel.setQueue([song], startIndex: 0)
        container.playerViewModel.play()

        return .result(
            dialog: IntentDialog("Resuming \(song.title) by \(song.artist).")
        )
    }
}

// MARK: - Pause

struct PausePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Dhunify"
    static let description = IntentDescription("Pause whatever Dhunify is currently playing.")

    // Pause doesn't need to bring the app forward — it's a
    // background-safe action.
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
    // PlaySongIntent stays available for explicit "Play <title>" requests
    // but is no longer the default surfaced action.
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
