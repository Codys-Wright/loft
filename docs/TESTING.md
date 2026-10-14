# Testing the desktop: sessions you can see and drive

Loft ships three tools for testing the desktop by looking at it and using it,
whether you're an agent or a person:

| Tool | What it does |
|---|---|
| `loft-dev --session NAME` | starts an isolated test session: the whole desktop (niri + the shell from a checkout) on an offscreen output |
| `loft-shot --session NAME …` | screenshots it — whole session, an output, a region, a window — with zoom, a coordinate grid and crosshair marks |
| `loft-input --session NAME …` | drives it with a virtual mouse and keyboard: move, click, drag, scroll, type, key combos, niri keybinds |

All three are in the dev shell's flake: `nix run .#dev -- …`, `nix run .#shot -- …`,
`nix run .#input -- …`. Inside a session (its terminals, scripts it spawns) `loft-input`
and `loft-shot` are on PATH and pick that session by themselves.

## Rules

- **Never drive the live desktop unless the person explicitly asked you to.** `loft-input`
  refuses to without `--live`. Screenshots of the live desktop (`loft-shot --live`) are
  read-only and harmless.
- **Use your own session name** (e.g. your task: `dock`, `extras-2`). A session only ever
  replaces *itself*; two agents with different names never touch each other's session.
- **Kill only what you started.** Stop your session with `loft-dev --stop NAME`. Never
  `pkill`/`pkill -f` by pattern: it has killed the calling shell before, and it can hit
  other agents' sessions or the live desktop.
- A test session shares `$HOME` with the real desktop. Apps you start in it see the real
  config and files, and so do the shell's settings that live outside the session's state dir.
  Prefer throwaway files in your scratch dir. For GTK apps that restore their last session,
  pass flags that skip it (e.g. `gnome-text-editor --standalone FILE`). Don't open the user's
  documents.
- The **system** D-Bus is shared. Control Center tiles for Ethernet, Bluetooth and Power Mode
  act on the real machine, so don't toggle them. The session bus, the runtime dir and audio are
  private (see below).

## Sessions

```sh
loft-dev --session NAME [--size 1600x1000] [CHECKOUT]     # start (blocks; run it in the background)
loft-dev --list                                            # sessions, mode, size, display
loft-dev --stop NAME                                       # stop yours
```

A named session is, by default:

- **headless**: niri runs fullscreen inside a headless wlroots compositor (sway, pixman
  renderer) whose single output is exactly `--size` (default 1600x1000). Everything renders in
  software (Mesa llvmpipe). The session never touches the GPU, never appears on a monitor,
  causes no modesets on the host, and works while the desktop is locked. Its screenshots
  always have the same size.
- **isolated**:
  - its own D-Bus session bus, with service activation off, so the launcher (walker), the
    notification server and the global-menu registrar never meet the live desktop's;
  - its own `XDG_RUNTIME_DIR` (`$XDG_RUNTIME_DIR/loft-dev-NAME/run`), so the Wayland and
    IPC sockets, elephant and the clipboard cache are separate;
  - its own cliphist db and state dir (theme, niri overrides).
- **silent**: no audio server, so dragging the volume slider can't change the real volume.
  `--share-audio` links the host's PipeWire in, but only do that when the test is about audio.

Run it in the background and wait for `session.env`:

```sh
nohup loft-dev --session dock "$PWD" > /tmp/dock-session.log 2>&1 &
echo $! > /tmp/dock-session.pid           # yours to kill, if --stop isn't enough
until [ -f "$XDG_RUNTIME_DIR/loft-dev-dock/session.env" ]; do sleep 0.2; done     # ~2-5 s
loft-input --session dock info            # outputs, windows, layer surfaces
```

The shell needs a second or two after that to draw its bar. Take a screenshot to check.

Other modes:

- `--on-host`: a window on the desktop you're running in, instead of headless. On niri a named
  session floats at `--size`. Note that niri ignores window actions while the screen is locked,
  and a window on a workspace nobody looks at only gets about one frame callback a second.
  Use it only when a person wants to watch.
- `loft-dev` without `--session` is the developer's own `dev` session: a window, fullscreen
  on the rightmost monitor (niri or KDE), on the shared bus and runtime dir. Don't use it for
  agent tests.
