//
//  CarPlayNowPlayingUpdater.swift
//  Dhunify
//
//  Mirrors PlayerViewModel state into MPNowPlayingInfoCenter so
//  CarPlay + the lock screen always see the current track. Observes
//  the VM via Observation's `withObservationTracking`, re-registering
//  after every change so the loop never terminates.
//

internal import CarPlay
import Foundation
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class CarPlayNowPlayingUpdater {

    @ObservationIgnored private let playerViewModel: PlayerViewModel
    @ObservationIgnored private var isObserving: Bool = false
    @ObservationIgnored private var artworkTaskID: UUID?
    @ObservationIgnored private var lastArtworkSongID: String?
    /// The artwork we last computed for the current song. PlayerViewModel
    /// also writes `MPNowPlayingInfoCenter.nowPlayingInfo` and clears
    /// the artwork slot when it does, so we re-assert this on every
    /// observation tick to outlive the overwrite.
    @ObservationIgnored private var currentArtwork: MPMediaItemArtwork?

    init(playerViewModel: PlayerViewModel) {
        self.playerViewModel = playerViewModel
    }

    // MARK: - Lifecycle

    /// Starts the observation loop. Idempotent — repeated calls are
    /// no-ops after the first.
    func start() {
        guard !isObserving else { return }
        isObserving = true
        CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = false
        scheduleObservation()
    }

    /// Re-registers the observation closure. `withObservationTracking`
    /// only fires `onChange` once, so every state change pushes us
    /// back through this method to re-arm the tracker.
    private func scheduleObservation() {
        withObservationTracking {
            _ = playerViewModel.currentSong
            _ = playerViewModel.isPlaying
            _ = playerViewModel.currentTime
            _ = playerViewModel.duration
            _ = playerViewModel.isShuffled
            _ = playerViewModel.repeatMode
            _ = LibraryStore.shared.likedSongs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                print("🎵 NowPlaying observation onChange fired")
                self?.scheduleObservation()
            }
        }
        update()
        refreshNowPlayingButtons()
    }

    // MARK: - Now Playing mirror

    private func update() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let song = playerViewModel.currentSong {
            info[MPMediaItemPropertyTitle] = song.title
            info[MPMediaItemPropertyArtist] = song.artist
        } else {
            info[MPMediaItemPropertyTitle] = "Dhunify"
            info[MPMediaItemPropertyArtist] = ""
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playerViewModel.currentTime
        info[MPMediaItemPropertyPlaybackDuration] = playerViewModel.duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = playerViewModel.isPlaying ? 1.0 : 0.0

        // Inline re-assert. Protects against the case where our tick
        // runs before PlayerViewModel's setupNowPlaying, which writes a
        // fresh empty dict and clobbers everything else.
        if let artwork = currentArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        loadArtworkIfNeeded()

        // Deferred re-assert on the next main-queue turn. Guarantees
        // we land AFTER any synchronous VM write that happens later in
        // this runloop pass — if VM wipes the artwork slot, this
        // closure restores it a moment later.
        DispatchQueue.main.async { [weak self] in
            guard let self, let artwork = self.currentArtwork else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            print("🎵 Artwork reapplied:", self.currentArtwork != nil, "song=\(self.playerViewModel.currentSong?.title ?? "nil")")
        }
    }

    private func loadArtworkIfNeeded() {
        guard let song = playerViewModel.currentSong else {
            lastArtworkSongID = nil
            currentArtwork = nil
            return
        }

        // Only kick off a new artwork fetch when the song actually
        // changes — otherwise every periodic tick would re-download.
        guard lastArtworkSongID != song.youtubeID else { return }
        lastArtworkSongID = song.youtubeID

        // Seed the Now Playing slot with the gradient fallback
        // immediately so CarPlay never shows a blank artwork well while
        // the real thumbnail is being fetched. Cached into
        // `currentArtwork` so the next `update()` tick re-asserts it
        // after any PlayerViewModel overwrite.
        let fallback = Self.generateFallbackArtwork(for: song)
        setCurrentArtwork(fallback)

        let taskID = UUID()
        artworkTaskID = taskID

        Task { [weak self] in
            let image = await Self.fetchArtwork(for: song)
            await MainActor.run {
                guard let self else { return }
                // Discard stale results if the song changed mid-flight.
                guard self.artworkTaskID == taskID else { return }
                guard self.playerViewModel.currentSong?.youtubeID == song.youtubeID else { return }

                self.setCurrentArtwork(image)
            }
        }
    }

    /// Wraps the image in `MPMediaItemArtwork`, caches it locally so
    /// `update()` can re-assert it, then pushes it into Now Playing
    /// immediately. The artwork request handler rescales on demand so
    /// CarPlay / Control Center / lock screen each get a crisp image
    /// regardless of the bounds they request.
    private func setCurrentArtwork(_ image: UIImage) {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
            guard requestedSize.width > 0, requestedSize.height > 0 else { return image }
            if requestedSize.width >= image.size.width &&
                requestedSize.height >= image.size.height {
                return image
            }
            let renderer = UIGraphicsImageRenderer(size: requestedSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: requestedSize))
            }
        }
        currentArtwork = artwork
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Artwork loading

    private static func fetchArtwork(for song: Song) async -> UIImage {
        if let url = URL(string: song.thumbnailURL) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    return image
                }
            } catch {
                // Fall through to the gradient fallback.
            }
        }
        return Self.generateFallbackArtwork(for: song)
    }

    /// Builds a 600x600 gradient artwork card (purple #6C5CE7 → #A29BFE)
    /// with the song title's first character centered on top. Matches
    /// the CarPlay artwork size hint and always produces a usable image.
    private static func generateFallbackArtwork(for song: Song) -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let cgContext = context.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // Gradient from the accent color into a lighter tint.
            let colors = [
                UIColor(red: 108 / 255, green: 92 / 255, blue: 231 / 255, alpha: 1).cgColor,
                UIColor(red: 162 / 255, green: 155 / 255, blue: 254 / 255, alpha: 1).cgColor
            ] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors,
                locations: [0, 1]
            ) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            } else {
                UIColor(red: 108 / 255, green: 92 / 255, blue: 231 / 255, alpha: 1).setFill()
                cgContext.fill(rect)
            }

            // Draw the centered initial.
            let initial = song.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .first
                .map { String($0).uppercased() } ?? "♪"

            let font = UIFont.systemFont(ofSize: 280, weight: .bold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(0.95),
                .paragraphStyle: paragraph
            ]

            let text = initial as NSString
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    // MARK: - Now Playing buttons

    /// Installs the trio of Now Playing buttons on
    /// `CPNowPlayingTemplate.shared`: shuffle (left), heart (center),
    /// repeat (right). Shuffle and repeat use Apple's dedicated CarPlay
    /// subclasses so head units render standard icons + active state
    /// and route taps through the system. Heart stays a custom image
    /// button. The observation loop in `scheduleObservation()`
    /// re-fires this method on every state change so visuals flip.
    private func refreshNowPlayingButtons() {
        guard let song = playerViewModel.currentSong else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }

        let shuffleButton = CPNowPlayingShuffleButton { [weak self] _ in
            Task { @MainActor in
                self?.playerViewModel.toggleShuffle()
            }
        }

        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            Task { @MainActor in
                self?.playerViewModel.toggleRepeat()
            }
        }

        let cfg = UIImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
        let liked = LibraryStore.shared.isLiked(song)
        let heartSymbol = liked ? "heart.fill" : "heart"
        let heartTint: UIColor = liked ? .systemPink : .white
        let heartImage = UIImage(systemName: heartSymbol, withConfiguration: cfg)?
            .withTintColor(heartTint, renderingMode: .alwaysOriginal) ?? UIImage()
        let heartButton = CPNowPlayingImageButton(image: heartImage) { _ in
            Task { @MainActor in
                _ = LibraryStore.shared.toggleLike(song)
            }
        }

        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffleButton, heartButton, repeatButton])
        syncRemoteCommandShuffleRepeatState()
    }

    /// Mirrors VM shuffle/repeat state into MPRemoteCommandCenter so
    /// the system Now Playing surfaces (CarPlay button glow, lock
    /// screen) reflect the current toggle without a fresh tap.
    private func syncRemoteCommandShuffleRepeatState() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType =
            playerViewModel.isShuffled ? .items : .off
        switch playerViewModel.repeatMode {
        case .off:
            center.changeRepeatModeCommand.currentRepeatType = .off
        case .all:
            center.changeRepeatModeCommand.currentRepeatType = .all
        case .one:
            center.changeRepeatModeCommand.currentRepeatType = .one
        }
    }
}
