# Spaces: functional desktops across every display

Status: **spec**, nothing here is implemented yet. It is designed together with
[THEME-ARCHITECTURE.md](THEME-ARCHITECTURE.md), which defines how a space can carry a
theme or its own wallpapers, and it reuses the display-role model of the `wallsets`
branch. Names are the Loft names (`loft`, `loft-niri`, `~/.local/state/loft`).
THEME-ARCHITECTURE.md §0 maps them to today's `studio` names.

Cody's brief: *spaces for what I do: **Main** (anything non-specific), **Music** (full
music production), **Video** (editing), **Communication**, **Task** (later: the
integration-of-everything space), **Gaming** (exists), and **Programming**, or rather
one per coding project. With two projects at once, each has the center monitor for the
editor and debugger, the right one for the app preview, and the left one for
documentation. Spin up variations of a space quickly. A dock configurable per space.
Optionally a theme per space that everything adjusts to, or one theme with different
wallpapers per workspace and monitor.*

## 1. Concepts

| Term | Meaning |
|---|---|
| **Space** | A functional desktop spanning **all displays**: one niri named workspace per display role, activated together. "Music" is a space. |
| **Role** | Which display, by layout, not by connector: `main`, `left` / `right` / `top` / `bottom` (`left-2` … further out), `portrait` / `landscape` / `ultrawide`, `display-N`, `*`. These are exactly the `wallsets` roles (`cli/loft/wallsets.py` `roles()`). `main` is the display named in Settings → Displays, else the largest. |
| **Template** | A space with **parameters** ("Project": name, dir, preview, docs). Instances are made from it. |
| **Instance** | A template filled in: "Project: loft", "Project: inferno". Each has its own workspaces and windows. |
| **Singleton** | A space that is its own only instance: Main, Music, Video, Communication, Gaming, Task. Internally a template with no parameters. |
| **Binding** | What a space puts on one role: its workspace (and the apps to launch there), or `keep`, which leaves that display alone. |

A display that a space binds `keep` doesn't change when the space activates. That is
how Cody's left portrait monitor can keep showing chat while he switches between Music
and Gaming.

## 2. Space documents

### 2.1 A singleton: Music

```json
{
  "$schema": "https://loft.dev/schema/space-1.json",
  "kind": "space",
  "id": "music",
  "name": "Music",
  "icon": "󰝚",
  "order": 3,
  "displays": {
    "main":  { "workspace": "music",
               "apps": [ { "id": "reaper", "exec": ["reaper"], "match": { "appId": "^REAPER$", "title": "REAPER v" },
                           "open": "maximized" } ] },
    "right": { "apps": [ { "id": "patchbay", "exec": ["qpwgraph"], "match": { "appId": "^org\\.rncbc\\.qpwgraph$" } } ] },
    "left":  "keep",
    "*":     "keep"
  },
  "dock": { "pinned": ["REAPER", "org.rncbc.qpwgraph", "kitty"], "mode": "replace" },
  "focus": { "dnd": true, "allow": ["Slack"] },
  "menubar": { "extras": ["clock", "sound", "cpu", "cpuTemp"] },
  "theme": null,
  "facets": { "motion": "motion:minimal" },
  "wallpapers": { "main": "~/Documents/Loft/Wallpapers/Topics/Studio/console.jpg" },
  "startup": "first-activate"
}
```

- `displays` keys are roles. Each display takes the **first of its roles** that the
  space binds (the `wallsets` rule). An unbound display is `keep`.
- `workspace` defaults to the space id for `main` and `<id>/<role>` otherwise
  (`music/right`). Keeping today's names for `main` (`music`, `gaming`, `comms`, `code`,
  `main`) means every existing niri window rule (`open-on-workspace "music"`) keeps
  working.
- `apps[]` is what the space launches or gathers on that display, in column order (§4).
- `theme`, `facets`, `wallpapers`, `dock`, `menubar`, `focus`, `bar`, `startup`: §5.

### 2.2 A template: Project

