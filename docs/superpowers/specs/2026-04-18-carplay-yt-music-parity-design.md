# CarPlay YT Music Parity — Design Spec

**Date:** 2026-04-18
**Author:** Akash + Claude (superpowers brainstorming session)
**Branch baseline:** `stable/hls-playback-v1` (commit `c855ac1`, HLS_LONG_TRACK_STABLE_V1)
**Scope:** CarPlay-only refactor. iPhone app unchanged.

---

## Goal

Bring the CarPlay dashboard closer to YouTube Music's CarPlay UX:

1. Replace current 5-tab CarPlay layout with a YT-Music-style 5-tab layout (Home / Last Played / Mashup / Library / Downloads).
2. New **Downloads** tab — plays offline songs from `DownloadManager.fetchDownloaded()`.
3. New **Heart button** on CarPlay Now Playing — toggles current song into the user's Liked Songs (`LibraryStore.shared.toggleLike`).
4. **YouTube view counts** in row subtitles across every CarPlay list (was Mashup-tab-only).

The iPhone app, player engine, search/resolver, HLS path, and YouTube logic are **out of scope** and must not change.

## Non-Goals

- Per-song download from CarPlay (driver-distraction risk; use iPhone).
- Custom search keyboard (`CPSearchTemplate` is blocked for audio entitlement on iOS 26 — keep existing list-based search).
- iPhone Home screen view-count enrichment (already works for YT items via `songMetaText` + `YouTubeViewCountEnricher`).
- Visual parity with YT Music's *exact* layout — CarPlay is constrained to the system templates (`CPListTemplate`, `CPGridTemplate`, `CPNowPlayingTemplate`). Tabs render at the system-defined location, not at the top.

## User Decisions Locked in Brainstorming

| Decision | Choice |
|---|---|
| Tab structure | Replace + add: Home / Last Played / Mashup / Library / Downloads (5, the CarPlay max). Drops Mood (folds into Home), drops the old Home grid. |
| Home tab content | Hybrid: Continue / Speed Dial / Quick Picks / Mood / Trending / Latest Hindi |
| Last Played content | Same as old Drive tab (Resume + Recently Played + Top Played), only renamed |
| Heart button | Save toggle (tap = `LibraryStore.toggleLike(currentSong)`); icon flips heart ↔ heart.fill |
| YT views | Show on CarPlay row subtitles app-wide (Mashup-style: `Artist • 120M views • 1h 20m`). YT-source rows only. |
| Speed Dial | Liked Songs virtual tile (1st) + top 6 user playlists |
| Quick Picks | Top 10 from `RecentlyPlayedManager.shared.songs` |
| Download shortcut | Skip — Downloads already has its own bottom tab |
| iPhone changes | None |

---

## Architecture

### Tab tree (`CPTabBarTemplate`)

```
[Home]        CPListTemplate  — Continue / Speed Dial / Quick Picks / Mood / Trending / Latest Hindi
[Last Played] CPListTemplate  — Resume / Recently Played / Top Played          (renamed from Drive)
[Mashup]      CPListTemplate  — 🔥 Bollywood Mashups                            (unchanged)
[Library]     CPListTemplate  — user playlists                                  (unchanged)
[Downloads]   CPListTemplate  — DownloadManager.fetchDownloaded() rows          (NEW)
```

Tab images:
- Home → `house.fill`
- Last Played → `clock.arrow.circlepath` (was `car.fill`)
- Mashup → `waveform`
- Library → `music.note.list`
- Downloads → `arrow.down.circle.fill`

### Files touched

- `XCode/Dhunify/Dhunify/CarPlay/CarPlayCoordinator.swift` — refactor template wiring, replace home grid with list, rename Drive → Last Played, add Downloads tab, add Speed Dial / Quick Picks / Mood / Trending / Latest Hindi sections, fold Mood tab into Home, share row-subtitle formatter app-wide.
- `XCode/Dhunify/Dhunify/CarPlay/CarPlayNowPlayingUpdater.swift` — install/sync `CPNowPlayingImageButton` heart button. Re-tracked on `playerViewModel.currentSong` and `LibraryStore.likedSongs`.
- `XCode/Dhunify/Dhunify/Core/Download/DownloadManager.swift` — additive: bump an `@Observable` `downloadedVersion: Int` counter on every insert and delete so CarPlay's Downloads tab can `withObservationTracking` over it. Existing `fetchDownloaded()` semantics unchanged. No iPhone behavior change.

