//
//  OnboardingView.swift
//  Dhunify
//
//  "Pick your favorites" — shown once after profile creation.
//  User selects 3-5 artists/genres. Home personalizes based on picks.
//

import SwiftUI

struct OnboardingView: View {
    let onDone: () -> Void
    @State private var selected: Set<String> = []

    private let artists = [
        ("Arijit Singh", "🎤"), ("AR Rahman", "🎹"), ("Shreya Ghoshal", "🎵"),
        ("Atif Aslam", "🎸"), ("Neha Kakkar", "💜"), ("Pritam", "🎶"),
        ("Diljit Dosanjh", "🔥"), ("AP Dhillon", "🎧"), ("Honey Singh", "🎤"),
        ("Jubin Nautiyal", "🌙"), ("B Praak", "💫"), ("Badshah", "👑"),
    ]

    private let genres = [
        ("Bollywood", "🎬"), ("Romantic", "💕"), ("Party", "🎉"),
        ("Punjabi", "🎵"), ("Lofi", "🌙"), ("90s Hits", "📻"),
        ("Devotional", "🙏"), ("Gujarati", "🪔"),
    ]

    private var canContinue: Bool { selected.count >= 3 }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Logo
                    ZStack {
                        Circle()
                            .fill(Color.appAccent)
                            .frame(width: 56, height: 56)
                        Text("D")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 40)

                    // Header
                    VStack(spacing: 6) {
                        Text("What do you love?")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Pick at least 3 to personalize your home")
                            .font(.system(size: 14))
                            .foregroundStyle(.appSecondary)
                    }

                    // Artists
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ARTISTS")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.appSecondary)
                            .padding(.horizontal, 20)

                        chipRow(items: Array(artists.prefix(6)))
                        chipRow(items: Array(artists.suffix(6)))
                    }

                    // Genres
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GENRES")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.appSecondary)
                            .padding(.horizontal, 20)

                        chipRow(items: Array(genres.prefix(4)))
                        chipRow(items: Array(genres.suffix(4)))
                    }

                    Spacer(minLength: 80)
                }
            }

            // Fixed continue button at bottom
            VStack {
                Spacer()
                Button {
                    let prefs = Array(selected)
                    UserDefaults.standard.set(prefs, forKey: "dhunify.favoritePicksV1")
                    UserDefaults.standard.set(true, forKey: "dhunify.onboardingDone")
                    onDone()
                } label: {
                    Text(canContinue ? "Continue (\(selected.count) selected)" : "Pick at least 3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(canContinue ? Color.appAccent : Color.appSecondary.opacity(0.3))
                        )
                }
                .disabled(!canContinue)
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .background(
                    LinearGradient(colors: [Color.appBackground.opacity(0), Color.appBackground],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 100)
                        .offset(y: -40)
                )
            }
        }
    }

    // MARK: - Chip row (wrapping, not scrolling)

    private func chipRow(items: [(String, String)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { name, emoji in
                    let isOn = selected.contains(name)
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            if isOn { selected.remove(name) } else { selected.insert(name) }
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 5) {
                            Text(emoji).font(.system(size: 15))
                            Text(name).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(isOn ? .white : .appSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(isOn ? Color.appAccent : Color.appSurface)
                        )
                        .overlay(
                            isOn ? nil : Capsule().strokeBorder(Color.appSecondary.opacity(0.2), lineWidth: 1)
                        )
                        .scaleEffect(isOn ? 1.05 : 1.0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension OnboardingView {
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: "dhunify.onboardingDone")
    }
    static var favoritePicks: [String] {
        UserDefaults.standard.stringArray(forKey: "dhunify.favoritePicksV1") ?? []
    }
}
