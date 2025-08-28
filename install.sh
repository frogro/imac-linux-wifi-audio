#!/usr/bin/env bash
set -euo pipefail

REPO_WIFI_ZIP="https://github.com/reynaldliu/macbook16-1-wifi-bcm4364-binary/releases/download/v5.10.28-wifi/bcm4364_firmware.zip"
REPO_CS8409_TAR="https://github.com/egorenar/snd-hda-codec-cs8409/archive/refs/heads/master.tar.gz"

DKMS_NAME="snd-hda-codec-cs8409"
DKMS_VER="1.0"
SRC_ROOT="/usr/src/${DKMS_NAME}-${DKMS_VER}"
STATE_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST="${STATE_DIR}/manifest.txt"

bail() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || bail "Bitte mit sudo/root ausführen."; }

need_root
mkdir -p "$STATE_DIR"
echo "# Manifest for imac-linux-wifi-audio" >"$MANIFEST"

if ! grep -qE '^(13|13\.)' /etc/debian_version 2>/dev/null; then
  echo "WARN: Nicht Debian 13 erkannt. Ungetestet, kann aber funktionieren." | tee -a "$MANIFEST"
fi

echo
echo "Welche Komponenten sollen installiert werden?"
echo "  1) Nur WLAN"
echo "  2) Nur Audio"
echo "  3) WLAN + Audio (Standard)"
read -rp "Auswahl [1-3]: " choice
choice="${choice:-3}"

# ---------------- Basis-Pakete -------------------------
echo "==> Pakete installieren…"
apt-get update -y
apt-get install -y \
  curl wget unzip ca-certificates \
  build-essential dkms linux-headers-$(uname -r) \
  git make rsync \
  pipewire pipewire-pulse wireplumber pavucontrol \
  alsa-utils alsa-ucm-conf

# ---------------- WLAN -------------------------
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  echo "==> WLAN-Firmware installieren…"
  TMP_WIFI="$(mktemp -d)"
  pushd "$TMP_WIFI" >/dev/null
  curl -L -o bcm4364_firmware.zip "$REPO_WIFI_ZIP"
  unzip -o -q bcm4364_firmware.zip

  install -d /lib/firmware/brcm
  COPIED=()

  pick_first_present() {
    local base_dir="$1"; shift
    for c in "$@"; do
      if [ -f "${base_dir}/${c}.trx" ] && [ -f "${base_dir}/${c}.clmb" ] && [ -f "${base_dir}/${c}.txcb" ]; then
        echo "$c"
        return 0
      fi
    done
    return 1
  }

  B2_DIR="bcm4364_drivers/wifi_firmware/C-4364__s-B2"
  B2_CAND=("midway" "kauai" "nihau")
  [ -d "$B2_DIR" ] && B2_CHOICE="$(pick_first_present "$B2_DIR" "${B2_CAND[@]}")" || B2_CHOICE=""

  B3_DIR="bcm4364_drivers/wifi_firmware/C-4364__s-B3"
  B3_CAND=("kure" "borneo" "hanauma")
  [ -d "$B3_DIR" ] && B3_CHOICE="$(pick_first_present "$B3_DIR" "${B3_CAND[@]}")" || B3_CHOICE=""

  install_variant() {
    local variant="$1" base="$2" choice="$3"
    local apple_codename="$choice"
    local src_fw="${base}/${apple_codename}.trx"
    local src_clm="${base}/${apple_codename}.clmb"
    local src_txc="${base}/${apple_codename}.txcb"

    local t_apple_bin="/lib/firmware/brcm/brcmfmac4364${variant}-pcie.apple,${apple_codename}.bin"
    local t_apple_clm="/lib/firmware/brcm/brcmfmac4364${variant}-pcie.apple,${apple_codename}.clm_blob"
    local t_apple_txc="/lib/firmware/brcm/brcmfmac4364${variant}-pcie.apple,${apple_codename}.txcap_blob"

    install -m 0644 "$src_fw"  "$t_apple_bin"
    install -m 0644 "$src_clm" "$t_apple_clm"
    install -m 0644 "$src_txc" "$t_apple_txc"
    COPIED+=("$t_apple_bin" "$t_apple_clm" "$t_apple_txc")

    ln -sf "$(basename "$t_apple_bin")" "/lib/firmware/brcm/brcmfmac4364${variant}-pcie.bin"
    ln -sf "$(basename "$t_apple_clm")" "/lib/firmware/brcm/brcmfmac4364${variant}-pcie.clm_blob"
    ln -sf "$(basename "$t_apple_txc")" "/lib/firmware/brcm/brcmfmac4364${variant}-pcie.txcap_blob"
  }

  [ -n "$B2_CHOICE" ] && install_variant "b2" "$B2_DIR" "$B2_CHOICE"
  [ -n "$B3_CHOICE" ] && install_variant "b3" "$B3_DIR" "$B3_CHOICE"

  modprobe -r wl brcmfmac 2>/dev/null || true
  modprobe brcmfmac || echo "WARN: brcmfmac konnte nicht geladen werden."

  {
    echo "## WLAN files:"
    printf '%s\n' "${COPIED[@]}" | sort -u
  } >>"$MANIFEST"

  popd >/dev/null
  rm -rf "$TMP_WIFI"
fi

# ---------------- AUDIO -------------------------
if [ "$choice" = "2" ] || [ "$choice" = "3" ]; then
  echo "==> Audio (CS8409) via DKMS installieren…"
  rm -rf "$SRC_ROOT"
  mkdir -p "$SRC_ROOT"
  TMP_AUD="$(mktemp -d)"
  pushd "$TMP_AUD" >/dev/null

  curl -L -o cs8409.tar.gz "$REPO_CS8409_TAR"
  tar -xzf cs8409.tar.gz
  rsync -a --delete snd-hda-codec-cs8409-master/ "$SRC_ROOT/"

  cat >"$SRC_ROOT/dkms.conf" <<'EOF'
PACKAGE_NAME="snd-hda-codec-cs8409"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"
DEST_MODULE_LOCATION[0]="/kernel/sound/pci/hda"
AUTOINSTALL="yes"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
EOF

  dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
  dkms add    -m "$DKMS_NAME" -v "$DKMS_VER"
  dkms build  -m "$DKMS_NAME" -v "$DKMS_VER"
  dkms install -m "$DKMS_NAME" -v "$DKMS_VER"

  echo "## DKMS: ${DKMS_NAME}-${DKMS_VER}" >>"$MANIFEST"

  popd >/dev/null
  rm -rf "$TMP_AUD"
fi

# ---------------- PipeWire aktivieren -------------------------
echo "==> PipeWire aktivieren…"
if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
  runuser -u "$SUDO_USER" -- systemctl --user enable --now pipewire.service pipewire-pulse.service wireplumber.service || true
fi

echo
echo "✔ Installation abgeschlossen."
echo "Manifest: $MANIFEST"
