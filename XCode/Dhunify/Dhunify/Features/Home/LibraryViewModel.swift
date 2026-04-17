//
//  LibraryViewModel.swift
//  Dhunify
//
//  View-model for the user's downloaded library. Reads from the
//  injected SongStore, exposes a case-insensitive text filter, and
//  handles deletions with optimistic UI updates.
//

import Foundation

@MainActor
@Observable
final class LibraryViewModel {
    var songs: [Song] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var searchText: String = ""

    var filteredSongs: [Song] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return songs }
        return songs.filter { song in
            song.title.localizedCaseInsensitiveContains(trimmed)
                || song.artist.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private let store: any SongStore

    init(store: any SongStore) {
        self.store = store
        Task { await loadLibrary() }
    }

    // MARK: - Actions

    func loadLibrary() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            songs = try await store.fetchLibrary()
        } catch {
            errorMessage = error.localizedDescription
            songs = []
        }
    }

    func deleteSong(_ song: Song) async {
        // Optimistic removal so the row disappears instantly; we restore
        // it if the store call fails.
        let previousSongs = songs
        songs.removeAll { $0.id == song.id }

        do {
            try await store.remove(song: song)
        } catch {
            songs = previousSongs
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
