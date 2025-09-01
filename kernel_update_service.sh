#!/usr/bin/env bash
set -euo pipefail

# Installiert/aktualisiert:
#  - Root-Check + Timer:     /usr/local/bin/imac-wifi-audio-check.sh
#  - Root-Fix-Helper:        /usr/local/sbin/imac-wifi-audio-fix.sh
#  - Polkit-Regel:           /usr/share/polkit-1/actions/com.frogro.imacwifi.policy
#  - User-Notifier (+timer): $HOME/.config/systemd/user/imac-wifi-audio-notify.*
#  - FW-Mirror (persistent): /usr/local/share/imac-linux-wifi-audio/broadcom/{b2,b3}

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

need_root(){ if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi }
need_root

mkdir -p "$STATE_DIR" "$SHARE_FW_B2" "$SHARE_FW_B3"

# --- kleine Helfer fürs User-Systemd (robust mit/ohne DBus-Env) ---
get_real_user(){
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
  else
    # Fallback: letzter eingeloggter non-root User auf der Sitzungs-tty
    logname 2>/dev/null || id -un
  fi
}
user_has_bus(){
  local u="$1" uid; uid="$(id -u "$u")"
  [[ -S "/run/user/${uid}/bus" ]]
}
run_user(){
  local u="$1"; shift
  local uid; uid="$(id -u "$u")"
  if user_has_bus "$u"; then
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" "$@"
  else
    # Linger einschalten, damit --user units ohne aktive Session funktionieren
    loginctl enable-linger "$u" >/dev/null 2>&1 || true
    sudo -u "$u" "$@"
  fi
}

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

C1=$(mirror_variant "${REPO_ROOT}/broadcom/b2" "$SHARE_FW_B2")
C2=$(mirror_variant "${REPO_ROOT}/broadcom/b3" "$SHARE_FW_B3")
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
  ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi|wlp)'
}

wifi_ok(){
  has_wifi_iface || lsmod | grep -q '^brcmfmac'
}

# Audio als „ok“, wenn CS8409-Modul geladen (robusteste Heuristik)
audio_ok(){
  lsmod | grep -q '^snd_hda_codec_cs8409'
}

cur_kernel="$(uname -r)"
prev_kernel=""; [[ -f "$LAST_FILE" ]] && prev_kernel="$(cat "$LAST_FILE")"

ok_wifi=0; ok_audio=0
wifi_ok && ok_wifi=1
audio_ok && ok_audio=1

mkdir -p "$STATE_DIR"
printf '{
  "kernel": "%s",
  "wifi_ok": %s,
  "audio_ok": %s,
  "checked_at": "%s"
}
' "$cur_kernel" "$ok_wifi" "$ok_audio" "$(date -Iseconds)" > "$STATUS_JSON"

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

# --- 2) FIX-Helper (WiFi + Audio mit „Schneller Heilung A/B“) ---
cat >"$FIX_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/imac-linux-wifi-audio"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"

REPO_ROOT="/usr/local/share/imac-linux-wifi-audio/__norepo__" # nicht benötigt, FW kommt aus /lib oder SHARE
SHARE_FW_BASE="/usr/local/share/imac-linux-wifi-audio/broadcom"
SHARE_FW_B2="${SHARE_FW_BASE}/b2"
SHARE_FW_B3="${SHARE_FW_BASE}/b3"

usage(){ echo "Usage: $0 [--wifi] [--audio]"; }

copy_fw_variant(){
  local src="$1"
  [[ -d "$src" ]] || { echo 0; return 0; }
  shopt -s nullglob
  local k=0
  for f in "$src"/brcmfmac4364*; do
    install -m 0644 "$f" /lib/firmware/brcm/
    ((k++))
  done
  echo "$k"
}

