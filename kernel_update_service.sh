#!/usr/bin/env bash
set -euo pipefail

# Installiert/aktualisiert:
#  - Root-Check + Timer:   /usr/local/bin/imac-wifi-audio-check.sh
#  - Root-Fix-Helper:      /usr/local/sbin/imac-wifi-audio-fix.sh  (ruft cirruslogic/* auf und kopiert WiFi-Firmware aus dem Repo)
#  - Polkit-Regel:         /usr/share/polkit-1/actions/com.frogro.imacwifi.policy
#  - User-Notifier (+timer): $HOME/.config/systemd/user/imac-wifi-audio-notify.*

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="/var/lib/imac-linux-wifi-audio"
LAST_FILE="${STATE_DIR}/last_kernel"
STATUS_JSON="${STATE_DIR}/status.json"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"

SERVICE="/etc/systemd/system/imac-wifi-audio-check.service"
TIMER="/etc/systemd/system/imac-wifi-audio-check.timer"
CHECK_BIN="/usr/local/bin/imac-wifi-audio-check.sh"
FIX_BIN="/usr/local/sbin/imac-wifi-audio-fix.sh"
POLKIT_POLICY="/usr/share/polkit-1/actions/com.frogro.imacwifi.policy"

need_root(){ if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi }
need_root

mkdir -p "$STATE_DIR"

cat >"$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="/var/lib/imac-linux-wifi-audio"
LAST_FILE="${STATE_DIR}/last_kernel"
STATUS_JSON="${STATE_DIR}/status.json"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"

log(){ printf "[imac-wifi-audio-check] %s\n" "$*"; }

has_wifi_iface(){
  command -v ip >/dev/null 2>&1 || return 1
  ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi)'
}

wifi_ok(){
  has_wifi_iface || lsmod | grep -q '^brcmfmac'
}

audio_ok(){
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  [[ -r /proc/asound/cards ]] && egrep -qi 'cs8409|cirrus' /proc/asound/cards
}

cur_kernel="$(uname -r)"
prev_kernel=""; [[ -f "$LAST_FILE" ]] && prev_kernel="$(cat "$LAST_FILE")"

ok_wifi=0; ok_audio=0
wifi_ok && ok_wifi=1
audio_ok && ok_audio=1

mkdir -p "$STATE_DIR"
echo "{
  \"kernel\": \"$cur_kernel\",
  \"wifi_ok\": $ok_wifi,
  \"audio_ok\": $ok_audio,
  \"checked_at\": \"$(date -Iseconds)\"
}" > "$STATUS_JSON"

# Flags setzen
[[ $ok_wifi -eq 0 ]] && touch "$FLAG_WIFI_NEEDED" || rm -f "$FLAG_WIFI_NEEDED" 2>/dev/null || true
[[ $ok_audio -eq 0 ]] && touch "$FLAG_AUDIO_NEEDED" || rm -f "$FLAG_AUDIO_NEEDED" 2>/dev/null || true

if [[ "$cur_kernel" != "$prev_kernel" ]]; then
  log "Kernelwechsel: ${prev_kernel:-<none>} -> $cur_kernel"
  echo "$cur_kernel" > "$LAST_FILE"
fi

exit 0
EOF

install -m 0755 "$CHECK_BIN" "$CHECK_BIN"

cat >"$FIX_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
STATE_DIR="$STATE_DIR"
FLAG_AUDIO_NEEDED="$FLAG_AUDIO_NEEDED"
FLAG_WIFI_NEEDED="$FLAG_WIFI_NEEDED"

usage(){ echo "Usage: \$0 [--wifi] [--audio]"; }

