//
//  YouTubeSearchManager.swift
//  Dhunify
//
//  Central gate for every YouTube search HTTP call. Exists because the
//  previous direct-from-callsite approach fired unlimited parallel
//  requests (songs+videos filters × rapid typing × multiple surfaces),
//  which produced -1001 timeouts and cascading "cancelled" errors as
//  URLSession ran out of connection budget.
//
//  Responsibilities:
//   • Concurrency cap — never more than `maxConcurrent` HTTPs live.
//   • FIFO queue — overflow waits in order for a free slot.
//   • Dedup — concurrent callers for the same dedup key share one
//     in-flight Task so duplicate typing doesn't double-call YT.
//   • Retry — one retry after 1s on transport or non-200 failure.
//   • Cancel protection — detached internal Task so an outer caller
//     getting cancelled (user kept typing) doesn't kill the HTTP we've
//     already paid a slot for. Cached bytes still populate URLCache
//     so the next callsite returns instantly.
//

import Foundation
import os

actor YouTubeSearchManager {
    static let shared = YouTubeSearchManager()

    private let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "YTSearchManager")

    private let maxConcurrent = 2
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // Per-dedupKey in-flight tasks. Value is a detached Task so outer
    // cancellation doesn't tear down the HTTP work we already started.
    private var inflight: [String: Task<Data?, Never>] = [:]

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 20 * 1024 * 1024,
            directory: nil
        )
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public API

    /// Execute a POST with the given body. Returns Data on 200, nil on
    /// any non-200 or failure (after one retry).
    func execute(
        dedupKey: String,
        url: URL,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) async -> Data? {
        if let existing = inflight[dedupKey] {
            logger.info("🔁 dedup hit \(dedupKey, privacy: .public)")
            return await existing.value
        }

        let task = Task<Data?, Never>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            await self.acquireSlot()
            let data = await self.performWithRetry(
                url: url,
                body: body,
                extraHeaders: extraHeaders,
                dedupKey: dedupKey
            )
            await self.releaseSlot()
            return data
        }
        inflight[dedupKey] = task
        let result = await task.value
        inflight.removeValue(forKey: dedupKey)
        return result
    }

    // MARK: - Request + retry

    private func performWithRetry(
        url: URL,
        body: Data,
        extraHeaders: [String: String],
        dedupKey: String
    ) async -> Data? {
        let maxAttempts = 2
        for attempt in 0..<maxAttempts {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(
                "com.google.ios.youtube/19.09.3 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
                forHTTPHeaderField: "User-Agent"
            )
            for (k, v) in extraHeaders {
                req.setValue(v, forHTTPHeaderField: k)
            }

            do {
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    if attempt > 0 {
                        logger.info("✅ retry succeeded \(dedupKey, privacy: .public)")
                    }
                    return data
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                logger.warning("YT HTTP \(code) attempt=\(attempt) key=\(dedupKey, privacy: .public)")
            } catch {
                let nse = error as NSError
                logger.warning("YT err \(nse.domain)/\(nse.code) attempt=\(attempt) key=\(dedupKey, privacy: .public)")
            }

            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return nil
    }

    // MARK: - Concurrency gate

    private func acquireSlot() async {
        while active >= maxConcurrent {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append(cont)
            }
        }
        active += 1
    }

    private func releaseSlot() {
        active -= 1
        if !waiters.isEmpty {
            let c = waiters.removeFirst()
            c.resume()
        }
    }
}
