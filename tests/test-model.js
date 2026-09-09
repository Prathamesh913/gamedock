// Focused tests for GameDock manual-refresh helpers and launch feedback.
//
// Runs under plain node (no Quickshell): Model.js only needs `console` and,
// for relativeTime's fallback, a `Qt.formatDate` stub. QML-side guards that
// cannot execute here (scanProcess.running, focus restore) are covered by
// static wiring assertions over Panel.qml plus the manual smoke test.
//
// Usage: node tests/test-model.js
"use strict"

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const repoRoot = path.join(__dirname, "..")
const warnings = []
const sandbox = {
  console: { warn: (...args) => warnings.push(args), log: () => {} },
  Qt: { formatDate: () => "formatted-date" },
}
vm.createContext(sandbox)
vm.runInContext(fs.readFileSync(path.join(repoRoot, "Model.js"), "utf8"), sandbox, { filename: "Model.js" })
const Model = sandbox

let passed = 0
let failed = 0
const failures = []
function check(name, cond, detail) {
  if (cond) {
    passed++
    console.log(`PASS: ${name}`)
  } else {
    failed++
    failures.push(name)
    console.log(`FAIL: ${name}${detail ? " — " + detail : ""}`)
  }
}

// --- notify() -------------------------------------------------------------
Model.setNotifyRunner(null)
check("notify without runner returns false", Model.notify("Hi") === false)

let notifyCalls = []
Model.setNotifyRunner((parts) => notifyCalls.push(parts))
notifyCalls = []
check("notify headline-only hands off once", Model.notify("Launching Portal") === true && notifyCalls.length === 1
  && JSON.stringify(notifyCalls[0]) === JSON.stringify(["Launching Portal"]),
  JSON.stringify(notifyCalls))
notifyCalls = []
Model.notify("Launching Portal", "Steam")
check("notify with description passes both parts", notifyCalls.length === 1
  && JSON.stringify(notifyCalls[0]) === JSON.stringify(["Launching Portal", "Steam"]),
  JSON.stringify(notifyCalls))
notifyCalls = []
check("notify empty headline never calls runner", Model.notify("   ") === false && notifyCalls.length === 0)
check("notify trims headline", (() => {
  notifyCalls = []
  Model.notify("  Hi  ")
  return notifyCalls.length === 1 && notifyCalls[0][0] === "Hi"
})())
Model.setNotifyRunner(null)

// --- rescanKeyPressed() ----------------------------------------------------
check("R always rescans", Model.rescanKeyPressed("R", "") === true && Model.rescanKeyPressed("R", "por") === true)
check("r rescans with empty query", Model.rescanKeyPressed("r", "") === true)
check("r refines a non-empty query", Model.rescanKeyPressed("r", "portal") === false)
check("other keys never rescan", ["a", "/", "j", "k", "", null, undefined].every((t) => Model.rescanKeyPressed(t, "") === false))

// --- display titles (toast text uses these, never ids/paths) ---------------
check("displayTitle uses game title", Model.displayTitle({ title: "Hades II", id: "steam/1" }) === "Hades II")
check("displayTitle falls back", Model.displayTitle({ id: "steam/1" }) === "game" && Model.displayTitle(null) === "game")
check("displayLauncherName uses launcher name",
  Model.displayLauncherName({ name: "Steam" }) === "Steam" && Model.displayLauncherName({}) === "launcher")

// --- launch paths (all four launchers + launcher-level) --------------------
function wireExec() {
  const calls = []
  Model.setExecRunner((argv) => calls.push(argv))
  Model.setLaunchers([
    { id: "steam", installed: true, executable: "/usr/bin/steam" },
    { id: "heroic", installed: true, executable: "/usr/bin/heroic" },
    { id: "retroarch", installed: true, executable: "/usr/bin/retroarch" },
    { id: "rpcs3", installed: true, executable: "/usr/bin/rpcs3" },
  ])
  return calls
}

let calls = wireExec()
const steamGame = { id: "steam/440", title: "Team Fortress 2", launcher: "steam", launch: { appid: "440" } }
check("steam launch accepted with rungameid argv",
  Model.launchGame(steamGame) === true && calls.length === 1
  && calls[0][0] === "/usr/bin/steam" && calls[0][1] === "steam://rungameid/440",
  JSON.stringify(calls))

