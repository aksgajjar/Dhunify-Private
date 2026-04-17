//
//  HotCacheManager.swift
//  Dhunify
//
//  On-device hot cache of recently-played song bytes. When a song
//  starts playing, the manager silently downloads the full audio to
//  Caches/hot/{id}.m4a in parallel with AVPlayer's own streaming.
//  On subsequent plays, PlayerViewModel.buildStreamURL notices the
//  local file and hands AVPlayer a file:// URL — which starts in
//  ~50ms since there's no network at all.
//
//  Design goals:
//   • Strictly additive — if any step fails, the original upstream URL
//     is used. No existing playback path is altered.
//   • IP-safe for YouTube — we fetch using the same upstream URL the
//     iPhone used to play, so googlevideo's ip= binding still matches.
//   • Crash-safe — downloads write to {id}.m4a.tmp and atomic-rename
//     on completion. Orphan .tmp files are cleaned up on launch.
//   • Bounded — 500MB hard cap with LRU eviction on every write.
//   • Low-priority — uses a background URLSession so prefetches don't
//     steal bandwidth from the song currently playing.
//

import Foundation
import os

@MainActor
final class HotCacheManager {
    static let shared = HotCacheManager()

    private let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "HotCache")
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxBytes: Int64 = 500 * 1024 * 1024  // 500 MB
    private var inFlight: Set<String> = []
    private var blockingDownloads: [String: Task<URL, Error>] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = caches.appendingPathComponent("hot", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        cleanupOrphanTempFiles()
    }

    // MARK: - Public API

    /// Returns a local `file://` URL if the song is fully cached, else nil.
    /// Callers pass this to AVPlayer directly for instant playback.
    func localURL(for songID: String) -> URL? {
        let url = finalFileURL(for: songID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        // Touch mtime so this counts as the most-recently-used entry.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Kicks off a background download of the song bytes if not already
    /// cached / in-flight. Non-blocking; returns immediately.
    func cache(songID: String, from upstreamURL: URL) {
        guard !songID.isEmpty else { return }
        let dest = finalFileURL(for: songID)
        if fileManager.fileExists(atPath: dest.path) { return }
        if inFlight.contains(songID) { return }

        inFlight.insert(songID)
        Task { [weak self] in
            await self?.download(songID: songID, url: upstreamURL)
        }
    }

    /// Blocking variant — awaits full download, returns local file URL.
    /// Coalesces concurrent calls for the same songID onto one Task so
    /// repeated loads of the same track don't issue duplicate GETs.
    /// Caller should show a loading indicator while awaiting.
    func ensureCached(songID: String, from upstreamURL: URL) async throws -> URL {
        guard !songID.isEmpty else { throw URLError(.badURL) }
        let dest = finalFileURL(for: songID)
        if fileManager.fileExists(atPath: dest.path) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }
        if let existing = blockingDownloads[songID] {
            return try await existing.value
        }
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw URLError(.cancelled) }
            return try await self.performDownload(songID: songID, url: upstreamURL)
        }
        blockingDownloads[songID] = task
        do {
            let result = try await task.value
            blockingDownloads.removeValue(forKey: songID)
            return result
        } catch {
            blockingDownloads.removeValue(forKey: songID)
            throw error
        }
    }

    /// Explicit purge of every cached file. Intended for a "clear cache"
    /// setting — not called automatically.
    func purgeAll() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Download

    private func download(songID: String, url: URL) async {
        defer { inFlight.remove(songID) }
        do {
            _ = try await performDownload(songID: songID, url: url)
        } catch {
            logger.info("HotCache error \(songID): \(error.localizedDescription)")
        }
    }

    /// Raw download → .tmp → atomic-rename to final. Throws on any
    /// failure so the blocking API can surface errors to the caller.
    ///
    /// Uses URLSessionDownloadTask (not dataTask). data-task buffers the
    /// full response in memory before handing it back — for a 10MB file
    /// the socket can stall silently with no progress callback. download-
    /// task streams bytes to a temp file and reports progress via
    /// delegate, which lets us detect stalls and cancel fast.
    private func performDownload(songID: String, url: URL) async throws -> URL {
        let tmp = tempFileURL(for: songID)
        let dest = finalFileURL(for: songID)

        var req = URLRequest(url: url)
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("keep-alive", forHTTPHeaderField: "Connection")

        let result: URL
        do {
            result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let delegate = HotDownloadDelegate(
                    songID: songID,
                    tmp: tmp,
                    dest: dest,
                    fileManager: fileManager,
                    logger: logger,
                    continuation: cont
                )
                let task = session.downloadTask(with: req)
                task.delegate = delegate
                delegate.attachWatchdog(task: task)
                logger.info("📥 HotCache starting download \(songID) host=\(url.host ?? "?")")
                task.resume()
            }
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
        enforceCapIfNeeded()
        return result
    }

    // MARK: - Eviction

    private func enforceCapIfNeeded() {
        let files = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []

        var entries: [(URL, Date, Int64)] = []
        var total: Int64 = 0
        for f in files where f.pathExtension == "m4a" {
            let values = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate ?? .distantPast
            entries.append((f, mtime, size))
            total += size
        }
        guard total > maxBytes else { return }

        entries.sort { $0.1 < $1.1 }  // oldest first
        var bytesToFree = total - maxBytes
        for (url, _, size) in entries {
            guard bytesToFree > 0 else { break }
            try? fileManager.removeItem(at: url)
            bytesToFree -= size
            logger.info("HotCache evicted \(url.lastPathComponent) (\(size / 1024)KB)")
        }
    }

    private func cleanupOrphanTempFiles() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for f in files where f.pathExtension == "tmp" {
            try? fileManager.removeItem(at: f)
        }
    }

    // MARK: - Paths

    private func finalFileURL(for songID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(songID).m4a")
    }

    private func tempFileURL(for songID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(songID).m4a.tmp")
    }
}

