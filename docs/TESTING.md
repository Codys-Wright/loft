# Testing the desktop: sessions you can see and drive

Loft ships three tools for testing the desktop by looking at it and using it,
whether you're an agent or a person:

| Tool | What it does |
|---|---|
| `loft-dev --session NAME` (or `loft dev …`) | starts an isolated test session: the whole desktop (niri + the shell from a checkout) on an offscreen output |
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
  documents. The Utilities window's Cleaner and Media Tools recents list and delete in `$HOME`:
  start the session with `LOFT_TEST_HOME=<scratch tree>` exported and they use that instead
  (the Cleaner shows a "Test home" banner, and its schedule skips systemctl).
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
  - its own cliphist db and state dir (theme, niri overrides);
  - its own launcher caches (`XDG_CACHE_HOME` for elephant/walker: files index, history,
    favicons) and script-commands folder, and Spotlight's Lock / Log Out / Restart / Shut
    Down / Sleep / Empty Trash are only logged to `<state>/launcher-dryrun.log`, never run.
  - the shell's Eject (Drives.qml) only logs its `udisksctl unmount / lock / power-off` and
    `eject` calls to `<state>/eject-dryrun.log`. To give it drives to list, put an `lsblk`
    shim that prints a fixed `lsblk -J` tree in `<state>/bin` (it's first on the session's
    PATH; create the dir before starting the session), then `quickshell ipc … call drives refresh`.
- **silent**: no audio server, so dragging the volume slider can't change the real volume.
  `--share-audio` links the host's PipeWire in, but only do that when the test is about audio.
- **no screen capture**: niri runs on a software renderer here, so it offers dmabuf only at v3,
  and Quickshell's ScreencopyView would end the shell with a protocol error (it always asks for
  v4 feedback). The dock preview checks first (`loft dock capture`) and shows icons. To test its
  thumbnails, start the shell with `LOFT_DEV_PREVIEW_STILL=<a loft-shot PNG of the session>`
  in its environment: that still stands in for the display capture.

### Several monitors: `--outputs`

```sh
loft-dev --session spaces --outputs 1440x2560,5120x1440,2560x1440 "$PWD"   # left to right
loft-dev --session walls --outputs 5120x1440+1440+0,1440x2560+0+0          # with positions
```

niri's nested (winit) backend only ever has one output, so `--outputs` runs niri on
**virtual outputs** instead: its own headless backend (made usable at runtime by
`nix/dev/niri-headless-outputs.patch`, the `loft-niri-headless` package), with no host
compositor at all. Each entry becomes `headless-1`, `headless-2`, … in that order, placed left
to right unless `+X+Y` gives a position. Their identities are `niri headless 1`, … (so roles
and `open-on-output` by identity work). Frames are paced at 60 Hz, clients render with shm
(Mesa llvmpipe), and screenshots work as usual (`loft-shot --output headless-2`).

- niri here (and in nested sessions) is `niri-loft`, with per-workspace wallpaper surfaces on
  (`niri/workspace-wallpapers.kdl` included, `LOFT_NIRI_WORKSPACE_LAYERS=1` for the shell).
  `--stock-wallpapers` runs without them (stock niri when nested; the rule left out with
  `--outputs`), so the shell swaps one wallpaper per screen as on a stock niri.
  `quickshell ipc --path <checkout>/src call wswallpapers stats` reports the surfaces and decoded
  image MB; `LOFT_WS_WALLPAPERS_ALL=1` in loft-dev's environment maps every workspace (the naive
  cost, for comparison).
- Unplug and replug a monitor: `niri msg output headless-3 off` / `… on` (niri's real hotplug
  path: its workspaces move to the first monitor and come back).
