#!/usr/bin/env bash
# spotlight-timing — how long Spotlight (walker) takes to appear and to go,
# measured in a nested KDE session (loft-dev --compositor kwin), never on
# the real desktop. docs/KWIN.md §4.22.
#
#   nix/dev/spotlight-timing.sh SESSION [--runs N] [--restart | --early] [--trigger key|launcher|CMD]
#
# A probe KWin script in the session stamps every window KWin maps and
# unmaps with KWin's own clock; dbus-monitor on the session's bus reads the
# stamps (as names in NameHasOwner calls, which need no service). Each run:
# t0, the trigger, the walker window's map → "open ms"; then the trigger
# again (Spotlight toggles), its unmap → "close ms".
#
#   --trigger key       (default) Meta+Space through KWin, the way a person
#                       opens it: loft-input's virtual keyboard → KWin →
#                       loft-keys' shortcut → … → walker
#   --trigger launcher  `loft-launcher open` in the session (the niri path,
#                       and what the old KDE shortcut unit ran)
#   --trigger 'CMD'     any command, run in the session's environment
#   --restart           restart the launcher (elephant + walker) first, as a
#                       deploy does, and wait for walker's D-Bus name: run 1
#                       is the first open after a start
#   --early             the same, but run 1 fires 200 ms after the restart (a
#                       key pressed while the launcher is still starting)
#
#   SPOTLIGHT_TIMING_LAUNCHER=PATH   another loft-launcher build (with --restart)
#   SPOTLIGHT_TIMING_SETTLE=S        --restart: wait S s more after walker's name
#   GSK_RENDERER, GDK_DEBUG, GSK_DEBUG, WAYLAND_DEBUG   passed to a restarted launcher
#
# --trigger key needs Loft's shortcuts in the session's KWin (loft-dev doesn't
# load them): `loft keys kwin render --binds … --out DIR`, then
# org.kde.kwin.Scripting loadScript DIR/loft-keys.js loft-keys.
#
# Prints one line per run and a summary; the stamps are in
# $dir/spotlight-timing.log.
set -euo pipefail

session="${1:-}"
[ -n "$session" ] && [ "${session#-}" = "$session" ] || {
  echo "usage: spotlight-timing.sh SESSION [--runs N] [--restart | --early] [--trigger key|launcher|CMD]" >&2
  exit 2
}
shift
runs=10 restart=0 early=0 trigger=key
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) runs="$2"; shift 2 ;;
    --restart) restart=1; shift ;;
    --early) restart=1 early=1; shift ;;
    --trigger) trigger="$2"; shift 2 ;;
    *) echo "spotlight-timing: unknown argument $1" >&2; exit 2 ;;
  esac
done

host_runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
dir="$host_runtime/loft-dev-$session"
[ -f "$dir/session.env" ] && [ -f "$dir/kde.env" ] || {
  echo "spotlight-timing: no KDE session $session (start one: loft-dev --session $session --compositor kwin)" >&2
  exit 1
}
here="$(cd "$(dirname "$0")/../.." && pwd)"
input="$(command -v loft-input || true)"
[ -n "$input" ] || input="$(nix build "$here#loft-input" --no-link --print-out-paths)/bin/loft-input"

# The session's unit and the unit --restart runs the launcher in (bound to
# the session's, so `loft-dev --stop` stops it too). Asked before
# XDG_RUNTIME_DIR is the session's.
unit="$(sed -n 's/^LOFT_DEV_UNIT=//p' "$dir/session.env")"
lunit="loft-dev-spotlight-$session.service"
cgroups=()
for u in "$lunit" "$unit"; do
  cg="$(systemctl --user show -p ControlGroup --value "$u" 2>/dev/null || true)"
  [ -z "$cg" ] || cgroups+=("/sys/fs/cgroup$cg")
done
user_systemctl() { XDG_RUNTIME_DIR="$host_runtime" systemctl --user "$@"; }

