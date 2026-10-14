#!/usr/bin/env bash
# A random password (letters, digits, a few symbols), copied.
#
# @raycast.schemaVersion 1
# @raycast.title Generate Password
# @raycast.mode compact
# @raycast.icon 🔑
# @raycast.packageName Utilities
# @raycast.description Copy a random password
# @raycast.argument1 { "type": "text", "placeholder": "length (24)", "optional": true }
# @keyword password, random
set -euo pipefail

len="${1:-24}"
case "$len" in '' | *[!0-9]*) echo "Length must be a number"; exit 1 ;; esac
[ "$len" -ge 4 ] && [ "$len" -le 256 ] || { echo "Length must be 4–256"; exit 1; }

# (tr is cut off by head on purpose: no pipefail error for that.)
pw=$( (LC_ALL=C tr -dc 'A-Za-z0-9!@#%^*_+=-' < /dev/urandom || true) | head -c "$len")
printf "%s" "$pw" | wl-copy -n >/dev/null 2>&1 # its background half must not hold our stdout
echo "Copied a $len-character password"
