#!/usr/bin/env bash
set -euo pipefail

### === Einstellungen ===
REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_BRANCH="main"
### =====================

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
say(){ echo -e "$*"; }
need_root(){ if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi }

# Strukturprüfung fürs Repo
has_repo_layout() {
  local base="$1"
  [[ -f "$base/cirruslogic/install_cs8409_manual.sh" ]] \
  && [[ -f "$base/cirruslogic/extract_from_kernelpkg.sh" ]] \
  && [[ -d "$base/broadcom" ]]
}

# Popup-Tool nach Desktop ermitteln/ggf. installieren
install_popup_tool() {
  if command -v zenity >/dev/null 2>&1 || command -v kdialog >/dev/null 2>&1; then return; fi
  local desktop="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
  export DEBIAN_FRONTEND=noninteractive
  case "$desktop" in
    *KDE*|*Plasma*|*kde*) apt-get update -y && apt-get install -y kdialog || true ;;
    *)                    apt-get update -y && apt-get install -y zenity  || true ;;
  esac
}

# Pfade
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
TMPROOT=""
CLEANUP=0

# Klonen, falls Installer nicht im Repo liegt
if ! has_repo_layout "$REPO_ROOT"; then
  command -v git >/dev/null 2>&1 || { echo "❌ Git fehlt. apt install git"; exit 2; }
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

# Status-/Manifest
STATE_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST_FILE="${STATE_DIR}/manifest.txt"
STATUS_JSON="${STATE_DIR}/status.json"
FLAG_AUDIO_NEEDS_FIX="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDS_FIX="${STATE_DIR}/needs_wifi_fix"
FLAG_REBOOT_SUGGESTED="${STATE_DIR}/reboot_suggested"
FLAG_POSTREBOOT_CHECK="${STATE_DIR}/postreboot_check"

mkdir -p "$STATE_DIR"; touch "$MANIFEST_FILE"

wifi_ok(){
  # Interface vorhanden?
  if command -v ip >/dev/null 2>&1; then ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi|wlp)'; [[ $? -eq 0 ]] && return 0; fi
  # Modul geladen?
  lsmod | grep -q '^brcmfmac' && return 0
  # dmesg-Hinweis?
  command -v dmesg >/dev/null 2>&1 && dmesg | grep -qi brcmfmac && return 0
  return 1
}

audio_ok(){
  # Modul da?
  if lsmod | grep -q '^snd_hda_codec_cs8409'; then
    # erkennbare CS8409 / Cirrus-Karte?
    [[ -r /proc/asound/cards ]] && grep -qiE 'CS8409|Cirrus' /proc/asound/cards && return 0
  fi
  # Fallback: aplay -l enthält CS8409/Cirrus?
  command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -qiE 'CS8409|Cirrus' && return 0
  # Noch im dmesg sichtbar?
  command -v dmesg >/dev/null 2>&1 && dmesg | grep -qiE 'cs8409|cirrus' && return 0
  return 1
}

