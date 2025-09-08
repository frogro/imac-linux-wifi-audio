#!/usr/bin/env bash
# iMac 2019 (iMac19,1): WLAN (BCM4364 b2/b3) + Audio (CS8409 via DKMS)
# Debian 12/13 kompatibel. Optional: Debian 12 Backports-Kernel (>=6.8).
# WLAN: holt Firmware (Noa-Paket), setzt Symlinks (generisch + iMac19,1).
# Audio: ersetzt Non-DKMS-Variante vollständig durch DKMS-Build.

set -euo pipefail

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "• %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
warn(){ printf "⚠️  %s\n" "$*"; }
die(){ printf '❌ %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Bitte als root/sudo ausführen."; }

need_root

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMPROOT="$(mktemp -d /tmp/imac-linux-wifi-audio.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

STATE_DIR="/var/lib/imac-linux-wifi-audio"
FW_DIR_BASE="/usr/local/share/imac-linux-wifi-audio/broadcom"
FW_DIR_B2="${FW_DIR_BASE}/b2"
FW_DIR_B3="${FW_DIR_BASE}/b3"
FW_RUNTIME="/lib/firmware/brcm"
mkdir -p "$STATE_DIR" "$FW_DIR_B2" "$FW_DIR_B3" "$FW_RUNTIME"

FW_URL_DEFAULT="https://github.com/NoaHimesaka1873/apple-bcm-firmware/releases/download/v14.0/apple-bcm-firmware-14.0-1-any.pkg.tar.zst"

# Distro/Kernel
ID_STR=""; CODENAME=""
if [[ -r /etc/os-release ]]; then . /etc/os-release; ID_STR="${PRETTY_NAME:-$ID}"; CODENAME="${VERSION_CODENAME:-}"; fi

maybe_upgrade_kernel_backports() {
  bold "==> Kernel via Backports (optional)"
  if [[ "${ID:-}" != "debian" || "$CODENAME" != "bookworm" ]]; then
    info "Nicht Debian 12/bookworm → übersprungen."; return 0; fi
  local kv; kv="$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
  awk -v kv="$kv" 'BEGIN{split(kv,a,"."); exit ! (a[1]>6 || (a[1]==6 && a[2]>=8)) }' || {
    printf "Erkannt: %s (%s)\n" "$ID_STR" "$CODENAME"
    read -r -p "Backports eintragen & Kernel/Headers installieren? [y/N]: " yn
    [[ "${yn:-N}" =~ ^[Yy]$ ]] || { info "Backports-Upgrade übersprungen."; return 0; }
    info "Trage bookworm-backports ein…"
    echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware" \
      > /etc/apt/sources.list.d/backports.list
    apt-get update -y
    apt-get -y -t bookworm-backports install linux-image-amd64 linux-headers-amd64
    warn "Neustart erforderlich, damit neuer Kernel aktiv wird."
    read -r -p "Jetzt neu starten? [y/N]: " rn; [[ "${rn:-N}" =~ ^[Yy]$ ]] && reboot
  }
}

# --- WLAN (BCM4364 b2/b3, Noa) ---
chip_present(){ lspci -nn | grep -qi '14e4:4464'; }
detect_hw_rev(){ local d; d="$(dmesg | grep -m1 -o 'BCM4364/[23]' || true)"; [[ -n "$d" ]] && echo "${d##*/}" || echo ""; }
preferred_family_for_rev(){ case "$1" in 3) echo b2;; 2) echo b3;; *) echo b2;; esac; }

pick_txt_from_pkg(){
  local fam="$1" src="$2" picked=""
  install -d -m0755 "$FW_RUNTIME"
  shopt -s nullglob
  if [[ "$fam" == "b2" ]]; then
    for cand in brcmfmac4364b2-pcie.apple,midway-HRPN-m.txt brcmfmac4364b2-pcie.apple,midway-HRPN-u.txt; do
      [[ -f "$src/$cand" ]] && { picked="$cand"; break; }
    done
    [[ -n "$picked" ]] && install -m0644 "$src/$picked" "$FW_RUNTIME/brcmfmac4364b2-pcie.apple,midway.txt"
  else
    for cand in brcmfmac4364b3-pcie.apple,borneo-HRPN-u-7.9.txt brcmfmac4364b3-pcie.apple,borneo-HRPN-u-7.7.txt brcmfmac4364b3-pcie.apple,borneo-HRPN-m.txt; do
      [[ -f "$src/$cand" ]] && { picked="$cand"; break; }
    done
    [[ -n "$picked" ]] && install -m0644 "$src/$picked" "$FW_RUNTIME/brcmfmac4364b3-pcie.apple,borneo.txt"
  fi
  shopt -u nullglob
  [[ -n "$picked" ]] && ok "TXT gewählt: $picked" || warn "Keine passende .txt gefunden (Kalibrierung ggf. suboptimal)."
}

