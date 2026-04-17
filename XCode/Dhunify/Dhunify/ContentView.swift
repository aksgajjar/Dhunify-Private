//
//  ContentView.swift
//  Dhunify
//
//  4-tab layout: Home | Search | Radio | Library
//

import SwiftUI
import UIKit

struct ContentView: View {
    enum Tab: Hashable {
        case home
        case search
        case radio
        case library
        case settings
    }

    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @State private var selectedTab: Tab = .home
    @State private var showSplash: Bool = true
    @State private var profileManager = ProfileManager.shared
    @State private var showProfilePicker: Bool = false
    @State private var showOnboarding: Bool = false
    @State private var network = NetworkMonitor.shared
    @Namespace private var playerNamespace

    init() {
        // Frosted glass tab bar
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = UIColor(Color.appBackground.opacity(0.75))
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)

        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(Color.appSecondary)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(Color.appSecondary)]
        item.selected.iconColor = UIColor(Color.appAccent)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(Color.appAccent)]
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        @Bindable var router = router

        ZStack {
            if showSplash {
                SplashView {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        showSplash = false
                        // After splash, check if we need profile selection.
                        if !profileManager.hasSelectedProfile {
                            showProfilePicker = true
                        }
                    }
                }
                .transition(.opacity)
            } else if showProfilePicker {
                ProfilePickerView {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        showProfilePicker = false
                        if !OnboardingView.isCompleted {
                            showOnboarding = true
                        }
                    }
                }
                .transition(.opacity)
            } else if showOnboarding {
                OnboardingView {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        showOnboarding = false
                    }
                }
                .transition(.opacity)
            } else {
                NavigationStack(path: $router.path) {
                    ZStack(alignment: .bottom) {
                        Color.appBackground.ignoresSafeArea()

                        VStack(spacing: 0) {
                            // Offline banner
                            if !network.isConnected {
                                HStack(spacing: 6) {
                                    Image(systemName: "wifi.slash")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Offline Mode — Playing downloaded songs only")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.appAccent.opacity(0.9))
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            TabView(selection: $selectedTab) {
                            HomeView()
                                .tabItem { Label("Home", systemImage: "house.fill") }
                                .tag(Tab.home)

                            SearchView()
                                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                                .tag(Tab.search)

                            RadioView()
                                .tabItem { Label("Radio", systemImage: "radio") }
                                .tag(Tab.radio)

                            LibraryView()
                                .tabItem { Label("Library", systemImage: "music.note.list") }
                                .tag(Tab.library)

                            SettingsView()
                                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                                .tag(Tab.settings)
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedTab)
                        .onChange(of: selectedTab) { _, _ in HapticManager.light() }
                        .onChange(of: router.requestSearchTabFocus) { _, newValue in
                            if newValue {
                                selectedTab = .search
                                router.requestSearchTabFocus = false
                            }
                        }
                        } // end VStack (offline banner + tabs)
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: network.isConnected)

                        // Mini player above tab bar (hidden while full player overlay is up)
                        VStack(spacing: 0) {
                            Spacer()
                            if router.playerRoute == nil {
                                MiniPlayerView(namespace: playerNamespace)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                    .padding(.bottom, 49)
                            }
                        }
                        .ignoresSafeArea(.keyboard)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: container.playerViewModel.currentSong?.youtubeID)
                    }
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .home: HomeView()
                        case .search: SearchView()
                        case .library: LibraryView()
                        case .player: EmptyView()
                        }
                    }
                    .navigationDestination(for: String.self) { artistName in
                        ArtistView(artistName: artistName)
                    }
                    .navigationDestination(for: AlbumResult.self) { album in
                        AlbumDetailView(album: album)
                    }
                }
                .overlay {
                    if let route = router.playerRoute,
                       case let .player(queue, startIndex) = route {
                        PlayerView(queue: queue, startIndex: startIndex, namespace: playerNamespace)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                            .zIndex(10)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: router.playerRoute?.id)
                .sheet(item: $router.presentedSheet) { route in
                    switch route {
                    case .home: HomeView()
                    case .search: SearchView()
                    case .library: LibraryView()
                    case .player: EmptyView()
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
