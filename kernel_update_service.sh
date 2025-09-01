#!/usr/bin/env bash
set -euo pipefail
# Installiert/aktualisiert:
#  - Root-Checker & Timer
#  - pkexec-Policy + Fix-Helper
#  - User-Notifier (Timer)
#  - persistenter FW-Mirror
#
# Beide Wege (Installer/Popup) nutzen „Schnelle Heilung A & B“.

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

# Persistenter Firmware-Speicher (Mirror des Repo-Verzeichnisses)
SHARE_FW_BASE="/usr/local/share/imac-linux-wifi-audio/broadcom"
SHARE_FW_B2="${SHARE_FW_BASE}/b2"
SHARE_FW_B3="${SHARE_FW_BASE}/b3"

need_root(){ if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi; }
need_root

mkdir -p "$STATE_DIR" "$SHARE_FW_B2" "$SHARE_FW_B3"

# --- 0) Firmware aus dem Repo einmalig spiegeln (falls vorhanden) ---
mirror_variant() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || { echo 0; return 0; }
  shopt -s nullglob
  local n=0
  for f in "$src"/brcmfmac4364*; do
    install -m 0644 "$f" "$dst/"
    ((n++))
  done
  echo "$n"
}

C1=$(mirror_variant "${REPO_ROOT}/broadcom/b2" "$SHARE_FW_B2" || echo 0)
C2=$(mirror_variant "${REPO_ROOT}/broadcom/b3" "$SHARE_FW_B3" || echo 0)
echo "FW-Mirror: b2=${C1} Dateien, b3=${C2} Dateien unter ${SHARE_FW_BASE}"

# --- 1) ROOT-Check Script ---
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
  ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi|wlp|p2p-dev-wl)'
}

wifi_ok(){
  has_wifi_iface && return 0
  lsmod | grep -q '^brcmfmac' && return 0
  dmesg | grep -qi brcmfmac && return 0
  return 1
}

audio_ok(){
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  [[ -r /proc/asound/cards ]] && egrep -qi 'cs8409|cirrus' /proc/asound/cards && return 0
  aplay -l 2>/dev/null | egrep -qi 'CS8409|Cirrus' && return 0
  dmesg | grep -qi cs8409 && return 0
  return 1
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

# Flags setzen/entfernen
[[ $ok_wifi -eq 0 ]] && touch "$FLAG_WIFI_NEEDED" || rm -f "$FLAG_WIFI_NEEDED" 2>/dev/null || true
[[ $ok_audio -eq 0 ]] && touch "$FLAG_AUDIO_NEEDED" || rm -f "$FLAG_AUDIO_NEEDED" 2>/dev/null || true

if [[ "$cur_kernel" != "$prev_kernel" ]]; then
  log "Kernelwechsel: ${prev_kernel:-<none>} -> $cur_kernel"
  echo "$cur_kernel" > "$LAST_FILE"
fi

exit 0
EOF
chmod 0755 "$CHECK_BIN"

# --- 2) Fix-Helper aktualisieren (inkl. Schnelle Heilung A & B) ---
install -m 0755 "${REPO_ROOT}/imac-wifi-audio-fix.sh" "$FIX_BIN"

# --- 3) Root service + timer ---
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

# --- 4) Polkit Policy für pkexec ---
cat >"$POLKIT_POLICY" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN" "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="com.frogro.imacwifi.fix">
    <description>iMac WiFi/Audio-Fix ausführen</description>
    <message>Authentifizieren, um WiFi/Audio-Fix als Administrator auszuführen</message>
    <icon_name>audio-card</icon_name>
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

# --- 5) User-Notifier (Timer) ---
U="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
if id "$U" >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$U" | cut -d: -f6)"
  USER_UNIT_DIR="$USER_HOME/.config/systemd/user"
  NOTIFY_BIN="$USER_HOME/.local/bin/imac-wifi-audio-notify.sh"
  mkdir -p "$USER_UNIT_DIR" "${NOTIFY_BIN%/*}"

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
  msg_wifi="Nach dem Kernel-Update auf Version ${kernel} ist WLAN nicht aktiv. Jetzt automatisch reparieren (Firmware setzen + Modul neu laden)?"
  if ask_yes_no "$msg_wifi"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi || true
  fi
fi

if [[ -f "$FLAG_AUDIO_NEEDED" ]]; then
  msg_audio="Nach dem Kernel-Update auf Version ${kernel} ist der Audiotreiber (CS8409) nicht aktiv. Jetzt automatisch reparieren?"
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

  # User-Timer sauber aktivieren – auch wenn dieses Skript per sudo läuft
  UIDNUM="$(id -u "$U")"
  export XDG_RUNTIME_DIR="/run/user/${UIDNUM}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UIDNUM}/bus"
  su - "$U" -c "systemctl --user daemon-reload"
  su - "$U" -c "systemctl --user enable --now imac-wifi-audio-notify.timer" || {
    echo "⚠️  Hinweis: Konnte User-Timer nicht sofort aktivieren. Sobald $U angemeldet ist, bitte ausführen:"
    echo "    systemctl --user daemon-reload && systemctl --user enable --now imac-wifi-audio-notify.timer"
  }
fi

echo "✅ Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet."
echo "   (Audio-Fix enthält Schnelle Heilung A & B.)"
