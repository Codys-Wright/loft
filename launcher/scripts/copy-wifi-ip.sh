#!/usr/bin/env bash
# Copies this machine's local IPv4 address: the Wi-Fi interface's, or else the
# one the default route uses.
#
# @raycast.schemaVersion 1
# @raycast.title Copy Wi-Fi IP
# @raycast.mode compact
# @raycast.icon 📶
# @raycast.packageName Network
# @raycast.description Copy your local IP address
# @keyword ip address, local ip, lan ip
set -euo pipefail

iface=""
for d in /sys/class/net/*; do
  [ -d "$d/wireless" ] && { iface=$(basename "$d"); break; }
done
if [ -z "$iface" ]; then
  iface=$(ip -j route show default | jq -r '.[0].dev // empty')
fi
[ -n "$iface" ] || { echo "No network connection"; exit 1; }

addr=$(ip -j -4 addr show dev "$iface" | jq -r '.[0].addr_info[0].local // empty')
[ -n "$addr" ] || { echo "$iface has no IPv4 address"; exit 1; }

printf "%s" "$addr" | wl-copy -n >/dev/null 2>&1
echo "Copied $addr ($iface)"
