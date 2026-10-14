# studio-launcher — runs the Spotlight launcher (walker + elephant).
#
#   studio-launcher service   prepare walker's config and run elephant + the walker service
#   studio-launcher [open]    open (or close) the launcher
#   studio-launcher emoji     emoji / symbol picker (walker's symbols provider)
#   studio-launcher clipboard clipboard history
#
# walker's config is rendered into $STUDIO_STATE_DIR/launcher instead of
# ~/.config, so trying studio never touches the user's own walker setup (a
# user ~/.config/walker/config.toml still takes precedence — XDG order).
# colors.css links to the active studio theme's rendered walker.css, so a
# theme switch recolors the launcher on its next open.

# The launcher files: the packaged copy, or a checkout (studio-dev) for live edits.
src="${STUDIO_LAUNCHER_DIR:-@LAUNCHER@}"
state_dir="${STUDIO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/studio-linux}"
dir="$state_dir/launcher"
theme_dir="$dir/walker/themes/studio"

prepare() {
  mkdir -p "$theme_dir"
  ln -sfn "$src/walker/themes/studio/style.css" "$theme_dir/style.css"
  ln -sfn "$src/walker/themes/studio/layout.xml" "$theme_dir/layout.xml"
  ln -sfn "$state_dir/current/walker.css" "$theme_dir/colors.css"
  # Top-level key first: appended after the tables it would land in the last one.
  {
    printf 'additional_theme_location = "%s"\n' "$dir/walker/themes"
    cat "$src/walker/config.toml"
  } > "$dir/walker/config.toml"

  # Until the theme engine renders walker.css (PLAN §4.2), derive the colors
  # from the active theme.json so the launcher is themed today.
  if [ ! -e "$state_dir/current/walker.css" ] && [ -f "$state_dir/current/theme.json" ]; then
    jq -r -f "$src/walker-colors.jq" "$state_dir/current/theme.json" > "$dir/fallback-colors.css"
    ln -sfn "$dir/fallback-colors.css" "$theme_dir/colors.css"
  fi
}

case "${1:-open}" in
  service)
    prepare
    export XDG_CONFIG_DIRS="$dir${XDG_CONFIG_DIRS:+:$XDG_CONFIG_DIRS}"
    elephant &
    elephant_pid=$!
    trap 'kill $elephant_pid 2>/dev/null' EXIT INT TERM
    # Give elephant a moment to open its socket before walker connects.
    for _ in $(seq 1 50); do
      [ -S "${XDG_RUNTIME_DIR:-/tmp}/elephant/elephant.sock" ] && break
      sleep 0.1
    done
    # gtk4-layer-shell must load before libwayland-client, or walker silently
    # falls back to a normal (tiled) window; nixpkgs' wrapper doesn't preload it.
    LD_PRELOAD="@LAYERSHELL@${LD_PRELOAD:+:$LD_PRELOAD}" walker --gapplication-service
    ;;
  open)
    exec walker
    ;;
  emoji)
    exec walker --provider symbols --placeholder "Emoji & Symbols"
    ;;
  clipboard)
    exec walker --provider clipboard --placeholder "Clipboard History"
    ;;
  *)
    echo "usage: studio-launcher [service|open|emoji|clipboard]" >&2
    exit 2
    ;;
esac
