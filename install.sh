#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================
#  iMac Late 2019 – WLAN (b2/b3) + Audio CS8409
# ============================================

# ----- Helpers -----
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Bitte mit sudo/root starten."; exit 1; }; }
say()  { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[×]\033[0m $*"; exit 1; }

need_root

# ----- Repos & Pfade -----
REPO_URL="https://github.com/frogro/imac-linux-wifi-audio.git"
REPO_DIR="/tmp/imac-linux-wifi-audio"

FW_DEST="/lib/firmware/brcm"

# DKMS (neues Schema)
DKMS_NAME="snd-hda-codec-cs8409"
DKMS_VER="1.0-6.12"                         # DKMS-Versionslabel
DKMS_SRC="/usr/src/${DKMS_NAME}-${DKMS_VER}"

# Audio-Quellen
FROGRO_SUBDIR="cirruslogic"                 # erwartet deine *.c/*.h
DAVIDJO_REPO="https://github.com/davidjo/snd_hda_macbookpro.git"
DAVIDJO_SUBDIR="patch_cirrus"               # Fallback

# ----- Fehler- / Exit-Handling -----
WORK=""
cleanup() {
  [[ -n "${WORK}" && -d "${WORK}" ]] && rm -rf "${WORK}" || true
}
trap cleanup EXIT

on_error() {
  echo
  echo "!!! Fehler während der Installation."
  # Falls Audio gebaut wurde: DKMS-Log anhängen
  local log="/var/lib/dkms/${DKMS_NAME}/${DKMS_VER}/build/make.log"
  if [[ -f "$log" ]]; then
    echo "--- DKMS Build-Log (Tail) ---"
    tail -n 120 "$log" || true
  fi
}
trap on_error ERR

# =========================
#  Auswahlmenü
# =========================
echo "Welche Komponenten sollen installiert werden?"
echo "  1) Nur WLAN"
echo "  2) Nur Audio"
echo "  3) WLAN + Audio (Standard)"
read -r -p "Auswahl [1-3]: " CHOICE
CHOICE="${CHOICE:-3}"

DO_WIFI=false; DO_AUDIO=false
case "$CHOICE" in
  1) DO_WIFI=true ;;
  2) DO_AUDIO=true ;;
  3) DO_WIFI=true; DO_AUDIO=true ;;
  *) warn "Ungültige Eingabe – nehme Standard (3)."; DO_WIFI=true; DO_AUDIO=true ;;
esac

# =========================
#  Pakete
# =========================
say "Pakete installieren…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  git curl wget unzip ca-certificates \
  build-essential dkms make rsync \
  linux-headers-"$(uname -r)" \
  pipewire pipewire-pulse wireplumber \
  pavucontrol alsa-utils alsa-ucm-conf \
  grep coreutils sed gawk

# =========================
#  Repo holen (shallow clone)
# =========================
say "Repository von GitHub holen…"
rm -rf "$REPO_DIR"
git clone --depth=1 "$REPO_URL" "$REPO_DIR"

# =========================
#  WLAN installieren
# =========================
if $DO_WIFI; then
  say "WLAN-Firmware (b2 & b3) kopieren…"
  mkdir -p "$FW_DEST"

  B2_SRC="$REPO_DIR/broadcom/b2"
  B3_SRC="$REPO_DIR/broadcom/b3"

  found_any=false

  if [ -d "$B2_SRC" ]; then
    for f in \
      brcmfmac4364b2-pcie.bin \
      brcmfmac4364b2-pcie.clm_blob \
      brcmfmac4364b2-pcie.txcap_blob \
      brcmfmac4364b2-pcie.apple,midway.bin \
      brcmfmac4364b2-pcie.apple,midway.clm_blob \
      brcmfmac4364b2-pcie.apple,midway.txcap_blob
    do
      [ -f "$B2_SRC/$f" ] && install -m 0644 "$B2_SRC/$f" "$FW_DEST/" && found_any=true
    done
  fi

  if [ -d "$B3_SRC" ]; then
    for f in \
      brcmfmac4364b3-pcie.bin \
      brcmfmac4364b3-pcie.clm_blob \
      brcmfmac4364b3-pcie.txcap_blob \
      brcmfmac4364b3-pcie.apple,borneo.bin \
      brcmfmac4364b3-pcie.apple,borneo.clm_blob \
      brcmfmac4364b3-pcie.apple,borneo.txcap_blob
    do
      [ -f "$B3_SRC/$f" ] && install -m 0644 "$B3_SRC/$f" "$FW_DEST/" && found_any=true
    done
  fi

  $found_any || die "Keine Broadcom-Firmwaredateien im Repo gefunden."

  # Hinweise, aber nicht fatal
  for must in \
      brcmfmac4364b2-pcie.bin brcmfmac4364b2-pcie.clm_blob brcmfmac4364b2-pcie.txcap_blob \
      brcmfmac4364b3-pcie.bin brcmfmac4364b3-pcie.clm_blob brcmfmac4364b3-pcie.txcap_blob
  do
    [ -f "$FW_DEST/$must" ] || warn "Hinweis: $must fehlt in $FW_DEST (ok, wenn dein Gerät die andere Revision nutzt)."
  done

  say "WLAN-Firmware installiert nach $FW_DEST."
