//
//  HomeView.swift
//  Dhunify
//
//  YT Music-inspired home. Compact cards, recently played, quick picks.
//

import SwiftUI
import UIKit
import OSLog

struct HomeView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @State private var viewModel: HomeViewModel?
    @State private var recent = RecentlyPlayedManager.shared
    @State private var profileManager = ProfileManager.shared
    @State private var showProfilePicker = false
    @State private var network = NetworkMonitor.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if !network.isConnected {
                offlineHomeView
            } else if let viewModel {
                HomeContent(viewModel: viewModel, router: router, recent: recent, profileEmoji: profileManager.currentProfile?.emoji ?? "🎵")
            } else {
                ProgressView().tint(.appAccent)
            }
        }
        .task {
            if viewModel == nil {
                let vm = HomeViewModel(searchUseCase: container.searchSongsUseCase)
                viewModel = vm
                await vm.loadAll()
            }
        }
    }

    private var offlineHomeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dhunify")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.appAccent)
                    Text("Offline Mode")
                        .font(.system(size: 14))
                        .foregroundStyle(.appSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if !recent.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recently Played")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)

                        LazyVStack(spacing: 4) {
                            ForEach(Array(recent.songs.enumerated()), id: \.element.id) { idx, song in
                                SongRowView(song: song, onTap: {
                                    router.presentPlayer(queue: recent.songs, startIndex: idx)
                                })
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }

                let downloaded = container.downloadManager.fetchDownloaded()
                if !downloaded.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Downloaded (\(downloaded.count))")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)

                        LazyVStack(spacing: 4) {
                            ForEach(Array(downloaded.enumerated()), id: \.element.songID) { idx, dl in
                                SongRowView(song: dl.toSong(), isAlreadyDownloaded: true, onTap: {
                                    router.presentPlayer(queue: downloaded.map { $0.toSong() }, startIndex: idx)
                                })
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }

                if recent.songs.isEmpty && downloaded.isEmpty {
                    VStack(spacing: 12) {
                        Spacer(minLength: 60)
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.appSecondary)
                        Text("You're offline")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Download songs to play them offline")
                            .font(.system(size: 14))
                            .foregroundStyle(.appSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }

                Spacer(minLength: 130)
            }
        }
    }
}

private struct HomeContent: View {
    let viewModel: HomeViewModel
    let router: AppRouter
    let recent: RecentlyPlayedManager
    let profileEmoji: String

    @State private var meshPhase: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Header with mesh gradient background
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .background(
                        TimelineView(.animation(minimumInterval: 1.0 / 10.0)) { timeline in
                            Canvas { context, size in
                                let t = timeline.date.timeIntervalSinceReferenceDate
                                let w = size.width

                                let x1 = w * 0.3 + sin(t * 0.4) * w * 0.15
                                let y1 = 40 + cos(t * 0.3) * 20
                                let x2 = w * 0.7 + cos(t * 0.5) * w * 0.1
                                let y2 = 70 + sin(t * 0.35) * 15

                                context.fill(
                                    Path(ellipseIn: CGRect(x: x1 - 60, y: y1 - 40, width: 120, height: 80)),
                                    with: .color(Color.appAccent.opacity(0.1))
                                )
                                context.fill(
                                    Path(ellipseIn: CGRect(x: x2 - 70, y: y2 - 50, width: 140, height: 100)),
                                    with: .color(Color.appOcean.opacity(0.07))
                                )
                            }
                        }
                        .blur(radius: 30)
                    )

                // Mood chips
                moodChips

