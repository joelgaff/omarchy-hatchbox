# Hatchbox for Omarchy

Deploy status, deploy/restart, and logs for [Hatchbox.io](https://hatchbox.io) apps, from the top bar.

## Install

```bash
omarchy plugin add https://github.com/joelgaff/omarchy-hatchbox.git --enable
```

Or by hand: copy this directory to `~/.config/omarchy/plugins/joelgaff.hatchbox`, run `omarchy-shell shell rescanPlugins`, then `omarchy plugin enable joelgaff.hatchbox`.

## Token

Click the bar icon. The panel asks for a Hatchbox API token the first time; paste it and press Enter. Tokens are created at https://hatchbox.io/api_tokens. They are unscoped, so treat one like a password.

The token is written to `~/.config/omarchy/hatchbox.json` with mode 600 by `bin/hatchbox-token`, which reads it from stdin. It never touches `shell.json`, argv, a log, or an IPC payload. Press `t` in the panel to replace it, or run `bin/hatchbox-token clear` to remove it. `HATCHBOX_API_TOKEN` in the environment overrides the file.

`bin/hatchbox-api` is the only place the token is read. All QML goes through it.

## Keys

| Key | Action |
| --- | --- |
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

## First check (development)

`./check.sh` validates the manifest, lists accounts and apps, and prints the newest logs so we can confirm whether `last_deploy_at` moves on a failed deploy. It needs the token file from the step above.
