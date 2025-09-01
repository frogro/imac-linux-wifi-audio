#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_BRANCH="main"

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "• %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
warn(){ printf "⚠️  %s\n" "$*"; }
die(){ printf "❌ %s\n" "$*\n" >&2; exit 1; }

need_root(){ if [[ ${EUID:-$(id -u)} -ne 0 ]]; then die "Bitte als root/sudo ausführen."; fi; }
need_root

TMPROOT="$(mktemp -d /tmp/imac-linux-wifi-audio.XXXXXX)"
CLEANUP(){ rm -rf "$TMPROOT"; }
trap CLEANUP EXIT

bold "==> Klone Repo nach: $TMPROOT"
git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMPROOT" >/dev/null 2>&1 || {
  die "Git-Clone fehlgeschlagen (Branch: $REPO_BRANCH, URL: $REPO_URL)"
}
REPO_ROOT="$TMPROOT"

# Pfade im Repo
KERNEL_SVC="${REPO_ROOT}/kernel_update_service.sh"
BRCM_B2="${REPO_ROOT}/broadcom/b2"
BRCM_B3="${REPO_ROOT}/broadcom/b3"

# Zielorte
STATE_DIR="/var/lib/imac-linux-wifi-audio"
FW_DIR_BASE="/usr/local/share/imac-linux-wifi-audio/broadcom"
FW_DIR_B2="${FW_DIR_BASE}/b2"
FW_DIR_B3="${FW_DIR_BASE}/b3"

mkdir -p "$STATE_DIR" "$FW_DIR_B2" "$FW_DIR_B3"

menu(){
  echo "== iMac Linux WiFi + Audio Installer =="
  echo "1) WLAN installieren"
  echo "2) Audio installieren"
  echo "3) WLAN + Audio installieren"
  echo "4) Nur Service installieren"
  read -rp "> Auswahl [1-4]: " CH
  echo "${CH:-4}"
}

copy_fw_variant(){
  local src="$1" dst="$2" count=0
  if [[ -d "$src" ]]; then
    shopt -s nullglob
    install -d /lib/firmware/brcm
    install -d "$dst"
    for f in "$src"/brcmfmac4364*; do
      install -m0644 "$f" /lib/firmware/brcm/
      install -m0644 "$f" "$dst/"
      ((count++)) || true
    done
  fi
  echo "$count"
}

do_wifi(){
  bold "==> WLAN-Firmware kopieren (BCM4364 b2/b3 inkl. .bin/.txt/.clm_blob/.txcap_blob)"
  local c1 c2
  c1="$(copy_fw_variant "$BRCM_B2" "$FW_DIR_B2")"
  c2="$(copy_fw_variant "$BRCM_B3" "$FW_DIR_B3")"
  info "FW-Mirror: b2=${c1} Dateien, b3=${c2} Dateien unter ${FW_DIR_BASE}"
  # brcmfmac Basics (keine Fix-Logik hier – die macht später der Fix-Helper aus kernel_update_service.sh)
  echo "options brcmfmac p2pon=0" >/etc/modprobe.d/brcmfmac.conf || true
  modprobe -r wl 2>/dev/null || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211 || true
  modprobe brcmutil || true
  modprobe brcmfmac || true
  systemctl restart NetworkManager 2>/dev/null || true
}

do_audio(){
  bold "==> Audio (CS8409) aktivieren"
  # Nur Basisschritte; die volle Heilung (A & B) übernimmt später der Fix-Helper aus kernel_update_service.sh
  rm -f /etc/modprobe.d/blacklist-cs8409.conf 2>/dev/null || true
  echo snd_hda_codec_cs8409 >/etc/modules-load.d/snd_hda_codec_cs8409.conf
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe -r snd_hda_intel 2>/dev/null || true
  modprobe snd_hda_intel || true
  modprobe snd_hda_codec_cs8409 || true
}

summarize(){
  local wifi_ok="Nein" audio_ok="Nein"
  if lsmod | grep -q '^brcmfmac'; then wifi_ok="Ja"; fi
  if lsmod | grep -q '^snd_hda_codec_cs8409'; then audio_ok="Ja"; fi

  echo
  echo "== Zusammenfassung =="
  echo "WLAN aktiv:  $wifi_ok"
  echo "Audio aktiv: $audio_ok"
  echo "Manifest: ${STATE_DIR}/manifest.txt"
  echo
  if [[ "$audio_ok" != "Ja" ]]; then
    warn "Ein Neustart wird empfohlen, damit CS8409 sauber initialisiert."
    echo "   Nach dem Reboot prüft der User-Notifier erneut."
  else
    ok "Audio ist aktiv."
  fi
}

do_service(){
  # EINZIGE Quelle für Fix-Helper/Checker/User-Notifier ist die kernel_update_service.sh aus dem Repo!
  if [[ -x "$KERNEL_SVC" ]]; then
    bold "==> Service/Checker via kernel_update_service.sh aus dem Repo einrichten"
    # direkt aus dem geklonten Ordner starten (sie generiert: check.sh, fix.sh, user-notify, timer, usw.)
    bash "$KERNEL_SVC"
  else
    warn "kernel_update_service.sh nicht gefunden – Service wird übersprungen."
    warn "Erwartet an: $KERNEL_SVC"
  fi
}

# --- Ablauf ---
CHOICE="$(menu)"
case "$CHOICE" in
  1) do_wifi ;;
  2) do_audio ;;
  3) do_wifi; do_audio ;;
  4) : ;;  # nur Service
  *) die "Ungültige Auswahl." ;;
esac

read -r -p $'Service zur Kernel-Update-Prüfung einrichten? [y/N]: ' yn
if [[ "${yn:-N}" =~ ^[Yy]$ ]]; then
  do_service
else
  info "Service-Einrichtung übersprungen."
fi

# Manifest (nur informativ)
{
  echo "installed_at=$(date -Iseconds)"
  echo "kernel=$(uname -r)"
} >>"${STATE_DIR}/manifest.txt"

summarize
