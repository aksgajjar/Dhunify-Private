//
//  SearchView.swift
//  Dhunify
//
//  Search feature UI. Premium dark, Shopify-inspired minimal look.
//  Reads AppContainer / AppRouter from the environment, lazily builds
//  its SearchViewModel, and drives navigation through AppRouter.
//

import SwiftUI

// MARK: - Root

struct SearchView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @State private var viewModel: SearchViewModel?

    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            if let viewModel {
                SearchContent(viewModel: viewModel, router: router, downloadManager: container.downloadManager)
            } else {
                ProgressView()
                    .tint(.appAccent)
            }
        }
        .task {
            if viewModel == nil {
                let vm = SearchViewModel(
                    searchSongsUseCase: container.searchSongsUseCase,
                    downloadSongUseCase: container.downloadSongUseCase
                )
                viewModel = vm
                // Pre-warm the backend connection in the background so
                // the first real search feels instant.
                Task { await vm.prewarm() }
            }
        }
    }
}

// Notification bridge: content view listens, text field grabs focus.
extension Notification.Name {
    static let dhunifyFocusSearchField = Notification.Name("dhunify.focusSearchField")
}

// MARK: - Content

private struct SearchContent: View {
    @Bindable var viewModel: SearchViewModel
    let router: AppRouter
    let downloadManager: DownloadManager

    @FocusState private var queryFocused: Bool
    @State private var searchMode: SearchMode = .songs

    enum SearchMode: String, CaseIterable { case songs = "Songs"; case albums = "Albums" }

