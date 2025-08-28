#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Pfade gemäß deiner Repo-Struktur (siehe Screenshot)
# ------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Broadcom-FW:
FIRMWARE_SRC_B2="$SCRIPT_DIR/broadcom/b2"
FIRMWARE_SRC_B3="$SCRIPT_DIR/broadcom/b3"
FIRMWARE_DST="/lib/firmware/brcm"

# Cirrus-Codec (DKMS) – liegt direkt im Repo unter cirruslogic/
AUDIO_SRC="$SCRIPT_DIR/cirruslogic"
DKMS_NAME="snd-hda-codec-cs8409"
DKMS_VER="1.0"
DKMS_DST="/usr/src/${DKMS_NAME}-${DKMS_VER}"

# ------------------------------------------------------------
# Helfer
# ------------------------------------------------------------
say()    { printf "\033[33m==>\033[0m %s\n" "$*"; }
ok()     { printf "\033[32m✔\033[0m %s\n" "$*"; }
err()    { printf "\033[31m✖ %s\033[0m\n" "$*"; }
needroot(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Bitte mit sudo/root ausführen."; exit 1; }; }

install_pkgs() {
  say "Pakete installieren…"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    curl wget unzip ca-certificates \
    build-essential dkms linux-headers-$(uname -r) \
    git make rsync \
    pipewire pipewire-pulse wireplumber pavucontrol \
    alsa-utils alsa-ucm-conf
  ok "Pakete bereit."
}

copy_fw_set() {
  local src="$1" label="$2"
  [[ -d "$src" ]] || { err "Firmware-Quelle fehlt: $src"; return 1; }
  install -d "$FIRMWARE_DST"

  # Standard-Dateien
  for f in brcmfmac4364*-pcie.bin brcmfmac4364*-pcie.clm_blob brcmfmac4364*-pcie.txcap_blob; do
    compgen -G "$src/$f" > /dev/null && install -m0644 "$src"/$f "$FIRMWARE_DST/"
  done
  # Apple-Varianten (midway/borneo)
  for f in brcmfmac4364*-pcie.apple,*; do
    compgen -G "$src/$f" > /dev/null && install -m0644 "$src"/$f "$FIRMWARE_DST/"
  done

  ok "Firmware ($label) nach $FIRMWARE_DST kopiert."
}

install_wifi() {
  say "WLAN-Firmware kopieren…"
  copy_fw_set "$FIRMWARE_SRC_B2" "BCM4364 B2"
  copy_fw_set "$FIRMWARE_SRC_B3" "BCM4364 B3"
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u || true
  fi
  ok "WLAN-Firmware installiert."
}

install_audio() {
  say "Audio (Cirrus CS8409) via DKMS bauen & installieren…"

  # Minimal-Check der Quellen
  for f in dkms.conf Makefile patch_cs8409.c patch_cirrus_apple.h; do
    [[ -f "$AUDIO_SRC/$f" ]] || { err "Datei fehlt: $AUDIO_SRC/$f"; exit 2; }
  done

  # Sauberer Zustand
  dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
  rm -rf "$DKMS_DST"
  install -d "$DKMS_DST"

  # Quellen in /usr/src spiegeln
  rsync -a --delete "$AUDIO_SRC"/ "$DKMS_DST"/

  # DKMS-Lebenszyklus
  dkms add    -m "$DKMS_NAME" -v "$DKMS_VER"
  dkms build  -m "$DKMS_NAME" -v "$DKMS_VER"
  dkms install -m "$DKMS_NAME" -v "$DKMS_VER" --force

  # Modul laden (falls möglich)
  modprobe "$DKMS_NAME" || true
  ok "Audio-Treiber installiert."
}

pipewire_hint() {
  if [[ -z "${SUDO_USER:-}" ]]; then
    say "Hinweis: PipeWire läuft als USER-Dienst. In deiner Desktop-Session prüfen mit:"
    echo "   systemctl --user --type=service | grep -E 'pipewire|wireplumber'"
  fi
}

menu() {
  echo
  echo "Welche Komponenten sollen installiert werden?"
  echo "  1) Nur WLAN"
  echo "  2) Nur Audio"
  echo "  3) WLAN + Audio (Standard)"
  read -r -p "Auswahl [1-3]: " choice || true
  case "${choice:-3}" in
    1) SELECTION="wifi"  ;;
    2) SELECTION="audio" ;;
    3|*) SELECTION="both";;
  esac
  echo
}

manifest() {
  local d="/var/lib/imac-linux-wifi-audio"
  install -d "$d"
  {
    echo "timestamp: $(date -Is)"
    echo "kernel: $(uname -r)"
    echo "firmware_b2: $FIRMWARE_SRC_B2"
    echo "firmware_b3: $FIRMWARE_SRC_B3"
    echo "audio_src:   $AUDIO_SRC"
    echo "dkms:        $DKMS_NAME/$DKMS_VER"
  } > "$d/manifest.txt"
  ok "Manifest: $d/manifest.txt"
}

main() {
  needroot
  menu
  install_pkgs

  case "$SELECTION" in
    wifi) install_wifi ;;
    audio) install_audio ;;
    both) install_wifi; install_audio ;;
  esac

  pipewire_hint
  ok "Installation abgeschlossen."
  manifest
}

main "$@"
