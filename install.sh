#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_BRANCH="main"

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
note(){ printf "%s\n" "$*"; }
err(){ printf "\033[31m%s\033[0m\n" "$*" >&2; }

# Prüft, ob wir bereits im geklonten Repo liegen (lokal)
has_repo_layout() {
  local base="$1"
  [[ -f "$base/cirruslogic/install_cs8409_manual.sh" ]]
}

# Arbeitsverzeichnis bestimmen
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
TMPROOT=""
CLEANUP=0

if ! has_repo_layout "$REPO_ROOT"; then
  # Kein Repo – hole frisches
  command -v git >/dev/null 2>&1 || { err "git fehlt"; exit 1; }
  TMPROOT="$(mktemp -d /tmp/imac-linux-wifi-audio.XXXXXX)"
  CLEANUP=1
  bold "==> Klone Repo nach: ${TMPROOT}"
  if [[ -n "${REPO_BRANCH:-}" ]]; then
    git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMPROOT"
  else
    git clone --depth=1 "$REPO_URL" "$TMPROOT"
  fi
  REPO_ROOT="$TMPROOT"
  trap '[[ $CLEANUP -eq 1 ]] && rm -rf "$TMPROOT"' EXIT
fi

bold "== iMac Linux WiFi + Audio Installer =="
echo "1) WLAN installieren"
echo "2) Audio installieren"
echo "3) WLAN + Audio installieren"
echo "4) Nur Service installieren"
read -rp "> Auswahl [1-4]: " CHOICE

# Status-Abfragen (leichtgewichtig)
wifi_is_up() {
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -Eq '^(wlan|wl|wlp|p2p-dev-wl)' && return 0
  lsmod | grep -q '^brcmfmac' && return 0
  dmesg 2>/dev/null | grep -qi brcmfmac && return 0
  return 1
}
audio_is_up() {
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  [[ -r /proc/asound/cards ]] && grep -Eqi 'cs8409|cirrus' /proc/asound/cards && return 0
  aplay -l 2>/dev/null | grep -Eqi 'CS8409|Cirrus' && return 0
  dmesg 2>/dev/null | grep -qi cs8409 && return 0
  return 1
}

# --- WLAN Installation (Firmware spiegeln/kopieren + brcmfmac hochziehen) ---
do_wifi_install() {
  # Firmware liegt im Repo unter broadcom/{b2,b3}
  install -d /usr/local/share/imac-linux-wifi-audio/broadcom/b2 \
             /usr/local/share/imac-linux-wifi-audio/broadcom/b3 \
             /lib/firmware/brcm

  shopt -s nullglob
  local c1=0 c2=0
  for f in "$REPO_ROOT"/broadcom/b2/brcmfmac4364*; do install -m0644 "$f" /lib/firmware/brcm/; ((c1++)); done
  for f in "$REPO_ROOT"/broadcom/b3/brcmfmac4364*; do install -m0644 "$f" /lib/firmware/brcm/; ((c2++)); done
  shopt -u nullglob

  # Symlinks auf Apple-Varianten
  pushd /lib/firmware/brcm >/dev/null || true
  [[ -f brcmfmac4364b2-pcie.apple,midway.bin      ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.bin      brcmfmac4364b2-pcie.bin
  [[ -f brcmfmac4364b2-pcie.apple,midway.txt      ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.txt      brcmfmac4364b2-pcie.txt
  [[ -f brcmfmac4364b2-pcie.apple,midway.clm_blob ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.clm_blob brcmfmac4364b2-pcie.clm_blob
  [[ -f brcmfmac4364b2-pcie.apple,midway.txcap_blob ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.txcap_blob brcmfmac4364b2-pcie.txcap_blob

  [[ -f brcmfmac4364b3-pcie.apple,borneo.bin      ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.bin      brcmfmac4364b3-pcie.bin
  [[ -f brcmfmac4364b3-pcie.apple,borneo.txt      ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.txt      brcmfmac4364b3-pcie.txt
  [[ -f brcmfmac4364b3-pcie.apple,borneo.clm_blob ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.clm_blob brcmfmac4364b3-pcie.clm_blob
  [[ -f brcmfmac4364b3-pcie.apple,borneo.txcap_blob ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.txcap_blob brcmfmac4364b3-pcie.txcap_blob
  popd >/dev/null || true

  # wl raus, brcmfmac rein
  modprobe -r wl 2>/dev/null || true
  echo "options brcmfmac p2pon=0" >/etc/modprobe.d/brcmfmac.conf || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmutil
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true
}

# --- Audio Installation (CS8409 verfügbar machen + Autoload) ---
do_audio_install() {
  rm -f /etc/modprobe.d/blacklist-cs8409.conf 2>/dev/null || true
  echo snd_hda_codec_cs8409 >/etc/modules-load.d/snd_hda_codec_cs8409.conf
  # Stack jetzt noch nicht hart neuladen – machen wir im Fix-Helper/Heilung, falls nötig.
}

# --- Fix-Helper & Service einrichten (aus Repo) ---
setup_service() {
  local svc="${REPO_ROOT}/kernel_update_service.sh"
  if [[ -f "$svc" ]]; then
    bash "$svc"
  else
    err "⚠️  kernel_update_service.sh nicht gefunden – Service wird übersprungen."
  fi
}

case "$CHOICE" in
  1)
    if wifi_is_up; then
      echo "✔ WLAN ist bereits aktiv – überspringe Firmware-Installation."
    else
      do_wifi_install
    fi
    ;;
  2)
    if audio_is_up; then
      echo "✔ Audio (CS8409) ist bereits aktiv – überspringe Installation."
    else
      do_audio_install
    fi
    ;;
  3)
    if wifi_is_up; then
      echo "✔ WLAN ist bereits aktiv – überspringe Firmware-Installation."
    else
      do_wifi_install
    fi
    if audio_is_up; then
      echo "✔ Audio (CS8409) ist bereits aktiv – überspringe Installation."
    else
      do_audio_install
    fi
    ;;
  4)
    # Nur Service/Timer/Notifier
    :
    ;;
  *)
    err "Ungültige Auswahl."
    exit 2
    ;;
esac

read -rp $'\nService zur Kernel-Update-Prüfung einrichten? [y/N]: ' yn
if [[ "${yn,,}" == "y" ]]; then
  setup_service
fi

# Zusammenfassung
WLAN_OK="Nein"; audio_OK="Nein"
wifi_is_up && WLAN_OK="Ja"
audio_is_up && audio_OK="Ja"

cat <<EOF

== Zusammenfassung ==
WLAN aktiv:  ${WLAN_OK}
Audio aktiv: ${audio_OK}
Manifest: /var/lib/imac-linux-wifi-audio/manifest.txt

⚠️  Ein Neustart wird empfohlen, damit CS8409 sauber initialisiert. Nach dem Reboot prüft der User-Notifier erneut.
EOF