                // Genre browse entry
                HStack {
                    NavigationLink {
                        GenreBrowseView()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Browse Genres")
                                .font(.appCaption)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.appOcean))
                    }
                    .accessibilityLabel("Browse all genres")
                    Spacer()
                }
                .padding(.horizontal, 20)

                // Aaj Ka Mix — AI playlist generator (hero section)
                aajKaMixSection

                // Latest Hindi (multi-source waterfall)
                if !viewModel.latestHindi.isEmpty || viewModel.latestHindiLoading {
                    moodLikeSection(
                        label: "Latest Hindi",
                        subtitle: "Fresh tracks from all sources",
                        isLoading: viewModel.latestHindiLoading,
                        songs: viewModel.latestHindi
                    )
                }

                // Latest Gujarati (multi-source waterfall)
                if !viewModel.latestGujarati.isEmpty || viewModel.latestGujaratiLoading {
                    moodLikeSection(
                        label: "Latest Gujarati",
                        subtitle: "Nava Gujarati gaano",
                        isLoading: viewModel.latestGujaratiLoading,
                        songs: viewModel.latestGujarati
                    )
                }

                // Mood detection — time-of-day suggestion
                moodDetectionSection

                // Occasion — festival / seasonal section (shown only when matched)
                occasionSection

                // Featured long-play YouTube mashups (hands off to YT app)
                featuredMashupsSection

                // Recently played
                if !recent.songs.isEmpty {
                    compactSection(title: "Recently Played", songs: recent.songs)
                }

                // For You (personalized)
                if !viewModel.forYouSongs.isEmpty {
                    compactSection(title: "For You", icon: "star.fill", songs: viewModel.forYouSongs)
                }

                // Song sections
                ForEach(viewModel.sections) { section in
                    if !section.songs.isEmpty {
                        compactSection(title: section.title, icon: section.icon, songs: section.songs)
                            .transition(.opacity)
                    } else if section.isLoading {
                        skeletonSection(title: section.title, icon: section.icon)
                            .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: viewModel.sections.map { $0.songs.count })

                // Album sections
                ForEach(viewModel.albumSections) { section in
                    if !section.albums.isEmpty {
                        albumScrollSection(section)
                    }
                }

                Spacer(minLength: 130) // room for mini player + tab bar
            }
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            await viewModel.forceRefresh()
        }
    }

    // ── Header ───────────────────────────────────────────────

    @Environment(AppContainer.self) private var container

    private var playerVM: PlayerViewModel { container.playerViewModel }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                Text("Dhunify")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [Color.appOcean, Color.appOceanLight],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                Spacer()
                Text(viewModel.greeting)
                    .font(.system(size: 13))
                    .foregroundStyle(.appSecondary)
                Button {
                    ProfileManager.shared.switchProfile()
                } label: {
                    Text(profileEmoji)
                        .font(.system(size: 20))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.appSurface))
                }
            }

            // Top search bar — tap to jump to the Search tab with the
            // keyboard already focused (matches Apple Music / Spotify /
            // YT Music). No in-place search — keeps Home clean and
            // reuses the full SearchView (filters, genre chips, etc).
            Button {
                HapticManager.soft()
                router.requestSearchKeyboardFocus = true
                router.requestSearchTabFocus = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.appSecondary)
                    Text("Search songs, artists, albums")
                        .font(.system(size: 15))
                        .foregroundStyle(.appSecondary)
                    Spacer()
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.appSecondary.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.appSurface)
                )
            }
            .buttonStyle(ScalePressButtonStyle())
            .accessibilityLabel("Search")

            // Now playing strip
            if let song = playerVM.currentSong {
                Button {
                    router.presentPlayer(queue: playerVM.queue, startIndex: playerVM.currentIndex)
                } label: {
                    HStack(spacing: 8) {
                        DhunifyAsyncImage(url: song.thumbnailURL, size: 28, cornerRadius: 4)
                        Text(song.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("•")
                            .foregroundStyle(.appSecondary)
                        Text(song.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.appSecondary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: playerVM.isPlaying ? "waveform" : "pause.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.appAccent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.appSurface))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ── Mood chips ───────────────────────────────────────────

    @State private var loadingMood: String? = nil

    private var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.moods) { mood in
                    Button {
                        loadingMood = mood.name
                        Task {
                            let songs = await viewModel.searchMood(mood)
                            loadingMood = nil
                            if !songs.isEmpty { router.presentPlayer(queue: songs, startIndex: 0) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mood.icon)
                                .font(.system(size: 11, weight: .medium))
                            Text(mood.name)
                                .font(.appCaption)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(loadingMood == mood.name ? Color.appOcean : Color.appSurface)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.appOcean.opacity(0.4), lineWidth: 0.5)
                        )
                        .overlay {
                            if loadingMood == mood.name {
                                ProgressView().tint(.white).scaleEffect(0.6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingMood != nil)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // ── Aaj Ka Mix — AI playlist hero ─────────────────────────

    private var aajKaMixSection: some View {
        let promptBinding = Binding<String>(
            get: { viewModel.aajKaMixPrompt },
            set: { viewModel.aajKaMixPrompt = $0 }
        )

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AAJ KA MIX")
                        .font(.appLabel)
                        .tracking(1.2)
                        .foregroundColor(.appSecondary)
                    Text("AI se banao apna playlist")
                        .font(.appHeadline)
                        .foregroundColor(.white)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.appOcean, Color.appAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 14)

            // Input card — shown when user hasn't generated yet or tapped regenerate.
            if viewModel.showAajKaMixInput || viewModel.aajKaMixSongs.isEmpty {
                HStack(spacing: 12) {
                    TextField("kuch bhi likho... sad songs, party, 90s hits",
                              text: promptBinding)
                        .font(.appBody)
                        .foregroundColor(.white)
                        .tint(.appOcean)
                        .submitLabel(.go)
                        .onSubmit {
                            HapticManager.medium()
                            Task { await viewModel.generateAajKaMix() }
                        }

                    Button {
                        HapticManager.medium()
                        Task { await viewModel.generateAajKaMix() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(aajKaMixSendStyle)
                    }
                    .disabled(viewModel.aajKaMixPrompt.isEmpty)
                    .scaleButton(0.9)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            // Loading state
            if viewModel.aajKaMixLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Color.appOcean)
                    Text("AI playlist bana raha hai...")
                        .font(.appCaption)
                        .foregroundColor(.appSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            // Error state
            if viewModel.aajKaMixError {
                VStack(spacing: 8) {
                    Text("Kuch problem aayi. Dobara try karo.")
                        .font(.appCaption)
                        .foregroundColor(.appSecondary)
                    Button {
                        HapticManager.soft()
                        Task { await viewModel.generateAajKaMix() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                            Text("Retry")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.appAccent))
                    }
                    .accessibilityLabel("Retry AI mix")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            // Songs result — horizontal scroll
            if !viewModel.aajKaMixSongs.isEmpty {
                HStack {
                    Button {
                        HapticManager.trackChange()
                        router.presentPlayer(queue: viewModel.aajKaMixSongs, startIndex: 0)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                            Text("Poora mix chalao")
                                .font(.appCaption)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            LinearGradient(
                                colors: [Color.appOcean, Color.appAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(Capsule())
                    }
                    .scaleButton(0.95)

                    Spacer()

                    Button {
                        HapticManager.soft()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            viewModel.showAajKaMixInput = true
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundColor(.appSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.aajKaMixSongs) { song in
                            Button {
                                HapticManager.soft()
                                let idx = viewModel.aajKaMixSongs.firstIndex(
                                    where: { $0.youtubeID == song.youtubeID }
                                ) ?? 0
                                router.presentPlayer(queue: viewModel.aajKaMixSongs, startIndex: idx)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    DhunifyAsyncImage(url: song.thumbnailURL, size: 130, cornerRadius: 12)
                                        .overlay(alignment: .topTrailing) {
                                            sourceBadge(for: song)
                                        }
                                    Text(song.title)
                                        .font(.appCaption)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .frame(width: 130, alignment: .leading)
                                    Text(song.artist)
                                        .font(.system(size: 10))
                                        .foregroundColor(.appSecondary)
                                        .lineLimit(1)
                                        .frame(width: 130, alignment: .leading)
                                }
                            }
                            .scaleButton(0.97)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }
        }
    }

    /// Send-button fill: grey when empty, gradient when the prompt has content.
    private var aajKaMixSendStyle: AnyShapeStyle {
        if viewModel.aajKaMixPrompt.isEmpty {
            return AnyShapeStyle(Color.appSecondary)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [Color.appOcean, Color.appAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // ── Mood detection — time-of-day suggestion ───────────────

    @ViewBuilder
    private var moodDetectionSection: some View {
        if let mood = viewModel.moodSuggestion,
           !viewModel.moodSongs.isEmpty || viewModel.moodLoading {
            moodLikeSection(
                label: mood.title,
                subtitle: mood.subtitle,
                isLoading: viewModel.moodLoading,
                songs: viewModel.moodSongs
            )
        }
    }

    // ── Occasion — festival / seasonal ────────────────────────

    @ViewBuilder
    private var occasionSection: some View {
        if let occasion = viewModel.currentOccasion,
           !viewModel.occasionSongs.isEmpty || viewModel.occasionLoading {
            moodLikeSection(
                label: occasion.name,
                subtitle: nil,
                isLoading: viewModel.occasionLoading,
                songs: viewModel.occasionSongs
            )
        }
    }

    /// Shared layout for both the mood and occasion hero rows: small
    /// uppercase label with a gradient dot, optional subtitle, play-all
    /// circle button, then a horizontal 130pt card scroll.
    private func moodLikeSection(
        label: String,
        subtitle: String?,
        isLoading: Bool,
        songs: [Song]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.appOcean, Color.appAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 6, height: 6)

                        Text(label.uppercased())
                            .font(.appLabel)
                            .tracking(1.2)
                            .foregroundColor(.appSecondary)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.appHeadline)
                            .foregroundColor(.white)
                    }
                }
                Spacer()
                if !songs.isEmpty {
                    Button {
                        HapticManager.trackChange()
                        router.presentPlayer(queue: songs, startIndex: 0)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.appOcean, Color.appAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .scaleButton(0.9)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 12)

            if isLoading {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<5, id: \.self) { _ in CardSkeleton() }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(songs) { song in
                            Button {
                                HapticManager.soft()
                                let idx = songs.firstIndex { $0.youtubeID == song.youtubeID } ?? 0
                                router.presentPlayer(queue: songs, startIndex: idx)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    DhunifyAsyncImage(
                                        url: song.thumbnailURL,
                                        size: 130,
                                        cornerRadius: 12
                                    )
                                    .overlay(alignment: .topTrailing) {
                                        sourceBadge(for: song)
                                    }
                                    Text(song.title)
                                        .font(.appCaption)
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .frame(width: 130, alignment: .leading)
                                    Text(song.artist)
                                        .font(.system(size: 10))
                                        .foregroundColor(.appSecondary)
                                        .lineLimit(1)
                                        .frame(width: 130, alignment: .leading)
                                }
                            }
                            .scaleButton(0.97)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 8)
    }

    // ── Featured Mashups — long-play YouTube links ────────────

    private var featuredMashupsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#FF0000"), Color(hex: "#CC0000")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 6, height: 6)

                Text("LONG PLAY MASHUPS")
                    .font(.appLabel)
                    .tracking(1.2)
                    .foregroundColor(.appSecondary)

                Spacer()

                Text("Opens YouTube")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.appSecondary)
                    .opacity(0.6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.featuredMashups) { mashup in
                        Button {
                            HapticManager.soft()
                            openInYouTube(mashup.id)
                        } label: {
                            featuredMashupCard(mashup)
                        }
                        .scaleButton(0.97)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)
        }
    }

    private func featuredMashupCard(_ mashup: FeaturedMashup) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(mashup.id)/hqdefault.jpg")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color.appSurface
                case .empty:
                    Color.appSurface
                        .overlay(ProgressView().tint(Color.appOcean))
                @unknown default:
                    Color.appSurface
                }
            }
            .frame(width: 200, height: 112)
            .clipped()

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(mashup.mood.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        LinearGradient(
                            colors: [Color.appOcean, Color.appAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())

                Text(mashup.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.7))
                    Text(mashup.duration)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))

                    Spacer()

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(width: 200, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// Deep-link to the YouTube app; fall back to Safari if YouTube
    /// isn't installed.
    private func openInYouTube(_ videoID: String) {
        let appURL = URL(string: "youtube://\(videoID)")
        let webURL = URL(string: "https://youtu.be/\(videoID)")!
        if let appURL, UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else {
            UIApplication.shared.open(webURL)
        }
    }

    // ── Source badge (YT overlay on non-JioSaavn thumbnails) ──

    @ViewBuilder
    private func sourceBadge(for song: Song) -> some View {
        if song.youtubeID.hasPrefix("yt_") {
            Text("YT")
                .font(.system(size: 7, weight: .black))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color(hex: "#FF0000").opacity(0.9))
                .clipShape(Capsule())
                .padding(4)
        }
    }

    // ── Song section (compact 110pt cards) ────────────────────

    private func compactSection(title: String, icon: String = "", songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.appAccent)
                }
                Text(title)
                    .font(.appLabel)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.appSecondary)
                Spacer()

                if !songs.isEmpty {
                    Button {
                        container.playerViewModel.categorySeed = title
                        router.presentPlayer(queue: songs, startIndex: 0)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.appAccent)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .contextMenu {
                        Button {
                            container.playerViewModel.categorySeed = title
                            router.presentPlayer(queue: songs, startIndex: 0)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                        }
                        Button {
                            container.playerViewModel.categorySeed = title
                            router.presentPlayer(queue: songs.shuffled(), startIndex: 0)
                        } label: {
                            Label("Shuffle All", systemImage: "shuffle")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(songs) { song in
                        Button {
                            let idx = songs.firstIndex(of: song) ?? 0
                            container.playerViewModel.categorySeed = title
                            router.presentPlayer(queue: songs, startIndex: idx)
                        } label: {
                            let isCurrent = container.playerViewModel.currentSong?.youtubeID == song.youtubeID
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    DhunifyAsyncImage(url: song.thumbnailURL, size: 110, cornerRadius: 14)
                                    if isCurrent {
                                        RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.4))
                                            .frame(width: 110, height: 110)
                                        NowPlayingBars(isPlaying: container.playerViewModel.isPlaying, size: 20)
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    sourceBadge(for: song)
                                }
                                Text(song.title)
                                    .font(.appHeadline)
                                    .foregroundStyle(isCurrent ? Color.appAccent : .white)
                                    .lineLimit(1)
                                Text(song.artist)
                                    .font(.appCaption)
                                    .foregroundStyle(.appSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 110)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func skeletonSection(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.appAccent)
                Text(title)
                    .font(.appLabel)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.appSecondary)
                Spacer()
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(0..<5, id: \.self) { _ in
                        CardSkeleton()
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // ── Album section (120pt cards) ──────────────────────────

    private func albumScrollSection(_ section: HomeAlbumSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: section.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.appAccent)
                Text(section.title)
                    .font(.appLabel)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.appSecondary)
                Spacer()
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(section.albums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                DhunifyAsyncImage(url: album.artworkURL, size: 120, cornerRadius: 14)
                                Text(album.title)
                                    .font(.appHeadline)
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Text(album.artist)
                                    .font(.appCaption)
                                    .foregroundStyle(.appSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                Task { await playAlbumByID(album.id, shuffle: false) }
                            } label: {
                                Label("Play Album", systemImage: "play.fill")
                            }
                            Button {
                                Task { await playAlbumByID(album.id, shuffle: true) }
                            } label: {
                                Label("Shuffle Album", systemImage: "shuffle")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .navigationDestination(for: AlbumResult.self) { album in
            AlbumDetailView(album: album)
        }
    }

    private func playAlbumByID(_ albumID: String, shuffle: Bool) async {
        guard var components = URLComponents(string: Config.backendBaseURL) else { return }
        components.path = "/album"
        components.queryItems = [URLQueryItem(name: "id", value: albumID)]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let detail = try JSONDecoder().decode(AlbumDetail.self, from: data)
            guard !detail.songs.isEmpty else { return }
            let queue = shuffle ? detail.songs.shuffled() : detail.songs
            router.presentPlayer(queue: queue, startIndex: 0)
        } catch {
            Logger(subsystem: "com.diphoria.Dhunify", category: "Home")
                .error("playAlbumByID failed: \(error.localizedDescription)")
        }
    }
}

// Color hex (keep for backward compat)
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
