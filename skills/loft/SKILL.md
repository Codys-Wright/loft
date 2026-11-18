---
name: loft
description: Configure the Loft desktop (Loft's Quickshell shell in a KDE Plasma session, on KWin) and write window rules — open an app on a KDE Activity, virtual desktop or display, at a size and position, maximized / full screen / kept above — place one launch with `loft open`, and fix keyboard remaps per app (macOS-style keys via xremap). Use when asked to change Loft settings or its theme, how an app's windows open, or when an app's keyboard shortcuts misbehave, including apps being developed that should always land somewhere specific.
---

# Configuring Loft and writing window rules

**Loft is a macOS-style shell for KDE Plasma.** It replaces plasmashell inside a
normal Plasma session ("Loft" in SDDM, `loft-plasma-session`): KWin is the
compositor, KDE's services (PowerDevil, kscreenlocker, KScreen, kglobalaccel,
Activities) stay, and Loft draws the bar, dock, Spotlight, Control Center, island
and Settings. **niri is abandoned (2026-11-18):** the niri session still builds but
gets no new work. Write, test and document for KDE; see "Legacy: niri" at the end
only when a machine still runs it.

Most of what a user changes is runtime state that the `loft` CLI and the Settings
app edit; a few install-time choices are Nix options. Window rules are Loft's own
records, applied by Loft's KWin script as windows open (never `kwinrulesrc`).

## Rules first

- **Live desktop vs. test session.** Without `--dev`, every `loft …` command
  changes the user's running desktop. That is right when the user asked for the
  change. To try something first, use a KDE test session (end of this file) and
  point commands at it with `LOFT_SESSION=NAME loft --dev …`.
- **Never `loft windows reset` without an app id** (it drops every rule and the
  glass settings). `loft theme reset` is just as broad.
- **Don't edit generated files**: `$LOFT_STATE_DIR/current/*`,
  `$XDG_RUNTIME_DIR/loft/plasma-keys/*`, `xremap/config.json`. Change the source
  (CLI / Settings / Nix) and let Loft render.
- **Don't write `kwinrulesrc`, `plasma-org.kde.plasma.desktop-appletsrc` or
  `plasmashellrc`.** Loft keeps out of them so plain Plasma comes back untouched
  (docs/KWIN.md §5). Loft's KWin changes are runtime-only and reverted when its
  shell stops.
- Window rules act when a window **opens**. After adding one, reopen the app or
  move its open windows (§5).

## Which shell is running

```sh
loft-plasma status            # the session's choice (loft | plasma) and what runs
loft-plasma use loft          # switch a running Plasma session to Loft's shell
loft-plasma use plasma        # back to plasmashell (Loft leaves no traces)
systemctl --user status loft-plasma-shell loft-plasma-launcher loft-plasma-keys
journalctl --user -u loft-plasma-shell -b
```

After three shell crashes in a minute `loft-plasma-fallback` hands the session to
plasmashell and sends a notification ("Loft stopped"); `loft-plasma use loft`
brings it back once the cause is fixed.

## Where configuration lives

| Layer | Where | Changed with | Takes effect |
|---|---|---|---|
| Install-time (Nix) | `programs.loft.*` in the user's home-manager config, `programs.loft.plasma` in the NixOS module (find it: `grep -rn "programs.loft" <their nix config>`) | edit + rebuild (on Cody's fleet: deploy from `~/.flake`) | after the switch |
| Runtime state | `$LOFT_STATE_DIR` (default `~/.local/state/loft`) | `loft …` CLI, Settings app | immediately |
| Themes / library | `$LOFT_LIBRARY` (default `~/Documents/Loft`) | `loft theme …`, `loft library …` | on apply |
| KDE's own settings | `~/.config/k*rc`, System Settings | KDE; Loft's Settings write some (Displays via KScreen, Keyboard & Mouse, idle timings) | live |

### The `loft` CLI (runtime)

`loft --help` lists everything; every subcommand has `--help`. The useful ones:

