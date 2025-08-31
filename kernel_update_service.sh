#!/usr/bin/env bash
set -euo pipefail

# Installiert/aktualisiert:
#  - Root-Check + Timer:   /usr/local/bin/imac-wifi-audio-check.sh
#  - Root-Fix-Helper:      /usr/local/sbin/imac-wifi-audio-fix.sh
#  - Polkit-Regel:         /usr/share/polkit-1/actions/com.frogro.imacwifi.policy
#  - User-Notifier (+timer): $HOME/.config/systemd/user/imac-wifi-audio-notify.*
#  - FW-Mirror (persistent): /usr/local/share/imac-linux-wifi-audio/broadcom/{b2,b3}

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="/var/lib/imac-linux-wifi-audio"
LAST_FILE="${STATE_DIR}/last_kernel"
STATUS_JSON="${STATE_DIR}/status.json"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"
FLAG_REBOOT_SUGGESTED="${STATE_DIR}/reboot_suggested"
FLAG_POSTREBOOT_CHECK="${STATE_DIR}/postreboot_check"

SERVICE="/etc/systemd/system/imac-wifi-audio-check.service"
TIMER="/etc/systemd/system/imac-wifi-audio-check.timer"
CHECK_BIN="/usr/local/bin/imac-wifi-audio-check.sh"
FIX_BIN="/usr/local/sbin/imac-wifi-audio-fix.sh"
POLKIT_POLICY="/usr/share/polkit-1/actions/com.frogro.imacwifi.policy"

# Persistenter Firmware-Speicher
SHARE_FW_BASE="/usr/local/share/imac-linux-wifi-audio/broadcom"
SHARE_FW_B2="${SHARE_FW_BASE}/b2"
SHARE_FW_B3="${SHARE_FW_BASE}/b3"

need_root(){ if [[ $EUID -ne 0 ]]; then echo "Bitte mit sudo ausführen." >&2; exit 1; fi }
need_root

mkdir -p "$STATE_DIR" "$SHARE_FW_B2" "$SHARE_FW_B3"

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

# --- 1) ROOT-Check Script (robuster Audio/WiFi-Check + Blacklist-Wächter) ---
cat >"$CHECK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="/var/lib/imac-linux-wifi-audio"
LAST_FILE="${STATE_DIR}/last_kernel"
STATUS_JSON="${STATE_DIR}/status.json"
FLAG_AUDIO_NEEDED="${STATE_DIR}/needs_audio_fix"
FLAG_WIFI_NEEDED="${STATE_DIR}/needs_wifi_fix"
FLAG_REBOOT_SUGGESTED="${STATE_DIR}/reboot_suggested"
FLAG_POSTREBOOT_CHECK="${STATE_DIR}/postreboot_check"

log(){ printf "[imac-wifi-audio-check] %s\n" "$*"; }

has_wifi_iface(){
  command -v ip >/dev/null 2>&1 || return 1
  ip -o link show | awk -F': ' '{print $2}' | egrep -q '^(wlan|wl|wifi|wlp)'
}

wifi_ok(){
  has_wifi_iface || lsmod | grep -q '^brcmfmac'
}

audio_ok(){
  if lsmod | grep -q '^snd_hda_codec_cs8409' && [[ -r /proc/asound/cards ]]; then
    grep -qiE 'CS8409|Cirrus' /proc/asound/cards && return 0
  fi
  command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -qiE 'CS8409|Cirrus' && return 0
  dmesg | grep -qiE 'cs8409|cirrus' && return 0
  return 1
}

