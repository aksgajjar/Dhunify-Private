//
//  PlaybackTelemetry.swift
//  Dhunify
//
//  Lightweight local-only telemetry for playback reliability. Records
//  start events, stall occurrences, and recovery outcomes so we can
//  diagnose real-world behavior later without a backend.
//
//  Storage: bounded ring buffer (last 200 events) in UserDefaults,
//  keyed by profile. No network, no PII beyond song IDs + durations.
//

import Foundation

@MainActor
@Observable
final class PlaybackTelemetry {

    static let shared = PlaybackTelemetry()

    enum EventKind: String, Codable {
        case playbackStart
        case stall
        case recoveryTriggered
        case recoverySucceeded
        case recoveryFailed
    }

    struct Event: Codable, Identifiable {
        let id: UUID
        let kind: EventKind
        let songID: String
        let durationSec: Int
        let reason: String?
        let timestamp: Date
    }

    private(set) var events: [Event] = []

    private let maxEvents = 200
    private var storageKey: String {
        let suffix = ProfileManager.shared.currentProfile?.id.uuidString ?? "default"
        return "dhunify.playbackTelemetry.\(suffix)"
    }

    private init() { reload() }

    func reload() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Event].self, from: data) else {
            events = []
            return
        }
        events = decoded
    }

    func logPlaybackStart(songID: String, durationSec: Int) {
        append(Event(id: UUID(), kind: .playbackStart, songID: songID,
                     durationSec: durationSec, reason: nil, timestamp: Date()))
    }

    func logStall(songID: String, durationSec: Int, reason: String) {
        append(Event(id: UUID(), kind: .stall, songID: songID,
                     durationSec: durationSec, reason: reason, timestamp: Date()))
    }

    func logRecoveryTriggered(songID: String, durationSec: Int) {
        append(Event(id: UUID(), kind: .recoveryTriggered, songID: songID,
                     durationSec: durationSec, reason: nil, timestamp: Date()))
    }

    func logRecoveryOutcome(songID: String, durationSec: Int, succeeded: Bool) {
        append(Event(id: UUID(),
                     kind: succeeded ? .recoverySucceeded : .recoveryFailed,
                     songID: songID, durationSec: durationSec,
                     reason: nil, timestamp: Date()))
    }

    func clear() {
        events = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func append(_ event: Event) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
