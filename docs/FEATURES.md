# Feature map — vorssaint-utils parity

[vorssaint-utils](https://github.com/vorssaint/vorssaint-utils) is a macOS all-in-one
menu-bar utility. It is not installed anywhere; it's the checklist for what our shell
should grow into, the Linux/niri way. Status: **have** · **partial** · **todo** ·
**niri** (niri or the niri settings pages already cover it) · **n/a** (doesn't apply
on Linux/Nix, with the reason).

Every feature is a module the user can switch on/off in Settings → Features (the
"install only what you use" hub, below). Waves group the work so modules can be built
in parallel without touching each other.

## Sound — wave 1 (audio)
| Feature | Status | How (Linux) |
|---|---|---|
| Volume mixer per app, boost > 100 % | have | `mixer`: glass panel (bar volume right-click, CC chevron, `mixer toggle`); app streams grouped per app (filters/loopbacks/meters hidden), up to 150 %, mute, live levels, favorites pinned in the mixer and reordered in Settings → Sound |
| Per-app output | have | mixer: per-app output list → `pw-metadata <stream> target.object <sink>` (delete = follow the default); the row says where it plays when not the default |
| Output switcher + volume drop on headphone unplug | have | `audioOutputs`: picker in CC (click the device name), mixer and Settings; Mod+Shift+O / `audio nextOutput`; OSD "Output: …"; when headphones/Bluetooth vanish the new output drops to a safe volume (setting) |
| Microphone tools (preferred input, level, mute all) | have | `micTools`: input picker + level (mixer, Settings), mute all (Mod+Shift+M / `mic toggleMute`, OSD), bar mic while an app records (amber) or muted |
| Music app blocker | n/a | macOS media-key quirk |

## Know what the system is doing — wave 1 (system)
| Feature | Status | How |
|---|---|---|
| System monitor (CPU/GPU/mem/temps, history graphs, energy-hungry apps) | have | `systemMonitor`: SystemStats ring buffers (5 min) → Canvas graphs in a glass window (island "Open Monitor", bar readouts, `monitor toggle`, Ctrl+Shift+Esc); top processes from /proc/<pid>/stat + status (only while open) with Quit / Force Quit after a confirm |
| Fan control | partial (read-only) | every hwmon `fan*_input` RPM + temps on Disks & Sensors, NVIDIA fan % via nvidia-smi; control via `pwm*` is hardware-specific → later |
| Menu bar readouts | have | `barReadouts`: CPU, RAM, CPU temp, GPU, net up/down, battery (when present) in the status pill; chosen in Settings → System |
| Network (live traffic, totals, local IP, speed test) | have | `network`: /proc/net/dev (physical interfaces summed), session totals, `ip -j addr`, librespeed-cli on button press |
| Alerts (sustained load, temps, memory pressure, low disk, low battery) | have | `alerts`: island banners with hold time, hysteresis and a 10 min cooldown; PSI memory pressure, `df` every 5 min (re-alerts only when another fs fills), UPower; thresholds in Settings → System |

## Menu bar — wave 1 (menu bar)
| Feature | Status | How |
|---|---|---|
| App menu for every app (macOS ⌘-menu) | have | click the bold app name or Mod+F10 (`src/menubar/`): About, New Window + `.desktop` actions, Move to Workspace ▸ / Display ▸, Float/Tile, Full Screen, Maximize Column, Center, Hide / Hide Others / Show All (parking workspace `hidden-<output>`: niri has no minimize), Close Window, Quit (closes every window, confirms when several, optional SIGTERM after 3/10 s). Hold-to-quit: todo |
| Global menu (File / Edit / View … in the bar) | have | `loft-appmenu` (crates/loft-appmenu): owns `com.canonical.AppMenu.Registrar` (never replaces another one, e.g. Plasma's), matches the focused window by pid (niri has no appmenu protocol) — registrar entries, then introspection of the process's bus connections, and `_NET_ACTIVE_WINDOW` for X11 windows. Reads DBusMenu (Qt/KDE, Electron on X11) and `org.gtk.Menus` (GtkApplication menubars). Verified: Qt/KDE (Kate, KCalc, PyQt), GTK3 GtkApplication (Mousepad, gtk3-demo-application), Electron under XWayland (needs libdbusmenu-glib). No: GTK4/libadwaita apps without a menubar (Text Editor), Firefox, Electron on Wayland |
| Desktop right-click menu | have | `desktopMenu` (`src/desktopmenu/`): right-click the wallpaper (a click on no window) → a glass menu at the pointer on that display, drawn with the bar menus' MenuPanel (submenus, keyboard, Esc / click outside; a right-click elsewhere moves it). Change Wallpaper…, Wallpaper ▸ (next / previous / shuffle in the theme's vibe set, matching suggestions with thumbnails, Browse Library…; with several displays the choice is for the clicked display, plus Use on All Displays), Theme ▸ (every installed theme grouped Built-in / Cozytile / Qylock with a palette swatch, current checked, scrolls; applies via `loft theme apply`), Appearance ▸ (Light / Dark when the pack has an `-dark`/`-light` sibling, Liquid Glass ▸ Clear / Default / Tinted, Reduce Transparency, Show Menu Bar Background), Display / Dock Settings…, Control Center, Notification History (the clock extra's calendar + notifications panel), Screenshot ▸, Open Terminal Here, Lock Screen, System Settings…, Edit Menu… (Settings → Desktop Menu: show / hide / reorder items and separators, `Settings.desktopMenu.items`). Items of switched-off modules drop out. IPC `desktopmenu open\|theme\|appearance\|wallpaper\|state\|down\|…`. Per-display dock show / auto-hide: todo (needs per-display dock settings) |

## Menu bar extras (top right) — wave 2 (status)
macOS's own status items (vorssaint has none of these — macOS ships them), plus
vorssaint's readouts/sound tools that already exist, in one style: a monochrome
icon in the bar → a glass dropdown under it (one open at a time; hovering another
extra or an app-menu title switches to it, like real menus; arrow keys move along
the bar too), scroll on the icon where it makes sense, ⌥-click (Alt-click) for
details, "… Settings" at the bottom opens the Settings page. Every extra is a
**control** (`src/services/Controls.qml`) — the same model as the Control
Center, so each can live in the bar, the CC, or both; each panel is one shared
component (`src/controls/*Panel.qml`) used by the dropdown and the CC's expanded
module. IPC: `extras wifi|wifiDetails|bluetooth|sound|soundDetails|nowPlaying|focus|display|battery|clock|camera|inputSource|overflow|details|close|up|down|left|right|enter`.

| Feature | Status | How |
|---|---|---|
| **Wi-Fi / network extra** — icon: signal bars, ethernet, offline, VPN badge | have | Quickshell `Networking` (NetworkManager): Wi-Fi switch; current network; known + other networks (scan only while shown); click to join, inline password for new secured networks (join timeout → "couldn't join"); "Other Network…" (hidden SSID, `nmcli … hidden yes`); every wired link (connection name, speed, cable state) and VPNs — tun/WireGuard links such as Tailscale ("connected (externally)", shown not toggled) and NM VPN/WireGuard profiles (click = up/down); ⌥: IP, IPv6, router, DNS, MAC, security, BSSID, channel/band, rate, signal; live traffic line. `nmcli` (read-only, refreshed on `nmcli monitor`) fills what Quickshell doesn't model |
| **Bluetooth extra** — icon shows on / connected / off | have | Quickshell `Bluetooth` (BlueZ): switch; paired devices (connected first) with type disc and battery % (Battery1); click = connect/disconnect; "Nearby Devices" (discovery only while that list is open and the menu shown; stopped only if we started it) → pair, then trust + connect; ⌥: address, RSSI (busctl), trusted; low-battery banner for headsets/mice/keyboards at ≤ 15 % (with `alerts`, re-arms above 25 %) |
| **Sound extra** — icon reflects volume / headphones / muted | have | output slider (+ scroll on the icon, middle-click mute, right-click mixer — the old bar volume item folded in), outputs (Bluetooth ones with battery, matched by `api.bluez5.address`), Mixer ›, "Sound Settings…"; ⌥: inputs + mic level (only with Settings → Sound level meters, or "Show level" — it opens a capture stream), and the PipeWire clock: current rate · quantum · latency with quick switching (Auto / 44.1–96 kHz from `clock.allowed-rates`, Auto / 64–1024 frames) via `pw-metadata -n settings 0 clock.force-rate|clock.force-quantum` (Auto writes 0). IPC `pwclock rate N|quantum N|auto|status` |
| Now Playing extra (optional) | have (off in the bar by default) | MPRIS cards: art, title/artist, transport, scrubber (seek); every player |
| Battery extra (only when a battery exists) | have | UPower: %, time remaining / to full, power source, power mode (power-profiles-daemon), busiest apps when known (`systemMonitor` sampling) |
| Clock in the bar (optional) | have | the date as before; Settings → Menu Bar → Clock adds the time (12/24 h); click → calendar + recent notifications |
| Focus / Do Not Disturb indicator | have | moon while DND or a focus timer is on ("only when active" by default); menu: DND, focus for 25 / 50 min |
| Recording indicator | have | while the Recorder runs: a red stop square + elapsed — click stops |
| Camera-in-use indicator | have | green dot while a camera is used: PipeWire Video/Source links + processes holding `/dev/video*` (read-only /proc scan every 4 s while the indicator is on); menu lists who uses the camera and the mic |
| Input source (keyboard layout) | have | only with more than one xkb layout (niri `KeyboardLayoutsChanged`); short name in the bar, menu switches (`SwitchLayout`) |
| Spotlight icon | have | magnifier → `loft-launcher open` |
| Control Center | have | the toggles icon (rebuilt, see below) |
| Menu bar readouts (CPU, RAM, temps, net, battery) | have | `barReadouts` (off by default); each readout is its own bar item |
| **Arrange the extras** (Bartender / Ice / Golden Gate) | have | Settings → Menu Bar: show/hide, reorder (↑/↓) and "only when active" for every control and readout; tray (StatusNotifier) icons pinned or tucked behind », drawn as monochrome templates in the bar's color (symbolic icons as an alpha-mask fill; opaque icons — badges, full squares — as luminance-preserving grayscale so their detail survives; per item "In color"); tray apps that duplicate a Loft control (blueman → Bluetooth, nm-applet → Wi-Fi, pasystray/pavucontrol → Sound) start tucked behind » while that control is in the bar, overridable per item; items that don't fit move behind the same » (leftmost first); Super-drag a status item along the bar to move it or off the bar to remove it. Persists in `Settings.menubar.bar` |

## Control Center — wave 2 (status)
macOS Golden Gate's Control Center (`src/controlcenter/`), anchored top-right under
the bar on the display with the status area. Layout in `Settings.controlCenter.layout`.

| Feature | Status | How |
|---|---|---|
| Module grid (1×1, 2×1, 2×2, 4-wide rows) | have | 4-column cell grid, first-fit packing; default close to macOS: Connectivity, Focus, Keep Awake, Night Light, Display, Sound, Now Playing, Screenshot, Screen Recording, Microphones, Lock, Overview, Displays, Clipboard, Spotlight |
| Connectivity (Wi-Fi, Bluetooth, Nearby share) | have | discs toggle, labels expand in place into the shared Wi-Fi / Bluetooth panels; Nearby = LocalSend or KDE Connect when installed (else hidden) |
| Expand in place | have | the module's rect grows into the panel (one curve for open, close and expand); "‹ Control Center" or Esc/← backs out |
| Display | have | brightness (backlight via brightnessctl, external monitors via ddcutil DDC/CI; hidden when nothing is adjustable) → per display, Night Light, Dark/Light appearance when the theme has an installed counterpart of the other polarity (same family name) |
| Sound, Focus, Now Playing | have | slider row → outputs + mixer; DND + focus timers; all MPRIS players |
| Small controls | have | Keep Awake, Night Light, Power Mode, Focus Timer, Screenshot, Screen Recording (elapsed while active), Microphones (mute all), Lock, Overview, Displays, Clipboard, Color Picker, Spotlight — only those whose feature is on |
| Calendar | have (gallery, off by default) | the old CC calendar as a 2×2 control |
| Edit Controls | have | Done-style edit state: drag to reorder, − removes, ⤢ cycles sizes; the gallery (grouped like Features) adds controls and pins them to the menu bar ("Menu Bar") |
| Keyboard | have | arrows between modules, Space toggles, Enter / → expands, Tab cycles, Esc backs out then closes |
| IPC | have | `controlcenter toggle|close|wifi|bluetooth|sound|display|focus|nowPlaying|back|edit` |

## Windows and the dock — wave 2 (windows)
| Feature | Status | How |
|---|---|---|
| App switcher with previews/search | partial (icons) | niri has no window thumbnails API → titles + search; previews later via screencast |
| Window layout snapping, move between displays, restore | partial (niri binds) | layout presets → niri actions (column width, maximize, move-to-monitor); a snap menu |
| Dock menus (right-click / Ctrl-click / long-press an icon) | have | `src/dock/DockMenu.qml`, drawn by the menu bar's cascade (MenuState.openContext → MenuOverlay/MenuPanel, same glass and keys): the app's windows (✓ focused, ◇ hidden; click focuses across workspaces/outputs), Recent files, Open / New Window + `.desktop` actions, Options ▸ (Keep in Dock, Open at Login, Show in Files, Assign To, Move to Desktop ▸ / Display ▸), Show All Windows (overview), Hide / Hide Others / Show All (parking workspace), Quit (confirm when several windows; hold Alt → Force Quit = SIGKILL), Remove from Dock. Right-click the shelf: Automatically Hide ▸, Magnification, Position ▸, recent apps, Dock Settings… |
| Dock preview (hover → windows, switch/close/move) | partial | the right-click menu lists the windows (focus, move); no hover popover or thumbnails (niri has no window thumbnails API) |
| Dock clicks (minimize/hide/cycle) | have | click focuses, again cycles the app's windows; a hidden app comes back whole; launching bounces until the first window; files dropped on an icon open with that app |
| Recent files per app | have | `loft dock recents`: `recently-used.xbel` matched by the program that opened each file (file managers record it in `exec`), then the app's default MIME types; VS Code (`state.vscdb`) and Zed (`db.sqlite`) recent workspaces; re-read when the xbel changes |
| Open at Login | have | XDG autostart: a copy of the app's entry marked `X-Loft-OpenAtLogin` (others' entries are shadowed with `Hidden=true`, never deleted); started once per niri session by the shell unless `xdg-desktop-autostart.target` is active |
| Assign To (desktop) | partial | This Desktop / None → a niri `window-rule { open-on-workspace }` in overrides/niri.kdl (loft-niri `window_rules`); an unnamed workspace is named "Desktop N" live (and again after a niri restart). All Desktops: n/a, niri has no sticky windows |
| Dock folders (stacks) | have | `dockStacks`: Downloads by default (any folder: Settings → Dock), newest items piled with thumbnails (`<state>/cache/thumbs`, ffmpeg / pdftoppm, or the freedesktop cache); click → Fan / Grid / List (Automatic: fan up to 10 on a bottom dock); drag items out (text/uri-list); Sort by Name / Date Added / Modified / Kind, Display as Folder / Stack; live via inotifywait |
| Trash in the dock | have | `dockStacks`: empty/full icon, click opens `trash:///`, drop files on it (`gio trash`), Empty Trash… with a confirm (home trash only) |
| Recent apps section | have | `dockRecents`: apps used lately (AppUsage.lastUsed) that aren't pinned or running, count in Settings |
| Dock per display, auto-hide | have | a dock on every display that has it on; per display (by niri identity): position bottom / left / right, auto-hide never / always / when windows are open (macOS-style edge reveal); every dock steps aside for a fullscreen window. Settings live in one profile shape (`DockData.profileFor(screen)`) so Spaces can add a layer |
| Maximize without a new Space | niri | maximize-column / fullscreen |
| Fixed Space order | n/a | niri workspaces don't reorder by use |
| Quit on close | todo | when an app's last window closes, kill its process (opt-in per app) |
| Quit / close protection (hold ⌘Q) | todo | Cmd+Q bound to a shell hold-to-confirm overlay, then close/quit |

## Keyboard and mouse — mostly niri + fleet
| Feature | Status | How |
|---|---|---|
| Text snippets | have | `<state>/snippets.json` (Settings → Snippets) + a glass picker (Mod+Shift+Period, IPC `snippets toggle`) typing the expansion with wtype; variables {clipboard} {date} {time} {datetime} {weekday} {user}. No as-you-type expansion (needs an input hook, e.g. keyd/espanso) |
| Smooth / linear scrolling | n/a | libinput has no wheel smoothing; apps handle it |
| Pointer acceleration, scroll direction, focus follows mouse | niri | Keyboard & Mouse settings page |
| Scroll sideways while holding a key | todo (later) | needs an input remapper (keyd/xremap) |
| Side buttons / mouse button shortcuts | partial | niri binds support mouse buttons; add to the bind presets |
| Middle click (3-finger) | niri | touchpad `click-method` |
| Click filter / key debounce | todo (later) | keyd/interception; hardware-specific |
| Super key (Caps tap/hold) | have (fleet) | xremap in the fleet; Loft-native later |
| Keyboard shortcuts hub | partial | Keybinds page (read-only) → editable later |

## Clipboard, files and links — wave 1 (clipboard)
| Feature | Status | How |
|---|---|---|
| Clipboard history (text/images/files, pin, preview) | have | the shell runs `wl-paste --watch cliphist store` (dies with the shell); glass panel (Mod+Shift+V, IPC `clipboard toggle`): search, filters, image previews, pins kept apart from cliphist (`<state>/clipboard/`), Enter pastes into the focused app via wtype (Ctrl+Shift+V for terminals) |
| Auto-clear clipboard (delay / lock) | have | N minutes after the last copy and/or on lock (`LockState`), `wl-copy --clear`; history kept |
| Paste as plain text | have | Mod+Shift+Alt+V / IPC `clipboard pastePlain`: wl-paste --type text → wl-copy text/plain → paste |
| Shelf (park files/text/links while dragging) | have | edge drop target (a thin strip mid-edge notices drags and slides the shelf out), items persisted, dragged back out as text/uri-list / text/plain (Qt Drag.Automatic); IPC `shelf toggle\|addClipboard`. Verified client↔client in nested niri |
| Finder shortcuts | n/a | file-manager specific |
| Clean URL | have | opt-in watcher (Settings → Clipboard & Files) + "Clean link" in the panel; rules in src/services/urlclean.js (unit-tested) |
| Disk image installer | n/a | Nix installs apps declaratively |

## Everyday tools — wave 2 (everyday)
| Feature | Status | How |
|---|---|---|
| Dynamic Island (music, notifications, timers, …) | have | + calendars, downloads, lyrics, camera preview, file tools |
| AI agents in the island | todo | Claude Code / Codex usage + live sessions from their local logs (~/.claude, ~/.codex) |
| Command Bar | partial (walker) | + unit conversion, saved scripts, app menu commands n/a |
| Web search: !bangs, Quicklinks, default engine | have | Spotlight (`launcher/elephant-bangs`): `!` browses/fuzzy-finds 13.5k DuckDuckGo bangs, Enter/Tab scopes (`!nixpkgs ` + term), `!yt lofi` direct; quicklinks (`yt`, `yt lofi`, `gm`) without the !; Settings → Spotlight edits the default engine, favorites and quicklinks (`<state>/spotlight.json`) |
| Quick panel (favorite tools palette) | todo | glass palette of tools/toggles, ⌃⌘V |
| Quick toggles | partial (CC) | + dark/light, empty trash, eject disks, lock |
| Radial menu | todo | pointer-centred wheel of apps/tools with profiles |
| Scratchpad (tabbed autosaved Markdown notes) | have (island page: todo) | floating glass window (Mod+Shift+N), tabs, autosave to `<state>/scratchpad.json`, Markdown preview, export to `<dir>/<title>.md` |
| Cleaning mode | todo | full-screen overlay grabbing the keyboard; hold Esc to exit |

## Capture and create — wave 1 (capture)
| Feature | Status | How |
|---|---|---|
| Unified capture selector (shot/record/OCR/color) | have | ⌘⇧5 glass toolbar (`capture toggle`): screen / focused window / area shots, screen / area recording, Text, Color, Options (save to, timer 0/3/10 s, thumbnail, clipboard, annotate, pointer, audio, color format); ⌘⇧4 area, ⌘⇧3 screen. Area selection is a QML overlay on frozen grim frames with a pixel loupe; window shots via niri `screenshot-window --path` |
| Screenshot annotate/crop/redact/pin | have | floating thumbnail (click → satty, drag the file out, pin, delete); pins are always-on-top layer windows (drag, scroll to zoom, double-click to annotate) |
| Screen recording with mic + system tracks, trim, GIF | have | Recorder: area (`-g`) or output; audio none / system (default monitor) / mic / both (mic recorded by ffmpeg, muxed as a 2nd track); thumbnail → Trim (range + frame previews) and Export GIF (palettegen) |
| Camera preview | have | QtMultimedia camera in a floating round/rounded mirror (`camera toggle`) + an island Camera page; "No camera" / "in use" / "unavailable" states |
| Text from screen (OCR) + QR | have | region → zbarimg (QR first) → tesseract → clipboard + island banner |
| Color picker | have | loupe on the frozen frame, HEX/RGB/HSL/QML, recent colors in the selector and Settings |
| Media tools (compress, convert, watermark) | todo (later) | ffmpeg / imagemagick presets |

## App management — wave 2 (system tools)
| Feature | Status | How |
|---|---|---|
| App updates | todo | flake input ages + `nix flake update` diff summary; flatpak if present |
| Cleaner | todo | nix-collect-garbage / nh clean + ~/.cache sweep, scheduled |
| Messaging downloads | n/a (later) | rules over ~/Downloads |
| Uninstaller / Homebrew manager | n/a | Nix is declarative; instead: a package finder that copies the nix attr |
| Port manager | todo | `ss -ltnp` list + kill |

## Energy and display — wave 2 (display)
| Feature | Status | How |
|---|---|---|
| Keep awake (timer, while apps/power/displays) | partial (Caffeine) | durations + rules |
| Displays brightness (hardware + software dimming) | partial (Displays page) | ddcutil for external monitors, backlight for laptops, gamma dimming fallback |
| Extra brightness (XDR) | n/a | Apple hardware |
| Bluetooth off on sleep | todo (later) | systemd sleep hook |
| Wallpaper per display and per workspace, auto-matched, sets | have | Settings → Wallpaper → Displays & Workspaces (`src/settings/WallpaperDisplays.qml`): a diagram of the displays at their real positions / sizes / orientation showing what each shows; click one to pick for it, a workspace strip (named workspaces by name) to pick per workspace; *Use for all workspaces* per display; **Auto** (per theme; on by default when ≥ 6 images match) fills every display and workspace without a choice with images from the theme's vibe set + library in the same tone bucket, related to the display's image (same folder / color family first), aspect-aware (crop kept around each image's interest: edge + colorfulness saliency, so a landscape image on the portrait display keeps its subject; the wallpaper layer crops there too); deterministic per (theme, display, workspace), *Shuffle* reseeds. **Sets** assign by display role (main / left / right / top / bottom, portrait / ultrawide / landscape, display-N, `*`) + per-workspace entries: *Save as Set…*, apply, delete; theme packs ship them (`theme.json` `wallpaperSets`, applied automatically on a multi-display layout until you choose something). Workspace switches crossfade (400 ms, no flash). CLI `loft wallpaper plan\|sets\|set apply\|save\|delete\|shuffle\|auto`; IPC `wallpaper applySet\|saveSet\|deleteSet\|sets\|shuffle\|autoFill\|setAuto\|status`. Rules: `cli/loft/wallsets.py` |

## Features hub
Settings → **Features**: every module listed with on/off, grouped like the sections
above, with presets (Minimal · Creative · Everything). A module that is off isn't
loaded (its surfaces are `Loader { active: false }`) and its Settings page hides;
turning it back on restores its settings. Modules register in
`src/features/Features.qml` (id, label, icon, group, settings page, surfaces), so
new modules don't edit `shell.qml` or the Settings sidebar.
