#!/usr/bin/env bash
# What `nix flake update` would change in the system flake: `loft updates`'
# last check (Utilities → Flake Updates), one line per input that moved.
# With "check" it runs a fresh one first (network; the real flake is only
# read). Without any check yet, the lock's input ages.
#
# @raycast.schemaVersion 1
# @raycast.title Flake Update Summary
# @raycast.mode fullOutput
# @raycast.icon ❄️
# @raycast.packageName Nix
# @raycast.description What a flake update would change
# @raycast.argument1 { "type": "text", "placeholder": "check", "optional": true }
# @keyword flake, nix inputs
set -euo pipefail

if [ "${1:-}" = check ]; then
  loft updates check --no-packages >/dev/null
fi

summary=$(loft updates show 2>/dev/null || echo '{}')
if [ "$(jq -r '.inputs // [] | length' <<<"$summary")" -gt 0 ]; then
  jq -r '
    def day: if . then (todate | .[0:10]) else "?" end;
    def short: (.rev // "")[0:7];
    "\(.flake) — checked \(.checkedAt | todate | .[0:16] | sub("T"; " "))",
    "\(.changedCount) input(s) can update" + (if .nixpkgs.changed then " · nixpkgs \(.nixpkgs.old // "?") → \(.nixpkgs.new // "?")" else "" end),
    (.inputs[] | select(.changed) | "\(.name)  \(.old | short) (\(.old.date | day)) → \(.new | short) (\(.new.date | day))"),
    (.commands // [] | if type == "array" then .[] else . end | "run: \(.)")' <<<"$summary"
  exit 0
fi

dir="${LOFT_FLAKE:-$HOME/.flake}"
lock="$dir/flake.lock"
[ -f "$lock" ] || { echo "No check yet and no flake.lock in $dir (type: flake update summary check)"; exit 1; }
echo "No check yet (type “flake update summary check”). Input ages in $lock:"
jq -r --argjson now "$(date +%s)" '
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
