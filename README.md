# Hatchbox for Omarchy

Deploy status, deploy/restart, and logs for Hatchbox.io apps, from the top bar.

## First check (before any Tier 1 work)

1. Copy this directory to `~/.config/omarchy/plugins/joelgaff.hatchbox`.
2. Create `~/.config/omarchy/hatchbox.json` with `{"token":"<Hatchbox API token>"}` and `chmod 600` it.
   Tokens are created at https://hatchbox.io/api_tokens. They are unscoped, so keep this file out of dotfiles.
3. Run `./check.sh`. It validates the manifest, lists accounts and apps, and prints the newest logs so we can confirm whether `last_deploy_at` moves on a failed deploy.
4. `omarchy-shell shell rescanPlugins && omarchy plugin enable joelgaff.hatchbox`, then click the icon.

`bin/hatchbox-api` is the only place the token is read. All QML goes through it.