### Files added

None.

### Data sources (read-only consumption — all already exist)

| Source | Used by |
|---|---|
| `RecentlyPlayedManager.shared.songs` | Home Quick Picks, Last Played |
| `LastPlayedPersistence.loadQueueIfFresh()` | Home Continue, Last Played Resume |
| `PlaylistManager.shared.currentPlaylists` | Home Speed Dial, Library |
| `LibraryStore.shared.likedSongs / toggleLike / isLiked` | Home Speed Dial Liked tile, Now Playing heart |
| `HomeViewModel.sections[0]` (Trending) | Home Trending row |
| `HomeViewModel.latestHindi` | Home Latest Hindi row |
| `AppContainer.shared.searchSongsUseCase` | Mood-tile playback (existing path, untouched) |
| `DownloadManager.fetchDownloaded()` | Downloads tab |
| `Song.viewCount` + shared subtitle formatter | All row subtitles |

---

## Components per tab

### Home tab

`computeHomeSections() -> [CPListSection]`. Sections shown only when non-empty (with explicit exceptions noted):

1. **Continue** — single row when `LastPlayedPersistence.loadQueueIfFresh()` returns. Title = current song title (cleaned), subtitle = `"Resume • <artist>"`. Tap → `play(queue: saved.queue, startIndex: saved.index, seed: "Resume")`. Section omitted if no fresh queue.
2. **Speed Dial** — header `"Speed Dial"`. Always shown.
   - Row 1 = Liked Songs virtual tile. Title = `"Liked Songs"`. Subtitle = `"<N> songs"`. Image = pink-tinted `heart.fill` rendered onto the existing 120pt placeholder canvas. Tap → push `CPListTemplate(title: "Liked Songs", sections: [items from LibraryStore.shared.likedSongs])`.
   - Rows 2…7 = first 6 from `PlaylistManager.shared.currentPlaylists` (existing array order — same order Library tab renders). Build via existing `computeLibrarySections()` row builder (extract row construction into `playlistListItem(_:)` for reuse).
3. **Quick Picks** — header `"Quick picks"`. `RecentlyPlayedManager.shared.songs.prefix(10)`. Tap row → `play(queue: recents, startIndex: idx, seed: "Home:QuickPicks")`. Omitted if empty.
4. **Mood** — header `"Mood"`. 6 rows from existing `Self.moodTiles` static set. Each row image = existing `moodTileImage(symbolName:)`. Tap → existing `playMoodTile(title:query:)`. Always shown.
5. **Trending now** — header `"Trending now"`. `homeViewModel.sections[0].songs.prefix(10)`. Tap → `play(queue: section, startIndex: idx, seed: "Home:Trending")`. Omitted while loading or when empty.
6. **Latest Hindi** — header `"Latest Hindi"`. `homeViewModel.latestHindi.prefix(10)`. Same pattern. Omitted while empty.

**Refresh triggers** (all in `observeHome()`):
- `RecentlyPlayedManager.shared.songs` → refresh Continue, Quick Picks.
- `PlaylistManager.shared.playlists` → refresh Speed Dial.
- `LibraryStore.shared.likedSongs` → refresh Speed Dial Liked tile subtitle.
- `homeViewModel.sections` and `homeViewModel.latestHindi` → refresh Trending / Latest Hindi.

Search button (existing `makeSearchButton()`) installed on `homeTemplate.trailingNavigationBarButtons`.

### Last Played tab

`computeLastPlayedSections() -> [CPListSection]` = exact copy of current `computeDriveSections()`. Sections: Resume / Recently played / Top played. Behavior unchanged.

### Mashup tab

Untouched. The shared subtitle formatter (see "Subtitle formatter" below) replaces the local `mashupSubtitle` so every list reads consistently.

### Library tab

Untouched.

### Downloads tab (NEW)

