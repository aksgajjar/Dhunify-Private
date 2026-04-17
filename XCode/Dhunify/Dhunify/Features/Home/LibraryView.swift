//
//  LibraryView.swift
//  Dhunify
//
//  Library feature UI. Reads AppContainer from the environment, builds
//  its LibraryViewModel lazily on first appearance, and drives
//  navigation through the shared AppRouter. Reuses SongRowView and
//  SkeletonRowView from the Search feature so the two screens stay
//  visually consistent.
//

import SwiftUI

struct LibraryView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @State private var viewModel: LibraryViewModel?
    @State private var downloadedSongs: [DownloadedSong] = []

    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            if let viewModel {
                LibraryContent(
                    viewModel: viewModel,
                    router: router,
                    downloadManager: container.downloadManager,
                    downloadedSongs: $downloadedSongs
                )
            } else {
                VStack(spacing: 4) {
                    ForEach(0..<6, id: \.self) { _ in SongRowSkeleton() }
                }
                .padding(.top, 12)
            }
        }
        .task {
            if viewModel == nil {
                viewModel = LibraryViewModel(store: container.songStore)
            }
            await viewModel?.loadLibrary()
            refreshDownloads()
        }
        .onAppear { refreshDownloads() }
    }

    private func refreshDownloads() {
        downloadedSongs = container.downloadManager.fetchDownloaded()
    }
}

// MARK: - Content

private struct LibraryContent: View {
    @Bindable var viewModel: LibraryViewModel
    let router: AppRouter
    let downloadManager: DownloadManager
    @Binding var downloadedSongs: [DownloadedSong]
    @State private var pm = PlaylistManager.shared

    @State private var isSearching: Bool = false
    @State private var showCreatePlaylist: Bool = false
    @State private var newPlaylistName: String = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

