#!/bin/bash
set -euo pipefail

TITLE="iMac Late 2019 - Debian 13 Install Script"
PKG="snd-hda-codec-cs8409"
VER="1.0-6.12"                      # eigene DKMS-Version, kollidiert nicht mit '1.0'
SRC="/usr/src/${PKG}-${VER}"
KVER="$(uname -r)"
KDIR="/lib/modules/${KVER}/build"

FROGRO_REPO="https://github.com/frogro/imac-linux-wifi-audio"
FROGRO_SUBDIR="cirruslogic"         # dort liegen die *.h
FROGRO_RAW="https://raw.githubusercontent.com/frogro/imac-linux-wifi-audio/main/${FROGRO_SUBDIR}"

DAVIDJO_RAW="https://raw.githubusercontent.com/davidjo/snd_hda_macbookpro/master/patch_cirrus"
PATCH_C="patch_cs8409.c"            # aus davidjo

say() { echo -e "$*"; }
hr() { printf '%*s\n' "${COLUMNS:-60}" '' | tr ' ' '-'; }

menu() {
  hr
  echo " $TITLE"
  hr
  echo
  echo "Bitte auswählen:"
  echo "  1) WLAN + Audio"
  echo "  2) nur WLAN"
  echo "  3) nur Audio"
  echo
  read -rp "Deine Auswahl [1-3]: " CHOICE
  echo
}

ensure_deps() {
  say "[*] Abhängigkeiten installieren..."
  sudo apt-get update
  sudo apt-get install -y build-essential dkms rsync git curl wget ca-certificates "linux-headers-$(uname -r)"
}

dkms_clean_all() {
  say "[*] Vorhandene cs8409-DKMS-Einträge bereinigen..."
  for V in "1.0-6.12" "1.0"; do
    sudo dkms remove -m "$PKG" -v "$V" --all 2>/dev/null || true
    sudo dkms delete -m "$PKG" -v "$V" --all 2>/dev/null || true
    sudo rm -rf "/usr/src/${PKG}-${V}"
  done
  sudo modprobe -r "$PKG" 2>/dev/null || true
}

prepare_audio_sources() {
  local workdir="$1"
  say "[*] Audio-Quellen vorbereiten unter: $workdir"
  mkdir -p "$workdir/src"
  cd "$workdir/src"

  say "    - Lade Header (*.h) aus deinem Fork (frogro)..."
  # Liste der benötigten Header aus deinem cirruslogic-Verzeichnis
  # (ggf. erweitern, falls du weitere ergänzt)
  headers=(
    "patch_cirrus_apple.h"
    "patch_cirrus_boot84.h"
    "patch_cirrus_new84.h"
    "patch_cirrus_real84.h"
    "patch_cirrus_real84_i2c.h"
    "patch_cirrus.h"
  )
  for h in "${headers[@]}"; do
    curl -fsSLo "$h" "${FROGRO_RAW}/${h}"
  done

  say "    - Lade ${PATCH_C} aus davidjo (angepasstes .c für 6.x)..."
  curl -fsSLo "${PATCH_C}" "${DAVIDJO_RAW}/${PATCH_C}"

  # Minimaler Sanity-Check
  [[ -s "${PATCH_C}" ]] || { echo "!!! ${PATCH_C} fehlt oder ist leer"; exit 1; }
}

write_dkms_files() {
  local dst="$1"
  say "[*] Erzeuge DKMS-Struktur unter: $dst"
  sudo mkdir -p "$dst"
  sudo rsync -a . "$dst/"

  say "[*] dkms.conf schreiben..."
  sudo tee "${dst}/dkms.conf" >/dev/null <<DKMSCONF
PACKAGE_NAME="${PKG}"
PACKAGE_VERSION="${VER}"

BUILT_MODULE_NAME[0]="${PKG}"
DEST_MODULE_LOCATION[0]="/kernel/sound/pci/hda"

MAKE[0]="make KDIR=/lib/modules/\${kernelver}/b
