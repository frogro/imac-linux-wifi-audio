#!/usr/bin/env bash
# iMac 2019 (iMac19,1): WLAN (BCM4364 b2/b3) + Audio (CS8409) Installer
# - Debian 12/13 kompatibel
# - Optional: Kernel-Upgrade via bookworm-backports (6.8+)
# - WLAN: holt Firmware (Noa-Paket), wählt b2/b3 nach HW, setzt Symlinks
# - Audio: aktiviert CS8409 (Basisschritte; DKMS-Bau separat möglich)

set -euo pipefail

# ---------------------------
# UI & Helpers
# ---------------------------
bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "• %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
warn(){ printf "⚠️  %s\n" "$*"; }
die(){ printf '❌ %s\n' "$*" >&2; exit 1; }

need_root(){ if [[ ${EUID:-$(id -u)} -ne 0 ]]; then die "Bitte als root/sudo ausführen."; fi; }
have(){ command -v "$1" >/dev/null 2>&1; }

need_root

TMPROOT="$(mktemp -d /tmp/imac-linux-wifi-audio.XXXXXX)"
CLEANUP(){ rm -rf "$TMPROOT"; }
trap CLEANUP EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_BRANCH="main"
REPO_ROOT="$TMPROOT" # wird ggf. auf SCRIPT_DIR gesetzt, falls git-Clone scheitert

# Zielorte & Spiegel
STATE_DIR="/var/lib/imac-linux-wifi-audio"
FW_DIR_BASE="/usr/local/share/imac-linux-wifi-audio/broadcom"
FW_DIR_B2="${FW_DIR_BASE}/b2"
FW_DIR_B3="${FW_DIR_BASE}/b3"
FW_RUNTIME="/lib/firmware/brcm"

mkdir -p "$STATE_DIR" "$FW_DIR_B2" "$FW_DIR_B3" "$FW_RUNTIME"

# Noa-Firmware-Paket (immer Quelle für Wi-Fi)
FW_URL_DEFAULT="https://github.com/NoaHimesaka1873/apple-bcm-firmware/releases/download/v14.0/apple-bcm-firmware-14.0-1-any.pkg.tar.zst"

# ---------------------------
# Distro/Kernel-Erkennung
# ---------------------------
ID_STR=""; CODENAME=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ID_STR="${PRETTY_NAME:-${ID:-unknown}}"
  CODENAME="${VERSION_CODENAME:-}"
fi

# ---------------------------
# Optional: Backports-Kernel (nur Debian 12/bookworm)
# ---------------------------
maybe_upgrade_kernel_backports() {
  bold "==> Kernel via Backports (optional)"

  if [[ "${ID:-}" != "debian" || "$CODENAME" != "bookworm" ]]; then
    info "Nicht Debian 12/bookworm → Schritt wird übersprungen."
    return 0
  fi

  local kv
  kv="$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
  # bereits >= 6.8?
  awk -v kv="$kv" 'BEGIN{split(kv,a,"."); if(a[1]>6 || (a[1]==6 && a[2]>=8)) exit 0; else exit 1}'
  if [[ $? -eq 0 ]]; then
    ok "Aktiver Kernel ist bereits >= 6.8 (${kv}) – kein Upgrade nötig."
    return 0
  fi

  printf "Erkanntes System: %s (Codename: %s)\n" "${ID_STR:-unknown}" "${CODENAME:-unknown}"
  read -r -p "Backports eintragen & Kernel/Headers aus bookworm-backports installieren? [y/N]: " yn
  if [[ ! "${yn:-N}" =~ ^[Yy]$ ]]; then
    info "Backports-Upgrade übersprungen."
    return 0
  fi

  info "Trage bookworm-backports (inkl. non-free-firmware) ein…"
  mkdir -p /etc/apt/sources.list.d
  echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware" \
    > /etc/apt/sources.list.d/backports.list

  info "Aktualisiere Paketlisten…"
  apt-get update -y

  info "Installiere neuen Kernel & Header aus Backports…"
  apt-get -y -t bookworm-backports install linux-image-amd64 linux-headers-amd64

  warn "Ein Neustart ist erforderlich, damit der neue Kernel aktiv wird."
  echo "Optional: 'firmware-brcm80211' aus Backports:"
  echo "  apt-get -y -t bookworm-backports install firmware-brcm80211"
  read -r -p "Jetzt sofort neu starten? [y/N]: " rn
  if [[ "${rn:-N}" =~ ^[Yy]$ ]]; then
    reboot
  else
    info "Fahre ohne Neustart fort (aktueller Kernel bleibt aktiv)."
  fi
}

