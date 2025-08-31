#!/usr/bin/env bash
set -euo pipefail

### === Einstellungen ===
REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_BRANCH="main"
### =====================

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
log(){ echo -e "$*"; }
need_root(){ if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi }

# Prüfe Repo-Struktur
has_repo_layout() {
  local base="$1"
  [[ -f "$base/cirruslogic/install_cs8409_manual.sh" ]] \
  && [[ -f "$base/cirruslogic/extract_from_kernelpkg.sh" ]] \
  && [[ -d "$base/broadcom" ]]
}

# Popup-Tool passend zur Desktop-Umgebung (optional)
install_popup_tool() {
  if command -v zenity >/dev/null 2>&1 || command -v kdialog >/dev/null 2>&1; then
    return
  fi
  local desktop="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
  echo "==> Prüfe GUI für Popup-Tool (gefunden: ${desktop:-<unbekannt>})"
  export DEBIAN_FRONTEND=noninteractive
  case "$desktop" in
    *KDE*|*Plasma*|*kde*)
      echo "==> Installiere kdialog (KDE/Plasma)"
      apt-get update -y && apt-get install -y kdialog || echo "⚠️  KDialog konnte nicht installiert werden."
      ;;
    *GNOME*|*X-Cinnamon*|*MATE*|*XFCE*|*LXDE*|*LXQt*|*Unity*|*Budgie*|*Deepin*|*Pantheon*)
      echo "==> Installiere zenity (GTK-Desktop)"
      apt-get update -y && apt-get install -y zenity || echo "⚠️  Zenity konnte nicht installiert werden."
      ;;
    *) echo "⚠️  Keine bekannte Desktop-Umgebung erkannt – Terminal-Prompts als Fallback."; ;;
  esac
}

# Pfade
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
TMPROOT=""; CLEANUP=0

# Bei nackter install.sh → Repo klonen
if ! has_repo_layout "$REPO_ROOT"; then
  command -v git >/dev/null 2>&1 || { echo "❌ git fehlt. apt install git"; exit 2; }
  TMPROOT="$(mktemp -d /tmp/imac-linux-wifi-audio.XXXXXX)"
  CLEANUP=1
  bold "==> Klone Repo nach: $TMPROOT"
  if [[ -n "$REPO_BRANCH" ]]; then
    git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMPROOT"
  else
    git clone --depth=1 "$REPO_URL" "$TMPROOT"
  fi
  REPO_ROOT="$TMPROOT"
  trap '[[ $CLEANUP -eq 1 ]] && rm -rf "$TMPROOT"' EXIT
fi

# State/Manifest
STATE_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST_DIR="$STATE_DIR"
MANIFEST_FILE="${STATE_DIR}/manifest.txt"
PENDING_AUDIO="${STATE_DIR}/pending_audio_check"

wifi_ok(){
  if command -v ip >/dev/null 2>&1; then
    ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi)' && return 0
  fi
  lsmod | grep -q '^brcmfmac' && return 0
  command -v dmesg >/dev/null 2>&1 && dmesg | grep -qi brcmfmac && return 0
  return 1
}

audio_ok(){
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  [[ -r /proc/asound/cards ]] && grep -qiE 'cs8409|cirrus' /proc/asound/cards && return 0
  command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -qiE 'CS8409|Cirrus' && return 0
  command -v dmesg  >/dev/null 2>&1 && dmesg | grep -qi cs8409 && return 0
  return 1
}

