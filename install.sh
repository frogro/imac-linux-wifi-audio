#!/usr/bin/env bash
set -Eeuo pipefail

echo "------------------------------------------"
echo " iMac Late 2019 - Debian 13 Install Script"
echo "------------------------------------------"
echo
echo "Bitte auswählen:"
echo "  1) WLAN + Audio"
echo "  2) nur WLAN"
echo "  3) nur Audio"
echo

read -rp "Deine Auswahl [1-3]: " choice

case "$choice" in
  1)
    DO_WIFI=1
    DO_AUDIO=1
    ;;
  2)
    DO_WIFI=1
    DO_AUDIO=0
    ;;
  3)
    DO_WIFI=0
    DO_AUDIO=1
    ;;
  *)
    echo "Ungültige Auswahl!"
    exit 1
    ;;
esac

# --------------------------------------------------
# Gemeinsame Abhängigkeiten
# --------------------------------------------------
echo "[*] Abhängigkeiten installieren..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential dkms rsync git curl wget ca-certificates \
  "linux-headers-$(uname -r)"

# --------------------------------------------------
# WLAN Teil
# --------------------------------------------------
if [[ "$DO_WIFI" -eq 1 ]]; then
  echo "[*] WLAN-Teil installieren..."
  # hier käme dein Broadcom/Apple brcmfmac Workflow
  # z.B. Firmware nach /lib/firmware/brcm/ kopieren
  # oder eigene DKMS Module für WLAN
  echo "[!] WLAN-Installation noch TODO (Firmware/Module)."
fi

# --------------------------------------------------
# Audio Teil (unser cs8409-DKMS Build)
# --------------------------------------------------
if [[ "$DO_AUDIO" -eq 1 ]]; then
  echo "[*] Audio-Teil installieren..."
  # ---- hier rufst du unser cs8409-Install-Skript auf ----
  bash ./install_audio.sh
fi

echo
echo "[✓] Alles fertig."
