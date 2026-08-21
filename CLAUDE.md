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
- **CP-RESOLVER-FALLBACK (2026-08-19) — pre-URL resolver total-failure fallback.**
  - *Symptom:* "Couldn't resolve this track. Try another." — device log showed
    IOS client returns IP-bound URL (skipped, correct), ANDROID_VR client
    rejected with "Sign in to confirm you're not a bot", no other client tried
    → `ALL_CLIENTS_FAILED` thrown from `YouTubeStreamResolver.resolve` inside
    `loadCurrentSong` BEFORE any URL exists. Confirms the `youtube_ip_bound_all_clients`
    OPEN item: the existing backend-worker fallback (`swapToBackendYTStream`,
    used successfully by the post-URL `.failed` KVO branch and CP-SILENT-VLC's
    VLC watchdog) never ran here because those triggers only fire once VLC/AVPlayer
    has a URL to fail on — a resolve-time throw has no URL yet, so the app fell
    straight to a user-facing error with no fallback attempt.
  - *Fix:* the resolver `catch` block in `loadCurrentSong` (was: set `playbackError`
    + return) now checks `!backendFallbackUsed` first and calls
    `swapToBackendYTStream(song:, resumeAt: currentTime)` — same one-shot backend
    worker proxy path (`api.heyandirect.com/stream?id=yt_<id>`) already proven
    reliable elsewhere in this file. Only falls through to the error message if
    the backend fallback was already used this load (matches existing one-shot
    guard pattern at line ~1328).
  - *Affected:* one `catch` block only, in the non-preloaded YT resolve branch of
    `loadCurrentSong` (PlayerViewModel.swift, YT path start / resolver-failure
    section). No resolver client-chain logic, no VLC engine, no protocol change.
  - *Rollback:* restore the catch block to unconditionally set `playbackError`
    and return (drop the `swapToBackendYTStream` call + `backendFallbackUsed`
    guard); or `git checkout playback-stable-9 -- .../PlayerViewModel.swift`.
  - *Status:* built for physical device via `xcodebuild` (Xcode 27 beta,
    DEVELOPER_DIR override) — awaiting device replay of the failing track to
    confirm audible fallback.
- **CP-SILENT-VLC (2026-08-19) — no-audio fix: build break + silent VLC failure + dead `/fstream`.**
  - *Symptom:* press Play → no audio, often no error at all.
  - *Root causes (3, all verified):*
    1. **Working tree did not compile.** `PlayerViewModel.swift` L326/L1038 carried
       raw `\u2192` / `\u23f0` escapes — invalid Swift (only `\u{...}` is legal).
       `swiftc -frontend -parse` → *"expected hexadecimal code in braces after
       unicode escape"*. No build could be produced from that tree.
    2. **VLC path had no failure surface.** VLC owns YT-progressive
       (`vlcSmokeTest=true`) but has no AVPlayer `.failed` KVO, so a rejected
       googlevideo fetch was silent — no audio, no error, no fallback, forever.
       YouTube now signs **every** client's audio URL with `ip=` (verified: all
       5 IOS audio formats carry it; tampering the param → HTTP 403), so any
       egress-IP change (Wi-Fi↔LTE, CGNAT, Private Relay) turns playback into a
       403 the app could not see.
    3. **Fly `/fstream` is gone** — `GET /fstream?id=yt_…` → **404** (Fly only
       exposes `/stream` + `/stream/{id}`). The AVPlayer YT-progressive branch
       and the launch/next-track prewarm were both pointed at that dead route.
  - *Fix:* (a) fix the invalid escapes; (b) `VLCPlaybackEngine.onError` bridge +
    `isActuallyPlaying`/`stateDescription` readouts, and
    `armVLCReadinessWatchdog(song:loadGen:)` — 8s no-audio → `swapToBackendYTStream`;
    armed from the VLC load AND from `play()` (a paused load never armed one);
    watchdog asks VLC for real state, not the optimistic `isPlaying`;
    (c) repoint the `/fstream` branch + `prewarmFstream` at `backendStreamURL`
    (`api.heyandirect.com/stream?id=yt_<id>` → 302 → Worker → verified 206 audio/mp4).
  - *Affected:* `VLCPlaybackEngine` (onError, isActuallyPlaying, stateDescription,
    state-changed bridge); `PlayerViewModel` (wireVLCEngine, failVLCAndFallBackToBackend,
    armVLCReadinessWatchdog, loadCurrentSong VLC + progressive branches,
    prewarmFstream, play()). No resolver, UI, queue, or protocol change.
  - *Rollback:* `git checkout playback-stable-9 -- XCode/Dhunify/Dhunify/Features/Player/PlayerViewModel.swift XCode/Dhunify/Dhunify/Core/Playback/VLCPlaybackEngine.swift`.
  - *Status:* AWAITING DEVICE TEST — no Xcode on this machine, so only
    `swiftc -frontend -parse` (clean on all three files) could be run.
  - *OPEN:* `YouTubeStreamResolver.resolveStable` rejects IP-bound URLs from every
    client. Now that YouTube IP-binds every client, it **always throws** → the
    AVPlayer stall-recovery re-resolve is permanently dead. Left untouched
    (locked resolver logic); needs its own reviewed checkpoint.
