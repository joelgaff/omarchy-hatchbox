#!/usr/bin/env bash
# Smoke test for the API wrapper. Validates the manifest, then walks
# accounts, apps, and the newest logs per app with the configured token.
# Individual API failures are printed and the walk continues.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
api="$here/bin/hatchbox-api"

echo "== 1. Manifest validation"
omarchy plugin validate "$here" && echo "ok"

echo "== 2. Accounts"
accounts="$($api GET /accounts)" || { echo "accounts request failed"; exit 1; }
echo "$accounts" | jq .

echo "== 3. Apps per account"
for id in $(echo "$accounts" | jq -r '.[].id'); do
  $api GET "/accounts/$id/apps" | jq '.[] | {id, name, branch, auto_deploy, maintenance, last_deploy_at, last_deploy_sha}' || echo "apps request failed for account $id"
done

echo "== 4. Newest logs per app (deploy state comes from here, not last_deploy_at)"
for id in $(echo "$accounts" | jq -r '.[].id'); do
  for app in $($api GET "/accounts/$id/apps" 2>/dev/null | jq -r '.[].id'); do
    echo "-- app $app"
    $api GET "/apps/$app/logs?limit=3" | jq '.[] | {id, name, state, commit_sha: (.commit_sha // "" | .[0:7]), description, completed_at}' || echo "logs request failed for app $app"
  done
done
echo "== Done"
