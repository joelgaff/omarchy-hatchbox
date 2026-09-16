.pragma library

// Remote strings (app, branch, and account names) reach labels, tooltips, and
// the confirm dialog. Every sink in the shell kit renders plain text, but the
// values are constrained here anyway so crafted metadata cannot carry markup,
// control characters, or unbounded length into any text surface.
function safeText(value, maxLength) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(/<[^>]*>/g, "")
  s = s.replace(/[\x00-\x1f\x7f-\x9f]/g, "")
  s = s.replace(/\s+/g, " ").trim()
  var cap = maxLength || 120
  return s.length > cap ? s.slice(0, cap) : s
}

// Parse the array from GET /accounts/:id/apps into row objects the panel binds to.
// Deploy state fields start empty; the panel fills them from the logs endpoint,
// because last_deploy_at only moves on a successful deploy.
function parseApps(text, hideList) {
  var hidden = (hideList || "").split(",").map(function(s){ return s.trim() }).filter(Boolean)
  var apps
  try { apps = JSON.parse(text) } catch (e) { return [] }
  if (!Array.isArray(apps)) return []
  return apps.filter(function(a){ return a && typeof a === "object" && hidden.indexOf(String(a.name || "")) === -1 }).map(function(a) {
    return {
      id: Number(a.id) || 0,
      name: safeText(a.name),
      branch: safeText(a.branch),
      sha: a.last_deploy_sha ? String(a.last_deploy_sha).slice(0, 7) : "",
      dashboardUrl: "https://hatchbox.io/apps/" + a.id,
      state: "",
      stateAgo: "",
      isRestart: false,
      failed: false,
      busy: false,
      actionLogId: 0,
      busySince: 0
    }
  })
}

var stateFields = ["state", "stateAgo", "isRestart", "failed", "busy", "actionLogId", "busySince"]

// Carry deploy state across a refresh so a red row does not flicker back to
// plain while the logs are refetched.
function mergeState(fresh, previous) {
  var byId = {}
  ;(previous || []).forEach(function(row){ byId[row.id] = row })
  return fresh.map(function(row) {
    var old = byId[row.id]
    if (!old) return row
    var merged = Object.assign({}, row)
    stateFields.forEach(function(key){ merged[key] = old[key] })
    return merged
  })
}

function isBusyState(state) { return state === "pending" || state === "processing" }
function isFailedState(state) { return state === "failed" || state === "aborted" }

function byNewest(a, b) { return Date.parse(b.created_at || 0) - Date.parse(a.created_at || 0) }

// Choose the log entry a row should show, from GET /apps/:id/logs. Other job
// types (Apps::EnvVars) share the list, so filter by name. A restart only
// speaks for the row while it is running or has failed; a completed restart
// does not clear a failed deploy, because the failing build is still live.
// With minLogId set (an action is in flight), entries older than that action
// are ignored, and undefined means "nothing new yet, keep what you have".
function pickActivity(text, minLogId) {
  var logs
  try { logs = JSON.parse(text) } catch (e) { return null }
  if (!Array.isArray(logs)) return null
  if (minLogId) logs = logs.filter(function(l){ return l && Number(l.id) >= minLogId })
  var deploys = logs.filter(function(l){ return l && l.name === "Apps::Deploy" }).sort(byNewest)
  var restarts = logs.filter(function(l){ return l && l.name === "Apps::Restart" }).sort(byNewest)
  if (minLogId && deploys.length === 0 && restarts.length === 0) return undefined
  var restart = restarts[0]
  var deploy = deploys[0]
  if (restart && (!deploy || byNewest(deploy, restart) > 0) && (isBusyState(restart.state) || isFailedState(restart.state))) return restart
  if (deploy) return deploy
  return restart || null
}

// One log object from GET /logs/:id.
function parseLog(text) {
  try {
    var log = JSON.parse(text)
    return (log && typeof log === "object" && !Array.isArray(log)) ? log : null
  } catch (e) { return null }
}

