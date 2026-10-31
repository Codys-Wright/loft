# Credits

Loft builds on other people's work. This lists what it ships code or designs
from, what it patches, and what it fetches or follows at runtime.

## Code and designs Loft started from

| Project | What Loft takes | License |
|---|---|---|
| [javiiervm/dotfiles](https://github.com/javiiervm/dotfiles) | **The starting point of the shell**: its Hyprland + Quickshell "Liquid Glass" macOS-style components (Dynamic Island, Control Center, dock, switcher, lock) were ported to niri and rebuilt on Loft's theme. | No license file; used with the author's permission (link: TODO) |
| [qylock](https://github.com/Darkkal44/qylock) | The SDDM-API shim that lets a qylock theme run as both the login screen and the lock screen is vendored into the lock/greeter loader. The themes themselves are only fetched at runtime by the `qylock` importer, never shipped. | GPL-3.0 |
| [Cozytile](https://github.com/Darkkal44/Cozytile) | The theming pattern (a theme = per-app fragments, one apply step, a picker, per-app reload hooks). Its five themes are fetched and converted at install time by the `cozytile` importer; none of its assets are in this repo. | None |
| [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils) | Not used as code: its feature list was the checklist for Loft's utilities (Phase 7, docs/VORSSAINT-COMPARISON.md). | GPL-3.0 |

## Patched and built on

| Project | How | License |
|---|---|---|
| [niri](https://github.com/YaLTeR/niri) | `niri-loft` is niri 26.04 with Loft's patches (`nix/niri/`: per-workspace wallpaper layers, the server-side title bar). | GPL-3.0 |
| [Quickshell](https://quickshell.org) | The shell runs on it. | LGPL-3.0 |
| [Qt Multimedia](https://www.qt.io) | `nix/qt/qtmultimedia-nvidia-vaapi.patch` for zero-copy video wallpapers on NVIDIA. | LGPL-3.0 / GPL |
| [walker](https://github.com/abenz1267/walker) + [elephant](https://github.com/abenz1267/elephant) | The launcher, with Loft's theme and providers. | GPL-3.0 |
| [xremap](https://github.com/xremap/xremap) | macOS-style keys per app (`loft keys`). | MIT |
| [tether](https://github.com/zackb/tether) | `tetherd`, the iPhone link behind the Phone features. | MIT |

## Data and palettes

| Project | What | License |
|---|---|---|
| [unduck](https://github.com/T3-Content/unduck) | The `!bang` list for Spotlight web search (built into `bangs.json`). | MIT |
| [Tokyo Night](https://github.com/folke/tokyonight.nvim) | The `tokyonight` / Loft Dark palette. | Apache-2.0 |
| [Catppuccin](https://github.com/catppuccin/catppuccin) | The `latte` / Loft Light palette (Latte). | MIT |
| [MacTahoe](https://github.com/vinceliuice/MacTahoe-gtk-theme) | The optional GTK / libadwaita base stylesheet (`programs.loft.gtkBase`) Loft's gtk.css layers on. Not shipped. | MIT |
