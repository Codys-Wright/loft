# loft-dev — run Loft from a checkout in a nested niri, with hot
# reload. Packaged by nix/packages.nix (writeShellApplication: bash,
# `set -euo pipefail`, shellcheck); @NAME@ placeholders are substituted there.
#
#   loft-dev [CHECKOUT]                      the dev session (`dev`), a window on
#                                            your desktop: on a niri host
#                                            fullscreen on the rightmost monitor,
#                                            on KDE likewise via KWin
#   loft-dev --session NAME [--size WxH]     a named test session: headless
#                                            (an offscreen output of exactly
#                                            WxH), its own runtime dir, D-Bus
#                                            and state — for agents
#   loft-dev --session NAME --outputs WxH,WxH,…   the same with several
#                                            monitors (niri on virtual outputs)
#   loft-dev --session NAME --compositor kwin [--shell loft|plasma]
#                                            a KDE session instead: KWin
#                                            nested in the headless host, its
#                                            own bus, runtime dir and $HOME,
#                                            all in one systemd user unit
#   loft-dev --list | --stop NAME
#   loft-dev live [stop|status] [--niri]    the checkout on the real desktop
#                                            instead (loft-live, nix/dev/loft-live.sh)
#
# Each session lives in $XDG_RUNTIME_DIR/loft-dev (dev) or
# $XDG_RUNTIME_DIR/loft-dev-NAME, with a session.env saying how to reach it
# (loft-input, loft-shot and `loft --dev` read it). Starting a session
# replaces only that session's previous niri.

usage() {
  cat >&2 <<'EOF'
usage: loft-dev [--session NAME] [--size WxH | --outputs WxH[+X+Y],…] [--headless | --gpu | --on-host]
                [--output NAME | --windowed]
                [--isolated | --shared | --private-bus | --private-runtime]
                [--share-audio] [--stock-wallpapers] [CHECKOUT]
       loft-dev --session NAME --compositor kwin [--shell loft|plasma] [--size WxH]
                [--output-count N] [--keep-home] [--kwin-scale S] [--kwin-env NAME=VALUE]… [CHECKOUT]
       loft-dev --list
       loft-dev --stop NAME

  --session NAME     a named session (default `dev`); a session only ever
                     replaces itself, so parallel agents use distinct names
  --size WxH         the session's size (named sessions: default 1600x1000)
  --outputs LIST     several monitors instead of one, e.g.
                     1440x2560,5120x1440,2560x1440 (left to right) or with
                     positions 5120x1440+1440+0,1440x2560+0+0,… — niri runs on
                     virtual outputs headless-1, headless-2, … (in this order;
                     identities "niri headless 1", …). Headless only.
                     `niri msg output headless-2 off|on` unplugs / replugs one.
  --headless         run on an offscreen output (a headless wlroots host,
                     software rendering): exact size, never on screen, works
                     while the desktop is locked — the default for named sessions
  --gpu              headless, but rendered on the GPU (the host sway on
                     the first GPU render node, gles2; niri and the shell on
                     its EGL): for measuring GPU paths such as video
                     wallpapers (VAAPI zero-copy). Still offscreen and
                     isolated. LOFT_DEV_RENDER_NODE picks the node.
  --on-host          a window on this desktop instead (on niri: floating at
                     --size; the dev session: fullscreen on --output or the
                     rightmost monitor) — the default for `dev`
  --output NAME      the monitor for the fullscreen dev window
  --windowed         leave the window where the host puts it
  --isolated         own D-Bus (no service activation) + own XDG_RUNTIME_DIR
                     (launcher, clipboard, IPC sockets don't meet the live
                     desktop's) — the default for named sessions
  --shared           the host's bus and runtime dir — the default for `dev`
  --private-bus      only the own D-Bus;  --private-runtime: only the runtime dir
  --share-audio      isolated sessions: reach the host's PipeWire/Pulse (off by
                     default, so a test never changes the real volume or routing)
  --stock-wallpapers without per-workspace wallpaper surfaces: nested sessions
                     run stock niri, --outputs leaves the layer rule out (the
                     shell then swaps one wallpaper per screen, as on stock
                     niri). By default sessions run niri-loft
                     (nix/niri/workspace-layers.patch) with
                     niri/workspace-wallpapers.kdl included.

KDE sessions (--compositor kwin): KWin 6 from the system nested in a headless
GPU host (implies --gpu: KWin needs compositing), a private D-Bus with service
activation, a private XDG_RUNTIME_DIR and a scratch HOME + XDG dirs in the
session dir, so KDE's config writes never reach the real ~/.config. The whole
session (KWin, kded, Akonadi, portals, FUSE mounts) runs in the user unit
loft-dev-kwin-NAME; `loft-dev --stop NAME` stops all of it.
  --compositor niri|kwin   niri (default) or a KDE session
  --shell loft|plasma      kwin: the checkout's shell (hot reload, default) or
                           stock plasmashell
  --output-count N         kwin: N outputs of --size side by side (WL-0, WL-1, …)
  --keep-home              kwin: keep the scratch HOME from the last run
                           (default: a fresh one each start)
  --kwin-scale S           kwin: the outputs' scale (e.g. 1.25, 1.5), for
                           fractional-scaling tests: the host output is
                           scaled, KWin follows it; --size stays device px
  --kwin-env NAME=VALUE    kwin: extra environment for the whole session
                           (repeatable), e.g. a build's plugins first:
                           QT_PLUGIN_PATH=$PWD/result/lib/qt-6/plugins:$QT_PLUGIN_PATH
EOF
  exit 2
}

# `loft-dev live …` is loft-live: the checkout on the real desktop.
if [ "${1:-}" = live ]; then
  shift
  exec loft-live "$@"
fi

