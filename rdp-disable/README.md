# rdp-disable

Actually turns off GNOME Remote Desktop — both halves of it.

## Symptom

You disable Remote Desktop in GNOME Settings, but something is still listening:

```bash
$ ss -tln | grep 339
LISTEN 0 10 *:3389 *:*
```

## Cause

GNOME Remote Desktop runs as **two independent services**:

| Layer | Runs as | Port | Turned off by Settings? |
|---|---|---|---|
| Session | your user, `systemctl --user` | 3390 | yes |
| System | `gnome-remote-desktop` user, `--system` | 3389 | **no** |

The Settings toggle only covers the session daemon. The system daemon is a
separate unit running under its own account and keeps listening.

> This is why `ss -tlnp` can look like it shows no owner for the port: the process
> belongs to a different user. If a port has no visible owner, check system
> services before concluding the port is orphaned.

## What the scripts do

**`disable-system-rdp.sh`** — prints the before state, then stops, disables and
masks the system-level unit, and prints the after state so you can see the port
close.

**`enable-system-rdp.sh`** — unmasks and re-enables it.

Neither script touches the session-level daemon or any other service.

## Run

```bash
sudo bash rdp-disable/disable-system-rdp.sh
```

## Verify

```bash
ss -tln | grep 3389 || echo "3389 closed"
systemctl is-enabled gnome-remote-desktop.service
```

## Undo

```bash
sudo bash rdp-disable/enable-system-rdp.sh
```

## Requirements

Linux with systemd and GNOME Remote Desktop installed. No configuration.
