//
//  DownloadedSong.swift
//  Dhunify
//
//  SwiftData model for offline songs. Each record is scoped to a
//  profile ID so different users have independent libraries.
//

import Foundation
import SwiftData

@Model
final class DownloadedSong {
    var songID: String      // jio_XXXXX
    var profileID: String                        // owner profile UUID
    var title: String
    var artist: String
    var artworkURL: String
    var localPath: String                        // relative to Documents
    var duration: TimeInterval
    var fileSizeBytes: Int64
    var downloadedAt: Date

    init(
        songID: String,
        profileID: String,
        title: String,
        artist: String,
        artworkURL: String,
        localPath: String,
        duration: TimeInterval,
        fileSizeBytes: Int64 = 0,
        downloadedAt: Date = Date()
    ) {
        self.songID = songID
        self.profileID = profileID
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.localPath = localPath
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.downloadedAt = downloadedAt
    }

    /// Convert to a playable Song with localFileURL set.
    func toSong() -> Song {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let fullPath = docs?.appendingPathComponent(localPath).absoluteString

        return Song(
            title: title,
            artist: artist,
            thumbnailURL: artworkURL,
            youtubeID: songID,
            duration: duration,
            isDownloaded: true,
            localFileURL: fullPath
        )
    }
}
