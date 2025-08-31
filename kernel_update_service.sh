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

# --- 1) ROOT-Check Script (robustere Prüfungen) ---
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
  # Wenn Interface vorhanden -> OK. Sonst: Modul geladen?
  has_wifi_iface && return 0
  lsmod | grep -q '^brcmfmac' && return 0
  # Fallback: dmesg Hinweis
  dmesg | grep -qi 'brcmfmac.*Firmware' && return 0
  return 1
}

audio_ok(){
  # Modul geladen?
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  # CS8409 / Cirrus in der Kartenliste?
  [[ -r /proc/asound/cards ]] && egrep -qi 'cs8409|cirrus' /proc/asound/cards && return 0
  # aplay Sichtbarkeit
  command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | egrep -qi 'CS8409|Cirrus' && return 0
  return 1
}

cur_kernel="$(uname -r)"
prev_kernel=""; [[ -f "$LAST_FILE" ]] && prev_kernel="$(cat "$LAST_FILE")"

ok_wifi=0; ok_audio=0
wifi_ok && ok_wifi=1
audio_ok && ok_audio=1

mkdir -p "$STATE_DIR"
cat >"$STATUS_JSON" <<JSON
{
  "kernel": "$cur_kernel",
  "wifi_ok": $ok_wifi,
  "audio_ok": $ok_audio,
  "checked_at": "$(date -Iseconds)"
}
JSON

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

# --- 2) FIX-Helper (robuste WLAN-Schritte + Audio-Setup) ---
cat >"$FIX_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
STATE_DIR="$STATE_DIR"
FLAG_AUDIO_NEEDED="$FLAG_AUDIO_NEEDED"
FLAG_WIFI_NEEDED="$FLAG_WIFI_NEEDED"
SHARE_FW_BASE="$SHARE_FW_BASE"
SHARE_FW_B2="$SHARE_FW_B2"
SHARE_FW_B3="$SHARE_FW_B3"

usage(){ echo "Usage: \$0 [--wifi] [--audio]"; }

copy_fw_variant(){
  # copy_fw_variant <srcdir>
  local src="\$1"
  [[ -d "\$src" ]] || { echo 0; return 0; }
  shopt -s nullglob
  local k=0
  for f in "\$src"/brcmfmac4364*; do
    install -m 0644 "\$f" /lib/firmware/brcm/
    ((k++))
  done
  echo "\$k"
}

set_symlinks_if_present(){
  # set_symlinks_if_present <prefix> <apple_variant>
  local base="\$1" ; local apple="\$2"
  local dir="/lib/firmware/brcm"
  pushd "\$dir" >/dev/null || return 0
  local src_bin="\${base}.\${apple}.bin"
  local src_txt="\${base}.\${apple}.txt"
  local src_clm="\${base}.\${apple}.clm_blob"
  local src_txcap="\${base}.\${apple}.txcap_blob"

  [[ -f "\$src_bin"  ]] && ln -sf "\$src_bin"   "\${base}.bin"
  [[ -f "\$src_txt"  ]] && ln -sf "\$src_txt"   "\${base}.txt"   || echo "⚠️  Hinweis: NVRAM (.txt) für \${base} fehlt – Treiber lädt oft trotzdem."
  [[ -f "\$src_clm"  ]] && ln -sf "\$src_clm"   "\${base}.clm_blob"
  [[ -f "\$src_txcap" ]] && ln -sf "\$src_txcap" "\${base}.txcap_blob"
  popd >/dev/null || true
}

ensure_nm_running(){
  systemctl enable --now NetworkManager >/dev/null 2>&1 || true
}

fix_wifi(){
  echo "==> (WiFi) Firmware aktualisieren & Stack neu laden"
  install -d /lib/firmware/brcm

  # 0) p2p-Workaround dauerhaft setzen
  mkdir -p /etc/modprobe.d
  if ! grep -qs '^options[[:space:]]\+brcmfmac[[:space:]]\+p2pon=0' /etc/modprobe.d/brcmfmac.conf 2>/dev/null; then
    echo 'options brcmfmac p2pon=0' > /etc/modprobe.d/brcmfmac.conf
  fi

  # 1) Aus persistentem Mirror kopieren (b2/b3), sonst Repo
  local c1 c2
  c1=\$(copy_fw_variant "\$SHARE_FW_B2")
  c2=\$(copy_fw_variant "\$SHARE_FW_B3")
  if [[ "\$c1" -eq 0 && "\$c2" -eq 0 ]]; then
    c1=\$(copy_fw_variant "\$REPO_ROOT/broadcom/b2")
    c2=\$(copy_fw_variant "\$REPO_ROOT/broadcom/b3")
  fi
  echo "   → Dateien kopiert: b2=\$c1, b3=\$c2"

  # 2) Symlinks für b2/b3 setzen (falls Quellen existieren)
  set_symlinks_if_present "brcmfmac4364b2-pcie" "apple,midway"
  set_symlinks_if_present "brcmfmac4364b3-pcie" "apple,borneo"

  # 3) STA-Reste blockfrei halten
  modprobe -r wl 2>/dev/null || true

  # 4) NetworkManager kurz stoppen, Stack neu laden, NM starten
  systemctl stop NetworkManager 2>/dev/null || true
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  sleep 1
  modprobe cfg80211
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl start NetworkManager 2>/dev/null || true
  nmcli radio wifi on 2>/dev/null || true

  if lsmod | grep -q '^brcmfmac'; then
    echo "✅ WLAN Modul aktiv."
    rm -f "\$FLAG_WIFI_NEEDED" 2>/dev/null || true
  else
    echo "⚠️  WLAN weiterhin nicht aktiv. Prüfe dmesg für fehlende Dateien."
  fi
}

