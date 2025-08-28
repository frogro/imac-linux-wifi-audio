#!/usr/bin/env bash
set -euo pipefail
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Bitte mit sudo/root ausführen."; exit 1; }; }
need_root

STATE_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST="${STATE_DIR}/manifest.txt"
DKMS_NAME="snd-hda-codec-cs8409"
DKMS_VER="1.0"

echo "==> DKMS-Modul entfernen…"
dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VER}"

echo "==> Installierte WLAN-Firmware-Dateien entfernen (laut Manifest)…"
if [ -f "$MANIFEST" ]; then
  awk '/^\/lib\/firmware\/brcm\//{print $1}' "$MANIFEST" | while read -r f; do
    if [ -L "$f" ] || [ -f "$f" ]; then
      rm -f "$f"
      echo "  removed: $f"
    fi
  done
else
  echo "WARN: Kein Manifest gefunden – lasse Firmware unangetastet."
fi

echo "==> Module neu laden (best effort)…"
modprobe -r brcmfmac 2>/dev/null || true
modprobe brcmfmac 2>/dev/null || true

echo "==> Aufräumen…"
rm -rf "$STATE_DIR"

echo
echo "✔ Deinstallation abgeschlossen."
echo "Du kannst ggf. neu starten."
