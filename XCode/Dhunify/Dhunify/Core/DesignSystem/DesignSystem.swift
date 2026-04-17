//
//  DesignSystem.swift
//  Dhunify
//
//  App-wide palette and shared view styles. Single source of truth for
//  visual identity — change values here, app-wide theme shifts.
//
//  Theme: "Midnight × Ember"
//   • Background stack → deep midnight falling into ocean blue
//   • Accent / CTA    → ember to amber gradient (warm on cool)
//   • Hero sections   → blue × orange collision via mesh gradients
//

import SwiftUI

// MARK: - Palette

public extension Color {

    // ── Background stack (Midnight → Ocean Blue) ──────────────────

    /// #060914 — deepest midnight, full-screen canvas.
    static let appBackground = Color(red: 6 / 255, green: 9 / 255, blue: 20 / 255)

    /// #0C1426 — one step lifted, used under hero sections.
    static let appBackgroundSoft = Color(red: 12 / 255, green: 20 / 255, blue: 38 / 255)

    /// #131C34 — cards, search bars, control backdrops.
    static let appSurface = Color(red: 19 / 255, green: 28 / 255, blue: 52 / 255)

    /// #1A2642 — modal sheets, elevated chrome.
    static let appSurfaceElevated = Color(red: 26 / 255, green: 38 / 255, blue: 66 / 255)

    // ── Ocean Blue (secondary accent) ─────────────────────────────

    /// #1E3A8A — deep ocean, shadows & emphasis.
    static let appOceanDeep = Color(red: 30 / 255, green: 58 / 255, blue: 138 / 255)

    /// #2563EB — ocean mid, informational highlights, badges.
    static let appOcean = Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)

    /// #60A5FA — ocean light, hover states & links.
    static let appOceanLight = Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255)

    // ── Ember → Amber (primary CTA family) ───────────────────────

    /// #F59E0B — primary accent. Replaces the old purple.
    /// Used for play buttons, selected states, progress bars, brand dots.
    static let appAccent = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)

    /// #EA580C — ember, deeper side of the accent gradient (pressed).
    static let appEmber = Color(red: 234 / 255, green: 88 / 255, blue: 12 / 255)

    /// #FBBF24 — amber light, top of gradient / shine highlights.
    static let appAmberLight = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)

    // ── Text ──────────────────────────────────────────────────────

    /// #8B93A7 — secondary text, icons, placeholders (blue-tinted grey).
    static let appSecondary = Color(red: 139 / 255, green: 147 / 255, blue: 167 / 255)

    /// #5B6377 — tertiary / disabled text.
    static let appSecondaryMuted = Color(red: 91 / 255, green: 99 / 255, blue: 119 / 255)
}

/// Mirror the palette onto `ShapeStyle` so the dot-shorthand works with
/// APIs like `.foregroundStyle(.appAccent)` and `.fill(.appSurface)`.
public extension ShapeStyle where Self == Color {
    static var appBackground: Color { .appBackground }
    static var appBackgroundSoft: Color { .appBackgroundSoft }
    static var appSurface: Color { .appSurface }
    static var appSurfaceElevated: Color { .appSurfaceElevated }
    static var appOceanDeep: Color { .appOceanDeep }
    static var appOcean: Color { .appOcean }
    static var appOceanLight: Color { .appOceanLight }
    static var appAccent: Color { .appAccent }
    static var appEmber: Color { .appEmber }
    static var appAmberLight: Color { .appAmberLight }
    static var appSecondary: Color { .appSecondary }
    static var appSecondaryMuted: Color { .appSecondaryMuted }
}

// MARK: - Typography

public extension Font {
    /// Hero titles, player song name.
    static let appDisplay  = Font.system(size: 26, weight: .bold,     design: .rounded)
    /// Section headers, album titles.
    static let appTitle    = Font.system(size: 20, weight: .bold,     design: .rounded)
    /// Song titles in lists.
    static let appHeadline = Font.system(size: 16, weight: .semibold, design: .rounded)
    /// Artist names, descriptions.
    static let appBody     = Font.system(size: 14, weight: .regular,  design: .rounded)
    /// Timestamps, metadata, duration.
    static let appCaption  = Font.system(size: 12, weight: .medium,   design: .rounded)
    /// All-caps section labels. Use with `.tracking(1.2).textCase(.uppercase)`.
    static let appLabel    = Font.system(size: 11, weight: .semibold, design: .rounded)
}

// MARK: - Signature gradients

public enum AppGradient {

    /// Midnight → Ocean Blue. Vertical, covers full-screen backgrounds.
    public static let background = LinearGradient(
        colors: [.appBackground, .appBackgroundSoft, .appSurface],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Ember → Amber. Horizontal, used on primary CTAs, play buttons,
    /// progress fills, "Dhunify" wordmark.
    public static let accent = LinearGradient(
        colors: [.appEmber, .appAccent, .appAmberLight],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Ember → Amber, diagonal — better on square buttons / chips.
    public static let accentDiagonal = LinearGradient(
        colors: [.appEmber, .appAmberLight],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Blue × Orange collision — used on hero cards, artwork glow, and
    /// album-detail backdrops. Cool / warm contrast is the signature.
    public static let heroCollision = LinearGradient(
        colors: [
            .appOcean.opacity(0.85),
            .appOceanDeep.opacity(0.55),
            .appEmber.opacity(0.45),
            .appAmberLight.opacity(0.25),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle vignette overlay for cards on hero backgrounds.
    public static let surfaceVeil = LinearGradient(
        colors: [Color.black.opacity(0.55), Color.black.opacity(0.15)],
        startPoint: .bottom,
        endPoint: .top
    )
}

// MARK: - Button style

/// Applies a subtle scale-down + haptic-style compression when a button
/// is pressed. Used app-wide so every tappable control has the same feel.
public struct ScalePressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}

/// Parameterized scale-on-press style. Used via `View.scaleButton(_:)`
/// so callers can tune the press-in amount per surface (bigger cards → less
/// shrink, tiny icons → more shrink).
public struct ScaleButtonStyle: ButtonStyle {
    public var scale: CGFloat = 0.94
    public init(scale: CGFloat = 0.94) { self.scale = scale }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

public extension View {
    /// Shortcut for `.buttonStyle(ScaleButtonStyle(scale:))`.
    func scaleButton(_ scale: CGFloat = 0.94) -> some View {
        self.buttonStyle(ScaleButtonStyle(scale: scale))
    }
}

/// Primary CTA button style: Ember→Amber gradient fill, white text,
/// scale feedback. Drop-in replacement for `.buttonStyle(.borderedProminent)`.
public struct EmberButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(AppGradient.accent)
                    .shadow(color: .appEmber.opacity(0.35), radius: 12, y: 6)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}