# Blacklist-Wächter für CS8409
unblacklist_cs8409(){
  local changed=0
  shopt -s nullglob
  for f in /etc/modprobe.d/*cs8409*.conf; do
    if grep -qiE '^\s*blacklist\s+snd_hda_codec_cs8409' "$f"; then
      say "⚠️  Entferne Blacklist in: $f"
      rm -f "$f"
      changed=1
    fi
  done
  if (( changed )); then
    say "==> update-initramfs (wegen Blacklist-Änderung)…"
    update-initramfs -u || true
    touch "$FLAG_REBOOT_SUGGESTED" "$FLAG_POSTREBOOT_CHECK"
  fi
  return 0
}

copy_wifi() {
  if wifi_ok; then
    say "\n✔ WLAN ist bereits aktiv – überspringe Firmware-Installation."
    return 0
  fi

  say "\n==> WLAN-Firmware kopieren (BCM4364 b2/b3 inkl. .bin/.txt/.clm_blob/.txcap_blob)"
  install -d /lib/firmware/brcm
  shopt -s nullglob

  # Variante aus dmesg ableiten (midway=b2, borneo=b3). Fallback: beide
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

  # Generische Symlinks
  if ls /lib/firmware/brcm/brcmfmac4364b2-pcie.apple,midway.* >/dev/null 2>&1; then
    ( cd /lib/firmware/brcm
      ln -sf brcmfmac4364b2-pcie.apple,midway.bin        brcmfmac4364b2-pcie.bin
      ln -sf brcmfmac4364b2-pcie.apple,midway.txt        brcmfmac4364b2-pcie.txt
      ln -sf brcmfmac4364b2-pcie.apple,midway.clm_blob   brcmfmac4364b2-pcie.clm_blob
      ln -sf brcmfmac4364b2-pcie.apple,midway.txcap_blob brcmfmac4364b2-pcie.txcap_blob
    )
  fi
  if ls /lib/firmware/brcm/brcmfmac4364b3-pcie.apple,borneo.* >/dev/null 2>&1; then
    ( cd /lib/firmware/brcm
      ln -sf brcmfmac4364b3-pcie.apple,borneo.bin        brcmfmac4364b3-pcie.bin
      ln -sf brcmfmac4364b3-pcie.apple,borneo.txt        brcmfmac4364b3-pcie.txt
      ln -sf brcmfmac4364b3-pcie.apple,borneo.clm_blob   brcmfmac4364b3-pcie.clm_blob
      ln -sf brcmfmac4364b3-pcie.apple,borneo.txcap_blob brcmfmac4364b3-pcie.txcap_blob
    )
  fi

  # STA-Treiber entfernen & Stack neu laden
  apt-get purge -y broadcom-sta-dkms bcmwl-kernel-source 2>/dev/null || true
  modprobe -r wl 2>/dev/null || true

  say "   → ${copied} Dateien aktualisiert. Initramfs/Stack neu laden…"
  command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u || true

  # WLAN-Stack neu laden
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmutil 2>/dev/null || true
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true
}

install_audio() {
  # 1) Blacklist-Wächter
  unblacklist_cs8409

  if audio_ok; then
    say "\n✔ Audio (CS8409) ist bereits aktiv – überspringe Installation."
    return 0
  fi

  say "\n==> Audio (CS8409) aktivieren"
  # Autoload-Datei sicherstellen
  echo "snd_hda_codec_cs8409" >/etc/modules-load.d/snd_hda_codec_cs8409.conf

  # Wenn Kernelmodul im Baum vorhanden ist: versuchen zu laden
  if modprobe -n snd_hda_codec_cs8409 2>/dev/null; then
    say "==> Modul vorhanden/ladbar – aktiviere Autoload"
    modprobe snd_hda_codec_cs8409 || true
  fi

  # Falls cirruslogic-Skripte vorhanden: ausführen (OHNE DKMS)
  chmod +x "${REPO_ROOT}/cirruslogic/"*.sh 2>/dev/null || true
  if [[ -x "${REPO_ROOT}/cirruslogic/extract_from_kernelpkg.sh" ]]; then
    bash "${REPO_ROOT}/cirruslogic/extract_from_kernelpkg.sh" || true
  fi
  if [[ -x "${REPO_ROOT}/cirruslogic/install_cs8409_manual.sh" ]]; then
    bash "${REPO_ROOT}/cirruslogic/install_cs8409_manual.sh" --autoload || true
  fi

  # Kurzer Stack-Refresh
  alsactl init >/dev/null 2>&1 || true

  # Erfolgskontrolle
  if audio_ok; then
    say "✅ CS8409 Setup fertig."
    rm -f "$FLAG_AUDIO_NEEDS_FIX" "$FLAG_POSTREBOOT_CHECK" 2>/dev/null || true
  else
    # Kein sofortiger Erfolg: Nachlauf über Reboot/Popup
    say "ℹ️  Audio noch nicht verifizierbar – wahrscheinlich benötigt der HDA-Bus einen Neustart."
    touch "$FLAG_POSTREBOOT_CHECK" "$FLAG_REBOOT_SUGGESTED" "$FLAG_AUDIO_NEEDS_FIX"
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
    4) setup_service; echo "✅ Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet (non-blocking Setup).";;
    *) echo "Ungültige Auswahl"; exit 3 ;;
  esac

  # Post-Schritt: optional Service dazu
  printf "\nService zur Kernel-Update-Prüfung einrichten? [y/N]: "
  read -r yn
  if [[ "${yn,,}" == "y" ]]; then
    setup_service
  fi

  # Zusammenfassung
  local st
  st=$(already_ok)
  echo -e "\n== Zusammenfassung =="
  echo "WLAN aktiv:  $( [[ ${st%%:*} -eq 1 ]] && echo Ja || echo Nein )"
  echo "Audio aktiv: $( [[ ${st##*:} -eq 1 ]] && echo Ja || echo Nein )"
  echo "Manifest: ${MANIFEST_FILE}"

  if [[ -f "$FLAG_REBOOT_SUGGESTED" ]]; then
    echo -e "\n⚠️  Ein Neustart wird empfohlen, damit CS8409 sauber initialisiert. Nach dem Reboot prüft der User-Notifier erneut."
  else
    echo -e "\nFertig."
  fi
}

main "$@"
