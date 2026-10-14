# Loft vs vorssaint — feature comparison

**What vorssaint is.** [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils) is a
macOS menu-bar app that bundles ~65 small utilities Mac users normally buy separately — a
per-app volume mixer (like SoundSource), window snapping (Rectangle), a clipboard manager
(Paste), a screenshot suite (CleanShot), a Dynamic Island for the notch, a system monitor
(iStat Menus), keyboard/mouse fixes (Mos, Karabiner), cleaners, and more — each one a
module you switch on in its Features hub. It only adds *utilities* on top of macOS; the
Mac itself still provides the desktop (menu bar, Control Center, Wi-Fi/Bluetooth menus,
Spotlight, the Dock, themes).

**What Loft is.** The whole desktop — niri + our own Quickshell shell — so it has to
provide both halves: vorssaint's utilities *and* what macOS gives vorssaint for free.
vorssaint is the checklist for the first half (detail and status per row live in
[FEATURES.md](FEATURES.md)); [DESIGN-GOLDEN-GATE.md](DESIGN-GOLDEN-GATE.md) is the target
for the second.

Legend: ✅ have · 🟡 partial · 🔨 in progress · ⬜ todo · ➖ not applicable on Linux/NixOS
(reason given) · 🧩 handled by niri / the fleet config.

## Scoreboard (vorssaint's own feature list, 65 rows)

| | Count |
|---|---|
| ✅ Have | 40 |
| 🧩 Handled by niri / fleet | 9 |
| 🟡 Partial | 4 |
| 🔨 In progress | 0 |
| ⬜ Todo | 3 |
| ➖ Not applicable on Linux/NixOS | 9 |

Of the 56 rows that apply on Linux: 49 are covered (✅ + 🧩), 4 more are partial, 3 are
still todo — and Loft adds a whole desktop's worth of features vorssaint doesn't need
(bottom of this file).

## Sound
| vorssaint | Loft | How |
|---|---|---|
| Volume mixer (per-app, boost > 100 %, favorites) | ✅ | Mixer panel: per-app volume to 150 %, mute, pinned favorites |
| Per-app output | ✅ | Pick a device per app (PipeWire `target.object`) |
| Output switcher + lower volume on headphone disconnect | ✅ | Sound menu / Control Center / ⌘⇧O; safe volume on unplug |
| Microphone tools (preferred input, level, mute all) | ✅ | Input picker + level, mute-all ⌘⇧M, recording indicator |
| Music app blocker | ➖ | macOS-only media-key quirk |

## Know what your Mac is doing
| vorssaint | Loft | How |
|---|---|---|
| System monitor (CPU/GPU/memory/temps, graphs, energy-hungry apps) | ✅ | System Monitor window, history graphs, processes with Quit / Force Quit |
| Fan control (manual / curves) | 🟡 | Live RPM + temps; control is hardware-specific (later) |
| Menu bar readouts | ✅ | CPU / RAM / temp / GPU / net / battery — off by default, one switch |
| Network (traffic, totals, local IP, speed test) | ✅ | Network page + Wi-Fi menu details |
| Alerts (load, heat, memory pressure, disk, battery) | ✅ | Island banners with hysteresis |

## Windows and the Dock
| vorssaint | Loft | How |
|---|---|---|
| App switcher (live previews, search) | 🧩 | niri's recent-windows switcher: ⌘Tab / ⌥Tab with live window previews, ⌘` within the app |
| Window layout (snapping, move between displays, restore) | ✅ | Arrange ▸ in the app menu and dock menu, ⌘⌃A palette: floating windows snap to halves / thirds / ⅔ / quarters / fill / center; tiled ones get column widths ⅓ ½ ⅔ full, heights, center, join/split columns; move to display |
| Dock Preview (hover → windows, switch/close/move) | ✅ | Hover (or click) an app: Liquid Glass cards per window with title, desktop / display, hidden state; click focuses anywhere, × closes, ⋯ / right-click moves to a desktop or display, hides. Thumbnails only where niri allows (floating / fullscreen windows; niri 26.04 has no per-window capture), else the app icon |
| Dock clicks (minimize / hide / cycle) | ✅ | Click focuses, again cycles the app's windows; Hide via a parking workspace (niri has no minimize) |
| Maximize without a new Space | 🧩 | niri maximize-column / fullscreen |
| Fixed Space order | ➖ | niri workspaces never reorder by use |
| Quit on close | ✅ | Opt-in per app (Settings → Everyday, dock Options): SIGTERM a few seconds after the last window closes |
| Quit / close protection (⌘Q, ⌘W) | 🟡 | Hold ⌘Q to quit (per app or all, pill with a ring); ⌘W can't be caught — it goes straight to the app |

