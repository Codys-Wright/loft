# Loft

(Formerly studio-linux.) A desktop for creative work, music production and programming: [niri](https://github.com/niri-wm/niri)
plus our own [Quickshell](https://quickshell.org) shell, with a macOS-inspired Liquid Glass design language
that is fully themeable at runtime.

```sh
nix run github:Codys-Wright/loft              # try it: opens as a nested niri window
```

## Develop

```sh
nix run .#dev                       # nested niri window running ./src, ./niri, ./themes — hot reload on save
nix run .#dev -- --output DP-1      # inside KDE: fullscreen on that monitor (default: the rightmost)
nix run .#loft -- --dev theme list
nix run .#loft -- --dev theme apply latte     # recolors the running session live (checkout templates/themes)
nix run .#shot -- out.png           # screenshot the dev session (--grid, --zoom, --window …)
```

Inside the nested session Mod is Alt (Super in a real session): Mod+Return terminal,
Mod+O overview, Mod+Shift+E quit.

Testing (agents included): `nix run .#dev -- --session NAME` starts an isolated, headless test
session (own bus, runtime dir and state; offscreen, software-rendered, exact size);
`nix run .#shot -- --session NAME --grid` screenshots it with a coordinate grid, and
`nix run .#input -- --session NAME click X Y` / `type` / `drag` / `bind mod+space` drives it.
See [docs/TESTING.md](docs/TESTING.md) and the `skills/loft-drive` agent skill.

## Designing live

`nix run .#dev` runs the whole desktop from this checkout in a nested niri window — inside
KDE it goes fullscreen and borderless on the rightmost monitor (`--output NAME` picks one,
`--windowed` keeps a normal window). Re-running it replaces the running session.

| You edit | What happens |
|---|---|
| QML (`src/**`) | hot reload on save — a "Reloaded" pill; open panels and the Settings page stay where they were |
| QML with an error | the error (file:line) is pinned on screen, the last good version keeps running; saving the fix reloads |
| niri KDL (`niri/*.kdl`) | niri reloads on save |
| a theme (`themes/*`, `loft theme apply`) | recolors everything live |
| launcher theme (`launcher/walker/themes/loft/*`) | next time the launcher opens |
| the CLI (`cli/loft/*`) | live — `loft` runs the checkout |
| Rust (`crates/*`) | `cargo build`; `target/debug` binaries shadow the packaged ones (restart the dev session once) |
| Nix (`nix/*`, runtime deps) | re-run `nix run .#dev` |

`Mod+Shift+R` (or `qs ipc call shell reload`) forces a reload.

## Themes

A theme is a pack (`manifest.json` + `theme.json`: palette + glass), rendered at runtime into
per-app fragments under `~/.local/state/loft/current/`. Format: [docs/THEME-FORMAT.md](docs/THEME-FORMAT.md).

```sh
loft theme list | current
loft theme apply latte                        # render (cached) → swap `current` → reload shell, niri, kitty, Ghostty, GTK
loft theme render tokyonight ./out            # just render a pack's files
loft theme new mytheme --from latte           # scaffold in the library's Packs/ (else ~/.local/share/loft/themes)
loft theme install ./pack | pack.tar.zst | https://…/repo.git [--subdir packs/x]
loft theme install cozytile:all               # importers convert upstream themes at install time
loft theme install qylock:pixel-sakura        #   (--list cozytile: / qylock: shows what's available)
loft theme export mytheme -o mytheme.tar.zst
loft theme remove mytheme
loft theme validate ./pack                    # against themes/schema.json
loft theme vibes [theme] [--json] [--dir ~/Pictures/Wallpapers]     # wallpapers + lock designs that fit
```

**Vibes.** A pack carries a collection of wallpapers (`wallpapers/`, `wallpaper.images`) and lock
designs (`locks`), plus curated links to other packs' (`vibes`, and groups in the
[themes index](https://github.com/Codys-Wright/loft-themes)). `loft theme vibes` lists
the theme's own, the curated ones, then every other installed pack's wallpapers and locks (and
loose images) ranked by color closeness (CIEDE2000 between palettes and between image swatches).
Settings → Wallpaper / Lock Screen and the wallpaper picker (`wallpaper toggle`) show the same
set; choices, rotation and per-workspace wallpapers are remembered per theme.

**Wallpaper sets.** A wallpaper per display and per niri workspace, with **Auto** filling the
rest from the theme's vibe set in the same tone and colors (cropped around each image's subject),
and **sets** that assign images by display role (main, left, right, portrait, …) so they fit any
desk; theme packs ship them as `wallpaperSets` ([THEME-FORMAT.md](docs/THEME-FORMAT.md#wallpaper-sets)).
Settings → Wallpaper → Displays & Workspaces, or:

```sh
loft wallpaper plan                           # every display + workspace: what it shows and why
loft wallpaper sets | set apply|save|delete NAME | shuffle | auto on|off
```

**Library.** `~/Documents/Themes` (`$LOFT_LIBRARY`; home-manager: `programs.loft.library`)
is one folder for everything: installed packs in `Packs/` (searched first; `install` and `new`
put packs there when the library exists) and your wallpapers in `Wallpapers/Topics/<Topic>/`.
`loft library sort` generates symlink views beside them, regenerated idempotently and never
touching real files or links it didn't make:

```
Wallpapers/Colors/<Red|Orange|Yellow|Green|Teal|Blue|Purple|Pink|Brown|Monochrome>/
Wallpapers/Tones/<Dark|Medium|Light>/
Wallpapers/Themes/<theme>/          # own + curated + the closest images (vibes score ≥ 0.6, top 24)
```

```sh
loft library sort [--json]                       # views + README.md + the index Settings → Wallpaper reads
loft library add a.jpg b.png --topic "Studio Ghibli" [--move]
loft library status [--json]
```

Topic images also rank among `theme vibes` matches (and in the wallpaper picker); Settings →
Wallpaper → Library browses by Topic, Color (+ tone) and Theme. Thumbnails are cached in
`<state>/cache/thumbs`.

Point your apps at the rendered fragments once; `apply` keeps them current:

| App | Add to its config |
|---|---|
| niri | `include optional=true "~/.local/state/loft/current/niri.kdl"` (after Loft's `base.kdl`; the Loft sessions do this) |
| kitty | `include ~/.local/state/loft/current/kitty.conf` |
| Ghostty | `config-file = ?~/.local/state/loft/current/ghostty.conf` |
| GTK 3/4 | `@import url("file:///home/you/.local/state/loft/current/gtk.css");` in `~/.config/gtk-{3,4}.0/gtk.css` |

`LOFT_HOOKS=none|all|shell,niri,kitty,ghostty,gtk` picks the reload hooks. From a checkout,
`python3 cli/loft …` runs the same CLI (the dev shell has `jsonschema`), and
`nix flake check` runs the schema, unit, golden-render and `niri validate` checks.

## Lock screen and login screen

`Mod+Ctrl+Q` (Ctrl+Cmd+Q on a Mac) locks: a session lock with PAM, a big clock, now playing
and a frosted card with the password field. The same design is the login screen, shipped as the
SDDM theme `loft` (`packages.loft-sddm-theme`). A theme pack can replace both with its own
`lock/Main.qml` ([docs/THEME-FORMAT-LOCK.md](docs/THEME-FORMAT-LOCK.md)) or ship several designs;
Settings → Lock Screen picks one per theme (any installed pack's) and previews it.

```sh
nix run .#greeter-preview           # the login screen in SDDM's test mode (opens a window)
qs ipc --path <shell> call lock lock
```

Locking on idle (swayidle):

```sh
swayidle -w timeout 300 'loft-lock' before-sleep 'loft-lock'
# where loft-lock = quickshell ipc --path <shell src> call lock lock
```

Using the login screen on NixOS:

```nix
environment.systemPackages = [ loft.packages.${system}.loft-sddm-theme ];
services.displayManager.sddm = {
  theme = "loft";
  # lets the greeter read /var/lib/loft/greeter/theme.json
  settings.General.GreeterEnvironment = "QML_XHR_ALLOW_FILE_READ=1";
};
# optional: a dedicated PAM service for the lock (default: "login")
security.pam.services.loft-lock = { };     # + LOFT_LOCK_PAM=loft-lock in the shell's environment
```

## Spotlight: apps, !bangs and Quicklinks

`Mod+Space` opens Spotlight (walker + elephant, `loft-launcher`). Besides apps, windows,
the calculator and niri actions:

| Type | |
|---|---|
| `!` | every DuckDuckGo bang (13,574, from [unduck](https://github.com/T3-Content/unduck)): your quicklinks and favorites first, then the most used |
| `!nixpk`, `!youtube`, `!yout` | fuzzy on the trigger, the name, the domain and the category; one row per site, with its favicon |
| Enter or Tab on a bang | the sub-search: the query becomes `!nixpkgs ` and the row says "Search NixOS Packages". Type, Enter opens the results in your browser. Backspace on the empty term leaves |
| `!yt lofi` | searches right away (a space after an exact trigger is the scope too) |
| `yt` | a quicklink keyword: the top result. Enter scopes to it, `yt lofi` searches directly, `gm` opens Gmail |
| `github.com` | Open https://github.com |
| anything else | the last row searches the default engine |

Ctrl+Enter opens a bang's site; Ctrl+K in a scope creates a quicklink for it. Settings →
Spotlight edits the default engine (Google, DuckDuckGo, Brave, Kagi, Bing, Startpage, Ecosia
or any bang), the favorite bangs and the quicklinks: a keyword, then a `!bang` or your own
URL with `%TERM%` (without it, the link just opens the page). Add one from a bang search,
reorder, test. They live in `<state>/spotlight.json`, seeded from
`launcher/spotlight-defaults.json`, and apply on the next keystroke.

How: an elephant provider, `launcher/elephant-bangs` (Go, built inside elephant's own
derivation as `loft-elephant`, since Go plugins only load into the exact binary they were
built with), ranks the bangs (~3 ms for all of them per keystroke) and answers plain queries
with the quicklinks, URLs and the default engine. Scoping needs walker to let a provider set
its query: `launcher/walker-set-query.patch` (`loft-walker`). The bang list is unduck's
`src/bang.ts` at a pinned rev (`loft-bangs` in `nix/packages.nix`: bump `rev` and `hash`
to refresh), converted by `launcher/bangs.py`, which also fixes the NixOS search URLs and adds
`!nixopts`, `!hmopts`, `!noogle` and `!kagi`.

## Dock

Right-click (or Ctrl-click, or long-press) an app: its windows, recent files, New Window and the
app's actions, Options ▸ (Keep in Dock, Open at Login, Show in Files, Assign To, Move to Desktop /
Display), Hide, Quit (hold Alt: Force Quit). Downloads sits left of the Trash as a stack (fan,
grid or list; drag files out), any folder can be added in Settings → Dock, and recent apps get
their own section. Each display has its own dock: position, and auto-hide never / always / when
windows are open. The helpers behind it are `loft dock …` (JSON for the shell):

```sh
loft dock recents | folder xdg:DOWNLOAD --sort added | trash [--empty]
loft dock autostart list | set ID on|off | run --once KEY
loft dock open ID FILE… | show PATH|ID | apps [ID…]
```

## Clipboard, snippets, shelf, scratchpad

| | |
|---|---|
| `Mod+Shift+V` | clipboard history: search, text/image previews, pins, Enter pastes into the focused app |
| `Mod+Shift+Alt+V` | paste as plain text |
| `Mod+Shift+Period` | snippet picker (edit snippets in Settings → Snippets) |
| `Mod+Shift+N` | scratchpad: tabbed, autosaved Markdown notes |

The shell records the clipboard itself (`wl-paste --watch cliphist store`, into cliphist's
usual db — turn it off in Settings → Clipboard & Files if you already run a recorder).
Pasting and snippets send keys with `wtype`, so they go to whatever window has keyboard
focus (Ctrl+V; Ctrl+Shift+V for terminals, matched by app id). Pins, snippets, the shelf
and notes live under `<state>/` (`clipboard/`, `snippets.json`, `shelf.json`,
`scratchpad.json`). The Shelf slides out when you drag something to the middle of the
right screen edge (Wayland only reports a drag to the surface under the pointer, so a thin
strip there is the sensor) or with `qs ipc … call shelf toggle`. IPC targets: `clipboard`
(toggle, pastePlain, clear, cleanUrl, wipe, settings), `snippets`, `shelf`, `scratchpad`.

## Menu bar: app menu and global menu

Click the focused app's bold name (or Mod+F10) for its app menu: About, New Window and
the `.desktop` file's actions, Move to Workspace / Display, Float, Full Screen, Center,
Hide (niri has no minimize: windows park on a `hidden-<output>` workspace until Show All),
Close and Quit. The app's own menus (File, Edit, View …) follow it in the bar; menus
take the keyboard (arrows, Enter, Esc, type to select) and hovering across titles
switches between them. Settings → Menu Bar.

The global menu comes from `loft-appmenu` (`crates/loft-appmenu`), which the shell
runs. It owns `com.canonical.AppMenu.Registrar`, so Qt/KDE apps started afterwards move
their menubar into the bar; it never takes the name from another registrar (Plasma's),
and finds menus by introspection then. GTK apps with a GtkApplication menubar show
theirs too (their in-window menubar stays); Electron does under XWayland when
libdbusmenu-glib is loadable. GTK4/libadwaita apps, Firefox and Wayland Electron have
no exported menubar.

```sh
printf '{"cmd":"focus","pid":%s}\n' "$(pidof kate)" | loft-appmenu     # → {"menu":{…}}
```

To try it from inside another desktop (KDE has its own registrar on your session bus),
run the nested session on a private bus: `dbus-run-session -- nix run .#dev`.

## niri settings

Loft Settings has Displays, Keyboard & Mouse, Layout & Motion and Keybinds pages,
backed by `loft-niri` (`crates/loft-niri`). Your own niri KDL is never edited:
changes are stored in `<state>/overrides/niri.json` and rendered (validated with
`niri validate`) into `<state>/overrides/niri.kdl`, which the Loft sessions include
**first** (niri uses the first `output` block matching a monitor) and **last** (every
other section merges, later wins). Displays are recorded by make/model/serial, never
by connector. With the home-manager module, `~/.config/loft/niri.kdl` includes
it last; add `include optional=true "~/.config/loft/niri-early.kdl"` at the top
of your niri config for display overrides to win over your own `output` blocks.

```sh
loft-niri outputs                         # live outputs, modes, identities
loft-niri output set DP-1 --scale 1.25 --render     # live + recorded (by identity)
loft-niri set layout.gaps 8 --render      # see `loft-niri keys`
loft-niri show                            # value + source (override / file:line / default)
loft-niri binds --conflicts               # keys bound more than once, and which wins
loft-niri reset [input|layout.gaps|…]     # drop overrides and re-render
```

Status: Phase 0 (dev loop), Phase 1 (theme engine + selector + Cozytile/qylock importers), the shell port (bar, dock, Control Center, Dynamic Island, OSD, switcher, notifications, wallpaper picker, Settings incl. niri Displays/Input/Layout/Keybinds), the Spotlight launcher, the System module (monitor, bar readouts, network, alerts; `qs ipc call monitor toggle`) and Phase 5 (lock + login screen). See [docs/PLAN.md](docs/PLAN.md). Themes: [loft-themes](https://github.com/Codys-Wright/loft-themes).
