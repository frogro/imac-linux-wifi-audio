#!/usr/bin/env bash
# install.sh
set -euo pipefail

REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_BRANCH="main"

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

has_repo_layout() { [[ -f "$1/kernel_update_service.sh" ]] || [[ -d "$1/broadcom" ]]; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
TMPROOT=""
CLEANUP=0

if ! has_repo_layout "$REPO_ROOT"; then
  command -v git >/dev/null 2>&1
  TMPROOT="$(mktemp -d /tmp/imac-linux-wifi-audio.XXXXXX)"
  CLEANUP=1
  bold "==> Klone Repo nach: $TMPROOT"
  [[ -n "${REPO_BRANCH:-}" ]] && git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMPROOT" || git clone --depth=1 "$REPO_URL" "$TMPROOT"
  REPO_ROOT="$TMPROOT"
  trap '[[ $CLEANUP -eq 1 ]] && rm -rf "$TMPROOT"' EXIT
fi

MANIFEST_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST_FILE="${MANIFEST_DIR}/manifest.txt"
install -d -m 0755 "$MANIFEST_DIR"
: > "$MANIFEST_FILE"

wifi_active() {
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(wlan|wl|wifi|wlp|p2p-dev-wl)' >/dev/null 2>&1 && return 0
  lsmod | grep -q '^brcmfmac' && return 0
  dmesg | grep -qi 'brcmfmac' && return 0
  return 1
}

audio_active() {
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  [[ -r /proc/asound/cards ]] && grep -qiE 'cs8409|cirrus' /proc/asound/cards && return 0
  command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -qiE 'CS8409|Cirrus' && return 0
  dmesg | grep -qi 'cs8409' && return 0
  return 1
}

install_wifi() {
  bold "==> WLAN-Firmware kopieren (BCM4364 b2/b3 inkl. .bin/.txt/.clm_blob/.txcap_blob)"
  install -d /lib/firmware/brcm
  local copied=0
  shopt -s nullglob
  for p in "$REPO_ROOT"/broadcom/b2/brcmfmac4364b2-pcie.* "$REPO_ROOT"/broadcom/b3/brcmfmac4364b3-pcie.*; do
    install -m0644 "$p" /lib/firmware/brcm/
    ((copied++)) || true
  done
  # Symlinks setzen (Apple-Varianten bevorzugen)
  pushd /lib/firmware/brcm >/dev/null
  [[ -f brcmfmac4364b2-pcie.apple,midway.bin      ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.bin      brcmfmac4364b2-pcie.bin
  [[ -f brcmfmac4364b2-pcie.apple,midway.txt      ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.txt      brcmfmac4364b2-pcie.txt
  [[ -f brcmfmac4364b2-pcie.apple,midway.clm_blob ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.clm_blob brcmfmac4364b2-pcie.clm_blob
  [[ -f brcmfmac4364b2-pcie.apple,midway.txcap_blob ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.txcap_blob brcmfmac4364b2-pcie.txcap_blob

  [[ -f brcmfmac4364b3-pcie.apple,borneo.bin      ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.bin      brcmfmac4364b3-pcie.bin
  [[ -f brcmfmac4364b3-pcie.apple,borneo.txt      ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.txt      brcmfmac4364b3-pcie.txt
  [[ -f brcmfmac4364b3-pcie.apple,borneo.clm_blob ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.clm_blob brcmfmac4364b3-pcie.clm_blob
  [[ -f brcmfmac4364b3-pcie.apple,borneo.txcap_blob ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.txcap_blob brcmfmac4364b3-pcie.txcap_blob
  popd >/dev/null

  # brcmfmac p2p deaktivieren (stabiler)
  echo "options brcmfmac p2pon=0" | sudo tee /etc/modprobe.d/brcmfmac.conf >/dev/null

  # Stack kurz neu laden
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmutil
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true
}

install_audio() {
  bold "==> Audio (CS8409) aktivieren"
  # Blacklist entfernen & Autoload setzen
  rm -f /etc/modprobe.d/blacklist-cs8409.conf 2>/dev/null || true
  echo snd_hda_codec_cs8409 >/etc/modules-load.d/snd_hda_codec_cs8409.conf

  # Modul laden
  if modinfo snd_hda_codec_cs8409 >/dev/null 2>&1; then
    yellow "==> Modul vorhanden/ladbar – aktiviere Autoload"
    modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
    modprobe -r snd_hda_intel 2>/dev/null || true
    modprobe snd_hda_intel
    modprobe snd_hda_codec_cs8409
  else
    echo "⚠️  snd_hda_codec_cs8409 nicht im Kernel gefunden."
  fi

  # ALSA & User-Audio-Stack (Schnelle Heilung B)
  command -v alsactl >/dev/null 2>&1 && alsactl init || true
  systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true

  # Mixer-Heilung
  amixer -c 0 sset 'Auto-Mute Mode' Disabled 2>/dev/null || true
  amixer -c 0 sset Speaker 100% unmute 2>/dev/null || true
  amixer -c 0 sset Headphone mute 2>/dev/null || true
  amixer -c 0 sset PCM 100% unmute 2>/dev/null || true
}

summary() {
  local w="Nein" a="Nein"
  wifi_active && w="Ja"
  audio_active && a="Ja"
  echo "WLAN aktiv:  $w" | tee -a "$MANIFEST_FILE"
  echo "Audio aktiv: $a" | tee -a "$MANIFEST_FILE"
  echo "Manifest: $MANIFEST_FILE"
}

menu() {
  bold "== iMac Linux WiFi + Audio Installer =="
  echo "1) WLAN installieren"
  echo "2) Audio installieren"
  echo "3) WLAN + Audio installieren"
  echo "4) Nur Service installieren"
  read -rp "> Auswahl [1-4]: " CH
  case "${CH:-}" in
    1)
      if wifi_active; then green "✔ WLAN ist bereits aktiv – überspringe Firmware-Installation."; else install_wifi; fi
      ;;
    2)
      if audio_active; then green "✔ Audio (CS8409) ist bereits aktiv – überspringe Installation."; else install_audio; fi
      ;;
    3)
      if wifi_active; then green "✔ WLAN ist bereits aktiv – überspringe Firmware-Installation."; else install_wifi; fi
      if audio_active; then green "✔ Audio (CS8409) ist bereits aktiv – überspringe Installation."; else install_audio; fi
      ;;
    4)
      :
      ;;
    *)
      echo "Ungültige Auswahl." >&2; exit 2;;
  esac

  echo
  read -rp "Service zur Kernel-Update-Prüfung einrichten? [y/N]: " YN
  if [[ "${YN,,}" == "y" ]]; then
    if [[ -x "$REPO_ROOT/kernel_update_service.sh" ]]; then
      bash "$REPO_ROOT/kernel_update_service.sh"
      green "✅ Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet (non-blocking Setup)."
    else
      echo "⚠️  kernel_update_service.sh nicht gefunden – Service wird übersprungen." >&2
    fi
  fi

  echo
  bold "== Zusammenfassung =="
  summary
  echo
  yellow "⚠️  Ein Neustart wird empfohlen, damit CS8409 sauber initialisiert. Nach dem Reboot prüft der User-Notifier erneut."
}

menu
