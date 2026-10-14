#!/usr/bin/env bash
# Switches between your last dark and last light Loft theme (tokyonight / latte
# the first time), remembering each in <state>/spotlight-dark-mode.
#
# @raycast.schemaVersion 1
# @raycast.title Toggle Dark Mode
# @raycast.mode compact
# @raycast.icon 🌗
# @raycast.packageName Appearance
# @raycast.description Switch between your dark and light theme
# @keyword dark mode, light mode, appearance
set -euo pipefail

state="${LOFT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/loft}"
memo="$state/spotlight-dark-mode"
dark=tokyonight light=latte
# shellcheck disable=SC1090
[ -f "$memo" ] && . "$memo"

current=$(loft theme current 2>/dev/null || true)
polarity=$(loft theme list --json | jq -r --arg n "$current" '.[] | select(.name == $n) | .polarity')

if [ "$polarity" = light ]; then
  light="$current" target="$dark"
else
  dark="${current:-$dark}" target="$light"
fi
printf 'dark=%q\nlight=%q\n' "$dark" "$light" > "$memo"

loft theme apply "$target" >/dev/null
echo "Theme: $target"
