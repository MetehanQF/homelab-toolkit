#!/bin/bash
# GERI ALMA: sistem seviyesindeki GNOME Remote Desktop'i tekrar acar.
# Oturum seviyesi ayri; onu geri acmak icin (root gerekmez):
#   gsettings set org.gnome.desktop.remote-desktop.rdp enable true
#   systemctl --user enable --now gnome-remote-desktop.service
set -uo pipefail

echo "-> systemctl enable --now gnome-remote-desktop.service"
systemctl enable --now gnome-remote-desktop.service 2>&1 | sed 's/^/   /'
echo "-> grdctl --system rdp enable"
grdctl --system rdp enable && echo "   RDP arka ucu acildi"

sleep 2
echo
ss -tln 2>/dev/null | grep -q ':3389' && echo "3389: ACIK - geri alindi" || echo "3389: hala kapali <<< kontrol et"