session=dev
size=""
outputs=""
output=""
windowed=0
root=""
bus=""
runtime=""
headless=""
gpu=0
audio=0
ws_layers=1
compositor=niri
kshell=loft
output_count=1
keep_home=0
kwin_env=()
kwin_scale=1
action=run
stop_name=""
orig_args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ $# -ge 2 ] || usage; session="$2"; shift 2 ;;
    --size) [ $# -ge 2 ] || usage; size="$2"; shift 2 ;;
    --outputs) [ $# -ge 2 ] || usage; outputs="$2"; shift 2 ;;
    --output) [ $# -ge 2 ] || usage; output="$2"; shift 2 ;;
    --windowed) windowed=1; shift ;;
    --headless) headless=1; shift ;;
    --gpu) headless=1; gpu=1; shift ;;
    --on-host) headless=0; shift ;;
    --isolated) bus=1; runtime=1; shift ;;
    --shared) bus=0; runtime=0; shift ;;
    --private-bus) bus=1; shift ;;
    --private-runtime) runtime=1; shift ;;
    --share-audio) audio=1; shift ;;
    --stock-wallpapers) ws_layers=0; shift ;;
    --compositor) [ $# -ge 2 ] || usage; compositor="$2"; shift 2 ;;
    --shell) [ $# -ge 2 ] || usage; kshell="$2"; shift 2 ;;
    --output-count) [ $# -ge 2 ] || usage; output_count="$2"; shift 2 ;;
    --keep-home) keep_home=1; shift ;;
    --kwin-scale) [ $# -ge 2 ] || usage; kwin_scale="$2"; shift 2 ;;
    --kwin-env)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "loft-dev: --kwin-env wants NAME=VALUE" >&2; exit 2; }
      kwin_env+=("--setenv=$2"); shift 2 ;;
    --list) action=list; shift ;;
    --stop) [ $# -ge 2 ] || usage; action=stop; stop_name="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "loft-dev: unknown option $1" >&2; usage ;;
    *) root="$1"; shift ;;
  esac
done

# The user's real runtime dir, even inside an isolated session.
rt="${LOFT_DEV_HOST_RUNTIME:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}}"

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$ ]]; }
session_dir() {
  if [ "$1" = dev ]; then echo "$rt/loft-dev"; else echo "$rt/loft-dev-$1"; fi
}
env_get() { sed -n "s/^$2=//p" "$1/session.env" 2>/dev/null | head -n1; }