## Keyboard and mouse
| vorssaint | Loft | How |
|---|---|---|
| Text snippets (variables, insert menu) | ✅ | Snippets picker with {date} {clipboard} …; no type-to-expand |
| Smooth scrolling | ➖ | libinput/apps handle it |
| Pointer acceleration (disable) | 🧩 | Keyboard & Mouse settings → niri |
| Linear scrolling | ➖ | same as smooth scrolling |
| Focus follows mouse | 🧩 | niri setting |
| Scroll direction (independent) | 🧩 | niri per-device |
| Scroll sideways while holding a key | 🧩 | Shift+wheel in GTK, Firefox, Chromium, Electron; Alt+wheel in Qt |
| Side buttons (Back / Forward) | 🧩 | Apps map buttons 8/9 to Back / Forward themselves |
| Mouse button shortcuts | 🧩 | niri binds MouseBack / MouseForward / MouseMiddle (+ modifiers) |
| Middle click (three-finger) | 🧩 | touchpad click method |
| Apps to leave alone | ⬜ | Per-app exclusions for remaps |
| Extra click filter / key debounce | ⬜ | Hardware-specific (later) |
| Super key (Caps / right modifier as a combo) | ✅ | Esc / Caps hold = window key (xremap); Super = ⌘ for apps |
| Keyboard shortcuts hub (+ macOS shortcut takeover) | 🟡 | Keybinds page read-only; ⌘C/V/⌘⇧3/4/5 work; editable hub todo |

## Clipboard, files and links
| vorssaint | Loft | How |
|---|---|---|
| Clipboard history (text, images, files, pins, previews) | ✅ | ⌘⇧V |
| Auto clear clipboard | ✅ | Delay / on lock |
| Paste as plain text | ✅ | |
| Shelf | ✅ | Park files / links / text at the screen edge |
| Finder shortcuts (⌘X/⌘V move, F2 rename) | ➖ | File-manager specific |
| Clean URL | ✅ | Strips tracking parameters |
| Disk image installer | ➖ | No .dmg on NixOS |

## Everyday tools
| vorssaint | Loft | How |
|---|---|---|
| Dynamic Island (music, notifications, calendars, timers, downloads) | ✅ | Music (+ synced lyrics, opt-in), notifications with action buttons, calendar page + next event in the pill with Join (khal / vdirsyncer, Evolution, ICS), multiple timers + stopwatches with alarm, downloads live activity + Downloaded banner (Open / Show in Files / drag out), quick toggles, focus, recording, system, screen time; pages reorderable |
| AI agents usage in the island (Claude, Codex, …) | ✅ | Claude Code + Codex: running sessions, tokens and ≈ cost today / this week, 5-hour window (Codex rate limits), from local logs — counts only |
| Command Bar (search, calculator, units, emoji, scripts) | ✅ | Spotlight (walker + elephant): apps, windows, system commands with confirm, Settings pages, calculator with units / currency / time zones, Raycast-compatible script commands, emoji, files with previews, clipboard, 13,570 web !bangs, quicklinks; `?` help |
| Quick panel (floating palette) | ✅ | ⌃⌘V glass palette at the pointer: favorite tools from the action catalog, clipboard, snippets, type-to-filter |
| Quick toggles | ✅ | Control Center controls (+ pin any to the menu bar) |
| Radial menu | ✅ | Hold ⌃⌘Space or middle-button on the desktop: pointer-centered wheel, submenu rings, per-app profiles, release-to-activate |
| Scratchpad (tabbed Markdown notes) | ✅ | |
| Cleaning Mode | ✅ | Dark session lock on every display: no keys, clicks or shortcuts; hold Esc 3 s, timer or IPC to leave |

