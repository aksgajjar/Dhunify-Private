//
//  PlayerView.swift
//  Dhunify
//
//  Full-screen player. Dark premium design.
//

import SwiftUI

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container
    @Environment(AppRouter.self) private var router

    let queue: [Song]
    let startIndex: Int
    var namespace: Namespace.ID? = nil

    @State private var isLiked: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var toastMessage: String? = nil
    @State private var showPlaylistSheet = false
    @State private var showQueue = false
    @State private var showSongInfo = false
    private var dominantColor: Color { viewModel.dominantColor }

    private var viewModel: PlayerViewModel { container.playerViewModel }

    var body: some View {
        ZStack {
            // Base — solid dark, never transparent so the player never
            // bleeds the screen behind it.
            Color.appBackground.ignoresSafeArea()

            // Dynamic color backdrop driven by viewModel.dominantColor.
            dominantColor
                .opacity(0.45)
                .ignoresSafeArea()
                .animation(.spring(response: 0.6, dampingFraction: 0.8),
                           value: dominantColor.description)

            // Bottom vignette pulls text/controls into darkness so they stay
            // readable regardless of how bright the dominant color is.
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.appBackground.opacity(0.6),
                    Color.appBackground.opacity(0.92),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top center: logo + NOW PLAYING
                VStack(spacing: 2) {
                    Text("Dhunify")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.appOcean, Color.appOceanLight],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("NOW PLAYING")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.appSecondary)
                }
                .padding(.top, 16)

                Spacer(minLength: 12)

                // Artwork (280pt centered)
                artwork
                    .padding(.horizontal, 40)

                Spacer(minLength: 12)

                // Song info
                songInfo
                    .padding(.horizontal, 32)
                    .padding(.top, 6)

                // Error
                if let error = viewModel.playbackError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(2)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                }

                // Progress + time
                progressSection
                    .padding(.horizontal, 32)
                    .padding(.top, 16)

                // Controls
                controls
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                // Volume + Speed + Queue
                HStack(spacing: 8) {
                    volumeSection

                    // Speed button
                    Button {
                        let speeds = PlayerViewModel.speedOptions
                        let idx = speeds.firstIndex(of: viewModel.playbackSpeed) ?? 2
                        viewModel.playbackSpeed = speeds[(idx + 1) % speeds.count]
                    } label: {
                        Text(viewModel.playbackSpeed == 1.0 ? "1x" : String(format: "%.1gx", viewModel.playbackSpeed))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(viewModel.playbackSpeed == 1.0 ? .appSecondary : .appAccent)
                            .frame(width: 32, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.appSurface))
                    }

                    // Equalizer button
                    Button {
                        HapticManager.soft()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            viewModel.showEqualizer = true
                        }
                    } label: {
                        Image(systemName: "slider.vertical.3")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(viewModel.showEqualizer ? Color.appOcean : Color.appSecondary)
                            .frame(width: 32, height: 36)
                            .contentShape(Rectangle())
                    }
                    .scaleButton(0.9)

                    // Queue button
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.appSecondary)
                            .frame(width: 32, height: 36)
                            .contentShape(Rectangle())
                    }
                }
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showEqualizer },
            set: { viewModel.showEqualizer = $0 }
        )) {
            EqualizerView(isPresented: Binding(
                get: { viewModel.showEqualizer },
                set: { viewModel.showEqualizer = $0 }
            ))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.appBackground)
        }
        // Toast
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.appAccent))
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.3), value: toastMessage)
            }
        }
        // Dismiss button — top-left
        .overlay(alignment: .topLeading) {
            Button { dismissPlayer() } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(ScalePressButtonStyle())
            .padding(.top, 52)
            .padding(.leading, 20)
        }
        // Info button — top-right
        .overlay(alignment: .topTrailing) {
            Button { showSongInfo = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(ScalePressButtonStyle())
            .padding(.top, 58)
            .padding(.trailing, 20)
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = viewModel.currentSong {
                SongInfoSheet(song: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .task {
                        // Trigger loading
                    }
            }
        }
        .offset(y: max(0, dragOffset))
        .gesture(dismissDrag)
        .sheet(isPresented: $showPlaylistSheet) {
            if let song = viewModel.currentSong {
                AddToPlaylistSheet(songID: song.youtubeID, songTitle: song.title, showLibraryOption: true, song: song) { name in
                    showToast("Added to \(name)")
                    if name == "Library" { isLiked = true }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .task {
            let vm = container.playerViewModel
            if vm.queue != queue || vm.currentIndex != startIndex {
                vm.setQueue(queue, startIndex: startIndex)
            }
            // Always call play() on presentation so repeat-taps of the
            // same song resume instantly without the user having to
            // touch the Play button.
            vm.play()
            await checkIfLiked()
        }
        .onChange(of: viewModel.currentSong?.youtubeID) { _, _ in
            Task {
                await checkIfLiked()
            }
        }
        .overlay {
            if viewModel.showLyrics {
                LyricsView(
                    lyrics: viewModel.lyrics,
                    isLoading: viewModel.lyricsLoading,
                    currentTime: viewModel.currentTime,
                    duration: viewModel.duration,
                    isPresented: Binding(
                        get: { viewModel.showLyrics },
                        set: { viewModel.showLyrics = $0 }
                    )
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
            }
        }
    }

    // MARK: - Artwork

    private var artwork: some View {
        Group {
            if let ns = namespace {
                DhunifyAsyncImage(
                    url: viewModel.currentSong?.thumbnailURL ?? "",
                    size: 280,
                    cornerRadius: 20
                )
                .matchedGeometryEffect(id: "playerArtwork", in: ns)
            } else {
                DhunifyAsyncImage(
                    url: viewModel.currentSong?.thumbnailURL ?? "",
                    size: 280,
                    cornerRadius: 20
                )
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
        .scaleEffect(viewModel.isPlaying ? 1.0 : 0.92)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: viewModel.isPlaying)
        .onLongPressGesture {
            guard viewModel.currentSong?.hasLyrics == true else { return }
            HapticManager.medium()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewModel.showLyrics = true
            }
        }
    }

    // MARK: - Song info

    private var songInfo: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(
                    text: viewModel.currentSong?.title ?? "—",
                    font: .system(size: 26, weight: .bold, design: .rounded),
                    color: .white
                )
                Text(viewModel.currentSong?.artist ?? "")
                    .font(.appBody)
                    .foregroundStyle(.appSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Download button
            if let song = viewModel.currentSong {
                let dm = container.downloadManager
                if dm.activeDownloads.contains(song.youtubeID) {
                    ProgressView()
                        .tint(.appAccent)
                        .frame(width: 36, height: 36)
                } else if dm.isDownloaded(song.youtubeID) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.appAccent)
                        .frame(width: 36, height: 36)
                } else {
                    Button {
                        dm.download(song: song)
                        showToast("Downloading...")
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }

            // Add to playlist
            if viewModel.currentSong != nil {
                Button { showPlaylistSheet = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScalePressButtonStyle())
            }

            // Lyrics button — only shown when the current song is a
            // JioSaavn track (those are the only ones lyrics are
            // available for via this route).
            if viewModel.currentSong?.hasLyrics == true {
                Button {
                    HapticManager.soft()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        viewModel.showLyrics = true
                    }
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 20))
                        .foregroundStyle(viewModel.showLyrics ? Color.appOcean : Color.appSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScalePressButtonStyle())
            }

            // Heart / library button
            Button {
                guard let song = viewModel.currentSong else { return }
                HapticManager.soft()
                isLiked.toggle()
                if isLiked {
                    Task {
                        try? await container.songStore.save(song: song)
                        showToast("Added to Library")
                    }
                } else {
                    Task {
                        try? await container.songStore.remove(song: song)
                        showToast("Removed from Library")
                    }
                }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalePressButtonStyle())
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isLiked)
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if toastMessage == message { toastMessage = nil }
        }
    }

    // MARK: - Progress + time

    private var progressSection: some View {
        VStack(spacing: 6) {
            ProgressSlider(
                progress: viewModel.progress,
                onSeek: { viewModel.seek(to: $0) }
            )
            .frame(height: 20)

            HStack {
                Text(formatTime(viewModel.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.appSecondary)
                Spacer()
                Text(formatTime(viewModel.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.appSecondary)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack {
            Button { viewModel.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(viewModel.isShuffled ? .white : Color.appSecondary)
                    .frame(width: 44, height: 44)
                    .background(
                        viewModel.isShuffled
                            ? Circle().fill(Color.appAccent).frame(width: 36, height: 36)
                            : nil
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalePressButtonStyle())
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.isShuffled)

            Spacer()

            Button {
                HapticManager.trackChange()
                viewModel.previousTrack()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalePressButtonStyle())

            Spacer()

            Button {
                HapticManager.medium()
                viewModel.togglePlayPause()
            } label: {
                // `effective` drives the icon so the pause glyph
                // appears the instant the user taps. `pending` is true
                // only in the gap between tap and real playback, and
                // activates the SF Symbol pulse + a stronger glow so
                // the button reads as "working" without a spinner.
                let effective = viewModel.isPlaying || viewModel.playPendingFeedback
                let pending = viewModel.playPendingFeedback && !viewModel.isPlaying
                ZStack {
                    Circle().fill(Color.appAccent).frame(width: 72, height: 72)
                    Image(systemName: effective ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: effective ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, options: .repeating, isActive: pending)
                }
                .shadow(
                    color: Color.appAccent.opacity(pending ? 0.55 : 0.35),
                    radius: pending ? 22 : 16,
                    x: 0,
                    y: 8
                )
                .animation(.easeInOut(duration: 0.25), value: pending)
            }
            .buttonStyle(ScalePressButtonStyle())

            Spacer()

            Button {
                HapticManager.trackChange()
                viewModel.nextTrack()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalePressButtonStyle())

            Spacer()

            Button { viewModel.toggleRepeat() } label: {
                Image(systemName: viewModel.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(viewModel.repeatMode == .off ? Color.appSecondary : .white)
                    .frame(width: 44, height: 44)
                    .background(
                        viewModel.repeatMode != .off
                            ? Circle().fill(Color.appAccent).frame(width: 36, height: 36)
                            : nil
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScalePressButtonStyle())
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.repeatMode)
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 14))
                .foregroundStyle(.appSecondary)
            SystemVolumeSlider()
                .frame(height: 30)
                .tint(Color.appAccent)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 14))
                .foregroundStyle(.appSecondary)
        }
    }

    // MARK: - Drag to dismiss

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                dragOffset = max(0, v.translation.height)
            }
            .onEnded { v in
                // Commit dismiss on either a past-threshold drag or a flick with enough momentum.
                let shouldDismiss = v.translation.height > 80 ||
                                    v.predictedEndTranslation.height > 200
                if shouldDismiss {
                    dismissPlayer()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func dismissPlayer() {
        // Reset local offset so the overlay is in its natural position,
        // then let ContentView's `.transition(.move(edge: .bottom))` drive the exit.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dragOffset = 0
        }
        router.dismissPlayer()
    }

    private func checkIfLiked() async {
        guard let song = viewModel.currentSong else {
            isLiked = false
            return
        }
        let library = (try? await container.songStore.fetchLibrary()) ?? []
        isLiked = library.contains { $0.youtubeID == song.youtubeID }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Progress slider

private struct ProgressSlider: View {
    let progress: Double
    let onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var lastHapticStep: Int = -1

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let displayed = isDragging ? dragProgress : progress.clamped01
            let fillWidth = width * displayed
            let thumbX = max(7, min(fillWidth, width - 7))

            ZStack(alignment: .leading) {
                Capsule().fill(Color.appSurface).frame(height: 4)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.appOcean, Color.appAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .position(x: thumbX, y: geo.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !isDragging { isDragging = true; dragProgress = progress.clamped01; lastHapticStep = -1 }
                        dragProgress = Double(v.location.x / width).clamped01
                        // Haptic tick every 5% of progress
                        let step = Int(dragProgress * 20)
                        if step != lastHapticStep {
                            lastHapticStep = step
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        let final = dragProgress; isDragging = false; onSeek(final)
                    }
            )
        }
    }
}

private extension BinaryFloatingPoint {
    var clamped01: Self { Swift.max(0, Swift.min(self, 1)) }
}
