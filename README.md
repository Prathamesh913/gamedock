# GameDock

Gaming dashboard for the Omarchy bar. One compact panel for everything you
play: favorite games, recently played titles, your launchers, and everything
installed — launched directly, no launcher UIs in the way.

An Omarchy Quattro shell plugin (Quickshell/QML + a Python 3 stdlib scanner).

## Status

**Step 4B — game artwork.** GameDock reads installed games and recent-played
metadata from Steam, Heroic, RetroArch playlists, and RPCS3. Favorites persist
outside the plugin directory, and supported games launch directly through
their owning application. The panel follows Omarchy visual and interaction
patterns: shared cursor hover, keyboard navigation (Escape/Tab/Enter/arrows),
popout coordination, per-launcher grouping, and compact game artwork tiles
(local Heroic icons, RPCS3 `ICON0.PNG`, Steam grid, plus best-effort remote
Heroic `art_square` fetched on open via curl and cached under
`~/.local/state/omarchy/gamedock/art/`, with a launcher-glyph fallback for
anything unavailable).

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

## How it works

- `BarWidget.qml` — bar pill (gamepad glyph) that loads and forwards the
  panel lifecycle, so GameDock participates in bar popout coordination.
- `Panel.qml` — `KeyboardPanel` with four sections: Favorites, Recently
  Played, Launchers, Installed Games.
- `Model.js` — scan-data views, favorites state, and detached launch command
  builders.
- `scan.py` — Python 3 stdlib backend. `scan` parses launcher metadata and
  writes the canonical cache; `favorites-set` persists favorites. Every
  launcher is isolated so a malformed source cannot abort the full scan.

## State files

| Path | Owner | Purpose |
|---|---|---|
| `~/.local/state/omarchy/gamedock/cache.json` | `scan.py scan` | canonical game/launcher cache |
| `~/.local/state/omarchy/settings/gamedock.json` | `scan.py favorites-set` | `{ "favorites": [...] }` |

## Dependencies

None beyond what Omarchy ships: Quickshell (shell), Python 3 stdlib (scanner).

## Remove

```bash
omarchy plugin remove io.github.prathamesh913.gamedock
```

The state files above are left behind on purpose; delete them by hand to
fully reset.
