# loft-launcher — runs the Spotlight launcher (walker + elephant).
#
#   loft-launcher service     prepare walker's config and run elephant + the walker service
#   loft-launcher [open]      open (or close) the launcher (!bangs: !nixpk ⏎ firefox, !yt lofi;
#                             quicklinks: yt lofi)
#   loft-launcher emoji       emoji / symbol picker (walker's symbols provider)
#   loft-launcher clipboard clipboard history
#   loft-launcher help        Spotlight's "?" help: every prefix with examples
#
# walker's config is rendered into $LOFT_STATE_DIR/launcher instead of
# ~/.config, so trying Loft never touches the user's own walker setup (a
# user ~/.config/walker/config.toml still takes precedence — XDG order).
# colors.css links to the active Loft theme's rendered walker.css, so a
# theme switch recolors the launcher on its next open.

# The launcher files: the packaged copy, or a checkout (loft-dev) for live edits.
src="${LOFT_LAUNCHER_DIR:-@LAUNCHER@}"
state_dir="${LOFT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/loft}"
dir="$state_dir/launcher"
theme_dir="$dir/walker/themes/loft"

prepare() {
  mkdir -p "$theme_dir"
  ln -sfn "$src/walker/themes/loft/style.css" "$theme_dir/style.css"
  ln -sfn "$src/walker/themes/loft/layout.xml" "$theme_dir/layout.xml"
  ln -sfn "$state_dir/current/walker.css" "$theme_dir/colors.css"
  # Top-level key first: appended after the tables it would land in the last one.
  {
    printf 'additional_theme_location = "%s"\n' "$dir/walker/themes"
    cat "$src/walker/config.toml"
  } > "$dir/walker/config.toml"

  # !bangs + Quicklinks: elephant's `bangs` provider (launcher/elephant-bangs).
  # Quicklinks, favorites and the default engine live in spotlight.json
  # (Settings → Spotlight; the provider re-reads it on change), seeded here.
  # A user ~/.config/elephant/bangs.toml still wins (XDG_CONFIG_HOME first).
  mkdir -p "$dir/elephant"
  rm -f "$dir/elephant/websearch.toml" # the pre-provider !bangs (13k websearch engines)
  if [ ! -e "$state_dir/spotlight.json" ]; then
    cp "$src/spotlight-defaults.json" "$state_dir/spotlight.json.tmp"
    chmod u+w "$state_dir/spotlight.json.tmp"
    mv "$state_dir/spotlight.json.tmp" "$state_dir/spotlight.json"
  fi
  shell="${LOFT_SHELL_SRC:-@SHELL@}"
  cat > "$dir/elephant/bangs.toml" <<EOF
data = "@BANGS@"
settings = "$state_dir/spotlight.json"
defaults = "$src/spotlight-defaults.json"
settings_cmd = "quickshell ipc --any-display --path '$shell' call settings spotlight"
EOF
  # Tests: open URLs with something else than xdg-open (e.g. a logger).
  if [ -n "${LOFT_LAUNCHER_OPEN:-}" ]; then
    printf 'command = "%s"\n' "$LOFT_LAUNCHER_OPEN" >> "$dir/elephant/bangs.toml"
  fi

  # Calculator (math, units, currencies, time zones) and Commands (system,
  # Settings pages, window actions, script commands, "?" help): elephant
  # providers too (launcher/elephant-calculator, launcher/elephant-commands).
  # qalc gets its own config dir, so the person's qalc settings stay theirs.
  cat > "$dir/elephant/calculator.toml" <<EOF
settings = "$state_dir/spotlight.json"
qalc_config = "$dir/qalc"
EOF
  scripts="${LOFT_SCRIPTS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/loft/scripts}"
  cat > "$dir/elephant/commands.toml" <<EOF
shell_ipc = "quickshell ipc --any-display --path '$shell' call"
shell_path = "$shell"
scripts = "$scripts"
builtin_scripts = "$src/scripts"
settings = "$state_dir/spotlight.json"
drives = "$state_dir/drives.json"
EOF
  # Tests (named loft-dev sessions): power / session / trash commands are
  # logged, never run.
  if [ -n "${LOFT_LAUNCHER_DRYRUN:-}" ]; then
    printf 'dry_run = "%s"\n' "$LOFT_LAUNCHER_DRYRUN" >> "$dir/elephant/commands.toml"
  fi
  # The calculator replaces elephant's calc (which downloads currency rates at
  # every start; ours only daily, when Settings → Spotlight allows it).
  # Recently used apps come first on an empty query.
  printf 'ignored_providers = ["calc"]\n' > "$dir/elephant/elephant.toml"
  printf 'history_when_empty = true\n' > "$dir/elephant/desktopapplications.toml"

  # Until the theme engine renders walker.css (PLAN §4.2), derive the colors
  # from the active theme.json so the launcher is themed today.
  if [ ! -e "$state_dir/current/walker.css" ] && [ -f "$state_dir/current/theme.json" ]; then
    jq -r -f "$src/walker-colors.jq" "$state_dir/current/theme.json" > "$dir/fallback-colors.css"
    ln -sfn "$dir/fallback-colors.css" "$theme_dir/colors.css"
  fi
}