## Capture and create
| vorssaint | Loft | How |
|---|---|---|
| Screen capture selector (shot / record / OCR / color) | ✅ | ⌘⇧5 toolbar |
| Screenshot (area / window / screen, annotate, share; scrolling) | 🟡 | All but scrolling capture; ⌘⇧3/⌘⇧4 + the Keychron key |
| Screen recording (system + mic, editing, GIF) | ✅ | Trim + GIF; zooms todo |
| Camera preview | ✅ | Floating round mirror + island page |
| Copy text from screen (OCR + QR) | ✅ | tesseract + zbar, offline |
| Color picker | ✅ | Pixel loupe, formats, recents |
| Media tools (compress, convert, watermark, GIF) | ✅ | Utilities → Media Tools: compress video, convert images, GIF, text/logo watermark, extract audio; drop files, dock Quick Actions ▸, Open With / Spotlight |

## App management
| vorssaint | Loft | How |
|---|---|---|
| App updates (one list) | ✅ | Flake updates: what `nix flake update` would change (inputs, commits, package versions); you run `just update && just switch` |
| Cleaner (caches, logs) | ✅ | Caches, Trash, Nix garbage + generations (GC is a command you run), scheduled cleanup (systemd user timer) |
| Messaging downloads cleanup | ✅ | Retention per folder (Telegram, WhatsApp …) → old files to the Trash |
| Uninstaller | ➖ | Declarative NixOS — remove from the flake |
| Homebrew manager | ➖ | Nix replaces it |
| Port manager | ✅ | Listening ports with process + project, open dev servers, stop (Force Quit) your own |

## Energy and display
| vorssaint | Loft | How |
|---|---|---|
| Keep awake (timer, lid, apps, power, displays) | ✅ | 15 min … indefinitely; while apps are open, on power, a display connected; lid closed (logind) |
| Displays (per-display brightness, hardware/software, dimming) | ✅ | Control Center Display: ddcutil / backlight per display |
| Extra brightness (XDR) | ➖ | Apple hardware |
| Bluetooth off on sleep | ⬜ | systemd sleep hook |

## Panel and app settings
| vorssaint | Loft | How |
|---|---|---|
| Features hub (install only what you use), reorder/hide sections, export | ✅ | Settings → Features with presets; every module switchable |

## What Loft has that vorssaint doesn't
vorssaint relies on macOS for these; on Linux Loft builds them, in the Golden Gate style.

| Area | Loft |
|---|---|
| Menu bar | Transparent, adaptive light/dark per display; **global File/Edit/View menu** for Qt/GTK apps; app menu; monochrome status icons; » overflow; arrange like Bartender/Ice |
| Menu bar extras | Wi-Fi (join networks, VPNs), Bluetooth (pair, battery), Sound (incl. PipeWire sample rate / buffer for studio work), Battery, Clock, Focus, recording / camera / mic indicators, input source |
| Control Center | macOS-style module grid, expand in place, Edit Controls gallery, pin controls to the bar |
| Desktop | Right-click desktop menu (wallpaper, themes, appearance, screenshot, terminal …) |
| Themes | Runtime theme engine, 46 themes (cozytile, qylock), live recolor of shell / niri / GTK / terminals / launcher; Liquid Glass slider, Reduce Transparency; theme architecture with facets + variants 🔨 |
| Wallpapers | Library sorted by topic / color / tone / theme; **per-display and per-workspace wallpapers**, auto-matched by tone and colors, subject-aware crops, wallpaper sets in theme packs |
| Lock & login | Lock screen with qylock designs; matching SDDM login theme |
| Dock | Liquid Glass dock; per-display docks with auto-hide rules, right-click menus, window previews, Downloads stack 🔨 |
| Multi-monitor | Main / fallback display logic, status area follows fullscreen |
| Spotlight | DuckDuckGo !bangs; Raycast-style quicklinks and script commands; time zones in the calculator |
| Spaces | Functional desktops across all monitors (Main, Music, Video, per-project) 🔨 (design) |
| Settings | Full Settings app incl. niri settings (displays, input, layout, keybinds) |
| Phone | iPhone integration via tether (messages, notifications, calls) — researched, not started |
| Testing | `loft-input` / `loft-shot` / headless sessions so agents can drive the desktop |
