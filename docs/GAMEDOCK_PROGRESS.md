# GameDock — AI Handoff / Progress Document

Canonical project state for the GameDock Omarchy Quattro plugin. Read this
before making changes. This file is the single source of truth for what the
project is, what has shipped, what is intentionally left alone, and what the
next step should be.

---

## Project purpose

GameDock is an Omarchy Quattro bar-widget that provides a native gaming
dashboard. From one compact panel you can favorite games, see recently played
titles, browse everything installed per launcher, launch launchers, and launch
games directly — no launcher UI in the way.

The core interaction:

```
Omarchy bar → GameDock icon → GameDock panel → click game → game launches
```

## Plugin location

```
~/.config/omarchy/plugins/io.github.prathamesh913.gamedock/
```

## Repository

- GameDock now has its own Git repository (this standalone plugin is version
  controlled independently of Omarchy).
- Repository root:
  ```
  ~/.config/omarchy/plugins/io.github.prathamesh913.gamedock/
  ```
- Runtime state stays outside the repository:
  `~/.local/state/omarchy/gamedock/cache.json` and
  `~/.local/state/omarchy/settings/gamedock.json` are never committed.
- Git should be used for checkpoints before major development steps (e.g.
  before each accepted step), so work can be reviewed and reverted cleanly.

## Architecture

Stack (fixed, do not change):

- **Quickshell/QML** — UI
- **JavaScript** — UI-facing logic (`Model.js`)
- **Python 3 stdlib** — scanning (`scan.py`)
- **JSON** — cache/state

Constraints (hard rules):

- No Electron
- No Tauri
- No GTK application
- No Rust helper
- No additional dependency installation
- Do not modify `~/.local/share/omarchy/default/`
- Plugin must remain self-contained

## Files and their responsibilities

| File | Responsibility |
|---|---|
| `manifest.json` | Plugin schema: id `io.github.prathamesh913.gamedock`, kind `bar-widget`, entry `BarWidget.qml`, `refreshIntervalSec` setting (default 300). |
| `BarWidget.qml` | Bar pill (gamepad glyph). Loads `Panel.qml` via a `Loader` and forwards the panel lifecycle (`open`/`close`/`toggle`/`openFromHotkey`/`popoutSwitchClosing`/`closeForPopoutSwitch`) so GameDock participates in bar popout coordination. Middle/right click refreshes the scan. |
| `Panel.qml` | The `KeyboardPanel`. Owns cached-data presentation, launch/favorite actions, focus/keyboard navigation, panel lifecycle, search, launcher filtering, lightweight sorting, and artwork display. Contains `GameRow`, `LauncherRow`, and `LauncherGames` components. Search/filter/sort are presentation-only over the loaded model. |
| `Model.js` | Scan-data views (`allGames`, `recentGames`, `favoriteGames`, `gamesByLauncher`, `relativeTime`), favorites state, and detached launch command builders (`launchGame`, `launchLauncher`). |
| `scan.py` | Python 3 stdlib backend. `scan` parses launcher metadata and atomically writes `cache.json`; `favorites-set` persists favorites. Per-launcher error isolation. Emits optional per-game `artwork` metadata (local paths + Heroic `art_square` URL + deterministic `cachePath`). |
| `icons/` | Plugin icon assets. |
| `preview.png` | Preview image. |
| `LICENSE` | MIT. |
| `README.md` | End-user readme (install/usage/state files). |
| `docs/GAMEDOCK_PROGRESS.md` | This handoff document. |

## Completed Step 1 — bar-widget manifest + panel integration

- Quattro bar-widget manifest works.
- GameDock appears in the Omarchy bar.
- BarWidget → Panel integration works.
- Panel opens/closes.
- Popout coordination follows Omarchy patterns (single-popout model via
  `KeyboardPanel`, `bar.requestPopout`, `closeForPopoutSwitch`).