# Blacklist-Wächter (falls jemand die Blacklist wieder gesetzt hat)
for f in /etc/modprobe.d/*cs8409*.conf; do
  [[ -e "$f" ]] || continue
  if grep -qiE '^\s*blacklist\s+snd_hda_codec_cs8409' "$f"; then
    log "Entferne Blacklist: $f"
    rm -f "$f"
    update-initramfs -u || true
    touch "$FLAG_REBOOT_SUGGESTED" "$FLAG_POSTREBOOT_CHECK"
  fi
done

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

[[ $ok_wifi -eq 0 ]] && touch "$FLAG_WIFI_NEEDED"  || rm -f "$FLAG_WIFI_NEEDED"  2>/dev/null || true
[[ $ok_audio -eq 0 ]] && touch "$FLAG_AUDIO_NEEDED" || rm -f "$FLAG_AUDIO_NEEDED" 2>/dev/null || true

if [[ "$cur_kernel" != "$prev_kernel" ]]; then
  log "Kernelwechsel: ${prev_kernel:-<none>} -> $cur_kernel"
  echo "$cur_kernel" > "$LAST_FILE"
  # Nach Kernelwechsel nachprüfen
  touch "$FLAG_POSTREBOOT_CHECK"
fi

exit 0
EOF
chmod 0755 "$CHECK_BIN"

# --- 2) FIX-Helper (harte WLAN-Schritte + Audio-Nachlauf) ---
cat >"$FIX_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
STATE_DIR="$STATE_DIR"
FLAG_AUDIO_NEEDED="$FLAG_AUDIO_NEEDED"
FLAG_WIFI_NEEDED="$FLAG_WIFI_NEEDED"
FLAG_REBOOT_SUGGESTED="$FLAG_REBOOT_SUGGESTED"
FLAG_POSTREBOOT_CHECK="$FLAG_POSTREBOOT_CHECK"
SHARE_FW_B2="$SHARE_FW_B2"
SHARE_FW_B3="$SHARE_FW_B3"

usage(){ echo "Usage: \$0 [--wifi] [--audio]"; }

copy_fw_variant(){
  local src="\$1"; [[ -d "\$src" ]] || { echo 0; return 0; }
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
  [[ -f "\$src_txt"  ]] && ln -sf "\$src_txt"   "\${base}.txt"
  [[ -f "\$src_clm"  ]] && ln -sf "\$src_clm"   "\${base}.clm_blob"
  [[ -f "\$src_txcap" ]] && ln -sf "\$src_txcap" "\${base}.txcap_blob"
  popd >/dev/null || true
}

fix_wifi(){
  echo "==> (WiFi) Firmware aktualisieren & Stack neu laden"
  install -d /lib/firmware/brcm
  local c1=\$(copy_fw_variant "$SHARE_FW_B2")
  local c2=\$(copy_fw_variant "$SHARE_FW_B3")
  if [[ "\$c1" -eq 0 && "\$c2" -eq 0 ]]; then
    c1=\$(copy_fw_variant "\$REPO_ROOT/broadcom/b2")
    c2=\$(copy_fw_variant "\$REPO_ROOT/broadcom/b3")
  fi
  echo "   → Dateien kopiert: b2=\$c1, b3=\$c2"
  set_symlinks_if_present "brcmfmac4364b2-pcie" "apple,midway"
  set_symlinks_if_present "brcmfmac4364b3-pcie" "apple,borneo"

  apt-get purge -y broadcom-sta-dkms bcmwl-kernel-source 2>/dev/null || true
  modprobe -r wl 2>/dev/null || true

  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211
  modprobe brcmutil 2>/dev/null || true
  modprobe brcmfmac
  rfkill unblock wifi 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true

  if lsmod | grep -q '^brcmfmac'; then
    echo "✅ WLAN Modul aktiv."
    rm -f "\$FLAG_WIFI_NEEDED" 2>/dev/null || true
  else
    echo "⚠️  WLAN weiterhin nicht aktiv. Prüfe dmesg."
  fi
}

fix_audio(){
  echo "==> (Audio) CS8409 bereitstellen"
  # Blacklist-Schutz
  for f in /etc/modprobe.d/*cs8409*.conf; do
    [[ -e "\$f" ]] || continue
    if grep -qiE '^\s*blacklist\s+snd_hda_codec_cs8409' "\$f"; then
      echo "   → entferne Blacklist: \$f"
      rm -f "\$f"; update-initramfs -u || true
      touch "\$FLAG_REBOOT_SUGGESTED" "\$FLAG_POSTREBOOT_CHECK"
    fi
  done

  echo snd_hda_codec_cs8409 >/etc/modules-load.d/snd_hda_codec_cs8409.conf

  if [[ -x "\$REPO_ROOT/cirruslogic/extract_from_kernelpkg.sh" ]]; then
    "\$REPO_ROOT/cirruslogic/extract_from_kernelpkg.sh" || true
  fi
  if [[ -x "\$REPO_ROOT/cirruslogic/install_cs8409_manual.sh" ]]; then
    "\$REPO_ROOT/cirruslogic/install_cs8409_manual.sh" --autoload || true
  fi

  modprobe -r snd_hda_codec_cs8409 2>/dev/null || true
  modprobe snd_hda_codec_cs8409 2>/dev/null || true
  alsactl init >/dev/null 2>&1 || true

  if lsmod | grep -q '^snd_hda_codec_cs8409' && grep -qiE 'CS8409|Cirrus' /proc/asound/cards 2>/dev/null; then
    echo "✅ Audio aktiv."
    rm -f "\$FLAG_AUDIO_NEEDED" "\$FLAG_POSTREBOOT_CHECK" 2>/dev/null || true
  else
    echo "ℹ️  Audio noch nicht verifizierbar – ggf. Reboot nötig."
    touch "\$FLAG_REBOOT_SUGGESTED" "\$FLAG_POSTREBOOT_CHECK" "\$FLAG_AUDIO_NEEDED"
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

# --- 5) User-Notifier (prüft Flags & bietet Fix oder Erfolgsmeldung) ---
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
FLAG_REBOOT_SUGGESTED="${STATE_DIR}/reboot_suggested"
FLAG_POSTREBOOT_CHECK="${STATE_DIR}/postreboot_check"

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

inform(){
  local msg="$1"
  if command -v zenity >/dev/null 2>&1; then
    zenity --info --title="iMac – Hinweis" --text="$msg" || true
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --msgbox "$msg" || true
  else
    echo "$msg"
  fi
}

kernel="$(uname -r)"

# Postreboot-Check: Erfolg/Nicht-Erfolg nach Neustart melden
if [[ -f "$FLAG_POSTREBOOT_CHECK" ]]; then
  WIFI="NOK"; AUDIO="NOK"
  if lsmod | grep -q '^brcmfmac'; then WIFI="OK"; fi
  if lsmod | grep -q '^snd_hda_codec_cs8409' && grep -qiE 'CS8409|Cirrus' /proc/asound/cards 2>/dev/null; then AUDIO="OK"; fi
  inform "Nach dem Neustart (\${kernel}): WLAN=\${WIFI}, Audio=\${AUDIO}"
  # Wenn alles gut: Flags weg
  if [[ "$WIFI" == "OK" && "$AUDIO" == "OK" ]]; then
    rm -f "$FLAG_AUDIO_NEEDED" "$FLAG_WIFI_NEEDED" "$FLAG_REBOOT_SUGGESTED" "$FLAG_POSTREBOOT_CHECK" 2>/dev/null || true
  fi
fi

# WLAN-Reparatur?
if [[ -f "$FLAG_WIFI_NEEDED" ]]; then
  msg_wifi="WLAN ist aktuell nicht aktiv. Soll ich die Broadcom-Firmware (b2/b3) neu einrichten und den Stack neu laden?"
  if ask_yes_no "$msg_wifi"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --wifi || true
  fi
fi

# Audio-Reparatur?
if [[ -f "$FLAG_AUDIO_NEEDED" ]]; then
  msg_audio="Audio (CS8409) ist aktuell nicht aktiv. Soll ich den passenden Treiber bereitstellen?"
  if ask_yes_no "$msg_audio"; then
    pkexec /usr/local/sbin/imac-wifi-audio-fix.sh --audio || true
  fi
fi

# Reboot-Hinweis (nur anzeigen)
if [[ -f "$FLAG_REBOOT_SUGGESTED" ]]; then
  inform "Ein Neustart wird empfohlen, damit der HDA-Bus (CS8409) sauber initialisiert. Nach dem Reboot prüfe ich erneut."
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

echo "✅ Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet."
