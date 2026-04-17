//
//  LyricsView.swift
//  Dhunify
//
//  Full-screen lyrics overlay with auto-scroll + active-line highlight.
//  No per-line timestamps from the source — current line is estimated
//  by mapping `currentTime / duration` across the line count.
//

import SwiftUI

struct LyricsView: View {
    let lyrics: String
    let isLoading: Bool
    let currentTime: Double
    let duration: Double
    @Binding var isPresented: Bool

    private var lines: [String] {
        lyrics
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var currentLineIndex: Int {
        guard duration > 0, !lines.isEmpty else { return 0 }
        let progress = min(max(currentTime / duration, 0), 1)
        let idx = Int(Double(lines.count) * progress)
        return min(idx, lines.count - 1)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.appBackground.ignoresSafeArea()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView().tint(Color.appOcean)
                    Text("Loading lyrics...")
                        .font(.appCaption)
                        .foregroundColor(.appSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 44))
                        .foregroundColor(.appSecondary)
                    Text("Lyrics not available")
                        .font(.appHeadline)
                        .foregroundColor(.appSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 80)

                            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                let distance = abs(idx - currentLineIndex)
                                Text(line)
                                    .font(lineFont(distance: distance))
                                    .foregroundColor(lineColor(distance: distance))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, lineSpacing(distance: distance))
                                    .animation(
                                        .spring(response: 0.4, dampingFraction: 0.8),
                                        value: currentLineIndex
                                    )
                                    .id(idx)
                            }

                            Color.clear.frame(height: 120)
                        }
                    }
                    .onChange(of: currentLineIndex) { _, newIdx in
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(currentLineIndex, anchor: .center)
                    }
                }
            }

            // Close button (top-right, above everything).
            Button {
                HapticManager.soft()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.appSecondary)
                    .padding(20)
            }
            .zIndex(1)
        }
    }

    private func lineFont(distance: Int) -> Font {
        switch distance {
        case 0: return .system(size: 20, weight: .bold,    design: .rounded)
        case 1: return .system(size: 17, weight: .medium,  design: .rounded)
        case 2: return .system(size: 15, weight: .regular, design: .rounded)
        default: return .system(size: 14, weight: .regular, design: .rounded)
        }
    }

    private func lineColor(distance: Int) -> Color {
        switch distance {
        case 0: return Color.appOcean
        case 1: return Color.white.opacity(0.65)
        case 2: return Color.white.opacity(0.35)
        default: return Color.appSecondary.opacity(0.4)
        }
    }

    private func lineSpacing(distance: Int) -> CGFloat {
        switch distance {
        case 0: return 12
        case 1: return 10
        default: return 8
        }
    }
}