- `qmllint` passed.
- `omarchy plugin validate` passed.
- Clean shell restart passed.

## Completed Step 2 — real game data and launching

Real scanner data wired through `scan.py` → `cache.json` → `Panel.qml`:

- Steam: detected; currently no games because Steam has no logged-in library.
- Heroic: 1 game — Hogwarts Legacy.
- RetroArch: 1 playlist game — Silent Hill 2.
- RPCS3: 1 game — Grand Theft Auto V.

Functionality shipped in Step 2:

- Steam VDF parsing, Heroic Epic/GOG/Amazon metadata parsing, RetroArch
  `.lpl`/`.lrtl` parsing, RPCS3 `games.yml` parsing.
- Launcher detection and per-launcher error isolation.
- Canonical JSON output and atomic cache writes.
- Real launcher/game launching (Steam URI, Heroic URI with encoded params,
  RetroArch `-L core rom`, RPCS3 `--no-gui path`).
- Favorites stored by stable game IDs, persistent across shell restart/cache
  refresh.
- Panel sections: Favorites, Recently Played, Launchers, Installed Games.

## Completed Step 3 — visual and interaction refinement

All changes were made in `Panel.qml` only. No application behavior,
scanner, or cache architecture was changed.

### Width overflow fixes

- **GameRow**: title Column width was `parent.width - Style.space(58)`, which
  over-summed with icon+gaps+star (22+8+8+24 = 62) and overflowed by 4px.
  Fixed to `parent.width - Style.space(62)`.
- **LauncherRow**: name Text width did not reserve room for the status Text
  (✓ / "Unavailable"), so the status clipped past the row edge. Fixed by
  reserving `launcherStatusText.width`.

### FileView stale-text fix

`cacheFile` and `favoritesFile` `onFileChanged` handlers read `text()`
directly, which is stale inside the change signal (a documented Quickshell
gotcha; every first-party FileView consumer uses `reload()`). Changed both to
`onFileChanged: reload()` so the `onLoaded` handler parses fresh content.
Favorites and cache now live-reload on external file writes.

### Keyboard behavior alignment

- `onTabRequested` now calls `root.switchPanel(direction)` directly, matching
  all first-party Omarchy panels (audio, bluetooth, clock, network, power,
  etc.). Previously it walked focusables first and only switched at the
  boundary, so Tab effectively never cycled panels.
- Removed `activeFocusOnTab: true` from `GameRow`/`LauncherRow` and removed
  `forceActiveFocus()` from `focusAt()`. These moved Qt focus onto rows, and
  Qt's native tab-traversal then consumed Tab before the `PanelKeyCatcher`
  saw it (why Tab appeared broken). Keyboard focus now stays on the key
  catcher; visuals come from the shared cursor state.

### Shared-cursor hover model

`hasCursor` was `containsMouse || activeFocus`, which could highlight two rows
at once (mouse hover on one, keyboard focus on another) and violated the
`CursorSurface` contract. Now:

- `hasCursor: root.focusables[root.focusIndex] === <row>` for GameRow,
  LauncherRow, and the favorite star button.
- Row/star `MouseArea` hover routes through a new `setHoverCursor(item)`,
  which moves `focusIndex` without stealing Qt focus.
- Result: one highlight on screen at any time, shared by mouse and keyboard,
  matching the first-party bluetooth panel model.

## Completed Step 4A — panel space and content density

All changes were made in `Panel.qml` only. No scanner, cache, Model.js,
launch commands, or behavior were changed.

### Height cap

- **Previous cap:** `contentHeight` used `fittedContentHeight(..., Style.space(560))`.
  With favorites + 3 recent + 3 installed + 4 launchers, content (~728 logical
  px) exceeded the 560 cap, so LAUNCHERS scrolled below the fold.
- **New cap:** `Style.space(700)` — the panel now reaches ~700 logical px and
  the full four-section layout fits on the current 1080p display without
  scrolling.