set_symlinks_if_present(){
  local base="$1" apple="$2" dir="/lib/firmware/brcm"
  pushd "$dir" >/dev/null || return 0
  [[ -f "${base}.${apple}.bin"      ]] && ln -sf "${base}.${apple}.bin"      "${base}.bin"
  [[ -f "${base}.${apple}.txt"      ]] && ln -sf "${base}.${apple}.txt"      "${base}.txt"
  [[ -f "${base}.${apple}.clm_blob" ]] && ln -sf "${base}.${apple}.clm_blob" "${base}.clm_blob"
  [[ -f "${base}.${apple}.txcap_blob" ]] && ln -sf "${base}.${apple}.txcap_blob" "${base}.txcap_blob"
  popd >/dev/null || true
}

fix_wifi(){
  echo "==> (WiFi) Firmware aktualisieren & Stack neu laden"
  install -d /lib/firmware/brcm
  local c1 c2
  c1=$(copy_fw_variant "$SHARE_FW_B2" || echo 0)
  c2=$(copy_fw_variant "$SHARE_FW_B3" || echo 0)
  echo "   → Dateien kopiert: b2=${c1}, b3=${c2}"

  set_symlinks_if_present "brcmfmac4364b2-pcie" "apple,midway"
  set_symlinks_if_present "brcmfmac4364b3-pcie" "apple,borneo"

  # stabile P2P-Option
  echo "options brcmfmac p2pon=0" >/etc/modprobe.d/brcmfmac.conf

  # Stack neu
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true

  if lsmod | grep -q '^brcmfmac'; then
    echo "✅ WLAN Modul aktiv."
    rm -f "$FLAG_WIFI_NEEDED" 2>/dev/null || true
  else
    echo "⚠️  WLAN weiterhin nicht aktiv. Prüfe dmesg."
  fi
}

# -------------------- Schnelle Heilung A: Kernel/ALSA --------------------
audio_quick_heal_kernel(){
  echo "==> (Audio/A) Kernel/ALSA-Heilung"
  # evtl. Blacklist entfernen + initramfs aktualisieren
  if [[ -f /etc/modprobe.d/blacklist-cs8409.conf ]]; then
    rm -f /etc/modprobe.d/blacklist-cs8409.conf
    update-initramfs -u || true
  fi

  # Autoload sicherstellen
  echo "snd_hda_codec_cs8409" >/etc/modules-load.d/snd_hda_codec_cs8409.conf

  # HDA-Stack sauber neu laden
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe -r snd_hda_intel 2>/dev/null || true
  modprobe snd_hda_intel
  modprobe snd_hda_codec_cs8409

  # ALSA neu initialisieren
  command -v alsactl >/dev/null 2>&1 && alsactl init || true
}

# -------------------- Schnelle Heilung B: Mixer & PipeWire ----------------
audio_quick_heal_userspace(){
  echo "==> (Audio/B) Mixer & PipeWire/WirePlumber-Heilung"
  # Mixer (Karte 0) defensiv setzen
  amixer -c 0 sset 'Auto-Mute Mode' Disabled 2>/dev/null || true
  amixer -c 0 sset Speaker 100% unmute 2>/dev/null || true
  amixer -c 0 sset Headphone mute 2>/dev/null || true
  amixer -c 0 sset PCM 100% unmute 2>/dev/null || true

  # User-Sounddienste frisch (falls vorhanden)
  # Versuche, den aktiven GUI-User zu finden (id der Prozessgruppe mit grafischer Session)
  ACTIVE_U="$(loginctl list-users 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $2}' | head -n1)"
  if [[ -n "${ACTIVE_U:-}" ]]; then
    UID="$(id -u "$ACTIVE_U")"
    XDG_RUNTIME_DIR="/run/user/${UID}"
    DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
    if [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
      sudo -u "$ACTIVE_U" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        systemctl --user restart wireplumber pipewire pipewire-pulse || true
      # Default-Sink auf Analog
      SINK="$(sudo -u "$ACTIVE_U" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
                pactl list short sinks 2>/dev/null | awk '/analog-stereo/ {print $2; exit}')"
      if [[ -n "${SINK:-}" ]]; then
        sudo -u "$ACTIVE_U" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
          pactl set-default-sink "$SINK" || true
        sudo -u "$ACTIVE_U" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
          pactl set-sink-mute "$SINK" 0 || true
        sudo -u "$ACTIVE_U" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
          pactl set-sink-volume "$SINK" 100% || true
      fi
    fi
  fi
}

