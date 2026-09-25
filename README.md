# homelab-toolkit

Four small, independent fixes for problems a Raspberry Pi home lab actually runs
into — each one written after diagnosing the failure on real hardware, not copied
from a forum thread.

Nothing here is a framework. Each tool is a directory you can read in five
minutes, install with one script, and undo with the recovery notes next to it.
They share no code and no state; take one and ignore the rest.

| Tool | Problem it solves |
|---|---|
| [`wifi-usb-fix`](wifi-usb-fix/) | RTL8822BU USB Wi-Fi adapter locks up under memory fragmentation; the whole host goes offline until you replug it |
| [`health-monitor`](health-monitor/) | The failure signals a generic monitor misses: Wi-Fi driver errors, page-allocation failures, watchdog activity, NFS mount options |
| [`swap-fix`](swap-fix/) | Default `swappiness` evicts anonymous pages even with RAM to spare, exhausting a small swap partition so no emergency buffer is left |
| [`rdp-disable`](rdp-disable/) | GNOME Remote Desktop keeps listening even after you turn it off in Settings — there is a second, system-level daemon |

Tested on Raspberry Pi 5 / Ubuntu / kernel 6.8, but nothing is Pi-specific except
where a tool says so.

---

## Design rules

These hold for every tool here:

- **Additive by default.** Install scripts create new files and leave existing
  configuration alone. Where a shared file must change (`/etc/fstab`), the edit is
  a single targeted line and the original is backed up first.
- **Back up before touching anything.** Every install writes a timestamped backup
  and prints the path. Override the location with `TOOLKIT_BACKUP_DIR`.
- **No machine-specific values in source.** Paths are derived from the script's own
  location; anything that cannot be derived is read from configuration and fails
  loudly when missing, rather than guessing.
- **Reversible.** Each tool ships recovery instructions that were actually used.
- **Safe to re-run.** Installs are idempotent.

---

## Quick start

```bash
git clone https://github.com/MetehanQF/homelab-toolkit.git
cd homelab-toolkit

# read the tool's README first, then:
sudo bash wifi-usb-fix/install.sh
```

Backups default to `~/.local/state/homelab-toolkit/backups/<timestamp>-<tool>/`.
Change that with `TOOLKIT_BACKUP_DIR=/path sudo -E bash <tool>/install.sh`.

---

## The tools

### `wifi-usb-fix` — RTL8822BU lockup

A TP-Link USB Wi-Fi adapter (`2357:0138`, RTL8822BU, `rtw88_8822bu`) stops passing
traffic after hours or days. The interface still exists, the link looks associated,
and nothing short of physically replugging it brings the host back.

The cause is not the driver alone: `rtw88_usb` needs order-3 contiguous pages for
its RX buffers, and once free memory is fragmented those allocations fail, the
driver wedges, and the adapter never recovers on its own.

The fix has two halves — sysctl tuning that keeps order-3 pages available, and a
30-second watchdog that performs a USB-level reset if the gateway becomes
unreachable. A third, optional step lowers NFS `rsize`/`wsize`, which matters when
the NFS traffic crosses that same USB 2.0 adapter.

Full write-up with measurements: [`wifi-usb-fix/docs/root-cause-analysis.md`](wifi-usb-fix/docs/root-cause-analysis.md)

### `health-monitor` — the gaps a normal monitor leaves

Runs a check script and forwards only the signals a general-purpose monitor does
not already cover: `rtw88` tx-report errors, page-allocation failures, order-3
buddyinfo collapse, gateway reachability, watchdog interventions, swap pressure,
NFS `rsize`, and failed systemd units.

It notifies on *state transitions* (OK→WARN, WARN→CRITICAL, WARN→OK), so a standing
warning does not page you every cycle. Delivery goes through a Home Assistant
script you name in configuration — this tool does not own deduplication, push, or
quiet hours.

### `swap-fix` — keep swap as an emergency buffer

The default `vm.swappiness=60` pushes anonymous pages out in favour of page cache
even when RAM is plentiful. On a host with a small swap partition that slowly
fills it to capacity, so when a real memory spike arrives there is nowhere left to
fall back to — while latency-sensitive services sit paged out on disk.

Sets `vm.swappiness=10` and flushes the accumulated swap, keeping swap available
as a buffer instead of a dumping ground.

### `rdp-disable` — turn off GNOME Remote Desktop properly

Disabling remote desktop in GNOME Settings stops the *session* daemon (port 3390)
but leaves the *system* daemon running as its own user on port 3389. This closes
both, and `enable-system-rdp.sh` puts it back.

---

## Configuration

Only `health-monitor` needs configuration:

```bash
cd health-monitor
cp config.example.env config.env
$EDITOR config.env
```

`config.env` is git-ignored. It holds no secrets — the Home Assistant token is
minted inside the container from its own refresh token and never written to disk —
but the values are specific to your installation.

---

## A note on the deep-dive documents

The per-tool `README.md` files and this page are in English. The original
diagnostic write-ups (`docs/root-cause-analysis.md`, the `RECOVERY.md` files) are
in Turkish, as they were written during the incidents. They are published as-is
rather than translated, so the measurements and commands stay exactly as they were
verified. The English READMEs cover what each tool does and how to run it.

---

## Contributing

Patches welcome. Please keep real addresses, hostnames, MAC addresses and
credentials out of them — including in examples. Use the RFC documentation ranges
(`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`, `100.64.0.0/10`).

## Licence

[MIT](LICENSE) © 2026 Metehan Öztürk
