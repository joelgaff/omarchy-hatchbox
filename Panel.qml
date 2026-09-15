import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// First-check panel: fetch accounts, then apps per account, render one row each.
// No actions yet. Tier 1 buttons hang off the row once this renders real data.
Panel {
  id: root
  moduleName: "joelgaff.hatchbox"
  ipcTarget: "joelgaff.hatchbox"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar identifies this panel by the widget mounted in its slot
  // (BarWidget.qml), not by this nested panel. See the weather plugin.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property string label: "󰏗"
  property string tooltip: "Hatchbox"
  property string error: ""
  property var apps: []
  property var accounts: []
  property int accountCursor: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 5), 10) || 5)
  readonly property string hideApps: String(setting("hideApps", ""))
  readonly property string apiBin: Qt.resolvedUrl("bin/hatchbox-api").toString().replace("file://", "")
  readonly property string tokenBin: Qt.resolvedUrl("bin/hatchbox-token").toString().replace("file://", "")

  // Token setup. The form shows when the API reports no token, or on demand
  // via `t` / the setup IPC. The token goes to bin/hatchbox-token over
  // stdin, never argv or shell.json, and never through an IPC payload.
  property bool needsToken: false
  property bool editingToken: false
  property bool savingToken: false
  property string tokenError: ""

  function startEditingToken() {
    editingToken = true
    savingToken = false
    tokenError = ""
    Qt.callLater(function() {
      tokenField.text = ""
      tokenField.forceActiveFocus()
    })
  }

  function cancelEditingToken() {
    editingToken = false
    savingToken = false
    tokenField.text = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitToken() {
    var value = tokenField.text.replace(/\s+/g, "")
    if (value === "") {
      tokenError = "Paste a token first"
      return
    }
    savingToken = true
    tokenError = ""
    tokenSaveProc.secret = value
    tokenField.text = ""
    tokenSaveProc.running = true
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    refresh()
    // Set after showing: the popout coordinator closes whichever panel was
    // open, and that close clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingToken) root.cancelEditingToken()
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

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    error = ""
    needsToken = false
    accountsProc.running = false
    accountsProc.running = true
  }

  Process {
    id: accountsProc
    command: [root.apiBin, "GET", "/accounts"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          if (!Array.isArray(parsed)) throw new Error("not an array")
          root.accounts = parsed
        } catch (e) {
          if (root.error === "") root.error = "Could not read accounts"
          return
        }
        root.apps = []
        root.accountCursor = 0
        root.fetchNextAccount()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "")
        if (err.indexOf("No Hatchbox token") >= 0) {
          root.error = "No API token configured"
          root.needsToken = true
          if (root.opened && !root.editingToken) root.startEditingToken()
          return
        }
        var status = err.trim().match(/(\d{3})\s*$/)
        if (status && status[1] === "401") {
          root.error = "Hatchbox rejected the token"
          root.needsToken = true
        } else if (status && status[1].charAt(0) !== "2") {
          root.error = "Hatchbox returned HTTP " + status[1]
        } else if (!status && err.trim() !== "") {
          root.error = "Could not reach Hatchbox"
        }
      }
    }
  }

  Process {
    id: tokenSaveProc
    property string secret: ""
    command: [root.tokenBin, "set"]
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      root.savingToken = false
      if (exitCode !== 0) {
        root.tokenError = "Could not save the token"
        return
      }
      root.editingToken = false
      root.needsToken = false
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      root.refresh()
    }
  }

  function fetchNextAccount() {
    if (accountCursor >= accounts.length) {
      tooltip = apps.length + (apps.length === 1 ? " app" : " apps")
      return
    }
    appsProc.accountName = String(accounts[accountCursor].name || "")
    appsProc.command = [apiBin, "GET", "/accounts/" + accounts[accountCursor].id + "/apps"]
    appsProc.running = true
  }

  Process {
    id: appsProc
    property string accountName: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = Model.parseApps(String(text || ""), appsProc.accountName, root.hideApps)
        root.apps = root.apps.concat(rows)
        root.accountCursor += 1
        root.fetchNextAccount()
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function setup(): void { root.openFromHotkey(); root.startEditingToken() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingToken
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "t" || t === "T") root.startEditingToken()
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
          spacing: Style.spacing.sm

          Text {
            textFormat: Text.PlainText
            text: "Hatchbox"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            visible: root.error !== "" && !(root.editingToken && root.needsToken)
            textFormat: Text.PlainText
            text: root.error
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---- Token setup form.
          Column {
            visible: root.editingToken
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: "Paste your Hatchbox API token and press Enter"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              text: "Create one at hatchbox.io/api_tokens. It is stored in ~/.config/omarchy/hatchbox.json with mode 600."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              TextField {
                id: tokenField
                width: parent.width - saveHint.width - parent.spacing
                enabled: !root.savingToken
                password: true
                placeholderText: "API token"
                foreground: root.foreground
                font.family: root.fontFamily

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.cancelEditingToken()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.commitToken()
                    event.accepted = true
                  }
                }
              }

              Text {
                id: saveHint
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.savingToken ? "Saving" : "Esc cancels"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              visible: root.tokenError !== ""
              textFormat: Text.PlainText
              text: root.tokenError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            visible: root.needsToken && !root.editingToken
            textFormat: Text.PlainText
            text: "Press t to paste a token"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.error === "" && root.apps.length === 0
            textFormat: Text.PlainText
            text: "Loading apps"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Repeater {
            model: root.apps

            RowLayout {
              required property var modelData
              width: column.width
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                text: modelData.name
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                Layout.preferredWidth: Style.space(160)
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.branch + " @ " + modelData.sha
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                Layout.fillWidth: true
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.lastDeployAgo
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }
  }
}
