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

    /// Lightweight Gujarati-presence check across the last 10 plays.
    /// Drives the Home / CarPlay section ordering: when Gujarati shows
    /// up in the recent window, the "Gujarati Hits" section is hoisted
    /// above "Latest Hindi". Pure keyword match — no script detection,
    /// no ML, ~zero CPU.
    func recentlyHasGujarati() -> Bool {
        let window = songs.prefix(10)
        guard !window.isEmpty else { return false }
        let keywords: [String] = [
            "gujarati", "garba", "navratri", "dandiya", "raas",
            "falguni pathak", "kinjal", "geeta rabari", "jignesh kaviraj",
            "kirtidan", "aditya gadhvi"
        ]
        for song in window {
            let haystack = "\(song.title) \(song.artist)".lowercased()
            // Latin keywords.
            for kw in keywords where haystack.contains(kw) {
                return true
            }
            // Gujarati Unicode block (U+0A80–U+0AFF). One scalar in
            // range = Gujarati script in title or artist.
            for scalar in haystack.unicodeScalars {
                if (0x0A80...0x0AFF).contains(scalar.value) { return true }
            }
        }
        return false
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
