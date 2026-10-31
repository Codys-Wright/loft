# loft-live — run Loft from a checkout on the real desktop, in place of the
# installed one. Packaged by nix/packages.nix (writeShellApplication: bash,
# `set -euo pipefail`, shellcheck); @NAME@ placeholders are substituted there.
#
#   loft-live [start] [--niri] [CHECKOUT]   take over: the installed shell and
#                                          launcher stop, the checkout's run
#                                          on this niri with hot reload
#   loft-live stop [--niri]                hand back to the installed Loft
#   loft-live status
#
# Unlike `loft-dev` (a nested niri with its own state), this is the desktop
# you work in: the same niri, state, settings, theme and windows. While it
# runs, $XDG_RUNTIME_DIR/loft-live/active exists; the installed loft-shell /
# loft-launcher units don't start while it does (ConditionPathExists in
# programs.loft), so a home-manager switch or a crash restart can't bring them
# back underneath. The live shell's unit removes it when it stops (also when
# the session ends), so a reboot or a new login is always the installed Loft.
#
# What hot-reloads: QML (src/), the checkout's niri fragments (shell binds,
# title-bar.kdl, workspace-wallpapers.kdl — through the optional include
# of <state>/dev/niri.kdl in loft/niri.kdl), themes/templates (`loft` is the
# checkout's CLI for the shell), launcher theme. The compositor itself can't
# be swapped under a running session: --niri builds the checkout's niri-loft
# into <state>/dev/niri, which the session's niri (package niri-loft-live)
# runs from the next login on; `stop --niri` removes it again.

usage() {
  cat >&2 <<'EOF'
usage: loft-live [start] [--niri] [CHECKOUT]
       loft-live stop [--niri]
       loft-live status
EOF
  exit 2
}

action=start
niri=0
root=""
case "${1:-}" in
  start | stop | status) action="$1"; shift ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --niri) niri=1; shift ;;
    -h | --help) usage ;;
    -*) echo "loft-live: unknown option $1" >&2; usage ;;
    *) root="$1"; shift ;;
  esac
done

rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
live="$rt/loft-live"
state="${LOFT_LIVE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/loft}"
dev="$state/dev"
installed_units=(loft-shell.service loft-launcher.service)
live_units=(loft-live-shell.service loft-live-launcher.service)

say() { echo "loft-live: $*"; }
env_get() { sed -n "s/^$1=//p" "$live/active" 2>/dev/null | head -n1; }
is_active() { [ -f "$live/active" ]; }

# The running compositor's features, from its version string ("…, loft:
# workspace-layers, title-bar"). Builds from before the title bar say
# "traffic-lights" and reject title-bar.kdl.
# The compositor's line only: the CLI on PATH (this package's niri-loft) can
# be newer than the running niri, and its line made a niri without the
# title bar include title-bar.kdl and reject the whole config.
niri_has() { niri msg version 2>/dev/null | grep "^Compositor" | grep -q "loft:.*$1"; }

build_niri() {
  [ -n "$root" ] || root="$(env_get CHECKOUT)"
  root="$(realpath "${root:-$PWD}")"
  mkdir -p "$dev"
  say "building niri-loft from $root (niri's tests run too) …"
  nix build "$root#niri-loft" --out-link "$dev/niri"
  say "next login runs $(readlink -f "$dev/niri")/bin/niri, if the session's niri is the"
  say "niri-loft-live package (programs.niri.package); \`loft-live stop --niri\` goes back"
}

status() {
  if is_active; then
    say "live from $(env_get CHECKOUT) since $(env_get STARTED)"
  else
    say "not active: the installed Loft runs"
  fi
  for u in "${installed_units[@]}" "${live_units[@]}"; do
    printf '  %-28s %s\n' "$u" "$(systemctl --user is-active "$u" 2>/dev/null || true)"
  done
  if [ -L "$dev/niri" ]; then
    say "next login's niri: $(readlink -f "$dev/niri")"
  fi
  say "running niri: $(niri msg version 2>/dev/null | head -n1 | sed 's/^Compositor version: *//')"
}

