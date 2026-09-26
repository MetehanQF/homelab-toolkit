#!/bin/bash
# Pi5 saglik kontrolu - WiFi/bellek duzeltmelerinin tutup tutmadigini olcer.
#
# Kullanim:  ./check.sh [pencere]     ornek: ./check.sh 24h   (varsayilan 24h)
#
# Root GEREKTIRMEZ. Hicbir sey degistirmez, sadece okur.
# Cikis kodu:  0 = OK,  1 = WARN (incelenmeli)

set -uo pipefail
WINDOW="${1:-24h}"

# WiFi/bellek duzeltmesinin kurulum ani = sysctl dosyasinin mtime'i
FIXCONF=/etc/sysctl.d/99-wifi-usb-mem-stability.conf
if [ -e "$FIXCONF" ]; then
  FIX_EPOCH=$(stat -c %Y "$FIXCONF")
  FIX_HUMAN=$(date -d "@$FIX_EPOCH" '+%Y-%m-%d %H:%M')
  FIX_AGE_H=$(( ( $(date +%s) - FIX_EPOCH ) / 3600 ))
else
  FIX_EPOCH=0; FIX_HUMAN="KURULU DEGIL"; FIX_AGE_H=0
fi

WARN=0
note() { printf '%s\n' "$*"; }
warn() { WARN=1; printf 'UYARI: %s\n' "$*"; }

note "=== Pi5 saglik kontrolu ($(date '+%Y-%m-%d %H:%M')) ==="
note "wifi-usb-fix kurulum: $FIX_HUMAN  (${FIX_AGE_H} saat once)"
note "olcum penceresi     : son $WINDOW"
note ""

# ---------------------------------------------------------------- 1. WiFi
TX=$(journalctl -k --since "$WINDOW ago" --no-pager 2>/dev/null | grep -ci "failed to get tx report" || true)
ALLOC=$(journalctl -k --since "$WINDOW ago" --no-pager 2>/dev/null | grep -ci "page allocation failure" || true)
# Kurulumdan BERI olanlar (duzeltmenin gercek karnesi)
TX_SINCE=$(journalctl -k --since "@$FIX_EPOCH" --no-pager 2>/dev/null | grep -ci "failed to get tx report" || true)
ALLOC_SINCE=$(journalctl -k --since "@$FIX_EPOCH" --no-pager 2>/dev/null | grep -ci "page allocation failure" || true)

note "--- WiFi / bellek hatalari ---"
note "tx report hatasi    : $TX (son $WINDOW) | $TX_SINCE (kurulumdan beri)"
note "allocation failure  : $ALLOC (son $WINDOW) | $ALLOC_SINCE (kurulumdan beri)"
[ "$TX_SINCE" -gt 0 ]    && warn "kurulumdan beri $TX_SINCE adet tx report hatasi - duzeltme yetmiyor olabilir"
[ "$ALLOC_SINCE" -gt 0 ] && warn "kurulumdan beri $ALLOC_SINCE adet allocation failure"

# watchdog mudahale etti mi
WD=$(journalctl -t wifi-usb-watchdog --since "$WINDOW ago" --no-pager 2>/dev/null | grep -ci "reset\|authorized\|recover" || true)
WD_ACTIVE=$(systemctl is-active wifi-usb-watchdog.timer 2>/dev/null)
note "watchdog timer      : $WD_ACTIVE"
note "watchdog mudahale   : $WD (son $WINDOW)"
[ "$WD_ACTIVE" != "active" ] && warn "wifi-usb-watchdog.timer calismiyor"
[ "$WD" -gt 0 ] && warn "watchdog $WD kez mudahale etti - dongle hala takiliyor"

# baglanti canli mi
GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
if [ -n "${GW:-}" ]; then
  # ping cap_net_raw ister. NoNewPrivileges=true altinda (or. systemd servisi)
  # yetki hatasi verir; bu "gecit olu" demek DEGILDIR. 2026-09-24'te bu ayrim
  # yokken servis sahte CRITICAL uretti. Yetki hatasini erisilemezlikten ayir.
  PING_ERR=$(ping -c2 -W2 "$GW" 2>&1 >/dev/null)
  PING_RC=$?
  if [ "$PING_RC" -eq 0 ]; then
    RTT=$(ping -c3 -W2 "$GW" 2>/dev/null | tail -1 | cut -d'=' -f2)
    note "gecit ($GW)  : ERISILEBILIR ${RTT:-}"
  elif printf '%s' "$PING_ERR" | grep -qi "not permitted\|cap_net_raw\|setuid"; then
    note "gecit ($GW)  : OLCULEMEDI (ping yetkisi yok - uyari uretilmiyor)"
  else
    warn "gecit $GW PING'E YANIT VERMIYOR"
  fi
fi
note ""