# ---------------------------
# Git-Clone mit Fallback
# ---------------------------
clone_or_fallback() {
  bold "==> Klone Repo nach: $TMPROOT"
  if have git; then
    if git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMPROOT" >/dev/null 2>&1; then
      ok "Git-Clone ok."
      REPO_ROOT="$TMPROOT"
      return 0
    else
      warn "Git-Clone fehlgeschlagen – verwende lokalen Skriptordner als Fallback."
    fi
  else
    warn "git nicht installiert – verwende lokalen Skriptordner als Fallback."
  fi

  # Fallback auf lokalen Ordner (nur für Audio/Service; Wi-Fi kommt stets aus Noa-Paket)
  REPO_ROOT="$SCRIPT_DIR"
}

# ---------------------------
# WLAN: IMMER aus Noa-Paket
# ---------------------------

chip_present(){ lspci -nn | grep -qi '14e4:4464'; }

detect_hw_rev(){
  # sucht "BCM4364/2" oder "/3" in dmesg; gibt "2" oder "3" zurück (oder leer)
  local d; d="$(dmesg | grep -m1 -o 'BCM4364/[23]' || true)"
  [[ -n "$d" ]] && echo "${d##*/}" || echo ""
}

preferred_family_for_rev(){
  # Policy: /3 ⇒ b2(midway), /2 ⇒ b3(borneo)
  case "$1" in
    3) echo "b2";;
    2) echo "b3";;
    *) echo "b2";; # Default b2, weil bei dir stabil
  esac
}

pick_txt_from_pkg(){
  # wählt & installiert passende TXT aus entpacktem Paket nach /lib/firmware/brcm
  local fam="$1" src="$2" picked=""
  install -d -m0755 "$FW_RUNTIME"
  shopt -s nullglob
  if [[ "$fam" == "b2" ]]; then
    for cand in \
      brcmfmac4364b2-pcie.apple,midway-HRPN-m.txt \
      brcmfmac4364b2-pcie.apple,midway-HRPN-u.txt; do
      [[ -f "$src/$cand" ]] && { picked="$cand"; break; }
    done
    if [[ -n "$picked" ]]; then
      install -m0644 "$src/$picked" "$FW_RUNTIME/brcmfmac4364b2-pcie.apple,midway.txt"
      ok "TXT gewählt: $picked → brcmfmac4364b2-pcie.apple,midway.txt"
    fi
  else
    for cand in \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-u-7.9.txt \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-u-7.7.txt \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-m.txt; do
      [[ -f "$src/$cand" ]] && { picked="$cand"; break; }
    done
    if [[ -n "$picked" ]]; then
      install -m0644 "$src/$picked" "$FW_RUNTIME/brcmfmac4364b3-pcie.apple,borneo.txt"
      ok "TXT gewählt: $picked → brcmfmac4364b3-pcie.apple,borneo.txt"
    fi
  fi
  shopt -u nullglob
  [[ -n "$picked" ]]
}

