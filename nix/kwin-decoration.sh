# loft-kwin-decoration apply | revert | status
#
# Selects Loft's KWin decoration (dev.loft.decoration) while Loft's shell runs
# in Plasma, and puts back whatever was there when it stops (docs/KWIN.md §5:
# no traces in Plasma). The home-manager unit loft-plasma-shell runs `apply`
# after it starts and `revert` after it stops.
#
#   apply   records kwinrc [org.kde.kdecoration2] library / theme in
#           <state>/kwin-decoration.prev (unless Loft's is already selected),
#           selects Loft's, and asks KWin to reconfigure
#   revert  restores the recorded values (only if Loft's is still selected:
#           a choice made in System Settings meanwhile wins) and reconfigures
#   status  prints the selected library and whether a record exists
#
# <state> is $LOFT_STATE_DIR, else $XDG_STATE_HOME/loft, else ~/.local/state/loft.

state="${LOFT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/loft}"
record="$state/kwin-decoration.prev"
group="org.kde.kdecoration2"
ours="dev.loft.decoration"
unset_marker="__loft_unset__"

# The user's own kwinrc only (an absolute path skips KConfig's cascade): a
# value that came from /etc/xdg is recorded as unset, so revert deletes the
# key instead of copying the system default into the user's file.
kwinrc="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc"
read_key() {
  kreadconfig6 --file "$kwinrc" --group "$group" --key "$1" --default "$unset_marker"
}

write_key() { # key value-or-marker
  if [ "$2" = "$unset_marker" ]; then
    kwriteconfig6 --file kwinrc --group "$group" --key "$1" --delete
  else
    kwriteconfig6 --file kwinrc --group "$group" --key "$1" -- "$2"
  fi
}

reconfigure() {
  # Nothing to tell when KWin isn't running (e.g. the session is ending).
  dbus-send --session --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
}

# Whether KWin can load Loft's plugin: selecting a missing one would leave
# windows undecorated. KWin searches QT_PLUGIN_PATH (on NixOS: the system and
# user profiles, which the session's environment lists too).
installed() {
  local IFS=: d
  for d in ${QT_PLUGIN_PATH:-} /run/current-system/sw/lib/qt-6/plugins "/etc/profiles/per-user/${USER:-}/lib/qt-6/plugins" "$HOME/.nix-profile/lib/qt-6/plugins"; do
    [ -n "$d" ] && [ -f "$d/org.kde.kdecoration3/$ours.so" ] && return 0
  done
  return 1
}

case "${1:-}" in
  apply)
    if ! installed; then
      echo "loft-kwin-decoration: $ours is not installed (programs.loft.plasma in the NixOS config installs it); leaving KWin's decoration alone" >&2
      exit 0
    fi
    if [ "$(read_key library)" != "$ours" ] || [ ! -f "$record" ]; then
      mkdir -p "$state"
      tmp="$record.tmp"
      {
        printf 'library=%s\n' "$(read_key library)"
        printf 'theme=%s\n' "$(read_key theme)"
      } > "$tmp"
      # Loft's already selected but no record (a crash lost it): Breeze is
      # what Plasma would show, so revert goes to Plasma's default.
      if grep -q "^library=$ours\$" "$tmp"; then
        printf 'library=%s\ntheme=%s\n' "$unset_marker" "$unset_marker" > "$tmp"
      fi
      mv "$tmp" "$record"
    fi
    write_key library "$ours"
    write_key theme Loft
    reconfigure
    ;;
  revert)
    if [ ! -f "$record" ]; then
      exit 0
    fi
    if [ "$(read_key library)" = "$ours" ]; then
      while IFS='=' read -r key value; do
        case "$key" in
          library | theme) write_key "$key" "$value" ;;
        esac
      done < "$record"
      reconfigure
    fi
    rm -f "$record"
    ;;
  status)
    echo "library: $(read_key library)"
    if [ -f "$record" ]; then echo "recorded: $record"; else echo "recorded: none"; fi
    ;;
  *)
    echo "usage: loft-kwin-decoration apply | revert | status" >&2
    exit 2
    ;;
esac
