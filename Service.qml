import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  readonly property string scriptsDir: String(Qt.resolvedUrl("scripts")).replace(/^file:\/\//, "")
  readonly property string stateScript: scriptsDir + "/state.sh"
  readonly property string setupScript: scriptsDir + "/warp-setup"
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 3600)

  property bool loaded: false
  property var warpState: Model.parseState("")
  readonly property string stage: Model.stage(loaded, warpState)

  // Optimistic switch state so the toggle throws the instant it is clicked.
  // -1 follows the real state; 0/1 while a connect/disconnect catches up.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? warpState.connected : _desired === 1
  readonly property bool busy: actionProcess.running || registerProcess.running || _desired !== -1

  property bool registering: false
  property bool _connectAfterRegister: false
  property string loginUrl: ""
  property string actionStatus: ""
  property string lastError: ""

  readonly property string statusText: {
    if (stage === "loading") return "Checking…"
    if (stage === "install") return "Not installed"
    if (stage === "service") return "Service stopped"
    if (registering) return "Finish signing in…"
    if (stage === "register") return "Not registered"
    if (_desired === 1 || (warpState.connecting && !warpState.connected)) return "Connecting…"
    if (_desired === 0) return "Disconnecting…"
    if (warpState.connected) return "Connected"
    return "Disconnected"
  }

  readonly property string accountLabel: Model.accountLabel(warpState)
  readonly property string edgeSummary: Model.edgeSummary(warpState)
  readonly property string proxyAddress: Model.proxyAddress(warpState)
  readonly property var modes: Model.MODES

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function modeLabel(mode) { return Model.modeLabel(mode) }
  function formatBytes(value) { return Model.formatBytes(value) }
  function cleanTeamName(value) { return Model.cleanTeamName(value) }

  function refresh() {
    if (stateProcess.running) return
    stateProcess.command = [root.stateScript]
    stateProcess.running = true
    stateWatchdog.restart()
  }

  function flash(message) {
    actionStatus = message
    actionStatusTimer.restart()
  }

  function copyToClipboard(value, label) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["wl-copy", "--", text])
    flash("Copied " + (label || text))
  }

  function runAction(command, pending) {
    if (actionProcess.running) return false
    lastError = ""
    actionStatus = pending || ""
    actionProcess.command = command
    actionProcess.running = true
    return true
  }

  function warp(args, pending) {
    return runAction(["warp-cli", "--accept-tos"].concat(args), pending)
  }

  function connect() {
    if (stage !== "ready" || actionProcess.running) return
    _desired = 1
    if (!warp(["connect"])) _desired = -1
    settleTimer.restart()
  }

  function disconnect() {
    if (stage !== "ready" || actionProcess.running) return
    _desired = 0
    if (!warp(["disconnect"])) _desired = -1
    settleTimer.restart()
  }

  function toggle() {
    if (active) disconnect()
    else connect()
  }

  function setMode(mode) {
    if (stage !== "ready" || warpState.modeLocked || String(mode) === warpState.mode) return
    warp(["mode", String(mode)], "Switching to " + Model.modeLabel(mode) + "…")
  }

  function setVnet(id) {
    if (stage !== "ready" || String(id) === warpState.activeVnetId) return
    warp(["vnet", String(id)], "Switching virtual network…")
  }

  function toggleLocalNetwork() {
    if (stage !== "ready") return
    if (warpState.localNetworkAllowed) warp(["override", "local-network", "stop"], "Restoring local network policy…")
    else warp(["override", "local-network", "allow"], "Allowing local network access…")
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  // Installing and starting the daemon need sudo, so they run in a visible
  // terminal where the password can be typed.
  function runInTerminal(command) {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", shellQuote(setupScript) + " " + command])
    settleTimer.restart()
  }

  function install() { runInTerminal("install") }
  function startService() { runInTerminal("start-service") }

  function register(team) {
    if (registerProcess.running) return
    var name = Model.cleanTeamName(team)
    lastError = ""
    loginUrl = ""
    registering = name !== ""
    _connectAfterRegister = true
    actionStatus = name !== "" ? "Opening the " + name + " login in your browser…" : "Registering with free WARP…"
    registerProcess.command = Model.registerCommand(name)
    registerProcess.running = true
    if (registering) registrationTimeout.restart()
  }

  function cancelRegistration() {
    registering = false
    _connectAfterRegister = false
    loginUrl = ""
    actionStatus = ""
    registrationTimeout.stop()
  }

  function openLoginUrl() {
    if (loginUrl !== "") Quickshell.execDetached(["omarchy-launch-browser", loginUrl])
  }

  function unregister() {
    runAction(["bash", "-c", "warp-cli --accept-tos disconnect >/dev/null 2>&1; exec warp-cli --accept-tos registration delete"], "Removing this device's registration…")
  }

  function applyState(raw) {
    var next = Model.parseState(raw)
    var wasRegistered = warpState.registered
    warpState = next
    loaded = true

    if (_desired !== -1 && next.connected === (_desired === 1)) _desired = -1
    if (next.registered && !wasRegistered && registering) {
      registering = false
      loginUrl = ""
      registrationTimeout.stop()
      flash("Registered" + (next.organization !== "" ? " with " + next.organization : ""))
    }
    if (next.registered && _connectAfterRegister && !registerProcess.running) {
      _connectAfterRegister = false
      if (!next.connected) connect()
    }
  }

  function firstLine(text) {
    var lines = String(text || "").split("\n").map(function(line) { return line.trim() }).filter(function(line) { return line !== "" })
    for (var i = 0; i < lines.length; i++) if (/^error/i.test(lines[i])) return lines[i]
    return lines.length > 0 ? lines[lines.length - 1] : ""
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Poll quickly while something is changing: a toggle, a mode switch, or a
  // browser login the user is still finishing.
  Timer {
    id: settleTimer
    interval: 1000
    repeat: true
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 20) {
        root._desired = -1
        stop()
      } else if (!root.busy && !root.registering && ticks >= 3) {
        stop()
      }
    }
  }

  Timer {
    id: registrationTimeout
    interval: 180000
    onTriggered: {
      if (!root.registering) return
      root.registering = false
      root._connectAfterRegister = false
      root.lastError = "Timed out waiting for the browser login. Try registering again."
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    onTriggered: root.actionStatus = ""
  }

  // warp-cli can hang while the daemon restarts; never let one stuck poll stop
  // the panel refreshing for good.
  Timer {
    id: stateWatchdog
    interval: 15000
    onTriggered: if (stateProcess.running) stateProcess.running = false
  }

  Process {
    id: stateProcess
    stdout: StdioCollector {
      id: stateStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      stateWatchdog.stop()
      if (exitCode === 0) root.applyState(stateStdout.text)
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.firstLine(String(actionStderr.text || "") + "\n" + String(actionStdout.text || "")) || "Cloudflare WARP command failed"
        root.actionStatus = ""
      } else if (root.actionStatus !== "") {
        actionStatusTimer.restart()
      }
      settleTimer.restart()
    }
  }

  Process {
    id: registerProcess
    stdout: SplitParser {
      onRead: function(line) {
        var match = String(line || "").match(/https?:\/\/\S+/)
        if (match) root.loginUrl = match[0]
      }
    }
    stderr: StdioCollector { id: registerStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.registering = false
        root._connectAfterRegister = false
        registrationTimeout.stop()
        root.actionStatus = ""
        root.lastError = root.firstLine(registerStderr.text) || "Registration failed"
      } else if (!root.registering) {
        root.actionStatus = ""
      }
      settleTimer.restart()
    }
  }
}
