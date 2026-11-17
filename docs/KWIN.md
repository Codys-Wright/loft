# Loft on KWin: running the shell in a Plasma session

Status: **plan**. Step 1 (this doc), step 2 (the `Compositor` seam, §2) and step 7 (the decoration, §4.4) are done.
The KWin backend itself is not written yet. The niri session is unchanged and stays
the default.

Goal: a KDE Plasma session (KWin as compositor, plus the KDE services) where Loft's
bar, dock, launcher and switcher replace plasmashell. Hosts that run niri, and Cody
until this is ready, keep the niri session.

### Decisions (Cody, 2026-11-15)

| Question | Decision |
|---|---|
| Hide under KWin | KWin **minimize**, not parking on a hidden workspace |
| Spaces under KWin | **the user's own KDE Activities**, read-only; KDE's virtual desktops inside them (§4.2, revised 2026-11-16) |
| Lock screen | Plasma's locker (KWin has no `ext-session-lock`), **with Loft's lock design** as a shell package (§4.3) |
| Title bars | a **custom KWin decoration plugin** (KDecoration3, §4.4) |
| Wallpapers | one per screen, swapped with the desktop/activity. No per-workspace surfaces |
| Backing out | Loft and plasmashell must be **switchable**, live and at login, without leaving traces in each other (§5) |
| Window thumbnails | **icons first**. Thumbnails later through `ScreenShot2` (done, §4.8) |

## 1. What's already portable, and what isn't

These were checked against KWin 6.8.2 (the battleship's) and Quickshell 0.3.2 (the
version Loft pins), by listing the Wayland globals each binary exports or binds.