install_family_from_pkg(){
  local fam="$1" src="$2" base label
  if [[ "$fam" == "b2" ]]; then base="brcmfmac4364b2-pcie.apple,midway"; label="midway"; else base="brcmfmac4364b3-pcie.apple,borneo"; label="borneo"; fi
  install -d -m0755 "$FW_RUNTIME"
  for ext in bin clm_blob txcap_blob; do [[ -f "$src/${base}.${ext}" ]] || die "Fehlt: ${base}.${ext}"; install -m0644 "$src/${base}.${ext}" "$FW_RUNTIME/${base}.${ext}"; done
  pick_txt_from_pkg "$fam" "$src"
  ln -sf "${base}.bin"        "$FW_RUNTIME/brcmfmac4364-pcie.bin"
  ln -sf "${base}.clm_blob"   "$FW_RUNTIME/brcmfmac4364-pcie.clm_blob"
  ln -sf "${base}.txcap_blob" "$FW_RUNTIME/brcmfmac4364-pcie.txcap_blob"
  [[ -f "$FW_RUNTIME/${base}.txt" ]] && ln -sf "${base}.txt" "$FW_RUNTIME/brcmfmac4364-pcie.txt"
  # Board-spezifisch:
  ln -sf "${base}.bin"        "$FW_RUNTIME/brcmfmac4364-pcie.Apple Inc.-iMac19,1.bin"
  ln -sf "${base}.clm_blob"   "$FW_RUNTIME/brcmfmac4364-pcie.Apple Inc.-iMac19,1.clm_blob"
  ln -sf "${base}.txcap_blob" "$FW_RUNTIME/brcmfmac4364-pcie.Apple Inc.-iMac19,1.txcap_blob"
  [[ -f "$FW_RUNTIME/${base}.txt" ]] && ln -sf "${base}.txt" "$FW_RUNTIME/brcmfmac4364-pcie.Apple Inc.-iMac19,1.txt"
  ok "Installiert: ${label} (${fam}) → $FW_RUNTIME"
}

reload_wifi_stack(){
  echo "options brcmfmac p2pon=0" >/etc/modprobe.d/brcmfmac.conf || true
  modprobe -r wl 2>/dev/null || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211 || true; modprobe brcmutil || true; modprobe brcmfmac || true
  have rfkill || { apt-get update -y; apt-get install -y rfkill; }
  rfkill unblock all || true
  systemctl restart NetworkManager 2>/dev/null || true
}

do_wifi(){
  bold "==> WLAN installieren (BCM4364 b2/b3 via Noa)"
  chip_present || die "BCM4364 (14e4:4464) nicht gefunden."
  have curl || die "curl fehlt."; have tar  || die "tar fehlt."
  local ZSTD_FLAG="--zstd"; tar --help | grep -q -- --zstd || ZSTD_FLAG="--use-compress-program=unzstd"
  local TMP="$TMPROOT/fw"; mkdir -p "$TMP"; local PKG="$TMP/fw.pkg.tar.zst" EX="$TMP/extract"
  local HWREV PREF FAM; HWREV="$(detect_hw_rev || true)"; PREF="$(preferred_family_for_rev "$HWREV")"; FAM="$PREF"
  bold "→ Auto-Erkennung: BCM4364/${HWREV:-?} ⇒ wähle ${FAM}"
  curl -fL "$FW_URL_DEFAULT" -o "$PKG"; ok "Download ok: $(du -h "$PKG" | awk '{print $1}')"
  mkdir -p "$EX"; tar $ZSTD_FLAG -xvf "$PKG" -C "$EX" >/dev/null
  local SRC="$EX/usr/lib/firmware/brcm"; [[ -d "$SRC" ]] || die "Paket-Struktur unerwartet."
  install_family_from_pkg "$FAM" "$SRC"
  reload_wifi_stack
  echo; bold "Kurzreport (Wi-Fi)"; dmesg -T | egrep -i 'brcmfmac|firmware|bcm4364' | tail -n 40 || true; nmcli dev status || true
}

