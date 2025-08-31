#!/usr/bin/env bash
set -euo pipefail

# Installiert/aktualisiert:
#  - Root-Checker (+Timer): /usr/local/bin/imac-wifi-audio-check.sh
#  - Root-Fix-Helper:       /usr/local/sbin/imac-wifi-audio-fix.sh   <-- enthält die neuen WLAN/Audio-Schritte
#  - Polkit-Regel:          /usr/share/polkit-1/actions/com.frogro.imacwifi.policy
#  - User-Notifier (+Timer):$HOME/.config/systemd/user/imac-wifi-audio-notify.*
#  - Persistenter FW-Mirror:/usr/local/share/imac-linux-wifi-audio/broadcom/{b2,b3}

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
  [[ -d "$src" ]] || return 0
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
  ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi)'
}

wifi_ok(){
  has_wifi_iface || lsmod | grep -q '^brcmfmac'
}

audio_ok(){
  # 1) Modul geladen?
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  # 2) ALSA-Karten mit Cirrus/CS8409?
  [[ -r /proc/asound/cards ]] && egrep -qi 'cs8409|cirrus' /proc/asound/cards && return 0
  # (Optionales) Schnell-Heuristik: PipeWire sink "Analog Stereo" vorhanden?
  if command -v pactl >/dev/null 2>&1; then
    pactl list short sinks 2>/dev/null | grep -qi 'analog-stereo' && return 0
  fi
  return 1
}

cur_kernel="$(uname -r)"
prev_kernel=""; [[ -f "$LAST_FILE" ]] && prev_kernel="$(cat "$LAST_FILE")"

ok_wifi=0; ok_audio=0
wifi_ok && ok_wifi=1
audio_ok && ok_audio=1

mkdir -p "$STATE_DIR"
cat > "$STATUS_JSON" <<JSON
{
  "kernel": "$cur_kernel",
  "wifi_ok": $ok_wifi,
  "audio_ok": $ok_audio,
  "checked_at": "$(date -Iseconds)"
}
JSON

# Flags setzen/entfernen
[[ $ok_wifi -eq 0  ]] && touch "$FLAG_WIFI_NEEDED"  || rm -f "$FLAG_WIFI_NEEDED"  2>/dev/null || true
[[ $ok_audio -eq 0 ]] && touch "$FLAG_AUDIO_NEEDED" || rm -f "$FLAG_AUDIO_NEEDED" 2>/dev/null || true

if [[ "$cur_kernel" != "$prev_kernel" ]]; then
  log "Kernelwechsel: ${prev_kernel:-<none>} -> $cur_kernel"
  echo "$cur_kernel" > "$LAST_FILE"
fi

exit 0
EOF
chmod 0755 "$CHECK_BIN"

# --- 2) FIX-Helper (WLAN + Audio) — AKTUALISIERT ---
cat >"$FIX_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "Usage: $0 [--wifi] [--audio]"; }

ensure_nm_on(){
  systemctl enable --now NetworkManager 2>/dev/null || true
}

