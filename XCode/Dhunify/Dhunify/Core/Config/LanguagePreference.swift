//
//  LanguagePreference.swift
//  Dhunify
//
//  User language preference for queue refill / recommendations. v1
//  ships hardcoded ratios — no settings UI. v2 will read/write from
//  UserDefaults so the user can tune.
//

import Foundation

enum LanguagePreference {
    static let hindiRatio: Double = 0.9
    static let gujaratiRatio: Double = 0.1
    static let blockedLanguages: Set<Language> = [.english]

    /// Splits a target batch size into per-language counts based on the
    /// configured ratios. Rounds Gujarati up to at least 1 when the
    /// batch is non-trivial so queue refill still surfaces some
    /// regional variety.
    static func split(batchSize: Int) -> (hindi: Int, gujarati: Int) {
        guard batchSize > 0 else { return (0, 0) }
        let gujarati = max(batchSize >= 5 ? 1 : 0,
                           Int((Double(batchSize) * gujaratiRatio).rounded()))
        let hindi = max(0, batchSize - gujarati)
        return (hindi, gujarati)
    }

    static func isBlocked(_ language: Language) -> Bool {
        blockedLanguages.contains(language)
    }
}
