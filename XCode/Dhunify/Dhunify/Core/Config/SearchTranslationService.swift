//
//  SearchTranslationService.swift
//  Dhunify
//
//  One-shot translator: converts a Hindi / Gujarati / Hinglish music
//  query into an English JioSaavn search string via GPT-4o-mini.
//  Falls back to the original input if the key is empty or the call
//  fails (5s timeout — search must feel instant).
//

import Foundation

struct SearchTranslationService {

    static func translateToSearchQuery(_ input: String) async -> String {
        let key = AppConfig.openAIAPIKey
        guard !key.isEmpty else { return input }

        let systemPrompt = """
        You are a music search assistant for JioSaavn. \
        User types in Hindi, Gujarati, English, or mixed. \
        Convert to best English JioSaavn search query. \
        Return ONLY the query. No explanation. Max 6 words.
        """

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 30,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": input],
            ],
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return input
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = 5.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return input
            }
            let translated = content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return translated.isEmpty ? input : translated
        } catch {
            return input
        }
    }
}
