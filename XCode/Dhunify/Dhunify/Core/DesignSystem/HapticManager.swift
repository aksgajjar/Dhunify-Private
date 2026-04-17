//
//  HapticManager.swift
//  Dhunify
//
//  App-wide haptic feedback. Single entry point so taps, track changes,
//  and successes all feel consistent across the app.
//

import UIKit

enum HapticManager {

    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Signature 2-tap rhythm fired on track change — users feel the brand.
    static func trackChange() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
