//
//  SongModel.swift
//  Dhunify
//
//  SwiftData persistence model for `Song`. Kept deliberately separate
//  from the domain entity so storage concerns (schema, migrations,
//  @Attribute annotations) never leak into the domain layer.
//

import Foundation
import SwiftData

@Model
final class SongModel {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var youtubeID: String

    var title: String
    var artist: String
    var thumbnailURL: String
    var duration: TimeInterval
    var isDownloaded: Bool
    var localFileURL: String?
    var addedAt: Date

    init(
        id: UUID,
        title: String,
        artist: String,
        thumbnailURL: String,
        youtubeID: String,
        duration: TimeInterval,
        isDownloaded: Bool,
        localFileURL: String?,
        addedAt: Date
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.thumbnailURL = thumbnailURL
        self.youtubeID = youtubeID
        self.duration = duration
        self.isDownloaded = isDownloaded
        self.localFileURL = localFileURL
        self.addedAt = addedAt
    }

    // MARK: - Mapping

    func toDomain() -> Song {
        Song(
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

    static func from(song: Song) -> SongModel {
        SongModel(
            id: song.id,
            title: song.title,
            artist: song.artist,
            thumbnailURL: song.thumbnailURL,
            youtubeID: song.youtubeID,
            duration: song.duration,
            isDownloaded: song.isDownloaded,
            localFileURL: song.localFileURL,
            addedAt: song.addedAt
        )
    }

    /// Copies mutable fields from `song` onto this managed instance.
    /// Used by the upsert path in `LocalSongStore` so we don't orphan
    /// a record while preserving its SwiftData identity.
    func apply(_ song: Song) {
        title = song.title
        artist = song.artist
        thumbnailURL = song.thumbnailURL
        duration = song.duration
        isDownloaded = song.isDownloaded
        localFileURL = song.localFileURL
        addedAt = song.addedAt
    }
}
