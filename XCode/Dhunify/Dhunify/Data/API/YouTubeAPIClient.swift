//
//  YouTubeAPIClient.swift
//  Dhunify
//
//  SongRepository implementation backed by the Dhunify search/download
//  backend. Uses URLSession + async/await; no third-party dependencies.
//

import Foundation

enum NetworkError: LocalizedError {
    case invalidURL
    case badResponse(Int)
    case decodingFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The request URL could not be constructed."
        case .badResponse(let code):
            return "The server returned an unexpected status code (\(code))."
        case .decodingFailed:
            return "The server response could not be decoded."
        case .downloadFailed:
            return "The song could not be downloaded."
        }
    }
}

final class YouTubeAPIClient: SongRepository {
    private let baseURL: URL
    private let session: URLSession
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    init(
        baseURL: URL = URL(string: Config.backendBaseURL) ?? URL(string: "http://localhost:8000")!,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.baseURL = baseURL
        self.session = session
        self.fileManager = fileManager

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - SongRepository

    func search(query: String) async throws -> [Song] {
        // Hybrid search: JioSaavn via backend (geo-restricted, Mumbai IP
        // required) + YouTube Music via direct InnerTube on-device
        // (residential iPhone IP bypasses the rate limiting that affects
        // Fly Mumbai). Merge + score + dedup locally.
        async let jioSongs = fetchJioSaavnOnly(query: query)
        async let ytSongs = YouTubeSearchClient.shared.search(query)

        let (jio, yt) = await (jioSongs, ytSongs)
        return Self.merge(query: query, jio: jio, youtube: yt)
    }

    private func fetchJioSaavnOnly(query: String) async -> [Song] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("search/jio"),
            resolvingAgainstBaseURL: false
        ) else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            try validate(response)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return arr.compactMap(Self.songFromBackendDict)
        } catch {
            return []
        }
    }

    private static func songFromBackendDict(_ dict: [String: Any]) -> Song? {
        guard let title = dict["title"] as? String,
              let artist = dict["artist"] as? String,
              let thumb = dict["thumbnailURL"] as? String,
              let youtubeID = dict["youtubeID"] as? String else { return nil }
        let dur: TimeInterval
        if let d = dict["duration"] as? Double { dur = d }
        else if let d = dict["duration"] as? Int { dur = TimeInterval(d) }
        else { dur = 0 }
        return Song(title: title, artist: artist, thumbnailURL: thumb, youtubeID: youtubeID, duration: dur)
    }

    // MARK: - Merge + score (ported from backend)

    static func merge(query: String, jio: [Song], youtube: [Song]) -> [Song] {
        var scored: [(score: Double, source: Int, idx: Int, song: Song)] = []
        for (i, s) in jio.enumerated() {
            let sc = relevance(query: query, title: s.title, artist: s.artist) + 0.05
            scored.append((sc, 0, i, s))
        }
        for (i, s) in youtube.enumerated() {
            let sc = relevance(query: query, title: s.title, artist: s.artist)
            scored.append((sc, 1, i, s))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.source != b.source { return a.source < b.source }
            return a.idx < b.idx
        }

        let topScore = scored.first?.score ?? 0
        var seen = Set<String>()
        var merged: [Song] = []
        for entry in scored {
            if merged.count >= 30 { break }
            if topScore >= 0.9 && entry.score < 0.2 { continue }
            let key = normKey(title: entry.song.title, artist: entry.song.artist)
            if !key.isEmpty, seen.insert(key).inserted {
                merged.append(entry.song)
            }
        }
        return merged
    }

    private static func relevance(query: String, title: String, artist: String) -> Double {
        let qClean = query.lowercased().trimmingCharacters(in: .whitespaces)
        let qTokens = tokens(qClean).filter { $0.count > 1 }
        guard !qTokens.isEmpty else { return 0 }

        let tl = title.lowercased()
        let al = artist.lowercased()

        var score = 0.0
        for t in qTokens {
            if tl.contains(t) { score += 1.0 }
            else if al.contains(t) { score += 0.3 }
        }
        score /= Double(qTokens.count)

        if qClean.count >= 4, tl.contains(qClean) { score += 0.3 }
        if let first = qTokens.first, tl.hasPrefix(first) { score += 0.1 }

        return min(score, 1.4)
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normKey(title: String, artist: String) -> String {
        let raw = "\(title) \(artist)".lowercased()
        let filtered = raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let str = String(String.UnicodeScalarView(filtered))
        return String(str.prefix(40))
    }

    func download(song: Song) async throws -> URL {
        guard
            var components = URLComponents(url: baseURL.appendingPathComponent("download"), resolvingAgainstBaseURL: false)
        else {
            throw NetworkError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "id", value: song.youtubeID)]

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        let (tempURL, response) = try await session.download(from: url)
        try validate(response)

        let destination = try documentsDirectory()
            .appendingPathComponent("\(song.youtubeID).m4a")

        // Replace any existing file so re-downloads are idempotent.
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.moveItem(at: tempURL, to: destination)
        } catch {
            throw NetworkError.downloadFailed
        }

        return destination
    }

    func delete(song: Song) async throws {
        let fileURL: URL
        if let localFileURL = song.localFileURL, let url = URL(string: localFileURL) {
            fileURL = url
        } else {
            fileURL = try documentsDirectory()
                .appendingPathComponent("\(song.youtubeID).m4a")
        }

        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    // MARK: - Helpers

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.badResponse(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.badResponse(http.statusCode)
        }
    }

    private func documentsDirectory() throws -> URL {
        guard let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NetworkError.downloadFailed
        }
        return url
    }
}

// MARK: - DTO

/// Wire format for `/search` results. Decoupled from the `Song` domain
/// entity so backend field changes don't leak into the domain layer.
private struct SearchResultDTO: Decodable {
    let title: String
    let artist: String
    let thumbnailURL: String
    let youtubeID: String
    let duration: TimeInterval

    func toSong() -> Song {
        Song(
            title: title,
            artist: artist,
            thumbnailURL: thumbnailURL,
            youtubeID: youtubeID,
            duration: duration
        )
    }
}
