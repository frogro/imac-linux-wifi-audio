#!/usr/bin/env bash
set -euo pipefail

# Richtet ein:
#  - Root-Check- und Fix-Tools
#  - Polkit-Regel für pkexec
#  - User-Notifier (service + timer) im Benutzerbus

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "• %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
warn(){ printf "⚠️  %s\n" "$*"; }
die(){ printf '❌ %s\n' "$*" >&2; exit 1; }

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Bitte als root ausführen."; }
need_root

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Installationsziele
ROOT_CHECK_BIN="/usr/local/bin/imac-wifi-audio-check.sh"
ROOT_FIX_BIN="/usr/local/sbin/imac-wifi-audio-fix.sh"
POLKIT_FILE="/usr/share/polkit-1/actions/com.frogro.imacwifi.policy"
NOTIFY_BIN="/usr/local/bin/imac-wifi-audio-notify.sh"

# 1) Dateien installieren
install -m0755 "$REPO_ROOT/scripts/imac-wifi-audio-check.sh" "$ROOT_CHECK_BIN"
install -m0755 "$REPO_ROOT/scripts/imac-wifi-audio-fix.sh"  "$ROOT_FIX_BIN"
install -m0755 "$REPO_ROOT/scripts/imac-wifi-audio-notify.sh" "$NOTIFY_BIN"
install -m0644 "$REPO_ROOT/policy/com.frogro.imacwifi.policy" "$POLKIT_FILE"

# 2) Persistent FW-Mirror (für spätere Vergleiche/Backups)
install -d -m0755 /usr/local/share/imac-linux-wifi-audio/broadcom/{b2,b3}

# 3) User-Notifier Units schreiben (für aktuellen User oder SUDO_USER)
U="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
USER_HOME="$(getent passwd "$U" | cut -d: -f6)"
USER_UNIT_DIR="${USER_HOME}/.config/systemd/user"
install -d -m0755 "$USER_UNIT_DIR"

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

# 4) User-Timer aktivieren (falls User-Bus erreichbar)
if su - "$U" -c "systemctl --user daemon-reload" 2>/dev/null; then
  su - "$U" -c "systemctl --user enable --now imac-wifi-audio-notify.timer" 2>/dev/null || {
    echo "⚠️  User-Timer konnte nicht sofort aktiviert werden."
    echo "   Bitte als ${U}: systemctl --user daemon-reload && systemctl --user enable --now imac-wifi-audio-notify.timer"
  }
else
  echo "⚠️  User-Session-Bus aktuell nicht erreichbar."
  echo "   Nach Login als ${U}: systemctl --user daemon-reload && systemctl --user enable --now imac-wifi-audio-notify.timer"
fi

ok "Root-Check, pkexec-Helper, User-Notifier & persistenter FW-Mirror eingerichtet."
