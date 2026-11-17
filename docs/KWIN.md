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
| keybinds (loft-niri → niri KDL binds) | kglobalaccel, **done** (§4.5): `loft-keys.js`, a KWin script of `registerShortcut`s generated from shell-binds + Settings → Keyboard Shortcuts, loaded while Loft's shell runs (§5) |
| window rules (loft-niri window_rules.rs) | applied by loft-bridge.js at `windowAdded` while Loft runs, not written to `kwinrulesrc` (§5) |
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
(Maximize Column, column-width presets, consume/expel, center visible), niri's motion
and shape settings (KWin has its own animations), the niri sections of Settings
(keybinds-as-KDL, window-rule KDL preview), and workspace-layer wallpapers.

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
  bar extras, `bar.hidden`, Focus, `wallpapers`, apps and display roles (§4.13); the space
  then has the document's id. **No document → a plain Activity**: switching, the bar,
  Move to Space and its windows all work; no extras, nothing started. Settings → Spaces
  links one (a card's **Add Loft Settings…**: new settings, or "Use “Music”" for a library
  document no Activity has yet), **Edit** / **Unlink** / **Remove Settings…** it later;
  **Save This Activity's Apps** (§4.13's capture) writes a document linked to the current
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
  made in Plasma), reordering, renaming (Plasma's), archive.
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
    A bind of the user's own on Alt+F3 (Settings → Keyboard Shortcuts) keeps the key.
    Tested nested (KWin 6.8.2, `loft-input key alt+F3`, the branch's loft-kwin): Loft's
    menu opened under KWrite's green bead; with that loft-kwin killed, KWin's own menu at
    once; `claim` took "Window Menu" (KWin's friendly name) and `release` gave Alt+F3
    back, kglobalshortcutsrc's line as before.
  - **Other ways KWin's menu still opens:** a Wayland client's
    `xdg_toplevel.show_window_menu` (GTK / libadwaita header bars on right-click,
    Chromium's CSD) and X11's `_GTK_SHOW_WINDOW_MENU` / `_NET_WM` window-menu requests go
    straight to KWin's `UserActionsMenu`; a KWin script can't intercept them (no signal),
    so they keep KWin's menu (with the global Qt style, §4.13, in Loft's look after a
    re-login). KWin's `[MouseBindings]` defaults put no window menu on Alt+click
    (Alt+right-drag resizes), and the Window Operations button (`M`) isn't in Loft's
    button order. Loft has no task manager.
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
Cmd, Right ⌘ stays the symbols layer. Every `loft keys` write records the key in
`<state>/xremap/wm-key`, so a `loft keys …` from a terminal renders for the
xremap that runs (then `XDG_CURRENT_DESKTOP` with KDE → meta). `loft keys show`
says which. Not covered: WM key + mouse (KWin's Meta+drag) and a WM-key hold
alone (Cleaning Mode's "hold Esc" — the timer still ends it).

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
hold and the Radial Menu's hold: §4.13 (KWin does repeat held shortcuts; the
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
| Keyboard Shortcuts | `show-hotkey-overlay` | Loft's Settings → Keyboard Shortcuts (KDE has no overlay) |
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

### 4.13 Held shortcuts: press, repeat and release

Two Loft shortcuts are about holding a key: **⌘Q** (the quit guard, hold ~1 s to quit a
protected app, `src/everyday/QuitGuard.qml`) and **⌃⌘Space** (the Radial Menu: press opens
the wheel, release picks, `src/palette/Radial.qml`). On niri the first counts niri's bind
repeats and the second is `repeat=false` plus the wheel's own key-release handling.

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
   the action id without `loft-` and a `-N` twin suffix: `quit` for Meta+Q and Alt+F4,
   `radial-hold`) and keeps when each id was last pressed and whether it is down.
   `capabilities.shortcutKeys` is true on KWin, false on niri.
2. The KWin script keeps niri's bind properties (`cli/loft/kwinkeys.py`): a `repeat=false`
   bind drops triggers within 250 ms of the previous one (a repeat; the first repeat, one
   repeat delay after the press, still gets through), a `cooldown-ms` bind runs at most once
   per cooldown. Moved/custom binds keep their `props`. A held ⌘Q now starts ~6 units a
   second instead of 25, a held ⌃⌘Space 2 in all.
3. The shortcut's own command still runs (it is the fallback when the shell is gone: the
   quit bind then closes the window through KWin), arriving 50+ ms later through systemd and
   `quickshell ipc`. `Compositor.shortcutRecent(id, 1500)` (pressed in the last 1.5 s, or
   still down) tells the shell it is the same keypress, and `quit key`/`keyAt` and
   `radial hold` drop it.
4. **Quit guard**: `QuitGuard.shortcut(state)`. pressed = the bind's press (protected app:
   the pill; other apps: close the window once); repeated = keeps a hold going, never a
   second close; released before the hold completes = cancel at once (instead of after
   0.8 s without repeats). Between the press and the first repeat the key is known to be
   down, so a long repeat delay doesn't cancel the hold. It quits once the hold has lasted
   `holdMs` with repeats arriving, or with the key down and no repeats (key repeat off in
   KDE).
5. **Radial Menu**: pressed → `Radial.hold()` (opens, or closes an open wheel); released →
   `Radial.release()` (picks the slice under the pointer; a tap or a submenu leaves it open
   to click). The wheel's own modifier-release handling stays; whichever comes second finds
   the wheel closed or sticky and does nothing. Unlike niri, letting go of Space first picks
   too.

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
- hold ⌃⌘Space, move onto the top slice, release: the wheel shows Terminal selected while
  held, the release runs it (a terminal opens). Tap (100 ms): the wheel stays open; Esc
  closes it.

**Not run / open**: real keyboards through xremap-kde (it would grab the real devices; xremap
sends ⌘Q as Meta+Q or Alt+F4 presses, both `loft-quit*`, so the same signals apply);
plasmashell's shortcuts. Seen once in the nested session: the wheel opened at the screen's
top-left corner, or on the pointer's previous position, instead of under the pointer
(`RadialMenuWindow` takes `mouseX/mouseY` on the pointer's enter; likely the
virtual-pointer races of §6); placement isn't part of this change.
### 4.14 Dragging a window into another Space

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

### 4.13 One Qt style for every app (global mode)

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

**Global mode tested** nested (KWin 6.8.2, scratch HOME; `loft qt global start|on|off|stop`
run by hand where the units would): a BreezeClassic baseline (`plasma-apply-colorscheme`,
`widgetStyle=Breeze`, Kvantum `theme=KvArc`); `on` → 109 kdeglobals keys + Kvantum's
theme, a running KWrite (and its context menu) re-skinned live; tokyonight → latte through
the `qt` hook re-skinned it again (`kvantum-dark` → `kvantum`); `stop`, and the Settings
switch off: Kvantum's file byte for byte as before and kdeglobals as before except the
`[KFileDialog Settings]` Kate's dialog wrote itself; the record gone.
### 4.13 A Space's apps under KWin: spin-up, display roles, capture

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
  - **starts** what's missing (`launch` not off) in its own process group, then sends
    the script `expectWindow` {pid, app id pattern, title, activity, output, open,
    ttl 20 s}. bridge.js, on `windowAdded`, takes the first window with that pid
    (else matching the app id / title), sets its activities to the Space's, sends it to
    the display (`workspace.sendClientToScreen`) and maximizes / fullscreens it if the
    app says `open`. The window is placed as it maps, before the shell sees it;
  - doesn't start an app again while its window is still coming (20 s), so two Opens in
    a row don't duplicate it;
  - answers `{"SpaceOpened": {space, activity, apps: [{app, display, window, spawn}],
    notes}}`; the notes become an island banner (as `space open`'s under niri).
- **When:** like niri. The first activation of a Space in the shell's life
  (`startup: first-activate`, the default; `Spaces.persist.opened`), **Open** in
  Settings → Spaces (switch + find + place + start), and `startup: login` Spaces once the
  Activities and the library are loaded (started in their Activity without switching:
  the script assigns the window's Activity, not the current one). Only Activities with
  Loft settings (a linked document, §4.2) have apps; a plain Activity starts nothing. A shell restart forgets
  what was opened; the next activation then finds the running apps and starts nothing.
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
- **IPC:** `spaces open <id|n>`, `spaces capture <name>` (besides Settings → Spaces).
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
  switched there; closing Kate and Open Desk started Kate maximized on WL-1. Not run:
  `startup: login` at a real login (its path, `openSpace` without focus, was), and real
  hardware with mixed sizes and a portrait display (roles come from the same code as
  `space list --displays`, unit-tested).

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
| KWin's popup fade (`fadingpopups`: 150 ms in, 600 ms out on every popup, so Loft's menus seemed to grow out of a corner) | `loft-kwin` unloads it at start (runtime only, nothing written to kwinrc) and loads it again on exit; the effects it took are noted in `$XDG_RUNTIME_DIR/loft/kwin-effects-off`, so a restart after a crash still gives them back, and an effect the user had off stays off |
| the global Qt style (`programs.loft.qt.global`, §4.13): kdeglobals `[KDE] widgetStyle`, `[General] ColorScheme` / `ColorSchemeHash`, the `[Colors:*]` / `[ColorEffects:*]` / `[WM]` keys of Loft's scheme; Kvantum's `[General] theme` | `loft qt global start` (`ExecStartPost`, only when on) records the user's values in `<state>/qt-global.prev`; `loft qt global stop` (`ExecStopPost`, and plasmashell's `ExecStartPre`) puts back every key still Loft's and deletes the ones that weren't set, with KConfig's change notification so running apps follow |
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
