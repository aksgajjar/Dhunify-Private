//
//  RecentlyPlayedManager.swift
//  Dhunify
//
//  Stores last 20 played songs in UserDefaults as JSON.
//

import Foundation

@MainActor
@Observable
final class RecentlyPlayedManager {
    static let shared = RecentlyPlayedManager()

    var songs: [Song] = []

    private let baseKey = "dhunify.recentlyPlayed"
    private let maxCount = 20

    private var key: String {
        let profileID = ProfileManager.shared.currentProfile?.id.uuidString ?? "default"
        return "\(baseKey).\(profileID)"
    }

    private init() { load() }

    func add(song: Song) {
        // Remove duplicate, prepend, cap at 20.
        songs.removeAll { $0.youtubeID == song.youtubeID }
        songs.insert(song, at: 0)
        if songs.count > maxCount { songs = Array(songs.prefix(maxCount)) }
        save()
    }

    /// Reload data for the current profile (call after profile switch).
    func reloadForCurrentProfile() {
        load()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(songs) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Song].self, from: data) else {
            songs = []
            return
        }
        songs = decoded
    }
}