    private let genreChips: [(String, String)] = [
        ("🔥", "Trending"), ("🎬", "Bollywood"), ("💕", "Romantic"),
        ("🎉", "Party"), ("📻", "90s"), ("🚗", "Long Drive"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

            searchBar
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            // Genre chips
            genreChipBar
                .padding(.bottom, 8)

            // Songs / Albums switcher
            Picker("Mode", selection: $searchMode) {
                ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if let message = viewModel.errorMessage {
                errorBanner(message)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if searchMode == .songs {
                mainContent
            } else {
                albumContent
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.isLoading)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.results)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.errorMessage)
        .onAppear {
            if router.requestSearchKeyboardFocus {
                router.requestSearchKeyboardFocus = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    queryFocused = true
                }
            }
        }
        .onChange(of: router.requestSearchKeyboardFocus) { _, newValue in
            if newValue {
                router.requestSearchKeyboardFocus = false
                queryFocused = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Dhunify")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            Spacer()
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.appSecondary)

            TextField("", text: $viewModel.query, prompt:
                Text("Hindi, Gujarati ya English mein search karo...")
                    .foregroundStyle(.appSecondary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .tint(.appAccent)
            .submitLabel(.search)
            .focused($queryFocused)
            .onSubmit { triggerSearch() }

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                    viewModel.results = []
                    viewModel.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.appSecondary)
                }
                .buttonStyle(ScalePressButtonStyle())
                .transition(.opacity.combined(with: .scale))
            }

            Button(action: triggerSearch) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(viewModel.query.isEmpty ? Color.appSecondary : Color.appAccent)
            }
            .buttonStyle(ScalePressButtonStyle())
            .disabled(viewModel.query.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.appSurface)
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.query.isEmpty)

        if !AppConfig.openAIAPIKey.isEmpty {
            Text("AI search on")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.appOcean.opacity(0.8))
                .padding(.leading, 20)
                .padding(.top, 2)
        }
        } // end VStack
    }

    private func triggerSearch() {
        HapticManager.soft()
        queryFocused = false
        Task { await viewModel.search() }
    }

    // MARK: Main content

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isLoading && viewModel.results.isEmpty {
            loadingList
        } else if viewModel.results.isEmpty && !viewModel.query.isEmpty {
            // User typed something but no results yet (or search returned empty).
            if viewModel.isLoading {
                loadingList
            } else {
                noResultsState
            }
        } else if viewModel.results.isEmpty {
            emptyState
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView {
            // Shimmer skeletons while the first page is loading.
            if viewModel.isLoading && viewModel.results.isEmpty {
                VStack(spacing: 4) {
                    ForEach(0..<6, id: \.self) { _ in SongRowSkeleton() }
                }
                .padding(.top, 8)
            } else if viewModel.isLoading {
                // Thin progress when re-searching over existing results.
                ProgressView()
                    .tint(.appAccent)
                    .scaleEffect(0.7)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }

            sectionHeader(title: "Songs", count: viewModel.results.count)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 4)

            LazyVStack(spacing: 12) {
                ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, song in
                    SongRowView(
                        song: song,
                        isDownloading: downloadManager.activeDownloads.contains(song.youtubeID),
                        isAlreadyDownloaded: downloadManager.isDownloaded(song.youtubeID),
                        isCurrentlyPlaying: AppContainer.shared.playerViewModel.currentSong?.youtubeID == song.youtubeID,
                        highlightQuery: viewModel.query,
                        onDownload: {
                            downloadManager.download(song: song)
                        },
                        onTap: {
                            router.presentPlayer(queue: viewModel.results, startIndex: index)
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 80) // room for mini player + tab bar
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            await viewModel.search()
        }
    }

    private var loadingList: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonRowView()
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var emptyState: some View {
        Group {
            if !viewModel.recentSearches.isEmpty {
                recentSearchList
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.appSecondary)
                    Text("Search for your favorite songs")
                        .font(.system(size: 14))
                        .foregroundStyle(.appSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var recentSearchList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent Searches")
                        .font(.appLabel)
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(.appSecondary)
                    Spacer()
                    Button { viewModel.clearHistory() } label: {
                        Text("Clear")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.appAccent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                ForEach(viewModel.recentSearches, id: \.self) { text in
                    Button {
                        viewModel.searchFromHistory(text)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 14))
                                .foregroundStyle(.appSecondary)
                                .frame(width: 24)
                            Text(text)
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 12))
                                .foregroundStyle(.appSecondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.appSecondary)
            Text("No results for \"\(viewModel.query)\"")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Check the spelling or try different keywords.")
                .font(.system(size: 12))
                .foregroundStyle(.appSecondary)
                .multilineTextAlignment(.center)
            // Quick pivots so the user isn't stranded on a dead query.
            HStack(spacing: 8) {
                ForEach(["Trending", "Bollywood", "90s"], id: \.self) { suggestion in
                    Button {
                        viewModel.query = suggestion
                        Task { await viewModel.search() }
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.appSurface))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: Genre chips

    private var genreChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genreChips, id: \.1) { emoji, label in
                    let isActive = viewModel.query.lowercased() == label.lowercased()
                    Button {
                        viewModel.query = label
                        Task { await viewModel.search() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(emoji).font(.system(size: 12))
                            Text(label).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(isActive ? .white : .appSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(isActive ? Color.appAccent : Color.appSurface)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: Album content

    @ViewBuilder
    private var albumContent: some View {
        if viewModel.isLoading && viewModel.albumResults.isEmpty && viewModel.results.isEmpty {
            loadingList
        } else if viewModel.albumResults.isEmpty && viewModel.results.isEmpty {
            albumEmptyState
        } else if viewModel.albumResults.isEmpty {
            // Fallback: backend returned no albums for this query. Reuse the
            // song results so the Albums tab never feels broken or empty.
            albumFallbackSongs
        } else {
            ScrollView {
                sectionHeader(title: "Albums", count: viewModel.albumResults.count)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                LazyVStack(spacing: 10) {
                    ForEach(viewModel.albumResults) { album in
                        NavigationLink(value: album) {
                            albumRow(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // Album tab fallback when backend /search/albums returns nothing:
    // surface the YT music-shelf / video-shelf songs so the tab is useful
    // instead of empty. Tapping a row plays from the song list like the
    // Songs tab does.
    private var albumFallbackSongs: some View {
        ScrollView {
            sectionHeader(title: "Results", count: viewModel.results.count)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 4)

            LazyVStack(spacing: 12) {
                ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, song in
                    SongRowView(
                        song: song,
                        isDownloading: downloadManager.activeDownloads.contains(song.youtubeID),
                        isAlreadyDownloaded: downloadManager.isDownloaded(song.youtubeID),
                        isCurrentlyPlaying: AppContainer.shared.playerViewModel.currentSong?.youtubeID == song.youtubeID,
                        highlightQuery: viewModel.query,
                        onDownload: {
                            downloadManager.download(song: song)
                        },
                        onTap: {
                            router.presentPlayer(queue: viewModel.results, startIndex: index)
                        }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // Shared section header — count hint mirrors Spotify's "N results".
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.white)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.appSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.appSurface))
            Spacer()
        }
    }

    private var albumEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: viewModel.query.isEmpty ? "square.stack" : "rectangle.stack.badge.xmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.appSecondary)
            if viewModel.query.isEmpty {
                Text("Search for albums")
                    .font(.system(size: 14))
                    .foregroundStyle(.appSecondary)
            } else {
                Text("No albums for \"\(viewModel.query)\"")
                    .font(.system(size: 14))
                    .foregroundStyle(.appSecondary)
                    .multilineTextAlignment(.center)
                Text("Try a different title or artist.")
                    .font(.system(size: 12))
                    .foregroundStyle(.appSecondary.opacity(0.7))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private func albumRow(_ album: AlbumResult) -> some View {
        let isYouTube = album.id.hasPrefix("yt_")
        let q = viewModel.query
        return HStack(spacing: 12) {
            DhunifyAsyncImage(url: album.artworkURL, size: 56, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(searchHighlighted(album.title, match: q, base: .white))
                        .font(.appHeadline)
                        .lineLimit(1)
                    if isYouTube {
                        Text("YouTube")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(hex: "#FF0000").opacity(0.8))
                            .clipShape(Capsule())
                    }
                }
                Text(searchHighlighted(album.artist, match: q, base: .appSecondary))
                    .font(.appCaption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isYouTube {
                // `album.year` carries duration label like "1h 40m" for YT items.
                Text(album.year)
                    .font(.appCaption)
                    .foregroundStyle(.appSecondary)
            } else if album.songCount > 0 {
                Text("\(album.songCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.appAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.appAccent.opacity(0.15)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.appSurface))
    }

    // MARK: Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.appAccent)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                HapticManager.soft()
                Task { await viewModel.search() }
            } label: {
                Text("Retry")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.appAccent))
            }
            .buttonStyle(ScalePressButtonStyle())
            .accessibilityLabel("Retry search")

            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.appSecondary)
            }
            .buttonStyle(ScalePressButtonStyle())
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appSurface)
        )
    }
}

// MARK: - Query highlight helper
//
// Builds an AttributedString with matched substrings (case-insensitive,
// diacritic-insensitive) rendered in accent color + semibold, so the
// reason a result matched is obvious without extra UI.
//
// Used by SongRowView and the album row. Free function so non-view code
// can call it without pulling in SwiftUI state.
fileprivate func searchHighlighted(_ text: String, match query: String?, base: Color) -> AttributedString {
    var attr = AttributedString(text)
    attr.foregroundColor = base
    guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines),
          !query.isEmpty else { return attr }

    // Case + diacritic insensitive range scan. We walk the string
    // finding every non-overlapping occurrence and style each slice.
    let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    guard !needle.isEmpty else { return attr }

    var searchFrom = haystack.startIndex
    while let range = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
        let lower = text.index(text.startIndex, offsetBy: haystack.distance(from: haystack.startIndex, to: range.lowerBound))
        let upper = text.index(text.startIndex, offsetBy: haystack.distance(from: haystack.startIndex, to: range.upperBound))
        if let aLower = AttributedString.Index(lower, within: attr),
           let aUpper = AttributedString.Index(upper, within: attr) {
            attr[aLower..<aUpper].foregroundColor = Color.appAccent
            attr[aLower..<aUpper].font = .system(size: 15, weight: .semibold)
        }
        searchFrom = range.upperBound
    }
    return attr
}

// MARK: - Song row (compact, 56pt, 3-dot menu)

struct SongRowView: View {
    let song: Song
    var isDownloading: Bool = false
    var isAlreadyDownloaded: Bool = false
    var isCurrentlyPlaying: Bool = false
    var highlightQuery: String? = nil
    var onDownload: () -> Void = {}
    let onTap: () -> Void
    @State private var showMenu = false
    @State private var showPlaylistSheet = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Artwork with EQ bars overlay when playing
                ZStack {
                    DhunifyAsyncImage(url: song.thumbnailURL, size: 44, cornerRadius: 10)
                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.5))
                            .frame(width: 44, height: 44)
                        NowPlayingBars(isPlaying: true, size: 16)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(searchHighlighted(song.title, match: highlightQuery,
                                               base: isCurrentlyPlaying ? Color.appAccent : .white))
                            .font(.appHeadline)
                            .lineLimit(1)
                        SourceBadge(song: song)
                    }
                    HStack(spacing: 4) {
                        NavigationLink(value: song.artist) {
                            Text(searchHighlighted(song.artist, match: highlightQuery,
                                                   base: .appSecondary))
                                .font(.appCaption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .layoutPriority(1)
                        if song.isYouTubeSource, let meta = songMetaText(song, leadingBullet: true) {
                            meta
                                .font(.appCaption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Downloaded indicator
                if isAlreadyDownloaded || song.isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.appAccent)
                }

                // 3-dot menu
                Button { showMenu = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundStyle(.appSecondary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .frame(height: 56)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            // Warm the /stream CDN connection so the tap feels instant.
            StreamPrewarmer.shared.prewarm(youtubeID: song.youtubeID)
        }
        .sheet(isPresented: $showMenu) {
            SongMenuSheet(
                song: song,
                isDownloading: isDownloading,
                isDownloaded: isAlreadyDownloaded || song.isDownloaded,
                onDownload: onDownload,
                onPlaylist: { showPlaylistSheet = true }
            )
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPlaylistSheet) {
            AddToPlaylistSheet(songID: song.youtubeID, songTitle: song.title, showLibraryOption: true, song: song) { _ in }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Song menu sheet (3-dot options)

private struct SongMenuSheet: View {
    let song: Song
    let isDownloading: Bool
    let isDownloaded: Bool
    let onDownload: () -> Void
    let onPlaylist: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var library = LibraryStore.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Song info header
                HStack(spacing: 10) {
                    DhunifyAsyncImage(url: song.thumbnailURL, size: 44, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(song.title).font(.appHeadline).foregroundStyle(.white).lineLimit(1)
                            SourceBadge(song: song)
                        }
                        Text(song.artist).font(.appCaption).foregroundStyle(.appSecondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(16)

                Divider().overlay(Color.appSurface)

                // Menu options
                VStack(spacing: 0) {
                    let liked = library.isLiked(song)
                    menuRow(liked ? "Liked" : "Like",
                            icon: liked ? "heart.fill" : "heart",
                            tint: liked ? .appAccent : .white,
                            action: {
                                library.toggleLike(song)
                                dismiss()
                            })

                    menuRow("Save to Playlist...", icon: "text.badge.plus", action: { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onPlaylist() } })

                    if isDownloading {
                        HStack(spacing: 12) {
                            ProgressView().tint(.appAccent).frame(width: 20, height: 20)
                            Text("Downloading...").font(.system(size: 15)).foregroundStyle(.appSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    } else if isDownloaded {
                        menuRow("Downloaded", icon: "checkmark.circle.fill", action: { dismiss() })
                    } else {
                        menuRow("Download", icon: "arrow.down.circle", action: { onDownload(); dismiss() })
                    }

                    menuRow("Play Next", icon: "text.insert", action: {
                        AppContainer.shared.playerViewModel.playNext(song: song)
                        dismiss()
                    })
                    menuRow("Add to Queue", icon: "text.badge.plus", action: {
                        AppContainer.shared.playerViewModel.addToQueue(song: song)
                        dismiss()
                    })
                    menuRow("Hide this song", icon: "eye.slash", action: {
                        HiddenSongsManager.shared.hide(song: song)
                        dismiss()
                    })
                    menuRow("Share", icon: "square.and.arrow.up", action: {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            ShareCardGenerator.share(song: song)
                        }
                    })
                }
            }
        }
    }

    private func menuRow(_ title: String, icon: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint).frame(width: 24)
                Text(title).font(.system(size: 15)).foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skeleton row

struct SkeletonRowView: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.appSecondary.opacity(0.25))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.appSecondary.opacity(0.25))
                    .frame(height: 12)
                    .frame(maxWidth: .infinity)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.appSecondary.opacity(0.25))
                    .frame(height: 10)
                    .frame(maxWidth: 100, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .frame(height: 56)
        .padding(.horizontal, 12)
        .opacity(pulse ? 0.8 : 0.4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Song row / card meta (views + duration)
//
// Shared between Search rows and Home horizontal cards. Views segment is
// accent-colored + semibold, duration is secondary. `leadingBullet = true`
// prepends " • " for use directly after an artist text (Search). Set to
// `false` for standalone lines (Home cards beneath artist).

/// Composed `Text` combining view count and duration. Returns `nil` when
/// neither segment is present (safely hides). View count is only carried on
/// YouTube videoRenderer results via `Song.viewCount`.
func songMetaText(_ song: Song, leadingBullet: Bool = true) -> Text? {
    let sep = Text(" • ").foregroundColor(.appSecondary)
    var parts: [Text] = []
    if let v = song.viewCount, v > 0 {
        parts.append(
            Text(searchFormatViews(v))
                .foregroundColor(.appAccent)
                .fontWeight(.semibold)
        )
    }
    if song.duration > 0 {
        parts.append(
            Text(searchFormatDurationShort(song.duration))
                .foregroundColor(.appSecondary)
        )
    }
    guard let first = parts.first else { return nil }
    var body = first
    for p in parts.dropFirst() {
        body = body + sep + p
    }
    return leadingBullet ? (sep + body) : body
}

func searchFormatViews(_ n: Int64) -> String {
    func fmt(_ val: Double, _ suffix: String) -> String {
        let rounded = (val * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))\(suffix) views"
        }
        return String(format: "%.1f%@ views", rounded, suffix)
    }
    if n >= 1_000_000_000 { return fmt(Double(n) / 1_000_000_000, "B") }
    if n >= 1_000_000 { return fmt(Double(n) / 1_000_000, "M") }
    if n >= 1_000 { return fmt(Double(n) / 1_000, "K") }
    return "\(n) views"
}

func searchFormatDurationShort(_ d: TimeInterval) -> String {
    let total = Int(d)
    if total < 60 { return "\(total) sec" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let rem = minutes % 60
    return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
}
