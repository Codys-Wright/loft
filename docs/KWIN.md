# Loft on KWin: running the shell in a Plasma session

Status: **plan**. Step 1 (this doc) and step 2 (the `Compositor` seam, §2) are done.
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
| keybinds (loft-niri → niri KDL binds) | kglobalaccel. Loft's own actions are `registerShortcut`s in loft-bridge.js that run `quickshell ipc …`, so they exist only while Loft runs (§5) |
| window rules (loft-niri window_rules.rs) | applied by loft-bridge.js at `windowAdded` while Loft runs, not written to `kwinrulesrc` (§5) |
| outputs / Displays page | `kscreen-doctor` (or KScreen D-Bus). Identities from its JSON |
| overview (`toggle-overview`) | KWin's Overview effect |
| lock screen (`WlSessionLock`) | Plasma's locker with **Loft's lock design** (§4.3) |
| Spaces (named niri workspaces per output) | **KDE Activities** (§4.2) |
| idle (swayidle on niri.service) | PowerDevil (Plasma's own idle and DPMS) |
| xremap per-app remaps (`xremap.niri`) | `xremap` built with its `kde` feature (it ships a KWin script for the focused app) |

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

KWin can't host Loft's `WlSessionLock`, but Plasma 6's greeter is themeable.
`kscreenlocker_greet` (6.8.2) loads `contents/lockscreen/LockScreen.qml` from a
Plasma **shell package**, picked by `PLASMA_DEFAULT_SHELL` (default
`org.kde.plasma.desktop`, whose lockscreen dir is `LockScreen.qml`, `LockScreenUi.qml`,
`MainBlock.qml`, …). It also has `--testing --theme <package>` for previews.

- Ship **`dev.loft.desktop`**, a shell package that contains only `lockscreen/` and
  falls back to `org.kde.plasma.desktop` for everything else (KPackage fallback). Its
  `LockScreen.qml` wraps `src/lock/design`, the same way `nix/lock.nix` already builds
  the SDDM theme from it (`qs.*` imports rewritten, a stand-in `Theme.qml`). It talks to
  the greeter's `authenticator` instead of PAM directly. The theme colors come from
  Loft's rendered theme, as for SDDM.
- Set `PLASMA_DEFAULT_SHELL=dev.loft.desktop` **only on `plasma-kwin_wayland.service`**
  (a drop-in). The greeter is a child of KWin, so the lock screen changes and
  plasmashell's own shell choice doesn't.
- Lock, unlock, idle and sleep all stay Plasma's (kscreenlocker + PowerDevil), so a
  broken Loft can never leave the session unlockable: if the package fails to load,
  the greeter falls back to Breeze's.
- Preview: `kscreenlocker_greet --testing --theme dev.loft.desktop`, as
  `nix run .#greeter-preview` does for SDDM.
- To check: whether the greeter honors a user-installed package from
  `~/.local/share/plasma/shells`, or it has to be in the system profile's `share/`.

### 4.4 Loft's KWin decoration

A KDecoration3 plugin (`libkdecorations3`, 6.8.2 here), in C++, built in the flake
against the system's kdecoration. Call it `dev.loft.decoration`.

- **Look:** macOS-style traffic lights (close, minimize, maximize), a centered title,
  the corner radius and colors from Loft's theme. The theme engine gets a `kdecoration`
  render unit that writes a small INI the plugin watches (reload on change, as
  ghostty.conf works today). Focused/unfocused states, with glyphs on hover.
- **Behavior is KWin's:** minimize is real (= Hide, §4.1), green = maximize, or
  fullscreen with a modifier. Long-press green or right-click the title opens a menu.
  First KWin's window menu; later Loft's (the plugin calls `dev.loft.KWinBridge`,
  which forwards to `windowActionsMenuRequested`).
- **Selected at runtime only while Loft runs** (§5). Under plasmashell, Breeze comes
  back.
- Fallback until it exists: an Aurorae theme with the same buttons.

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
| the decoration (`[org.kde.kdecoration2] library/theme` in kwinrc) | `loft-kwin apply` records the previous value in Loft's state dir and sets Loft's. `loft-kwin revert` (on stop) puts it back. Both run `org.kde.KWin.reconfigure` |
| any other kwinrc key Loft needs (blur strength, effects) | the same record / revert list. Nothing outside it is touched |
| the lock screen | `PLASMA_DEFAULT_SHELL` only on KWin's unit, set by the session option. Lock and unlock stay Plasma's either way |
| activities created for Spaces | kept (harmless). `loft spaces prune` removes them |

Loft never writes `plasma-org.kde.plasma.desktop-appletsrc`, `plasmashellrc` or
`kwinrulesrc`, so plasmashell comes back with your panels as you left them.

**Also in the module:** `findNiriSocket` is already a no-op without niri. swayidle
stays bound to `niri.service`, and Plasma uses PowerDevil. loft-appmenu already steps
aside when Plasma's appmenu kded module owns `com.canonical.AppMenu.Registrar`.
Whether menus then still reach Loft's bar needs checking.

## 6. Testing against KWin with loft-dev

**Verified on 2026-11-15** (KWin 6.8.2, prototype scripts, not in the repo yet): a
whole KDE session runs nested and headless, the same way loft-dev runs niri. Both
stock **plasmashell** (panel, tray, dock, wallpaper) and **Loft's shell** (bar,
island, dock) drew in it and were screenshotted with grim on the host.

