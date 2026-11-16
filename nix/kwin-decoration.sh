# loft-kwin-decoration apply | revert | status
#
# Selects Loft's KWin decoration (dev.loft.decoration) while Loft's shell runs
# in Plasma, and puts back whatever was there when it stops (docs/KWIN.md §5:
# no traces in Plasma). The home-manager unit loft-plasma-shell runs `apply`
# after it starts and `revert` after it stops.
#
#   apply   records kwinrc [org.kde.kdecoration2] library / theme and
#           ButtonsOnLeft / ButtonsOnRight in <state>/kwin-decoration.prev
#           (unless Loft's are already set), selects Loft's decoration and
#           macOS's button order (close, minimize, zoom on the left, nothing
#           on the right), and asks KWin to reconfigure
#   revert  restores the recorded values (each only if Loft's is still set:
#           a choice made in System Settings meanwhile wins) and reconfigures
#   status  prints the selected library, the button order and whether a
#           record exists
#
# The button order matters to apps that draw their own title bars: kded's
# gtkconfig module copies it into GTK's gtk-decoration-layout (gtk-3.0 /
# gtk-4.0 settings.ini, xsettingsd, GSettings org.gnome.desktop.wm.preferences
# button-layout), which GTK, Chromium / Brave and Electron apps follow
# (docs/KWIN.md §4.4). gtkconfig only hears about it through KConfig's change
# notification, so those keys are announced with it (notify, below).
#
# <state> is $LOFT_STATE_DIR, else $XDG_STATE_HOME/loft, else ~/.local/state/loft.

state="${LOFT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/loft}"
record="$state/kwin-decoration.prev"
group="org.kde.kdecoration2"
ours="dev.loft.decoration"
unset_marker="__loft_unset__"
# macOS: close, minimize, zoom on the left (KWin's letters: X close,
# I minimize, A maximize; M menu, S all desktops, H help, F keep above,
# B keep below, L shade, N application menu). Nothing on the right.
ours_left="XIA"
ours_right=""

# The user's own kwinrc only (an absolute path skips KConfig's cascade): a
# value that came from /etc/xdg is recorded as unset, so revert deletes the
# key instead of copying the system default into the user's file.
kwinrc="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc"
read_key() {
  kreadconfig6 --file "$kwinrc" --group "$group" --key "$1" --default "$unset_marker"
}

# What KWin and gtkconfig see: the cascade. KConfig doesn't write a value
# the lower files already give (a MacTahoe global theme's kdedefaults has
# XIA), so "is it still Loft's" is asked here, not of the user's file.
read_effective() {
  kreadconfig6 --file kwinrc --group "$group" --key "$1" --default "$unset_marker"
}

write_key() { # key value-or-marker
  if [ "$2" = "$unset_marker" ]; then
    kwriteconfig6 --file kwinrc --group "$group" --key "$1" --delete
    # When a lower config file (/etc/xdg, ~/.config/kdedefaults: the global
    # theme's) has the key, KConfig deletes it by writing `key[$d]`, which
    # hides that value too. Unset means "whatever Plasma would show", so
    # drop the marker.
    if [ -f "$kwinrc" ]; then
      awk -v grp="[$group]" -v drop="$1[\$d]" '
        /^\[/ { ingroup = ($0 == grp) }
        !(ingroup && $0 == drop)
      ' "$kwinrc" > "$kwinrc.loft-tmp" && cat "$kwinrc.loft-tmp" > "$kwinrc"
      rm -f "$kwinrc.loft-tmp"
    fi
  else
    kwriteconfig6 --file kwinrc --group "$group" --key "$1" -- "$2"
  fi
}

# What Loft sets each recorded key to.
ours_for() {
  case "$1" in
    library) printf '%s' "$ours" ;;
    theme) printf 'Loft' ;;
    ButtonsOnLeft) printf '%s' "$ours_left" ;;
    ButtonsOnRight) printf '%s' "$ours_right" ;;
  esac
}

# KConfig's change notification for kwinrc keys (what `kwriteconfig6
# --notify` sends: org.kde.kconfig.notify.ConfigChanged on /kwinrc, group →
# key names as byte arrays). kded's gtkconfig only re-reads the button order
# on it. Sent by hand so a deletion (above) notifies too.
notify() { # key...
  local keys_ay="" key bytes
  for key in "$@"; do
    bytes="$(printf '%s' "$key" | od -An -tx1 -v | tr -s ' \n' ' ' | sed 's/^ //; s/ $//; s/ /, 0x/g')"
    keys_ay="$keys_ay${keys_ay:+, }[byte 0x$bytes]"
  done
  gdbus emit --session --object-path /kwinrc --signal org.kde.kconfig.notify.ConfigChanged \
    "{'$group': [$keys_ay]}" > /dev/null 2>&1 || true
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

keys="library theme ButtonsOnLeft ButtonsOnRight"

case "${1:-}" in
  apply)
    if ! installed; then
      echo "loft-kwin-decoration: $ours is not installed (programs.loft.plasma in the NixOS config installs it); leaving KWin's decoration alone" >&2
      exit 0
    fi
    # A new run (Loft's decoration not selected) records everything afresh;
    # otherwise only keys the record lacks (a record from before Loft set
    # the buttons, or a crash that lost it).
    fresh=
    if [ "$(read_key library)" != "$ours" ]; then fresh=1; fi
    mkdir -p "$state"
    tmp="$record.tmp"
    if [ -n "$fresh" ] || [ ! -f "$record" ]; then
      : > "$tmp"
    else
      cp "$record" "$tmp"
    fi
    for key in $keys; do
      if [ -n "$fresh" ] || ! grep -q "^$key=" "$tmp"; then
        value="$(read_key "$key")"
        # Already Loft's but not recorded (a crash lost it): Plasma's
        # default is what revert should go back to.
        if [ -z "$fresh" ] && [ "$value" = "$(ours_for "$key")" ]; then
          value="$unset_marker"
        fi
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
      fi
    done
    mv "$tmp" "$record"
    for key in $keys; do
      write_key "$key" "$(ours_for "$key")"
    done
    notify ButtonsOnLeft ButtonsOnRight
    reconfigure
    ;;
  revert)
    if [ ! -f "$record" ]; then
      exit 0
    fi
    # Each key goes back only if it is still Loft's: a choice made in System
    # Settings while Loft ran wins. The theme follows the library.
    library_ours=
    if [ "$(read_key library)" = "$ours" ]; then library_ours=1; fi
    while IFS='=' read -r key value; do
      case "$key" in
        library | theme)
          if [ -n "$library_ours" ]; then write_key "$key" "$value"; fi
          ;;
        ButtonsOnLeft | ButtonsOnRight)
          if [ "$(read_effective "$key")" = "$(ours_for "$key")" ]; then write_key "$key" "$value"; fi
          ;;
      esac
    done < "$record"
    notify ButtonsOnLeft ButtonsOnRight
    reconfigure
    rm -f "$record"
    ;;
  status)
    echo "library: $(read_key library)"
    echo "buttons: $(read_effective ButtonsOnLeft) | $(read_effective ButtonsOnRight)"
    if [ -f "$record" ]; then echo "recorded: $record"; else echo "recorded: none"; fi
    ;;
  *)
    echo "usage: loft-kwin-decoration apply | revert | status" >&2
    exit 2
    ;;
esac
