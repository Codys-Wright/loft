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
| Global menu (File / Edit / View … in the bar) | have | `studio-appmenu` (crates/studio-appmenu): owns `com.canonical.AppMenu.Registrar` (never replaces another one, e.g. Plasma's), matches the focused window by pid (niri has no appmenu protocol) — registrar entries, then introspection of the process's bus connections, and `_NET_ACTIVE_WINDOW` for X11 windows. Reads DBusMenu (Qt/KDE, Electron on X11) and `org.gtk.Menus` (GtkApplication menubars). Verified: Qt/KDE (Kate, KCalc, PyQt), GTK3 GtkApplication (Mousepad, gtk3-demo-application), Electron under XWayland (needs libdbusmenu-glib). No: GTK4/libadwaita apps without a menubar (Text Editor), Firefox, Electron on Wayland |

## Menu bar extras (top right) — wave 2 (status)
macOS's own status items (vorssaint has none of these — macOS ships them), plus
vorssaint's readouts/sound tools that already exist, in one style: an icon in the
flush bar → a glass dropdown under it (one open at a time, hover-switch between
open extras like real menus), scroll on the icon where it makes sense, ⌥-click
(Alt-click) for details, "… Settings" at the bottom opens the Settings page.

| Feature | Status | How |
|---|---|---|
| **Wi-Fi / network extra** — icon: signal bars, ethernet, offline, VPN badge | todo | Quickshell `Networking` (NetworkManager): Wi-Fi toggle; current network (signal, lock); known + other networks from a scan while open; click to connect, inline password field for new secured networks; "Other Network…" (hidden SSID); every wired link (Wired connection 1, 10G Jumbo) and VPNs (Tailscale) with state; ⌥-click details: IP, router, DNS, channel/band, link rate, RSSI; live traffic line (from `network`) |
| **Bluetooth extra** — icon shows on / connected / off | todo | Quickshell `Bluetooth` (BlueZ): toggle; devices (connected first) with type icon and battery % (BlueZ Battery1); click = connect/disconnect; "Nearby Devices" (discovery only while open) → pair + trust; ⌥-click: address, RSSI; low-battery alert for headsets/mice (hooks `alerts`) |
| **Sound extra** — icon reflects volume / headphones / muted | partial (icon, mixer) | output volume slider (+ scroll on icon), output device list (TF, Dante, Bluetooth with battery), "Sound Settings…", mixer chevron (`mixer`); ⌥-click: inputs + mic level, and the PipeWire graph clock — sample rate / quantum with quick switch (48/96 kHz, 64–1024 frames via `pw-metadata` clock.force-*) for studio work |
| Now Playing extra (optional) | todo | MPRIS, like macOS's Now Playing item — for when the island is off |
| Battery extra (only when a battery exists) | todo | UPower: %, time remaining, power source, power profile (power-profiles-daemon), energy-hungry apps (from `systemMonitor`) |
| Clock in the bar (optional) | todo | the time lives in the island today; a setting shows date + time on the right like macOS; click → calendar / notification history |
| Focus / Do Not Disturb indicator | todo | moon icon while DND is on (CC toggle exists) |
| Recording indicator | partial (island) | a stop button in the bar while the Recorder runs (macOS shows one) |
| Camera-in-use indicator | todo | green dot when a camera node is in use (PipeWire video sources / v4l2 users) — alongside the mic indicator (have) |
| Input source (keyboard layout) | todo | only when more than one xkb layout; niri `switch-layout` |
| Spotlight icon | todo | magnifier → `studio-launcher open` |
| Control Center | have | the toggles icon |
| Menu bar readouts (CPU, RAM, temps, net, battery) | have | `barReadouts` |
| **Arrange the extras** (Bartender / Ice-style) | todo | Settings → Menu Bar: show/hide and reorder every extra and readout; tray (StatusNotifier) icons can be pinned or tucked behind a » overflow that expands on click/hover; per-item "only when active" (e.g. VPN, recording) |

## Windows and the dock — wave 2 (windows)
| Feature | Status | How |
|---|---|---|
| App switcher with previews/search | partial (icons) | niri has no window thumbnails API → titles + search; previews later via screencast |
| Window layout snapping, move between displays, restore | partial (niri binds) | layout presets → niri actions (column width, maximize, move-to-monitor); a snap menu |
| Dock preview (hover → windows, switch/close/move) | todo | hover popover listing the app's windows (titles), actions via niri IPC |
| Dock clicks (minimize/hide/cycle) | partial (cycle) | niri has no minimize → "hide" = move to a parking workspace |
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

## Features hub
Settings → **Features**: every module listed with on/off, grouped like the sections
above, with presets (Minimal · Creative · Everything). A module that is off isn't
loaded (its surfaces are `Loader { active: false }`) and its Settings page hides;
turning it back on restores its settings. Modules register in
`src/features/Features.qml` (id, label, icon, group, settings page, surfaces), so
new modules don't edit `shell.qml` or the Settings sidebar.