stop() {
  if [ "$niri" = 1 ]; then
    rm -f "$dev/niri"
    say "next login runs the installed niri again"
  fi
  if ! is_active; then
    [ "$niri" = 1 ] || say "not active"
    return 0
  fi
  systemctl --user stop "${live_units[@]}" 2>/dev/null || true
  # niri drops the checkout's fragments (the include is optional).
  rm -f "$dev/niri.kdl"
  rm -f "$live/active"
  # The installed CLI renders the theme with its own templates again.
  theme="$(LOFT_STATE_DIR="$state" loft theme current 2>/dev/null || true)"
  if [ -n "$theme" ]; then
    LOFT_STATE_DIR="$state" LOFT_HOOKS=none loft theme apply "$theme" >/dev/null 2>&1 \
      || say "re-rendering the theme with the installed loft failed; \`loft theme apply\` fixes it"
  fi
  systemctl --user start "${installed_units[@]}" || true
  say "handed back to the installed Loft"
}

start() {
  if [ -z "${NIRI_SOCKET:-}" ] || ! niri msg version >/dev/null 2>&1; then
    echo "loft-live: needs the real niri session (NIRI_SOCKET); for a window, use loft-dev" >&2
    exit 1
  fi
  if [ -n "${LOFT_SESSION:-}" ]; then
    echo "loft-live: inside the loft-dev session $LOFT_SESSION; run it from the real desktop" >&2
    exit 1
  fi
  root="$(realpath "${root:-$PWD}")"
  if [ ! -f "$root/src/shell.qml" ] || [ ! -f "$root/niri/shell-binds.kdl.in" ]; then
    echo "loft-live: $root is not a Loft checkout (pass its path, or run from inside it)" >&2
    exit 1
  fi
  if ! grep -qF "$dev/niri.kdl" "${XDG_CONFIG_HOME:-$HOME/.config}/loft/niri.kdl" 2>/dev/null; then
    say "warning: loft/niri.kdl doesn't include $dev/niri.kdl (programs.loft from before"
    say "loft-live): the checkout's QML runs, but its niri fragments and binds don't"
  fi

  mkdir -p "$live" "$dev"
  chmod 700 "$live"

  # The installed shell's environment (state dir, library, icon theme, …),
  # then what makes it the checkout's.
  unit_env=()
  read -r -a unit_env <<< "$(systemctl --user show loft-shell.service -p Environment --value 2>/dev/null || true)"
  [ ${#unit_env[@]} -gt 0 ] || unit_env=("LOFT_STATE_DIR=$state")

  # `loft` for the shell: the checkout's CLI (its renderers and templates).
  mkdir -p "$live/bin"
  printf '#!/bin/sh\nexec %s -B "%s" "$@"\n' "@PYTHON@" "$root/cli/loft" > "$live/bin/loft"
  chmod +x "$live/bin/loft"
  path="$live/bin:$PATH"
  [ -d "$root/target/debug" ] && path="$root/target/debug:$path"

  # No LOFT_DEV: that marks an isolated test session (loft-dev), and turns
  # on test hooks — the lock screen's unlock-without-password among them —
  # and test-only hook sets. This is the real desktop: it runs as installed,
  # from the checkout.
  loft_env=(
    "LOFT_STATE_DIR=$state"
    "LOFT_DATA_DIR=$root"
    "LOFT_THEME_PATH=${XDG_DATA_HOME:-$HOME/.local/share}/loft/themes:$root/themes"
    "LOFT_SHELL_PATH=$root/src"
    "LOFT_SHELL_SRC=$root/src"
  )

  # A previous live run first (stopping its shell removes the marker), then
  # mark: from here on the installed units refuse to start.
  systemctl --user stop "${live_units[@]}" 2>/dev/null || true
  systemctl --user reset-failed "${live_units[@]}" 2>/dev/null || true
  {
    printf 'CHECKOUT=%s\nSTARTED=%s\n' "$root" "$(date -Iseconds)"
  } > "$live/active"
  systemctl --user stop "${installed_units[@]}" 2>/dev/null || true

  # The theme, rendered by the checkout's templates.
  # (By name: `current` is a rendered composition, not a pack.)
  theme="$(env "${loft_env[@]}" PATH="$path" loft theme current 2>/dev/null || true)"
  if [ -n "$theme" ]; then
    env "${loft_env[@]}" PATH="$path" LOFT_HOOKS=none loft theme apply "$theme" >/dev/null 2>&1 \
      || say "warning: rendering the theme with the checkout's templates failed"
  fi

  # The checkout's niri fragments, after the installed ones (later wins).
  # quickshell by absolute path: niri spawns with its own PATH, which
  # doesn't have it (a bare name made every shell keybind do nothing).
  qs="$(command -v quickshell)"
  sed "s|@IPC@|\"$qs\" \"ipc\" \"--path\" \"$root/src\" \"call\"|g" \
    "$root/niri/shell-binds.kdl.in" > "$live/shell-binds.kdl"
  {
    echo "// loft-live: $root over the installed Loft. Removed by \`loft-live stop\`."
    echo "include \"$live/shell-binds.kdl\""
    if niri_has workspace-layers && [ -f "$root/niri/workspace-wallpapers.kdl" ]; then
      echo "include \"$root/niri/workspace-wallpapers.kdl\""
    fi
    if niri_has title-bar && [ -f "$root/niri/title-bar.kdl" ]; then
      echo "include \"$root/niri/title-bar.kdl\""
      # The theme's bar colors over the checkout's fallback.
      echo "include optional=true \"$state/current/niri-loft.kdl\""
    fi
    [ -f "$root/niri/dev-local.kdl" ] && echo "include \"$root/niri/dev-local.kdl\""
  } > "$dev/niri.kdl"
  if [ -f "$root/niri/title-bar.kdl" ] && ! niri_has title-bar; then
    say "the running niri has no title bar; \`loft-live --niri\` builds one for the next login"
  fi

  setenv=()
  for e in "${unit_env[@]}" "${loft_env[@]}" "PATH=$path" "QS_DISABLE_CRASH_HANDLER=1" \
    "LOFT_UI_FONT=@UI_FONT@" "LOFT_ICON_FONT=@ICON_FONT@" \
    "QML_IMPORT_PATH=@LOCK_QML_PATH@" "QT_PLUGIN_PATH=@QT_MM_PLUGINS@" \
    "QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi" "LOFT_QT_VAAPI_ZERO_COPY=1" "NVD_MAX_DETACHED_BACKING_IMAGES=0"; do
    setenv+=("--setenv=$e")
  done
  for e in WAYLAND_DISPLAY NIRI_SOCKET DISPLAY XDG_CURRENT_DESKTOP; do
    [ -n "${!e:-}" ] && setenv+=("--setenv=$e=${!e}")
  done

  common=(--user --collect --quiet -p Restart=on-failure -p RestartSec=2
    -p PartOf=graphical-session.target)
  # The marker goes with the live shell: when the session ends (PartOf) —
  # the runtime dir outlives a logout when the user lingers — the next login
  # starts the installed Loft.
  systemd-run "${common[@]}" --unit=loft-live-shell --description="Loft shell (live from $root)" \
    -p "ExecStopPost=rm -f $live/active" \
    "${setenv[@]}" quickshell --path "$root/src"
  systemd-run "${common[@]}" --unit=loft-live-launcher --description="Loft launcher (live from $root)" \
    "${setenv[@]}" "--setenv=LOFT_LAUNCHER_DIR=$root/launcher" loft-launcher service

  say "live from $root: the installed shell and launcher are stopped"
  say "logs: journalctl --user -fu loft-live-shell   back: loft-live stop"
}

case "$action" in
  status) status ;;
  stop) stop ;;
  start)
    if [ "$niri" = 1 ]; then build_niri; fi
    start
    ;;
esac