### Responsive sizing

`fittedContentHeight` still sizes naturally:

- small content → compact panel (measured: 639 logical px with no favorites)
- more content → panel grows (660 logical px with one favorite)
- large content → reaches the 700 cap
- very large content → existing `Flickable`/scroll takes over (unchanged)

### Spacing/density adjustments

To fit the current 3-game dataset within the taller panel without excessive
padding, small Omarchy-consistent tweaks:

- `contentColumn` inter-section spacing: `Style.space(10)` → `Style.space(6)`
- Four section columns (`FAVORITES`/`RECENTLY PLAYED`/`INSTALLED GAMES`/
  `LAUNCHERS`) internal spacing: `Style.space(4)` → `Style.space(3)`
- `GameRow` minimum height: `Style.space(36)` → `Style.space(30)`
- `LauncherRow` minimum height: `Style.space(34)` → `Style.space(28)`

Result: content ~660 logical px with real data (1 favorite), fitting the
~668 logical px viewport at the 700 cap. Section separators and row
proportions remain visually consistent with Omarchy.

### Large-data scrolling test

Temporarily wrote a synthetic cache with 75 games (25 each for Heroic,
RetroArch, RPCS3) and verified:

- panel reached the maximum height (700 cap)
- `Flickable` still scrolled correctly
- content was not clipped (scroll revealed rows at the bottom edge)
- keyboard navigation continued to work (arrow keys scroll + move cursor)
- Escape still closed the panel

The real cache and favorites were restored afterward; the scanner re-verified
the real data (`errors: []`).

### Keyboard regression

- Escape → closes panel ✓
- Tab → next panel (opencode-go) ✓
- Shift+Tab → previous panel (GameDock) ✓
- Arrow keys → move shared cursor ✓
- Enter → launch (Heroic launch verified with correct URI args) ✓
- Enter/Space on favorite star → toggles ✓

### Popout regression

- GameDock → Bluetooth: clean switch, single panel visible ✓
- Bluetooth → GameDock: clean switch ✓
- GameDock → Escape: closes ✓

### Validation

- `qmllint -I $OMARCHY_PATH/shell Panel.qml` → passed (exit 0)
- `qmllint ... BarWidget.qml` → passed (exit 0)
- `omarchy plugin validate` → passed (exit 0)
- Clean shell restart → no GameDock errors in journal/runtime log
- Favorites persist across restart ✓

## Completed Step 4B — game artwork

Compact 30×30 artwork tiles in `GameRow`, replacing the launcher glyph. The
panel stays a native list-based design — no grid/card layout.

### Artwork sources

| Launcher | Source | Shape |
|---|---|---|
| Heroic | `~/.config/heroic/icons/<app_name>.jpg` (local) and `art_square` from `store_cache/*_library.json` (remote URL) | `localPath` + `url`/`cachePath` |
| RPCS3 | `dev_hdd0/game/<serial>/ICON0.PNG` or `<serial>_install/ICON0.PNG` | `localPath` |
| Steam | `userdata/<id>/config/grid/<appid>p.jpg` (grid artwork; none today until logged in with grid files) | `localPath` |
| RetroArch | none reliable | no artwork object → glyph fallback |

`artwork_object()` in `scan.py` emits `{"localPath", "url", "cachePath"}` only
when a real source exists. `cachePath` is a deterministic `md5(url)` path under
`~/.local/state/omarchy/gamedock/art/`. Remote URLs are never invented — only
existing metadata (`art_square`).

Real-data results:

- Hogwarts Legacy → Heroic icon (local)
- Grand Theft Auto V → RPCS3 `ICON0.PNG` (local)
- Silent Hill 2 → launcher glyph fallback (no reliable RetroArch art)

### Local artwork behavior

- Shown immediately from disk (`asynchronous: true`, `cache: false` file URLs).
- Local artwork always wins over remote; a remote URL is never fetched while a
  `localPath` exists.