fix_wifi(){
  echo "==> (WiFi) Firmware/Symlinks prüfen & Stack neu laden"

  # 1) P2P/GO deaktivieren (verhindert p2p-dev-* Rauschen)
  echo "options brcmfmac p2pon=0" > /etc/modprobe.d/brcmfmac.conf

  # 2) (Optional) generische Symlinks setzen (falls Apple-Varianten vorhanden)
  ( cd /lib/firmware/brcm 2>/dev/null || true
    [[ -f brcmfmac4364b2-pcie.apple,midway.bin        ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.bin        brcmfmac4364b2-pcie.bin
    [[ -f brcmfmac4364b2-pcie.apple,midway.txt        ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.txt        brcmfmac4364b2-pcie.txt
    [[ -f brcmfmac4364b2-pcie.apple,midway.clm_blob   ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.clm_blob   brcmfmac4364b2-pcie.clm_blob
    [[ -f brcmfmac4364b2-pcie.apple,midway.txcap_blob ]] && ln -sf brcmfmac4364b2-pcie.apple,midway.txcap_blob brcmfmac4364b2-pcie.txcap_blob

    [[ -f brcmfmac4364b3-pcie.apple,borneo.bin        ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.bin        brcmfmac4364b3-pcie.bin
    [[ -f brcmfmac4364b3-pcie.apple,borneo.txt        ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.txt        brcmfmac4364b3-pcie.txt
    [[ -f brcmfmac4364b3-pcie.apple,borneo.clm_blob   ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.clm_blob   brcmfmac4364b3-pcie.clm_blob
    [[ -f brcmfmac4364b3-pcie.apple,borneo.txcap_blob ]] && ln -sf brcmfmac4364b3-pcie.apple,borneo.txcap_blob brcmfmac4364b3-pcie.txcap_blob
  )

  # 3) STA-"wl" sicher entfernen (falls noch geladen)
  modprobe -r wl 2>/dev/null || true

  # 4) WLAN-Stack robust neu laden
  systemctl stop NetworkManager 2>/dev/null || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  sleep 1
  modprobe cfg80211
  modprobe brcmutil 2>/dev/null || true
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl start NetworkManager 2>/dev/null || true
  ensure_nm_on

  echo "✅ WLAN-Stack neu initialisiert."
}

fix_audio(){
  echo "==> (Audio) CS8409 vorbereiten"

  # 1) Modulparameter + Autoload, damit es nach Reboot sicher kommt
  echo "options snd_hda_codec_cs8409 model=imac27" > /etc/modprobe.d/cs8409.conf
  echo "snd_hda_codec_cs8409" > /etc/modules-load.d/snd_hda_codec_cs8409.conf

  # 2) Versuche ein Live-Reload (funktioniert nicht immer ohne Reboot)
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe snd_hda_codec_cs8409 2>/dev/null || true

  # 3) Kernel-Metatabellen & Initramfs auffrischen
  depmod -a || true
  update-initramfs -u || true

  # 4) Direkt danach Root-Check & Popup triggern (zeigt Status sofort an)
  systemctl start imac-wifi-audio-check.service 2>/dev/null || true
  su - "${SUDO_USER:-$(logname 2>/dev/null || echo root)}" -c "systemctl --user start imac-wifi-audio-notify.service" 2>/dev/null || true

  echo "ℹ️  Falls weiterhin nur 'Generic/HDMI' sichtbar: bitte einmal neu starten."
}

DO_WIFI=0; DO_AUDIO=0
for a in "$@"; do
  case "$a" in
    --wifi) DO_WIFI=1 ;;
    --audio) DO_AUDIO=1 ;;
    *) usage; exit 2 ;;
  esac
done

(( DO_WIFI + DO_AUDIO == 0 )) && { usage; exit 2; }
(( DO_WIFI )) && fix_wifi
(( DO_AUDIO )) && fix_audio
EOF
chmod 0755 "$FIX_BIN"

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

# --- 5) User-Notifier (fragt Flags ab und ruft pkexec auf) ---
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
  msg_wifi="Nach dem Kernel-Update auf Version ${kernel} ist WLAN nicht aktiv. Jetzt Broadcom-Firmware prüfen & Stack neu laden?"
  if ask_yes_no "$msg_wifi"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi || true
  fi
fi

if [[ -f "$FLAG_AUDIO_NEEDED" ]]; then
  msg_audio="Nach dem Kernel-Update auf Version ${kernel} konnte kein Audiotreiber (CS8409) geladen werden. Jetzt Treiber vorbereiten?"
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

  # User-Daemon neu laden & Timer starten
  su - "${SUDO_USER}" -c "systemctl --user daemon-reload && systemctl --user enable --now imac-wifi-audio-notify.timer" || true

  # Sofortige Benachrichtigung einmalig anstoßen (kein Warten auf den Timer)
  su - "${SUDO_USER}" -c "systemctl --user start imac-wifi-audio-notify.service" || true
fi

# Gleich initial prüfen, damit status.json/Flags aktuell sind
systemctl start imac-wifi-audio-check.service || true

echo "✅ Root-Check, Fix-Helper, Polkit, User-Notifier & FW-Mirror eingerichtet/aktualisiert."