fi

# =========================
#  Audio (CS8409) via DKMS
# =========================
if $DO_AUDIO; then
  say "CS8409 (Cirrus) DKMS vorbereiten…"

  # Altversionen aufräumen (falls du vorher 1.0 genutzt hast)
  if dkms status | grep -q "^${DKMS_NAME}/1.0"; then
    say "Alte DKMS-Version ${DKMS_NAME}/1.0 entfernen…"
    dkms remove -m "${DKMS_NAME}" -v "1.0" --all || true
  fi

  # Unsere Version säubern
  if dkms status | grep -q "^${DKMS_NAME}/${DKMS_VER}"; then
    say "Vorhandene DKMS-Version ${DKMS_NAME}/${DKMS_VER} entfernen…"
    dkms remove -m "${DKMS_NAME}" -v "${DKMS_VER}" --all || true
  fi
  rm -rf "$DKMS_SRC"
  install -d "$DKMS_SRC"

  # Arbeitsverzeichnis
  WORK="$(mktemp -d -p /tmp cs8409.XXXXXX)"
  say "Arbeitsverzeichnis: ${WORK}"

  # Quellen aus frogro bevorzugen
  SRC_DIR="${REPO_DIR}/${FROGRO_SUBDIR}"
  if [[ -f "${SRC_DIR}/patch_cs8409.c" ]]; then
    say "Verwende Quellen aus frogro/${FROGRO_SUBDIR}"
  else
    warn "In ${FROGRO_SUBDIR}/ fehlt patch_cs8409.c – weiche auf davidjo aus…"
    git clone --depth=1 "${DAVIDJO_REPO}" "${WORK}/davidjo"
    if [[ -f "${WORK}/davidjo/${DAVIDJO_SUBDIR}/patch_cs8409.c" ]]; then
      SRC_DIR="${WORK}/davidjo/${DAVIDJO_SUBDIR}"
      say "Verwende Fallback-Quellen aus davidjo/${DAVIDJO_SUBDIR}"
    else
      die "Weder in frogro/${FROGRO_SUBDIR} noch in davidjo/${DAVIDJO_SUBDIR} gibt es patch_cs8409.c"
    fi
  fi

  # Relevante Dateien kopieren
  rsync -a \
    --include='*.c' --include='*.h' \
    --exclude='*' \
    "${SRC_DIR}/" "${DKMS_SRC}/"

  [[ -f "${DKMS_SRC}/patch_cs8409.c" ]] || die "patch_cs8409.c fehlt unter ${DKMS_SRC}"

  # (A) Kompatibilitäts-Header bereitstellen
  say "cs8409_compat.h hinzufügen…"
  cat > "${DKMS_SRC}/cs8409_compat.h" <<'EOF'
#ifndef _CS8409_COMPAT_H
#define _CS8409_COMPAT_H

/* hda_local.h */
#if __has_include(<sound/pci/hda/hda_local.h>)
#  include <sound/pci/hda/hda_local.h>
#elif __has_include("hda_local.h")
#  include "hda_local.h"
#else
#  error "hda_local.h nicht gefunden – bitte Kernel-Header installieren"
#endif

/* hda_codec.h */
#if __has_include(<sound/pci/hda/hda_codec.h>)
#  include <sound/pci/hda/hda_codec.h>
#elif __has_include("hda_codec.h")
#  include "hda_codec.h"
#endif

/* hda_jack.h */
#if __has_include(<sound/pci/hda/hda_jack.h>)
#  include <sound/pci/hda/hda_jack.h>
#elif __has_include("hda_jack.h")
#  include "hda_jack.h"
#endif

/* hda_auto_parser.h */
#if __has_include(<sound/pci/hda/hda_auto_parser.h>)
#  include <sound/pci/hda/hda_auto_parser.h>
#elif __has_include("hda_auto_parser.h")
#  include "hda_auto_parser.h"
#endif

