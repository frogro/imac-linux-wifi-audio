#!/usr/bin/env bash
set -euo pipefail

### === Einstellungen ===
REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_BRANCH="main"   # ggf. anpassen
### =====================

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
log(){ echo -e "$*"; }
need_root(){ if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi }

# Prüft, ob erwartete Struktur unter $1 vorhanden ist
has_repo_layout() {
  local base="$1"
  [[ -f "$base/cirruslogic/install_cs8409_manual.sh" ]] \
  && [[ -f "$base/cirruslogic/extract_from_kernelpkg.sh" ]] \
  && [[ -d "$base/broadcom" ]]
}

# Versuche, echtes Repo-Root zu bestimmen (Skriptverzeichnis)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
TMPROOT=""
CLEANUP=0

# Wenn die Struktur neben install.sh fehlt → Repo nach /tmp klonen
if ! has_repo_layout "$REPO_ROOT"; then
  if ! command -v git >/dev/null 2>&1; then
    echo "❌ Git nicht gefunden und Repo-Struktur fehlt. Bitte git installieren (apt install git) oder vollständiges Repo bereitstellen."
    exit 2
  fi
  TMPROOT="$(mktemp -d /tmp/imac-linux-wifi-audio.XXXXXX)"
  CLEANUP=1
  bold "==> Klone Repo nach: $TMPROOT"
  if [[ -n "$REPO_BRANCH" ]]; then
    git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMPROOT"
  else
    git clone --depth=1 "$REPO_URL" "$TMPROOT"
  fi
  REPO_ROOT="$TMPROOT"
  # Aufräumen bei Exit
  trap '[[ $CLEANUP -eq 1 ]] && rm -rf "$TMPROOT"' EXIT
fi

# Ab hier: normaler Installer-Flow, arbeitet aus $REPO_ROOT
MANIFEST_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST_FILE="${MANIFEST_DIR}/manifest.txt"

wifi_ok(){
  command -v ip >/dev/null 2>&1 && ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi)' && return 0
  lsmod | grep -q '^brcmfmac'
}

audio_ok(){
  # 1) Modul geladen? (falls nicht built-in)
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  # 2) ALSA-Karten zeigen CS8409/Cirrus?
  [[ -r /proc/asound/cards ]] && grep -qiE 'cs8409|cirrus' /proc/asound/cards && return 0
  # 3) aplay -l listet CS8409?
  command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -qiE 'CS8409|Cirrus' && return 0
  # 4) dmesg erwähnt CS8409?
  command -v dmesg >/dev/null 2>&1 && dmesg | grep -qi cs8409 && return 0
  return 1
}

copy_wifi() {
  if wifi_ok; then
    log "\n✔ WLAN ist bereits aktiv (OOTB) – überspringe Firmware-Installation."
    return 0
  fi
  log "\n==> WLAN-Firmware kopieren (b2 + b3)"
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
    log "\n✔ Audio (CS8409) ist bereits aktiv (OOTB) – überspringe Installation."
    return 0
  fi
  log "\n==> Audio (CS8409) aktivieren"
  chmod +x "${REPO_ROOT}/cirruslogic/"*.sh || true
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
  chmod +x "${REPO_ROOT}/kernel_update_service.sh" || true
  bash "${REPO_ROOT}/kernel_update_service.sh"
}

main() {
  need_root
  mkdir -p "${MANIFEST_DIR}"
  touch "${MANIFEST_FILE}"

  bold "== iMac Linux WiFi + Audio Installer =="
  echo "1) WLAN installieren"
  echo "2) Audio installieren"
  echo "3) WLAN + Audio installieren"
  echo "4) Nur Service installieren"
  echo -n "> Auswahl [1-4]: "
  read -r choice

  case "$choice" in
    1) copy_wifi ;;
    2) install_audio ;;
    3) copy_wifi; install_audio ;;
    4) setup_service; exit 0 ;;
    *) echo "Ungültige Auswahl"; exit 3 ;;
  esac

  printf "\nService zur Kernel-Update-Prüfung einrichten? [y/n]: "
  read -r yn
  if [[ "${yn,,}" == "y" ]]; then
    setup_service
  fi

  # kurze Re-Initialisierung, falls Module gerade frisch geladen wurden
  sleep 1
  command -v alsactl >/dev/null 2>&1 && alsactl init >/dev/null 2>&1 || true

  local st
  st=$(already_ok)
  echo -e "\n== Zusammenfassung =="
  echo "WLAN aktiv:  $( [[ ${st%%:*} -eq 1 ]] && echo Ja || echo Nein )"
  echo "Audio aktiv: $( [[ ${st##*:} -eq 1 ]] && echo Ja || echo Nein )"
  echo "Manifest: ${MANIFEST_FILE}"
  echo -e "\nFertig. Ein Neustart wird empfohlen."
}

main "$@"
