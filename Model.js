.pragma library

// Parse the array from GET /accounts/:id/apps into row objects the panel binds to.
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
      dashboardUrl: "https://hatchbox.io/apps/" + a.id
    }
  })
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
