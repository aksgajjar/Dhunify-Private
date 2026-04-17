//
//  LocalSongStore.swift
//  Dhunify
//
//  SwiftData-backed SongStore. Implemented as a @ModelActor so every
//  mutation runs on the actor's owned ModelContext — safe to call
//  from any task without worrying about ModelContext's non-Sendable
//  nature.
//

import Foundation
import SwiftData

@ModelActor
actor LocalSongStore: SongStore {

    // MARK: - SongStore

    func fetchLibrary() async throws -> [Song] {
        let descriptor = FetchDescriptor<SongModel>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        let models = try modelContext.fetch(descriptor)
        return models.map { $0.toDomain() }
    }

    func save(song: Song) async throws {
        if let existing = try fetchModel(youtubeID: song.youtubeID) {
            existing.apply(song)
        } else {
            modelContext.insert(SongModel.from(song: song))
        }
        try modelContext.save()
    }

    func remove(song: Song) async throws {
        guard let existing = try fetchModel(youtubeID: song.youtubeID) else {
            return
        }

        // Best-effort removal of the downloaded file — a missing file
        // should not prevent the library row from being deleted.
        if let localFileURL = existing.localFileURL,
           let url = URL(string: localFileURL),
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        modelContext.delete(existing)
        try modelContext.save()
    }

    // MARK: - Helpers

    private func fetchModel(youtubeID: String) throws -> SongModel? {
        var descriptor = FetchDescriptor<SongModel>(
            predicate: #Predicate { $0.youtubeID == youtubeID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
