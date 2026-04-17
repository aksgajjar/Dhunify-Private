//
//  DownloadSongUseCase.swift
//  Dhunify
//
//  Downloads a song through the SongRepository and persists the
//  resulting local copy in the SongStore.
//

import Foundation

struct DownloadSongUseCase {
    private let repository: SongRepository
    private let store: SongStore

    init(repository: SongRepository, store: SongStore) {
        self.repository = repository
        self.store = store
    }

    func execute(song: Song) async throws -> Song {
        let localURL = try await repository.download(song: song)

        let downloaded = Song(
            id: song.id,
            title: song.title,
            artist: song.artist,
            thumbnailURL: song.thumbnailURL,
            youtubeID: song.youtubeID,
            duration: song.duration,
            isDownloaded: true,
            localFileURL: localURL.absoluteString,
            addedAt: song.addedAt
        )

        try await store.save(song: downloaded)
        return downloaded
    }
}
