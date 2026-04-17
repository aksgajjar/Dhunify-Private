//
//  SearchViewModel.swift
//  Dhunify
//
//  View-model for the Search feature. Supports debounced auto-search
//  (400ms delay after typing stops) and manual search-on-submit.
//

import Foundation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = "" {
        didSet { scheduleAutoSearch() }
    }
    var results: [Song] = []
    var albumResults: [AlbumResult] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var downloadingIDs: Set<String> = []

    var recentSearches: [String] = []

    private let searchSongsUseCase: SearchSongsUseCase
    private let downloadSongUseCase: DownloadSongUseCase
    private var autoSearchTask: Task<Void, Never>?
    private var lastSearchedQuery: String = ""
    private let historyKey = "dhunify.searchHistory"
    private let maxHistory = 10

    init(
        searchSongsUseCase: SearchSongsUseCase,
        downloadSongUseCase: DownloadSongUseCase
    ) {
        self.searchSongsUseCase = searchSongsUseCase
        self.downloadSongUseCase = downloadSongUseCase
        recentSearches = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    // MARK: - Debounced auto-search

    private func scheduleAutoSearch() {
        autoSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            results = []
            albumResults = []
            errorMessage = nil
            isLoading = false
            lastSearchedQuery = ""
            return
        }

        // Don't re-search the same query.
        if trimmed == lastSearchedQuery { return }

        autoSearchTask = Task {
            // 300ms debounce — snappy but not wasteful.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(query: trimmed)
        }
    }

    // MARK: - Manual search (submit button / keyboard return)

    func search() async {
        autoSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await performSearch(query: trimmed)
    }

    // MARK: - Core search logic

    private func performSearch(query: String) async {
        isLoading = true
        errorMessage = nil

        // Translate Hindi / Gujarati / Hinglish to English when an
        // OpenAI key is available. Falls back to the raw query on
        // timeout or if the key is empty.
        let needsTranslation = containsNonEnglish(query) || containsHinglish(query)
        let searchQuery: String
        if needsTranslation, !AppConfig.openAIAPIKey.isEmpty {
            searchQuery = await SearchTranslationService.translateToSearchQuery(query)
        } else {
            searchQuery = query
        }

        // Fire songs + albums in parallel.
        async let songsTask = searchSongsUseCase.execute(query: searchQuery)
        async let albumsTask = Self.fetchAlbums(query: searchQuery)

        do {
            var songs = try await songsTask
            guard !Task.isCancelled else { return }

            // YouTube fallback when JioSaavn returns few results.
            if songs.count < 3 {
                let ytSongs = await searchYouTube(query: searchQuery)
                songs = songs + ytSongs
            }

            // Partial-failure safety: if every backend returned nothing
            // but the UI already has data from a previous query, keep
            // that data on screen rather than flashing an empty state.
            if songs.isEmpty, !results.isEmpty {
                lastSearchedQuery = query
            } else {
                results = songs
                lastSearchedQuery = query
                saveToHistory(query)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            // Don't wipe existing UI data on transient errors. Show an
            // inline message, leave the previous results visible so the
            // user isn't stranded on a blank screen.
            errorMessage = error.localizedDescription
        }

        let albums = await albumsTask
        if !Task.isCancelled {
            albumResults = Self.rankAlbums(albums, against: searchQuery)
        }

        isLoading = false
    }

    // MARK: - Album ranking
    //
    // Normalizes + scores albums against the query so the Album tab
    // behaves like Spotify: exact title wins, then prefix, then contains;
    // albumTitle outranks artistName; non-matches drop out entirely.
    private static func normalize(_ text: String) -> String {
        let lowered = text
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
        let stripped = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " "
        }
        return String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rankAlbums(_ albums: [AlbumResult], against query: String) -> [AlbumResult] {
        let q = normalize(query)
        guard !q.isEmpty else { return albums }

        // Score: title exact 100, title prefix 60, title contains 30,
        //        artist exact 40,  artist prefix 20, artist contains 10.
        // Higher combined score first. Ties broken by songCount desc.
        func score(_ album: AlbumResult) -> Int {
            let t = normalize(album.title)
            let a = normalize(album.artist)
            var s = 0
            if t == q { s += 100 }
            else if t.hasPrefix(q) { s += 60 }
            else if t.contains(q) { s += 30 }
            if a == q { s += 40 }
            else if a.hasPrefix(q) { s += 20 }
            else if a.contains(q) { s += 10 }
            return s
        }

        let scored = albums.map { ($0, score($0)) }.filter { $0.1 > 0 }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.songCount > rhs.0.songCount
            }
            .map { $0.0 }
    }

    // MARK: - Language detection

    private func containsNonEnglish(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Devanagari (Hindi) + Gujarati Unicode blocks.
            (scalar.value >= 0x0900 && scalar.value <= 0x097F) ||
            (scalar.value >= 0x0A80 && scalar.value <= 0x0AFF)
        }
    }

    private func containsHinglish(_ text: String) -> Bool {
        let words = [
            "gaana","gaane","gana","gane","wala","wale",
            "acha","accha","aur","nahi","kuch","koi",
            "dil","pyaar","ishq","yaar","bhai","dost",
            "mast","desi","filmi","sunao","bajao",
            "kem","che","chhe","tamara","mara","mari",
            "garba","dandiya","bhajan","aarti","purane",
            "purana","naya","nayi","waala","waali",
        ]
        let lower = text.lowercased()
        return words.contains { lower.contains($0) }
    }

    // MARK: - YouTube fallback search

    private func searchYouTube(query: String) async -> [Song] {
        let ytURL = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false"
        let payload: [String: Any] = [
            "query": query,
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20260114.08.00",
                    "hl": "en",
                    "gl": "IN",
                ] as [String: String],
            ],
            "params": "EgWKAQIIAQ%3D%3D",
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: ytURL) else { return [] }

        let data = await YouTubeSearchManager.shared.execute(
            dedupKey: "www|\(query)",
            url: url,
            body: bodyData
        )
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var songs: [Song] = []
        let contents = (json["contents"] as? [String: Any])?["twoColumnSearchResultsRenderer"] as? [String: Any]
        let primary = (contents?["primaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any]
        let sections = primary?["contents"] as? [[String: Any]] ?? []

        outer: for section in sections {
            let items = (section["itemSectionRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
            for item in items {
                guard let renderer = item["videoRenderer"] as? [String: Any],
                      let videoId = renderer["videoId"] as? String else { continue }

                let titleRuns = (renderer["title"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                let title = titleRuns.first?["text"] as? String ?? ""
                if title.isEmpty { continue }

                let channelRuns =
                    ((renderer["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]]) ??
                    ((renderer["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
                var artist = channelRuns.first?["text"] as? String ?? "YouTube"
                artist = artist.replacingOccurrences(of: " - Topic", with: "", options: .caseInsensitive)

                let durText = (renderer["lengthText"] as? [String: Any])?["simpleText"] as? String ?? "0:00"
                let parts = durText.split(separator: ":").compactMap { Int($0) }
                var duration = 0
                if parts.count == 2 { duration = parts[0] * 60 + parts[1] }
                if parts.count == 3 { duration = parts[0] * 3600 + parts[1] * 60 + parts[2] }
                if duration < 30 || duration > 900 { continue }

                songs.append(Song(
                    title: title,
                    artist: artist,
                    thumbnailURL: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                    youtubeID: "yt_\(videoId)",
                    duration: TimeInterval(duration)
                ))
                if songs.count >= 8 { break outer }
            }
        }
        return songs
    }

    private static func fetchAlbums(query: String) async -> [AlbumResult] {
        guard var components = URLComponents(string: Config.backendBaseURL) else { return [] }
        components.path = "/search/albums"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([AlbumResult].self, from: data)
        } catch {
            return []
        }
    }

    // MARK: - Download

    func download(song: Song) async {
        guard !downloadingIDs.contains(song.youtubeID) else { return }

        downloadingIDs.insert(song.youtubeID)
        errorMessage = nil
        defer { downloadingIDs.remove(song.youtubeID) }

        do {
            _ = try await downloadSongUseCase.execute(song: song)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Search history

    private func saveToHistory(_ query: String) {
        recentSearches.removeAll { $0.lowercased() == query.lowercased() }
        recentSearches.insert(query, at: 0)
        if recentSearches.count > maxHistory { recentSearches = Array(recentSearches.prefix(maxHistory)) }
        UserDefaults.standard.set(recentSearches, forKey: historyKey)
    }

    func clearHistory() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    func searchFromHistory(_ text: String) {
        query = text
        Task { await search() }
    }

    // MARK: - Pre-warm

    /// Fire a silent search to wake up the backend connection.
    /// Called once from SearchView's .task so the first real search
    /// feels instant.
    func prewarm() async {
        do {
            _ = try await searchSongsUseCase.execute(query: "trending")
        } catch {
            // Silently ignored — this is just a connection warm-up.
        }
    }
}
