//
//  ProfileManager.swift
//  Dhunify
//
//  Local-only multi-user profile system. Max 4 profiles stored in
//  UserDefaults as JSON. No internet, no passwords.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "Profile")

struct UserProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var emoji: String
    var createdAt: Date

    init(name: String, emoji: String) {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.createdAt = Date()
    }
}

@MainActor
@Observable
final class ProfileManager {
    static let shared = ProfileManager()

    var profiles: [UserProfile] = []
    var currentProfile: UserProfile? = nil

    static let maxProfiles = 4

    private let profilesKey = "dhunify.profiles"
    private let currentIDKey = "dhunify.currentProfileID"

    private init() {
        load()
    }

    var hasSelectedProfile: Bool {
        currentProfile != nil
    }

    var canAddProfile: Bool {
        profiles.count < Self.maxProfiles
    }

    // MARK: - CRUD

    func addProfile(name: String, emoji: String) {
        guard canAddProfile else { return }
        let profile = UserProfile(name: name, emoji: emoji)
        profiles.append(profile)
        save()
        logger.info("Profile added: \(name) \(emoji)")
    }

    func selectProfile(_ profile: UserProfile) {
        currentProfile = profile
        UserDefaults.standard.set(profile.id.uuidString, forKey: currentIDKey)
        logger.info("Profile selected: \(profile.name)")
    }

    func deleteProfile(_ profile: UserProfile) {
        profiles.removeAll { $0.id == profile.id }
        if currentProfile?.id == profile.id {
            currentProfile = nil
            UserDefaults.standard.removeObject(forKey: currentIDKey)
        }
        save()
    }

    func switchProfile() {
        currentProfile = nil
        UserDefaults.standard.removeObject(forKey: currentIDKey)
    }

    /// Directory for a profile's downloads.
    func downloadsDirectory(for profile: UserProfile? = nil) -> URL {
        let p = profile ?? currentProfile
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Downloads/\(p?.id.uuidString ?? "default")")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: profilesKey)
        } catch {
            logger.error("Profile save failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: profilesKey) else { return }
        do {
            profiles = try JSONDecoder().decode([UserProfile].self, from: data)
        } catch {
            logger.error("Profile load failed: \(error.localizedDescription)")
            profiles = []
        }

        // Restore current profile.
        if let idString = UserDefaults.standard.string(forKey: currentIDKey),
           let id = UUID(uuidString: idString) {
            currentProfile = profiles.first { $0.id == id }
        }
    }
}
