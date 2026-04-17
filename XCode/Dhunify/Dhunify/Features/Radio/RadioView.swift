//
//  RadioView.swift
//  Dhunify
//

import SwiftUI

struct RadioView: View {
    @State private var viewModel = RadioViewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Radio")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    if viewModel.isPlaying {
                        liveBadge
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

                // Category picker
                Picker("Category", selection: $viewModel.selectedCategory) {
                    ForEach(RadioCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // Status message
                if let msg = viewModel.statusMessage {
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.appAccent)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                // Station list
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.filteredStations) { station in
                            stationCard(station)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, viewModel.currentStation != nil ? 130 : 120)
                }
            }

            // Now playing bar
            if let station = viewModel.currentStation {
                nowPlayingBar(station)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.currentStation?.id)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.selectedCategory)
    }

    // MARK: - Station card

    private func stationCard(_ station: RadioStation) -> some View {
        let isActive = viewModel.currentStation?.id == station.id && viewModel.isPlaying

        return Button {
            viewModel.play(station: station)
        } label: {
            HStack(spacing: 14) {
                // Logo image when available, else emoji-on-color circle.
                if let thumb = station.thumbnailURL, !thumb.isEmpty {
                    DhunifyAsyncImage(url: thumb, size: 56, cornerRadius: 28)
                        .overlay(
                            Circle().strokeBorder(station.color.opacity(0.35), lineWidth: 1)
                        )
                } else {
                    Text(station.emoji)
                        .font(.system(size: 26))
                        .frame(width: 56, height: 56)
                        .background(
                            Circle().fill(station.color.opacity(0.2))
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(.appHeadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(station.description)
                        .font(.appCaption)
                        .foregroundStyle(.appSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isActive {
                    liveDot
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isActive
                            ? station.color.opacity(0.12)
                            : Color.appSurface
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isActive ? station.color.opacity(0.3) : .clear,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    // MARK: - Now playing bar

    private func nowPlayingBar(_ station: RadioStation) -> some View {
        HStack(spacing: 12) {
            if let thumb = station.thumbnailURL, !thumb.isEmpty {
                DhunifyAsyncImage(url: thumb, size: 40, cornerRadius: 20)
            } else {
                Text(station.emoji)
                    .font(.system(size: 22))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(station.color.opacity(0.25)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.appHeadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    liveDot
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Button { viewModel.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(ScalePressButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.appSurface)
                .shadow(color: .black.opacity(0.4), radius: 12, y: -4)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Live indicators

    private var liveDot: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(.red.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .scaleEffect(viewModel.isPlaying ? 1.3 : 0.8)
                    .opacity(viewModel.isPlaying ? 0 : 0.6)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: viewModel.isPlaying
                    )
            )
    }

    private var liveBadge: some View {
        HStack(spacing: 4) {
            liveDot
            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.red.opacity(0.15)))
    }
}
