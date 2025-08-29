#!/bin/bash
set -euo pipefail

PKG="snd-hda-codec-cs8409"

# Version aus dkms.conf lesen, falls vorhanden
if [[ -f dkms.conf ]]; then
  VER="$(grep -E '^PACKAGE_VERSION=' dkms.conf | cut -d'"' -f2)"
else
  VER="1.0-6.12"
fi

SRC="/usr/src/${PKG}-${VER}"

echo "[*] Abhängigkeiten installieren..."
sudo apt-get update
sudo apt-get install -y build-essential dkms \
    "linux-headers-$(uname -r)" git curl wget ca-certificates rsync

echo "[*] Alte DKMS-Installation (falls vorhanden) entfernen..."
sudo dkms remove -m "$PKG" -v "$VER" --all 2>/dev/null || true
sudo rm -rf "$SRC"

echo "[*] Quellcode nach ${SRC} kopieren..."
# → wir verwenden deine lokalen cirruslogic-Dateien, nicht mehr egorenar-Git
sudo mkdir -p "$SRC"
sudo rsync -a cirruslogic/ "$SRC/"

# dkms.conf und Makefile mitnehmen
if [[ -f dkms.conf ]]; then
  sudo cp dkms.conf "$SRC/"
fi
if [[ -f cirruslogic/Makefile ]]; then
  sudo cp cirruslogic/Makefile "$SRC/"
fi

cd "$SRC"

# Sanity-Check
if [[ ! -f patch_cs8409.c ]]; then
  echo "!!! patch_cs8409.c fehlt weiterhin in $SRC"
  exit 1
fi

echo "[*] DKMS registrieren..."
sudo dkms add -m "$PKG" -v "$VER"

echo "[*] Modul bauen..."
sudo dkms build -m "$PKG" -v "$VER"

echo "[*] Modul installieren..."
sudo dkms install -m "$PKG" -v "$VER"

echo "[*] Modul laden..."
if lsmod | grep -q '^snd_hda_codec_cs8409'; then
  sudo modprobe -r snd-hda-codec-cs8409 || true
fi
sudo modprobe snd-hda-codec-cs8409 || {
  echo "!! Hinweis: Modul konnte nicht geladen werden. Secure Boot aktiv?"
}

echo
echo "[✓] Fertig."
echo "Prüfen mit:"
echo "  lsmod | grep cs8409"
echo "  dmesg | grep -i cs8409"
