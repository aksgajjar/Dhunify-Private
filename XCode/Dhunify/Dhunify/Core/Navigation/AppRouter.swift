//
//  AppRouter.swift
//  Dhunify
//
//  Central navigation coordinator. Uses a typed `[Route]` path so the
//  app root can inspect entries and intercept specific routes (e.g.
//  the player is pulled out and presented as a full-screen cover).
//  Injected through the SwiftUI environment so any feature can drive
//  navigation without holding a reference to the view hierarchy.
//

import Foundation
import SwiftUI

enum Route: Hashable, Identifiable {
    case home
    case search
    case player(queue: [Song], startIndex: Int)
    case library

    var id: String {
        switch self {
        case .home:
            return "home"
        case .search:
            return "search"
        case .library:
            return "library"
        case .player(let queue, let startIndex):
            let first = queue.first?.id.uuidString ?? "empty"
            return "player-\(first)-\(queue.count)-\(startIndex)"
        }
    }
}

@Observable
final class AppRouter {
    var path = NavigationPath()
    var presentedSheet: Route?
    var playerRoute: Route?
    /// Set by the tab-owning view so features (e.g. the top-of-Home
    /// search bar) can switch to the Search tab without drilling a
    /// binding through the view tree.
    var requestSearchTabFocus: Bool = false
    /// Set alongside `requestSearchTabFocus` so the SearchView field
    /// opens the keyboard immediately, matching Spotify/YTM behavior.
    var requestSearchKeyboardFocus: Bool = false

    // MARK: - Push navigation

    func navigate(to route: Route) {
        // .player always routes to fullScreenCover, never to NavigationStack
        if case let .player(queue, startIndex) = route {
            presentPlayer(queue: queue, startIndex: startIndex)
            return
        }
        path.append(route)
    }

    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        path = NavigationPath()
    }

    // MARK: - Sheet presentation

    func presentSheet(_ route: Route) {
        presentedSheet = route
    }

    func dismissSheet() {
        presentedSheet = nil
    }

    // MARK: - Player (full-screen cover)

    /// Presents the full-screen player for the given queue. Bypasses
    /// the navigation path entirely so there is no phantom push
    /// animation before the cover appears.
    func presentPlayer(queue: [Song], startIndex: Int) {
        playerRoute = .player(queue: queue, startIndex: startIndex)
    }

    func dismissPlayer() {
        playerRoute = nil
    }
}