| Wayland protocol | KWin 6.8.2 | Quickshell uses it for | Under KWin |
|---|---|---|---|
| `zwlr_layer_shell_v1` | yes | every Loft surface (bar, dock, island, panels, wallpaper) | **works as-is** |
| `ext_background_effect_manager_v1` | yes | `BackgroundEffect.blurRegion` (bar, panels) | **works as-is**: KWin's blur |
| `ext_idle_notifier_v1` | yes | idle | works |
| `ext_data_control_v1` | yes | clipboard (cliphist / wl-clipboard) | works |
| `zwlr_foreign_toplevel_manager_v1` | **no** | `ToplevelManager` | `ToplevelManager` is empty |
| `ext_foreign_toplevel_list_v1` | **no** | — | — |
| `ext_session_lock_manager_v1` | **no** | `WlSessionLock` (Loft's lock screen) | Loft's lock can't lock |
| `zwlr_screencopy_manager_v1` / `ext_image_copy_capture_*` | **no** | `ScreencopyView` (thumbnails, display stills) | no in-shell capture |
| `hyprland_toplevel_export_v1` | no (niri-loft's patch) | window thumbnails | none |
| `zwlr_virtual_pointer_v1` | **no** | — (loft-input) | see §6 |
| `org_kde_plasma_window_management` | yes, privileged | — (Quickshell has no client) | needs our own client |
| `org_kde_kwin_fake_input` | yes, privileged | — | loft-input's alternative |

So the shell **draws** under KWin unchanged. What it can't do is **know about
windows**: every window and workspace fact today comes from niri's IPC (§2).

## 2. The compositor interface (done in step 2)

`src/services/Compositor.qml` is the only thing the shell talks to. `Niri.qml` is its
niri backend and nothing else imports it (`grep -rn '\bNiri\.' src` finds only
`Compositor.qml`). `Compositor.session` says what the session runs (`$LOFT_COMPOSITOR`,
else niri if `$NIRI_SOCKET`, else kwin if `XDG_CURRENT_DESKTOP` has `KDE`).
`Compositor.backend` is always `niri` for now.

**State.** The data model is niri-ipc's, because ~60 consumers read those field names.
A KWin backend produces the same records:

| | Fields consumers read |
|---|---|
| window | `id` (int, ascending = older; WindowCapture and the switcher rely on that order), `title`, `app_id`, `pid`, `workspace_id`, `is_focused`, `is_floating`, `is_urgent`, `focus_timestamp`, `layout.{window_size, tile_size, tile_pos_in_workspace_view}` |
| workspace | `id`, `idx` (1-based, per output), `name`, `output` (connector), `is_active` (per output), `is_focused` (global), `is_urgent`, `active_window_id` |
| other | `available`, `windows`, `workspaces`, `windowMap`, `workspaceMap`, `focusedWindow`, `focusedWorkspace`, `overviewOpen`, `keyboardLayouts {names, current_idx}`, `workspacesOn(output)`, `windowsOn(wsId)` |

**Events.** `screenshotTaken(path)`, `shutter()` (emitted by Loft's capture, not the
compositor), `configLoaded(failed)`, `windowMinimizeRequested(id)`,
`windowActionsMenuRequested(id, output, x, y)`, `outputsChanged()`.

**Actions** (semantic; the 26 raw `Niri.action("…")` calls are gone from consumers):

- any compositor: `spawn`, `focusWindow`, `focusWorkspace`, `focusWorkspaceRelative(±1)`,
  `closeWindow`, `moveWindowToWorkspace(win, ws, focus)`, `moveWindowToWorkspaceIndex`,
  `moveFocusedWindowToWorkspaceRelative(±1, focus)`, `moveWindowToOutput`,
  `moveFocusedWindowToNextOutput`, `toggleFloating`, `setFloating`, `toggleFullscreen`,
  `maximizeToEdges`, `centerWindow`, `setWindowWidthPercent` / `HeightPercent`,
  `resetWindowHeight`, `moveFloatingWindowPercent`, `setWorkspaceName`,
  `unsetWorkspaceName`, `switchKeyboardLayout`, `toggleOverview`, `screenshotWindow`
- scrolling layout only (`capabilities.columns`): `maximizeColumn`,
  `setColumnWidthPercent`, `expandColumn`, `centerVisibleColumns`,
  `expelWindowFromColumn`, `consumeOrExpelWindowLeft`

**Capabilities.** `Compositor.capabilities` is `{ columns, overview, windowScreenshot,
workspaceNames, perOutputWorkspaces, titleBarEvents, configReload, spaces }`, all true
under niri (`spaces`: Spaces work; under KWin they are Activities, §4.2). Nothing reads it yet. The KWin step gates menu items on it (e.g. MenuState's
"Maximize Column" and Arrange's column presets hide when `columns` is false).

### How the consumers map

| Area (files) | Uses | Under KWin |
|---|---|---|
| Bar: `bar/Workspaces`, `StatusItems`, `menubar/MenuBarTitles`, `components/WindowChrome` | workspaces per output, focused window title, layouts, overview | port: desktops, focused title, `org.kde.keyboard` |
| Menu bar + app menu: `menubar/MenuState`, `services/AppMenu`, `Arrange` | focused window, pid groups, close/float/fullscreen/move, hide = park on a `hidden-*` workspace | port. **Hide** becomes KWin minimize (decided): `hideApp`/`hideOthers`/`showAll` and the dock's unhide go through a `Compositor.setMinimized(id, bool)` the KWin backend adds, and the `hidden-*` parking stays niri-only. Column items off. Floating presets map to `frameGeometry` |
| Dock: `dock/*`, `services/DockData`, `Previews`, `WindowCapture` | windows by app, move/close, workspace names, thumbnails | port windows and actions. Thumbnails: stills through ScreenShot2 (§4.8) |
| Switchers: `switcher/Switcher`, `SpaceSwitcher`, `palette/*` | window list by `focus_timestamp`, focus | port. The bridge stamps `focus_timestamp` on activation |
| Launchpad, Spotlight, panels' "which screen": `Launchpad`, `Panels`, `Hud`, `Sound`, `clipboard/*`, … (~20 files) | `focusedWorkspace.output` | port: needs the focused window's output, or the cursor's |
| Everyday / QuitGuard / QuitOnClose / KeepAwake / KeyRemaps / WindowRules (running check) | windows by pid / app_id, close | port |
| Capture: `capture/Capture`, `island/Island` | `screenshotWindow`, `screenshotTaken`, `shutter` | screen/area capture goes through grim today, which needs screencopy (KWin has none): switch to `org.kde.KWin.ScreenShot2` (§4) |
| Wallpapers: `WorkspaceWallpapers`, `VideoWallpapers`, `Vibes` | active workspace per output, overview | per-workspace wallpaper **surfaces** off (they need niri-loft's patch). The "one wallpaper per screen, swapped on switch" fallback works |
| Spaces: `services/Spaces`, settings pages | named niri workspaces per output, activated together by loft-niri | **KDE Activities** (decided, §4.2). Off until that lands |
| Displays: `Displays` (`niri msg -j outputs`), `NiriSettings`, settings pages | output identities, config writes through loft-niri | **done** (§4.11): `Displays.outputs` / `setOutputs` → `KScreen.qml` → `loft-kwin displays` (kscreen-doctor) |
| Spaces: `services/Spaces`, settings pages | named niri workspaces per output, activated together by loft-niri | **the user's KDE Activities**, read-only (done, §4.2) |
| Displays: `Displays` (`niri msg -j outputs`), `NiriSettings`, settings pages | output identities, config writes through loft-niri | KWin-native: `kscreen-doctor -j` / KScreen D-Bus |
| Title-bar events (`windowMinimizeRequested`, `windowActionsMenuRequested`) | niri-loft's traffic lights | not needed: KWin decorations minimize and open the window menu themselves |
| `configLoaded` (NiriSettings, WindowRules) | niri reloaded its KDL | `org.kde.KWin.reloadConfig` after writing kwinrc / kwinrulesrc |

## 3. Getting the data out of KWin: three options

**A. KWin D-Bus API alone.** `org.kde.KWin /KWin` (`currentDesktop`, `queryWindowInfo`,
`getWindowInfo(uuid)`, `reconfigure`, `showDesktop`), `/VirtualDesktopManager`
(desktops, names, create/remove, `currentChanged`), `org.kde.keyboard /Layouts`,
`org.kde.KWin.ScreenShot2`, `/Effects`, `org.kde.kglobalaccel`. It's good for
desktops, layouts, screenshots and effects. But it has **no window list and no window
events**, and no per-window actions by id. On its own it can't feed the dock or the
switcher.

**B. A KWin script that pushes state.** Scripts (JS, Plasma 6 API) see everything:
`workspace.windowList()`, `windowAdded/Removed/windowActivated`,
`workspace.desktops`/`currentDesktop`, `workspace.screens`. Each window has
`internalId`, `caption`, `resourceClass`/`desktopFileName`, `pid`, `desktops`,
`output`, `frameGeometry`, `fullScreen`, `minimized`, `keepAbove`, `demandsAttention`
and change signals. Actions are plain assignments or calls (`workspace.activeWindow = w`,
`w.desktops = [d]`, `workspace.sendClientToScreen`, `w.closeWindow()`,
`w.frameGeometry = …`, `w.minimized = true`). The catch is that a script can only talk
**outward**, through `callDBus(service, path, iface, method, args…, callback)`. It can't
open a socket or export a D-Bus object. And Quickshell QML can't own a D-Bus service.

**C. Toplevel protocols (Quickshell's `ToplevelManager`).** KWin 6.8.2 exports neither
`wlr-foreign-toplevel` nor `ext-foreign-toplevel-list` (§1), so `ToplevelManager` is
empty. KWin's own `org_kde_plasma_window_management` has the data but is restricted to
privileged clients, and Quickshell has no client for it. Even where toplevel lists
exist, they carry no desktops and no stable ids.

### Recommendation: B, through a small Rust bridge, with A for the rest

```
KWin ──(loft-bridge.js: KWin script, callDBus)──▶ loft-kwin (Rust, zbus)
                                                      │ owns dev.loft.KWinBridge
                                                      │ line-JSON on stdin/stdout
                                                      ▼
                                   services/KWin.qml (Process, like AppMenu ↔ loft-appmenu)
                                                      ▼
                                               Compositor.qml
```

- **`crates/loft-kwin`** follows the `loft-appmenu` pattern: the shell starts it as a
  `Process` and talks line-JSON. On start it loads `loft-bridge.js` through
  `org.kde.KWin /Scripting loadScript` (loft-dev already does this, see
  `nix/dev/kwin-place.js`) and owns `dev.loft.KWinBridge` on the session bus.
- **State, KWin → shell:** the script calls `Bridge.Snapshot(json)` once and then
  `Bridge.Event(json)` for each change. loft-kwin turns those into niri-shaped events
  (`WindowsChanged`, `WindowOpenedOrChanged`, `WindowClosed`, `WindowFocusChanged`,
  `WorkspacesChanged`, `WorkspaceActivated`). Then `KWin.qml` can reuse
  `Niri.qml`'s reducer almost line for line. loft-kwin also maps KWin's UUIDs to
  ascending integer ids (oldest first, which the shell relies on). It synthesizes one
  workspace record per (desktop × output) pair, sets `is_active` from the current
  desktop, and sets `focus_timestamp` on activation.
- **Actions, shell → KWin:** the script long-polls
  `Bridge.NextCommands(callback)`. loft-kwin holds the reply until there's a command
  (async zbus can do that), then the script applies it and polls again. The fallback,
  if long-polling misbehaves, is kdotool's approach: one generated script per action,
  loaded, run and unloaded (~50–100 ms each, which is fine for menu clicks).
- **D-Bus directly (A)** for what KWin already serves well: desktop create/rename
  (`VirtualDesktopManager`), keyboard layouts (`org.kde.keyboard`), screenshots
  (`ScreenShot2`), overview (`kglobalaccel` → `Overview`), config reload.

Why not do it all in QML: a KWin script's only outward channel is D-Bus, and
Quickshell can't serve D-Bus, so something has to sit in between. Doing the
translation in Rust also gets it unit tests and keeps `KWin.qml` as thin as `Niri.qml`.

## 4. Feature by feature under KWin

**Ports as-is** (no compositor state): notifications, OSDs (volume/brightness),
control center, clipboard, island, phone, timers, Spotlight/launcher (walker), theme
engine, the bar's status items, blur (`ext-background-effect`).

**Ports through the backend:** dock (running apps, window lists, move/close), switcher,
app menu and menu bar titles, Quit guard, launchpad's running dots, workspace dots on
the bar (= desktops), "which screen" for panels, keyboard layout switching, floating
Arrange presets (geometry in % of `workspace.clientArea(MaximizeArea, …)`), move to
desktop / display, fullscreen, maximize, keep-above ("Float").

**KWin-native replacements:**

| niri / niri-loft | Under KWin |
|---|---|
| traffic-light title bars (`title-bar.patch`) | **Loft's own KDecoration3 plugin** (§4.4) |
| per-workspace wallpaper surfaces (`workspace-layers.patch`) | off (decided). One wallpaper per screen, swapped on desktop/activity change (the existing stock-niri path), under KWin's slide effect |
| window thumbnails (`toplevel-export.patch`) | **done** (§4.8): stills through `ScreenShot2.CaptureWindow` (`loft-kwin thumbs`), taken when the dock preview or the switcher opens |
| screen/area capture via grim | **done** (§4.7): `loft-kwin shot`, KWin's `ScreenShot2` |
| keybinds (loft-niri → niri KDL binds) | kglobalaccel, **done** (§4.5): `loft-keys.js`, a KWin script of `registerShortcut`s generated from shell-binds + Settings → Keyboard & Mouse → Keyboard Shortcuts, loaded while Loft's shell runs (§5) |
| window rules (loft-niri window_rules.rs) | **done** (§4.17): the same `window-rules` records, applied by loft-bridge.js as windows open (Activity, desktop, display role, full screen / maximized / size, keep above, follow) while Loft runs, never written to `kwinrulesrc` (§5); `loft open` places one launch's windows |
| outputs / Displays page | `kscreen-doctor` (or KScreen D-Bus). Identities from its JSON |
| overview (`toggle-overview`) | KWin's Overview effect; its state reaches the shell as `overviewOpen` (§4.9) |
| outputs / Displays page | **done** (§4.11): `kscreen-doctor -j` + `-o`, applied with `kscreen-doctor output.…`; identities from the bridge's screens |
| overview (`toggle-overview`) | KWin's Overview effect |
| lock screen (`WlSessionLock`) | Plasma's locker with **Loft's lock design** (§4.3) |
| Spaces (named niri workspaces per output) | **the user's KDE Activities**, read-only (§4.2) |
| idle (swayidle on niri.service) | PowerDevil (Plasma's own idle and DPMS) |
| xremap per-app remaps (`xremap.niri`) | **done**: `loft-plasma-keys.service` runs `xremap.kde` (its KWin script reports the focused window's `resourceClass`, the Wayland app id) on the same config (§4.5) |
| WM key (Caps / Esc / Right Ctrl held → Right Alt = niri Mod) | **done**: the hold is a private xremap virtual modifier (F24) that sends **Meta** + the next key, so KWin's and Loft's Meta shortcuts are reachable (§4.5, `LOFT_WM_KEY=meta`) |

**Off under KWin** (hidden with `Compositor.capabilities`): scrolling-column ops
(consume/expel, center visible; Maximize Column, preset widths and center column are
KWin keys instead, §4.5), niri's motion
and shape settings (KWin has its own animations), the niri sections of Settings
(keybinds-as-KDL, window-rule KDL preview), and workspace-layer wallpapers. Columns are
niri's by nature, so Settings hides their controls under KWin rather than showing dead
ones: Spaces & Windows → **Layout & Motion** is greyed out on the overview ("KWin's own
under Plasma: System Settings → Window Management") and, if reached anyway, shows only
that note; Window Rules has no **Column width**; a Space's editor has no workspace names
(a role is Keep / Apps), and its apps' column order and widths (kept in the document,
used under niri) aren't offered.

### 4.1 Hide = minimize

KWin has real minimize, so MenuState's "park on a `hidden-*` workspace" trick stays
niri-only. Under KWin, `hideApp`/`hideOthers` set `minimized` on the windows, `showAll`
and the dock's unhide clear it, and `MenuState.hidden` is derived from `w.minimized`.
The window record gains an `is_minimized` field (always false under niri). The
decoration's minimize button and Loft's Hide then mean the same thing.

### 4.2 Spaces = your KDE Activities

**Done** (step 10, reworked 2026-11-16). An Activity is a set of windows (plus its own
wallpaper and settings) that switches as one across **every** display. That is what a Space
is (SPACES.md §1), so under KWin **the user's own KDE Activities are Loft's Spaces**, and
**KDE stays the source of truth**: Loft never creates, renames, re-icons or removes an
Activity, and never takes KDE's keys for them. Virtual desktops stay KWin's, *inside* the
Activity: ⌃← → step them, as ⌃← → step Spaces on macOS.

Why not one Activity per library Space (what step 10 did first): on a real session the
library (Main, Music, Video, Communication …, written for niri) didn't match the user's
Activities (Default, Music, Coding, Gaming, Editing, System Configuration), Loft took
Meta+1…6 off "Switch to activity" for Spaces that had no Activity yet, so ⌘N did nothing,
and the first sync would have renamed the current Activity and added duplicates. Decision
(Cody, 2026-11-16): KDE's Activities are the Spaces; KDE's virtual desktops live inside them.

- **The list** (`crates/loft-kwin/src/activities.rs`, read-only). loft-kwin reads
  kactivitymanagerd (`org.kde.ActivityManager /ActivityManager/Activities`:
  `ListActivities`, `ActivityName`, `ActivityIcon`, `CurrentActivity`) and kglobalaccel's
  `/component/ActivityManager` (`allShortcutInfos`, actions `switch-to-activity-<uuid>`),
  and sends the shell `{"Activities": {"activities": [{id, name, icon, key, position}],
  "current"}}` at start, on `{"cmd": "activities"}`, and again after every
  `org.kde.ActivityManager.Activities` signal (added, removed, renamed, re-iconed, current
  changed), every kglobalaccel `yourShortcutsChanged`, and when kactivitymanagerd
  (re)starts (debounced 150 ms).
- **Order:** the Activities whose "Switch to activity" key is on a digit, by that digit
  (Meta+1 … Meta+9, then Meta+0; `position` = the digit), then the rest in
  kactivitymanagerd's order (`order()`, unit-tested). A digit two Activities share keeps
  its position on the first. That order is the bar's dots, the switcher, Settings →
  Spaces, `spaces next/prev`, and `spaces focus N` / `moveWindow N` (N = the digit: the
  Activity KDE's Meta+N switches to). Reordering is KDE's (change the shortcuts).
- **Spaces.qml** (`byActivity`): `all` = one space per Activity: `{id, name, icon, kdeIcon,
  key, position, activity, linked, displays, startup, doc}`. The name is always KDE's; the
  icon is a Nerd Font glyph guessed from KDE's icon name or the Activity's name (the bar
  draws glyphs, not freedesktop icons). `spaces focus` takes an id, the digit, an Activity
  id or a name (any case).
- **Loft's extras attach by link only.** A library document (SPACES.md §2) whose
  `"activity"` is the Activity's id or name (any case) gives that Activity its dock, menu
  bar extras, `bar.hidden`, Focus, `wallpapers`, apps and display roles (§4.15); the space
  then has the document's id. **No document → a plain Activity**: switching, the bar,
  Move to Space and its windows all work; no extras, nothing started. Settings → Spaces & Windows → Spaces
  links one (a card's **Add Loft Settings…**: new settings, or "Use “Music”" for a library
  document no Activity has yet), **Edit** / **Unlink** / **Remove Settings…** it later;
  **Save This Activity's Apps** (§4.15's capture) writes a document linked to the current
  Activity. Linking only writes the document (`loft-niri space save|patch`); the Activity
  isn't touched. Under niri the `activity` field is ignored.
- **Switching.** KDE's own "Switch to activity" shortcuts do ⌘1…9 / ⌘0 (Loft binds none of
  them, §4.5). The bar's dots, the switcher, Settings' Activate and `spaces
  focus|next|prev` set `workspace.currentActivity` through the bridge (`setActivity`), with
  wrap-around. The **active Space** is the current Activity's (`Spaces.deriveActivity`); a
  change fires `activated` (island banner, per-Space dock / menu bar / DND). Focusing a
  window of another Activity (dock, switcher) switches to it first (bridge.js
  `focusWindow`).
- **Moving a window:** `Spaces.moveWindow(space, window?, follow?)` → bridge.js
  `setWindowActivities` (`w.activities = [uuid]`), from Window ▸ Move to Space, the app
  menu, ⌘⇧1…9 / ⌘⇧0 (when KDE binds nothing there, §4.5) and `qs ipc call spaces
  moveWindow <n|id|name>`.
- **Virtual desktops inside the Activity.** KWin's desktops are global, a window belongs to
  an Activity *and* a desktop, so each Activity shows its own windows on each desktop.
  ⌃← → reach KWin as Meta+Ctrl+← → (the keyboard layer's `mac-parity` group), which KWin's
  own *Switch One Desktop to the Left/Right* has by default; Loft doesn't bind them under
  KWin any more. ⌃⇧← → become Meta+Ctrl+Shift+← → (Plasma only), KWin's *Window One
  Desktop to the Left/Right* (moves the window and follows it). The bar shows the desktops
  after a divider when there is more than one (the current one highlighted, filled when the
  current Activity has windows there; click to switch) and the pill says "Coding · 2".
- **Per-Space wallpaper:** one wallpaper per screen, swapped (crossfaded) on Activity
  change: a linked document's `wallpapers` for the screen's most specific role, else the
  per-workspace choice made under niri for the workspace it binds to that role. A plain
  Activity keeps the current wallpaper.
- **Not under KWin:** New Space / templates in Settings (a new Space is a new Activity,
  made in Plasma), reordering, renaming (Plasma's), archive, workspace names and the
  apps' column order / widths (niri's; the editor hides them).
- **Documents made for an Activity stay out of niri.** One library serves both sessions.
  A document whose settings exist only for a KDE Activity would otherwise be an extra
  niri Space (a ⌘ number with nothing on it, or a captured Activity's apps showing up as
  a Space). So a document is **no niri Space** when it says `"niri": false` (written by
  **Add Loft Settings… → New settings** and **Save This Activity's Apps**), or when it has
  an `activity` and binds no workspace (what older builds' New settings wrote). loft-niri
  leaves those out of `Catalog::active()` (⌘N, the switcher, `next`/`prev`, spaces.kdl's
  binds, `space startup`); `space list` still lists them (`"niri": false`, no position)
  and finds them by id, so under KWin nothing changes. Under niri, Settings → Spaces lists
  them in an **Only for KDE Activities** card with **Use as a Space Here** (`niri: true`,
  plus `main` if it binds nothing), and a niri Space that is also linked (the **Use
  “Music”** case: an existing niri Space linked by name) stays a Space, its card saying
  "also KDE Activity “Music” under Plasma". Badge only, not hidden: linking an existing
  Space mustn't take it away from niri.
- **Older Loft builds' Activities.** Step 10 at first kept `<state>/kwin-activities.json`
  (`{"spaces": {"<id>": {"activity", "adopted"?: {name, icon}}}}`). Nothing writes it now.
  `loft spaces prune [--dry-run]` (= `loft-kwin spaces prune`) undoes **only what it
  records**: removes the Activities those builds created and gives an adopted one its old
  name and icon back, then deletes the file; with no file it does nothing. `loft spaces
  activities` prints the Activities in Loft's order (plus the old map, if any). Both use
  the session bus; `loft --dev` targets a dev session.
- **Tested** in a nested KWin 6.8.2 (§6, two outputs, `LOFT_LIBRARY` / `LOFT_SPACES_DIR`
  scratch with the built-in library Main, Music, Video, Comms, Gaming, Task) with
  kactivitymanagerd on the session's bus. Setup like the user's: Activities Default,
  Music, Coding, Gaming, Editing, Ignition, System-Configuration created in a scrambled
  order, "Switch to activity" keys Meta+1…6 and Meta+0. Results: no Activity renamed or
  created and no map written; the bar, the switcher (⌘1…⌘6, ⌘0) and `spaces list` showed
  them in key order, live through adds and a rename; real key presses (`loft-input key`)
  Meta+3/4/1/2/6 switched to Coding/Gaming/Default/Music/Ignition and the shell's active
  Space followed; Meta+0 did too once KWin's stock *Zoom to Actual Size* (also Meta+0 in a
  fresh profile, and the winner) had its key cleared, as on a profile where Meta+0 was
  given to an Activity; Meta+Ctrl+→ →, ← stepped desktops 1→2→3→2 inside Default;
  Meta+Ctrl+Shift+← moved KWrite to desktop 2 and followed, the Activity unchanged;
  `spaces moveWindow 2` put KWrite on Music while Default stayed current; `spaces focus
  coding | next | 0` switched; the bar showed "Default · 2" and the desktop cells; linking
  (`activity: "Music"` by name, a new `coding` document by id) showed both as linked with
  Edit / Open; `prune` with an old map (an adopted Default renamed Main, a made Video)
  restored "Default", removed Video, ignored a stale entry and touched nothing else. The
  shortcut load (§4.5) with an old record of six ActivityManager entries gave all six back
  and didn't take them again.

### 4.3 Loft's lock design in Plasma's locker

**Done** (step 8): `lock/plasma/` → package `loft-plasma-lockscreen` (`nix/lock.nix`).

KWin can't host Loft's `WlSessionLock`, but Plasma 6's greeter is themeable.
`kscreenlocker_greet` (6.8.2) loads `contents/lockscreen/LockScreen.qml` from a
Plasma **shell package**, picked by `PLASMA_DEFAULT_SHELL` (default
`org.kde.plasma.desktop`), unless `plasmashellrc [Shell] ShellPackage` is set.

- **`dev.loft.desktop`** holds only `metadata.json` + `contents/lockscreen/`. KPackage's
  Plasma/Shell structure gives every non-default shell a fallback package
  (`X-Plasma-FallbackPackage`, default `org.kde.plasma.desktop`), so everything else
  (and the lock screen's `config.xml`) comes from Plasma's own. It installs to
  `share/plasma/shells/dev.loft.desktop`: system-wide from the NixOS module
  (`programs.loft.plasma`), and in `home.packages` from the home-manager module.
  A copy in `~/.local/share/plasma/shells` works too, and **wins** over the system
  one (XDG_DATA_HOME comes first), so don't leave stale copies there.
- `LockScreen.qml` is the host: it imports only QtQuick and `org.kde.kscreenlocker`,
  runs PAM through the greeter's `authenticator` (`startAuthenticating()` every second
  while locked, `respond()`, waits out `inPasswordDelay`, `failed(0)` → "Incorrect
  password" + shake, `succeeded` → `stopAuthenticating()` + `Qt.quit()`), and picks
  the screen that shows the card. `LoftLock.qml` feeds `MacLock` (src/lock/design,
  copied in with `qs.*` rewritten, as for SDDM) with the user's rendered theme and
  wallpaper: `$XDG_STATE_HOME/loft/current/{theme.json,wallpapers.json}`, read at
  every lock, so it follows `loft theme apply` without a rebuild.
- Never unlockable: if `LockScreen.qml` fails to load, the greeter uses its built-in
  fallback locker. If the design fails, `LockScreen.qml` shows a plain password field.
  The card fails open: when the greeter can't tell which screen is active, every
  screen shows it. Lock, unlock, idle and sleep stay Plasma's (kscreenlocker +
  PowerDevil).
- **Only Loft sessions.** KWin spawns the greeter with its own environment, so the
  variable goes on `plasma-kwin_wayland.service` only, never the user manager (a
  `set-environment` would leak into plasmashell and every later unit). The
  home-manager drop-in adds `ExecStartPre=-loft-plasma lock-env`, which writes
  `$XDG_RUNTIME_DIR/loft/plasma-lock.env` (`PLASMA_DEFAULT_SHELL=dev.loft.desktop`,
  `QML_XHR_ALLOW_FILE_READ=1` for the theme files) when `loft-plasma check loft`
  passes and removes it otherwise, and `EnvironmentFile=-` reads it (systemd reads
  env files right before each command, so after the ExecStartPre). The login wrapper
  writes the session marker before `startplasma-wayland`, which starts KWin, so the
  check sees this login. A plain "Plasma" login keeps Breeze's lock screen.
- `loft-plasma use plasma|loft` switches the shell live, but not the lock screen:
  KWin's environment is fixed at start, so the lock follows the login entry until
  the next login.
- Preview: `kscreenlocker_greet --testing --shell <id or path>` (the option is
  `--shell`, not `--theme`). With `PLASMA_DEFAULT_SHELL` and the package on
  `XDG_DATA_DIRS`, no option is needed. Run it in the nested KWin of §6, never on the
  live session. Testing mode still authenticates through real PAM (the `kde` service).

### 4.4 Loft's KWin decoration

**Done** (`kdecoration/`, package `loft-kdecoration`). A KDecoration3 plugin in C++,
id **`dev.loft.decoration`**, installed at `lib/qt-6/plugins/org.kde.kdecoration3/`.
`programs.loft.plasma` (NixOS) puts it in `environment.systemPackages`, so KWin finds it
on `QT_PLUGIN_PATH`.

- **Look: macOS 26 Tahoe's title bar.** The metrics are measured on real macOS 26.6
  (2x screenshots, in points); the art comes from the MacTahoe KDE theme's Aurorae
  decoration (a careful copy of Tahoe's). Both are cited in `kdecoration/tahoe.h`:

  | | traffic lights | vertical centre | left inset (first bead's edge) | strip |
  |---|---|---|---|---|
  | macOS Brave (compact tab strip) | 14 pt, 23 pt centre to centre (9 pt gaps) | 20 pt | 13 pt | 40 pt |
  | macOS Preview / Finder (unified toolbar) | 14 pt | 26 pt | 19 pt | ~52 pt |
  | Brave on Linux (its own strip, scale 1) | | | | 40 px |
  | MacTahoe Aurorae (what Loft matched before) | 14 px, 26 px apart | 18 px | 17 px | 34 px |

  Loft draws the compact one: a 40 px bar, 14 px beads 23 px apart, centred in the
  bar, the first one 13 px in. macOS insets the first bead from the left as much as
  from the top, and so does Loft: `TitleBarHeight=52` in the INI gives the toolbar's
  19 px. The title is centred vertically too. From MacTahoe: the beads' exact light /
  dark fills and rims (its beads are 14 px too, so glyphs and rims keep their size),
  grey when the window is in the background, 24 px corners (top and bottom), a 1 px
  frame with Tahoe's white highlight (dark: all around), a 1 px black outline outside
  the frame (KWin's border outline, crisp at any scale), and Tahoe's shadow (fitted to
  MacTahoe's rendered shadow: strength · (1 − d / reach)^1.5 per side, reaches = the rc's
  shadow paddings). Glyphs are MacTahoe's SVG paths (×, −, the two-triangle zoom glyph,
  inward triangles when maximized). Where Aurorae can't do what macOS does, it follows
  macOS: pointing at the button group (gaps included) shows all three glyphs and lights
  the beads of a background window too; the title is centred on the window, 13 px
  semibold in the KDE title font's family; bottom corners are rounded. Green shows the
  full-screen arrows, or a "+" while Option (Alt) is held (below).
- **Theme:** the `kdecoration` render unit (`cli/loft/render/kdecoration.py`,
  `templates/render/kdecoration.ini`) writes `<state>/current/kdecoration.ini` with only
  `[General] Appearance=light|dark` (the colors' polarity): the traffic lights are fixed
  colors, as on macOS, and the bar, text and grey beads are Tahoe's for that appearance.
  A hand-written file may still override `[Colors]` TitleBarActive / TitleBarInactive /
  TextActive / TextInactive (`#rrggbb[aa]`, Loft's order) and `[Metrics]` CornerRadius /
  TitleBarHeight (at least 18) / FontSize. The plugin reads it from `$LOFT_STATE_DIR`, else
  `$XDG_STATE_HOME/loft`, else `~/.local/state/loft`, watches the file, `current/` and the
  state dir (the theme engine swaps the `current` link), and repaints open windows on
  change. Without the file it is Tahoe dark.
- **Behavior is macOS's** (table in [WINDOW-DECORATIONS.md](WINDOW-DECORATIONS.md#under-kwin)):
  red and yellow are KDecoration's Close / Minimize (minimize is real, = Hide, §4.1).
  **Green** is full screen; with **Option** (Alt, PLAN.md §5: Loft's Option key) held it
  zooms (KWin's maximize, both ways) and shows a "+" instead of the arrows, live as the key
  goes down and up; the tooltip says "Enter Full Screen" / "Zoom". **Resting the
  pointer** on green (600 ms, as macOS 26 Tahoe) or **pressing and holding** it (350 ms,
  as niri-loft) opens Loft's window menu under the bead; the release after a hold doesn't
  count as a click. **Right-click** on the bar (beads included) opens the same menu at the
  pointer. The menu is the shell's `trafficLightItems` (niri-loft's bar opens it too), laid
  out like Tahoe's: rows of tile icons first — Move & Resize (halves, quarters), Fill &
  Arrange (fill, center, and the window with the others on its workspace left & right, top
  & bottom, in quarters) — then Enter Full Screen, Zoom, Move to Display ▸, Move to
  Workspace ▸ (and Move to Space ▸). See WINDOW-DECORATIONS.md for the rows. Double-click on the
  bar zooms whatever KWin's title-bar action is; drag and the other title-bar actions
  are KWin's settings.
  - **How** (`kdecoration/shell.{h,cpp}`): KDecoration has no request for full screen
    and no way to reach Loft's menu, and the decoration doesn't know its window's id. It
    calls `dev.loft.KWinBridge.TitleBar(json)` (`{"action": "fullscreen"|"menu"|"tileMenu",
    "x", "y"` = decoration-local anchor, `"width", "height"` = the frame}`) on the session
    bus; loft-kwin queues a `titleBar` command; the loft-bridge script takes the topmost
    window under `workspace.cursorPos` whose frame is that size, toggles `fullScreen` or
    sends `Event({"WindowActionsMenuRequested": {window, output, x, y, kind}})` back, which
    loft-kwin prints for the shell (`KWin.qml` → `Compositor.windowActionsMenuRequested`,
    as niri's event; `capabilities.titleBarEvents` is now on). Title-bar menus open down
    and right from the point (`openContext` edge `"pointer"`), under niri too.
  - **Without the shell** (no `dev.loft.KWinBridge` owner, watched with a
    `QDBusServiceWatcher`, or the call fails within 1 s): green maximizes, and
    right-click / hold show KWin's own window menu. loft-kwin is the shell's child, so the
    name's owner means the shell runs. (loft-kwin now exits right after SIGTERM: tokio's
    blocking stdin thread used to keep it alive without its bus name, so the shell never
    restarted it.)
  - **Alt+F3** (KWin's "Window Operations Menu", or whatever key it has) opens Loft's
    window menu for the active window, under its green bead: `loft-keys.js` (§4.5)
    registers `loft-window-menu` on that key, and `claim` moves it to the key KWin's
    action has (the record keeps the original when a restart claims again) and takes it
    off KWin's action; `release` gives it back. The callback asks the bus whether
    `dev.loft.KWinBridge` has an owner: yes → `loft-kwin`'s `Command
    {"cmd":"windowMenu"}` → the bridge's `windowMenu` sends the same
    `WindowActionsMenuRequested` as a held green (anchor: frame + (59, 27), the green
    bead's lower left; (16, 16) for a window without a title bar); no → KWin's own menu
    (`workspace.slotWindowOperations()`). With no active window the bridge shows KWin's.
    A bind of the user's own on Alt+F3 (Settings → Keyboard & Mouse → Keyboard Shortcuts) keeps the key.
    Tested nested (KWin 6.8.2, `loft-input key alt+F3`, the branch's loft-kwin): Loft's
    menu opened under KWrite's green bead; with that loft-kwin killed, KWin's own menu at
    once; `claim` took "Window Menu" (KWin's friendly name) and `release` gave Alt+F3
    back, kglobalshortcutsrc's line as before.
  - **Apps that draw their own title bar** ask the compositor for the window menu
    themselves: a Wayland client's `xdg_toplevel.show_window_menu` (GTK 3/4 and
    libadwaita header bars on right-click, Electron's `-webkit-app-region: drag` areas)
    and X11's `_GTK_SHOW_WINDOW_MENU` (GTK on Xwayland). Stock KWin 6.8.2 sends both
    straight to `UserActionsMenu::show` (`XdgToplevelWindow::handleWindowMenuRequested`
    → `performMousePressCommand(MouseOperationsMenu)`, `X11Window::GTKShowWindowMenu`
    → `Workspace::showWindowMenu`). Nothing on that path reaches a script or an
    effect: no signal, no config to route it, and the decoration isn't involved. The
    only script hook, `registerUserActionsMenu`, adds entries to KWin's menu while it
    opens and can't stop it. So it takes a **KWin patch**
    (`nix/kwin/client-window-menu-service.patch`, ~50 lines, next to Option-drag's,
    §4.6, in `loft-kwin-patched`):
    - kwinrc `[Windows] ClientWindowMenuService` (default empty = stock), read with the
      other options (`Options::clientWindowMenuService()`, member at the end of
      `Options`, re-read on `reconfigure`).
    - `Workspace::showClientWindowMenu(window, globalPos, fallback)`, called from those
      two client paths only (KWin's own Alt+F3, mouse bindings and decorations are
      unchanged): with the key set, an **async** call to `<service>`
      `/WindowMenu` `org.kde.KWin.ClientWindowMenu.Show(s window, d x, d y) → b`
      (KWin's internal id, the global point), 1 s timeout. An error (no owner: at
      once), a timeout or `false` runs the fallback: KWin's menu, as stock. KWin never
      blocks on the bus.
    - loft-kwin serves that interface on `dev.loft.KWinBridge` and queues
      `{"cmd":"clientMenu","window","x","y"}`; the bridge script's `clientMenu` sends
      the same `WindowActionsMenuRequested` as a right-click on Loft's own bar (`kind`
      `"menu"`, anchored at the point the app asked for).
    - `loft-kwin-window-menu apply` (loft-plasma-shell's `ExecStartPost`, only with
      `programs.loft.plasma.kwinPackage`) records the previous value in
      `<state>/kwin-window-menu.prev`, sets `dev.loft.KWinBridge` and reconfigures KWin;
      `revert` (`ExecStopPost`) puts it back unless it was changed by hand (§5). In
      plain Plasma the key is unset, and even if left set, with no Loft on the bus KWin
      falls back at once.
    - Who asks: GTK 3 / GTK 4 / libadwaita (gnome-text-editor, gtk3-demo), Electron
      frameless windows. Chromium's own tab strip doesn't: it shows Chromium's context
      menu (Minimize, Maximize, New tab, …, "Use system title bar and borders").
      Chromium `--app` windows take server-side decorations under KWin, so Loft's bar
      already gives them Loft's menu.
    - Needs the patched KWin and a re-login (it's the session's compositor). With
      stock KWin these keep KWin's menu (with the global Qt style, §4.14, in Loft's
      look after a re-login).
    - Tested nested (KWin 6.8.2 + both patches, the branch's loft-kwin and shell,
      `loft-input` right-clicks): key unset → KWin's menu on gnome-text-editor's
      header bar; `apply` → Loft's menu at the pointer, and Left Half moved that
      window; the same for a frameless Electron 43 window (`--ozone-platform=wayland`)
      and for gtk3-demo with `GDK_BACKEND=x11`; loft-kwin killed → KWin's menu at once
      (X11 and Wayland), Loft's again once the shell restarted it; `revert` → KWin's
      with loft-kwin running; `revert` keeps a value set by hand.
  - KWin's `[MouseBindings]` defaults put no window menu on Alt+click (Alt+right-drag
    resizes), and the Window Operations button (`M`) isn't in Loft's button order. Loft
    has no task manager.
  - **Option**: KWin builds decoration hover events without modifiers (`input.cpp`
    `DecorationEventFilter`; presses do carry them) and a key alone sends the decoration
    nothing. KWin's `InputRedirection` (a child of the application object) has
    `keyboardModifiersChanged`: the plugin finds it by class name and connects by
    signature, so it doesn't link KWin. Outside KWin (System Settings' previews) Option
    never reads as held. The click itself also checks the press's own modifiers.
  - **Arrange under KWin**: presets are several `geometryPercent` commands (width, height,
    move) and a resize only shows in `frameGeometry` once the client acks it, so each
    step used to start from the stale frame (Left Half came out at the old size). The
    script now builds each step on the geometry it last asked for (kept 1 s).
  - **Rest** (`Button::restFrom`): the timer starts when the pointer enters green, or
    moves on it; leaving or pressing stops it. Only while the shell runs (KWin's own menu
    doesn't open on hover). After the menu opens, closing it (Esc, a click elsewhere) makes
    KWin hover the bead again at the same spot; that doesn't reopen it until the pointer
    has moved more than 3 px, as on macOS, where the menu stays closed until you move.
  - **Tiles** (`Arrange.tileRows`, drawn by `MenuPanel`'s `tiles` rows): each icon is a
    small screen with the window's rect filled (other windows' rects lighter); ← / →
    move along a row, ↑ / ↓ between rows, Return applies. "Arrange …" puts this window
    in the first rect and the most recently focused other windows (`focus_timestamp`) in
    the rest, then focuses this one; they're dimmed when the workspace has too few
    windows. Under niri a tile floats a tiled window (as Arrange's presets always did);
    the column choices live on under Column ▸.
  - Tested nested (KWin 6.8.2, the branch's plugin, loft-kwin and shell): rest on green →
    no menu at 300 ms, the menu at 1 s; leave after 300 ms → none; Esc with the pointer
    still on green → none 1.5 s later (tooltip only), a 4 px move → the menu again; hold
    700 ms → the menu, the release doesn't toggle full screen; hovering a tile names it
    on the header; Arrange Left & Right with two windows, Arrange in Quarters with four
    (this window top left, the next most recent top right, …); Down, Right, Return →
    Top Right. niri (`loft-dev --gpu`): right-click on a tiled foot's bar → the same rows
    plus Column ▸ and niri's shortcuts; Left Half → floating, 640×674 at 0,50.
  - Not done: Arrange through KWin's own quick tiles (its shortcut semantics combine with
    the current tile and hop outputs); the rest timer on niri-loft's bar (its input code
    lives in the niri fork).
- **Selected only while Loft runs** (§5): `loft-kwin-decoration apply` (the
  `ExecStartPost` of `loft-plasma-shell.service`) records the user's own kwinrc
  `[org.kde.kdecoration2] library` / `theme` in `<state>/kwin-decoration.prev` (a key
  only set in `/etc/xdg` is recorded as unset), selects Loft's and calls
  `org.kde.KWin.reconfigure`. `revert` (`ExecStopPost`, so a crash reverts too) puts
  the recorded values back, deleting keys that weren't set, unless the user picked
  another decoration meanwhile. `apply` does nothing when the plugin isn't installed.
  KWin 6.8 still reads the group `org.kde.kdecoration2` (the plugins' namespace is
  `org.kde.kdecoration3`).
- **Button order for apps that draw their own title bars.** `apply` also records
  kwinrc `[org.kde.kdecoration2] ButtonsOnLeft` / `ButtonsOnRight` and sets macOS's
  order, `XIA` / empty (KWin's letters: X close, I minimize, A maximize, M menu,
  S all desktops, H help, F keep above, B keep below, L shade, N application menu;
  Plasma's default is `MS` / `HIAX`). `revert` puts each back if it is still Loft's.
  kded's **gtkconfig** module (kde-gtk-config 6.8, `onKWinSettingsChange`) turns them
  into GTK's notation (`close,minimize,maximize:`; only X/I/A/M have GTK names) and
  writes `gtk-decoration-layout` to `gtk-3.0/settings.ini` and `gtk-4.0/settings.ini`,
  `Gtk/DecorationLayout` to xsettingsd (and its own XSETTINGS manager for Xwayland),
  and GSettings `org.gnome.desktop.wm.preferences button-layout`. Traps, both seen:
  - gtkconfig only reacts to KConfig's **change notification** (`kwriteconfig6
    --notify`, i.e. `org.kde.kconfig.notify.ConfigChanged` on `/kwinrc`); a plain
    write or `org.kde.KWin.reconfigure` changes nothing. With kded running it lands in
    about 0.1 s; without kded nothing is copied until it starts (it applies everything
    then). The script sends the signal itself (`gdbus emit`) so deletions notify too.
  - `kwriteconfig6 --delete` of a key that a lower file also sets (`/etc/xdg`, or
    `~/.config/kdedefaults/kwinrc`, which a global theme like MacTahoe fills with its
    decoration and `XIA`) writes `key[$d]`, which hides that value: revert used to
    leave Plasma's Breeze (and would have left `MS`/`HIAX`) instead of the user's
    theme. The script drops the marker. KConfig also skips writing a value the lower
    files already give, so "still Loft's" is checked on the cascaded value.

  Who follows it: GTK 3 (gtk3-demo) and GTK 4 / libadwaita (gnome-text-editor), native
  Wayland, move their buttons **live** (verified nested; they watch GSettings / the
  settings portal). Chromium / Brave with the GTK frame and Electron apps that use
  GTK's layout read it through GtkSettings, which also updates live, but neither was
  in the test session, so unverified; restart them if they don't follow. Electron
  apps with fixed custom buttons (Obsidian's own frame, VS Code's custom title bar)
  ignore it.
- **Compared** first with MacTahoe-Light/Dark (Aurorae, border size Tiny) pixel by
  pixel, then re-measured against the macOS numbers above in a nested session
  (kwrite, dark; device px ÷ scale = logical):

  | scale | bar | bead | centre to centre | first bead from frame edge | bead / title centre from top |
  |---|---|---|---|---|---|
  | 1 | 40 | 14 | 23 | 13 | 20 / 20 |
  | 1.25 | 50 dev = 40 | ~17.5 dev = 14 | 29 dev ≈ 23.2 | 16 dev = 12.8 (snapped) | 24.5 dev ≈ 19.6 / same |
  | 1.5 | 60 dev = 40 | 21 dev = 14 | 34.5 dev = 23 | 20 dev ≈ 13.3 | 30.5 dev ≈ 20.3 / same |

  Edges stay crisp at 1.25x / 1.5x (bar and frame on the pixel grid, beads
  antialiased). Build the plugin against the system's nixpkgs (`--override-input
  nixpkgs nixpkgs`) or KWin won't load it, and pass it with `--kwin-env
  QT_PLUGIN_PATH=<build>/lib/qt-6/plugins:$QT_PLUGIN_PATH` (first wins). Run `apply`
  once KWin is up, or call `org.kde.KWin.reconfigure` again: a reconfigure sent too
  early is lost and windows keep the old decoration.
- **Title-bar behaviors tested** nested (KWin 6.8.2, kwrite, the branch's plugin and
  loft-kwin via `--kwin-env QT_PLUGIN_PATH=… --kwin-env LOFT_KWIN_BIN=…`): hover green →
  arrows, `keydown alt` without moving → "+", `keyup` → arrows; tooltips follow; click →
  full screen; Option+click → maximized; hold 700 ms → the menu under the bead, release
  does nothing more; Arrange ▸ Left Half → the left half of the working area; right-click
  → the menu at the pointer; right-click on a background window's bar → Center moved that
  window; with loft-kwin stopped → KWin's menu, and Loft's again once the shell restarted
  it.
- **Tested** nested (§6, plugin on `QT_PLUGIN_PATH`, scratch HOME): two foot windows,
  focus / unfocus, hover glyphs, the window menu, maximize / restore, minimize, close,
  a live theme swap (tokyonight → latte) and metric edits, and apply / revert with the
  user's Breeze and with no key set. Button order: apply / revert with an explicit
  `MS` / `HIAX`, with the keys only in kdedefaults (MacTahoe: back to its Aurorae theme
  and `XIA`), with the user changing the order while Loft ran (theirs kept), and over
  a record written by the previous version (buttons added to it).

### 4.5 Shortcuts and the keyboard layer under Plasma

**Shortcuts** (`cli/loft/kwinkeys.py`, `loft keys kwin render|claim|release`).
`loft-plasma-shell.service` runs `loft-plasma-shortcuts load` after start and
`unload` after stop:

1. **render**: niri/shell-binds.kdl.in (IPC command filled in) plus
   `<state>/overrides/niri.json` (disabled keys dropped, moved and custom
   shortcuts added) → `$XDG_RUNTIME_DIR/loft/plasma-keys/`: `loft-keys.js`,
   `actions/<id>` (each bind's command as a shell script), `names`.
2. **load** `loft-keys.js` into KWin (`Scripting.loadScript … loft-keys`, run). Each
   `registerShortcut("loft-<id>", "Loft: <title>", keys, …)` lands in
   kglobalaccel's `kwin` component.
3. **claim**: kglobalaccel lets two actions share a key, and then the *other*
   one wins (seen: Meta+I opened System Settings instead of the Island). So Loft
   takes its keys off every other action that has them (`setForeignShortcutKeys`),
   recording what they had in `<state>/kwin-shortcuts-taken.json`. With stock
   Plasma that is 15 actions: KWin's Walk Through Windows (Meta+Tab), Close Window
   (Alt+F4), Switch One Desktop ← → ↑ ↓ (Meta+Ctrl+arrows), Switch Window ← →
   (Meta+Alt+←/→), Present Windows (Meta+F10), Activate Window Demanding
   Attention (Meta+Ctrl+A), System Settings (Meta+I), Emoji Selector (Meta+.),
   Spectacle region recording (Meta+Shift+R), and KWin's Window Operations Menu (Alt+F3,
which Loft's window menu takes, §4.4).
   Plasma that is 12 actions: KWin's Walk Through Windows (Meta+Tab), Close Window
   (Alt+F4), Switch One Desktop ↑ ↓ (Meta+Ctrl+↑/↓: ⌃↑ Mission Control, ⌃↓ App
   Exposé), Switch Window ← → (Meta+Alt+←/→), Present Windows (Meta+F10),
   Activate Window Demanding Attention (Meta+Ctrl+A), System Settings (Meta+I),
   Emoji Selector (Meta+.), Spectacle region recording (Meta+Shift+R).
   **KDE's Activities and desktops stay KDE's** (§4.2): Loft binds neither ⌘1…9 /
   ⌘0 (kactivitymanagerd's "Switch to activity") nor ⌃⌘← → (`spaces prev/next`;
   KWin's Switch One Desktop to the Left/Right keeps Meta+Ctrl+←/→, `KDE_OWNED_IPC`),
   and claim never takes a key from the `ActivityManager` component
   (`PROTECTED_COMPONENTS`): if a key of Loft's is one of those, KDE keeps it.
   ⌘⇧1…9 / ⌘⇧0 (Move Window to Space N) **yield**: when another action has that
   key, Loft's gets no key instead of taking it (`YIELD_PREFIXES`; the window menu's
   Move to Space still works). A record from an older Loft that took ActivityManager
   keys is put right at the next load: unload's `release` gives everything back, and
   `claim` also gives back (and drops from the record) any ActivityManager entry it
   finds first (`give_back_protected`).
4. **unload**: unload the script, `unregister` every name in `names`, give the
   recorded keys back (`release`). kglobalshortcutsrc ends up as it was before
   (checked by diffing it in a nested session). If the session ended without a
   stop job, the next start of Loft's shell or of plasmashell (an `ExecStartPre`
   in its drop-in) gives them back.

**Running a command.** KWin scripts can't start processes, so a callback calls
the user's systemd: `StartUnit("loft-plasma-key@<id>:<n>.service")`, a new
instance per press (a running instance would swallow a quick second press). The
template runs `actions/<id>`. systemd over D-Bus was picked over the alternatives:
kglobalaccel `.desktop` components with `X-KDE-Shortcuts` are written into
kglobalshortcutsrc for good and only picked up when kglobalaccel loads them;
`org.kde.krunner`/KLauncher can't run an arbitrary command line (KLauncher is gone
in KF6); `StartTransientUnit` needs `a(sv)` arguments that `callDBus` can't build.

**Key names.** Mod and Super are both Meta (no ISO_Level3_Shift WM key under
KWin; the keyboard layer's WM key sends Meta instead, below), so `Mod+X` and `Super+X` twins become one shortcut. niri keysyms map to
QKeySequence names (`Period` → `.`, `Escape` → `Esc`, `XF86LaunchA` →
`Launch (A)`, …). KWin matches Shift+digit/symbol by the shifted symbol without
Shift: Mod+Shift+5 must be registered as `Meta+%`, Mod+Shift+Period as `Meta+>`
(US layout); letters keep Shift. niri-only actions: `toggle-overview` → KWin's
Overview, `fullscreen-window` → `fullScreen`, the quit guard's fallback → KWin's
Window Close; the recent-windows binds (⌥Tab, ⌘\`) are left to KWin's own.

**Keyboard layer.** `loft-plasma-keys.service` (with `programs.loft.keyboard.enable`
and `plasma.enable`; a Plasma-session unit, so only in Loft sessions) runs
`programs.loft.keyboard.plasmaPackage` (`pkgs.xremap.kde`) on the same
`<state>/xremap/config.json` that `loft keys` renders. `Conflicts=loft-keys.service`
keeps it to one xremap. xremap loads its own KWin script (`xremap`) for the
focused window; the unit unloads it on stop.

**The window-manager key.** niri's Mod is Right Alt (`lv3:ralt_switch` makes it
ISO_Level3_Shift); KWin has no such key and Qt shortcuts take only
Meta/Ctrl/Alt/Shift, so Caps+T would reach KWin as Alt+T. In Plasma `loft keys`
renders the WM key differently (`LOFT_WM_KEY=meta`, set by the Plasma units;
`cli/loft/keys.py`): the `wmKey` groups' hold (Caps Lock / Esc, `dual-role`; Right
Ctrl, `right-ctrl-mod`) is `F24`, an xremap **virtual modifier** that is never
sent, and a generated first keymap entry sends WM key + X as **Meta + X** for
every key (letters, digits, punctuation, arrows, F1–F23, Space, Tab, Enter,
Backspace, Esc, Delete/Insert, Home/End/PgUp/PgDn, Print). It isn't exact, so a
held Shift / Ctrl / Alt stays held (Caps+Shift+← → Meta+Shift+←), and it comes
before every other entry, so the ⌘ groups can't take the key (xremap never
re-reads its own output, so its Super_L isn't ⌘). The `mac-parity` group sends
Meta where niri gets Right Alt (⌃↑ → Meta+Ctrl+Up). Taps stay Escape, ⌘ stays
Cmd, Right ⌘ stays plain Super (or the symbols layer, when on; below). Every `loft keys` write records the key in
`<state>/xremap/wm-key`, so a `loft keys …` from a terminal renders for the
xremap that runs (then `XDG_CURRENT_DESKTOP` with KDE → meta). `loft keys show`
says which. Not covered: WM key + mouse (KWin's Meta+drag) and a WM-key hold
alone (Cleaning Mode's "hold Esc" — the timer still ends it).

**Window keys: Caps + H/J/K/L, F, ⇧F, C, W.** niri's window binds in `niri/base.kdl`
are registered under KWin too (`kwinkeys.WINDOW_BINDS`, checked against base.kdl by
`tests/test_kwinkeys.py`). Each one is a call in the script, a KWin workspace slot or a
few lines of the script's own (`loftFullscreen`, `loftCenter`, `loftPresetWidth`), so
nothing goes through kglobalaccel's own KWin actions:

| Keys (Caps held = Meta) | niri (base.kdl) | KWin |
|---|---|---|
| Caps H / L, Caps ← / → | focus-column-left / right | `slotSwitchWindowLeft/Right` (Switch to Window to the Left/Right) |
| Caps J / K, Caps ↓ / ↑ | focus-window-or-workspace-down / up | `slotSwitchWindowDown/Up` (Switch to Window Below/Above) |
| Caps ⇧ H / L | move-column-left / right | `slotWindowQuickTileLeft/Right` |
| Caps ⇧ J / K | move-window-down / up-or-to-workspace-down / up | `slotWindowQuickTileBottom/Top` |
| Caps F | maximize-column | `slotWindowMaximize` (KWin's maximize toggle) |
| Caps ⇧ F (and shell-binds' Caps ⌃ F) | fullscreen-window | the active window's `fullScreen`, toggled |
| Caps C | center-column | centered in its output's work area, size kept (not for a maximized window) |
| Caps W | switch-preset-column-width | the next of niri's preset widths, below |
| Caps V | toggle-window-floating | **not bound**: every KWin window floats. KDE keeps Meta+V |

**Caps W, preset widths.** The widths are niri's `preset-column-widths`: base.kdl's ⅓ ½ ⅔
(`DEFAULT_PRESETS`, checked against base.kdl by the tests), or the user's from Settings
(`<state>/overrides/niri.json` `layout.preset-column-widths`, a proportion or `{"fixed":
px}`), rendered into the script as `LOFT_PRESETS`. A press gives the window the next preset
wider than it is, as a fraction of its output's work area (`clientArea(MaximizeArea)`, so
the bar and dock are left out), and wraps to the narrowest after the widest. Its height
and vertical place stay. Horizontally: a window flush with the left or right edge of the
work area (quick-tiled there with Caps ⇧ H / L, or sized there by an earlier Caps W)
keeps that edge and grows from it; any other window is centered. Edge-anchoring by
geometry rather than KWin's tile was picked so that repeated presses stay on the same
side (resizing a tiled window takes it out of its tile). A maximized window comes out of
maximize at the narrowest preset; a fullscreen one is left alone. niri's widths leave
out its gaps; KWin has none, so ⅓ is a third of the work area exactly. A press while
the last resize hasn't landed reads the size it asked for, as the bridge does.

**Keys these take from KDE** (`claim`, given back by `release`): Meta+W is KWin's
Overview (Toggle Overview) in stock Plasma. Loft's overview is still Caps O and ⌃↑
(Mission Control), and KDE gets Meta+W back on unload. Stock KWin binds nothing on
Meta+F, Meta+Shift+F or Meta+C (KWin's own Maximize is Meta+PgUp, Fullscreen has no
key), so nothing is taken for them in a stock session. A user's own KDE shortcut on one
of them is taken and given back the same way.

KWin has no columns, so the semantics differ at the edges. Focus is directional and
crosses outputs, and it stops at the last window, where niri's J/K go on to the next
workspace. Move is a quick tile to that half. A second press at an output's edge moves
the window to the next output, which niri's move-column doesn't do. Tiles combine:
⇧K on a right-tiled window gives the top-right quarter, and ⇧J then gives the right
half back. niri has no Mod+⇧+arrows, so KDE keeps Meta+⇧+←/→ (Window to Previous/Next
Screen). `claim` takes Meta+←/→/↑/↓ from KWin's Quick Tile actions, and Meta+L from
ksmserver's Lock Session in a full Plasma session. `release` gives them back. A
Settings → Keyboard Shortcuts change to Mod+H … wins here as well (a disabled Mod+L
leaves Meta+L to KDE).

**⌘H / ⌘M under KWin.** Under niri, ⌘H / ⌘M go out on Right Super (`Super+H`
"Hide App"), and niri tells Super from Mod. KWin doesn't: Super_L, Super_R and the WM
key's Meta are all Meta, so `Super+H` would be Meta+H, which is now focus left. Under
Plasma the parity group's `plasmaRemap` sends ⌘H / ⌘M as **Meta+Ctrl+Alt+H / M**
instead (parity.json `kdeKeys`), and kwinkeys registers Hide App / Minimize on those
keys (`plasma_keys()`). The niri side is unchanged.

**Right ⌘ is the system's Super key.** Left ⌘ (Super_L) is the macOS ⌘ (the `cmd`
groups, ⌘C → Ctrl+C …). Right ⌘ (Super_R) never was in a ⌘→Ctrl group, and the
`right-cmd` group makes that explicit. Right ⌘ reaches the desktop as plain Super:

- **Under Plasma**, Right ⌘ + key = Meta + key: KDE's own Meta shortcuts, and the
  ones Loft registers for Caps. So Right ⌘ H/J/K/L focuses like Caps H/J/K/L, and
  Right ⌘ A opens the Control Center.
- **Right ⌘ L locks the screen.** xremap sends it as ⌃⌘Q (`Super_R-l` →
  `Ctrl-Super_L-q`, exact match), which is Loft's Lock Screen: KWin's Meta+Ctrl+Q,
  niri's Super+Ctrl+Q. Plain Meta+L would be the WM key's focus right.
- **Under niri** the same group applies (Right ⌘ L locks). Otherwise Right ⌘ stays
  niri's Super: it fires niri's `Super+…` binds (the ⌘ twins: Spotlight, ⌘⇧3/4/5,
  ⌘Tab, and Hide App on Right ⌘ H) and is not niri's Mod, which is Caps (Right Alt).
  Making Right ⌘ niri's Mod would need XKB `lv3:rwin_switch` and give up those binds,
  so it is left as it is.
- The symbols layer (`symbols`, off by default) comes before `right-cmd`. When it's on,
  it owns Right ⌘, and Right ⌘ L types its symbol.

**Verified (focus and move)** in a nested KWin 6.8.2 (`loft-dev --compositor kwin
--shell plasma`, private bus): Loft's script rendered from the checkout, loaded, and
`claim` run against the session's kglobalaccel. Real key presses (`loft-input key
super+…`) moved focus between two Konsole windows, checked with `loft-kwin state`:
Meta+H/L/←/→ and Meta+J/K/↑/↓. Meta+⇧+H/L/K/J tiled left, right, top-right and back.
Hide, Minimize and Lock were registered on Meta+Ctrl+Alt+H, Meta+Ctrl+Alt+M and
Meta+Ctrl+Q (the callbacks need the user's systemd, which isn't on that bus). Unload
and `release` gave KWin's Quick Tile keys back, and the desktop keys were never taken.
The xremap side (Right ⌘ L, ⌘H → Meta+Ctrl+Alt+H) is checked only on the rendered
config (`tests/test_keys.py`, `tests/test_parity.py`). xremap-kde never runs against
input devices in tests.

**Verified (F, ⇧F, C, W)** in a nested KWin 6.8.2 (`loft-dev --compositor kwin --shell
loft`, 1600×1000, work area 0,30 1600×894), the branch's script loaded and claimed in the
session, real key presses (`loft-input key super+…`) on a Konsole and a KWrite window,
checked with `loft-kwin state`. Meta+F maximized (0,30 1600×894) and restored
(378,247 910×498); Meta+Shift+F and Meta+Ctrl+F each went fullscreen (0,0 1600×1000) and
back. Meta+C moved 910×498 to 345,228. Meta+W from 910 wide: 1067 at x=267, 533 at
x=534, 800 at x=400, 1067 again. Tiled left (Meta+Shift+H, 0,30 800×894) then Meta+W:
1067, 533, 800, all at x=0, height 894. Tiled right: 1067 at x=533, then 533 at x=1067.
Maximized + Meta+W: 533 centered. Two presses 150 ms apart went two presets on. `claim`
took Meta+W from KWin's Toggle Overview; unload + `release` gave it back
(`Overview=Meta+W,Meta+W,Toggle Overview`), and kglobalshortcutsrc matched its copy
from before the load.

**Verified** in a nested KWin 6.8.2 (private bus, scratch HOME; a stand-in for
systemd's `StartUnit` on the private bus that runs the real `loft-plasma-key`
dispatcher): all 42 shortcuts register with the expected keys; real key presses
(virtual keyboard into the host) open the Control Center (Meta+A), the Capture
bar (Meta+Shift+5), the Island (Meta+I, after claim), the switcher, Spaces,
emoji; unload leaves kglobalshortcutsrc as before. xremap-kde's KWin script
loads and reports `org.kde.dolphin` for a Dolphin window. **Not run:** the
systemd template itself (no user systemd on the private bus), xremap-kde against
input devices (it would grab the real keyboard), and conflicts with plasmashell's own shortcuts (Meta+Q
activities etc.: same mechanism, not present in the scratch session). The quit guard's
hold: §4.13 (KWin does repeat held shortcuts; the
press and release come from kglobalaccel's signals through loft-kwin).

### 4.6 Option-drag tiles, like macOS

On macOS (Sequoia and later), holding **Option** while dragging a window shows the tile
zones and drops the window into one. KWin does the same with **Shift**, and the key is
hard-coded (KWin 6.8.2, `src/window.cpp`):

- `Window::updateInteractiveMoveResize`: while moving, `modifiers & Qt::ShiftModifier`
  shows the outline of the custom tile under the pointer (`quickTileGeometry(Custom)`) and
  turns the screen-edge maximize/tile zones off; without it, the edge zones apply.
- `Window::finishInteractiveMoveResize`: on release, `wasMove && (modifiers &
  Qt::ShiftModifier)` tiles the window (`setQuickTileMode(QuickTileFlag::Custom, anchor)`).
- The modifiers come from the last pointer motion, or from a key **press** during the move
  (`MoveResizeFilter::keyboardKey` in `src/input.cpp`). Releasing the key mid-drag takes
  effect at the next pointer motion. The patch keeps all of that.

**The patches.** `loft-kwin-patched` carries three, all applying to 6.7.5 and 6.8.2. Two
are off until a kwinrc key is set: this one, and
`nix/kwin/client-window-menu-service.patch` ([Windows] `ClientWindowMenuService`: the
window menus apps with their own title bars ask for go to Loft, §4.4). The third,
`nix/kwin/unique-script-ids.patch`, is always on: a KWin script id is never handed out
twice, so a client churning throwaway scripts (kdotool) can't stop Loft's (§4.18).

**The patch** (`nix/kwin/tile-while-moving-modifier.patch`, ~30 lines, upstreamable):
a kcfg entry `[Windows] TileWhileMovingModifier` = `Shift` (default) | `Alt` | `Ctrl` |
`Meta`, read in `Options::syncFromKcfgc()` next to `ElectricBorderTiling` into
`Options::tileWhileMovingModifier()`, and the two `Qt::ShiftModifier` checks use it.
The new member sits at the end of `Options` so plugins built against stock headers keep
the same field offsets. The patch applies to 6.7.5 and 6.8.2. Unset, KWin behaves like
stock. `Workspace::slotReconfigure` re-reads it (`options->updateSettings()`), so
`qdbus org.kde.KWin /KWin reconfigure` applies it live.

**Packages and wiring:**

- `loft-kwin-patched` = `kdePackages.kwin.overrideAttrs` + the patch. Nothing else in
  Plasma depends on it, so only KWin builds (~2000 objects).
- home-manager `programs.loft.plasma.kwinPackage` (default `null` = stock): Loft's drop-in
  for `plasma-kwin_wayland.service` replaces `ExecStart` with that package's
  `kwin_wayland_wrapper --xwayland` (the stock unit's arguments). This applies to every
  Plasma login, plain "Plasma" too. That's safe because the default is Shift.
  `kwin_wayland_wrapper` starts `kwin_wayland` **from `PATH`**, which in the session finds
  NixOS's `/run/wrappers/bin/kwin_wayland`, the **stock** KWin. So the launcher puts a
  directory first (`$XDG_RUNTIME_DIR/loft/kwin-bin`) whose `kwin_wayland` points at the
  patched one.
- **CAP_SYS_NICE.** NixOS runs `kwin_wayland` through a capability wrapper
  (`cap_sys_nice+ep`) so KWin can give its main, DRM commit and libinput threads realtime
  (`SCHED_RR`) priority (`gainRealTime()`, `src/utils/realtime.cpp`) and ask for
  high-priority EGL contexts. Without it KWin still runs (it logs "Failed to gain real
  time thread priority"), but frames and the pointer can stutter when the CPU is busy. Loft's NixOS option `programs.loft.plasma.kwinPackage`
  gives the patched KWin the same capability, through `/run/wrappers/bin/loft-kwin_wayland`,
  and sets the home-manager option for every user. The launcher uses that wrapper when it
  exists, else the package's binary.
- Plugins and effects: the package's `kwin_wayland` (a Qt wrapper) puts its own
  `lib/qt-6/plugins` and `qml` first on `QT_PLUGIN_PATH`/`NIXPKGS_QT6_QML_IMPORT_PATH`. So
  the patched KWin loads its own effects, not the system KWin's (KPluginMetaData keeps the
  first plugin found for each id). System Settings' KCMs stay the system's. They don't know
  the new key, and nothing else needs them to.
- `programs.loft.plasma.tileModifier` (default `"Alt"`, `null` = never touch it):
  `loft-kwin-tile-modifier apply Alt` (loft-plasma-shell's `ExecStartPost`, only when
  `kwinPackage` is set) records the previous value in `<state>/kwin-tile-modifier.prev`,
  sets the key and reconfigures KWin. `revert` (`ExecStopPost`) restores the old value,
  unless the key was changed by hand meanwhile. So in plain Plasma, Shift tiles as usual.

**Alt must be free.** Plasma's window-action modifier (System Settings → Window Management →
Window Actions → Modifier key; kwinrc `[MouseBindings] CommandAllKey`) defaults to **Meta**.
On Cody's desktop it's unset, so Meta, and Alt+click/drag goes to the window as usual:
Option+drag on a **title bar** moves and tiles. If `CommandAllKey` is Alt, Alt+drag
**anywhere** in a window moves it (`CommandAll1=Move`) and, with Alt as the tile modifier,
tiles it too. Nothing breaks, but apps no longer see Alt+click.
Loft's keyboard layer (xremap) doesn't remap Left Alt. Holding Caps Lock / Esc or Right
Ctrl produces Right Alt, so those keys tile too.

**A wart of Alt in particular:** during a move, KWin's `MoveResizeFilter` swallows every
key event, releases included. If you let go of Alt **before** the mouse button, the app
under the drag never sees the release. Qt apps (e.g. KWrite) then keep showing their
underlined menu mnemonics until Alt is pressed and released again (seen in the nested
test). Stock KWin does this with Shift too; Shift just has nothing to show. Releasing the
button first and then Alt, as on macOS, leaves nothing behind.

Testing: `LOFT_DEV_KWIN=Testing: `LOFT_DEV_KWIN=$(nix build .#loft-kwin-patched --print-out-paths) loft-dev
--session NAME --compositor kwin --shell plasma`, then set the key in the session's
scratch kwinrc and reconfigure (TESTING.md).

### 4.7 Screenshots through ScreenShot2

**Done.** KWin has no wlr-screencopy, so `grim` can't capture and niri's
`screenshot-window` doesn't exist. `loft-kwin shot` (crates/loft-kwin/src/shot.rs) calls
KWin's `org.kde.KWin.ScreenShot2` and writes a PNG:

```sh
loft-kwin shot screen DP-2 out.png [--pointer]    # one output, native resolution
loft-kwin shot window '{uuid}' out.png            # a window (its kwin_uuid), title bar included
loft-kwin shot area X Y W H out.png               # global logical rect, native resolution
loft-kwin shot workspace out.png                  # every output
```

KWin replies with the metadata (width, height, stride, QImage format; 6.8 hands back
RGBX8888) and writes the raw pixels into a pipe we pass. 6.8.2 accepted the calls from an
ordinary session process: no `X-KDE-DBUS-Restricted-Interfaces` desktop entry was
needed (checked on THEBATTLESHIP and in a nested session).

Under the KWin backend, Capture.qml's screen shots and the frozen frames for area
selection run `KWin.screenshotArgv()` instead of grim, and `Compositor.screenshotWindow`
(`capabilities.windowScreenshot`) runs `shot window`, copies the PNG and emits
`screenshotTaken`, like niri. `--max PX` downscales so the longer side is at most PX.
Window thumbnails are §4.8, recording §4.10.

### 4.8 Window thumbnails through ScreenShot2

**Done** (step 11). Under niri-loft each dock-preview card and switcher cell is a live
`ScreencopyView` of its window. KWin has no toplevel capture protocol, so under KWin they
are **stills**:

```sh
loft-kwin thumbs DIR MAX_PX UUID…   # one connection, a PNG per window: DIR/<uuid>.png
# one line per window on stdout:
# {"window":"{uuid}","path":"…","width":440,"height":246,"ms":16}  or  {"window":…,"error":…}
```

- `services/KWinThumbs.qml` runs it. Stills live in
  `$XDG_RUNTIME_DIR/loft-kwin-thumbs/$WAYLAND_DISPLAY/`, at most 440 px on the longer
  side (the cards are 196×124, the switcher cells at most 220 wide; ×2 for HiDPI). The
  first batch of a shell run clears out the last run's (a restarted loft-kwin numbers
  windows afresh). A window's still is deleted when the window closes.
- **When:** no polling. `components/WindowThumb.qml` asks for a still when it becomes active
  (the dock preview opening, the switcher's first press), then every 2 s while it stays
  open. Cards that open together share one batch, and a still younger than 1 s is reused.
  Also, once a window has been focused for 1.5 s, it gets a still if its last is older
  than 10 s, so the switcher usually opens with pictures already there.
- **Capabilities:** `windowThumbnails` (KWin true, niri false). `WindowCapture.canWindows`
  is true under KWin through `KWinThumbs.enabled`, which turns on the switcher's
  thumbnail cells and the dock preview's cards, and `WindowThumbs` (cropping display
  stills) stays off. Under niri nothing changes: `WindowThumb` uses its ScreencopyView,
  and the toplevel map only looks at `canToplevels`.
- **What KWin 6.8.2 captures:** windows that are covered, on another desktop, and
  **minimized** too (their last frame; checked in a nested session). A capture that fails
  keeps the window's last still, and with none the card shows the app icon.
- **Cost** (nested session, release build): a ~800×440 window takes 4–8 ms per window
  (capture, convert, downscale, PNG), and the whole `thumbs` process for two windows
  12–16 ms. A maximized 1600×894 window takes 16–28 ms (21–35 ms for the process); the
  full-size `shot window` of it takes 18–24 ms. Well inside the switcher's 120 ms show
  delay.

### 4.9 Window commands, `loft mcp` and the overview under KWin

**Done.** Spotlight's window commands, `loft mcp`'s window tools and `Compositor.overviewOpen`
work under KWin, through one route: the shell's `loft-kwin` daemon.

- **`loft-kwin send JSON`** hands one command to the running daemon over its D-Bus method
  `dev.loft.KWinBridge.Command` (on `/Bridge`), the same as a line on its stdin. The
  daemon runs it over KWin's D-Bus API (`toggleOverview`, `setDesktopName`, `switchLayout`)
  or queues it for `bridge.js`. **Without a `window`, the script acts on the active
  window.** New script commands: `moveToNextOutput` (the next screen in KWin's order,
  wrapping, like niri's `move-window-to-monitor-next`), `moveToDesktopRelative {delta,
  focus}` (no wrapping; follows the window unless `focus: false`), `focusOutput {output}`
  (activates the topmost window there).
- **`loft-kwin state`** prints the daemon's last state (`dev.loft.KWinBridge.State`): the
  same niri-shaped JSON the shell gets, with `kwin_uuid` on windows and `kwin_desktop`
  on workspaces.
- loft-kwin is on the PATH of the shell and Spotlight (`loft-launcher`), and in
  `home.packages` with `programs.loft.plasma.enable` (for `loft mcp` and terminals).

**Spotlight** (`launcher/elephant-commands/builtin.go`). Each command's shell line picks
niri or KWin when it runs (`$NIRI_SOCKET`, like Log Out):

| Command | niri | KWin |
|---|---|---|
| Maximize Window | `maximize-column` | `toggleMaximize` (KWin's maximize) |
| Fullscreen Window | `fullscreen-window` | `toggleFullscreen` |
| Center Window | `center-column` | `center` (in the output's work area) |
| Move Window to Next Display | `move-window-to-monitor-next` | `moveToNextOutput` |
| Move Window to Next Workspace | `move-window-to-workspace-down` | `moveToDesktopRelative` +1, follows |
| Close Window | `close-window` | `closeWindow` |
| Overview | `toggle-overview` | `toggleOverview` (kglobalaccel `kwin/Overview`) |
| Keyboard Shortcuts | `show-hotkey-overlay` | Loft's Settings → Keyboard & Mouse → Keyboard Shortcuts (KDE has no overlay) |
| Turn Off Displays | `power-off-monitors` | `kscreen-doctor --dpms off` (any input wakes them) |
| Toggle Floating, Expand to Available Width, Cycle Window Width | niri | **hidden** (no tiling or columns; the menus hide Float the same way) |

**`loft mcp`** (`cli/loft/mcptools.py`) picks the backend as `Compositor.qml` does
(`$LOFT_COMPOSITOR`, else niri with `$NIRI_SOCKET`, else KWin when `XDG_CURRENT_DESKTOP` has
KDE). Under KWin: windows, workspaces and outputs come from `loft-kwin state` (outputs carry
no modes or scale); focus / close / move to workspace or display / fullscreen / maximize /
center / focus workspace / focus output / overview go through `loft-kwin send` with the
window's `kwin_uuid`; `toggle_overview open|close` checks `overview_open` first (KWin's
Overview only toggles); `launch` and `spotlight_open` start the program themselves
(detached, the server's environment); screenshots are `loft-kwin shot screen|window`
(a window shot includes its title bar, on screen or not). `set_window_floating`,
`maximize_column` and `set_column_width` answer with an error saying they're niri-only.

**Overview state.** KWin has no signal for an effect starting or stopping, and its D-Bus
`activeEffects` property has no change signal either. So `bridge.js` runs a 100 ms
`QTimer` that calls `workspace.isEffectActive()` (in-process, a lookup in the loaded
effects) for `overview` (Overview and Grid View, one effect in 6.8) and `windowview`
(Present Windows), and pushes a snapshot only when that changes. loft-kwin passes it on
as `overview_open`, `KWin.qml` sets `overviewOpen` from it, so the wallpapers, fullscreen
chrome, previews and the dock's "Show All Windows" react as under niri. However the
overview opens (shortcut, hot corner, gesture, Loft), the shell sees it within ~0.1 s.

**Tested** in a nested KWin 6.8.2 (§6, two outputs, two desktops, kwrite): every command
through `loft-kwin send` and Spotlight's exact shell lines (with `NIRI_SOCKET` unset), each
checked in `loft-kwin state` (maximized / fullscreen flags, geometry, output, desktop,
the window gone after close); overview via Loft, kglobalaccel `Overview`, `Grid View` and
`Expose`, each showing up in the shell's `Compositor.overviewOpen` (`wswallpapers stats`)
and going back to false; the MCP tools from `mcptools` against the session (a real window
screenshot); `kscreen-doctor --dpms off` sends `org_kde_kwin_dpms.set(Off)` for both
outputs, KWin's `kscreen` effect stayed active (and Overview refused to open) until pointer
input woke them.

Found while testing, not fixed here: `Displays.fullscreenOn` skips floating windows, and
under KWin every window floats, so FullscreenChrome never sees a fullscreen window there.

### 4.10 Screen recording through zkde_screencast

**Done.** wf-recorder needs wlr-screencopy, which KWin doesn't have. `loft-kwin record`
(crates/loft-kwin/src/record.rs) asks KWin for a screencast and records it:

```sh
loft-kwin record screen WL-0 out.mp4                       # one output, native resolution
loft-kwin record area X Y W H out.mp4 [--scale S]          # global logical rect, S px per logical px
loft-kwin record window '{uuid}' out.mp4                   # one window (its kwin_uuid), title bar included
#   [--no-pointer] [--audio @DEFAULT_MONITOR@|default|SOURCE] [--fps 30]
# SIGINT/SIGTERM: finish the file and exit 0. SIGTSTP / SIGCONT: pause / resume.
```

How: loft-kwin binds KWin's `zkde_screencast_unstable_v1` (the protocol KWin's own
portal and Spectacle use; bindings from the `wayland-protocols-plasma` crate) and calls
`stream_output`, `stream_region` (v3) or `stream_window` with the pointer embedded. KWin
answers `created(node)` with a PipeWire node, and loft-kwin runs

```
gst-launch-1.0 -e pipewiresrc path=NODE keepalive-time=500 always-copy=true ! videorate ! 30 fps
  ! ENCODER (even width/height) ! h264parse ! mp4mux ! filesink        [+ pulsesrc ! avenc_aac ! mux.]

ENCODER, the first that works (--encoder auto|nvenc|va|x264, or LOFT_RECORD_ENCODER):
  nvenc  videoscale ! nvh264enc preset=p4 tune=high-quality rc-mode=vbr const-quality=25   (NVIDIA; takes BGRx, converts on the GPU)
  va     vapostproc ! NV12 VAMemory ! vah264enc rate-control=cqp qpi=24 qpp=26              (AMD / Intel)
  x264   videoconvert ! videoscale ! I420 ! x264enc veryfast pass=qual quantizer=23        (CPU, always there)
```

so the file is what wf-recorder makes under niri: H.264 (High, yuv420p) in MP4 with an
optional AAC track, in the same `Recording_<date>.mp4` under `recordingDir`. The frame rate is
constant (30), and `keepalive-time` repeats the last frame while KWin sends none (it only sends
frames on damage). A region is cropped by KWin (`stream_region`), so area recordings need no crop
in the encoder and can span outputs. An odd width or height loses one pixel (4:2:0).

Why this route:

| | dialog | extra daemon | area | window | verdict |
|---|---|---|---|---|---|
| `zkde_screencast` + gst-launch | none | none (gst-launch only while recording) | `stream_region`, by KWin | `stream_window` | **chosen** |
| xdg-desktop-portal ScreenCast | always the first time; a restore token (`persist_mode` 2) can skip it later, but an invalid token (e.g. the output changed) brings the picker back | the portal (D-Bus activated) | crop in the encoder | via the picker | no: never reliably non-interactive |
| `spectacle --record` | its own UI to pick the region and to stop | Spectacle | its own region picker | yes | no: its UI, its settings decide format and folder |

KWin 6.8.2 let loft-kwin, an ordinary session client, bind `zkde_screencast` with no
`X-KDE-Wayland-Interfaces` desktop entry (nested session), like ScreenShot2 (§4.7); its
interface filter looks aimed at sandboxed clients (`wp_security_context_v1`). Should a later KWin restrict it again, loft-kwin needs a .desktop file whose `Exec`
is its binary, with `X-KDE-Wayland-Interfaces=zkde_screencast_unstable_v1`.

The Nix package wraps `loft-kwin` with exactly the GStreamer plugins this uses (`gstreamer`,
`-base`, `-good`, `-ugly` for x264enc, `-bad` for h264parse, nvcodec and va, `gst-libav` for
avenc_aac, and PipeWire's pipewiresrc) on `GST_PLUGIN_SYSTEM_PATH_1_0`. PipeWire itself is
the session's; the GPU drivers (libnvidia-encode, the VA driver) are the system's
(`/run/opengl-driver`).

**Hardware encoding.** GPU encoders register in GStreamer even when they can't open (no
driver, no encode entrypoint), so auto runs a 3-frame test encode per candidate (NVENC,
then VA-API; x264 isn't probed) and keeps the pick in `$XDG_RUNTIME_DIR/loft-kwin-encoder`
with the plugin path, so a new loft-kwin or driver set probes again. The probe runs while
KWin sets the stream up. If the chosen GPU encoder still fails before anything was written,
the recording restarts with x264 and the pick becomes x264. VA-API picks the first render
node with an encoder (here the AMD iGPU, renderD129); NVENC the first CUDA device.

**The first run after an update.** GStreamer scans every plugin into its registry
(`$XDG_CACHE_HOME/gstreamer-1.0`) the first time a new plugin set is used: 9.5 s here
(nvcodec and va probe their devices, lv2 reads `~/.lv2`). A recording started then used to
lose its first seconds, and one stopped in that window left no file at all. The daemon now
warms up 20 s after it starts (`record::warm_up`: a one-buffer pipeline, then auto's probe).

**Stopping early.** gst-launch killed by SIGINT before its pipeline plays writes nothing,
and one stopped right after PLAYING wrote 0.1 s. loft-kwin now reads gst-launch's
"Setting pipeline to PLAYING" and holds a stop until the pipeline has played 1 s
(`MIN_RUN`; at most 15 s for it to start), so the file always has frames.

The shell: `Recorder.start` runs `loft-kwin record …` instead of wf-recorder when
`Compositor.backend` is `kwin` (Recorder.qml `kwinArgs`): the focused output, an area from
the frozen-frame overlay (with the screen's `devicePixelRatio` as `--scale`), or a window.
Audio modes map the same way (system → `--audio @DEFAULT_MONITOR@`, mic → `--audio
default`, both → system in the file plus the separate mic track muxed afterwards, as under
niri). The island's live activity, the notification, the thumbnail and the recording
editor are unchanged.

**Pause is a cut.** Both recorders used to pause by being stopped (SIGSTOP; loft-kwin's
SIGTSTP still does that, for scripts), and both kept the paused span as one held frame:
wf-recorder 0.6 under niri writes variable-rate timestamps, so its file had a 4.0 s gap
(4.59 s → 8.58 s) for a 4 s pause, and gst-launch's videorate filled the same span with
copies. Now `Recorder.qml` ends the part on pause (SIGINT, so it's finished) and starts a
new recorder into the next part on resume (`Recording_….part2.mp4`, …, with
`.mic2.wav` … for "both"); stop runs `loft capture join OUT PART[:MIC]…`
(`cli/loft/capture.py`), which muxes each part's mic in (per part, so the mic stays in
step with its video) and concatenates the parts with ffmpeg's concat demuxer (stream copy;
re-encoded to the first part's size when a part's frame size differs, e.g. a window that
was resized). One part is just renamed. A part that wrote nothing is skipped. Same under
niri and KWin.
`capabilities.windowRecording` (KWin only) adds **Record Focused Window** to the capture
selector and IPC `capture recordWindow`; niri's recorder can't record one window, so niri
doesn't show it.

Tested in a nested session (`loft-dev --compositor kwin`, 1280×800, a foot window drawing a
moving block and a frame counter): screen 5.000 s, 1280×800, 150 frames at 30 fps; area
501×301 → 500×300; area at `--scale 2` → 600×400; window 1268×502 with its title bar,
following the window's content; system audio (null sink monitor) and mic (a silent virtual
source) as a stereo AAC track. Through the shell: `capture recordScreen`, pause, resume,
`recorder stop` → the file in `~/Videos/Recordings`, the "Recording saved" notification and
the thumbnail; `capture recordArea` + a drag on the overlay → `record area 200 150 501 301
… --scale 1`; `capture recordWindow` → `record window {uuid}`. Frames extracted with ffmpeg
showed the counter advancing and the block moving.

Measured in the nested session (1920×1080 on the NVIDIA node, 10 s, CPU = loft-kwin +
gst-launch user + sys over the run, 100 % = one core; KWin's own share is the same for all):

| content | encoder | CPU | file | length |
|---|---|---|---|---|
| a terminal scrolling one line every 0.2 s | x264 | 61 % | 1.2 MB | 10.8 s (falls behind, 2.7 s to finish) |
| | VA-API (AMD iGPU) | 13 % | 1.6 MB | 9.5 s |
| | NVENC | 15 % | 2.4 MB | 10.3 s |
| full-screen random text, redrawn at 30 fps | x264 | 87 % | 1.8 MB | 11.3 s (smeared, unreadable) |
| | VA-API | 25 % | 15.5 MB | 9.2 s |
| | NVENC | 24 % | 18.1 MB | 10.3 s |

(Lengths under 10 s are the start-up; x264's over 10 s is its backlog.) Auto picked NVENC
here. Early stops (the new build): stop 0.1 / 0.3 / 0.6 s after starting, and 0.2 s with
an empty registry (`GST_REGISTRY` pointed at a new file) → 1.07–1.13 s files, 32–34 frames;
the previous build wrote no file for any of them (gst-launch died on SIGINT). Through the
shell: start, 3 s, pause 3 s, resume 3 s, pause, stop while paused → 5.7 s with a clock
jumping 55.75 → 59.30 (paused 55.71–58.84), each part starting ~0.4 s after the call;
the same under niri with wf-recorder → 51.88 → 55.21 (paused 52.12–55.15).

Not done: recording with KWin's cursor as metadata instead of embedded; a resume takes
~0.4 s to show frames (a new screencast and pipeline), and a part is at least 1 s long, so
pausing within a second of resuming records up to that second.

### 4.11 Settings → Displays through KScreen

**Done.** Under niri the Displays page reads `loft-niri outputs` and writes Loft's
overrides through `loft-niri apply`. Under KWin it goes to KScreen instead, and Loft
records nothing: KScreen applies a change and saves it in its own config, as System
Settings does.

```
DisplaysPage / IdentifyOverlay ──▶ Displays.outputs / setOutputs / identify
                                     ├─ niri: NiriSettings (loft-niri)
                                     └─ KWin: KScreen.qml ──▶ loft-kwin displays [set JSON]
                                                                 └─ kscreen-doctor -j, -o / output.<name>.…
```

- **Reading.** `loft-kwin displays` (crates/loft-kwin/src/displays.rs) prints loft-niri's
  `outputs` records (name, modes with `WxH@R` strings, mode, scale, transform, logical
  rect, enabled, VRR), so the page renders the same either way. In KScreen 6.8.2 the
  `-j` JSON has the modes, current mode, position, scale, rotation and priority, but
  not `enabled`, VRR or HDR, so those come from `-o`'s text (`enabled` / `disabled` /
  `disable unsupported`, `Vrr: Never|Automatic|Always|incapable`, `HDR: …`, ANSI
  stripped). Extra fields: `primary` (priority 1), `can_disable`, `vrr_policy`,
  `hdr_supported`, `hdr_enabled`.
- **Identities.** KScreen's output has no make/model/serial. `KScreen.qml` takes the
  "Make Model Serial" the bridge already builds from KWin's screens (`state::identity`),
  and keeps it for outputs that are off (they drop out of `workspace.screens`).
  Outputs with no EDID (KWin's nested `WL-0`…) are their connector, as on niri.
- **Writing.** `loft-kwin displays set '{"WL-1": {"scale": 1.5, "position": {"x": 0,
  "y": 0}}}'` turns the page's staged changes into one atomic kscreen-doctor call:
  `mode` → the KScreen mode id of that size with the nearest refresh, `scale`,
  `position.x,y`, `transform` → `rotation.none|left|inverted|right|flipped…`
  (wl_output 90 = KScreen left), `off` → `disable`/`enable` (enable first),
  `vrr` → `vrrpolicy.automatic|never` (or a policy name), `hdr` → `hdr.enable|disable`,
  `primary` → `primary`. Unknown outputs or fields are errors, not skipped. The page's
  15 s Keep / Revert works as on niri: Revert applies the previous values again
  (and gives the primary back to the display that had it); Keep has nothing to record.
- **Refresh.** 6.8's kscreen-doctor runs KScreen's backend in-process, so there's no
  `org.kde.KScreen` service to watch. The bridge pushes a snapshot when a screen's
  `geometryChanged` / `scaleChanged` fires, `KWin.qml` emits `displayLayoutChanged`
  when a screen's name, geometry or scale changed, and `KScreen.qml` re-reads on that,
  on `outputsChanged`, on Quickshell's screens, after each apply and when the page
  opens. No polling. A VRR or HDR change made in System Settings shows the next
  time the page opens.
- **Hidden under KWin** (`Displays.outputCaps`): Reset and "changed here" (no Loft
  overrides). The "Use this display" switch is off for outputs KScreen can't disable.
  **Shown only under KWin**: Main display (KDE) when two or more are on, HDR when
  the display has it.
- Brightness (Control Center, brightness keys) never used niri: brightnessctl and
  ddcutil work the same under KWin.
- `loft-kwin`'s Nix wrapper appends libkscreen's `bin` to PATH, so the system's
  kscreen-doctor (matching the running KWin) wins when there is one.

Tested in a nested session (`--output-count 2`, outputs `WL-0`/`WL-1`), checked each
time with the session's `kscreen-doctor -j`: the page lists both; dragging WL-1 from
below WL-0 to its right and Apply moved it to `1280,0`; a position changed with
kscreen-doctor showed on the open page by itself; rotation 90° + Main display (KDE)
applied together, Keep kept them, and the 15 s timeout of a later 180° + primary
change put the rotation and the old primary back; Identify shows on both outputs.
**Scale can't be tested nested**: KWin's nested outputs follow the host's scale
(`loft-dev --kwin-scale`), so `output.WL-0.scale.1.5` succeeds and changes nothing.
Nested outputs also have one mode, no VRR/HDR and can't be disabled ("Always on"), so
mode, scale, VRR, HDR and on/off are covered by the unit tests (the kscreen-doctor
arguments) only. Needs a check on real hardware.

The arrangement drag also got `preventStealing`: the settings page's Flickable used to
take the drag over (the page scrolled and the tile stayed half-moved), on niri too.

### 4.12 Settings → Keyboard & Mouse through kxkbrc and KWin's InputDevice

**Done.** Under niri the page writes `input.keyboard` / `input.mouse` / `input.touchpad`
overrides through `loft-niri apply`. Under KWin the same controls write KDE's own
settings, as System Settings does, and Loft records nothing:

```
InputPage ──▶ KdeInput.qml ─┬─ key repeat: kwriteconfig6 --notify kcminputrc [Keyboard]
                            └─ loft-kwin input [set JSON]   (crates/loft-kwin/src/input.rs)
                                 ├─ keyboard: kxkbrc [Layout] + KConfig ConfigChanged on /kxkbrc
                                 └─ mouse / touchpad: org.kde.KWin /org/kde/KWin/InputDevice/<sysName>
                                      Properties.Set (live) + kcminputrc [Libinput][vendor][product][name]
```

- **Layouts.** `{"keyboard": {"layout": "us,de", "variant": ",nodeadkeys", "options":
  "caps:escape"}}` writes `LayoutList`, `VariantList` (padded to one entry per layout),
  `Use` (false for an empty layout = the system default), `Options` and
  `ResetOldOptions=true` (niri's options are the whole list, so they replace the
  system's). KWin's `KeyboardLayout` watches kxkbrc with a `KConfigWatcher`
  (kwin 6.8.2 `keyboard_layout.cpp`), so after the writes loft-kwin emits KConfig's
  `org.kde.kconfig.notify.ConfigChanged` on `/kxkbrc` once, with every key, and KWin
  rebuilds the keymap from a consistent file. Layout names are checked as XKB names
  before anything is written. The bar's layout indicator follows through
  `org.kde.keyboard` `layoutListChanged`, as before.
- **Mouse and trackpad.** KWin exports each libinput device at
  `/org/kde/KWin/InputDevice/<sysName>` (`org.kde.KWin.InputDevice`; the list is
  `devicesSysNames` on `org.kde.KWin.InputDeviceManager`). A device is a trackpad when
  `touchpad`, a mouse when `pointer` and not touch / tablet. Loft's niri keys map to:

  | niri key | KWin property (supported when) | kcminputrc key |
  |---|---|---|
  | `accel-speed` | `pointerAcceleration` (`supportsPointerAcceleration`) | `PointerAcceleration` ("%.3f") |
  | `accel-profile` | `pointerAccelerationProfileFlat` / `…Adaptive` = true (both `supports…`) | `PointerAccelerationProfile` (1 flat, 2 adaptive) |
  | `natural-scroll` | `naturalScroll` (`supportsNaturalScroll`) | `NaturalScroll` |
  | `scroll-factor` | `scrollFactor` (the property exists) | `ScrollFactor` |
  | `left-handed` | `leftHanded` (`supportsLeftHanded`) | `LeftHanded` |
  | `middle-emulation` (mouse) | `middleEmulation` (`supportsMiddleEmulation`) | `MiddleButtonEmulation` |
  | `tap`, `drag` (trackpad) | `tapToClick`, `tapAndDrag` (`tapFingerCount` > 0) | `TapToClick`, `TapAndDrag` |
  | `dwt` (trackpad) | `disableWhileTyping` (`supportsDisableWhileTyping`) | `DisableWhileTyping` |

  Like niri's sections, one change goes to **every** device of that kind that supports
  it. Setting the property applies it at once, and KWin itself writes it to kcminputrc
  (`Device::writeEntry` in `backends/libinput/device.cpp`); loft-kwin writes the same key
  to the same group (`[Libinput][vendor][product][name]`, as `Connection::applyDeviceConfig`
  builds it) so it survives login either way. The page shows the first device's values
  (niri has one value per section, KDE one per device) and only the rows some device
  supports; the Mouse or Trackpad card is hidden when there's no such device. Scrolling
  speed, left-handed, middle-click emulation and tap and drag are rows only KDE's page has.
  Reset and "changed here" are hidden (no Loft overrides).
- `loft-kwin input` prints `{keyboard: {layout, variant, options}, libinput, mouse,
  touchpad, devices}`; `mouse` / `touchpad` are `{devices, supported, values}`. Bad
  sections, keys or values are errors before anything is written. Its Nix wrapper adds
  kconfig's `bin` after the system's PATH for kreadconfig6 / kwriteconfig6.
- **Not done:** a device plugged in later keeps its own KDE settings (KDE's behaviour)
  until the next change on the page. KDE's `[Libinput][Defaults][Pointer|Touchpad]`
  would cover future devices, but it also changes what System Settings' Defaults
  means, so Loft leaves it alone. KDE's scroll method, click method, button mapping
  and tablet settings stay in System Settings.

Tested in a nested session: `input set` with `us,de` / `,nodeadkeys` / `caps:escape`
turned KWin's `org.kde.keyboard getLayoutsList` from `us` into `us` + "German (no dead
keys)" at once, and an empty layout put it back to `us`; a control write of
`LayoutList=us,fr` with plain `kwriteconfig6` (no notification) changed nothing until
`input set` sent it. **The device half can't be tested nested**: KWin creates its libinput
connection only with the DRM backend, so a nested KWin has no `/org/kde/KWin/InputDevice`
(`input` reports `libinput: false`, and the page shows a "no mouse or trackpad" row and
no cards). It's covered by unit tests (classification, support, the value mapping, the
kcminputrc entries) and a D-Bus test against a fake `InputDeviceManager` + mouse over a
socket pair (`devices_over_dbus`: listing, `GetAll`, `Properties.Set`). Needs a check on
real hardware.

### 4.13 Held shortcuts: press, repeat and release

One Loft shortcut is about holding a key: **⌘Q** (the quit guard, hold ~1 s to quit a
protected app, `src/everyday/QuitGuard.qml`). On niri it counts niri's bind repeats.
(The Radial Menu, ⌃⌘Space, was the other one; it has been removed. The measurements below
included it.)

**What KWin delivers** (KWin 6.8.2, kglobalaccel 6.x, measured in a nested session with
real key presses held for set times; `dbus-monitor` on the session bus, and a stand-in for
systemd's `StartUnit` logging every unit the KWin script starts):

| | ⌘Q (`loft-quit`, Meta+Q) | ⌃⌘Space (`loft-radial-hold`) |
|---|---|---|
| press | `globalShortcutPressed` at once, and the script's callback | same |
| held | after the repeat delay (600 ms), `globalShortcutRepeated` every 40 ms (25/s), **and the callback again each time** | same |
| release | `globalShortcutReleased` when the first key of the chord goes up (Q, or Meta) | same: Space, ⌃ or ⌘, whichever first |

So kglobalaccel does repeat, unlike what §4.5 assumed, but a KWin script can't tell a
repeat from a press (its callback is the QAction's `triggered`) and never sees the release.
Before this change a 2.5 s ⌘Q hold started 48 `loft-plasma-key@quit` units (it did quit, the
repeats feeding the guard), and a 2 s ⌃⌘Space hold sent 38 `radial hold` calls, each one
toggling the wheel: it never stayed open. The signals on `/component/kwin`
(`org.kde.kglobalaccel.Component`) carry the action name and do say which is which.

**The mechanism** (one, for any Loft shortcut):

1. `loft-kwin` subscribes to `globalShortcutPressed` / `Repeated` / `Released` on
   kglobalaccel's `kwin` component (`crates/loft-kwin/src/keys.rs`) and prints
   `{"Shortcut": {"name": "loft-quit", "state": "pressed"|"repeated"|"released"}}` for every
   `loft-*` action. `KWin.qml` turns that into `Compositor.shortcutKey(id, state)` (id =
   the action id without `loft-` and a `-N` twin suffix: `quit` for Meta+Q and Alt+F4) and keeps when each id was last pressed and whether it is down.
   `capabilities.shortcutKeys` is true on KWin, false on niri.
2. The KWin script keeps niri's bind properties (`cli/loft/kwinkeys.py`): a `repeat=false`
   bind drops triggers within 250 ms of the previous one (a repeat; the first repeat, one
   repeat delay after the press, still gets through), a `cooldown-ms` bind runs at most once
   per cooldown. Moved/custom binds keep their `props`. A held ⌘Q now starts ~6 units a
   second instead of 25.
3. The shortcut's own command still runs (it is the fallback when the shell is gone: the
   quit bind then closes the window through KWin), arriving 50+ ms later through systemd and
   `quickshell ipc`. `Compositor.shortcutRecent(id, 1500)` (pressed in the last 1.5 s, or
   still down) tells the shell it is the same keypress, and `quit key`/`keyAt` drop
   it.
4. **Quit guard**: `QuitGuard.shortcut(state)`. pressed = the bind's press (protected app:
   the pill; other apps: close the window once); repeated = keeps a hold going, never a
   second close; released before the hold completes = cancel at once (instead of after
   0.8 s without repeats). Between the press and the first repeat the key is known to be
   down, so a long repeat delay doesn't cancel the hold. It quits once the hold has lasted
   `holdMs` with repeats arriving, or with the key down and no repeats (key repeat off in
   KDE).

**Verified** in a nested KWin 6.8.2 (`loft-dev --compositor kwin`, Loft's shortcuts
rendered and loaded as `loft-plasma-shortcuts load` does, a stand-in for systemd's
`StartUnit` on the private bus running the real action scripts, quit protection on for
every app, `loft-input` holding keys for set times):

- tap ⌘Q (120 ms) on KWrite: the pill, `cancelled` within ~125 ms of the release, KWrite
  stays; the duplicate `quit keyAt` was dropped.
- hold 700 ms (past the repeat delay, short of 1 s): cancelled on release, KWrite stays.
- hold 1.5 s: `quitting`, KWrite quits.
- with the stand-in told **not** to run the commands (only KWin's signals through
  loft-kwin): tap → pill, cancelled; 1.5 s hold → KWrite quits.

**Not run / open**: real keyboards through xremap-kde (it would grab the real devices; xremap
sends ⌘Q as Meta+Q or Alt+F4 presses, both `loft-quit*`, so the same signals apply);
plasmashell's shortcuts.
### 4.14 One Qt style for every app (global mode)

**Off by default.** `programs.loft.qt.global = true` (needs `programs.loft.qt.enable`,
which installs Kvantum), or **Settings → Appearance → Theme all Qt apps**, which
wins once used (`loft qt global on|off`, kept in `<state>/qt-global`). Without it,
Loft themes only the apps `programs.loft.qt.apps` names (Dolphin, `cli/loft/qtapps.py`).

With it, while Loft is the shell, every Qt / KDE app (KWin's own menus and dialogs,
kdialog, file dialogs, plasma's leftovers, plain Qt apps under Plasma's platform
theme) gets Loft's Kvantum theme and KDE color scheme, both rendered from the current
Loft theme by the `qt` unit (`cli/loft/qtglobal.py`):

| File | Key | Value |
|---|---|---|
| `~/.config/kdeglobals` | `[KDE] widgetStyle` | `kvantum`, or `kvantum-dark` when the scheme's window background is dark |
| | `[General] ColorScheme` | `Loft` |
| | `[General] ColorSchemeHash` | sha1 of `Loft.colors` (as System Settings writes it) |
| | every key of `[Colors:Window]`, `[Colors:View]`, `[Colors:Button]`, `[Colors:Selection]`, `[Colors:Tooltip]`, `[Colors:Complementary]`, `[Colors:Header]` (and `[Colors:Header][Inactive]` when the scheme has it), `[ColorEffects:Disabled]`, `[ColorEffects:Inactive]`, `[WM]` | the rendered `Loft.colors`' values, copied the way `plasma-apply-colorscheme` copies a scheme |
| `~/.config/Kvantum/kvantum.kvconfig` | `[General] theme` | `Loft` |

plus the links `qt sync` makes anyway (`~/.config/Kvantum/Loft/`, `~/.local/share/color-schemes/Loft.colors`
→ `<state>/current/…`). Nothing else: fonts, icons, `[KDE] contrast`, `AccentColor`, per-app
rc files and Kvantum's `[Applications]` stay as they are.

**Lifecycle.** `loft qt global start` (`ExecStartPre` of KWin's drop-in on a Loft login,
`ExecStartPost` of `loft-plasma-shell`, and of `loft-shell` under niri) applies when the
switch is on; `loft qt global stop`
(`ExecStopPost` of both, and `ExecStartPre` of plasmashell's drop-in and of KWin's on a
plain "Plasma" login, for a session that ended without a stop job) puts everything back. `loft-plasma use plasma` stops Loft's
unit, so the stop job reverts. The switch applies / reverts at once while the shell
runs (`$XDG_RUNTIME_DIR/loft/qt-global-session` marks that). A theme change re-applies
through the `qt` hook while applied.

**Record and revert** (`<state>/qt-global.prev`, JSON): per key the user's own value
(`null` = not in the user's file; KConfig's cascade is not consulted, so a value from
`/etc/xdg` or `kdedefaults` is never copied into the user's file) and the value Loft
wrote. `revert` gives a key back only while it still holds Loft's value (a choice made in
System Settings meanwhile wins) and deletes keys that weren't there, then removes the
record. A re-apply keeps the recorded originals; a key somebody else changed since Loft
wrote it (e.g. a login script that ran after Loft's apply) is recorded afresh, so that
value is what comes back. `loft qt global status [--json]` shows the switch, the session,
whether it's applied and the current values.

**Notifications.** After writing, Loft sends what `kwriteconfig6 --notify` and the colors KCM
send: `org.kde.kconfig.notify.ConfigChanged` on `/kdeglobals` (the groups and keys it
changed) and `org.kde.KGlobalSettings.notifyChange` palette (0) and style (2) on
`/KGlobalSettings` (busctl, on the session bus).

**Live or at re-login:**

| What | When it shows |
|---|---|
| running Qt / KDE apps (Plasma's platform theme: kwrite, kate, file dialogs, context menus) | **live**: the style is re-created and the palette re-read on the notification (seen nested: kwrite switched from Breeze to Loft's Kvantum, and from tokyonight to latte, without a restart). A live switch can leave a toolbar's overflow arrows or a menu's corners half-drawn until the app restarts |
| apps started afterwards | at start |
| **KWin's own menus and dialogs** (the window-operations menu, its More Actions dialogs) | **at KWin's start only** (not live, seen nested). So on a Loft login KWin's drop-in applies global mode *before* KWin starts (`ExecStartPre`, when `loft-plasma check loft`); seen nested: KWin started with the keys in place drew its menu in Loft's latte Kvantum theme. Turning the switch on or off, or a live `loft-plasma use plasma|loft`, reaches KWin's menus at the next login |
| a theme change | live in running apps (the `qt` hook re-applies and notifies); KWin's menus keep the old theme until the next login |

Glass under KWin: Loft's Kvantum theme draws translucent windows. niri blurs them by
window rule; under KWin the theme now sets `blurring=true`, so Kvantum asks KWin for its
blur (KWindowEffects; Kvantum 1.1.8 links KF6WindowSystem). Without it, the windows of
every app were see-through and unblurred in global mode (seen nested: Kate's file
dialog over KWrite). niri has no `org_kde_kwin_blur`, so this changes nothing there.

**Under niri** the same keys are written while `loft-shell` runs. KDE apps read
`kdeglobals`' style and colors when they start (KStyleManager / KColorScheme without a
KDE platform theme), so KDE apps follow; plain Qt apps follow only the niri session's own
platform theme (`QT_QPA_PLATFORMTHEME` / `QT_STYLE_OVERRIDE`, set at login, which Loft
doesn't change). Nothing is live there: restart the app.

**For the fleet's MacTahoe module** (`mactahoe-apply` writes `kdeglobals [KDE]
widgetStyle=kvantum-dark` and a MacTahoe Kvantum theme at login): when `loft-plasma check
loft` succeeds and `loft qt global status --json` says `"enabled": true`, skip
`kdeglobals [KDE] widgetStyle`, `[General] ColorScheme`, `[General] ColorSchemeHash`, the
colour groups in the table, and `Kvantum/kvantum.kvconfig [General] theme`. If it writes
them anyway after Loft's apply, Loft's record takes those values as the ones to restore,
and the next theme change (or `loft qt global apply`) puts Loft's back.

Menus in global mode (and everything else's menus) follow the shell's: §4.19.

**Global mode tested** nested (KWin 6.8.2, scratch HOME; `loft qt global start|on|off|stop`
run by hand where the units would): a BreezeClassic baseline (`plasma-apply-colorscheme`,
`widgetStyle=Breeze`, Kvantum `theme=KvArc`); `on` → 109 kdeglobals keys + Kvantum's
theme, a running KWrite (and its context menu) re-skinned live; tokyonight → latte through
the `qt` hook re-skinned it again (`kvantum-dark` → `kvantum`); `stop`, and the Settings
switch off: Kvantum's file byte for byte as before and kdeglobals as before except the
`[KFileDialog Settings]` Kate's dialog wrote itself; the record gone.
### 4.15 A Space's apps under KWin: spin-up, display roles, capture

**Done.** What §4.2 left niri-only, on Activities.

- **Which app goes where:** `loft-niri space specs <space> --displays JSON` (pure, no
  niri) resolves the Space's apps on KWin's outputs the way spin-up does under niri
  (`roles::resolve` + `apps::specs`, `crates/loft-niri/src/spaces/kwin.rs`) and prints
  each with the **display** its role is on: `{app, role, display, exec, cwd, launch,
  open, width, match: {appId, title, cwd}}`. A role no display has folds onto main's
  (`stack`, `columns`) or is skipped (`skip`, in `notes`).
- **Opening** (`crates/loft-kwin/src/spinup.rs`): the shell sends those to loft-kwin,
  `{"cmd": "openSpace", "space", "activity", "apps", "notes", "focus"}`. loft-kwin
  - **finds** each app's window among the windows **of the Space's Activity** (the
    `match` regexes and cwd, all that are given; without `match`, an app id equal to the
    command's name or ending in `.name`: `konsole` → `org.kde.konsole`). Each window
    counts once. A window on every Activity or on another Space's is never taken, so
    two Spaces with the same app each get their own (niri's claims do this there);
  - **places** a found window on another display on its role's (`moveToOutput`), as
    niri's spin-up moves a window back to its workspace;
  - **starts** what's missing (`launch` not off) in its own process group, then
    expects its window the way `loft open` does (§4.17, `expectWindow` {pid, app id
    pattern, title, activity, output, open, ttl 20 s, one window, `loose`}).
    bridge.js, on `windowAdded`, takes the first window with that pid (else, `loose`,
    matching the app id / title), sets its activities to the Space's, sends it to the
    display (`workspace.sendClientToScreen`) and maximizes / fullscreens it if the app
    says `open`. The window is placed as it maps, before the shell sees it; one that
    a child process or a running instance opens instead is placed by loft-kwin's
    process-tree check (§4.17);
  - doesn't start an app again while its window is still coming (20 s), so two Opens in
    a row don't duplicate it;
  - answers `{"SpaceOpened": {space, activity, apps: [{app, display, window, spawn}],
    notes}}`; the notes become an island banner (as `space open`'s under niri).
- **When:** like niri. The first activation of a Space in the shell's life
  (`startup: first-activate`, the default; `Spaces.persist.opened`), **Open** in
  Settings → Spaces & Windows → Spaces (switch + find + place + start), and `startup: login` Spaces once the
  Activities and the library are loaded (started in their Activity without switching:
  the script assigns the window's Activity, not the current one). Only Activities with
  Loft settings (a linked document, §4.2) have apps; a plain Activity starts nothing.
  **What was opened survives a shell restart:** `<state>/kwin-spaces.json` (`{session,
  opened, loginDone}`) is kept per login session (boot id + `XDG_SESSION_ID` +
  `WAYLAND_DISPLAY`, as loft-niri's `runtime.json` keeps `opened` per niri session) and
  read back at start, so a restarted shell doesn't start a Space's apps again (or the
  `startup: login` ones); a new session starts empty.
  No systemd scopes (niri's spin-up uses them to tell an app's windows apart): matching
  is by pid at start, then by app id / title / cwd.
- **Save This Activity's Apps** (New Space from Current Desktop under niri): `space
  capture --displays JSON --windows JSON` takes the current Activity's windows (not
  minimized, not Loft's own) instead of niri's: per display, left to right, with `exec`
  from `/proc/<pid>/cmdline`, the `appId` match, and `open: maximized` for a maximized
  window (else its width share, which only niri uses). The new document is then **linked
  to the current Activity** (`"activity": <id>`, §4.2) and marked opened for this session;
  nothing moves and the Activity isn't touched. An Activity that already has Loft settings
  is refused (edit or unlink those first). (Before the 2026-11-16 rework this made a new
  Activity and moved the windows into it.)
- **Closing** (niri's `space close`): **Close Apps…** on a linked card, or `spaces close
  <id|n>`. The shell asks `space specs` again and sends loft-kwin `{"cmd": "closeSpace",
  "space", "activity", "apps", "dryRun"}`; loft-kwin closes the windows **of the Space's
  Activity that Open would take for its apps** (`spinup::close_targets`: the same
  matching, each window once, never one on every Activity or of another Activity, never
  a window no app matches) and answers `{"SpaceClosed": {space, activity, dryRun,
  windows: [{app, window, app_id, title}], notes}}`. niri closes the windows it claimed
  or started in its scopes; KWin keeps no claims across a shell restart, so matching
  stands in for them (a second KWrite you opened yourself in the Activity stays, the one
  matched to the app goes). Settings first sends a dry run and asks: "Close 2 windows of
  “Coding”: …? Apps with unsaved changes ask first." The close is KWin's normal close, so
  an app with unsaved changes shows its own save dialog (Loft has no unsaved-state guard
  of its own; the ⌘Q QuitGuard is a hold-to-quit, not that). The **Activity is never
  removed**, and its other windows stay. Afterwards the Space counts as not opened, so its
  next activation spins it up again (niri forgets `opened` the same way).
- **Settings → Spaces cards** of linked Activities list which app goes where, one line
  per role: `main  kwrite  WL-0 (left)`, from the same `space specs --displays` (refreshed
  when the library or the displays change; `spaces list` carries them as `apps`), with
  `specs`' notes (a skipped role) under them.
- **IPC:** `spaces open <id|n>`, `spaces close <id|n>`, `spaces capture <name>` (besides
  Settings → Spaces & Windows → Spaces).
- **Tested** in a nested KWin 6.8.2 with two outputs (`--output-count 2`, WL-0 = main,
  WL-1 = right) and kactivitymanagerd, a scratch library with Main and Work (KWrite on
  `main`, Konsole on `right` without a `match`), checked with `loft-kwin state` and
  loft-shot: the first `spaces focus work` started both in Work's Activity, KWrite on
  WL-0 and Konsole on WL-1; focusing Main and Work again and two `spaces open work` in a
  row started nothing; with Konsole moved to WL-0 and KWrite closed, Open moved Konsole
  back to WL-1 and started only KWrite; `openSpace` without focus from Main started
  KWrite in Work's Activity while Main stayed current; with Dolphin on WL-0 and a
  maximized Kate on WL-1 in Main, `spaces capture Desk` wrote Desk (Dolphin on `main`,
  Kate on `right`, `open: maximized`), made its Activity, moved both windows into it and
  switched there; closing Kate and Open Desk started Kate maximized on WL-1.
  **Close, role lines, restart, niri** (2026-11-17, nested KWin 6.8.2, two outputs,
  kactivitymanagerd with Default, Music, Coding, Gaming, Editing, Ignition,
  System-Configuration made in a scrambled order and keyed Meta+1…6/0 on the session's
  kglobalaccel; scratch library: `coding` linked by name with KWrite on `main` and
  Konsole on `right`, `music` a niri Space linked by name, `gaming` linked with no
  displays, `main`): Settings → Spaces showed Coding's lines (`main kwrite WL-0 (left)`,
  `right konsole WL-1 (right)`); `spaces focus coding` started both; with a second KWrite
  and Dolphin added in Coding and a KWrite in Default, **Close Apps…** asked "Close 2
  windows of “Coding”: Welcome — KWrite, cody : bash — Konsole?", and Close closed
  Konsole while the matched KWrite (with unsaved text) showed its own save dialog; the
  other KWrite, Dolphin, Default's window and the Activity stayed; `kwin-spaces.json`
  dropped `coding`, and focusing Coding again started only Konsole. Then, with the shell
  stopped and started again, a Konsole closed by hand stayed closed on the next
  activation (`opened` read back). **Save This Activity's Apps** on Editing wrote
  `activity` + `niri: false`. The same library in a niri session: `spaces list` and
  spaces.kdl's binds had only Main and Music; Settings showed Coding, Gaming and Editing
  under **Only for KDE Activities**, Music with "also KDE Activity “Music”"; **Use as a
  Space Here** on Gaming wrote `niri: true` + `main` and it became a Space. Layout & Motion
  showed only its KWin note under KWin and every control under niri. Not run:
  `startup: login` at a real login (its path, `openSpace` without focus, was), and real
  hardware with mixed sizes and a portrait display (roles come from the same code as
  `space list --displays`, unit-tested).
- **Still open:** claims under KWin (Close takes what matching finds, not what Loft
  started; a pid record would survive only as long as loft-kwin); `space close` for a
  plain Activity (no apps of its own, so nothing; closing *all* its windows would be a
  different feature); `space gather` (niri pulls a Space's windows back from other
  workspaces; under KWin that would mean taking matching windows from other Activities,
  which Open deliberately never does); an `archive` of a linked document; the Python `loft
  space …` CLI (still loft-niri / `qs ipc` only).

### 4.16 Dragging a window into another Space

On macOS you can hold a window by its title bar, switch Space (⌃← →, ⌃1…9) and the window
comes along. Under KWin a Space is an Activity (§4.2), and KWin doesn't do this for
Activities. **Done**, in the bridge script, with stock KWin.

**What KWin does during an interactive move** (measured in a nested KWin 6.8.2 with a probe
script logging `interactiveMoveResizeStarted/Finished`, `activitiesChanged` and
`currentActivityChanged`):

- **Global shortcuts still fire.** `GlobalShortcutFilter` is installed before
  `MoveResizeFilter` (`InputRedirection::setupInputFilters`, `src/input.cpp`), so KDE's
  "Switch to activity" keys (Meta+1/2/3 in the test) switch the Activity mid-drag. Keys
  that are no shortcut go to the move filter and are swallowed (§4.6).
- **Activities: the window stays behind.** On the switch the held window is hidden (it is
  on the old Activity only), the move goes on (`move` stays true, its geometry keeps
  following the pointer) and the release finishes it on the **old** Activity: the reported
  bug. KWin knows: `// FIXME: Keep Move/Resize window across activities` in
  `Workspace::updateWindowVisibilityOnDesktopChange` (`src/workspace.cpp`).
- **Virtual desktops: KWin carries it.** The same function puts the move/resize window on
  the new desktop when it's on that output (`setDesktops({newDesktop})`). Measured:
  Ctrl+Meta+→ mid-drag, the window's desktop became "Two" and it was dropped there.
- **xremap** works on evdev events before KWin and doesn't know about moves. Its per-app
  match uses the active window, which during a drag is the dragged one, as before it, so a
  key that switches Activities normally switches them mid-drag too. Loft's keymap leaves
  ⌘1…9 alone; ⌘0 becomes Ctrl+0 (reset zoom) in every app, drag or not.

**The fix** (`carryMovingWindow`, `crates/loft-kwin/src/bridge.js`): on
`workspace.currentActivityChanged`, a window with `move` set (an interactive move, not a
resize) that isn't on the new Activity gets `activities = [current]`. It reappears at once
under the pointer, the move continues, and the drop leaves it there. Its desktop and
position are untouched (KWin's own desktop carry still applies). A window on every
Activity (`[]`) is left so. Setting `workspace.activeWindow` during the move doesn't stick
(the window stayed unfocused), so the carried window is focused when it's dropped
(`interactiveMoveResizeFinished`, once), as on macOS. Escape cancels the move as usual:
the window goes back to where the drag started, on the new Activity.

It reacts to the Activity changing, not to a key, so every way of switching works: KDE's
shortcuts, Loft's Spaces (⌘1…9, ⌃⌘← →, `setActivity` through the bridge, also tested), a
D-Bus `SetCurrentActivity`. No KWin patch, nothing for xremap, and nothing changes under
niri. It needs only the new loft-kwin (it loads the script when the shell starts it), no
re-login.

Options looked at and not needed: catching Meta+digit inside the move in the script (it
can't see keys) or in loft-kwin/xremap with a D-Bus `SetCurrentActivity` (the shortcut
already gets through), or a KWin patch for the FIXME (the script does the same thing from
outside; worth upstreaming as a patch to `updateWindowVisibilityOnDesktopChange` some day).

**Not covered:** switching by dragging onto a screen edge or onto the bar's Space
indicator. During a move KWin keeps the pointer (`MoveResizeFilter`), so the bar sees no
hover or drop. KWin's own "Switch desktop on edge: only when moving windows" (System
Settings → Screen Edges) does it for virtual desktops, and the window comes along; for
Activities it would need the bridge to watch the cursor during a move. Not done.

**Tested** in a nested KWin 6.8.2 (§6) with kactivitymanagerd, Activities Default / Coding /
Music on Meta+1/2/3 (kglobalaccel `ActivityManager` component) and a second desktop,
loft-input holding the left button on a title bar: Konsole held on Default + Meta+2 → on
Coding, still moving, dropped there and focused (`loft-kwin state`: `kwin_activities`
[Coding]); one drag through Meta+3 then Meta+1 ended on Default; KWrite, not dragged,
stayed on Default throughout, and a plain Meta+1 moved nothing; a held window on desktop
Two + Meta+2 kept desktop Two on Coding; `loft-kwin send setActivity` mid-drag carried it
to Music; a window on every Activity stayed on every Activity; Escape after Meta+2 put
the window back where the drag began, on Coding, focused. Stock KWin first, same steps:
the window ended on the old Activity.

### 4.17 Where windows open: window rules and `loft open`

**Done.** "Activity Coding, desktop 2, the right display, full screen, wherever I am":
Loft's per-app window rules work under KWin, and `loft open` does it for one launch
(agent terminals and dev sessions, whose app id every other terminal shares).

**One schema, both compositors.** The records stay loft-niri's `window-rules`
(`<state>/overrides/niri.json`, Settings → Window Rules, `loft windows rule`), plus a
Nix seed (`programs.loft.windowRules` → `~/.config/loft/window-rules.json`, merged
under the runtime records field by field, `window_rules::with_seed`). New fields
(`crates/loft-niri/src/window_rules.rs` has the table):

| field | KWin | niri |
|---|---|---|
| `match-app-id`, `match-title`, `exclude-app-id`, `exclude-title` (regexes; with `match-app-id` the key is only the rule's name) | matched against the desktop file name and the Wayland app id / WM_CLASS, and the caption | `match` / `exclude` nodes |
| `open-on-activity` | the user's KDE Activity **by name** (case, spaces, `-`, `_` ignored: "System-Configuration" = "System Configuration"), resolved when the window opens | ignored |
| `open-on-desktop` | desktop number (1 = first) or name; `open-on-workspace` counts as a desktop name when this is unset | a name becomes `open-on-workspace`; a number is ignored (indexes shift) |
| `open-on-output` | a connector, or a **display role** (`main`, `left`, `right-2`, `portrait`, `display-2` …, spaces/roles.rs on KWin's outputs) | the same, roles resolved on niri's live outputs when rendering |
| `open-fullscreen` / `open-maximized` | `fullScreen` / `setMaximize(true, true)` | as before |
| `open-size` (`1200x800`, `60%x80%`) | the frame size in the output's work area | `default-column-width` (unless set) + `default-window-height` |
| `open-position` (`center` (default with a size), `left` / `right` = that half, `X,Y` in the work area) | frame position | ignored |
| `keep-above` | `keepAbove` | ignored |
| `follow` | true: switch to its Activity and desktop and focus it; false/unset: it lands there and you stay | `open-focused` |

An Activity is never a Loft Space id here: Spaces are the user's own Activities
(§4.2), so rules name them, and an Activity that doesn't exist yet is found once
it does.

**How (KWin).**

```
niri.json + window-rules.json ── loft-niri --json windows kwin-rules --displays [KWin's outputs]
                                   → {rules (JS-ready regexes, roles → connectors), roles, sources}
loft-kwin (src/placement.rs) ── setWindowRules {rules, activityNames} ──▶ loft-bridge.js
   at start, when outputs or Activities change (activityNames: id → name from the same
   {"Activities"} report the shell's Spaces come from, §4.2, so renames too),
   when a source file's mtime changes (polled every 2 s), on {"cmd":"reloadWindowRules"}
loft-bridge.js: windowAdded → expected window? (below) → every matching rule, later
   wins per field (as niri's) → place(): activities, desktops, sendClientToScreen,
   keepAbove, fullScreen / setMaximize / geometry, then follow
   a window whose title or app id changes in its first 8 s is matched again (once)
```

There is one list of Activities: activities.rs's report (§4.2). loft-kwin keeps the
last one for the rules' names and `expect`'s check, and passes it on to the shell
(`KWin.activityList`), whose Settings page lists them by name. The state's windows gain
`kwin_output`.

**`loft open`** (`cli/loft/openwin.py`, MCP tool `open`):

```sh
loft open [--activity NAME] [--desktop N|NAME] [--monitor ROLE|CONNECTOR]
          [--fullscreen | --maximized | --size WxH] [--position center|left|right|X,Y]
          [--keep-above] [--follow] [--app-id REGEX] [--count N] [--ttl S] -- COMMAND…
```

It reads `loft-kwin state` first: no Loft shell under KWin, no such desktop, or an
`--activity` / `--monitor` that isn't there (`loft-kwin expect` with `dryRun`, checked
against loft-kwin's Activities and displays) is an error and **nothing starts**. Then the command starts detached in the caller's
environment and directory (`systemd-run --user --scope`, else its own session), and
`loft-kwin expect {pid, …}` (D-Bus `Expect`, answered with the connector it resolved)
registers it:

- bridge.js gets an `expectWindow` for the pid (placed in `windowAdded`, no flash);
- loft-kwin checks every new window of later states: one whose process descends from
  the pid (`/proc/PID/stat` parents), or, for 10 s, one of a process **older** than
  the started one whose app id matches `--app-id` (default: ends in the command's
  name), i.e. a running instance that took the request. It sends `placeWindow`.
  A konsole you start yourself meanwhile is newer and not a descendant: left alone;
- every such window for `--ttl` s (30) is placed, or the first `--count`.

**One expectation for both launchers.** A Space's apps (`openSpace`, §4.15) and `loft
open` go through the same path: loft-kwin's command loop holds the spin-up state and
the expectations (`Places`, src/placement.rs), and `openSpace` registers each started
app as an `expectWindow` with `tree` like `loft open`'s (one window, 20 s, the
Activity by id, its role's connector, and `loose`: the script may also take the first
new window matching its app id / title, as spin-up always did). bridge.js has one
`expectWindow` (`pid`/`pids`, `appId`/`appIdFlags`, `title`, `activity` (id) or
`activityName`, `desktop`, `output`, `open`, `size`, `position`, `keepAbove`,
`follow`, `ttl`, `count` (default 1; 0 = all until ttl), `id`), placed by the rules'
`place()`. Commands from stdin and from `loft-kwin send` / `expect` (D-Bus) share one
handler; `expect` gets its answer (or the refusal) back.

**niri.** Rules: the overlapping fields render into `overrides/niri.kdl` (table).
`loft open`: niri IPC (`event-stream`, then `move-window-to-monitor`,
`move-window-to-workspace --focus false`, `fullscreen-window`,
`maximize-window-to-edges`, `set-window-width/height`, `focus-window` with
`--follow`) for the first `--count` (1) window of the process tree, waiting up to
`--ttl`; `--desktop` = workspace index on that display or a name; Activity, position
and keep-above are reported as ignored. Unit-tested (the action lists), not yet run
in a niri session.

**Settings → Window Rules** (each app's editor, "Opens On"): Activity (the user's
Activities by name, KWin), Desktop (KWin: number with its name; niri: named
workspaces), Display (roles of the live layout with their connector, then
connectors), Size, Position and Keep above (KWin), Switch to it when it opens,
Only / Except titles matching; a "Nix" badge and row for seeded rules. Open floating
and Column width are hidden under KWin (every window floats).

**Backing out:** nothing is written to KDE; the rules live in the script and go
when loft-kwin unloads it (§5).

Two things learned on the way: KWin activates a new window (sometimes before
`windowAdded`), so with `follow` off the script hands focus back to the window the
user was in (a short history of recently focused windows "here", else the topmost
one); and a window sized as it maps answers its first configure with its own size,
so the geometry is asked again 200 and 800 ms later if it isn't what was asked. A
window opened onto another Activity or desktop is moved but doesn't take the resize
while hidden (seen after the stack rebase: `loft open --activity Coding --size …`
from Default left Konsole at its own size), so the geometry is kept and asked again
when the window is first shown here (`showPending`, on an Activity or desktop
switch). An expectation that arrives after a rule placed the window (the app mapped
before `loft-kwin expect` ran) places it again; `open: maximized` then drops the
rule's full screen. A size is capped to the output's work area (bar and dock
struts). Apps that remember their window size (Konsole's `konsolestaterc`) reopen
at it; that isn't a rule.

**Tested** in a nested KWin 6.8.2 (§6: `--output-count 2 --size 1280x800`, scratch
`LOFT_LIBRARY` / `LOFT_SPACES_DIR`), Activities Default, Music, Coding, Gaming made on
the session's kactivitymanagerd and a second desktop "Two", checked with `loft-kwin
state` and screenshots:

- rule `org.kde.kwrite`: `open-on-activity=Coding open-on-desktop=2
  open-on-output=right open-fullscreen=true follow=false`, sitting in Default /
  desktop 1 with a konsole focused on WL-0: the new KWrite got `kwin_activities` =
  Coding, desktop 2, `kwin_output` WL-1, fullscreen 1280×800; current Activity and
  desktop stayed Default / 1, the konsole kept focus. With `follow=true` (picked up
  from the file within the 2 s poll) the next KWrite switched the session to Coding /
  desktop "Two", focused;
- `loft open --activity Coding --desktop 2 --monitor right --size 1200x800 --
  konsole`, then a plain konsole: the first on Coding / 2 / WL-1 at 1200×694 (the work
  area's height), the plain one on Default / 1 / WL-0 at its own 910×498, focused; the
  session never left Default / 1. `--activity music --desktop Two --monitor main
  --maximized --follow`: Music / 2 / WL-0, maximized, switched there;
- refused before starting anything: `--activity Nope` (lists the Activities),
  `--monitor left` (lists the displays' roles), `--desktop 5` ("KWin has 2");
- Settings → Window Rules under KWin showed KWrite's rule (Coding, "2 · Two",
  "Right (WL-1)", Follows) and typing `60%x80%` in Size saved `open-size`.

Not tested: the late-title re-match (no test), the running-instance fallback (a
unit test only), `loft open` under niri (its action lists are unit-tested), and the
Nix option beyond evaluating its type with the example and the module parsing.

**Re-tested after the stack rebase** (same session shape, KDE "Switch to activity"
keys Meta+1…4 set on the session's kglobalaccel, the rule and `loft open` as above):
the KWrite rule with `follow=false` (Coding / Two / WL-1 full screen, Default / 1 and
the Konsole's focus kept) and `follow=true` (switched to Coding · 2, KWrite focused);
`loft open … --size 1200x800 -- konsole` (Coding / Two / WL-1, 1200×694 once Coding is
shown, after the fix above) and a plain Konsole (stayed on the current Activity and
desktop, focused); `--activity music --desktop Two --monitor main --maximized
--follow -- kwrite` (Music / Two / WL-0, maximized, focused, switched); refusals for
`--activity Nope` (from loft-kwin's dry run, with the Activities' names), `--monitor
left`, `--desktop 5`, nothing started. The stack's own paths still work: Spaces =
the four Activities in key order, following a rename both ways; `spaces open` of a
Space linked to Gaming started Konsole on Gaming / WL-1 and switched there, a second
Open started nothing; dragging a Konsole and pressing Meta+2 mid-drag carried it to
Music, focused after the drop; with `loft-keys.js` loaded, tapping Meta+Q on a
protected Konsole showed "Hold ⌘Q to quit Konsole" and kept it, holding 2 s quit it;
Settings → Spaces & Windows → Window Rules showed KWrite's rule (Coding, 2 · Two,
Right (WL-1), Follows).

### 4.18 KWin scripts that heal themselves

Two KWin scripts carry Loft under KWin: loft-kwin's **`loft-bridge`** (state and window
commands, §3) and **`loft-keys`** (the shortcuts, §4.5). After a deploy on THEBATTLESHIP
both were sometimes not loaded, or loaded and never started, while loft-kwin ran (most
likely KWin's reused script ids, fixed by `Scripting.start`; #57). Neither ever came back
on its own: the bridge is loaded once when loft-kwin starts, the keys once when Loft's
shell unit starts. **Done:** loft-kwin watches both and loads them again
(`crates/loft-kwin/src/heal.rs`).

Every 5 s, while loft-kwin runs (= while Loft's shell runs):

- **loft-bridge is gone** when KWin's `isScriptLoaded("loft-bridge")` is false, or when
  it is loaded but silent: no `NextCommands` poll in flight and none for 25 s (a poll is
  answered within 15 s and the script polls again at once, so a running bridge always
  has one). loft-kwin then unloads and loads it as at start (`load_script`, with
  `Scripting.start`) and turns KWin's popup fade off again (a new KWin has it on).
- **loft-keys is gone** when `isScriptLoaded("loft-keys")` is false at two checks in a
  row, while the rendered `$XDG_RUNTIME_DIR/loft/plasma-keys/loft-keys.js` exists and is
  at least 10 s old (a fresh one means a `load` is running). loft-kwin then runs
  `$LOFT_PLASMA_SHORTCUTS heal` (`loft-plasma-shell.service` sets it to the unit's own
  `loft-plasma-shortcuts`). `heal` is the unit's `load` (unload, render, load, start,
  `claim`), behind the same lock as `load` and `unload` (`flock` on
  `…/plasma-keys.lock`), and only if, under that lock, the rendered script still exists,
  `loft-plasma-shell.service` is **active** (not starting, not stopping) and KWin still
  says it isn't loaded. Because it is the same load, the claim record stays right:
  `unload` gives back what was taken and `claim` takes it again, also from a KWin that
  restarted and reread kglobalshortcutsrc. Without `LOFT_PLASMA_SHORTCUTS` (a `loft-dev`
  session) loft-kwin loads the rendered file itself (`loadScript` + `start`, no claim).
- **Loaded but never started.** For loft-keys there's nothing to observe a dead script
  by, so every 30 s while it is loaded loft-kwin calls `Scripting.start`, which starts
  any loaded script that isn't running and leaves running ones alone.
- **Rate limit:** at most one heal per script every 30 s. Each heal is one stderr line
  (the shell logs loft-kwin's stderr), e.g. `loft-kwin: heal loft-bridge (loaded but
  no poll for 25 s): reloaded`, `loft-kwin: heal loft-keys (not loaded in KWin):
  loft-plasma-shortcuts heal`, or the same with `failed: …`.

**Never against a deliberate unload.** `loft-plasma-shortcuts unload` (the unit's
`ExecStopPost`: Loft stopping, `loft-plasma use plasma`, a crash) removes the rendered
script **first**, under the lock. From then on there is nothing to heal, and loft-kwin is
gone with the shell's cgroup by then anyway. loft-kwin itself marks itself stopping before
it unloads its bridge on exit, so its healer can't put it back.

**Restarts.** KWin restarting (`kwin_wayland --replace`, a crash): while KWin is away
`isScriptLoaded` fails and nothing is done; the new KWin answers "not loaded" and both
scripts come back at the next checks. The shell restarting: a new loft-kwin loads the
bridge as it starts; the unit's stop and start unload and load the keys. loft-kwin
restarting alone (the shell restarts it when it exits): the new one loads the bridge, and
loft-keys is untouched.

**Limits.** Healing needs loft-kwin: if it can't start at all (no session bus, its bus
name taken), nothing heals. A loft-keys that loads but fails inside (a script error) looks
loaded and isn't reloaded. The first heal comes 5–10 s (bridge) or 10–15 s (keys) after
the loss, and a bridge that stopped polling is noticed only after 25 s.

**Tested** in a nested KWin 6.8.2 (§6, `--shell loft`, the branch's loft-kwin; loft-keys
rendered from the checkout, loaded and claimed in the session by a stand-in for the
unit's `load`), every unload against the session's own KWin:

| What | Back after | Then |
|---|---|---|
| `unloadScript loft-bridge` | 4 s | a new KWrite window reached `loft-kwin state`; `loft-kwin send center` moved it |
| `loft-bridge` swapped for a script that never polls (the #57 case) | 39 s (`no poll for 25 s`) | `send geometryPercent` moved the window |
| `unloadScript loft-keys` | 9 s | Meta+C, Meta+W, Meta+F worked |
| both at once (what a KWin restart leaves) | bridge 2 s, keys 7 s | |
| `loft-bridge` again 5 s later | 30 s after the previous heal (rate limit) | |
| loft-kwin `SIGTERM` | new loft-kwin in 2 s, bridge loaded, keys untouched | Meta+C, Meta+Shift+F worked |
| deliberate unload (stand-in `unload`: script file removed, then unloaded, released) | not reloaded in 45 s, no heal line | KDE's Overview had Meta+W again |

The real `loft-plasma-shortcuts` (built from the fleet config with this checkout) was run
in the session only for its early exits, as its `load` uses the real state dir: `heal`
with no rendered script exits 0, and with one it waited for a held lock (2.7 s) and
then exited 0 without loading, as no `loft-plasma-shell.service` is active there. **Not
tested:** a real `kwin_wayland --replace` (the nested KWin owns the session; replacing it
ends the test session) and the `heal` → `load` path under the user's systemd.

**The cause, fixed in KWin: reused script ids.** Stock KWin (6.7, 6.8) gives a new
script the id `scripts.size()` (`Scripting::loadScript`, `src/scripting/scripting.cpp`)
and exports it at `/Scripting/Script<id>`. Once any script is removed, the next load
gets an id that a script loaded after it still has. That load's `registerObject` fails
silently, and the client calling `run`/`stop` on "its" id reaches the other script.
kdotool (OpenDeck's KWin backend) loads, runs, stops and unloads a throwaway script
several times a second. So whenever loft-bridge or loft-keys loaded while one of those
was in flight (at login, after a heal), kdotool's next `stop` stopped Loft's script.
`loft-kwin-patched` carries `nix/kwin/unique-script-ids.patch` (always on, 6.7.5 and
6.8.2). Ids come from a counter that only grows for the life of KWin. `stop` and
`unloadScript` take the script's path off the bus at once, so a stale id fails with
`UnknownObject` and never reaches another script. A failed `registerObject` is logged.
The D-Bus API is unchanged (`loadScript` still returns an int, `-1` = already loaded),
so kdotool, Plasma, loft-kwin and `loft-plasma-shortcuts` work as before. With the
patched KWin the heal above is a **fallback** (a KWin restart, a script error), and
**OpenDeck can come back**. On a stock KWin (`plasma.kwinPackage = null`), Loft still
relies on the heal.

Tested in a nested session (§6, `--shell loft`), with stock KWin 6.8.2 and then the fleet's
patched 6.8.2. Deterministic case: load X, A, B; unload X; load T; `Script<T>.stop`.
Churn: 3–4 kdotool-style workers (`loadScript` a temp file, `Script<id>.run`, `.stop`,
`unloadScript`, ~4/s each) for 60 s, while a script A and a loft-keys stand-in were
loaded mid-churn and reloaded every 15 s:

| | stock 6.8.2 | patched 6.8.2 |
|---|---|---|
| X, A, B = 1, 2, 3; X unloaded; T gets | 3 (B's): `stop` on it stopped B | 4: B stays loaded |
| `run` on X's old path | `UnknownObject` (nothing reuses 1 yet) | `UnknownObject` |
| churn: ids handed out twice | 5 ids, 202 kdotool loads on an id a Loft-side script had | none in 655 + 524 loads |
| churn: A missing | 27 of 60 s | 0 (beyond the second before its first load) |
| churn: loft-bridge | missing 33 of 60 s, a heal on top of the one for the deliberate unload at t=3 | only the deliberate unload's heal; run 2 (no unload): 0 heals |

### 4.19 Menus in every app: GTK, Electron and Qt in the shell's look

Real Loft-drawn menus inside other apps aren't possible on Linux: each toolkit draws its
own context menus. Loft styles each toolkit's menus to look like the shell's own
(`src/menubar/MenuPanel.qml`), from one set of numbers in `cli/loft/render/look.py`
(`MENU`, `menu()`): 12 px radius, the theme's glass (`Theme.fillFor(1.9)`: the glass
opacity × 1.9, at most 0.97, at least 0.72 without blur) with its hairline, rows inset
6 px and 26 px tall, the highlighted row an accent pill (radius 6) with readable text
(`on_accent`), separators a 1 px line at 14 % text, shortcuts in subtext.

| Toolkit | Where | What matches | What can't |
|---|---|---|---|
| GTK 3 (context menus, menu bar menus: `menu`, `menuitem`, `.csd.popup decoration`) | the theme's `gtk.css` (`gtk` unit), imported by `~/.config/gtk-3.0/gtk.css` (`programs.loft.gtk`) | everything above; the shadow is the popup's CSD shadow | blur: GTK can't ask the compositor for it, so the glass is drawn opaque (the menu fill over the theme's background) |
| GTK 4 / libadwaita (`popover.menu`, `modelbutton`) | the same `gtk.css`, imported by `gtk-4.0/gtk.css` | everything above | blur (as GTK 3) |
| Chromium / Electron (tested: T3 Code, an Electron 43 app; VS Code, Brave and other Chromium apps work the same way, untested) | nothing app-side: Chromium's own `views` menus take their colors from GTK (`ui/gtk` color mixer: the `menu` node's background, `menu menuitem` text, `menuitem:hover` background and text, `menu separator`, `menuitem accelerator`, disabled text) | background, text, hover pill color and its text, separators, disabled and shortcut colors | radius, padding, row height, font, shadow and the hover pill's shape are Chromium's own (`MenuConfig`); no blur; no CSS reaches it. The menu colors are opaque on purpose: Chromium samples the node's background and can't blend it |
| Qt / KDE (Kvantum: Dolphin with `programs.loft.qt`, every app with global mode §4.14) | the `qt` unit's `kvantum.kvconfig` / `kvantum.svg` | everything above, and real glass: the menu is translucent and Kvantum asks KWin to blur behind it (`popup_blurring`, `menu_blur_radius=10` rounds the blur region; `menu-shadow-hint-*` keep it off the shadow), an 8 px shadow (`menu_shadow_depth`, which also makes Kvantum draw the menu translucent so the corners are round), separators (`arrow-separator`: Kvantum draws a separator with the MenuItem *indicator* element, `menu_separator_height=9`) | rows are inset by the 12 px frame (Kvantum uses the corner size as the padding), not 6. Under niri there is no blur for Qt popups; the fill (≥ 0.72) keeps text legible |

Nothing is needed per app: T3 Code's right-click menu followed with no flags and no
`--gtk-version` (seen nested, below). Either GTK version Chromium loads reads Loft's
file: `gtk-3.0/gtk.css` and `gtk-4.0/gtk.css` both import it.

**When it shows.** GTK apps read `gtk.css` when they start, and Chromium reads the GTK
colors at start (and when GTK's theme name changes), so after a theme change a running
app shows the new menus once restarted. Qt apps in global mode re-skin live (the `qt`
hook's style notification, §4.14); Dolphin in scoped mode at restart.

**One switch?** No new switch. GTK and Electron menus come with `programs.loft.gtk`
(on by default), which already themes GTK everywhere through home-manager's `gtk.css`;
Loft writes no GTK setting there, so there is nothing to record or put back while Loft is
the shell. Qt keeps **Theme all Qt apps** (§4.14), because that one changes the user's
global KDE style and has to be undone when Loft isn't the shell.

**For the fleet's MacTahoe module.** Nothing has to change for the menus: the user CSS
wins over the forced `gtk.theme` (MacTahoe-Dark-blue), and Chromium reads the result.
Worth changing:

- `~/.config/gtk-4.0/gtk.css` imports MacTahoe's GTK 4 CSS *after* Loft's (home-manager
  appends the `gtk.theme` / `gtk.gtk4.theme` import below `gtk4.extraCss`), so MacTahoe
  wins every rule Loft writes with the same selector. Loft's menu rules carry
  `:not(.loft-a)` to stay ahead, but the clean fix is to stop home-manager adding that
  import (`gtk.gtk4.theme = null`, or not setting a GTK 4 theme) and let
  `programs.loft.gtkBase` import MacTahoe *under* Loft, as it already does.
- `gtk-application-prefer-dark-theme=true` and `MacTahoe-Dark-blue` are forced, so with a
  light Loft theme GTK 3 apps keep MacTahoe's dark base outside what Loft overrides. The
  menus are light either way (seen nested with latte); the rest would need the theme name
  to follow the polarity, which a static home-manager value can't do.
- Qt: turn on `programs.loft.qt.global` (or the Settings switch) for every KDE app's
  menus, and have `mactahoe-apply` skip the keys listed in §4.14 while it's on.

**Tested** nested (KWin 6.8.2, scratch HOME with the fleet's GTK files reproduced:
`gtk-3.0/settings.ini` + `GTK_THEME=MacTahoe-Dark-blue`, `gtk-4.0/gtk.css` importing
MacTahoe's GTK 4 CSS before and after Loft's; global Qt mode on), tokyonight and latte,
"before" = main's render: gtk3-demo's entry menu (GTK 3), gnome-text-editor's text menu
(GTK 4), a minimal Electron 43 app with a `Menu.popup` context menu, T3 Code's AppImage
with a scratch `--user-data-dir` / `T3CODE_HOME` (its text-field menu), KWrite's editor
menu (Qt), next to the shell's desktop menu. Before: MacTahoe's grey menus with #2E7CF7
rows in GTK and Electron / T3 Code, square opaque Kvantum menus without separators in
KWrite. After: all in the Loft theme's colors and accent with dark-on-accent (tokyonight)
or white-on-accent (latte) text; KWrite's menu round, shadowed, blurred glass with
separators.

## 5. One Plasma session, two shells: switching and backing out

Requirements: both shells work in the same Plasma session, never run at once, can be
switched live, and Loft leaves nothing behind that changes how plain Plasma behaves.

**Units.** Don't mask plasmashell. Instead:

- `loft-shell.service` (+ `loft-launcher.service`): `WantedBy`, `PartOf` and `After`
  `plasma-workspace.target`, `Requisite=plasma-kwin_wayland.service` (Loft stays out
  of other desktops, as with niri today), and **`Conflicts=plasma-plasmashell.service`**.
- A drop-in for `plasma-plasmashell.service`: `Conflicts=loft-shell.service`, and an
  `ExecCondition` that skips it when the choice is `loft`.
- `loft-shell.service` gets the mirrored `ExecCondition` (skip when the choice is
  `plasma`). Starting either shell stops the other.

**The choice**, highest priority first:

1. The login session. SDDM offers **"Plasma (Loft)"** next to plain **"Plasma"**. The
   Loft entry runs `startplasma-wayland` with `LOFT_PLASMA_SHELL=loft`, which Plasma
   imports into the user manager's environment, where the `ExecCondition`s read it.
   Plain "Plasma" sets nothing.
2. Otherwise, `~/.local/state/loft/plasma-shell` (`loft` | `plasma`), written by the
   switch command. A missing file means `plasma`, so stock Plasma is the safe default.

**Switching live:** `loft shell use plasma|loft` writes the choice and runs
`systemctl --user start` on the chosen unit (`Conflicts` stops the other). Also:

- Settings → General → "Switch to Plasma's desktop".
- A kglobalaccel shortcut that belongs to neither shell (a `.desktop` with
  `X-KDE-Shortcuts`, e.g. Meta+Ctrl+Alt+Backspace). kglobalaccel lives in KWin, so it
  works with no shell running at all.
- From a TTY or SSH: `systemctl --user start plasma-plasmashell` works by hand.

**Automatic back-out.** `loft-shell.service` has `OnFailure=loft-shell-fallback.service`.
After the restart limit (e.g. 3 crashes in 30 s), that unit starts plasmashell and
sends a notification. A broken Loft lands you in plain Plasma, never on an empty
screen.

**No traces in Plasma.** Everything Loft changes in KWin is runtime-only and undone
when Loft stops:

| Loft changes | How it's undone |
|---|---|
| loft-bridge.js (state, actions, Loft shortcuts, window rules) | loft-kwin unloads it on exit (`ExecStopPost` too, in case it crashed). Its shortcuts and rules disappear with it |
| the decoration and button order (`[org.kde.kdecoration2] library/theme/ButtonsOnLeft/ButtonsOnRight` in kwinrc; GTK's `gtk-decoration-layout` follows via kded's gtkconfig) | `loft-kwin-decoration apply` (loft-plasma-shell's `ExecStartPost`) records the previous value in Loft's state dir and sets Loft's. `loft-kwin-decoration revert` (`ExecStopPost`) puts it back. Both run `org.kde.KWin.reconfigure` (§4.4) |
| Loft's shortcuts (`loft-keys.js`, §4.5) and the keys taken from other shortcuts | `loft-plasma-shortcuts unload` (`ExecStopPost` of loft-plasma-shell): script unloaded, Loft's actions unregistered, taken keys given back from `<state>/kwin-shortcuts-taken.json` (plasmashell's start does the last part too) |
| the tile-while-dragging modifier (`[Windows] TileWhileMovingModifier`, §4.6) | `loft-kwin-tile-modifier apply` / `revert`, recorded in `<state>/kwin-tile-modifier.prev` like the decoration. Only set with `programs.loft.plasma.kwinPackage` |
| where apps' own window-menu requests go (`[Windows] ClientWindowMenuService`, §4.4) | `loft-kwin-window-menu apply` / `revert`, recorded in `<state>/kwin-window-menu.prev`. Only set with `programs.loft.plasma.kwinPackage` |
| KWin's popup fade (`fadingpopups`: 150 ms in, 600 ms out on every popup, so Loft's menus seemed to grow out of a corner) | `loft-kwin` unloads it at start (runtime only, nothing written to kwinrc) and loads it again on exit; the effects it took are noted in `$XDG_RUNTIME_DIR/loft/kwin-effects-off`, so a restart after a crash still gives them back, and an effect the user had off stays off |
| the global Qt style (`programs.loft.qt.global`, §4.14): kdeglobals `[KDE] widgetStyle`, `[General] ColorScheme` / `ColorSchemeHash`, the `[Colors:*]` / `[ColorEffects:*]` / `[WM]` keys of Loft's scheme; Kvantum's `[General] theme` | `loft qt global start` (`ExecStartPost`, only when on) records the user's values in `<state>/qt-global.prev`; `loft qt global stop` (`ExecStopPost`, and plasmashell's `ExecStartPre`) puts back every key still Loft's and deletes the ones that weren't set, with KConfig's change notification so running apps follow |
| Alt+F3 (KWin's Window Operations Menu, §4.4) | taken by Loft's `loft-window-menu` shortcut through the same claim / release as the others |
| any other kwinrc key Loft needs (blur strength, effects) | the same record / revert list. Nothing outside it is touched |
| the lock screen | `PLASMA_DEFAULT_SHELL` only in KWin's environment, and only when the login is Loft's (`loft-plasma lock-env`, §4.3). Lock and unlock stay Plasma's either way |
| KDE Activities | never written: Spaces are the user's Activities, read-only (§4.2). Activities an older Loft build created (`<state>/kwin-activities.json`) are kept (harmless); `loft spaces prune` removes those and renames an adopted one back |

Loft never writes `plasma-org.kde.plasma.desktop-appletsrc`, `plasmashellrc` or
`kwinrulesrc`, so plasmashell comes back with your panels as you left them.

**Also in the module:** `findNiriSocket` is already a no-op without niri. swayidle
stays bound to `niri.service`, and Plasma uses PowerDevil. loft-appmenu already steps
aside when Plasma's appmenu kded module owns `com.canonical.AppMenu.Registrar`.
Whether menus then still reach Loft's bar needs checking.

## 6. Testing against KWin with loft-dev

**Implemented** (KWin 6.8.2): `loft-dev --session NAME --compositor kwin [--shell
loft|plasma]` runs a whole KDE session nested and headless, the way loft-dev runs niri.
Usage is in [TESTING.md](TESTING.md#kde-sessions---compositor-kwin). Both stock
**plasmashell** (panel, tray, dock, wallpaper) and **Loft's shell** (bar, island, dock,
Control Center) run in it, screenshotted with `loft-shot` and driven with `loft-input`.

```sh
# what loft-dev does, in short (nix/dev/loft-dev.sh, run_kwin):
# 1. headless sway host on a GPU render node (gles2), one output N×W wide
# 2. in one user unit, loft-dev-kwin-NAME: a private bus with KWin's socket, scratch HOME
#    and XDG dirs, the session's own XDG_RUNTIME_DIR, and only KWin on the host:
dbus-run-session -- env WAYLAND_DISPLAY=$host kwin_wayland --width W --height H \
  --output-count N --socket wayland-loft --xwayland --no-lockscreen --exit-with-session kde-session.sh
# kde-session.sh: dbus-update-activation-environment, kactivitymanagerd, kded6, then
#   loft-shell (LOFT_SHELL_SRC=$checkout/src LOFT_DEV=1) + loft-launcher, or plasmashell
```

What it took:

- **The host needs a GPU renderer.** With loft-dev's default pixman host, KWin's wayland
  backend quits ("The used windowing system requires compositing"). `KWIN_COMPOSE=Q`
  doesn't help. So `--compositor kwin` implies `--gpu`. Still headless.
- **`$HOME` must be scratch, unlike niri sessions.** plasmashell, KWin, kded and Akonadi
  write their config on startup. With `HOME` + XDG dirs pointed at `<session dir>/home`
  nothing outside it changes (checked: no KDE files in the real `~/.config` or
  `~/.local/share` after a run). Defaults still come from `/etc/xdg`.
- **One transient unit.** D-Bus activation starts portals, gvfs and the document portal (FUSE
  mounts under the runtime dir), at-spi, ksecretd, Akonadi. Stopping the unit stops them
  all. Their FUSE mounts can outlive the cgroup (the auto-unmount helper dies with it), so the
  unit's `ExecStopPost` lazily unmounts them.
- **The bus must not have the host's `WAYLAND_DISPLAY`**, or every activated service maps
  its surfaces on the host, over KWin. The bus starts with KWin's socket. Only KWin gets the
  host's, and the session script updates the activation environment (as startplasma does).
- **Input needs devices held on the host.** The headless host has none, and a virtual
  device appearing per `loft-input` run flips the seat's capabilities. KWin binds a new
  `wl_pointer` each time, the `enter` is lost in that race, and KWin drops the buttons
  (seen with `WAYLAND_DEBUG=client` on KWin: `button` with no `enter`/`motion`). A
  `loft-input` script holding a pointer + keyboard for the session's lifetime (unit
  `loft-dev-kwin-NAME-input`) fixes it, with one output or several.
- **Several outputs:** `--output-count N` (`WL-0`, `WL-1`, …). The N nested windows sit side
  by side on one host output; with one host output per KWin output the windows rendered, but
  that layout was dropped while chasing the input bug above.
- `loft-input key` reaches KWin itself, so global shortcuts fire with real combos (`key
  super+w` → Overview). `loft-input bind COMPONENT/NAME` calls kglobalaccel's
  `invokeShortcut` on the session's bus (`bind kwin/Overview`, verified).
- `loft-live` runs inside such a session as a test of its Plasma path (TESTING.md).
- Plasma-session services that `startplasma-wayland` normally starts and this doesn't:
  ksmserver, powerdevil, the polkit agent, xdg-desktop-portal-kde (D-Bus activated anyway).
  Add them when a test needs them.
- **A private PipeWire.** KWin's screencasts (`loft-kwin record`, §4.10) need PipeWire.
  `kwin-run.sh` starts `pipewire`, `wireplumber` and `pipewire-pulse` in the session's runtime
  dir before KWin, with no devices (WirePlumber's ALSA, bluez, V4L2 and libcamera monitors off,
  no logind or device reservation) and two virtual nodes: a null sink (`loft-dev-sink`, the
  default; its monitor is "system audio") and a silent source (`loft-dev-mic`). The user's own
  PipeWire is never involved. Log: `<session dir>/pipewire.log`.
- Still open: whether KWin's privileged-interface checks (ScreenShot2,
  plasma_window_management) can be relaxed for a dev session, or whether loft-kwin needs an
  installed .desktop file with `X-KDE-Wayland-Interfaces` /
  `X-KDE-DBUS-Restricted-Interfaces`.

## 7. Steps

1. ✅ This plan.
2. ✅ `Compositor.qml` in front of `Niri.qml`, every consumer moved, behavior under niri
   unchanged.
3. `loft-dev --compositor kwin [--shell loft|plasma]` (§6), so every later step can be
   tested headless like niri sessions.
4. ✅ `crates/loft-kwin` + its KWin script (`crates/loft-kwin/src/bridge.js`) +
   `services/KWin.qml`: windows, desktops, focus, minimized, keyboard layouts.
5. ✅ Actions + `capabilities` gating in menus. Hide → minimize.
6. ✅ Shell switching (§5): the SDDM "Loft" entry, `loft-plasma use plasma|loft`, the
   crash fallback, `loft-kwin-decoration apply/revert`.
7. ✅ Decoration plugin (§4.4): `dev.loft.decoration`, `loft-kwin-decoration apply|revert`.
8. ✅ Lock screen shell package (§4.3).
9. ✅ Keybinds (§4.5). ✅ Capture through ScreenShot2 (§4.7). ✅ Spotlight's window
   commands, `loft mcp` and the overview state (§4.9). ✅ Recording through
   zkde_screencast (§4.10). ✅ Display settings (§4.11).
10. ✅ Spaces on Activities (§4.2).
11. ✅ Window thumbnails through ScreenShot2 (§4.8).

## 8. Notes for the fleet flake (~/.flake, out of scope here)

- `settings.desktop.session = "kde"` needs Plasma 6 enabled *and* niri kept, so SDDM
  offers niri, "Plasma" and "Plasma (Loft)" (§5).
- A Loft-on-Plasma variant of `fleet.desktop._.loft` turns on the module's Plasma
  option (units, plasmashell drop-in, the SDDM session entry, the switch shortcut).
  It must **not** mask plasmashell (§5 relies on it being startable), and must not
  enable `programs.niri`-only bits (swayidle on `niri.service`, `niri-loft-live`) for
  that session.
- The lock-screen shell package (§4.3) and the decoration plugin (§4.4) probably have
  to be in the system profile (`environment.systemPackages`) for the greeter and KWin
  to find them. Check before relying on home-manager's profile.
- xremap: `pkgs.xremap.kde` (or both features) on hosts that boot into Plasma.
- `loft-kdecoration` links against the kdecoration / Qt of Loft's nixpkgs input. Let
  that input follow the fleet's nixpkgs so it matches the system's KWin. (A plugin
  built against kdecoration 6.7.5 / Qt 6.11 loaded and worked in KWin 6.8.2 / Qt 6.12
  in the nested test, but KDecoration doesn't promise ABI across Plasma releases.)
- Leave kwinrc to the user. Loft applies its keys at runtime and reverts them (§5).
  The flake shouldn't bake the Loft decoration into kwinrc, or plain Plasma would get
  it too.