install_family_from_pkg(){
  # kopiert bin/clm/txcap (+TXT) und setzt Symlinks (generisch + iMac19,1)
  local fam="$1" src="$2" base label
  if [[ "$fam" == "b2" ]]; then base="brcmfmac4364b2-pcie.apple,midway"; label="midway";
  else base="brcmfmac4364b3-pcie.apple,borneo"; label="borneo"; fi

  install -d -m0755 "$FW_RUNTIME"
  for ext in bin clm_blob txcap_blob; do
    [[ -f "$src/${base}.${ext}" ]] || die "Fehlt im Paket: ${base}.${ext}"
    install -m0644 "$src/${base}.${ext}" "$FW_RUNTIME/${base}.${ext}"
  done
  pick_txt_from_pkg "$fam" "$src" || warn "Keine passende .txt im Paket gefunden (Kalibrierung ggf. suboptimal)."

  # generische Symlinks
  ln -sf "${base}.bin"        "$FW_RUNTIME/brcmfmac4364-pcie.bin"
  ln -sf "${base}.clm_blob"   "$FW_RUNTIME/brcmfmac4364-pcie.clm_blob"
  ln -sf "${base}.txcap_blob" "$FW_RUNTIME/brcmfmac4364-pcie.txcap_blob"
  # TXT Symlinks (falls vorhanden)
  if [[ -f "$FW_RUNTIME/${base}.txt" ]]; then
    ln -sf "${base}.txt" "$FW_RUNTIME/brcmfmac4364-pcie.txt"
    ln -sf "${base}.txt" "$FW_RUNTIME/brcmfmac4364-pcie.Apple Inc.-iMac19,1.txt"
  fi
  # Apple Board Name
  ln -sf "${base}.bin"        "$FW_RUNTIME/brcmfmac4364-pcie.Apple Inc.-iMac19,1.bin"
  ln -sf "${base}.clm_blob"   "$FW_RUNTIME/brcmfmac4364-pcie.Apple Inc.-iMac19,1.clm_blob"
  ln -sf "${base}.txcap_blob" "$FW_RUNTIME/brcmfmac4364-pcie.Apple Inc.-iMac19,1.txcap_blob"

  ok "Installiert: ${label} (${fam}) → $FW_RUNTIME"
}

reload_wifi_stack(){
  # kleine Netztweaks + Module neu laden + NM neu starten
  echo "options brcmfmac p2pon=0" >/etc/modprobe.d/brcmfmac.conf || true
  modprobe -r wl 2>/dev/null || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211 || true
  modprobe brcmutil || true
  modprobe brcmfmac || true
  if ! have rfkill; then apt-get update -y && apt-get install -y rfkill; fi
  rfkill unblock all || true
  systemctl restart NetworkManager 2>/dev/null || true
}

do_wifi(){
  bold "==> WLAN installieren (BCM4364 b2/b3 aus Noa-Paket)"
  chip_present || die "BCM4364 (14e4:4464) nicht gefunden."

  have curl || die "curl fehlt."
  have tar  || die "tar fehlt."
  local ZSTD_FLAG="--zstd"
  tar --help | grep -q -- --zstd || ZSTD_FLAG="--use-compress-program=unzstd"

  local TMP="$(mktemp -d /tmp/bcm4364.XXXXXX)"
  local PKG="$TMP/fw.pkg.tar.zst"
  local EX="$TMP/extract"
  trap 'rm -rf "$TMP"' RETURN

  # HW-Erkennung -> Family
  local HWREV PREF FAM
  HWREV="$(detect_hw_rev || true)"
  PREF="$(preferred_family_for_rev "$HWREV")"
  FAM="$PREF"
  bold "→ Auto-Erkennung: BCM4364/${HWREV:-?} ⇒ wähle ${FAM}"

  bold "==> Lade Firmware-Paket"
  curl -fL "$FW_URL_DEFAULT" -o "$PKG"
  ok "Download ok: $(du -h "$PKG" | awk '{print $1}')"

  bold "==> Entpacke Paket"
  mkdir -p "$EX"
  tar $ZSTD_FLAG -xvf "$PKG" -C "$EX" >/dev/null
  local SRC="$EX/usr/lib/firmware/brcm"
  [[ -d "$SRC" ]] || die "Paket-Struktur unerwartet. Kein brcm/-Ordner gefunden."

  install_family_from_pkg "$FAM" "$SRC"
  reload_wifi_stack

  echo
  bold "Kurzreport"
  dmesg -T | egrep -i 'brcmfmac|firmware|bcm4364' | tail -n 40 || true
  nmcli -g WIFI radio || true
  nmcli dev status || true
  echo
  echo "If you do not see Wi-Fi yet, try a reboot."
  read -r -p "Reboot now? [y/N]: " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] && reboot
}

