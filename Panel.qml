import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button + popup listing every OpenVPN and WireGuard profile that
// NetworkManager knows about, each with its own on/off switch.
//
// Listing and switching go through the sibling `nm-vpn` script. Switching is
// detached, so a slow OpenVPN handshake survives a plugin hot-reload, and the
// script reports failures itself via notify-send. `nmcli monitor` drives
// refreshes so the bar follows changes made from anywhere else too.
Panel {
  id: root
  moduleName: "pointpack.nm-vpn"
  ipcTarget: "pointpack.nm-vpn"

  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("nm-vpn")).replace(/^file:\/\//, ""))
  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 30)))
  readonly property bool hideWhenEmpty: setting("hideWhenEmpty", false) === true

  property var connections: []
  property bool loaded: false
  // uuid -> { on: bool, at: ms }: the state the user asked for, shown until
  // NetworkManager catches up so the switch throws instantly.
  property var pending: ({})
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property var activeConnections: connections.filter(function(c) { return c.state === "activated" })
  readonly property bool anyActive: activeConnections.length > 0
  readonly property bool anyBusy: connections.some(function(c) { return root.isBusy(c) })
  readonly property bool shown: !(hideWhenEmpty && loaded && connections.length === 0)

  function isOn(c) {
    var p = pending[c.uuid]
    if (p) return p.on
    return c.state === "activated" || c.state === "activating"
  }

  function isBusy(c) {
    return !!pending[c.uuid] || c.state === "activating" || c.state === "deactivating"
  }

  function kindLabel(kind) {
    return kind === "wireguard" ? "WireGuard" : "OpenVPN"
  }

  function stateLabel(c) {
    var p = pending[c.uuid]
    if (p) return p.on ? "Connecting…" : "Disconnecting…"
    switch (c.state) {
    case "activated": return c.device ? "Connected · " + c.device : "Connected"
    case "activating": return "Connecting…"
    case "deactivating": return "Disconnecting…"
    default: return "Disconnected"
    }
  }

  function toggleConnection(c) {
    if (!c) return
    var on = !isOn(c)
    var next = Object.assign({}, pending)
    next[c.uuid] = { on: on, at: Date.now() }
    pending = next
    Quickshell.execDetached([root.scriptPath, on ? "up" : "down", c.uuid])
  }

  function refresh() {
    if (listProc.running) refreshAgain.restart()
    else listProc.running = true
  }

  function update(raw) {
    var list
    try { list = JSON.parse(raw) } catch (e) { return }
    if (!Array.isArray(list)) return

    // Drop a pending request once NetworkManager agrees with it, or once it
    // is old enough that the attempt has clearly ended (failed or cancelled).
    var now = Date.now()
    var next = {}
    for (var uuid in pending) {
      var p = pending[uuid]
      var c = list.find(function(x) { return x.uuid === uuid })
      if (!c) continue
      var settled = p.on ? c.state === "activated" || c.state === "activating"
                         : c.state === "" || c.state === "deactivating"
      if (!settled && now - p.at < 8000) next[uuid] = p
    }
    pending = next
    connections = list
    loaded = true
    if (cursorIndex >= list.length) cursorIndex = Math.max(0, list.length - 1)
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      cursorIndex = 0
    }
  }

  Component.onCompleted: refresh()

  Process {
    id: listProc
    command: [root.scriptPath, "list"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.update(text) }
  }

  // Coalesce bursts of monitor events (one activation emits several lines).
  Timer { id: debounce; interval: 250; onTriggered: root.refresh() }
  Timer { id: refreshAgain; interval: 300; onTriggered: root.refresh() }

  Process {
    id: monitorProc
    running: true
    command: ["nmcli", "monitor"]
    stdout: SplitParser { onRead: debounce.restart() }
    onExited: monitorRestart.start()
  }
  Timer { id: monitorRestart; interval: 5000; onTriggered: monitorProc.running = true }

  // Fallback poll, plus a faster one while something is in flight so pending
  // switches expire even if the monitor misses the final event.
  Timer {
    interval: root.anyBusy ? 2000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.anyActive ? "󰦝" : "󰦞"
    active: root.anyActive
    tooltipText: root.opened ? "" : (root.anyActive
      ? "VPN: " + root.activeConnections.map(function(c) { return c.name }).join(", ")
      : "VPN: disconnected")
    onPressed: function(b) {
      if (b === Qt.RightButton) Quickshell.execDetached(["nm-connection-editor"])
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
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.connections.length === 0) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        var delta = dy !== 0 ? dy : dx
        root.cursorIndex = Math.max(0, Math.min(root.connections.length - 1, root.cursorIndex + delta))
      }
      onActivateRequested: if (root.cursorActive) root.toggleConnection(root.connections[root.cursorIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: button.text
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "VPN"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: (root.anyActive
                ? root.activeConnections.length + " connected"
                : "Not connected").toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "CONNECTIONS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            visible: root.loaded && root.connections.length === 0
            width: parent.width
            text: "No OpenVPN or WireGuard connections are configured in NetworkManager. Right-click the bar icon to open the connection editor."
            wrapMode: Text.Wrap
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.connections

            Toggle {
              required property var modelData
              required property int index
              width: parent.width
              label: modelData.name
              description: root.kindLabel(modelData.kind) + " · " + root.stateLabel(modelData)
              checked: root.isOn(modelData)
              opacity: root.isBusy(modelData) ? 0.7 : 1
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === index
              onClicked: root.toggleConnection(modelData)
              onHovered: function(h) {
                if (h) {
                  root.cursorActive = true
                  root.cursorIndex = index
                }
              }
            }
          }
        }
      }
    }
  }
}