# The session's environment; never the real session's bus.
set -a
# shellcheck disable=SC1091
. "$dir/session.env"
# shellcheck disable=SC1091
. "$dir/kde.env"
set +a
case "${DBUS_SESSION_BUS_ADDRESS:-}" in
  "" | *"$host_runtime/bus"*) echo "spotlight-timing: refusing: that's the real session's bus" >&2; exit 1 ;;
esac
export XDG_RUNTIME_DIR="$dir/run" HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/.config" \
  XDG_DATA_HOME="$dir/home/.local/share" XDG_STATE_HOME="$dir/home/.local/state" XDG_CACHE_HOME="$dir/home/.cache"
unset NIRI_SOCKET

launcher_pid() { # the session's `loft-launcher service` (its bash), by cgroup
  local cg pid
  for cg in "${cgroups[@]}"; do
    [ -r "$cg/cgroup.procs" ] || continue
    while read -r pid; do
      tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'loft-launcher service' && { echo "$pid"; return; }
    done < "$cg/cgroup.procs"
  done
}
launcher_bin() {
  local pid
  pid="$(launcher_pid)"
  [ -n "$pid" ] && tr '\0' '\n' < "/proc/$pid/cmdline" | sed -n 2p
}
# The running service's loft-launcher; else (a --restart stopped it) the last
# one seen, or $SPOTLIGHT_TIMING_LAUNCHER (another build to measure).
launcher="${SPOTLIGHT_TIMING_LAUNCHER:-$(launcher_bin || true)}"
[ -n "$launcher" ] || launcher="$(cat "$dir/spotlight-launcher.bin" 2> /dev/null || true)"
[ -n "$launcher" ] || { echo "spotlight-timing: no loft-launcher service in the session" >&2; exit 1; }
echo "$launcher" > "$dir/spotlight-launcher.bin"

log="$dir/spotlight-timing.log"
probe="$dir/spotlight-probe.js"
cat > "$probe" <<'EOF'
// spotlight-timing's probe: each window KWin maps or unmaps → a NameHasOwner
// call whose name carries the event, the window's class and KWin's clock.
function loftProbe(ev, w) {
    if (!w) return;
    var cls = String(w.resourceClass || "x").replace(/[^A-Za-z0-9_]/g, "_") || "x";
    callDBus("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
        "loft.probe." + ev + ".c" + cls + ".t" + Date.now());
}
workspace.windowAdded.connect(function (w) { loftProbe("added", w); });
workspace.windowRemoved.connect(function (w) { loftProbe("removed", w); });
EOF
kwin_script() { qdbus org.kde.KWin /Scripting "org.kde.kwin.Scripting.$1" "${@:2}"; }
kwin_script unloadScript loft-spotlight-probe > /dev/null || true
kwin_script loadScript "$probe" loft-spotlight-probe > /dev/null
kwin_script start > /dev/null
: > "$log"
dbus-monitor "type='method_call',member='NameHasOwner'" > "$log" 2>&1 &
mon=$!
cleanup() {
  kill "$mon" 2>/dev/null || true
  kwin_script unloadScript loft-spotlight-probe > /dev/null 2>&1 || true
}
trap cleanup EXIT
sleep 0.5

# The walker stamp of EVENT after T0 (ms), waiting up to 5 s; empty on timeout.
stamp_after() {
  local ev="$1" t0="$2" t
  for _ in $(seq 500); do
    t="$(grep -o "loft\.probe\.$ev\.c[A-Za-z0-9_]*walker[A-Za-z0-9_]*\.t[0-9]*" "$log" | sed 's/.*\.t//' |
      awk -v t0="$t0" '$1 >= t0 { print; exit }')"
    [ -n "$t" ] && { echo "$t"; return; }
    sleep 0.01
  done
}

fire() {
  case "$trigger" in
    key) XDG_RUNTIME_DIR="$host_runtime" "$input" -s "$session" key super+space > /dev/null ;;
    launcher) "$launcher" open ;;
    *) bash -c "$trigger" ;;
  esac
}