```sh
loft theme list | current | apply NAME | state      # themes; facets: loft colors|material|motion|shape|typography|icons|wallpapers|lock|launcher|sounds …
loft appearance …                                   # Transparency / Blur dials
loft windows list                                   # per-app rules (+ glass, niri-only)
loft windows rule APP-ID [FIELD=VALUE…]             # per-app window rule (below)
loft open [--activity A --desktop D --monitor M …] -- CMD   # place one launch (below)
loft spaces activities | new | rename | icon | move | order | remove   # KDE Activities (Loft's Spaces)
loft keys show | app APP … | group ID on|off        # the keyboard layer (macOS remaps via xremap), per-app fixes
loft idle status                                    # Loft's idle timings as applied to kscreenlocker / PowerDevil
loft wallpaper … · loft dock … · loft doctor perf
```

Add `--json` (for `windows`: `loft windows --json list`) for machine-readable output.

### Nix options (install-time)

`programs.loft` (Loft's home-manager module, `nix/modules/home.nix` in the Loft
repo; the NixOS module is `nixosModules.default`, which adds the "Loft" SDDM
session and turns on `programs.loft.plasma.enable` for every user):

```nix
programs.loft = {
  enable = true;
  plasma.enable = true;                 # Loft's shell in Plasma (on by default with the NixOS module)
  plasma.kwinPackage = …;               # Loft's patched KWin: Option-drag tiles, apps' window menus
  theme = "default";                    # first theme; the user's choice later wins
  features = [ "spaces" "-island" ];    # defaults for Settings → Features
  idle.lockAfter = 300; idle.screenOffAfter = 600;   # seeds Settings → Lock & Sleep; null = never
  qt.enable = true;                     # Dolphin etc. in the Loft look (qt.global: every Qt app)
  phone.enable = true;                  # iPhone via tether
  keyboard.enable = true;               # macOS-style remaps (xremap, KDE build); seed: keyboard.{groups,apps,classes,remap}
  windowRules."org.kde.kwrite" = { open-on-activity = "Coding"; };   # window rules for every machine
  agentSkills.enable = true;            # installs this skill and loft-drive for Claude Code
  library = "~/Documents/Loft";
};
```

Read the module for the full list and descriptions. Runtime choices (Settings,
CLI) override Nix defaults where both exist.

## Window rules

### 1. Find the app id

```sh
loft-kwin state | jq -r '.windows[] | "\(.id)\t\(.app_id)\t\(.title)\tws=\(.workspace_id)"'
```

`loft-kwin state` is the running shell's view of KWin (niri-shaped JSON:
`windows`, `workspaces` with `kwin_desktop`, `outputs`); it needs Loft's shell
running. The app id is KWin's `resourceClass`: for Wayland apps the toolkit's app
id (GTK: the GtkApplication id; Qt: `QGuiApplication::setDesktopFileName`), for X11
apps the WM_CLASS. Rules also match the desktop file name. **When developing an
app, give it a stable, unique app id** (e.g. `dev.cody.myapp`) so a rule can
target it and nothing else.

### 2. Find the target

```sh
loft spaces activities                       # KDE Activities, in Loft's order (Spaces = Activities)
loft-kwin state | jq -r '.workspaces[] | "\(.output)\tdesktop=\(.kwin_desktop)\tname=\(.name)"'
loft-kwin state | jq -r '.outputs[] | .name'      # or: kscreen-doctor -o
```

- **Activity**: by name; case, spaces, `-` and `_` are ignored. A rule naming an
  Activity created later starts working once it exists. Create one with
  `loft spaces new NAME`.
- **Desktop**: KDE's virtual desktop, by number (1 = first) or name.
- **Display**: a connector (`DP-2`) or a **display role** resolved on the live
  layout (`main`, `left`, `right`, `left-2`, `right-2`, `portrait`, `display-2` …).
  Prefer a role: connectors can renumber.

### 3. Write the rule: `loft windows rule`

```sh
loft windows rule dev.cody.myapp open-on-activity=Coding open-on-desktop=2 open-on-output=right
loft windows rule dev.cody.myapp open-size=1200x800 open-position=center
loft windows rule dev.cody.myapp open-maximized=true keep-above=true follow=false
loft windows rule dev.cody.myapp open-size=          # FIELD= drops one field
loft windows rule dev.cody.myapp                     # show the rule
loft windows reset dev.cody.myapp                    # drop the whole rule
```

It is saved in `$LOFT_STATE_DIR/overrides/niri.json` (`window-rules`; the file
name is historical), shows up in Settings → Window Rules, and reaches KWin within
~2 s (`loft-kwin` watches the file and sends `setWindowRules` to its script). No
rebuild, no reload. It matches the app id **exactly** (`^dev\.cody\.myapp$`)
unless `match-app-id` says otherwise. When several rules match, later ones win
field by field.

