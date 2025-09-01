#!/usr/bin/env bash
set -euo pipefail

# Installiert/aktualisiert:
#  - Root-Check + Timer:        /usr/local/bin/imac-wifi-audio-check.sh  (+ .service/.timer)
#  - Root-Fix-Helper:           /usr/local/sbin/imac-wifi-audio-fix.sh    (pkexec-fähig)
#  - Polkit-Regel:              /usr/share/polkit-1/actions/com.frogro.imacwifi.policy
#  - User-Notifier (+timer):    $HOME/.config/systemd/user/imac-wifi-audio-notify.{service,timer}
#  - Persistenter FW-Mirror:    /usr/local/share/imac-linux-wifi-audio/broadcom/{b2,b3}

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

# --- Hilfsfunktion: sichere --user systemctl Aufrufe (ohne Hänger) ---
userctl(){
  # userctl <username> -- systemctl --user <args...>
  local user="$1"; shift
  [[ "$1" == "--" ]] && shift || true
  local uid
  uid="$(id -u "$user")"
  # Nur ausführen, wenn User-Session aktiv ist
  if loginctl show-user "$user" >/dev/null 2>&1; then
    local xrd="/run/user/$uid"
    local dbus="unix:path=/run/user/$uid/bus"
    sudo -u "$user" env XDG_RUNTIME_DIR="$xrd" DBUS_SESSION_BUS_ADDRESS="$dbus" systemctl --user "$@"
  else
    echo "⚠️  Keine aktive Usersession für $user gefunden – überspringe: systemctl --user $*" >&2
    return 0
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

C1=$(mirror_variant "${REPO_ROOT}/broadcom/b2" "$SHARE_FW_B2" || echo 0)
C2=$(mirror_variant "${REPO_ROOT}/broadcom/b3" "$SHARE_FW_B3" || echo 0)
echo "FW-Mirror: b2=${C1} Dateien, b3=${C2} Dateien unter ${SHARE_FW_BASE}"

# --- 1) ROOT-Check Script (schreibt status.json + Flags) ---
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
  ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi|wlp|wlo)'
}

wifi_ok(){
  # Interface ODER Modul als Indiz
  has_wifi_iface && return 0
  lsmod | grep -q '^brcmfmac' && return 0
  # Firmware-Hinweise
  dmesg | grep -qi 'brcmfmac' && return 0
  return 1
}

audio_ok(){
  # Cirrus 8409 geladen?
  lsmod | grep -q '^snd_hda_codec_cs8409' && return 0
  # Wird der Cirrus Codec sichtbar?
  [[ -r /proc/asound/cards ]] && grep -qiE 'CS8409|Cirrus' /proc/asound/cards && return 0
  # dmesg-Spur?
  dmesg | grep -qiE 'cs8409|cirrus' && return 0
  return 1
}

cur_kernel="$(uname -r)"
prev_kernel=""; [[ -f "$LAST_FILE" ]] && prev_kernel="$(cat "$LAST_FILE")"

ok_wifi=0; ok_audio=0
wifi_ok && ok_wifi=1
audio_ok && ok_audio=1

mkdir -p "$STATE_DIR"
printf '{
  "kernel": "%s",
  "wifi_ok": %d,
  "audio_ok": %d,
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

# --- 2) FIX-Helper (WiFi & Audio) ---
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

usage(){ echo "Usage: \$0 [--wifi] [--audio] [--verify-only]"; }

copy_fw_variant(){
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
  local base="\$1" ; local apple="\$2"
  local dir="/lib/firmware/brcm"
  pushd "\$dir" >/dev/null || return 0
  local src_bin="\${base}.\${apple}.bin"
  local src_txt="\${base}.\${apple}.txt"
  local src_clm="\${base}.\${apple}.clm_blob"
  local src_txcap="\${base}.\${apple}.txcap_blob"

  [[ -f "\$src_bin"  ]] && ln -sf "\$src_bin"   "\${base}.bin"
  [[ -f "\$src_txt"  ]] && ln -sf "\$src_txt"   "\${base}.txt"   || echo "⚠️  Hinweis: NVRAM (.txt) fehlt – Treiber lädt oft trotzdem, ggf. NVRAM später ergänzen."
  [[ -f "\$src_clm"  ]] && ln -sf "\$src_clm"   "\${base}.clm_blob"
  [[ -f "\$src_txcap" ]] && ln -sf "\$src_txcap" "\${base}.txcap_blob"
  popd >/dev/null || true
}

