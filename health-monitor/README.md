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
| `rtw88` tx-report errors | CRITICAL |
| Page allocation failure (all boots since the fix, not just the current one) | CRITICAL |
| Contiguous ≥order-3 memory pool below 64 MB | CRITICAL |
| Contiguous ≥order-3 memory pool below 200 MB | WARNING |
| `compact_fail` / `allocstall_normal` rising by ≥100 between runs | WARNING |
| Swap read-back ≥1000 pages/min | WARNING |
| Memory pressure (PSI `some`) ≥5 % of the interval | WARNING |
| Watchdog intervened *n* times | WARNING |
| `watchdog.timer` not running | WARNING |
| NFS `rsize` smaller than expected | WARNING |
| Failed systemd units present | WARNING |

Anything else `check.sh` reports is logged locally but **not** notified — the
assumption is that your main monitor owns it.

## What it measures, and what it deliberately does not

Two earlier thresholds were removed because they paged on healthy machines.

**The `order-3` counter is not a fragmentation metric.** `/proc/buddyinfo`'s
order-3 column is the number of *ready-made* 32 KB blocks, not whether a 32 KB
allocation can succeed: the buddy allocator satisfies an order-3 request by
splitting a higher order. With memory sitting intact in order-10 blocks the
counter can drop to 2, which is the opposite of fragmentation. The old
`median < 100` / `single sample < 30` thresholds fired 10 times in three days,
4 of them CRITICAL, all false. They were replaced by:

- the **total contiguous pool** at order ≥3 across all zones, in MB
  (`awk '/zone/{for(o=3;o<=10;o++) t+=$(o+5)*(4*2^o)/1024} END{print t}' /proc/buddyinfo`).
  The worst value measured after the Wi-Fi fix was ~365 MB, normal is
  0.7–7.2 GB, so 200 MB does not trip on ordinary fluctuation;
- the **rate** of `compact_fail` and `allocstall_normal`, not their absolute
  value. Deltas are kept in `.mem-counters` next to the script (the only file it
  writes); a negative delta means a reboot and is skipped rather than reported.

**Swap fullness is not a pressure metric.** The kernel pushes idle pages to swap
once and never asks for them back. A 1 GB swap sat at 90 % while 6.6 GB of RAM
was available, with zero swap-in, zero PSI stall and 875 pages swapped in over
four days; the old "above 60 %" threshold sent 37 false notifications. What
matters is swap **read-back** (`pswpin` rate) and **PSI memory stall time**.
Both need two runs at least two minutes apart; until then they report
`OLCULEMEDI` (not measured) instead of guessing.

Kernel-log counts use `journalctl _TRANSPORT=kernel --since @<epoch>` rather than
`journalctl -k`, which only covers the current boot and silently shrinks the
"since the fix" window to the uptime after every reboot.

## State-change notification

`notify.py` keeps a signature of the current warning set. It notifies on
OK→WARNING, WARNING→CRITICAL and WARNING→OK, and stays silent while the same
warning persists. A standing problem does not page you every cycle.

Numbers are stripped from the signature, so the same warning changing from
"79 %" to "80 %" is not a new event — only a different *kind* of warning, or its
clearing, notifies again.

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
- `.notify-state.json`, `.mem-counters`, `notify.log` — runtime state, git-ignored
