//
//  DownloadManager.swift
//  Dhunify
//
//  Downloads songs from the VPS stream endpoint, saves to disk,
//  and records metadata in SwiftData. All per-profile.
//

import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "Download")

@MainActor
@Observable
final class DownloadManager {
    /// Song IDs currently being downloaded.
    var activeDownloads: Set<String> = []
    /// Download progress per song ID (0.0 – 1.0).
    var progress: [String: Double] = [:]
    /// Bumped on every successful insert/delete so observers (CarPlay
    /// Downloads tab) can refresh without polling. Counter only — observers
    /// re-call fetchDownloaded() when this changes.
    private(set) var downloadedVersion: Int = 0

    private let modelContainer: ModelContainer
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Check if downloaded

    func isDownloaded(_ songID: String) -> Bool {
        let profileID = ProfileManager.shared.currentProfile?.id.uuidString ?? ""
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<DownloadedSong>(
            predicate: #Predicate { $0.songID == songID && $0.profileID == profileID }
        )
        return (try? context.fetchCount(descriptor)) ?? 0 > 0
    }

    // MARK: - Download

    func download(song: Song) {
        let songID = song.youtubeID
        guard !activeDownloads.contains(songID) else { return }
        guard !isDownloaded(songID) else { return }

        activeDownloads.insert(songID)
        progress[songID] = 0

        downloadTasks[songID] = Task {
            await performDownload(song: song)
        }
    }

    private func performDownload(song: Song) async {
        let songID = song.youtubeID
        defer {
            activeDownloads.remove(songID)
            progress.removeValue(forKey: songID)
            downloadTasks.removeValue(forKey: songID)
        }

        guard let profileID = ProfileManager.shared.currentProfile?.id.uuidString else {
            logger.warning("⬇️ No profile selected — skipping download")
            return
        }

        // Build stream URL.
        guard var components = URLComponents(string: Config.backendBaseURL) else { return }
        components.path = "/stream"
        components.queryItems = [URLQueryItem(name: "id", value: songID)]
        guard let streamURL = components.url else { return }

        logger.info("⬇️ Starting download: \(song.title)")

        do {
            // Follow the 302 redirect to get the CDN URL.
            let (tempURL, response) = try await URLSession.shared.download(from: streamURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<400).contains(httpResponse.statusCode) else {
                logger.warning("⬇️ Bad response for \(songID)")
                return
            }

            // Move to profile's download directory.
            let downloadsDir = ProfileManager.shared.downloadsDirectory()
            let ext = "m4a"
            let cleanID = songID
                .replacingOccurrences(of: "jio_", with: "")
                .replacingOccurrences(of: "yt_", with: "")
            let fileName = "\(cleanID).\(ext)"
            let destURL = downloadsDir.appendingPathComponent(fileName)

            // Remove existing file if any.
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0

            // Store relative path from Documents.
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            let relativePath: String
            if let docsURL {
                relativePath = destURL.path.replacingOccurrences(of: docsURL.path + "/", with: "")
            } else {
                relativePath = fileName
            }

            // Save to SwiftData — check for existing record first.
            let context = ModelContext(modelContainer)
            let existingDescriptor = FetchDescriptor<DownloadedSong>(
                predicate: #Predicate { $0.songID == songID && $0.profileID == profileID }
            )
            if let _ = try? context.fetch(existingDescriptor).first {
                logger.info("⬇️ Already exists in DB, skipping insert")
                return
            }
            let record = DownloadedSong(
                songID: songID,
                profileID: profileID,
                title: song.title,
                artist: song.artist,
                artworkURL: song.thumbnailURL,
                localPath: relativePath,
                duration: song.duration,
                fileSizeBytes: fileSize
            )
            context.insert(record)
            try context.save()
            downloadedVersion &+= 1

            logger.info("⬇️ Downloaded: \(song.title) (\(fileSize / 1024)KB)")

        } catch {
            logger.error("⬇️ Download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch downloaded songs for current profile

    func fetchDownloaded() -> [DownloadedSong] {
        let profileID = ProfileManager.shared.currentProfile?.id.uuidString ?? ""
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<DownloadedSong>(
            predicate: #Predicate { $0.profileID == profileID },
            sortBy: [SortDescriptor(\.downloadedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Delete

    func deleteSong(_ downloaded: DownloadedSong) {
        // Delete file.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs {
            let filePath = docs.appendingPathComponent(downloaded.localPath)
            try? FileManager.default.removeItem(at: filePath)
        }

        // Delete record.
        let context = ModelContext(modelContainer)
        let songID = downloaded.songID
        let descriptor = FetchDescriptor<DownloadedSong>(
            predicate: #Predicate { $0.songID == songID }
        )
        if let record = try? context.fetch(descriptor).first {
            context.delete(record)
            try? context.save()
            downloadedVersion &+= 1
        }

        logger.info("🗑️ Deleted: \(downloaded.title)")
    }

    // MARK: - Clear all downloads for current profile

    func clearAll() {
        let downloaded = fetchDownloaded()
        for d in downloaded {
            deleteSong(d)
        }
        logger.info("🗑️ Cleared all downloads")
    }

    // MARK: - Storage stats

    func storageStats() -> (count: Int, bytes: Int64) {
        let downloaded = fetchDownloaded()
        let total = downloaded.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        return (downloaded.count, total)
    }
}
