//
//  MiniPlayerView.swift
//  Dhunify
//
//  60pt mini player. Swipe down or tap × to dismiss.
//

import SwiftUI

struct MiniPlayerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @State private var dragOffset: CGFloat = 0

    var namespace: Namespace.ID? = nil

    private var vm: PlayerViewModel { container.playerViewModel }

    var body: some View {
        if vm.currentSong != nil {
            VStack(spacing: 0) {
                // 2pt progress bar. Animated so scrubs / auto-advance
                // feel continuous rather than snappy.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.appSecondary.opacity(0.15))
                            .frame(height: 2)
                        Rectangle()
                            .fill(Color.appAccent)
                            .frame(width: max(0, geo.size.width * vm.progress), height: 2)
                            .animation(.linear(duration: 0.4), value: vm.progress)
                    }
                }
                .frame(height: 2)

                // Content
                HStack(spacing: 10) {
                    // Tap area → open full player
                    Button {
                        router.presentPlayer(queue: vm.queue, startIndex: vm.currentIndex)
                    } label: {
                        HStack(spacing: 10) {
                            Group {
                                if let ns = namespace {
                                    DhunifyAsyncImage(url: vm.currentSong?.thumbnailURL ?? "", size: 40, cornerRadius: 10)
                                        .matchedGeometryEffect(id: "playerArtwork", in: ns)
                                } else {
                                    DhunifyAsyncImage(url: vm.currentSong?.thumbnailURL ?? "", size: 40, cornerRadius: 10)
                                }
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(vm.currentSong?.title ?? "")
                                    .font(.appHeadline)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .contentTransition(.opacity)
                                Text(vm.currentSong?.artist ?? "")
                                    .font(.appCaption)
                                    .foregroundStyle(.appSecondary)
                                    .lineLimit(1)
                                    .contentTransition(.opacity)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Cross-fade + subtle horizontal slide when
                            // the song changes. Keying on youtubeID lets
                            // SwiftUI animate the text content transition.
                            .animation(.easeInOut(duration: 0.28), value: vm.currentSong?.youtubeID)
                        }
                    }
                    .buttonStyle(.plain)

                    // Play/pause. Icon reflects `isPlaying ||
                    // playPendingFeedback` so the pause glyph appears
                    // the instant the user taps, even before audio
                    // actually starts. While pending, the glyph pulses
                    // via SF Symbol effect.
                    Button {
                        HapticManager.medium()
                        vm.togglePlayPause()
                    } label: {
                        let effective = vm.isPlaying || vm.playPendingFeedback
                        let pending = vm.playPendingFeedback && !vm.isPlaying
                        Image(systemName: effective ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.pulse, options: .repeating, isActive: pending)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }

                    // Next
                    Button { vm.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.appSecondary)
                            .frame(width: 28, height: 36)
                            .contentShape(Rectangle())
                    }

                    // Close button
                    Button { vm.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.appSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 58)
            }
            .frame(height: 60)
            .background(Color.appSurface)
            .overlay(alignment: .top) {
                vm.dominantColor
                    .opacity(0.8)
                    .frame(height: 2)
                    .animation(.spring(response: 0.5, dampingFraction: 0.9),
                               value: vm.dominantColor.description)
            }
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 40 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                dragOffset = 200
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                vm.stop()
                                dragOffset = 0
                            }
                        } else {
                            withAnimation(.spring(response: 0.3)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