### Remote artwork behavior

- Heroic remote-only artwork is fetched **on panel open** through a detached
  `curl -fsS --create-dirs --max-time 8 -o <cachePath> <url>` process.
- One queued download at a time; per-URL state (`queued`/`inflight`/`failed`/
  `ready`) prevents repeat downloads and failed retries.
- Never blocks QML, scanning, or launching (Quickshell `Process`, non-blocking).
- On completion, `artRevision` bumps and remote GameRows re-read their cache
  file so the image appears without reopening the panel.
- Failed downloads silently fall back to the launcher glyph and are not
  retried in the session.

### UI changes

- `GameRow`'s launcher glyph is replaced by a 30×30 rounded tile
  (`radius: Style.spacing.labelGap`, `Style.normalFillFor` backdrop).
- The `Image` is visible only once decoded (`status === Image.Ready`), so an
  invalid/missing/unavailable source can never render Qt's broken-image
  placeholder; the launcher glyph is the fallback for any non-ready state.
- Title Column width reserves the new tile: `Style.space(62)` →
  `Style.space(70)` (30 tile + 8 + 8 + 24 star). Row height math is unchanged;
  `GameRow` stays compact (~33–36 logical px).

### Performance

- No synchronous downloads; every fetch is async and best-effort.
- Local artwork renders immediately from disk.
- Remote artwork downloads once per URL (cached under the art dir); later
  opens read the cache file.
- No background daemons, no new dependencies, no network traffic on every
  open.

### Validation

- `qmllint -I $OMARCHY_PATH/shell Panel.qml BarWidget.qml` → passed (exit 0)
- `omarchy plugin validate` → passed (exit 0)
- Clean shell restart → no GameDock errors in journal (only pre-existing
  first-party messages)
- Scanner output verified against the real 3-game library (artwork per the
  table above, `errors: []`)
- Remote fetch verified: `curl -fsS --create-dirs --max-time 8` wrote a valid
  1200×1600 JPEG into the art cache dir
- Runtime state confirmed outside the repository (`git status` clean of
  cache/art/pycache)

## Completed Step 4C — game search

Keyboard-first search over the already-loaded model. Pure presentation layer:
no scanner, cache, favorites, launch, keyboard-architecture, or artwork changes.
No launcher filter in 4C (see "Recommended next step").

### UI

- A compact search `TextField` (qs.Ui, the first-party search component)
  sits under the header, above FAVORITES, always visible.
- Empty query → the normal Favorites / Recently Played / Installed Games /
  Launchers layout, unchanged.
- Non-empty query → one flat **SEARCH RESULTS** section (reuses `GameRow` with
  artwork + favorite stars); Favorites/Recent/Installed/Launchers are hidden.
- No results → a single empty state: "No games found / Try another search."
- Query resets to empty each time the panel opens (matches the first-party
  menu panel clearing its filter on close).

### Matching

- Case-insensitive substring match against game title and launcher id/name
  (so "hog" → Hogwarts Legacy, "hero"/"heroic" → Heroic games).
- Runs in memory on the loaded model only; no scans, filesystem access, or
  network on keystroke. O(n) per query over installed games; instantaneous
  even for hundreds/thousands of games.

### Keyboard interaction (integrated, not replacing, the shared cursor)

- Search is **not** auto-focused on open; `/` or clicking the field activates
  it (the field takes Qt focus and `PanelKeyCatcher.blocked` forwards keys to
  it — the documented inline-editor pattern).
- Field focused: native typing; **Tab/Shift+Tab → switchPanel** (intercepted,
  so panel switching still works); **Down/Enter → cursor to first result**;
  **Escape → clear query (non-empty) / close (empty)**.
- Field not focused with a non-empty query: printable keys refine the query
  (`PanelKeyCatcher.textKey`), arrows move the shared cursor through results,
  Enter/Space launch/toggle, and Escape clears the query before closing.
