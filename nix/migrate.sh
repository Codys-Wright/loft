# loft-migrate — the one-time move from studio-linux (Loft's old name).
# Packaged by nix/packages.nix (writeShellApplication: bash, `set -euo
# pipefail`, shellcheck). Run by the home-manager activation and by
# loft-session / loft-shell on start, so it must be cheap and idempotent.
#
#   loft-migrate          state, data and cache: for each of
#                         $XDG_STATE_HOME, $XDG_DATA_HOME, $XDG_CACHE_HOME,
#                         <base>/studio-linux → <base>/loft
#   loft-migrate config   $XDG_CONFIG_HOME/studio-linux → loft, as a link only
#                         (home-manager writes the files under loft/ itself)
#
# A real directory is moved (a rename: nothing is copied); a symlink is
# recreated at the new path with the same target. The old path is left as a
# symlink to the new one, so anything still pointing there (a kitty/Ghostty/
# GTK include, a running old shell) keeps working. After moving the state
# dir, absolute paths into it are rewritten: the `current` symlink and text
# files (overrides/*.json, caches, the launcher's generated config).
#
# When both paths already exist they are left alone (reported) — never
# merged, never deleted. DRY_RUN=1 only prints what would be done.

dry="${DRY_RUN:-}"
say() { echo "loft-migrate: $*" >&2; }
act() {
  if [ -n "$dry" ]; then say "would run: $*"; else "$@"; fi
}

state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"

exists() { [ -e "$1" ] || [ -L "$1" ]; }

# A new dir holding nothing but unit hashes (written by an earlier activation
# before anything was moved) is not data: it may make way for the old one.
only_unit_hashes() {
  local f
  for f in "$1"/* "$1"/.[!.]*; do
    exists "$f" || continue
    case "$f" in
      *.unit-hash) [ -f "$f" ] && [ ! -L "$f" ] || return 1 ;;
      *) return 1 ;;
    esac
  done
}

# The compat link this script leaves behind (relative or absolute).
is_compat_link() {
  [ -L "$1" ] || return 1
  local t
  t="$(readlink "$1")"
  [ "$t" = loft ] || [ "$t" = "$2" ]
}

# migrate BASE: BASE/studio-linux → BASE/loft. Prints "moved" when it did.
migrate() {
  local old="$1/studio-linux" new="$1/loft" target f
  exists "$old" || return 0
  is_compat_link "$old" "$new" && return 0
  if exists "$new"; then
    if [ -d "$new" ] && [ ! -L "$new" ] && only_unit_hashes "$new"; then
      for f in "$new"/*.unit-hash; do
        [ -e "$f" ] && act rm -f "$f"
      done
      act rmdir "$new"
    else
      say "both $old and $new exist; leaving them alone (merge them by hand)"
      return 0
    fi
  fi
  if [ -L "$old" ]; then
    # e.g. ~/.local/share/studio-linux → a library elsewhere: same target.
    target="$(readlink "$old")"
    act ln -s "$target" "$new"
    act rm "$old" # the symlink only
  else
    act mv "$old" "$new"
  fi
  act ln -s loft "$old"
  if [ -n "$dry" ]; then
    say "would move $old → $new"
  else
    say "moved $old → $new ($old links to it)"
  fi
  echo moved
}

# sed-quote a literal for the pattern / the replacement side (delimiter #).
re_quote() { printf '%s' "$1" | sed 's/[]\\.*^$[#]/\\&/g'; }
rep_quote() { printf '%s' "$1" | sed 's/[\\&#]/\\&/g'; }

# Absolute paths into the old state dir → the new one.
fix_state() {
  local old="$1" new="$2" link f pat rep
  [ -d "$new" ] || return 0
  link="$(readlink "$new/current" 2>/dev/null || true)"
  case "$link" in
    "$old"/*) act ln -sfn "$new/${link#"$old"/}" "$new/current" ;;
  esac
  pat="$(re_quote "$old")"
  rep="$(rep_quote "$new")"
  # -r (not -R): symlinks inside the state dir are not followed; -I: text only.
  { grep -rlIF -- "$old" "$new/" 2>/dev/null || true; } | while IFS= read -r f; do
    [ -L "$f" ] && continue
    act sed -i -e "s#$pat\\([/\"' ]\\)#$rep\\1#g" -e "s#$pat\$#$rep#" "$f"
  done
}

case "${1:-}" in
  "")
    old_state="$state_home/studio-linux"
    new_state="$state_home/loft"
    moved="$(migrate "$state_home")"
    # Also when an earlier run moved the dir but stopped before this.
    if [ -n "$moved" ] || case "$(readlink "$new_state/current" 2>/dev/null || true)" in "$old_state"/*) true ;; *) false ;; esac; then
      fix_state "$old_state" "$new_state"
    fi
    migrate "$data_home" >/dev/null
    migrate "$cache_home" >/dev/null
    ;;
  config)
    # home-manager removed its old files (and the then-empty dir) already.
    old="$config_home/studio-linux"
    if ! exists "$old" && [ -d "$config_home/loft" ]; then
      act ln -s loft "$old"
      say "linked $old → loft"
    fi
    ;;
  *)
    echo "usage: loft-migrate [config]" >&2
    exit 2
    ;;
esac
