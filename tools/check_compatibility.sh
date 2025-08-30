!/usr/bin/env bash
set -euo pipefail

bold(){ printf "[1m%s[0m
" "$*"; }
ok(){ printf "[ OK ] %s
" "$*"; }
warn(){ printf "[WARN] %s
" "$*"; }
err(){ printf "[FAIL] %s
" "$*"; }

have(){ command -v "$1" >/dev/null 2>&1; }

bold "iMac/MacBook Linux – Kompatibilitätscheck"

# WLAN: suche Broadcom BCM4364 (b2/b3 preferred, aber generisches Match genügt)
WIFI_MATCH=0
if have lspci; then
  if lspci -nn | grep -iE 'broadcom|brcm' | grep -qi '4364'; then
    WIFI_MATCH=1; ok "Broadcom BCM4364 erkannt (gut)."
  elif lspci -nn | grep -iE 'broadcom|brcm' >/dev/null; then
    warn "Broadcom WLAN erkannt, aber nicht eindeutig BCM4364."
  else
    warn "Kein Broadcom WLAN in lspci ersichtlich."
  fi
else
  warn "lspci nicht verfügbar – WLAN‑Erkennung eingeschränkt."
fi

# Zusätzlicher Firmware‑Hinweis
if [ -d /lib/firmware/brcm ]; then
  if ls /lib/firmware/brcm 2>/dev/null | grep -qiE 'brcmfmac4364(b2|b3)'; then
    ok "Firmware für 4364(b2/b3) ist bereits im System vorhanden."
  fi
fi

# Audio: suche CS8409
AUDIO_MATCH=0
if [ -r /proc/asound/cards ]; then
  if grep -qiE 'cs8409|cirrus' /proc/asound/cards; then
    AUDIO_MATCH=1; ok "Cirrus/CS8409 in ALSA‑Karten sichtbar (gut)."
  fi
fi

if have dmesg; then
  dmesg | grep -i cs8409 >/dev/null 2>&1 && { AUDIO_MATCH=1; ok "CS8409 im Kernel‑Log erwähnt."; } || true
fi

if have lsmod; then
  lsmod | grep -q '^snd_hda_codec_cs8409' && { AUDIO_MATCH=1; ok "Modul snd_hda_codec_cs8409 bereits geladen."; }
fi

# Zusammenfassung
if [ $WIFI_MATCH -eq 1 ] && [ $AUDIO_MATCH -eq 1 ]; then
  bold "Ergebnis: kompatibel (BCM4364 + CS8409)"
  exit 0
fi

if [ $WIFI_MATCH -eq 1 ] || [ $AUDIO_MATCH -eq 1 ]; then
  bold "Ergebnis: teilweise/unklar"
  warn "Mindestens eine Komponente passt, die andere ist unklar. Lies README und entscheide, ob du nur WLAN oder nur Audio installieren willst."
  exit 1
fi

bold "Ergebnis: nicht kompatibel (für dieses Repo)"
err "Weder BCM4364 noch CS8409 erkannt. Prüfe deine Hardware oder nutze eine alternative Anleitung."
exit 2
