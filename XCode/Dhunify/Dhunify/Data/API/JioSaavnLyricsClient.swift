//
//  JioSaavnLyricsClient.swift
//  Dhunify
//
//  Fetches song lyrics from JioSaavn's public API. The response contains
//  HTML-escaped text with <br> line breaks which we normalize into plain
//  UTF-8 with \n separators before handing to the UI.
//

import Foundation

enum JioSaavnLyricsClient {

    /// Returns cleaned-up plain-text lyrics, or an empty string if the
    /// track doesn't have lyrics on JioSaavn.
    static func fetchLyrics(lyricsId: String, session: URLSession = .shared) async throws -> String {
        guard !lyricsId.isEmpty else { return "" }

        var components = URLComponents(string: "https://www.jiosaavn.com/api.php")
        components?.queryItems = [
            URLQueryItem(name: "__call",       value: "lyrics.getLyrics"),
            URLQueryItem(name: "lyrics_id",    value: lyricsId),
            URLQueryItem(name: "_format",      value: "json"),
            URLQueryItem(name: "_marker",      value: "0"),
            URLQueryItem(name: "api_version",  value: "4"),
            URLQueryItem(name: "ctx",          value: "web6dot0"),
        ]
        guard let url = components?.url else { return "" }

        var request = URLRequest(url: url)
        // JioSaavn's public endpoint is picky about Referer/UA; without
        // these it sometimes returns an error blob instead of lyrics.
        request.setValue("https://www.jiosaavn.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return ""
        }

        // JioSaavn occasionally wraps the JSON in a JS callback. Strip
        // anything outside the outer {...} before decoding.
        guard let raw = extractJSONObject(from: data) else { return "" }
        let lyrics = raw["lyrics"] as? String ?? ""
        return cleanLyrics(lyrics)
    }

    // MARK: - Private helpers

    private static func extractJSONObject(from data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end   = text.lastIndex(of: "}") else { return nil }
        let sliced = text[start...end]
        guard let subData = sliced.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: subData) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func cleanLyrics(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }

        // Replace <br> tags with newlines; accept variations like <br/>, <br />.
        var text = raw.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: .regularExpression
        )

        // Strip any remaining HTML tags.
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Unescape the common HTML entities JioSaavn emits.
        let entities: [(String, String)] = [
            ("&amp;",  "&"),
            ("&quot;", "\""),
            ("&#39;",  "'"),
            ("&apos;", "'"),
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Collapse any 3+ consecutive newlines into a single blank line.
        text = text.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