# --- Audio via DKMS (ersetzt Non-DKMS) ---
do_audio(){
  bold "==> Audio (CS8409) via DKMS installieren"
  apt-get update -y
  apt-get install -y git dkms rsync sed linux-headers-amd64 "linux-headers-$(uname -r)" || true

  local PKG="snd-hda-codec-cs8409" UPSTREAM_URL="https://github.com/davidjo/snd_hda_macbookpro.git" DEFAULT_REF="master"
  local WORK_DIR="$TMPROOT/upstream-cs8409"
  rm -rf "$WORK_DIR"; git clone --depth 1 --branch "$DEFAULT_REF" "$UPSTREAM_URL" "$WORK_DIR"
  local SHORTSHA DATE PKG_VERSION; SHORTSHA="$(git -C "$WORK_DIR" rev-parse --short=7 HEAD)"; DATE="$(date +%Y%m%d)"
  PKG_VERSION="1.0+${DATE}-${SHORTSHA}"; info "DKMS-Version: ${PKG_VERSION}"

  bold "==> Alte DKMS-Versionen entfernen"
  while read -r line; do
    local ver; ver="${line#${PKG}/}"; ver="${ver%%,*}"; [[ -n "$ver" ]] || continue
    dkms remove -m "${PKG}" -v "${ver}" --all || true; rm -rf "/usr/src/${PKG}-${ver}" || true
  done < <(dkms status | grep "^${PKG}/" || true); rm -rf "/var/lib/dkms/${PKG}" || true

  local DKMS_SRC="/usr/src/${PKG}-${PKG_VERSION}"
  bold "==> Quellen nach ${DKMS_SRC}"; rm -rf "${DKMS_SRC}"; mkdir -p "${DKMS_SRC}"
  rsync -a --delete --exclude ".git" "${WORK_DIR}/" "${DKMS_SRC}/"

  if [[ -f "${SCRIPT_DIR}/dkms.conf" ]]; then install -m 0644 "${SCRIPT_DIR}/dkms.conf" "${DKMS_SRC}/dkms.conf"
  elif [[ ! -f "${DKMS_SRC}/dkms.conf" ]]; then die "dkms.conf fehlt (Repo & Upstream)."; fi
  sed -i -E "s/^PACKAGE_VERSION=\"[^\"]*\"/PACKAGE_VERSION=\"${PKG_VERSION}\"/" "${DKMS_SRC}/dkms.conf"
  grep -q "^BUILT_MODULE_LOCATION\[0\]=" "${DKMS_SRC}/dkms.conf" || echo 'BUILT_MODULE_LOCATION[0]="build/hda"' >> "${DKMS_SRC}/dkms.conf"

  bold "==> DKMS add/build/install"
  dkms add -m "${PKG}" -v "${PKG_VERSION}" || true
  dkms build -m "${PKG}" -v "${PKG_VERSION}"
  dkms install -m "${PKG}" -v "${PKG_VERSION}"

  bold "==> depmod & Module neu laden"
  depmod -a
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe snd_hda_intel 2>/dev/null || true
  modprobe snd_hda_codec_cs8409 2>/dev/null || true

  ok  "DKMS installiert: ${PKG}-${PKG_VERSION}"
  modinfo snd_hda_codec_cs8409 2>/dev/null | egrep 'filename|version' || true
  dmesg -T | egrep -i 'snd|hda|cs8409' | tail -n 60 || true
}

menu(){
  {
    echo "== iMac Linux WiFi + Audio Installer =="
    echo "1) WLAN installieren"
    echo "2) Audio installieren (CS8409 via DKMS)"
    echo "3) WLAN + Audio installieren"
    echo "4) Kernel aktualisieren (Debian 12: Backports)"
    echo "5) Checker/Notifier/Polkit einrichten"
  } >&2
  read -rp "> Auswahl [1-5]: " CH
  printf '%s\n' "${CH:-3}"
}

bold "==> Basis-Tools"
apt-get update -y
apt-get install -y ca-certificates curl grep sed gawk coreutils network-manager pciutils tar

CHOICE="$(menu)"
case "$CHOICE" in
  1) do_wifi ;;
  2) do_audio ;;
  3) do_wifi; do_audio ;;
  4) maybe_upgrade_kernel_backports ;;
  5) bash "$SCRIPT_DIR/scripts/kernel_update_service.sh" ;;
  *) die "Ungültige Auswahl." ;;
esac

# Manifest
{
  echo "installed_at=$(date -Iseconds)"
  echo "kernel=$(uname -r)"
} >>"${STATE_DIR}/manifest.txt"

# Zusammenfassung (+ erkennt Kernel-vs-DKMS & Firmware-Quelle)
echo
bold "== Zusammenfassung =="
wifi_ok="Nein"; audio_ok="Nein"
lsmod | grep -q '^brcmfmac' && wifi_ok="Ja"
lsmod | grep -q '^snd_hda_codec_cs8409' && audio_ok="Ja"
echo "System:   ${ID_STR:-unbekannt} (Codename: ${CODENAME:-n/a})"
echo "Kernel:   $(uname -r)"
echo "WLAN:     $wifi_ok"
echo "Audio:    $audio_ok"
echo "Firmware: ${FW_RUNTIME}"
echo "Manifest: ${STATE_DIR}/manifest.txt"
echo

echo "Audio (Quelle):"
if modinfo snd_hda_codec_cs8409 &>/dev/null; then
  modinfo snd_hda_codec_cs8409 | grep filename | sed 's/^/  /'
  modinfo snd_hda_codec_cs8409 | grep ^version | sed 's/^/  /' || true
  case "$(modinfo snd_hda_codec_cs8409 | awk -F: '/filename/{print $2}')" in
    *"/updates/dkms/"*) echo "  → DKMS-Modul aktiv";;
    *"/kernel/sound/pci/hda/"*) echo "  → In-Kernel-Modul aktiv (DKMS evtl. überflüssig)";;
  esac
else
  echo "  (modinfo nicht verfügbar)"
fi

echo
echo "WLAN (Firmware-Quelle):"
if dpkg -S /lib/firmware/brcm/brcmfmac4364b2-pcie.bin >/dev/null 2>&1 || \
   dpkg -S /lib/firmware/brcm/brcmfmac4364b3-pcie.bin >/dev/null 2>&1; then
  echo "  → Bereitgestellt durch Debian-Paket (firmware-brcm80211 o.ä.)"
else
  echo "  → Bereitgestellt durch Noa-Paket + Symlinks"
fi
echo
ok "Fertig."
