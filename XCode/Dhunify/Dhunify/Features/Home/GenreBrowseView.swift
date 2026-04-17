//
//  GenreBrowseView.swift
//  Dhunify
//
//  Dedicated browse grid of large genre tiles. Tap a tile → fires a
//  search for that genre's curated query and presents the full player
//  queue built from the results.
//

import SwiftUI

struct GenreBrowseView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var loadingGenre: String? = nil

    private let tiles: [Tile] = [
        Tile(name: "Bollywood",  icon: "film.fill",            query: "bollywood hits 2026",       colorA: "#FF6B6B", colorB: "#C2185B"),
        Tile(name: "Gujarati",   icon: "music.note.list",      query: "gujarati songs 2026",       colorA: "#FB8C00", colorB: "#E65100"),
        Tile(name: "Oldies",     icon: "clock.arrow.circlepath", query: "old hindi classic songs", colorA: "#5C6BC0", colorB: "#283593"),
        Tile(name: "Dance",      icon: "bolt.fill",            query: "party dance bollywood",     colorA: "#E91E63", colorB: "#880E4F"),
        Tile(name: "Love",       icon: "heart.fill",           query: "romantic hindi songs latest", colorA: "#EC407A", colorB: "#AD1457"),
        Tile(name: "Chill",      icon: "leaf.fill",            query: "chill lofi hindi",          colorA: "#26A69A", colorB: "#00695C"),
        Tile(name: "Sufi",       icon: "wind",                 query: "sufi songs hindi",          colorA: "#8E24AA", colorB: "#4A148C"),
        Tile(name: "Classical",  icon: "tuningfork",           query: "indian classical music",    colorA: "#7E57C2", colorB: "#4527A0"),
        Tile(name: "Devotional", icon: "hands.and.sparkles.fill", query: "hindi bhajan devotional", colorA: "#F57C00", colorB: "#E65100"),
    ]

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("BROWSE")
                        .font(.appLabel)
                        .tracking(1.2)
                        .foregroundColor(.appSecondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(tiles) { tile in
                            tileView(tile)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tileView(_ tile: Tile) -> some View {
        Button {
            HapticManager.soft()
            Task { await play(tile) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(hex: tile.colorA), Color(hex: tile.colorB)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: tile.icon)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.2))
                    .offset(x: 60, y: -30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if loadingGenre == tile.name {
                        HStack(spacing: 5) {
                            ProgressView().tint(.white).scaleEffect(0.6)
                            Text("Loading...")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .padding(14)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .scaleButton(0.96)
        .accessibilityLabel("Browse \(tile.name)")
    }

    private func play(_ tile: Tile) async {
        loadingGenre = tile.name
        defer { loadingGenre = nil }
        do {
            let songs = try await container.searchSongsUseCase.execute(query: tile.query)
            let filtered = HiddenSongsManager.shared.filtered(songs)
            guard !filtered.isEmpty else { return }
            container.playerViewModel.categorySeed = tile.query
            router.presentPlayer(queue: filtered, startIndex: 0)
        } catch {
            // Silent fail — tile stays tappable for retry.
        }
    }

    struct Tile: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let query: String
        let colorA: String
        let colorB: String
    }
}
