# Loft on KWin: running the shell in a Plasma session

Status: **plan**. Step 1 (this doc) and step 2 (the `Compositor` seam, §2) are done.
The KWin backend itself is not written yet. The niri session is unchanged and stays
the default.

Goal: a KDE Plasma session (KWin as compositor, plus the KDE services) where Loft's
bar, dock, launcher and switcher replace plasmashell. Hosts that run niri, and Cody
until this is ready, keep the niri session.

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
| Menu bar + app menu: `menubar/MenuState`, `services/AppMenu`, `Arrange` | focused window, pid groups, close/float/fullscreen/move, hide = park on a `hidden-*` workspace | port. **Hide** becomes KWin minimize, not parking. Column items off. Floating presets map to `frameGeometry` |
| Dock: `dock/*`, `services/DockData`, `Previews`, `WindowCapture` | windows by app, move/close, workspace names, thumbnails | port windows and actions. Thumbnails fall back to icons (the path stock niri uses) until §4 capture exists |
| Switchers: `switcher/Switcher`, `SpaceSwitcher`, `palette/*` | window list by `focus_timestamp`, focus | port. The bridge stamps `focus_timestamp` on activation |
| Launchpad, Spotlight, panels' "which screen": `Launchpad`, `Panels`, `Hud`, `Sound`, `clipboard/*`, … (~20 files) | `focusedWorkspace.output` | port: needs the focused window's output, or the cursor's |
| Everyday / QuitGuard / QuitOnClose / KeepAwake / KeyRemaps / WindowRules (running check) | windows by pid / app_id, close | port |
| Capture: `capture/Capture`, `island/Island` | `screenshotWindow`, `screenshotTaken`, `shutter` | screen/area capture goes through grim today, which needs screencopy (KWin has none): switch to `org.kde.KWin.ScreenShot2` (§4) |
| Wallpapers: `WorkspaceWallpapers`, `VideoWallpapers`, `Vibes` | active workspace per output, overview | per-workspace wallpaper **surfaces** off (they need niri-loft's patch). The "one wallpaper per screen, swapped on switch" fallback works |
| Spaces: `services/Spaces`, settings pages | named niri workspaces per output, activated together by loft-niri | **off at first.** A Space later maps onto a KWin virtual desktop, which already spans every display (a better fit than niri, §4) |
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
| traffic-light title bars (`title-bar.patch`) | a KWin decoration: an Aurorae theme with macOS-style buttons is enough at first. Its minimize / window menu are native |
| per-workspace wallpaper surfaces (`workspace-layers.patch`) | off. One wallpaper per screen swapped on desktop change (the existing stock-niri path) under KWin's slide effect |
| window thumbnails (`toplevel-export.patch`) | icons first. Later stills via `ScreenShot2.CaptureWindow` (restricted: loft-kwin's .desktop needs `X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2`) |
| screen/area capture via grim | `ScreenShot2.CaptureScreen/CaptureArea`, or spectacle `-b -n` |
| keybinds (loft-niri → niri KDL binds) | kglobalaccel. Loft's own actions become KWin script `registerShortcut`s that run `quickshell ipc …`, or `.desktop` shortcuts in `kglobalshortcutsrc` |
| window rules (loft-niri window_rules.rs) | `kwinrulesrc`, written by a loft-kwin renderer, then `reconfigure` |
| outputs / Displays page | `kscreen-doctor` (or KScreen D-Bus). Identities from its JSON |
| overview (`toggle-overview`) | KWin's Overview effect |
| lock screen (`WlSessionLock`) | kscreenlocker (`loginctl lock-session`). KWin has no `ext-session-lock`, so Loft's lock UI is off |
| Spaces (named niri workspaces per output) | later: one virtual desktop per Space, with its wallpapers and dock. Desktops already span all displays, which is what a Space is |
| idle (swayidle on niri.service) | PowerDevil (Plasma's own idle and DPMS) |
| xremap per-app remaps (`xremap.niri`) | `xremap` built with its `kde` feature (it ships a KWin script for the focused app) |

**Off under KWin** (hidden with `Compositor.capabilities`): scrolling-column ops
(Maximize Column, column-width presets, consume/expel, center visible), niri's motion
and shape settings (KWin has its own animations), the niri sections of Settings
(keybinds-as-KDL, window-rule KDL preview), workspace-layer wallpapers, Loft's lock
screen, and Spaces until they're rebuilt on desktops.

## 5. A Plasma session with Loft instead of plasmashell

Plasma 6 starts through systemd: `plasma-workspace.target` wants
`plasma-kwin_wayland.service`, `plasma-plasmashell.service`, kded, polkit agent,
powerdevil and so on.

- **Mask plasmashell** for the user: link
  `~/.config/systemd/user/plasma-plasmashell.service` to `/dev/null`. In home-manager:
  `xdg.configFile."systemd/user/plasma-plasmashell.service".source = config.lib.file.mkOutOfStoreSymlink "/dev/null"`.
  That only affects Plasma sessions, because niri never starts it. What plasmashell
  carries that Loft must replace or leave alone:
  - notifications (`org.freedesktop.Notifications`): Loft's own, already there
  - the OSD service (`org.kde.osdService`): Loft's OSDs, already there
  - Klipper: Loft's clipboard
  - the system tray host: Loft's bar (the SNI watcher is in kded, which stays)
  - desktop icons and wallpaper: Loft's wallpaper layer
- **Bind Loft's units to KWin**, generalizing today's niri-only wiring in
  `nix/modules/home.nix` (`service`, `loftSessionUnits`, the `niri.service.d` drop-in):
  `PartOf`/`After`/`Requisite` and `WantedBy` on the *compositor unit*, which is
  `niri.service` or `plasma-kwin_wayland.service`. Requisite still keeps Loft out of
  any other desktop. The `ExecStopPost` drop-in goes on whichever unit applies. A new
  option such as `programs.loft.compositors = [ "niri" "kwin" ]` lists them. The
  shell picks its backend at runtime (`Compositor.session`), so one store path serves
  both sessions.
- **`findNiriSocket`** (the ExecStartPre that exports `NIRI_SOCKET`) must be a
  no-op when there's no niri. It already exits 0.
- **loft-appmenu vs Plasma's appmenu kded module:** both want
  `com.canonical.AppMenu.Registrar`. loft-appmenu already steps aside when another
  registrar owns it, and then it should read menus from the kded one. Check this.
- **swayidle** is wired to `niri.service`. Under Plasma, leave idle to PowerDevil.

## 6. Testing against KWin with loft-dev

Keep loft-dev's **headless sway host** and run KWin nested inside it in place of niri:

```sh
kwin_wayland --wayland-display "$host" --socket wayland-1 --width W --height H \
  --no-lockscreen --exit-with-session "quickshell --path $checkout/src"
```

- `loft-shot` (grim on the sway host) and `loft-input` (`zwlr_virtual_pointer` on the
  sway host) keep working unchanged, because they act on the host and KWin is just a
  window in it. A bare `kwin_wayland --virtual` would break both: KWin has no
  screencopy and no wlr virtual pointer. With `--virtual`, loft-input would need
  `org_kde_kwin_fake_input` or libei (KWin's EIS plugin) instead.
- `--output-count N` gives several outputs in the nested (windowed) backend, the KWin
  counterpart of `--outputs`.
- The session bus is already private (loft-dev's own dbus-daemon), so loading
  `loft-bridge.js` and calling `org.kde.KWin` there never touches the live Plasma.
- The flag becomes `loft-dev --compositor kwin`. `bind` maps to
  `kglobalaccel invokeShortcut`.
- Not checked yet: whether KWin's privileged-interface checks (ScreenShot2,
  plasma_window_management) can be relaxed for a dev session, or whether loft-kwin
  needs an installed .desktop file with `X-KDE-Wayland-Interfaces` /
  `X-KDE-DBUS-Restricted-Interfaces`.

## 7. Steps

1. ✅ This plan.
2. ✅ `Compositor.qml` in front of `Niri.qml`, every consumer moved, behavior under niri
   unchanged.
3. `crates/loft-kwin` + `loft-bridge.js` + `services/KWin.qml`: state only (windows,
   desktops, focus). Test with `loft-dev --compositor kwin`.
4. Actions + `capabilities` gating in menus. Hide → minimize.
5. Session wiring (§5) in the home-manager module, behind an option.
6. KWin-native replacements (§4) one at a time: decoration, keybinds, rules, displays,
   capture.
7. Spaces on virtual desktops.

## 8. Notes for the fleet flake (~/.flake, out of scope here)

- `settings.desktop.session = "kde"` needs Plasma 6 enabled *and* niri kept, so SDDM
  offers both sessions.
- A Loft-on-Plasma variant of `fleet.desktop._.loft` sets the new compositor option
  (§5), masks plasmashell, and must not enable `programs.niri`-only bits (swayidle on
  `niri.service`, `niri-loft-live`) for that session.
- xremap: `pkgs.xremap.kde` (or both features) on hosts that boot into Plasma.
- kwinrc defaults Loft wants: blur on, the Loft decoration theme, desktop count/names
  (or let loft-kwin manage them), Overview on a key, edge actions off.
