import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Cloudflare WARP in the bar. One panel walks the whole lifecycle:
//   not installed -> install          (floating terminal, AUR + sudo)
//   service off   -> start service    (floating terminal, sudo)
//   unregistered  -> Zero Trust team login in the browser, or free WARP
//   registered    -> on/off, mode, virtual networks, local network access,
//                    split tunnel routes, change team / unregister
Panel {
  id: root
  moduleName: "coding-sparrow.cloudflare-warp"
  ipcTarget: "coding-sparrow.cloudflare-warp"
  manageIpc: false

  property string cursorKey: ""
  property bool cursorActive: false
  property bool changingTeam: false
  property bool confirmUnregister: false

  readonly property string glyph: ""
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: warp.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property var warpState: warp.warpState
  readonly property string panelStage: warp.stage === "ready" && (changingTeam || warp.registering) ? "register" : warp.stage
  readonly property var navKeys: Model.navKeys(panelStage, warpState, {
    registering: warp.registering,
    hasLoginUrl: warp.loginUrl !== "",
    changingTeam: changingTeam
  })
  readonly property string heroMeta: {
    var parts = [warp.statusText]
    if (warp.stage === "ready" && warp.edgeSummary !== "") parts.push(warp.edgeSummary)
    return parts.join(" · ")
  }
  readonly property string toggleHint: warpState.switchLocked ? "Your organization keeps WARP on" : (warp.active ? "Turn WARP off" : "Turn WARP on")

  function hasCursor(key) {
    return cursorActive && cursorKey === key
  }

  function setCursor(key) {
    cursorActive = true
    cursorKey = key
  }

  function ensureCursor() {
    if (navKeys.indexOf(cursorKey) === -1) cursorKey = navKeys.length > 0 ? navKeys[0] : ""
  }

  function moveCursor(dy) {
    if (!cursorActive) {
      cursorActive = true
      ensureCursor()
    } else {
      cursorKey = Model.moveKey(navKeys, cursorKey, dy)
    }
    if (cursorKey === "team") teamField.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
    scrollCursorIntoView()
  }

  function activate(key) {
    if (key === "toggle") warp.toggle()
    else if (key === "install") { warp.install(); root.close() }
    else if (key === "start-service") { warp.startService(); root.close() }
    else if (key === "team") teamField.forceActiveFocus()
    else if (key === "register-team") registerTeam()
    else if (key === "register-free") { changingTeam = false; warp.register("") }
    else if (key === "open-login") warp.openLoginUrl()
    else if (key === "cancel") cancelRegister()
    else if (key === "proxy") warp.copyToClipboard(warp.proxyAddress, "proxy address")
    else if (key === "local-network") warp.toggleLocalNetwork()
    else if (key === "change-team") startChangingTeam()
    else if (key === "unregister") unregister()
    else if (key.indexOf("mode:") === 0) warp.setMode(key.slice(5))
    else if (key.indexOf("vnet:") === 0) warp.setVnet(key.slice(5))
    else if (key.indexOf("route:") === 0) {
      var route = warpState.splitTunnelRoutes[parseInt(key.slice(6), 10)]
      if (route) warp.copyToClipboard(route.value)
    }
  }

  function registerTeam() {
    var team = warp.cleanTeamName(teamField.text)
    if (team === "") {
      warp.lastError = "Enter your organization's Zero Trust team name."
      teamField.forceActiveFocus()
      return
    }
    changingTeam = false
    warp.register(team)
  }

  function cancelRegister() {
    changingTeam = false
    warp.cancelRegistration()
    keyCatcher.forceActiveFocus()
  }

  function startChangingTeam() {
    changingTeam = true
    teamField.text = warpState.zeroTrust ? warpState.organization : ""
    setCursor("team")
    Qt.callLater(function() { teamField.forceActiveFocus(); teamField.selectAll() })
  }

  function unregister() {
    if (!confirmUnregister) {
      confirmUnregister = true
      confirmTimer.restart()
      return
    }
    confirmUnregister = false
    warp.unregister()
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      var item = rowFor(column, cursorKey)
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function rowFor(item, key) {
    if (!item) return null
    if (item.rowKey === key && item.visible) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = rowFor(children[i], key)
      if (found) return found
    }
    return null
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      warp.lastError = ""
      if (panelFlick) panelFlick.contentY = 0
      warp.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      teamFocusTimer.restart()
    } else {
      changingTeam = false
      confirmUnregister = false
    }
  }
  onNavKeysChanged: if (cursorActive) ensureCursor()

  Service {
    id: warp
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { warp.refresh(); return "ok" }
    function connect(): string { warp.connect(); return "ok" }
    function disconnect(): string { warp.disconnect(); return "ok" }
    function toggleWarp(): string { warp.toggle(); return "ok" }
    function status(): string { return warp.statusText }
  }

  // The panel window takes keyboard focus a moment after it opens and hands
  // it to the key catcher, so the team field is focused once that settles.
  Timer {
    id: teamFocusTimer
    interval: 150
    onTriggered: {
      if (!root.opened || root.panelStage !== "register" || warp.registering) return
      root.setCursor("team")
      teamField.forceActiveFocus()
    }
  }

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirmUnregister = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    foreground: root.barIconColor
    tooltipText: root.opened ? "" : "Cloudflare WARP: " + warp.statusText
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) warp.toggle()
      else if (buttonCode === Qt.MiddleButton) warp.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: {
        if (root.cursorActive) root.activate(root.cursorKey)
        else root.activate(root.panelStage === "ready" ? "toggle" : (root.navKeys[0] || ""))
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = t.toLowerCase()
        if (key === "t") warp.toggle()
        else if (key === "r") warp.refresh()
        else if (key === "c" && root.cursorKey.indexOf("route:") === 0) root.activate(root.cursorKey)
        else if (key === "p" && warp.warpState.mode === "proxy") root.activate("proxy")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // The hero's trailingControl resolves `root` to PanelHero, so it
            // reaches panel state through `header`.
            readonly property bool ringVisible: root.hasCursor("toggle")
            function focusToggle() { root.setCursor("toggle") }

            PanelHero {
              id: hero
              width: parent.width
              title: warp.warpState.zeroTrust && warp.warpState.organization !== "" ? warp.warpState.organization : "Cloudflare WARP"
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: warp.active ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  text: root.glyph
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: warp.stage === "ready" && root.panelStage === "ready"
                  checked: warp.active
                  busy: warp.busy
                  interactive: !warp.warpState.switchLocked
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusToggle() }
                  onToggled: warp.toggle()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: warp.lastError !== "" ? warp.lastError : warp.actionStatus
            color: warp.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------------------------------------------------- not installed
          Column {
            visible: root.panelStage === "install"
            width: parent.width
            spacing: Style.space(8)

            Hint { text: "The Cloudflare WARP client isn't installed. Installing it adds cloudflare-warp-bin from the AUR and enables its background service; a terminal opens to ask for your password." }
            ActionRow { rowKey: "install"; icon: "󰏔"; label: "Install Cloudflare WARP" }
          }

          // ---------------------------------------------------- service off
          Column {
            visible: root.panelStage === "service"
            width: parent.width
            spacing: Style.space(8)

            Hint { text: "The WARP background service (warp-svc) isn't running. Starting it opens a terminal to ask for your password." }
            ActionRow { rowKey: "start-service"; icon: "󰐊"; label: "Start the WARP service" }
          }

          // ---------------------------------------------------- registration
          Column {
            visible: root.panelStage === "register"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "ZERO TRUST TEAM"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Hint { text: "Your organization's team name: the part before .cloudflareaccess.com. Its login page opens in your browser." }

            TextField {
              id: teamField
              width: parent.width
              placeholderText: "e.g. acme"
              enabled: !warp.registering
              hasCursor: root.hasCursor("team")
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onActiveFocusChanged: if (activeFocus) root.setCursor("team")
              onAccepted: root.registerTeam()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  if (root.changingTeam || warp.registering) root.cancelRegister()
                  else root.close()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  root.moveCursor(1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  root.switchPanel(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
                  event.accepted = true
                }
              }
            }

            ActionRow {
              rowKey: "register-team"
              icon: "󰍂"
              label: warp.registering ? "Waiting for the browser login…" : "Sign in with your team"
              enabled: !warp.registering && warp.cleanTeamName(teamField.text) !== ""
            }
            ActionRow {
              rowKey: "register-free"
              icon: "󰖟"
              label: "Use free WARP instead"
              detail: "No organization: 1.1.1.1 with WARP"
              enabled: !warp.registering
            }
            ActionRow {
              rowKey: "open-login"
              visible: warp.registering && warp.loginUrl !== ""
              icon: "󰏌"
              label: "Open the login page again"
            }
            ActionRow {
              rowKey: "cancel"
              visible: warp.registering || root.changingTeam
              icon: "󰅖"
              label: "Cancel"
            }
          }

          // ---------------------------------------------------- connected
          Column {
            visible: root.panelStage === "ready"
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair { label: "Account"; value: warp.accountLabel }
            InfoPair { label: "Mode"; value: warp.modeLabel(warp.warpState.mode) + (warp.warpState.modeLocked ? " (set by your organization)" : "") }
            InfoPair { visible: warp.warpState.reason !== ""; label: "Network"; value: warp.warpState.reason }
            InfoPair { visible: warp.warpState.connected && warp.warpState.protocol !== ""; label: "Protocol"; value: warp.warpState.protocol }
            InfoPair {
              visible: warp.warpState.connected && (warp.warpState.bytesSent > 0 || warp.warpState.bytesReceived > 0)
              label: "Traffic"
              value: "↑ " + warp.formatBytes(warp.warpState.bytesSent) + "   ↓ " + warp.formatBytes(warp.warpState.bytesReceived)
            }
          }

          Section {
            visible: root.panelStage === "ready" && !warp.warpState.modeLocked
            title: "MODE"

            Repeater {
              model: warp.modes
              ActionRow {
                required property var modelData
                readonly property bool selected: warp.warpState.mode === modelData.id
                rowKey: "mode:" + modelData.id
                icon: selected ? "󰐾" : "󰐽"
                label: modelData.label
                detail: modelData.detail
                current: selected
                compact: true
              }
            }
          }

          Section {
            visible: root.panelStage === "ready" && warp.warpState.mode === "proxy"
            title: "PROXY"

            ActionRow {
              rowKey: "proxy"
              icon: "󰆏"
              label: warp.proxyAddress
              detail: "Point apps at this to send them through WARP"
            }
          }

          Section {
            visible: root.panelStage === "ready" && warp.warpState.vnets.length > 1
            title: "VIRTUAL NETWORKS"

            Repeater {
              model: warp.warpState.vnets
              ActionRow {
                required property var modelData
                rowKey: "vnet:" + modelData.id
                icon: modelData.active ? "󰐾" : "󰐽"
                label: modelData.name + (modelData.isDefault ? " (default)" : "")
                detail: modelData.description
                current: modelData.active
                compact: true
              }
            }
          }

          Section {
            visible: root.panelStage === "ready" && warp.warpState.zeroTrust
            title: "LOCAL NETWORK"

            ActionRow {
              rowKey: "local-network"
              icon: "󰌗"
              label: warp.warpState.localNetworkAllowed ? "Stop local network access" : "Allow local network access"
              detail: warp.warpState.localNetworkAllowed
                ? (warp.warpState.localNetworkEndsInSecs > 0 ? "Ends in " + Math.ceil(warp.warpState.localNetworkEndsInSecs / 60) + " min" : "Allowed")
                : "Reach printers, NAS and dev boxes on this LAN, if your policy permits"
              current: warp.warpState.localNetworkAllowed
            }
          }

          Section {
            visible: root.panelStage === "ready" && warp.warpState.splitTunnelRoutes.length > 0
            title: "SPLIT TUNNEL · " + (warp.warpState.splitTunnelMode === "include" ? "ONLY THESE GO THROUGH WARP" : "THESE BYPASS WARP")

            Repeater {
              model: warp.warpState.splitTunnelRoutes
              ActionRow {
                required property var modelData
                required property int index
                rowKey: "route:" + index
                icon: "󰑪"
                label: modelData.value
                detail: modelData.description
                compact: true
                trailingIcon: "󰆏"
              }
            }
          }

          PanelSeparator {
            visible: root.panelStage === "ready"
            foreground: root.foreground
          }

          Column {
            visible: root.panelStage === "ready"
            width: parent.width
            spacing: Style.space(6)

            ActionRow {
              rowKey: "change-team"
              icon: "󰀙"
              label: warp.warpState.zeroTrust ? "Change Zero Trust team" : "Join a Zero Trust team"
              compact: true
            }
            ActionRow {
              rowKey: "unregister"
              icon: "󰌸"
              label: root.confirmUnregister ? "Press again to unregister this device" : "Unregister this device"
              compact: true
              current: root.confirmUnregister
            }
          }
        }
      }
    }
  }

  component Hint: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  component Section: Column {
    property string title: ""
    default property alias rows: sectionRows.data

    width: parent ? parent.width : 0
    spacing: Style.space(8)

    PanelSectionHeader {
      text: parent.title
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Column {
      id: sectionRows
      width: parent.width
      spacing: Style.space(4)
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)

    Text {
      id: pairLabel
      anchors.left: parent.left
      textFormat: Text.PlainText
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: pairValue
      anchors.right: parent.right
      width: Math.min(implicitWidth, parent.width - pairLabel.implicitWidth - Style.space(12))
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property string rowKey: ""
    property string icon: ""
    property string label: ""
    property string detail: ""
    property string trailingIcon: ""
    property bool compact: false

    width: parent ? parent.width : 0
    hasCursor: root.hasCursor(rowKey)
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    opacity: enabled ? 1.0 : 0.45
    implicitHeight: actionContent.implicitHeight + (compact ? Style.spacing.lg : Style.spacing.rowPaddingX)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: actionRow.enabled
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(actionRow.rowKey)
      onClicked: root.activate(actionRow.rowKey)
    }

    RowLayout {
      id: actionContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        visible: actionRow.icon !== ""
        text: actionRow.icon
        textFormat: Text.PlainText
        color: actionRow.hasCursor || actionRow.current ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.preferredWidth: Style.space(20)
        horizontalAlignment: Text.AlignHCenter
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: actionRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: actionRow.compact ? Style.font.bodySmall : Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: actionRow.detail !== ""
          textFormat: Text.PlainText
          text: actionRow.detail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: actionRow.trailingIcon !== "" && actionRow.hasCursor
        text: actionRow.trailingIcon
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

}