- `loft --dev …` (theme apply, etc.) targets `$LOFT_SESSION`, so for a named session run
  `LOFT_SESSION=dock nix run .#loft -- --dev theme apply latte`.

Hot reload works as in the dev session: QML saves reload the shell, KDL saves reload niri.

## Looking: loft-shot

Every image maps to **global logical coordinates**, the same numbers `loft-input` clicks.
stderr says how, for example
`loft-shot: 0,0 1600x1000 → 1254x772 px; global = (0, 0) + (px - (54, 22) rulers) / 0.75`.

```sh
loft-shot -s dock --max 1200 --grid --out shot.png         # overview with a coordinate grid
loft-shot -s dock --zoom 1300,0,300,32 --grid               # crop + upscale (bar's right end)
loft-shot -s dock --mark 1497,15 --zoom 1350,0,250,30       # check a click target before clicking
loft-shot -s dock --window "Loft Settings"                  # a window, by id / app id / title
loft-shot -s dock --region 600,250,630,80                   # any rectangle X,Y,W,H
loft-shot -s dock --output winit                            # one output
loft-shot -s dock --layer loft:bar                          # the output a layer surface is on
```

- `--grid [N]` draws lines every N logical px (auto when N is omitted), with the coordinates
  on rulers outside the picture so the labels never cover anything. Read a target's x off the
  top ruler and its y off the left ruler.
- `--mark X,Y` (repeatable) draws a crosshair labelled `X,Y`. Use it to confirm a planned
  click before you click.
- `--max N` caps the longer side (use about 1200–1600 for image input), `--scale F` resizes,
  `--crop X,Y,W,H` crops relative to the target, `--delay MS` waits first, `--cursor` includes
  the pointer, `--json` prints `{path, region, width, height, px_per_unit, origin_px, grid}`.
- Window geometry: niri 26.04 reports positions only for **floating** windows. For a tiled
  window, `--window` has niri render the window alone (`--window-render`, automatic in test
  sessions), so coordinates in that image are window-local. To click into a tiled window, read
  its position off a `--grid` screenshot of the whole session.
- niri reports no geometry for layer surfaces (bar, dock, panels), so `--layer` captures their
  output. Zoom into the part you need with `--zoom`.

## Driving: loft-input

```sh
loft-input -s dock info                            # what's where (windows with global rects)
loft-input -s dock click 1497 15                   # left click at X Y   (click [left|right|middle|back|forward] [X Y] [--double])
loft-input -s dock click right 120 171             # context menu
loft-input -s dock move 800 500                    # --output NAME: relative to that output
loft-input -s dock down left 1245 387              # press and hold … (up [BUTTON] [X Y])
loft-input -s dock drag 330 72 1100 400 --duration 600     # real press–move–release (--steps, --hold, --button)
loft-input -s dock scroll down 5 --at 800 550      # wheel notches; --smooth: touchpad pixels
loft-input -s dock type "hello, wörld → ok"        # any unicode; \n = Return in scripts
loft-input -s dock key ctrl+a Escape super+space # combos: ctrl shift alt super mod, plus key names
loft-input -s dock keydown shift … keyup shift     # held keys (within one script)
loft-input -s dock bind mod+space                  # run a niri keybind (see below)
loft-input -s dock spawn foot                      # start a program inside the session
loft-input -s dock wait 500
```

**Scripts** run many steps on one connection, fast and in order, and can take screenshots in
between:

```sh
loft-input -s dock script <<'EOF'
bind mod+space             # Spotlight
wait 700
type kitty
key Return
wait 2500
shot --max 1200 --grid --out /tmp/after.png
EOF
```

A script has one command per line, the same syntax as the command line, with `#` comments and
shell-style quotes. `shot ARGS…` runs `loft-shot` on the same session.

### niri keybinds: use `bind`, not `key`

