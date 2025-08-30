#!/usr/bin/env bash
set -euo pipefail

# Optional: --autoload legt /etc/modules-load.d/<modul>.conf an
AUTOLOAD=0
for arg in "${@:-}"; do
  case "$arg" in
    --autoload) AUTOLOAD=1 ;;
    *) echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
  esac
done

MODULE="snd_hda_codec_cs8409"
MOD_UNDER="$MODULE"     # modprobe-Name
KVER="$(uname -r)"
MODDIR="/lib/modules/${KVER}/kernel/sound/pci/hda"
DEST_KO_XZ="${MODDIR}/${MODULE}.ko.xz"
DEST_KO="${MODDIR}/${MODULE}.ko"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit Root-Rechten ausführen (sudo)." >&2
  exit 1
fi

echo "==> Prüfe Kernel-Verzeichnis: ${MODDIR}"
mkdir -p "${MODDIR}"

# Fall A: Modul bereits im Kernel vorhanden?
if modinfo -k "${KVER}" "${MODULE}" >/dev/null 2>&1; then
  echo "✔ Modul ${MODULE} ist bereits im Kernel ${KVER} vorhanden. Versuche zu laden..."
  modprobe "${MOD_UNDER}" || true
else
  echo "➡️  Modul scheint nicht im Kernel zu liegen – prüfe, ob ein lokales .ko(.xz) vorhanden ist..."
  SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
  CAND_XZ="${SRC_DIR}/${MODULE}.ko.xz"
  CAND_KO="${SRC_DIR}/${MODULE}.ko"

  if [[ -f "${CAND_XZ}" ]]; then
    echo "==> Kopiere ${CAND_XZ} nach ${DEST_KO_XZ}"
    install -m 0644 "${CAND_XZ}" "${DEST_KO_XZ}"
    echo "==> Entpacke ${DEST_KO_XZ}"
    xz -d -f "${DEST_KO_XZ}"
  elif [[ -f "${CAND_KO}" ]]; then
    echo "==> Kopiere ${CAND_KO} nach ${DEST_KO}"
    install -m 0644 "${CAND_KO}" "${DEST_KO}"
  else
    echo "❌ Weder ${CAND_XZ} noch ${CAND_KO} gefunden. Lege Modul nicht ab."
    echo "   Tipp: Nutze ggf. cirruslogic/extract_from_kernelpkg.sh als Fallback."
    exit 3
  fi

  echo "==> depmod & modprobe"
  depmod -a
  modprobe "${MOD_UNDER}" || true
fi

if (( AUTOLOAD )); then
  echo "==> Autoload aktivieren: /etc/modules-load.d/${MODULE}.conf"
  echo "${MOD_UNDER}" > "/etc/modules-load.d/${MODULE}.conf"
fi

# Optionale ALSA/PipeWire Initialisierung
command -v alsactl >/dev/null 2>&1 && alsactl init || true
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet pipewire 2>/dev/null; then
  systemctl --user restart pipewire || true
  systemctl --user restart pipewire-pulse || true
fi

echo "==> Kurzcheck:"
aplay -l || true
pactl list short sinks 2>/dev/null || true

echo "✅ CS8409 Setup fertig."