```json
{
  "kind": "space-template",
  "id": "project",
  "name": "Project",
  "icon": "󰅩",
  "params": {
    "name":    { "type": "string", "required": true, "label": "Name" },
    "dir":     { "type": "dir",    "required": true, "label": "Folder" },
    "preview": { "type": "string", "default": "", "label": "Preview", "hint": "URL (http…) or a command (dx serve, cargo run …)" },
    "previewMatch": { "type": "match", "default": null, "hint": "app-id / title of a native preview window" },
    "docs":    { "type": "url",    "default": "", "label": "Documentation" },
    "editor":  { "type": "enum",   "values": ["zed", "code", "nvim"], "default": "zed" }
  },
  "instance": { "id": "proj-${slug(name)}", "name": "Project: ${name}", "workspace": "${slug(name)}" },
  "displays": {
    "main": { "apps": [
      { "id": "editor", "when": "${editor == 'zed'}", "exec": ["zeditor", "${dir}"],
        "match": { "appId": "^dev\\.zed\\.Zed$", "title": "^${basename(dir)}\\b" }, "width": 0.67 },
      { "id": "editor", "when": "${editor == 'code'}", "exec": ["code", "--new-window", "${dir}"],
        "match": { "appId": "^(code|Code)$", "title": "${basename(dir)}" }, "width": 0.67 },
      { "id": "debug", "exec": ["kitty", "--class", "loft.${id}.debug", "--directory", "${dir}"],
        "match": { "appId": "^loft\\.${id}\\.debug$" }, "width": 0.33 }
    ] },
    "right": { "apps": [
      { "id": "preview", "when": "${isUrl(preview)}",
        "exec": ["chromium", "--app=${preview}", "--class=loft.${id}.preview", "--user-data-dir=${state}/browser/${id}"],
        "match": { "appId": "^loft\\.${id}\\.preview$" }, "open": "maximized" },
      { "id": "preview-cmd", "when": "${preview && !isUrl(preview)}",
        "exec": ["kitty", "--class", "loft.${id}.run", "--directory", "${dir}", "--hold", "sh", "-c", "${preview}"],
        "match": { "appId": "^loft\\.${id}\\.run$" }, "width": 0.33 },
      { "id": "preview-app", "when": "${previewMatch}", "launch": false, "match": "${previewMatch}", "width": 0.67 }
    ] },
    "left": { "apps": [
      { "id": "docs", "when": "${docs}",
        "exec": ["chromium", "--app=${docs}", "--class=loft.${id}.docs", "--user-data-dir=${state}/browser/${id}"],
        "match": { "appId": "^loft\\.${id}\\.docs$" }, "open": "maximized" }
    ] }
  },
  "dock": { "pinned": ["dev.zed.Zed", "kitty", "chromium"], "mode": "prepend" },
  "theme": null
}
```

- Interpolation `${…}` sees the params, plus `id`, `state` (`~/.local/state/loft`),
  `home`, and the helpers `slug`, `basename`, `isUrl`. `when` drops an app whose
  condition is empty or false.
- `launch: false` gathers an existing window and never spawns one. That's for a native
  preview window that `preview-cmd` (e.g. `dx serve`, `cargo run`) opens.
- Apps whose command can set its app-id (`kitty --class`, Chromium `--class` with a
  per-instance `--user-data-dir`) are matched **exactly**, which is the reliable path.
  Editors that reuse one process (Zed, VS Code) are matched by app-id + title. That's
  why the default browser for preview and docs is Chromium `--app`, not Firefox
  (open question Q5).

### 2.3 An instance

```json
// ~/Documents/Loft/Spaces/instances/proj-loft.json
{
  "kind": "space-instance",
  "template": "project",
  "id": "proj-loft",
  "params": { "name": "loft", "dir": "~/Development/loft", "preview": "http://localhost:8080",
              "docs": "https://quickshell.org/docs/", "editor": "zed" },
  "order": 2,
  "created": "2026-10-14T10:02:00Z",
  "archived": false,
  "overrides": { "wallpapers": { "main": "~/Documents/Loft/Wallpapers/Topics/Code/loft.jpg" } }
}
```

`overrides` can patch any space field of the instance (RFC 7386 merge patch, the same
semantics as theme patches) without forking the template. Workspaces of `proj-loft`:
`loft` (main), `loft/right`, `loft/left`.

