//
//  SettingsView.swift
//  Dhunify
//
//  Settings tab: audio quality, storage, profile, about.
//  Full dark theme.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @State private var audioQuality: String = UserDefaults.standard.string(forKey: "audioQuality") ?? "320"
    @State private var eq = EQManager.shared
    @State private var profileManager = ProfileManager.shared
    @State private var showClearConfirm = false
    @State private var storageCount = 0
    @State private var storageBytes: Int64 = 0
    @State private var hidden = HiddenSongsManager.shared
    @AppStorage("dhunify.themePreference") private var themePreference: String = "dark"

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    Text("Settings")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    // Audio Quality
                    settingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            label("Audio Quality", icon: "waveform")

                            Picker("Quality", selection: $audioQuality) {
                                Text("Low (128k)").tag("128")
                                Text("Normal (160k)").tag("160")
                                Text("High (320k)").tag("320")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: audioQuality) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: "audioQuality")
                            }

                            Text("Higher quality uses more data")
                                .font(.system(size: 12))
                                .foregroundStyle(.appSecondary)
                        }
                    }

                    // Equalizer
                    settingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            label("Equalizer", icon: "tuningfork")

                            // Presets
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(EQManager.presets, id: \.name) { preset in
                                        Button { eq.applyPreset(preset) } label: {
                                            Text(preset.name)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(eq.activePreset == preset.name ? .white : .appSecondary)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 7)
                                                .background(
                                                    Capsule().fill(eq.activePreset == preset.name ? Color.appAccent : Color.appSurface)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            // Bass slider
                            eqSlider(label: "Bass", icon: "speaker.wave.3.fill", value: $eq.bassGain)
                            // Mid slider
                            eqSlider(label: "Mid", icon: "speaker.wave.2.fill", value: $eq.midGain)
                            // Treble slider
                            eqSlider(label: "Treble", icon: "speaker.wave.1.fill", value: $eq.trebleGain)
                        }
                    }

                    // Storage
                    settingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            label("Storage", icon: "internaldrive")

                            HStack {
                                Text("\(storageCount) songs")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(formatBytes(storageBytes))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.appAccent)
                            }

                            Button {
                                showClearConfirm = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                        .font(.system(size: 14))
                                    Text("Clear All Downloads")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.red.opacity(0.1))
                                )
                            }
                            .buttonStyle(ScalePressButtonStyle())
                        }
                    }

                    // Profile
                    settingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            label("Profile", icon: "person.circle")

                            if let profile = profileManager.currentProfile {
                                HStack(spacing: 12) {
                                    Text(profile.emoji)
                                        .font(.system(size: 32))
                                        .frame(width: 50, height: 50)
                                        .background(Circle().fill(Color.appAccent.opacity(0.15)))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Text("Current profile")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.appSecondary)
                                    }

                                    Spacer()
                                }
                            }

                            Button {
                                profileManager.switchProfile()
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 14))
                                    Text("Switch Profile")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(.appAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.appAccent.opacity(0.1))
                                )
                            }
                            .buttonStyle(ScalePressButtonStyle())
                        }
                    }

                    // Appearance
                    settingsCard {
                        VStack(alignment: .leading, spacing: 10) {
                            label("Appearance", icon: "paintpalette")
                            themePicker
                        }
                    }

                    // Hidden songs
                    settingsCard {
                        VStack(alignment: .leading, spacing: 10) {
                            label("Hidden Songs", icon: "eye.slash")
                            hiddenSongsRow
                        }
                    }

                    // About
                    settingsCard {
                        VStack(alignment: .leading, spacing: 10) {
                            label("About", icon: "info.circle")

                            HStack {
                                Text("Version")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.appSecondary)
                                Spacer()
                                Text(appVersion)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                            }

                            Text("Made with ♥ by Diphoria")
                                .font(.system(size: 13))
                                .foregroundStyle(.appSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }
                    }

                    Spacer(minLength: 100)
                }
            }
        }
        .onAppear { refreshStorage() }
        .alert("Clear All Downloads?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                container.downloadManager.clearAll()
                refreshStorage()
            }
        } message: {
            Text("This will delete \(storageCount) downloaded songs (\(formatBytes(storageBytes))). This cannot be undone.")
        }
    }

    // MARK: - Helpers

    private func refreshStorage() {
        let stats = container.downloadManager.storageStats()
        storageCount = stats.count
        storageBytes = stats.bytes
    }

    // MARK: - Appearance

    private var themePicker: some View {
        Picker("Theme", selection: $themePreference) {
            Text("Dark").tag("dark")
            Text("Light").tag("light")
            Text("System").tag("system")
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Hidden songs

    @ViewBuilder
    private var hiddenSongsRow: some View {
        if hidden.hiddenIDs.isEmpty {
            Text("No hidden songs")
                .font(.system(size: 13))
                .foregroundStyle(.appSecondary)
        } else {
            HStack {
                Text("\(hidden.hiddenIDs.count) hidden")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    for id in hidden.hiddenIDs { hidden.unhide(youtubeID: id) }
                } label: {
                    Text("Unhide all")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.appAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.appAccent.opacity(0.12)))
                }
            }
        }
    }

    private func label(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.appAccent)
            Text(text)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.appSurface)
            )
            .padding(.horizontal, 20)
    }

    private func eqSlider(label: String, icon: String, value: Binding<Float>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.appSecondary)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%+.0f dB", value.wrappedValue))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.appAccent)
                    .frame(width: 50, alignment: .trailing)
            }
            Slider(value: value, in: -12...12, step: 1) {
                Text(label)
            }
            .tint(Color.appAccent)
            .onChange(of: value.wrappedValue) { _, _ in
                eq.activePreset = "Custom"
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