- **CP-VLC-2a (2026-05-26) — VLC engine for YT-progressive (replaces AVPlayer faststart).**
  - *Root:* AVPlayer can't fast-start YouTube's raw fragmented itag139 (scans
    whole moov) — faststart via Fly was ~4-6s. Smoke test proved VLC plays the
    raw IP-bound googlevideo URL directly, audible ~1.1-2.4s, NO Fly/worker/remux.
  - *Fix:* new `Core/Playback/VLCPlaybackEngine.swift` (owns `VLCMediaPlayer`,
    `import VLCKitSPM`). PlayerViewModel routes the YT non-file non-HLS path
    through it, gated on `vlcSmokeTest` + new `usingVLC` flag. Engine callbacks
    (`onTime`/`onPlaying`/`onEnded`) drive `currentTime`/`duration`/`progress`/
    `isPlaying` → existing UI + now-playing bindings unchanged. AVPlayer fully
    OUT of VLC loads (no item/KVO/watchdog); timeControlStatus observer guards
    `!usingVLC`. AVPlayer still owns `file://` offline + HLS + JioSaavn.
  - *Resolver (paired):* `YouTubeStreamResolver.vlcDirectLongTrack=true` collapses
    the long-track chain to ANDROID_VR-first (skips dead HLS hunt) → resolve
    ~150-255ms vs 4-client ~600-800ms+.
  - *Affected:* PlayerViewModel — `vlcEngine`/`usingVLC` props, `wireVLCEngine()`,
    loadCurrentSong VLC branch, volume/playbackSpeed didSet, play/pause/seek/
    seekToStart/stop routing, observeTimeControl guard. YouTubeStreamResolver —
    `vlcDirectLongTrack` flag + orderedChain branch. New VLCPlaybackEngine.swift.
  - *Rollback:* `PlayerViewModel.vlcSmokeTest = false` → AVPlayer faststart path
    (CP6) returns; `YouTubeStreamResolver.vlcDirectLongTrack = false` → HLS chain.
    Or `git checkout playback-stable-6 -- .../PlayerViewModel.swift`.
  - *Status:* awaiting device test — seek (mashup scrub), play/pause correctness,
    next/prev, lockscreen, **sustained full long mashup** (IP-bound hold on VLC).
  - *NOT done (next):* CarPlay scrub/now-playing (2c), crossfade (AVPlayer-only),
    AVPlayer preload/L2 prefetch dormant on VLC path.
