#!/usr/bin/env bash
set -euo pipefail

say(){ printf "%s\n" "$*"; }

say "=== iMac WiFi/Audio Status ==="
say "Kernel: $(uname -r)"
say

# Audio (DKMS vs Kernel)
if lsmod | grep -q '^snd_hda_codec_cs8409'; then
  say "Audio: LOADED (snd_hda_codec_cs8409)"
  if modinfo snd_hda_codec_cs8409 >/dev/null 2>&1; then
    FN="$(modinfo snd_hda_codec_cs8409 | awk -F': ' '/^filename/{print $2}')"
    VER="$(modinfo snd_hda_codec_cs8409 | awk -F': ' '/^version/{print $2}' || true)"
    say "  filename: $FN"
    [[ -n "$VER" ]] && say "  version:  $VER"
    case "$FN" in
      *"/updates/dkms/"*) say "  source:   DKMS ✔";;
      *"/kernel/sound/pci/hda/"*) say "  source:   In-Kernel (DKMS evtl. entbehrlich)";;
      *) say "  source:   unbekannt";;
    esac
  fi
else
  say "Audio: NOT LOADED"
fi
say

# DKMS Status
if command -v dkms >/dev/null 2>&1; then
  dkms status | grep '^snd-hda-codec-cs8409/' || echo "DKMS: kein cs8409-Eintrag"
fi
say

# ALSA Sichtbarkeit
( cat /proc/asound/cards 2>/dev/null || true ) | sed 's/^/ALSA: /'
say

# WLAN (Firmware & Treiber)
if lsmod | grep -q '^brcmfmac'; then
  say "Wi-Fi: LOADED (brcmfmac)"
else
  say "Wi-Fi: NOT LOADED"
fi

if dpkg -S /lib/firmware/brcm/brcmfmac4364b2-pcie.bin >/dev/null 2>&1 || \
   dpkg -S /lib/firmware/brcm/brcmfmac4364b3-pcie.bin >/dev/null 2>&1; then
  say "Firmware: Debian-Paket (z.B. firmware-brcm80211)"
else
  say "Firmware: Noa-Paket + Symlinks"
fi

ls -l /lib/firmware/brcm | grep -E '4364|iMac19,1' || true
say
nmcli -g WIFI radio 2>/dev/null || true
nmcli dev status 2>/dev/null || true
say "=== Ende ==="
