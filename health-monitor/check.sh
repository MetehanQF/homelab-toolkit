#!/bin/bash
# Pi5 saglik kontrolu - WiFi/bellek duzeltmelerinin tutup tutmadigini olcer.
#
# Kullanim:  ./check.sh [pencere]     ornek: ./check.sh 24h   (varsayilan 24h)
#
# Root GEREKTIRMEZ. Sistemde hicbir sey degistirmez. Tek yazdigi sey kendi
# dizinindeki .mem-counters (baski delta'si icin onceki vmstat sayaclari).
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
# Kurulumdan BERI olanlar (duzeltmenin gercek karnesi).
# `journalctl -k` SADECE mevcut boot'u gosterir; yeniden baslatmadan sonra bu
# sutun sessizce uptime kadar daralir (10-02 ve 10-03 turlarinda 244h/268h
# yerine 8h/17h kapsiyordu). `_TRANSPORT=kernel` tum boot'lari tarar.
# 2026-10-04'te order-3 esigi kaldirilinca allocation failure ASIL kilitlenme
# olcutu oldu, dolayisiyla bu sutunun dogru olmasi artik zorunlu.
TX_SINCE=$(journalctl _TRANSPORT=kernel --since "@$FIX_EPOCH" --no-pager 2>/dev/null | grep -ci "failed to get tx report" || true)
ALLOC_SINCE=$(journalctl _TRANSPORT=kernel --since "@$FIX_EPOCH" --no-pager 2>/dev/null | grep -ci "page allocation failure" || true)

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
# 144 gosterdi, 60 sn sonra ~1360'ti. Bu yuzden 5 ornek alip medyani kullan.
#
# ORDER-3 SAYACI TEK BASINA OLCUT DEGIL (2026-10-04'te esik buradan tasindi).
# O sayac "hazir 32KB blok adedi"dir, "32KB bulunabilir mi"nin cevabi degil:
# buddy allocator order-3 istegini ust order'i BOLEREK karsilar. Bellek order-10
# blok halinde bozulmadan dururken order-3 sayaci 2'ye kadar duser ve bu
# parcalanma DEGIL, tersidir. Eski esik (<100 / <30) 10-02..10-04 arasinda 10 kez
# calip 4 CRITICAL uretti, hepsi yanlis alarmdi.
# Gercek olcut: (a) her iki zone'daki >=order-3 TOPLAM bitisik havuz,
# (b) compaction/geri kazanim basarisizliginin ARTIS HIZI. Kilitlenmenin asil
# imzasi olan "page allocation failure" 1. bolumde zaten CRITICAL.
_median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

# tum zone'lardaki >=order-3 bos bellegi MB olarak topla (sayfa 4KB varsayimi)
_pool_mb() {
  awk '/zone/{for(o=3;o<=10;o++) t+=$(o+5)*(4*2^o)/1024} END{printf "%d", t}' /proc/buddyinfo 2>/dev/null
}
POOL_SAMPLES=(); O3_SAMPLES=(); O4_SAMPLES=()
for _i in 1 2 3 4 5; do
  POOL_SAMPLES+=("$(_pool_mb)")
  O3_SAMPLES+=("$(awk '/zone *Normal/{print $8}' /proc/buddyinfo 2>/dev/null)")
  O4_SAMPLES+=("$(awk '/zone *Normal/{print $9}' /proc/buddyinfo 2>/dev/null)")
  [ "$_i" -lt 5 ] && sleep 2
done
POOL_MB=$(_median "${POOL_SAMPLES[@]}")
POOL_MIN=$(printf '%s\n' "${POOL_SAMPLES[@]}" | sort -n | head -1)
ORDER3=$(_median "${O3_SAMPLES[@]}")
ORDER4=$(_median "${O4_SAMPLES[@]}")
read -r CS CF CSU < <(awk '/^compact_stall/{s=$2} /^compact_fail/{f=$2} /^compact_success/{u=$2} END{print s+0, f+0, u+0}' /proc/vmstat)
AS_NORMAL=$(awk '/^allocstall_normal/{print $2+0}' /proc/vmstat)
SWAP_TOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
SWAP_PCT=0
[ "${SWAP_TOTAL:-0}" -gt 0 ] && SWAP_PCT=$(( (SWAP_TOTAL - SWAP_FREE) * 100 / SWAP_TOTAL ))
AVAIL_MB=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))