# FUSE mounts a KDE session's D-Bus-activated helpers left in its runtime
# dir (the document portal, gvfs): their auto-unmount helper dies with the
# unit's cgroup, so they can outlive it, stale. Lazily unmount what is
# still there.
unmount_session_fuse() {
  local fm m
  fm="$(command -v fusermount3 || command -v fusermount || true)"
  [ -n "$fm" ] || return 0
  while read -r m; do
    case "$m" in "$1"/run/*) "$fm" -uz "$m" 2>/dev/null || true ;; esac
  done < <(findmnt -rn -o TARGET 2>/dev/null || true)
}

# The niri recorded in DIR's session.env, if it is still running and ours
# (its command line names DIR's config). Never another session's process.
session_pid() {
  local dir="$1" pid
  [ -f "$dir/session.env" ] || return 1
  pid="$(env_get "$dir" NIRI_PID)"
  [ -n "$pid" ] || pid="$(sed -n 's/^NIRI_SOCKET=.*\.\([0-9]*\)\.sock$/\1/p' "$dir/session.env")"
  [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qF "$dir/config.kdl" || return 1
  echo "$pid"
}

# Helpers the session's shell started (nmcli monitor, inotifywait, `loft island
# downloads --watch`, …) can outlive niri: end every process of this user whose
# environment points at this session's state dir.
reap_session_procs() {
  local dir="$1" p
  for p in /proc/[0-9]*; do
    [ -O "$p" ] || continue
    { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qxF "LOFT_STATE_DIR=$dir" || continue
    kill "${p#/proc/}" 2>/dev/null || true
  done
}

stop_session() {
  local dir="$1" pid
  if pid="$(session_pid "$dir")"; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 25); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    echo "$pid"
  fi
  reap_session_procs "$dir"
  return 0
}

case "$action" in
  list)
    printf '%-14s %-8s %-9s %-8s %-10s %s\n' SESSION STATE MODE NIRI SIZE WAYLAND_DISPLAY
    for d in "$rt/loft-dev" "$rt"/loft-dev-*; do
      [ -f "$d/session.env" ] || continue
      name="$(basename "$d")"; name="${name#loft-dev-}"; [ "$name" = loft-dev ] && name=dev
      if [ "$(env_get "$d" LOFT_DEV_COMPOSITOR)" = kwin ]; then
        unit="$(env_get "$d" LOFT_DEV_UNIT)"
        if [ -n "$unit" ] && systemctl --user is-active --quiet "$unit"; then
          printf '%-14s %-8s %-9s %-8s %-10s %s\n' "$name" running "$(env_get "$d" LOFT_DEV_MODE)" "kwin $(env_get "$d" KWIN_PID)" \
            "$(env_get "$d" LOFT_DEV_SIZE)x$(env_get "$d" LOFT_DEV_OUTPUT_COUNT)" "$(env_get "$d" WAYLAND_DISPLAY)"
        else
          printf '%-14s %-8s %-9s %-8s %-10s %s\n' "$name" stopped - - - -
        fi
        continue
      fi
      if pid="$(session_pid "$d")"; then
        sz="$(NIRI_SOCKET="$(env_get "$d" NIRI_SOCKET)" timeout 2 niri msg -j outputs 2>/dev/null \
          | jq -r '[.[] | select(.logical) | "\(.logical.width)x\(.logical.height)"] | join(",")' || true)"
        printf '%-14s %-8s %-9s %-8s %-10s %s\n' "$name" running "$(env_get "$d" LOFT_DEV_MODE)" "$pid" "${sz:-?}" "$(env_get "$d" WAYLAND_DISPLAY)"
      else
        printf '%-14s %-8s %-9s %-8s %-10s %s\n' "$name" stopped - - - -
      fi
    done
    exit 0
    ;;
  stop)
    valid_name "$stop_name" || { echo "loft-dev: bad session name $stop_name" >&2; exit 2; }
    d="$(session_dir "$stop_name")"
    unit="loft-dev-kwin-$stop_name.service"
    if systemctl --user is-active --quiet "$unit" || systemctl --user is-failed --quiet "$unit"; then
      systemctl --user stop "$unit" 2>/dev/null || true
      systemctl --user reset-failed "$unit" 2>/dev/null || true
      unmount_session_fuse "$d"
      rm -f "$d/session.env"
      echo "loft-dev: stopped $stop_name (unit $unit)"
      exit 0
    fi
    pid="$(stop_session "$d")"
    rm -f "$d/session.env"
    if [ -n "$pid" ]; then echo "loft-dev: stopped $stop_name (niri $pid)"; else echo "loft-dev: $stop_name was not running"; fi
    exit 0
    ;;
esac

# ── KDE sessions (--compositor kwin) ──────────────────────────────────────
# KWin nested in a headless sway host rendered on the GPU (pixman makes
# KWin quit: "requires compositing"), one host output per KWin output.
# Unlike niri sessions, KDE writes config on start (kwinrc, appletsrc,
# kglobalshortcutsrc, an Akonadi DB): HOME and the XDG dirs are a scratch
# tree in the session dir. Its private bus keeps service activation (KDE
# needs it), so portals, gvfs, at-spi, Akonadi … start on demand: the whole
# session runs in one transient user unit, and stopping it stops them all
# (and unmounts their FUSE mounts under the session's runtime dir).
run_kwin() {
  case "$kshell" in loft | plasma) ;; *) echo "loft-dev: --shell wants loft or plasma" >&2; exit 2 ;; esac
  if [ -n "$outputs" ]; then echo "loft-dev: --compositor kwin takes --size and --output-count, not --outputs" >&2; exit 2; fi
  if [ "$headless" = 0 ]; then echo "loft-dev: --compositor kwin is headless only" >&2; exit 2; fi
  if ! [[ "$output_count" =~ ^[1-8]$ ]]; then echo "loft-dev: --output-count wants 1-8" >&2; exit 2; fi
  if ! [[ "$kwin_scale" =~ ^[1-4](\.[0-9]+)?$ ]]; then echo "loft-dev: --kwin-scale wants a number from 1 to 4, e.g. 1.25" >&2; exit 2; fi
  size="${size:-1600x1000}"
  if ! [[ "$size" =~ ^[0-9]+x[0-9]+$ ]]; then echo "loft-dev: --size wants WxH, e.g. 1600x1000" >&2; exit 2; fi
  local w="${size%x*}" h="${size#*x}"
  local kwin_bin plasma_bin kamd=""
  kwin_bin="$(command -v kwin_wayland || true)"
  [ -n "$kwin_bin" ] || { echo "loft-dev: kwin_wayland not found (needs KDE Plasma 6 installed)" >&2; exit 1; }
  if [ "$kshell" = plasma ]; then
    plasma_bin="$(command -v plasmashell || true)"
    [ -n "$plasma_bin" ] || { echo "loft-dev: plasmashell not found" >&2; exit 1; }
  fi
  for c in /run/current-system/sw/libexec/kactivitymanagerd /usr/libexec/kactivitymanagerd /usr/lib/kactivitymanagerd; do
    [ -x "$c" ] && { kamd="$c"; break; }
  done

  root="$(realpath "${root:-$PWD}")"
  if [ ! -f "$root/src/shell.qml" ]; then
    echo "loft-dev: $root is not a Loft checkout (pass its path, or run from inside it)" >&2
    exit 1
  fi
  local dir unit
  dir="$(session_dir "$session")"
  unit="loft-dev-kwin-$session.service"
  mkdir -p "$dir"
  chmod 700 "$dir"

  # Relaunching replaces this session (and only this one): its unit, or a
  # niri session of the same name.
  if systemctl --user is-active --quiet "$unit"; then
    echo "loft-dev: replacing the running $session session ($unit)"
    systemctl --user stop "$unit" 2>/dev/null || true
  fi
  systemctl --user reset-failed "$unit" 2>/dev/null || true
  if old="$(session_pid "$dir")"; then
    echo "loft-dev: replacing the running $session session (niri $old)"
    stop_session "$dir" >/dev/null
  fi
  unmount_session_fuse "$dir"
  rm -f "$dir/session.env" "$dir/kde.env"

  # Scratch HOME (fresh unless --keep-home).
  local home="$dir/home"
  if [ "$keep_home" = 0 ] && [ -d "$home" ]; then rm -rf "${dir:?}/home"; fi
  mkdir -p "$home/.config" "$home/.local/share" "$home/.cache" "$home/.local/state"
  # Bluedevil's kded module would start obexd, which registers with the
  # real (system) bluez. Nothing a shell test needs.
  [ -f "$home/.config/kded6rc" ] || printf '[Module-bluedevil]\nautoload=false\n' > "$home/.config/kded6rc"

  # Loft's state: the session dir, the theme rendered by the checkout.
  local loft_env=(
    "LOFT_STATE_DIR=$dir"
    "LOFT_DATA_DIR=$root"
    "LOFT_THEME_PATH=${XDG_DATA_HOME:-$HOME/.local/share}/loft/themes:$root/themes"
    "LOFT_SHELL_PATH=$root/src"
  )
  if [ ! -e "$dir/current/theme.json" ]; then
    env "${loft_env[@]}" LOFT_HOOKS=none @LOFT@ theme apply default >/dev/null || true
  fi
  mkdir -p "$dir/bin"
  printf '#!/bin/sh\nexec %s -B "%s" "$@"\n' "@PYTHON@" "$root/cli/loft" > "$dir/bin/loft"
  chmod +x "$dir/bin/loft"
  local path="$dir/bin:$PATH"
  [ -d "$root/target/debug" ] && path="$root/target/debug:$path"

  local node="${LOFT_DEV_RENDER_NODE:-$(for n in /dev/dri/renderD*; do [ -e "$n" ] && echo "$n" && break; done)}"
  [ -n "$node" ] || { echo "loft-dev: no GPU render node (/dev/dri/renderD*); KWin needs one" >&2; exit 1; }

  # The host: one headless output, N KWin outputs wide; KWin's nested
  # windows (titled "KDE Wayland Compositor WL-<i> …") side by side on it.
  # (Input to KWin needs held devices on the host; see input-hold below.)
  local hrt="$dir/host" i rects=""
  mkdir -p "$hrt" "$dir/run"
  chmod 700 "$hrt" "$dir/run"
  rm -f "$hrt"/wayland-* "$hrt"/sway-ipc.*
  {
    # --kwin-scale: KWin's wayland backend takes its outputs' scale from the
    # host surface's preferred scale (its own --scale is ignored there).
    echo "output HEADLESS-1 resolution $((output_count * w))x$h position 0,0 scale $kwin_scale bg #000000 solid_color"
    for ((i = 0; i < output_count; i++)); do
      if [ "$output_count" = 1 ]; then
        echo "for_window [title=\"^KDE Wayland Compositor WL-0 \"] move container to output HEADLESS-1, focus, fullscreen enable"
      else
        echo "for_window [title=\"^KDE Wayland Compositor WL-$i \"] floating enable, resize set $w $h, move absolute position $((i * w)) 0"
      fi
      rects="${rects:+$rects+}WL-$i=$((i * w)),0,${w}x$h"
    done
    echo "default_border none"
    echo "default_floating_border none"
  } > "$dir/host-sway.conf"

  # What runs inside KWin (--exit-with-session): KDE's services, then the shell.
  cat > "$dir/kde-session.sh" <<'EOF'
#!/usr/bin/env bash
# loft-dev: the session inside the nested KWin (written by loft-dev).
# Services the bus activates from now on get this session's displays (as
# startplasma does; the bus itself started with KWin's socket already).
dbus-update-activation-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP || true
env | grep -E '^(DBUS_SESSION_BUS_ADDRESS|WAYLAND_DISPLAY|DISPLAY)=' > "$LOFT_DEV_DIR/kde.env.tmp"
mv "$LOFT_DEV_DIR/kde.env.tmp" "$LOFT_DEV_DIR/kde.env"
[ -z "$LOFT_DEV_KAMD" ] || "$LOFT_DEV_KAMD" &
kded6 &
if [ "$LOFT_DEV_SHELL" = plasma ]; then
  plasmashell &
else
  env "LOFT_STATE_DIR=$LOFT_DEV_DIR" "LOFT_LAUNCHER_DIR=$LOFT_DEV_ROOT/launcher" "LOFT_SHELL_SRC=$LOFT_DEV_ROOT/src" \
    "LOFT_SCRIPTS_DIR=$LOFT_DEV_DIR/scripts" "LOFT_LAUNCHER_DRYRUN=$LOFT_DEV_DIR/launcher-dryrun.log" \
    loft-launcher service &
  env LOFT_DEV=1 "LOFT_STATE_DIR=$LOFT_DEV_DIR" "LOFT_DATA_DIR=$LOFT_DEV_ROOT" "LOFT_SHELL_SRC=$LOFT_DEV_ROOT/src" \
    "LOFT_THEME_FILE=$LOFT_DEV_DIR/current/theme.json" \
    "LOFT_EJECT_DRYRUN=$LOFT_DEV_DIR/eject-dryrun.log" "LOFT_VIDEO_CACHE=$LOFT_DEV_DIR/cache/wallpaper-video" \
    QS_DISABLE_CRASH_HANDLER=1 loft-shell &
fi
wait
EOF
  chmod +x "$dir/kde-session.sh"

  # The unit's main process: the host, then KWin on a private bus.
  cat > "$dir/kwin-run.sh" <<'EOF'
#!/usr/bin/env bash
# loft-dev: a nested KDE session (written by loft-dev; runs as its unit).
# Only KWin talks to the host; the private bus (and everything it
# activates: portals, ksecretd, at-spi …) gets KWin's socket, or those
# would map their surfaces on the host, over KWin, and take its input.
set -u
d="$LOFT_DEV_DIR"
env -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY -u DISPLAY -u NIRI_SOCKET XDG_RUNTIME_DIR="$d/host" \
  WLR_BACKENDS=headless WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE="$LOFT_DEV_NODE" WLR_LIBINPUT_NO_DEVICES=1 \
  WLR_HEADLESS_OUTPUTS=1 \
  "$LOFT_DEV_SWAY" --unsupported-gpu -c "$d/host-sway.conf" > "$d/host.log" 2>&1 &
echo "$!" > "$d/host.pid"
for _ in $(seq 100); do [ -S "$d/host/wayland-1" ] && break; sleep 0.1; done
[ -S "$d/host/wayland-1" ] || { echo "loft-dev: the headless host did not start (see $d/host.log)" >&2; exit 1; }
exec env -u DBUS_SESSION_BUS_ADDRESS -u DISPLAY -u NIRI_SOCKET -u WAYLAND_SOCKET -u SWAYSOCK \
  HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" XDG_DATA_HOME="$d/home/.local/share" \
  XDG_CACHE_HOME="$d/home/.cache" XDG_STATE_HOME="$d/home/.local/state" \
  XDG_RUNTIME_DIR="$d/run" WAYLAND_DISPLAY="$d/run/wayland-loft" \
  XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE XDG_SESSION_TYPE=wayland \
  KDE_FULL_SESSION=true KDE_SESSION_VERSION=6 QT_QPA_PLATFORM=wayland \
  CLIPHIST_DB_PATH="$d/cliphist.db" LOFT_SESSION="$LOFT_SESSION" \
  dbus-run-session -- env WAYLAND_DISPLAY="$d/host/wayland-1" "$LOFT_DEV_KWIN" --width "$LOFT_DEV_W" --height "$LOFT_DEV_H" \
    --output-count "$LOFT_DEV_OUTPUT_COUNT" --socket wayland-loft --xwayland --no-lockscreen \
    --exit-with-session "$d/kde-session.sh"
EOF
  chmod +x "$dir/kwin-run.sh"

  # After the cgroup is gone: unmount the helpers' FUSE mounts (see
  # unmount_session_fuse; this runs even when the unit just ends).
  local fuse_post=() fm
  fm="$(command -v fusermount3 || command -v fusermount || true)"
  # (The single quotes are systemd's command-line quoting.)
  [ -z "$fm" ] || fuse_post=(-p "ExecStopPost=-$(command -v bash) -c '$fm -uz $dir/run/doc; $fm -uz $dir/run/gvfs; true'")
  local mode="kwin-$kshell"
  echo "loft-dev: session $session ($mode, ${size} x$output_count on $node), unit $unit, shell from $root/src"
  systemd-run --user --quiet --collect --unit="$unit" \
    --description="loft-dev KDE session $session ($kshell shell)" \
    -p KillMode=control-group -p TimeoutStopSec=15 \
    "${fuse_post[@]}" \
    --setenv=PATH="$path" \
    --setenv=LOFT_DEV_DIR="$dir" --setenv=LOFT_DEV_ROOT="$root" --setenv=LOFT_DEV_SHELL="$kshell" \
    --setenv=LOFT_DEV_NODE="$node" --setenv=LOFT_DEV_SWAY=@SWAY@ --setenv=LOFT_DEV_KWIN="$kwin_bin" \
    --setenv=LOFT_DEV_KAMD="$kamd" --setenv=LOFT_DEV_W="$w" --setenv=LOFT_DEV_H="$h" \
    --setenv=LOFT_DEV_OUTPUT_COUNT="$output_count" --setenv=LOFT_SESSION="$session" \
    --setenv=LOFT_DEV_HOST_RUNTIME="$rt" \
    --setenv=LOFT_THEME_PATH="${XDG_DATA_HOME:-$HOME/.local/share}/loft/themes:$root/themes" \
    --setenv=LOFT_UI_FONT=@UI_FONT@ --setenv=LOFT_ICON_FONT=@ICON_FONT@ \
    --setenv=QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi \
    "${kwin_env[@]}" \
    bash "$dir/kwin-run.sh"
  trap 'systemctl --user stop "$unit" 2>/dev/null || true; exit 130' INT TERM

  # Ready when the session script has run (KWin is up, its bus known).
  for _ in $(seq 1 150); do
    [ -f "$dir/kde.env" ] && break
    systemctl --user is-active --quiet "$unit" || break
    sleep 0.2
  done
  if [ ! -f "$dir/kde.env" ]; then
    echo "loft-dev: KWin did not start; journalctl --user -u $unit" >&2
    systemctl --user stop "$unit" 2>/dev/null || true
    exit 1
  fi
  local kwin_pid host_pid bus xdisplay
  kwin_pid="$(systemctl --user show -p MainPID --value "$unit")"
  # MainPID is dbus-run-session; KWin is its kwin_wayland child (by comm:
  # KWin has capabilities, so /proc/PID/exe isn't readable).
  local kids p
  read -r -a kids < <(cat "/proc/$kwin_pid/task/"*/children 2>/dev/null) || true
  for p in "${kids[@]}"; do
    case "$(cat "/proc/$p/comm" 2>/dev/null)" in *kwin_wayland*) kwin_pid="$p" ;; esac
  done
  host_pid="$(cat "$dir/host.pid" 2>/dev/null || true)"
  bus="$(sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' "$dir/kde.env")"
  xdisplay="$(sed -n 's/^DISPLAY=//p' "$dir/kde.env")"
  {
    printf 'LOFT_DEV_COMPOSITOR=kwin\nLOFT_DEV_UNIT=%s\nLOFT_DEV_SHELL=%s\n' "$unit" "$kshell"
    printf 'WAYLAND_DISPLAY=%s\nLOFT_DEV_HOST_DISPLAY=%s\n' "$dir/run/wayland-loft" "$hrt/wayland-1"
    printf 'KWIN_PID=%s\nLOFT_DEV_HOST_PID=%s\n' "$kwin_pid" "$host_pid"
    printf 'LOFT_SESSION=%s\nLOFT_DEV_PID=%s\nLOFT_DEV_MODE=%s\n' "$session" "$$" "$mode"
    printf 'LOFT_DEV_SIZE=%s\nLOFT_DEV_OUTPUT_COUNT=%s\nLOFT_DEV_OUTPUT_RECTS=%s\n' "$size" "$output_count" "$rects"
    printf 'XDG_RUNTIME_DIR=%s\nDBUS_SESSION_BUS_ADDRESS=%s\n' "$dir/run" "$bus"
    printf 'HOME=%s\nXDG_CONFIG_HOME=%s\nXDG_DATA_HOME=%s\nXDG_CACHE_HOME=%s\nXDG_STATE_HOME=%s\n' \
      "$home" "$home/.config" "$home/.local/share" "$home/.cache" "$home/.local/state"
    printf 'XDG_CURRENT_DESKTOP=KDE\nLOFT_DEV_HOST_RUNTIME=%s\n' "$rt"
    [ -z "$xdisplay" ] || printf 'DISPLAY=%s\n' "$xdisplay"
    printf '%s\n' "${loft_env[@]}"
  } > "$dir/session.env"
  # Input: the host has no devices of its own, so each loft-input run's
  # virtual pointer/keyboard flips the seat's capabilities, KWin binds a new
  # wl_pointer, and the pointer enter is lost in that race: KWin then gets
  # buttons without enter/motion and ignores them (seen with WAYLAND_DEBUG).
  # Devices held for the session's lifetime keep the capabilities, and
  # KWin's pointer, in place. (30 days; the unit is bound to the session's.)
  printf 'move 1 1\nwait 300\nmove 2 2\nkey Shift_L\nwait 3000\nmove 3 3\nwait 2592000000\n' > "$dir/input-hold.txt"
  systemd-run --user --quiet --collect --unit="loft-dev-kwin-$session-input" \
    -p "BindsTo=$unit" -p "After=$unit" \
    --description="loft-dev KDE session $session: held host input devices" \
    "$(command -v loft-input)" --session "$session" script "$dir/input-hold.txt" || true
  echo "loft-dev: WAYLAND_DISPLAY=$dir/run/wayland-loft  (loft-input/loft-shot --session $session; stop: loft-dev --stop $session)"

  # Follow the unit; forget the session when it ends.
  while systemctl --user is-active --quiet "$unit"; do sleep 1; done
  if [ "$(env_get "$dir" LOFT_DEV_PID)" = "$$" ]; then rm -f "$dir/session.env"; fi
  exit 0
}

