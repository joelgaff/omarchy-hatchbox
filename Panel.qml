import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Hatchbox apps panel: one row per app across every account, with the
// latest deploy state read from the logs endpoint (last_deploy_at only
// moves on success). Rows carry deploy, restart, and view actions.
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
  property var pendingApps: []

  readonly property bool anyFailed: apps.some(function(row){ return row.failed })
  readonly property bool anyBusy: apps.some(function(row){ return row.busy })

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Failed rows must read as red. Monochrome themes set their red to the
  // foreground, which would hide a failure, so fall back to a fixed red.
  readonly property color failedColor: (Qt.colorEqual(Color.urgent, foreground) || Qt.colorEqual(Color.urgent, Color.foreground)) ? "#c0392b" : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 5), 10) || 5)
  readonly property string hideApps: String(setting("hideApps", ""))
  readonly property string apiBin: Qt.resolvedUrl("bin/hatchbox-api").toString().replace("file://", "")
  readonly property string tokenBin: Qt.resolvedUrl("bin/hatchbox-token").toString().replace("file://", "")

  // ---- Keyboard cursor over the app rows.
  property bool cursorActive: false
  property int appIndex: 0

  function moveCursor(dx, dy) {
    if (apps.length === 0) return
    cursorActive = true
    if (dy === 0) return
    appIndex = Math.max(0, Math.min(apps.length - 1, appIndex + dy))
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    appIndex = index
  }

  function cursorRow() {
    if (apps.length === 0) return null
    return apps[Math.max(0, Math.min(apps.length - 1, appIndex))]
  }

  function scrollCursorIntoView() {
    if (!appColumn || appIndex < 0 || appIndex >= appColumn.children.length) return
    var item = appColumn.children[appIndex]
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  // ---- Token setup. The form shows when the API reports no token, or on
  // demand via `t` / the setup IPC. The token goes to bin/hatchbox-token over
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

  // ---- Actions. Deploy and restart confirm first; view opens the dashboard.
  property var confirmRow: null
  property string confirmAction: ""
  readonly property bool confirmOpen: confirmRow !== null

  function askDeploy(row) {
    if (!row || row.busy) return
    confirmRow = row
    confirmAction = "deploy"
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function askRestart(row) {
    if (!row || row.busy) return
    confirmRow = row
    confirmAction = "restart"
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function closeConfirm() {
    confirmRow = null
    confirmAction = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function runConfirmed() {
    var row = confirmRow
    var action = confirmAction
    closeConfirm()
    if (!row || action === "") return
    if (actionProc.running) {
      error = "Still starting the previous action"
      return
    }
    error = ""
    actionProc.appId = row.id
    actionProc.appName = row.name
    actionProc.action = action
    actionProc.command = [apiBin, "POST", "/apps/" + row.id + "/" + action]
    actionProc.running = true
  }

  function viewApp(row) {
    if (!row) return
    Quickshell.execDetached(["xdg-open", row.dashboardUrl])
    close()
  }

  function activateCursor() {
    viewApp(cursorRow())
  }

  // ---- Open/close lifecycle, mirroring the weather plugin.
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
    if (root.confirmOpen) root.closeConfirm()
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

  onOpenedChanged: if (opened) {
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
  }

  // ---- Data: accounts, then apps per account, then deploy logs per app.
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
        root.pendingApps = []
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

  function fetchNextAccount() {
    if (accountCursor >= accounts.length) {
      apps = Model.mergeState(pendingApps, apps)
      pendingApps = []
      if (appIndex >= apps.length) appIndex = Math.max(0, apps.length - 1)
      updateTooltip()
      queueLogs(apps.map(function(row){ return row.id }))
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
        root.pendingApps = root.pendingApps.concat(rows)
        root.accountCursor += 1
        root.fetchNextAccount()
      }
    }
  }

  // One logs fetch at a time; rows update as each answer lands.
  property var logQueue: []

  function queueLogs(ids) {
    var next = logQueue.slice()
    ids.forEach(function(id){ if (next.indexOf(id) === -1) next.push(id) })
    logQueue = next
    pumpLogs()
  }

  function pumpLogs() {
    if (logsProc.running || logQueue.length === 0) return
    var id = logQueue[0]
    logQueue = logQueue.slice(1)
    logsProc.appId = id
    logsProc.command = [apiBin, "GET", "/apps/" + id + "/logs?limit=5"]
    logsProc.running = true
  }

  Process {
    id: logsProc
    property int appId: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.updateRow(logsProc.appId, Model.statePatch(Model.latestDeploy(raw)))
        Qt.callLater(root.pumpLogs)
      }
    }
  }

  function updateRow(appId, patch) {
    var next = apps.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i].id === appId) next[i] = Object.assign({}, next[i], patch)
    }
    apps = next
    updateTooltip()
  }

  function updateTooltip() {
    var failed = apps.filter(function(row){ return row.failed }).length
    var text = apps.length + (apps.length === 1 ? " app" : " apps")
    if (failed > 0) text += ", " + failed + " failed"
    tooltip = text
  }

  // While a deploy or restart is in flight, poll that app's logs.
  Timer {
    interval: 8000
    running: root.anyBusy
    repeat: true
    onTriggered: root.queueLogs(root.apps.filter(function(row){ return row.busy }).map(function(row){ return row.id }))
  }

  Process {
    id: actionProc
    property int appId: 0
    property string appName: ""
    property string action: ""
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.error = "Could not start " + actionProc.action + " for " + actionProc.appName
        return
      }
      root.updateRow(actionProc.appId, {
        state: "pending", stateAt: "", stateAgo: "just now", stateSha: "", stateDescription: "",
        failed: false, busy: true, isRestart: actionProc.action === "restart"
      })
      actionFollowUp.appId = actionProc.appId
      actionFollowUp.restart()
    }
  }

  Timer {
    id: actionFollowUp
    property int appId: 0
    interval: 2500
    onTriggered: root.queueLogs([appId])
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
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingToken || root.confirmOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "t" || t === "T") root.startEditingToken()
        else if ((t === "d" || t === "D") && root.cursorActive) root.askDeploy(root.cursorRow())
        else if ((t === "s" || t === "S") && root.cursorActive) root.askRestart(root.cursorRow())
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

          RowLayout {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: "Hatchbox"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              Layout.fillWidth: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.tooltip
              color: root.anyFailed ? root.failedColor : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            PanelActionButton {
              iconText: "󰌆"
              tooltipText: root.editingToken ? "Cancel" : "Change API token"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.editingToken ? root.cancelEditingToken() : root.startEditingToken()
            }
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

          // ---- App rows.
          Column {
            id: appColumn
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.apps
              AppRow {
                required property var modelData
                required property int index
                width: appColumn.width
                app: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: root.apps.length > 0
            textFormat: Text.PlainText
            text: "Enter view, d deploy, s restart, r refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Keys land here while a confirm is up, since the key catcher is blocked.
      Item {
        id: confirmKeys
        anchors.fill: parent
        visible: root.confirmOpen
        z: 10
        Keys.onPressed: function(event) {
          if (confirm.handleKey(event)) event.accepted = true
        }

        ConfirmDialog {
          id: confirm
          anchors.fill: parent
          opened: root.confirmOpen
          message: root.confirmRow
            ? (root.confirmAction === "deploy"
                ? "Deploy " + root.confirmRow.name + " from " + root.confirmRow.branch + "?"
                : "Restart " + root.confirmRow.name + "?")
            : ""
          confirmText: root.confirmAction === "deploy" ? "Deploy" : "Restart"
          background: Color.popups.background
          foreground: root.foreground
          selectedText: Color.accent
          fontFamily: root.fontFamily
          onCanceled: root.closeConfirm()
          onConfirmed: root.runConfirmed()
        }
      }
    }
  }

  component AppRow: CursorSurface {
    id: appRow
    property var app: null
    property int rowIndex: 0
    readonly property bool failed: app ? app.failed === true : false
    readonly property bool busy: app ? app.busy === true : false
    readonly property string stateText: Model.stateLabel(app)

    hasCursor: root.cursorActive && root.appIndex === rowIndex
    foreground: root.foreground

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(appRow.rowIndex)
      onClicked: root.viewApp(appRow.app)
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: appRow.app ? appRow.app.name : ""
          color: appRow.failed ? root.failedColor : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: appRow.app
            ? appRow.app.branch + " @ " + (appRow.app.sha || "no deploy")
              + (appRow.stateText !== "" ? "   " + appRow.stateText : "")
            : ""
          color: appRow.failed ? root.failedColor : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: appRow.busy
        textFormat: Text.PlainText
        text: "󰦖"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        RotationAnimator on rotation {
          running: appRow.busy
          from: 0; to: 360
          duration: 800
          loops: Animation.Infinite
        }
      }

      PanelActionButton {
        visible: !appRow.busy
        iconText: "󱓞"
        tooltipText: "Deploy " + (appRow.app ? appRow.app.branch : "")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.askDeploy(appRow.app)
      }

      PanelActionButton {
        visible: !appRow.busy
        iconText: "󰜉"
        tooltipText: "Restart"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.askRestart(appRow.app)
      }

      PanelActionButton {
        iconText: "󰏌"
        tooltipText: "Open in Hatchbox"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.viewApp(appRow.app)
      }
    }
  }
}
