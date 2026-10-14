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
| ✅ Have | 24 |
| 🧩 Handled by niri / fleet | 5 |
| 🟡 Partial | 11 |
| 🔨 In progress | 2 |
| ⬜ Todo | 14 |
| ➖ Not applicable on Linux/NixOS | 9 |

Of the 56 rows that apply on Linux: 29 are covered (✅ + 🧩), 13 more are partial or being
built, 14 are still todo — and Loft adds a whole desktop's worth of features vorssaint
doesn't need (bottom of this file).

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
| App switcher (live previews, search) | 🟡 | ⌘Tab by app with icons + titles; niri has no window-thumbnail API yet |
| Window layout (snapping, move between displays, restore) | 🟡 | niri binds + app menu Move to Display / Workspace; a snap menu is todo |
| Dock Preview (hover → windows, switch/close/move) | 🔨 | Dock agent: window list in the right-click menu (titles) |
| Dock clicks (minimize / hide / cycle) | 🔨 | Hide via a parking workspace (niri has no minimize) |
| Maximize without a new Space | 🧩 | niri maximize-column / fullscreen |
| Fixed Space order | ➖ | niri workspaces never reorder by use |
| Quit on close | ⬜ | Quit an app when its last window closes (opt-in per app) |
| Quit / close protection (⌘Q, ⌘W) | 🟡 | Quit confirms with several windows; hold-to-quit todo |

## Keyboard and mouse
| vorssaint | Loft | How |
|---|---|---|
| Text snippets (variables, insert menu) | ✅ | Snippets picker with {date} {clipboard} …; no type-to-expand |
| Smooth scrolling | ➖ | libinput/apps handle it |
| Pointer acceleration (disable) | 🧩 | Keyboard & Mouse settings → niri |
| Linear scrolling | ➖ | same as smooth scrolling |
| Focus follows mouse | 🧩 | niri setting |
| Scroll direction (independent) | 🧩 | niri per-device |
| Scroll sideways while holding a key | ⬜ | Needs the input remapper |
| Side buttons (Back / Forward) | 🟡 | niri can bind mouse buttons; presets todo |
| Mouse button shortcuts | 🟡 | same |
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
| Dynamic Island (music, notifications, calendars, timers, downloads) | 🟡 | Music, notifications, live activities, focus timer, system pages; calendars/downloads todo |
| AI agents usage in the island (Claude, Codex, …) | ⬜ | |
| Command Bar (search, calculator, units, emoji, scripts) | 🟡 | Spotlight (walker): apps, calculator, emoji, files, clipboard, 13,570 web !bangs; quicklinks + bang picker 🔨 |
| Quick panel (floating palette) | ⬜ | |
| Quick toggles | ✅ | Control Center controls (+ pin any to the menu bar) |
| Radial menu | ⬜ | |
| Scratchpad (tabbed Markdown notes) | ✅ | |
| Cleaning Mode | ⬜ | Lock input while cleaning |

## Capture and create
| vorssaint | Loft | How |
|---|---|---|
| Screen capture selector (shot / record / OCR / color) | ✅ | ⌘⇧5 toolbar |
| Screenshot (area / window / screen, annotate, share; scrolling) | 🟡 | All but scrolling capture; ⌘⇧3/⌘⇧4 + the Keychron key |
| Screen recording (system + mic, editing, GIF) | ✅ | Trim + GIF; zooms todo |
| Camera preview | ✅ | Floating round mirror + island page |
| Copy text from screen (OCR + QR) | ✅ | tesseract + zbar, offline |
| Color picker | ✅ | Pixel loupe, formats, recents |
| Media tools (compress, convert, watermark, GIF) | ⬜ | |

## App management
| vorssaint | Loft | How |
|---|---|---|
| App updates (one list) | ⬜ | → a flake-update summary for NixOS |
| Cleaner (caches, logs) | ⬜ | → nix store GC + caches |
| Messaging downloads cleanup | ⬜ | later |
| Uninstaller | ➖ | Declarative NixOS — remove from the flake |
| Homebrew manager | ➖ | Nix replaces it |
| Port manager | ⬜ | List listening processes, stop them |

## Energy and display
| vorssaint | Loft | How |
|---|---|---|
| Keep awake (timer, lid, apps, power, displays) | 🟡 | Caffeine toggle; rules todo |
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
| Dock | Liquid Glass dock; per-display docks with auto-hide rules, right-click menus, Downloads stack 🔨 |
| Multi-monitor | Main / fallback display logic, status area follows fullscreen |
| Spotlight | DuckDuckGo !bangs; Raycast-style quicklinks 🔨 |
| Spaces | Functional desktops across all monitors (Main, Music, Video, per-project) 🔨 (design) |
| Settings | Full Settings app incl. niri settings (displays, input, layout, keybinds) |
| Phone | iPhone integration via tether (messages, notifications, calls) — researched, not started |
| Testing | `loft-input` / `loft-shot` / headless sessions so agents can drive the desktop |
