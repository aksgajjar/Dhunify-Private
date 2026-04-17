//
//  ResolvedURLCache.swift
//  Dhunify
//
//  Caches resolved final CDN URLs (post-302) for JioSaavn /stream links.
//  StreamPrewarmer fills this on row-appear; PlayerViewModel checks it
//  before calling resolveRedirect() so the 302 round-trip is skipped on
//  play. YouTube URLs have their own resolver cache and are not stored
//  here.
//
//  Entries expire after 60s — JioSaavn CDN links are signed and short-
//  lived, so we'd rather re-resolve than risk serving a stale URL.
//

import Foundation

@MainActor
final class ResolvedURLCache {
    static let shared = ResolvedURLCache()

    private struct Entry {
        let url: URL
        let expiry: Date
    }

    private var store: [String: Entry] = [:]
    private let ttl: TimeInterval = 60

    private init() {}

    func get(_ key: String) -> URL? {
        guard let entry = store[key] else { return nil }
        if entry.expiry < Date() {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.url
    }

    func set(_ key: String, url: URL) {
        store[key] = Entry(url: url, expiry: Date().addingTimeInterval(ttl))
    }

    func clear() {
        store.removeAll()
    }
}
