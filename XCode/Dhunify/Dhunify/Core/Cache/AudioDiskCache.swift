//
//  AudioDiskCache.swift
//  Dhunify
//
//  L2 disk cache for previously-streamed audio. Sits in
//  `Library/Caches/audio/` so iOS may purge it under storage pressure
//  without affecting the user's permanent downloads (which live in
//  Documents/Downloads via DownloadManager).
//
//  Two-purpose cache:
//    1. Replay path — when the user re-plays a song that's been heard
//       before, AVPlayer gets a local file URL and starts instantly
//       with zero network.
//    2. Pre-download path — when the player is on Wi-Fi and the
//       current track is past 50%, the next-track URL is downloaded
//       here so an advance during a dead zone still plays.
//
//  LRU eviction keyed by `songID` (raw, prefix-included). Capacity is
//  configurable; default 200 MB chosen to hold ~50 songs at typical
//  64-128 kbps audio while staying small enough that iOS purges are
//  rare in normal use.
//

import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "AudioDiskCache")

actor AudioDiskCache {
    static let shared = AudioDiskCache()

    /// Hard cap on total cache size. iOS may evict from `Caches/`
    /// independently of this — this is just our self-imposed budget.
    private let capacityBytes: Int64 = 200 * 1024 * 1024

    /// UserDefaults key for the LRU map `[songID: lastAccessEpoch]`.
    private let lruKey = "dhunify.audioDiskCache.lru.v1"

    /// In-memory mirror of the LRU map. Hydrated on first access,
    /// flushed back to UserDefaults after every mutation.
    private var lru: [String: TimeInterval]?
    private var hydrated = false

    /// In-flight downloads keyed by songID — coalesces concurrent
    /// `store(...)` calls for the same song so we never fire two
    /// downloads in parallel for one ID.
    private var inflight: [String: Task<URL?, Never>] = [:]

    private init() {}

    // MARK: - Public API

    /// Returns a local file URL for `songID` if one exists on disk.
    /// Touches the LRU access timestamp so eviction prefers truly
    /// stale entries. Nil when there's no cache file.
    func cachedFileURL(for songID: String) -> URL? {
        let url = fileURL(for: songID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        bumpAccess(songID)
        return url
    }

    /// Downloads bytes from `sourceURL` into the cache under `songID`.
    /// Coalesces if a download for the same songID is already in
    /// flight. Returns the local file URL on success, nil on failure
    /// (caller should fall back to the network URL).
    func store(songID: String, sourceURL: URL) async -> URL? {
        if let existing = cachedFileURL(for: songID) {
            return existing
        }
        if let task = inflight[songID] {
            return await task.value
        }
        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.performStore(songID: songID, sourceURL: sourceURL)
        }
        inflight[songID] = task
        let result = await task.value
        inflight[songID] = nil
        return result
    }

    /// Drops the cached file for `songID` and the LRU entry. No-op if
    /// nothing is stored.
    func remove(songID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: songID))
        var map = hydratedLRU()
        map.removeValue(forKey: songID)
        lru = map
        flushLRU()
    }

    /// Clears the entire cache. Used by Settings → "Clear Cache".
    func clearAll() {
        let dir = cacheDirectory()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lru = [:]
        flushLRU()
    }

    /// Total bytes currently on disk (approximate — sum of file sizes).
    func currentSize() -> Int64 {
        let dir = cacheDirectory()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return urls.reduce(into: Int64(0)) { acc, u in
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            acc += Int64(size)
        }
    }

    // MARK: - Internals

    private func performStore(songID: String, sourceURL: URL) async -> URL? {
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
            if let http = response as? HTTPURLResponse,
               !(200..<400).contains(http.statusCode) {
                logger.warning("L2 download bad status \(http.statusCode) for \(songID, privacy: .public)")
                return nil
            }
            let dest = fileURL(for: songID)
            ensureCacheDirectory()
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            bumpAccess(songID)
            evictIfOverCap()
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            logger.info("L2 stored \(songID, privacy: .public) (\(size / 1024) KB)")
            return dest
        } catch {
            logger.warning("L2 store failed for \(songID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func evictIfOverCap() {
        var size = currentSize()
        guard size > capacityBytes else { return }
        var map = hydratedLRU()
        // Sort oldest first.
        let ordered = map.sorted { $0.value < $1.value }
        for (id, _) in ordered {
            if size <= capacityBytes { break }
            let url = fileURL(for: id)
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try? FileManager.default.removeItem(at: url)
            size -= Int64(fileSize)
            map.removeValue(forKey: id)
            logger.info("L2 evicted \(id, privacy: .public) to reclaim \(fileSize / 1024) KB")
        }
        lru = map
        flushLRU()
    }

    private func bumpAccess(_ songID: String) {
        var map = hydratedLRU()
        map[songID] = Date().timeIntervalSince1970
        lru = map
        flushLRU()
    }

    // MARK: - Paths

    private func cacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("audio", isDirectory: true)
    }

    private func ensureCacheDirectory() {
        let dir = cacheDirectory()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func fileURL(for songID: String) -> URL {
        // Sanitize: songID may contain `yt_` / `jio_` prefixes — keep
        // them so different sources never alias to the same file.
        let safe = songID.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory().appendingPathComponent("\(safe).m4a")
    }

    // MARK: - LRU persistence

    private func hydratedLRU() -> [String: TimeInterval] {
        if let cached = lru { return cached }
        let map = (UserDefaults.standard.dictionary(forKey: lruKey)
            as? [String: TimeInterval]) ?? [:]
        lru = map
        hydrated = true
        return map
    }

    private func flushLRU() {
        UserDefaults.standard.set(lru ?? [:], forKey: lruKey)
    }
}
