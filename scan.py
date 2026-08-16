#!/usr/bin/env python3
"""GameDock scanner — backend for the GameDock Omarchy shell plugin.

Python 3 stdlib only. No third-party dependencies.

Modes:
  scan           Detect launchers, parse game metadata for Steam / Heroic /
                 RetroArch / RPCS3, write cache.json atomically, print the
                 canonical JSON document to stdout.
  favorites-set  Persist the panel's favorites state (JSON on argv).

  Canonical document shape:

  {
    "generatedAt": 0,
    "launchers": [{"id", "name", "icon", "executable", "installed", "note"}, ...],
    "recent": [{"id", "title", "launcher", "lastPlayed", "installed", "launch", "artwork"?}, ...],
    "games": [same shape, ...],
    "errors": [{"launcher", "message"}, ...]
  }

  Optional per-game artwork (only when a real local/remote source exists):

  "artwork": {"localPath": "...", "url": "...", "cachePath": "..."}

  - localPath: existing local image (Heroic icons/<app>.jpg, RPCS3 ICON0.PNG,
    Steam grid <appid>p.jpg)
  - url: existing remote metadata (Heroic art_square only; never invented)
  - cachePath: deterministic md5(url) path under the art cache dir where the
    panel's detached curl download lands

Stable game IDs:
  steam/<appid>
  heroic/<runner>/<app_name>
  retro/<core>/<rom-path>
  rpcs3/<serial>

Design rules:
  - each launcher is scanned in isolation; a failure records an error and
    never aborts the rest of the scan
  - no recursive filesystem walks of game directories — only documented
    metadata files
  - timestamps are read from real metadata only; nothing is fabricated
"""

import glob
import calendar
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
from datetime import datetime

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, ".local", "state", "omarchy", "gamedock")
ART_DIR = os.path.join(STATE_DIR, "art")
SETTINGS_DIR = os.path.join(HOME, ".local", "state", "omarchy", "settings")
CACHE_PATH = os.path.join(STATE_DIR, "cache.json")
FAVORITES_PATH = os.path.join(SETTINGS_DIR, "gamedock.json")

LAUNCHER_DEFS = [
    {"id": "steam", "name": "Steam", "icon": "", "command": "steam"},
    {"id": "heroic", "name": "Heroic Games Launcher", "icon": "󱓟", "command": "heroic"},
    {"id": "retroarch", "name": "RetroArch", "icon": "󰯉", "command": "retroarch"},
    {"id": "rpcs3", "name": "RPCS3", "icon": "", "command": "rpcs3"},
]

# Steam apps that are not games (runtime/tooling). Skipped from the library.
STEAM_TOOL_APPIDS = {
    "228980",  # Steamworks Common Redistributables
    "1070560",  # Steam Linux Runtime
    "1391110",  # Steam Linux Runtime - Soldier
    "1628350",  # Steam Linux Runtime - Sniper
    "1743180",  # Steam Linux Runtime - Sniper (32-bit)
    "2440710",  # Steam Linux Runtime - Sniper (shim)
    "250820",  # SteamVR
    "1420600",  # SteamVR Theater Screen
    "232090",  # Steam Audio
    "410980",  # Steam Audio
}

STEAM_TOOL_NAME_RE = re.compile(
    r"(steamworks common|steam linux runtime|steamvr|steam audio|^proton)", re.IGNORECASE
)


def atomic_write(path, text):
    """Write text to path atomically (tmp file + rename), creating parents."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_text(path):
    """Read a file as UTF-8 (falling back to latin-1), or None if missing."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def load_json(path):
    """Parse a JSON file, returning (data, error_message)."""
    raw = read_text(path)
    if raw is None:
        return None, None
    try:
        return json.loads(raw), None
    except (ValueError, TypeError):
        return None, "could not parse " + os.path.basename(path)


def add_error(doc, launcher, message):
    doc["errors"].append({"launcher": launcher, "message": message})


def artwork_object(local_path=None, url=None):
    """Build the optional artwork metadata for a game, or None.

    Only real sources are used: an existing local file and/or an existing
    remote URL taken from launcher metadata (never invented). The deterministic
    cachePath is where the panel's detached curl download is stored.
    """
    obj = {}
    if local_path:
        obj["localPath"] = local_path
    if url and str(url).startswith("https://"):
        url = str(url)
        obj["url"] = url
        name = hashlib.md5(url.encode("utf-8")).hexdigest() + ".jpg"
        obj["cachePath"] = os.path.join(ART_DIR, name)
    return obj if obj else None