- `RUST_LOG=niri=info,niri::ipc_action=debug,niri::headless_frame=debug` in loft-dev's
  environment logs every IPC action and every rendered frame per output, with timestamps
  (how SPACES.md §3.1's frame measurements were made).
- There's no input device: drive it with `loft-input` as usual. Mod is `mod-key` (the
  session isn't nested), `bind` knows that.

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

### Virtual keys change the app's keymap

The virtual keyboard uploads its own keymap, and niri hands the focused app the keymap of the
keyboard it last used. After one `key` / `type` into foot, foot no longer turns wheel notches
into arrow keys in full-screen programs (less, vim): the wheel does nothing there until you
open a new foot. To test scrolling (e.g. scrolling capture's Auto) in `foot less FILE`, don't
send keys to that foot. Go back to the top with `scroll up N` instead of `key g`.

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

### A checkout as your real desktop: `loft dev live`

To use a branch for real (your niri, windows, state, settings and theme), let the checkout
take over from the installed Loft instead of running it in a window:

```sh
loft dev live            # from the checkout (= nix run .#live): installed shell + launcher stop,
                         #   the checkout's run with hot reload (QML, niri fragments, themes)
loft dev live status
loft dev live stop       # hand back to the installed Loft
```

While it runs, `$XDG_RUNTIME_DIR/loft-live/active` exists and the installed `loft-shell` /
`loft-launcher` units refuse to start, so a home-manager switch or a crash restart can't
bring them back underneath (`programs.loft`). The live shell's unit removes it when it stops,
including when the session ends, so a reboot or a new login is always the installed Loft. Logs: `journalctl --user -fu loft-live-shell`.

The compositor can't be swapped under a running session. `loft dev live --niri` builds the
checkout's `niri-loft` into `~/.local/state/loft/dev/niri`. If the session's niri is the
`niri-loft-live` package (`programs.niri.package`), the next login runs that build, as long
as it accepts the config. `loft dev live stop --niri` (or removing the link from a TTY) goes
back to the installed niri at the next login.

Agents: this changes the person's desktop. Only start it when asked.

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

## Capture tests: sideways scrolling and workspace panoramas

Both run against your own session; point captures at a scratch dir first (the session's
`<state>/overrides/capture.json`: `screenshotDir`, `recordingDir`, `copyToClipboard: false`).
Run the CLI with the session's environment (`session.env`: `NIRI_SOCKET`, `WAYLAND_DISPLAY`)
so every `niri msg` / `grim` / `loft-pointer` call reaches the session and nothing else.

- **Sideways**: `loft-input -s NAME spawn foot less -S -#16 WIDE.txt` (long lines), `bind`
  or `niri msg action maximize-column`, then `quickshell ipc … call capture scrolling`, drag
  the area with `loft-input drag`, click into it (the pager gets the keys) and press `key Right`
  a few times: the direction is detected (`capture scrollAxisState` → `x`), `scrollWidth` grows,
  `scrollDone` writes the PNG. For Auto Scroll sideways use an app that takes the horizontal
  wheel, e.g. Firefox with a throwaway profile (`--no-remote --profile SCRATCH`) on a wide
  HTML table with a `position: sticky` first column (the track headers stay once):
  `capture scrollAxis x`, `capture scrollAuto`, poll `scrollAutoState` until `off end`.
- **Panorama**: spawn several `foot`s, give them different widths (`set-column-width`), stack
  one (`consume-or-expel-window-left`), tab one (`toggle-column-tabbed-display`), float one
  (`toggle-window-floating`), then `loft capture panorama --insets 0,0,30,76 --out X.png`
  (or `capture panorama ""` through the shell). `--plan` prints the computed layout without
  touching anything. Compare a `loft-shot` before and after: the view should come back.
- The session's PATH has `<checkout>/target/debug` only if it existed when the session
  started. After changing `loft-pointer`, either restart the session or link the fresh build
  into the session's own `bin`: `ln -sf $PWD/target/debug/loft-pointer
  $XDG_RUNTIME_DIR/loft-dev-NAME/bin/`.

## Performance: the shell's own cost, video wallpapers

**Is it keeping up?** `loft doctor perf` (or `quickshell ipc … call perf status` for the JSON)
asks the running shell (`src/services/Perf.qml`) for its CPU %, RSS, main-thread lag p50 / p99 /
max over the last 30 s (a 100 ms timer measuring how late it fires), video wallpapers loaded /
playing / held and how they decode, wallpaper surfaces, child processes and reloads, then adds
the shell's children by name (duplicate long-running helpers, zombies) and the journal's
`vaExportSurfaceHandle failed` count. Exit 1 on trouble. In a session: `LOFT_SESSION=NAME loft
--dev doctor perf --pid <the session shell's pid>` (`ls $XDG_RUNTIME_DIR/loft-dev-NAME/run/quickshell/by-pid/`).
`quickshell ipc … call videowallpapers stats` lists every player (screen, display copy or
original, size, playing, why it is held).

**Measuring video on the real GPU**: named sessions render in software (llvmpipe; the shell then
decodes video in software too, `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=,`), so for GPU paths use
`loft-dev --session NAME --gpu --size 2560x1440 CHECKOUT`: the same offscreen, isolated session
with the host sway rendering through gles2 on the first GPU render node (`LOFT_DEV_RENDER_NODE`
picks another) and niri + the shell on its EGL, decoding with VAAPI as the packaged shell does.
One output only (`--outputs` is software). Give it a live wallpaper by writing a same-stem
`.png` + `.mp4` pair from a scratch dir into `<state>/overrides/shell.json`
(`perTheme.<theme>.wallpaper`, or `.displays["niri headless N"]` with `--outputs`); the shell
picks it up. Copies go to `<state>/cache/wallpaper-video` (`LOFT_VIDEO_CACHE`). Sample the
shell's main thread (`/proc/PID/task/PID/stat` utime+stime) and the process
(`/proc/PID/stat`) over 20–30 s; `QT_LOGGING_RULES=qt.scenegraph.time.renderloop=true` in
loft-dev's environment logs every frame per window (how the island's every-frame breathing was
found).

Measured on THEBATTLESHIP (RTX 4080, NVIDIA 615.71, nvidia-vaapi-driver 0.0.18, Qt 6.11.2,
FFmpeg 9.0.1), 2026-10:

| 3 videos playing, 5120x2560 HEVC, minimal Quickshell scene on a headless gles2 sway | GUI thread | process | RSS |
|---|---|---|---|
| stock QtMultimedia, VAAPI (what ran live: export refused → vaGetImage copy-back) | 95–96 % | 101 % | 2.8 GB |
| stock, `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=cuda` (copy-back too) | 66 % | 71 % | 2.8 GB |
| software decode (10-bit) | 44 % | 318 % | 4.4 GB |
| `qtmultimedia-loft`, VAAPI zero-copy, 10-bit | 6.2 % | 8.8 % | 1.5 GB |
| `qtmultimedia-loft`, display copies (5120x1440 + 2 × 2560x1440, 8-bit) | 5.4 % | 9.0 % | 1.0 GB |
| 6 players loaded, never played / played then paused | 0.0 % | 0.0–0.8 % | — |

With VRAM (`nvidia-smi -q -x`, per process), 3 videos playing, after the shared VAAPI device:

| Decode path | 5K 10-bit originals: GUI / VRAM | display copies: GUI / VRAM |
|---|---|---|
| stock Qt, `vulkan,vaapi` (Vulkan picked; frames downloaded) | 83.7 % / 4.0 GB | 20.6 % / 1.3 GB |
| `qtmultimedia-loft`, `vulkan,vaapi` | 83.9 % / 2.3 GB | 18.5 % / 1.0 GB |
| stock Qt, `vaapi` | hung (0 frames) / 7.6 GB | 36.5 % / 2.3 GB |
| `qtmultimedia-loft`, `vaapi` (the default) | 7.6 % / 5.4 GB | 5.6 % / 1.4 GB |

One decoder, `vaapi`, own device: 2560x1440 copy 540 MB, 5120x1440 copy 798 MB, 5K 10-bit
1.93 GB, of which the device (a CUDA context in nvidia-vaapi-driver) is ~264 MB; Vulkan: 317 /
376 / 768 MB but 2.7 / 9.5 / 37 % of the GUI thread. A paused decoder keeps all of it, `stop()`
too; a never-played player holds ~1 MB; unloading frees it. First frame after `play()`: never
played 100–290 ms, paused or stopped 1–33 ms, unloaded and reloaded 85–130 ms. Hence
WallpaperView: neighbours open but never decoding, a played video paused for 10 s and then
reopened (decoder dropped).

Whole shell, one live wallpaper (a 5120x2560 still + video), `--gpu`, fresh session per row,
2026-10-30 (#12): stills only (`wallpaper.video` "still", or Performance mode) 93 MB at
2560x1440 / 185 MB at 5120x1440, Ultra 102 MB; playing the display copy 683 / 1102 MB, the
original 1304 MB. Per-workspace surfaces (`moveWithWorkspaces`) make no difference. nvidia-vaapi-
driver's detached backing-image cache (exported frames kept for reuse, up to VRAM/64 = 256 MB)
was part of that: `NVD_MAX_DETACHED_BACKING_IMAGES=0` (set in `qtMultimediaEnv`, loft-dev,
loft-live) gives 602 / 952 MB, and 952 instead of 1285 MB at the start, with the same CPU (6 %)
and frame lag. What stays per 5120x1440 copy: the shared device (~264 MB, once), the decoder's
surfaces and 9 active backing images (106 MB). `NVD_LOG=<file> NVD_STATS=1` in loft-dev's
environment logs decoders and backing-image counts.

Zero-copy with FFmpeg's frame threads hung the GUI thread in 4 of 16 starts
(`waitSurfaceResolved` in nvidia-vaapi-driver); with one decoder thread: 0 of 25.
`ffmpeg -i X -f null -` on one 12 s 5K clip, CPU per second of video: software 1.6 cores,
`-hwaccel cuda -hwaccel_output_format cuda` 0.05, VAAPI zero-copy 0.08, VAAPI copy-back 0.77
(and only ~26 fps: vaGetImage is the bottleneck), CUDA copy-back 0.5.

The whole Loft shell in a `--gpu` session (2560x1440, one video): no video 0.3 % GUI thread;
still frame held 0.6 %; the display copy playing 3.0 % (RSS 775 MB); the 5K 10-bit original
4.2 % (968 MB). Before the island's pulse was stepped (`components/SlowPulse.qml`), the island
alone redrew every frame while an AI agent was busy: 60 frames/s here (~3 % of the GUI thread),
the refresh rate of each display live (240 + 180 + 180 Hz).

## How it works (for maintainers)

- `crates/loft-input`: the `loft-input` and `loft-shot` binaries, plus `loft-pointer` (the
  product's Auto Scroll helper for scrolling capture: pointer motion + wheel notches — vertical,
  or horizontal with `--axis horizontal` — on the `--display` it is given, never anything else;
  its pacing and stop logic, and that only motion and the chosen wheel reach the compositor,
  are unit-tested).
  - `zwlr_virtual_pointer_v1` without an output: niri maps absolute motion onto the bounding
    box of all outputs, so coordinates are global logical px (quarter-pixel precision).
  - `zwp_virtual_keyboard_v1`: a US keymap on real evdev codes, plus spare keycodes for
    characters a US keyboard can't type.
  - Key combos, scripts and bind lookup are unit-tested (`nix flake check`).
- `--outputs`: `nix/dev/niri-headless-outputs.patch` selects niri's test-only headless backend
  when `NIRI_HEADLESS_OUTPUTS=WxH,…` is set, adds a renderer (EGL surfaceless, for
  screencopy), paces frames with a 16.7 ms timer like a vblank, and turns `output … off|on`
  into removing / re-adding the output.
- `nix/dev/loft-dev.sh`: session dirs `$XDG_RUNTIME_DIR/loft-dev[-NAME]`, with
  `session.env` (NIRI_SOCKET, WAYLAND_DISPLAY, NIRI_PID, XDG_RUNTIME_DIR,
  DBUS_SESSION_BUS_ADDRESS, …). The headless host is `sway` with `WLR_BACKENDS=headless
  WLR_RENDERER=pixman`, and the session renders through Mesa's EGL vendor with
  `LIBGL_ALWAYS_SOFTWARE=1`. The CPU cost is near zero when idle and a few cores during
  animations.
