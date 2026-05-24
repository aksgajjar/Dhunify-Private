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
  `loadCurrentSong`. `relayPlaybackMode = true` disables old preload, the backend
  yt-dlp swap (`swapToBackendYTStream`), and the webm→mp4 swap (`swapToYTFallback`).
- Single-flight: `loadToken` + `loadStillCurrent`; install guarded by
  `loadGen == loadToken`. L2 `file://` offline cache still plays locally.

### Working contract (every playback edit)
Small, isolated, reversible steps only. Before each playback-related edit, add a
Rollback Checkpoint entry below documenting: current behavior · reason for change
· rollback path · affected functions ONLY. Then update the Graphify note
(`graphify-out/PLAYBACK_ARCHITECTURE.md`).

### Rollback checkpoints
- **CP0 (2026-05-24) — LOCKED baseline.** Relay playback stable: long tracks,
  next, seek, no hijack races. Rollback target for all Phase 1+ work. (Commit
  this state before the first Phase 1 edit.)

## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `python3 -c "from graphify.watch import _rebuild_code; from pathlib import Path; _rebuild_code(Path('.'))"` to keep the graph current
