#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST_FILE="${MANIFEST_DIR}/manifest.txt"

need_root() { if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi }
log() { echo -e "$@"; }

wifi_ok(){
  command -v ip >/dev/null 2>&1 && ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi)' && return 0
  lsmod | grep -q '^brcmfmac'
}

audio_ok(){
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  [[ -r /proc/asound/cards ]] && egrep -qi 'cs8409|cirrus' /proc/asound/cards
}

copy_wifi() {
  if wifi_ok; then
    log "
✔ WLAN ist bereits aktiv (OOTB) – überspringe Firmware-Installation."
    return 0
  fi
  log "
==> WLAN-Firmware kopieren (b2 + b3)"
  install -d /lib/firmware/brcm
  local cnt=0
  shopt -s nullglob
  for sub in b2 b3; do
    for f in "${REPO_ROOT}/broadcom/${sub}"/*; do
      install -m 0644 "$f" /lib/firmware/brcm/
      echo "/lib/firmware/brcm/$(basename "$f")" >>"${MANIFEST_FILE}"
      ((cnt++))
    done
  done
  log "   → ${cnt} Dateien kopiert. Lade brcmfmac neu (Best effort)."
  modprobe -r brcmfmac 2>/dev/null || true
  modprobe brcmfmac || true
}

install_audio() {
  if audio_ok; then
    log "
✔ Audio (CS8409) ist bereits aktiv (OOTB) – überspringe Installation."
    return 0
  fi
  log "
==> Audio (CS8409) aktivieren"
  bash "${REPO_ROOT}/cirruslogic/install_cs8409_manual.sh" --autoload || true
  echo "MODULE:snd_hda_codec_cs8409" >>"${MANIFEST_FILE}"
}

already_ok() {
  local ok_wifi=0 ok_audio=0
  wifi_ok && ok_wifi=1
  audio_ok && ok_audio=1
  echo "$ok_wifi:$ok_audio"
}

setup_service() {
  bash "${REPO_ROOT}/kernel_update_service.sh"
}

main() {
  need_root
  mkdir -p "${MANIFEST_DIR}"
  touch "${MANIFEST_FILE}"

  echo "== iMac Linux WiFi + Audio Installer =="
  echo "1) WLAN installieren"
  echo "2) Audio installieren"
  echo "3) WLAN + Audio installieren"
  echo -n "> Auswahl [1-3]: "
  read -r choice

  case "$choice" in
    1) copy_wifi ;;
    2) install_audio ;;
    3) copy_wifi; install_audio ;;
    *) echo "Ungültige Auswahl"; exit 2 ;;
  esac

  echo -n "
Service zur Kernel-Update-Prüfung einrichten? [y/N]: "
  read -r yn
  if [[ "${yn,,}" == "y" ]]; then
    setup_service
  fi

  local st
  st=$(already_ok)
  echo "
== Zusammenfassung =="
  echo "WLAN aktiv:  $( [[ ${st%%:*} -eq 1 ]] && echo Ja || echo Nein )"
  echo "Audio aktiv: $( [[ ${st##*:} -eq 1 ]] && echo Ja || echo Nein )"
  echo "Manifest: ${MANIFEST_FILE}"
  echo "
Fertig. Ein Neustart wird empfohlen."
}

main "$@"
