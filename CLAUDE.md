## PLAYBACK SAFETY RECOVERY (permanent, highest priority)

**App priority #1: PRESS SONG → SONG PLAYS RELIABLY.** If playback breaks the
whole app is broken; stability always outranks features/UX. Never stack new work
on broken playback.

### Known-stable restore point
- Git tag **`playback-stable`** → commit `7d0de32`. Captures working relay
  architecture, resolver chain, AVPlayer config, `loadToken` serialization,
  preload-disabled safe state (`relayPlaybackMode`), buffering settings.
- **Restore commands:**
  - one file: `git checkout playback-stable -- XCode/Dhunify/Dhunify/Features/Player/PlayerViewModel.swift`
  - relay: `git checkout playback-stable -- relay/`
  - full hard reset (destructive — confirm first): `git reset --hard playback-stable`
- NEVER delete playback rollback tags / checkpoint history.

### Recovery protocol (if playback breaks after a change)
Symptoms: song won't play · long-track buffers forever · next/prev breaks ·
seek breaks · AVPlayer stuck · relay corruption · race conditions · unexpected
pause · readyToPlay never fires · queue corruption · lockscreen desync.
1. STOP all feature work.
2. Revert the unstable playback logic to `playback-stable` FIRST.
3. Confirm songs play again.
4. ONLY THEN retry the feature incrementally.

### Regression test checklist (run on device after every playback change)
1 hr+ mixes · rapid next/previous taps · seek · lockscreen controls ·
background playback · network interruption.

## Playback architecture — LOCKED (baseline 2026-05-24)

YouTube playback is **stable and frozen**. Do NOT redesign, rewrite the player
engine, re-enable the old preload system, or touch the relay protocol, resolver
chain ordering, `loadToken` serialization, or the relay URL flow.

Working pieces:
- Go byte-range relay (`relay/`): `GET /stream?id=<videoID>` → yt-dlp resolve
  (itag 139/140, cached to expiry) → bounded 1 MiB subrange stitching →
  full-body delivery → transparent mid-stream re-resolve on 403/expiry.
- App: `PlayerViewModel.relayStreamURL(youtubeID:)` strips the `yt_` prefix to
  the bare 11-char id and overrides `finalURL` for YouTube non-`file://` URLs in
  `loadCurrentSong` — **gated on `relayPlaybackMode`**.
- **CURRENT STATE (CP-RESET): YouTube plays the BACKEND stream.** `finalURL` is
  overridden to `backendStreamURL` (`Config.backendBaseURL/stream?id=yt_<id>`)
  for YT non-`file://` tracks — the reliable Cloudflare-Worker source. Relay-first
  DISABLED (`relayPlaybackMode = false`); relay/prewarm/diagnostics dormant.
  Legacy preload off (`legacyPreloadEnabled = false`). L2 offline (`file://`)
  still plays locally. Re-enable relay only later, with a working fallback.
  Reliability over optimization.
- Single-flight: `loadToken` + `loadStillCurrent`; install guarded by
  `loadGen == loadToken`. L2 `file://` offline cache still plays locally.

### Working contract (every playback edit)
Small, isolated, reversible steps only. Before each playback-related edit, add a
Rollback Checkpoint entry below documenting: current behavior · reason for change
· rollback path · affected functions ONLY. Then update the Graphify note
(`graphify-out/PLAYBACK_ARCHITECTURE.md`).

