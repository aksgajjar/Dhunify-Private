//
//  QueueView.swift
//  Dhunify
//
//  Shows current play queue. Reorder, remove, tap to play.
//

import SwiftUI

struct QueueView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    private var vm: PlayerViewModel { container.playerViewModel }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Text("Queue")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(vm.queue.count) songs")
                        .font(.system(size: 13))
                        .foregroundStyle(.appSecondary)

                    if vm.queue.count > 1 {
                        Button {
                            HapticManager.medium()
                            vm.clearQueueExceptCurrent()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.appSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.appSurface))
                        }
                        .accessibilityLabel("Clear queue")
                    }

                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.appSecondary)
                    }
                    .accessibilityLabel("Close queue")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Now playing
                if let song = vm.currentSong {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundStyle(.appAccent)
                        Text("Now Playing")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.appAccent)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)

                    SongRowView(song: song, onTap: {})
                        .padding(.horizontal, 8)
                        .background(Color.appAccent.opacity(0.08))

                    Divider().overlay(Color.appSurface).padding(.vertical, 8)
                }

                // Up next
                if vm.queue.count > 1 {
                    HStack {
                        Text("Up Next")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.appSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                }

                // "Up Next" is the queue minus the current track, kept
                // as a separate array so drag-reorder offsets are simple
                // (no index holes from filtering). On reorder/remove we
                // rebuild the full queue by re-inserting the current
                // song at its position and call setQueue — no changes
                // to PlayerViewModel internals.
                let upNext: [Song] = {
                    guard vm.queue.indices.contains(vm.currentIndex) else { return vm.queue }
                    var q = vm.queue
                    q.remove(at: vm.currentIndex)
                    return q
                }()

                List {
                    ForEach(Array(upNext.enumerated()), id: \.element.id) { upIndex, song in
                        SongRowView(song: song, onTap: {
                            let queueIndex = queueIndex(forUpNext: upIndex, in: vm.queue, currentIndex: vm.currentIndex)
                            vm.setQueue(vm.queue, startIndex: queueIndex)
                            vm.play()
                        })
                        .listRowBackground(Color.appBackground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .swipeActions(edge: .leading) {
                            Button {
                                playNext(song: song, upNextIndex: upIndex, upNext: upNext)
                            } label: {
                                Label("Play Next", systemImage: "text.insert")
                            }
                            .tint(.appAccent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                remove(upNextIndex: upIndex, upNext: upNext)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                    .onMove { source, destination in
                        reorder(source: source, destination: destination, upNext: upNext)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // No explicit edit-mode: SwiftUI enables long-press
                // drag on rows with `.onMove` in iOS 16+. Keeps the UI
                // clean (no delete bullets) while letting users reorder
                // with a familiar iOS gesture.
            }
        }
    }

    // MARK: - Queue edits
    //
    // All edits rebuild the full queue array by taking the upNext list
    // (post-edit) and re-inserting the current song at `currentIndex`.
    // This keeps currentIndex stable so playback doesn't get bumped.

    private func queueIndex(forUpNext upIndex: Int, in queue: [Song], currentIndex: Int) -> Int {
        // upNext is queue with currentIndex removed. Map back:
        upIndex < currentIndex ? upIndex : upIndex + 1
    }

    private func rebuild(upNext: [Song]) {
        guard let current = vm.currentSong else {
            vm.setQueue(upNext, startIndex: 0)
            return
        }
        var rebuilt = upNext
        let insertAt = min(vm.currentIndex, rebuilt.count)
        rebuilt.insert(current, at: insertAt)
        vm.setQueue(rebuilt, startIndex: insertAt)
    }

    private func reorder(source: IndexSet, destination: Int, upNext: [Song]) {
        var list = upNext
        list.move(fromOffsets: source, toOffset: destination)
        HapticManager.soft()
        rebuild(upNext: list)
    }

    private func remove(upNextIndex: Int, upNext: [Song]) {
        var list = upNext
        guard list.indices.contains(upNextIndex) else { return }
        list.remove(at: upNextIndex)
        rebuild(upNext: list)
    }

    private func playNext(song: Song, upNextIndex: Int, upNext: [Song]) {
        // Remove from wherever it is, then insert at position 0 of
        // upNext (i.e. immediately after the current track).
        var list = upNext
        guard list.indices.contains(upNextIndex) else { return }
        list.remove(at: upNextIndex)
        list.insert(song, at: 0)
        HapticManager.medium()
        rebuild(upNext: list)
    }
}