fix_wifi(){
  echo "==> (WiFi) Firmware aktualisieren & Stack neu laden"
  install -d /lib/firmware/brcm

  local c1 c2
  c1=\$(copy_fw_variant "$SHARE_FW_B2" || echo 0)
  c2=\$(copy_fw_variant "$SHARE_FW_B3" || echo 0)
  if [[ "\$c1" -eq 0 && "\$c2" -eq 0 ]]; then
    c1=\$(copy_fw_variant "\$REPO_ROOT/broadcom/b2" || echo 0)
    c2=\$(copy_fw_variant "\$REPO_ROOT/broadcom/b3" || echo 0)
  fi
  echo "   → Dateien kopiert: b2=\$c1, b3=\$c2"

  set_symlinks_if_present "brcmfmac4364b2-pcie" "apple,midway"
  set_symlinks_if_present "brcmfmac4364b3-pcie" "apple,borneo"

  # Broadcom-STA Reste entfernen/blockaden lösen
  modprobe -r wl 2>/dev/null || true

  # Stack neu laden + NM reaktivieren
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmutil 2>/dev/null || true
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true

  if lsmod | grep -q '^brcmfmac'; then
    echo "✅ WLAN-Modul aktiv."
    rm -f "\$FLAG_WIFI_NEEDED" 2>/dev/null || true
  else
    echo "⚠️  WLAN weiterhin nicht aktiv. Prüfe dmesg."
  fi
}

fix_audio(){
  echo "==> (Audio) HDA-Stack sauber neu initialisieren (CS8409)"
  # 1) Blacklist sicher entfernen (falls vorhanden) + initramfs refresh
  rm -f /etc/modprobe.d/blacklist-cs8409.conf 2>/dev/null || true
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u || true
  fi

  # 2) Autoload sicherstellen
  echo snd_hda_codec_cs8409 > /etc/modules-load.d/snd_hda_codec_cs8409.conf

  # 3) Kernelmodule frisch binden
  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe -r snd_hda_intel 2>/dev/null || true
  modprobe snd_hda_intel
  modprobe snd_hda_codec_cs8409

  # 4) ALSA neu initialisieren
  if command -v alsactl >/dev/null 2>&1; then
    alsactl init || true
  fi

  # 5) Erfolg prüfen (root-seitig)
  if lsmod | grep -q '^snd_hda_codec_cs8409'; then
    echo "✅ CS8409 Modul geladen."
    rm -f "\$FLAG_AUDIO_NEEDED" 2>/dev/null || true
  else
    echo "⚠️  CS8409 weiterhin nicht aktiv."
  fi
}

verify_only(){
  # schreibt Statusdatei neu
  /usr/local/bin/imac-wifi-audio-check.sh || true
  cat /var/lib/imac-linux-wifi-audio/status.json 2>/dev/null || true
}

DO_WIFI=0; DO_AUDIO=0; VERIFY_ONLY=0
for a in "\$@"; do
  case "\$a" in
    --wifi) DO_WIFI=1 ;;
    --audio) DO_AUDIO=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    *) usage; exit 2 ;;
  esac
done

(( DO_WIFI )) && fix_wifi
(( DO_AUDIO )) && fix_audio
(( VERIFY_ONLY )) && verify_only
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
    <icon_name>multimedia-volume-control</icon_name>
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

# --- 5) User-Notifier (fragt Fixe an + refresht User-Soundstack) ---
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  USER_UNIT_DIR="${USER_HOME}/.config/systemd/user"
  NOTIFY_BIN="${USER_HOME}/.local/bin/imac-wifi-audio-notify.sh"

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
  else
    read -p "$msg [y/N]: " yn; [[ "${yn,,}" == "y" ]]
  fi
}

refresh_user_audio_stack(){
  # Nach erfolgreichem Audio-Fix: PipeWire/WirePlumber neu starten (Userspace)
  systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
}

kernel="$(uname -r)"

if [[ -f "$FLAG_WIFI_NEEDED" ]]; then
  msg_wifi="Nach Kernel-Wechsel auf ${kernel} ist WLAN inaktiv. Firmware & Modul neu einrichten?"
  if ask_yes_no "$msg_wifi"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi || true
  fi
fi

if [[ -f "$FLAG_AUDIO_NEEDED" ]]; then
  msg_audio="Nach Kernel-Wechsel auf ${kernel} ist der Audiotreiber (CS8409) nicht aktiv. HDA-Stack frisch laden?"
  if ask_yes_no "$msg_audio"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --audio || true
    # Egal ob erfolgreich oder nicht – Status neu abfragen und Userspace refreshen
    /usr/local/sbin/imac-wifi-audio-fix.sh --verify-only >/dev/null 2>&1 || true
    refresh_user_audio_stack
  fi
fi
EOF
  chmod +x "$NOTIFY_BIN"

  USER_SERVICE_FILE="${USER_UNIT_DIR}/imac-wifi-audio-notify.service"
  USER_TIMER_FILE="${USER_UNIT_DIR}/imac-wifi-audio-notify.timer"

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

  # --user units ohne Hänger laden/aktivieren
  userctl "$SUDO_USER" -- daemon-reload
  userctl "$SUDO_USER" -- enable --now imac-wifi-audio-notify.timer
fi

echo "✅ Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet."
