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
| Volume mixer per app, boost > 100 % | todo | PipeWire stream nodes (Quickshell.Services.Pipewire), volume up to 150 %, pin/reorder favorites |
| Per-app output | todo | set the stream's `target.object` (PipeWire metadata) from the mixer |
| Output switcher + volume drop on headphone unplug | partial (CC slider) | default-sink picker in CC + shortcut + OSD; watch default sink changes |
| Microphone tools (preferred input, level, mute all) | todo | default source picker, level, global mute shortcut + bar indicator |
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
| App menu for every app (macOS ⌘-menu) | todo | the bar's app pill opens: About, Hide, New Window + `.desktop` actions, window commands (move to workspace/display, float, fullscreen), Quit (with hold-to-quit protection) |
| Global menu (File / Edit / View … in the bar) | todo | Rust `appmenu` daemon: a `com.canonical.AppMenu.Registrar` (Qt exports its menubar when one exists) + reads DBusMenu / `org.gtk.Menus` for the focused window, matched by PID from niri (niri has no KDE appmenu protocol); the bar draws glass dropdowns. Qt/KDE apps yes; GTK3 via appmenu-gtk-module; Electron only under XWayland; GTK4/libadwaita/Firefox no (in-window menus) |

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
| Text snippets | todo | snippet store + picker (walker `snippets` provider) + typed expansion via wtype |
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
| Clipboard history (text/images/files, pin, preview) | partial (walker) | cliphist store + our own glass history panel with image previews and pins |
| Auto-clear clipboard (delay / lock) | todo | timer + on-lock hook |
| Paste as plain text | todo | shortcut: wl-paste --type text → wl-copy → paste |
| Shelf (park files/text/links while dragging) | todo | a drop target panel (Qt DropArea) that keeps items until dropped out |
| Finder shortcuts | n/a | file-manager specific |
| Clean URL | todo | clipboard watcher stripping utm_*/fbclid/… (opt-in) |
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
| Scratchpad (tabbed autosaved Markdown notes) | todo | floating window + island page |
| Cleaning mode | todo | full-screen overlay grabbing the keyboard; hold Esc to exit |

## Capture and create — wave 1 (capture)
| Feature | Status | How |
|---|---|---|
| Unified capture selector (shot/record/OCR/color) | partial (recorder) | one glass selector; area/window/screen via niri + slurp |
| Screenshot annotate/crop/redact/pin | todo | satty for annotation; pinned captures as floating windows |
| Screen recording with mic + system tracks, trim, GIF | partial | wf-recorder audio options; ffmpeg trim/GIF |
| Camera preview | todo | QtMultimedia camera in the island / a floating mirror |
| Text from screen (OCR) + QR | todo | tesseract + zbar on a slurp region |
| Color picker | todo | hyprpicker (wlr-screencopy) → HEX/RGB/HSL |
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