```sh
# 1. headless sway host, rendered on a GPU render node (as `loft-dev --gpu` does)
XDG_RUNTIME_DIR=$dir/host WLR_BACKENDS=headless WLR_RENDERER=gles2 \
  WLR_RENDER_DRM_DEVICE=/dev/dri/renderD129 sway -c host.conf &
# 2. KWin nested in it: private bus, private runtime dir, scratch HOME and XDG dirs
env HOME=$scratch XDG_CONFIG_HOME=$scratch/.config XDG_DATA_HOME=… XDG_CACHE_HOME=… \
    XDG_STATE_HOME=… XDG_RUNTIME_DIR=$dir/run WAYLAND_DISPLAY=$dir/host/wayland-1 \
    XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true KDE_SESSION_VERSION=6 \
  dbus-run-session -- kwin_wayland --width 1600 --height 1000 --socket kde-1 \
    --xwayland --no-lockscreen --exit-with-session session.sh
# session.sh: kactivitymanagerd & kded6 & then the shell under test:
#   plasmashell                                          (stock Plasma)
#   LOFT_SHELL_SRC=$checkout/src LOFT_DEV=1 loft-shell   (Loft, hot reload)
```

What the prototype showed:

- **The host needs a GPU renderer.** With loft-dev's default pixman host, KWin's
  wayland backend quits ("The used windowing system requires compositing").
  `KWIN_COMPOSE=Q` doesn't help. So `--compositor kwin` implies `--gpu`. It's still
  headless: no monitor, no modeset.
- **`$HOME` must be scratch, unlike niri sessions.** plasmashell, KWin, kded and
  Akonadi write their config on startup (`kwinrc`, `plasma-…-appletsrc`,
  `kglobalshortcutsrc`, an Akonadi MariaDB). With the real `$HOME` that would rewrite
  your Plasma setup. With `HOME` + XDG dirs pointed at scratch, nothing outside it
  changed. Defaults still come from the system profile (`/etc/xdg`), so the nested
  Plasma looks like the machine's Plasma.
- **Run it in one transient unit** (`systemd-run --user --unit=loft-dev-kwin-NAME`).
  D-Bus activation starts many helpers (portals, gvfs FUSE mounts under the runtime
  dir, at-spi, Akonadi). Stopping the unit stops them all and its FUSE mounts go with
  them. Never clean up with `pkill -f`.
- `loft-shot` works unchanged (grim on the host). `loft-input` should too (the wlr
  virtual pointer goes to the host, and KWin is a window in it), but that isn't tried
  yet. A bare `kwin_wayland --virtual` would break both: KWin has no screencopy and no
  wlr virtual pointer.
- Plasma-session services that `startplasma-wayland` normally starts, and the
  prototype didn't: ksmserver, powerdevil, polkit agent, xdg-desktop-portal-kde
  (D-Bus activated anyway). Add them when a test needs them.
- `--output-count N` gives several outputs in the nested (windowed) backend, the KWin
  counterpart of `--outputs` (not tried yet).

**Proposed loft-dev interface:**

```sh
loft-dev --session NAME --compositor kwin [--shell loft|plasma] [CHECKOUT]
```

- `--shell loft` (default) runs the checkout's shell. `--shell plasma` runs stock
  plasmashell in the same harness, to compare with plain Plasma, or to test the §5
  switching (`loft shell use …` inside the session).
- session.env gains `LOFT_DEV_COMPOSITOR=kwin`, so `loft-shot` / `loft-input` /
  `loft-dev --stop` know the session. `bind` maps to kglobalaccel's `invokeShortcut`.
- The scratch tree lives in the session dir, and `--keep-home` keeps it between runs.
- Still open: whether KWin's privileged-interface checks (ScreenShot2,
  plasma_window_management) can be relaxed for a dev session, or whether loft-kwin
  needs an installed .desktop file with `X-KDE-Wayland-Interfaces` /
  `X-KDE-DBUS-Restricted-Interfaces`.

## 7. Steps

1. ✅ This plan.
2. ✅ `Compositor.qml` in front of `Niri.qml`, every consumer moved, behavior under niri
   unchanged.
3. `loft-dev --compositor kwin [--shell loft|plasma]` (§6), so every later step can be
   tested headless like niri sessions.
4. `crates/loft-kwin` + `loft-bridge.js` + `services/KWin.qml`: state only (windows,
   desktops, focus, minimized).
5. Actions + `capabilities` gating in menus. Hide → minimize.
6. Shell switching (§5): units, `loft shell use`, the SDDM "Plasma (Loft)" entry, the
   fallback unit, `loft-kwin apply/revert`. This comes **before** daily use, so
   backing out works from day one.
7. Decoration plugin (§4.4), with the Aurorae stand-in until it lands.
8. Lock screen shell package (§4.3).
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
- Leave kwinrc to the user. Loft applies its keys at runtime and reverts them (§5).
  The flake shouldn't bake the Loft decoration into kwinrc, or plain Plasma would get
  it too.
