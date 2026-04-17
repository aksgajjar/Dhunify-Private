//
//  LikedSongsView.swift
//  Dhunify
//
//  Dedicated screen listing the user's liked songs, newest first.
//  Reads from LibraryStore.shared so changes elsewhere (Search menu,
//  Player, etc.) reflect here instantly.
//

import SwiftUI

struct LikedSongsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @State private var library = LibraryStore.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if library.likedSongs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 16)

                    LazyVStack(spacing: 8) {
                        ForEach(Array(library.likedSongs.enumerated()), id: \.element.id) { index, song in
                            SongRowView(
                                song: song,
                                isCurrentlyPlaying: container.playerViewModel.currentSong?.youtubeID == song.youtubeID,
                                onTap: {
                                    router.presentPlayer(queue: library.likedSongs, startIndex: index)
                                }
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    library.unlike(youtubeID: song.youtubeID)
                                } label: {
                                    Label("Unlike", systemImage: "heart.slash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 80)
                }
            }
        }
        .navigationTitle("Liked Songs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.appAccent.opacity(0.18))
                    .frame(width: 64, height: 64)
                Image(systemName: "heart.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.appAccent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Liked Songs")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(library.likedSongs.count) song\(library.likedSongs.count == 1 ? "" : "s")")
                    .font(.system(size: 13))
                    .foregroundStyle(.appSecondary)
            }
            Spacer()
            Button {
                router.presentPlayer(queue: library.likedSongs, startIndex: 0)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.appAccent))
            }
            .buttonStyle(ScalePressButtonStyle())
            .disabled(library.likedSongs.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "heart")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.appSecondary)
            Text("No liked songs yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text("Tap the heart on any song to save it here.")
                .font(.system(size: 12))
                .foregroundStyle(.appSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}