fix_audio(){
  echo "==> (Audio) CS8409 prüfen & reparieren"
  audio_quick_heal_kernel
  # Status prüfen
  if lsmod | grep -q '^snd_hda_codec_cs8409'; then
    echo "   → CS8409 geladen."
  else
    echo "⚠️  CS8409 nicht geladen. Prüfe Blacklist/Kernel."
  fi
  audio_quick_heal_userspace

  # Flag wegräumen, wenn Modul jetzt da ist
  if lsmod | grep -q '^snd_hda_codec_cs8409'; then
    echo "✅ Audio aktiv (Modul geladen)."
    rm -f "$FLAG_AUDIO_NEEDED" 2>/dev/null || true
  else
    echo "⚠️  Audio weiterhin nicht aktiv."
  fi
}

DO_WIFI=0; DO_AUDIO=0
for a in "$@"; do
  case "$a" in
    --wifi) DO_WIFI=1 ;;
    --audio) DO_AUDIO=1 ;;
    *) usage; exit 2 ;;
  esac
done

(( DO_WIFI )) && fix_wifi
(( DO_AUDIO )) && fix_audio
EOF
chmod 0755 "$FIX_BIN"

# --- 3) Root service + timer ---
cat >"$SERVICE" <<'EOF'
[Unit]
Description=iMac WiFi/Audio Status-Check (root)
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

# --- 5) User-Notifier (zeigt Popup & ruft pkexec Fix) ---
U="$(get_real_user)"
UIDNUM="$(id -u "$U")"
USER_UNIT_DIR="/home/${U}/.config/systemd/user"
NOTIFY_BIN="/home/${U}/.local/bin/imac-wifi-audio-notify.sh"

mkdir -p "$USER_UNIT_DIR" "${NOTIFY_BIN%/imac-wifi-audio-notify.sh}"

cat >"$NOTIFY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="/var/lib/imac-linux-wifi-audio"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"

ask_yes_no(){
  local msg="$1" t="iMac – Hinweis"
  if command -v zenity >/dev/null 2>&1; then
    zenity --question --title="$t" --text="$msg" && return 0 || return 1
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --yesno "$msg" && return 0 || return 1
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$t" "$msg
(Öffne Terminal zur Bestätigung)"
    read -p "${msg} [y/N]: " yn; [[ "${yn,,}" == "y" ]]
  else
    read -p "${msg} [y/N]: " yn; [[ "${yn,,}" == "y" ]]
  fi
}

kernel="$(uname -r)"
did_any=0

if [[ -f "$FLAG_WIFI_NEEDED" ]]; then
  msg_wifi="Nach dem Kernel-Update auf ${kernel} ist WLAN nicht aktiv. Soll ich die Broadcom-Firmware neu einrichten und das Modul neu laden?"
  if ask_yes_no "$msg_wifi"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi || true
    did_any=1
  fi
fi

if [[ -f "$FLAG_AUDIO_NEEDED" ]]; then
  msg_audio="Nach dem Kernel-Update auf ${kernel} konnte der Audiotreiber (CS8409) nicht geladen werden. Jetzt reparieren?"
  if ask_yes_no "$msg_audio"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --audio || true
    did_any=1
  fi
fi

# Nach Fix ggf. Erfolg melden
if [[ $did_any -eq 1 ]]; then
  sudo /usr/local/bin/imac-wifi-audio-check.sh || true
  if command -v zenity >/dev/null 2>&1; then
    zenity --info --title="iMac – Hinweis" --text="Check/Fix ausgeführt. Öffne Netzwerk-/Audioeinstellungen, falls weiterhin kein Ton/WLAN."
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --msgbox "Check/Fix ausgeführt. Öffne Netzwerk-/Audioeinstellungen, falls weiterhin kein Ton/WLAN."
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

# User-Units laden/aktivieren (robust)
run_user "$U" systemctl --user daemon-reload
run_user "$U" systemctl --user enable --now imac-wifi-audio-notify.timer || true

echo "✅ Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet."
echo "   (Audio-Fix enthält Schnelle Heilung A & B.)"