# --- baski ARTIS HIZI: mutlak sayac degil delta onemli ---
# Kendi dizinindeki tek sayac dosyasini yazar (sistemde hicbir sey degistirmez).
# Yeniden baslatmada sayaclar sifirlanir; negatif delta = reboot, atlanir.
PREV_STATE="$(dirname "$(readlink -f "$0")")/.mem-counters"
NOW_EPOCH=$(date +%s)
# SWAP DOLULUGU OLCUT DEGIL (2026-10-07'de esik buradan kaldirildi).
# Swap 1 GB; kernel bosta duran sayfalari (whisper, frigate yardimci surecleri)
# bir kez iter ve geri istemez. %90 doluyken MemAvailable 6.6 GB, si/so=0,
# PSI=0, 4 gunde toplam swap-in 875 sayfa idi. Eski "%60 ustu" esigi 37 kez
# bildirim gonderdi, hepsi yanlis alarmdi. Gercek olcut: swap'tan GERI OKUMA
# hizi (pswpin) + bellek basinci (PSI memory 'some' stall suresi).
SWIN=$(awk '/^pswpin/{print $2+0}' /proc/vmstat)
PSI_US=$(awk '/^some/{for(i=1;i<=NF;i++) if($i~/^total=/){sub("total=","",$i); print $i+0}}' /proc/pressure/memory 2>/dev/null)
CF_DELTA=-1; AS_DELTA=-1; DELTA_MIN=0
SWIN_PER_MIN=-1; PSI_PCT=-1
if [ -r "$PREV_STATE" ]; then
  read -r P_EPOCH P_CF P_AS P_SWIN P_PSI < "$PREV_STATE" 2>/dev/null || true
  if [ -n "${P_CF:-}" ] && [ "$CF" -ge "${P_CF:-0}" ] && [ "$AS_NORMAL" -ge "${P_AS:-0}" ]; then
    CF_DELTA=$(( CF - P_CF ))
    AS_DELTA=$(( AS_NORMAL - P_AS ))
    DELTA_MIN=$(( (NOW_EPOCH - P_EPOCH) / 60 ))
  fi
  # Hiz olcutleri kisa aralikta gurultulu (elle ust uste calistirma); en az 2 dk.
  DELTA_SEC=$(( NOW_EPOCH - ${P_EPOCH:-NOW_EPOCH} ))
  if [ "$DELTA_SEC" -ge 120 ] && [ -n "${P_SWIN:-}" ] && [ "$SWIN" -ge "$P_SWIN" ]; then
    SWIN_PER_MIN=$(( (SWIN - P_SWIN) * 60 / DELTA_SEC ))
  fi
  if [ "$DELTA_SEC" -ge 120 ] && [ -n "${P_PSI:-}" ] && [ -n "${PSI_US:-}" ] && [ "$PSI_US" -ge "$P_PSI" ]; then
    # stall mikrosaniyesi / aralik mikrosaniyesi * 100
    PSI_PCT=$(( (PSI_US - P_PSI) / (DELTA_SEC * 10000) ))
  fi
fi
printf '%s %s %s %s %s\n' "$NOW_EPOCH" "$CF" "$AS_NORMAL" "$SWIN" "${PSI_US:-0}" > "$PREV_STATE" 2>/dev/null || true

note "--- bellek / parcalanma ---"
note ">=order-3 havuz     : ${POOL_MB:-?} MB (medyan/5, en dusuk ${POOL_MIN:-?})  <- rtw88'in 32KB istegini karsilayan GERCEK rezerv"
note "order-3 blok (32KB) : ${ORDER3:-?} (medyan) - bilgi amacli, tek basina olcut DEGIL"
note "order-4 blok (64KB) : ${ORDER4:-?} (medyan)"
note "compaction          : stall=$CS fail=$CF success=$CSU"
if [ "$CF_DELTA" -ge 0 ]; then
  note "baski artisi        : compact_fail +${CF_DELTA} / allocstall_normal +${AS_DELTA} (son ${DELTA_MIN} dk)"
else
  note "baski artisi        : OLCULEMEDI (ilk calisma veya yeniden baslatma)"
fi
note "swap kullanimi      : %$SWAP_PCT - bilgi amacli, tek basina olcut DEGIL"
if [ "$SWIN_PER_MIN" -ge 0 ]; then
  note "swap geri okuma     : ${SWIN_PER_MIN} sayfa/dk"
  note "bellek basinci (PSI): %${PSI_PCT} (aralikta bellek bekleyen sure)"
else
  note "swap geri okuma/PSI : OLCULEMEDI (ilk calisma, reboot veya aralik < 2 dk)"
fi
note "MemAvailable        : ${AVAIL_MB} MiB"
# Esik kalibrasyonu: fix sonrasi olculen en kotu havuz ~365 MB (10-02), tipik
# 0.7-7.2 GB. 200 MB o en kotunun altinda, yani normal dalgalanmada calmaz.
# 64 MB'da rtw88 icin hala ~2000 adet 32KB blok karsiligi var.
[ "${POOL_MB:-999999}" -lt 64 ]  && warn "bitisik bellek havuzu KRITIK (${POOL_MB} MB) - rtw88 kilitlenme riski"
[ "${POOL_MB:-999999}" -lt 200 ] && [ "${POOL_MB:-0}" -ge 64 ] && warn "bitisik bellek havuzu dusuk (${POOL_MB} MB) - parcalanma geri geliyor"
[ "$CF_DELTA" -ge 100 ] && warn "compaction basarisizligi artiyor (+${CF_DELTA} / ${DELTA_MIN} dk) - cekirdek yuksek order icin zorlaniyor"
[ "$AS_DELTA" -ge 100 ] && warn "dogrudan geri kazanim artiyor (allocstall +${AS_DELTA} / ${DELTA_MIN} dk) - bellek baskisi"
# 1000 sayfa/dk ~= 4 MiB/dk surekli diskten geri okuma: calisan surecler artik
# swap'a itilen bellegi geri istiyor (thrashing baslangici). Olculen normal ~0.
[ "$SWIN_PER_MIN" -ge 1000 ] && warn "swap'tan geri okuma yuksek (${SWIN_PER_MIN} sayfa/dk) - RAM yetmiyor"
# Araligin %5'inden fazlasinda en az bir surec bellek bekledi. Olculen normal 0.
[ "$PSI_PCT" -ge 5 ]         && warn "bellek basinci yuksek (PSI %${PSI_PCT}) - surecler bellek bekliyor"
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
