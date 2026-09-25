# health-monitor

Watches the failure signals a general-purpose monitor typically misses, and
notifies **only on state changes**.

## Why it is narrow on purpose

Disk, temperature, throttling, RAM, containers and services are already covered by
whatever dashboard you run. Duplicating them here means two notifications for one
event. This tool deliberately owns a different set:

| Signal | Severity |
|---|---|
| Default gateway not responding to ping | CRITICAL |
| `order-3` buddyinfo collapse in a single sample | CRITICAL |
| `rtw88` tx-report errors | CRITICAL |
| Page allocation failure | CRITICAL |
| Watchdog intervened *n* times | WARNING |
| `watchdog.timer` not running | WARNING |
| `order-3` median low | WARNING |
| Swap above threshold | WARNING |
| NFS `rsize` smaller than expected | WARNING |
| Failed systemd units present | WARNING |

Anything else `check.sh` reports is logged locally but **not** notified — the
assumption is that your main monitor owns it.

## State-change notification

`notify.py` keeps a signature of the current warning set. It notifies on
OK→WARNING, WARNING→CRITICAL and WARNING→OK, and stays silent while the same
warning persists. A standing problem does not page you every cycle.

## Delivery

Alerts are delivered by calling a **Home Assistant script you name**, so
deduplication, phone push, logbook entries and quiet hours stay in one place
instead of being reimplemented here.

The script is called as `script.<HA_ALERT_SCRIPT>` with:

```json
{"source": "<ALERT_SOURCE_ENTITY>", "severity": "WARNING|CRITICAL", "message": "..."}
```

The Home Assistant token is minted **inside the container** from its own refresh
token for each call. No long-lived token is written to disk.

## Configure

```bash
cp config.example.env config.env
$EDITOR config.env
```

| Key | Meaning |
|---|---|
| `HA_CONTAINER` | Home Assistant Docker container name |
| `HA_ALERT_SCRIPT` | script entity name, **without** the `script.` prefix |
| `ALERT_SOURCE_ENTITY` | value passed as `source` for attribution |
| `CHECK_WINDOW` | log window for `check.sh` (`journalctl --since` syntax) |

Environment variables override the file. `HEALTH_MONITOR_CONFIG` points at a
different config file. `config.env` is git-ignored.

## Run

```bash
bash check.sh 24h          # raw checks, prints UYARI: lines
python3 notify.py --dry-run   # classify + show what would be sent
python3 notify.py             # classify + notify on change
```

Schedule it with a systemd timer (15 minutes is a sensible interval):

```ini
[Unit]
Description=health-monitor

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 %h/homelab-toolkit/health-monitor/notify.py
```

> **Test it under the timer, not just by hand.** `ping` needs the `cap_net_raw`
> file capability; a unit with `NoNewPrivileges=true` blocks it and the gateway
> check will report a false CRITICAL. Verify with:
> ```bash
> systemd-run --user --wait -p NoNewPrivileges=true --pipe bash check.sh 24h
> ```

## Requirements

Python 3, `bash`, `docker` (to reach Home Assistant), and a Home Assistant script
to receive the alert. Without Docker/HA the checks still run — only delivery fails.

## Files

- `check.sh` — the checks; prints `UYARI:` lines, exits non-zero on findings
- `notify.py` — classifies, debounces by state change, delivers
- `config.example.env` — configuration template
- `.notify-state.json`, `notify.log` — runtime state, git-ignored
