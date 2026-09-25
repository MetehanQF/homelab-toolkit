#!/bin/bash
# /usr/local/bin/wifi-usb-watchdog.sh
#
# rtw88_usb TX yolu kilitlendiginde ("failed to get tx report from firmware")
# surucunun kendi kurtarma yolu yoktur; sadece USB yeniden numaralandirma
# canlandirir. Bu script fiziksel cikar-tak yerine sysfs uzerinden ayni
# islemi yapar.
#
# Saglikli durumda HICBIR SEY yapmaz.

set -uo pipefail

USB_ID="2357:0138"                     # TP-Link 802.11ac NIC (RTL8822BU)
STATE_DIR="/run/wifi-usb-watchdog"
FAIL_FILE="$STATE_DIR/consecutive_failures"
LAST_RESET="$STATE_DIR/last_reset"
FAIL_THRESHOLD=3                       # 3 ardisik tur (~90 s) sonra reset
RESET_COOLDOWN=300                     # ayni resetten en az 5 dk sonra tekrar

mkdir -p "$STATE_DIR"

log() { logger -t wifi-usb-watchdog "$*"; }

# --- TP-Link cihazinin sysfs yolunu dinamik bul (port degisse de calisir) ---
find_usb_path() {
  local vid="${USB_ID%:*}" pid="${USB_ID#*:}" d
  for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
    [ -f "$d/idVendor" ] || continue
    if [ "$(cat "$d/idVendor" 2>/dev/null)" = "$vid" ] &&
       [ "$(cat "$d/idProduct" 2>/dev/null)" = "$pid" ]; then
      echo "$d"; return 0
    fi
  done
  return 1
}

# --- Bu cihaza ait ag arayuzunu bul ---
find_iface() {
  local usb_path="$1" n
  for n in "$usb_path"/*/net/*; do
    [ -e "$n" ] && basename "$n" && return 0
  done
  return 1
}

USB_PATH="$(find_usb_path)" || { log "TP-Link $USB_ID bulunamadi (fiziksel olarak cikarilmis?) - atlandi"; exit 0; }
IFACE="$(find_iface "$USB_PATH")"      || { log "$USB_PATH icin ag arayuzu yok - atlandi"; exit 0; }

# --- Saglik testi: varsayilan gecidi bu arayuz uzerinden yokla ---
GW="$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')"
if [ -z "$GW" ]; then
  log "$IFACE uzerinde varsayilan gecit yok - atlandi (DHCP/NM isi)"
  exit 0
fi

if ping -c 2 -W 2 -I "$IFACE" "$GW" >/dev/null 2>&1; then
  # Saglikli: sayaci sifirla
  [ -f "$FAIL_FILE" ] && rm -f "$FAIL_FILE"
  exit 0
fi

# --- Basarisiz: ardisik sayaci arttir ---
FAILURES=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$FAILURES" > "$FAIL_FILE"

# Surucu kilitlenmesine ozgu imza var mi? Varsa esigi beklemeden mudahale et.
WEDGED=0
if journalctl -k --since "-3 min" --no-pager 2>/dev/null \
     | grep -q "failed to get tx report from firmware"; then
  WEDGED=1
fi

if [ "$WEDGED" -eq 0 ] && [ "$FAILURES" -lt "$FAIL_THRESHOLD" ]; then
  log "$IFACE -> $GW yok ($FAILURES/$FAIL_THRESHOLD, surucu imzasi yok) - bekleniyor"
  exit 0
fi

# --- Bekleme suresi (ayni anda tekrar tekrar resetlemeyi onle) ---
NOW=$(date +%s)
PREV=$(cat "$LAST_RESET" 2>/dev/null || echo 0)
if [ $(( NOW - PREV )) -lt "$RESET_COOLDOWN" ]; then
  log "$IFACE hala erisilemez ama son reset $(( NOW - PREV )) s once - bekleniyor"
  exit 0
fi

# --- Yazilimsal 'cikar-tak': USB portunu yetkisizlestirip geri ver ---
if [ "$WEDGED" -eq 1 ]; then
  REASON="rtw88_usb TX kilitlenmesi (tx report hatasi)"
else
  REASON="$FAILURES ardisik gecit erisim hatasi"
fi
log "RESET baslatiliyor: $REASON | cihaz=$USB_PATH arayuz=$IFACE gecit=$GW"
echo "$NOW" > "$LAST_RESET"

if ! echo 0 > "$USB_PATH/authorized" 2>/dev/null; then
  log "HATA: $USB_PATH/authorized yazilamadi (root gerekli)"
  exit 1
fi
sleep 3
echo 1 > "$USB_PATH/authorized" 2>/dev/null

# --- Geri gelmesini bekle (yeniden iliskilendirme ~25-30 s suruyor) ---
for i in $(seq 1 24); do
  sleep 5
  NEW_PATH="$(find_usb_path)" || continue
  NEW_IFACE="$(find_iface "$NEW_PATH")" || continue
  NEW_GW="$(ip -4 route show default dev "$NEW_IFACE" 2>/dev/null | awk '{print $3; exit}')"
  if [ -n "$NEW_GW" ] && ping -c 2 -W 2 -I "$NEW_IFACE" "$NEW_GW" >/dev/null 2>&1; then
    log "KURTARILDI: $NEW_IFACE ${i}. denemede ($(( i * 5 )) s) geri geldi, gecit=$NEW_GW"
    rm -f "$FAIL_FILE"
    exit 0
  fi
done

log "UYARI: reset sonrasi 120 s icinde baglanti geri gelmedi - fiziksel mudahale gerekebilir"
exit 1
