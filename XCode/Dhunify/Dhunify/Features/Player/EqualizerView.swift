//
//  EqualizerView.swift
//  Dhunify
//
//  3-band EQ control sheet wired to EQManager, which drives the real
//  MTAudioProcessingTap filter chain in EQProcessor.swift. Slider moves
//  update EQManager gain properties, whose `didSet` propagates into the
//  live tap storage and persists settings.
//

import SwiftUI

struct EqualizerView: View {
    @Bindable var eqManager = EQManager.shared
    @Environment(AppContainer.self) private var container
    @Binding var isPresented: Bool
    @State private var crossfadeOn: Bool = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Equalizer")
                        .font(.appTitle)
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        HapticManager.soft()
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.appSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)

                // Crossfade toggle
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Crossfade")
                            .font(.appHeadline)
                            .foregroundColor(.white)
                        Text("Songs smoothly blend into each other")
                            .font(.appCaption)
                            .foregroundColor(.appSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { crossfadeOn },
                        set: { newValue in
                            crossfadeOn = newValue
                            container.playerViewModel.crossfadeEnabled = newValue
                        }
                    ))
                    .tint(Color.appOcean)
                    .labelsHidden()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .onAppear { crossfadeOn = container.playerViewModel.crossfadeEnabled }

                // Preset chips — driven by EQManager.presets tuple array.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(EQManager.presets, id: \.name) { preset in
                            presetChip(preset)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 40)

                // 3 vertical sliders — Bass / Mid / Treble.
                HStack(alignment: .bottom, spacing: 0) {
                    EQBandSlider(
                        label: "Bass",
                        sublabel: "60Hz",
                        value: Binding(
                            get: { Double(eqManager.bassGain) },
                            set: { eqManager.bassGain = Float($0) }
                        )
                    )
                    .frame(maxWidth: .infinity)

                    EQBandSlider(
                        label: "Mid",
                        sublabel: "1kHz",
                        value: Binding(
                            get: { Double(eqManager.midGain) },
                            set: { eqManager.midGain = Float($0) }
                        )
                    )
                    .frame(maxWidth: .infinity)

                    EQBandSlider(
                        label: "Treble",
                        sublabel: "10kHz",
                        value: Binding(
                            get: { Double(eqManager.trebleGain) },
                            set: { eqManager.trebleGain = Float($0) }
                        )
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)

                Spacer()
            }
        }
    }

    private func presetChip(_ preset: (name: String, bass: Float, mid: Float, treble: Float)) -> some View {
        let isSelected = eqManager.activePreset == preset.name
        return Button {
            HapticManager.soft()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                eqManager.applyPreset(preset)
            }
        } label: {
            Text(preset.name)
                .font(.appCaption)
                .fontWeight(.medium)
                .foregroundColor(isSelected ? .white : .appSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [Color.appOcean, Color.appAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        : AnyShapeStyle(Color.appSurface)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            Color.appOcean.opacity(isSelected ? 0 : 0.3),
                            lineWidth: 0.5
                        )
                )
        }
        .scaleButton(0.95)
    }
}

// MARK: - EQBandSlider

struct EQBandSlider: View {
    let label: String
    let sublabel: String
    @Binding var value: Double
    private let range: ClosedRange<Double> = -12...12

    var body: some View {
        VStack(spacing: 10) {
            Text(String(format: "%+.0fdB", value))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.appSecondary)
                .frame(width: 52)

            VerticalSlider(
                value: $value,
                range: range,
                accentColor: Color.appOcean
            )
            .frame(width: 44, height: 200)

            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            Text(sublabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.appSecondary)
        }
    }
}

// MARK: - VerticalSlider

struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            let fillHeight = max(4, geo.size.height * normalizedValue)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.appSurface)
                    .frame(width: 6)
                    .frame(maxWidth: .infinity)

                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [accentColor, Color.appAccent],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 6, height: fillHeight)
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .offset(y: -(fillHeight - 11))
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newValue = 1 - drag.location.y / geo.size.height
                        let clamped = min(max(newValue, 0), 1)
                        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }

    private var normalizedValue: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}
