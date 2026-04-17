//
//  ProfilePickerView.swift
//  Dhunify
//
//  "Who's Listening?" screen shown on first launch or when
//  switching profiles. Max 4 profiles, local only.
//

import SwiftUI

struct ProfilePickerView: View {
    @State private var profileManager = ProfileManager.shared
    @State private var showingCreate = false

    let onProfileSelected: () -> Void

    private let emojiOptions = ["🎵", "🎧", "🎤", "🎸", "🎹", "🎶", "🎷", "🥁", "🎻", "💜", "🌙", "⭐", "🦋", "🌸", "🔥", "💫"]

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.appAccent)
                            .frame(width: 60, height: 60)
                        Text("D")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    Text("DHUNIFY")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(.appSecondary)
                }

                Text("Who's Listening?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                // Profile grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(profileManager.profiles) { profile in
                        profileCard(profile)
                    }

                    if profileManager.canAddProfile {
                        addProfileCard
                    }
                }
                .padding(.horizontal, 40)

                Spacer()
                Spacer()
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateProfileSheet(
                emojiOptions: emojiOptions,
                onSave: { name, emoji in
                    profileManager.addProfile(name: name, emoji: emoji)
                    showingCreate = false
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func profileCard(_ profile: UserProfile) -> some View {
        Button {
            profileManager.selectProfile(profile)
            onProfileSelected()
        } label: {
            VStack(spacing: 10) {
                Text(profile.emoji)
                    .font(.system(size: 40))
                    .frame(width: 80, height: 80)
                    .background(
                        Circle().fill(Color.appAccent.opacity(0.15))
                    )

                Text(profile.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.appSurface)
            )
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    private var addProfileCard: some View {
        Button { showingCreate = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.appAccent)
                    .frame(width: 80, height: 80)
                    .background(
                        Circle()
                            .strokeBorder(Color.appAccent.opacity(0.3), lineWidth: 2)
                    )

                Text("Add Profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.appSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.appSurface)
            )
        }
        .buttonStyle(ScalePressButtonStyle())
    }
}

// MARK: - Create Profile Sheet

private struct CreateProfileSheet: View {
    let emojiOptions: [String]
    let onSave: (String, String) -> Void

    @State private var name: String = ""
    @State private var selectedEmoji: String = "🎵"
    // Pre-computed validity. Derived from `name` via a 200ms debounced
    // `.onChange` task so the enabled / disabled + fill-color updates
    // don't fire on every keystroke — the TextField body still updates
    // instantly (it must), but the rest of the sheet stays quiet.
    @State private var isNameValid: Bool = false
    @State private var validationTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("New Profile")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 20)

                // Subviews capture ONLY the state they need. Emoji
                // preview + grid don't read `name`, so SwiftUI skips
                // their bodies on typing — only the NameField rebuilds.
                SelectedEmojiPreview(emoji: selectedEmoji)

                EmojiGrid(options: emojiOptions, selected: $selectedEmoji)

                NameField(name: $name)
                    .onChange(of: name) { _, newValue in
                        // Debounced validation. Cancelling the prior
                        // task on each keystroke means we only pay the
                        // trim + parent invalidation once, ~200ms after
                        // the user pauses.
                        validationTask?.cancel()
                        validationTask = Task { [newValue] in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            if Task.isCancelled { return }
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            let valid = !trimmed.isEmpty
                            await MainActor.run {
                                if isNameValid != valid {
                                    isNameValid = valid
                                }
                            }
                        }
                    }

                SaveButton(isEnabled: isNameValid) {
                    // Trim on the actual submit — `isNameValid` may be
                    // one debounce-tick stale (user taps instantly
                    // after typing), so the final check is authoritative.
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    validationTask?.cancel()
                    onSave(trimmed, selectedEmoji)
                }

                Spacer()
            }
        }
    }
}

private struct SelectedEmojiPreview: View {
    let emoji: String
    var body: some View {
        Text(emoji)
            .font(.system(size: 50))
            .frame(width: 90, height: 90)
            .background(Circle().fill(Color.appAccent.opacity(0.15)))
    }
}

private struct EmojiGrid: View {
    let options: [String]
    @Binding var selected: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
            ForEach(options, id: \.self) { emoji in
                Button {
                    selected = emoji
                } label: {
                    Text(emoji)
                        .font(.system(size: 24))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(selected == emoji
                                      ? Color.appAccent.opacity(0.3)
                                      : Color.clear)
                        )
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

private struct NameField: View {
    @Binding var name: String

    var body: some View {
        TextField("", text: $name, prompt:
            Text("Your name").foregroundStyle(.appSecondary)
        )
        .textFieldStyle(.plain)
        .font(.system(size: 16))
        .foregroundStyle(.white)
        .tint(.appAccent)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled(true)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appSurface)
        )
        .padding(.horizontal, 20)
    }
}

private struct SaveButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("Create Profile")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isEnabled ? Color.appAccent : Color.appSecondary.opacity(0.3))
                )
        }
        .disabled(!isEnabled)
        .padding(.horizontal, 20)
    }
}