valid_name "$session" || { echo "loft-dev: bad session name $session (letters, digits, - _ ., up to 32)" >&2; exit 2; }
case "$compositor" in
  niri) ;;
  kwin) run_kwin ;;
  *) echo "loft-dev: --compositor wants niri or kwin" >&2; exit 2 ;;
esac
named=0
[ "$session" = dev ] || named=1
[ -n "$bus" ] || bus=$named
[ -n "$runtime" ] || runtime=$named
[ -n "$headless" ] || headless=$named
if [ -n "$size" ] && ! [[ "$size" =~ ^[0-9]+x[0-9]+$ ]]; then
  echo "loft-dev: --size wants WxH, e.g. 1600x1000" >&2; exit 2
fi
# --outputs: niri's own (patched) headless backend with one virtual output
# per entry; the sway host can't help here, niri nested has one output.
output_sizes=""
output_kdl=""
if [ -n "$outputs" ] && [ "$gpu" = 1 ]; then
  echo "loft-dev: --gpu runs one output (--size), not --outputs" >&2; exit 2
fi
if [ -n "$outputs" ]; then
  if [ -n "$size" ]; then echo "loft-dev: --size and --outputs don't mix" >&2; exit 2; fi
  if [ "$headless" = 0 ]; then echo "loft-dev: --outputs is headless only" >&2; exit 2; fi
  headless=1
  n=0
  IFS=, read -r -a out_specs <<< "$outputs"
  for spec in "${out_specs[@]}"; do
    n=$((n + 1))
    if ! [[ "$spec" =~ ^([0-9]+x[0-9]+)(\+(-?[0-9]+)\+(-?[0-9]+))?$ ]]; then
      echo "loft-dev: --outputs wants WxH or WxH+X+Y entries, got $spec" >&2; exit 2
    fi
    output_sizes="${output_sizes:+$output_sizes,}${BASH_REMATCH[1]}"
    if [ -n "${BASH_REMATCH[2]}" ]; then
      output_kdl+="output \"headless-$n\" { position x=${BASH_REMATCH[3]} y=${BASH_REMATCH[4]}; }"$'\n'
    fi
  done
