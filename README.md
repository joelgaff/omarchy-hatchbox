# Hatchbox for Omarchy

Deploy status, deploy/restart, and logs for [Hatchbox.io](https://hatchbox.io) apps, from the top bar.

## Install

```bash
omarchy plugin add https://github.com/joelgaff/omarchy-hatchbox.git --enable
```

Or by hand: copy this directory to `~/.config/omarchy/plugins/joelgaff.hatchbox`, run `omarchy-shell shell rescanPlugins`, then `omarchy plugin enable joelgaff.hatchbox`.

## Token

Click the bar icon. The panel asks for a Hatchbox API token the first time; paste it and press Enter. Tokens are created at https://hatchbox.io/api_tokens. They are unscoped, so treat one like a password.

The token is written to `~/.config/omarchy/hatchbox.json` with mode 600 by `bin/hatchbox-token`, which reads it from stdin. It never touches `shell.json`, argv, a log, or an IPC payload. Press `t` in the panel, or click the key icon in the panel header, to replace it. Run `bin/hatchbox-token clear` to remove it. `HATCHBOX_API_TOKEN` in the environment overrides the file.

`bin/hatchbox-api` is the only place the token is read. All QML goes through it.

## What it shows

One row per app across every account: name, branch, deployed SHA, and the state of the newest deploy or restart read from the app's logs. An app whose latest deploy or restart failed gets a red name. Everything else, the bar icon included, follows the theme. Themes whose red is the same as their foreground (monochrome themes) get a fixed red instead, so a failure never hides.

Each row has three actions: deploy the branch, restart, and open the app in Hatchbox. Deploy and restart ask for confirmation first, then the row shows a spinner and polls the logs until the job settles.

## Keys

| Key | Action |
| --- | --- |
| `Up` / `Down` | Move between apps |
| `Enter` | Open the highlighted app in Hatchbox |
| `d` | Deploy the highlighted app |
| `s` | Restart the highlighted app |
| `r` | Refresh |
| `t` | Paste a new token |
| `Esc` | Close |
| `Tab` | Switch to the neighbouring panel |

## IPC

```bash
omarchy-shell joelgaff.hatchbox toggle
omarchy-shell joelgaff.hatchbox refresh
omarchy-shell joelgaff.hatchbox setup
```

## Settings

Set per widget in `shell.json` or from the bar settings panel.

| Key | Default | Meaning |
| --- | --- | --- |
| `refreshMinutes` | `5` | How often to poll |
| `hideApps` | `""` | Comma-separated app names to leave out |

## Development

The shell hot-reloads edits to existing plugin files. Adding a new file (a new QML type, say) needs `omarchy restart shell` before the running shell can see it.

## First check

`./check.sh` validates the manifest, lists accounts and apps, and prints the newest logs so we can confirm whether `last_deploy_at` moves on a failed deploy. It needs the token file from the step above.