/* hda_bind.h */
#if __has_include(<sound/pci/hda/hda_bind.h>)
#  include <sound/pci/hda/hda_bind.h>
#elif __has_include("hda_bind.h")
#  include "hda_bind.h"
#endif

/* hda_generic.h */
#if __has_include(<sound/pci/hda/hda_generic.h>)
#  include <sound/pci/hda/hda_generic.h>
#elif __has_include("hda_generic.h")
#  include "hda_generic.h"
#endif

#endif /* _CS8409_COMPAT_H */
EOF

  # (B) patch_cs8409.c automatisch auf cs8409_compat.h umstellen (idempotent)
  say "Includes in patch_cs8409.c auf cs8409_compat.h umstellen…"
  # Erst alle direkten HDA-Includes entfernen/ersetzen …
  sed -i -E \
    -e 's|#include[[:space:]]*"hda_[a-z_]+\.h"[[:space:]]*$||g' \
    -e 's|#include[[:space:]]*<sound/pci/hda/hda_[a-z_]+\.h>[[:space:]]*$||g' \
    "${DKMS_SRC}/patch_cs8409.c"
  # … und sicherstellen, dass genau 1 Include für den Kompat-Header vorhanden ist.
  if ! grep -q '^#include[[:space:]]*"cs8409_compat.h"' "${DKMS_SRC}/patch_cs8409.c"; then
    sed -i '1i #include "cs8409_compat.h"' "${DKMS_SRC}/patch_cs8409.c"
  fi

  # dkms.conf schreiben
  say "dkms.conf schreiben…"
  cat > "${DKMS_SRC}/dkms.conf" <<'DKMSCONF'
PACKAGE_NAME="snd-hda-codec-cs8409"
PACKAGE_VERSION="1.0-6.12"

BUILT_MODULE_NAME[0]="snd-hda-codec-cs8409"
DEST_MODULE_LOCATION[0]="/kernel/sound/pci/hda"

# DKMS übergibt ${kernelver}; an Kbuild weiterreichen
MAKE[0]="make KDIR=/lib/modules/${kernelver}/build"
CLEAN="make clean"

AUTOINSTALL="yes"
DKMSCONF

  # Kbuild-Wrapper-Makefile schreiben
  say "Kbuild-Wrapper-Makefile schreiben…"
  cat > "${DKMS_SRC}/Makefile" <<'KBUILD'
# Kbuild-Wrapper für DKMS
KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := snd-hda-codec-cs8409.o
# Nur diese .c erzeugt das Modul; weitere .h werden via #include verwendet
snd-hda-codec-cs8409-objs := patch_cs8409.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
KBUILD

  # DKMS add/build/install
  say "DKMS add/build/install…"
  dkms add -m "${DKMS_NAME}" -v "${DKMS_VER}"
  dkms build -m "${DKMS_NAME}" -v "${DKMS_VER}"
  dkms install -m "${DKMS_NAME}" -v "${DKMS_VER}"

  # Audio-Userdienste (best effort)
  say "Audio-Dienste aktivieren (falls möglich)…"
  SUDO_USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
  if id "$SUDO_USER_NAME" &>/dev/null; then
    loginctl enable-linger "$SUDO_USER_NAME" || true
    su -s /bin/sh -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$SUDO_USER_NAME") systemctl --user daemon-reload" "$SUDO_USER_NAME" || true
    su -s /bin/sh -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$SUDO_USER_NAME") systemctl --user enable --now pipewire pipewire-pulse wireplumber" "$SUDO_USER_NAME" || true
  else
    warn "Konnte User-Services nicht aktivieren (Live-Umgebung?). Audio funktioniert nach Reboot dennoch."
  fi

  # Modul laden
  say "Kernel-Module neu einlesen & laden…"
  depmod -a || true
  if modprobe snd-hda-codec-cs8409 2>/dev/null; then
    say "CS8409-Modul geladen."
  else
    warn "Modul konnte nicht sofort geladen werden. Prüfe dmesg:"
    echo "    dmesg | grep -i cs8409 | tail -n 120"
  fi

  say "CS8409 DKMS installiert."
fi

# =========================
#  Abschluss
# =========================
say "✔ Installation abgeschlossen."
echo "  • WLAN-Firmware liegt in: $FW_DEST"
$DO_AUDIO && echo "  • DKMS: $(dkms status | grep -E "^${DKMS_NAME}/${DKMS_VER}" || echo 'nicht gefunden')"
echo
echo "Empfehlung: System neu starten."
echo "Falls Audio stumm: 'pavucontrol' öffnen und Profil/Ausgabe prüfen."
