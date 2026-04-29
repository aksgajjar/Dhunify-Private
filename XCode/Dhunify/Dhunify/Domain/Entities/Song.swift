//
//  Song.swift
//  Dhunify
//
//  Domain entity representing a music track.
//

import Foundation

struct Song: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let artist: String
    let thumbnailURL: String
    let youtubeID: String
    let duration: TimeInterval
    let isDownloaded: Bool
    let localFileURL: String?
    let addedAt: Date
    /// YouTube videoRenderer view count. `nil` for music-shelf and JioSaavn items.
    let viewCount: Int64?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        thumbnailURL: String,
        youtubeID: String,
        duration: TimeInterval,
        isDownloaded: Bool = false,
        localFileURL: String? = nil,
        addedAt: Date = Date(),
        viewCount: Int64? = nil
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
        self.viewCount = viewCount
    }

    // MARK: - Source

    /// Backend prefixes JioSaavn ids with `jio_` and YouTube fallbacks with
    /// `yt_`. UI uses this to tag tracks that came from the YT fallback.
    var isYouTubeSource: Bool { youtubeID.hasPrefix("yt_") }

    // MARK: - Lyrics

    /// Backend prefixes JioSaavn ids with `jio_`. Songs from JioSaavn have a
    /// chance at having lyrics; YouTube-only songs don't.
    var hasLyrics: Bool { youtubeID.hasPrefix("jio_") }

    /// JioSaavn lyrics_id, extracted from the backend's `jio_<id>` prefix.
    /// Empty for non-JioSaavn tracks.
    var lyricsId: String {
        guard youtubeID.hasPrefix("jio_") else { return "" }
        return String(youtubeID.dropFirst(4))
    }

    // MARK: - View count enrichment

    /// Bare videoId (without `yt_` prefix) for YouTube items. Empty otherwise.
    var youtubeVideoId: String {
        guard youtubeID.hasPrefix("yt_") else { return "" }
        return String(youtubeID.dropFirst(3))
    }

    /// Returns a copy of this Song with `viewCount` set, preserving `id` and
    /// all other fields. Used by Home feed enrichment to fill in view counts
    /// fetched from the InnerTube /player endpoint without breaking
    /// SwiftUI `ForEach` identity.
    func withViewCount(_ v: Int64) -> Song {
        Song(
            id: id,
            title: title,
            artist: artist,
            thumbnailURL: thumbnailURL,
            youtubeID: youtubeID,
            duration: duration,
            isDownloaded: isDownloaded,
            localFileURL: localFileURL,
            addedAt: addedAt,
            viewCount: v
        )
    }
}
