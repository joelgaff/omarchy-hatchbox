import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Particles
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Hatchbox apps panel: one row per app across every account, with the
// latest deploy state read from the logs endpoint (last_deploy_at only
// moves on success). Rows carry deploy, restart, and view actions.
//
// Data flow: /accounts, then /accounts/:id/apps per account, then
// /apps/:id/logs per app, one process at a time. Every fetch is tagged
// with the refresh generation it started under, so a refresh that lands
// mid-walk cannot mix results from two walks. A failed fetch keeps the
// previous rows and reports the failure instead of dropping rows.
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

  property string tooltip: "Hatchbox"
  property string error: ""
  property var apps: []
  property var accounts: []
  property int accountCursor: 0
  property var pendingApps: []
  property int generation: 0

  readonly property bool anyFailed: apps.some(function(row){ return row.failed })
  readonly property bool anyBusy: apps.some(function(row){ return row.busy })
  readonly property bool loading: accountsProc.running || appsProc.running || logsProc.running || logQueue.length > 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  // Failed rows must read as red. Themes whose "red" is not actually red
  // (see Model.failedColor) get a fixed red picked for the background.
  readonly property color failedColor: Model.failedColor(Color.urgent.toString(), foreground.toString(), Color.background.toString())
  // A job in progress gets a popping colour on its glyph: the theme accent
  // when it stands out, else a fixed orange (see Model.busyColor).
  readonly property color busyColor: Model.busyColor(Color.accent.toString(), foreground.toString(), Color.background.toString())
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 5), 10) || 5)
  readonly property string hideApps: String(setting("hideApps", ""))
  readonly property string sortBy: String(setting("sortBy", "Most recent deploy"))
  onSortByChanged: resortApps()
  readonly property string apiBin: Qt.resolvedUrl("bin/hatchbox-api").toString().replace("file://", "")
  readonly property string tokenBin: Qt.resolvedUrl("bin/hatchbox-token").toString().replace("file://", "")

  // Give up on a busy row after this long without a settled log, so a lost
  // job cannot keep the poll timer running forever.
  readonly property int busyTimeoutMs: 30 * 60 * 1000

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

  // ---- Settings section, toggled by the gear in the header. Sort order is
  // persisted to the widget's shell.json entry the way the clock panel does
  // it: applied locally first, then written through the bar's shell.
  property bool settingsOpen: false

  function toggleSettings() {
    settingsOpen = !settingsOpen
    if (!settingsOpen && editingToken) cancelEditingToken()
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setSortBy(value) {
    if (value === sortBy) return
    persistSettings({ sortBy: value })
  }

  // ---- Token setup. The form opens when the API reports a missing or
  // rejected token, once per problem (dismissing it with Esc keeps it shut
  // until the next save), or on demand via the key button, `t`, or the
  // setup IPC. The token goes to bin/hatchbox-token over stdin, never argv
  // or shell.json, and never through an IPC payload.
  property bool needsToken: false
  property bool editingToken: false
  property bool savingToken: false
  property bool tokenPromptDismissed: false
  property string tokenError: ""

  function promptForToken() {
    needsToken = true
    if (opened && !editingToken && !tokenPromptDismissed) startEditingToken()
  }

  function startEditingToken() {
    settingsOpen = true
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
    tokenPromptDismissed = true
    tokenField.text = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function toggleEditingToken() {
    if (editingToken) cancelEditingToken()
    else startEditingToken()
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
    root.settingsOpen = false
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

  // A bar surface exists per monitor, and each has its own copy of this
  // panel. User-driven refreshes go through the host widget so every
  // screen reloads, not only the one that took the click.
  function refreshAll() {
    if (hostWidget && typeof hostWidget.refresh === "function") hostWidget.refresh()
    else refresh()
  }

  function refresh() {
    generation += 1
    error = ""
    needsToken = false
    logQueue = []
    accountsProc.running = false
    appsProc.running = false
    logsProc.running = false
    accountsProc.running = true
  }

  Process {
    id: accountsProc
    property int startedGeneration: 0
    command: [root.apiBin, "GET", "/accounts"]
    onStarted: startedGeneration = root.generation
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (startedGeneration !== root.generation) return
      var err = String(stderr.text || "")
      if (exitCode !== 0) {
        root.error = Model.describeFailure(err, "accounts")
        if (err.indexOf("No Hatchbox token") >= 0 || Model.httpStatus(err) === "401") root.promptForToken()
        return
      }
      try {
        var parsed = JSON.parse(String(stdout.text || "").trim())
        if (!Array.isArray(parsed)) throw new Error("not an array")
        root.accounts = parsed
      } catch (e) {
        root.error = "Could not read accounts"
        return
      }
      root.pendingApps = []
      root.accountCursor = 0
      root.fetchNextAccount()
    }
  }

  function fetchNextAccount() {
    if (accountCursor >= accounts.length) {
      apps = Model.sortApps(Model.mergeState(pendingApps, apps), sortBy)
      pendingApps = []
      if (appIndex >= apps.length) appIndex = Math.max(0, apps.length - 1)
      updateTooltip()
      queueLogs(apps.map(function(row){ return { appId: row.id, logId: row.actionLogId } }))
      return
    }
    appsProc.accountName = Model.safeText(accounts[accountCursor].name)
    appsProc.command = [apiBin, "GET", "/accounts/" + accounts[accountCursor].id + "/apps"]
    appsProc.running = true
  }

  Process {
    id: appsProc
    property int startedGeneration: 0
    property string accountName: ""
    onStarted: startedGeneration = root.generation
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (startedGeneration !== root.generation) return
      if (exitCode !== 0) {
        // Keep the rows from the last good walk rather than dropping an account.
        root.error = Model.describeFailure(String(stderr.text || ""), "apps for " + appsProc.accountName)
        root.pendingApps = []
        return
      }
      root.pendingApps = root.pendingApps.concat(Model.parseApps(String(stdout.text || ""), root.hideApps))
      root.accountCursor += 1
      root.fetchNextAccount()
    }
  }

  // One logs fetch at a time; rows update as each answer lands. An entry
  // with a logId polls that job directly (GET /logs/:id); otherwise the
  // app's recent log list is read.
  property var logQueue: []

  function queueLogs(entries) {
    var next = logQueue.slice()
    entries.forEach(function(entry) {
      var dup = next.some(function(q){ return q.appId === entry.appId && q.logId === entry.logId })
      if (!dup) next.push(entry)
    })
    logQueue = next
    pumpLogs()
  }

  // Re-sort once a sweep has drained, keeping the cursor on the same app.
  function resortApps() {
    var row = cursorActive ? cursorRow() : null
    apps = Model.sortApps(apps, sortBy)
    if (row) {
      for (var i = 0; i < apps.length; i++) if (apps[i].id === row.id) { appIndex = i; break }
    }
  }

  function pumpLogs() {
    if (logsProc.running) return
    if (logQueue.length === 0) { resortApps(); return }
    var entry = logQueue[0]
    logQueue = logQueue.slice(1)
    logsProc.appId = entry.appId
    logsProc.logId = entry.logId || 0
    logsProc.command = [apiBin, "GET", logsProc.logId ? "/logs/" + logsProc.logId : "/apps/" + entry.appId + "/logs?limit=5"]
    logsProc.running = true
  }

  Process {
    id: logsProc
    property int startedGeneration: 0
    property int appId: 0
    property int logId: 0
    onStarted: startedGeneration = root.generation
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (startedGeneration !== root.generation) return
      // A failed fetch leaves the row as it was; a red or busy row must not
      // turn plain because one poll got throttled.
      if (exitCode === 0) {
        var raw = String(stdout.text || "").trim()
        var row = root.rowById(logsProc.appId)
        if (raw !== "" && row) {
          if (logsProc.logId) {
            var log = Model.parseLog(raw)
            if (log) root.updateRow(logsProc.appId, Model.statePatch(log))
          } else {
            var entry = Model.pickActivity(raw, row.actionLogId)
            if (entry !== undefined) root.updateRow(logsProc.appId, Model.statePatch(entry))
          }
        }
      }
      Qt.callLater(root.pumpLogs)
    }
  }

  function rowById(appId) {
    for (var i = 0; i < apps.length; i++) if (apps[i].id === appId) return apps[i]
    return null
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
    var busy = apps.filter(function(row){ return row.busy }).length
    var text = apps.length + (apps.length === 1 ? " app" : " apps")
    if (busy > 0) text += ", " + busy + " deploying"
    if (failed > 0) text += ", " + failed + " failed"
    tooltip = text
  }

  // While a deploy or restart is in flight, poll it.
  Timer {
    interval: 8000
    running: root.anyBusy
    repeat: true
    onTriggered: {
      var now = Date.now()
      var due = []
      root.apps.forEach(function(row) {
        if (!row.busy) return
        if (row.busySince && now - row.busySince > root.busyTimeoutMs) {
          root.updateRow(row.id, { busy: false, actionLogId: 0, busySince: 0 })
          return
        }
        due.push({ appId: row.id, logId: row.actionLogId })
      })
      root.queueLogs(due)
    }
  }

  Process {
    id: actionProc
    property int appId: 0
    property string appName: ""
    property string action: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.error = Model.describeFailure(String(stderr.text || ""), actionProc.action + " for " + actionProc.appName)
        return
      }
      // The response is {"id": N}, the log to poll for this job.
      var logId = 0
      try { logId = Number(JSON.parse(String(stdout.text || "").trim()).id) || 0 } catch (e) {}
      root.updateRow(actionProc.appId, {
        state: "pending", stateAt: new Date().toISOString(), stateAgo: "just now", isRestart: actionProc.action === "restart",
        failed: false, busy: true, actionLogId: logId, busySince: Date.now()
      })
      actionFollowUp.appId = actionProc.appId
      actionFollowUp.logId = logId
      actionFollowUp.restart()
    }
  }

  Timer {
    id: actionFollowUp
    property int appId: 0
    property int logId: 0
    interval: 2500
    onTriggered: root.queueLogs([{ appId: appId, logId: logId }])
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
      root.tokenPromptDismissed = false
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      root.refreshAll()
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
    function refresh(): void { root.refreshAll() }
    function setup(): void { root.openFromHotkey(); root.startEditingToken() }
    function settings(): void { root.openFromHotkey(); root.settingsOpen = true }
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
        if (t === "r" || t === "R") root.refreshAll()
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
              color: root.anyFailed ? root.failedColor : (root.anyBusy ? root.busyColor : root.dim)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            PanelActionButton {
              id: refreshButton
              // The glyph is drawn below so only it spins; the button's hover
              // fill stays square and still.
              iconText: ""
              tooltipText: "Refresh (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refreshAll()

              Text {
                id: refreshGlyph
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "󰑐"
                color: refreshButton._hot ? refreshButton.hoverColor : root.foreground
                font.family: root.fontFamily
                font.pixelSize: refreshButton.fontSize
                transformOrigin: Item.Center

                RotationAnimator on rotation {
                  running: root.loading
                  from: 0; to: 360
                  duration: 900
                  loops: Animation.Infinite
                  onRunningChanged: if (!running) refreshGlyph.rotation = 0
                }
              }
            }
            PanelActionButton {
              iconText: "󰒓"
              tooltipText: root.settingsOpen ? "Close settings" : "Settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleSettings()
            }
          }

          Text {
            visible: root.error !== "" && !(root.editingToken && root.needsToken)
            textFormat: Text.PlainText
            text: root.error
            color: root.failedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            width: parent.width
            wrapMode: Text.WordWrap
          }

          // ---- Settings section: sort order and the API token.
          Column {
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Style.spacing.lg

              Text {
                textFormat: Text.PlainText
                text: "Sort apps by"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.preferredWidth: Style.space(130)
              }
              ButtonGroup {
                Layout.fillWidth: true
                options: ["Most recent deploy", "Name"]
                value: root.sortBy
                focusable: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) { root.setSortBy(value) }
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.spacing.lg
              visible: !root.editingToken

              Text {
                textFormat: Text.PlainText
                text: "API token"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.preferredWidth: Style.space(130)
              }
              Button {
                text: root.needsToken ? "Paste a token" : "Replace token"
                iconText: "󰌆"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.startEditingToken()
              }
              Text {
                textFormat: Text.PlainText
                text: root.needsToken ? "none configured" : "configured"
                color: root.needsToken ? root.failedColor : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                Layout.fillWidth: true
              }
            }

            // ---- Token form, shown in place of the token row while editing.
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
              color: root.failedColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          }

          Text {
            visible: root.needsToken && !root.editingToken
            textFormat: Text.PlainText
            text: "Open settings (gear) or press t to paste a token"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.error === "" && root.apps.length === 0
            textFormat: Text.PlainText
            text: root.loading ? "Loading apps" : "No apps found"
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
    // Two phases of a job. Queued: Hatchbox has accepted it but nothing runs
    // yet, so the whole row breathes red. Running: the rocket rattles and the
    // text pulses in the busy colour.
    readonly property bool queued: busy && app.state === "pending"
    readonly property bool running: busy && !queued
    readonly property string stateText: Model.stateLabel(app)

    hasCursor: root.cursorActive && root.appIndex === rowIndex
    foreground: root.foreground

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    // Queued: a red wash over the row that breathes slowly.
    Rectangle {
      id: queuedWash
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.failedColor
      opacity: 0
      visible: appRow.queued
      SequentialAnimation on opacity {
        running: appRow.queued
        loops: Animation.Infinite
        NumberAnimation { to: 0.32; duration: 1200; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0.06; duration: 1200; easing.type: Easing.InOutSine }
        onRunningChanged: if (!running) queuedWash.opacity = 0
      }
    }

    // Running: smoke billows out of the rocket and drifts left across the
    // row while the job runs. The emitter caps how many puffs are alive, so
    // a long deploy settles into a steady plume rather than filling the
    // row. When the job ends the emitter stops and the remaining puffs
    // live out their lifespan and fade, then the system sleeps.
    readonly property int smokeLifeMs: 3600
    onRunningChanged: if (!running) smokeTail.restart()
    Timer { id: smokeTail; interval: appRow.smokeLifeMs + 1200 }

    ParticleSystem {
      id: smoke
      anchors.fill: parent
      running: appRow.running || smokeTail.running
      paused: !running
      clip: true
      z: 1

      // Pixel exhaust: many small hard-edged squares in a few grey shades,
      // rather than a handful of soft clouds.
      ImageParticle {
        source: Qt.resolvedUrl("assets/smoke.png")
        color: root.dim
        colorVariation: 0.08
        alpha: 0.8
        alphaVariation: 0.25
        entryEffect: ImageParticle.Fade
      }

      // Out of the back of the rocket, which for this glyph is down and to
      // the left. Buoyancy (an upward pull) turns the dive into a curve that
      // bottoms out near the row's floor, then the smoke billows up and
      // drifts left until it leaves the row.
      Emitter {
        id: smokeEmitter
        enabled: appRow.running
        x: rowContent.x + deployButton.x + deployButton.width * 0.28
        y: rowContent.y + deployButton.y + deployButton.height * 0.68
        width: Style.space(2); height: Style.space(2)
        emitRate: 90
        lifeSpan: appRow.smokeLifeMs
        lifeSpanVariation: 700
        maximumEmitted: 260
        size: Style.space(2)
        endSize: Style.space(3)
        sizeVariation: Style.space(1)
        velocity: AngleDirection { angle: 135; angleVariation: 18; magnitude: Style.space(56); magnitudeVariation: Style.space(12) }
        acceleration: AngleDirection { angle: 262; magnitude: Style.space(46) }
      }

      Wander {
        xVariance: Style.space(10)
        yVariance: Style.space(8)
        pace: Style.space(30)
      }
    }

    RowLayout {
      id: rowContent
      z: 2
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

      // Deploy and restart. While a job runs, the matching glyph shakes and
      // takes the busy colour; the button stays in place but does nothing.
      ActionGlyphButton {
        id: deployButton
        glyph: "󱓞"
        active: appRow.running && !(appRow.app && appRow.app.isRestart)
        tooltipText: appRow.busy ? "Deploying" : "Deploy " + (appRow.app ? appRow.app.branch : "")
        onClicked: root.askDeploy(appRow.app)
      }

      ActionGlyphButton {
        glyph: "󰜉"
        active: appRow.running && !!(appRow.app && appRow.app.isRestart)
        tooltipText: appRow.busy ? "Restarting" : "Restart"
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

  // PanelActionButton with the glyph drawn as a child, so only the glyph
  // animates and the button's hover fill stays square and still.
  component ActionGlyphButton: PanelActionButton {
    id: glyphButton
    property string glyph: ""
    property bool active: false

    iconText: ""
    foreground: root.foreground
    fontFamily: root.fontFamily

    Text {
      id: glyphText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: glyphButton.glyph
      color: glyphButton.active ? root.busyColor : (glyphButton._hot ? glyphButton.hoverColor : root.foreground)
      font.family: root.fontFamily
      font.pixelSize: glyphButton.fontSize
      transformOrigin: Item.Center

      // A continuous rattle: uneven left-right twitches with no rest.
      SequentialAnimation {
        id: rattle
        running: glyphButton.active
        loops: Animation.Infinite
        NumberAnimation { target: glyphText; property: "rotation"; to: -14; duration: 45 }
        NumberAnimation { target: glyphText; property: "rotation"; to: 12; duration: 70 }
        NumberAnimation { target: glyphText; property: "rotation"; to: -8; duration: 60 }
        NumberAnimation { target: glyphText; property: "rotation"; to: 10; duration: 55 }
        NumberAnimation { target: glyphText; property: "rotation"; to: -11; duration: 65 }
        NumberAnimation { target: glyphText; property: "rotation"; to: 6; duration: 50 }
        onRunningChanged: if (!running) glyphText.rotation = 0
      }
    }
  }
}
