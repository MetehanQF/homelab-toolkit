#!/bin/bash
# Pi5 swap tamponu duzeltmesi - kurulum
# Calistirma:  sudo bash swap-fix/install.sh
#
# Yaptigi degisiklikler:
#   1. /etc/sysctl.d/99-swap-tuning.conf  (YENI dosya)  -> vm.swappiness 60 -> 10
#   2. swapoff + swapon  -> swap'teki bayat sayfalar RAM'e geri cekilir,
#                           1 GiB tampon tamamen bosalir
#
# DOKUNMADIKLARI: mevcut sysctl dosyalari, fstab, hicbir servis, hicbir
# container, ag. wifi-usb-fix paketinin ayarlari AYNEN korunur (farkli
# anahtarlar, cakisma yok).
#
# Geri alma: RECOVERY.md

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "HATA: root olarak calistirin:  sudo bash $0" >&2
  exit 1
fi

# Kaynak dosyalar betigin kendi konumundan bulunur; makineye ozel yol yoktur.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Yedek dizini: TOOLKIT_BACKUP_DIR ile degistirilebilir. Varsayilan, betigi
# sudo ile calistiran kullanicinin XDG state dizini.
_owner="${SUDO_USER:-root}"
_home="$(getent passwd "$_owner" | cut -d: -f6)"
BACKUP_ROOT="${TOOLKIT_BACKUP_DIR:-${_home:-/root}/.local/state/homelab-toolkit/backups}"
BACKUP="$BACKUP_ROOT/${STAMP}-swap-fix"
mkdir -p "$BACKUP"

say() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- 0. yedek
say "Yedek: $BACKUP"
sysctl -a 2>/dev/null | grep -E '^vm\.(swappiness|min_free_kbytes|watermark_scale_factor|compaction_proactiveness|dirty_)' \
  > "$BACKUP/sysctl-vm.before.txt" || true
cp -a /proc/swaps          "$BACKUP/swaps.before.txt"
cp -a /proc/meminfo        "$BACKUP/meminfo.before.txt"
grep -E 'pswpin|pswpout|pgmajfault|compact_' /proc/vmstat > "$BACKUP/vmstat.before.txt"
ls -la /etc/sysctl.d/      > "$BACKUP/sysctl.d-listing.before.txt"
echo "$BACKUP" > /tmp/swap-fix-last-backup
echo "  onceki swappiness: $(cat /proc/sys/vm/swappiness)"

# ------------------------------------------------------- 1. swappiness
say "1/2  vm.swappiness -> 10"
DST=/etc/sysctl.d/99-swap-tuning.conf
if [ -e "$DST" ]; then cp -a "$DST" "$BACKUP/$(basename $DST).orig"; fi
install -m 0644 -o root -g root "$SRC/99-swap-tuning.conf" "$DST"
sysctl --load="$DST"

# wifi-usb-fix degerlerinin bozulmadigini dogrula
say "    wifi-usb-fix ayarlari hala yerinde mi?"
for k in min_free_kbytes watermark_scale_factor compaction_proactiveness; do
  printf '    %-28s %s\n' "$k" "$(cat /proc/sys/vm/$k)"
done

# ------------------------------------------------------- 2. swap tazeleme
say "2/2  Swap tamponunu bosalt (swapoff + swapon)"

SWAP_USED_KB=$(awk 'NR>1 {s+=$4} END {print s+0}' /proc/swaps)
AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
MARGIN_KB=$((1024 * 1024))   # 1 GiB emniyet payi

echo "    swap kullanimda : $((SWAP_USED_KB / 1024)) MiB"
echo "    MemAvailable    : $((AVAIL_KB / 1024)) MiB"
echo "    gereken         : $(((SWAP_USED_KB + MARGIN_KB) / 1024)) MiB"

if [ "$SWAP_USED_KB" -eq 0 ]; then
  echo "    -> swap zaten bos, bir sey yapilmadi"
elif [ "$AVAIL_KB" -lt $((SWAP_USED_KB + MARGIN_KB)) ]; then
  echo "    !! IPTAL: yeterli bos RAM yok. swapoff sistemi kilitleyebilirdi." >&2
  echo "    !! swappiness degisikligi uygulandi, swap tazeleme ATLANDI." >&2
  echo "    !! Daha sonra bos bir anda tekrar calistirin." >&2
  exit 0
else
  echo "    -> guvenli, devam ediliyor"
  # swapfile.swap bir systemd unit; swapoff'u dogrudan yapip
  # unit'i yeniden baslatmak en temizi.
  time swapoff /swapfile
  echo "    swapoff tamam, swap bos"
  swapon /swapfile
  echo "    swapon tamam"
  systemctl is-active swapfile.swap >/dev/null 2>&1 \
    && echo "    swapfile.swap unit: active" \
    || systemctl restart swapfile.swap
fi

# ---------------------------------------------------------------- dogrulama
say "Sonuc"
cat /proc/swaps
free -h
printf '\nvm.swappiness = %s\n' "$(cat /proc/sys/vm/swappiness)"

cp -a /proc/swaps   "$BACKUP/swaps.after.txt"
cp -a /proc/meminfo "$BACKUP/meminfo.after.txt"

cat <<EOF

===========================================================
KURULUM TAMAM.

Uygulananlar:
  * vm.swappiness 60 -> 10  (kalici, /etc/sysctl.d/99-swap-tuning.conf)
  * swap tamponu bosaltildi (Frigate sayfalari RAM'e geri cekildi)

wifi-usb-fix ayarlari korundu.

Yedek: $BACKUP
Geri alma: RECOVERY.md
===========================================================
EOF