## 3. Activation

### 3.1 The niri IPC sequence

niri workspaces belong to one output. `FocusWorkspace` on a workspace of another output
also focuses that output, and niri has no "show this workspace there without focusing"
action. So activating a space focuses each display's workspace in turn and ends on the
display that should keep focus.

```
activate(space S, from display F):
  plan = resolve_roles(live outputs, S.displays)            # display → binding (workspace | keep)
  ensure(S, plan)                                           # §3.2: create/rename/move missing workspaces
  order = [d for d in plan if plan[d] != keep and d != target]
          sorted by distance from target, farthest first   # each focus jump stays short
  target = main               (default: `focus: "main"`)
         | F if F is bound in S   (`focus: "stay"`)
  for d in order:   FocusWorkspace { reference: { Name: plan[d].workspace } }
  FocusWorkspace    { reference: { Name: plan[target].workspace } }   # last: keyboard focus lands here
  emit SpaceActivated(S)   → shell: island banner, dock, menu bar, DND, theme (§5)
```

- All actions go over **one** connection to niri's socket, back to back, with no reads
  in between, so they land in the same frame or the next. The workspace-switch
  animations of all displays run together. Measured target: under 2 frames between the
  first and last output switching (phase P0 verifies it).
- The focus ring on intermediate displays is visible for one frame at most. With niri
  `input { warp-mouse-to-focus }` on, the pointer travels with each focus. That's
  harmless, because it ends on `target`, but Loft warns in Settings → Spaces when warp
  is on.
- Windows keep their focus history per workspace, so the last-focused window on
  `target` gets keyboard focus. That is the editor in a Project, REAPER in Music.
- Activating the space that is already active refocuses `main` and restores any `keep`
  displays that were switched away by hand ("bring the space back").
- Fast path: the niri binds call `loft-niri space focus <id>` (Rust, `crates/loft-niri`,
  which already speaks niri IPC). It runs in about 5 ms, whereas a Python CLI or
  `qs ipc` call spawns an interpreter. The shell sees `WorkspaceActivated` events and
  derives the active space from workspace names. Nothing has to tell it.

### 3.2 Ensuring workspaces exist

| Space kind | How its workspaces exist |
|---|---|
| Singletons | Declared in the generated `spaces.kdl` (`workspace "music" { open-on-output "<identity>" }`), with the identity resolved from the role when the file is rendered. Declared named workspaces exist from niri start, so `open-on-workspace` rules work at login. |
| Instances | Created at runtime: claim the empty workspace niri keeps last on the role's output with `SetWorkspaceName { name, workspace }` (the technique `MenuState.qml` uses for `hidden-<output>`), then `MoveWorkspaceToIndex` to sit in space order. Named workspaces are kept when empty. Instances are also written to `spaces.kdl` on the next render, so they survive a niri restart. |

`spaces.kdl` is re-rendered when spaces change and when the display layout changes
(`Displays.qml` already watches outputs). Roles move with the desk, identities don't.

### 3.3 Fewer displays than roles

When a bound role has no display (laptop, monitor off), the space's `fold` setting
decides what happens:

| `fold` | Behavior |
|---|---|
| `"stack"` (default) | The role's workspace lives on `main`'s output, directly below the space's main workspace. Activation focuses only main. Mod+Ctrl+Down reaches it, and the bar shows the space with a "+1" badge. |
| `"columns"` | The role's apps are gathered into the main workspace as columns: `left` apps before, `right` apps after. Good for one ultrawide. |
| `"skip"` | The role's apps aren't launched while the display is missing. |

When the display comes back, niri moves a workspace back to the output it was created
on (it remembers that output). For workspaces Loft created while the display was absent,
Loft issues `MoveWorkspaceToMonitor` to the role's output, triggered by the outputs
change.

## 4. Spinning up and restoring apps

`loft space open <id>` (and the first activation of a space with `startup:
"first-activate"`) runs, per display in plan order and per app in column order:

