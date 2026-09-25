import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Cloudflare WARP for the Omarchy bar.
//
// One panel walks through the whole lifecycle:
//   not installed -> Install         (floating terminal, AUR + sudo)
//   service off   -> Start service   (floating terminal, sudo)
//   unregistered  -> Company / team name, or free WARP
//   registered    -> On/off switch, account details, change team / unregister
Panel {
  id: root
  moduleName: "coding-sparrow.cloudflare-warp"
  ipcTarget: "coding-sparrow.cloudflare-warp"

  readonly property string script: String(Qt.resolvedUrl("scripts/warp-setup")).replace(/^file:\/\//, "")

  // ---- state reported by `warp-setup state`
  property bool loaded: false
  property bool installed: false
  property bool serviceUp: false
  property bool registered: false
  property string account: ""
  property string organization: ""
  property string vpnStatus: ""
  property string network: ""
  property string reason: ""

  // ---- ui state
  property bool busy: false
  property bool desired: false
  property bool confirmUnregister: false
  property bool changingTeam: false
  property string lastError: ""

  readonly property bool connected: vpnStatus.toLowerCase() === "connected"
  readonly property bool connecting: vpnStatus.toLowerCase().indexOf("connecting") !== -1
  readonly property bool switchOn: busy ? desired : connected
  // "loading" | "install" | "service" | "register" | "ready"
  readonly property string stage: !loaded ? "loading"
    : !installed ? "install"
    : !serviceUp ? "service"
    : (!registered || changingTeam) ? "register"
    : "ready"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: "󰖂"

  readonly property string statusText: {
    if (stage === "loading") return "Checking…"
    if (stage === "install") return "Not installed"
    if (stage === "service") return "Service stopped"
    if (stage === "register") return changingTeam ? "Change team" : "Not registered"
    if (busy) return desired ? "Connecting…" : "Disconnecting…"
    if (connected) return "Connected"
    if (connecting) return "Connecting…"
    return "Disconnected"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ actions

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function runInTerminal(args) {
    var quoted = args.map(function(a) { return "'" + String(a).replace(/'/g, "'\\''") + "'" }).join(" ")
    if (bar) bar.run("omarchy-launch-floating-terminal-with-presentation " + quoted)
    close()
  }

  function install() { runInTerminal([script, "install"]) }
  function startService() { runInTerminal([script, "start-service"]) }

  function cleanTeam(value) {
    return String(value || "").trim().toLowerCase()
      .replace(/^https?:\/\//, "")
      .replace(/\.cloudflareaccess\.com.*$/, "")
      .replace(/[^a-z0-9-]/g, "")
  }

  function register(team) {
    var t = cleanTeam(team)
    if (!t) { lastError = "Enter your company's Zero Trust team name."; return }
    lastError = ""
    changingTeam = false
    runInTerminal([script, "register", t])
  }

  function registerFree() {
    lastError = ""
    changingTeam = false
    runInTerminal([script, "register", ""])
  }

  function unregister() {
    if (!confirmUnregister) { confirmUnregister = true; confirmTimer.restart(); return }
    confirmUnregister = false
    quickProc.command = [script, "unregister"]
    quickProc.running = true
  }

  function toggleVpn() {
    if (stage !== "ready" || busy) return
    desired = !connected
    busy = true
    quickProc.command = [script, desired ? "connect" : "disconnect"]
    quickProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      lastError = ""
      refresh()
      Qt.callLater(function() {
        if (root.stage === "register") teamField.forceActiveFocus()
        else keyCatcher.forceActiveFocus()
      })
    } else {
      confirmUnregister = false
      changingTeam = false
    }
  }

  // ------------------------------------------------------------ processes

  Process {
    id: stateProc
    command: [root.script, "state"]
    stdout: StdioCollector {
      onStreamFinished: {
        var kv = ({})
        String(text).split("\n").forEach(function(line) {
          var i = line.indexOf("=")
          if (i > 0) kv[line.slice(0, i)] = line.slice(i + 1)
        })
        root.installed = kv.installed === "true"
        root.serviceUp = kv.service === "true"
        root.registered = kv.registered === "true"
        root.account = kv.account || ""
        root.organization = kv.organization || ""
        root.vpnStatus = kv.status || ""
        root.network = kv.network || ""
        root.reason = kv.reason || ""
        root.loaded = true
        if (root.busy && root.connected === root.desired) root.busy = false
      }
    }
  }

  Process {
    id: quickProc
    stderr: StdioCollector {
      onStreamFinished: {
        var t = String(text).trim()
        if (t !== "") root.lastError = t.split("\n").pop()
      }
    }
    onExited: settleTimer.restart()
  }

  Timer {
    id: settleTimer
    interval: 1000
    repeat: true
    property int tries: 0
    onRunningChanged: if (running) tries = 0
    onTriggered: {
      root.refresh()
      tries++
      if (!root.busy || tries > 15) { root.busy = false; stop() }
    }
  }

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirmUnregister = false
  }

  Timer {
    interval: root.opened || root.stage !== "ready" ? 2000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------ bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    dimmed: !root.connected
    tooltipText: root.opened ? "" : "WARP: " + root.statusText
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.toggleVpn()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(460))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.toggleVpn()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " " || t === "t" || t === "T") root.toggleVpn()
        else if (t === "r" || t === "R") root.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: "Cloudflare WARP"
          meta: root.statusText
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: root.glyph
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: vpnSwitch
              visible: root.stage === "ready"
              checked: root.switchOn
              busy: root.busy
              foreground: hero.foreground
              onToggled: root.toggleVpn()

              PanelToolTip {
                visible: vpnSwitch.containsMouse
                text: root.switchOn ? "Turn VPN off" : "Turn VPN on"
                fontFamily: hero.fontFamily
              }
            }
          }
        }

        // ---- not installed
        Column {
          visible: root.stage === "install"
          width: parent.width
          spacing: Style.space(10)

          Hint { text: "The Cloudflare WARP client isn't installed. It will be installed from the AUR (cloudflare-warp-bin) and its background service enabled. You'll be asked for your password in a terminal." }
          Button {
            width: parent.width
            iconText: "󰏗"
            text: "Install Cloudflare WARP"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.install()
          }
        }

        // ---- service stopped
        Column {
          visible: root.stage === "service"
          width: parent.width
          spacing: Style.space(10)

          Hint { text: "The WARP background service (warp-svc) isn't running." }
          Button {
            width: parent.width
            iconText: "󰐊"
            text: "Start WARP service"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.startService()
          }
        }

        // ---- registration
        Column {
          visible: root.stage === "register"
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "COMPANY / TEAM NAME"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Hint { text: "Your company's Cloudflare Zero Trust team name, the part before .cloudflareaccess.com. A browser window opens for your company login." }

          TextField {
            id: teamField
            width: parent.width
            placeholderText: "e.g. acme"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            foreground: root.foreground
            onAccepted: root.register(text)
            Keys.onEscapePressed: root.close()
          }

          Button {
            width: parent.width
            iconText: "󰌋"
            text: "Register with company"
            bordered: true
            enabled: root.cleanTeam(teamField.text) !== ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.register(teamField.text)
          }

          Button {
            width: parent.width
            iconText: "󰖟"
            text: "Use free WARP instead (no company)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.registerFree()
          }

          Button {
            visible: root.changingTeam
            width: parent.width
            text: "Cancel"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.changingTeam = false
          }
        }

        // ---- registered
        Column {
          visible: root.stage === "ready"
          width: parent.width
          spacing: Style.spacing.labelGap

          InfoPair { label: "Account"; value: root.account || "—" }
          InfoPair { visible: root.organization !== ""; label: "Team"; value: root.organization }
          InfoPair { visible: root.network !== ""; label: "Network"; value: root.network }
          InfoPair { visible: root.reason !== ""; label: "Reason"; value: root.reason }
        }

        PanelSeparator {
          visible: root.stage === "ready"
          foreground: root.foreground
        }

        Row {
          visible: root.stage === "ready"
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing) / 2
            iconText: "󰑐"
            text: "Change team"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: {
              root.changingTeam = true
              teamField.text = root.organization
              Qt.callLater(function() { teamField.forceActiveFocus(); teamField.selectAll() })
            }
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            iconText: "󰩺"
            text: root.confirmUnregister ? "Click to confirm" : "Unregister"
            active: root.confirmUnregister
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.unregister()
          }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component Hint: Text {
    width: parent.width
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: pairLabel
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item { width: Math.max(0, parent.width - pairLabel.implicitWidth - pairValue.implicitWidth - parent.spacing * 2); height: 1 }
    Text {
      id: pairValue
      textFormat: Text.PlainText
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