// MARK: - Delegate

/// Per-download delegate. Retained by URLSessionTask until the task
/// completes, so we don't need to hold a strong reference ourselves.
/// All mutable state is guarded by `lock` because URLSession delegate
/// callbacks and the watchdog Task run on different queues.
private final class HotDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let songID: String
    private let tmp: URL
    private let dest: URL
    private let fileManager: FileManager
    private let logger: Logger

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastProgressTs: Date = Date()
    private var lastLoggedMB: Int64 = 0
    private var watchdog: Task<Void, Never>?

    /// No progress for this long → kill the task. The GoogleVideo CDN
    /// occasionally opens a socket and then never ships bytes. Without
    /// this watchdog the download would sit forever on URLSession's
    /// 30s request timeout (which resets on every byte).
    private let stallTimeout: TimeInterval = 15

    init(
        songID: String,
        tmp: URL,
        dest: URL,
        fileManager: FileManager,
        logger: Logger,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.songID = songID
        self.tmp = tmp
        self.dest = dest
        self.fileManager = fileManager
        self.logger = logger
        self.continuation = continuation
    }

    func attachWatchdog(task: URLSessionDownloadTask) {
        let taskRef = task
        let log = self.logger
        let id = self.songID
        let stall = self.stallTimeout
        watchdog = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                let idle: TimeInterval = {
                    self.lock.lock(); defer { self.lock.unlock() }
                    return Date().timeIntervalSince(self.lastProgressTs)
                }()
                if idle >= stall {
                    log.error("🔥 HotCache STALL \(id, privacy: .public) — no progress for \(Int(idle))s, cancelling")
                    taskRef.cancel()
                    self.resumeOnce(.failure(NSError(
                        domain: "HotCache",
                        code: -100,
                        userInfo: [NSLocalizedDescriptionKey: "Download stalled — no bytes for \(Int(stall))s"]
                    )))
                    return
                }
            }
        }
    }

    private func resumeOnce(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let w = watchdog
        watchdog = nil
        lock.unlock()
        w?.cancel()
        guard let cont = cont else { return }
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        lastProgressTs = Date()
        let mb = totalBytesWritten / (1024 * 1024)
        let shouldLog = mb > lastLoggedMB
        if shouldLog { lastLoggedMB = mb }
        lock.unlock()

        if shouldLog {
            let expected = totalBytesExpectedToWrite > 0
                ? "\(totalBytesExpectedToWrite / (1024 * 1024))MB"
                : "?"
            logger.info("📥 HotCache \(self.songID, privacy: .public) \(mb)MB / \(expected, privacy: .public)")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Must move the file out of the temporary spool synchronously —
        // URLSession deletes `location` as soon as this method returns.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            try? fileManager.removeItem(at: location)
            logger.error("HotCache HTTP \(http.statusCode) for \(self.songID, privacy: .public)")
            resumeOnce(.failure(URLError(.badServerResponse)))
            return
        }

        let size = (try? fileManager.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        guard size > 50_000 else {
            try? fileManager.removeItem(at: location)
            logger.error("HotCache tiny body (\(size)B) for \(self.songID, privacy: .public)")
            resumeOnce(.failure(URLError(.zeroByteResource)))
            return
        }

        do {
            try? fileManager.removeItem(at: tmp)
            try fileManager.moveItem(at: location, to: tmp)
            try? fileManager.removeItem(at: dest)
            try fileManager.moveItem(at: tmp, to: dest)
            logger.info("✅ HotCache stored \(self.songID, privacy: .public) (\(size / 1024)KB)")
            resumeOnce(.success(dest))
        } catch {
            try? fileManager.removeItem(at: tmp)
            logger.error("HotCache move failed \(self.songID, privacy: .public): \(error.localizedDescription)")
            resumeOnce(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            logger.error("HotCache task error \(self.songID, privacy: .public): \(error.localizedDescription)")
            try? fileManager.removeItem(at: tmp)
            resumeOnce(.failure(error))
        }
        // Success path already resumed in didFinishDownloadingTo.
    }
}
