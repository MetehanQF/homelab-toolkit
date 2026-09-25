#!/bin/bash
# Sistem seviyesindeki GNOME Remote Desktop'i kapatir (port 3389).
# Oturum seviyesindeki daemon (port 3390) zaten kapatildi, bu root istiyor.
# Geri almak icin: enable-system-rdp.sh
set -uo pipefail

echo "=== ONCE ==="
ss -tln 2>/dev/null | grep -q ':3389' && echo "  3389: ACIK" || echo "  3389: kapali"
echo "  servis: $(systemctl is-active gnome-remote-desktop.service 2>/dev/null) / $(systemctl is-enabled gnome-remote-desktop.service 2>/dev/null)"

echo
echo "=== UYGULANIYOR ==="
echo "-> grdctl --system rdp disable"
grdctl --system rdp disable && echo "   RDP arka ucu kapatildi"
echo "-> systemctl disable --now gnome-remote-desktop.service"
systemctl disable --now gnome-remote-desktop.service 2>&1 | sed 's/^/   /'
# soket aktivasyonu varsa o da kapansin
systemctl disable --now gnome-remote-desktop.socket 2>/dev/null | sed 's/^/   /' || true

sleep 2
echo
echo "=== SONRA ==="
if ss -tln 2>/dev/null | grep -q ':3389'; then
  echo "  3389: HALA ACIK  <<< beklenmeyen, rapor et"
  RC=1
else
  echo "  3389: KAPALI"
  RC=0
fi
echo "  servis: $(systemctl is-active gnome-remote-desktop.service 2>/dev/null) / $(systemctl is-enabled gnome-remote-desktop.service 2>/dev/null)"

echo
echo "=== SSH SAGLAM MI (erisimi kaybetmedigini dogrula) ==="
ss -tln 2>/dev/null | grep -qE '(^|\s)(0\.0\.0\.0|\*):22\s' && echo "  SSH 22: ACIK - erisim guvende" || echo "  SSH 22: KAPALI <<< DIKKAT"

exit $RC