### Rollback checkpoints
- **CP-WORKER (2026-05-24) — THE FIX: bounded-subrange stitching in the Cloudflare Worker.**
  - *Root cause (finally):* app → `api.heyandirect.com` → 302 → Cloudflare Worker
    (`dhunify-audio…workers.dev`, `backend/worker/src/worker.js`). On R2 miss the
    Worker proxied the client's range to googlevideo **raw**. googlevideo throttles
    large/open-ended ranges (~30 KB/s) but serves bounded subranges (≤8 MB) at
    multi-MB/s. AVPlayer's open-ended + moov-at-EOF reads got throttled → item
    stuck `.unknown` forever. (URLSession warmup worked because its small range
    wasn't throttled.) NOT an app/state-machine bug.
  - *Fix:* Worker miss-path now probes total size, then serves the client range
    via **stitched bounded 4 MB subranges** (small ranges buffered for exact
    Content-Length; large ranges streamed with backpressure). Defeats the
    throttle. Verified locally: open range 30 KB/s → 5.9 MB/s; probe/moov carry
    exact Content-Length.
  - *Affected:* `backend/worker/src/worker.js` (miss-path only). R2-hit path
    unchanged. No app rebuild.
  - *DEPLOYED 2026-05-24* (version b20f7e16). Verified live: open-range
    31 KB/s → 9.66 MB/s; probe carries exact Content-Length. Redeploy after any
    worker.js change: `cd backend/worker && wrangler deploy`.
  - *Rollback:* `git`/edit the worker.js miss-path, redeploy.
- **CP-RESET3 (2026-05-24) — break deferred-load deadlock (the real `.unknown` cause).**
  - *Why:* item installed PAUSED + playback deferred to `.readyToPlay`, but a
    paused player (`automaticallyWaitsToMinimizeStalling=true`) wasn't loading
    the item → `.readyToPlay` never fired → deferred play never ran → stuck
    `.unknown` forever, every source. URLSession warmup loaded (doesn't wait).
  - *Change:* after `replaceCurrentItem`, if `wantsToPlay`, call
    `player.playImmediately(atRate: playbackSpeed)` to nudge AVPlayer to start
    loading immediately. May briefly flap WAITING (cosmetic) — reliable > clean.
  - *Affected:* `loadCurrentSong` install block.
  - *Rollback:* remove the eager `playImmediately` call.
- **CP-RESET2 (2026-05-24) — remove UA-override experiment (the real `.unknown` cause).**
  - *Why:* even via the backend stream, AVPlayerItem stayed `.unknown` forever
    (status=0, buffered=0, ~29s) while a URLSession warmup got HTTP 206 fine.
    The split = our own code: the YT item was built from an `AVURLAsset` with a
    custom `User-Agent` (`AVURLAssetHTTPHeaderFieldsKey`, cycling experiment UAs).
    AVPlayer's media requests used that non-default UA and stalled; URLSession
    (default UA) succeeded. Default AppleCoreMedia UA is required.
  - *Change:* build a vanilla `AVPlayerItem(url: playURL)` for all sources — no
    custom UA, no `AVURLAssetPreferPreciseDurationAndTimingKey` (CP2 reverted).
    Deleted the unused `experimentUAs` table.
  - *Affected:* `PlayerViewModel` — item construction in `loadCurrentSong`.
  - *Rollback:* `git checkout playback-stable -- .../PlayerViewModel.swift`.
  - *Status:* awaiting device verification.
- **CP-RESET (2026-05-24) — YouTube plays the BACKEND stream (reliable source).**
  - *Why:* with relay off, `finalURL` = direct googlevideo, which is IP-bound →
    AVPlayerItem stuck in `.unknown` forever (status=0, never `.readyToPlay`),
    no connection error. This is a SOURCE problem, not the play state machine
    (deferred autoplay/watchdog/guards all run AFTER `.readyToPlay`). The backend
    (`Config.backendBaseURL/stream?id=yt_<id>`, Cloudflare Worker) proxies
    audio/mp4 from its own egress IP → AVPlayer-friendly, reliable.
  - *Change:* in `loadCurrentSong`, override `finalURL` to `backendStreamURL(...)`
    for YouTube non-`file://` tracks (new helper). Replaces the retired relay
    override. Relay infra dormant behind `relayPlaybackMode=false`.
  - *Affected:* `PlayerViewModel` — `backendStreamURL` helper + the YT finalURL
    override block. Play path unchanged (already plays on `.readyToPlay`).
  - *Rollback:* remove the backend override block → falls back to resolved URL;
    or `git checkout playback-stable -- .../PlayerViewModel.swift`.
  - *Status:* awaiting device verification ("music always plays").
- **CP-RECOVER (2026-05-24) — PHASE 1: disable relay-first, restore reliable playback.**
  - *Why:* relay-first enforcement forced every YT track through the LAN relay,
    which iOS Local Network privacy blocked (-1009) / refused (-1004); fallbacks
    were suppressed → relay miss = HARD FAIL + poisoned state. (Logs: "Local
    network prohibited", ECONNREFUSED errno 61, "backend yt-dlp fallback
    suppressed (relay mode)".)
  - *Change:* `relayPlaybackMode = false` (relay override now gated on it →
    skipped); backend yt-dlp + webm fallbacks RE-ENABLED → graceful fallback on
    failure; legacy preload kept OFF via new decoupled `legacyPreloadEnabled =
    false`. Relay infra + diagnostics remain in code but dormant.
  - *Affected:* `PlayerViewModel` — `relayPlaybackMode` flag, relay-override
    condition, preload guard. No relay/resolver protocol change.
  - *Rollback:* set `relayPlaybackMode = true` to re-enable relay-first.
  - *Status:* awaiting device verification ("music always plays") before commit.
- **CP0 (2026-05-24) — LOCKED baseline.** Commit `7d0de32`. Relay playback
  stable: long tracks, next, seek, no hijack races. Rollback target for all
  Phase 1+ work.
- **CP1 (2026-05-24) — Phase 1 step 1: relay prewarm.**
  - *Current behavior:* next-track tap pays the relay's yt-dlp resolve latency
    (~300–1300 ms) before audio starts.
  - *Change:* at ~60% of the current track, fire ONE best-effort background
    `HEAD /stream?id=<nextID>` so the relay resolves + caches the next URL
    ahead of the tap. Metadata/warm only — no `AVPlayerItem`, no player
    replacement, no autoplay, no buffering. Relay cache expiry unchanged.
  - *Affected functions (only):* new `prewarmNextRelay()`, new stored prop
    `relayWarmedForSongID`, ~4-line call added in `handleTimeUpdate`.
  - *Rollback:* delete the `prewarmNextRelay()` call in `handleTimeUpdate`
    (one block) → CP0 behavior; or `git checkout 7d0de32 -- PlayerViewModel.swift`.
- **CP-diag (2026-05-24) — transition timing instrumentation (TEMPORARY).**
  - *Change:* behavior-free `tmark()` + `transitionStart`; logs `⏱️ T+ms` at
    load start → url finalized → item installed → readyToPlay → audible. Pure
    logging, no playback behavior change.
  - *Affected functions:* `loadCurrentSong` (marks), readyToPlay handler,
    `observeTimeControl`. New `tmark`/`transitionStart`.
  - *Rollback:* remove the `⏱️`/`tmark`/`transitionStart` lines. Remove once
    the next-song delay is localized.
- **CP2 (2026-05-24) — startup: skip precise timing parse.**
  - *Current behavior:* `item installed → readyToPlay` ~14–15s; AVPlayer loads
    + parses the full long-track progressive-MP4 `moov`/sample tables (moov at
    end, large for multi-hour tracks) before declaring ready. buffered=0 the
    whole window, then jumps.
  - *Change:* add `AVURLAssetPreferPreciseDurationAndTimingKey: false` to the
    YouTube `AVURLAsset` options in `loadCurrentSong` → readyToPlay on partial
    moov parse, not the full sample table.
  - *Affected functions (only):* the YT `AVURLAsset(...)` construction in
    `loadCurrentSong` (the `song.isYouTubeSource && !isFileURL` branch).
  - *Risk:* estimated duration / reduced seek precision on long tracks —
    MUST regression-test seek before keeping.
  - *Rollback:* remove the key from the options dict; or
    `git checkout playback-stable -- .../PlayerViewModel.swift`.
- **CP-diag2 (2026-05-24) — CarPlay next-track regression instrumentation (TEMPORARY).**
  - *Symptom:* with CarPlay attached, next (from CarPlay AND app) fails;
    disconnect → works. Current song keeps playing on attach.
  - *Change:* behavior-free `cpdiag()` state snapshot (isLoadingItem,
    loadingSongID, loadToken, idx, queue, hasItem, timeControlStatus,
    wantsToPlay, audio route) logged at `nextTrack`, `loadCurrentSong`,
    `play()`, `handleAirPlayRouteChange`, `handleInterruption`; remote
    nextTrackCommand logs when fired. Pure logging, NO behavior change.
  - *Affected functions:* those above + new `cpdiag`. Diagnosis only — no fix.
  - *Rollback:* remove `🚗DIAG`/`cpdiag` lines; or `git checkout playback-stable -- .../PlayerViewModel.swift`.
- **CP3 (2026-05-24) — Local Network permission (relay throughput).**
  - *Current behavior:* relay LAN path ~128 KB/s (vs 6.5 MB/s direct); repeated
    "Local network prohibited"; slow `item installed → readyToPlay`. iOS Local
    Network privacy was gating/throttling connections to the LAN relay IP.
  - *Change:* add `NSLocalNetworkUsageDescription` to `Info.plist` so iOS shows
    the Local Network prompt; granting it ungates LAN-IP connections. ATS
    already allows cleartext (`NSAllowsArbitraryLoads`), so ATS was not the
    blocker. Config only — no playback code touched.
  - *Affected:* `Info.plist` (one key). No Swift change.
  - *Validation:* after install, grant the Local Network prompt (or Settings →
    Privacy → Local Network → Dhunify ON); re-measure relay throughput +
    `⏱️ item installed → readyToPlay`. Expect throughput ↑, readyToPlay ↓.
  - *Strategic follow-up (not CP3):* on-device localhost relay (127.0.0.1) is
    exempt from Local Network privacy + removes the Wi-Fi hop — production endgame.
  - *Rollback:* remove the `NSLocalNetworkUsageDescription` key from Info.plist.
- **CP4 (2026-05-24) — CarPlay wedge recovery watchdog.**
  - *Root cause:* CP1 suppressed `swapToBackendYTStream`, but the 30s unknown-hang
    watchdog still called it → no-op → a stalled load never cleared `isLoadingItem`
    → all later loads blocked by the same-song/in-flight guards (player "poisoned
    until restart", esp. CarPlay-originated new-song loads).
  - *Change:* under `relayPlaybackMode`, the unknown-hang watchdog now FORCE-CLEARS
    the wedged loading state (`isLoadingItem=false`, `loadingSongID=nil`,
    `isBuffering=false`, soft error) instead of the dead backend swap. Fires only
    when genuinely stuck (status still not ready/failed at 30s) → can't abort a
    valid slower long-track load.
  - *Affected functions:* the `unknownStatusWatchdog` action block in `loadCurrentSong`.
  - *Rollback:* restore the single `swapToBackendYTStream` call; or `git checkout playback-stable -- .../PlayerViewModel.swift`.
- **CP-diag3 (2026-05-24) — CarPlay selection-flow instrumentation (TEMPORARY).**
  - *Change:* behavior-free `cpdiag` at `setQueue`, every `loadCurrentSong`
    early-return (same-song skip, cooldown, stale-install abort), and the
    `play()` load-in-flight return. Localizes where a CarPlay-originated new-song
    load stalls. Pure logging.
  - *Rollback:* remove the added `cpdiag(...)` lines.

## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `python3 -c "from graphify.watch import _rebuild_code; from pathlib import Path; _rebuild_code(Path('.'))"` to keep the graph current
