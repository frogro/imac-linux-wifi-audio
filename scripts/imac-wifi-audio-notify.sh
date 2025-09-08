#!/usr/bin/env bash
set -euo pipefail

REPORT="$(/usr/local/bin/imac-wifi-audio-check.sh | sed -E 's/\x1b\[[0-9;]*m//g')"

if command -v notify-send >/dev/null 2>&1; then
  notify-send "iMac WiFi/Audio Status" "$(printf '%s\n' "$REPORT" | sed -n '1,12p')"
else
  echo "$REPORT"
fi