| Field | Values |
|---|---|
| `open-on-activity` | a KDE Activity by name |
| `open-on-desktop` | virtual desktop number (1 = first) or name |
| `open-on-output` | connector or display role |
| `open-size` | `1200x800` or `60%x80%` (of the display's work area; capped to it) |
| `open-position` | `center` · `left` / `right` (that half) · `X,Y` |
| `open-maximized` / `open-fullscreen` | true/false |
| `keep-above` | true/false |
| `follow` | true: switch to its Activity/desktop and focus it when it opens · false: it lands there, you stay |
| `match-app-id` | regex replacing the exact key match (the key is then just the rule's name) |
| `match-title` / `exclude-title` / `exclude-app-id` | regexes (a title or app id set in the first 8 s is matched again) |

Booleans also accept on/off/yes/no.

**Not under KWin** (accepted, ignored there; they were niri's): `glass`,
`opacity`, `opacity-unfocused`, `blur` (translucency comes from the theme's
Kvantum style), `open-floating` (every KWin window floats),
`default-column-width`, `square-corners`, `block-out-from`, `open-on-workspace`
(read as a desktop name when `open-on-desktop` is unset). Not implemented: keep
below, on all desktops, minimized, skip taskbar. For those, a KDE window rule
(System Settings → Window Management → Window Rules) is the only route; ask the
user first, since it lives in `kwinrulesrc` and stays when Loft is off.

"Wherever I am, it lands there":

```sh
loft windows rule org.kde.kwrite open-on-activity=Coding open-on-desktop=2 open-on-output=right open-fullscreen=true follow=false
loft windows rule agents match-app-id='^com\.mitchellh\.ghostty$' match-title='^claude' open-on-activity=Coding open-size=1200x800
```

**Declarative / every machine:** `programs.loft.windowRules."org.kde.kwrite" = {
open-on-activity = "Coding"; open-on-desktop = 2; open-on-output = "right";
open-fullscreen = true; };` (→ `~/.config/loft/window-rules.json`, merged under
the runtime rules, field by field).

Details: docs/KWIN.md §4.17.

### 4. One launch, not every window of an app: `loft open`

Agent terminals and dev sessions share an app id (every one is a ghostty / kitty /
konsole), so a rule can't tell them apart. Start them with `loft open`: the windows
of **that process tree** go where you say, the rest of the app's windows open as usual.

```sh
loft open --activity Coding --desktop 2 --monitor right --size 1200x800 -- konsole
loft open --activity Coding --monitor main --fullscreen --follow -- ghostty -e claude
```

Every new window of the process (and its children) for `--ttl` seconds (30);
`--count N` stops earlier; `--app-id REGEX` (default: ends in the command's name)
catches an app that hands its window to an instance already running. It fails
with the reason (and starts nothing) when Loft's shell isn't running or the
Activity / desktop / display doesn't exist. MCP: the `open` tool.

### 5. Windows that are already open

The shell's `loft-kwin` daemon runs commands on KWin through Loft's script
(`loft-kwin send JSON`; without `window` it acts on the active window). The
window's `kwin_uuid` is in `loft-kwin state`:

```sh
u=$(loft-kwin state | jq -r '.windows[] | select(.app_id=="org.kde.kwrite") | .kwin_uuid' | head -1)
loft-kwin send "{\"cmd\":\"moveToDesktop\",\"window\":\"$u\",\"desktop\":2,\"focus\":false}"
loft-kwin send "{\"cmd\":\"moveToOutput\",\"window\":\"$u\",\"output\":\"DP-2\"}"
loft-kwin send "{\"cmd\":\"setWindowActivities\",\"window\":\"$u\",\"activities\":[\"<activity id>\"]}"
loft-kwin send '{"cmd":"toggleMaximize"}'          # also toggleFullscreen, toggleKeepAbove, center, closeWindow
```

Or drag a window onto another Space in the dock / overview (docs/KWIN.md §4.16).
The `loft mcp` tools below do the same by window id.

## Keyboard: when an app's keys misbehave

Loft's keyboard layer remaps keys macOS-style before apps see them: Super = ⌘
(⌘C → Ctrl+C, in terminals ⌘C → Ctrl+Shift+C), Esc / Caps Lock hold = the
window-manager key (sends Meta + the next key, so KWin's and Loft's Meta shortcuts
work), ⌥/⌘ + arrows for word / line navigation, extras for browsers, file
managers and editors. Loft owns the keymap (`cli/loft/keymap/mac.json`); xremap's
KDE build runs it (`loft-plasma-keys.service`, on with
`programs.loft.keyboard.enable`; its KWin script reports the focused window's app
id). Remaps are per **app id**, so a misbehaving app is nearly always "Loft
guesses the wrong kind of app" or "one group fights the app's own shortcuts".

```sh
loft keys app APP-ID            # which groups reach the app (✓) and why not (·) — start here
loft keys show                  # every group (on/off), the app classes, per-app rules
```

The same is in Settings → Keyboard Remaps (the dock's Window Rules ▸ Keyboard
Remaps… opens it on an app). Fix the one app, not the whole layer:

| Symptom | Fix |
|---|---|
| a terminal Loft doesn't know: ⌘C sends Ctrl+C (kills the job), ⌘V doesn't paste | `loft keys app APP --like terminals` (same for `browsers`, `fileManagers`, `codeEditors`, `jetbrains`) |
| one group clashes with the app (e.g. ⌥← / ⌘← navigation in a DAW or game) | `loft keys app APP --off text-editing` (`--on` undoes) |
| the app needs one key sent differently | `loft keys app APP --remap Super_L-k=Ctrl-k` (`--unmap Super_L-k` drops it); a per-app remap wins over every group |
| the app should get raw keys (game, VM, remote desktop) | `loft keys app APP --leave-alone` (also pauses Loft's window shortcuts there; `--no-leave-alone` undoes) |
| a group should change everywhere | `loft keys group ID on\|off\|default` |

Key names are xremap's: evdev names without `KEY_` (`a`, `Esc`, `CapsLock`,
`LeftBrace`, `F13`, `BTN_LEFT`), modifiers `Shift`, `Ctrl`/`C`, `Alt`/`M`,
`Super`/`Win`, optionally `_L`/`_R`, joined with `-` (`Super_L-Shift-t`). A
comma-separated TO is a sequence. Every change is checked before it's saved (an
unknown key or class is refused with the reason) and xremap reloads by itself;
the change is live, no restart. Test by switching to the app and pressing the key.

Runtime changes live in `$LOFT_STATE_DIR/overrides/keymap.json` (don't edit it
by hand). For a fix every machine should get, use the Nix seed instead
(`programs.loft.keyboard.apps."APP".like = [ "terminals" ];`, `.groups`,
`.classes`, `.remap`, `.extraGroups`); runtime still wins over it.

**Global shortcuts** (Meta+Space Spotlight, window commands …) aren't remaps:
Loft registers them in KDE's kglobalaccel while its shell runs (and takes the
keys off KDE actions that had them, giving them back when it stops; docs/KWIN.md
§4.5). Change them in Settings → Keyboard & Mouse → Keyboard Shortcuts.

## `loft mcp`: the desktop as MCP tools for an agent

`loft mcp` is a Model Context Protocol server on stdin/stdout (JSON-RPC 2.0, one
message per line, protocol `2025-06-18`). An agent that runs elsewhere (Hermes)
reaches it over SSH: a forced-command launcher on the desktop machine exports the
user's session environment (`systemctl --user show-environment`:
`WAYLAND_DISPLAY`, `DISPLAY`, `XDG_CURRENT_DESKTOP`, `XDG_RUNTIME_DIR`,
`DBUS_SESSION_BUS_ADDRESS`) and execs `loft mcp`. Under KDE the window tools go
through `loft-kwin state` / `loft-kwin send`, so Loft's shell must be running;
without a session every desktop tool answers `isError` with the reason. Logs
(one line per call) go to stderr. `loft mcp --list-tools` prints the list.

| Tool | Does |
|---|---|
| `list_windows` (`app_id`?) · `focused_window` | id, app_id, title, workspace, output, focused, size |
| `list_workspaces` · `list_outputs` | desktops per output (idx, name, active, window count); displays (connector, identity, logical rect) |
| `focus_window` · `close_window` · `center_window` | by window id (close = the app's close request, not a kill) |
| `move_window_to_workspace` (`workspace` index or name, `focus`?) · `move_window_to_monitor` | |
| `fullscreen_window` · `maximize_window` | toggle |
| `focus_workspace` · `focus_output` · `toggle_overview` (`state` toggle/open/close) | |
| `launch` (`command` argv) · `spotlight_open` | starts it detached in the session |
| `open` (`command`, `activity`, `desktop`, `monitor`, `placement` fullscreen/maximized, `size`, `position`, `keep_above`, `follow`, `app_id`, `count`, `ttl`, `cwd`) | `loft open` (§4) |
| `screenshot_output` (`output`?, `max_width`) · `screenshot_window` (`id`, `max_width`) | PNG (default ≤ 1920 px wide) via KWin's ScreenShot2; a window shot includes its title bar |
| `loft_windows_list` · `loft_windows_rule` (`app_id`, `fields`) | `loft windows …` (fields as in the table above; `null` drops one) |
| `loft_theme_list` · `loft_theme_apply` (`name`, `mode`?) | `loft theme …` |
| `loft_appearance_get` · `loft_appearance_set` (transparency, blur, terminals, gtk) | `loft appearance …` |
| `loft_keys_show` · `loft_keys_app` (`app_id`, `like`/`unlike`/`off`/`on` lists, `remap` {from: to\|null}, `leave_alone`, `reset`) · `loft_keys_group` (`id`, `state`) | `loft keys …` |
| `shell_ipc_list` · `shell_ipc_call` (`target`, `function`, `args`) | the shell's Quickshell IPC (island, controlcenter, settings, mixer, monitor, wallpaper, timers …), only what `SHELL_ALLOW` in `cli/loft/mcptools.py` lists |

niri-only, answering an error under KDE: `set_window_floating`,
`maximize_column`, `set_column_width`, `loft_niri_*`.

Not exposed on purpose: power, log out, lock, killing processes, the phone, the
clipboard, capture / recording / camera, live audio routing, and `enter` in the
bar menus. To add a shell function, add it to `SHELL_ALLOW` (the unit test checks
it exists in `src/`).

Testing: `tests/test_mcp.py` runs in `nix flake check`. Against a test session,
never the live desktop:
`python3 tests/mcp_session.py NAME -- $(nix build --no-link --print-out-paths .#loft)/bin/loft`.

## Trying it in a test session

A whole KDE session, nested and headless, with Loft's shell from the checkout
(details and the screenshot/input tools: the `loft-drive` skill, docs/TESTING.md):

```sh
nix run <loft checkout or github:Codys-Wright/loft>#dev -- --session NAME --compositor kwin "$PWD" &
until [ -f "$XDG_RUNTIME_DIR/loft-dev-NAME/session.env" ]; do sleep 0.2; done; sleep 10
# run a command against the session's KWin and bus, never the live desktop:
k() { env -u NIRI_SOCKET bash -c 'set -a; . "$XDG_RUNTIME_DIR/loft-dev-NAME/session.env"; set +a; exec "$@"' _ "$@"; }
k loft-kwin state | jq -c '.windows[] | {app_id, workspace_id}'
LOFT_SESSION=NAME loft --dev windows rule org.kde.kwrite open-on-desktop=2 open-size=800x600
loft-input -s NAME spawn kwrite
k loft-kwin state | jq -c '.windows[] | {app_id, workspace_id}'
nix run …#dev -- --stop NAME
```

## Legacy: niri

Some machines may still boot the old niri session (`$NIRI_SOCKET` is set). There
everything above works except the KWin-only parts (Activities, `open-position`,
`keep-above`), and these differ:

- Window ids, workspaces and outputs come from `niri msg -j windows|workspaces|outputs`;
  open windows move with `niri msg action move-window-to-workspace|move-window-to-monitor`.
- The rule fields `glass`, `opacity`, `blur`, `open-floating`,
  `default-column-width`, `square-corners`, `block-out-from` and
  `open-on-workspace` (a named niri workspace) work; rules are rendered into
  `overrides/niri.kdl` (don't edit it) and niri reloads. niri settings are
  `loft niri keys|show|set|unset|binds|outputs`.
- The keyboard layer is `loft-keys.service`; the WM key is niri's Mod.

Don't add niri-only features or docs; if a niri-only path breaks, say so and ask
before fixing it.
