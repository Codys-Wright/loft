# Loft — Plan

> **Status:** draft for discussion (2026-10-13).
>
> **Loft** is a desktop for creative work, music production and
> programming: niri + our own Quickshell shell, a macOS-inspired Liquid Glass
> design language, fully themeable at runtime. It's a standalone flake (you
> can `nix run` it) that the NixOS fleet (`~/.flake`, Codys-Wright/nix-config)
> consumes as an input. Themes live in a separate repo, **loft-themes**.
>
> The fleet's [`docs/desktop-design.md`](https://github.com/Codys-Wright/nix-config/blob/main/docs/desktop-design.md)
> holds Cody's personal workflow: workspaces, monitors, per-app placement.

---

## 1. Goal

A desktop we own end to end, macOS-inspired in look and feel, built on niri and
our own Quickshell shell:

1. **Our own shell.** A Quickshell (QML) shell living in this repo with a menu
   bar, dock, control center, notifications, OSD, a Dynamic Island and an app
   switcher. It replaces Noctalia once it reaches parity, then keeps growing
   into the system we need.
2. **Runtime-flexible everything.** NixOS sets the *defaults* (theme, shell
   settings, niri config). Anything can be changed at runtime without a
   rebuild. A **save-back tool** promotes runtime changes into the repo once
   we decide we like them.
3. **Mac-like design language, fully themeable.** The *components* are
   macOS-inspired in shape and behavior: Liquid Glass surfaces, menu bar,
   dock, Control Center, Dynamic Island. *Themes* are not limited to a mac
   look. A theme can be anything: anime, pixel art, e-ink, Nier. It drives
   every token the components expose, including colors, wallpaper, fonts,
   radii, glass tint/opacity/blur, and optionally a whole lock/greeter
   design.
