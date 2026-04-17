//
//  ArtistView.swift
//  Dhunify
//
//  Artist page — shows all songs by an artist via JioSaavn search.
//  Tap artist name anywhere in the app → this view.
//

import SwiftUI

struct ArtistView: View {
    let artistName: String
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [Song] = []
    @State private var albums: [AlbumResult] = []
    @State private var isLoading = true

    private var topSongs: [Song] {
        Array(songs.prefix(5))
    }

    private var relatedArtists: [String] {
        let all = songs.flatMap { $0.artist.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        let unique = Array(Set(all))
        return unique
            .filter { !$0.isEmpty && $0.lowercased() != artistName.lowercased() }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Artist header
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.appAccent.opacity(0.15))
                                .frame(width: 100, height: 100)
                            Text(String(artistName.prefix(1)).uppercased())
                                .font(.system(size: 40, weight: .bold))
                                .foregroundStyle(.appAccent)
                        }
                        .padding(.top, 20)

                        Text(artistName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)

                        if !songs.isEmpty {
                            Text("\(songs.count) songs")
                                .font(.system(size: 14))
                                .foregroundStyle(.appSecondary)
                        }

                        // Play All / Shuffle
                        if !songs.isEmpty {
                            HStack(spacing: 12) {
                                Button {
                                    router.presentPlayer(queue: songs, startIndex: 0)
                                } label: {
                                    Label("Play All", systemImage: "play.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 10)
                                        .background(Capsule().fill(Color.appAccent))
                                }
                                .buttonStyle(ScalePressButtonStyle())

                                Button {
                                    router.presentPlayer(queue: songs.shuffled(), startIndex: 0)
                                } label: {
                                    Label("Shuffle", systemImage: "shuffle")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.appAccent)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Capsule().strokeBorder(Color.appAccent, lineWidth: 1))
                                }
                                .buttonStyle(ScalePressButtonStyle())
                            }
                        }
                    }

                    // Top songs strip
                    if !topSongs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TOP SONGS")
                                .font(.appLabel)
                                .tracking(1.2)
                                .foregroundColor(.appSecondary)
                                .padding(.horizontal, 20)

                            LazyVStack(spacing: 4) {
                                ForEach(Array(topSongs.enumerated()), id: \.element.id) { idx, song in
                                    SongRowView(
                                        song: song,
                                        isCurrentlyPlaying: container.playerViewModel.currentSong?.youtubeID == song.youtubeID,
                                        onTap: { router.presentPlayer(queue: songs, startIndex: idx) }
                                    )
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                    }

                    // Albums section
                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Albums")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(albums) { album in
                                        NavigationLink(value: album) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                DhunifyAsyncImage(url: album.artworkURL, size: 110, cornerRadius: 8)
                                                Text(album.title)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(2)
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

                    // Songs list
                    if isLoading {
                        ForEach(0..<6, id: \.self) { _ in SkeletonRowView() }
                            .padding(.horizontal, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Songs")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)

                            LazyVStack(spacing: 4) {
                                ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                                    SongRowView(
                                        song: song,
                                        isCurrentlyPlaying: container.playerViewModel.currentSong?.youtubeID == song.youtubeID,
                                        onTap: { router.presentPlayer(queue: songs, startIndex: idx) }
                                    )
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                    }

                    // Related artists
                    if !relatedArtists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("RELATED ARTISTS")
                                .font(.appLabel)
                                .tracking(1.2)
                                .foregroundColor(.appSecondary)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(relatedArtists, id: \.self) { name in
                                        NavigationLink(value: name) {
                                            Text(name)
                                                .font(.appCaption)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(Capsule().fill(Color.appSurface))
                                                .overlay(
                                                    Capsule()
                                                        .strokeBorder(Color.appOcean.opacity(0.4), lineWidth: 0.5)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }

                    Spacer(minLength: 80)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .navigationDestination(for: AlbumResult.self) { album in
            AlbumDetailView(album: album)
        }
        .task { await loadArtist() }
    }

    private func loadArtist() async {
        isLoading = true
        defer { isLoading = false }

        // Songs
        do {
            let raw = try await container.searchSongsUseCase.execute(query: "\(artistName) songs")
            songs = HiddenSongsManager.shared.filtered(raw)
        } catch {
            songs = []
        }

        // Albums
        guard var components = URLComponents(string: Config.backendBaseURL) else { return }
        components.path = "/search/albums"
        components.queryItems = [URLQueryItem(name: "q", value: artistName)]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            albums = try JSONDecoder().decode([AlbumResult].self, from: data)
        } catch {
            albums = []
        }
    }
}