copy_wifi() {
  if wifi_ok; then
    log "\n✔ WLAN ist bereits aktiv – überspringe Firmware-Installation."
    return 0
  fi
  log "\n==> WLAN-Firmware kopieren (BCM4364 b2/b3 inkl. .bin/.txt/.clm_blob/.txcap_blob)"
  install -d /lib/firmware/brcm
  shopt -s nullglob

  local want="both"
  if dmesg | grep -qi 'apple,midway'; then want="b2"; fi
  if dmesg | grep -qi 'apple,borneo'; then want="b3"; fi

  local copied=0
  do_copy_variant(){
    local var="$1" ; local src="${REPO_ROOT}/broadcom/${var}"
    [[ -d "$src" ]] || return 0
    for f in "${src}"/brcmfmac4364*; do
      install -m 0644 "$f" /lib/firmware/brcm/
      echo "/lib/firmware/brcm/$(basename "$f")" >>"${MANIFEST_FILE}"
      ((copied++))
    done
  }

  case "$want" in
    b2) do_copy_variant b2 ;;
    b3) do_copy_variant b3 ;;
    both) do_copy_variant b2; do_copy_variant b3 ;;
  esac

  if ls /lib/firmware/brcm/brcmfmac4364b2-pcie.apple,midway.* >/dev/null 2>&1; then
    ( cd /lib/firmware/brcm
      ln -sf brcmfmac4364b2-pcie.apple,midway.bin        brcmfmac4364b2-pcie.bin
      ln -sf brcmfmac4364b2-pcie.apple,midway.txt        brcmfmac4364b2-pcie.txt || true
      ln -sf brcmfmac4364b2-pcie.apple,midway.clm_blob   brcmfmac4364b2-pcie.clm_blob
      ln -sf brcmfmac4364b2-pcie.apple,midway.txcap_blob brcmfmac4364b2-pcie.txcap_blob
    )
  fi
  if ls /lib/firmware/brcm/brcmfmac4364b3-pcie.apple,borneo.* >/dev/null 2>&1; then
    ( cd /lib/firmware/brcm
      ln -sf brcmfmac4364b3-pcie.apple,borneo.bin        brcmfmac4364b3-pcie.bin
      ln -sf brcmfmac4364b3-pcie.apple,borneo.txt        brcmfmac4364b3-pcie.txt || true
      ln -sf brcmfmac4364b3-pcie.apple,borneo.clm_blob   brcmfmac4364b3-pcie.clm_blob
      ln -sf brcmfmac4364b3-pcie.apple,borneo.txcap_blob brcmfmac4364b3-pcie.txcap_blob
    )
  fi

  # STA-Treiber entfernen (falls je installiert)
  apt-cache policy broadcom-sta-dkms >/dev/null 2>&1 && apt-get purge -y broadcom-sta-dkms bcmwl-kernel-source 2>/dev/null || true
  modprobe -r wl 2>/dev/null || true

  # Stack neu laden + NM starten
  command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl enable --now NetworkManager 2>/dev/null || true
}

install_audio() {
  if audio_ok; then
    log "\n✔ Audio (CS8409) ist bereits aktiv – überspringe Installation."
    return 0
  fi
  log "\n==> Audio (CS8409) aktivieren"
  chmod +x "${REPO_ROOT}/cirruslogic/"*.sh || true
  bash "${REPO_ROOT}/cirruslogic/install_cs8409_manual.sh" --autoload || true
  echo "MODULE:snd_hda_codec_cs8409" >>"${MANIFEST_FILE}"

  # Sofortcheck; häufig erst nach Reboot stabil → Marker & Reboot anbieten
  if audio_ok; then
    log "✅ Audio scheint aktiv."
  else
    log "⚠️  Audio ist vermutlich korrekt installiert, benötigt aber einen Neustart."
    touch "${PENDING_AUDIO}"
    # Reboot anbieten
    if command -v zenity >/dev/null 2>&1; then
      if zenity --question --title="Neustart empfohlen" --text="Audio-Treiber wurde installiert.\nFür CS8409 ist ein Neustart nötig.\nJetzt neu starten?"; then
        systemctl reboot
      fi
    elif command -v kdialog >/dev/null 2>&1; then
      if kdialog --yesno "Audio-Treiber wurde installiert.\nFür CS8409 ist ein Neustart nötig.\nJetzt neu starten?"; then
        systemctl reboot
      fi
    else
      read -r -p "Audio installiert – Neustart jetzt durchführen? [y/N]: " yn
      [[ "${yn,,}" == "y" ]] && systemctl reboot
    fi
  fi
}

already_ok() {
  local ok_wifi=0 ok_audio=0
  wifi_ok && ok_wifi=1
  audio_ok && ok_audio=1
  echo "$ok_wifi:$ok_audio"
}

setup_service() {
  install_popup_tool
  chmod +x "${REPO_ROOT}/kernel_update_service.sh" || true
  bash "${REPO_ROOT}/kernel_update_service.sh"
}

main() {
  need_root
  mkdir -p "${STATE_DIR}"
  touch "${MANIFEST_FILE}"

  bold "== iMac Linux WiFi + Audio Installer =="
  echo "1) WLAN installieren"
  echo "2) Audio installieren"
  echo "3) WLAN + Audio installieren"
  echo "4) Nur Service installieren"
  printf "> Auswahl [1-4]: "
  read -r choice

  case "$choice" in
    1) copy_wifi ;;
    2) install_audio ;;
    3) copy_wifi; install_audio ;;
    4) setup_service; exit 0 ;;
    *) echo "Ungültige Auswahl"; exit 3 ;;
  esac

  printf "\nService zur Kernel-Update-Prüfung einrichten? [y/N]: "
  read -r yn
  if [[ "${yn,,}" == "y" ]]; then
    setup_service
  fi

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
