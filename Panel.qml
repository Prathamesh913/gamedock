import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// GameDock panel. The scanner owns metadata parsing; this component owns
// cached-data presentation, launch/favorite actions, and panel lifecycle.

Panel {
  id: root
  moduleName: "io.github.prathamesh913.gamedock"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string stateHome: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string cachePath: stateHome + "/gamedock/cache.json"
  readonly property string favoritesPath: stateHome + "/settings/gamedock.json"
  readonly property string scanPath: Qt.resolvedUrl("scan.py").toString().replace("file://", "")

  property var launchers: []
  property var scanDoc: null
  property var favoriteIds: []
  property var recentRows: []
  property var favoriteRows: []
  property int installedGameCount: 0
  property int dataRevision: 0
  property int favoritesRevision: 0
  property var focusables: []
  property int focusIndex: -1

  // Remote artwork download state. Keyed by URL: "queued" | "inflight" |
  // "failed" | "ready". Guards prevent repeat downloads and failed retries.
  // artRevision signals GameRows to re-read their cached remote image after a
  // curl download completes.
  property var artworkState: ({})
  property var artworkAttempts: ({})
  property var artworkCheckQueue: []
  property var artworkDownloadQueue: []
  property int artRevision: 0
  readonly property int artworkQueueLimit: 8

  // Search is a pure presentation/filtering layer over the already-loaded
  // model. Empty query shows the normal library view; any non-empty query
  // shows a single SEARCH RESULTS section instead. Matching is a
  // case-insensitive substring over game title and launcher id/name,
  // recomputed only when the query or the cache document changes.
  property string searchQuery: ""

  // Launcher filter ("", i.e. All) + lightweight sort, both presentation-only.
  // "natural" preserves cache order by default; "recent" uses real timestamps
  // and "az"/"launcher" reorder the filtered rows. Filtering/search/sorting run in
  // memory over the loaded model; no scan, filesystem, or network work.
  property string launcherFilter: ""
  property string sortMode: "natural"
  property var filteredRows: []
  readonly property bool searchActive: root.searchQuery.trim() !== ""
  readonly property bool normalViewActive: !root.searchActive && root.launcherFilter === ""
  readonly property bool filteredViewActive: !root.normalViewActive

  property string favoritesPendingPayload: ""

  readonly property var launcherFilterOptions: {
    root.dataRevision
    var out = [{ value: "", label: "All" }]
    var rows = root.launcherRows
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] && rows[i].installed === true)
        out.push({ value: String(rows[i].id), label: root.shortLauncherName(rows[i].id) })
    }
    return out
  }

  readonly property var sortOptions: [
    { value: "natural", label: "Natural" },
    { value: "recent", label: "Recent" },
    { value: "az", label: "A–Z" },
    { value: "launcher", label: "Launcher" }
  ]

  onSearchQueryChanged: {
    if (searchField.text !== root.searchQuery) searchField.text = root.searchQuery
    root.updateFilteredRows()
    root.focusIndex = -1
    Qt.callLater(root.refreshVisibleArtwork)
  }

  onLauncherFilterChanged: {
    root.updateFilteredRows()
    root.focusIndex = -1
    Qt.callLater(root.refreshVisibleArtwork)
  }

  onSortModeChanged: {
    root.updateFilteredRows()
    root.focusIndex = -1
    Qt.callLater(root.refreshVisibleArtwork)
  }

  readonly property var defaultLaunchers: [
    { id: "steam", name: "Steam", icon: "", installed: false, executable: "", note: "" },
    { id: "heroic", name: "Heroic Games Launcher", icon: "󱓟", installed: false, executable: "", note: "" },
    { id: "retroarch", name: "RetroArch", icon: "󰯉", installed: false, executable: "", note: "" },
    { id: "rpcs3", name: "RPCS3", icon: "", installed: false, executable: "", note: "" }
  ]

  // Explicit revision reads keep these derived arrays reactive when the JS
  // module's favorite state changes or a cache document is replaced.
  readonly property var launcherRows: {
    root.dataRevision
    return root.launchers.length > 0 ? root.launchers : root.defaultLaunchers
  }
  function open() {
    openedFromHotkey = false
    root.controller.show()
    startTimers()
    loadCache()
    refresh()
    Qt.callLater(root.refreshVisibleArtwork)
    root.searchQuery = ""
    root.launcherFilter = ""
    keyCatcher.forceActiveFocus()
    Qt.callLater(root.focusInitial)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    startTimers()
    loadCache()
    refresh()
    Qt.callLater(root.refreshVisibleArtwork)
    root.searchQuery = ""
    root.launcherFilter = ""
    keyCatcher.forceActiveFocus()
    Qt.callLater(root.focusInitial)
  }

  function close() {
    stopTimers()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function startTimers() {
    refreshTimer.interval = root.setting("refreshIntervalSec", 300) * 1000
    refreshTimer.restart()
  }

  function stopTimers() {
    refreshTimer.stop()
  }

  function refresh() {
    if (!scanProcess.running) scanProcess.running = true
  }

  function loadCache() {
    cacheFile.reload()
    applyScan(Model.parseScan(cacheFile.text()))
  }

  function applyScan(doc) {
    if (!doc) return
    scanDoc = doc
    launchers = Array.isArray(doc.launchers) ? doc.launchers : []
    Model.setLaunchers(launchers)
    dataRevision++
    refreshViews()
    root.updateFilteredRows()
  }

  function setFavorites(values) {
    favoriteIds = Array.isArray(values) ? values : []
    favoritesRevision++
    refreshViews()
  }

  function refreshViews() {
    recentRows = Model.recentGames(scanDoc)
    favoriteRows = Model.favoriteGames(scanDoc, favoriteIds)
    installedGameCount = Model.allGames(scanDoc).length
  }

  function persistFavorites() {
    var payload = Model.saveFavorites()
    if (favoritesSaveProcess.running) {
      favoritesPendingPayload = payload
      return
    }
    root.startFavoritesSave(payload)
  }

  function startFavoritesSave(payload) {
    favoritesSaveProcess.currentPayload = payload
    favoritesSaveProcess.command = ["python3", root.scanPath, "favorites-set", payload]
    favoritesSaveProcess.running = true
  }

  function toggleFavorite(game) {
    if (!game || !game.id) return
    setFavorites(Model.toggleFavorite(game.id))
    persistFavorites()
  }

  function launchGame(game) {
    Model.setExecRunner(function(argv) { Quickshell.execDetached(argv) })
    return Model.launchGame(game)
  }

  function launchLauncher(launcher) {
    Model.setExecRunner(function(argv) { Quickshell.execDetached(argv) })
    return Model.launchLauncher(launcher)
  }

  function registerFocusable(item) {
    if (!item || focusables.indexOf(item) >= 0) return
    var current = focusIndex >= 0 && focusIndex < focusables.length ? focusables[focusIndex] : null
    var next = focusables.concat([item])
    next.sort(function(a, b) { return Number(a.focusOrder || 0) - Number(b.focusOrder || 0) })
    focusables = next
    focusIndex = current ? focusables.indexOf(current) : -1
    if (focusIndex >= focusables.length) focusIndex = -1
  }

  function unregisterFocusable(item) {
    var index = focusables.indexOf(item)
    if (index < 0) return
    var current = focusIndex >= 0 && focusIndex < focusables.length ? focusables[focusIndex] : null
    var next = focusables.slice()
    next.splice(index, 1)
    focusables = next
    focusIndex = current ? focusables.indexOf(current) : -1
    if (focusIndex >= focusables.length) focusIndex = focusables.length - 1
  }

  function ensureFocusVisible(item) {
    if (!item || !panelFlick || !panelFlick.visible) return
    var position = item.mapToItem(panelFlick.contentItem, 0, 0)
    var top = position.y
    var bottom = top + item.height
    if (top < panelFlick.contentY) panelFlick.contentY = top
    else if (bottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = bottom - panelFlick.height
  }

  function focusAt(index) {
    if (focusables.length === 0) return false
    var clamped = Math.max(0, Math.min(index, focusables.length - 1))
    focusIndex = clamped
    var item = focusables[clamped]
    if (!item) return false
    Qt.callLater(function() { root.ensureFocusVisible(item) })
    return true
  }

  function focusInitial() {
    var firstGame = -1
    for (var i = 0; i < focusables.length; i++) {
      if (focusables[i] && focusables[i].game) {
        firstGame = i
        break
      }
    }
    focusIndex = firstGame >= 0 ? firstGame : 0
    focusAt(focusIndex)
  }

  function moveFocus(direction) {
    if (focusables.length === 0) return false
    if (focusIndex < 0) return focusAt(0)
    var next = focusIndex + (direction < 0 ? -1 : 1)
    if (next < 0 || next >= focusables.length) return false
    return focusAt(next)
  }

  // Mouse hover and the keyboard cursor share one highlight: hovering a row
  // moves the cursor without stealing Qt focus, so the on-screen highlight
  // always points at the single focusIndex (first-party CursorSurface model).
  function setHoverCursor(item) {
    var index = focusables.indexOf(item)
    if (index >= 0) focusIndex = index
  }

  function activateFocused() {
    if (focusIndex < 0 || focusIndex >= focusables.length) return
    var item = focusables[focusIndex]
    if (item && typeof item.activate === "function") item.activate()
  }

  function launcherFor(id) {
    var values = root.launcherRows
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].id) === String(id)) return values[i]
    }
    return null
  }

  function launcherName(id) {
    var launcher = launcherFor(id)
    return launcher ? String(launcher.name) : String(id || "")
  }

  function launcherGlyph(id) {
    var launcher = launcherFor(id)
    return launcher && launcher.icon ? launcher.icon : ""
  }

  // Artwork source resolution: local artwork always wins. A remote cache is
  // shown only after its per-game check or validated download says ready.
  function artworkSource(game) {
    if (!game || !game.artwork) return ""
    var a = game.artwork
    if (a.localPath) return "file://" + a.localPath
    if (a.cachePath && root.artworkState[a.url] === "ready") return "file://" + a.cachePath
    return ""
  }

  function artworkNearViewport(item) {
    if (!item || !root.opened || !panelFlick.visible) return false
    for (var ancestor = item; ancestor && ancestor !== panelFlick; ancestor = ancestor.parent) {
      if (!ancestor.visible) return false
    }
    var position = item.mapToItem(panelFlick.contentItem, 0, 0)
    var margin = panelFlick.height
    return position.y + item.height >= panelFlick.contentY - margin
      && position.y <= panelFlick.contentY + panelFlick.height + margin
  }

  function refreshVisibleArtwork() {
    if (!root.opened) return
    for (var i = 0; i < focusables.length; i++) {
      var item = focusables[i]
      if (item && item.game && root.artworkNearViewport(item)) root.ensureArtwork(item.game, item)
    }
  }

  function ensureArtwork(game, item) {
    if (!game || !game.artwork || !root.opened || !root.artworkNearViewport(item)) return false
    var a = game.artwork
    var url = a.url
    var cachePath = a.cachePath
    if (!url || !cachePath) return false
    var state = root.artworkState[url]
    var attempts = Number(root.artworkAttempts[url] || 0)
    if (state === "checking" || state === "ready" || state === "queued" || state === "inflight") return false
    if (state === "failed" && attempts >= 2) return false
    root.artworkState[url] = "checking"
    if (root.artworkCheckQueue.length < root.artworkQueueLimit)
      root.artworkCheckQueue.push({ url: url, path: cachePath, game: game })
    else
      root.artworkState[url] = ""
    root.pumpArtworkChecks()
    return true
  }

  function pumpArtworkChecks() {
    if (artworkCheckProcess.running || root.artworkCheckQueue.length === 0) return
    var job = root.artworkCheckQueue.shift()
    artworkCheckProcess.currentJob = job
    artworkCheckProcess.command = ["test", "-s", job.path]
    artworkCheckProcess.running = true
  }

  function queueArtworkDownload(job) {
    var attempts = Number(root.artworkAttempts[job.url] || 0)
    if (attempts >= 2 || root.artworkDownloadQueue.length >= root.artworkQueueLimit) {
      root.artworkState[job.url] = "failed"
      return
    }
    root.artworkAttempts[job.url] = attempts + 1
    root.artworkState[job.url] = "queued"
    root.artworkDownloadQueue.push(job)
    root.pumpArtworkDownloads()
  }

  function pumpArtworkDownloads() {
    if (artworkFetchProcess.running || artworkCommitProcess.running
        || root.artworkDownloadQueue.length === 0) return
    var job = root.artworkDownloadQueue.shift()
    artworkFetchProcess.currentJob = job
    artworkFetchProcess.command = ["curl", "-fsS", "--create-dirs", "--max-time", "8",
      "-o", job.tempPath, job.url]
    root.artworkState[job.url] = "inflight"
    artworkFetchProcess.running = true
  }

  function invalidateArtwork(game) {
    if (!game || !game.artwork || !game.artwork.url) return
    var a = game.artwork
    root.artworkState[a.url] = "failed"
    root.queueArtworkDownload({
      url: a.url,
      path: a.cachePath,
      tempPath: a.cachePath + ".part"
    })
  }

  function sortGames(values) {
    var out = Array.isArray(values) ? values.slice() : []
    if (root.sortMode === "az") {
      out.sort(function(a, b) {
        return String(a.title || "").toLowerCase().localeCompare(String(b.title || "").toLowerCase())
      })
    } else if (root.sortMode === "launcher") {
      var order = {}
      var rows = root.launcherRows
      for (var j = 0; j < rows.length; j++) order[String(rows[j].id)] = j
      out.sort(function(a, b) {
        var ai = Object.prototype.hasOwnProperty.call(order, String(a.launcher)) ? order[String(a.launcher)] : rows.length
        var bi = Object.prototype.hasOwnProperty.call(order, String(b.launcher)) ? order[String(b.launcher)] : rows.length
        return ai - bi
      })
    } else if (root.sortMode === "recent") {
      // "recent": real timestamps first (newest first), then games without
      // timestamps in their stable existing order.
      out.sort(function(a, b) {
        var at = a.lastPlayed !== null && a.lastPlayed !== undefined ? Number(a.lastPlayed) : -1
        var bt = b.lastPlayed !== null && b.lastPlayed !== undefined ? Number(b.lastPlayed) : -1
        if (at < 0 && bt < 0) return 0
        if (at < 0) return 1
        if (bt < 0) return -1
        return bt - at
      })
    }
    return out
  }

  // The filtered view pipeline: all installed games → launcher filter →
  // search filter → sort → display. Purely in memory over the loaded model;
  // game objects are referenced (never duplicated) and the stable sort keeps
  // equal keys in their existing order.
  function updateFilteredRows() {
    var q = String(root.searchQuery || "").trim().toLowerCase()
    var filter = String(root.launcherFilter || "")
    var games = Model.allGames(root.scanDoc)
    var out = []
    for (var i = 0; i < games.length; i++) {
      var g = games[i]
      if (!g) continue
      if (filter !== "" && String(g.launcher) !== filter) continue
      if (q) {
        var title = String(g.title || "").toLowerCase()
        var launcher = String(g.launcher || "").toLowerCase()
        var launcherName = root.launcherName(g.launcher).toLowerCase()
        if (title.indexOf(q) === -1 && launcher.indexOf(q) === -1 && launcherName.indexOf(q) === -1) continue
      }
      out.push(g)
    }
    root.filteredRows = root.sortGames(out)
  }

  function setLauncherFilter(value) {
    root.launcherFilter = String(value || "")
  }

  function setSortMode(value) {
    root.sortMode = String(value || "natural")
  }

  // Compact display label for a launcher chip/empty state. Falls back to the
  // model's full launcher name for any launcher outside the known set.
  function shortLauncherName(id) {
    if (id === "steam") return "Steam"
    if (id === "heroic") return "Heroic"
    if (id === "retroarch") return "RetroArch"
    if (id === "rpcs3") return "RPCS3"
    return root.launcherName(id)
  }

  function filteredEmptyText() {
    var searching = root.searchActive
    var filtering = root.launcherFilter !== ""
    if (searching)
      return "No games found\nTry another search" + (filtering ? " or launcher." : ".")
    if (filtering)
      return "No games found for " + root.shortLauncherName(root.launcherFilter) + "."
    return ""
  }

  function focusSearch() {
    searchField.forceActiveFocus()
  }

  function focusFirstSearchResult() {
    keyCatcher.forceActiveFocus()
    Qt.callLater(function() { root.focusAt(0) })
  }

  // Escape from the key catcher (search field not focused): clear a non-empty
  // query first, close only when the query is already empty.
  function handleEscape() {
    if (root.searchQuery !== "") root.searchQuery = ""
    else root.close()
  }

  // Printable key from the key catcher (search field not focused). "/"
  // activates the search field; with a non-empty query other characters
  // refine it, matching the first-party menu/dropdown filter pattern.
  function handleTextKey(t) {
    if (t === "/") {
      root.focusSearch()
      return
    }
    if (root.searchQuery !== "") root.searchQuery = root.searchQuery + t
  }

  function launcherInstalled(id) {
    var launcher = launcherFor(id)
    return launcher ? launcher.installed === true : false
  }

  function gameLaunchAvailable(game) {
    if (!game || !game.launch) return false
    if (game.launcher === "retroarch")
      return !!game.launch.core && !!game.launch.rom
    if (game.launcher === "steam") return !!game.launch.appid
    if (game.launcher === "heroic") return !!game.launch.appName && !!game.launch.runner
    if (game.launcher === "rpcs3") return !!game.launch.path
    return false
  }

  function gamesForLauncher(id) {
    root.dataRevision
    return root.sortGames(Model.gamesByLauncher(root.scanDoc, id))
  }

  function emptyTextFor(launcherId) {
    var launcher = launcherFor(launcherId)
    if (launcher && launcher.note) return launcher.note
    if (launcherId === "steam") return "No installed Steam games."
    if (launcherId === "heroic") return "No installed Heroic games."
    if (launcherId === "retroarch") return "No RetroArch games in your playlists."
    if (launcherId === "rpcs3") return "No RPCS3 games found."
    return "No installed games."
  }

  function scanErrorText() {
    return root.scanDoc && Array.isArray(root.scanDoc.errors) && root.scanDoc.errors.length > 0
      ? "Some launcher data could not be refreshed."
      : ""
  }

  Component.onCompleted: {
    Model.setRefreshRunner(function() { root.refresh() })
    Model.setExecRunner(function(argv) { Quickshell.execDetached(argv) })
  }

  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: true
    printErrors: false
    // text() is stale inside onFileChanged, so re-read through onLoaded like
    // every first-party FileView consumer does.
    onFileChanged: reload()
    onLoaded: root.applyScan(Model.parseScan(text()))
  }

  FileView {
    id: favoritesFile
    path: root.favoritesPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.setFavorites(Model.loadFavorites(text()))
  }

  Process {
    id: scanProcess
    command: ["python3", root.scanPath, "scan"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseScan(String(text || "").trim())
        if (parsed) root.applyScan(parsed)
        // A failed process produces no replacement cache, so the old cache
        // remains visible. A successful scan writes this atomically.
        cacheFile.reload()
      }
    }
  }

  Process {
    id: favoritesSaveProcess
    command: ["python3", root.scanPath, "favorites-set", "{}"]
    property string currentPayload: ""
    onExited: {
      if (root.favoritesPendingPayload !== ""
          && root.favoritesPendingPayload !== currentPayload) {
        var payload = root.favoritesPendingPayload
        root.favoritesPendingPayload = ""
        root.startFavoritesSave(payload)
      } else {
        root.favoritesPendingPayload = ""
      }
    }
  }

  Process {
    id: artworkCheckProcess
    property var currentJob: null
    onExited: {
      var job = artworkCheckProcess.currentJob
      if (!job) return
      if (exitCode === 0) {
        root.artworkState[job.url] = "ready"
        root.artRevision++
      } else {
        root.queueArtworkDownload({
          url: job.url,
          path: job.path,
          tempPath: job.path + ".part"
        })
      }
      root.pumpArtworkChecks()
    }
  }

  // Best-effort, non-blocking remote artwork fetch (Heroic art_square only).
  // Curl writes a temporary file; scan.py validates its image signature and
  // atomically promotes it before the row is marked ready.
  Process {
    id: artworkFetchProcess
    property var currentJob: null
    onExited: {
      var job = artworkFetchProcess.currentJob
      if (!job) return
      if (exitCode === 0) {
        artworkCommitProcess.currentJob = job
        artworkCommitProcess.command = ["python3", root.scanPath, "artwork-commit",
          job.tempPath, job.path]
        artworkCommitProcess.running = true
      } else {
        root.artworkState[job.url] = "failed"
        Quickshell.execDetached(["rm", "-f", job.tempPath])
        root.pumpArtworkDownloads()
      }
    }
  }

  Process {
    id: artworkCommitProcess
    property var currentJob: null
    onExited: {
      var job = artworkCommitProcess.currentJob
      if (!job) return
      if (exitCode === 0) {
        root.artworkState[job.url] = "ready"
        root.artRevision++
      } else {
        root.artworkState[job.url] = "failed"
      }
      root.pumpArtworkDownloads()
    }
  }

  Timer {
    id: refreshTimer
    interval: 300000
    repeat: true
    running: false
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field holds Qt focus, forward keys to it instead of
      // driving the panel cursor (the documented inline-editor pattern).
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        root.moveFocus(dy !== 0 ? dy : dx)
      }
      onActivateRequested: root.activateFocused()
      onCloseRequested: root.handleEscape()
      onTabRequested: function(direction) {
        root.switchPanel(direction)
      }
      onTextKey: function(text) {
        root.handleTextKey(text)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        onContentYChanged: Qt.callLater(root.refreshVisibleArtwork)
        onHeightChanged: Qt.callLater(root.refreshVisibleArtwork)
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: contentColumn
            width: panelFlick.width
            spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: headerRow.implicitHeight

            Row {
              id: headerRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: ""
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.title
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  text: "GAME DOCK"
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  text: "Gaming dashboard"
                  color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.bar ? root.bar.foreground : Color.foreground
          }

          Item {
            width: parent.width
            implicitHeight: searchField.implicitHeight

            TextField {
              id: searchField
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              verticalPadding: Style.space(4)
              placeholderText: "󰍉  Search games..."
              foreground: root.bar ? root.bar.foreground : Color.foreground
              accent: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family

              onTextChanged: {
                if (root.searchQuery !== text) root.searchQuery = text
              }

              // The field only owns keys while it holds Qt focus (the key
              // catcher is blocked). Tab/Shift+Tab keep switching bar panels,
              // Down/Enter hand off to the shared-cursor results, and Escape
              // clears the query before closing — exactly the panel rule.
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  if (root.searchQuery !== "") root.searchQuery = ""
                  else root.close()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.focusFirstSearchResult()
                  event.accepted = true
                }
              }
            }
          }

          // Launcher filter — compact chip row (All + installed launchers).
          // Each chip is an ordinary focusable in the shared cursor, so arrow
          // navigation, Enter/Space activation, and mouse hover all work like
          // any other row/star; no Qt focus is given to the chips.
          Item {
            width: parent.width
            implicitHeight: launcherFilterChips.implicitHeight

            Row {
              id: launcherFilterChips
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(4)

              Repeater {
                model: root.launcherFilterOptions

                Button {
                  id: filterChip
                  required property var modelData
                  required property int index
                  text: modelData ? modelData.label : "All"
                  selected: root.launcherFilter === (modelData ? modelData.value : "")
                  hasCursor: root.focusables[root.focusIndex] === filterChip
                  bordered: true
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  accent: Color.accent
                  fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(6)
                  verticalPadding: Style.space(2)
                  property int focusOrder: -2000 + index
                  onHovered: function(h) { if (h) root.setHoverCursor(filterChip) }
                  onClicked: {
                    root.setHoverCursor(filterChip)
                    root.setLauncherFilter(modelData ? modelData.value : "")
                  }
                  function activate() { root.setLauncherFilter(modelData ? modelData.value : "") }
                  Component.onCompleted: root.registerFocusable(filterChip)
                  Component.onDestruction: root.unregisterFocusable(filterChip)
                }
              }
            }
          }

          // Lightweight sort — compact chip row (Recently Played / A–Z /
          // Launcher). Same focusable pattern as the filter chips.
          Item {
            width: parent.width
            implicitHeight: sortChips.implicitHeight

            Row {
              id: sortChips
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(4)

              Repeater {
                model: root.sortOptions

                Button {
                  id: sortChip
                  required property var modelData
                  required property int index
                  text: modelData ? modelData.label : "Natural"
                  selected: root.sortMode === (modelData ? modelData.value : "natural")
                  hasCursor: root.focusables[root.focusIndex] === sortChip
                  bordered: true
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  accent: Color.accent
                  fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(6)
                  verticalPadding: Style.space(2)
                  property int focusOrder: -1000 + index
                  onHovered: function(h) { if (h) root.setHoverCursor(sortChip) }
                  onClicked: {
                    root.setHoverCursor(sortChip)
                    root.setSortMode(modelData ? modelData.value : "natural")
                  }
                  function activate() { root.setSortMode(modelData ? modelData.value : "natural") }
                  Component.onCompleted: root.registerFocusable(sortChip)
                  Component.onDestruction: root.unregisterFocusable(sortChip)
                }
              }
            }
          }

          // Normal library view (empty search query, All launcher filter) —
          // the unchanged Step 1-4 layout: Favorites, Recently Played,
          // Installed Games, Launchers.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.normalViewActive

            PanelSeparator {
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(3)

              PanelSectionHeader {
                text: "FAVORITES"
                topPadding: 0
                bottomPadding: Style.space(3)
              }

              Repeater {
                model: root.normalViewActive ? root.favoriteRows : []

                GameRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  game: modelData
                  starred: true
                  focusOrder: index * 2
                }
              }

              Text {
                visible: root.favoriteRows.length === 0
                text: "No favorites yet · Star a game to keep it here."
                color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                leftPadding: Style.space(6)
                bottomPadding: Style.space(2)
                elide: Text.ElideRight
                width: parent.width
              }
            }

            PanelSeparator {
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(3)

              PanelSectionHeader {
                text: "RECENTLY PLAYED"
                bottomPadding: Style.space(3)
              }

              Repeater {
                model: root.normalViewActive ? root.recentRows : []

                GameRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  game: modelData
                  starred: root.favoriteIds.indexOf(String(modelData.id)) >= 0
                  focusOrder: 1000 + index * 2
                }
              }

              Text {
                visible: root.recentRows.length === 0
                text: "No recently played games."
                color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                leftPadding: Style.space(6)
                bottomPadding: Style.space(2)
              }
            }

            PanelSeparator {
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(3)

              PanelSectionHeader {
                text: "INSTALLED GAMES"
                bottomPadding: Style.space(3)
              }

              LauncherGames {
                width: parent.width
                launcherId: "steam"
                launcherName: "Steam"
                focusBase: 2000
              }
              LauncherGames {
                width: parent.width
                launcherId: "heroic"
                launcherName: "Heroic Games Launcher"
                focusBase: 2100
              }
              LauncherGames {
                width: parent.width
                launcherId: "retroarch"
                launcherName: "RetroArch"
                focusBase: 2200
              }
              LauncherGames {
                width: parent.width
                launcherId: "rpcs3"
                launcherName: "RPCS3"
                focusBase: 2300
              }

              Text {
                visible: root.installedGameCount === 0
                text: "No games found."
                color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                leftPadding: Style.space(6)
              }
            }

            PanelSeparator {
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(3)

              PanelSectionHeader {
                text: "LAUNCHERS"
                bottomPadding: Style.space(3)
              }

              Repeater {
                model: root.normalViewActive ? root.launcherRows : []

                LauncherRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  launcher: modelData
                  focusOrder: 3000 + index
                }
              }
            }
          }

          // Filtered view (non-empty query OR active launcher filter): one
          // flat section reusing GameRow (artwork + favorites included) with
          // the selected sort applied. No repeated empty sections — a single
          // context-aware empty state when nothing matches.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.filteredViewActive

            PanelSeparator {
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(3)

              PanelSectionHeader {
                text: root.searchActive ? "SEARCH RESULTS" : "INSTALLED GAMES"
                bottomPadding: Style.space(3)
              }

              Repeater {
                model: root.filteredViewActive ? root.filteredRows : []

                GameRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  game: modelData
                  starred: root.favoriteIds.indexOf(String(modelData.id)) >= 0
                  focusOrder: 4000 + index * 2
                }
              }

              Text {
                visible: root.filteredRows.length === 0
                text: root.filteredEmptyText()
                color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                leftPadding: Style.space(6)
                bottomPadding: Style.space(2)
                lineHeight: 1.4
                width: parent.width
              }
            }
          }

          Text {
            visible: root.scanErrorText() !== ""
            text: root.scanErrorText()
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            leftPadding: Style.space(6)
            topPadding: Style.space(2)
          }
        }
      }
    }
  }

  component GameRow: CursorSurface {
    id: gameRow
    required property var game
    property bool starred: false
    property int focusOrder: 0

    hasCursor: root.focusables[root.focusIndex] === gameRow
    foreground: root.bar ? root.bar.foreground : Color.foreground
    implicitHeight: Math.max(Style.space(30), rowInner.implicitHeight + Style.space(6))

    function activate() {
      if (root.gameLaunchAvailable(gameRow.game)) root.launchGame(gameRow.game)
    }

    Component.onCompleted: root.registerFocusable(gameRow)
    Component.onDestruction: root.unregisterFocusable(gameRow)

    // After a curl download lands, re-read the cached remote image. Only
    // remote-only rows reload; local-artwork rows never need it. Re-assign
    // unconditionally so the Image re-reads disk even when the path is the
    // same as before the download completed. Connections is required because
    // inline components do not resolve parent-scope signal handlers.
    Connections {
      target: root
      function onArtRevisionChanged() {
        var a = gameRow.game && gameRow.game.artwork
        if (!a || a.localPath || !a.url) return
        artImage.source = ""
        artImage.source = root.artworkSource(gameRow.game)
      }
    }

    Row {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      // Compact artwork tile (replaces the launcher glyph). Local artwork is
      // shown immediately; a cached remote download appears after curl
      // finishes; otherwise the launcher glyph is the fallback. The Image is
      // only visible once fully decoded, so an invalid/missing/failed source
      // can never render Qt's broken-image placeholder.
      Rectangle {
        id: artTile
        width: Style.space(30)
        height: Style.space(30)
        radius: Style.spacing.labelGap
        color: Style.normalFillFor(gameRow.foreground, Color.accent)
        anchors.verticalCenter: parent.verticalCenter

        Image {
          id: artImage
          anchors.fill: parent
          anchors.margins: Style.space(2)
          asynchronous: true
          cache: false
          smooth: true
          fillMode: Image.PreserveAspectCrop
          source: root.artworkSource(gameRow.game)
          visible: status === Image.Ready
          onStatusChanged: {
            if (status === Image.Error && root.opened && gameRow.game && gameRow.game.artwork) {
              if (gameRow.game.artwork.url) root.invalidateArtwork(gameRow.game)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: artImage.status !== Image.Ready
          text: root.launcherGlyph(gameRow.game ? gameRow.game.launcher : "")
          color: gameRow.foreground
          opacity: root.gameLaunchAvailable(gameRow.game) ? 1 : 0.45
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
        }
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(70)
        spacing: Style.space(1)

        Text {
          text: gameRow.game && gameRow.game.title ? gameRow.game.title : "Unknown game"
          color: gameRow.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          text: root.launcherName(gameRow.game ? gameRow.game.launcher : "")
            + (gameRow.game && Model.relativeTime(gameRow.game.lastPlayed) !== ""
              ? " · " + Model.relativeTime(gameRow.game.lastPlayed) : "")
          color: Qt.darker(gameRow.foreground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      PanelActionButton {
        id: favoriteButton
        z: 2
        size: Style.space(24)
        iconText: gameRow.starred ? "★" : "☆"
        foreground: gameRow.foreground
        hoverColor: Color.accent
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        fontSize: Style.font.title
        tooltipText: gameRow.starred ? "Remove favorite" : "Add favorite"
        hasCursor: root.focusables[root.focusIndex] === favoriteButton
        property int focusOrder: gameRow.focusOrder + 1
        onHovered: function(on) { if (on) root.setHoverCursor(favoriteButton) }
        onClicked: root.toggleFavorite(gameRow.game)

        function activate() { root.toggleFavorite(gameRow.game) }

        Component.onCompleted: root.registerFocusable(favoriteButton)
        Component.onDestruction: root.unregisterFocusable(favoriteButton)
      }
    }

    MouseArea {
      id: rowMouse
      z: -1
      anchors.fill: parent
      hoverEnabled: true
      enabled: root.gameLaunchAvailable(gameRow.game)
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      acceptedButtons: Qt.LeftButton
      onContainsMouseChanged: if (containsMouse) root.setHoverCursor(gameRow)
      onClicked: gameRow.activate()
    }
  }

  component LauncherRow: CursorSurface {
    id: launcherRow
    required property var launcher
    property int focusOrder: 0

    hasCursor: root.focusables[root.focusIndex] === launcherRow
    foreground: root.bar ? root.bar.foreground : Color.foreground
    implicitHeight: Math.max(Style.space(28), rowInner.implicitHeight + Style.space(6))

    function activate() {
      if (launcherRow.launcher && launcherRow.launcher.installed)
        root.launchLauncher(launcherRow.launcher)
    }

    Component.onCompleted: root.registerFocusable(launcherRow)
    Component.onDestruction: root.unregisterFocusable(launcherRow)

    Row {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: launcherRow.launcher && launcherRow.launcher.icon ? launcherRow.launcher.icon : ""
        color: launcherRow.foreground
        opacity: launcherRow.launcher && launcherRow.launcher.installed ? 1 : 0.45
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: launcherRow.launcher ? launcherRow.launcher.name : "Unknown launcher"
        color: launcherRow.foreground
        opacity: launcherRow.launcher && launcherRow.launcher.installed ? 1 : 0.55
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(22) - Style.space(8) - launcherStatusText.width - Style.space(8)
        elide: Text.ElideRight
      }

      Text {
        id: launcherStatusText
        text: launcherRow.launcher && launcherRow.launcher.installed ? "✓" : "Unavailable"
        color: launcherRow.launcher && launcherRow.launcher.installed
          ? Color.foreground : Qt.darker(launcherRow.foreground, 1.4)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: launcherRow.launcher && launcherRow.launcher.installed === true
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      acceptedButtons: Qt.LeftButton
      onContainsMouseChanged: if (containsMouse) root.setHoverCursor(launcherRow)
      onClicked: launcherRow.activate()
    }
  }

  component LauncherGames: Column {
    id: gameGroup
    required property string launcherId
    required property string launcherName
    property int focusBase: 2000
    readonly property var rows: {
      root.dataRevision
      root.sortMode
      return root.normalViewActive ? root.gamesForLauncher(gameGroup.launcherId) : []
    }

    spacing: Style.space(3)
    visible: root.launcherInstalled(gameGroup.launcherId) || gameGroup.rows.length > 0

    Text {
      text: gameGroup.launcherName
      color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.2)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      leftPadding: Style.space(6)
      topPadding: Style.space(2)
    }

    Repeater {
      model: gameGroup.rows

      GameRow {
        required property var modelData
        required property int index
        width: gameGroup.width
        game: modelData
        starred: root.favoriteIds.indexOf(String(modelData.id)) >= 0
        focusOrder: gameGroup.focusBase + index * 2
      }
    }

    Text {
      visible: gameGroup.rows.length === 0
      text: root.emptyTextFor(gameGroup.launcherId)
      color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      leftPadding: Style.space(6)
      bottomPadding: Style.space(3)
    }
  }
}
