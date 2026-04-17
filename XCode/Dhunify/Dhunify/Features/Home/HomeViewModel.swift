//
//  HomeViewModel.swift
//  Dhunify
//
//  Home screen data — loads curated sections by searching the JioSaavn
//  backend in parallel. All song IDs are live jio_ IDs, not hardcoded.
//

import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "Home")

// MARK: - Models

struct HomeSection: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let query: String
    var songs: [Song] = []
    var isLoading: Bool = true
}

struct MoodItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let icon: String
    let searchQuery: String
    let color: String
}

struct GenreItem: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let searchQuery: String
}

struct ArtistItem: Identifiable {
    let id = UUID()
    let name: String
    let searchQuery: String
    let initial: String
}

struct FeaturedMashup: Identifiable {
    /// YouTube video id — used for thumbnail URL and `youtube://` deep link.
    let id: String
    let title: String
    let duration: String
    let mood: String
}

struct HomeAlbumSection: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let query: String
    var albums: [AlbumResult] = []
    var isLoading: Bool = true
}

// MARK: - ViewModel

@MainActor
@Observable
final class HomeViewModel {
    var sections: [HomeSection] = []
    var albumSections: [HomeAlbumSection] = []
    var forYouSongs: [Song] = []
    var moods: [MoodItem] = []
    var genres: [GenreItem] = []
    var topArtists: [ArtistItem] = []
    var isLoading: Bool = true

    // MARK: - Aaj Ka Mix (AI playlist generator)

    var aajKaMixSongs: [Song] = []
    var aajKaMixLoading: Bool = false
    var aajKaMixError: Bool = false
    var showAajKaMixInput: Bool = false
    var aajKaMixPrompt: String = ""

    // MARK: - Occasion (calendar-based)

    var occasionSongs: [Song] = []
    var occasionLoading: Bool = false
    var currentOccasion: OccasionEngine.Occasion? = nil

    // MARK: - Mood detection (time-of-day)

    var moodSuggestion: MoodDetectionEngine.MoodSuggestion? = nil
    var moodSongs: [Song] = []
    var moodLoading: Bool = false

    // MARK: - Latest songs (multi-source /latest endpoint)

    var latestHindi: [Song] = []
    var latestGujarati: [Song] = []
    var latestHindiLoading = false
    var latestGujaratiLoading = false

    // MARK: - Featured Mashups (long-play YouTube links)

    /// Curated long-form YouTube mashup set. Tapping one hands off to
    /// the YouTube app (or Safari fallback); these are not streamed
    /// through the Dhunify playback pipeline.
    let featuredMashups: [FeaturedMashup] = [
        FeaturedMashup(id: "pgpCsZroa3g", title: "Bollywood Mashup 2025",      duration: "1h+", mood: "Party"),
        FeaturedMashup(id: "HX9Sjdy-giw", title: "Non-Stop Hindi Hits",        duration: "1h+", mood: "Hits"),
        FeaturedMashup(id: "JbFd9S3NpdY", title: "Romantic Mashup Collection", duration: "1h+", mood: "Romantic"),
        FeaturedMashup(id: "95HD3Cpkr1k", title: "Party Bollywood Mix",        duration: "1h+", mood: "Dance"),
        FeaturedMashup(id: "I4YdWlsiTyk", title: "Bollywood Nonstop 2025",     duration: "1h+", mood: "Chill"),
        FeaturedMashup(id: "K5hFQtkCUtM", title: "Hindi Hits Jukebox",         duration: "1h+", mood: "Jukebox"),
        FeaturedMashup(id: "vXh1W8GuApw", title: "Best of Bollywood Mix",      duration: "1h+", mood: "Mix"),
    ]

