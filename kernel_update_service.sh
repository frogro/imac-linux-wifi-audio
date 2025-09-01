#!/usr/bin/env bash
set -euo pipefail

# --- Konstanten & Pfade ---
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

SHARE_FW_BASE="/usr/local/share/imac-linux-wifi-audio/broadcom"
SHARE_FW_B2="${SHARE_FW_BASE}/b2"
SHARE_FW_B3="${SHARE_FW_BASE}/b3"

need_root(){ if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi; }
need_root

mkdir -p "$STATE_DIR" "$SHARE_FW_B2" "$SHARE_FW_B3"

# --- Firmware aus Repo ins persistente Share spiegeln (falls vorhanden) ---
mirror_variant(){
  local src="$1" dst="$2"
  [[ -d "$src" ]] || { echo 0; return 0; }
  shopt -s nullglob
  local n=0
  for f in "$src"/brcmfmac4364*; do
    install -m0644 "$f" "$dst/"
    ((n++))
  done
  shopt -u nullglob
  echo "$n"
}

C1=$(mirror_variant "${REPO_ROOT}/broadcom/b2" "$SHARE_FW_B2" || echo 0)
C2=$(mirror_variant "${REPO_ROOT}/broadcom/b3" "$SHARE_FW_B3" || echo 0)
echo "FW-Mirror: b2=${C1} Dateien, b3=${C2} Dateien unter ${SHARE_FW_BASE}"

# --- Root-Check Script: robust, kein Exit bei „nicht gefunden“ ---
cat >"$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="/var/lib/imac-linux-wifi-audio"
LAST_FILE="${STATE_DIR}/last_kernel"
STATUS_JSON="${STATE_DIR}/status.json"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"

has_wifi_iface() {
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -Eq '^(wlan|wl|wlp|p2p-dev-wl)'
}

wifi_ok() {
  if has_wifi_iface || lsmod | grep -q '^brcmfmac' || dmesg 2>/dev/null | grep -qi brcmfmac; then
    return 0
  fi
  return 1
}

audio_ok() {
  if lsmod | grep -q '^snd_hda_codec_cs8409' \
     || { [[ -r /proc/asound/cards ]] && grep -Eqi 'cs8409|cirrus' /proc/asound/cards; } \
     || aplay -l 2>/dev/null | grep -Eqi 'CS8409|Cirrus' \
     || dmesg 2>/dev/null | grep -qi cs8409
  then
    return 0
  fi
  return 1
}

cur_kernel="$(uname -r)"
prev_kernel=""
[[ -f "$LAST_FILE" ]] && prev_kernel="$(cat "$LAST_FILE" || true)"

ok_wifi=0
ok_audio=0
wifi_ok && ok_wifi=1 || true
audio_ok && ok_audio=1 || true

mkdir -p "$STATE_DIR"
printf '{\n  "kernel": "%s",\n  "wifi_ok": %d,\n  "audio_ok": %d,\n  "checked_at": "%s"\n}\n' \
  "$cur_kernel" "$ok_wifi" "$ok_audio" "$(date -Iseconds)" >"$STATUS_JSON"

if [[ $ok_wifi -eq 0 ]]; then :> "$FLAG_WIFI_NEEDED"; else rm -f "$FLAG_WIFI_NEEDED" 2>/dev/null || true; fi
if [[ $ok_audio -eq 0 ]]; then :> "$FLAG_AUDIO_NEEDED"; else rm -f "$FLAG_AUDIO_NEEDED" 2>/dev/null || true; fi

if [[ "$cur_kernel" != "$prev_kernel" ]]; then
  echo "$cur_kernel" > "$LAST_FILE"
fi
EOF
chmod 0755 "$CHECK_BIN"

# --- Fix-Helper (Schnelle Heilung A & B integriert) ---
cat >"$FIX_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="/var/lib/imac-linux-wifi-audio"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"
REPO_ROOT_FALLBACK="/usr/local/share/imac-linux-wifi-audio"
SHARE_FW_BASE="${REPO_ROOT_FALLBACK}/broadcom"
SHARE_FW_B2="${SHARE_FW_BASE}/b2"
SHARE_FW_B3="${SHARE_FW_BASE}/b3"

usage(){ echo "Usage: $0 [--wifi] [--audio]"; }

copy_fw_variant(){
  local src="$1"
  [[ -d "$src" ]] || { echo 0; return 0; }
  shopt -s nullglob
  local k=0
  for f in "$src"/brcmfmac4364*; do
    install -m0644 "$f" /lib/firmware/brcm/
    ((k++))
  done
  shopt -u nullglob
  echo "$k"
}

set_syml(){
  local base="$1" apple="$2"
  pushd /lib/firmware/brcm >/dev/null || return 0
  [[ -f "${base}.${apple}.bin"      ]] && ln -sf "${base}.${apple}.bin"      "${base}.bin"
  [[ -f "${base}.${apple}.txt"      ]] && ln -sf "${base}.${apple}.txt"      "${base}.txt" || echo "⚠️  NVRAM (.txt) fehlt evtl."
  [[ -f "${base}.${apple}.clm_blob" ]] && ln -sf "${base}.${apple}.clm_blob" "${base}.clm_blob"
  [[ -f "${base}.${apple}.txcap_blob" ]] && ln -sf "${base}.${apple}.txcap_blob" "${base}.txcap_blob"
  popd >/dev/null || true
}

fast_heal_mixer(){
  amixer -c 0 sset 'Auto-Mute Mode' Disabled 2>/dev/null || true
  amixer -c 0 sset Speaker 100% unmute 2>/dev/null || true
  amixer -c 0 sset Headphone mute 2>/dev/null || true
  amixer -c 0 sset PCM 100% unmute 2>/dev/null || true
}

