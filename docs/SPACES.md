# Spaces: functional desktops across every display

Status: **P0–P4 implemented** (test infra, spikes, model, roles, `spaces.kdl` render,
activation, spin-up / restore in `loft-niri space …`, and the shell); P5–P8 are spec.
See §10 for the status and §3.4 for what the spikes measured. It is designed together with
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
- A binding may carry `layout` (niri workspace `layout {}` overrides as KDL-in-JSON:
  `{"struts": {"top": 0}, "focus-ring": {"off": true}}`): it lives on the binding,
  `displays.main.layout`, next to the workspace it changes.
- `focus` is the Do Not Disturb object (above). Where keyboard focus lands on
  activation is `target: "main" | "stay"` (§3.1); the two used to share the name.

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
  "cwd": "${dir}",
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
        "exec": ["chromium", "--app=${preview}", "--class=loft.${id}.preview", "--user-data-dir=${profiles}/${id}/preview"],
        "match": { "appId": "^chrome-${re(chromeApp(preview))}-Default$" }, "open": "maximized" },
      { "id": "preview-cmd", "when": "${preview && !isUrl(preview)}",
        "exec": ["kitty", "--class", "loft.${id}.run", "--directory", "${dir}", "--hold", "sh", "-c", "${preview}"],
        "match": { "appId": "^loft\\.${id}\\.run$" }, "width": 0.33 },
      { "id": "preview-app", "when": "${previewMatch}", "launch": false, "match": "${previewMatch}", "width": 0.67 }
    ] },
    "left": { "apps": [
      { "id": "docs", "when": "${docs}",
        "exec": ["chromium", "--app=${docs}", "--class=loft.${id}.docs", "--user-data-dir=${profiles}/${id}/docs"],
        "match": { "appId": "^chrome-${re(chromeApp(docs))}-Default$" }, "open": "maximized" }
    ] }
  },
  "dock": { "pinned": ["dev.zed.Zed", "kitty", "chromium"], "mode": "prepend" },
  "theme": null
}
```

- Interpolation `${…}` sees the params, plus `id`, `state` (`~/.local/state/loft`),
  `home`, `profiles` (browser profiles: `$LOFT_SPACES_PROFILES`, else
  `${state}/browser`), and the helpers `slug`, `basename`, `isUrl`, `re` (a regex
  literal) and `chromeApp` (below). `when` drops an app whose condition is empty or
  false.
- `cwd` (on the space or on one app) is where apps are spawned; `~` is expanded there
  and at the start of `exec` arguments.
- `launch: false` gathers an existing window and never spawns one. That's for a native
  preview window that `preview-cmd` (e.g. `dx serve`, `cargo run`) opens.
- Apps whose command can set its app-id (`kitty --class`) are matched **exactly**,
  which also gives them `spaces.kdl` window rules. Editors that reuse one process (Zed,
  VS Code) are matched by app-id + title. Every spawned app is also identified by its
  systemd scope (§4), which is what really tells two instances apart.
- **Chromium `--app` ignores `--class` on Wayland** (measured with Chromium 155): an app
  window's app-id is `chrome-<host>_<path, / → _>-Default`, without the port
  (`http://127.0.0.1:9/` → `chrome-127.0.0.1__-Default`). `chromeApp(url)` computes the
  middle part, so the template matches what Chromium really reports. That app-id isn't
  unique (two projects on `localhost` share it), so the preview and docs are told apart
  by their scope and claims, and they get no window rule: they're moved into place
  after they map. Each gets its **own** profile (`${profiles}/${id}/preview`,
  `…/docs`): with one profile per instance, the docs window would hand off to the
  preview's browser process and land in the preview's scope.

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
  target = main               (default: `target: "main"`)
         | F if F is bound in S   (`target: "stay"`)
  order = [d for d in plan if plan[d] != keep and d != target
                           and plan[d] isn't already active on d]   # no needless focus hop
          sorted by distance from target, farthest first
  if order: FocusWorkspace { reference: { Name: plan[target].workspace } }   # first (§3.4)
  for d in order:   FocusWorkspace { reference: { Name: plan[d].workspace } }
  FocusWorkspace    { reference: { Name: plan[target].workspace } }   # last: keyboard focus lands here
  emit SpaceActivated(S)   → shell: island banner, dock, menu bar, DND, theme (§5)
```

- All actions go over **one** connection to niri's socket, back to back, with no reads
  in between. niri applies them about 0.1 ms apart, and every display switches within
  two frames (§3.4). The workspace-switch animations are clock-based, so they run
  together whatever frame they first show up in.
- The target is focused **first and last**: the one early frame niri renders already
  shows the target focused, so no rendered frame has the focus ring on an intermediate
  display. Intermediate windows still get keyboard focus for well under a millisecond,
  and the pointer jumps to the target display's center (§3.4).
- Windows keep their focus history per workspace, so the last-focused window on
  `target` gets keyboard focus. That is the editor in a Project, REAPER in Music.
- Activating the space that is already active refocuses `main` and restores any `keep`
  displays that were switched away by hand ("bring the space back"). Each activation
  records what the space's `keep` displays show (by identity) in `runtime.json`
  `memory`, and activating the active space focuses those workspaces again when they
  are still on that display (P3).
- Fast path: the niri binds call `loft-niri space focus <id>` (Rust, `crates/loft-niri`,
  which already speaks niri IPC). It runs in about 5 ms, whereas a Python CLI or
  `qs ipc` call spawns an interpreter. The shell sees `WorkspaceActivated` events and
  derives the active space from workspace names. Nothing has to tell it.

### 3.2 Ensuring workspaces exist

| Space kind | How its workspaces exist |
|---|---|
| Singletons | Declared in the generated `spaces.kdl` (`workspace "music" { open-on-output "<identity>" }`), with the identity resolved from the role when the file is rendered. Declared named workspaces exist from niri start, so `open-on-workspace` rules work at login. |
| Instances | Created at runtime: claim the empty workspace niri keeps last on the role's output with `FocusMonitor` + `SetWorkspaceName { name, workspace: Id }` (the technique `MenuState.qml` uses for `hidden-<output>`), then `MoveWorkspaceToIndex` to sit in space order. Named workspaces are kept when empty (§3.4). The `FocusMonitor` works around a niri 26.04 bug: it only appends the next empty workspace when the renamed one is on the *focused* monitor. The new empty workspace's id is unknown until niri reports it, so a second creation on one display takes another round (`loft-niri space focus` loops, at most 4 rounds). Instances are also written to `spaces.kdl` on the next render, so they survive a niri restart. |

`spaces.kdl` is re-rendered when spaces change and when the display layout changes
(`Displays.qml` already watches outputs). Roles move with the desk, identities don't.

At niri's start, declared workspaces appear in config order (each display shows its
first). But workspaces that a config **reload** declares are each inserted at the top of
their display, so a render on a running niri lists them in reverse. `loft-niri space
render` therefore runs `space order` after the reload: every display gets the spaces'
workspaces first, in space order, and unowned ones keep their order after them.

### 3.3 Fewer displays than roles

When a bound role has no display (laptop, monitor off), the space's `fold` setting
decides what happens:

| `fold` | Behavior |
|---|---|
| `"stack"` (default) | The role's workspace lives on `main`'s output, directly below the space's main workspace. Activation focuses only main. Mod+Ctrl+Down reaches it, and the bar shows the space with a "+1" badge. |
| `"columns"` | The role's apps are gathered into the main workspace as columns: `left` apps before, `right` apps after. Good for one ultrawide. |
| `"skip"` | The role's apps aren't launched while the display is missing. |

When a display is unplugged, niri moves its workspaces to its **first** monitor (the
one connected first, not necessarily `main`), appended in order. For `stack`, `ensure`
moves the role's workspace to main's display (`MoveWorkspaceToMonitor`) right below the
space's main workspace (`MoveWorkspaceToIndex`).

When the display comes back, niri moves back the workspaces *it* displaced (it remembers
their output). An explicit `MoveWorkspaceToMonitor` re-homes a workspace, so folded
workspaces (and ones Loft created while the display was absent) don't come back by
themselves. `ensure` notices that they are on the wrong display and moves them back,
on the next activation (and, from P4 on, when the outputs change).

### 3.4 What P0 measured

Everything below was measured in headless multi-output sessions (`loft-dev --session
spaces --outputs 1440x2560,5120x1440,2560x1440`, niri 26.04 + the dev-only patch in
TESTING.md). Actions and frames were timed with niri's debug log, frame pacing was 60 Hz,
and screenshots are in the P0/P2 report.

**Multi-output test sessions.** niri's nested (winit) backend has exactly one output, so
the spec's "headless sway with several outputs" can't give niri several. `loft-dev
--outputs` runs niri on its own headless backend instead, made usable at runtime by a
small patch (`nix/dev/niri-headless-outputs.patch`, used only for `--outputs`): virtual
outputs `headless-N` (identity `niri headless N`), 60 Hz frame pacing, screencopy
(`loft-shot` works), and `niri msg output headless-N off|on` as a real hotplug.

1. **Do runtime-named workspaces persist when empty?** Yes. A workspace named with
   `SetWorkspaceName` stays when empty and unfocused, through focus changes, a config
   reload (`load-config-file`) and an unplug/replug of its display. Two caveats:
   - the `niri msg action set-workspace-name --workspace N` CLI reads `N` as an *index
     on the focused monitor*, not an id. Use IPC with `{"Id": n}`, as `loft-niri` does;
   - naming a workspace on a non-focused monitor doesn't add the trailing empty workspace
     (niri bug, `layout/mod.rs` `set_workspace_name` only checks the active monitor). So
     `ensure` focuses that monitor first (§3.2).
2. **Are pipelined IPC requests applied in one frame?** Not strictly, but close. niri
   handles one request per event-loop turn: each action waits for an idle callback before
   the next line is read. Pipelined on one connection, 3–4 actions were all applied
   within 0.4–0.9 ms (20 runs: median 0.48 ms, worst 14.8 ms). An idle display renders
   right after the first action, though. So frame 1 (+0.2 ms) shows only the first
   action, and frame 2 (+17 ms at 60 Hz) shows the final state. In all 20 runs the last
   action landed before frame 2. Separate `niri msg` processes spread the same actions
   over 19–30 ms and 3 frames. That's why the binds call `loft-niri` (one pipelined
   connection), and why the target is focused first: the early frame is then the target
   already switched and focused, not some intermediate display. On real monitors each
   output has its own vblank, so "one frame" across displays doesn't exist anyway. The
   switch animations are clock-based and start within a millisecond of each other.
3. **Does `MoveWorkspaceToIndex` keep the order across hotplug?** Yes, as long as
   nothing reorders the workspaces while their display is away. `MoveWorkspaceToIndex`'s
   `index` is 1-based. On unplug, the display's workspaces are appended to niri's first
   monitor in their order. On replug, they return in the order they have *there*: a
   reorder while away carries over, and a workspace moved explicitly with
   `MoveWorkspaceToMonitor` doesn't return at all (§3.3).
4. **Is the focus flash / pointer warp of "activate without focus" visible?**
   - **Focus flash:** with the target-first-and-last order, no rendered frame showed the
     focus ring on an intermediate display (20/20 runs). With plain farthest-first
     order, the first frame does (one frame, 17 ms at 60 Hz).
   - **Focus events:** intermediate windows still get keyboard focus for well under a
     millisecond. The event stream shows `WindowFocusChanged` for each, and apps may
     redraw focus-dependent UI (terminal cursor, GTK backdrop). **P4:** Spaces.qml and
     the bar must not react to focus events mid-activation (debounce, or wait for
     `SpaceActivated`).
   - **Pointer warp: visible.** `FocusWorkspace` on another display centers the pointer
     on that display (`move_cursor_to_output`) whether or not `warp-mouse-to-focus` is
     on. Measured: the pointer at (3000,700) on main ended at main's center (4000,720)
     after activating a space whose other displays had to switch. It jumps only when a
     non-target display actually switches; displays already showing their workspace are
     skipped.
   - **Fix:** a small upstream niri action that switches a monitor's active workspace
     without focusing it (`focus-workspace --no-focus` / `SetActiveWorkspace`). It
     removes the warp and the focus events. It's a few lines in `input/mod.rs`
     (`monitor.activate_workspace(idx)` without `focus_output`), but it needs a new
     `niri-ipc` variant, so it's for upstream, or a Loft-carried niri patch (open
     question Q-S1).

## 4. Spinning up and restoring apps

`loft-niri space open <id>` (and the first activation of a space with `startup:
"first-activate"`) runs, per display in plan order and per app in column order
(`crates/loft-niri/src/spaces/{apps,launch,runtime}.rs`):

1. **Find**, strongest first:
   1. the window this instance/app **claimed** before (claims live in
      `~/.local/state/loft/spaces/runtime.json`, `window id → instance/app`);
   2. a window whose process sits in the app's **scope** (its pid's
      `/proc/<pid>/cgroup` names `loft-space-<instance>-<app>.scope`);
   3. `match`: the `appId` and `title` regexes and the `cwd` prefix (the window's
      `pid` → `/proc/<pid>/cwd` under the path), all that are given.

   A window claimed by another instance or app, or sitting in another app's scope, is
   never taken by 3, so two Project instances never steal each other's windows. Among
   several candidates, one already on the app's workspace wins, then the oldest.
2. **Spawn** when nothing matches and `launch` isn't false: `systemd-run --user --scope
   --unit loft-space-<instance>-<app>.scope -- <exec>`, in the app's `cwd`. The scope's
   cgroup tags every descendant, so a window whose `pid` sits in that cgroup is this
   app's, even through wrappers and forks. An **active** unit of that name means the app
   is already running (its window may still be coming), so it's never started twice,
   even when two `open`s race. Apps that hand off to an already-running process (Zed,
   VS Code) leave the scope empty and are found by app-id + title. Loft waits up to 10 s
   (`--timeout`) and reports "Couldn't find the editor window" for the rest (P4 turns it
   into a toast). Without a reachable user manager the command is spawned directly and
   its pid's descendants stand in for the scope.
3. **Place**: `MoveWindowToWorkspace { window_id, reference: Name(ws), focus: false }`
   when the window is elsewhere. A window claimed just now, or one that had to move, is
   also sized: `SetWindowWidth { id, change: SetProportion(67.0) }` for `width: 0.67`,
   `"open": "maximized"` → `SetProportion(100)` (niri's `MaximizeColumn` is a toggle
   and takes no window id; a full-width column is the same thing, set idempotently),
   `"fullscreen"` → `FullscreenWindow` and `"floating"` → `MoveWindowToFloating`, these
   two only for a window claimed just now and not already in that state. A window that
   stayed where it was keeps whatever you did to it.
4. **Order**: when a workspace got a new window (spun up, newly claimed, or moved in by
   a gather or a fold) and its declared apps aren't left to right in declared order,
   `FocusWindow { id }` + `MoveColumnToIndex { index }` for each, then focus the first
   app of `main`. Columns you rearranged with nothing moving in stay as you left them.
5. **Rules where possible**: for apps with an exact app-id (`^loft\.…$`) Loft also
   writes niri window rules into `spaces.kdl` (`open-on-workspace`,
   `default-column-width`, `open-focused false`, `open-maximized`, …), following the
   current layout (a `columns` fold targets main's workspace, `skip` writes none). niri
   then places them at map time with no visible jump, and steps 3–4 become no-ops.

The **`columns` fold** (§3.3) puts the folded roles' apps on main's workspace: `left` /
`top` roles before main's apps, the others after. There they are columns of their
`width`, or half the display (`apps::FOLD_WIDTH`), never maximized or fullscreen. When
the display comes back, `gather` moves them back to their own workspace at their
declared size.

**Lifetime** (§12.4): `runtime.json`'s claims and `opened` list belong to one niri
session (boot id + niri's socket path, which carries niri's pid), because window ids
only mean something inside one niri process. After a reboot or niri restart the
instances' workspaces come back from `spaces.kdl`, and each space spins up on its first
activation (`startup: "first-activate"`, the default). `startup: "login"` spaces are
opened by `loft-niri space startup` (for the session's autostart), `"never"` only by an
explicit `open`.

| Command | Effect |
|---|---|
| `loft-niri space focus <id>` | activate (§3); on the space's first activation in a session, spin it up (`--no-open`: don't) |
| `loft-niri space open <id>` | restore a space: steps 1–5 (find first, so already-open windows are gathered, not duplicated), then activate it (`--no-focus`: don't) |
| `loft-niri space gather <id>` | find + place only, no spawning: pull matching windows back into the space |
| `loft-niri space close <id>` | `CloseWindow` for each window the space claimed or that sits in one of its scopes (apps may ask to save), then, for instances, `UnsetWorkspaceName` on its workspaces so niri drops them when empty. The instance file stays. Its claims and `opened` are forgotten. |
| `loft-niri space apps <id>` | which window is which app right now, and how it was matched; changes nothing |
| `loft-niri space startup` | open the `startup: "login"` spaces without switching to them |
| `loft space archive <id>` | close + `archived: true` (hidden from the switcher, listed under "Archived"); P6 |

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
| Mod+Ctrl+S | space switcher overlay (`src/switcher/SpaceSwitcher.qml`: spaces with their ⌘N keys, type to filter) |
| Mod+Alt+PageUp / PageDown | niri's own per-output workspace up / down (the escape hatch) |

These are generated into `spaces.kdl` as `spawn "loft-niri" "space" "focus" "music"` and
so on, by space **id** rather than position, so a stale `spaces.kdl` never switches to the
wrong space. Mod+Ctrl+Space is already the Radial Menu (`niri/shell-binds.kdl.in`), so
the space switcher overlay is **Mod+Ctrl+S** (Q-S4, implemented in P4). Plain Mod+PageUp / PageDown stop meaning "the next niri workspace on this output":
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
  spaces/runtime.json                    {session, claims: {window: {space, app}}, opened: [ids],
                                         active, memory: {space: {keep: {identity: workspace}}}}
  browser/<instance>/{preview,docs}      Chromium profiles ($LOFT_SPACES_PROFILES overrides)
  overrides/spaces.kdl                   generated (loft-niri spaces render; validated with `niri validate`)
  appearance.json                        "space": "<id>" while a space with a theme is active
```

`spaces.kdl` holds named workspaces (`open-on-output` by identity, per-workspace
`layout`), window rules for app-ids Loft controls (`loft.<id>.*`), and the space binds.
The Loft session includes it after `base.kdl` and the theme fragment. A consumer like the
fleet includes it last, through `~/.config/loft/niri.kdl` as it does with
`overrides/niri.kdl`, so its binds and declarations win over earlier duplicates.

Library location (P1): `$LOFT_SPACES_DIR`, else `~/Documents/Loft/Spaces`;
`LOFT_LIBRARY=none` uses the built-ins only. Built-in templates are compiled into
`loft-niri`. As soon as the library has any singleton `<id>.json`, the library's
singletons replace the built-in set (seeding copies them there first). Settings →
Displays' main display is read from `overrides/shell.json` `displays.main`. Sessions
include `overrides/spaces.kdl` **once**, after the theme fragment (a workspace declared
twice exists twice).

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
loft-niri space focus|ensure|move-window <id|n>    # the fast path (P2, implemented)
loft-niri space next | prev | order | list [--archived] | render [--dry-run] [--no-binds]
loft-niri space plan <id|n> [--move-window] [--from-file STATE.json]   # the action list, not sent
loft-niri space open <id> [--no-focus] [--timeout S] | close | gather | apps <id>   # §4 (P3)
loft-niri space startup                                # open the `startup: "login"` spaces
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

**Status (2026-10-14, branch `spaces`).**

- **P0 done.** `loft-dev --outputs` (multi-output headless sessions, documented in
  TESTING.md). Spike answers are in §3.4.
- **P1 done.** `crates/loft-niri/src/spaces/{model,expr,roles,render}.rs`,
  `schemas/space-1.json`, `spaces/templates/{main,music,video,comms,gaming,task,
  project}.json`. Roles are checked against the wallsets fixtures. Golden `spaces.kdl`
  files (Cody's desk, a laptop) are in `crates/loft-niri/tests/golden/` and pass `niri
  validate` with `base.kdl`. All of it runs in `nix flake check` (crate tests, clippy,
  `tests/test_spaces_schema.py`).
- **P2 done.** `spaces/plan.rs` (pure `activate` / `ensure_only` / `move_window` /
  `order_all` / `step`, with golden action lists for focus order, keep, already-shown
  displays, target stay/main, fold stack/columns/skip, creation rounds, wrong-display
  moves and space order), `spaces/live.rs` (pipelined IPC), and `loft-niri space …`.
  Exercised live in a 3-output session: activating each space, next/prev, move-window,
  unplug/fold/replug, runtime-created instances, multi-round creation, render + order.
- **Not done in P2** (both done in P3): "activating the active space restores `keep`
  displays that were switched by hand" (§3.1); moving a `columns` fold's apps into main.
- **P3 done** (branch `spaces-p3`). `spaces/apps.rs` (pure: a space on a layout → its
  apps with workspace, column, cwd, unit; matching by claim → scope → regex/cwd;
  placement and column order as action lists; `/proc` cgroup / cwd / lineage),
  `spaces/runtime.rs` (`runtime.json`: session-scoped claims and `opened`, per-space
  keep memory, locked read-modify-write), `spaces/launch.rs` (systemd scopes, waiting,
  `open` / `gather` / `close` / `apps` / `startup`, and `focus` with memory + lazy
  spin-up), `plan::activate_with` + `keep_shown`, fold-aware window rules in
  `spaces.kdl`, `${profiles}` + `chromeApp()` for the Chromium apps. Unit tests: specs
  per layout and fold, matching order, two Project instances with one folder basename
  (claims, scopes, cwd), golden placement / order / fold action lists, toggles not
  repeated, keep-display restore, runtime sessions, rules per fold, Chromium app-ids.
  Exercised live in a 3-output session (`--outputs
  3440x1440+1440+0,1440x2560+0+0,2560x1440+4880+0`, fake `kitty --class` apps, real
  scopes through `LOFT_SPACES_SYSTEMD_RUNTIME_DIR`): open (≈1 s for four apps), a second
  instance side by side without stealing, focus (5 ms once open), gather after a manual
  move, keep-display restore, unplug → `columns` fold → replug → gather back, close,
  niri restart → lazy spin-up on first focus with `spaces.kdl` rules placing the exact
  app-ids, the no-scope fallback (`LOFT_SPACES_NO_SCOPES=1`), and Chromium `--app`
  preview + docs with scratch profiles.
- **Not done in P3:** `loft space archive` (P6's Python CLI); re-gathering on output
  changes is P4's to trigger (`space gather <active>` after Displays.qml sees outputs
  change); the "Couldn't find the window" toast is P4's (the note is in `--json`'s
  `notes`).
- **P4 done** (branch `spaces-p4`). `src/services/Spaces.qml`: the index from `loft-niri
  space list --json`; the active space = the owner of the main display's active
  workspace, else of the focused one, else the last one, re-derived once niri's events
  have been quiet for 140 ms and never while the shell's own activation runs (§3.4's
  intermediate focus events); `activated(space, previous)`. IPC `spaces focus <id|n> |
  next | prev | list | active | switcher | reload`. Bar: `bar/Workspaces.qml` is the §6.1
  indicator (pill → the switcher instead of a menu for now; the menu's New / Edit /
  Close / Theme items are P6). Switcher overlay `switcher/SpaceSwitcher.qml` on
  **Mod+Ctrl+S**; **Mod+Ctrl+←/→** spawn `loft-niri space prev/next` (both in
  `niri/shell-binds.kdl.in`; spaces.kdl rebinds the arrows identically). Island banner
  (1.2 s) on every switch, the OSD pill without the island. §5 applied on activation:
  `dock` (pinned replace/prepend/append, visible show/autohide/hidden →
  `DockData.profileFor`), `menubar.extras` (`Controls.barShown`; Control Center always
  stays), `bar.hidden` (on outputs showing one of the space's workspaces), `focus`
  (DND + allow list by app name, restored on leave unless changed by hand). `theme`:
  `Spaces.applyTheme()` is the P5 hook (logs only). The shell runs loft-niri with
  `--json` off the UI thread: `notes` of an activation ("Couldn't find the … window")
  become an island banner; a first activation's spin-up stops holding the derivation
  back after 1.5 s. Outputs changing: `space render`, `space ensure <active>`, `space
  gather <active>`, only once `overrides/spaces.kdl` exists (nothing is
  rendered behind a user who hasn't opted in). Settings → Spaces: read-only list,
  Activate, Open (shown once `loft-niri space open` exists, P3). Feature id `spaces`.
- **Not done in P4:** notes of activations the niri binds run (Mod+N, ⌃⌘← →
  spawn loft-niri directly) don't reach the shell; `space startup` belongs in the
  session's autostart (fleet / loft-session, P8), not wired; `dock.displays` per role (the shell has no role resolution; it
  would need roles in `space list`); the fold "+1" badge (§3.3); after a replug,
  `ensure` puts workspaces back but the returning display shows its first workspace,
  not the active space's (re-activating would warp the pointer; left to the user).
- **Decisions taken while implementing** (each noted where it applies): `target` vs
  `focus`, `layout` on the binding, binds by id, `space order` after render, Comms' id
  is `comms` (file `comms.json`, name "Communication").

**Tests.**

- **Unit**: roles over the `wallsets` fixtures (1, 2 and 4 displays, portrait,
  ultrawide), `plan()` golden action lists (focus order, keep, fold stack / columns,
  focus stay / main), template interpolation, matching (cgroup vs title fallback), claim
  conflicts between two Project instances.
- **Test sessions and scopes**: a `loft-dev` session has its own `XDG_RUNTIME_DIR`, so
  the systemd user manager isn't reachable from inside it and spin-up falls back to
  unscoped spawns. `LOFT_SPACES_SYSTEMD_RUNTIME_DIR=/run/user/$UID` lets `systemctl` /
  `systemd-run` reach it (the app gets the session's runtime dir and bus back through
  `env`), and `LOFT_SPACES_UNIT_PREFIX=<session>` names the scopes apart from real
  ones. Point `LOFT_SPACES_DIR` at a scratch library with fake apps (`kitty --class
  loft.<id>.<app> --title … sh -c 'exec sleep 1d'`) and `LOFT_SPACES_PROFILES` at a
  scratch dir. Remove leftover test scopes with `systemctl --user stop <unit>` by name.
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

### Open questions from P0–P2

- **Q-S1.** Carry a Loft niri patch for "activate a workspace without focusing" (removes
  the pointer jump and the intermediate focus events, §3.4), or only propose it
  upstream?
- **Q-S2.** `code` (today's generic editor workspace on the center) has no space, since
  §12.6 lists none. Keep it as an unowned utility workspace like `lab`, add it back as
  a "Programming" singleton, or let the editor rules target the active Project?
- **Q-S3.** Main binds `left` as `keep` (like Music and Gaming), so the left display
  keeps chat. Should Main show something of its own there instead?
- **Q-S4.** Mod+Ctrl+Space (§6.2's space switcher) is taken by the Radial Menu. Which
  key should the switcher get?
- **Q-S5.** Cody's AOC (`HDMI-A-2`, x=-2560) becomes `left-2`. No built-in space binds
  it, so it's always `keep`. Is that right?

### Follow-up decisions (2026-10-14, lead, under Cody's "go with defaults")

- **Q-S1** (switch a display's workspace without moving focus or the pointer): propose it
  upstream, and carry it as an opt-in Loft niri patch once written; until then the pointer
  jump is accepted.
- **Q-S2**: `code` stays a utility workspace (editor rules keep working); projects are the
  programming spaces.
- **Q-S3**: Main keeps the left display (chat stays visible).
- **Q-S4**: the space switcher gets **Mod+Ctrl+S** (Mod+Ctrl+Space stays the Radial Menu);
  next / previous space: **Mod+Ctrl+→ / ←**.
- **Q-S5**: yes, the AOC is `keep` in the built-ins.

