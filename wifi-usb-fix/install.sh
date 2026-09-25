#!/bin/bash
# TP-Link USB WiFi (rtw88_usb) kilitlenme duzeltmesi - kurulum
# Calistirma:  sudo bash wifi-usb-fix/install.sh
#
# Yaptigi degisiklikler (hepsi eklemeli, mevcut ayarlar korunur):
#   1. /etc/sysctl.d/99-wifi-usb-mem-stability.conf  (YENI dosya)
#   2. /usr/local/bin/wifi-usb-watchdog.sh           (YENI dosya)
#   3. /etc/systemd/system/wifi-usb-watchdog.{service,timer} (YENI)
#   4. /etc/fstab  -> NFS satirina rsize/wsize=131072 eklenir (tek satir)
#
# Aga DOKUNMAZ, hicbir servisi yeniden baslatmaz, kamera kaydini kesmez.

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
BACKUP="$BACKUP_ROOT/${STAMP}-wifi-usb-fix"
mkdir -p "$BACKUP"

say() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- 0. yedek
say "Yedek: $BACKUP"
cp -a /etc/fstab "$BACKUP/fstab.orig"
sysctl -a 2>/dev/null | grep -E '^vm\.(min_free_kbytes|watermark_scale_factor|compaction_proactiveness|dirty_)' \
  > "$BACKUP/sysctl-vm.before.txt" || true
cat /proc/buddyinfo > "$BACKUP/buddyinfo.before.txt"
echo "$BACKUP" > /tmp/wifi-usb-fix-last-backup

# ------------------------------------------------------- 1. sysctl (bellek)
say "1/4  sysctl ayarlari"
DST=/etc/sysctl.d/99-wifi-usb-mem-stability.conf
if [ -e "$DST" ]; then cp -a "$DST" "$BACKUP/$(basename $DST).orig"; fi
install -m 0644 -o root -g root "$SRC/99-wifi-usb-mem-stability.conf" "$DST"
sysctl --load="$DST"

# --------------------------------------------------------- 2. watchdog script
say "2/4  Otomatik kurtarma scripti"
install -m 0755 -o root -g root "$SRC/wifi-usb-watchdog.sh" /usr/local/bin/wifi-usb-watchdog.sh

# ---------------------------------------------------------- 3. systemd timer
say "3/4  systemd timer (30 saniyede bir kontrol)"
install -m 0644 -o root -g root "$SRC/wifi-usb-watchdog.service" /etc/systemd/system/
install -m 0644 -o root -g root "$SRC/wifi-usb-watchdog.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now wifi-usb-watchdog.timer
systemctl start wifi-usb-watchdog.service   # saglikli durumda hicbir sey yapmaz
systemctl status wifi-usb-watchdog.timer --no-pager | head -n 6

# ------------------------------------------------- 4. NFS rsize/wsize dusur
# OPSIYONEL adim. Yalnizca USB WiFi uzerinden NFS mount'unuz varsa anlamlidir.
# Varsayilan olarak ATLANIR; hangi fstab satirinin duzenlenecegini siz soylersiniz:
#
#   NFS_FSTAB_SOURCE='nfs.example.internal:/srv/share' sudo -E bash install.sh
#
# Deger, fstab'in ILK alanina (kaynak) birebir eslesmelidir.
NFS_FSTAB_SOURCE="${NFS_FSTAB_SOURCE:-}"
NFS_RSIZE="${NFS_RSIZE:-131072}"

if [ -z "$NFS_FSTAB_SOURCE" ]; then
  say "4/4  NFS rsize/wsize — ATLANDI (NFS_FSTAB_SOURCE tanimli degil)"
  echo "  Bu adim opsiyoneldir. USB WiFi uzerinden NFS kullaniyorsaniz:"
  echo "    NFS_FSTAB_SOURCE='sunucu:/paylasim' sudo -E bash \$0"
else
  say "4/4  NFS rsize/wsize -> $NFS_RSIZE (/etc/fstab)"
  # Buyuk rsize (orn. 512 KB) USB2 WiFi uzerinde asiri buyuk scatter-gather
  # zincirleri ve page cache sismesi uretir; 128 KB daha dengeli.
  ESC=$(printf '%s' "$NFS_FSTAB_SOURCE" | sed -e 's/[].[^$*\/]/\\&/g')
  if grep -qE "^${ESC}[[:space:]]" /etc/fstab; then
    if grep -E "^${ESC}[[:space:]]" /etc/fstab | grep -q 'rsize='; then
      echo "  -> rsize zaten tanimli, fstab degistirilmedi"
    else
      sed -i -E "s|^(${ESC}[[:space:]]+\S+[[:space:]]+nfs4?[[:space:]]+)([^[:space:]]+)|\1rsize=${NFS_RSIZE},wsize=${NFS_RSIZE},\2|" /etc/fstab
      echo "  -> yeni satir:"
      grep -nE "^${ESC}[[:space:]]" /etc/fstab | sed 's/^/     /'
    fi
    findmnt --verify --verbose 2>&1 | tail -n 3
  else
    echo "  UYARI: fstab'da '$NFS_FSTAB_SOURCE' satiri bulunamadi, atlandi"
  fi
fi

cat <<'EOF'

===========================================================
KURULUM TAMAM.

Hemen etkili olanlar:
  * sysctl bellek ayarlari  (kilitlenmenin KOK nedenine karsi)
  * otomatik kurtarma timer'i (bir daha fise dokunmaniza gerek yok)

Sonraki yeniden baslatmada / NFS yeniden baglanmasinda etkili:
  * NFS rsize/wsize = 128 KB

NFS'i simdi uygulamak isterseniz (mount kisa sure kesilir):
  systemctl list-units --type=mount | grep nfs      # mount biriminin adini bulun
  sudo systemctl restart '<mount-birimi>.mount'     # tek tirnak sart: ad \x2d icerir
  findmnt -t nfs4 -o TARGET,OPTIONS

Izleme:
  journalctl -t wifi-usb-watchdog -f
  cat /proc/buddyinfo
  grep -E 'compact_(stall|fail|success)' /proc/vmstat

Geri alma:  wifi-usb-fix/RECOVERY.md
===========================================================
EOF
