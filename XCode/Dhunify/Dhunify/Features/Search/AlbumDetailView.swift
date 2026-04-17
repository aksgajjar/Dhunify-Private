//
//  AlbumDetailView.swift
//  Dhunify
//
//  Album detail with hero artwork, track list, play/download all.
//

import SwiftUI

struct AlbumResult: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: String
    let songCount: Int
    let year: String
}

struct AlbumDetail: Codable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: String
    let year: String
    let songCount: Int
    let songs: [Song]

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, artworkURL, year, songCount, songs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        artworkURL = try c.decode(String.self, forKey: .artworkURL)
        year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount) ?? 0

        struct SongDTO: Decodable {
            let title: String
            let artist: String
            let thumbnailURL: String
            let youtubeID: String
            let duration: TimeInterval
        }
        let dtos = try c.decode([SongDTO].self, forKey: .songs)
        songs = dtos.map {
            Song(title: $0.title, artist: $0.artist, thumbnailURL: $0.thumbnailURL,
                 youtubeID: $0.youtubeID, duration: $0.duration)
        }
    }

    func encode(to encoder: Encoder) throws {
        // Not needed — decode only.
    }
}

struct AlbumDetailView: View {
    let album: AlbumResult
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var detail: AlbumDetail?
    @State private var isLoading = true
    @State private var library = LibraryStore.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if isLoading {
                albumSkeleton
            } else if let detail {
                albumContent(detail)
            } else {
                Text("Could not load album")
                    .foregroundStyle(.appSecondary)
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
            ToolbarItem(placement: .navigationBarTrailing) {
                let saved = library.isSaved(album)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    library.toggleSave(album)
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(saved ? .appAccent : .white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .task { await loadAlbum() }
    }

    private func albumContent(_ detail: AlbumDetail) -> some View {
        let isYouTube = album.id.hasPrefix("yt_")
        return ScrollView {
            VStack(spacing: 16) {
                // Hero artwork
                DhunifyAsyncImage(url: detail.artworkURL, size: 240, cornerRadius: 18)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)

                // Title + artist
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text(detail.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if isYouTube {
                            Text("YouTube")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(hex: "#FF0000").opacity(0.85))
                                .clipShape(Capsule())
                        }
                    }
                    Text(detail.artist)
                        .font(.system(size: 15))
                        .foregroundStyle(.appSecondary)
                    if !detail.year.isEmpty {
                        Text(detail.year)
                            .font(.system(size: 13))
                            .foregroundStyle(.appSecondary)
                    }
                    if !isYouTube {
                        let totalMin = Int(detail.songs.reduce(0) { $0 + $1.duration }) / 60
                        Text("\(detail.songs.count) songs • \(totalMin) min")
                            .font(.system(size: 12))
                            .foregroundStyle(.appSecondary)
                    }
                }
                .padding(.horizontal, 32)

                if isYouTube {
                    // YouTube long-form: single Play Full Video CTA, no track list.
                    Button {
                        if let song = detail.songs.first {
                            router.presentPlayer(queue: [song], startIndex: 0)
                        }
                    } label: {
                        Label("Play Full Video", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.appAccent))
                    }
                    .buttonStyle(ScalePressButtonStyle())
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                } else {
                    // JioSaavn: Play / Shuffle / Download All + full track list.
                    HStack(spacing: 12) {
                        Button {
                            if !detail.songs.isEmpty {
                                router.presentPlayer(queue: detail.songs, startIndex: 0)
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Color.appAccent))
                        }
                        .buttonStyle(ScalePressButtonStyle())

                        Button {
                            if !detail.songs.isEmpty {
                                router.presentPlayer(queue: detail.songs.shuffled(), startIndex: 0)
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.appAccent)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Capsule().strokeBorder(Color.appAccent, lineWidth: 1))
                        }
                        .buttonStyle(ScalePressButtonStyle())

                        Button {
                            for song in detail.songs {
                                container.downloadManager.download(song: song)
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(.appAccent)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(ScalePressButtonStyle())
                    }
                    .padding(.top, 4)

                    LazyVStack(spacing: 8) {
                        ForEach(Array(detail.songs.enumerated()), id: \.element.id) { index, song in
                            SongRowView(
                                song: song,
                                isDownloading: container.downloadManager.activeDownloads.contains(song.youtubeID),
                                isAlreadyDownloaded: container.downloadManager.isDownloaded(song.youtubeID),
                                onDownload: { container.downloadManager.download(song: song) },
                                onTap: { router.presentPlayer(queue: detail.songs, startIndex: index) }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
            .padding(.top, 20)
        }
    }

    @State private var pulse = false

    private var albumSkeleton: some View {
        ScrollView {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 18).fill(Color.appSurface)
                    .frame(width: 240, height: 240)
                RoundedRectangle(cornerRadius: 6).fill(Color.appSurface)
                    .frame(width: 180, height: 20)
                RoundedRectangle(cornerRadius: 4).fill(Color.appSurface)
                    .frame(width: 120, height: 14)
                HStack(spacing: 12) {
                    Capsule().fill(Color.appSurface).frame(width: 100, height: 36)
                    Capsule().fill(Color.appSurface).frame(width: 100, height: 36)
                }
                .padding(.top, 8)
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.appSurface).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.appSurface).frame(height: 12).frame(maxWidth: .infinity)
                            RoundedRectangle(cornerRadius: 3).fill(Color.appSurface).frame(height: 10).frame(maxWidth: 100, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Spacer()
                    }
                    .frame(height: 56)
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 20)
        }
        .opacity(pulse ? 0.7 : 0.4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func loadAlbum() async {
        isLoading = true
        defer { isLoading = false }

        guard var components = URLComponents(string: Config.backendBaseURL) else { return }
        components.path = "/album"
        components.queryItems = [URLQueryItem(name: "id", value: album.id)]
        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            detail = try JSONDecoder().decode(AlbumDetail.self, from: data)
        } catch {
            detail = nil
        }
    }
}
