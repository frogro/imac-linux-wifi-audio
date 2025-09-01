#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# iMac Linux WiFi + Audio – Kernel-Update-Checker
# Installiert:
#   - Root-Timer (prüft WLAN/Audio nach Kernelwechsel)
#   - Root-Fix-Helper (/usr/local/sbin/imac-wifi-audio-fix.sh)
#   - User-Notifier (~/.local/bin/imac-wifi-audio-notify.sh)
# =========================================================

STATE_DIR="/var/lib/imac-linux-wifi-audio"
LAST_FILE="${STATE_DIR}/last_kernel"
STATUS_JSON="${STATE_DIR}/status.json"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------
# Root-Check-Script
# ---------------------------------------------------------
install -m 755 /dev/stdin /usr/local/bin/imac-wifi-audio-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/imac-linux-wifi-audio"
LAST_FILE="${STATE_DIR}/last_kernel"
STATUS_JSON="${STATE_DIR}/status.json"
FLAG_AUDIO="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI="${STATE_DIR}/needs_wifi_fix"

mkdir -p "$STATE_DIR"

kernel="$(uname -r)"
wifi_ok=0
audio_ok=0

# WLAN vorhanden?
if ip link show | grep -qE 'wl|wlan'; then
  wifi_ok=1
fi

# Audio vorhanden?
if aplay -l 2>/dev/null | grep -q "Analog"; then
  audio_ok=1
fi

# Status speichern
jq -n \
  --arg kernel "$kernel" \
  --argjson wifi_ok "$wifi_ok" \
  --argjson audio_ok "$audio_ok" \
  --arg checked_at "$(date --iso-8601=seconds)" \
  '{kernel:$kernel,wifi_ok:$wifi_ok,audio_ok:$audio_ok,checked_at:$checked_at}' \
  >"$STATUS_JSON"

# Flags setzen
[[ "$wifi_ok" -eq 1 ]] && rm -f "$FLAG_WIFI" || touch "$FLAG_WIFI"
[[ "$audio_ok" -eq 1 ]] && rm -f "$FLAG_AUDIO" || touch "$FLAG_AUDIO"

# Kernelwechsel erkennen
if [[ ! -f "$LAST_FILE" ]] || [[ "$(cat "$LAST_FILE")" != "$kernel" ]]; then
  echo "$kernel" >"$LAST_FILE"
  touch "${STATE_DIR}/postreboot_check"
fi
EOF

# ---------------------------------------------------------
# Root-Fix-Helper
# ---------------------------------------------------------
install -m 755 /dev/stdin /usr/local/sbin/imac-wifi-audio-fix.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/imac-linux-wifi-audio"
FLAG_AUDIO="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI="${STATE_DIR}/needs_wifi_fix"

fix_wifi() {
  systemctl stop NetworkManager || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  sleep 1
  modprobe cfg80211
  modprobe brcmfmac
  rfkill unblock wifi || true
  systemctl start NetworkManager || true
  nmcli radio wifi on || true
  rm -f "$FLAG_WIFI"
}

fix_audio() {
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe -r snd_hda_intel 2>/dev/null || true
  modprobe snd_hda_intel
  modprobe snd_hda_codec_cs8409
  alsactl init || true
  systemctl --user restart pipewire pipewire-pulse wireplumber || true
  rm -f "$FLAG_AUDIO"
}

case "${1:-}" in
  --wifi)  fix_wifi ;;
  --audio) fix_audio ;;
  *) echo "Usage: $0 --wifi|--audio"; exit 1 ;;
esac
EOF

# ---------------------------------------------------------
# User-Notifier
# ---------------------------------------------------------
mkdir -p ~/.local/bin
install -m 755 /dev/stdin ~/.local/bin/imac-wifi-audio-notify.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/imac-linux-wifi-audio"
STATUS_JSON="${STATE_DIR}/status.json"
FLAG_AUDIO="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI="${STATE_DIR}/needs_wifi_fix"

kernel="$(uname -r)"
wifi_ok=$(jq -r '.wifi_ok' "$STATUS_JSON" 2>/dev/null || echo 0)
audio_ok=$(jq -r '.audio_ok' "$STATUS_JSON" 2>/dev/null || echo 0)

show_popup() {
  local title="iMac – Hinweis"
  local text="$1"
  if command -v zenity >/dev/null 2>&1; then
    zenity --info --title="$title" --text="$text"
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --msgbox "$text"
  else
    notify-send "$title" "$text" || echo "$text"
  fi
}

# 1) Post-Reboot-Info
if [[ -f "${STATE_DIR}/postreboot_check" ]]; then
  rm -f "${STATE_DIR}/postreboot_check"
  WIFI="Fehlt"; [[ "$wifi_ok" -eq 1 ]] && WIFI="OK"
  AUDIO="Fehlt"; [[ "$audio_ok" -eq 1 ]] && AUDIO="OK"
  msg="Nach dem Neustart (${kernel}): WLAN=${WIFI}, Audio=${AUDIO}"
  show_popup "$msg"
fi

# 2) WLAN-Fix
if [[ -f "$FLAG_WIFI" ]]; then
  if zenity --question --title="iMac – Hinweis" \
      --text="WLAN ist nicht aktiv. Jetzt fixen?"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi
  fi
fi

# 3) Audio-Fix
if [[ -f "$FLAG_AUDIO" ]]; then
  if zenity --question --title="iMac – Hinweis" \
      --text="Audio ist nicht aktiv. Jetzt fixen?"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --audio
  fi
fi
EOF

# ---------------------------------------------------------
# Systemd Units
# ---------------------------------------------------------
install -m 644 /dev/stdin /etc/systemd/system/imac-wifi-audio-check.service <<'EOF'
[Unit]
Description=iMac WiFi/Audio Check (Kernel-Update)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/imac-wifi-audio-check.sh
EOF

install -m 644 /dev/stdin /etc/systemd/system/imac-wifi-audio-check.timer <<'EOF'
[Unit]
Description=Run iMac WiFi/Audio Check daily and at boot

[Timer]
OnBootSec=30s
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF

mkdir -p ~/.config/systemd/user

install -m 644 /dev/stdin ~/.config/systemd/user/imac-wifi-audio-notify.service <<'EOF'
[Unit]
Description=iMac WiFi/Audio Notifier

[Service]
Type=oneshot
ExecStart=%h/.local/bin/imac-wifi-audio-notify.sh
EOF

install -m 644 /dev/stdin ~/.config/systemd/user/imac-wifi-audio-notify.timer <<'EOF'
[Unit]
Description=Run iMac WiFi/Audio Notifier hourly

[Timer]
OnBootSec=45s
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ---------------------------------------------------------
# Enable Units
# ---------------------------------------------------------
systemctl daemon-reload
systemctl enable --now imac-wifi-audio-check.timer
systemctl --user daemon-reload
systemctl --user enable --now imac-wifi-audio-notify.timer