fi
if [ -z "$size" ] && { [ "$named" = 1 ] || [ "$headless" = 1 ]; }; then size=1600x1000; fi
# The headless host's sockets live in the session's runtime dir.
[ "$headless" = 0 ] || runtime=1

root="$(realpath "${root:-$PWD}")"
if [ ! -f "$root/src/shell.qml" ] || [ ! -f "$root/niri/base.kdl" ]; then
  echo "loft-dev: $root is not a Loft checkout (pass its path, or run from inside it)" >&2
  exit 1
fi

# The entry config lives outside the checkout; it includes the live
# fragments by absolute path, so niri watches and reloads them.
dir="$(session_dir "$session")"
mkdir -p "$dir"
chmod 700 "$dir"

# Own D-Bus: re-run under dbus-run-session with a config that has no service
# directories, so nothing is ever activated on it (walker, notifications,
# the menu registrar … live only on this bus, never reach the host's).
if [ "$bus" = 1 ] && [ "${LOFT_DEV_IN_BUS:-}" != "$dir" ]; then
  rm -f "$dir"/dbus-*
  cat > "$dir/dbus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:dir=$dir</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
  export LOFT_DEV_IN_BUS="$dir" LOFT_DEV_HOST_BUS="${DBUS_SESSION_BUS_ADDRESS:-}"
  export LOFT_DEV_HOST_RUNTIME="$rt"
  exec dbus-run-session --config-file="$dir/dbus.conf" -- "$0" "${orig_args[@]}"
