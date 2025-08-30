#!/usr/bin/env bash
set -euo pipefail

# Optionen:
#   --module=NAME   (Default: snd-hda-codec-cs8409)
#   --keep-workdir  Temp-Ordner behalten

MODULE_DASH="snd-hda-codec-cs8409"   # Dateiname mit Bindestrichen
KEEP_WORKDIR=0
for arg in "${@:-}"; do
  case "$arg" in
    --module=*) MODULE_DASH="${arg#*=}" ;;
    --keep-workdir) KEEP_WORKDIR=1 ;;
    *) echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
  esac
done

MODULE_UNDER="${MODULE_DASH//-/_}" # modprobe-Name mit Unterstrichen
KVER="$(uname -r)"
WORKDIR="$(mktemp -d /tmp/cs8409.XXXXXX)"
MODDIR="/lib/modules/${KVER}/kernel/sound/pci/hda"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit Root-Rechten ausführen (sudo)." >&2
  exit 1
fi

trap '(( KEEP_WORKDIR )) || rm -rf "${WORKDIR}"' EXIT

echo "==> Suche Kernel-Dateien in /usr/lib/modules/${KVER}"
KPATH="/usr/lib/modules/${KVER}"
if [[ ! -d "$KPATH" ]]; then
  KPATH="/lib/modules/${KVER}"
fi

# Versuche vorhandene .ko(.xz) direkt zu finden
FOUND=""
if [[ -f "${KPATH}/kernel/sound/pci/hda/${MODULE_DASH}.ko" ]]; then
  FOUND="${KPATH}/kernel/sound/pci/hda/${MODULE_DASH}.ko"
elif [[ -f "${KPATH}/kernel/sound/pci/hda/${MODULE_DASH}.ko.xz" ]]; then
  FOUND="${KPATH}/kernel/sound/pci/hda/${MODULE_DASH}.ko.xz"
fi

if [[ -z "$FOUND" ]]; then
  echo "⚠️  Modul nicht direkt gefunden. Ist das passende linux-image Paket installiert?"
  echo "    Tipp: apt-get install --reinstall linux-image-${KVER}"
  exit 4
fi

mkdir -p "$MODDIR"

if [[ "$FOUND" == *.xz ]]; then
  echo "==> Kopiere & entpacke: $FOUND"
  install -m 0644 "$FOUND" "${MODDIR}/${MODULE_DASH}.ko.xz"
  xz -d -f "${MODDIR}/${MODULE_DASH}.ko.xz"
else
  echo "==> Kopiere: $FOUND"
  install -m 0644 "$FOUND" "${MODDIR}/${MODULE_DASH}.ko"
fi

echo "==> depmod & Testlade: ${MODULE_UNDER}"
depmod -a
if modprobe "$MODULE_UNDER"; then
  echo "✅ Modul geladen (Test)."
else
  echo "⚠️  Konnte Modul nicht laden. Kernelmeldungen folgen:"
  dmesg | tail -n 80
  echo "   Vermagic mismatch? Prüfe:  modinfo -F vermagic ${MODDIR}/${MODULE_DASH}.ko*  && uname -r"
  exit 5
fi

echo "🎉 Fertig (ohne Autoload). Prüfen: lsmod | grep ${MODULE_UNDER}"
