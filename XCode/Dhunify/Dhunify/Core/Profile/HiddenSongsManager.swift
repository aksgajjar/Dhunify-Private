//
//  HiddenSongsManager.swift
//  Dhunify
//
//  Stores the set of songs the user has hidden via "Don't show me this
//  again". Persisted in UserDefaults under the active profile so two
//  profiles on the same device keep independent block lists.
//

import Foundation

@MainActor
@Observable
final class HiddenSongsManager {

    static let shared = HiddenSongsManager()

    private(set) var hiddenIDs: Set<String> = []

    private var storageKey: String {
        let suffix = ProfileManager.shared.currentProfile?.id.uuidString ?? "default"
        return "dhunify.hiddenSongs.\(suffix)"
    }

    private init() { reload() }

    func reload() {
        let stored = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        hiddenIDs = Set(stored)
    }

    func hide(song: Song) {
        guard !song.youtubeID.isEmpty else { return }
        hiddenIDs.insert(song.youtubeID)
        persist()
    }

    func unhide(youtubeID: String) {
        hiddenIDs.remove(youtubeID)
        persist()
    }

    func isHidden(_ song: Song) -> Bool {
        hiddenIDs.contains(song.youtubeID)
    }

    /// Convenience helper — filters a list in one call for callers that
    /// want to hide the blocked songs from a home/search result set.
    func filtered(_ songs: [Song]) -> [Song] {
        guard !hiddenIDs.isEmpty else { return songs }
        return songs.filter { !hiddenIDs.contains($0.youtubeID) }
    }

    private func persist() {
        UserDefaults.standard.set(Array(hiddenIDs), forKey: storageKey)
    }
}
