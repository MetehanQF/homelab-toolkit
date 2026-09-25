# swap-fix

Keeps swap usable as an emergency buffer instead of letting it silently fill up.

## Symptom

Swap sits at or near 100 % full while RAM is largely free, and latency-sensitive
services have pages stranded on disk.

The measurement that motivated this:

```
SwapTotal 1048572 kB / SwapFree 51284 kB     ->  95 % full
pswpout 207156 / pswpin 1608
PSI memory some/full = 0.00
```

`pswpout` far exceeding `pswpin` means this is **not thrashing** — pages were
evicted once and essentially never read back, and PSI confirms there is no memory
pressure. Performance is fine *right now*. The problem is that the buffer is gone:
a machine with plenty of RAM but a small swap partition has filled it, so a sudden
allocation spike has nowhere to fall back to.

## Cause

`vm.swappiness` defaults to `60`, which encourages the kernel to evict anonymous
pages in favour of page cache **even when RAM is abundant**. Over weeks that
quietly consumes the whole swap partition.

## What the fix does

1. **`/etc/sysctl.d/99-swap-tuning.conf`** — sets `vm.swappiness = 10`. Swap stays
   available for emergencies but is not used routinely.
2. **Flushes accumulated swap** — `swapoff` followed by `swapon`, which pulls the
   stranded pages back into RAM and returns the swap device to empty.

> `swapoff` needs enough free RAM to absorb everything currently swapped out. The
> script reports sizes before doing it. On a host that is genuinely short on RAM,
> skip step 2.

## Install

```bash
sudo bash swap-fix/install.sh
```

A timestamped backup is written first and its path printed. Override the location
with `TOOLKIT_BACKUP_DIR`.

## Verify

```bash
sysctl vm.swappiness                  # 10
free -h                               # swap used should be near zero
grep -E 'pswpin|pswpout' /proc/vmstat
```

## Tuning for your host

`10` suits a machine with comfortable RAM running latency-sensitive services. If
RAM is genuinely tight, a higher value is more appropriate — edit
`files/99-swap-tuning.conf` before installing. The file documents the reasoning
inline so you can judge it against your own numbers.

## Undo

[`RECOVERY.md`](RECOVERY.md) *(Turkish)*
