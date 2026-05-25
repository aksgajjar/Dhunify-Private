# Playback Forensic Recovery Analysis (2026-05-24)

Goal: identify the "golden" instant/native build, what destabilized it, and the
safest path back. Method: fingerprinted each Xcode archive's compiled binary for
playback-architecture symbols (`strings | grep`), correlated with git + version.

## Architecture timeline (from archive binaries)

| Date | App / Version(Build) | Architecture markers | Playback model |
|---|---|---|---|
| Apr 06–10 | DIPHORIA v1.0 (1–3.1) | `workers.dev` | early Cloudflare-worker proxy |
| **Apr 12–15** | Dhunify v1–v4 | **`m3u8`** | **HLS (native) — no worker/backend** |
| **Apr 17** | Dhunify v5.1–v7.1 | **`heyandirect` + `m3u8`** | **HLS primary + backend fallback** ← git `c855ac1` "HLS_LONG_TRACK_STABLE_V1" |
| Apr 18 | Dhunify v8.1 | `heyandirect` + `m3u8` + **`preloadNextSong`** | HLS + backend + preload (1st complexity) |
| Apr 19 | Dhunify **v9.1(8.1)** | `heyandirect` + `m3u8` + `preloadNextSong` | **= the TestFlight build in the screenshot — still HLS** |
| **Apr 22** | DIPHORIA v10.1 | `workers.dev` (**m3u8 GONE**) | **HLS DROPPED → progressive via worker** ← regression starts |
| May 14–21 | DIPHORIA v10.x–v11 | `workers.dev` | progressive proxy, layered |
| May 24 (this session) | uncommitted → `0766cb3` | relay + backend-primary + UA-experiment + watchdog + eager-play | progressive + raw-passthrough worker (throttled) → `.unknown` saga |

## Best build & WHY it felt instant/native

**Golden window = the HLS era, Apr 12 → Apr 19** (best git anchor: `c855ac1`,
"HLS_LONG_TRACK_STABLE_V1", Apr 17; latest HLS build = v9.1(8.1), Apr 19, the
screenshot build).

Why instant/native: **AVPlayer plays HLS (`m3u8`) natively.** HLS is segmented —
AVPlayer starts on a tiny first segment (no full-file dependency), there is **no
moov-at-EOF scan** and **no throttle sensitivity**. That is exactly the "instant,
native" feel. Progressive MP4 (the later model) requires the `moov` atom (at end
of file for these YT itags) before `.readyToPlay`, and googlevideo throttles
large/open-ended reads → slow or stuck startup.

## What destabilized playback (in order)

1. **Apr 18 — `preloadNextSong` added.** First concurrency layer → later
   install-hijack / "poisoned state" races.
2. **Apr 22 — HLS abandoned for progressive-via-worker. ← ROOT REGRESSION.**
   Traded AVPlayer-native HLS for progressive MP4, exposing moov-at-EOF + the
   googlevideo throttle. Everything after is symptom management.
3. **May — progressive layered** with caching/proxy variants.
4. **May 24 (this session) — stacked fixes** on the progressive base: LAN/on-device
   relay, backend-primary override, custom-UA AVURLAsset experiment, deferred
   play / eager play, unknown-hang watchdog. The Cloudflare worker still did a
   **raw range passthrough** → googlevideo throttled it (~30 KB/s) → AVPlayer
   stuck `.unknown`. (Worker stitching fix shipped this session restores fast
   progressive delivery, but it is treating the symptom of dropping HLS.)

## Safest path back

**Restore HLS playback.** Confirmed today via `yt-dlp -F`: YouTube still serves
HLS `m3u8` manifests (formats 91–96, video+audio). The regression was the
**resolver's client chain losing `hlsManifestUrl`** — current clients
(IOS_MUSIC/TVHTML5/IOS/ANDROID_VR) return progressive only, so the code falls
back to itag 139 and inherits the moov/throttle problems. The golden resolver
obtained `hlsManifestUrl` and handed the `m3u8` straight to AVPlayer.

Recommended (NOT yet done — pending decision):
1. Inspect the golden resolver (`git show c855ac1` → `YouTubeStreamResolver`)
   for which client returned `hlsManifestUrl`.
2. Restore that HLS-capable client / manifest retrieval; play the `m3u8` natively.
3. If HLS playback is restored, the relay + worker-stitching + backend-primary +
   custom-UA + eager-play layers become **unnecessary** — delete, don't maintain.
4. Keep the worker stitching deployed only as a progressive fallback for videos
   that lack HLS.

## Preservation (done)

- Commit `0766cb3` — worker stitching (force-added) + app recovery state.
- Tag `snapshot/2026-05-24-worker-stitch`.
- Branch `recovery/archive-analysis` (at HEAD) — holds this report.
- Branch `recovery/golden-baseline` (at `c855ac1`) — HLS golden restore point.
- Worker also preserved live: Cloudflare deployment version `b20f7e16`.
- Note: git history starts Apr 17 (`ce35053`); Apr 06–15 archives predate git
  (binaries are the only record for those).
