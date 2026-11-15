---
name: loft-drive
description: See and drive the Loft desktop in an isolated test session (niri, or KDE/KWin with --compositor kwin) — start a headless session with loft-dev, screenshot it with loft-shot (grid, zoom, marks), and click/type/drag/scroll/run niri keybinds with loft-input. Use when testing or verifying shell/QML/niri changes visually, or whenever asked to interact with the desktop.
---

# Driving a Loft test session

Full reference: `docs/TESTING.md` in the Loft checkout. The tools are `nix run .#dev`,
`.#shot` and `.#input`, or `loft-dev` (also `loft dev`), `loft-shot` and `loft-input` on PATH.

## Rules

- Work only in **your own named session**. Never send input to the live desktop
  (`--live`) unless the user explicitly asked for that.
- Stop your session with `loft-dev --stop NAME`. Kill only PIDs you started. Never
  `pkill`/`pkill -f`.
- `$HOME` and the system bus are shared. Use scratch files, don't open the user's documents,
  and don't toggle the Control Center's Ethernet, Bluetooth or Power tiles.

## Loop

```sh
nohup nix run .#dev -- --session NAME "$PWD" > /tmp/NAME.log 2>&1 &     # headless, 1600x1000, isolated
until [ -f "$XDG_RUNTIME_DIR/loft-dev-NAME/session.env" ]; do sleep 0.2; done; sleep 2

loft-input -s NAME info                                   # windows (floating ones with global rects), layers
loft-shot  -s NAME --max 1200 --grid --out /tmp/s.png     # look; read coords off the rulers
loft-shot  -s NAME --zoom X,Y,W,H --grid                  # detail
loft-shot  -s NAME --zoom … --mark X,Y                    # confirm a target before clicking
loft-input -s NAME click X Y          # click right X Y · click X Y --double · move X Y
loft-input -s NAME drag X1 Y1 X2 Y2   # press–move–release (sliders, header bars)
loft-input -s NAME scroll down 3 --at X Y
loft-input -s NAME type "text"        # key ctrl+a Escape Return …
loft-input -s NAME bind mod+space     # niri keybinds: ALWAYS `bind`, never `key` (see below)
loft-input -s NAME spawn foot         # start an app inside the session
loft-dev --stop NAME
```

Every coordinate is in global logical px, the numbers on `loft-shot`'s rulers and in `info`.
After each action, take a screenshot again to check the result before the next step.

Batch steps with `loft-input -s NAME script <<'EOF'`, one command per line, with
`wait MS` and `shot ARGS…` lines in between.

## KDE sessions (KWin)

To test Loft's shell (or stock plasmashell) on KWin, start the session with
`--compositor kwin [--shell loft|plasma]` (optionally `--size WxH --output-count N`). It
runs in the user unit `loft-dev-kwin-NAME` with a scratch `$HOME`; `loft-dev --stop NAME`
stops all of it. Wait for `session.env` as above, then give the shell ~10 s to draw.

- `loft-shot` works as usual (`--output WL-0`, `--region`, `--grid`); `--window` / `--layer`
  don't (no niri).
- `loft-input click/type/drag/scroll` work. **`key` combos reach KWin itself**, so global
  shortcuts fire with `key` (`key super+w` → Overview). `bind COMPONENT/NAME` runs a
  kglobalaccel shortcut by name (`bind kwin/Overview`; `bind --list`).
- `loft-input spawn kwrite` starts an app in the session. `info` lists outputs only.
- KDE tools against the session: `env -u NIRI_SOCKET bash -c 'set -a; . "$XDG_RUNTIME_DIR/loft-dev-NAME/session.env"; set +a; qdbus org.kde.KWin …'`.
- Plasma windows and popups can take a second or two to appear; screenshot again before
  concluding a click missed.

## Facts that save time

- **niri keybinds don't fire for virtual keys** (smithay sends them straight to the focused
  app). `bind COMBO` looks the bind up in the session's config and runs it through niri IPC.
  `bind --list` shows them all (Mod is ISO_Level3_Shift). Some useful ones: `mod+space`
  Spotlight, `mod+a` Control Center, `mod+comma` Settings, `mod+o` overview, `mod+return`
  terminal.
- A `key` / `type` gives the focused app the virtual keyboard's keymap. After that, foot no
  longer scrolls less / vim with the wheel. To test wheel scrolling in a pager, send it no keys
  (use `scroll up N` to go back) or open a fresh foot.
- The pointer is a real pointer to niri. Clicks, drags and dragging a window by its header bar
  all work. Mod+drag doesn't (it needs Mod held on a real keyboard).
- niri reports positions only for floating windows. For tiled windows, find them on a
  `--grid` screenshot. `loft-shot --window` falls back to a window-local render. Layer
  surfaces (bar, dock, panels) have no reported geometry, so zoom into them.
- The session has no audio (the volume slider does nothing, on purpose). `--share-audio`
  connects real audio. Use it only when the test is about audio.
- `LOFT_SESSION=NAME nix run .#loft -- --dev theme apply latte` re-themes your session.
- QML and KDL edits in the checkout hot-reload into a running session.
