#!/usr/bin/env bash
# Root-Fix-Helper (mit pkexec nutzbar): lädt Module neu, initialisiert Wi-Fi.
set -euo pipefail
echo "[fix] depmod & reload modules…"
depmod -a || true
modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
modprobe snd_hda_intel 2>/dev/null || true
modprobe snd_hda_codec_cs8409 2>/dev/null || true
modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
modprobe cfg80211 || true; modprobe brcmutil || true; modprobe brcmfmac || true
rfkill unblock all 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
echo "[fix] done."
