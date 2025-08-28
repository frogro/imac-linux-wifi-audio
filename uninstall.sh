#!/usr/bin/env bash
set -euo pipefail

APP_NAME="imac-linux-wifi-audio"
MANIFEST="/var/lib/${APP_NAME}/manifest.txt"
FW_DIR="/lib/firmware/brcm"
DKMS_NAME="snd-hda-codec-cs8409"
DKMS_VER="1.0"

bold() { printf "\e[1m%s\e[0m\n" "$*"; }
info() { printf "==> %s\n" "$*"; }
warn() { printf "\e[33m[WARN]\e[0m %s\n" "$*"; }
err()  { printf "\e[31m[ERR]\e[0m %s\n" "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Bitte mit sudo/root ausführen."
    exit 1
  fi
}

remove_file() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    rm -f "$p" && echo "REMOVED $p"
  fi
}

remove_wifi() {
  bold "WLAN-Dateien entfernen…"
  # Falls ein Manifest existiert, nutzen wir es bevorzugt.
  if [[ -f "$MANIFEST" ]]; then
    grep -E '^FW:' "$MANIFEST" | cut -d' ' -f2- | while read -r f; do
      remove_file "$f"
    done
  else
    # Fallback: bekannte Dateinamen aus diesem Repo entfernen (b2/b3)
    for f in \
      brcmfmac4364b2-pcie.bin \
      brcmfmac4364b2-pcie.clm_blob \
      brcmfmac4364b2-pcie.txcap_blob \
      brcmfmac4364b2-pcie.apple,midway.bin \
      brcmfmac4364b2-pcie.apple,midway.clm_blob \
      brcmfmac4364b2-pcie.apple,midway.txcap_blob \
      brcmfmac4364b3-pcie.bin \
      brcmfmac4364b3-pcie.clm_blob \
      brcmfmac4364b3-pcie.txcap_blob \
      brcmfmac4364b3-pcie.apple,borneo.bin \
      brcmfmac4364b3-pcie.apple,borneo.clm_blob \
      brcmfmac4364b3-pcie.apple,borneo.txcap_blob
    do
      remove_file "${FW_DIR}/${f}"
    done
  fi
  # Firmware-Cache neu einlesen
  if command -v update-initramfs >/dev/null 2>&1; then
    info "Initramfs aktualisieren…"
    update-initramfs -u || true
  fi
  depmod -a || true
}

remove_audio() {
  bold "CS8409 (Cirrus) DKMS entfernen…"
  if dkms status | grep -q "^${DKMS_NAME}/${DKMS_VER}"; then
    dkms remove -m "${DKMS_NAME}" -v "${DKMS_VER}" --all || true
  fi
  # evtl. im Build-Verzeichnis zurückgebliebene Reste entfernen
  rm -rf "/var/lib/dkms/${DKMS_NAME}/${DKMS_VER}" || true
  rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VER}" || true
}

usage() {
  cat <<EOF
Uninstaller für ${APP_NAME}

Verwendung:
  sudo ./uninstall.sh [--wifi] [--audio]

Ohne Flags werden WLAN + Audio deinstalliert.
EOF
}

main() {
  require_root

  WIFI=1
  AUDIO=1
  if [[ $# -gt 0 ]]; then
    WIFI=0; AUDIO=0
    for a in "$@"; do
      case "$a" in
        --wifi) WIFI=1 ;;
        --audio) AUDIO=1 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "Unbekannte Option: $a" ;;
      esac
    done
  fi

  [[ $WIFI -eq 1 ]] && remove_wifi
  [[ $AUDIO -eq 1 ]] && remove_audio

  # Manifest-Verzeichnis aufräumen
  if [[ -d "/var/lib/${APP_NAME}" ]]; then
    rm -f "$MANIFEST"
    rmdir "/var/lib/${APP_NAME}" 2>/dev/null || true
  fi

  bold "✔ Deinstallation abgeschlossen."
  echo "Ein Reboot ist empfohlen: sudo reboot"
}

main "$@"
