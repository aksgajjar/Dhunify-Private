//
//  PlaylistDetailView.swift
//  Dhunify
//
//  Shows all songs in a playlist with play/shuffle/remove.
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: UUID
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var pm = PlaylistManager.shared
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var showAddSongs = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false

    private var playlist: UserPlaylist? { pm.playlist(for: playlistID) }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if let playlist {
                ScrollView {
                    VStack(spacing: 16) {
                        // Header
                        VStack(spacing: 8) {
                            Text(playlist.emoji)
                                .font(.system(size: 56))
                                .frame(width: 100, height: 100)
                                .background(Circle().fill(Color.appAccent.opacity(0.15)))

                            Text(playlist.name)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)

                            Text("\(playlist.songCount) songs\(!songs.isEmpty ? " • \(Int(songs.reduce(0) { $0 + $1.duration }) / 60) min" : "")")
                                .font(.system(size: 14))
                                .foregroundStyle(.appSecondary)
                        }
                        .padding(.top, 20)

                        // Actions
                        HStack(spacing: 16) {
                            Button {
                                if !songs.isEmpty { router.presentPlayer(queue: songs, startIndex: 0) }
                            } label: {
                                Label("Play All", systemImage: "play.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 24).padding(.vertical, 10)
                                    .background(Capsule().fill(Color.appAccent))
                            }
                            .buttonStyle(ScalePressButtonStyle())

                            Button {
                                if !songs.isEmpty {
                                    let shuffled = songs.shuffled()
                                    router.presentPlayer(queue: shuffled, startIndex: 0)
                                }
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.appAccent)
                                    .padding(.horizontal, 24).padding(.vertical, 10)
                                    .background(Capsule().strokeBorder(Color.appAccent, lineWidth: 1))
                            }
                            .buttonStyle(ScalePressButtonStyle())
                        }

                        // Songs
                        if isLoading {
                            ProgressView().tint(.appAccent).padding(.top, 20)
                        } else if songs.isEmpty {
                            Text("No songs in this playlist")
                                .font(.system(size: 14)).foregroundStyle(.appSecondary)
                                .padding(.top, 20)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                                    HStack(spacing: 0) {
                                        if isEditing {
                                            Button {
                                                pm.removeSong(song.youtubeID, from: playlistID)
                                                songs.removeAll { $0.youtubeID == song.youtubeID }
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(.red)
                                                    .frame(width: 36, height: 44)
                                            }
                                            .transition(.move(edge: .leading).combined(with: .opacity))
                                        }
                                        SongRowView(
                                            song: song,
                                            isDownloading: container.downloadManager.activeDownloads.contains(song.youtubeID),
                                            isAlreadyDownloaded: container.downloadManager.isDownloaded(song.youtubeID),
                                            onDownload: { container.downloadManager.download(song: song) },
                                            onTap: {
                                                if !isEditing { router.presentPlayer(queue: songs, startIndex: idx) }
                                            }
                                        )
                                    }
                                    .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isEditing)
                                }
                            }
                            .padding(.horizontal, 20)
                        }

                        Spacer(minLength: 40)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button { showAddSongs = true } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(.appAccent)
                    }
                    Button { isEditing.toggle() } label: {
                        Text(isEditing ? "Done" : "Edit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.appAccent)
                    }
                    Menu {
                        Button {
                            renameText = playlist?.name ?? ""
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.appAccent)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSongs) {
            PlaylistAddSongsSheet(playlistID: playlistID) {
                Task { await loadSongs() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Playlist name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                pm.renamePlaylist(playlistID, to: renameText)
            }
        }
        .alert("Delete Playlist?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                pm.deletePlaylist(playlistID)
                dismiss()
            }
        } message: {
            Text("This will remove the playlist. Songs stay in your library.")
        }
        .task { await loadSongs() }
    }

    private func loadSongs() async {
        guard let playlist else { isLoading = false; return }
        let ids = playlist.songIDs
        // Parallel fetch — sequential /song/<id> calls froze the screen
        // on playlists with >3 songs. Bounded by songIDs count (max 100s).
        struct SongDTO: Decodable {
            let title: String; let artist: String; let thumbnailURL: String
            let youtubeID: String; let duration: TimeInterval
        }
        let loaded: [Song] = await withTaskGroup(of: (Int, Song?).self) { group in
            for (idx, songID) in ids.enumerated() {
                group.addTask {
                    guard var components = URLComponents(string: Config.backendBaseURL) else { return (idx, nil) }
                    components.path = "/song/\(songID)"
                    guard let url = components.url else { return (idx, nil) }
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        let dto = try JSONDecoder().decode(SongDTO.self, from: data)
                        return (idx, Song(title: dto.title, artist: dto.artist, thumbnailURL: dto.thumbnailURL, youtubeID: dto.youtubeID, duration: dto.duration))
                    } catch {
                        return (idx, nil)
                    }
                }
            }
            var buf: [(Int, Song)] = []
            for await (idx, song) in group {
                if let song { buf.append((idx, song)) }
            }
            return buf.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        songs = loaded
        isLoading = false
    }
}

// MARK: - Add songs to playlist sheet

struct PlaylistAddSongsSheet: View {
    let playlistID: UUID
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Song] = []
    @State private var isSearching = false
    @State private var pm = PlaylistManager.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Add Songs")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Done") { dismiss(); onDone() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.appAccent)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // Search bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.appSecondary)
                    TextField("", text: $query, prompt: Text("Search songs...").foregroundStyle(.appSecondary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .tint(.appAccent)
                        .submitLabel(.search)
                        .onSubmit { search() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.appSurface))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                if isSearching {
                    ProgressView().tint(.appAccent).padding(.top, 20)
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    Text("Search to find songs to add")
                        .font(.system(size: 14)).foregroundStyle(.appSecondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(results) { song in
                                let alreadyAdded = pm.playlist(for: playlistID)?.songIDs.contains(song.youtubeID) ?? false
                                Button {
                                    if !alreadyAdded {
                                        pm.addSong(song.youtubeID, to: playlistID)
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        DhunifyAsyncImage(url: song.thumbnailURL, size: 44, cornerRadius: 6)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(song.title)
                                                    .font(.system(size: 14, weight: .medium))
                                                    .foregroundStyle(.white).lineLimit(1)
                                                SourceBadge(song: song)
                                            }
                                            Text(song.artist)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.appSecondary).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        if alreadyAdded {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 18)).foregroundStyle(.appAccent)
                                        } else {
                                            Image(systemName: "plus.circle")
                                                .font(.system(size: 18)).foregroundStyle(.appAccent)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 56)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        Task {
            do {
                results = try await AppContainer.shared.songRepository.search(query: trimmed)
            } catch {
                results = []
            }
            isSearching = false
        }
    }
}
