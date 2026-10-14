# studio — studio-linux CLI (first slice: theme list/current/apply).
#
# Environment (all optional):
#   STUDIO_STATE_DIR   holds `current` → active theme dir   (default: $XDG_STATE_HOME/studio-linux)
#   STUDIO_THEME_PATH  colon-separated dirs of theme packs  (default: user themes, then built-ins)
#   STUDIO_SHELL_PATH  Quickshell config of the running shell, for IPC (default: the packaged shell)
#
# `studio --dev …` targets the session started by `nix run .#dev` instead.

usage() {
  cat >&2 <<EOF
usage: studio [--dev] theme list
       studio [--dev] theme current
       studio [--dev] theme apply <name|path>
EOF
  exit 2
}

if [ "${1-}" = "--dev" ]; then
  shift
  env_file="${XDG_RUNTIME_DIR:-/tmp}/studio-dev/session.env"
  [ -f "$env_file" ] || { echo "studio: no studio-dev session running" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$env_file"
fi

state_dir="${STUDIO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/studio-linux}"
theme_path="${STUDIO_THEME_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/studio-linux/themes:@BUILTIN_THEMES@}"
shell_path="${STUDIO_SHELL_PATH:-@SHELL_SRC@}"

# Tell the running shell to re-resolve the theme. Not an error if no shell
# is running: it reads `current` when it starts.
notify_shell() {
  quickshell ipc --any-display --path "$shell_path" call theme reload >/dev/null 2>&1 || true
}

find_theme() {
  local name="$1" dir
  if [ -f "$name/theme.json" ]; then
    realpath "$name"
    return
  fi
  IFS=: read -r -a dirs <<<"$theme_path"
  for dir in "${dirs[@]}"; do
    if [ -f "$dir/$name/theme.json" ]; then
      realpath "$dir/$name"
      return
    fi
  done
  return 1
}

[ "${1-}" = "theme" ] || usage
shift

case "${1-}" in
  list)
    IFS=: read -r -a dirs <<<"$theme_path"
    for dir in "${dirs[@]}"; do
      [ -d "$dir" ] || continue
      for t in "$dir"/*/theme.json; do
        d="$(dirname "$t")"
        # `default` is an alias (symlink) for one of the real themes.
        [ -f "$t" ] && [ ! -L "$d" ] && basename "$d"
      done
    done | sort -u
    ;;
  current)
    if [ -L "$state_dir/current" ]; then
      basename "$(readlink "$state_dir/current")"
    else
      echo "(none — the shell uses its built-in default)"
    fi
    ;;
  apply)
    [ $# -eq 2 ] || usage
    target="$(find_theme "$2")" || { echo "studio: no theme '$2' in $theme_path" >&2; exit 1; }
    mkdir -p "$state_dir"
    ln -sfn "$target" "$state_dir/current"
    notify_shell
    echo "studio: applied $(basename "$target")"
    ;;
  *) usage ;;
esac
