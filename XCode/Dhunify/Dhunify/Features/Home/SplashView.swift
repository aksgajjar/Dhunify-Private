//
//  SplashView.swift
//  Dhunify
//
//  Launch animation. Logo pops in → wordmark slides up → glow pulses →
//  fades out after 2.2s. No particles, no chrome — just the brand.
//

import SwiftUI

struct SplashView: View {
    let onFinished: () -> Void

    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var wordmarkOpacity: Double = 0
    @State private var wordmarkOffset: CGFloat = 20
    @State private var pulseScale: CGFloat = 1.0
    @State private var bgOpacity: Double = 1.0

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            // Radial glow behind logo — Ocean Blue, matches new palette.
            RadialGradient(
                colors: [Color.appOcean.opacity(0.25), Color.clear],
                center: .center,
                startRadius: 10,
                endRadius: 160
            )
            .scaleEffect(pulseScale)
            .opacity(logoOpacity)
            .ignoresSafeArea()

            VStack(spacing: 16) {
                // Logo mark — Ocean→Ember ring, inner dot, audio-wave bars.
                ZStack {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.appOcean, Color.appAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 72, height: 72)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.appOcean, Color.appEmber],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)

                    HStack(spacing: 3) {
                        ForEach([0.4, 1.0, 0.65, 0.85, 0.5], id: \.self) { h in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 3, height: CGFloat(h) * 18)
                        }
                    }
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                // Wordmark — mapped appPrimary → .white.
                Text("dhunify")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color.appSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .tracking(2)
                    .opacity(wordmarkOpacity)
                    .offset(y: wordmarkOffset)

                Text("music without limits")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(Color.appSecondary)
                    .tracking(1.5)
                    .opacity(wordmarkOpacity * 0.7)
                    .offset(y: wordmarkOffset)
            }
        }
        .opacity(bgOpacity)
        .onAppear { runAnimation() }
    }

    private func runAnimation() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
            logoScale = 1.0
            logoOpacity = 1.0
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7).delay(0.25)) {
            wordmarkOpacity = 1.0
            wordmarkOffset = 0
        }
        withAnimation(.easeInOut(duration: 1.2).delay(0.4).repeatForever(autoreverses: true)) {
            pulseScale = 1.15
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeInOut(duration: 0.4)) {
                bgOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                onFinished()
            }
        }
    }
}
