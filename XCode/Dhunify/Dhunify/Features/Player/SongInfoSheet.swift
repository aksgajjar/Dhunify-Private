//
//  SongInfoSheet.swift
//  Dhunify
//
//  Song credits & info bottom sheet. Fetches from /song/{id} API.
//

import SwiftUI

struct SongInfoSheet: View {
    let song: Song
    @State private var info: SongDetail? = nil
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Artwork
                    DhunifyAsyncImage(url: song.thumbnailURL, size: 160, cornerRadius: 16)
                        .padding(.top, 24)

                    // Title + artist
                    VStack(spacing: 4) {
                        Text(song.title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text(song.artist)
                            .font(.system(size: 15))
                            .foregroundStyle(.appAccent)
                    }
                    .padding(.horizontal, 20)

                    if isLoading {
                        ProgressView().tint(.appAccent).padding(.top, 20)
                    } else if let info {
                        // Info rows
                        VStack(spacing: 0) {
                            if !info.album.isEmpty { infoRow("Album", info.album) }
                            if !info.year.isEmpty { infoRow("Year", info.year) }
                            if !info.language.isEmpty { infoRow("Language", info.language.capitalized) }
                            infoRow("Duration", formatDuration(song.duration))
                            if info.has320 { infoRow("Quality", "320kbps AAC") }
                            if info.hasLyrics { infoRow("Lyrics", "Available") }
                        }
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.appSurface))
                        .padding(.horizontal, 20)
                    }

                    // Source
                    Text("Source: JioSaavn")
                        .font(.system(size: 11))
                        .foregroundStyle(.appSecondary)
                        .padding(.top, 8)

                    Spacer(minLength: 40)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.appSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.appBackground)
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        guard d.isFinite, d > 0 else { return "—" }
        let m = Int(d) / 60; let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }

    // Fetch from /song/{id}
    init(song: Song) {
        self.song = song
        _isLoading = State(initialValue: true)
    }

    struct SongDetail: Decodable {
        let album: String
        let year: String
        let language: String
        let has320: Bool
        let hasLyrics: Bool

        enum CodingKeys: String, CodingKey {
            case album, year, language
            case has320 = "has_320"
            case hasLyrics = "has_lyrics"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            album = (try? c.decode(String.self, forKey: .album)) ?? ""
            year = (try? c.decode(String.self, forKey: .year)) ?? ""
            language = (try? c.decode(String.self, forKey: .language)) ?? ""
            has320 = (try? c.decode(Bool.self, forKey: .has320)) ?? false
            hasLyrics = (try? c.decode(Bool.self, forKey: .hasLyrics)) ?? false
        }
    }
}

// Add .task to load on appear
extension SongInfoSheet {
    var loadingBody: some View {
        self.task {
            guard var components = URLComponents(string: Config.backendBaseURL) else { return }
            components.path = "/song/\(song.youtubeID)"
            guard let url = components.url else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                info = try JSONDecoder().decode(SongDetail.self, from: data)
            } catch {}
            isLoading = false
        }
    }
}
