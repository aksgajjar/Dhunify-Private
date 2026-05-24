import SwiftUI
import AVFoundation
import os

/// EXPERIMENT HARNESS (temporary). Isolated, dependency-free probe to
/// settle the long-track playback question empirically on-device — the
/// only place these IP-bound googlevideo URLs are valid.
///
/// Present it from any debug hook, e.g. temporarily in `DhunifyApp`:
///     WindowGroup { PlaybackLabView() }
/// or from a sheet/button. Remove the file when the experiment concludes.
///
/// Decisive test = "URLSession sustained": does the APP process's own
/// URLSession download the long file sequentially without throttling to
/// zero? That decides whether an `AVAssetResourceLoaderDelegate` proxy is
/// viable (app fetches, feeds AVPlayer) vs. backend relay being mandatory.
struct PlaybackLabView: View {
    @State private var videoID = "z3oE8E1AEHo"   // a known-failing long track
    @State private var relayURL = "https://"     // paste the relay /stream URL
    @State private var log = ""
    @State private var running = false

    private static let logger = Logger(subsystem: "com.diphoria.Dhunify", category: "PlaybackLab")

    var body: some View {
        VStack(spacing: 10) {
            Text("Playback Lab").font(.headline)
            TextField("videoID", text: $videoID)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("relay /stream URL", text: $relayURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button("① URLSession sustained fetch (decisive)") {
                Task { await runURLSessionSustainTest() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)

            Button("② Plain AVPlayer control (expect 0 bytes)") {
                Task { await runAVPlayerControl() }
            }
            .buttonStyle(.bordered)
            .disabled(running)

            Button("③ Relay AVPlayer proof") {
                Task { await runRelayAVPlayer() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)

            Button("Clear log") { log = "" }.font(.caption)

            ScrollView {
                Text(log)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    @MainActor private func append(_ s: String) {
        log += s + "\n"
        Self.logger.info("🔬 \(s, privacy: .public)")
    }

    /// Resolve FRESH on-device (matches device egress IP). Forces the
    /// long-track path with a large expectedDuration so we get the same
    /// itag=139 progressive URL the app fails on.
    private func resolve() async -> URL? {
        await append("resolving \(videoID) (long-track path)…")
        do {
            let stream = try await YouTubeStreamResolver.shared.resolve(videoID: videoID, expectedDuration: 3000)
            await append("resolved host=\(stream.url.host ?? "?") mime=\(stream.mimeType) dur=\(Int(stream.duration))s isHLS=\(stream.url.absoluteString.contains(".m3u8"))")
            return stream.url
        } catch {
            await append("resolve FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    /// DECISIVE: sequential range download via the app's URLSession up to
    /// 8 MB. Logs cumulative bytes + throughput + stall. If it sustains,
    /// a resource-loader proxy can feed AVPlayer; if it throttles to zero,
    /// only a backend relay can.
    private func runURLSessionSustainTest() async {
        await MainActor.run { running = true }
        defer { Task { @MainActor in running = false } }

        guard let url = await resolve() else { return }
        let chunk = 524_288                 // 512 KB per range
        let target = 8 * 1024 * 1024        // sustain check: 8 MB
        var offset = 0
        let start = Date()

        while offset < target {
            var req = URLRequest(url: url)
            req.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            req.timeoutInterval = 12
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if data.isEmpty {
                    await append("⚠️ zero bytes at \(offset / 1024)KB (http=\(code)) — throttled/stopped")
                    break
                }
                offset += data.count
                let mb = Double(offset) / 1_048_576
                let secs = Date().timeIntervalSince(start)
                await append("@\(offset/1024)KB http=\(code) +\(data.count)B total=\(String(format: "%.2f", mb))MB \(String(format: "%.2f", mb / max(secs, 0.001)))MB/s")
            } catch {
                await append("❌ error at \(offset / 1024)KB: \(error.localizedDescription)")
                break
            }
        }

        let total = Date().timeIntervalSince(start)
        if offset >= target {
            await append("✅ SUSTAINS \(offset/1024)KB in \(String(format: "%.1f", total))s → AVAssetResourceLoader VIABLE")
        } else {
            await append("⛔️ stalled at \(offset/1024)KB → resource-loader NOT viable; backend relay required")
        }
    }

    /// CONTROL: plain AVPlayer on the same fresh URL; watch loadedTimeRanges
    /// for 20s. Expected to mirror the app: 0 bytes, never readyToPlay.
    private func runAVPlayerControl() async {
        await MainActor.run { running = true }
        defer { Task { @MainActor in running = false } }

        guard let url = await resolve() else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.play()

        for i in 1...20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let buffered = item.loadedTimeRanges
                .map { CMTimeGetSeconds($0.timeRangeValue.duration) }
                .reduce(0, +)
            await append("AVPlayer t=\(i)s status=\(item.status.rawValue) buffered=\(String(format: "%.1f", buffered))s tcs=\(player.timeControlStatus.rawValue)")
            if item.status == .failed {
                await append("AVPlayer .failed: \(item.error?.localizedDescription ?? "nil")")
                break
            }
            if buffered > 1 {
                await append("✅ AVPlayer consuming bytes")
                break
            }
        }
        player.pause()
    }

    /// PROOF: AVPlayer against relay /stream URL. Success criteria:
    /// buffered > 0 and/or readyToPlay, proving mediaserverd can consume
    /// our origin with normal byte-range progressive playback.
    private func runRelayAVPlayer() async {
        await MainActor.run { running = true }
        defer { Task { @MainActor in running = false } }

        guard let url = URL(string: relayURL), ["http", "https"].contains(url.scheme?.lowercased()) else {
            await append("relay URL invalid")
            return
        }

        await append("relay AVPlayer → \(url.absoluteString)")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.play()

        for i in 1...45 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let buffered = item.loadedTimeRanges
                .map { CMTimeGetSeconds($0.timeRangeValue.duration) }
                .reduce(0, +)
            await append("Relay t=\(i)s status=\(item.status.rawValue) buffered=\(String(format: "%.1f", buffered))s tcs=\(player.timeControlStatus.rawValue)")
            if item.status == .failed {
                await append("Relay .failed: \(item.error?.localizedDescription ?? "nil")")
                break
            }
            if item.status == .readyToPlay || buffered > 1 {
                await append("✅ RELAY PLAYBACK PROVEN")
                break
            }
        }
        player.pause()
    }
}
