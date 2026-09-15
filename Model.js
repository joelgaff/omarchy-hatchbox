.pragma library

// Parse the array from GET /accounts/:id/apps into row objects the panel binds to.
// Deploy state fields start empty; the panel fills them from the logs endpoint,
// because last_deploy_at only moves on a successful deploy.
function parseApps(text, accountName, hideList) {
  var hidden = (hideList || "").split(",").map(function(s){ return s.trim() }).filter(Boolean)
  var apps
  try { apps = JSON.parse(text) } catch (e) { return [] }
  if (!Array.isArray(apps)) return []
  return apps.filter(function(a){ return hidden.indexOf(a.name) === -1 }).map(function(a) {
    return {
      id: a.id,
      name: a.name,
      account: accountName || "",
      branch: a.branch || "",
      repo: a.repo_path || "",
      autoDeploy: !!a.auto_deploy,
      maintenance: !!a.maintenance,
      sha: a.last_deploy_sha ? String(a.last_deploy_sha).slice(0, 7) : "",
      lastDeployAt: a.last_deploy_at || "",
      lastDeployAgo: relative(a.last_deploy_at),
      dashboardUrl: "https://hatchbox.io/apps/" + a.id,
      state: "",
      stateAt: "",
      stateAgo: "",
      stateSha: "",
      stateDescription: "",
      failed: false,
      busy: false
    }
  })
}

// Carry deploy state across a refresh so a red row does not flicker back to
// plain while the logs are refetched.
function mergeState(fresh, previous) {
  var byId = {}
  ;(previous || []).forEach(function(row){ byId[row.id] = row })
  return fresh.map(function(row) {
    var old = byId[row.id]
    if (!old) return row
    return Object.assign({}, row, {
      state: old.state, stateAt: old.stateAt, stateAgo: old.stateAgo, stateSha: old.stateSha,
      stateDescription: old.stateDescription, failed: old.failed, busy: old.busy
    })
  })
}

// Newest Apps::Deploy entry from GET /apps/:id/logs. Other job types
// (Apps::EnvVars, restarts) share the list, so filter by name. A restart is
// counted too, so a failed restart also turns the row red.
function latestDeploy(text) {
  var logs
  try { logs = JSON.parse(text) } catch (e) { return null }
  if (!Array.isArray(logs)) return null
  var deploys = logs.filter(function(l){ return l && (l.name === "Apps::Deploy" || l.name === "Apps::Restart") })
  if (deploys.length === 0) return null
  deploys.sort(function(a, b){ return Date.parse(b.created_at || 0) - Date.parse(a.created_at || 0) })
  return deploys[0]
}

// Row fields derived from a log entry. States: pending, processing,
// completed, failed, aborted.
function statePatch(log) {
  if (!log) return { state: "unknown", failed: false, busy: false }
  var state = String(log.state || "")
  var at = log.completed_at || log.started_at || log.created_at || ""
  return {
    state: state,
    stateAt: at,
    stateAgo: relative(at),
    stateSha: log.commit_sha ? String(log.commit_sha).slice(0, 7) : "",
    stateDescription: log.description || "",
    failed: state === "failed" || state === "aborted",
    busy: state === "pending" || state === "processing",
    isRestart: log.name === "Apps::Restart"
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

function relative(iso) {
  if (!iso) return "never"
  var t = Date.parse(iso); if (isNaN(t)) return ""
  var s = Math.max(0, (Date.now() - t) / 1000)
  if (s < 60) return "just now"
  if (s < 3600) return Math.floor(s / 60) + "m ago"
  if (s < 86400) return Math.floor(s / 3600) + "h ago"
  return Math.floor(s / 86400) + "d ago"
}