fix_wifi(){
  echo "==> (WiFi) Firmware aktualisieren & Stack neu laden"
  install -d /lib/firmware/brcm
  c1=$(copy_fw_variant "$SHARE_FW_B2" || echo 0)
  c2=$(copy_fw_variant "$SHARE_FW_B3" || echo 0)
  echo "   → Dateien kopiert: b2=$c1, b3=$c2"
  set_syml "brcmfmac4364b2-pcie" "apple,midway"
  set_syml "brcmfmac4364b3-pcie" "apple,borneo"

  modprobe -r wl 2>/dev/null || true
  echo "options brcmfmac p2pon=0" >/etc/modprobe.d/brcmfmac.conf || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmutil
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true

  if lsmod | grep -q '^brcmfmac'; then
    echo "✅ WLAN Modul aktiv."
    rm -f "$FLAG_WIFI_NEEDED" 2>/dev/null || true
  else
    echo "⚠️  WLAN weiterhin nicht aktiv."
  fi
}

fix_audio(){
  echo "==> (Audio) CS8409 bereitstellen"
  # Schnelle Heilung A (Kernel/ALSA)
  rm -f /etc/modprobe.d/blacklist-cs8409.conf 2>/dev/null || true
  update-initramfs -u || true
  echo snd_hda_codec_cs8409 >/etc/modules-load.d/snd_hda_codec_cs8409.conf
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe -r snd_hda_intel 2>/dev/null || true
  modprobe snd_hda_intel
  modprobe snd_hda_codec_cs8409

  # ALSA neu initialisieren (wenn verfügbar)
  command -v alsactl >/dev/null 2>&1 && alsactl init >/dev/null 2>&1 || true

  # Schnelle Heilung B (Mixer & PipeWire)
  systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
  fast_heal_mixer

  if lsmod | grep -q '^snd_hda_codec_cs8409' || dmesg 2>/dev/null | grep -qi 'cs8409'; then
    echo "✅ Audio aktiv bzw. initialisiert."
    rm -f "$FLAG_AUDIO_NEEDED" 2>/dev/null || true
  else
    echo "⚠️  Audio weiterhin nicht aktiv."
  fi
}

DO_WIFI=0
DO_AUDIO=0
for a in "$@"; do
  case "$a" in
    --wifi) DO_WIFI=1 ;;
    --audio) DO_AUDIO=1 ;;
    *) echo "Usage: $0 [--wifi] [--audio]"; exit 2 ;;
  esac
done

(( DO_WIFI )) && fix_wifi
(( DO_AUDIO )) && fix_audio
EOF
chmod 0755 "$FIX_BIN"

# --- Root service + timer ---
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

# --- Polkit Policy für pkexec (Fix-Helper) ---
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

# --- User-Notifier (im Benutzerkontext) ---
U="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
if id "$U" >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$U" | cut -d: -f6)"
  USER_UNIT_DIR="$USER_HOME/.config/systemd/user"
  NOTIFY_BIN="$USER_HOME/.local/bin/imac-wifi-audio-notify.sh"
  mkdir -p "$USER_UNIT_DIR" "${NOTIFY_BIN%/*}"

  cat >"$NOTIFY_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
S="/var/lib/imac-linux-wifi-audio"
ask(){
  local m="$1"
  if command -v zenity >/dev/null; then
    zenity --question --title="iMac – Hinweis" --text="$m"
  else
    read -rp "$m [y/N]: " yn
    [[ "${yn,,}" == "y" ]]
  fi
}
k="$(uname -r)"
[[ -f "$S/needs_wifi_fix"  ]] && ask "Nach dem Kernel-Update auf ${k} ist WLAN nicht aktiv. Jetzt automatisch reparieren?"  && pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi  || true
[[ -f "$S/needs_audio_fix" ]] && ask "Nach dem Kernel-Update auf ${k} ist Audio (CS8409) nicht aktiv. Jetzt automatisch reparieren?" && pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --audio || true
EOF
  chmod +x "$NOTIFY_BIN"

  cat >"$USER_UNIT_DIR/imac-wifi-audio-notify.service" <<EOF
[Unit]
Description=iMac WiFi/Audio Notifier (user)
After=graphical-session.target
[Service]
Type=oneshot
ExecStart=${NOTIFY_BIN}
EOF

  cat >"$USER_UNIT_DIR/imac-wifi-audio-notify.timer" <<'EOF'
[Unit]
Description=iMac WiFi/Audio Notifier Timer (user)
[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
Unit=imac-wifi-audio-notify.service
[Install]
WantedBy=default.target
EOF

  # Versuche, direkt im aktiven User-Bus zu laden; fällt andernfalls freundlich zurück.
  if su - "$U" -c "systemctl --user daemon-reload" 2>/dev/null; then
    su - "$U" -c "systemctl --user enable --now imac-wifi-audio-notify.timer" 2>/dev/null || {
      echo "⚠️  User-Timer konnte nicht sofort aktiviert werden. Bei Desktop-Login bitte ausführen:"
      echo "   systemctl --user daemon-reload && systemctl --user enable --now imac-wifi-audio-notify.timer"
    }
  else
    echo "⚠️  User-Session-Bus aktuell nicht erreichbar."
    echo "   Nach Login als ${U}: systemctl --user daemon-reload && systemctl --user enable --now imac-wifi-audio-notify.timer"
  fi
fi

echo "✅ Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet."
