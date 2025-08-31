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

# Popup-Tool (zenity/kdialog) passend zur Desktop-Umgebung installieren (falls keins vorhanden)
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
      apt-get update -y
      apt-get install -y kdialog || echo "⚠️  KDialog konnte nicht installiert werden. Fallback: Terminal-Prompts."
      ;;
    *GNOME*|*X-Cinnamon*|*MATE*|*XFCE*|*LXDE*|*LXQt*|*Unity*|*Budgie*|*Deepin*|*Pantheon*)
      echo "==> Installiere zenity (GTK-Desktop)"
      apt-get update -y
      apt-get install -y zenity || echo "⚠️  Zenity konnte nicht installiert werden. Fallback: Terminal-Prompts."
      ;;
    *)
      echo "⚠️  Keine bekannte Desktop-Umgebung erkannt. Bitte installiere manuell 'zenity' oder 'kdialog', sonst gibt es nur Terminal-Prompts."
      ;;
  esac
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
  trap '[[ $CLEANUP -eq 1 ]] && rm -rf "$TMPROOT"' EXIT
fi

# Ab hier: normaler Installer-Flow, arbeitet aus $REPO_ROOT
MANIFEST_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST_FILE="${MANIFEST_DIR}/manifest.txt"

wifi_ok(){
  # Interface vorhanden?
  if command -v ip >/dev/null 2>&1; then
    ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi)' && return 0
  fi
  # Modul geladen?
  lsmod | grep -q '^brcmfmac' && return 0
  # dmesg-Hinweis?
  command -v dmesg >/dev/null 2>&1 && dmesg | grep -qi brcmfmac && return 0
  return 1
}

audio_ok(){
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  [[ -r /proc/asound/cards ]] && grep -qiE 'cs8409|cirrus' /proc/asound/cards && return 0
  command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -qiE 'CS8409|Cirrus' && return 0
  command -v dmesg >/dev/null 2>&1 && dmesg | grep -qi cs8409 && return 0
  return 1
}

ensure_nm(){
  systemctl enable --now NetworkManager 2>/dev/null || true
  nmcli radio wifi on 2>/dev/null || true
}

copy_wifi() {
  # 0) Vorab: STA-Treiber entfernen (falls vorhanden)
  if apt-cache policy broadcom-sta-dkms >/dev/null 2>&1; then
    if dpkg -l broadcom-sta-dkms 2>/dev/null | grep -q '^ii'; then
      echo "==> Entferne broadcom-sta-dkms (wl) wegen Konflikt mit brcmfmac"
      apt-get purge -y broadcom-sta-dkms || true
      update-initramfs -u || true
      # Eventuell noch geladen? Dann entladen wir ihn (ignorieren Fehler)
      modprobe -r wl 2>/dev/null || true
    fi
  fi

  # 1) Modprobe-Optionen setzen (P2P aus, Lärm weg)
  install -d /etc/modprobe.d
  if ! grep -qs '^options brcmfmac p2pon=0' /etc/modprobe.d/brcmfmac.conf 2>/dev/null; then
    echo "options brcmfmac p2pon=0" > /etc/modprobe.d/brcmfmac.conf
  fi

  if wifi_ok; then
    log "\n✔ WLAN ist bereits aktiv – überspringe Firmware-Installation."
  else
    log "\n==> WLAN-Firmware kopieren (BCM4364 b2/b3 inkl. .bin/.txt/.clm_blob/.txcap_blob)"
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

    # Generik-Symlinks für vorhandene Variante(n)
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

    log "   → ${copied} Dateien aktualisiert. Initramfs/Stack neu laden…"
    command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u || true
  fi

  # 2) WLAN-Stack sauber neu laden & NM aktivieren
  systemctl stop NetworkManager 2>/dev/null || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  sleep 1
  modprobe cfg80211 || true
  modprobe brcmfmac || true
  rfkill unblock wifi 2>/dev/null || true
  systemctl start NetworkManager 2>/dev/null || true
  systemctl enable NetworkManager 2>/dev/null || true

  # 3) Radio an & Interface hoch (best effort)
  nmcli radio wifi on 2>/dev/null || true
  # typisches Iface ermitteln und up setzen
  if command -v ip >/dev/null 2>&1; then
    IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(wlan|wl|wifi)' | head -n1 || true)"
    [[ -n "${IFACE:-}" ]] && ip link set "$IFACE" up 2>/dev/null || true
    [[ -n "${IFACE:-}" ]] && nmcli dev set "$IFACE" managed yes 2>/dev/null || true
  fi
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
  mkdir -p "${MANIFEST_DIR}"
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

  # kurze Re-Initialisierung, falls Module gerade frisch geladen wurden
  sleep 1
  command -v alsactl >/dev/null 2>&1 && alsactl init >/dev/null 2>&1 || true
  ensure_nm

  local st
  st=$(already_ok)
  echo -e "\n== Zusammenfassung =="
  echo "WLAN aktiv:  $( [[ ${st%%:*} -eq 1 ]] && echo Ja || echo Nein )"
  echo "Audio aktiv: $( [[ ${st##*:} -eq 1 ]] && echo Ja || echo Nein )"
  echo "Manifest: ${MANIFEST_FILE}"
  echo -e "\nFertig. Ein Neustart wird empfohlen."
}

main "$@"