- Rows keep `activeFocusOnTab` off; Qt focus stays on the key catcher. No
  native focus-traversal regressions.

### Performance

- Filtering recomputes only when the query or cache document changes.
- SEARCH RESULTS reuses the existing GameRow artwork (local / cached remote /
  glyph fallback) and the 700px cap + Flickable scrolling.

### Validation

- `qmllint -I $OMARCHY_PATH/shell Panel.qml BarWidget.qml` → passed (exit 0)
- `omarchy plugin validate` → passed (exit 0)
- Clean shell restart → no GameDock errors or warnings (only the pre-existing
  first-party portal message)
- Real-data search verified: "hog" → Hogwarts Legacy; "silent" → Silent Hill 2;
  "grand" → Grand Theft Auto V; "heroic"/"hero" → Hogwarts Legacy; unknown
  string → no matches; empty → normal view
- Synthetic 78-game library test (25 Heroic + 26 RetroArch + 27 RPCS3 + real
  games): filtering correct across the set, panel stayed clean (no "Cannot
  open" artwork warnings after the ready-gated remote source), real cache and
  favorites restored byte-identical afterward
- Regression: launch, favorites, keyboard, popout, artwork fallback all use
  the unchanged Step 1–4B code paths

## Completed Step 4D — launcher filtering and lightweight sorting

Step 4D adds compact launcher filtering and presentation-only sorting without
changing the native list layout, scanner, cache, favorites, recent timestamps,
launch commands, or artwork implementation.

### Launcher filter

- Compact chip row uses first-party `Button` styling with the shared cursor
  model: `All` plus only currently installed/detected launchers.
- Current validation machine exposes `All`, `Steam`, `Heroic`, `RetroArch`,
  and `RPCS3`; Steam remains selectable even when its library is empty.
- Empty query + `All` preserves the normal four-section layout exactly.
- An active launcher filter replaces the normal sections with one flat filtered
  game list, avoiding repeated empty sections. Empty states use
  `No games found for <Launcher>.`.

### Search and filter

- The existing Step 4C search pipeline now combines launcher filtering before
  search matching, then sorting: all games → launcher filter → search filter →
  sort → display.
- Examples verified: `hog` + Heroic → Hogwarts Legacy; `hog` + RetroArch →
  no results; `silent` + RetroArch → Silent Hill 2; `grand` + RPCS3 → Grand
  Theft Auto V.
- Search results reuse the same GameRow, stable IDs, favorite stars, artwork,
  and glyph fallback. No duplicate game objects are created.

### Sorting

- `Natural` is the default and preserves the current cache order.
- `Recent` uses only existing `lastPlayed` timestamps, newest first; missing
  timestamps follow in stable existing order.
- `A–Z` sorts normalized titles case-insensitively.
- `Launcher` groups by the detected launcher order and preserves stable order
  within each launcher group.
- Sorting applies to the flat filtered/search view and does not alter the
  semantics of Favorites or Recently Played in the normal view.

### Keyboard and performance

- Filter and sort chips are ordinary shared-cursor focusables with negative
  focus orders matching their position above the library. Arrows navigate;
  Enter/Space activate; mouse hover/click uses `setHoverCursor`.
- Tab/Shift+Tab still switch Omarchy panels. GameRow/LauncherRow remain free
  of native tab focus, and the existing PanelKeyCatcher remains the keyboard
  owner.
- All changes operate in memory. Filter/sort changes do not scan, touch the
  filesystem, launch processes, perform network requests, or mutate cache/state.

### Validation

- `qmllint -I $OMARCHY_PATH/shell Panel.qml BarWidget.qml` → passed (exit 0)
- `omarchy plugin validate` → passed (exit 0)
- Clean shell restart → no GameDock errors/warnings; only the pre-existing
  first-party portal warning appeared
- Real data: All/Heroic/RetroArch/RPCS3/Steam filters and search+filter cases
  passed; Natural/Recent/A–Z/Launcher ordering passed
- Synthetic 78-game library: filter/search/sort responsiveness, stable IDs,
  no duplicates, and artwork stability passed; real cache restored
  byte-identically
- Runtime cache and favorites remained outside the repository

## Current game/launcher detection behavior

Detected launchers (all installed on the validation machine):

| Launcher | Installed | Notes |
|---|---|---|
| Steam | yes | library empty until logged in |
| Heroic | yes | 1 game: Hogwarts Legacy |
| RetroArch | yes | 1 playlist game: Silent Hill 2 |
| RPCS3 | yes | 1 game: Grand Theft Auto V |

`scan.py` writes canonical JSON with `generatedAt`, `launchers`, `games`,
`recent`, and `errors`. Launcher parsing is isolated so one malformed source
cannot abort the full scan; scanner errors appear in `errors` and are surfaced
as a small caption line in the panel.

## Current launch behavior

`Model.launchGame(game)` dispatches by launcher:

- **steam**: `<steam executable> steam://rungameid/<appid>`
- **heroic**: `<heroic executable> --no-gui heroic://launch?appName=<appName>&runner=<runner>`
- **retroarch**: `<retroarch executable> -L <core> <rom>`
- **rpcs3**: `<rpcs3 executable> --no-gui <path>`

`Model.launchLauncher(launcher)` runs the launcher executable directly.
All launches use `Quickshell.execDetached(argv)` with a runner wired from the
panel, so no process is blocked on the shell. Launch availability is gated by
`gameLaunchAvailable()` (checks launcher-specific launch fields).

## Favorites implementation

- Stored as `{ "favorites": [stable-game-id, ...] }` in
  `~/.local/state/omarchy/settings/gamedock.json`.
- Stable game IDs (e.g. `heroic/legendary/fa4240e57a3c46b39f169041b7811293`),
  so they survive cache refreshes and renames.
- `Model.js` owns `toggleFavorite`/`isFavorite`/`saveFavorites`/`loadFavorites`
  (also accepts a bare array when reading older Step 1 state).
- `Panel.qml` calls `toggleFavorite(game)`, updates `favoriteIds`, and persists
  via `scan.py favorites-set` (a detached `Process`).
- Favorites section is rebuilt reactively (`favoritesRevision` →
  `refreshViews` → `favoriteRows`); star toggles update the UI immediately.
- Live reload of external favorite writes works after the Step 3 FileView fix.

## Cache/state locations

| Path | Owner | Purpose |
|---|---|---|
| `~/.local/state/omarchy/gamedock/cache.json` | `scan.py scan` | canonical game/launcher/recent cache |
| `~/.local/state/omarchy/gamedock/art/` | `Panel.qml` (curl) | downloaded remote artwork cache (md5(url).jpg) |
| `~/.local/state/omarchy/settings/gamedock.json` | `scan.py favorites-set` | `{ "favorites": [...] }` |

`cache.json` is watched by `FileView` (`watchChanges: true`) and re-applied on
load and change. The scan `Process` re-reads the cache after a successful scan.

## Keyboard behavior

- **Escape** — clears a non-empty search query first; when the query is
  already empty (or search isn't active) it closes the panel.
- **Tab** — switches to the next bar panel (`bar.switchPanelFrom`).
- **Shift+Tab** — switches to the previous bar panel.
- **`/`** — activates the search field (also by clicking it). Not auto-focused
  on open.
- **Search field focused** — typing edits the query; Tab/Shift+Tab still
  switch panels; Down/Enter hand the cursor to the first result; Escape clears
  the query then closes.
- **Launcher/sort chips** — arrows move through the shared focusables;
  Enter/Space activate the focused filter or sort; mouse hover/click updates
  the shared cursor and value immediately.
- **Up/Down** (and `k`/`j`) — move the cursor through focusables.
- **Left/Right** (and `h`/`l`) — move the cursor through focusables (rows and
  their star buttons are ordered by `focusOrder`).
- **Enter** — activates the focused item: launches a game/launcher, or
  toggles a favorite star.
- **Space** — same as Enter.
- Focus order: launcher filter chips (-2000+) → sort chips (-1000+) →
  Favorites rows/stars → Recently Played rows/stars → Installed rows/stars →
  Launchers rows; filtered/search results rows/stars (4000+) when active.
  `focusables` is sorted by each item's `focusOrder`.
- Hovering a row/star moves the shared cursor (`setHoverCursor`), so mouse and
  keyboard share one highlight.
- Qt focus stays on the `PanelKeyCatcher` (the panel's `focusTarget`) or the
  search field while it is active; rows are not Qt tab-focusable.

## Popout behavior

- The panel is a `KeyboardPanel` layer-shell popup attached to the GameDock bar
  button.
- Single-popout model: opening GameDock while another popout is open switches
  the popout cleanly, and vice versa (validated both directions with
  bluetooth/network/opencode-go).
- `BarWidget.qml` forwards `popoutSwitchClosing`/`closeForPopoutSwitch` so the
  bar coordinator treats the widget root as the popout identity.
- Outside-click dismissal is handled by `KeyboardPanel`.

## Validation commands/results

| Command | Result |
|---|---|
| `qmllint -I $OMARCHY_PATH/shell Panel.qml` | passed (exit 0) |
| `qmllint ... BarWidget.qml` | passed (exit 0) |
| `qmllint -I $OMARCHY_PATH/shell Panel.qml BarWidget.qml` | passed (exit 0, Step 4B/4C/4D) |
| `omarchy plugin validate ~/.config/omarchy/plugins/io.github.prathamesh913.gamedock` | passed (exit 0) |
| `omarchy restart shell` | clean; no GameDock errors in journal or runtime log |
| Launch regression (Enter on Hogwarts Legacy) | launched via Heroic URI with correct args; process cleaned up |
| Favorite toggle | immediate UI update; persists across shell restart |
| Keyboard: Escape / Tab / Shift+Tab / Enter / arrows | all working |
| Popout switch (GameDock ↔ bluetooth) | working both directions |
| Artwork: Heroic icon / RPCS3 ICON0.PNG / RetroArch glyph fallback | verified in scanner output |
| Artwork remote fetch (curl to art cache) | verified; valid JPEG written under `gamedock/art/` |
| Search: "hog"/"silent"/"grand"/"heroic"/"hOG"/unknown/empty | all match correctly (Step 4C) |
| Launcher filters: All/Heroic/RetroArch/RPCS3/Steam | all correct; Steam empty state correct (Step 4D) |
| Search + launcher filter combinations | all requested real-data cases passed |
| Sorting: Natural/Recent/A–Z/Launcher | stable and presentation-only; real-data cases passed |
| Synthetic 78-game library | filter/search/sort responsive; no duplicates; cache restored byte-identical |

Only pre-existing first-party warnings appear in logs (e.g. network panel
`PanelSectionHeader` binding-loop, bluetooth same) — not GameDock.

## Known limitations

- **Steam is empty until logged in.** Steam shows a library-empty state and a
  "Log in to Steam to see your library." note.
- **Artwork is best-effort.** Heroic remote artwork is fetched on open via
  curl and cached; until a successful download (or if it fails) the row shows
  the launcher glyph. RetroArch has no reliable artwork source, so its rows
  always use the glyph. Steam grid artwork only appears once Steam is logged
  in with grid files present.
- **RPCS3 titles are path-derived** (from `games.yml` / disc paths), so titles
  may be file-name derived rather than canonical.
- **RPCS3 recent timestamps use save/game directory mtimes**, so "recently
  played" ordering for RPCS3 is heuristic.
- **Playtime tracking is not implemented.**
- **Controller navigation is not implemented.**
- **Additional gaming integrations are not implemented** (Lutris, Battle.net,
  Moonlight, other V2 integrations).
- **RetroArch playlist/core metadata limitation:** the current playlist maps
  Silent Hill 2 to the PUAE (Amiga) core, which appears to be incorrect
  playlist metadata. GameDock intentionally preserves the playlist's configured
  core instead of guessing a replacement — the game launches with the
  playlist's core.

## Known intentional behaviors

- **RetroArch core preservation**: GameDock uses the core configured in the
  playlist and does not guess a "better" one.
- **Height cap**: the 700px cap keeps the panel from exceeding the screen on
  small displays; scrolling is the intended mechanism for overflow on very
  large libraries.
- **Focus order includes star buttons** as first-class focusables so the
  favorite star is reachable by keyboard.
- **Mouse hover and keyboard share one cursor** (single highlight), matching
  the first-party `CursorSurface` model.
- **Favorites use stable IDs**, not display titles, so they persist across
  metadata changes.

## Current UI structure

Panel sections, in order:

1. Header — gamepad glyph + "GAME DOCK" + "Gaming dashboard" subtitle.
2. **Search field** — compact `TextField` ("󰍉 Search games..."); `/` or a
   click activates it. Filters the loaded model live.
3. **Launcher filter chips** — `All` plus detected launchers only.
4. **Sort chips** — `Natural`, `Recent`, `A–Z`, `Launcher`.
5. **FAVORITES** — favorited games; star toggles; compact empty state
   ("No favorites yet · Star a game to keep it here.").
6. **RECENTLY PLAYED** — merged across launchers, newest first, relative time
   shown when reliable.
7. **INSTALLED GAMES** — grouped per launcher (Steam, Heroic, RetroArch,
   RPCS3); each group shows the launcher name, its games, and a launcher-
   specific empty note when the launcher has no games.
8. **LAUNCHERS** — Steam, Heroic, RetroArch, RPCS3 with availability state
   (✓ / "Unavailable").
9. **Filtered/search games** — when a query or launcher filter is active, the
   normal sections are replaced by one flat section headed SEARCH RESULTS or
   INSTALLED GAMES, with one context-aware empty state.

Each `GameRow` shows: artwork tile (launcher glyph fallback), title,
launcher/platform + relative time, favorite star, hover/cursor highlight, and
launch affordance (pointer cursor + click/keyboard activation). `LauncherRow`
shows: launcher glyph, name, availability status, hover/cursor highlight, and
launch affordance.

Panel dimensions: `contentWidth = fittedContentWidth(Style.space(340))`,
`contentHeight = fittedContentHeight(implicitHeight, Style.space(700))`.
With real data (1 favorite + 3 recent + 3 installed + 4 launchers) plus the
search/filter/sort controls, the panel remains capped at 700 logical px;
slightly larger content scrolls via the `Flickable`. Larger libraries grow to
the cap and scroll without changing the underlying model.

## Height cap

`contentHeight = fittedContentHeight(implicitHeight, Style.space(700))`, giving
the panel a 700 logical px maximum as a screen-safety clamp. Below that cap the
panel sizes naturally and grows responsively with content (compact at ~639
logical px with no favorites, ~660 logical px with the real 3-game library).
Very large libraries (dozens of games) hit the cap and scroll via the
`Flickable` (verified with a synthetic 75-game cache). The previous 560px cap,
which pushed LAUNCHERS below the fold, was resolved in Step 4A.

## Exact recommended next step

**Step 5 (proposed): further integrations or controller support.** Step 4D
completed the compact browsing controls. Candidate next steps (only if
accepted by the user):

1. Controller navigation — deferred.
2. Additional gaming integrations (Lutris, Battle.net, Moonlight) — requires a
   scanner/parser change.
3. Playtime tracking — deferred.

Do not add features outside the accepted scope. Only change what the specific
accepted step requires.
