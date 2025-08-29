#!/bin/bash
set -euo pipefail

PKG=snd-hda-codec-cs8409
VER=1.0
SRC="/usr/src/${PKG}-${VER}"

echo "[*] Abhängigkeiten installieren..."
sudo apt-get update
sudo apt-get install -y build-essential dkms \
    linux-headers-$(uname -r) git curl wget ca-certificates

echo "[*] Alte DKMS-Installation (falls vorhanden) entfernen..."
sudo dkms remove -m "$PKG" -v "$VER" --all 2>/dev/null || true
sudo rm -rf "$SRC"

echo "[*] Quellcode klonen und nach ${SRC} kopieren..."
git clone https://github.com/egorenar/snd-hda-codec-cs8409.git /tmp/$PKG
sudo mkdir -p "$SRC"
sudo rsync -a /tmp/$PKG/ "$SRC/"
rm -rf /tmp/$PKG

cd "$SRC"

# Falls das Repo bereits patch_cs8409.c enthält, überspringen wir fetch.
if [[ ! -f patch_cs8409.c ]] && [[ -x ./fetch_cs8409.sh ]]; then
  echo "[*] patch_cs8409.c via fetch_cs8409.sh holen..."
  sudo bash -x ./fetch_cs8409.sh
fi

# --- DKMS-Metadateien erzeugen ---
echo "[*] dkms.conf schreiben..."
sudo tee "$SRC/dkms.conf" >/dev/null <<'DKMSCONF'
PACKAGE_NAME="snd-hda-codec-cs8409"
PACKAGE_VERSION="1.0"

BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"
DEST_MODULE_LOCATION[0]="/kernel/sound/pci/hda"

# DKMS ruft MAKE mit $kernelver auf – sorgen wir für KDIR
MAKE[0]="make KDIR=/lib/modules/${kernelver}/build"
CLEAN="make clean"

AUTOINSTALL="yes"
DKMSCONF

echo "[*] DKMS-Wrapper-Makefile schreiben..."
sudo tee "$SRC/Makefile" >/dev/null <<'KBUILDWRAP'
# Kbuild-Wrapper für DKMS
KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := snd-hda-codec-cs8409.o
snd-hda-codec-cs8409-objs := patch_cs8409.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
KBUILDWRAP

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
sudo modprobe snd-hda-codec-cs8409 || true

echo
echo "[✓] Fertig."
echo "Prüfen mit:"
echo "  lsmod | grep cs8409"
echo "  dmesg | grep -i cs8409"
