//
//  DhunifyApp.swift
//  Dhunify
//
//  App entry point. Constructs the composition root and navigation
//  router once at launch and injects them into the SwiftUI environment.
//

import SwiftUI
import SwiftData
import UIKit
import AVFoundation
internal import CarPlay
import os

private let appLifecycleLogger = Logger(subsystem: "com.diphoria.Dhunify", category: "AppLifecycle")

/// Pure SwiftUI `@main` means `WindowGroup.task` only fires when the
/// user-facing scene activates. For CarPlay cold-launch (app killed,
/// iPhone locked, engine starts) we never hit that path, so without
/// this delegate the AppContainer and audio session wouldn't be
/// initialized until *after* CarPlay asks us to play — usually too
/// late, which is why the car silently fails to auto-play.
final class DhunifyAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 150MB on-disk URL cache for thumbnails + backend responses.
        // Cuts cold-launch image flicker and keeps the home feed feeling
        // instant even on slow networks. `URLSession.shared` picks this
        // up automatically.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 150 * 1024 * 1024,
            diskPath: "dhunify.urlcache"
        )

        // Warm the composition root on the main actor so the player
        // view model, audio session, and remote command handlers are
        // all live before CarPlay's scene delegate asks for playback.
        MainActor.assumeIsolated {
            _ = AppContainer.shared.playerViewModel
            AppContainer.shared.startCarPlayUpdater()
            // Touch the iPhone refill coordinator so it subscribes to
            // `.dhunifyQueueNearEnd` before the user can reach the queue
            // tail. Idempotent — lazy var ensures one observer.
            _ = AppContainer.shared.queueRefillCoordinator
        }

        // Phase 3: prime the YouTube resolver in the background so the
        // first play doesn't pay the visitor_data bootstrap cost
        // (~200-500ms GET of a watch page to scrape the token). Fire-
        // and-forget; any failure here just means the first real
        // resolve falls back to the same bootstrap path it took before.
        YouTubeStreamResolver.shared.warmup()

        // Prime the audio session. `PlayerViewModel.init` already does
        // this but doing it again here is idempotent and guarantees
        // the session is primed even if a later init races CarPlay.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            // Non-fatal — PlayerViewModel will retry on play().
        }

        return true
    }

    /// CarPlay scene configuration. Returning the correct scene config
    /// here (rather than relying purely on Info.plist) makes cold-launch
    /// scene hand-off more reliable on some iOS versions, particularly
    /// the 17/18 wireless CarPlay path.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        appLifecycleLogger.info("🎬 configurationForConnecting — role=\(connectingSceneSession.role.rawValue, privacy: .public)")
        if connectingSceneSession.role == .carTemplateApplication {
            appLifecycleLogger.info("🚗 Returning CarPlay scene configuration (delegate=CarPlaySceneDelegate)")
            let config = UISceneConfiguration(
                name: "CarPlay Configuration",
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }
}

@main
struct DhunifyApp: App {
    @UIApplicationDelegateAdaptor(DhunifyAppDelegate.self) private var appDelegate
    @State private var router = AppRouter()
    @AppStorage("dhunify.themePreference") private var themePreference: String = "dark"

    private var preferredScheme: ColorScheme? {
        switch themePreference {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppContainer.shared)
                .environment(router)
                .modelContainer(AppContainer.shared.modelContainer)
                .preferredColorScheme(preferredScheme)
                .task { resumeLastPlayed() }
        }
    }

    /// Restore the last played song state on app launch (paused).
    /// Shows song in mini player but does NOT start audio.
    private func resumeLastPlayed() {
        guard let song = LastPlayedPersistence.load() else { return }
        let vm = AppContainer.shared.playerViewModel
        // Only restore if nothing is already playing.
        guard vm.currentSong == nil else { return }
        if let saved = LastPlayedPersistence.loadQueueIfFresh() {
            vm.restoreQueue(saved.queue, startIndex: saved.index)
        } else {
            vm.restoreQueue([song], startIndex: 0)
        }
        // Prewarm the resumed track's faststart build during the launch→tap
        // lead time so the first play() is instant (cache hit) instead of a
        // ~4-5s cold build.
        if let resumed = vm.currentSong, resumed.isYouTubeSource {
            vm.prewarmFstream(youtubeID: resumed.youtubeID)
        }
        // Arm resume so first play() — whether from UI tap or CarPlay
        // route activation firing MPRemoteCommandCenter.playCommand —
        // seeks to last saved position instead of restarting at 0.
        let pos = LastPlayedPersistence.loadPosition()
        if pos > 3 {
            vm.pendingResumeSeconds = pos
        }
    }
}
