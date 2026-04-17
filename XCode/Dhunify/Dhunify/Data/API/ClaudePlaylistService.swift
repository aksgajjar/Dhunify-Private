//
//  ClaudePlaylistService.swift
//  Dhunify
//
//  Turns a free-form mood prompt (Hindi / Gujarati / English / Hinglish)
//  into a set of JioSaavn search queries via OpenAI chat completions.
//  Kept under the original `ClaudePlaylistService` name to avoid
//  churning every call site — internals are now OpenAI.
//

import Foundation

enum ClaudePlaylistService {

    private static let apiURL = "https://api.openai.com/v1/chat/completions"
    private static let model  = "gpt-4o-mini"

    enum PlaylistError: Error {
        case missingAPIKey
        case apiError(String)
        case parseError
        case noResults
    }

    /// Returns 6 English JioSaavn search queries derived from the user's
    /// mood prompt. Accepts Hindi / Gujarati / English / Hinglish input.
    static func generateSearchQueries(
        prompt: String,
        timeOfDay: String,
        recentSongs: [String]
    ) async throws -> [String] {

        guard !AppConfig.openAIAPIKey.isEmpty else {
            throw PlaylistError.missingAPIKey
        }

        let systemPrompt = """
        You are a Bollywood music expert. User gives mood in any language. \
        Return ONLY a JSON object of shape {"queries": [..5 English JioSaavn \
        search queries, 3–5 words each..]}. No explanation.
        """

        let userMessage = """
        Time of day: \(timeOfDay)
        Recent songs played: \(recentSongs.prefix(3).joined(separator: ", "))
        User mood/request: \(prompt)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 150,
            "temperature": 0.7,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userMessage],
            ],
        ]

        guard let url = URL(string: apiURL) else {
            throw PlaylistError.apiError("invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AppConfig.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PlaylistError.apiError("no response")
        }
        guard http.statusCode == 200 else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw PlaylistError.apiError("HTTP \(http.statusCode): \(snippet)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PlaylistError.parseError
        }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentData = cleaned.data(using: .utf8) else {
            throw PlaylistError.parseError
        }

        // Preferred shape: {"queries": [...]}. Fallback: a raw JSON array.
        if let obj = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
           let arr = obj["queries"] as? [String], !arr.isEmpty {
            return arr
        }
        if let arr = try? JSONDecoder().decode([String].self, from: contentData), !arr.isEmpty {
            return arr
        }
        throw PlaylistError.parseError
    }
}
