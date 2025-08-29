#!/bin/bash
set -euo pipefail

# --------- Einstellungen ---------
REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
SUBDIR="cirruslogic"                # dort liegen patch_cs8409.c und die *.h
PKG="snd-hda-codec-cs8409"
DEFAULT_VER="1.0-6.12"              # Fallback, falls keine dkms.conf mit Version gefunden wird
# ---------------------------------

echo "[*] Abhängigkeiten installieren..."
sudo apt-get update
sudo apt-get install -y build-essential dkms \
  "linux-headers-$(uname -r)" git curl wget ca-certificates rsync

# tmp-Clone
WORKDIR="$(mktemp -d)"
echo "[*] Klone Repo $REPO_URL nach $WORKDIR/repo ..."
git clone --depth=1 "$REPO_URL" "$WORKDIR/repo"

SRC_SUBDIR="$WORKDIR/repo/$SUBDIR"
if [[ ! -d "$SRC_SUBDIR" ]]; then
  echo "!!! Unterordner $SUBDIR fehlt im Repo ($SRC_SUBDIR)"
  exit 1
fi
if [[ ! -f "$SRC_SUBDIR/patch_cs8409.c" ]]; then
  echo "!!! patch_cs8409.c fehlt unter $SRC_SUBDIR"
  exit 1
fi

# Version aus (optional vorhandener) dkms.conf im Repo lesen
VER="$DEFAULT_VER"
if [[ -f "$WORKDIR/repo/dkms.conf" ]]; then
  VER="$(grep -E '^PACKAGE_VERSION=' "$WORKDIR/repo/dkms.conf" | cut -d'"' -f2 || true)"
  VER="${VER:-$DEFAULT_VER}"
fi

DEST="/usr/src/${PKG}-${VER}"

echo "[*] Alte DKMS-Installation (falls vorhanden) entfernen..."
sudo dkms remove -m "$PKG" -v "$VER" --all 2>/dev/null || true
sudo rm -rf "$DEST"
sudo mkdir -p "$DEST"

echo "[*] Quellen nach $DEST kopieren..."
sudo rsync -a "$SRC_SUBDIR/" "$DEST/"

# dkms.conf bereitstellen (Repo-Root bevorzugt, sonst generieren)
if [[ -f "$WORKDIR/repo/dkms.conf" ]]; then
  echo "[*] dkms.conf aus dem Repo übernehmen..."
  sudo cp "$WORKDIR/repo/dkms.conf" "$DEST/dkms.conf"
else
  echo "[*] dkms.conf erzeugen..."
  sudo tee "$DEST/dkms.conf" >/dev/null <<DKMSCONF
PACKAGE_NAME="${PKG}"
PACKAGE_VERSION="${VER}"

BUILT_MODULE_NAME[0]="${PKG}"
DEST_MODULE_LOCATION[0]="/kernel/sound/pci/hda"

# DKMS setzt \$kernelver; wir reichen KDIR an Kbuild durch
MAKE[0]="make KDIR=/lib/modules/\${kernelver}/build"
CLEAN="make clean"

AUTOINSTALL="yes"
DKMSCONF
fi

# Makefile bereitstellen (falls im cirruslogic/ keins liegt)
if [[ -f "$SRC_SUBDIR/Makefile" ]]; then
  echo "[*] Makefile aus cirruslogic/ übernehmen..."
  sudo cp "$SRC_SUBDIR/Makefile" "$DEST/Makefile"
else
  echo "[*] Kbuild-Wrapper-Makefile erzeugen..."
  sudo tee "$DEST/Makefile" >/dev/null <<'KBUILD'
# Kbuild-Wrapper für DKMS
KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := snd-hda-codec-cs8409.o
snd-hda-codec-cs8409-objs := patch_cs8409.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
KBUILD
fi

# Sanity
if [[ ! -f "$DEST/patch_cs8409.c" ]]; then
  echo "!!! patch_cs8409.c fehlt in $DEST"
  exit 1
fi

echo "[*] DKMS registrieren..."
sudo dkms add -m "$PKG" -v "$VER"

echo "[*] Modul bauen..."
sudo dkms build -m "$PKG" -v "$VER"

echo "[*] Modul installieren..."
sudo dkms install -m "$PKG" -v "$VER"

echo "[*] Modul (neu) laden..."
sudo modprobe -r snd-hda-codec-cs8409 2>/dev/null || true
if ! sudo modprobe snd-hda-codec-cs8409; then
  echo "!! Modul konnte nicht geladen werden. Prüfe ggf. Secure Boot."
fi

echo
echo "[✓] Fertig."
echo "Prüfen:"
echo "  lsmod | grep cs8409"
echo "  dmesg | grep -i cs8409"
