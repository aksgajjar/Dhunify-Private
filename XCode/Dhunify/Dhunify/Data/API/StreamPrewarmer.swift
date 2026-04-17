//
//  StreamPrewarmer.swift
//  Dhunify
//
//  Opportunistically opens a TCP/TLS connection to the /stream CDN for
//  songs the user is likely to tap next (rows appearing on-screen). The
//  actual audio stream isn't downloaded — we just want URLSession to
//  keep the connection warm so the eventual resolveRedirect() call in
//  PlayerViewModel resolves in milliseconds instead of ~2s.
//
//  Concurrency is capped at 3 in-flight prewarms to avoid saturating
//  the backend or the device's radio. Requests beyond the cap are
//  dropped (they are purely best-effort).
//

import Foundation

@MainActor
final class StreamPrewarmer {
    static let shared = StreamPrewarmer()

    private var inFlight: Set<String> = []
    private var warmed: Set<String> = []
    private let maxConcurrent = 3

    private init() {}

    /// Fires a lightweight GET (zero-byte Range) against /stream for the
    /// given song so the CDN redirect is pre-resolved and the connection
    /// is pooled by URLSession.shared.
    ///
    /// - Returns immediately. No-op if the song is already warmed or the
    ///   in-flight cap has been reached.
    func prewarm(youtubeID: String) {
        guard !warmed.contains(youtubeID),
              !inFlight.contains(youtubeID),
              inFlight.count < maxConcurrent,
              !youtubeID.isEmpty else {
            return
        }

        // YouTube URLs are IP/session-bound and expire. Rule: never cache
        // or prewarm — always resolve fresh at play time.
        if youtubeID.hasPrefix("yt_") { return }

        inFlight.insert(youtubeID)

        guard var components = URLComponents(string: Config.backendBaseURL) else {
            inFlight.remove(youtubeID)
            return
        }
        components.path = "/stream"
        components.queryItems = [
            URLQueryItem(name: "id", value: youtubeID),
            URLQueryItem(name: "quality", value: "320")
        ]
        guard let url = components.url else {
            inFlight.remove(youtubeID)
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        // Some backends reject HEAD, so use a Range GET that transfers
        // essentially no bytes but still walks the redirect chain.
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        Task { [weak self] in
            let result = try? await URLSession.shared.data(for: request)
            await MainActor.run {
                guard let self else { return }
                self.inFlight.remove(youtubeID)
                self.warmed.insert(youtubeID)
                // Capture resolved CDN URL so PlayerViewModel can skip
                // its own resolveRedirect() round-trip on play.
                if let finalURL = result?.1.url,
                   finalURL.host != url.host {
                    ResolvedURLCache.shared.set(youtubeID, url: finalURL)
                }
            }
        }
    }
}
