# wifi-usb-fix

Stops an RTL8822BU USB Wi-Fi adapter from wedging the host, and recovers it
automatically if it does.

## Symptom

The adapter passes traffic for hours or days, then stops. The interface still
exists, `iw` still reports an association, but nothing routes. Only physically
unplugging and replugging the dongle brings the host back — which is useless on a
headless machine.

Typical kernel log before it dies:

```
rtw88_8822bu: failed to get tx report from firmware
page allocation failure: order:3, mode:0x40cc0
```

## Cause

`rtw88_usb` allocates **order-3** (32 KB contiguous) pages for RX buffers. On a
long-running host those allocations start failing as memory fragments — not
because memory is exhausted, but because it is fragmented. When the allocation
fails the driver wedges and does not recover.

Measurements and the full reasoning are in
[`docs/root-cause-analysis.md`](docs/root-cause-analysis.md) *(Turkish)*.

## What the fix does

1. **`/etc/sysctl.d/99-wifi-usb-mem-stability.conf`** — raises `min_free_kbytes`
   and `watermark_scale_factor`, enables proactive compaction, and tightens dirty
   ratios so order-3 pages stay available. This addresses the cause.
2. **`/usr/local/bin/wifi-usb-watchdog.sh`** + a systemd timer — every 30 s, checks
   whether the default gateway is reachable through the adapter. After repeated
   failures it performs a **USB-level reset** (unbind/bind), then waits for the
   interface to come back. This is the safety net.
3. **NFS `rsize`/`wsize`** *(optional, off by default)* — 512 KB reads over a USB 2.0
   adapter produce oversized scatter-gather chains; 128 KB is more stable.

The watchdog discovers the interface and gateway at runtime. There is no hardcoded
interface name.

## Install

```bash
sudo bash wifi-usb-fix/install.sh
```

Additive: creates new files, restarts nothing, does not touch the network.
A timestamped backup is written first and its path printed.

To include the optional NFS step, name the fstab source line explicitly:

```bash
NFS_FSTAB_SOURCE='nfs.example.internal:/srv/share' sudo -E bash wifi-usb-fix/install.sh
# optional: NFS_RSIZE=131072 (default)
```

Without `NFS_FSTAB_SOURCE` that step is skipped and says so.

## Verify

```bash
journalctl -t wifi-usb-watchdog -f            # watchdog decisions
cat /proc/buddyinfo                           # order-3 column should stay non-zero
grep -E 'compact_(stall|fail|success)' /proc/vmstat
systemctl status wifi-usb-watchdog.timer
```

A healthy host logs nothing from the watchdog — it only speaks when it acts.

> `compact_stall` / `compact_fail` / `compact_success` reset on reboot. A drop is
> not a leak; check uptime before reading anything into it.

## Requirements

Linux with systemd, `iw`/`ip`, and a USB Wi-Fi adapter bound through the USB bus
(the reset works at the USB level, so the adapter must be USB — not PCIe).

## Undo

[`RECOVERY.md`](RECOVERY.md) *(Turkish)* — restores sysctl, removes the watchdog
units, and reverts the fstab line from the backup.
