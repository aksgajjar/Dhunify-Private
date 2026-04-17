//
//  AddToPlaylistSheet.swift
//  Dhunify
//
//  Sheet for adding a song to an existing or new playlist.
//  Reused from PlayerView and SongRowView context menu.
//

import SwiftUI

struct AddToPlaylistSheet: View {
    let songID: String
    let songTitle: String
    var showLibraryOption: Bool = false
    var song: Song? = nil
    let onDone: (String) -> Void  // callback with playlist name
    @Environment(\.dismiss) private var dismiss
    @State private var pm = PlaylistManager.shared
    @State private var showCreate = false

    private let emojiOptions = ["🎵", "🎧", "🎤", "🎸", "🎹", "🎶", "🎷", "🥁", "🎻", "💜", "🌙", "⭐", "🦋", "🌸", "🔥", "💫"]

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                Text("Add to Playlist")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 20)

                Text(songTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.appSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 20)

                if pm.currentPlaylists.isEmpty || showCreate {
                    createForm
                } else {
                    playlistList
                }

                Spacer()
            }
        }
    }

    // MARK: - Existing playlists

    private var playlistList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Save to Library option
                    if showLibraryOption, let song {
                        Button {
                            Task { try? await AppContainer.shared.songStore.save(song: song) }
                            onDone("Library")
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.appAccent)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Color.appAccent.opacity(0.15)))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("My Library")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text("Saved songs")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.appSecondary)
                                }

                                Spacer()
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.appSurface))
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(pm.currentPlaylists) { playlist in
                        Button {
                            pm.addSong(songID, to: playlist.id)
                            onDone(playlist.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(playlist.emoji)
                                    .font(.system(size: 24))
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Color.appAccent.opacity(0.15)))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text("\(playlist.songCount) songs")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.appSecondary)
                                }

                                Spacer()

                                if playlist.songIDs.contains(songID) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.appAccent)
                                        .font(.system(size: 14, weight: .bold))
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.appSurface))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }

            if pm.canCreate {
                Button { showCreate = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                        Text("Create New Playlist")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.appAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.appAccent.opacity(0.1)))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Create new playlist

    @State private var newName = ""
    @State private var newEmoji = "🎵"

    private var createForm: some View {
        VStack(spacing: 16) {
            // Emoji picker
            Text(newEmoji)
                .font(.system(size: 44))
                .frame(width: 80, height: 80)
                .background(Circle().fill(Color.appAccent.opacity(0.15)))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 6) {
                ForEach(emojiOptions, id: \.self) { emoji in
                    Button { newEmoji = emoji } label: {
                        Text(emoji)
                            .font(.system(size: 22))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(newEmoji == emoji ? Color.appAccent.opacity(0.3) : .clear))
                    }
                }
            }
            .padding(.horizontal, 20)

            TextField("", text: $newName, prompt: Text("Playlist name").foregroundStyle(.appSecondary))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .tint(.appAccent)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.appSurface))
                .padding(.horizontal, 20)

            Button {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let playlist = pm.createPlaylist(name: trimmed, emoji: newEmoji)
                pm.addSong(songID, to: playlist.id)
                onDone(trimmed)
                dismiss()
            } label: {
                Text("Create & Add")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? Color.appSecondary.opacity(0.3) : Color.appAccent)
                    )
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 20)

            if !pm.currentPlaylists.isEmpty {
                Button { showCreate = false } label: {
                    Text("Back to playlists")
                        .font(.system(size: 13))
                        .foregroundStyle(.appSecondary)
                }
            }
        }
    }
}
