# swap-fix - Geri Alma

Kurulum yedegi: `$TOOLKIT_BACKUP_DIR/<STAMP>-swap-fix/`
Son yedegin yolu: `cat /tmp/swap-fix-last-backup`

## Tam geri alma

```bash
sudo rm -f /etc/sysctl.d/99-swap-tuning.conf
sudo sysctl -w vm.swappiness=60
```

Bu kadar. Baska hicbir kalici degisiklik yapilmadi.

## Swap tazeleme geri alinabilir mi?

Hayir ve gerek de yok. `swapoff` + `swapon` kalici bir degisiklik degil;
sadece o an swap'te bekleyen sayfalari RAM'e geri ceker ve swap alanini
bosaltir. Dosyanin kendisi (`/swapfile`, 1 GiB), boyutu, onceligi ve
`swapfile.swap` systemd unit'i degismez. Sistem yeniden baslatildiginda
zaten ayni durum olusur.

## Dogrulama

```bash
cat /proc/sys/vm/swappiness      # geri alindiysa 60
cat /proc/swaps
grep -E 'pswpin|pswpout' /proc/vmstat
```

## wifi-usb-fix ile iliskisi

Bu paket `wifi-usb-fix`'ten TAMAMEN bagimsizdir ve onun ayarlarina
dokunmaz:

- `wifi-usb-fix` -> `/etc/sysctl.d/99-wifi-usb-mem-stability.conf`
  (`min_free_kbytes`, `watermark_scale_factor`, `compaction_proactiveness`,
  `dirty_bytes`, `dirty_background_bytes`)
- `swap-fix` -> `/etc/sysctl.d/99-swap-tuning.conf` (`swappiness`)

Ortak anahtar yok, cakisma yok. Birini geri almak digerini etkilemez.
