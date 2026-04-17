//
//  NowPlayingBars.swift
//  Dhunify
//
//  Animated equalizer bars indicating the currently playing song.
//  3 bars that animate at different speeds.
//

import SwiftUI

struct NowPlayingBars: View {
    var isPlaying: Bool = true
    var color: Color = .appAccent
    var size: CGFloat = 14

    @State private var animate = false

    var body: some View {
        HStack(spacing: size * 0.1) {
            bar(delay: 0.0, minH: 0.3)
            bar(delay: 0.15, minH: 0.2)
            bar(delay: 0.3, minH: 0.4)
        }
        .frame(width: size, height: size)
        .onAppear { animate = isPlaying }
        .onChange(of: isPlaying) { _, playing in
            animate = playing
        }
    }

    private func bar(delay: Double, minH: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.08)
            .fill(color)
            .frame(width: size * 0.22)
            .frame(height: animate ? size : size * minH)
            .animation(
                animate
                    ? .easeInOut(duration: 0.4 + delay)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    : .easeOut(duration: 0.2),
                value: animate
            )
    }
}