fix_wifi(){
  echo "==> (WiFi) Kopiere Firmware aus Repo und lade Modul neu"
  install -d /lib/firmware/brcm
  shopt -s nullglob
  cnt=0
  for sub in b2 b3; do
    for f in "\${REPO_ROOT}/broadcom/\${sub}"/*; do
      install -m 0644 "\$f" /lib/firmware/brcm/
      ((cnt++))
    done
  done
  echo "   → \${cnt} Dateien aktualisiert."
  modprobe -r brcmfmac 2>/dev/null || true
  modprobe brcmfmac || true
  command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u || true
  if lsmod | grep -q '^brcmfmac'; then
    echo "✅ WLAN Modul aktiv."
    rm -f "\${FLAG_WIFI_NEEDED}" 2>/dev/null || true
  else
    echo "⚠️  WLAN weiterhin nicht aktiv. Bitte Kernel/Logs prüfen."
  fi
}

fix_audio(){
  echo "==> (Audio) Versuche Modulbereitstellung aus Kernelpaket"
  if [[ -x "\${REPO_ROOT}/cirruslogic/extract_from_kernelpkg.sh" ]]; then
    sudo "\${REPO_ROOT}/cirruslogic/extract_from_kernelpkg.sh" || true
  fi
  if [[ -x "\${REPO_ROOT}/cirruslogic/install_cs8409_manual.sh" ]]; then
    sudo "\${REPO_ROOT}/cirruslogic/install_cs8409_manual.sh" --autoload || true
  fi
  sudo depmod -a || true
  if lsmod | grep -q '^snd_hda_codec_cs8409'; then
    echo "✅ Audio aktiv."
    rm -f "\${FLAG_AUDIO_NEEDED}" 2>/dev/null || true
  else
    echo "⚠️  Audio weiterhin nicht aktiv."
  fi
}

DO_WIFI=0; DO_AUDIO=0
for a in "\$@"; do
  case "\$a" in
    --wifi) DO_WIFI=1 ;;
    --audio) DO_AUDIO=1 ;;
    *) usage; exit 2 ;;
  esac
done

(( DO_WIFI )) && fix_wifi
(( DO_AUDIO )) && fix_audio
EOF

install -m 0755 "$FIX_BIN" "$FIX_BIN"

# Root service + timer
cat >"$SERVICE" <<'EOF'
[Unit]
Description=iMac WiFi/Audio Status-Check (root, no-install)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/imac-wifi-audio-check.sh

[Install]
WantedBy=multi-user.target
EOF

cat >"$TIMER" <<'EOF'
[Unit]
Description=Täglicher iMac WiFi/Audio Status-Check

[Timer]
OnBootSec=2min
OnUnitActiveSec=24h
Unit=imac-wifi-audio-check.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now imac-wifi-audio-check.service
systemctl enable --now imac-wifi-audio-check.timer

# Polkit Policy für pkexec
cat >"$POLKIT_POLICY" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN" "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="com.frogro.imacwifi.fix">
    <description>iMac WiFi/Audio-Fix ausführen</description>
    <message>Authentifizieren, um WiFi/Audio-Fix als Administrator auszuführen</message>
    <icon_name>network-wireless</icon_name>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/sbin/imac-wifi-audio-fix.sh</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
EOF

# User-Notifier (fragt separat nach WLAN/Audio) – jetzt mit Live-Kernel via uname -r
USER_UNIT_DIR="${SUDO_USER:+/home/${SUDO_USER}/.config/systemd/user}"
if [[ -n "${USER_UNIT_DIR}" && -d "${USER_UNIT_DIR%/*}" ]]; then
  mkdir -p "$USER_UNIT_DIR"
  NOTIFY_BIN="${USER_UNIT_DIR%/.config/systemd/user}/.local/bin/imac-wifi-audio-notify.sh"
  mkdir -p "${NOTIFY_BIN%/imac-wifi-audio-notify.sh}"
  cat >"$NOTIFY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="/var/lib/imac-linux-wifi-audio"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"

ask_yes_no(){
  local msg="$1"
  if command -v zenity >/dev/null 2>&1; then
    zenity --question --title="iMac – Hinweis" --text="$msg" && return 0 || return 1
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --yesno "$msg" && return 0 || return 1
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "iMac – Hinweis" "$msg
(Öffne Terminal zur Bestätigung)"
    read -p "${msg} [y/N]: " yn; [[ "${yn,,}" == "y" ]]
  else
    read -p "${msg} [y/N]: " yn; [[ "${yn,,}" == "y" ]]
  fi
}

kernel="$(uname -r)"

if [[ -f "$FLAG_WIFI_NEEDED" ]]; then
  msg_wifi="Nach dem Kernel-Update auf Version ${kernel} ist WLAN nicht aktiv. Soll ich die im Repo enthaltene Broadcom-Firmware neu einrichten und das Modul neu laden?"
  if ask_yes_no "$msg_wifi"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi || true
  fi
fi

if [[ -f "$FLAG_AUDIO_NEEDED" ]]; then
  msg_audio="Nach dem Kernel-Update auf Version ${kernel} konnte kein Audiotreiber (CS8409) geladen werden. Soll ich den zum Kernel passenden Treiber installieren?"
  if ask_yes_no "$msg_audio"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --audio || true
  fi
fi
EOF
  chmod +x "$NOTIFY_BIN"

  USER_SERVICE_FILE="$USER_UNIT_DIR/imac-wifi-audio-notify.service"
  USER_TIMER_FILE="$USER_UNIT_DIR/imac-wifi-audio-notify.timer"
  cat >"$USER_SERVICE_FILE" <<EOF
[Unit]
Description=iMac WiFi/Audio Notifier (user)
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=${NOTIFY_BIN}
EOF

  cat >"$USER_TIMER_FILE" <<'EOF'
[Unit]
Description=iMac WiFi/Audio Notifier Timer (user)

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
Unit=imac-wifi-audio-notify.service

[Install]
WantedBy=default.target
EOF

  su - "${SUDO_USER}" -c "systemctl --user daemon-reload && systemctl --user enable --now imac-wifi-audio-notify.timer" || true
fi

echo "✅ Root-Check, pkexec-Helper und User-Notifier aktualisiert (Notifier zeigt Live-Kernel via uname -r)."
