//
//  YouTubeSearchClient.swift
//  Dhunify
//
//  Client-side YouTube search. Fires two parallel InnerTube calls:
//    * music.youtube.com (WEB_REMIX) — unfiltered, yields musicShelfRenderer
//      (songs, albums, playlists) via musicResponsiveListItemRenderer.
//    * www.youtube.com (WEB) — yields videoRenderer with viewCount metadata
//      so popular results rank first.
//  Results are merged: videos sorted by view count DESC, then music shelf
//  items in original relevance order. Deduped by videoId, capped at 25.
//
//  Why client-side: iPhone residential IP is never rate-limited by YouTube,
//  round-trip stays ~80ms, and latest releases surface immediately.
//
//  Backend still handles JioSaavn results (geo-restricted API). Merge
//  happens on-device.
//

import Foundation
import os

private let ytSearchLog = Logger(subsystem: "com.diphoria.Dhunify", category: "YTSearch")

final class YouTubeSearchClient {
    static let shared = YouTubeSearchClient()

    private let musicEndpoint = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!
    private let videoEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!
    // Public InnerTube key. Stable since 2019, works for both music and www hosts.
    private let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"

    private init() {}

    /// Fire music + video searches in parallel, merge, sort videos by views,
    /// append music items in relevance order, dedupe by videoId, cap 25.
    func search(_ query: String) async -> [Song] {
        async let music = runMusicSearch(query: query)
        async let videos = runVideoSearch(query: query)
        let (musicItems, videoItems) = await (music, videos)

        let sortedVideos = videoItems
            .sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }

        var seen = Set<String>()
        var merged: [Song] = []
        for s in sortedVideos + musicItems {
            if seen.insert(s.youtubeID).inserted {
                merged.append(s)
                if merged.count >= 25 { break }
            }
        }
        ytSearchLog.info("YT search \"\(query, privacy: .public)\" → \(merged.count) (m=\(musicItems.count) v=\(videoItems.count))")
        return merged
    }

    // MARK: - Music search (WEB_REMIX, unfiltered)

    private func runMusicSearch(query: String) async -> [Song] {
        let body: [String: Any] = [
            "query": query,
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": "1.20240101.01.00",
                    "hl": "en",
                    "gl": "US",
                ]
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return []
        }

        let data = await YouTubeSearchManager.shared.execute(
            dedupKey: "music|\(query)",
            url: musicEndpoint,
            body: bodyData,
            extraHeaders: [
                "X-Goog-Api-Key": apiKey,
                "Origin": "https://music.youtube.com",
                "Referer": "https://music.youtube.com/",
            ]
        )
        guard let data = data else { return [] }
        return parseMusicResponse(data: data)
    }

    // MARK: - Video search (WEB, videoRenderer + viewCount)

    private func runVideoSearch(query: String) async -> [Song] {
        let body: [String: Any] = [
            "query": query,
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
            return []
        }

        let data = await YouTubeSearchManager.shared.execute(
            dedupKey: "video|\(query)",
            url: videoEndpoint,
            body: bodyData,
            extraHeaders: [
                "X-Goog-Api-Key": apiKey,
                "Origin": "https://www.youtube.com",
                "Referer": "https://www.youtube.com/",
            ]
        )
        guard let data = data else { return [] }
        return parseVideoResponse(data: data)
    }

    // MARK: - Music parser

    private func parseMusicResponse(data: Data) -> [Song] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var items: [[String: Any]] = []
        collectMusicItems(from: root, into: &items)

        var out: [Song] = []
        for item in items {
            if let song = songFromMusicItem(item) {
                out.append(song)
            }
        }
        return out
    }

    private func collectMusicItems(from node: Any, into acc: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            if let renderer = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                acc.append(renderer)
                return
            }
            for (_, v) in dict {
                collectMusicItems(from: v, into: &acc)
            }
        } else if let arr = node as? [Any] {
            for v in arr {
                collectMusicItems(from: v, into: &acc)
            }
        }
    }

    private func songFromMusicItem(_ item: [String: Any]) -> Song? {
        guard let flex = item["flexColumns"] as? [[String: Any]],
              flex.count >= 2 else { return nil }

        guard let titleCol = flex[0]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let titleText = titleCol["text"] as? [String: Any],
              let titleRuns = titleText["runs"] as? [[String: Any]],
              let firstRun = titleRuns.first,
              let title = (firstRun["text"] as? String)?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty else { return nil }

        let videoId: String? = {
            if let nav = firstRun["navigationEndpoint"] as? [String: Any],
               let watch = nav["watchEndpoint"] as? [String: Any],
               let v = watch["videoId"] as? String { return v }
            if let pdata = item["playlistItemData"] as? [String: Any],
               let v = pdata["videoId"] as? String { return v }
            return nil
        }()
        guard let vid = videoId, !vid.isEmpty else { return nil }

        guard let subCol = flex[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let subText = subCol["text"] as? [String: Any],
              let subRuns = subText["runs"] as? [[String: Any]] else { return nil }

        let texts = subRuns.compactMap { $0["text"] as? String }
        let artistParts = texts.filter { !$0.contains("•") && !isDurationString($0) }
        let artist = artistParts.first?.trimmingCharacters(in: .whitespaces) ?? "Unknown Artist"
        let duration = texts.last.flatMap(parseDuration) ?? 0

        if duration > 0 && duration < 60 { return nil }

        let thumbnail = extractMusicThumbnail(from: item) ?? "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg"

        return Song(
            title: title,
            artist: artist,
            thumbnailURL: thumbnail,
            youtubeID: "yt_\(vid)",
            duration: TimeInterval(duration)
        )
    }

    private func extractMusicThumbnail(from item: [String: Any]) -> String? {
        guard let thumb = item["thumbnail"] as? [String: Any],
              let inner = thumb["musicThumbnailRenderer"] as? [String: Any],
              let inner2 = inner["thumbnail"] as? [String: Any],
              let thumbs = inner2["thumbnails"] as? [[String: Any]],
              let last = thumbs.last,
              let url = last["url"] as? String else { return nil }
        return url
    }

    // MARK: - Video parser

    private func parseVideoResponse(data: Data) -> [Song] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var renderers: [[String: Any]] = []
        collectVideoRenderers(from: root, into: &renderers)

        var out: [Song] = []
        for r in renderers {
            if let song = videoFromRenderer(r) {
                out.append(song)
            }
        }
        return out
    }

    private func collectVideoRenderers(from node: Any, into acc: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            if let r = dict["videoRenderer"] as? [String: Any] {
                acc.append(r)
                return
            }
            for (_, v) in dict {
                collectVideoRenderers(from: v, into: &acc)
            }
        } else if let arr = node as? [Any] {
            for v in arr {
                collectVideoRenderers(from: v, into: &acc)
            }
        }
    }

    private func videoFromRenderer(_ r: [String: Any]) -> Song? {
        guard let vid = r["videoId"] as? String, !vid.isEmpty else { return nil }

        if isLiveRenderer(r) { return nil }

        // lengthText missing = live or upcoming — skip.
        guard let lengthText = r["lengthText"] as? [String: Any],
              let lengthStr = firstRunText(lengthText),
              let duration = parseDuration(lengthStr) else { return nil }
        if duration < 60 { return nil }

        guard let titleDict = r["title"] as? [String: Any],
              let titleStr = firstRunText(titleDict)?.trimmingCharacters(in: .whitespaces),
              !titleStr.isEmpty else { return nil }

        let artist: String = {
            if let d = r["ownerText"] as? [String: Any], let t = firstRunText(d) { return t }
            if let d = r["longBylineText"] as? [String: Any], let t = firstRunText(d) { return t }
            if let d = r["shortBylineText"] as? [String: Any], let t = firstRunText(d) { return t }
            return "Unknown Artist"
        }()

        let views = parseViews(r)
        let thumbnail = extractVideoThumbnail(r) ?? "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg"

        return Song(
            title: titleStr,
            artist: artist.trimmingCharacters(in: .whitespaces),
            thumbnailURL: thumbnail,
            youtubeID: "yt_\(vid)",
            duration: TimeInterval(duration),
            viewCount: views > 0 ? views : nil
        )
    }

    private func isLiveRenderer(_ r: [String: Any]) -> Bool {
        if let badges = r["badges"] as? [[String: Any]] {
            for b in badges {
                if let br = b["metadataBadgeRenderer"] as? [String: Any] {
                    if let style = br["style"] as? String, style.uppercased().contains("LIVE") { return true }
                    if let label = br["label"] as? String, label.uppercased().contains("LIVE") { return true }
                }
            }
        }
        if let overlays = r["thumbnailOverlays"] as? [[String: Any]] {
            for o in overlays {
                if let tr = o["thumbnailOverlayTimeStatusRenderer"] as? [String: Any],
                   let style = tr["style"] as? String,
                   style.uppercased().contains("LIVE") { return true }
            }
        }
        return false
    }

    private func parseViews(_ r: [String: Any]) -> Int64 {
        if let vc = r["viewCountText"] as? [String: Any] {
            if let s = vc["simpleText"] as? String {
                let digits = s.filter(\.isNumber)
                if let n = Int64(digits), n > 0 { return n }
            }
            if let runs = vc["runs"] as? [[String: Any]],
               let txt = runs.first?["text"] as? String {
                let digits = txt.filter(\.isNumber)
                if let n = Int64(digits), n > 0 { return n }
            }
        }
        if let svc = r["shortViewCountText"] as? [String: Any] {
            if let s = svc["simpleText"] as? String {
                let n = parseShortCount(s); if n > 0 { return n }
            }
            if let runs = svc["runs"] as? [[String: Any]],
               let txt = runs.first?["text"] as? String {
                let n = parseShortCount(txt); if n > 0 { return n }
            }
        }
        return 0
    }

    private func parseShortCount(_ s: String) -> Int64 {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
                       .uppercased()
        let scan = Scanner(string: cleaned)
        guard let num = scan.scanDouble() else { return 0 }
        if cleaned.contains("K") { return Int64(num * 1_000) }
        if cleaned.contains("M") { return Int64(num * 1_000_000) }
        if cleaned.contains("B") { return Int64(num * 1_000_000_000) }
        return Int64(num)
    }

    private func extractVideoThumbnail(_ r: [String: Any]) -> String? {
        guard let thumb = r["thumbnail"] as? [String: Any],
              let thumbs = thumb["thumbnails"] as? [[String: Any]],
              let last = thumbs.last,
              let url = last["url"] as? String else { return nil }
        return url
    }

    // MARK: - Shared helpers

    private func firstRunText(_ dict: [String: Any]) -> String? {
        if let runs = dict["runs"] as? [[String: Any]],
           let t = runs.first?["text"] as? String { return t }
        if let s = dict["simpleText"] as? String { return s }
        return nil
    }

    private func isDurationString(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    private func parseDuration(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard isDurationString(trimmed) else { return nil }
        let parts = trimmed.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}
