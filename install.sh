#!/usr/bin/env bash
set -euo pipefail

### Einstellungen
REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_BRANCH="main"

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
log(){ echo -e "$*"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }; }

has_repo_layout() {
  local base="$1"
  [[ -f "$base/cirruslogic/install_cs8409_manual.sh" ]] \
  && [[ -f "$base/cirruslogic/extract_from_kernelpkg.sh" ]] \
  && [[ -d "$base/broadcom" ]]
}

install_popup_tool() {
  command -v zenity >/dev/null || command -v kdialog >/dev/null && return 0
  local desktop="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
  export DEBIAN_FRONTEND=noninteractive
  case "$desktop" in
    *KDE*|*Plasma*|*kde*) apt-get update -y && apt-get install -y kdialog || true ;;
    *)                    apt-get update -y && apt-get install -y zenity  || true ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
TMPROOT=""; CLEANUP=0
if ! has_repo_layout "$REPO_ROOT"; then
  command -v git >/dev/null 2>&1 || { echo "❌ git fehlt"; exit 2; }
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

MANIFEST_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST_FILE="${MANIFEST_DIR}/manifest.txt"
mkdir -p "$MANIFEST_DIR"; touch "$MANIFEST_FILE"

wifi_ok(){
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi)' && return 0
  lsmod | grep -q '^brcmfmac'
}
audio_ok(){
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  [[ -r /proc/asound/cards ]] && grep -qiE 'cs8409|cirrus' /proc/asound/cards && return 0
  return 1
}

copy_wifi() {
  log "\n==> WLAN-Firmware kopieren (BCM4364 b2/b3 inkl. .bin/.txt/.clm_blob/.txcap_blob)"
  install -d /lib/firmware/brcm
  shopt -s nullglob

  # abgeleitete Variante (midway=b2, borneo=b3). Fallback: beide
  local want="both"
  dmesg | grep -qi 'apple,midway' && want="b2"
  dmesg | grep -qi 'apple,borneo' && want="b3"

  local copied=0
  do_copy_variant(){
    local var="$1" src="${REPO_ROOT}/broadcom/${var}"
    [[ -d "$src" ]] || return 0
    for f in "$src"/brcmfmac4364*; do
      install -m 0644 "$f" /lib/firmware/brcm/
      echo "/lib/firmware/brcm/$(basename "$f")" >>"$MANIFEST_FILE"
      ((copied++))
    done
  }
  case "$want" in
    b2) do_copy_variant b2 ;;
    b3) do_copy_variant b3 ;;
    *)  do_copy_variant b2; do_copy_variant b3 ;;
  esac

  # Symlinks (falls Dateien vorhanden sind)
  ( cd /lib/firmware/brcm 2>/dev/null || true
    [[ -f brcmfmac4364b2-pcie.apple,midway.bin       ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.bin        brcmfmac4364b2-pcie.bin
    [[ -f brcmfmac4364b2-pcie.apple,midway.txt       ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.txt        brcmfmac4364b2-pcie.txt
    [[ -f brcmfmac4364b2-pcie.apple,midway.clm_blob  ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.clm_blob   brcmfmac4364b2-pcie.clm_blob
    [[ -f brcmfmac4364b2-pcie.apple,midway.txcap_blob]] && ln -sf brcmfmac4364b2-pcie.apple,midway.txcap_blob brcmfmac4364b2-pcie.txcap_blob

    [[ -f brcmfmac4364b3-pcie.apple,borneo.bin       ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.bin        brcmfmac4364b3-pcie.bin
    [[ -f brcmfmac4364b3-pcie.apple,borneo.txt       ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.txt        brcmfmac4364b3-pcie.txt
    [[ -f brcmfmac4364b3-pcie.apple,borneo.clm_blob  ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.clm_blob   brcmfmac4364b3-pcie.clm_blob
    [[ -f brcmfmac4364b3-pcie.apple,borneo.txcap_blob]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.txcap_blob brcmfmac4364b3-pcie.txcap_blob
  )

  # STA-Treiber entfernen (falls da)
  apt-get -y purge broadcom-sta-dkms bcmwl-kernel-source 2>/dev/null || true

  # brcmfmac-Option (P2P aus)
  echo "options brcmfmac p2pon=0" > /etc/modprobe.d/brcmfmac.conf

  # Stack neu + NM sicher aktiv
  modprobe -r wl 2>/dev/null || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmutil 2>/dev/null || true
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl enable --now NetworkManager 2>/dev/null || true

  log "   → ${copied} Dateien aktualisiert."
}

install_audio() {
  log "\n==> Audio (CS8409) aktivieren"
  # Modul-Param & Autoload
  echo "options snd_hda_codec_cs8409 model=imac27" > /etc/modprobe.d/cs8409.conf
  echo "snd_hda_codec_cs8409" > /etc/modules-load.d/snd_hda_codec_cs8409.conf

  chmod +x "${REPO_ROOT}/cirruslogic/"*.sh || true
  # Versuche: wenn Kernel-Modul schon mitkommt, nur (re)laden – sonst Helper
  if [[ -e "/lib/modules/$(uname -r)/kernel/sound/pci/hda/snd-hda-codec-cs8409.ko"* ]]; then
    modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
    modprobe snd_hda_codec_cs8409 2>/dev/null || true
  else
    bash "${REPO_ROOT}/cirruslogic/install_cs8409_manual.sh" --autoload || true
  fi

  depmod -a || true
  update-initramfs -u || true

  # Sofortiger Check + Popup
  systemctl start imac-wifi-audio-check.service 2>/dev/null || true
  su - "${SUDO_USER:-$(logname 2>/dev/null || echo root)}" -c "systemctl --user start imac-wifi-audio-notify.service" 2>/dev/null || true

  echo "MODULE:snd_hda_codec_cs8409" >>"$MANIFEST_FILE"
}

already_ok(){
  local okw=0 oka=0
  wifi_ok && okw=1
  audio_ok && oka=1
  echo "$okw:$oka"
}

setup_service() {
  install_popup_tool
  chmod +x "${REPO_ROOT}/kernel_update_service.sh" || true
  bash "${REPO_ROOT}/kernel_update_service.sh"
}

main(){
  need_root
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
  [[ "${yn,,}" == "y" ]] && setup_service

  # Direkt nachziehen: Check & Popup (damit du nicht warten musst)
  systemctl start imac-wifi-audio-check.service 2>/dev/null || true
  su - "${SUDO_USER:-$(logname 2>/dev/null || echo root)}" -c "systemctl --user start imac-wifi-audio-notify.service" 2>/dev/null || true

  sleep 1
  command -v alsactl >/dev/null 2>&1 && alsactl init >/dev/null 2>&1 || true

  IFS=: read -r W A < <(already_ok)
  echo -e "\n== Zusammenfassung =="
  echo "WLAN aktiv:  $([[ $W -eq 1 ]] && echo Ja || echo Nein)"
  echo "Audio aktiv: $([[ $A -eq 1 ]] && echo Ja || echo Nein)"
  echo "Manifest: $MANIFEST_FILE"
  [[ $A -eq 0 ]] && echo -e "\nℹ️  Audio ist häufig erst nach Reboot da. Ich habe den Notifier sofort gestartet."
  echo -e "\nFertig."
}
main "$@"
