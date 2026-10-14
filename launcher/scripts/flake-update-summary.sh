#!/usr/bin/env bash
# How old each input of a flake's lock is, oldest first — what `nix flake
# update` would refresh. Read-only (a placeholder until `loft` grows an
# update command for the system flake).
#
# @raycast.schemaVersion 1
# @raycast.title Flake Update Summary
# @raycast.mode fullOutput
# @raycast.icon ❄️
# @raycast.packageName Nix
# @raycast.description Input ages of a flake.lock
# @raycast.argument1 { "type": "text", "placeholder": "flake dir (~/.flake)", "optional": true }
# @keyword flake, nix inputs
set -euo pipefail

dir="${1:-${LOFT_FLAKE:-$HOME/.flake}}"
dir="${dir/#\~/$HOME}"
lock="$dir/flake.lock"
[ -f "$lock" ] || { echo "No flake.lock in $dir"; exit 1; }

now=$(date +%s)
echo "$lock"
jq -r --argjson now "$now" '
  .nodes as $n
  | [ $n.root.inputs | to_entries[]
      | .key as $k
      | (if (.value | type) == "string" then .value else empty end) as $node
      | $n[$node].locked
      | select(.lastModified)
      | { k: $k, age: (($now - .lastModified) / 86400 | floor),
          rev: ((.rev // .narHash // "")[0:7]), what: ((.owner // "") + "/" + (.repo // .url // "")) } ]
  | sort_by(-.age)[]
  | "\(.age)d  \(.k)  \(.what)  \(.rev)"' "$lock"
