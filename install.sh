#!/bin/bash
set -euo pipefail

PKG="snd-hda-codec-cs8409"

# Basis-Verzeichnis = da wo install.sh liegt
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Version aus dkms.conf (im Repo-Root) lesen, sonst Default
if [[ -f "${SCRIPT_DIR}/dkms.conf" ]]; then
  VER="$(grep -E '^PACKAGE_VERSION=' "${SCRIPT_DIR}/dkms.conf" | cut -d'"' -f2)"
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

echo "[*] Quellcode vorbereiten..."
# cirruslogic-Quellen ins DKMS-Buildverzeichnis kopieren
if [[ ! -d "${SCRIPT_DIR}/cirruslogic" ]]; then
  echo "!!! Quellordner cirruslogic/ fehlt im Repo"
  exit 1
fi
if [[ ! -f "${SCRIPT_DIR}/cirruslogic/patch_cs8409.c" ]]; then
  echo "!!! patch_cs8409.c fehlt im Ordner cirruslogic/"
  exit 1
fi

sudo mkdir -p "$SRC"
sudo rsync -a "${SCRIPT_DIR}/cirruslogic/" "$SRC/"

# dkms.conf und evtl. Makefile mitnehmen
if [[ -f "${SCRIPT_DIR}/dkms.conf" ]]; then
  sudo cp "${SCRIPT_DIR}/dkms.conf" "$SRC/"
fi
if [[ -f "${SCRIPT_DIR}/cirruslogic/Makefile" ]]; then
  sudo cp "${SCRIPT_DIR}/cirruslogic/Makefile" "$SRC/"
fi

cd "$SRC"

echo "[*] DKMS registrieren..."
sudo dkms add -m "$PKG" -v "$VER"

echo "[*] Modul bauen..."
sudo dkms build -m "$PKG" -v "$VER"

echo "[*] Modul installieren..."
sudo dkms install -m "$PKG" -v "$VER"

echo "[*] Modul laden..."
sudo modprobe -r snd-hda-codec-cs8409 2>/dev/null || true
if ! sudo modprobe snd-hda-codec-cs8409; then
  echo "!! Modul konnte nicht geladen werden. Ist Secure Boot aktiv?"
fi

echo
echo "[✓] Fertig."
echo "Prüfen mit:"
echo "  lsmod | grep cs8409"
echo "  dmesg | grep -i cs8409"
