//
//  SongRepository.swift
//  Dhunify
//
//  Domain-layer repository contracts for song discovery, downloads,
//  and local library persistence.
//

import Foundation

/// Handles remote song discovery and the lifecycle of downloaded media.
protocol SongRepository {
    /// Searches the remote catalog for songs matching `query`.
    func search(query: String) async throws -> [Song]

    /// Downloads `song` to local storage and returns the on-disk URL.
    func download(song: Song) async throws -> URL

    /// Removes the local copy of `song`, if one exists.
    func delete(song: Song) async throws
}

/// Persists the user's library of saved songs.
protocol SongStore {
    /// Returns every song currently in the user's library.
    func fetchLibrary() async throws -> [Song]

    /// Inserts or updates `song` in the library.
    func save(song: Song) async throws

    /// Removes `song` from the library.
    func remove(song: Song) async throws
}