4. **Runtime theming across the whole desktop**, the way
   [Cozytile](https://github.com/Darkkal44/Cozytile) does it. A theme is one
   switch that recolors the shell, niri, terminals, GTK, launcher, lock screen,
   greeter and wallpaper. We also build our own theme selector.
5. **A theme manager, outside the NixOS build.** Themes are packs you
   *install* at runtime (`loft theme install …`), author yourself, and share
   (a git repo or tarball). The NixOS build ships only the engine and a small
   default set. Adding all 39 qylock themes must never be needed to build a
   machine.
6. **Uses niri 26.04's native blur** (`ext-background-effect`) for the glass
   surfaces.
7. **A matched launcher:** [walker](https://github.com/abenz1267/walker) with
   our own Spotlight-style layout, styled by the active theme.
8. **A Quickshell login and lock screen** in
   [qylock](https://github.com/Darkkal44/qylock)'s format: one QML design that
   serves as both the SDDM greeter and the lock screen. **All qylock themes
   can be installed** through the theme manager.
9. **macOS keyboard parity.** Cody switches between this desktop and voyager
   (macOS) all day, so the same physical keys must do the same things on both.
10. **Testable without rebooting.** Develop and run everything in a nested niri
   window inside the current KDE session.

### Non-goals (for now)
- No greetd and no second display manager. SDDM stays, with our theme.
- Not a general distro. We serve the use cases in `desktop-design.md`.
- vorssaint-utils is not installed anywhere (see §3).

---

## 1a. Repository boundary and flake

### What lives where

| Loft (this repo, public) | loft-themes (public) | nix-config fleet (`~/.flake`) |
|---|---|---|
| Shell (QML), `loft` CLI (theme engine, manager, importers, save-back), lock/greeter loaders + vendored qylock shim, walker Spotlight layout, nirimod package | Our authored theme packs + `index.json` (packs + `qylock:*` / `cozytile:*` importer entries) | Host and personal layer: monitors/outputs, named workspaces + app rules (`desktop-design.md`), REAPER/Dante rules, xremap keyboard (until shared, see §5), which hosts/users get Loft, *personal* default settings and theme |
| **Base niri config**: layout, animations, blur rules, mac-like binds, startup of Loft services. Shipped as KDL fragments for the consumer to `include` | | `niri/_config/config.kdl` `include`s the Loft base, then adds host fragments |
| Built-in themes: the default + a couple of basics (a build needs only these) | Everything else, installed at runtime | |
| NixOS + home-manager modules | | den aspect `fleet.desktop._.loft` wraps those modules (input declared inline, the dendritic idiom) |

Open boundary question: should the creative-workflow *opinions* (semantic
workspaces music/code/video, workflow profiles such as music mode with fixed
FPS or gaming mode with no effects) become Loft features with
defaults? Or stay personal in the fleet? *Leaning:* the **mechanisms**
(profiles, per-workspace wallpaper, run-or-raise) go in Loft, and the
**specific assignments** stay in the fleet.

### Flake outputs

```
packages.<sys>.default          # session launcher (below)
packages.<sys>.loft-shell       # QML + quickshell wrapper with all runtime deps
packages.<sys>.loft             # CLI: theme engine/manager/importers, diff/save, greeter helper
packages.<sys>.loft-lock        # loader lock + loader SDDM theme + qylock shim
packages.<sys>.loft-themes-builtin
packages.<sys>.nirimod
apps.<sys>.default              # nix run github:Codys-Wright/loft
apps.<sys>.dev                  # nix run .#dev — from a checkout, hot-reload from ./src
nixosModules.default            # programs.loft: niri, SDDM loader theme, polkit helper, gstreamer, portals
homeManagerModules.default      # programs.loft: shell service, walker/elephant, theme state + consumers, settings
templates.theme                 # nix flake init -t …#theme → a new theme pack
checks.<sys>.*                  # qmllint, theme render golden tests, a NixOS VM test that boots to the shell
```

**`nix run github:Codys-Wright/loft`**
- Inside a Wayland or X session, it opens a **nested niri window**.
- On a bare TTY, it starts a full session.
- Either way it runs Loft's base niri config, the shell, walker and the
  default theme, all from the store. State goes to a throwaway
  `$XDG_STATE_HOME/loft-run`, so trying it never touches your real
  setup. Inside the nested window, Mod = Alt.

**`nix run .#dev`** (from a checkout)
- Same, but QML is loaded from `./src`, niri fragments from `./niri`, and
  themes from `./themes`.
- Quickshell and niri both hot-reload on save, so this is the inner dev loop.
- The SDDM greeter has its own preview: `nix run .#greeter-preview`
  (`sddm-greeter-qt6 --test-mode`).

### Module options sketch (home-manager)

```nix
programs.loft = {
  enable = true;
  theme = "tokyonight";                 # default theme (built-in or a pack path)
  extraThemes = [ ];                    # optional: pin packs into the build if you WANT to
  settings = lib.importJSON ./loft.json;     # consumer defaults (save-back target, §4.1)
  saveTarget = "${config.home.homeDirectory}/.flake/users/cody/_data/loft.json";    # null = no save-back
  dev.source = null;                    # e.g. "~/Development/loft" → live symlinks (cody)
  niri.includeBase = true;              # write the base fragments for the consumer's config to include
};
```

## 2. Starting point (today, in the fleet)

| Area | Today | Notes |
|---|---|---|
| Compositor | niri **26.04** (nixpkgs) | Blur and optional `include` are already available. No bump needed |
| niri config | Plain KDL tree `modules/desktop/environment/niri/_config/`, out-of-store symlinked to `~/.config/niri` | Live-editable. `config.kdl` is already split by `include` |
| Stale config | `_niri-settings.nix` + `niri-wrapper.nix` (wrapper-modules) | Drifted from the KDL tree. **Delete in Phase 0** |
| Shell | Noctalia (`spawn-at-startup "noctalia-shell"`) | Mutable `noctalia/colors.json`; Mod+Space opens its launcher |
| Theme | Stylix (build-time, tokyonight) + MacTahoe GTK/icons/cursor | Changing colors needs a rebuild |
| Display manager | SDDM + MacTahoe-Dark theme | `modules/desktop/display-manager/sddm.nix` |
| Lock / idle | swaylock + swayidle | |
| Keyboard | xremap + `_mac-keybindings.nix`: **Super = Cmd** (app shortcuts); **Caps-hold / Esc-hold / Right Ctrl = niri Mod (Mod5)** | Linux only. voyager has no keyboard or WM config in the flake |
| Quickshell | nixpkgs `quickshell` 0.3.1 | HM has `programs.quickshell` |
| Session | Cody is on KDE Wayland | niri can run nested as a window |

**Fleet-side bug to fix along the way:** `niri.nix`'s `provides.to-users` points
*every* user's `~/.config/niri` at `~/.flake/...`, which only exists for cody.
bri, joshua and the other users on THEBATTLESHIP get a dangling symlink. The
live-symlink model must be cody-only, with a store copy for everyone else (§5).

---

## 3. Upstream references: what we take from each

| Project | What it is | License | How we use it |
|---|---|---|---|
| [javiiervm/dotfiles](https://github.com/javiiervm/dotfiles) | Hyprland + Quickshell "Liquid Glass" macOS shell: Dynamic Island, Control Center, dock, launcher, Alt-Tab, lock | No LICENSE file, but **the author has given permission to use the designs as a starting point** | **Our starting point.** Port its components (glass surfaces, island, control center, dock, switcher) into `src/`, credited in `CREDITS.md` with a link to the permission. TODO: record that link. The port still needs real rework for niri and for theming (below) |
| [Cozytile](https://github.com/Darkkal44/Cozytile) | Qtile/X11 rice with one-key theme switching; themes **Cozy, Sakura, Natura, Everforest, Carbon** | **None** | **The theming pattern** (theme = per-app fragments + one apply script + picker + per-app reload hooks), **and all five themes as installable packs.** A `cozytile` importer in the theme manager fetches each theme's palette, wallpaper and SDDM art from upstream at install time and converts it to our format. Nothing is committed here, so the unlicensed assets never enter this public repo. We do *not* copy its `cp -r ~/Themes/X ~` mechanism, which fights home-manager's read-only symlinks |
| [walker](https://github.com/abenz1267/walker) + elephant | GTK4 launcher frontend + provider backend (apps, calc, files, clipboard, symbols, **niri actions**, websearch, …) | GPL-3.0 | Consume from **nixpkgs** (walker 2.17, elephant 2.22) + HM `services.walker` / `services.elephant`. Write our own theme |
| [qylock](https://github.com/Darkkal44/qylock) | 39 themes that each run as **both** an SDDM greeter and a Quickshell `WlSessionLock` lock screen, through an SDDM-API shim | GPL-3.0 | **Vendor the small shim** into our lock/greeter loader. **Every qylock theme is installable** via a `qylock` importer in the theme manager: a sparse checkout of just that theme's directory, since the repo is ~1.2 GB of mostly `bg.mp4`. Never a flake input and never part of a machine build |
| [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils) | Native macOS (Swift) all-in-one menu-bar utility | GPL-3.0+ | **Not installed. A feature checklist for our shell** (§6.4) |
| [nirimod](https://github.com/srinivasr/nirimod) | GTK4 niri config editor: monitor layout, keybind heat map and conflict check, curve editor, `niri validate` before writes | MIT | **Package it** (Python/GTK4; not in nixpkgs, to verify). It follows our symlinks and writes to the real file, so its edits land in the repo. It resolves `include`s and writes each change only to the file it came from. Later, possibly our own settings UI that covers the same ground |
| niri 26.04 | Blur (normal + efficient **xray**), `layer` matcher, optional `include` with `~` expansion | GPL-3.0 | Blur rules in a theme-owned `include` (§4.3) |

### Porting notes for the javiiervm shell (what the port has to change)
- It is Hyprland-only: 9 files import `Quickshell.Hyprland`
  (`focusedWorkspace`, `dispatch`, `HyprlandFocusGrab`, `GlobalShortcut`), and
  it shells out to `hyprctl` for gaps, sunset and window focus.
  → Use a niri adapter: one `niri msg --json event-stream` service parsed in
  QML, with actions via `niri msg action …`. Use `IpcHandler` + niri `binds`
  instead of `GlobalShortcut`.
- Its own Python notification daemon, bash FIFO daemon and fake `swaync-client`
  bins → replace with Quickshell's built-in `Services.Notifications`,
  `Services.Pipewire`, `Services.UPower`, `Services.Mpris` and `SystemTray`.
- Hardcoded `/home/javier` paths and a OneDark `Theme.qml` singleton, plus
  132 raw hex literals → every color must go through our `Theme` singleton
  from day one.
- Its "Liquid Glass" relies on Hyprland layer blur. niri 26.04 provides it
  natively (§4.3).

---

## 4. Architecture

### 4.1 The layering model: defaults → runtime overrides → save-back

This is the core of "NixOS sets the defaults, runtime can change anything".
There are three layers, and the later layers win:

```
 1. product defaults          2. consumer defaults             3. runtime overrides
    (Loft repo)                  (fleet: module options/JSON)     (~/.local/state/loft/overrides)
    shell/defaults.json   ⊕      settings = importJSON …    ⊕     shell.json, theme-<name>.json
    built-in themes              theme = "…"                       (settings UI, theme selector, CLI)
           ▲                            ▲                                   │
           │  loft save --upstream      │  loft save (default)              │
           └────────────────────────────┴───────────────────────────────────┘
```

- **Defaults are JSON data, not Nix code**, both in Loft (product
  defaults) and in the consumer (`settings = lib.importJSON ./loft.json`).
  That makes save-back a *data* merge (JSON → JSON plus a `git diff`), never
  Nix code generation.
- **Effective value = product ⊕ consumer ⊕ overrides.** The home-manager
  module writes the first two merged into one store file. The shell reads
  that plus the overrides through `FileView` + `JsonAdapter` with
  `watchChanges`, so a write to an override file applies live. The settings
  UI and the theme selector only ever write to `overrides/`.
- **`loft diff` / `loft save`** (the save-back tool):
  - `loft diff` shows runtime overrides against the effective defaults.
  - `loft save [--shell] [--theme <name>]` merges overrides into
    **`saveTarget`** (the consumer's JSON, e.g. a file in `~/.flake`), then
    clears what it promoted. This is the normal path: *my* preferences go to
    *my* config.
  - `loft save --upstream` writes to a Loft checkout instead, which
    changes the product defaults.
  - `loft save --as-theme <new>` snapshots the tweaked theme as a new
    **pack**. That pack can stay local, be exported, or be PR'd to
    loft-themes.
  - It refuses when the target file has uncommitted changes, and prints the
    `git diff` for review. It never commits on its own.
- **niri config.** The consumer's own KDL (the fleet's `_config/`) is already
  live-symlinked, so nirimod and hand edits change the repo directly, and
  save-back there is just `git diff`. Loft's base fragments are
  read-only defaults the consumer overrides *after* its `include`. Only the
  theme-owned fragment (colors, blur, radii) goes through the theme pipeline.
- **Machines and users without a checkout** (`saveTarget = null`) get the same
  layering and can change things at runtime. There is just nowhere to save
  back to.

### 4.2 Theme system: engine, packs, manager (`loft` theme engine)

**Design language vs theme.** The *design language* (component shapes,
layout, glass treatment, animation) belongs to the shell and is mac-like. A
*theme* is mainly **the color palette and the glass/blur state that every
component reads.** Nothing else is required. A theme can look like anything.

**Theme core** (`theme.json`, the only required file):
- `palette`: base16/24 colors + semantic roles (`bg`, `surface`, `overlay`,
  `text`, `subtext`, `accent`, `accent2`, `urgent`, `ok`, `warn`), and
  `polarity` (dark/light).
- `glass`: `blur` on/off, `xray` on/off, tint color, surface opacity, noise,
  saturation.

**Optional pack extras** (each falls back to the default theme's when absent):
- `wallpaper` (image or video), `fonts`, `radii`, a `lock/` QML design
  (qylock format), `greeter/` art, and per-app overrides
  (`apps/<consumer>.*`) for when generated output isn't good enough.

**Theme pack** = a directory (`manifest.json` with name, author, version,
license, source + the files above). Packs are shared as a git repo, a tarball,
or a subdirectory of either.

**One renderer, runtime-first.** Themes can arrive after the build, so
rendering can't live only in Nix. `loft theme render` is a runtime program,
and the per-consumer templates ship with it in the store:

| Consumer | Generated from the theme | Live reload |
|---|---|---|
| Shell (Quickshell) | `theme.json` as-is | `FileView watchChanges` (instant) |
| niri | `niri.kdl`: focus ring, borders, shadows, **blur rules on/off + xray**, radii | `include optional=true "~/.local/state/loft/current/niri.kdl"`; niri polls every include by canonical path, so re-pointing `current` is noticed (*verified in niri 26.04 source*); `apply` also runs `niri msg action load-config-file` to skip the ≤500 ms poll |
| kitty | `kitty.conf` (colors, `background_blur`) | `include` + `kill -SIGUSR1` |
| Ghostty | `ghostty.conf` | `config-file = ?…` + `SIGUSR2` (*verified: GTK apprt reloads config on SIGUSR2*) |
| GTK 3/4 | `gtk.css` (`@define-color`), color-scheme | `@import` + `gsettings set … color-scheme` |
| walker | `walker.css` (`@define-color loft_*`) | CSS is re-read on every open (confirmed in source) |
| Lock / greeter | pack `lock/` or the default design + palette | Read at lock time; greeter, see §4.5 |
| Wallpaper | path | swww/awww transition (feeds xray blur) |
| Noctalia (transition period only) | `colors.json` | its own watcher |

Nix calls the *same* renderer at build time for the built-in packs, so
"default theme from Nix" and "installed theme" produce identical output.

**Where themes live:**

| Location | Contents | Written by |
|---|---|---|
| store: `pkgs.loft-themes-builtin` (rendered) | A small built-in set: the default + a couple of light/dark basics | NixOS build (the only themes a build needs) |
| `~/.local/share/loft themes/<name>/` | Installed and user-authored packs | `loft theme install/new/import` |
| `/var/lib/loft/themes/<name>/` | Packs promoted for the **greeter** (sddm must read them) | polkit-allowed helper (§4.5) |
| `~/.local/state/loft/rendered/<name>/<hash>/` | Render cache, keyed by pack content + renderer/template hash | `loft theme apply` |
| `~/.local/state/loft/current` | Symlink to the active rendered theme (swapped atomically) | `loft theme apply` |

**Theme manager CLI** (`loft theme`; the shell's selector is a GUI over the same commands):

```
loft theme list [--installed|--available]        # local packs + index entries
loft theme vibes [<name>] [--json] [--dir DIR]    # wallpapers + lock designs that fit (own, curated, ranked)
loft theme apply <name>                          # render (cached) → swap current → reload hooks
loft theme install <git-url|tarball|path>        # any pack
loft theme install qylock:<theme> | qylock:all # importer: sparse-checkout that theme dir
loft theme install cozytile:<theme> | cozytile:all
loft theme install --list qylock:                # what an importer offers
loft theme new <name> [--from <theme>]           # scaffold a pack to author
loft theme edit <name>                           # live token editing (selector does this too)
loft theme export <name> [-o pack.tar.zst]       # share
loft theme remove <name>
```

**Importers** convert upstream themes into packs at install time. Nothing
third-party is committed here or built into a machine:
- `qylock:<theme>`: brings its lock/greeter QML + assets as the pack's
  `lock/qylock/` (manifest `lock: {format: qylock, path: lock/qylock}`).
  Palette: from the theme's `theme.conf` colors when present, otherwise
  extracted from its background (our own median cut + k-means in Python;
  video frames via ffmpeg), with an editable result. Playing video
  backgrounds needs gstreamer, which the engine module installs (cheap).
  The theme's own fonts go in the pack (inside `lock/qylock/`).
- `cozytile:<name>` (Cozy, Sakura, Natura, Everforest, Carbon): palette from
  its qtile/rofi colors and theme switcher (Carbon: its pywal `e-ink.json`),
  wallpaper, SDDM art → `greeter/`. Cozytile's SDDM themes are themselves
  qylock-format, so `greeter/` could also be declared as the pack's `lock`.

**Index for sharing:** `loft theme` reads one or more index URLs (JSON:
name → source, preview image). The default index is a repo of ours listing
our own packs plus the qylock/cozytile importer entries. Anyone can host one.

**Overrides and save-back** (§4.1): per-token tweaks go to
`overrides/theme-<name>.json`. `loft save --as-theme <new>` writes
a new **pack**. That pack can either stay installed locally, be exported for
sharing, or, with `--builtin`, be copied into this repo's `themes/` so Nix
ships it as a default.

**Stylix's role shrinks** to build-time fonts, cursor and the boot default.
Runtime themes own colors and glass. Set Stylix targets to *off* for anything
the runtime layer drives, so the two don't fight.

### 4.3 Glass: niri blur

- The shell requests blur through `ext-background-effect`. Whether Quickshell
  0.3.1 exposes this needs **verification**. If not, use niri `layer-rule`
  matches on our layer namespaces (`loft:bar`, `loft:dock`, …)
  with `background-effect { blur true }` plus the correct
  `geometry-corner-radius`.
- Use the default **xray** blur for the bar, dock and background-ish layers
  (cheap: computed once per wallpaper). Use **normal** blur for top/overlay
  layers (Control Center, Spotlight, notifications) via the `layer` matcher.
- Window blur: kitty `background_blur 1`; Ghostty gets it in v1.4. Add per-app
  `window-rule` blur only where an app can't request it itself.
- A per-theme `glass` block decides intensity and can turn blur off entirely.
  The gaming and focus workflow profiles in `desktop-design.md` should force it
  off.

### 4.4 Shell (`loft-shell`)

**Source:** `src/` in this repo (QML), packaged as `loft-shell`, a
`quickshell` wrapper with every runtime dependency on PATH.

**Runs as** a systemd user service bound to `graphical-session.target`, not a
niri `spawn-at-startup`, so it can be restarted, logs to the journal, and is
replaced cleanly during the Noctalia cut-over.

**Dev vs installed:** `nix run .#dev` (and the HM option `dev.source`, which
cody sets in the fleet) points Quickshell at the live checkout, so it
hot-reloads on save. Everyone else runs the store copy.

**Structure** (each component reads colors and metrics only from `Theme`):

```
src/
  shell.qml                 # thin: instantiates per-screen windows only
  services/                 # singletons: Niri (event-stream adapter), Theme,
                            #   Settings (defaults ⊕ overrides), Audio, Network,
                            #   Bluetooth, Power, Media, Notifications, Clipboard
  bar/                      # macOS menu bar: app menu/title, workspaces, tray, clock, status
  dock/                     # magnifying dock, pinned + running apps (niri windows)
  controlcenter/            # Wi-Fi, BT, audio devices/mixer, brightness, focus, night light
  island/                   # Dynamic Island: media, timers, recording, notifications
  switcher/                 # Cmd+Tab app switcher (niri windows grouped by app-id)
  osd/                      # volume / brightness / mic toasts
  settings/                 # settings app: writes overrides, shows "differs from default"
  theme-selector/
```

### 4.5 Lock screen and greeter (`loft-lock`)

- **One static loader, runtime designs.** NixOS installs a single SDDM theme
  and a single Quickshell lock, both thin *loaders*, plus qylock's vendored
  SDDM-API shim (GPL-3.0, kept in its own directory with its license). The
  loader `Loader`s the active theme's `lock/Main.qml` (a qylock-format
  design) and falls back to our default design (mac-style: big clock, glass
  card over the blurred wallpaper, avatar, password pill) colored by the
  palette. Through the shim, the *same* design runs as the **SDDM greeter**
  and as the **Quickshell lock screen** (`WlSessionLock` + PAM).
  - Installing or switching lock designs never needs a rebuild, and SDDM's
    configured theme name never changes.
  - qylock themes (`loft theme install qylock:…`) drop straight in, because
    they are already in this format.
- **Lock** follows the user's current theme from
  `~/.local/state/loft/current`.
- **Greeter** runs as `sddm` before login, so it reads
  `/var/lib/loft/greeter` (a symlink to a pack under
  `/var/lib/loft/themes/`). `loft theme apply --greeter` (or a
  "use for login screen too" toggle in the selector) copies the pack there
  through a narrow polkit-allowed helper, not Cozytile's blanket `sudo tee`.
  The Nix default theme is used until then. *Multi-user note:* the greeter
  theme is machine-wide, and the lock theme is per user.
- Integration: replace `theme = "MacTahoe-Dark"` in `sddm.nix` (otherwise a
  conflicting definition). Add qt6 multimedia/svg/5compat + gstreamer to the
  greeter's `extraPackages` so video backgrounds work. Drop swaylock and
  route swayidle → `loft-lock`. Don't use qylock's `lock.sh` (it
  `killall -9`s other lockers) or its flake module.

### 4.6 Launcher (walker)

- walker + elephant from nixpkgs via HM `services.walker` /
  `services.elephant` (service mode, `--gapplication-service`). Don't also
  import upstream's flake module, because both define the same units.
- Our theme: a Spotlight look (centered pill, large input, grouped results).
  Its `style.css` `@import`s the active theme's `walker.css`, so it
  recolors with no restart.
- Providers to enable: apps, calc, files, clipboard, symbols, runner,
  websearch, **niri actions/sessions**, windows, bluetooth, wireplumber.
- Binds: Cmd+Space (Spotlight) and Mod+Space. The shell's own app grid
  (Launchpad) stays optional.

---

## 5. Keyboard: macOS parity (decision needed)

The constraint is that **the same physical keys do the same thing on
THEBATTLESHIP and voyager.**

What exists on Linux today:

| Physical key | Linux today | macOS native |
|---|---|---|
| Super (Cmd position) | **Cmd**: app shortcuts via xremap (copy, paste, tabs, …) | Cmd |
| Caps (hold), Esc (hold), Right Ctrl | **niri Mod** (Mod5) | — |
| Ctrl | Ctrl (terminal signals) | Ctrl (terminal, Emacs text nav, **Ctrl+←/→ Spaces, Ctrl+↑ Mission Control**) |
| Alt | Option (word navigation) | Option |

**Option A, recommended: Caps-hold = WM key on both machines, plus mac-native Ctrl aliases.**
- Keep Linux as it is. On voyager, map Caps-hold → Hyper with kanata or
  Karabiner, managed from nix-darwin, and bind the WM (OmniWM per
  `desktop-design.md`) on Hyper. The whole WM layer is then identical.
- Add macOS's *own* WM-ish shortcuts on Linux too: Ctrl+←/→ = workspace
  left/right, Ctrl+↑ = niri overview (Mission Control), Ctrl+↓ = app windows.
  Muscle memory from stock macOS then works on niri as well.
- Ctrl+letters stay untouched (terminals, readline, Emacs-style text editing).

**Option B: Ctrl as the WM key (Cody's suggestion).** It mirrors macOS
Spaces for the arrows, but Ctrl+letters collide with terminal signals (C, D,
R, W, L, Z) and with Emacs text navigation in every macOS text field (A, E, K,
N, P). It needs per-app exceptions on both OSes.

Either way, add a **shortcut audit** against the macOS list and fill gaps in
`_mac-keybindings.nix` / niri binds:

- Cmd+Space Spotlight · Cmd+Tab / Cmd+` app switcher and same-app windows
- Cmd+Q quit app vs Cmd+W close window · Cmd+H hide · Cmd+M minimize
- Cmd+Shift+3/4/5 screenshots · Ctrl+Cmd+Q lock · Cmd+Opt+Esc force quit
- Cmd+, settings · Cmd+Ctrl+F fullscreen

Keep the bind table as **shared Nix data**, generating both niri `binds.kdl`
fragments and the voyager WM/kanata config. That answers the open question in
`desktop-design.md`.

---

## 6. Plan (phases)

Each phase ends with something runnable in the nested dev session (Phase 0),
and nothing replaces the working Noctalia session until Phase 6.

### Phase 0: Repo + dev loop *(do first)*
- Create `Codys-Wright/loft` (flake-parts) and
  `Codys-Wright/loft-themes`. Credit javiiervm in `CREDITS.md`.
- `nix run` / `nix run .#dev`: niri **nested as a window** (inside KDE
  today) with Loft's base niri fragments + a hello-world bar from `./src`.
  - niri hot-reloads KDL on save and Quickshell hot-reloads QML on save, so
    both iterate with no rebuild.
  - Blur, layer-shell, `WlSessionLock` (lock screen) and walker all work
    nested. The greeter uses `.#greeter-preview`.
- Package nirimod.
- **Fleet side:**
  - Add the `loft` input + `fleet.desktop._.loft` aspect (off by
    default). `settings.desktop.shell = "noctalia" | "loft"` picks per host.
  - Delete the stale `_niri-settings.nix` + `niri-wrapper.nix`.
  - Fix the `~/.flake` symlink so it applies to cody only (§2).

**Done when:** `nix run github:Codys-Wright/loft` opens a nested niri
window with a glass bar from any machine, and in a checkout `nix run .#dev`
updates live when KDL or QML is edited.

### Phase 1: Theme spine *(engine done — branch `phase1-theme-engine`)*

> **Status:** pack format (`docs/THEME-FORMAT.md`, `themes/schema.json`), the
> runtime renderer + `loft theme list|current|apply|render|validate`, the
> `current` symlink + render cache, reload hooks (shell IPC, niri, kitty,
> Ghostty, GTK color-scheme), consumers niri/kitty/Ghostty/GTK/walker/Noctalia,
> `pkgs.loft-themes-builtin` rendered by the same CLI, and checks (schema,
> unit, golden, `niri validate`, `ghostty +validate-config`) are in.
> **Not yet:** the `overrides/` directory (lands with the settings UI /
> `loft save`, §4.1) and the fleet-side Stylix narrowing.
>
> **Design notes / deviations:**
> - The CLI is Python (stdlib + `jsonschema`), replacing `cli/loft.sh`: JSON,
>   color math and tests are natural there, and Nix runs the same program for
>   the built-ins. Templates are `string.Template` files; all logic (derived
>   colors, conditional snippets) is in `cli/loft/render.py`.
> - Render cache is `rendered/<name>/<hash>/` rather than `rendered/<name>/`,
>   so `apply` never rewrites the directory `current` points into, and an
>   edited pack lands at a new path (which niri's watcher sees).
> - Sessions write their niri entry config at runtime (in `$XDG_RUNTIME_DIR`):
>   the theme fragment's path depends on the runtime state dir.
> - Extra optional keys beyond the sketch: `ansi`, `glass.terminalOpacity`,
>   `glass.shadow`, `radii.window`, `fonts` (see THEME-FORMAT.md).
> - `--dev` runs only the shell + niri hooks by default (terminals and GTK
>   belong to the host desktop); `LOFT_HOOKS` picks hooks explicitly.

- Theme pack format (`manifest.json` + `theme.json` core: palette + glass).
  Built-in packs: `tokyonight` (ported from Stylix, the current look) + one
  light theme.
- `loft theme` runtime renderer (also called by Nix for built-ins),
  `apply|list`, `current` symlink + overrides directory.
- Consumers: niri fragment (colors + blur), kitty, Ghostty, GTK, Noctalia
  `colors.json` (so it works before our shell exists).
- Stylix narrowed to fonts, cursor and the default.

**Done when:** `loft theme apply <light theme>` recolors niri (and toggles
blur), terminals, GTK and Noctalia live with no rebuild, and the default
theme comes from Nix.

### Phase 1b: Theme manager + importers *(manager + importers done; index TODO)*

> **Status:** `loft theme install <dir|tarball|tarball URL|git URL> [--subdir]
> [--force]` (validated against the schema, manifest required), `new [--from]`,
> `remove`, `export [-o pack.tar.zst]` are in. Importers (branch `importers`):
> `install [--list] cozytile:|qylock:<theme>[,…]|all[@ref]` fetch blob-less +
> sparse at install time and write `cozytile-<theme>` / `qylock-<theme>` packs
> (manifest `upstream` + `lock`; see docs/THEME-FORMAT.md "Importers").
> `cozytile:all` downloads ~15 MB; a qylock theme downloads only its own
> directory (0.3–78 MB). Index support is not started.

- `install|new|export|remove`, index support, `~/.local/share/loft themes`.
- `cozytile:` importer (all five) and `qylock:` importer (palette + assets;
  lock designs become usable in Phase 5).

**Done when:** `loft theme install cozytile:all` followed by `apply cozytile-sakura`
works on a machine whose build contains none of them. *(Met.)*

### Phase 1c: Vibes *(done — branch `vibes`)*

> **Status:** a pack carries a wallpaper collection (`wallpaper.images`,
> `wallpapers/`, videos flagged / represented by a still) and several lock
> designs (`locks`, `locks/<dir>/`; `lock` stays the default shorthand), plus
> curated `vibes` links to other packs' assets; the themes index adds vibe
> groups (sakura, forest, monochrome). `loft theme vibes [--json] [--dir]`
> ranks every other installed pack's wallpapers/locks (and loose images) by
> CIEDE2000 palette distance + image swatch distance (cached by hash). The
> importers bring all of a theme's wallpapers (cozytile: orphaned
> `Wallpaper/` images go to the closest palette; qylock: every background,
> a frame per video) and its SDDM design as a lock. Shell: `Vibes` service;
> Settings → Wallpaper / Lock Screen pages and the wallpaper carousel show
> "From <theme>" then "Matching vibes"; choices, rotation and per-workspace
> wallpapers are per theme (`overrides/shell.json` `perTheme`); "Preview
> lock" locks with the chosen design. See THEME-FORMAT.md, "Vibes".

**Open:** qylock designs need `SddmComponents`, `Qt5Compat.GraphicalEffects`
and `QtMultimedia` on the shell's QML import path; the packaged
`loft-shell` doesn't add them yet (they load in a session whose
environment already has them, e.g. a KDE session with SDDM installed).
Videos are not played as desktop wallpapers (the still is shown).

### Phase 2: Shell skeleton
- `src/` skeleton, `loft-shell` package, HM systemd user service, dev/installed split.
- Services: `Niri` adapter (event-stream), `Theme`, `Settings` (defaults ⊕
  overrides).
- Menu bar: workspaces, focused-app title, clock, tray, status icons. Glass +
  blur.

**Done when:** in nested niri, the bar tracks workspaces and focus, recolors
on `loft theme apply`, and a setting changed in `overrides/` applies live.

### Phase 3: Core shell features
- Dock, Control Center, notifications (Quickshell server), OSD, media,
  Dynamic Island, Cmd+Tab switcher, theme selector, wallpaper picker.
- Settings app (writes overrides and marks values that differ from the
  default).

### Phase 4: Launcher + save-back
- walker/elephant service, Spotlight theme wired to the theme bundle, binds.
- `loft diff|save|save --as-theme`.

**Done when:** a theme tweaked in the selector can be saved as a new theme
JSON in the repo, and it is the default after the next `just switch`.

### Phase 5: Lock + greeter
- Loader SDDM theme + loader Quickshell lock + vendored qylock shim. Default
  mac-style design, palette-driven.
- Lock wired to swayidle and Ctrl+Cmd+Q. The loader replaces MacTahoe-Dark.
  `apply --greeter` via the polkit helper.

**Done when:** `loft theme install qylock:nier-automata` + `apply --greeter`
changes both the lock screen and the login screen with no rebuild.

**Status (2026-10-13): lock + greeter landed; wiring to the fleet pending.**
- Lock: `src/lock/` (`WlSessionLock` + `PamContext`, IPC `lock lock`,
  `Mod+Ctrl+Q`). The built-in design lives in `src/lock/design/` and is
  host-agnostic (QtQuick + `Theme` + the glass components only). Frost is
  rendered in-scene (`FrostedGlass`: MultiEffect blur of the lock's own
  wallpaper under a `GlassSurface`), since a lock surface is opaque and there
  is nothing behind it for niri to blur.
- Greeter: `lock/sddm/` + `nix/lock.nix` → `packages.loft-sddm-theme`. The
  build copies `src/lock/design` + `GlassSurface`/`Icon` into the theme with
  `qs.*` imports rewritten to relative ones; `lock/sddm/services/Theme.qml`
  stands in for the shell's Theme. The build fails if the shared design ever
  imports Quickshell. `nix run .#greeter-preview` runs it in SDDM test mode.
- Pack designs: `<pack>/lock/Main.qml`, one file for both hosts; contract in
  [THEME-FORMAT-LOCK.md](THEME-FORMAT-LOCK.md).
- Robustness: a design that doesn't compile falls back to the built-in one.
  A marker in `$XDG_RUNTIME_DIR` makes a restarted shell re-lock if it died
  holding the lock, since niri keeps the session locked, showing a blank
  screen.

**Deviations from §4.5:**
- **qylock's shim is not vendored.** The default design is shared with SDDM
  by the build-time import rewrite. The lock's SDDM-API facade is ~60 lines
  routed to our single PAM conversation, while qylock's `SddmShim.qml` runs
  its own PamContext, calls `loginctl unlock-session` and enumerates sessions
  through bash, none of which suits a `WlSessionLock`. What qylock designs
  still need (its `SddmComponents` / Qt 5 `QtGraphicalEffects` compatibility
  modules, plus qt5compat/qtmultimedia on the shell's QML import path) belongs
  with the `qylock:` importer (Phase 1b), so the "Done when" above is not met
  yet.
- **Pack contract:** SDDM's API subset (so qylock-style designs load) plus a
  loft-native `lock` object (`tryUnlock`, `failed`, `busy`, `showInput`,
  `theme`, …), so one design file works under both hosts.
- **Not done yet:** swayidle wiring (documented in the README only), replacing
  MacTahoe-Dark in the fleet's `sddm.nix`, `apply --greeter` + polkit helper,
  and the greeter's `QML_XHR_ALLOW_FILE_READ=1` environment (fleet module).

**Known issues:**
- Quickshell 0.3.2 can't hot-reload while locked. `WlSessionLock`'s reload
  path creates new lock surfaces before taking over the old windows, and niri
  disconnects the client with a protocol error. The lock fails closed, and the
  marker re-lock recovers once the shell restarts. This only affects the dev
  loop (editing QML while locked), because installed configs never reload.
- Multi-monitor focus handling (password field only on the focused output)
  is untested: the nested dev session has a single output.

### Phase 6: Cut-over + keyboard parity
- Replace Noctalia in `startup.kdl`/aspects. Delete `noctalia` bits and
  `wlr-which-key` if the shell takes it over.
- Keyboard decision (§5) implemented on both machines from shared bind data.
  voyager gets kanata/Karabiner + WM config in nix-darwin.

### Phase 7+: Grow the system (the vorssaint-utils feature list)
Our own shell's backlog, with vorssaint-utils as the reference for "what a
complete menu-bar system does":

- per-app volume mixer · system monitor + fan control · window snapping
  presets · dock window previews · clipboard history + snippets · **file shelf**
  (drag-drop stash) · **Command Bar** (actions palette over niri + shell IPC) ·
  radial menu · screen capture/recording UI · keep-awake (caffeine) · …
- Plus a settings UI that covers nirimod's ground (monitor arrangement, bind
  conflicts, animation curves) inside our shell. That replaces nirimod once it
  exists.

---

## 7. Repo layouts

**Loft**
```
flake.nix                 # flake-parts; outputs in §1a
src/                      # loft-shell QML
  shell.qml  services/  bar/  dock/  controlcenter/  island/  switcher/  osd/  lock/  settings/  theme-selector/
lock/                     # SDDM loader theme (sddm/); the Quickshell lock is src/lock/
cli/                      # `loft` CLI: render, theme manager, importers (qylock, cozytile), diff/save, greeter helper
templates/render/         # per-consumer templates: niri.kdl, kitty.conf, ghostty, gtk.css, walker css, noctalia
themes/                   # built-in packs only (default + basics)
niri/                     # base KDL fragments (layout, animations, blur rules, binds, startup)
defaults/shell.json       # product defaults (layer 1)
nix/
  packages/  modules/nixos.nix  modules/home.nix  apps.nix  checks.nix
docs/PLAN.md  CREDITS.md  LICENSE
```

**loft-themes**
```
index.json                # name → source, preview; includes qylock:*/cozytile:* importer entries
packs/<name>/             # manifest.json, theme.json (palette + glass), optional wallpaper/fonts/lock/greeter/apps
```

**Fleet (`~/.flake`) after integration**
```
modules/desktop/loft/loft.nix              # fleet.desktop._.loft — flake-file input + wraps the modules
users/cody/_data/loft.json                 # cody's consumer defaults (saveTarget)
modules/desktop/environment/niri/_config/  # includes Loft base; host outputs/workspaces/rules stay here
```

Per-host knobs stay den settings on `fleet.desktop`:

```nix
den.hosts.x86_64-linux.THEBATTLESHIP.settings.desktop = {
  shell = "loft";           # "noctalia" | "loft" during the transition
  theme = "tokyonight";     # default; runtime can override
};
```

## 8. Open decisions

1. **Keyboard:** Option A (Caps-hold WM key on both + mac Ctrl aliases) or
   Option B (Ctrl as WM key)? *Recommend A.*
2. **Pack palette mapping for imports:** when a qylock or Cozytile theme has
   no explicit palette, extract it from the wallpaper (matugen/wallust) and
   let the user fix it in the editor. Or require hand-mapping each one once
   and publishing the results in our index? *Leaning: extract, then curate
   the ones we use.*
3. **Theme index home:** a separate public repo (e.g. `loft-themes`) holding
   our own packs + importer entries, or a directory in this repo?
4. **Shell name** (placeholder: `loft-shell`).
5. **voyager WM:** stay with OmniWM (as `desktop-design.md` plans), or
   AeroSpace, which has a richer config, for the parity layer?

### Decided
- Themes are mainly **palette + glass/blur state**. The design language
  (Liquid Glass, mac-like components) is fixed, and themes need not be
  mac-like.
- javiiervm/dotfiles is our **starting point** (author permission; credit in
  `CREDITS.md`, link TODO).
- qylock and Cozytile themes are **all** available, but only through the
  runtime theme manager, never as a build dependency. qylock: vendor the shim
  only, no flake input.

## 9. To verify early
- Quickshell 0.3.1 support for `ext-background-effect` (otherwise use niri
  `layer-rule` blur).
- ~~niri reloads when an *included* file changes, not only `config.kdl`.~~
  Yes: it polls every include (mtime + canonical path) every 500 ms.
- ~~Ghostty runtime config reload mechanics~~ (SIGUSR2, Ghostty ≥ 1.2);
  kitty `background_blur` on niri.
- Whether nirimod is in nixpkgs, and its `uv`-based install under Nix.
- The qylock shim works through a QML `Loader` from a runtime path under SDDM
  (`/var/lib/...` is readable by the `sddm` user, and QML import paths
  resolve).
- How many qylock themes ship a `theme.conf` palette vs need extraction.
