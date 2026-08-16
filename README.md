# GameDock

Gaming dashboard for the Omarchy bar. One compact panel for everything you
play: favorite games, recently played titles, your launchers, and everything
installed — launched directly, no launcher UIs in the way.

An Omarchy Quattro shell plugin (Quickshell/QML + a Python 3 stdlib scanner).

## Status

**Step 4E — stability & scale hardening.** GameDock reads installed games and recent-played
metadata from Steam, Heroic, RetroArch playlists, and RPCS3. Favorites persist
outside the plugin directory, and supported games launch directly through
their owning application. The panel follows Omarchy visual and interaction
patterns: shared cursor hover, keyboard navigation (Escape/Tab/Enter/arrows),
popout coordination, per-launcher grouping, compact game artwork tiles, and
keyboard-first search (`/` or click to activate). Local Heroic icons, RPCS3
`ICON0.PNG`, and Steam grid artwork are used when available. Heroic remote
artwork is fetched lazily only for visible/near-visible games, cached under
`~/.local/state/omarchy/gamedock/art/`, and reused across shell restarts.
Remote URLs must use HTTPS; invalid downloads are rejected. If remote artwork
cannot be fetched, GameDock continues working with the launcher-glyph fallback.
`curl` is used for optional remote artwork downloads. If curl is unavailable or
a remote download fails, GameDock itself continues working normally.
Compact launcher chips show All plus detected launchers, and
Natural/Recent/A–Z/Launcher sorting operates only on filtered results in
memory. Artwork cache reuse, bounded lazy downloads, latest-wins favorites,
normalized search, meaningful cache writes, and large-library behavior are
hardened without changing the plugin architecture.

See `docs/GAMEDOCK_PROGRESS.md` for the full canonical handoff document.

## Install

```bash
omarchy plugin add https://github.com/prathamesh913/gamedock.git --enable --yes
```

Move it with `omarchy bar move io.github.prathamesh913.gamedock --section right`.

## Usage

- Left click: open/close the dashboard
- Middle/right click: refresh the scan
- Escape closes the panel; Tab switches to the next bar panel
- `/` or click the search field to search your library (Escape clears the
  query first, then closes)
- Launcher and sort chips are mouse- or keyboard-selectable; changing them
  never rescans or changes runtime state

## How it works

- `BarWidget.qml` — bar pill (gamepad glyph) that loads and forwards the
  panel lifecycle, so GameDock participates in bar popout coordination.
- `Panel.qml` — `KeyboardPanel` with search, compact launcher/sort controls,
  and four normal sections: Favorites, Recently Played, Launchers, Installed
  Games. An active search or launcher filter replaces them with one filtered
  results section.
- `Model.js` — scan-data views, favorites state, and detached launch command
  builders.
- `scan.py` — Python 3 stdlib backend. `scan` parses launcher metadata and
  writes the canonical cache; `favorites-set` persists favorites. Every
  launcher is isolated so a malformed source cannot abort the full scan.

## State files

| Path | Owner | Purpose |
|---|---|---|
| `~/.local/state/omarchy/gamedock/cache.json` | `scan.py scan` | canonical game/launcher cache |
| `~/.local/state/omarchy/gamedock/art/` | `Panel.qml` / optional `curl` | validated cached remote artwork |
| `~/.local/state/omarchy/settings/gamedock.json` | `scan.py favorites-set` | `{ "favorites": [...] }` |

## Dependencies

Required: Quickshell (shell) and Python 3 stdlib (scanner). `curl` is optional
and used only for best-effort remote artwork; GameDock falls back to launcher
glyphs when curl is unavailable.

## Remove

```bash
omarchy plugin remove io.github.prathamesh913.gamedock
```

The state files above are left behind on purpose; delete them by hand to
fully reset.
