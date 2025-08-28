#!/usr/bin/env bash
set -euo pipefail

# Wohin DKMS-Quellen kopiert werden
PKG="snd-hda-codec-cs8409"
VER="1.0"
DST="/usr/src/${PKG}-${VER}"
TMP="$(mktemp -d)"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "==> CS8409-Quellen holen…"
# Bewährter Community-Treiber (Fork). Du kannst hier jederzeit auf einen eigenen Fork zeigen.
ZIP_URL="https://github.com/egorenar/snd-hda-codec-cs8409/archive/refs/heads/master.zip"

curl -L --fail "$ZIP_URL" -o "$TMP/src.zip"
unzip -q "$TMP/src.zip" -d "$TMP"
SRCDIR="$(find "$TMP" -maxdepth 2 -type d -name 'snd-hda-codec-cs8409-*' | head -n1)"

# Frisches Zielverzeichnis
sudo rm -rf "$DST"
sudo mkdir -p "$DST"

echo "==> Dateien kopieren…"
# Nur die benötigten Quellen
sudo install -m 0644 "$SRCDIR/patch_cs8409.c" "$DST/"
# viele Repos legen die Logik in .h Files – die ziehen wir komplett mit:
sudo rsync -a --include='*.h' --include='*/' --exclude='*' "$SRCDIR/" "$DST/"

# Unser Makefile & dkms.conf aus dem Repo
REPOROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sudo install -m 0644 "$REPOROOT/dkms/cs8409/Makefile"   "$DST/Makefile"
sudo install -m 0644 "$REPOROOT/dkms/cs8409/dkms.conf"  "$DST/dkms.conf"

# Kompatibilitäts-Patches anwenden (idempotent)
if [ -f "$REPOROOT/dkms/cs8409/patches/10-compat-k6x.sed" ]; then
  echo "==> Kernel-Kompatibilitätsfixes anwenden…"
  sudo sed -i -f "$REPOROOT/dkms/cs8409/patches/10-compat-k6x.sed" "$DST"/patch_*.h "$DST"/patch_cs8409.c || true
fi

echo "==> DKMS registrieren/bauen/installieren…"
if dkms status | grep -q "^${PKG}/${VER}"; then
  sudo dkms remove -m "$PKG" -v "$VER" --all || true
fi

sudo dkms add    -m "$PKG" -v "$VER"
sudo dkms build  -m "$PKG" -v "$VER"
sudo dkms install -m "$PKG" -v "$VER"

echo "==> Fertig: Modul installiert als snd-hda-codec-cs8409.ko"
