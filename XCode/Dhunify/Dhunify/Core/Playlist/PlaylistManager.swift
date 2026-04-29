//
//  PlaylistManager.swift
//  Dhunify
//
//  Local playlist storage in UserDefaults (JSON). Max 20 per profile.
//

import Foundation
import os

private let playlistLog = Logger(subsystem: "com.diphoria.Dhunify", category: "Playlist")

struct UserPlaylist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var emoji: String
    var songIDs: [String]   // youtubeID / jio_XXX
    var createdAt: Date
    var profileID: String

    init(name: String, emoji: String, profileID: String) {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.songIDs = []
        self.createdAt = Date()
        self.profileID = profileID
    }

    var songCount: Int { songIDs.count }
}

@MainActor
@Observable
final class PlaylistManager {
    static let shared = PlaylistManager()

    var playlists: [UserPlaylist] = []

    static let maxPlaylists = 20
    private let storageKey = "dhunify.playlists"

    private init() { load() }

    /// Playlists for the current profile.
    var currentPlaylists: [UserPlaylist] {
        let pid = ProfileManager.shared.currentProfile?.id.uuidString ?? ""
        return playlists.filter { $0.profileID == pid }
    }

    var canCreate: Bool {
        currentPlaylists.count < Self.maxPlaylists
    }

    @discardableResult
    func createPlaylist(name: String, emoji: String) -> UserPlaylist {
        let pid = ProfileManager.shared.currentProfile?.id.uuidString ?? ""
        let playlist = UserPlaylist(name: name, emoji: emoji, profileID: pid)
        playlists.append(playlist)
        save()
        playlistLog.info("Created playlist '\(name, privacy: .public)' pid=\(pid, privacy: .public) total=\(self.currentPlaylists.count)")
        return playlist
    }

    func addSong(_ songID: String, to playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[idx].songIDs.contains(songID) {
            playlists[idx].songIDs.append(songID)
            save()
            let p = playlists[idx]
            playlistLog.info("Added to playlist '\(p.name, privacy: .public)' count=\(p.songIDs.count)")
        }
    }

    func renamePlaylist(_ id: UUID, to newName: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[idx].name = trimmed
        save()
    }

    func removeSong(_ songID: String, from playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].songIDs.removeAll { $0 == songID }
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func playlist(for id: UUID) -> UserPlaylist? {
        playlists.first { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([UserPlaylist].self, from: data) else { return }
        playlists = decoded
    }
}