    private let searchUseCase: SearchSongsUseCase
    private static let refreshKey = "dhunify.home.lastRefresh"
    private static let refreshInterval: TimeInterval = 12 * 3600 // 12 hours

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = ProfileManager.shared.currentProfile?.name ?? "there"
        switch hour {
        case 5..<12: return "Good Morning, \(name)"
        case 12..<17: return "Good Afternoon, \(name)"
        case 17..<21: return "Good Evening, \(name)"
        default: return "Good Night, \(name)"
        }
    }

    /// True if data needs refresh (first load or >12h since last).
    var needsRefresh: Bool {
        let last = UserDefaults.standard.double(forKey: Self.refreshKey)
        if last == 0 { return true }
        return Date().timeIntervalSince1970 - last >= Self.refreshInterval
    }

    init(searchUseCase: SearchSongsUseCase) {
        self.searchUseCase = searchUseCase
        moods = Self.curatedMoods
        genres = Self.curatedGenres
        topArtists = Self.curatedArtists

        sections = Self.sectionDefinitions.map {
            HomeSection(title: $0.title, icon: $0.icon, query: $0.query)
        }
        albumSections = Self.albumDefs.map {
            HomeAlbumSection(title: $0.title, icon: $0.icon, query: $0.query)
        }

        // Stale-while-revalidate: paint UI from disk cache instantly
        // so the user never stares at skeleton loaders on cold launch.
        // The cache is written on every successful loadAll().
        if let cached = Self.loadDiskCache() {
            for (i, def) in Self.sectionDefinitions.enumerated() {
                if let hit = cached.sections[def.title] {
                    sections[i].songs = hit
                    sections[i].isLoading = false
                }
            }
            for (i, def) in Self.albumDefs.enumerated() {
                if let hit = cached.albums[def.title] {
                    albumSections[i].albums = hit
                    albumSections[i].isLoading = false
                }
            }
            forYouSongs = cached.forYou
            isLoading = false
        }
    }

    // MARK: - Disk cache (stale-while-revalidate)

    private struct DiskCache: Codable {
        var sections: [String: [Song]]
        var albums: [String: [AlbumResult]]
        var forYou: [Song]
    }

    private static var cacheURL: URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return dir?.appendingPathComponent("home_cache.json")
    }

    private static func loadDiskCache() -> DiskCache? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiskCache.self, from: data)
    }

    private func writeDiskCache() {
        var cache = DiskCache(sections: [:], albums: [:], forYou: forYouSongs)
        for s in sections where !s.songs.isEmpty {
            cache.sections[s.title] = s.songs
        }
        for a in albumSections where !a.albums.isEmpty {
            cache.albums[a.title] = a.albums
        }
        guard let url = Self.cacheURL,
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Load all sections in parallel

    func loadAll() async {
        // Skip if data is fresh (loaded <12h ago) and sections have songs.
        let hasSongs = sections.contains { !$0.songs.isEmpty }
        if hasSongs && !needsRefresh { return }

        // Reset sections to loading state for refresh.
        for i in sections.indices {
            sections[i].songs = []
            sections[i].isLoading = true
        }
        for i in albumSections.indices {
            albumSections[i].albums = []
            albumSections[i].isLoading = true
        }

        isLoading = true

        logger.info("🏠 Loading \(self.sections.count) sections...")

        // Fire all searches in parallel.
        // Index 0 = "Trending Now" uses /trending endpoint for fresh charts.
        await withTaskGroup(of: (Int, [Song]).self) { group in
            for (index, section) in sections.enumerated() {
                group.addTask { [searchUseCase] in
                    if index == 0 {
                        // Use dedicated trending endpoint for freshest songs.
                        let trending = await Self.fetchTrending()
                        if !trending.isEmpty { return (index, trending) }
                    }
                    do {
                        let songs = try await searchUseCase.execute(query: section.query)
                        return (index, songs)
                    } catch {
                        logger.warning("🏠 Section '\(section.title)' failed: \(error.localizedDescription)")
                        return (index, [])
                    }
                }
            }

            for await (index, songs) in group {
                if sections.indices.contains(index) {
                    sections[index].songs = songs
                    sections[index].isLoading = false
                    logger.info("🏠 '\(self.sections[index].title)' → \(songs.count) songs")
                }
            }
        }

        // Load album sections in parallel too.
        await withTaskGroup(of: (Int, [AlbumResult]).self) { group in
            for (index, section) in albumSections.enumerated() {
                group.addTask {
                    await Self.fetchAlbums(query: section.query, index: index)
                }
            }
            for await (index, albums) in group {
                if albumSections.indices.contains(index) {
                    albumSections[index].albums = albums
                    albumSections[index].isLoading = false
                }
            }
        }

        // Load "For You" from onboarding picks.
        await loadForYou()

        // Occasion + mood sections populate in parallel.
        await loadOccasionAndMood()

        // Multi-source latest (JioSaavn → YouTube waterfall).
        await loadLatestSections()

        isLoading = false
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.refreshKey)
        writeDiskCache()
        logger.info("🏠 All sections loaded — next refresh in 12h")
    }

    /// Force refresh — called by pull-to-refresh or manually.
    func forceRefresh() async {
        UserDefaults.standard.set(0, forKey: Self.refreshKey)
        await loadAll()
    }

    /// Fetch trending/charts from the dedicated /trending endpoint.
    private static func fetchTrending() async -> [Song] {
        guard var components = URLComponents(string: Config.backendBaseURL) else { return [] }
        components.path = "/trending"
        components.queryItems = [URLQueryItem(name: "lang", value: "hindi")]
        guard let url = components.url else { return [] }
        do {
            struct SongDTO: Decodable {
                let title: String; let artist: String; let thumbnailURL: String
                let youtubeID: String; let duration: TimeInterval
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            let dtos = try JSONDecoder().decode([SongDTO].self, from: data)
            return dtos.map {
                Song(title: $0.title, artist: $0.artist, thumbnailURL: $0.thumbnailURL,
                     youtubeID: $0.youtubeID, duration: $0.duration)
            }
        } catch {
            return []
        }
    }

    private static func fetchAlbums(query: String, index: Int) async -> (Int, [AlbumResult]) {
        guard var components = URLComponents(string: Config.backendBaseURL) else { return (index, []) }
        components.path = "/search/albums"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return (index, []) }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let albums = try JSONDecoder().decode([AlbumResult].self, from: data)
            return (index, albums)
        } catch {
            return (index, [])
        }
    }

    /// Build "For You" from onboarding favorites + recent plays.
    private func loadForYou() async {
        let picks = OnboardingView.favoritePicks
        let recentArtists = RecentlyPlayedManager.shared.songs.prefix(5).map { $0.artist }
        let queries = Set(picks + recentArtists)

        guard !queries.isEmpty else { return }

        var mixed: [Song] = []
        // Fetch 5 songs per pick in parallel, then shuffle-mix.
        await withTaskGroup(of: [Song].self) { group in
            for q in queries.prefix(4) {
                group.addTask { [searchUseCase] in
                    (try? await searchUseCase.execute(query: "\(q) songs")) ?? []
                }
            }
            for await songs in group {
                mixed.append(contentsOf: songs.prefix(5))
            }
        }
        // Deduplicate and shuffle.
        var seen = Set<String>()
        forYouSongs = mixed.filter { seen.insert($0.youtubeID).inserted }.shuffled()
        logger.info("🏠 For You → \(self.forYouSongs.count) songs")
    }

    func searchMood(_ mood: MoodItem) async -> [Song] {
        do {
            return try await searchUseCase.execute(query: mood.searchQuery)
        } catch {
            return []
        }
    }

    func searchArtist(_ artist: ArtistItem) async -> [Song] {
        do {
            return try await searchUseCase.execute(query: artist.searchQuery)
        } catch {
            return []
        }
    }

    // MARK: - Latest songs fetcher

    private func fetchLatestSongs(lang: String) async -> [Song] {
        guard var components = URLComponents(string: Config.backendBaseURL) else { return [] }
        components.path = "/latest"
        components.queryItems = [URLQueryItem(name: "lang", value: lang)]
        guard let url = components.url else { return [] }
        do {
            struct DTO: Decodable {
                let title: String; let artist: String; let thumbnailURL: String
                let youtubeID: String; let duration: TimeInterval
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            let dtos = try JSONDecoder().decode([DTO].self, from: data)
            return dtos.map {
                Song(title: $0.title, artist: $0.artist, thumbnailURL: $0.thumbnailURL,
                     youtubeID: $0.youtubeID, duration: $0.duration)
            }
        } catch {
            return []
        }
    }

    func loadLatestSections() async {
        latestHindiLoading = true
        latestGujaratiLoading = true

        async let hindi = fetchLatestSongs(lang: "hindi")
        async let gujarati = fetchLatestSongs(lang: "gujarati")

        latestHindi = await hindi
        latestGujarati = await gujarati
        latestHindiLoading = false
        latestGujaratiLoading = false
    }

    // MARK: - Occasion + Mood detection

    /// Populates `currentOccasion` + `moodSuggestion` sections in parallel.
    /// Safe to call repeatedly — re-runs the time-of-day heuristic and
    /// refreshes the song lists.
    func loadOccasionAndMood() async {
        let useCase = searchUseCase

        if let occasion = OccasionEngine.currentOccasion() {
            currentOccasion = occasion
            occasionLoading = true
            var songs: [Song] = []
            var seen = Set<String>()
            await withTaskGroup(of: [Song].self) { group in
                for query in occasion.queries.prefix(4) {
                    group.addTask {
                        (try? await useCase.execute(query: query)) ?? []
                    }
                }
                for await result in group {
                    for song in result.prefix(4) {
                        if seen.insert(song.youtubeID).inserted {
                            songs.append(song)
                        }
                    }
                }
            }
            occasionSongs = Array(songs.shuffled().prefix(20))
            occasionLoading = false
        }

        let hour = Calendar.current.component(.hour, from: Date())
        let weekday = Calendar.current.component(.weekday, from: Date())
        let isWeekend = weekday == 1 || weekday == 7
        let suggestion = MoodDetectionEngine.suggestion(hour: hour, isWeekend: isWeekend)
        moodSuggestion = suggestion
        moodLoading = true
        var mSongs: [Song] = []
        var mSeen = Set<String>()
        await withTaskGroup(of: [Song].self) { group in
            for query in suggestion.queries.prefix(4) {
                group.addTask {
                    (try? await useCase.execute(query: query)) ?? []
                }
            }
            for await result in group {
                for song in result.prefix(4) {
                    if mSeen.insert(song.youtubeID).inserted {
                        mSongs.append(song)
                    }
                }
            }
        }
        moodSongs = Array(mSongs.shuffled().prefix(20))
        moodLoading = false
    }

    // MARK: - Aaj Ka Mix

    /// Calls Claude to turn `aajKaMixPrompt` into a 6-query plan, then
    /// fans out to the search backend in parallel, dedupes, shuffles, and
    /// surfaces up to 20 songs for the hero playlist card.
    func generateAajKaMix() async {
        let trimmed = aajKaMixPrompt.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        aajKaMixLoading = true
        aajKaMixError = false
        aajKaMixSongs = []
        showAajKaMixInput = false

        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        switch hour {
        case 5..<12:  timeOfDay = "morning"
        case 12..<17: timeOfDay = "afternoon"
        case 17..<21: timeOfDay = "evening"
        default:      timeOfDay = "night"
        }

        let recentTitles = RecentlyPlayedManager.shared.songs.prefix(3).map { $0.title }

        do {
            let queries = try await ClaudePlaylistService.generateSearchQueries(
                prompt: trimmed,
                timeOfDay: timeOfDay,
                recentSongs: Array(recentTitles)
            )

            let useCase = searchUseCase
            var allSongs: [Song] = []
            var seenIDs = Set<String>()

            await withTaskGroup(of: [Song].self) { group in
                for query in queries.prefix(5) {
                    group.addTask {
                        let results = try? await useCase.execute(query: query)
                        return Array((results ?? []).prefix(3))
                    }
                }
                for await songs in group {
                    for song in songs {
                        if seenIDs.insert(song.youtubeID).inserted {
                            allSongs.append(song)
                        }
                    }
                }
            }

            aajKaMixSongs = Array(allSongs.shuffled().prefix(20))
            if aajKaMixSongs.isEmpty { aajKaMixError = true }
        } catch {
            aajKaMixError = true
        }

        aajKaMixLoading = false
    }

    // MARK: - Section definitions (queries, not data)

    private struct SectionDef {
        let title: String
        let icon: String
        let query: String
    }

    private static let sectionDefinitions: [SectionDef] = [
        SectionDef(title: "Trending Now", icon: "chart.line.uptrend.xyaxis", query: "new hindi songs today 2026"),
        SectionDef(title: "Latest Hits", icon: "flame.fill", query: "latest bollywood hits 2026"),
        SectionDef(title: "Arijit Singh", icon: "music.mic", query: "Arijit Singh new songs 2026"),
        SectionDef(title: "Romantic Hits", icon: "heart.fill", query: "romantic hindi songs latest"),
        SectionDef(title: "Party Hits", icon: "party.popper.fill", query: "party bollywood songs 2026"),
        SectionDef(title: "Old is Gold", icon: "clock.arrow.circlepath", query: "old hindi classic songs"),
        SectionDef(title: "Lofi Chill", icon: "moon.stars.fill", query: "lofi hindi chill"),
        SectionDef(title: "Long Drive", icon: "car.fill", query: "long drive hindi songs"),
        SectionDef(title: "Trending Gujarati", icon: "chart.line.uptrend.xyaxis", query: "trending gujarati songs 2026"),
        SectionDef(title: "Naya Gujarati", icon: "sparkles", query: "latest new gujarati songs 2026"),
        SectionDef(title: "Gujarati Hits", icon: "music.note.list", query: "new gujarati songs 2026"),
        SectionDef(title: "Garba / Navratri", icon: "figure.dance", query: "garba navratri dandiya"),
    ]

    private static let albumDefs: [SectionDef] = [
        SectionDef(title: "Top Albums", icon: "square.stack.fill", query: "hindi hit albums 2025"),
        SectionDef(title: "Long Drive Albums", icon: "car.fill", query: "long drive hindi album"),
        SectionDef(title: "Arijit Singh Albums", icon: "music.mic", query: "arijit singh album"),
        SectionDef(title: "Romantic Albums", icon: "heart.fill", query: "romantic bollywood album"),
    ]

    // MARK: - Static curated data (no API needed)

    static let curatedMoods: [MoodItem] = [
        MoodItem(name: "Happy", icon: "face.smiling.fill", searchQuery: "happy hindi songs", color: "#FFD93D"),
        MoodItem(name: "Sad", icon: "cloud.rain.fill", searchQuery: "sad hindi songs", color: "#1E3A8A"),
        MoodItem(name: "Energy", icon: "bolt.fill", searchQuery: "high energy bollywood workout", color: "#FF6B6B"),
        MoodItem(name: "Chill", icon: "leaf.fill", searchQuery: "chill lofi hindi", color: "#54A0FF"),
        MoodItem(name: "Romance", icon: "heart.fill", searchQuery: "romantic hindi songs", color: "#FF78C4"),
        MoodItem(name: "Garba", icon: "figure.dance", searchQuery: "garba dandiya navratri songs", color: "#FB8C00"),
    ]

    static let curatedGenres: [GenreItem] = [
        GenreItem(name: "Bollywood", icon: "film.fill", searchQuery: "bollywood songs"),
        GenreItem(name: "Pop", icon: "star.fill", searchQuery: "hindi pop songs"),
        GenreItem(name: "Hip-Hop", icon: "beats.headphones", searchQuery: "desi hip hop"),
        GenreItem(name: "Lofi", icon: "moon.stars.fill", searchQuery: "lofi hindi"),
        GenreItem(name: "Punjabi", icon: "music.mic", searchQuery: "punjabi songs"),
        GenreItem(name: "Sufi", icon: "wind", searchQuery: "sufi songs hindi"),
        GenreItem(name: "Classical", icon: "tuningfork", searchQuery: "indian classical music"),
        GenreItem(name: "Indie", icon: "guitars.fill", searchQuery: "indie hindi songs"),
    ]

    static let curatedArtists: [ArtistItem] = [
        ArtistItem(name: "Arijit Singh", searchQuery: "Arijit Singh songs", initial: "A"),
        ArtistItem(name: "AR Rahman", searchQuery: "AR Rahman songs", initial: "AR"),
        ArtistItem(name: "Shreya Ghoshal", searchQuery: "Shreya Ghoshal songs", initial: "S"),
        ArtistItem(name: "Atif Aslam", searchQuery: "Atif Aslam songs", initial: "AT"),
        ArtistItem(name: "Pritam", searchQuery: "Pritam songs", initial: "P"),
        ArtistItem(name: "Neha Kakkar", searchQuery: "Neha Kakkar songs", initial: "N"),
        ArtistItem(name: "Darshan Raval", searchQuery: "Darshan Raval songs", initial: "DR"),
        ArtistItem(name: "Kinjal Dave", searchQuery: "Kinjal Dave gujarati songs", initial: "KD"),
    ]
}
