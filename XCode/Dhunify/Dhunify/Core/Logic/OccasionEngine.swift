//
//  OccasionEngine.swift
//  Dhunify
//
//  Calendar-aware Indian festival / event matcher. Given today's date
//  (or the next 3 days), returns a named occasion with search queries
//  so the home screen can surface a themed playlist — Diwali, Holi,
//  Navratri, Shaadi Season, etc.
//

import Foundation

struct OccasionEngine {

    struct Occasion {
        let name: String
        let queries: [String]
    }

    /// Returns the current occasion if any Indian festival/event falls
    /// within today + 3 days. Falls back to a seasonal match on the
    /// current month.
    static func currentOccasion() -> Occasion? {
        let calendar = Calendar.current
        let now = Date()
        let month = calendar.component(.month, from: now)
        let day   = calendar.component(.day,   from: now)

        for offset in 0...3 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let m = calendar.component(.month, from: date)
            let d = calendar.component(.day,   from: date)
            if let occasion = occasion(month: m, day: d) {
                return occasion
            }
        }
        return seasonalOccasion(month: month, day: day)
    }

    private static func occasion(month: Int, day: Int) -> Occasion? {
        switch (month, day) {
        // Diwali (Oct-Nov)
        case (10, 20...31), (11, 1...5):
            return Occasion(
                name: "Diwali Special",
                queries: [
                    "diwali songs bollywood",
                    "happy diwali music hindi",
                    "festive bollywood songs",
                    "diwali celebration songs",
                    "deepawali special songs",
                ]
            )
        // Holi (March)
        case (3, 20...31), (3, 1...10):
            return Occasion(
                name: "Holi Hai",
                queries: [
                    "holi songs bollywood",
                    "rang barse songs",
                    "holi party music",
                    "colorful bollywood dance",
                    "holi special hindi songs",
                ]
            )
        // New Year
        case (12, 28...31), (1, 1...3):
            return Occasion(
                name: "New Year Party",
                queries: [
                    "new year party songs hindi",
                    "bollywood new year hits",
                    "party songs 2024 2025",
                    "countdown party music",
                    "new year celebration songs",
                ]
            )
        // Independence Day
        case (8, 13...16):
            return Occasion(
                name: "Independence Day",
                queries: [
                    "desh bhakti songs",
                    "independence day hindi songs",
                    "patriotic bollywood songs",
                    "vande mataram songs",
                    "indian patriotic music",
                ]
            )
        // Republic Day
        case (1, 24...26):
            return Occasion(
                name: "Republic Day",
                queries: [
                    "republic day songs hindi",
                    "desh bhakti bollywood",
                    "patriotic indian songs",
                    "jai hind songs",
                    "patriotic hindi music",
                ]
            )
        // Valentine's Day
        case (2, 12...15):
            return Occasion(
                name: "Valentine's Day",
                queries: [
                    "valentine songs hindi",
                    "romantic bollywood 2024",
                    "love songs arijit singh",
                    "pyaar ke gaane",
                    "best romantic hindi songs",
                ]
            )
        // Navratri / Garba
        case (10, 1...20):
            return Occasion(
                name: "Navratri Garba",
                queries: [
                    "navratri garba songs",
                    "dandiya songs gujarati",
                    "garba music 2024",
                    "navratri special songs",
                    "falguni pathak garba",
                ]
            )
        // Eid (approximate)
        case (4, 1...30), (5, 1...15):
            return Occasion(
                name: "Eid Mubarak",
                queries: [
                    "eid mubarak songs hindi",
                    "bollywood eid songs",
                    "atif aslam eid songs",
                    "eid celebration music",
                    "ramadan hindi songs",
                ]
            )
        // Christmas
        case (12, 22...26):
            return Occasion(
                name: "Christmas",
                queries: [
                    "christmas songs hindi bollywood",
                    "jingle bells hindi",
                    "christmas party songs",
                    "winter bollywood songs",
                    "christmas celebration hindi",
                ]
            )
        // Shaadi season (Nov-Feb)
        case (11, 15...30), (12, 1...20),
             (1, 5...31), (2, 1...20):
            return Occasion(
                name: "Shaadi Season",
                queries: [
                    "best wedding songs hindi",
                    "shaadi bollywood songs",
                    "sangeet songs bollywood",
                    "wedding dance songs hindi",
                    "mehndi ceremony songs",
                ]
            )
        default:
            return nil
        }
    }

    private static func seasonalOccasion(month: Int, day: Int) -> Occasion? {
        switch month {
        case 6, 7, 8:
            return Occasion(
                name: "Monsoon Vibes",
                queries: [
                    "monsoon songs hindi",
                    "barish ke gaane",
                    "rain songs bollywood",
                    "romantic rain hindi songs",
                    "sawan special songs",
                ]
            )
        case 12, 1:
            return Occasion(
                name: "Winter Chill",
                queries: [
                    "winter songs hindi bollywood",
                    "cozy hindi songs",
                    "cold weather music hindi",
                    "warm romantic bollywood",
                    "winter evening hindi songs",
                ]
            )
        default:
            return nil
        }
    }
}
