import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// retro-wall's scenes as Omarchy backgrounds. Each scene is a still in the background picker (a link in
// ~/.config/omarchy/backgrounds/<theme>/ to a frame of it), so it is chosen, replaced and shown on the lock
// screen the way any background is. While the background is one of those stills, retro-wall plays the
// scene on the background layer, and the shell's own background is suspended, as Omarchy's video engine
// (OWE) suspends it for a video. Any other background stops it and hands the layer back.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string share: home + "/.local/share/retro"
  readonly property string binary: share + "/retro-wall"
  readonly property string stills: share + "/omarchy/"
  readonly property string currentDir: home + "/.local/state/omarchy/current"
  readonly property string helper: (manifest && manifest.__sourceDir ? manifest.__sourceDir : "") + "/bin/retro-wall-omarchy"

  property bool installed: false
  property string omarchyTheme: ""
  property string background: ""
  // The retro-wall theme the background asks for, "" for none.
  readonly property string scene: {
    var b = root.background
    if (b.indexOf(root.stills) !== 0) return ""
    var m = /^retro-wall-([A-Za-z0-9_.-]+)\.png$/.exec(b.slice(root.stills.length))
    return m ? m[1] : ""
  }
  // What the shell's background was told last: true while retro-wall has the layer.
  property bool suspended: false
  property bool notified: false

  // The bar's room on each screen, in the screen's own pixels, as retro-wall's --reserve-EDGE takes it.
  readonly property var bar: shell ? shell.bar : null
  readonly property var reserve: {
    var args = []
    if (!root.bar || root.bar.barHidden) return args
    var edge = ["top", "bottom", "left", "right"].indexOf(root.bar.position) !== -1 ? root.bar.position : "top"
    for (var s of Quickshell.screens) {
      var px = Math.round(root.bar.barSizeFor(s.name) * (s.devicePixelRatio || 1))
      if (px > 0) args.push("--reserve-" + edge, s.name + "=" + px)
    }
    return args
  }
  // The largest screen's pixels and its room, for the stills.
  readonly property var stillSize: {
    var best = null
    for (var s of Quickshell.screens) {
      var dpr = s.devicePixelRatio || 1
      var w = Math.round(s.width * dpr), h = Math.round(s.height * dpr)
      if (!best || w * h > best.w * best.h) best = { w: w, h: h, name: s.name }
    }
    return best
  }
  readonly property var stillReserve: {
    if (!root.stillSize || !root.bar || root.bar.barHidden) return []
    var edge = ["top", "bottom", "left", "right"].indexOf(root.bar.position) !== -1 ? root.bar.position : "top"
    for (var s of Quickshell.screens) {
      if (s.name !== root.stillSize.name) continue
      var px = Math.round(root.bar.barSizeFor(s.name) * (s.devicePixelRatio || 1))
      return px > 0 ? ["--reserve-" + edge, String(px)] : []
    }
    return []
  }

  function notify(headline, text, exec) {
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "retro-wall", headline, text].concat(exec ? ["--exec"].concat(exec) : []))
  }

  function setSuspended(value) {
    root.suspended = value
    Quickshell.execDetached(["omarchy-shell", "-q", "background", "setSuspended", value ? "true" : "false"])
  }

  function isVideo(path) {
    return /\.(mp4|m4v|mov|webm|mkv|avi|mpeg|mpg|ts|wmv|flv|ogv|3gp|gif)$/i.test(path)
  }

  // --- what the background is ---------------------------------------------------------------------------

  function read() {
    if (reader.running) reader.again = true
    else reader.running = true
  }

  Process {
    id: reader
    property bool again: false
    command: ["bash", "-c", 'readlink -f "$1/background" || echo; cat "$1/theme.name" 2>/dev/null || echo; [[ -x $2 ]] && echo yes || echo no',
              "retro-wall", root.currentDir, root.binary]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = this.text.split("\n")
        root.installed = lines[2] === "yes"
        root.missing()
        root.background = lines[0] || ""
        if (lines[1] && lines[1] !== root.omarchyTheme) root.omarchyTheme = lines[1]
        root.decide()
      }
    }
    onExited: if (again) { again = false; running = true }
  }

  // The picker's link or the theme's name changing: read again. inotifywait ends with the shell, and is
  // restarted when it ends, less and less often while it keeps ending at once.
  property real watchStarted: 0
  property int quickExits: 0
  Process {
    id: watcher
    command: ["bash", "-c", 'mkdir -p "$1" && exec setpriv --pdeathsig TERM -- inotifywait -m -q -e create,moved_to,delete --format "%f" "$1"',
              "retro-wall", root.currentDir]
    running: true
    onRunningChanged: if (running) root.watchStarted = Date.now()
    stdout: SplitParser {
      onRead: function(line) {
        if (line === "background" || line === "theme.name") settle.restart()
      }
    }
    onExited: {
      root.quickExits = Date.now() - root.watchStarted < 1000 ? root.quickExits + 1 : 0
      rewatch.interval = Math.min(60000, 1000 * Math.pow(2, Math.max(0, root.quickExits - 4)))
      rewatch.start()
    }
  }
  Timer { id: rewatch; onTriggered: watcher.running = true }
  Timer { id: settle; interval: 200; onTriggered: root.read() }
  // Until the program is installed, look for it now and then.
  Timer { interval: 15000; repeat: true; running: !root.installed; onTriggered: root.read() }

  // --- the picker's stills ---------------------------------------------------------------------------------

  function sync() {
    if (!root.installed || !root.omarchyTheme || !root.stillSize || !root.helper) return
    if (syncer.running) { syncer.again = true; return }
    syncer.command = [root.helper, "sync", root.omarchyTheme, root.stillSize.w + "x" + root.stillSize.h].concat(root.stillReserve)
    syncer.running = true
  }

  Process {
    id: syncer
    property bool again: false
    stdout: StdioCollector { onStreamFinished: if (this.text.trim()) console.log("retro-wall: " + this.text.trim()) }
    onExited: if (again) { again = false; root.sync() }
  }

  // Theme, screens or bar changing settle first, so a burst of them draws once.
  Timer { id: resync; interval: 1500; onTriggered: root.sync() }
  onOmarchyThemeChanged: resync.restart()
  onStillSizeChanged: resync.restart()
  onStillReserveChanged: resync.restart()
  onInstalledChanged: if (installed) resync.restart()

  // Once a session: the plugin without the program shows nothing. Said a little after the shell starts,
  // when its notifications are up to show it.
  function missing() {
    if (!root.installed && !root.notified && !missingNotice.running) missingNotice.start()
  }
  Timer {
    id: missingNotice
    interval: 8000
    onTriggered: {
      if (root.installed || root.notified) return
      root.notified = true
      root.notify("retro-wall is not installed", "Click to get it, then run linux/install.",
                  ["xdg-open", "https://github.com/PacAnimal/retro-wall/releases/latest"])
    }
  }

  // --- the scene -----------------------------------------------------------------------------------------

  property real wallStarted: 0
  property int wallFailures: 0
  property string wallScene: ""

  function decide() {
    if (root.scene !== root.wallScene && !wall.running) root.wallFailures = 0
    var want = root.installed && root.scene !== "" && root.wallFailures < 5
    if (want && wall.running && root.wallScene === root.scene) return
    var video = root.isVideo(root.background)
    if (wall.running && root.suspended && !video) {
      // another scene, or a still: the shell shows its still first, then the scene ends, so nothing
      // empty is seen between them (onExited starts what is wanted then)
      root.setSuspended(false)
      handover.restart()
    } else if (wall.running) {
      if (!handover.running) wall.running = false
    } else if (want) {
      start()
    } else if (root.suspended && !video) {
      root.setSuspended(false)
    }
  }

  function start() {
    root.wallScene = root.scene
    // the user's options for this display, then the scene, every monitor and the bar's room; it ends with
    // the shell that started it, whatever ends the shell
    wall.command = [root.helper, "run", root.wallScene].concat(root.reserve)
    wall.running = true
  }

  Process {
    id: wall
    onRunningChanged: {
      if (!running) return
      root.wallStarted = Date.now()
      root.held = false
      claim.count = 0
      claim.interval = 1500
      claim.restart()
    }
    onExited: function(code) {
      claim.stop()
      var wanted = root.installed && root.scene !== ""
      if (code === 0 && Date.now() - root.wallStarted < 10000) {
        // it chose to show only the still (no hardware OpenGL, say): the shell shows the same still
        console.log("retro-wall: it shows the still only; see ~/.local/share/retro/retro-wall.log")
        root.wallFailures = 5
        if (root.suspended) root.setSuspended(false)
        return
      }
      if (wanted && root.scene === root.wallScene) {
        // it ended by itself: again, but not forever
        root.wallFailures = Date.now() - root.wallStarted < 10000 ? root.wallFailures + 1 : 0
        if (root.wallFailures >= 5) {
          root.setSuspended(false)
          root.notify("retro-wall keeps stopping", "The scene's still is shown instead. See ~/.local/share/retro/retro-wall.log.")
          return
        }
        if (root.wallFailures > 0) root.setSuspended(false)
        restartWall.interval = 1000 * root.wallFailures
        restartWall.restart()
      } else {
        root.wallFailures = 0
        root.decide()
      }
    }
  }
  // The shell's background is shown again before the playing scene ends.
  Timer { id: handover; interval: 400; onTriggered: wall.running = false }

  // Read again first: the program could be gone, or the background changed meanwhile.
  Timer { id: restartWall; onTriggered: root.read() }

  // The shell's background is suspended once retro-wall has had time for its first frame, under which the
  // still of the same scene is what shows meanwhile. It is told again twice: a handoff of OWE's that was
  // still under way could have given the layer back to the shell.
  Timer {
    id: claim
    property int count: 0
    onTriggered: {
      if (!wall.running) return
      root.setSuspended(true)
      root.hold()
      count += 1
      if (count < 3) { interval = count === 1 ? 3000 : 8000; restart() }
    }
  }

  // --- unseen: under fullscreen windows, or locked -----------------------------------------------------
  //
  // Hyprland still asks a wallpaper for frames under a fullscreen window and under the lock screen, so
  // retro-wall cannot tell it is unseen. When the session is locked, or every monitor shows a real
  // fullscreen window (mode bit 2, as the shell's notifications tell it) on its workspace or on the special
  // workspace over it (the screensaver's), it is told to pause (SIGUSR1), and to run again (SIGUSR2) after.
  // The lock is told as Omarchy tells it: LOCK among a monitor's solitaryBlockedBy.
  property int hyprRevision: 0
  function fullscreenIn(workspace) {
    if (!workspace || !workspace.hasFullscreen) return false
    var windows = workspace.toplevels ? workspace.toplevels.values : []
    for (var w of windows) {
      if ((Number((w.lastIpcObject || {}).fullscreen) & 2) !== 0) return true
    }
    return false
  }
  readonly property bool covered: {
    var revision = root.hyprRevision
    var screens = Quickshell.screens
    if (screens.length === 0) return false
    var all = true
    for (var s of screens) {
      var monitor = Hyprland.monitorFor(s)
      if (!monitor) return false
      var ipc = monitor.lastIpcObject || {}
      if ((ipc.solitaryBlockedBy || []).indexOf("LOCK") !== -1) return true
      var special = null
      var specialId = ipc.specialWorkspace ? Number(ipc.specialWorkspace.id) : 0
      if (specialId !== 0) {
        for (var ws of Hyprland.workspaces.values) if (ws.id === specialId) special = ws
      }
      if (!root.fullscreenIn(monitor.activeWorkspace) && !root.fullscreenIn(special)) all = false
    }
    return all
  }
  property bool held: false

  function hold() {
    if (!wall.running || !wall.processId) { root.held = false; return }
    if (root.covered === root.held) return
    root.held = root.covered
    Quickshell.execDetached(["kill", root.held ? "-USR1" : "-USR2", String(wall.processId)])
  }
  onCoveredChanged: hold()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      switch (event.name) {
      case "fullscreen": case "openwindow": case "closewindow": case "movewindowv2":
      case "activewindowv2": case "workspacev2": case "focusedmonv2": case "changefloatingmode":
      case "activespecial": case "activespecialv2":
        hyprRefresh.restart()
      }
    }
  }
  // A burst of events settles, then Hyprland's answer lands before it is read again.
  Timer { id: hyprRefresh; interval: 100; onTriggered: root.refreshHyprland() }
  Timer { id: hyprSettle; interval: 250; onTriggered: root.hyprRevision++ }
  // Hyprland tells no event for a lock: while the wall plays, its monitors are asked again now and then.
  Timer { interval: 3000; repeat: true; running: wall.running; onTriggered: root.refreshHyprland() }
  function refreshHyprland() {
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    hyprSettle.restart()
  }

  // The bar moved, resized or hid, or a screen came or went: retro-wall again, with its room.
  property string reserveKey: root.reserve.join(" ")
  onReserveKeyChanged: if (wall.running) rereserve.restart()
  Timer { id: rereserve; interval: 1000; onTriggered: if (wall.running) wall.running = false }

  Component.onCompleted: read()
  Component.onDestruction: {
    wall.running = false
    if (root.suspended) root.setSuspended(false)
  }
}