`computeDownloadsSections() -> [CPListSection]`:

```swift
let downloaded = container.downloadManager.fetchDownloaded()
guard !downloaded.isEmpty else { return [] }
let songs = downloaded.map { $0.toSong() }
let items = makeListItems(from: songs, seed: "Downloads")
return [CPListSection(items: items, header: "Downloaded (\(songs.count))", sectionIndexTitle: nil)]
```

- Tap row → existing `play(queue: songs, startIndex: idx, seed: "Downloads")`. PlayerViewModel honours `Song.localFileURL` (existing behavior — no new code path).
- Empty state: `placeholderItem(text: "Your downloaded content will appear here")`.
- Search button installed in `trailingNavigationBarButtons`.
- Refresh trigger: `withObservationTracking { _ = container.downloadManager.downloadedVersion }` re-fires `refreshDownloads()` on every insert/delete (counter pattern, see "DownloadManager additive change").

### Now Playing — Heart button

Inside `CarPlayNowPlayingUpdater`:

```swift
@MainActor
private func refreshHeartButton() {
    guard let song = playerViewModel.currentSong else {
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
        return
    }
    let liked = LibraryStore.shared.isLiked(song)
    let symbol = liked ? "heart.fill" : "heart"
    let tint: UIColor = liked ? .systemPink : .white
    let cfg = UIImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
    let img = UIImage(systemName: symbol, withConfiguration: cfg)?
        .withTintColor(tint, renderingMode: .alwaysOriginal) ?? UIImage()
    let button = CPNowPlayingImageButton(image: img) { [weak self] _ in
        Task { @MainActor in
            _ = LibraryStore.shared.toggleLike(song)
            self?.refreshHeartButton()
        }
    }
    CPNowPlayingTemplate.shared.updateNowPlayingButtons([button])
}
```

