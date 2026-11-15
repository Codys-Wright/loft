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
| Spaces under KWin | **KDE Activities**: one Activity per Space (§4.2) |
| Lock screen | Plasma's locker (KWin has no `ext-session-lock`), **with Loft's lock design** as a shell package (§4.3) |
| Title bars | a **custom KWin decoration plugin** (KDecoration3, §4.4) |
| Wallpapers | one per screen, swapped with the desktop/activity. No per-workspace surfaces |
| Backing out | Loft and plasmashell must be **switchable**, live and at login, without leaving traces in each other (§5) |
| Window thumbnails | **icons first**. Thumbnails later through `ScreenShot2` |

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
workspaceNames, perOutputWorkspaces, titleBarEvents, configReload }`, all true under
niri. Nothing reads it yet. The KWin step gates menu items on it (e.g. MenuState's
"Maximize Column" and Arrange's column presets hide when `columns` is false).

### How the consumers map

| Area (files) | Uses | Under KWin |
|---|---|---|
| Bar: `bar/Workspaces`, `StatusItems`, `menubar/MenuBarTitles`, `components/WindowChrome` | workspaces per output, focused window title, layouts, overview | port: desktops, focused title, `org.kde.keyboard` |
| Menu bar + app menu: `menubar/MenuState`, `services/AppMenu`, `Arrange` | focused window, pid groups, close/float/fullscreen/move, hide = park on a `hidden-*` workspace | port. **Hide** becomes KWin minimize (decided): `hideApp`/`hideOthers`/`showAll` and the dock's unhide go through a `Compositor.setMinimized(id, bool)` the KWin backend adds, and the `hidden-*` parking stays niri-only. Column items off. Floating presets map to `frameGeometry` |
| Dock: `dock/*`, `services/DockData`, `Previews`, `WindowCapture` | windows by app, move/close, workspace names, thumbnails | port windows and actions. Thumbnails fall back to icons (the path stock niri uses) until §4 capture exists |
| Switchers: `switcher/Switcher`, `SpaceSwitcher`, `palette/*` | window list by `focus_timestamp`, focus | port. The bridge stamps `focus_timestamp` on activation |
| Launchpad, Spotlight, panels' "which screen": `Launchpad`, `Panels`, `Hud`, `Sound`, `clipboard/*`, … (~20 files) | `focusedWorkspace.output` | port: needs the focused window's output, or the cursor's |
| Everyday / QuitGuard / QuitOnClose / KeepAwake / KeyRemaps / WindowRules (running check) | windows by pid / app_id, close | port |
| Capture: `capture/Capture`, `island/Island` | `screenshotWindow`, `screenshotTaken`, `shutter` | screen/area capture goes through grim today, which needs screencopy (KWin has none): switch to `org.kde.KWin.ScreenShot2` (§4) |
| Wallpapers: `WorkspaceWallpapers`, `VideoWallpapers`, `Vibes` | active workspace per output, overview | per-workspace wallpaper **surfaces** off (they need niri-loft's patch). The "one wallpaper per screen, swapped on switch" fallback works |
| Spaces: `services/Spaces`, settings pages | named niri workspaces per output, activated together by loft-niri | **KDE Activities** (decided, §4.2). Off until that lands |
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
| window thumbnails (`toplevel-export.patch`) | **icons** (decided, the existing stock-niri fallback). Later stills via `ScreenShot2.CaptureWindow` (restricted: loft-kwin's .desktop needs `X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2`) |
| screen/area capture via grim | `ScreenShot2.CaptureScreen/CaptureArea`, or spectacle `-b -n` |
| keybinds (loft-niri → niri KDL binds) | kglobalaccel, **done** (§4.5): `loft-keys.js`, a KWin script of `registerShortcut`s generated from shell-binds + Settings → Keyboard Shortcuts, loaded while Loft's shell runs (§5) |
| window rules (loft-niri window_rules.rs) | applied by loft-bridge.js at `windowAdded` while Loft runs, not written to `kwinrulesrc` (§5) |
| outputs / Displays page | `kscreen-doctor` (or KScreen D-Bus). Identities from its JSON |
| overview (`toggle-overview`) | KWin's Overview effect |
| lock screen (`WlSessionLock`) | Plasma's locker with **Loft's lock design** (§4.3) |
| Spaces (named niri workspaces per output) | **KDE Activities** (§4.2) |
| idle (swayidle on niri.service) | PowerDevil (Plasma's own idle and DPMS) |
| xremap per-app remaps (`xremap.niri`) | **done**: `loft-plasma-keys.service` runs `xremap.kde` (its KWin script reports the focused window's `resourceClass`, the Wayland app id) on the same config (§4.5) |

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

### 4.2 Spaces = KDE Activities

An Activity is a set of windows (plus its own desktops, wallpaper and settings) that
switches as one across **every** display. That is what a Space is (SPACES.md §1),
without having to activate several per-output workspaces together.

- **API:** `org.kde.ActivityManager /ActivityManager/Activities`: `ListActivities`,
  `ListActivitiesWithInformation`, `AddActivity`, `RemoveActivity`, `SetActivityName`,
  `SetCurrentActivity`, `CurrentActivity`, signals `CurrentActivityChanged`,
  `ActivityAdded/Removed`, `ActivityNameChanged` (checked on this machine). In the KWin
  script: `workspace.activities`, `workspace.currentActivity`, `window.activities`
  (settable), `workspace.currentActivityChanged`.
- **Mapping:** a Space (singleton or template instance) gets one Activity. loft-kwin
  keeps a `space id ↔ activity uuid` map in Loft's state dir. `Spaces.focus` becomes
  `SetCurrentActivity`. A spin-up launches the Space's apps and the bridge tags them
  with `window.activities = [uuid]`. Display **roles** (main/left/right…) become
  per-window placement (`sendClientToScreen`) at `windowAdded`, from the same role
  resolution loft-niri does today (shared Rust code).
- **Per-Space look:** wallpaper, dock set and theme key off the current activity
  instead of named workspaces. The wallpaper path is the per-screen swap above.
- **The shell's model:** `Compositor` gains `activities` / `currentActivity` and
  windows gain `activities: [uuid]`. Under niri it reports no activities, and Spaces
  keeps using loft-niri. `Spaces.qml` picks its engine from `Compositor.backend`.
- **Backing out (§5):** activities Loft created stay in Plasma and are harmless there
  (plasmashell shows them in its Activities switcher). `loft spaces prune` removes them.

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

- **Look: macOS 26 Tahoe's title bar**, numbers taken from the MacTahoe KDE theme's
  Aurorae decoration (a careful copy of Tahoe's) and cited in `kdecoration/tahoe.h`: a
  34 px bar (what Aurorae draws for MacTahoe's rc: 8 + 16 + 2 button margin + 8), 14 px
  beads 26 px apart (centres at x 24/50/76, y 18), the beads' exact light / dark fills and
  rims, grey when the window is in the background, 24 px corners (top and bottom), a 1 px
  frame with Tahoe's white highlight (dark: all around), a 1 px black outline outside
  the frame (KWin's border outline, crisp at any scale), and Tahoe's shadow (fitted to
  MacTahoe's rendered shadow: strength · (1 − d / reach)^1.5 per side, reaches = the rc's
  shadow paddings). Glyphs are MacTahoe's SVG paths (×, −, the two-triangle zoom glyph,
  inward triangles when maximized). Where Aurorae can't do what macOS does, it follows
  macOS: pointing at the button group (gaps included) shows all three glyphs and lights
  the beads of a background window too; the title is centred on the window, 13 px
  semibold in the KDE title font's family; bottom corners are rounded. Not done: the
  Option-key "+" on green (KWin gives decorations no modifier state, input.cpp builds
  their hover events without it).
- **Theme:** the `kdecoration` render unit (`cli/loft/render/kdecoration.py`,
  `templates/render/kdecoration.ini`) writes `<state>/current/kdecoration.ini` with only
  `[General] Appearance=light|dark` (the colors' polarity): the traffic lights are fixed
  colors, as on macOS, and the bar, text and grey beads are Tahoe's for that appearance.
  A hand-written file may still override `[Colors]` TitleBarActive / TitleBarInactive /
  TextActive / TextInactive (`#rrggbb[aa]`, Loft's order) and `[Metrics]` CornerRadius /
  TitleBarHeight / FontSize. The plugin reads it from `$LOFT_STATE_DIR`, else
  `$XDG_STATE_HOME/loft`, else `~/.local/state/loft`, watches the file, `current/` and the
  state dir (the theme engine swaps the `current` link), and repaints open windows on
  change. Without the file it is Tahoe dark.
- **Behavior is KWin's:** the buttons are KDecoration's own Close / Minimize / Maximize
  (minimize is real, = Hide, §4.1; green toggles maximize, middle-click vertical,
  right-click horizontal). Right-click on the bar opens KWin's window menu at the
  pointer. Double-click on the bar zooms (maximizes) whatever KWin's title-bar action is,
  as on macOS; drag and the other title-bar actions are KWin's settings.
  Not done: fullscreen on a modifier+green, long-press green, and Loft's own window
  menu through `dev.loft.KWinBridge`.
- **Selected only while Loft runs** (§5): `loft-kwin-decoration apply` (the
  `ExecStartPost` of `loft-plasma-shell.service`) records the user's own kwinrc
  `[org.kde.kdecoration2] library` / `theme` in `<state>/kwin-decoration.prev` (a key
  only set in `/etc/xdg` is recorded as unset), selects Loft's and calls
  `org.kde.KWin.reconfigure`. `revert` (`ExecStopPost`, so a crash reverts too) puts
  the recorded values back, deleting keys that weren't set, unless the user picked
  another decoration meanwhile. `apply` does nothing when the plugin isn't installed.
  KWin 6.8 still reads the group `org.kde.kdecoration2` (the plugins' namespace is
  `org.kde.kdecoration3`).
- **Compared** pixel by pixel with MacTahoe-Light/Dark (Aurorae, border size Tiny) in a
  nested session: same kwrite windows, focused / background / hovered, light and dark,
  1x / 1.25x / 1.5x (`loft-dev --kwin-scale`). Build the plugin against the system's
  nixpkgs (`--override-input nixpkgs nixpkgs`) or KWin won't load it, and pass it with
  `--kwin-env QT_PLUGIN_PATH=<build>/lib/qt-6/plugins:$QT_PLUGIN_PATH` (first wins).
- **Tested** nested (§6, plugin on `QT_PLUGIN_PATH`, scratch HOME): two foot windows,
  focus / unfocus, hover glyphs, the window menu, maximize / restore, minimize, close,
  a live theme swap (tokyonight → latte) and metric edits, and apply / revert with the
  user's Breeze and with no key set.

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
   Plasma that is 14 actions: KWin's Walk Through Windows (Meta+Tab), Close Window
   (Alt+F4), Switch One Desktop ← → ↑ ↓ (Meta+Ctrl+arrows), Switch Window ← →
   (Meta+Alt+←/→), Present Windows (Meta+F10), Activate Window Demanding
   Attention (Meta+Ctrl+A), System Settings (Meta+I), Emoji Selector (Meta+.),
   Spectacle region recording (Meta+Shift+R).
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
KWin), so `Mod+X` and `Super+X` twins become one shortcut. niri keysyms map to
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

**Verified** in a nested KWin 6.8.2 (private bus, scratch HOME; a stand-in for
systemd's `StartUnit` on the private bus that runs the real `loft-plasma-key`
dispatcher): all 42 shortcuts register with the expected keys; real key presses
(virtual keyboard into the host) open the Control Center (Meta+A), the Capture
bar (Meta+Shift+5), the Island (Meta+I, after claim), the switcher, Spaces,
emoji; unload leaves kglobalshortcutsrc as before. xremap-kde's KWin script
loads and reports `org.kde.dolphin` for a Dolphin window. **Not run:** the
systemd template itself (no user systemd on the private bus), xremap-kde against
input devices (it would grab the real keyboard), the quit guard's hold, the
Radial Menu's hold (KWin shortcuts have no repeat/release semantics like niri's
`repeat=false`), and conflicts with plasmashell's own shortcuts (Meta+Q
activities etc.: same mechanism, not present in the scratch session).

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
| the decoration (`[org.kde.kdecoration2] library/theme` in kwinrc) | `loft-kwin-decoration apply` (loft-plasma-shell's `ExecStartPost`) records the previous value in Loft's state dir and sets Loft's. `loft-kwin-decoration revert` (`ExecStopPost`) puts it back. Both run `org.kde.KWin.reconfigure` (§4.4) |
| Loft's shortcuts (`loft-keys.js`, §4.5) and the keys taken from other shortcuts | `loft-plasma-shortcuts unload` (`ExecStopPost` of loft-plasma-shell): script unloaded, Loft's actions unregistered, taken keys given back from `<state>/kwin-shortcuts-taken.json` (plasmashell's start does the last part too) |
| any other kwinrc key Loft needs (blur strength, effects) | the same record / revert list. Nothing outside it is touched |
| the lock screen | `PLASMA_DEFAULT_SHELL` only in KWin's environment, and only when the login is Loft's (`loft-plasma lock-env`, §4.3). Lock and unlock stay Plasma's either way |
| activities created for Spaces | kept (harmless). `loft spaces prune` removes them |

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
9. Keybinds, display settings, capture through ScreenShot2.
10. Spaces on Activities (§4.2).
11. Window thumbnails through ScreenShot2.

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
