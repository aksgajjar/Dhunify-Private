//
//  LanguageClassifier.swift
//  Dhunify
//
//  Heuristic language detection for queue-refill filtering. Classifies
//  a Song as Hindi / Gujarati / English / unknown using:
//   1. Devanagari & Gujarati Unicode ranges in title or artist (script
//      presence is a high-confidence signal).
//   2. A literal allowlist of well-known Indian artists — forces Hindi
//      regardless of title (covers Bollywood remixes with English titles).
//   3. Romanized-Hindi keyword bag in the title (transliteration cases).
//   4. ASCII-only title + non-Indian artist → English.
//   5. Otherwise unknown — refill biases unknown toward keep so we never
//      throw away a track we couldn't confidently label.
//
//  Pure functions only. No state. No I/O.
//

import Foundation

enum Language: String {
    case hindi
    case gujarati
    case english
    case unknown
}

enum LanguageClassifier {

    static func classify(song: Song) -> Language {
        let title = song.title
        let artist = song.artist

        if containsDevanagari(title) || containsDevanagari(artist) {
            return .hindi
        }
        if containsGujaratiScript(title) || containsGujaratiScript(artist) {
            return .gujarati
        }
        if matchesIndianArtist(artist) {
            return .hindi
        }
        if containsRomanizedHindiKeyword(title) {
            return .hindi
        }
        if isAsciiOnly(title) {
            return .english
        }
        return .unknown
    }

    // MARK: - Script detection

    private static func containsDevanagari(_ s: String) -> Bool {
        for scalar in s.unicodeScalars where (0x0900...0x097F).contains(scalar.value) {
            return true
        }
        return false
    }

    private static func containsGujaratiScript(_ s: String) -> Bool {
        for scalar in s.unicodeScalars where (0x0A80...0x0AFF).contains(scalar.value) {
            return true
        }
        return false
    }

    private static func isAsciiOnly(_ s: String) -> Bool {
        for scalar in s.unicodeScalars where scalar.value > 0x007F {
            return false
        }
        return !s.isEmpty
    }

    // MARK: - Artist allowlist

    private static let indianArtistTokens: [String] = [
        "arijit singh", "atif aslam", "shreya ghoshal", "pritam",
        "a.r. rahman", "ar rahman", "rahman",
        "lata mangeshkar", "kishore kumar", "sonu nigam", "neha kakkar",
        "honey singh", "yo yo honey singh", "badshah",
        "jubin nautiyal", "armaan malik", "darshan raval",
        "vishal-shekhar", "vishal shekhar", "sachin-jigar", "sachin jigar",
        "amit trivedi", "tanishk bagchi",
        "kanika kapoor", "asha bhosle", "mohammad rafi", "mukesh",
        "udit narayan", "alka yagnik", "kumar sanu", "sunidhi chauhan",
        "kk", "rahat fateh ali khan", "tulsi kumar",
        "palak muchhal", "falguni pathak",
        "guru randhawa", "diljit dosanjh", "ap dhillon",
        "shankar mahadevan", "javed ali", "mohit chauhan"
    ]

    private static func matchesIndianArtist(_ artist: String) -> Bool {
        let lower = artist.lowercased()
        for token in indianArtistTokens where lower.contains(token) {
            return true
        }
        return false
    }

    // MARK: - Romanized-Hindi keyword bag

    private static let romanizedHindiKeywords: [String] = [
        "pyaar", "pyar", "tera", "mera", "dil", "ishq", "tum", "jaan",
        "sanam", "bewafa", "mohabbat", "yaar", "jeena", "raat",
        "dosti", "dilbar", "saiyaan", "saiyan", "chand", "chandni",
        "mehbooba", "mehbooba", "jaaneman", "jaaneman", "humdard",
        "tujh", "mujh", "kabhi", "kahin", "yeh", "woh", "kya",
        "deewana", "deewani", "bahut", "kuch", "khwab",
        "tum hi", "tu hi", "main", "tere", "mere",
        "hindi", "bollywood", "lofi hindi", "punjabi"
    ]

    private static func containsRomanizedHindiKeyword(_ title: String) -> Bool {
        let lower = title.lowercased()
        for kw in romanizedHindiKeywords {
            // Match as a whole-word-ish boundary so "humdard" doesn't
            // catch every "hum" inside a longer word.
            if lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: kw))\\b",
                           options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}
