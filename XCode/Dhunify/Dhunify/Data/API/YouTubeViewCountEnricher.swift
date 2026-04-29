//
//  YouTubeViewCountEnricher.swift
//  Dhunify
//
//  Enriches YouTube-source Songs with `viewCount` populated from the
//  InnerTube /player endpoint. Used by Home screen feeds that come from
//  backend endpoints (e.g. /trending, /latest) where view counts are not
//  carried in the payload.
//
//  Design:
//  * In-memory cache with 6h TTL keyed by videoId. Avoids refetching on
//    re-renders and across Home feed reloads within the same session.
//  * Bounded concurrency (8 parallel /player fetches) via a semaphore-
//    style iterator so we never fan out hundreds of calls at once.
//  * Caller decides which slice to enrich (spec: top 8–10 visible items
//    per section) — the enricher itself does not impose a slice size.
//  * Hard fail-quiet: any /player failure returns nil for that id; the
//    caller keeps the existing Song unchanged (duration-only UI).
//
//  Does NOT touch playback, resolver, HLS, or search logic.
//

import Foundation
import os

private let enricherLog = Logger(subsystem: "com.diphoria.Dhunify", category: "YTEnrich")

/// Shared in-memory view-count cache + /player fetcher.
actor YouTubeViewCountEnricher {
    static let shared = YouTubeViewCountEnricher()

    private struct CacheEntry {
        let viewCount: Int64
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private static let ttl: TimeInterval = 6 * 3600 // 6h per spec
    private static let maxConcurrent = 8

    // Public InnerTube key for www.youtube.com. Same key as search.
    private let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

    private init() {}

    /// Look up a cached view count without triggering network work.
    /// Returns nil when absent or expired.
    func cached(_ videoId: String) -> Int64? {
        guard let entry = cache[videoId] else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) > Self.ttl {
            cache.removeValue(forKey: videoId)
            return nil
        }
        return entry.viewCount
    }

    /// Fetch view counts for the given videoIds. Cached hits resolve
    /// instantly. Cache-miss ids fan out to /player with bounded parallelism.
    /// Returns a map `[videoId: viewCount]`; missing ids = fetch failed.
    func fetchViewCounts(videoIds: [String]) async -> [String: Int64] {
        guard !videoIds.isEmpty else { return [:] }

        // Dedupe + partition into cache hits and misses.
        let unique = Array(Set(videoIds))
        var result: [String: Int64] = [:]
        var toFetch: [String] = []
        for id in unique {
            if let hit = cached(id) {
                result[id] = hit
            } else {
                toFetch.append(id)
            }
        }
        guard !toFetch.isEmpty else { return result }

        // Bounded-concurrency task group. At most `maxConcurrent` in flight.
        let fetched: [(String, Int64?)] = await withTaskGroup(
            of: (String, Int64?).self
        ) { group in
            var inFlight = 0
            var idx = 0
            var collected: [(String, Int64?)] = []

            while idx < toFetch.count || inFlight > 0 {
                while inFlight < Self.maxConcurrent, idx < toFetch.count {
                    let vid = toFetch[idx]
                    idx += 1
                    inFlight += 1
                    group.addTask { [weak self] in
                        let n = await self?.fetchOne(videoId: vid)
                        return (vid, n)
                    }
                }
                if let next = await group.next() {
                    inFlight -= 1
                    collected.append(next)
                }
            }
            return collected
        }

        for (id, maybe) in fetched {
            if let v = maybe, v > 0 {
                cache[id] = CacheEntry(viewCount: v, fetchedAt: Date())
                result[id] = v
            }
        }
        return result
    }

    // MARK: - /player fetch

    private func fetchOne(videoId: String) async -> Int64? {
        let body: [String: Any] = [
            "videoId": videoId,
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20240101.00.00",
                    "hl": "en",
                    "gl": "US",
                ]
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 6

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let details = root["videoDetails"] as? [String: Any],
               let s = details["viewCount"] as? String,
               let n = Int64(s), n > 0 {
                return n
            }
            if let micro = root["microformat"] as? [String: Any],
               let mr = micro["playerMicroformatRenderer"] as? [String: Any],
               let s = mr["viewCount"] as? String,
               let n = Int64(s), n > 0 {
                return n
            }
            return nil
        } catch {
            enricherLog.debug("player fetch failed for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