niri never sees virtual-keyboard keys. smithay hands them straight to the focused app's
`wl_keyboard`, bypassing the compositor's input handling (`smithay
src/wayland/virtual_keyboard/virtual_keyboard_handle.rs`). So `key mod+space` reaches the
focused app, and no niri bind fires: not Spotlight, not the overview, not focus/move actions.
`wtype` has the same limitation.

`loft-input bind COMBO` works around this. It looks the combo up in the session's own niri
config (all includes, the last definition wins, Mod resolved through `mod-key` /
`mod-key-nested`) and runs the bound action through niri IPC (`niri msg action …`). Spawned
commands run inside that niri, with the session's environment.

```sh
loft-input -s dock bind --list              # Mod = ISO_Level3_Shift, then every bind
loft-input -s dock bind --dry-run mod+a     # Mod+A → niri msg action spawn -- quickshell ipc … controlcenter toggle
```

`key` prints a hint when you send a combo that is really a niri bind. The **virtual pointer**
does go through niri's normal input path: clicks, drags (including dragging a window by its
header bar, which starts niri's interactive move), wheel and pointer binds all behave like a
real mouse. Mod+drag needs Mod held on a *real* keyboard, so it can't be done virtually. Drag
by the header bar instead.

### The live desktop (only when asked)

`loft-input --live …` drives `$WAYLAND_DISPLAY` with the same protocols. It reaches the focused
window and whatever is under the pointer, while the person may be using it. For example, to
open the person's Control Center after they asked you to:
`loft-input --live info` → `loft-shot --live --output DP-4 --zoom … --mark …` →
`loft-input --live click X Y`.

As a last resort, `--uinput --live --yes-live` creates kernel input devices (needs the
`uinput` group). niri binds fire, but every event goes to the whole seat, so whatever has
focus on the real desktop gets it. Nested and headless sessions can't receive uinput at all.
This mode is untested by design.

## Worked example

```sh
S=/tmp/my-scratch; mkdir -p $S
nohup loft-dev --session demo "$PWD" > $S/session.log 2>&1 &
until [ -f "$XDG_RUNTIME_DIR/loft-dev-demo/session.env" ]; do sleep 0.2; done; sleep 2

# 1. Spotlight: open, type, launch
loft-input -s demo bind mod+space
loft-input -s demo type kitty
loft-shot    -s demo --region 300,100,1000,700 --out $S/spotlight.png
loft-input -s demo key Return

# 2. Control Center: find the gear icon in the bar, check, click
loft-shot    -s demo --zoom 1300,0,300,32 --grid --out $S/bar.png          # gear at ≈1497,15
loft-shot    -s demo --zoom 1350,0,250,30 --mark 1497,15 --out $S/check.png
loft-input -s demo click 1497 15
loft-shot    -s demo --region 1000,0,600,750 --grid 50 --out $S/cc.png

# 3. Drag a slider (Settings → Layout & Motion → Gaps; writes only this session's overrides)
loft-input -s demo click 1497 15                         # close the Control Center
loft-input -s demo bind mod+comma                        # Settings (a floating window: see `info`)
loft-input -s demo info                                  # "Loft Settings" 370,175 860x600
loft-shot    -s demo --window "Loft Settings" --grid 50 --out $S/settings.png
loft-input -s demo click 464 525                         # Layout & Motion
loft-input -s demo drag 1010 292 1110 292 --duration 500

# 4. Scroll, right-click, drag a window
loft-input -s demo spawn gnome-text-editor --standalone $S/note.txt
loft-input -s demo scroll down 3 --at 400 500
loft-input -s demo click right 120 171                   # GTK context menu
loft-input -s demo key Escape
loft-input -s demo drag 330 72 1100 400 --duration 600 # by the header bar: niri moves the window

loft-dev --stop demo
```

## How it works (for maintainers)

- `crates/loft-input`: the `loft-input` and `loft-shot` binaries.
  - `zwlr_virtual_pointer_v1` without an output: niri maps absolute motion onto the bounding
    box of all outputs, so coordinates are global logical px (quarter-pixel precision).
  - `zwp_virtual_keyboard_v1`: a US keymap on real evdev codes, plus spare keycodes for
    characters a US keyboard can't type.
  - Key combos, scripts and bind lookup are unit-tested (`nix flake check`).
- `nix/dev/loft-dev.sh`: session dirs `$XDG_RUNTIME_DIR/loft-dev[-NAME]`, with
  `session.env` (NIRI_SOCKET, WAYLAND_DISPLAY, NIRI_PID, XDG_RUNTIME_DIR,
  DBUS_SESSION_BUS_ADDRESS, …). The headless host is `sway` with `WLR_BACKENDS=headless
  WLR_RENDERER=pixman`, and the session renders through Mesa's EGL vendor with
  `LIBGL_ALWAYS_SOFTWARE=1`. The CPU cost is near zero when idle and a few cores during
  animations.
