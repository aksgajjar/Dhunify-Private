//
//  LastPlayedPersistence.swift
//  Dhunify
//
//  Persists the last played song across launches so the "Resume
//  Dhunify" App Intent and lock-screen resume flows have something
//  to pick back up from.
//

import Foundation

struct LastPlayedPersistence {
    private static var profileSuffix: String {
        ProfileManager.shared.currentProfile?.id.uuidString ?? "default"
    }

    private enum Keys {
        static var id: String { "dhunify.lastPlayed.\(profileSuffix).id" }
        static var title: String { "dhunify.lastPlayed.\(profileSuffix).title" }
        static var artist: String { "dhunify.lastPlayed.\(profileSuffix).artist" }
        static var thumbnailURL: String { "dhunify.lastPlayed.\(profileSuffix).thumbnailURL" }
        static var youtubeID: String { "dhunify.lastPlayed.\(profileSuffix).youtubeID" }
        static var duration: String { "dhunify.lastPlayed.\(profileSuffix).duration" }
        static var isDownloaded: String { "dhunify.lastPlayed.\(profileSuffix).isDownloaded" }
        static var localFileURL: String { "dhunify.lastPlayed.\(profileSuffix).localFileURL" }
        static var addedAt: String { "dhunify.lastPlayed.\(profileSuffix).addedAt" }
    }


    static func save(song: Song) {
        let defaults = UserDefaults.standard
        defaults.set(song.id.uuidString, forKey: Keys.id)
        defaults.set(song.title, forKey: Keys.title)
        defaults.set(song.artist, forKey: Keys.artist)
        defaults.set(song.thumbnailURL, forKey: Keys.thumbnailURL)
        defaults.set(song.youtubeID, forKey: Keys.youtubeID)
        defaults.set(song.duration, forKey: Keys.duration)
        defaults.set(song.isDownloaded, forKey: Keys.isDownloaded)
        defaults.set(song.addedAt.timeIntervalSince1970, forKey: Keys.addedAt)
        if let local = song.localFileURL {
            defaults.set(local, forKey: Keys.localFileURL)
        } else {
            defaults.removeObject(forKey: Keys.localFileURL)
        }
    }

    static func load() -> Song? {
        let defaults = UserDefaults.standard
        guard
            let idString = defaults.string(forKey: Keys.id),
            let id = UUID(uuidString: idString),
            let title = defaults.string(forKey: Keys.title),
            let artist = defaults.string(forKey: Keys.artist),
            let thumbnailURL = defaults.string(forKey: Keys.thumbnailURL),
            let youtubeID = defaults.string(forKey: Keys.youtubeID)
        else {
            return nil
        }
        let duration = defaults.double(forKey: Keys.duration)
        let isDownloaded = defaults.bool(forKey: Keys.isDownloaded)
        let localFileURL = defaults.string(forKey: Keys.localFileURL)
        let addedAtInterval = defaults.double(forKey: Keys.addedAt)
        let addedAt = addedAtInterval > 0 ? Date(timeIntervalSince1970: addedAtInterval) : Date()

        return Song(
            id: id,
            title: title,
            artist: artist,
            thumbnailURL: thumbnailURL,
            youtubeID: youtubeID,
            duration: duration,
            isDownloaded: isDownloaded,
            localFileURL: localFileURL,
            addedAt: addedAt
        )
    }

    // MARK: - Position memory

    private static var positionKey: String { "dhunify.lastPlayed.\(profileSuffix).position" }

    static func savePosition(_ seconds: TimeInterval) {
        UserDefaults.standard.set(seconds, forKey: positionKey)
    }

    static func loadPosition() -> TimeInterval {
        UserDefaults.standard.double(forKey: positionKey)
    }

    // MARK: - Full queue + freshness

    // Stores the whole current queue plus a "last played at" timestamp so
    // surfaces like CarPlay can decide whether to resume vs. start fresh.
    private static var queueKey: String { "dhunify.lastPlayed.\(profileSuffix).queueJSON" }
    private static var queueIndexKey: String { "dhunify.lastPlayed.\(profileSuffix).queueIndex" }
    private static var lastPlayedAtKey: String { "dhunify.lastPlayed.\(profileSuffix).lastPlayedAt" }

    static func saveQueue(_ songs: [Song], currentIndex: Int) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(songs) {
            defaults.set(data, forKey: queueKey)
        }
        defaults.set(currentIndex, forKey: queueIndexKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastPlayedAtKey)
    }

    /// Returns the saved queue + index if the last-played timestamp is
    /// within `maxAge` seconds (default 24h). Returns nil otherwise.
    static func loadQueueIfFresh(maxAge: TimeInterval = 24 * 60 * 60) -> (queue: [Song], index: Int)? {
        let defaults = UserDefaults.standard
        let savedAt = defaults.double(forKey: lastPlayedAtKey)
        guard savedAt > 0 else { return nil }
        guard Date().timeIntervalSince1970 - savedAt <= maxAge else { return nil }
        guard let data = defaults.data(forKey: queueKey),
              let songs = try? JSONDecoder().decode([Song].self, from: data),
              !songs.isEmpty else { return nil }
        let idx = defaults.integer(forKey: queueIndexKey)
        return (songs, max(0, min(idx, songs.count - 1)))
    }

    static func clear() {
        let defaults = UserDefaults.standard
        [
            Keys.id, Keys.title, Keys.artist, Keys.thumbnailURL,
            Keys.youtubeID, Keys.duration, Keys.isDownloaded,
            Keys.localFileURL, Keys.addedAt
        ].forEach { defaults.removeObject(forKey: $0) }
    }
}