# ---------------------------
# Audio (CS8409): Basisschritte
# ---------------------------
do_audio(){
  bold "==> Audio (CS8409) aktivieren (Basisschritte)"
  rm -f /etc/modprobe.d/blacklist-cs8409.conf 2>/dev/null || true
  echo snd_hda_codec_cs8409 >/etc/modules-load.d/snd_hda_codec_cs8409.conf
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe -r snd_hda_intel 2>/dev/null || true
  modprobe snd_hda_intel || true
  modprobe snd_hda_codec_cs8409 || true
}

# ---------------------------
# Menü
# ---------------------------
menu(){
  {
    echo "== iMac Linux WiFi + Audio Installer =="
    echo "1) WLAN installieren"
    echo "2) Audio installieren (CS8409, Basis)"
    echo "3) WLAN + Audio installieren"
    echo "4) Kernel aktualisieren (Debian 12: Backports)"
    echo "5) Nur Service/Checks überspringen (nichts tun)"
  } >&2
  read -rp "> Auswahl [1-5]: " CH
  printf '%s\n' "${CH:-3}"
}

# ---------------------------
# Ablauf
# ---------------------------
bold "==> Voraussetzungen (Basis-Tools)"
apt-get update -y
apt-get install -y ca-certificates curl grep sed gawk coreutils \
                    network-manager

maybe_upgrade_kernel_backports
clone_or_fallback

CHOICE="$(menu)"
case "$CHOICE" in
  1) do_wifi ;;
  2) do_audio ;;
  3) do_wifi; do_audio ;;
  4) maybe_upgrade_kernel_backports ;; # falls erneut gewählt
  5) : ;;
  *) die "Ungültige Auswahl." ;;
esac

# Manifest (informativ)
{
  echo "installed_at=$(date -Iseconds)"
  echo "kernel=$(uname -r)"
} >>"${STATE_DIR}/manifest.txt"

# ---------------------------
# Zusammenfassung
# ---------------------------
summarize(){
  local wifi_ok="Nein" audio_ok="Nein"
  if lsmod | grep -q '^brcmfmac'; then wifi_ok="Ja"; fi
  if lsmod | grep -q '^snd_hda_codec_cs8409'; then audio_ok="Ja"; fi

  echo
  echo "== Zusammenfassung =="
  echo "System:  ${ID_STR:-unbekannt} (Codename: ${CODENAME:-n/a})"
  echo "Kernel:  $(uname -r)"
  echo "WLAN aktiv:  $wifi_ok"
  echo "Audio aktiv: $audio_ok"
  echo "Firmware:    ${FW_RUNTIME}"
  echo "Mirror:      ${FW_DIR_BASE}"
  echo "Manifest:    ${STATE_DIR}/manifest.txt"
  echo

  if [[ "$wifi_ok" != "Ja" ]]; then
    warn "WLAN ist noch nicht aktiv. Prüfe Symlinks und Logs:"
    echo "   ls -l /lib/firmware/brcm | grep 4364"
    echo "   dmesg -T | egrep -i 'brcmf|firmware|bcm4364' | tail -n 80"
    echo "   nmcli device status"
  else
    ok "WLAN sollte bereitstehen. 'nmcli dev wifi list' zeigt verfügbare Netze."
  fi

  if [[ "$audio_ok" != "Ja" ]]; then
    warn "Ein Neustart wird oft benötigt, damit CS8409 sauber initialisiert."
  else
    ok "Audio (CS8409) ist aktiv."
  fi
}
summarize
