#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="/var/lib/imac-linux-wifi-audio/manifest.txt"

need_root() { if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi }
usage(){ echo "Usage: $0 [--wifi|--audio|--service]"; }

remove_wifi(){
  echo "==> Entferne WLAN-Firmware laut Manifest"
  if [[ -f "$MANIFEST_FILE" ]]; then
    grep '/lib/firmware/brcm/' "$MANIFEST_FILE" | while read -r f; do
      [[ -f "$f" ]] && rm -f "$f"
    done
    sed -i '/\/lib\/firmware\/brcm\//d' "$MANIFEST_FILE"
  fi
  modprobe -r brcmfmac 2>/dev/null || true
}

remove_audio(){
  echo "==> Entferne CS8409 Modul aus aktuellem Kernel"
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  for p in \
    "/lib/modules/$(uname -r)/kernel/sound/pci/hda/snd-hda-codec-cs8409.ko" \
    "/lib/modules/$(uname -r)/kernel/sound/pci/hda/snd-hda-codec-cs8409.ko.xz"; do
    [[ -f "$p" ]] && rm -f "$p"
  done
  rm -f "/etc/modules-load.d/snd_hda_codec_cs8409.conf" || true
  depmod -a || true
  sed -i '/^MODULE:snd_hda_codec_cs8409$/d' "$MANIFEST_FILE" 2>/dev/null || true
}

remove_service(){
  echo "==> Deaktiviere & entferne Systemd-Units"
  systemctl disable --now imac-wifi-audio-check.service 2>/dev/null || true
  systemctl disable --now imac-wifi-audio-check.timer 2>/dev/null || true
  rm -f /usr/local/bin/imac-wifi-audio-check.sh
  rm -f /etc/systemd/system/imac-wifi-audio-check.service
  rm -f /etc/systemd/system/imac-wifi-audio-check.timer
  systemctl daemon-reload || true
}

main(){
  need_root
  local do_wifi=1 do_audio=1 do_service=1
  case "${1:-all}" in
    --wifi)    do_audio=0; do_service=0 ;;
    --audio)   do_wifi=0;  do_service=0 ;;
    --service) do_wifi=0;  do_audio=0 ;;
    all) ;;
    *) [[ -n "${1:-}" ]] && usage && exit 2 ;;
  esac

  [[ $do_wifi -eq 1 ]] && remove_wifi
  [[ $do_audio -eq 1 ]] && remove_audio
  [[ $do_service -eq 1 ]] && remove_service

  echo "✅ Deinstallation abgeschlossen."
}

main "$@"
