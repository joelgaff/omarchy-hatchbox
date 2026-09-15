#!/usr/bin/env bash
# First-check script. Run on the Omarchy box after copying this dir to
# ~/.config/omarchy/plugins/joelgaff.hatchbox and creating ~/.config/omarchy/hatchbox.json.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
api="$here/bin/hatchbox-api"

echo "== 1. Manifest validation"
omarchy plugin validate "$here"

echo "== 2. Accounts (works even without a subscription)"
accounts="$($api GET /accounts)"; echo "$accounts" | jq .

echo "== 3. Apps per account (confirms subscription gate + app object fields)"
for id in $(echo "$accounts" | jq -r '.[].id'); do
  $api GET "/accounts/$id/apps" | jq '.[] | {id, name, branch, auto_deploy, maintenance, health_check_uri, last_deploy_at, last_deploy_sha}'
done

echo "== 4. Does last_deploy_at track failed deploys? Compare against the newest log per app."
for id in $(echo "$accounts" | jq -r '.[].id'); do
  for app in $(  $api GET "/accounts/$id/apps" | jq -r '.[].id'); do
    echo "-- app $app"
    $api GET "/apps/$app/logs?limit=3" | jq '.[] | {name, state, commit_sha: (.commit_sha // "" | .[0:7]), username, description, completed_at}'
  done
done
echo "== Done. Enable with: omarchy plugin enable joelgaff.hatchbox"
