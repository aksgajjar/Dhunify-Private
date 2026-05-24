//
//  SimilarTrackProvider.swift
//  Dhunify
//
//  Produces a batch of "similar" tracks for queue refill. v1 strategy:
//  artist-anchored search + optional mood-flavored search, merged,
//  language-filtered, and sampled to the configured language ratio.
//
//  Cached per-anchor for 1 hour to avoid hammering the search backend
//  when the user replays the same track or the queue refills several
//  times around the same anchor.
//
//  v2 plug point: replace the search step in `fetchCandidates` with
//  YouTube InnerTube WATCH_NEXT for true algorithmic similarity. The
//  public surface stays the same.
//

import Foundation

@MainActor
final class SimilarTrackProvider {

    static let shared = SimilarTrackProvider()

    private struct CachedBatch {
        let songs: [Song]
        let timestamp: Date
    }

    private var cache: [String: CachedBatch] = [:]
    private let cacheTTL: TimeInterval = 3600 // 1 hour
    private var inFlight: Set<String> = []

    private init() {}

    /// Returns up to `batchSize` tracks similar to `current`. Filters
    /// out the anchor itself and any IDs already present in `excludingIDs`
    /// so the caller (refill coordinator) doesn't re-queue duplicates.
    /// Mood, when supplied, biases one of the queries toward the user's
    /// theme (e.g. "love", "party") so refill stays on theme.
    func similarTracks(
        for current: Song,
        mood: String?,
        excludingIDs: Set<String> = [],
        batchSize: Int = 20
    ) async -> [Song] {
        let key = current.youtubeID

        if let cached = cache[key],
           Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return sample(from: cached.songs.filter { !excludingIDs.contains($0.youtubeID) },
                          batchSize: batchSize)
        }

        // Single-flight: if a refill is already fetching for this anchor,
        // bail. The original caller will populate the cache and the next
        // near-end fire will pick it up.
        if inFlight.contains(key) { return [] }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let candidates = await fetchCandidates(for: current, mood: mood)
        let filtered = candidates
            .filter { $0.youtubeID != current.youtubeID }
            .filter { !excludingIDs.contains($0.youtubeID) }
            .filter { !LanguagePreference.isBlocked(LanguageClassifier.classify(song: $0)) }

        // Dedupe by youtubeID, preserve order so artist-anchored hits
        // surface before mood-flavored fillers.
        var seen: Set<String> = []
        let deduped = filtered.filter { seen.insert($0.youtubeID).inserted }

        cache[key] = CachedBatch(songs: deduped, timestamp: Date())
        return sample(from: deduped, batchSize: batchSize)
    }

    // MARK: - Candidate sourcing

    private func fetchCandidates(for current: Song, mood: String?) async -> [Song] {
        let useCase = AppContainer.shared.searchSongsUseCase

        var queries: [String] = []
        let artist = current.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty {
            queries.append("\(artist) hits")
        } else {
            queries.append("\(current.title) similar")
        }
        if let mood, !mood.isEmpty,
           !mood.lowercased().contains(artist.lowercased()) {
            queries.append("\(mood) songs")
        }

        var collected: [Song] = []
        for q in queries {
            do {
                let results = try await useCase.execute(query: q)
                collected.append(contentsOf: results)
            } catch {
                // One failed query shouldn't blank the batch.
                continue
            }
        }
        return collected
    }

    // MARK: - Language sampling

    /// Picks `batchSize` songs split by the configured ratio. Falls
    /// back to Hindi (or `.unknown`) when Gujarati supply is thin —
    /// never fills with blocked languages.
    private func sample(from pool: [Song], batchSize: Int) -> [Song] {
        guard !pool.isEmpty, batchSize > 0 else { return [] }

        var hindi: [Song] = []
        var gujarati: [Song] = []
        var unknown: [Song] = []
        for song in pool {
            switch LanguageClassifier.classify(song: song) {
            case .hindi: hindi.append(song)
            case .gujarati: gujarati.append(song)
            case .unknown: unknown.append(song)
            case .english: continue   // belt-and-braces; already filtered
            }
        }

        let split = LanguagePreference.split(batchSize: batchSize)
        var result: [Song] = []

        let gujaratiPicked = Array(gujarati.prefix(split.gujarati))
        result.append(contentsOf: gujaratiPicked)

        let hindiPicked = Array(hindi.prefix(split.hindi))
        result.append(contentsOf: hindiPicked)

        // Fill any shortfall with unknown then remaining Hindi/Gujarati.
        if result.count < batchSize {
            let need = batchSize - result.count
            let chosen: Set<String> = Set(result.map { $0.youtubeID })
            let remainder = (unknown + hindi.dropFirst(hindiPicked.count) + gujarati.dropFirst(gujaratiPicked.count))
                .filter { !chosen.contains($0.youtubeID) }
                .prefix(need)
            result.append(contentsOf: remainder)
        }

        return result
    }
}