# ---------------------------------------------------- 2. bellek / parcalanma
# buddyinfo ANLIK dalgalanir: tek ornek yaniltir. 2026-09-23'te tek ornek
# 144 gosterdi, 60 sn sonra ~1360'ti. Bu yuzden 5 ornek alip medyani kullan,
# en dusugu de ayrica raporla.
_median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
O3_SAMPLES=(); O4_SAMPLES=()
for _i in 1 2 3 4 5; do
  O3_SAMPLES+=("$(awk '/zone *Normal/{print $8}' /proc/buddyinfo 2>/dev/null)")
  O4_SAMPLES+=("$(awk '/zone *Normal/{print $9}' /proc/buddyinfo 2>/dev/null)")
  [ "$_i" -lt 5 ] && sleep 2
done
ORDER3=$(_median "${O3_SAMPLES[@]}")
ORDER4=$(_median "${O4_SAMPLES[@]}")
ORDER3_MIN=$(printf '%s\n' "${O3_SAMPLES[@]}" | sort -n | head -1)
read -r CS CF CSU < <(awk '/^compact_stall/{s=$2} /^compact_fail/{f=$2} /^compact_success/{u=$2} END{print s, f, u}' /proc/vmstat)
SWAP_TOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
SWAP_PCT=0
[ "${SWAP_TOTAL:-0}" -gt 0 ] && SWAP_PCT=$(( (SWAP_TOTAL - SWAP_FREE) * 100 / SWAP_TOTAL ))
AVAIL_MB=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))

note "--- bellek / parcalanma ---"
note "order-3 blok (32KB) : ${ORDER3:-?} (medyan/5 ornek, en dusuk ${ORDER3_MIN:-?})  <- rtw88'in ihtiyaci, 0 olursa kilitlenir"
note "order-4 blok (64KB) : ${ORDER4:-?} (medyan)"
note "compaction          : stall=$CS fail=$CF success=$CSU"
note "swap kullanimi      : %$SWAP_PCT"
note "MemAvailable        : ${AVAIL_MB} MiB"
[ "${ORDER3:-0}" -lt 100 ] && warn "order-3 medyani dusuk (${ORDER3}) - parcalanma geri geliyor"
[ "${ORDER3_MIN:-0}" -lt 30 ] && warn "order-3 bir ornekte ${ORDER3_MIN}'e dustu - kilitlenme riski"
[ "$SWAP_PCT" -gt 60 ]     && warn "swap %$SWAP_PCT dolu - tampon tukeniyor"
[ "$AVAIL_MB" -lt 1500 ]   && warn "MemAvailable ${AVAIL_MB} MiB - dusuk"
note ""

# ------------------------------------------------------------ 3. genel saglik
TEMP=$(vcgencmd measure_temp 2>/dev/null | tr -d 'temp=')
THROT=$(vcgencmd get_throttled 2>/dev/null | cut -d'=' -f2)
LOAD=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
FAILED=$(systemctl list-units --state=failed --no-pager --plain 2>/dev/null | grep -c "\.service\|\.mount" || true)
NFS_RSIZE=$(findmnt -t nfs4 -o OPTIONS -n 2>/dev/null | tr ',' '\n' | grep -m1 '^rsize=' | cut -d= -f2)
DISK=$(df --output=pcent / 2>/dev/null | tail -1 | tr -d ' %')

note "--- genel ---"
note "sicaklik / throttle : ${TEMP:-?} / ${THROT:-?}"
note "load (1/5/15)       : $LOAD"
note "failed unit         : $FAILED"
note "NFS rsize           : ${NFS_RSIZE:-BAGLI DEGIL}"
note "kok disk kullanimi  : %${DISK:-?}"
[ "${THROT:-0x0}" != "0x0" ] && warn "throttled=$THROT - guc/sicaklik sorunu"
[ "$FAILED" -gt 0 ]          && warn "$FAILED adet failed systemd unit"
[ "${NFS_RSIZE:-0}" != "131072" ] && warn "NFS rsize=${NFS_RSIZE:-yok}, beklenen 131072"
[ "${DISK:-0}" -gt 85 ]      && warn "kok disk %$DISK dolu"

# container saglik
if command -v docker >/dev/null 2>&1; then
  TOTAL_C=$(docker ps -q 2>/dev/null | wc -l)
  BAD_C=$(docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null | grep -c "unhealthy\|Restarting" || true)
  note "container           : $TOTAL_C calisiyor, $BAD_C sorunlu"
  [ "$BAD_C" -gt 0 ] && warn "$BAD_C container unhealthy/restarting"
fi
note ""

if [ "$WARN" -eq 0 ]; then
  note "VERDICT: OK - ${FIX_AGE_H} saattir sorunsuz"
else
  note "VERDICT: WARN - yukaridaki UYARI satirlarina bak"
fi
exit "$WARN"
