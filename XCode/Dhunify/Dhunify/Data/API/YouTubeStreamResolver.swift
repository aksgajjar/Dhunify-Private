//
//  YouTubeStreamResolver.swift
//  Dhunify
//
//  ⚠️ CRITICAL PLAYBACK LOGIC — DO NOT MODIFY WITHOUT REVIEW
//  This HLS-based flow fixes long-track playback issues.
//  Removing or bypassing this will break playback for 20+ min tracks.
//
//  Milestone: HLS_LONG_TRACK_STABLE_V1 (2026-04-17)
//  See memory/hls_long_track_rule.md for the full rationale.
//
//  Client-side YouTube stream-URL extractor. Talks directly to YouTube's
//  InnerTube endpoint using the iOS client context — the same protocol
//  the official YouTube app uses. iOS client responses return audio URLs
//  already signed/unciphered in `streamingData.adaptiveFormats[].url`,
//  so we don't need a signature cipher or nsig decoder on-device.
//
//  Why client-side:
//   * The iPhone's residential IP is never rate-limited by YouTube, so
//     we avoid the Piped/Invidious/yt-dlp failures that plague server
//     resolvers.
//   * Shorter network path (phone → YT vs phone → CF → Fly → Piped → YT)
//     shaves ~500-1000ms off every first play.
//   * Backend stays small and cheap.
//
//  Legitimate use: this is the same API call an iPhone with the YouTube
//  app makes. Dhunify is a personal private-use app — no redistribution,
//  no public endpoints.
//
//  Fallback: on any failure (network, parse, age/region restriction),
//  the caller should use the existing backend /resolve path. This
//  resolver is an opportunistic fast path, not a replacement.
//

import Foundation
import os

enum YouTubeStreamResolverError: LocalizedError {
    case badResponse(Int)
    case playabilityFailed(String)
    case noAudioFormats
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .badResponse(let c): return "InnerTube HTTP \(c)"
        case .playabilityFailed(let r): return "Not playable: \(r)"
        case .noAudioFormats: return "No audio formats returned"
        case .malformedResponse: return "InnerTube response malformed"
        }
    }
}

/// A resolved YouTube audio stream ready to hand to AVPlayer.
struct YouTubeStream {
    let url: URL
    let mimeType: String     // e.g. "audio/mp4" or "audio/webm"
    let bitrate: Int         // bits per second
    let duration: TimeInterval
    let title: String
    /// Optional mp4 fallback. Present when `url` points to a webm/opus
    /// stream (used for long-track size savings); PlayerViewModel will
    /// swap to this URL if AVPlayer can't open the webm within ~3s.
    let fallbackURL: URL?
}

final class YouTubeStreamResolver {

    static let shared = YouTubeStreamResolver()