// Row fields derived from a log entry. States: pending, processing,
// completed, failed, aborted.
function statePatch(log) {
  if (!log) return { state: "unknown", stateAgo: "", isRestart: false, failed: false, busy: false, actionLogId: 0, busySince: 0 }
  var state = String(log.state || "")
  var busy = isBusyState(state)
  return {
    state: state,
    stateAgo: relative(log.completed_at || log.started_at || log.created_at || ""),
    isRestart: log.name === "Apps::Restart",
    failed: isFailedState(state),
    busy: busy,
    actionLogId: busy ? Number(log.id) || 0 : 0,
    busySince: busy ? Date.now() : 0
  }
}

function stateLabel(row) {
  if (!row) return ""
  var kind = row.isRestart ? "restart" : "deploy"
  switch (row.state) {
    case "pending": return kind + " queued"
    case "processing": return kind === "restart" ? "restarting" : "deploying"
    case "failed": return kind + " failed " + row.stateAgo
    case "aborted": return kind + " aborted " + row.stateAgo
    case "completed": return "deployed " + row.stateAgo
    case "unknown": return "no deploys yet"
    default: return ""
  }
}

// Last line of hatchbox-api's stderr is the HTTP status.
function httpStatus(stderrText) {
  var m = String(stderrText || "").trim().match(/(\d{3})\s*$/)
  return m ? m[1] : ""
}

function describeFailure(stderrText, what) {
  var err = String(stderrText || "")
  if (err.indexOf("No Hatchbox token") >= 0) return "No API token configured"
  var status = httpStatus(err)
  if (status === "401") return "Hatchbox rejected the token"
  if (status !== "") return "Could not load " + what + " (HTTP " + status + ")"
  return "Could not reach Hatchbox"
}

// ---- Failure colour. Failed rows must read as red. Many themes give their
// "red" slot a colour that is not red at all (green, blue, grey), which
// would hide a failure, so the theme colour is used only when it is
// visibly red; otherwise a fixed red is chosen for the background's brightness.
function hexToRgb(value) {
  var s = String(value || "").trim()
  var m = s.match(/^#([0-9a-f]{2})?([0-9a-f]{6})$/i)
  if (!m) return null
  var h = m[2]
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]
}

function hsl(rgb) {
  var r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var l = (max + min) / 2
  var d = max - min
  if (d === 0) return { h: 0, s: 0, l: l }
  var sat = d / (1 - Math.abs(2 * l - 1))
  var h
  if (max === r) h = ((g - b) / d) % 6
  else if (max === g) h = (b - r) / d + 2
  else h = (r - g) / d + 4
  h = h * 60
  if (h < 0) h += 360
  return { h: h, s: sat, l: l }
}

function looksRed(rgb) {
  var c = hsl(rgb)
  var hueIsRed = c.h <= 22 || c.h >= 335
  return hueIsRed && c.s >= 0.3 && c.l >= 0.2 && c.l <= 0.8
}

function distance(a, b) {
  return Math.sqrt(Math.pow(a[0] - b[0], 2) + Math.pow(a[1] - b[1], 2) + Math.pow(a[2] - b[2], 2))
}

function failedColor(urgent, foreground, background) {
  var u = hexToRgb(urgent), f = hexToRgb(foreground), bg = hexToRgb(background)
  if (u && looksRed(u) && (!f || distance(u, f) > 60)) return urgent
  var darkBackground = bg ? hsl(bg).l < 0.5 : true
  return darkBackground ? "#f26d6d" : "#c0392b"
}

function relative(iso) {
  if (!iso) return "never"
  var t = Date.parse(iso); if (isNaN(t)) return ""
  var s = Math.max(0, (Date.now() - t) / 1000)
  if (s < 60) return "just now"
  if (s < 3600) return Math.floor(s / 60) + "m ago"
  if (s < 86400) return Math.floor(s / 3600) + "h ago"
  return Math.floor(s / 86400) + "d ago"
}