calls = wireExec()
check("heroic launch accepted with launch URI",
  Model.launchGame({ title: "Hades", launcher: "heroic", launch: { appName: "hades", runner: "legendary" } }) === true
  && calls.length === 1 && calls[0][2].indexOf("heroic://launch?appName=hades&runner=legendary") === 0,
  JSON.stringify(calls))

calls = wireExec()
check("retroarch launch accepted with core+rom",
  Model.launchGame({ title: "Mario", launcher: "retroarch", launch: { core: "/c/snes.so", rom: "/r/m.smc" } }) === true
  && calls.length === 1 && JSON.stringify(calls[0]) === JSON.stringify(["/usr/bin/retroarch", "-L", "/c/snes.so", "/r/m.smc"]),
  JSON.stringify(calls))

calls = wireExec()
check("rpcs3 launch accepted with --no-gui path",
  Model.launchGame({ title: "Game", launcher: "rpcs3", launch: { path: "/g/BLUS1" } }) === true
  && calls.length === 1 && JSON.stringify(calls[0]) === JSON.stringify(["/usr/bin/rpcs3", "--no-gui", "/g/BLUS1"]),
  JSON.stringify(calls))

calls = wireExec()
check("launcher-level launch accepted",
  Model.launchLauncher({ id: "steam", name: "Steam", installed: true, executable: "/usr/bin/steam" }) === true
  && calls.length === 1 && JSON.stringify(calls[0]) === JSON.stringify(["/usr/bin/steam"]),
  JSON.stringify(calls))

calls = wireExec()
check("retroarch without core is a detectable failure",
  Model.launchGame({ title: "X", launcher: "retroarch", launch: { core: null, rom: "/r" } }) === false && calls.length === 0)
calls = wireExec()
check("unknown launcher is a detectable failure",
  Model.launchGame({ title: "X", launcher: "ps5", launch: { appid: "1" } }) === false && calls.length === 0)
Model.setLaunchers([{ id: "steam", installed: false, executable: "", name: "Steam" }])
calls = wireExec()
Model.setLaunchers([{ id: "steam", installed: false, executable: "" }])
check("uninstalled launcher is a detectable failure",
  Model.launchGame(steamGame) === false && calls.length === 0)

// Selection alone must not emit anything: viewing model data performs no runs.
calls = wireExec()
notifyCalls = []
Model.setNotifyRunner((parts) => notifyCalls.push(parts))
Model.allGames({ games: [steamGame] })
Model.recentGames({ recent: [steamGame] })
Model.favoriteGames({ games: [steamGame], recent: [] }, ["steam/440"])
Model.gamesByLauncher({ games: [steamGame] }, "steam")
check("selection/view access emits no launch or notification", calls.length === 0 && notifyCalls.length === 0)
Model.setNotifyRunner(null)

// --- Panel.qml wiring (static guards for QML-only behavior) ----------------
const panel = fs.readFileSync(path.join(repoRoot, "Panel.qml"), "utf8")
function has(snippet) { return panel.indexOf(snippet) >= 0 }
check("rescan ignores duplicate requests", has("if (scanProcess.running || root.rescanPending) return"))
check("scanning flag cleared on process exit", has("onExited:") && has("root.rescanPending = false"))
check("refresh failure path notifies", has("Could not refresh game library"))
check("refresh success path notifies once", (panel.match(/Game library updated/g) || []).length === 1)
check("launch success notifies with title", has('root.notify("Launching " + title)'))
check("launch failure notifies with title", has('root.notify("Could not launch " + title)'))
check("launcher open notifies with name", has('root.notify("Opening " + name)'))
check("successful game launch closes panel", has('root.notify("Launching " + title)') && has("root.close()"))
check("native notify binary wired", has("omarchy-notification-send"))
check("notify runner wired on completion", has("Model.setNotifyRunner"))
check("focus restore after rescan", has("restoreRescanFocus") && has("Qt.callLater(root.restoreRescanFocus)"))
check("scanning state shown on button", has("Scanning…") && has("iconSpinning: scanProcess.running"))
check("shortcut rule delegated to model", has("Model.rescanKeyPressed(t, root.searchQuery)"))

console.log(`\n${passed} passed, ${failed} failed`)
if (failed > 0) {
  console.log("FAILURES: " + failures.join(", "))
  process.exit(1)
}