# walker is a layer-shell surface: it must be a native Wayland client, even
# when the session exports GDK_BACKEND=x11 for some other app's sake.
export GDK_BACKEND=wayland

# Hand a command line to the running walker service over D-Bus (GApplication
# CommandLine, what the `walker` client sends): ~20 ms from the key to the
# window, where the walker client is a whole GTK start (50–270 ms) just to
# forward it. GApplication parses options in the client, so they travel as
# platform data. Fails (no service, or it hangs) → the caller decides.
#   ask [PROVIDER PLACEHOLDER]
ask() {
  local opts=""
  [ $# -eq 2 ] && opts="'options': <{'provider': <'$1'>, 'placeholder': <'$2'>}>"
  gdbus call --session --timeout 2 --dest dev.benz.walker --object-path /dev/benz/walker \
    --method org.gtk.Application.CommandLine /dev/benz/walker/loft "[b'walker']" "{$opts}" >/dev/null 2>&1
}

# The service isn't on the bus: it may be starting (a deploy restarts it),
# so wait for its name a moment and ask again. Only when it never comes does
# walker start by itself — a cold start (a whole GTK start, then elephant's),
# said in the journal. Never while the service is there: a walker started
# then would take the service's D-Bus name, and the service would fail.
#   ask_or_start [PROVIDER PLACEHOLDER] -- WALKER ARGS…
ask_or_start() {
  local ask_args=()
  while [ "$1" != -- ]; do ask_args+=("$1"); shift; done
  shift
  ask "${ask_args[@]}" && return
  if gdbus wait --session --timeout "${LOFT_LAUNCHER_WAIT:-5}" dev.benz.walker 2>/dev/null; then
    ask "${ask_args[@]}" && return
    echo "loft-launcher: walker's service is on the bus but doesn't answer; not starting a second walker" >&2
    return 1
  fi
  echo "loft-launcher: walker's service isn't running (is loft-launcher service up?); starting walker cold" >&2
  exec walker "$@"
}

case "${1:-open}" in
  service)
    prepare
    export XDG_CONFIG_DIRS="$dir${XDG_CONFIG_DIRS:+:$XDG_CONFIG_DIRS}"
    # A socket left by an elephant that was killed would have walker connect
    # to nothing until the new one listens.
    rm -f "${XDG_RUNTIME_DIR:-/tmp}/elephant/elephant.sock"
    elephant &
    elephant_pid=$!
    trap 'kill $elephant_pid 2>/dev/null' EXIT INT TERM
    # walker right away, not after elephant (which takes a second or two to
    # load its providers): its D-Bus name is up at once, so a key pressed
    # meanwhile reaches the service instead of starting a cold walker. The
    # service connects to elephant when its socket appears, and builds its
    # window hidden (launcher/walker-instant.patch), so the first open is as
    # quick as the next.
    # gtk4-layer-shell must load before libwayland-client, or walker silently
    # falls back to a normal (tiled) window; nixpkgs' wrapper doesn't preload it.
    LD_PRELOAD="@LAYERSHELL@${LD_PRELOAD:+:$LD_PRELOAD}" walker --gapplication-service
    ;;
  open)
    ask_or_start --
    ;;
  emoji)
    ask_or_start symbols "Emoji & Symbols" -- --provider symbols --placeholder "Emoji & Symbols"
    ;;
  clipboard)
    ask_or_start clipboard "Clipboard History" -- --provider clipboard --placeholder "Clipboard History"
    ;;
  help)
    ask_or_start commands "Spotlight Help" -- --provider commands --placeholder "Spotlight Help"
    ;;
  *)
    echo "usage: loft-launcher [service|open|emoji|clipboard|help]" >&2
    exit 2
    ;;
esac