if [ "$restart" = 1 ]; then
  echo "restarting the launcher ($launcher service)"
  if user_systemctl is-active --quiet "$lunit"; then
    user_systemctl stop "$lunit"
  elif [ -n "$(launcher_pid)" ]; then
    # The one kde-session.sh started: it and its children (walker, elephant),
    # as systemd stops a unit (bash runs its EXIT trap only once walker ends).
    pid="$(launcher_pid)"
    # shellcheck disable=SC2046
    kill $(ps -o pid= --ppid "$pid") "$pid" 2>/dev/null || true
    for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  fi
  for _ in $(seq 100); do qdbus | grep -q dev.benz.walker || break; sleep 0.05; done
  # As kde-session.sh starts it (loft-dev), in its own unit.
  envs=()
  for v in PATH HOME DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR XDG_CONFIG_HOME \
    XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_CURRENT_DESKTOP; do
    envs+=("--setenv=$v=${!v:-}")
  done
  # Passed on when set, for experiments (GSK_RENDERER=gl …).
  for v in GSK_RENDERER GDK_DEBUG GSK_DEBUG WAYLAND_DEBUG; do
    [ -z "${!v:-}" ] || envs+=("--setenv=$v=${!v}")
  done
  user_systemctl reset-failed "$lunit" 2> /dev/null || true
  XDG_RUNTIME_DIR="$host_runtime" systemd-run --user --quiet --collect --unit="$lunit" \
    -p BindsTo="$unit" -p After="$unit" "${envs[@]}" \
    --setenv=LOFT_STATE_DIR="$dir" --setenv=LOFT_LAUNCHER_DIR="$LOFT_DATA_DIR/launcher" \
    --setenv=LOFT_SHELL_SRC="$LOFT_DATA_DIR/src" --setenv=LOFT_SCRIPTS_DIR="$dir/scripts" \
    --setenv=LOFT_LAUNCHER_DRYRUN="$dir/launcher-dryrun.log" \
    "$launcher" service
  restarted="$(date +%s%3N)"
  if [ "$early" = 1 ]; then
    sleep 0.2 # a key pressed right after the service started
  else
    # Wait for the service's D-Bus name (the earliest a key can reach it).
    for _ in $(seq 500); do
      qdbus | grep -q dev.benz.walker && break
      sleep 0.01
    done
    echo "  walker on the bus after $(($(date +%s%3N) - restarted)) ms"
    # SPOTLIGHT_TIMING_SETTLE=S: and then S seconds more (a first open that
    # isn't racing the start).
    sleep "${SPOTLIGHT_TIMING_SETTLE:-0}"
  fi
  cg="$(user_systemctl show -p ControlGroup --value "$lunit")"
  cgroups=("/sys/fs/cgroup$cg" "${cgroups[@]}")
fi

# Start from a closed Spotlight (`walker --close`, as the service gets it).
close_walker() {
  gdbus call --session --timeout 2 --dest dev.benz.walker --object-path /dev/benz/walker \
    --method org.gtk.Application.CommandLine /dev/benz/walker/timing "[b'walker']" "{'options': <{'close': <true>}>}" \
    > /dev/null 2>&1 || true
}
close_walker
sleep 0.3

opens=() closes=()
for r in $(seq "$runs"); do
  t0="$(date +%s%3N)"
  fire
  t1="$(stamp_after added "$t0")"
  sleep 0.4
  t2="$(date +%s%3N)"
  fire
  t3="$(stamp_after removed "$t2")"
  o="${t1:+$((t1 - t0))}" c="${t3:+$((t3 - t2))}"
  printf 'run %2d  open %5s ms  close %5s ms\n' "$r" "${o:-none}" "${c:-none}"
  [ -n "$o" ] && opens+=("$o")
  [ -n "$c" ] && closes+=("$c")
  sleep 0.3
done

summary() {
  local name="$1"; shift
  [ $# -gt 0 ] || { echo "$name: no samples"; return; }
  printf '%s\n' "$@" | sort -n | awk -v n="$name" '{ a[NR] = $1; s += $1 }
    END { printf "%s: first-run %s  median %s  max %s  mean %.0f ms (n=%d)\n", n, first, a[int((NR + 1) / 2)], a[NR], s / NR, NR }' first="$1"
}
summary open "${opens[@]}"
summary close "${closes[@]}"
