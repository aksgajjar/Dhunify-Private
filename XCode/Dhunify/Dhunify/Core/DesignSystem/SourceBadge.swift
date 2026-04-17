//
//  SourceBadge.swift
//  Dhunify
//
//  Tiny "YT" pill shown next to song titles sourced from the YouTube
//  fallback (when JioSaavn has no match). JioSaavn tracks get no badge
//  — keeps the default case visually clean.
//

import SwiftUI

struct SourceBadge: View {
    let song: Song

    var body: some View {
        if song.isYouTubeSource {
            Text("YT")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
                )
                .accessibilityLabel("YouTube source")
        }
    }
}