            if isSearching {
                searchBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let message = viewModel.errorMessage {
                errorBanner(message)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            mainContent
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSearching)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.isLoading)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.filteredSongs)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.errorMessage)
        .navigationDestination(for: UUID.self) { playlistID in
            PlaylistDetailView(playlistID: playlistID)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
            Text("My Library")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            Button {
                toggleSearch()
            } label: {
                Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.appSurface))
            }
            .buttonStyle(ScalePressButtonStyle())
        }
    }

    private func toggleSearch() {
        if isSearching {
            viewModel.searchText = ""
            queryFocused = false
            isSearching = false
        } else {
            isSearching = true
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.appSecondary)

            TextField(
                "",
                text: $viewModel.searchText,
                prompt: Text("Search your library").foregroundStyle(.appSecondary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .tint(.appAccent)
            .submitLabel(.done)
            .focused($queryFocused)

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.appSecondary)
                }
                .buttonStyle(ScalePressButtonStyle())
                .transition(.opacity.combined(with: .scale))
            }

            Button {
                toggleSearch()
            } label: {
                Text("Cancel")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(ScalePressButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.appSurface)
        )
        .onAppear { queryFocused = true }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isLoading && viewModel.songs.isEmpty && downloadedSongs.isEmpty {
            loadingList
        } else if viewModel.songs.isEmpty && downloadedSongs.isEmpty {
            libraryEmptyState
        } else {
            libraryList
        }
    }

    private var libraryList: some View {
        List {
            // Quick access — Liked Songs shortcut. Persists across
            // sessions via LibraryStore. Saved albums aren't listed
            // separately; the bookmark toggle in AlbumDetailView
            // handles persistence and the saved count surfaces there.
            Section {
                NavigationLink(destination: LikedSongsView()) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.appAccent.opacity(0.2))
                                .frame(width: 48, height: 48)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.appAccent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Liked Songs")
                                .font(.appHeadline)
                                .foregroundStyle(.white)
                            Text("\(LibraryStore.shared.likedSongs.count) saved")
                                .font(.appCaption)
                                .foregroundStyle(.appSecondary)
                        }
                    }
                }
                .listRowBackground(Color.appBackground)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
            }

            // Playlists section
            Section {
                if !pm.currentPlaylists.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(pm.currentPlaylists) { playlist in
                                NavigationLink(value: playlist.id) {
                                    VStack(spacing: 6) {
                                        Text(playlist.emoji)
                                            .font(.system(size: 28))
                                            .frame(width: 70, height: 70)
                                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.appAccent.opacity(0.15)))
                                        Text(playlist.name)
                                            .font(.appHeadline)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text("\(playlist.songCount)")
                                            .font(.appCaption)
                                            .foregroundStyle(.appSecondary)
                                    }
                                    .frame(width: 80)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.appBackground)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 13)).foregroundStyle(.appAccent)
                    Text("Playlists (\(pm.currentPlaylists.count))")
                        .font(.appLabel)
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(.appSecondary)
                    Spacer()
                    if pm.canCreate {
                        Button { showCreatePlaylist = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.appAccent)
                        }
                    }
                }
            }

            // Downloaded songs section
            if !downloadedSongs.isEmpty {
                Section {
                    ForEach(downloadedSongs, id: \.songID) { downloaded in
                        let song = downloaded.toSong()
                        SongRowView(
                            song: song,
                            isDownloading: false,
                            isAlreadyDownloaded: true,
                            onDownload: {},
                            onTap: {
                                let queue = downloadedSongs.map { $0.toSong() }
                                let idx = downloadedSongs.firstIndex(where: { $0.songID == downloaded.songID }) ?? 0
                                router.presentPlayer(queue: queue, startIndex: idx)
                            }
                        )
                        .listRowBackground(Color.appBackground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                downloadManager.deleteSong(downloaded)
                                downloadedSongs = downloadManager.fetchDownloaded()
                            } label: {
                                Label("Delete", systemImage: "trash.fill")
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.appAccent)
                        Text("Downloaded (\(downloadedSongs.count))")
                            .font(.appLabel)
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(.appSecondary)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                }
            }

            // Saved library songs
            if !viewModel.filteredSongs.isEmpty {
                Section {
                    ForEach(viewModel.filteredSongs) { song in
                        SongRowView(
                            song: song,
                            isDownloading: false,
                            isAlreadyDownloaded: downloadManager.isDownloaded(song.youtubeID),
                            onDownload: {
                                downloadManager.download(song: song)
                            },
                            onTap: { tap(song) }
                        )
                        .listRowBackground(Color.appBackground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteSong(song) }
                            } label: {
                                Label("Delete", systemImage: "trash.fill")
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    Text("Saved")
                        .font(.appLabel)
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(.appSecondary)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .scrollDismissesKeyboard(.immediately)
        .alert("New Playlist", isPresented: $showCreatePlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pm.createPlaylist(name: trimmed, emoji: "🎵")
                }
                newPlaylistName = ""
            }
        } message: {
            Text("Enter a name for your new playlist")
        }
    }

    private var loadingList: some View {
        VStack(spacing: 12) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonRowView()
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    // MARK: - Empty states

    @State private var emptyPulse = false

    private var libraryEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.appAccent.opacity(emptyPulse ? 0.12 : 0.05))
                    .frame(width: 120, height: 120)
                    .scaleEffect(emptyPulse ? 1.1 : 0.9)

                Image(systemName: "music.note.list")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.appAccent.opacity(0.7))
                    .scaleEffect(emptyPulse ? 1.05 : 0.95)
            }
            .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: emptyPulse)
            .onAppear { emptyPulse = true }

            Text("Your library is empty")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text("Search for songs and tap ♡ to save them here")
                .font(.system(size: 14))
                .foregroundStyle(.appSecondary)
                .multilineTextAlignment(.center)

            Button { showCreatePlaylist = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                    Text("Create Playlist")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.appAccent))
            }
            .buttonStyle(ScalePressButtonStyle())
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.appSecondary)
            Text("No results for \"\(viewModel.searchText)\"")
                .font(.system(size: 14))
                .foregroundStyle(.appSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Error banner

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
                viewModel.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.appSecondary)
            }
            .buttonStyle(ScalePressButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appSurface)
        )
    }

    // MARK: - Actions

    private func tap(_ song: Song) {
        let current = viewModel.filteredSongs
        let startIndex = current.firstIndex(of: song) ?? 0
        router.presentPlayer(queue: current, startIndex: startIndex)
    }
}