fix_audio(){
  echo "==> (Audio) CS8409 bereitstellen"
  if [[ -x "\$REPO_ROOT/cirruslogic/extract_from_kernelpkg.sh" ]]; then
    "\$REPO_ROOT/cirruslogic/extract_from_kernelpkg.sh" || true
  fi
  if [[ -x "\$REPO_ROOT/cirruslogic/install_cs8409_manual.sh" ]]; then
    "\$REPO_ROOT/cirruslogic/install_cs8409_manual.sh" --autoload || true
  fi
  depmod -a || true

  # Kurzcheck
  if lsmod | grep -q '^snd_hda_codec_cs8409'; then
    echo "✅ Audio-Modul geladen."
  else
    echo "ℹ️  Modul (noch) nicht aktiv – evtl. Neustart erforderlich."
  fi

  # Flag nicht aggressiv löschen – der Notifier fragt nach Neustart erneut
}

DO_WIFI=0; DO_AUDIO=0
for a in "\$@"; do
  case "\$a" in
    --wifi) DO_WIFI=1 ;;
    --audio) DO_AUDIO=1 ;;
    *) usage; exit 2 ;;
  esac
done

ensure_nm_running
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
systemctl enable --now imac-wifi-audio-check.timer
# einmaliger initialer Check (blockiert nur kurz, kein GUI)
systemctl start imac-wifi-audio-check.service || true

# --- 4) Polkit Policy für pkexec ---
cat >"$POLKIT_POLICY" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN" "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="com.frogro.imacwifi.fix">
    <description>iMac WiFi/Audio-Fix ausführen</description>
    <message>Authentifizieren, um WiFi/Audio-Fix als Administrator auszuführen</message>
    <icon_name>network-wireless"
    </icon_name>
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

# --- 5) User-Notifier (live uname -r) ---
USER_NAME="${SUDO_USER:-$LOGNAME}"
UID_NUM="$(id -u "$USER_NAME")"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_UNIT_DIR="${USER_HOME}/.config/systemd/user"
NOTIFY_BIN="${USER_HOME}/.local/bin/imac-wifi-audio-notify.sh"

mkdir -p "$USER_UNIT_DIR" "${NOTIFY_BIN%/imac-wifi-audio-notify.sh}"

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
  msg_wifi="Nach dem Kernel-Update auf Version ${kernel} ist WLAN nicht aktiv. Soll ich die Broadcom-Firmware (b2/b3) neu einrichten und das Modul neu laden?"
  if ask_yes_no "$msg_wifi"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi || true
  fi
fi

if [[ -f "$FLAG_AUDIO_NEEDED" ]]; then
  msg_audio="Nach dem Kernel-Update auf Version ${kernel} ist Audio (CS8409) nicht aktiv. Jetzt Treiber/Setup erneut anwenden?"
  if ask_yes_no "$msg_audio"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --audio || true
  fi
fi
EOF
chmod 0755 "$NOTIFY_BIN"
chown -R "$USER_NAME":"$USER_NAME" "${USER_HOME}/.local" "${USER_HOME}/.config"

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

# --- 6) User-Session sauber initialisieren & Timer aktivieren (nicht blockieren) ---
loginctl enable-linger "$USER_NAME" || true
systemctl start "user@${UID_NUM}.service" || true

export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

runuser -u "$USER_NAME" -- systemctl --user daemon-reload
runuser -u "$USER_NAME" -- systemctl --user enable --now imac-wifi-audio-notify.timer

# Optional: ersten Lauf anstoßen, aber NICHT blockieren
runuser -u "$USER_NAME" -- systemctl --user --no-block start imac-wifi-audio-notify.service || true

echo "✅ Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet (non-blocking Setup)."