fi
host_bus="${LOFT_DEV_HOST_BUS:-${DBUS_SESSION_BUS_ADDRESS:-}}"

# The host desktop, captured before anything below changes the environment.
host_niri=""
if [ "$headless" = 0 ] && [ -n "${NIRI_SOCKET:-}" ] && [ -S "$NIRI_SOCKET" ]; then
  host_niri="$NIRI_SOCKET"
fi
host_display="${WAYLAND_DISPLAY:-}"

# `loft` run against this session: checkout templates + themes,
# user-installed packs, state in $dir.
loft_env=(
  "LOFT_STATE_DIR=$dir"
  "LOFT_DATA_DIR=$root"
  "LOFT_THEME_PATH=${XDG_DATA_HOME:-$HOME/.local/share}/loft/themes:$root/themes"
  "LOFT_SHELL_PATH=$root/src"
)

sed "s|@IPC@|\"quickshell\" \"ipc\" \"--path\" \"$root/src\" \"call\"|g" \
  "$root/niri/shell-binds.kdl.in" > "$dir/shell-binds.kdl"

# Relaunching replaces this session's running niri (and only this one's).
if old="$(session_pid "$dir")"; then
  echo "loft-dev: replacing the running $session session (niri $old)"
  stop_session "$dir" >/dev/null
fi
rm -f "$dir/session.env"

# The active theme: `current` → a rendered theme dir. Kept across
# restarts (`loft --dev theme apply NAME` switches it); rendered
# when missing (from the default) or still a raw pack from before
# the renderer (no niri.kdl; re-rendered, keeping the choice).
if [ ! -e "$dir/current/niri.kdl" ]; then
  theme=default
  [ -e "$dir/current/theme.json" ] && theme="$(readlink -f "$dir/current")"
  env "${loft_env[@]}" LOFT_HOOKS=none @LOFT@ theme apply "$theme" >/dev/null
fi

