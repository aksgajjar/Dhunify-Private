//
//  ShimmerView.swift
//  Dhunify
//
//  Moving shimmer placeholder used while lists/cards are loading.
//  Replaces plain grey skeleton boxes.
//

import SwiftUI

struct ShimmerView: View {
    var cornerRadius: CGFloat = 8
    var height: CGFloat? = nil

    @State private var phase: CGFloat = -1

    var body: some View {
        let gradient = LinearGradient(
            stops: [
                .init(color: Color.appSurface.opacity(0.6), location: 0),
                .init(color: Color.appSurface.opacity(0.6), location: max(phase, 0)),
                .init(color: Color.appOcean.opacity(0.15), location: min(phase + 0.15, 1)),
                .init(color: Color.appSurface.opacity(0.6), location: min(phase + 0.3, 1)),
                .init(color: Color.appSurface.opacity(0.6), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

        return Rectangle()
            .fill(gradient)
            .cornerRadius(cornerRadius)
            .frame(height: height)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

/// Skeleton row matching a song list entry.
struct SongRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            ShimmerView(cornerRadius: 10, height: 56)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 8) {
                ShimmerView(cornerRadius: 4, height: 13)
                    .frame(width: 160)
                ShimmerView(cornerRadius: 4, height: 11)
                    .frame(width: 100)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// Skeleton card for horizontal scrollers (albums, trending).
struct CardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShimmerView(cornerRadius: 12, height: 140)
                .frame(width: 140)
            ShimmerView(cornerRadius: 4, height: 12)
                .frame(width: 110)
            ShimmerView(cornerRadius: 4, height: 10)
                .frame(width: 80)
        }
    }
}
