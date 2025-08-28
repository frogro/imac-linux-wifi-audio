#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------
# iMac WiFi (BCM4364 b2/b3) + Audio (CS8409) Installer
# - installiert optional WLAN-Firmware (b2 UND b3 parallel)
# - baut & installiert DKMS-Modul für CS8409
# - erzeugt Manifest zum späteren Uninstall
# ---------------------------------------

# ---- Helpers
log()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m✔\033[0m $*"; }
warn() { echo -e "\033[1;33m⚠\033[0m $*"; }
err()  { echo -e "\033[1;31m✖\033[0m $*"; }
die()  { err "$*"; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Bitte mit sudo/root ausführen."
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST_FILE="$MANIFEST_DIR/manifest.txt"
mkdir -p "$MANIFEST_DIR"

# manifest append helper
manifest_add() { echo "$1" >> "$MANIFEST_FILE"; }

# ---- Auswahl
ask_components() {
  echo "Welche Komponenten sollen installiert werden?"
  echo "  1) Nur WLAN"
  echo "  2) Nur Audio"
  echo "  3) WLAN + Audio (Standard)"
  read -rp "Auswahl [1-3]: " choice || true
  case "${choice:-3}" in
    1) DO_WIFI=1; DO_AUDIO=0 ;;
    2) DO_WIFI=0; DO_AUDIO=1 ;;
    3|*) DO_WIFI=1; DO_AUDIO=1 ;;
  esac
}

# ---- Packages
install_packages() {
  log "Pakete installieren…"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget unzip ca-certificates git rsync make \
    build-essential dkms linux-headers-$(uname -r) \
    pipewire pipewire-pulse wireplumber pavucontrol \
    alsa-utils alsa-ucm-conf >/dev/null
  ok "Pakete vorhanden."
}

# ---- WLAN: beide Revisionen b2 & b3 kopieren
install_wifi() {
  local fw_dest="/lib/firmware/brcm"
  mkdir -p "$fw_dest"
  : > "$MANIFEST_FILE"

  log "WLAN-Firmware suchen (b2 & b3) und installieren…"

  # Suche rekursiv im Repo nach allen relevanten Dateien
  # (board-spezifische und generische Namen; b2 und b3)
  mapfile -t found < <(
    find "$SCRIPT_DIR" -type f \
      \( -iname 'brcmfmac4364b2-pcie*' -o -iname 'brcmfmac4364b3-pcie*' \) \
      -printf '%p\n' | sort
  )

  if [[ "${#found[@]}" -eq 0 ]]; then
    die "Keine Firmware-Dateien (brcmfmac4364b[23]-pcie*) im Repo gefunden."
  fi

  local copied=0
  for src in "${found[@]}"; do
    local base="$(basename "$src")"
    local dst="$fw_dest/$base"
    install -m 0644 "$src" "$dst"
    manifest_add "$dst"
    ((copied++))
  done

  ok "Firmware-Dateien kopiert: $copied"
  log "Hinweis: brcmfmac wählt automatisch die zum Board passende Datei."
}

# ---- Audio via DKMS (CS8409)
install_audio() {
  local mod_name="snd-hda-codec-cs8409"
  local ver_default="1.0"

  # Versuche die Quelle zu finden (flexibel nach Ordnernamen suchen)
  # Übliche Pfade: dkms/snd-hda-codec-cs8409, driver/cs8409, audio/cs8409
  local src_dir=""
  for cand in \
      "$SCRIPT_DIR/dkms/$mod_name" \
      "$SCRIPT_DIR/dkms/${mod_name%-*}" \
      "$SCRIPT_DIR/audio/$mod_name" \
      "$SCRIPT_DIR/driver/$mod_name" \
      "$SCRIPT_DIR/$mod_name"
  do
    [[ -d "$cand" ]] && src_dir="$cand" && break
  done
  [[ -n "$src_dir" ]] || die "CS8409-Quellen nicht gefunden. Erwarte z.B. $SCRIPT_DIR/dkms/$mod_name"

  # Version aus dkms.conf lesen, falls vorhanden
  local dkms_conf="$src_dir/dkms.conf"
  local ver="$ver_default"
  if [[ -f "$dkms_conf" ]]; then
    # Suche nach PACKAGE_VERSION in dkms.conf
    ver="$(awk -F'=' '/^PACKAGE_VERSION/ {gsub(/[ "\047]/,"",$2); print $2}' "$dkms_conf" | head -n1 || true)"
    ver="${ver:-$ver_default}"
  fi

  local usr_src="/usr/src/${mod_name}-${ver}"

  log "DKMS-Quelle nach $usr_src synchronisieren…"
  rm -rf "$usr_src"
  rsync -a --delete "$src_dir/" "$usr_src/"
  manifest_add "$usr_src/#dkms-source"

  # Workaround: Kernel 6.x Inkompatibilität (linein_jack_in -> mic_jack_in)
  # nur anwenden, wenn das Symbol im Source vorkommt:
  if grep -Rqs "linein_jack_in" "$usr_src"; then
    log "Kompatibilitäts-Patch anwenden (linein_jack_in -> mic_jack_in)…"
    sed -i 's/\blinein_jack_in\b/mic_jack_in/g' $(grep -RIl "linein_jack_in" "$usr_src")
  fi

  log "DKMS registrieren/neu bauen…"
  # Vorherige Reste wegräumen (falls vorhanden)
  if dkms status | grep -q "^${mod_name}/${ver}"; then
    dkms remove -m "$mod_name" -v "$ver" --all || true
  fi

  dkms add -m "$mod_name" -v "$ver"
  if ! dkms build -m "$mod_name" -v "$ver"; then
    err "DKMS Build fehlgeschlagen."
    local log_file="/var/lib/dkms/${mod_name}/${ver}/build/make.log"
    [[ -f "$log_file" ]] && { echo "---- make.log (Tail) ----"; tail -n 200 "$log_file" || true; }
    die "Abbruch."
  fi
  dkms install -m "$mod_name" -v "$ver"

  ok "CS8409-DKMS installiert."
}

# ---- PipeWire versuchen zu aktivieren (best effort)
enable_pipewire() {
  log "PipeWire aktivieren (Best-Effort)…"
  # Funktioniert nur im Userservice-Kontext; bei sudo ohne Session gibt's oft DBUS-Fehler.
  # Deshalb hier nur versuchen, Fehler sind ok.
  local user="${SUDO_USER:-$USER}"
  if command -v loginctl >/dev/null 2>&1 && loginctl show-user "$user" >/dev/null 2>&1; then
    # Versuche --machine user@.host
    systemctl --machine="${user}"@.host --user enable --now pipewire pipewire-pulse wireplumber || true
  else
    warn "Konnte Benutzer-Session nicht ermitteln. Starte PipeWire nach dem Login automatisch."
  fi
}

# ---- Zusammenfassung
summary() {
  echo
  ok "Installation abgeschlossen."
  echo "Manifest: $MANIFEST_FILE"
  echo
  echo "Nützlich:"
  echo "  • Geladene WLAN-Firmware prüfen:  dmesg | grep -i brcmfmac"
  echo "  • Audio-Module laden:             sudo modprobe snd_hda_intel"
  echo "  • DKMS-Status:                    dkms status"
}

# ---- main
require_root
ask_components
install_packages

if [[ "${DO_WIFI:-0}" -eq 1 ]]; then
  install_wifi
fi
if [[ "${DO_AUDIO:-0}" -eq 1 ]]; then
  install_audio
  enable_pipewire
fi

summary
