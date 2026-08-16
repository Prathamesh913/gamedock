// GameDock Model — UI-facing data and launch logic.
//
// QML owns presentation and file/process objects. This module owns the
// canonical game-facing operations and receives two small runners from the
// panel: one for refreshes and one for detached argv execution.

var favorites = []
var refreshRunner = null
var execRunner = null
var launchersById = ({})

function setRefreshRunner(fn) {
  refreshRunner = fn
}

function setExecRunner(fn) {
  execRunner = fn
}

function refresh() {
  if (typeof refreshRunner === "function") refreshRunner()
  else console.warn("GameDock: refresh() called before a runner was wired")
}

function setLaunchers(launchers) {
  launchersById = ({})
  var values = Array.isArray(launchers) ? launchers : []
  for (var i = 0; i < values.length; i++) {
    if (values[i] && values[i].id) launchersById[String(values[i].id)] = values[i]
  }
}

function parseScan(raw) {
  try {
    var doc = JSON.parse(String(raw || ""))
    if (!doc || typeof doc !== "object") return null
    return doc
  } catch (e) {
    return null
  }
}

function launcherExecutable(id) {
  var launcher = launchersById[String(id || "")]
  if (!launcher || launcher.installed !== true) return ""
  return String(launcher.executable || "")
}

function run(argv) {
  if (!Array.isArray(argv) || argv.length === 0 || typeof execRunner !== "function") {
    console.warn("GameDock: unable to launch; no executable runner is available")
    return false
  }
  execRunner(argv)
  return true
}

function launchGame(game) {
  if (!game || !game.launcher || !game.launch) {
    console.warn("GameDock: game has no launch metadata", JSON.stringify(game || {}))
    return false
  }

  var launcher = String(game.launcher)
  var executable = launcherExecutable(launcher)
  if (executable === "") {
    console.warn("GameDock: launcher is unavailable", launcher)
    return false
  }

  var launch = game.launch
  if (launcher === "steam") {
    if (!launch.appid) return false
    return run([executable, "steam://rungameid/" + encodeURIComponent(String(launch.appid))])
  }

  if (launcher === "heroic") {
    if (!launch.appName || !launch.runner) return false
    var uri = "heroic://launch?appName=" + encodeURIComponent(String(launch.appName))
      + "&runner=" + encodeURIComponent(String(launch.runner))
    return run([executable, "--no-gui", uri])
  }

  if (launcher === "retroarch") {
    if (!launch.core || !launch.rom) {
      console.warn("GameDock: RetroArch game has no valid core", String(game.id || ""))
      return false
    }
    return run([executable, "-L", String(launch.core), String(launch.rom)])
  }

  if (launcher === "rpcs3") {
    if (!launch.path) return false
    return run([executable, "--no-gui", String(launch.path)])
  }

  console.warn("GameDock: unsupported launcher", launcher)
  return false
}

function launchLauncher(launcher) {
  if (!launcher || launcher.installed !== true || !launcher.executable) {
    console.warn("GameDock: launcher is unavailable", JSON.stringify(launcher || {}))
    return false
  }
  return run([String(launcher.executable)])
}

// Favorites are stored as {"favorites": [stable-game-id, ...]}.
// Accept a bare array while reading older Step 1 state, but always write the
// canonical object shape.
function loadFavorites(raw) {
  favorites = []
  try {
    var parsed = JSON.parse(String(raw || "{}"))
    var values = Array.isArray(parsed) ? parsed : parsed && parsed.favorites
    if (Array.isArray(values)) {
      for (var i = 0; i < values.length; i++) {
        if (typeof values[i] === "string" && favorites.indexOf(values[i]) < 0)
          favorites.push(values[i])
      }
    }
  } catch (e) {
    // Missing or corrupt favorites state starts empty rather than failing UI.
  }
  return favorites.slice()
}

function getFavorites() {
  return favorites.slice()
}

function saveFavorites() {
  return JSON.stringify({ favorites: favorites }, null, 2) + "\n"
}

function isFavorite(gameId) {
  return favorites.indexOf(String(gameId || "")) >= 0
}

function toggleFavorite(gameId) {
  var key = String(gameId || "")
  if (key === "") return favorites.slice()
  var index = favorites.indexOf(key)
  if (index >= 0) favorites.splice(index, 1)
  else favorites.push(key)
  return favorites.slice()
}

function allGames(doc) {
  return doc && Array.isArray(doc.games) ? doc.games : []
}

function recentGames(doc) {
  var values = doc && Array.isArray(doc.recent) ? doc.recent.slice() : []
  values.sort(function(a, b) {
    var at = a && a.lastPlayed !== null && a.lastPlayed !== undefined ? Number(a.lastPlayed) : -1
    var bt = b && b.lastPlayed !== null && b.lastPlayed !== undefined ? Number(b.lastPlayed) : -1
    return bt - at
  })
  return values
}

function favoriteGames(doc, ids) {
  var wanted = Array.isArray(ids) ? ids : favorites
  var byId = ({})
  var games = allGames(doc)
  var recent = doc && Array.isArray(doc.recent) ? doc.recent : []
  for (var i = 0; i < games.length; i++) byId[String(games[i].id)] = games[i]
  for (var j = 0; j < recent.length; j++) {
    if (!byId[String(recent[j].id)]) byId[String(recent[j].id)] = recent[j]
  }

  var result = []
  for (var k = 0; k < wanted.length; k++) {
    var game = byId[String(wanted[k])]
    if (game) result.push(game)
  }
  return result
}

function gamesByLauncher(doc, launcherId) {
  var result = []
  var games = allGames(doc)
  for (var i = 0; i < games.length; i++) {
    if (String(games[i].launcher) === String(launcherId)) result.push(games[i])
  }
  return result
}

function relativeTime(timestamp) {
  if (timestamp === null || timestamp === undefined || timestamp === "") return ""
  var value = Number(timestamp)
  if (!isFinite(value) || value <= 0) return ""
  var seconds = Math.max(0, Math.floor(Date.now() / 1000 - value))
  if (seconds < 60) return "Just now"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m ago"
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago"
  if (seconds < 172800) return "Yesterday"
  if (seconds < 604800) return Math.floor(seconds / 86400) + "d ago"
  return Qt.formatDate(new Date(value * 1000), "d MMM yyyy")
}