1. **Find**: a live window matching `match` (`appId` regex, `title` regex, optional
   `cwd`: the window's `pid` → `/proc/<pid>/cwd` under `${dir}`) that no other space
   instance has claimed. Claims live in `~/.local/state/loft/spaces/runtime.json`
   (`window id → instance/app`).
2. **Spawn** when nothing matches and `launch` isn't false: `systemd-run --user --scope
   --unit loft-space-<instance>-<app> -- <exec>`, in `${dir}`. The scope's cgroup tags
   every descendant, so a window whose `pid` sits in that cgroup is this app's, even
   through wrappers and forks. Apps that hand off to an already-running process (Zed,
   VS Code, a browser without `--user-data-dir`) are matched by app-id + title, with a
   10 s timeout (a toast says "Couldn't find the editor window").
3. **Place**: `MoveWindowToWorkspace { window_id, reference: Name(ws), focus: false }`,
   then the width (`SetWindowWidth { id, change: SetProportion(67.0) }`, or
   `"open": "maximized"` → `MaximizeColumn` / `"fullscreen"`).
4. **Order**: once every app of a workspace is placed, for each window in declared
   order run `FocusWindow { id }` and `MoveColumnToIndex { index }`, then focus the
   first app of `main`. This happens once, at spin-up. Restoring later never re-orders
   columns you have moved.
5. **Rules where possible**: for apps with an exact app-id (`loft.<id>.*`) Loft also
   writes niri window rules into `spaces.kdl` (`open-on-workspace`,
   `default-column-width`, `open-focused false`). niri then places them at map time with
   no visible jump, and steps 3–4 become no-ops.

| Command | Effect |
|---|---|
| `loft space close <id>` | `CloseWindow` for each claimed window (apps may ask to save), then `UnsetWorkspaceName` on its workspaces so niri drops them when empty. The instance file stays. |
| `loft space archive <id>` | close + `archived: true` (hidden from the switcher, listed under "Archived"). |
| `loft space open <id>` | restore an instance: steps 1–5 (find first, so already-open windows are gathered, not duplicated). |
| `loft space gather <id>` | find + place only, no spawning: pull matching windows back into the space. |

## 5. Per-space settings

| Field | Values | Applied on activation through |
|---|---|---|
| `dock` | `{pinned: [...], mode: "replace" \| "prepend" \| "append", visible: "show" \| "autohide" \| "hidden", displays: {role: …}}` | `Dock.qml` reads `Spaces.active.dock` over `Settings.dock` (per-display behavior arrives with the per-display dock work in FEATURES.md) |
| `bar` | `{hidden: false}` | `Bar.qml` hides on the space's displays (replaces the fleet's `niri-workspace-wallpaper` hiding the bar on `gaming`) |
| `menubar` | `{extras: [ids]}`, a subset of the enabled extras | `MenuBar` filters its status items |
| `focus` | `{dnd: bool, allow: [app names]}` | `Notifications.qml` DND with an allow list, restored on leave |
| `theme` | `null` (inherit the global theme) or `{theme: "loft@light", scope: "desktop" \| "all"}` | `appearance.json` `space` (THEME-ARCHITECTURE §3.4: the space selects the theme, customizations of that theme still apply) |
| `facets` | facet selections per kind (`{"motion": "motion:minimal"}`) | the space layer in THEME-ARCHITECTURE §3.4 |
| `wallpapers` | `{role: path}` and/or `{workspace: path}` | the space layer of the Wallpapers facet: written as `arrangement.workspaces["<workspace name>"]`, whose `wallsets` precedence is "W's choice", the highest |
| `layout` | per role: niri workspace `layout {}` overrides (struts, focus-ring, border, gaps) | rendered into `workspace "<name>" { layout { … } }` in `spaces.kdl` (Gaming: no top strut, no ring, no border, as the fleet does today) |
| `startup` | `"first-activate" \| "login" \| "never"` | when §4 runs by itself |
| `fold`, `focus` (target) | §3.3, §3.1 | |

### 5.1 One theme per space, or one theme with wallpapers per space

Both are supported, and they combine.

- **Wallpapers only** (the light option): leave `theme: null` and set `wallpapers`.
  Switching the space doesn't run the renderer at all. The shell's wallpaper layer
  already resolves per workspace and per display, so the change is instant.
- **A theme per space**: `theme: {theme, scope}`. Activation focuses the workspaces
  **first**, then applies the theme asynchronously, so the switch animation never waits
  on it. Rendered compositions are cached by content (THEME-ARCHITECTURE §6.2). Loft
  pre-renders every space's theme when the space is saved, so a switch is resolve +
  symlink swap + hooks, under 150 ms.

What follows a per-space theme:

| Consumer | `scope: "desktop"` (default) | `scope: "all"` | Notes |
|---|---|---|---|
| Shell (bar, dock, panels, glass, motion) | yes, live | yes | |
| niri (ring/border colors, blur, radii, animations) | yes, live | yes | `load-config-file` |
| Wallpapers, lock screen | yes, live | yes | |
| Launcher (walker) | yes, next open | yes | |
| kitty / Ghostty | no | yes, live | they are global: every terminal in every space recolors |
| GTK4 / libadwaita | no | `color-scheme` only (light/dark, global) | custom CSS: new windows only |
| GTK3, Qt, Electron | no | no | restart needed |
| Cursor | no | new windows only | |
| Icon theme | never per space | never | needs a shell restart (THEME-ARCHITECTURE §10) |

`desktop` is the default because a half-recolored terminal or GTK app looks broken.
`all` is for spaces Cody wants fully immersive (Gaming at night, a Music theme). A
space never changes the global theme selection: leaving it re-applies the global theme
(or the next space's).

## 6. Switching UX

### 6.1 Menu bar

`src/bar/Workspaces.qml` becomes a **space indicator** on each display:

```
 [ 󰝚 Music ]  ● ● ◉ ● ○   │  ·  ·
   ▲ active space          ▲ unowned workspaces of this output (today's dots)
               ▲ one dot per space, in order: filled = has windows, ring = active, ghost = empty
```

- One dot per space (not per workspace). A dot's state comes from the space's workspace
  on *this* display. Hovering shows the name, and clicking activates the space.
- The pill shows the active space's icon and name on the main display (icon only on
  the others). Clicking it opens a menu: the list of spaces and instances, **New Space
  ▸** (Project…, the singletons not created yet), **Edit "Music"…**, **Close Space** /
  **Archive** (instances), and **Space Theme ▸** (Inherit · themes…).
- Workspaces that no space owns (`lab`, `hidden-*` parking excluded) keep today's dots
  after a divider.

### 6.2 Keyboard

| Keys | Action |
|---|---|
| Mod+1 … Mod+9 | activate the space at that position (singletons and active instances, in `order`) |
| Mod+Shift+1 … 9 | move the focused window to that space's workspace on the **same role** as the display it is on (else `main`), without following |
| Mod+Ctrl+Left / Right | previous / next space (macOS Ctrl+←/→) |
| Mod+Ctrl+Space | space switcher overlay (the app switcher's layout, `src/switcher/`, listing spaces with their windows) |
| Mod+Alt+PageUp / PageDown | niri's own per-output workspace up / down (the escape hatch) |

These are generated into `spaces.kdl` as `spawn "loft-niri" "space" "focus" "3"` and so
on. Plain Mod+PageUp / PageDown stop meaning "the next niri workspace on this output":
with spaces they move between spaces too, so the displays never get out of step.

### 6.3 Spotlight, island, overview

- **Spotlight**: a `spaces` provider (an elephant `menus` file, regenerated by `loft
  space list`) offers "Switch to Music", "Project: loft", **"New Project Space…"**
  (opens the parameter sheet: name, folder picker, preview, docs, editor) and "Archived
  ▸". Typing `space loft` or `proj inferno` goes straight to one.
- **Island**: on every space switch, a compact banner `󰝚 Music` (plus the theme's name
  when the space changed it) for 1.2 s, through `island/Banner.qml`.
- **Overview**: niri's overview shows each output's workspace strip, and its order
  follows spaces because Loft keeps workspaces in space order (`MoveWorkspaceToIndex`).
  A Loft "Spaces overview" with labels and window thumbnails comes later (phase P7).

### 6.4 Settings → Spaces

A sidebar page **Spaces**: the list of spaces (drag to reorder, which is also the
Mod+N order), and per space: displays (a diagram of the live layout with each display's
binding: workspace / keep / apps), apps per display (app picker + match + width), Dock,
Menu Bar, Focus, Theme (Inherit · a theme or variant · scope), Wallpapers per display.
Templates have a Parameters tab. "Duplicate as Template…" turns a space into a
template.

## 7. Storage

```
~/Documents/Loft/Spaces/                 (library; THEME-ARCHITECTURE §5.2)
  main.json  music.json  video.json  communication.json  gaming.json  task.json   singletons
  templates/project.json                 your templates (+ copies of built-ins you edited)
  instances/proj-loft.json  proj-inferno.json
repo: spaces/templates/{project,main,music,video,communication,gaming,task}.json   built-in starting points
~/.local/state/loft/
  spaces/runtime.json                    claims (window → instance/app), active space, last focus per space
  overrides/spaces.kdl                   generated (loft-niri spaces render; validated with `niri validate`)
  appearance.json                        "space": "<id>" while a space with a theme is active
```

`spaces.kdl` holds named workspaces (`open-on-output` by identity, per-workspace
`layout`), window rules for app-ids Loft controls (`loft.<id>.*`), and the space binds.
The Loft session includes it after `base.kdl` and the theme fragment. A consumer like the
fleet includes it last, through `~/.config/loft/niri.kdl` as it does with
`overrides/niri.kdl`, so its binds and declarations win over earlier duplicates.

**Defaults from Nix** (PLAN §4.1 layering): `programs.loft.spaces` takes JSON
(`lib.importJSON ./spaces/music.json`) as consumer defaults, and the library files are
runtime overrides on top. `loft save --spaces` writes runtime edits back into the
fleet's JSON. Instances are created at runtime and stay in the library.

## 8. Migrating Cody's fleet niri config

Read-only analysis of `~/.flake/modules/desktop/environment/niri/_config/`
(`workspaces.kdl`, `rules.kdl`, `binds.kdl`, `startup.kdl`, `outputs.kdl`) and
`bin/niri-workspace-wallpaper`.

**Displays → roles** (THEBATTLESHIP):

| Display (niri identity) | Position | Role |
|---|---|---|
| Microstep MPG491CX OLED (5120×1440) | center, x=1440 | `main` (largest; also `ultrawide`) |
| Acer XV271U M3 …93LAJ (rotated 90°) | x=0 | `left` (also `portrait`) |
| Acer XV271U M3 …C3LAJ | x=6560 | `right` |
| AOC Q32G1WG4 (`HDMI-A-2`) | x=-2560 | `left-2`, the only output still keyed by connector (renumbering risk, see the memory note on DP-x) |

**Today's workspaces → spaces** (keeping the names on `main`, so `rules.kdl` keeps
working unchanged):

| Today | Output | Becomes |
|---|---|---|
| `main` | center | **Main** `main` (Nautilus, Nextcloud) |
| `code` | center | **Programming**: the generic singleton `code`. Each project becomes a **Project** instance (`loft`, `inferno`, …) with `left` docs / `right` preview |
| `music` | center | **Music** `main`; `right`: `music/right` (patchbay, FTS Desktop panels); `left`: keep |
| `gaming` (no struts, ring, border) | center | **Gaming** `main` with `layout` overrides + `bar.hidden` + `dock.visible: hidden`; `right`: `stream`; `left`: keep |
| `stream` | right | **Gaming** `right` |
| `comms` | left | **Communication** `left` (where chat lives today); `main`: `comms/main` for calls (Zoom maximized) |
| `media` | left | **Video** `left` (reference playback) |
| `recording` | right | **Video** `right` (OBS); `main`: `video` (DaVinci Resolve) |
| `notes` | left | **Task** `left` (Obsidian), until Task is designed |
| `research` | right | **Task** `right` |
| `setup` (OpenDeck) | right | **Main** `right` |
| `lab` (nested niri test sessions) | left | stays an **unowned utility workspace** (no space activates it) |

Proposed order and keys: 1 Main, 2 Programming / Projects (instances follow in order),
3 Music, 4 Gaming, 5 Communication, 6 Video, 7 Task. That keeps today's Mod+1 main,
Mod+3 music, Mod+4 gaming and Mod+5 comms.

**What stays in the fleet** (host facts and app quirks, not space structure):

- `outputs.kdl` (modes, positions, the AOC). Displays can move to Settings → Displays
  later.
- `input.kdl`, `layout.kdl`, `environment.kdl`, `debug.kdl`.
- App quirk rules: REAPER sub-window rules (Mixer / MIDI take maximized, ReaScript
  console floating and unfocused), the `xwayland-satellite` / WebKit / FTS Desktop
  children → `music`, gamescope / Big Picture → `stream` (fullscreen), the `niri` →
  `lab` rule, kitty unfocused opacity. Each targets a workspace *name* that the spaces
  keep.
- `startup.kdl` (`reaper-console-pin`, xwayland-satellite).

**What moves into Loft spaces:**

- `workspaces.kdl`: every declaration is generated from the spaces into `spaces.kdl`,
  except `lab`, which stays in the fleet as a utility workspace.
- `binds.kdl` Mod+0…9 and Mod+Shift+0…9 (`focus-workspace "<name>"` /
  `move-column-to-workspace`) are replaced by the generated space binds. The fleet
  deletes them.
- The placement rules for whole apps (steam → gaming, equibop / vesktop / zoom / Slack
  → comms, obsidian → notes, OBS → recording, opendeck → setup, mpv / vlc → media, the
  editors → code, the file managers and Nextcloud → main) can stay as niri rules, since
  the names are unchanged. Moving them into the spaces' `apps[]` is optional, and it
  adds "launch it when the space opens".
- `bin/niri-workspace-wallpaper`: per-workspace wallpapers become space `wallpapers`,
  and its bar / dock hiding on `gaming` becomes Gaming's `bar.hidden` / `dock.visible`.
  Remove it once Gaming is a space.

The migration is a manual, reviewed change in `~/.flake` (`loft space import-niri
<config.kdl>` prints proposed space JSON plus a diff of the fleet files; it never
edits them).

## 9. CLI

```sh
loft space list [--json] [--archived]
loft space focus <id|n>                      # activate (the binds use loft-niri directly)
loft space next | prev
loft space new <template> --name loft --dir ~/Development/loft [--preview URL|CMD] [--docs URL] [--editor zed]
loft space open | close | archive | gather <id>
loft space edit <id>                         # $EDITOR on the JSON, then re-render
loft space set <id> <path> <value>           # loft space set music theme.theme loft@light
loft space move-window <id> [--role R]       # Mod+Shift+N
loft space render                            # spaces.kdl (+ niri validate) and the elephant menu
loft space import-niri <config.kdl>          # §8 proposal, read-only
loft-niri space focus|ensure|plan <id> [--json]   # the fast path; `plan` prints the action list without sending it
```

## 10. Implementation plan

| Phase | Owns | Depends on | Parallel with |
|---|---|---|---|
| **P0. Spikes + test infra** | `loft-dev --outputs WxH,WxH,…` (headless sway `create_output`, several niri outputs), plus answers: do runtime-named workspaces persist when empty, are pipelined IPC requests applied in one frame, does `MoveWorkspaceToIndex` keep order across hotplug | — | THEME A |
| **P1. Model + roles + render** | `crates/loft-niri/src/spaces/{model,roles,render}.rs` (roles ported from `wallsets.py`, sharing its fixtures `tests/fixtures/wallsets/layouts.json`), `schemas/space-1.json`, `spaces/templates/*.json`, golden `spaces.kdl` + `niri validate` check | P0 | P2 design |
| **P2. Activation** | `loft-niri space focus/ensure/plan` (plan is a pure function: niri state + space → action list), fold logic, generated binds | P1 | P3 |
| **P3. Spin-up / restore** | `loft-niri space open/close/gather`: scopes, matching (cgroup, app-id, title, cwd), placement, ordering, claims in `runtime.json` | P1 | P2, P4 |
| **P4. Shell** | `src/services/Spaces.qml` (index, active space from niri events), `bar/Workspaces.qml` → space indicator, island banner, dock / menu bar / bar / DND per space | P1 | P3 |
| **P5. Theme per space** | the `space` layer in the resolver and `appearance.json` (THEME phases A/D), async apply after focus, pre-render on save | THEME B, D; P4 | P6 |
| **P6. Creation UX** | `cli/loft` `space` commands, Spotlight provider, New Project sheet, Settings → Spaces page, space switcher overlay | P2, P3, P4 | P5 |
| **P7. Later** | Spaces overview, Task space design | P4 | — |
| **P8. Fleet migration** | `~/.flake` changes, reviewed by Cody (`import-niri` output as a starting point) | P2, P4 | — |

**Tests.**

- **Unit**: roles over the `wallsets` fixtures (1, 2 and 4 displays, portrait,
  ultrawide), `plan()` golden action lists (focus order, keep, fold stack / columns,
  focus stay / main), template interpolation, matching (cgroup vs title fallback), claim
  conflicts between two Project instances.
- **Headless, multi-output** (`loft-dev --session spaces --outputs
  5120x1440,1440x2560,2560x1440`): activate each space and assert the active workspace
  per output from `loft-input --session spaces info` / `niri msg -j workspaces`; spin up
  a Project with fake apps (`kitty --class`, and a tiny `loft-testwin --app-id X --title
  Y` for title matching) and assert columns and widths; screenshot each output with
  `loft-shot --output`. Unplug an output (`swaymsg output … disable`), check fold, plug
  it back, check that workspaces return.
- **Live**: only when Cody asks, with `--live`, never automated (TESTING.md rules).

## 11. Risks

- **No "activate without focus" in niri.** Each display switch moves focus. If the
  one-frame flash or pointer warp turns out to be visible, the fix is a small upstream
  niri action (`focus-workspace … --no-focus-output` / `SetActiveWorkspace`). P0
  measures it before anything is built on it.
- **Title matching is fragile** for editors that reuse a process. Exact app-ids
  (`--class`) are preferred wherever an app supports them, and the docs / preview
  browser uses Chromium with per-instance profiles for that reason.
- **Two sources of workspace truth** (fleet `workspaces.kdl` and Loft's `spaces.kdl`)
  during migration: a name declared in both is declared twice. `loft space render` warns
  about duplicates it finds in the consumer's config (`niri validate` of the whole tree).
- **Per-space themes on shared global consumers** (terminals, GTK color-scheme) recolor
  apps in other spaces. That is why `scope: "desktop"` is the default.
- **AOC on a connector name** can renumber. Moving it to identity in `outputs.kdl` is a
  fleet fix that's independent of spaces.

## 12. Decisions (Cody, 2026-10-14: "go with defaults")

1. **Workspace names**: keep today's names (`music`, `comms`, `code`, …) so existing
   window rules keep working.
2. **Communication** is the **left monitor's sidecar**: Music and Gaming `keep` the left
   display so chat stays visible. It is still reachable as a space for calls (center).
3. **Projects**: center = editor (⅔) + **debugger terminal** (⅓), right = preview, left
   (portrait) = docs. Each project instance gets its own left docs workspace, so
   switching projects swaps all three displays.
4. **Lifetime**: project instances restore **lazily** after a reboot: their workspaces
   come back, apps start on demand.
5. **Preview / docs browser**: **Chromium `--app`** with per-instance profiles (exact
   matching).
6. **Mod+1…9**: Main, Music, Video, Comms, Gaming, Task, then project instances take the
   next numbers.
7. **Per-space theme scope** defaults to **`desktop`** (shell, niri, wallpapers,
   launcher); terminals don't follow.
8. **Video** = DaVinci Resolve on the center (OBS on the right); **Task** starts blank.
9. **Storage**: spaces live in the library (`~/Documents/Loft/Spaces`), **seeded from the
   fleet** (Nix-provided JSON copied on first run, never overwritten).

Also decided: the AOC monitor (`HDMI-A-2`) is matched by identity in the fleet's
`outputs.kdl` (fleet fix, independent of spaces).