- **CP6 (2026-05-25) — INSTANT START: Fly faststart-remux `/fstream` + app prewarm.**
  - *Root (CP5 proved):* slow readyToPlay = fragmented DASH (AVPlayer scans whole
    file) + worker re-fetch every play. Unfixable app-side.
  - *Fix (Fly, deployed):* new `GET /fstream?id=yt_<id>` on `dhunify-api.fly.dev`
    — resolves itag139, downloads via **concurrent 4 MB subranges** (beats the
    googlevideo per-stream throttle: 38 MB in ~0.7 s vs ~12 s), then
    `ffmpeg -c copy -movflags +faststart` → **moov-at-front progressive MP4**
    cached on `/tmp` (2 GB LRU). AVPlayer reads ~256 KB → **instant ready**.
    Warm/prewarmed ttfb ~0.26 s; cold ~8-19s (resolve + 2-pass remux).
    Image: base = current Fly image + `apt ffmpeg` (zero dep drift); deploy dir
    `/tmp/dhunify-deploy/` (Dockerfile + main.py + fly.toml). yt-dlp pinned by
    base image (2026.03.17). Rollback: `fly releases` → prior release.
  - *App (this CP):* `PlayerViewModel` — (a) YT non-file non-HLS finalURL now
    routes to `Self.fstreamURL` (`Config.flyBaseURL/fstream?id=`) instead of the
    worker `backendStreamURL`; (b) `prewarmNextFstream()` fires a HEAD to
    `/fstream` for the next queued track at ~40% (one-shot, detached, no player
    mutation). HLS-primary gate unchanged; L2 `file://` unchanged; `.failed`/
    watchdog still `swapToBackendYTStream` (worker) → build-miss safe.
  - *Affected:* `AppContainer.Config.flyBaseURL` (new); `PlayerViewModel`
    finalURL override block, `fstreamURL` helper, `prewarmNextFstream` +
    `fstreamWarmedForSongID` + handleTimeUpdate trigger.
  - *Rollback (app):* in the override change `Self.fstreamURL` back to
    `Self.backendStreamURL` + remove the prewarm trigger; or `git checkout
    playback-stable-2 -- .../PlayerViewModel.swift`. *(Fly stays; harmless.)*
  - *Status:* awaiting device test (instant on prewarmed/warm; first cold tap
    ≈ today; song-play + audio-no-stop must hold).
- **CP5 (2026-05-25) — REVERTED (no effect). skip precise-timing scan.**
  - *Tried:* `AVURLAsset(url:, options:[AVURLAssetPreferPreciseDurationAndTimingKey:false])`
    to cut readyToPlay. Built + device-tested → NO measurable win. Reverted to
    `AVPlayerItem(url: playURL)`.
  - *Why it failed:* the flag can't help a fragmented DASH file with no `sidx` —
    AVFoundation scans the moof fragments regardless.
  - *Real root cause (curl-proven vs prod, 2026-05-25):* slow start is
    **worker/Fly-side, not app-side**. (1) Fly (`dhunify-api.fly.dev`) hardcodes
    **itag140 (~128kbps; 42MB for a 44min mix)**; ignores `?itag=`/`?quality=`.
    (2) Worker only proxies Fly's URL — can't pick a format (worker.js:34-49
    `resolveYouTube` → `/resolve/yt_{id}`). (3) Worker `x-cache: MISS` every
    request → re-fetches googlevideo each play, no caching. (4) Worker won't
    serve suffix range `bytes=-N` (returns 200 whole file). (5) `ftypdash`
    fragmented DASH, no sidx → AVPlayer drags ~the whole file before ready.
    (6) `?src=` bypass unusable — app's itag139 URLs are phone-IP-bound → worker
    403; direct-from-phone throttled.
  - *Conclusion:* no app- or worker-side fix; the only speed lever (smaller/
    faststart/sidx audio) lives in **Fly (black-box, no source)**. Needs Fly
    ownership: `fly ssh console -a dhunify-api` or replace the resolver.
  - *Baseline:* tag `playback-stable-2` (727d27f) + worker `515d2782`.
