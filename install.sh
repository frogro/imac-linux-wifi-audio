#!/bin/bash
set -e

PKG=snd-hda-codec-cs8409
VER=1.0
SRC="/usr/src/${PKG}-${VER}"

echo "[*] Abhängigkeiten installieren..."
sudo apt-get update
sudo apt-get install -y build-essential dkms \
    linux-headers-$(uname -r) git curl wget ca-certificates

echo "[*] Alte Installation entfernen (falls vorhanden)..."
sudo dkms remove -m "$PKG" -v "$VER" --all 2>/dev/null || true
sudo rm -rf "$SRC"

echo "[*] Quellcode nach /usr/src kopieren..."
mkdir -p "$SRC"
# Falls dein Repo lokal liegt:
# rsync -av ./dkms/$PKG/ "$SRC/"
# oder Repo klonen (Beispiel egorenar):
git clone https://github.com/egorenar/snd-hda-codec-cs8409.git /tmp/$PKG
rsync -av /tmp/$PKG/ "$SRC/"
rm -rf /tmp/$PKG

echo "[*] patch_cs8409.c holen..."
cd "$SRC"
if [ ! -f patch_cs8409.c ]; then
    bash -x ./fetch_cs8409.sh || {
        echo "!!! Fehler beim Holen von patch_cs8409.c"
        exit 1
    }
fi

echo "[*] DKMS-Quellcode registrieren..."
sudo dkms add -m "$PKG" -v "$VER"

echo "[*] Modul bauen..."
sudo dkms build -m "$PKG" -v "$VER"

echo "[*] Modul installieren..."
sudo dkms install -m "$PKG" -v "$VER"

echo "[*] Fertig. Lade das Modul neu:"
echo "  sudo modprobe snd-hda-codec-cs8409"