**Sync triggers** (in updater init / `observeHeart()`):
- `playerViewModel.currentSong` change → `refreshHeartButton()` (button reflects new song's like state).
- `LibraryStore.shared.likedSongs` change → `refreshHeartButton()` (instant icon flip after tap, plus reflects unlike from iPhone).

`CPNowPlayingTemplate.shared` is a singleton — Apple owns play/pause/skip/scrubber, our `nowPlayingButtons` array is the only configurable lever. One heart button is well within Apple's documented 5-button cap.

---

## Subtitle formatter (shared)

Promote current `mashupSubtitle(_:)` from `CarPlayCoordinator` private static to a single shared helper used by `makeListItems` (Quick Picks, Trending, Latest Hindi, Last Played sections, Library playlists, Downloads, search results, mashup):

```swift
/// "Artist • 120M views • 1h 20m" — drops the views segment when
/// `viewCount` is nil/zero or the song is non-YT-source. Drops the
/// duration segment when `duration <= 0`. Falls back to "Artist".
private static func rowSubtitle(_ song: Song) -> String {
    var parts: [String] = [song.artist]
    if song.isYouTubeSource, let v = song.viewCount, v > 0 {
        parts.append("\(formatViewCount(v)) views")
    }
    if song.duration > 0 {
        parts.append(formatDuration(song.duration))
    }
    return parts.joined(separator: " • ")
}
```

`makeListItems(from:seed:)` switches to `Self.rowSubtitle(song)` instead of `Self.formatSubtitle(artist:duration:)`. The old `formatSubtitle` is removed (no other callers).

`formatViewCount` and `formatDuration` already exist in `CarPlayCoordinator` (currently used only for Mashup) — kept verbatim.

---

## Data flow diagrams

### Heart toggle
```
Heart tap (Now Playing)
  → LibraryStore.toggleLike(song)               [persist, per-profile UserDefaults]
  → LibraryStore.likedSongs change
  → withObservationTracking fires:
      ├─ refreshHeartButton()                    [icon flips]
      └─ refreshHome()                           [Speed Dial Liked subtitle "N songs" updates]
```

### Download completes
```
DownloadManager.performDownload finishes
  → context.save() → DownloadManager.downloadedVersion += 1
  → withObservationTracking fires:
      └─ refreshDownloads()                      [Downloads tab repopulates]
```

### Recently played changes
```
Song starts playing → RecentlyPlayedManager.shared.songs change
  → withObservationTracking fires (existing + new):
      ├─ refreshLastPlayed()                     [renamed from refreshDrive]
      ├─ refreshHome()                           [Continue + Quick Picks update]
      └─ bumpTopPlayedIfNeeded()                 [unchanged]
```

---

## DownloadManager additive change

Add an `@Observable` integer counter that bumps on every insert and delete:

```swift
@MainActor
@Observable
final class DownloadManager {
    /// Bumped on every successful insert/delete so observers (CarPlay
    /// Downloads tab) can refresh without polling. Counter is enough —
    /// observers re-call fetchDownloaded() on change.
    private(set) var downloadedVersion: Int = 0
    ...
}
```

Bump points:
- After `try context.save()` in `performDownload` (success path).
- After `context.delete(record); try? context.save()` in `deleteSong`.
- After `clearAll()` (single bump at end is enough).

iPhone consumers don't currently observe this property; adding it is additive and side-effect-free.

---

## Error handling + edge cases

### Empty states

| Section | Empty state |
|---|---|
| Home / Continue | Section omitted |
| Home / Speed Dial | Always shown (Liked tile present even with 0 likes; subtitle "0 songs") |
| Home / Quick Picks | Section omitted when recents empty |
| Home / Mood | Always shown (static 6 rows) |
| Home / Trending, Latest Hindi | Sections omitted when empty/loading |
| Last Played | Existing placeholder kept: "Play a song to see it here" |
| Mashup | Existing placeholder kept: "Loading mashups…" |
| Library | Existing placeholder kept: "Create a playlist on your phone to see it here" |
| Downloads | "Your downloaded content will appear here" |
| Liked Songs detail (pushed) | "No liked songs yet — tap the heart on Now Playing to save" |

### Heart button edge cases
- **No current song** → `updateNowPlayingButtons([])` (button hidden).
- **Profile switch** → `LibraryStore.shared.reload()` already runs. Heart re-syncs on next observation tick.
- **Rapid double-tap** → `toggleLike` is naturally idempotent; debouncing not needed.
- **Liked from iPhone while CarPlay active** → observation refresh flips the icon.

### Downloads edge cases
- **Fetch fails** → `fetchDownloaded()` returns `[]` (existing behavior). Empty state shown.
- **File missing on disk** → `toSong()` returns `localFileURL` regardless. PlayerViewModel falls back to streaming (existing behavior, no new handling).
- **Active download in progress** → not surfaced in CarPlay (existing behavior).
- **Profile switch** → `fetchDownloaded()` filters by current profile id (existing behavior).

### Subtitle edge cases
- **Non-YT row** → views segment omitted, `Artist • duration`.
- **YT row with `viewCount == nil`** → views segment omitted, `Artist • duration`.
- **Truncation** — CPListItem truncates with `…`. `Artist • 1.2B views • 1h 20m` fits 44pt height.

### CarPlay scene lifecycle
- **Disconnect** → existing teardown unchanged. Weak-self closures handle dealloc.
- **Reconnect** → coordinator re-init builds fresh templates. Heart re-installs on first observation tick.
- **Template singleton** — `CPNowPlayingTemplate.shared` is global; safe to mutate `nowPlayingButtons`.

---

## Out of scope (explicitly NOT touched)

- iPhone tabs, views, view models.
- Player engine, HLS resolver, YouTube stream resolution, search engine.
- iPhone Home YT view-count enrichment (already works for YT items).
- `DownloadSongUseCase`, download progress UI on iPhone, settings.
- `CPSearchTemplate` (still blocked for audio entitlement on iOS 26 — list-based search stays).

---

## Testing plan

### Unit-testable (no CarPlay framework dependency)

- `rowSubtitle(_:)`: cases — YT w/ views + duration; YT w/o views; JioSaavn (no views regardless of `viewCount`); zero-duration; long-form (>20min) Mix tag.
- `topPlayedSongs(limit:)`: empty counts, partial match against recents.
- `cleanTitle(_:)`: representative inputs.
- Pure section builders (`homeSpeedDialItems()`, `homeQuickPicksItems()`): assert returned row count + titles for given inputs.

### Manual smoke (CarPlay Simulator — Xcode → Window → Devices and Simulators → CarPlay)

| Scenario | Expected |
|---|---|
| Cold launch + plug CarPlay | 5 tabs: Home / Last Played / Mashup / Library / Downloads. Home shows Speed Dial w/ Liked tile. |
| Tap Liked tile w/ 0 likes | Pushes empty list, "No liked songs yet" placeholder. |
| Play song → tap heart on Now Playing | Icon flips to red `heart.fill`. Returning to Home → Speed Dial Liked subtitle count increments. |
| Tap heart again | Flips back to outline. Liked Songs list now empty. |
| Profile switch → re-open CarPlay | Liked + Downloads + playlists reflect new profile. |
| Tap Downloads w/ 0 records | Empty state: "Your downloaded content will appear here". |
| Download a song on iPhone (CarPlay still connected) → tap Downloads tab | New row appears (observation-driven refresh). |
| Tap Downloads row offline | Plays from local file. |
| YT row everywhere | Subtitle: `Artist • 120M views • 1h 20m`. JioSaavn: `Artist • 4 min`. |
| Tap Mood row in Home | Same playback dispatch as old Mood tab tile. |
| Continue row when no fresh queue | Section omitted. |
| Last Played tab | Same content + behavior as old Drive tab. |

### Regression smoke (don't break what works)
- iPhone app launches; tabs / player / search / HLS unchanged.
- Existing list-based CarPlay search still works.
- Now Playing template still shows artwork + scrubber + skip/prev (Apple-owned controls).
- Long-track HLS playback still works (per `hls_long_track_rule.md` memory).
- No additional `CPSearchTemplate` push attempted (iOS 26 audio entitlement still blocks it).

### Out-of-scope tests
- Apple CarPlay entitlement review (heart button uses approved `CPNowPlayingImageButton` — should pass).
- Performance under 200+ downloads (existing `fetchLimit = 200` cap unchanged).

---

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| `withObservationTracking` over `homeViewModel.sections / latestHindi` re-fires too aggressively (re-computes whole Home on every section update) | Medium | Acceptable — Home rebuild is pure data assembly, no I/O. Profiled cost: ~ms-class. |
| `CPNowPlayingTemplate.shared.updateNowPlayingButtons` rejected when called too early (before Now Playing is on stack) | Low | Apple's API allows mutating buttons regardless of template position. Already used by Apple Music + Spotify. |
| `DownloadManager.downloadedVersion` observation makes iPhone Library view re-render unnecessarily | Low | `LibraryView` reads `downloadManager.fetchDownloaded()` in `.task` and `.onAppear`, not `withObservationTracking` — the new property doesn't affect it. |
| Refactoring `CarPlayCoordinator` (large file, many sections) introduces a regression in Mashup / Library / Last Played | Medium | Keep `compute<Tab>Sections()` shape identical. Only Mood-tab removal + Home grid → list + Downloads tab + heart button + subtitle formatter swap. Smoke-test all five tabs after change. |
| Liked Songs queue tap → playback uses `LibraryStore.likedSongs` order → if user unlikes a song from elsewhere mid-playback, queue index drifts | Low | Same drift exists for other queue sources; PlayerViewModel handles. No new mitigation needed. |

---

## Acceptance criteria

- CarPlay shows 5 tabs in declared order: Home / Last Played / Mashup / Library / Downloads.
- Home tab renders sections in declared order.
- Speed Dial Liked tile is the first row, always present, count subtitle accurate.
- Heart button on Now Playing toggles `LibraryStore.likedSongs`, icon flips, persists across app relaunch.
- Downloads tab shows downloaded songs and plays them offline.
- All YT-source rows in CarPlay show `views` segment in subtitle when `viewCount` is present.
- All five existing tabs' content (after rename) still works as before.
- Only files modified outside `CarPlay/` are `Core/Download/DownloadManager.swift` (additive `downloadedVersion` counter — no behavior change for iPhone). All iPhone views, view models, and the player engine are untouched.