- **CP-WORKER3 (2026-05-25) — worker streaming: pull-driven ReadableStream (fixes random truncation).**
  - *Symptom:* audio stopped ~40-50s while the clock kept running, across tracks.
    Root: the `ctx.waitUntil`+TransformStream pump was killed by Cloudflare at
    RANDOM points (same single pull gave 9.5MB once, 1.3MB next; never reliable)
    → partial body vs Content-Length → AVPlayer played to the gap then ran silent.
  - *Fix:* incremental pull-driven `ReadableStream` (no `waitUntil`; opens the
    next 4MB subrange as the client drains, enqueues network-sized chunks).
    Tied to the response lifecycle. `backend/worker/src/worker.js`.
  - *Deployed* version `515d2782`. Verified on production: full 9.5MB on single
    ×3 + 3-concurrent + 60s slow-read sustained (was random truncation).
  - *Note:* an earlier pull-stream (`9001d06b`) was reverted on a misread — the
    "resource unavailable" was a backend 502 (googlevideo 403) on a long song,
    not the pull-stream.
  - *Rollback:* `wrangler rollback` to a prior version (e.g. `b20f7e16`).
- **OPEN: long-song 502.** 60/89-min videos → worker `502 {"error":"CDN returned
  403"}` (googlevideo rejects the Fly-resolved URL). Separate from streaming;
  worker resolve/retry issue for ultra-long videos. Not yet fixed.
- **CP-WORKER2 (2026-05-24) — fix worker stream truncation (continuity).**
  - *Symptom:* progressive audio started fine, then went SILENT ~50s in while the
    AVPlayer clock kept advancing. Root: the worker's large-range streaming branch
    used `ctx.waitUntil` + TransformStream pump, which **Cloudflare truncated early
    on production** (~3-6MB of 40MB; 10MB req→6MB) → body shorter than advertised
    Content-Length → AVPlayer ran past received bytes = silence-with-clock.
    (Bytes delivered were correct/contiguous — pure truncation, not corruption.)
  - *Fix:* replaced the pump with a consumer-driven `ReadableStream({ pull })`
    tied to the response lifecycle (fetches next 4MB subrange as the client
    drains). Buffered branch (≤8MB) unchanged. `backend/worker/src/worker.js`.
  - *Deployed* version `9001d06b`. Verified: full 40MB delivered (was 2.6MB);
    96 KB/s slow read sustained full 60s (was dying ~22s).
  - *Rollback:* revert worker.js streaming branch, `wrangler deploy`.
- **CP-DUAL (2026-05-24) — dual-path gate: HLS primary (music), worker-progressive floor.**
  - *Finding (resolver spike):* YouTube serves `hlsManifestUrl` to the app's
    existing IOS client **anonymously, but only for official music videos**
    (verified: `dQw4w9WgXcQ`→HLS; long mixes→none). Long user mixes/jukeboxes
    (the app's bulk content) get progressive itag 139 only. `web_safari`/
    `tv_embedded` HLS needs the PO-token/SABR handshake (heavy, fragile) — NOT
    pursued. The CP-RESET backend override was discarding the HLS URLs IOS
    already returns for music.
  - *Change (one block in `loadCurrentSong`):* gate the backend override on
    `Self.urlIsHLS(finalURL)`. HLS URL → kept → native AVPlayer (instant).
    Non-HLS → backend worker (stitched progressive floor). No resolver change,
    no PO-token machinery, preload still off, fallback (`.failed`/watchdog →
    `swapToBackendYTStream`) intact.
  - *Affected:* `PlayerViewModel.swift` finalURL override block only. Uses
    existing `urlIsHLS` (L2468).
  - *Rollback:* delete the leading `if … urlIsHLS(finalURL) { … } else ` branch
    → reverts to backend-always; or `git checkout playback-stable -- …`.
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
