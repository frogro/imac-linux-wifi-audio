#!/usr/bin/env bash
set -euo pipefail

REPO_WIFI_ZIP="https://github.com/reynaldliu/macbook16-1-wifi-bcm4364-binary/releases/download/v5.10.28-wifi/bcm4364_firmware.zip"
REPO_CS8409_TAR="https://github.com/egorenar/snd-hda-codec-cs8409/archive/refs/heads/master.tar.gz"

DKMS_NAME="snd-hda-codec-cs8409"
DKMS_VER="1.0"
SRC_ROOT="/usr/src/${DKMS_NAME}-${DKMS_VER}"
STATE_DIR="/var/lib/imac-linux-wifi-audio"
MANIFEST="${STATE_DIR}/manifest.txt"

# --- helpers ---------------------------------------------------------------
bail() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || bail "Bitte mit sudo/root ausführen."; }

# --- preflight -------------------------------------------------------------
need_root
mkdir -p "$STATE_DIR"
echo "# Manifest for imac-linux-wifi-audio" >"$MANIFEST"

# Debian 13 check (nicht hart zwingend, aber warnen)
if ! grep -qE '^(13|13\.)' /etc/debian_version 2>/dev/null; then
  echo "WARN: Nicht Debian 13 erkannt. Es kann trotzdem funktionieren, ist aber ungetestet." | tee -a "$MANIFEST"
fi

echo "==> Pakete installieren…"
apt-get update -y
apt-get install -y \
  curl wget unzip ca-certificates \
  build-essential dkms linux-headers-$(uname -r) \
  git make \
  pipewire pipewire-pulse wireplumber pavucontrol \
  alsa-utils alsa-ucm-conf

# --- WLAN: BCM4364 Firmware ------------------------------------------------
echo "==> WLAN-Firmware holen & installieren…"
TMP_WIFI="$(mktemp -d)"
pushd "$TMP_WIFI" >/dev/null

curl -L -o bcm4364_firmware.zip "$REPO_WIFI_ZIP"
unzip -o bcm4364_firmware.zip

# Zielordner
install -d /lib/firmware/brcm

# Alle BCM4364-Dateien ins System kopieren
# (beide Varianten b2/b3 werden abgelegt; der Kernel nimmt die passende)
COPIED=()
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  install -m 0644 "$f" "/lib/firmware/brcm/$base"
  COPIED+=("/lib/firmware/brcm/$base")
done < <(find . -type f -name 'brcmfmac4364b*-pcie.*' -print0)

# Nützliche Symlinks für generische Loader-Pfade anlegen (best effort)
pushd /lib/firmware/brcm >/dev/null
for v in b2 b3; do
  for ext in bin clm_blob txcap_blob txt; do
    # falls eine Apple-Variante vorhanden ist (z.B. midway/kauai), symlink auf generischen Namen
    if ls "brcmfmac4364${v}-pcie.apple,"*".${ext}" >/dev/null 2>&1; then
      src="$(ls -1 "brcmfmac4364${v}-pcie.apple,"*".${ext}" | head -n1)"
      ln -sf "$src" "brcmfmac4364${v}-pcie.${ext}"
      COPIED+=("/lib/firmware/brcm/brcmfmac4364${v}-pcie.${ext}")
    fi
  done
done
popd >/dev/null

# Blacklist aufräumen & Modul laden
sed -i '/^blacklist brcmfmac$/d' /etc/modprobe.d/broadcom-blacklist.conf 2>/dev/null || true
modprobe -r wl 2>/dev/null || true
modprobe -r brcmfmac 2>/dev/null || true
if ! modprobe brcmfmac; then
  echo "WARN: brcmfmac konnte nicht geladen werden. Neustart probieren." | tee -a "$MANIFEST"
fi

# Manifest schreiben
{
  echo "## WLAN files:"
  printf '%s\n' "${COPIED[@]}" | sort -u
} >>"$MANIFEST"

popd >/dev/null
rm -rf "$TMP_WIFI"

# --- AUDIO: CS8409 via DKMS -----------------------------------------------
echo "==> Audio (CS8409) via DKMS bauen & installieren…"
rm -rf "$SRC_ROOT"
mkdir -p "$SRC_ROOT"
TMP_AUD="$(mktemp -d)"
pushd "$TMP_AUD" >/dev/null

curl -L -o cs8409.tar.gz "$REPO_CS8409_TAR"
tar -xzf cs8409.tar.gz
# Inhalt nach /usr/src/<name>-<ver> kopieren
rsync -a --delete snd-hda-codec-cs8409-master/ "$SRC_ROOT/"

# dkms.conf schreiben (auf vorhandene Makefile-Struktur bauen)
cat >"$SRC_ROOT/dkms.conf" <<'EOF'
PACKAGE_NAME="snd-hda-codec-cs8409"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"
DEST_MODULE_LOCATION[0]="/kernel/sound/pci/hda"
AUTOINSTALL="yes"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
EOF

# DKMS register/build/install
dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
dkms add -m "$DKMS_NAME" -v "$DKMS_VER"
dkms build -m "$DKMS_NAME" -v "$DKMS_VER"
dkms install -m "$DKMS_NAME" -v "$DKMS_VER"

popd >/dev/null
rm -rf "$TMP_AUD"

echo "## DKMS: ${DKMS_NAME}-${DKMS_VER}" >>"$MANIFEST"

# --- PipeWire für aktuellen Benutzer aktivieren ---------------------------
echo "==> PipeWire im Nutzerkontext aktivieren…"
if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
  # Nutzer-User-Services (ohne grafische Session kann enable fehlschlagen – best effort)
  runuser -u "$SUDO_USER" -- systemctl --user enable --now pipewire.service pipewire-pulse.service wireplumber.service || true
fi

# --- Abschluss -------------------------------------------------------------
echo
echo "✔ Installation abgeschlossen."
echo
echo "• WLAN: brcmfmac-Firmware installiert (b2/b3)."
echo "• Audio: CS8409-Modul per DKMS eingebunden."
echo "• PipeWire aktiviert. Bitte abmelden/anmelden oder neu starten."
echo
echo "Tipps:"
echo "  - WLAN prüfen:  nmcli dev wifi list"
echo "  - Audio-Ausgabe wählen:  pavucontrol (interne HDA, nicht HDMI)"
echo "  - DKMS-Status:  sudo dkms status"
echo
echo "Manifest: $MANIFEST"
