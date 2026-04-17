//
//  LibraryStore.swift
//  Dhunify
//
//  Per-profile liked-songs + saved-albums store. Persists full entity
//  payloads (not just IDs) in UserDefaults so the Liked Songs / Saved
//  Albums screens can render instantly without a round trip to any
//  backend.
//
//  Pattern mirrors HiddenSongsManager: singleton, @Observable, reloads
//  on profile switch via `reload()`.
//

import Foundation

@MainActor
@Observable
final class LibraryStore {

    static let shared = LibraryStore()

    // Insertion order preserved — newest first, so "Liked Songs" reads
    // like a chronological feed (iOS Music / Spotify behavior).
    private(set) var likedSongs: [Song] = []
    private(set) var savedAlbums: [AlbumResult] = []

    private var songsKey: String {
        let suffix = ProfileManager.shared.currentProfile?.id.uuidString ?? "default"
        return "dhunify.likedSongs.\(suffix)"
    }

    private var albumsKey: String {
        let suffix = ProfileManager.shared.currentProfile?.id.uuidString ?? "default"
        return "dhunify.savedAlbums.\(suffix)"
    }

    private init() { reload() }

    func reload() {
        likedSongs = decode([Song].self, forKey: songsKey) ?? []
        savedAlbums = decode([AlbumResult].self, forKey: albumsKey) ?? []
    }

    // MARK: - Likes

    func isLiked(_ song: Song) -> Bool {
        likedSongs.contains { $0.youtubeID == song.youtubeID }
    }

    /// Toggle like state. Returns the new state (true = now liked).
    @discardableResult
    func toggleLike(_ song: Song) -> Bool {
        if let idx = likedSongs.firstIndex(where: { $0.youtubeID == song.youtubeID }) {
            likedSongs.remove(at: idx)
            persistSongs()
            return false
        }
        likedSongs.insert(song, at: 0)
        persistSongs()
        return true
    }

    func unlike(youtubeID: String) {
        likedSongs.removeAll { $0.youtubeID == youtubeID }
        persistSongs()
    }

    // MARK: - Albums

    func isSaved(_ album: AlbumResult) -> Bool {
        savedAlbums.contains { $0.id == album.id }
    }

    @discardableResult
    func toggleSave(_ album: AlbumResult) -> Bool {
        if let idx = savedAlbums.firstIndex(where: { $0.id == album.id }) {
            savedAlbums.remove(at: idx)
            persistAlbums()
            return false
        }
        savedAlbums.insert(album, at: 0)
        persistAlbums()
        return true
    }

    func unsave(albumID: String) {
        savedAlbums.removeAll { $0.id == albumID }
        persistAlbums()
    }

    // MARK: - Persist

    private func persistSongs() {
        encode(likedSongs, forKey: songsKey)
    }

    private func persistAlbums() {
        encode(savedAlbums, forKey: albumsKey)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