# Own runtime dir: niri's and everything's sockets (Wayland, niri IPC,
# Quickshell IPC, elephant, clipboard cache) live there instead of next to the
# live desktop's. No audio server unless --share-audio links the host's
# PipeWire / Pulse sockets in (a test dragging the volume slider would
# otherwise change the real machine's volume).
if [ "$runtime" = 1 ]; then
  srt="$dir/run"
  mkdir -p "$srt"
  chmod 700 "$srt"
  for s in pipewire-0 pipewire-0-manager pulse; do
    rm -f "$srt/$s"
    if [ "$audio" = 1 ] && [ -e "$rt/$s" ]; then ln -sfn "$rt/$s" "$srt/$s"; fi
  done
  # niri's winit backend must still find the host's socket.
  case "$host_display" in
    /*|"") ;;
    *) export WAYLAND_DISPLAY="$rt/$host_display" ;;
  esac
  export XDG_RUNTIME_DIR="$srt"
  # The shell's clipboard history goes to the session, not the user's cliphist.
  export CLIPHIST_DB_PATH="$dir/cliphist.db"
fi

extra_kdl=""
host_pid=""
# niri-loft: the place-within-workspace layer rule (per-workspace wallpapers).
niri_bin=@NIRI_LOFT@
[ "$ws_layers" = 1 ] || niri_bin=@NIRI_STOCK@
nested=1
if [ -n "$output_sizes" ]; then
  # niri on virtual outputs (nix/dev/niri-headless-outputs.patch): no host
  # compositor at all; software rendering for screenshots (grim → screencopy).
  niri_bin=@NIRI_HEADLESS@
  nested=0
  export NIRI_HEADLESS_OUTPUTS="$output_sizes"
  export __EGL_VENDOR_LIBRARY_FILENAMES=@MESA_EGL_VENDOR@ LIBGL_ALWAYS_SOFTWARE=1
  unset WAYLAND_DISPLAY WAYLAND_SOCKET DISPLAY NIRI_SOCKET
elif [ "$headless" = 1 ]; then
  # A headless wlroots compositor (sway: WLR_BACKENDS=headless, pixman) is
  # the host: one offscreen output of exactly --size, niri fullscreen on it.
  # Everything renders in software (Mesa llvmpipe), so the session never
  # touches the GPU, never shows on a monitor, and doesn't care whether the
  # desktop is locked or which workspace is visible.
  hrt="$dir/host"
  mkdir -p "$hrt"
  chmod 700 "$hrt"
  rm -f "$hrt"/wayland-* "$hrt"/sway-ipc.*
  cat > "$dir/host-sway.conf" <<EOF
output HEADLESS-1 resolution $size position 0,0 bg #000000 solid_color
default_border none
default_floating_border none
for_window [app_id="niri"] fullscreen enable
EOF
  if [ "$gpu" = 1 ]; then
    # --gpu: the host renders with gles2 on a GPU render node (sway needs
    # --unsupported-gpu for NVIDIA's); niri and the shell use its EGL.
    node="${LOFT_DEV_RENDER_NODE:-$(for n in /dev/dri/renderD*; do [ -e "$n" ] && echo "$n" && break; done)}"
    env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$hrt" WLR_BACKENDS=headless WLR_RENDERER=gles2 \
      WLR_RENDER_DRM_DEVICE="$node" WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
      @SWAY@ --unsupported-gpu -c "$dir/host-sway.conf" > "$dir/host.log" 2>&1 &
  else
    env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$hrt" WLR_BACKENDS=headless WLR_RENDERER=pixman \
      WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
      @SWAY@ -c "$dir/host-sway.conf" > "$dir/host.log" 2>&1 &
  fi
  host_pid=$!
  hsock=""
  for _ in $(seq 1 50); do
    for s in "$hrt"/wayland-*; do
      [ -S "$s" ] && hsock="$s"
    done
    [ -n "$hsock" ] && break
    sleep 0.1
  done
  if [ -z "$hsock" ]; then
    echo "loft-dev: the headless host did not start (see $dir/host.log)" >&2
    kill "$host_pid" 2>/dev/null || true
    exit 1
  fi
  export WAYLAND_DISPLAY="$hsock"
  [ "$gpu" = 1 ] || export __EGL_VENDOR_LIBRARY_FILENAMES=@MESA_EGL_VENDOR@ LIBGL_ALWAYS_SOFTWARE=1
  unset NIRI_SOCKET
elif [ "$named" = 1 ]; then
  # A test window on the host usually sits on a workspace nobody looks at;
  # the host then sends frame callbacks about once a second, and with vsync
  # every nested frame blocks that long (laggy screenshots, key releases
  # arriving late → runaway key repeat). Swap without waiting (NVIDIA / Mesa);
  # unset again for the session's own clients.
  extra_kdl='environment {
    __GL_SYNC_TO_VBLANK null
    vblank_mode null
}'
  export __GL_SYNC_TO_VBLANK=0 vblank_mode=0
fi
cleanup_host() {
  if [ -n "$host_pid" ]; then kill "$host_pid" 2>/dev/null || true; fi
}

# Named (test) sessions keep the launcher's caches (elephant's files index,
# history, favicons, qalc) and script commands in the session, and never run
# Spotlight's power / session / trash commands: they're logged to launcher-dryrun.log.
launcher_env=""
# …and never eject a real drive: the shell's udisksctl calls (Drives.qml)
# go to eject-dryrun.log.
shell_env=""
if [ "$named" = 1 ]; then
  launcher_env="\"XDG_CACHE_HOME=$dir/cache\" \"LOFT_SCRIPTS_DIR=$dir/scripts\" \"LOFT_LAUNCHER_DRYRUN=$dir/launcher-dryrun.log\" "
  shell_env="\"LOFT_EJECT_DRYRUN=$dir/eject-dryrun.log\" \"LOFT_VIDEO_CACHE=$dir/cache/wallpaper-video\" "
fi
# Video wallpapers: how Qt decodes (VideoWallpapers.qml). On the GPU (a
# window on the host), VAAPI with Loft's zero-copy QtMultimedia, as the
# packaged shell does; with software rendering (headless, --outputs) the
# GPU's frames can't be imported into llvmpipe, so decode in software.
# QT_FFMPEG_DECODING_HW_DEVICE_TYPES in loft-dev's environment wins.
if [ -n "${QT_FFMPEG_DECODING_HW_DEVICE_TYPES+x}" ]; then
  video_env="\"QT_FFMPEG_DECODING_HW_DEVICE_TYPES=$QT_FFMPEG_DECODING_HW_DEVICE_TYPES\" \"LOFT_QT_VAAPI_ZERO_COPY=1\" "
elif [ "$gpu" != 1 ] && { [ "$headless" = 1 ] || [ -n "$output_sizes" ]; }; then
  video_env='"QT_FFMPEG_DECODING_HW_DEVICE_TYPES=," '
else
  video_env='"QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi" "LOFT_QT_VAAPI_ZERO_COPY=1" "NVD_MAX_DETACHED_BACKING_IMAGES=0" '
fi
shell_env="$shell_env$video_env"

# The theme fragment comes after base.kdl so it wins, then dev-local, then
# the spaces (`loft-niri space render`; included once: a workspace declared
# twice exists twice), then the runtime overrides (also first: see the
# header comment).
# Per-workspace wallpapers: the layer rule (only niri-loft parses it) and the
# shell's switch for them (WorkspaceWallpapers.qml).
ws_kdl=""
ws_env=""
if [ "$ws_layers" = 1 ]; then
  # niri-loft's title bar too (nix/niri/title-bar.patch).
  ws_kdl="include \"$root/niri/workspace-wallpapers.kdl\"
include \"$root/niri/title-bar.kdl\"
include optional=true \"$dir/current/niri-loft.kdl\""
  ws_env='"LOFT_NIRI_WORKSPACE_LAYERS=1" '
fi

cat > "$dir/config.kdl" <<EOF
include optional=true "$dir/overrides/niri.kdl"
$output_kdl
include "$root/niri/base.kdl"
include "$dir/shell-binds.kdl"
include optional=true "$dir/current/niri.kdl"
include optional=true "$root/niri/dev-local.kdl"
include optional=true "$dir/overrides/spaces.kdl"
include optional=true "$dir/overrides/niri.kdl"
$ws_kdl
$extra_kdl
spawn-at-startup "env" $launcher_env"LOFT_STATE_DIR=$dir" "LOFT_LAUNCHER_DIR=$root/launcher" "LOFT_SHELL_SRC=$root/src" "loft-launcher" "service"
spawn-at-startup "env" $ws_env$shell_env"LOFT_DEV=1" "LOFT_STATE_DIR=$dir" "LOFT_DATA_DIR=$root" "LOFT_THEME_PATH=${XDG_DATA_HOME:-$HOME/.local/share}/loft/themes:$root/themes" "LOFT_SHELL_PATH=$root/src" "LOFT_NIRI_CONFIG=$dir/config.kdl" "LOFT_THEME_FILE=$dir/current/theme.json" "LOFT_UI_FONT=@UI_FONT@" "LOFT_ICON_FONT=@ICON_FONT@" "QML_IMPORT_PATH=@LOCK_QML_PATH@" "QT_PLUGIN_PATH=@QT_MM_PLUGINS@" "quickshell" "--path" "$root/src"
EOF

# Live everything, not just QML: `loft` runs the checkout's CLI,
# and fresh `cargo build` binaries (target/debug) shadow the
# packaged loft-niri & co. niri — and everything it spawns —
# inherits this PATH.
mkdir -p "$dir/bin"
printf '#!/bin/sh\nexec %s -B "%s" "$@"\n' "@PYTHON@" "$root/cli/loft" > "$dir/bin/loft"
chmod +x "$dir/bin/loft"
export PATH="$dir/bin:$PATH"
# The session's `niri` (msg, and the `niri validate` loft-niri runs before it
# writes overrides) is the compositor it runs: stock niri rejects niri-loft's
# place-within-workspace rule, so validating with it fails every change.
case "$niri_bin" in /*) PATH="${niri_bin%/*}:$PATH" ;; esac
if [ -d "$root/target/debug" ]; then
  export PATH="$root/target/debug:$PATH"
fi
export LOFT_SESSION="$session"

mode=on-host
[ "$headless" = 1 ] && mode=headless
[ "$gpu" = 1 ] && mode="headless-gpu"
[ -n "$output_sizes" ] && mode="headless-outputs"
echo "loft-dev: session $session ($mode), niri config $dir/config.kdl, shell from $root/src"
"$niri_bin" --config "$dir/config.kdl" &
niri_pid=$!
trap 'kill $niri_pid 2>/dev/null; cleanup_host' INT TERM

# Record how to reach this session (loft-input, loft-shot, `loft --dev`).
sock=""
for _ in $(seq 1 50); do
  for s in "${XDG_RUNTIME_DIR:-/tmp}"/niri.wayland-*."$niri_pid".sock; do
    [ -S "$s" ] && sock="$s"
  done
  [ -n "$sock" ] && break
  sleep 0.2
done
if [ -z "$sock" ]; then
  echo "loft-dev: niri did not start" >&2
  kill "$niri_pid" 2>/dev/null || true
  cleanup_host
  exit 1
fi
display="$(basename "$sock" | cut -d. -f2)"
[ "$runtime" = 1 ] && display="$XDG_RUNTIME_DIR/$display"
{
  printf 'NIRI_SOCKET=%s\nWAYLAND_DISPLAY=%s\nNIRI_PID=%s\n' "$sock" "$display" "$niri_pid"
  printf 'LOFT_SESSION=%s\nLOFT_DEV_PID=%s\nLOFT_DEV_MODE=%s\n' "$session" "$$" "$mode"
  printf 'LOFT_DEV_NESTED=%s\n' "$nested"
  [ -n "$output_sizes" ] && printf 'LOFT_DEV_OUTPUTS=%s\n' "$outputs"
  printf 'LOFT_NIRI_CONFIG=%s\n' "$dir/config.kdl"
  printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-}"
  [ -n "$host_pid" ] && printf 'LOFT_DEV_HOST_PID=%s\n' "$host_pid"
  [ "$bus" = 1 ] && printf 'DBUS_SESSION_BUS_ADDRESS=%s\n' "${DBUS_SESSION_BUS_ADDRESS:-}"
  printf '%s\n' "${loft_env[@]}"
} > "$dir/session.env"
echo "loft-dev: WAYLAND_DISPLAY=$display  (loft-input/loft-shot --session $session)"

# Placement of an on-host window.
#   niri: `dev` → fullscreen on --output or the rightmost monitor; named
#         sessions (or --size) → floating at that size. Matched by our niri's pid.
#   KDE:  `dev` → fullscreen + borderless via a KWin script.
place_niri() {
  local id="" got=""
  for _ in $(seq 1 50); do
    id="$(NIRI_SOCKET="$host_niri" timeout 2 niri msg -j windows 2>/dev/null \
      | jq -r --argjson pid "$niri_pid" '[.[] | select(.pid == $pid)][0].id // empty' || true)"
    [ -n "$id" ] && break
    sleep 0.2
  done
  [ -n "$id" ] || { echo "loft-dev: host window not found; not placing it" >&2; return 0; }
  hm() { NIRI_SOCKET="$host_niri" timeout 2 niri msg action "$@" >/dev/null 2>&1 || true; }
  if [ -n "$size" ]; then
    local w="${size%x*}" h="${size#*x}"
    hm move-window-to-floating --id "$id"
    hm set-window-width --id "$id" "$w"
    hm set-window-height --id "$id" "$h"
    # niri ignores window actions while the host is locked.
    for _ in $(seq 1 15); do
      got="$(NIRI_SOCKET="$sock" niri msg -j outputs 2>/dev/null \
        | jq -r '[.[] | select(.logical)][0].logical | "\(.width)x\(.height)"' || true)"
      [ "$got" = "$size" ] && break
      sleep 0.2
    done
    if [ "$got" = "$size" ]; then
      echo "loft-dev: $size floating window (host window $id)"
    else
      echo "loft-dev: asked the host for $size, the session is $got (host locked, or the size is clamped); --headless gives an exact size" >&2
    fi
  else
    if [ -z "$output" ]; then
      output="$(NIRI_SOCKET="$host_niri" timeout 2 niri msg -j outputs 2>/dev/null \
        | jq -r '[.[] | select(.logical)] | max_by(.logical.x) | .name // empty' || true)"
    fi
    [ -n "$output" ] || return 0
    hm move-window-to-monitor --id "$id" "$output"
    hm fullscreen-window --id "$id"
    echo "loft-dev: fullscreen on $output (host window $id)"
  fi
}

if [ "$headless" = 0 ] && [ "$windowed" = 0 ]; then
  if [ -n "$host_niri" ]; then
    place_niri
  elif [ "$named" = 0 ] && [ -z "$size" ] && command -v kscreen-doctor >/dev/null; then
    # Inside KDE: fullscreen + borderless on one monitor, so the nested
    # session is a real full-size output. Default: the rightmost.
    if [ -z "$output" ]; then
      output="$(kscreen-doctor -j 2>/dev/null | jq -r '[.outputs[] | select(.enabled)] | max_by(.pos.x) | .name // empty' || true)"
    fi
    qdbus="$(command -v qdbus || command -v qdbus6 || true)"
    if [ -n "$output" ] && [ -n "$qdbus" ]; then
      echo "loft-dev: fullscreen on $output"
      sed -e "s/@OUTPUT@/$output/g" -e "s/@PID@/$niri_pid/g" @KWIN_PLACE@ > "$dir/kwin-place.js"
      id="$(DBUS_SESSION_BUS_ADDRESS="$host_bus" "$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$dir/kwin-place.js" loft-dev-place)"
      DBUS_SESSION_BUS_ADDRESS="$host_bus" "$qdbus" org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null
      # Stay loaded long enough to catch the window being mapped.
      (sleep 5; DBUS_SESSION_BUS_ADDRESS="$host_bus" "$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript loft-dev-place >/dev/null) &
    elif [ -n "$output" ]; then
      echo "loft-dev: --output needs KDE's qdbus; ignoring" >&2
    fi
  fi
fi

wait "$niri_pid" || true
cleanup_host
# Forget the session once its niri is gone (unless a newer one replaced it).
if [ "$(env_get "$dir" NIRI_PID)" = "$niri_pid" ]; then rm -f "$dir/session.env"; fi