    private let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "YouTubeStreamResolver")

    private let session: URLSession
    private let decoder = JSONDecoder()

    // InnerTube endpoint. The API key is a public client-type token and
    // has been stable for years.
    private let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    private let innertubeKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    // Short-track chain: IOS (primary) + ANDROID_VR (last-resort).
    // IOS returns URLs signed for general distribution (no `ip=`
    // binding), ANDROID_VR is the fallback whose URLs often carry the
    // server-IP `ip=` param. Sticky reorder applies to this chain.
    private let clientChain: [(name: String, version: String, userAgent: String)] = [
        (
            "IOS",
            "20.14.3",
            "com.google.ios.youtube/20.14.3 (iPhone16,2; U; CPU iOS 18_3_1 like Mac OS X)"
        ),
        (
            "ANDROID_VR",
            "1.60.19",
            "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        ),
    ]

    /// Long-track chain. Prioritizes clients that return
    /// `hlsManifestUrl` (HLS segments are per-chunk signed, so the
    /// IP-bound failure that kills progressive MP4 URLs on 20+ min
    /// tracks doesn't apply). Sticky reorder is intentionally skipped.
    ///
    /// Order:
    ///   1. `IOS_MUSIC` — YouTube Music iOS app. HLS for music
    ///      content, no PO Token grace window (still open), no
    ///      signature cipher in response.
    ///   2. `TVHTML5_SIMPLY_EMBEDDED_PLAYER` — embedded-player
    ///      variant used by yt-dlp to bypass the "Sign in to confirm
    ///      you're not a bot" wall. Requires `thirdParty.embedUrl`.
    ///   3. `IOS` — v20. Backs up the music client for non-music
    ///      long content.
    ///   4. `ANDROID_VR` — absolute last resort. URLs are IP-bound
    ///      on long tracks, but better than hard fail.
    private var longTrackChain: [(name: String, version: String, userAgent: String)] {
        [
            (
                "IOS_MUSIC",
                "7.11.2",
                "com.google.ios.youtubemusic/7.11.2 (iPhone16,2; U; CPU iOS 18_3_1 like Mac OS X)"
            ),
            (
                "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
                "2.0",
                "Mozilla/5.0 (PlayStation; PlayStation 4/12.02) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
            ),
            clientChain[0],  // IOS (v20)
            clientChain[1],  // ANDROID_VR
        ]
    }

    /// Name of the client whose last resolve succeeded. Next resolve
    /// tries this client first so repeated plays avoid wasting a round
    /// trip on the client that previously lost. Process-lifetime only —
    /// we don't persist it because the "right" client drifts with
    /// YouTube-side changes.
    private var lastSuccessfulClient: String?
    private let lastClientLock = NSLock()

    // In-memory LRU: videoId → (stream, expiryDate). YouTube URLs include
    // an `expire=` timestamp; we respect it so we never hand AVPlayer a
    // stale URL that would 403 mid-playback. Only IP-neutral URLs are
    // stored; ANDROID_VR fallbacks that carry `ip=` are excluded because
    // they 403 if the device's egress IP shifts between cache set and
    // play (Wi-Fi ↔ LTE, VPN toggle, etc.).
    private var cache: [String: (YouTubeStream, Date)] = [:]
    private let cacheLock = NSLock()
    private let cacheCap = 50

    // Inflight resolve coalescing: if two callers request the same
    // videoID concurrently (e.g. prefetch fired, then user taps the
    // song before prefetch finishes), both await the same Task instead
    // of firing duplicate InnerTube round trips.
    private var inflight: [String: Task<YouTubeStream, Error>] = [:]
    private let inflightLock = NSLock()

    // visitor_data authorizes InnerTube calls from non-signed-in clients.
    // Post-2024, YouTube rejects raw client calls without it ("Sign in to
    // confirm you're not a bot"). We bootstrap it once per session from
    // a GET of a watch page (YouTube embeds `"visitorData":"..."` in the
    // HTML's ytcfg blob), then reuse for every player request.
    private let visitorStore = VisitorDataStore()

    /// Actor-isolated cache for visitor_data. Using an actor avoids the
    /// `NSLock` async-unavailability compile error in Swift 6 mode while
    /// still coalescing concurrent resolves onto a single fetch.
    private actor VisitorDataStore {
        private var cached: String?
        private var inflight: Task<String?, Never>?

        func get(loader: @Sendable @escaping () async -> String?) async -> String? {
            if let c = cached { return c }
            if let t = inflight { return await t.value }
            let t = Task { await loader() }
            inflight = t
            let v = await t.value
            inflight = nil
            if v != nil { cached = v }
            return v
        }
    }

    private init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Resolve an audio stream for the given 11-char YouTube video ID.
    ///
    /// Strips the `yt_` prefix used by Dhunify internally before calling
    /// the API.
    ///
    /// Two fast paths sit in front of the InnerTube call:
    ///   1. In-memory cache keyed by videoID. Entries carry the URL's
    ///      `expire=` timestamp; we invalidate at (expire - 60s) so a
    ///      URL that's about to expire can't leak into playback.
    ///   2. Inflight coalescing — concurrent callers for the same
    ///      videoID share one Task instead of firing parallel resolves.
    func resolve(videoID rawID: String, expectedDuration: TimeInterval = 0) async throws -> YouTubeStream {
        let id = rawID.hasPrefix("yt_") ? String(rawID.dropFirst(3)) : rawID

        // Fast path 1: cache hit.
        if let cached = cachedStream(for: id) {
            logger.info("⚡️ YT cache hit \(id, privacy: .public) (expires in \(Int(cached.1.timeIntervalSinceNow))s)")
            return cached.0
        }

        // Fast path 2: inflight coalesce. Atomic check-or-create so
        // two callers racing here can't both spawn resolve Tasks.
        let (task, isOwner) = existingOrCreateInflight(for: id) { [weak self] in
            Task<YouTubeStream, Error> {
                guard let self else { throw YouTubeStreamResolverError.malformedResponse }
                return try await self.performResolve(id: id, expectedDuration: expectedDuration)
            }
        }
        if !isOwner {
            logger.info("⚡️ YT resolve coalesced \(id, privacy: .public)")
        }

        do {
            let result = try await task.value
            if isOwner { clearInflight(for: id) }
            return result
        } catch {
            if isOwner { clearInflight(for: id) }
            throw error
        }
    }

    /// Resolve with strict rejection of IP-bound URLs. Used by
    /// PlayerViewModel's stability guard when the primary resolve path
    /// returned a URL carrying an `ip=` query param on a long /
    /// unknown-duration track — those URLs expire the moment the
    /// device's egress IP shifts (Wi-Fi ↔ LTE, VPN toggle), which is
    /// a real failure mode on 15+ min tracks but a non-issue on short
    /// tracks.
    ///
    /// Walks the normal client chain but rejects IP-bound URLs from
    /// every client (not just non-ANDROID_VR). Bypasses the in-memory
    /// cache because the whole point is to get a fresh, stable URL —
    /// the cached entry is presumably the IP-bound one that tripped
    /// the guard. On success the new stable URL IS stored.
    ///
    /// Throws if no client can return a non-IP URL. Caller should keep
    /// the original URL on throw (graceful degradation).
    func resolveStable(videoID rawID: String, expectedDuration: TimeInterval = 0) async throws -> YouTubeStream {
        let id = rawID.hasPrefix("yt_") ? String(rawID.dropFirst(3)) : rawID
        var lastError: Error = YouTubeStreamResolverError.malformedResponse
        let chain = orderedChain(forLongTrack: expectedDuration > 1200)
        for client in chain {
            do {
                logger.info("🧪 DBG stable try client=\(client.name, privacy: .public) for \(id, privacy: .public)")
                let stream = try await fetchStreamUsing(client: client, videoID: id)
                if let ip = ipParam(in: stream.url) {
                    logger.info("🧪 DBG stable client=\(client.name, privacy: .public) returned IP-bound ip=\(ip, privacy: .public) — skipping")
                    lastError = YouTubeStreamResolverError.playabilityFailed("IP-bound from \(client.name)")
                    continue
                }
                logger.info("🧪 DBG stable URL acquired via client=\(client.name, privacy: .public)")
                storeStream(stream, for: id)
                rememberSuccessfulClient(client.name)
                return stream
            } catch {
                logger.info("🧪 DBG stable client=\(client.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Force a fresh resolve, bypassing the in-memory cache. Used by
    /// PlayerViewModel's stall-recovery path when playback stalls
    /// within the first 30s on an IP-bound URL — the likely cause is
    /// an IP change (Wi-Fi ↔ LTE hand-off), so the cached URL is
    /// signed for the wrong IP. Clearing the cache entry + re-resolving
    /// yields a URL signed for the device's CURRENT egress IP, which
    /// is what AVPlayer needs to resume.
    ///
    /// Accepts IP-bound URLs on return (unlike `resolveStable`) — the
    /// new IP-bound URL is valid for as long as the current IP holds,
    /// which is all we need for the rest of this playback session.
    func resolveFresh(videoID rawID: String, expectedDuration: TimeInterval = 0) async throws -> YouTubeStream {
        let id = rawID.hasPrefix("yt_") ? String(rawID.dropFirst(3)) : rawID
        purgeCache(for: id)
        clearInflight(for: id)
        return try await resolve(videoID: id, expectedDuration: expectedDuration)
    }

    private func purgeCache(for id: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: id)
    }

    /// Fire-and-forget prewarm. Safe to call repeatedly — no-ops if
    /// already cached or a resolve for the same videoID is already
    /// in flight. Surfaces no error; prefetch failure has zero impact
    /// on playback.
    func prewarm(videoID rawID: String, expectedDuration: TimeInterval = 0) {
        let id = rawID.hasPrefix("yt_") ? String(rawID.dropFirst(3)) : rawID
        if cachedStream(for: id) != nil { return }
        Task.detached(priority: .utility) { [weak self] in
            _ = try? await self?.resolve(videoID: id, expectedDuration: expectedDuration)
        }
    }

    /// Phase 3 warmup: prime the expensive bits of the resolver
    /// (visitor_data bootstrap, URLSession connection pool) at app
    /// launch so the first real resolve doesn't eat the cold-start
    /// cost. Non-blocking; safe to call multiple times — the visitor
    /// store already coalesces. Failure is silent.
    func warmup() {
        Task.detached(priority: .utility) { [weak self] in
            _ = await self?.fetchVisitorData()
        }
    }

    // MARK: - Resolve core

    private func performResolve(id: String, expectedDuration: TimeInterval) async throws -> YouTubeStream {
        let started = Date()
        let stream = try await fetchStream(videoID: id, expectedDuration: expectedDuration)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        logger.info("🎯 client-resolved \(id, privacy: .public) in \(ms)ms (\(stream.mimeType, privacy: .public), \(stream.bitrate / 1000)kbps)")

        // ───── DEBUG TRACE (STRICT DEBUG MODE) ─────
        let expireTs = parseExpireTimestamp(from: stream.url)
        let nowTs = Date().timeIntervalSince1970
        let secondsUntilExpire = expireTs.map { Int($0 - nowTs) } ?? -1
        let host = stream.url.host ?? "?"
        let urlString = stream.url.absoluteString
        let ipParamValue = ipParam(in: stream.url) ?? "none"
        logger.info("🧪 DBG resolve videoID=\(id, privacy: .public)")
        logger.info("🧪 DBG host=\(host, privacy: .public)")
        logger.info("🧪 DBG urlLen=\(urlString.count)")
        logger.info("🧪 DBG mime=\(stream.mimeType, privacy: .public) bitrate=\(stream.bitrate)")
        logger.info("🧪 DBG duration=\(stream.duration)s title=\(stream.title, privacy: .public)")
        logger.info("🧪 DBG expire=\(expireTs ?? 0) (\(secondsUntilExpire)s from now)")
        logger.info("🧪 DBG ipParam=\(ipParamValue, privacy: .public)")
        logger.info("🧪 DBG FULL_URL=\(urlString, privacy: .public)")
        // ───────────────────────────────────────────

        // Phase 1: cache only IP-neutral URLs. IP-bound URLs (ANDROID_VR
        // fallback path) expire semantically the moment the device's
        // egress IP changes, which we can't detect cheaply.
        if ipParam(in: stream.url) == nil {
            storeStream(stream, for: id)
        } else {
            logger.info("⚡️ YT cache SKIP \(id, privacy: .public) (IP-bound URL)")
        }

        return stream
    }

    // MARK: - Network

    private func fetchStream(videoID id: String, expectedDuration: TimeInterval) async throws -> YouTubeStream {
        // Walk the client chain. First OK response wins. The error from
        // the last client is re-thrown if none succeed.
        var lastError: Error = YouTubeStreamResolverError.malformedResponse
        let chain = orderedChain(forLongTrack: expectedDuration > 1200)
        for client in chain {
            do {
                logger.info("🧪 DBG try client=\(client.name, privacy: .public) for \(id, privacy: .public)")
                let stream = try await fetchStreamUsing(client: client, videoID: id)
                // Reject IP-bound URLs from IOS — IOS normally returns
                // IP-neutral URLs, so ip= present means something is off.
                // ANDROID_VR is the last-resort client and its URLs often
                // carry ip=; accept it there so we never fail when IOS
                // couldn't resolve at all.
                if let ip = ipParam(in: stream.url), client.name != "ANDROID_VR" {
                    logger.info("🧪 DBG client=\(client.name, privacy: .public) returned IP-bound URL ip=\(ip, privacy: .public) — skipping")
                    lastError = YouTubeStreamResolverError.playabilityFailed("IP-bound URL")
                    continue
                }
                if let ip = ipParam(in: stream.url) {
                    logger.info("🧪 DBG ANDROID_VR accepted with ip=\(ip, privacy: .public) (last-resort)")
                }
                rememberSuccessfulClient(client.name)
                return stream
            } catch {
                lastError = error
                if let ytErr = error as? YouTubeStreamResolverError,
                   case .playabilityFailed(let reason) = ytErr {
                    logger.info("🎯 \(client.name, privacy: .public) rejected \(id, privacy: .public): \(reason, privacy: .public) — trying next client")
                    continue
                }
                logger.info("🧪 DBG client=\(client.name, privacy: .public) errored: \(error.localizedDescription, privacy: .public)")
                // Network/parse error — also try next client; might just
                // be a transient edge issue.
                continue
            }
        }
        logger.error("🧪 DBG ALL_CLIENTS_FAILED for \(id, privacy: .public) lastError=\(lastError.localizedDescription, privacy: .public)")
        throw lastError
    }

    /// Returns the client chain with the previously-successful client
    /// moved to the front. First play of the session runs the static
    /// order; subsequent plays skip the rediscovery cost.
    ///
    /// Long-track mode skips the sticky reorder — HLS availability
    /// (which only IOS / TVHTML5 / WEB provide) matters more than a
    /// saved RTT, and ANDROID_VR sticking from a prior short-track
    /// success would starve the HLS path.
    private func orderedChain(forLongTrack: Bool = false) -> [(name: String, version: String, userAgent: String)] {
        if forLongTrack {
            logger.info("🧪 DBG long-track chain order: \(self.longTrackChain.map(\.name).joined(separator: " → "), privacy: .public)")
            return longTrackChain
        }
        lastClientLock.lock()
        let cached = lastSuccessfulClient
        lastClientLock.unlock()
        guard let cached,
              let idx = clientChain.firstIndex(where: { $0.name == cached }),
              idx > 0 else {
            return clientChain
        }
        var reordered = clientChain
        let hit = reordered.remove(at: idx)
        reordered.insert(hit, at: 0)
        logger.info("🧪 DBG chain reordered — trying \(hit.name, privacy: .public) first (last success)")
        return reordered
    }

    private func rememberSuccessfulClient(_ name: String) {
        lastClientLock.lock()
        lastSuccessfulClient = name
        lastClientLock.unlock()
    }

    /// Fetch (and cache) the visitor_data token. Without it, recent
    /// YouTube changes reject unauthenticated InnerTube traffic with
    /// LOGIN_REQUIRED.
    private func fetchVisitorData() async -> String? {
        let session = self.session
        let log = self.logger
        return await visitorStore.get {
            await Self.loadVisitorData(session: session, logger: log)
        }
    }

    private static func loadVisitorData(session: URLSession, logger: Logger) async -> String? {
        // YouTube embeds the visitor_data token in any watch page's
        // ytcfg blob. A lightweight iPhone-UA GET returns the mobile
        // page (follows the m.youtube.com redirect automatically).
        guard let url = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, _) = try await session.data(for: req)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            // Capture everything between `"visitorData":"` and the next `"`.
            let pattern = #""visitorData":"([^"]+)""#
            if let r = html.range(of: pattern, options: .regularExpression) {
                let segment = String(html[r])
                // Strip the wrapper: `"visitorData":"TOKEN"` → `TOKEN`.
                let tokenStart = segment.index(segment.startIndex, offsetBy: 15)
                let tokenEnd = segment.index(before: segment.endIndex)
                if tokenStart < tokenEnd {
                    let token = String(segment[tokenStart..<tokenEnd])
                    logger.info("🎯 visitor_data bootstrapped (\(token.count) chars)")
                    return token
                }
            }
            logger.warning("🎯 visitor_data regex found no match")
            return nil
        } catch {
            logger.info("🎯 visitor_data fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchStreamUsing(
        client: (name: String, version: String, userAgent: String),
        videoID id: String
    ) async throws -> YouTubeStream {
        let visitor = await fetchVisitorData()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(innertubeKey, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        req.setValue(client.name, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")

        var clientCtx: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
            "gl": "IN",
            "utcOffsetMinutes": 330
        ]
        if let visitor = visitor {
            clientCtx["visitorData"] = visitor
            req.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        switch client.name {
        case "ANDROID_VR":
            clientCtx["deviceMake"] = "Oculus"
            clientCtx["deviceModel"] = "Quest 3"
            clientCtx["osName"] = "Android"
            clientCtx["osVersion"] = "12L"
            clientCtx["androidSdkVersion"] = 32
            clientCtx["platform"] = "MOBILE"
        case "IOS":
            clientCtx["deviceMake"] = "Apple"
            clientCtx["deviceModel"] = "iPhone16,2"
            clientCtx["osName"] = "iOS"
            clientCtx["osVersion"] = "18.3.1.22D72"
            clientCtx["platform"] = "MOBILE"
        case "IOS_MUSIC":
            clientCtx["deviceMake"] = "Apple"
            clientCtx["deviceModel"] = "iPhone16,2"
            clientCtx["osName"] = "iOS"
            clientCtx["osVersion"] = "18.3.1.22D72"
            clientCtx["platform"] = "MOBILE"
        case "TVHTML5_SIMPLY_EMBEDDED_PLAYER":
            clientCtx["clientScreen"] = "EMBED"
            clientCtx["platform"] = "TV"
        default:
            break
        }

        // Build `context` as mutable dict so TVHTML5_SIMPLY_EMBEDDED_
        // PLAYER can add the top-level `thirdParty.embedUrl` required
        // to bypass the bot-wall. All other clients get the minimal
        // `{client: ...}` shape unchanged.
        var contextObj: [String: Any] = ["client": clientCtx]
        if client.name == "TVHTML5_SIMPLY_EMBEDDED_PLAYER" {
            contextObj["thirdParty"] = ["embedUrl": "https://www.youtube.com"]
        }

        let body: [String: Any] = [
            "videoId": id,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": contextObj
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeStreamResolverError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw YouTubeStreamResolverError.badResponse(http.statusCode)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeStreamResolverError.malformedResponse
        }

        if let status = root["playabilityStatus"] as? [String: Any],
           let code = status["status"] as? String,
           code != "OK" {
            let reason = (status["reason"] as? String) ?? code
            throw YouTubeStreamResolverError.playabilityFailed(reason)
        }

        guard let streamingData = root["streamingData"] as? [String: Any] else {
            throw YouTubeStreamResolverError.malformedResponse
        }

        // Prefer `adaptiveFormats` (separate audio/video streams) — that's
        // where the pure-audio tracks live. Ignore `formats` (muxed A+V).
        let adaptive = (streamingData["adaptiveFormats"] as? [[String: Any]]) ?? []
        let audioOnly = adaptive.filter {
            ($0["mimeType"] as? String)?.hasPrefix("audio/") == true
        }
        guard !audioOnly.isEmpty else {
            throw YouTubeStreamResolverError.noAudioFormats
        }

        let details = (root["videoDetails"] as? [String: Any]) ?? [:]
        let title = (details["title"] as? String) ?? ""
        let lengthStr = (details["lengthSeconds"] as? String) ?? ""
        let duration = TimeInterval(lengthStr) ?? 0

        // Bitrate strategy — fast start over max quality. Long tracks
        // need a hard cap because AVPlayer's initial buffer scales with
        // bitrate, and >90-minute tracks at high bitrate stall on first
        // seek/buffer-drain.
        //
        //   > 1hr   → target 72kbps, hard cap 80kbps
        //   > 30min → target 96kbps, hard cap 96kbps (strict)
        //   > 15min → target 96kbps, cap 128kbps
        //   normal  → target 128kbps, cap 160kbps
        let targetBitrate: Int
        let maxBitrate: Int
        if duration > 3600 {
            targetBitrate = 72_000
            maxBitrate = 80_000
        } else if duration > 1800 {
            targetBitrate = 96_000
            maxBitrate = 96_000
        } else if duration > 900 {
            targetBitrate = 96_000
            maxBitrate = 128_000
        } else {
            targetBitrate = 128_000
            maxBitrate = 160_000
        }

        // Prefer mp4/m4a (native AVPlayer support), fall back to webm/opus.
        let mp4s = audioOnly.filter { ($0["mimeType"] as? String ?? "").contains("mp4") }
        var pool = mp4s.isEmpty ? audioOnly : mp4s

        func br(_ f: [String: Any]) -> Int { (f["bitrate"] as? Int) ?? 0 }
        func itag(_ f: [String: Any]) -> Int? { f["itag"] as? Int }

        // Long-track HLS path. `streamingData.hlsManifestUrl` is
        // included in IOS / TVHTML5 client responses. HLS segments
        // are short-lived and signed per-segment, which sidesteps
        // the `ip=` binding failure that plagues progressive MP4
        // URLs on 20+ min tracks (CDN rejects the bound IP mid-
        // playback on Wi-Fi↔LTE hand-off, VPN toggle, etc.).
        // ANDROID_VR responses typically lack hlsManifestUrl, so
        // this branch is effectively IOS-only — which is exactly
        // the client we want for stability on long content.
        if duration > 1200,
           let hlsStr = streamingData["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            let hlsIP = ipParam(in: hlsURL) ?? "none"
            logger.info("🎵 HLS long-track pick via client=\(client.name, privacy: .public) host=\(hlsURL.host ?? "?", privacy: .public) duration=\(Int(duration))s ip=\(hlsIP, privacy: .public)")
            return YouTubeStream(
                url: hlsURL,
                mimeType: "application/vnd.apple.mpegurl",
                bitrate: 0,
                duration: duration,
                title: title,
                fallbackURL: nil
            )
        }

        // Long-track fast path (> 1200s = 20min): select m4a by itag,
        // strictly avoiding webm/opus. itag=139 (HE-AAC v1, ~48kbps)
        // has the smallest moov atom and fewest bytes per second, which
        // is what dominates AVPlayer startup on 20-140 min tracks.
        // itag=140 (AAC LC, ~128kbps) is the fallback. Webm/opus is
        // excluded entirely because the webm→mp4 3s watchdog cost
        // exceeds any bitrate win for long content.
        if duration > 1200 {
            let itag139 = audioOnly.first(where: { itag($0) == 139 })
            let itag140 = audioOnly.first(where: { itag($0) == 140 })
            let longPick = itag139 ?? itag140 ?? mp4s.min(by: { br($0) < br($1) })
            if let longPick,
               let urlString = longPick["url"] as? String,
               let url = URL(string: urlString) {
                let pickedItag = itag(longPick) ?? -1
                let mime = (longPick["mimeType"] as? String) ?? "audio/mp4"
                let bitrate = (longPick["bitrate"] as? Int) ?? 0
                logger.info("🧪 DBG long-track pick itag=\(pickedItag) bitrate=\(bitrate / 1000)kbps duration=\(Int(duration))s")
                return YouTubeStream(
                    url: url,
                    mimeType: mime.components(separatedBy: ";").first ?? "audio/mp4",
                    bitrate: bitrate,
                    duration: duration,
                    title: title,
                    // No webm on long-track path → no mp4 fallback
                    // needed. PlayerViewModel's watchdog no-ops when
                    // fallbackURL is nil.
                    fallbackURL: nil
                )
            }
            // Fall through to default selection only if zero m4a
            // present (extremely rare for standard YouTube videos).
            logger.info("🧪 DBG long-track fast-path bailed — no m4a available, using default selection")
        }

        // Legacy long-track fallback for 900-1200s window: if no mp4
        // fits target, switch to webm/opus in the 48-96kbps range.
        // Intentionally NOT applied above 1200s (handled by fast path).
        if duration > 1800, !mp4s.isEmpty {
            let mp4FitsTarget = mp4s.contains { br($0) <= targetBitrate }
            if !mp4FitsTarget {
                let opus = audioOnly.filter {
                    let m = $0["mimeType"] as? String ?? ""
                    return m.contains("webm") || m.contains("opus")
                }
                let opusInRange = opus.filter { br($0) >= 48_000 && br($0) <= 96_000 }
                if !opusInRange.isEmpty {
                    pool = opusInRange
                    logger.info("🧪 DBG long-track fallback → webm/opus pool (\(opusInRange.count) streams, 48-96kbps)")
                } else if !opus.isEmpty {
                    pool = opus
                    logger.info("🧪 DBG long-track fallback → webm/opus pool (\(opus.count) streams, out-of-range)")
                }
            }
        }

        // Hard cap: never exceed maxBitrate. If nothing under cap, take
        // lowest available (safety — should be rare since YouTube always
        // ships low-bitrate audio tracks).
        let underCap = pool.filter { br($0) <= maxBitrate }
        let candidates = underCap.isEmpty ? pool : underCap

        // Pick highest bitrate at-or-below target (closest LOWER). Never
        // overshoot. If no candidate is <= target, take the lowest-bitrate
        // stream remaining (still within cap).
        let atOrBelow = candidates.filter { br($0) <= targetBitrate }
        let picked: [String: Any]?
        if !atOrBelow.isEmpty {
            picked = atOrBelow.max(by: { br($0) < br($1) })
        } else {
            picked = candidates.min(by: { br($0) < br($1) })
        }

        guard let best = picked,
              let urlString = best["url"] as? String,
              let url = URL(string: urlString) else {
            // If the response contains only `signatureCipher` (no direct
            // `url`), the video is protected and we need server-side
            // decoding. Let the caller fall back.
            throw YouTubeStreamResolverError.noAudioFormats
        }

        let mime = (best["mimeType"] as? String) ?? "audio/mp4"
        let bitrate = (best["bitrate"] as? Int) ?? 0
        logger.info("🧪 DBG pickedBitrate=\(bitrate / 1000)kbps target=\(targetBitrate / 1000)kbps cap=\(maxBitrate / 1000)kbps duration=\(Int(duration))s")

        // If picked stream is webm/opus, compute mp4 fallback URL so the
        // player can swap to it if AVPlayer can't decode webm within
        // the watchdog window. Pick the lowest-bitrate m4a track
        // available (itag=139 if present, else itag=140).
        let pickedIsWebm = mime.contains("webm") || mime.contains("opus")
        var fallbackURL: URL? = nil
        if pickedIsWebm, !mp4s.isEmpty {
            let mp4Lowest = mp4s.min(by: { br($0) < br($1) })
            if let fbStr = mp4Lowest?["url"] as? String,
               let fb = URL(string: fbStr) {
                fallbackURL = fb
                logger.info("🧪 DBG mp4 fallback armed (\((mp4Lowest?["bitrate"] as? Int ?? 0) / 1000)kbps)")
            }
        }

        return YouTubeStream(
            url: url,
            mimeType: mime.components(separatedBy: ";").first ?? "audio/mp4",
            bitrate: bitrate,
            duration: duration,
            title: title,
            fallbackURL: fallbackURL
        )
    }

    // MARK: - Cache

    private func cachedStream(for id: String) -> (YouTubeStream, Date)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[id] else { return nil }
        if entry.1 <= Date() {
            cache.removeValue(forKey: id)
            return nil
        }
        return entry
    }

    // MARK: - Inflight coalescing

    private func existingOrCreateInflight(
        for id: String,
        factory: () -> Task<YouTubeStream, Error>
    ) -> (task: Task<YouTubeStream, Error>, isOwner: Bool) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        if let existing = inflight[id] {
            return (existing, false)
        }
        let created = factory()
        inflight[id] = created
        return (created, true)
    }

    private func clearInflight(for id: String) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        inflight.removeValue(forKey: id)
    }

    private func storeStream(_ stream: YouTubeStream, for id: String) {
        // Pull the `expire=` timestamp out of the googlevideo URL; that's
        // YouTube's own truth about how long the URL is valid.
        let expireTs = parseExpireTimestamp(from: stream.url) ?? (Date().timeIntervalSince1970 + 3 * 3600)
        let expiry = Date(timeIntervalSince1970: max(expireTs - 60, Date().timeIntervalSince1970 + 60))

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache.count >= cacheCap {
            // Evict the soonest-to-expire entry. Simpler than LRU and
            // matches the semantics we care about (freshness over recency).
            if let victim = cache.min(by: { $0.value.1 < $1.value.1 })?.key {
                cache.removeValue(forKey: victim)
            }
        }
        cache[id] = (stream, expiry)
    }

    private func ipParam(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "ip" })?
            .value
    }

    private func parseExpireTimestamp(from url: URL) -> TimeInterval? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        for item in items where item.name == "expire" {
            if let v = item.value, let ts = TimeInterval(v) { return ts }
        }
        return nil
    }
}