def valid_artwork_file(path):
    """Accept common image signatures without adding an image dependency."""
    try:
        if os.path.getsize(path) <= 16:
            return False
        with open(path, "rb") as f:
            header = f.read(16)
        return (
            header.startswith(b"\xff\xd8\xff")
            or header.startswith(b"\x89PNG\r\n\x1a\n")
            or (header[:4] == b"RIFF" and header[8:12] == b"WEBP")
        )
    except OSError:
        return False


def epoch_seconds(text):
    """Parse 'YYYY-MM-DDTHH:MM:SS...Z' or 'YYYY-MM-DD HH:MM:SS' to epoch."""
    if not text:
        return None
    text = str(text).strip()
    if not text:
        return None
    try:
        if text.endswith("Z") or text.endswith("z"):
            return int(calendar.timegm(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")))
        if "T" in text:
            return int(time.mktime(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")))
        return int(time.mktime(time.strptime(text[:19], "%Y-%m-%d %H:%M:%S")))
    except (ValueError, TypeError):
        return None


def dir_mtime_max(*paths):
    """Newest mtime among existing paths, else None."""
    best = None
    for p in paths:
        if not p:
            continue
        try:
            mt = os.path.getmtime(p)
        except OSError:
            continue
        if best is None or mt > best:
            best = mt
    return int(best) if best is not None else None


# ---------------------------------------------------------------------------
# KeyValues (VDF) parser — used for Steam libraryfolders.vdf, appmanifest_*.acf
# and localconfig.vdf. Tolerant: malformed input yields a partial result, never
# a crash.
# ---------------------------------------------------------------------------


class _VDFTokenizer:
    def __init__(self, text):
        self.text = text
        self.pos = 0
        self.n = len(text)

    def skip_ws_and_comments(self):
        while self.pos < self.n:
            c = self.text[self.pos]
            if c in " \t\r\n":
                self.pos += 1
            elif c == "/" and self.pos + 1 < self.n and self.text[self.pos + 1] == "/":
                end = self.text.find("\n", self.pos)
                self.pos = self.n if end == -1 else end + 1
            else:
                break

    def next_token(self):
        self.skip_ws_and_comments()
        if self.pos >= self.n:
            return None
        c = self.text[self.pos]
        if c == "{":
            self.pos += 1
            return ("{",)
        if c == "}":
            self.pos += 1
            return ("}",)
        if c == '"':
            return self._read_quoted()
        return self._read_bare()

    def _read_quoted(self):
        start = self.pos
        self.pos += 1
        out = []
        while self.pos < self.n:
            c = self.text[self.pos]
            if c == "\\" and self.pos + 1 < self.n:
                nxt = self.text[self.pos + 1]
                if nxt == '"':
                    out.append('"')
                    self.pos += 2
                    continue
                if nxt == "\\":
                    out.append("\\")
                    self.pos += 2
                    continue
                out.append(nxt)
                self.pos += 2
                continue
            if c == '"':
                self.pos += 1
                return ("str", "".join(out))
            out.append(c)
            self.pos += 1
        # Unterminated: salvage what we have.
        return ("str", "".join(out))

    def _read_bare(self):
        start = self.pos
        while self.pos < self.n:
            c = self.text[self.pos]
            if c in '{}" \t\r\n':
                break
            self.pos += 1
        return ("str", self.text[start:self.pos])


def parse_vdf(text):
    """Parse KeyValues text into nested dicts. Returns {} on any failure."""
    node = {}
    try:
        _parse_vdf_into(text, node)
    except Exception:
        return node
    return node


def _parse_vdf_into(text, node):
    """Recursive-descent KeyValues parser writing into `node`."""
    tok = _VDFTokenizer(text)

    def _recurse(tok2, block):
        while True:
            kt = tok2.next_token()
            if kt is None or kt[0] == "}":
                break
            if kt[0] != "str":
                continue
            vt = tok2.next_token()
            if vt is None:
                break
            if vt[0] == "{":
                sub = {}
                block[kt[1]] = sub
                _recurse(tok2, sub)
            else:
                block[kt[1]] = vt[1]

    # top-level: optional header key(s) then block(s)
    while True:
        kt = tok.next_token()
        if kt is None:
            break
        if kt[0] != "str":
            continue
        vt = tok.next_token()
        if vt is None:
            break
        if vt[0] == "{":
            sub = {}
            node[kt[1]] = sub
            _recurse(tok, sub)
        else:
            node[kt[1]] = vt[1]


def find_all(node, key):
    """Yield every value stored under `key` in nested dict `node` (recursive)."""
    if not isinstance(node, dict):
        return
    for k, v in node.items():
        if k == key:
            yield v
        if isinstance(v, dict):
            for found in find_all(v, key):
                yield found


# ---------------------------------------------------------------------------
# Steam
# ---------------------------------------------------------------------------


def _steam_grid_icon(steam_root, appid):
    """Existing Steam grid artwork (userdata/<id>/config/grid/<appid>p.jpg)."""
    grid_root = os.path.join(steam_root, "userdata")
    for sub in glob.glob(os.path.join(grid_root, "*", "config", "grid")):
        icon = os.path.join(sub, str(appid) + "p.jpg")
        if os.path.isfile(icon):
            return icon
    return None


def scan_steam(doc, launcher):
    root = os.path.join(HOME, ".local", "share", "Steam")
    if not os.path.isdir(root):
        return
    libs = []
    lf_path = os.path.join(root, "steamapps", "libraryfolders.vdf")
    lf_text = read_text(lf_path)
    if lf_text is not None:
        lf = parse_vdf(lf_text)
        libfolders = lf.get("libraryfolders", lf)
        for key, entry in libfolders.items():
            if not isinstance(entry, dict):
                continue
            if str(entry.get("mounted", "1")) == "0":
                continue
            path = entry.get("path")
            if path and os.path.isdir(path):
                libs.append(path)
    if not libs:
        libs = [root]

    manifest_paths = []
    for lib in libs:
        apps_dir = os.path.join(lib, "steamapps")
        if os.path.isdir(apps_dir):
            manifest_paths.extend(glob.glob(os.path.join(apps_dir, "appmanifest_*.acf")))

    games_by_appid = {}
    for mf_path in manifest_paths:
        mf = parse_vdf(read_text(mf_path) or "")
        state = mf.get("AppState", mf)
        appid = str(state.get("appid", ""))
        name = str(state.get("name", ""))
        installdir = str(state.get("installdir", ""))
        if not appid or not name:
            continue
        if appid in STEAM_TOOL_APPIDS or STEAM_TOOL_NAME_RE.search(name):
            continue
        games_by_appid[appid] = {
            "id": "steam/" + appid,
            "title": name,
            "launcher": "steam",
            "installed": True,
            "installdir": installdir,
            "appid": appid,
        }

    # Recently played: merge every user's localconfig.vdf RecentApps.
    last_played = {}
    userdata_dir = os.path.join(root, "userdata")
    config_paths = glob.glob(os.path.join(userdata_dir, "*", "config", "localconfig.vdf"))
    for cfg_path in config_paths:
        cfg = parse_vdf(read_text(cfg_path) or "")
        for recent in find_all(cfg, "RecentApps"):
            if not isinstance(recent, dict):
                continue
            for appid, info in recent.items():
                if not isinstance(info, dict):
                    continue
                lp = info.get("LastPlayed")
                if not lp:
                    continue
                try:
                    ts = int(float(lp))
                except (ValueError, TypeError):
                    continue
                if appid not in last_played or ts > last_played[appid]:
                    last_played[appid] = ts

    games = []
    for appid, g in sorted(games_by_appid.items()):
        g["lastPlayed"] = last_played.get(appid)
        g["launch"] = {"appid": appid}
        art = artwork_object(_steam_grid_icon(root, appid))
        if art:
            g["artwork"] = art
        games.append(g)

    recent = []
    for appid, ts in sorted(last_played.items(), key=lambda kv: kv[1], reverse=True):
        g = games_by_appid.get(appid)
        if not g:
            continue  # uninstalled recent games have no title without appinfo.vdf
        recent.append({
            "id": g["id"],
            "title": g["title"],
            "launcher": "steam",
            "lastPlayed": ts,
            "installed": True,
            "launch": {"appid": appid},
            "artwork": g.get("artwork"),
        })

    doc["games"].extend(games)
    doc["recent"].extend(recent)

    if not games and not config_paths:
        launcher["note"] = "Log in to Steam to see your library."


# ---------------------------------------------------------------------------
# Heroic
# ---------------------------------------------------------------------------


def scan_heroic(doc, launcher):
    base = os.path.join(HOME, ".config", "heroic")
    if not os.path.isdir(base):
        return

    library_specs = [
        ("legendary", "store_cache", "legendary_library.json"),
        ("gog", "store_cache", "gog_library.json"),
        ("nile", "store_cache", "nile_library.json"),
    ]

    icons_dir = os.path.join(base, "icons")

    entries = {}  # (runner, app_name) -> info
    for runner, folder, fname in library_specs:
        data, err = load_json(os.path.join(base, folder, fname))
        if err:
            add_error(doc, "heroic", err)
            continue
        if data is None:
            continue
        library = data.get("library", []) if isinstance(data, dict) else None
        if not isinstance(library, list):
            add_error(doc, "heroic", fname + " has no library list")
            continue
        for item in library:
            if not isinstance(item, dict):
                continue
            app_name = str(item.get("app_name") or "")
            title = str(item.get("title") or app_name)
            is_installed = item.get("is_installed") is True
            entries[(runner, app_name)] = {
                "runner": runner,
                "app_name": app_name,
                "title": title,
                "installed": is_installed,
                "art_square": str(item.get("art_square") or ""),
            }

    # recently played / playtime metadata
    timestamps = {}
    ts_data, ts_err = load_json(os.path.join(base, "store", "timestamp.json"))
    if ts_err:
        add_error(doc, "heroic", ts_err)
    elif isinstance(ts_data, dict):
        for app_name, info in ts_data.items():
            if not isinstance(info, dict):
                continue
            lp = epoch_seconds(info.get("lastPlayed"))
            if lp is not None:
                timestamps[str(app_name)] = lp

    def resolve(app_name, runner):
        """Return the library entry for a timestamp hit, preferring `runner`."""
        if (runner, app_name) in entries:
            return entries[(runner, app_name)]
        for (r, a), e in entries.items():
            if a == app_name:
                return e
        return None

    games = []
    for (runner, app_name), e in sorted(entries.items()):
        if not e["installed"]:
            continue
        gid = "heroic/{}/{}".format(runner, app_name)
        lp = timestamps.get(app_name)
        local_icon = os.path.join(icons_dir, app_name + ".jpg")
        art = artwork_object(local_icon if os.path.isfile(local_icon) else None, e["art_square"])
        game = {
            "id": gid,
            "title": e["title"],
            "launcher": "heroic",
            "installed": True,
            "lastPlayed": lp,
            "launch": {"appName": app_name, "runner": runner},
        }
        if art:
            game["artwork"] = art
        games.append(game)
    doc["games"].extend(games)

    recent = []
    for app_name, lp in sorted(timestamps.items(), key=lambda kv: kv[1], reverse=True):
        e = resolve(app_name, "")
        if e is None:
            continue
        gid = "heroic/{}/{}".format(e["runner"], app_name)
        local_icon = os.path.join(icons_dir, app_name + ".jpg")
        art = artwork_object(local_icon if os.path.isfile(local_icon) else None, e["art_square"])
        entry = {
            "id": gid,
            "title": e["title"],
            "launcher": "heroic",
            "lastPlayed": lp,
            "installed": e["installed"],
            "launch": {"appName": app_name, "runner": e["runner"]},
        }
        if art:
            entry["artwork"] = art
        recent.append(entry)
    doc["recent"].extend(recent)


# ---------------------------------------------------------------------------
# RetroArch
# ---------------------------------------------------------------------------

HISTORY_BASENAMES = {"content_history.lpl", "content_video_history.lpl"}


def _clean_playlist_entry(item):
    path = str(item.get("path") or "")
    if not path:
        return None
    if not os.path.exists(path):
        return None
    return {
        "path": path,
        "label": str(item.get("label") or ""),
        "core_path": str(item.get("core_path") or ""),
        "core_name": str(item.get("core_name") or ""),
        "db_name": str(item.get("db_name") or ""),
    }


def _resolve_core(core_path, core_name):
    if core_path and os.path.isfile(core_path):
        return core_path
    if core_path and not os.path.isabs(core_path):
        candidate = os.path.join(HOME, ".config", "retroarch", core_path)
        if os.path.isfile(candidate):
            return candidate
    if core_path == "DETECT" and core_name:
        short = re.sub(r"[^A-Za-z0-9_]", "", core_name.split("(")[0].split("-")[0].strip()).lower()
        if short:
            candidate = os.path.join("/usr/lib/libretro", short + "_libretro.so")
            if os.path.isfile(candidate):
                return candidate
    return None


def _lrtl_last_played(playlists_dir):
    """Map game-title-stem -> epoch from RetroArch's runtime logs (*.lrtl)."""
    result = {}
    for path in glob.glob(os.path.join(playlists_dir, "logs", "*", "*.lrtl")):
        data, err = load_json(path)
        if err or not isinstance(data, dict):
            continue
        lp = epoch_seconds(data.get("last_played"))
        if lp is not None:
            stem = os.path.splitext(os.path.basename(path))[0]
            result[stem] = lp
    return result


def scan_retroarch(doc, launcher):
    base = os.path.join(HOME, ".config", "retroarch")
    playlists_dir = os.path.join(base, "playlists")
    if not os.path.isdir(playlists_dir):
        return

    lrtl_map = _lrtl_last_played(playlists_dir)

    history_items = []
    game_items = []
    seen_game_paths = set()
    seen_history_paths = set()
    for path in glob.glob(os.path.join(playlists_dir, "**", "*.lpl"), recursive=True):
        base_name = os.path.basename(path)
        is_history = "history" in base_name and "image" not in base_name and "music" not in base_name
        data, err = load_json(path)
        if err:
            add_error(doc, "retroarch", err)
            continue
        if not isinstance(data, dict):
            continue
        items = data.get("items", [])
        if not isinstance(items, list):
            continue
        for item in items:
            if not isinstance(item, dict):
                continue
            cleaned = _clean_playlist_entry(item)
            if cleaned is None:
                continue
            if is_history:
                if cleaned["path"] in seen_history_paths:
                    continue
                seen_history_paths.add(cleaned["path"])
                history_items.append(cleaned)
            else:
                if cleaned["path"] in seen_game_paths:
                    continue
                seen_game_paths.add(cleaned["path"])
                game_items.append(cleaned)

    def to_game(entry, order_index):
        core = _resolve_core(entry["core_path"], entry["core_name"])
        stem = os.path.splitext(os.path.basename(entry["path"]))[0]
        lp = lrtl_map.get(stem)
        title = entry["label"] or os.path.splitext(os.path.basename(entry["path"]))[0]
        core_key = os.path.basename(core) if core else "unknown"
        return {
            "id": "retro/{}/{}".format(core_key, entry["path"]),
            "title": title,
            "launcher": "retroarch",
            "installed": True,
            "lastPlayed": lp,
            "launch": {"core": core, "rom": entry["path"]},
            "_order": order_index,
        }

    games = []
    seen_game_ids = set()
    for idx, entry in enumerate(game_items):
        g = to_game(entry, idx)
        if g["id"] in seen_game_ids:
            continue
        seen_game_ids.add(g["id"])
        games.append(g)
    # history entries also count as installed games, deduped by id
    for idx, entry in enumerate(history_items):
        g = to_game(entry, idx)
        if g["id"] in seen_game_ids:
            continue
        seen_game_ids.add(g["id"])
        games.append(g)
    doc["games"].extend(games)

    # recent: history order, newest first (history appends newest last)
    history_items.reverse()
    for idx, entry in enumerate(history_items):
        g = to_game(entry, idx)
        recent_entry = {
            "id": g["id"],
            "title": g["title"],
            "launcher": "retroarch",
            "lastPlayed": g["lastPlayed"],
            "installed": True,
            "launch": g["launch"],
        }
        doc["recent"].append(recent_entry)


# ---------------------------------------------------------------------------
# RPCS3
# ---------------------------------------------------------------------------

RPCS3_SERIAL_RE = re.compile(r"^[A-Za-z0-9_]+$")


def _rpcs3_title_from_path(path):
    name = os.path.splitext(os.path.basename(path))[0]
    name = re.sub(r"\s*\([^)]*\)", "", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name or os.path.basename(path)


def scan_rpcs3(doc, launcher):
    base = os.path.join(HOME, ".config", "rpcs3")
    if not os.path.isdir(base):
        return

    raw = read_text(os.path.join(base, "games.yml"))
    if raw is None:
        return

    home_id = os.path.join(base, "dev_hdd0", "home", "00000001")
    savedata_dir = os.path.join(home_id, "savedata")
    game_dir = os.path.join(base, "dev_hdd0", "game")

    def rpcs3_icon(serial):
        for sub in (os.path.join(game_dir, serial), os.path.join(game_dir, serial + "_install")):
            icon = os.path.join(sub, "ICON0.PNG")
            if os.path.isfile(icon):
                return icon
        return None

    games = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        serial, _, path = line.partition(":")
        serial = serial.strip()
        path = path.strip()
        if not RPCS3_SERIAL_RE.match(serial) or not path:
            continue
        if not os.path.exists(path):
            continue
        lp = None
        if os.path.isdir(savedata_dir):
            for sub in glob.glob(os.path.join(savedata_dir, serial + "*")):
                mt = dir_mtime_max(sub)
                if mt is not None and (lp is None or mt > lp):
                    lp = mt
        for sub in (os.path.join(game_dir, serial), os.path.join(game_dir, serial + "_install")):
            mt = dir_mtime_max(sub)
            if mt is not None and (lp is None or mt > lp):
                lp = mt
        art = artwork_object(rpcs3_icon(serial))
        game = {
            "id": "rpcs3/" + serial,
            "title": _rpcs3_title_from_path(path),
            "launcher": "rpcs3",
            "installed": True,
            "lastPlayed": lp,
            "launch": {"path": path},
        }
        if art:
            game["artwork"] = art
        games.append(game)

    games.sort(key=lambda g: g["title"].lower())
    doc["games"].extend(games)

    recent = []
    for g in games:
        if g["lastPlayed"] is not None:
            recent.append({k: g[k] for k in ("id", "title", "launcher", "lastPlayed", "installed", "launch", "artwork") if k in g})
    recent.sort(key=lambda g: g["lastPlayed"], reverse=True)
    doc["recent"].extend(recent)


# ---------------------------------------------------------------------------
# Scan orchestration
# ---------------------------------------------------------------------------


def detect_launchers():
    launchers = []
    for entry in LAUNCHER_DEFS:
        exe = shutil.which(entry["command"])
        launchers.append({
            "id": entry["id"],
            "name": entry["name"],
            "icon": entry["icon"],
            "executable": exe,
            "installed": exe is not None,
            "note": "",
        })
    return launchers


def scan():
    doc = {
        "generatedAt": int(time.time()),
        "launchers": detect_launchers(),
        "recent": [],
        "games": [],
        "errors": [],
    }
    launchers_by_id = {l["id"]: l for l in doc["launchers"]}

    scanners = [
        ("steam", scan_steam),
        ("heroic", scan_heroic),
        ("retroarch", scan_retroarch),
        ("rpcs3", scan_rpcs3),
    ]
    for launcher_id, scanner in scanners:
        launcher = launchers_by_id[launcher_id]
        if not launcher["installed"]:
            continue
        try:
            scanner(doc, launcher)
        except Exception:
            add_error(doc, launcher_id, launcher_id + " scan failed")

    for game in doc["games"]:
        game.pop("_order", None)
    for game in doc["recent"]:
        game.pop("_order", None)

    return doc


def cmd_scan():
    doc = scan()
    text = json.dumps(doc, indent=2)
    os.makedirs(ART_DIR, exist_ok=True)
    existing, _ = load_json(CACHE_PATH)
    current_meaningful = {k: v for k, v in doc.items() if k != "generatedAt"}
    existing_meaningful = (
        {k: v for k, v in existing.items() if k != "generatedAt"}
        if isinstance(existing, dict) else None
    )
    if existing_meaningful == current_meaningful:
        print(json.dumps(existing, indent=2))
        return
    atomic_write(CACHE_PATH, text)
    print(text)


def cmd_artwork_commit():
    if len(sys.argv) != 4:
        print("gamedock: artwork-commit requires temp and final paths", file=sys.stderr)
        sys.exit(2)
    temp_path, final_path = sys.argv[2], sys.argv[3]
    if not valid_artwork_file(temp_path):
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        sys.exit(1)
    try:
        os.makedirs(os.path.dirname(final_path), exist_ok=True)
        os.replace(temp_path, final_path)
    except OSError:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        sys.exit(1)


def cmd_favorites_set():
    payload = sys.argv[2] if len(sys.argv) > 2 else "{}"
    try:
        data = json.loads(payload)
        if isinstance(data, list):
            data = {"favorites": [x for x in data if isinstance(x, str)]}
        if not isinstance(data, dict) or not isinstance(data.get("favorites"), list):
            raise ValueError("favorites must be an object with a favorites array")
        data["favorites"] = [x for x in data["favorites"] if isinstance(x, str)]
    except ValueError as exc:
        print(f"gamedock: invalid favorites payload: {exc}", file=sys.stderr)
        sys.exit(2)
    atomic_write(FAVORITES_PATH, json.dumps(data, indent=2))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "scan"
    if mode == "scan":
        cmd_scan()
    elif mode == "favorites-set":
        cmd_favorites_set()
    elif mode == "artwork-commit":
        cmd_artwork_commit()
    else:
        print(f"gamedock: unknown mode '{mode}' (expected scan, favorites-set, or artwork-commit)", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
