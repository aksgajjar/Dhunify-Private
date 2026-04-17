//
//  MarqueeText.swift
//  Dhunify
//
//  Auto-scrolling text for long song titles. Scrolls only if text
//  is wider than the container. Pure SwiftUI, no UIKit.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 22, weight: .bold)
    var color: Color = .white

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animating = false

    private var needsScroll: Bool { textWidth > containerWidth + 5 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { inner in
                    Color.clear.onAppear {
                        textWidth = inner.size.width
                        containerWidth = w
                        startAnimation()
                    }
                })
                .offset(x: offset)
                .onChange(of: text) { _, _ in
                    offset = 0
                    animating = false
                    textWidth = 0
                    // Re-measure on next frame.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        startAnimation()
                    }
                }
        }
        .frame(height: fontHeight)
        .clipped()
    }

    var fontSize: CGFloat = 22

    private var fontHeight: CGFloat { fontSize * 1.3 }

    private func startAnimation() {
        guard needsScroll, !animating else { return }
        animating = true
        let distance = textWidth - containerWidth + 30
        let duration = Double(distance) / 30.0 // ~30pt per second

        // Pause 2s → scroll left → pause 1s → reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.linear(duration: duration)) {
                offset = -distance
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) {
                    offset = 0
                }
                animating = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    startAnimation()
                }
            }
        }
    }
}
