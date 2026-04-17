//
//  YouTubeSearchClient.swift
//  Dhunify
//
//  Client-side YouTube Music search. Hits YouTube Music's InnerTube
//  search endpoint directly from the iPhone using the WEB_REMIX client
//  context (same context the YT Music web app uses), which returns a
//  clean catalog of songs + videos with artist/duration metadata.
//
//  Why client-side:
//   * The iPhone's residential IP is never rate-limited by YouTube, so
//     we avoid the ytmusicapi/Innertube failures the Fly Mumbai IP hits.
//   * Latest releases show up immediately — server-side ytmusicapi
//     often misses freshly-released tracks for days because the
//     "songs" filter lags the "videos" filter by a few weeks.
//   * Round-trip stays phone → YT (~80ms) instead of phone → Fly Mumbai → YT.
//
//  Backend is still used for JioSaavn results (geo-restricted API that
//  requires an Indian IP). Merge is done on-device.
//

import Foundation
import os

private let ytSearchLog = Logger(subsystem: "com.diphoria.Dhunify", category: "YTSearch")

final class YouTubeSearchClient {
    static let shared = YouTubeSearchClient()

    private let endpoint = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!
    // Public InnerTube key for music.youtube.com. Stable since 2019.
    private let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    // "Songs + videos" filter params — returns both named tracks and
    // uploaded music videos, which together cover latest releases that
    // the "songs" catalog hasn't ingested yet.
    private let songsFilter = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
    private let videosFilter = "EgWKAQIQAWoKEAkQBRAKEAMQBA%3D%3D"

    private init() {}

    /// Fire songs + videos filters in parallel, merge by videoId, cap to 20.
    func search(_ query: String) async -> [Song] {
        async let songs = runSearch(query: query, params: songsFilter)
        async let videos = runSearch(query: query, params: videosFilter)
        let (sResult, vResult) = await (songs, videos)

        var seen = Set<String>()
        var merged: [Song] = []
        for s in sResult + vResult {
            let id = s.youtubeID
            if seen.insert(id).inserted {
                merged.append(s)
                if merged.count >= 20 { break }
            }
        }
        ytSearchLog.info("YT search \"\(query, privacy: .public)\" → \(merged.count) (s=\(sResult.count) v=\(vResult.count))")
        return merged
    }

    private func runSearch(query: String, params: String) async -> [Song] {
        let body: [String: Any] = [
            "query": query,
            "params": params,
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
            dedupKey: "music|\(query)|\(params)",
            url: endpoint,
            body: bodyData,
            extraHeaders: [
                "X-Goog-Api-Key": apiKey,
                "Origin": "https://music.youtube.com",
                "Referer": "https://music.youtube.com/",
            ]
        )
        guard let data = data else { return [] }
        return parseSearchResponse(data: data)
    }

    // MARK: - Parser

    private func parseSearchResponse(data: Data) -> [Song] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }

        // contents.tabbedSearchResultsRenderer.tabs[0].tabRenderer.content.
        //   sectionListRenderer.contents[].musicShelfRenderer.contents[].
        //     musicResponsiveListItemRenderer
        var items: [[String: Any]] = []
        collectMusicItems(from: root, into: &items)

        var out: [Song] = []
        for item in items {
            if let song = songFromItem(item) {
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

    private func songFromItem(_ item: [String: Any]) -> Song? {
        guard let flex = item["flexColumns"] as? [[String: Any]],
              flex.count >= 2 else { return nil }

        // Column 0: title + watchEndpoint (videoId)
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

        // Column 1: subtitle — artist • album • duration (runs, separators interleaved)
        guard let subCol = flex[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let subText = subCol["text"] as? [String: Any],
              let subRuns = subText["runs"] as? [[String: Any]] else { return nil }

        let texts = subRuns.compactMap { $0["text"] as? String }
        let artistParts = texts.filter { !$0.contains("•") && !isDurationString($0) }
        let artist = artistParts.first?.trimmingCharacters(in: .whitespaces) ?? "Unknown Artist"
        let duration = texts.last.flatMap(parseDuration) ?? 0

        // Skip likely non-music results (very short clips / very long compilations).
        if duration > 0 && (duration < 30 || duration > 900) { return nil }

        // Thumbnail: prefer highest-res.
        let thumbnail = extractThumbnail(from: item) ?? "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg"

        return Song(
            title: title,
            artist: artist,
            thumbnailURL: thumbnail,
            youtubeID: "yt_\(vid)",
            duration: TimeInterval(duration)
        )
    }

    private func extractThumbnail(from item: [String: Any]) -> String? {
        guard let thumb = item["thumbnail"] as? [String: Any],
              let inner = thumb["musicThumbnailRenderer"] as? [String: Any],
              let inner2 = inner["thumbnail"] as? [String: Any],
              let thumbs = inner2["thumbnails"] as? [[String: Any]],
              let last = thumbs.last,
              let url = last["url"] as? String else { return nil }
        return url
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
