---
name: loft-drive
description: See and drive the Loft desktop in an isolated test session — a headless, nested KDE Plasma session (KWin) started with `loft-dev --compositor kwin` — screenshot it with loft-shot (grid, zoom, marks), and click/type/drag/scroll/press KDE shortcuts with loft-input. Use when testing or verifying shell/QML/KWin changes visually, or whenever asked to interact with the desktop.
---

# Driving a Loft test session

Loft is a shell for KDE Plasma (niri was abandoned on 2026-11-18), so test in a
**KDE session**: `--compositor kwin`. Full reference: `docs/TESTING.md` and
docs/KWIN.md §6 in the Loft checkout. The tools are `nix run .#dev`, `.#shot` and
`.#input`, or `loft-dev` (also `loft dev`), `loft-shot` and `loft-input` on PATH.

## Rules

- Work only in **your own named session**. Never send input to the live desktop
  (`--live`) unless the user explicitly asked for that.
- Stop your session with `loft-dev --stop NAME`. Kill only PIDs you started. Never
  `pkill`/`pkill -f`.
- The session gets a scratch `$HOME`, but the system bus is shared, and the shell
  inherits `LOFT_LIBRARY` / `LOFT_SPACES_DIR`: pass scratch ones when the test writes
  library data. Don't toggle the Control Center's Ethernet, Bluetooth or Power tiles.
- KDE tools (qdbus, loft-kwin, kscreen-doctor) must run with the session's
  environment, never the host's: see `k` below.

## Loop

```sh
nohup nix run .#dev -- --session NAME --compositor kwin "$PWD" > /tmp/NAME.log 2>&1 &
#   options: --shell loft|plasma (plasmashell, to compare) · --size WxH · --output-count N
until [ -f "$XDG_RUNTIME_DIR/loft-dev-NAME/session.env" ]; do sleep 0.2; done; sleep 10   # the shell takes ~10 s to draw
k() { env -u NIRI_SOCKET bash -c 'set -a; . "$XDG_RUNTIME_DIR/loft-dev-NAME/session.env"; set +a; exec "$@"' _ "$@"; }

loft-shot  -s NAME --max 1200 --grid --out /tmp/s.png     # look; read coords off the rulers
loft-shot  -s NAME --zoom X,Y,W,H --grid                  # detail
loft-shot  -s NAME --zoom … --mark X,Y                    # confirm a target before clicking
loft-input -s NAME click X Y          # click right X Y · click X Y --double · move X Y
loft-input -s NAME drag X1 Y1 X2 Y2   # press–move–release (sliders, title bars)
loft-input -s NAME scroll down 3 --at X Y
loft-input -s NAME type "text"        # key ctrl+a Escape Return …
loft-input -s NAME key super+space    # global shortcuts: key combos reach KWin (Spotlight)
loft-input -s NAME bind kwin/Overview # a kglobalaccel shortcut by COMPONENT/NAME (bind --list)
loft-input -s NAME spawn kwrite       # start an app inside the session
k loft-kwin state | jq '.windows'     # windows, desktops, outputs as the shell sees them
k qdbus org.kde.KWin …                # KWin's D-Bus in the session
loft-dev --stop NAME                  # stops the whole unit (loft-dev-kwin-NAME)
```

Every coordinate is in global logical px, the numbers on `loft-shot`'s rulers.
After each action, take a screenshot again to check the result before the next step.

Batch steps with `loft-input -s NAME script <<'EOF'`, one command per line, with
`wait MS` and `shot ARGS…` lines in between.

## Facts that save time

- `loft-shot` works as usual (`--output WL-0`, `--region`, `--grid`); `--window` and
  `--layer` are niri-only. `loft-input info` lists outputs only; windows come from
  `k loft-kwin state`.
- Plasma windows and popups can take a second or two to appear; screenshot again
  before concluding a click missed.
- `LOFT_SESSION=NAME nix run .#loft -- --dev theme apply latte` re-themes your session
  (set `LOFT_DEV=1` so theme hooks never touch the real desktop).
- QML edits in the checkout hot-reload into a running session.
- The session has no audio (the volume slider does nothing, on purpose). `--share-audio`
  connects real audio. Use it only when the test is about audio.
- Loft's keyboard layer (xremap) and its kglobalaccel shortcuts load in a nested
  session only partly; test a remap on a real desktop, a shortcut with `bind`.

## Legacy: niri sessions

`loft-dev` without `--compositor kwin` still starts the old niri session. There
`bind COMBO` runs a niri keybind through niri IPC (niri ignores virtual keys for
binds), `info` lists windows and layers, and `--window` / `--layer` shots work. Use
it only when asked to look at niri.
