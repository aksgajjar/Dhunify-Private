//
//  EQProcessor.swift
//  Dhunify
//
//  Real 3-band parametric EQ using MTAudioProcessingTap.
//  Applies biquad filters (low shelf, peaking, high shelf) to
//  AVPlayerItem audio in real time.
//

import AVFoundation
import MediaToolbox

// MARK: - Shared EQ state (read from audio thread)

/// Holds EQ gains and biquad coefficients. Accessed from both the main
/// thread (writes) and the real-time audio thread (reads). Float
/// read/writes are atomic on ARM64 so no locking is needed for gains.
final class EQTapStorage: @unchecked Sendable {
    // Gains in dB (-12 to +12)
    var bassGain: Float = 0
    var midGain: Float = 0
    var trebleGain: Float = 0

    // Biquad coefficients [b0, b1, b2, a1, a2] — normalized (a0 = 1)
    var bassC: [Float] = [1, 0, 0, 0, 0]
    var midC: [Float] = [1, 0, 0, 0, 0]
    var trebleC: [Float] = [1, 0, 0, 0, 0]

    // Per-channel delay state: [band 0..2][channel][z1, z2]
    var states: [[[Float]]] = []

    func prepare(channels: Int, sampleRate: Double) {
        states = Array(repeating: Array(repeating: [0, 0], count: channels), count: 3)
        updateCoefficients(sampleRate: sampleRate)
    }

    func updateCoefficients(sampleRate: Double) {
        bassC = Self.lowShelf(freq: 60, gainDB: bassGain, sr: sampleRate)
        midC = Self.peaking(freq: 1000, gainDB: midGain, q: 1.0, sr: sampleRate)
        trebleC = Self.highShelf(freq: 10000, gainDB: trebleGain, sr: sampleRate)
    }

    // ── RBJ Audio EQ Cookbook ──────────────────────────────────

    static func lowShelf(freq: Double, gainDB: Float, sr: Double) -> [Float] {
        guard abs(gainDB) > 0.01 else { return [1, 0, 0, 0, 0] }
        let A = pow(10.0, Double(gainDB) / 40.0)
        let w0 = 2 * Double.pi * freq / sr
        let cs = cos(w0); let sn = sin(w0)
        let alpha = sn / 2.0 * sqrt(2.0)
        let twoSqrtAa = 2 * sqrt(A) * alpha

        let a0 = (A+1) + (A-1)*cs + twoSqrtAa
        return [
            Float(A * ((A+1) - (A-1)*cs + twoSqrtAa) / a0),
            Float(2*A * ((A-1) - (A+1)*cs) / a0),
            Float(A * ((A+1) - (A-1)*cs - twoSqrtAa) / a0),
            Float(-2 * ((A-1) + (A+1)*cs) / a0),
            Float(((A+1) + (A-1)*cs - twoSqrtAa) / a0),
        ]
    }

    static func peaking(freq: Double, gainDB: Float, q: Double, sr: Double) -> [Float] {
        guard abs(gainDB) > 0.01 else { return [1, 0, 0, 0, 0] }
        let A = pow(10.0, Double(gainDB) / 40.0)
        let w0 = 2 * Double.pi * freq / sr
        let cs = cos(w0)
        let alpha = sin(w0) / (2.0 * q)

        let a0 = 1 + alpha / A
        return [
            Float((1 + alpha * A) / a0),
            Float((-2 * cs) / a0),
            Float((1 - alpha * A) / a0),
            Float((-2 * cs) / a0),
            Float((1 - alpha / A) / a0),
        ]
    }

    static func highShelf(freq: Double, gainDB: Float, sr: Double) -> [Float] {
        guard abs(gainDB) > 0.01 else { return [1, 0, 0, 0, 0] }
        let A = pow(10.0, Double(gainDB) / 40.0)
        let w0 = 2 * Double.pi * freq / sr
        let cs = cos(w0); let sn = sin(w0)
        let alpha = sn / 2.0 * sqrt(2.0)
        let twoSqrtAa = 2 * sqrt(A) * alpha

        let a0 = (A+1) - (A-1)*cs + twoSqrtAa
        return [
            Float(A * ((A+1) + (A-1)*cs + twoSqrtAa) / a0),
            Float(-2*A * ((A-1) + (A+1)*cs) / a0),
            Float(A * ((A+1) + (A-1)*cs - twoSqrtAa) / a0),
            Float(2 * ((A-1) - (A+1)*cs) / a0),
            Float(((A+1) - (A-1)*cs - twoSqrtAa) / a0),
        ]
    }
}

// MARK: - Observable EQ manager

@MainActor
@Observable
final class EQManager {
    static let shared = EQManager()

