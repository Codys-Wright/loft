# loft-kwin-window-menu apply | revert | status
#
# Window menus that apps with their own title bars ask for (GTK / libadwaita
# header bars, Chromium / Electron's, X11's _GTK_SHOW_WINDOW_MENU) are KWin's
# own; loft-kwin-patched sends them to the D-Bus service in kwinrc [Windows]
# ClientWindowMenuService instead (nix/kwin/client-window-menu-service.patch,
# docs/KWIN.md §4.4), falling back to KWin's menu when nothing answers. Loft
# sets it to its bridge, dev.loft.KWinBridge, while Loft's shell runs in
# Plasma and puts the previous value back when it stops (docs/KWIN.md §5).
# The home-manager unit loft-plasma-shell runs `apply` after it starts and
# `revert` after it stops.
#
#   apply   records the current value in <state>/kwin-window-menu.prev
#           (unless a record exists: a crash kept the old one), sets the key,
#           and asks KWin to reconfigure
#   revert  restores the recorded value (only if the key still holds what
#           apply set: a later change by hand wins) and reconfigures
#   status  prints the key and whether a record exists
#
# With a stock KWin the key does nothing, so setting it is harmless.
# <state> is $LOFT_STATE_DIR, else $XDG_STATE_HOME/loft, else ~/.local/state/loft.

state="${LOFT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/loft}"
record="$state/kwin-window-menu.prev"
group="Windows"
key="ClientWindowMenuService"
want="dev.loft.KWinBridge"
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
    if [ ! -f "$record" ]; then
      mkdir -p "$state"
      printf 'value=%s\n' "$(read_key)" > "$record.tmp"
      mv "$record.tmp" "$record"
    fi
    write_key "$want"
    reconfigure
    ;;
  revert)
    [ -f "$record" ] || exit 0
    prev="$(sed -n 's/^value=//p' "$record")"
    if [ "$(read_key)" = "$want" ]; then
      write_key "${prev:-$unset_marker}"
      reconfigure
    fi
    rm -f "$record"
    ;;
  status)
    v="$(read_key)"
    [ "$v" != "$unset_marker" ] || v="unset (KWin's own menu)"
    echo "$key: $v"
    if [ -f "$record" ]; then echo "recorded: $record"; else echo "recorded: none"; fi
    ;;
  *)
    echo "usage: loft-kwin-window-menu apply | revert | status" >&2
    exit 2
    ;;
esac
