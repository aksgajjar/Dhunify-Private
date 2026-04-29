//
//  AppContainer.swift
//  Dhunify
//
//  Composition root. Owns the SwiftData container, the long-lived
//  PlayerViewModel, and every concrete dependency used by the app.
//  Exposed through `AppContainer.shared` so non-SwiftUI surfaces
//  (CarPlay scene delegate, App Intents) can reach the same graph
//  that the SwiftUI views see through `@Environment`.
//

import Foundation
import Observation
import SwiftData

enum Config {
    static let backendBaseURL = "https://api.heyandirect.com"
    /// Cloudflare Worker that edge-caches audio in R2. First play of
    /// any song proxies the upstream CDN and populates the R2 mirror;
    /// subsequent plays are served from the nearest CF PoP.
    static let audioWorkerURL = "https://dhunify-audio.aksgajjar.workers.dev"
}

@MainActor
@Observable
final class AppContainer {

    /// The single app-wide container. Main-actor isolated so every
    /// surface (SwiftUI environment, CarPlay scene delegate, App
    /// Intents) reaches the same graph without racing construction.
    static let shared = AppContainer()

    // All dependencies are set up once and never mutate after
    // construction, so none of them need to participate in observation.
    // `@ObservationIgnored` also sidesteps the fact that the @Observable
    // macro does not support `lazy` stored properties.

    @ObservationIgnored let modelContainer: ModelContainer

    @ObservationIgnored
    lazy var songStore: any SongStore = LocalSongStore(modelContainer: modelContainer)

    @ObservationIgnored
    lazy var songRepository: any SongRepository = {
        guard let url = URL(string: Config.backendBaseURL) else {
            fatalError("Invalid backend base URL: \(Config.backendBaseURL)")
        }
        return YouTubeAPIClient(baseURL: url)
    }()

    @ObservationIgnored
    lazy var searchSongsUseCase = SearchSongsUseCase(
        repository: songRepository
    )

    @ObservationIgnored
    lazy var downloadSongUseCase = DownloadSongUseCase(
        repository: songRepository,
        store: songStore
    )

    /// Long-lived player view-model. Created once here so CarPlay and
    /// the in-app PlayerView share a single playback state machine —
    /// otherwise the two would drift out of sync.
    @ObservationIgnored
    lazy var playerViewModel: PlayerViewModel = PlayerViewModel()

    @ObservationIgnored
    lazy var carPlayUpdater: CarPlayNowPlayingUpdater = CarPlayNowPlayingUpdater(
        playerViewModel: playerViewModel
    )

    @ObservationIgnored
    lazy var downloadManager: DownloadManager = DownloadManager(modelContainer: modelContainer)

    /// Shared Home view-model. HomeView and CarPlayCoordinator read from
    /// the same `sections` array so CarPlay's Trending / Popular tabs
    /// mirror the iPhone Home screen using the same disk cache + load
    /// cycle — no duplicate API calls.
    @ObservationIgnored
    lazy var homeViewModel: HomeViewModel = HomeViewModel(
        searchUseCase: searchSongsUseCase
    )

    private init() {
        // SwiftData's ModelContainer expects Library/Application Support
        // to exist. On fresh install the directory is missing, which
        // floods the console with multi-page Core Data sandbox errors
        // before its internal recovery path runs `mkdir`. Pre-creating
        // it ourselves keeps cold-launch logs clean.
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            _ = appSupport
        }

        do {
            self.modelContainer = try ModelContainer(for: SongModel.self, DownloadedSong.self)
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    /// Kicks off the observation loop that mirrors PlayerViewModel
    /// state into MPNowPlayingInfoCenter for CarPlay + lock screen.
    /// Safe to call multiple times — the updater is idempotent.
    func startCarPlayUpdater() {
        carPlayUpdater.start()
    }
}