    var bassGain: Float = 0 { didSet { applyGains() } }
    var midGain: Float = 0 { didSet { applyGains() } }
    var trebleGain: Float = 0 { didSet { applyGains() } }
    var activePreset: String = "Flat" { didSet { saveSettings() } }

    /// Shared storage read by the audio tap on the render thread.
    let tapStorage = EQTapStorage()

    static let presets: [(name: String, bass: Float, mid: Float, treble: Float)] = [
        ("Flat", 0, 0, 0),
        ("Bass Boost", 8, 0, -2),
        ("Pop", 3, 2, 4),
        ("Rock", 5, -2, 6),
        ("Classical", -2, 0, 5),
    ]

    private init() { loadSettings() }

    func applyPreset(_ preset: (name: String, bass: Float, mid: Float, treble: Float)) {
        activePreset = preset.name
        bassGain = preset.bass
        midGain = preset.mid
        trebleGain = preset.treble
    }

    private func applyGains() {
        tapStorage.bassGain = bassGain
        tapStorage.midGain = midGain
        tapStorage.trebleGain = trebleGain
        if !tapStorage.states.isEmpty {
            tapStorage.updateCoefficients(sampleRate: 44100)
        }
        saveSettings()
    }

    private func saveSettings() {
        UserDefaults.standard.set(bassGain, forKey: "eq.bass")
        UserDefaults.standard.set(midGain, forKey: "eq.mid")
        UserDefaults.standard.set(trebleGain, forKey: "eq.treble")
        UserDefaults.standard.set(activePreset, forKey: "eq.preset")
    }

    private func loadSettings() {
        bassGain = UserDefaults.standard.float(forKey: "eq.bass")
        midGain = UserDefaults.standard.float(forKey: "eq.mid")
        trebleGain = UserDefaults.standard.float(forKey: "eq.treble")
        activePreset = UserDefaults.standard.string(forKey: "eq.preset") ?? "Flat"
        tapStorage.bassGain = bassGain
        tapStorage.midGain = midGain
        tapStorage.trebleGain = trebleGain
    }

    // MARK: - Create audio mix with EQ tap for an AVPlayerItem

    func createAudioMix(for item: AVPlayerItem) async -> AVAudioMix? {
        // Load audio tracks (needed for streaming content)
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)

        // Create MTAudioProcessingTap
        let storage = tapStorage
        let storagePtr = Unmanaged.passUnretained(storage).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(storagePtr),
            init: eqTapInit,
            finalize: eqTapFinalize,
            prepare: eqTapPrepare,
            unprepare: eqTapUnprepare,
            process: eqTapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let createdTap = tap else { return nil }

        params.audioTapProcessor = createdTap

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

// MARK: - MTAudioProcessingTap C callbacks

private let eqTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let eqTapFinalize: MTAudioProcessingTapFinalizeCallback = { _ in }

private let eqTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let storage = Unmanaged<EQTapStorage>.fromOpaque(
        MTAudioProcessingTapGetStorage(tap)
    ).takeUnretainedValue()
    let channels = Int(format.pointee.mChannelsPerFrame)
    let sr = format.pointee.mSampleRate
    storage.prepare(channels: channels, sampleRate: sr)
}

private let eqTapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let eqTapProcess: MTAudioProcessingTapProcessCallback = {
    tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in

    // Pull source audio
    var sourceFlags: MTAudioProcessingTapFlags = 0
    var sourceFrames: CMItemCount = 0
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut,
        &sourceFlags, nil, &sourceFrames
    )
    guard status == noErr else { return }
    numberFramesOut.pointee = sourceFrames
    flagsOut.pointee = sourceFlags

    let storage = Unmanaged<EQTapStorage>.fromOpaque(
        MTAudioProcessingTapGetStorage(tap)
    ).takeUnretainedValue()

    // Skip processing if all gains are zero
    guard abs(storage.bassGain) > 0.01
       || abs(storage.midGain) > 0.01
       || abs(storage.trebleGain) > 0.01 else { return }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let allCoeffs = [storage.bassC, storage.midC, storage.trebleC]

    for (chIdx, buf) in buffers.enumerated() {
        guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        guard chIdx < storage.states[0].count else { continue }

        // Apply 3 cascaded biquad filters
        for band in 0..<3 {
            let c = allCoeffs[band]
            var z1 = storage.states[band][chIdx][0]
            var z2 = storage.states[band][chIdx][1]
            let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]

            for i in 0..<count {
                let x = data[i]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                data[i] = y
            }

            storage.states[band][chIdx][0] = z1
            storage.states[band][chIdx][1] = z2
        }
    }
}
