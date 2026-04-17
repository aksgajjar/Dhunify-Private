//
//  MoodDetectionEngine.swift
//  Dhunify
//
//  Heuristic mood suggestion driven by time of day + weekday vs weekend.
//  Returns a labeled suggestion with search queries so the home screen
//  can surface a mood-appropriate mini playlist.
//

import Foundation

struct MoodDetectionEngine {

    struct MoodSuggestion {
        let title: String
        let subtitle: String
        let queries: [String]
    }

    static func suggestion(hour: Int, isWeekend: Bool) -> MoodSuggestion {
        switch hour {
        case 5..<8:
            return MoodSuggestion(
                title: "Subah Ki Shuruaat",
                subtitle: "Fresh start to your morning",
                queries: [
                    "morning songs hindi fresh",
                    "good morning bollywood",
                    "uplifting hindi songs morning",
                    "happy start songs hindi",
                    "morning motivation songs",
                ]
            )
        case 8..<12:
            return MoodSuggestion(
                title: isWeekend ? "Lazy Morning" : "Office Mode On",
                subtitle: isWeekend ? "Weekend mornings are special" : "Focus aur kaam ka time",
                queries: isWeekend
                    ? [
                        "chill sunday songs hindi",
                        "lazy morning bollywood",
                        "soft hindi songs morning",
                        "weekend hindi chill",
                        "peaceful bollywood morning",
                      ]
                    : [
                        "focus music hindi",
                        "productive bollywood soft",
                        "work from home hindi songs",
                        "concentration music indian",
                        "soft hindi background music",
                      ]
            )
        case 12..<15:
            return MoodSuggestion(
                title: "Dopahar Ka Break",
                subtitle: "Lunch time energy boost",
                queries: [
                    "afternoon bollywood hits",
                    "lunch time hindi songs",
                    "upbeat hindi afternoon",
                    "trending bollywood 2024",
                    "popular hindi songs today",
                ]
            )
        case 15..<18:
            return MoodSuggestion(
                title: "Evening Drive",
                subtitle: "Wind down ka waqt",
                queries: [
                    "evening drive songs hindi",
                    "long drive bollywood",
                    "sunset hindi songs",
                    "evening chill bollywood",
                    "road trip hindi music",
                ]
            )
        case 18..<21:
            return MoodSuggestion(
                title: isWeekend ? "Party Night" : "Shaam Ka Sukoon",
                subtitle: isWeekend ? "Weekend party time" : "Relax after a long day",
                queries: isWeekend
                    ? [
                        "friday night party hindi",
                        "weekend party songs bollywood",
                        "dance songs hindi 2024",
                        "party bollywood hits",
                        "night out songs hindi",
                      ]
                    : [
                        "evening relaxing hindi songs",
                        "after work chill bollywood",
                        "calm evening hindi music",
                        "soft romantic evening songs",
                        "relax hindi evening",
                      ]
            )
        case 21..<24:
            return MoodSuggestion(
                title: "Late Night Feels",
                subtitle: "Raat ki khamoshi mein",
                queries: [
                    "late night hindi songs",
                    "night feelings bollywood",
                    "slow hindi songs night",
                    "midnight bollywood mood",
                    "2am hindi songs",
                ]
            )
        default: // 0–5 AM
            return MoodSuggestion(
                title: "Night Owl",
                subtitle: "Raat ko jaagna",
                queries: [
                    "late night lofi hindi",
                    "night chill bollywood",
                    "slow sad hindi songs",
                    "midnight mood songs",
                    "sleepless night hindi",
                ]
            )
        }
    }
}
