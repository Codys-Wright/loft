# loft-kwin-tile-modifier apply [Shift|Alt|Ctrl|Meta] | revert | status
#
# The key that, held while dragging a window, tiles it (KWin's custom
# tiles). Stock KWin hard-codes Shift; loft-kwin-patched reads kwinrc
# [Windows] TileWhileMovingModifier (nix/kwin/tile-while-moving-modifier.patch,
# docs/KWIN.md §4.6). Loft sets it to Alt (Option, as on macOS) while Loft's
# shell runs in Plasma and puts the previous value back when it stops
# (docs/KWIN.md §5: no traces in Plasma). The home-manager unit
# loft-plasma-shell runs `apply` after it starts and `revert` after it stops.
#
#   apply   records the current value in <state>/kwin-tile-modifier.prev
#           (unless a record exists: a crash kept the old one), sets the key
#           (default Alt), and asks KWin to reconfigure
#   revert  restores the recorded value (only if the key still holds what
#           apply set: a later change by hand wins) and reconfigures
#   status  prints the key and whether a record exists
#
# With a stock KWin the key does nothing, so setting it is harmless.
# <state> is $LOFT_STATE_DIR, else $XDG_STATE_HOME/loft, else ~/.local/state/loft.

state="${LOFT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/loft}"
record="$state/kwin-tile-modifier.prev"
group="Windows"
key="TileWhileMovingModifier"
unset_marker="__loft_unset__"

# The user's own kwinrc only (see loft-kwin-decoration).
kwinrc="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc"
read_key() {
  kreadconfig6 --file "$kwinrc" --group "$group" --key "$key" --default "$unset_marker"
}

write_key() { # value-or-marker
  if [ "$1" = "$unset_marker" ]; then
    kwriteconfig6 --file kwinrc --group "$group" --key "$key" --delete
  else
    kwriteconfig6 --file kwinrc --group "$group" --key "$key" -- "$1"
  fi
}

reconfigure() {
  dbus-send --session --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
}

case "${1:-}" in
  apply)
    want="${2:-Alt}"
    case "$want" in
      Shift | Alt | Ctrl | Meta) ;;
      *) echo "loft-kwin-tile-modifier: want Shift, Alt, Ctrl or Meta, not '$want'" >&2; exit 2 ;;
    esac
    if [ ! -f "$record" ]; then
      mkdir -p "$state"
      { printf 'value=%s\n' "$(read_key)"; printf 'applied=%s\n' "$want"; } > "$record.tmp"
      mv "$record.tmp" "$record"
    else
      # Keep the recorded original; note what this apply set.
      prev="$(sed -n 's/^value=//p' "$record")"
      printf 'value=%s\napplied=%s\n' "$prev" "$want" > "$record.tmp"
      mv "$record.tmp" "$record"
    fi
    write_key "$want"
    reconfigure
    ;;
  revert)
    [ -f "$record" ] || exit 0
    prev="$(sed -n 's/^value=//p' "$record")"
    applied="$(sed -n 's/^applied=//p' "$record")"
    if [ "$(read_key)" = "$applied" ]; then
      write_key "${prev:-$unset_marker}"
      reconfigure
    fi
    rm -f "$record"
    ;;
  status)
    v="$(read_key)"
    [ "$v" != "$unset_marker" ] || v="unset (KWin's default, Shift)"
    echo "$key: $v"
    if [ -f "$record" ]; then echo "recorded: $record"; else echo "recorded: none"; fi
    ;;
  *)
    echo "usage: loft-kwin-tile-modifier apply [Shift|Alt|Ctrl|Meta] | revert | status" >&2
    exit 2
    ;;
esac
