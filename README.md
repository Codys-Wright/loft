# studio-linux

A desktop for creative work, music production and programming: [niri](https://github.com/niri-wm/niri)
plus our own [Quickshell](https://quickshell.org) shell, with a macOS-inspired Liquid Glass design language
that is fully themeable at runtime.

```sh
nix run github:Codys-Wright/studio-linux      # try it: opens as a nested niri window
```

## Develop

```sh
nix run .#dev                       # nested niri window running ./src, ./niri, ./themes — hot reload on save
nix run .#dev -- --output DP-1      # inside KDE: fullscreen + borderless on that monitor
nix run .#studio -- --dev theme list
nix run .#studio -- --dev theme apply latte   # recolors the running session live (checkout templates/themes)
nix run .#shot -- out.png           # screenshot the dev session
```

Inside the nested session Mod is Alt (Super in a real session): Mod+Return terminal,
Mod+O overview, Mod+Shift+E quit.

## Themes

A theme is a pack (`manifest.json` + `theme.json`: palette + glass), rendered at runtime into
per-app fragments under `~/.local/state/studio-linux/current/`. Format: [docs/THEME-FORMAT.md](docs/THEME-FORMAT.md).

```sh
studio theme list | current
studio theme apply latte                      # render (cached) → swap `current` → reload shell, niri, kitty, Ghostty, GTK
studio theme render tokyonight ./out          # just render a pack's files
studio theme new mytheme --from latte         # scaffold in ~/.local/share/studio-linux/themes
studio theme install ./pack | pack.tar.zst | https://…/repo.git [--subdir packs/x]
studio theme export mytheme -o mytheme.tar.zst
studio theme remove mytheme
studio theme validate ./pack                  # against themes/schema.json
```

Point your apps at the rendered fragments once; `apply` keeps them current:

| App | Add to its config |
|---|---|
| niri | `include optional=true "~/.local/state/studio-linux/current/niri.kdl"` (after studio's `base.kdl`; the studio sessions do this) |
| kitty | `include ~/.local/state/studio-linux/current/kitty.conf` |
| Ghostty | `config-file = ?~/.local/state/studio-linux/current/ghostty.conf` |
| GTK 3/4 | `@import url("file:///home/you/.local/state/studio-linux/current/gtk.css");` in `~/.config/gtk-{3,4}.0/gtk.css` |

`STUDIO_HOOKS=none|all|shell,niri,kitty,ghostty,gtk` picks the reload hooks. From a checkout,
`python3 cli/studio …` runs the same CLI (the dev shell has `jsonschema`), and
`nix flake check` runs the schema, unit, golden-render and `niri validate` checks.

## niri settings

Studio Settings has Displays, Keyboard & Mouse, Layout & Motion and Keybinds pages,
backed by `studio-niri` (`crates/studio-niri`). Your own niri KDL is never edited:
changes are stored in `<state>/overrides/niri.json` and rendered (validated with
`niri validate`) into `<state>/overrides/niri.kdl`, which the studio sessions include
**first** (niri uses the first `output` block matching a monitor) and **last** (every
other section merges, later wins). Displays are recorded by make/model/serial, never
by connector. With the home-manager module, `~/.config/studio-linux/niri.kdl` includes
it last; add `include optional=true "~/.config/studio-linux/niri-early.kdl"` at the top
of your niri config for display overrides to win over your own `output` blocks.

```sh
studio-niri outputs                       # live outputs, modes, identities
studio-niri output set DP-1 --scale 1.25 --render   # live + recorded (by identity)
studio-niri set layout.gaps 8 --render    # see `studio-niri keys`
studio-niri show                          # value + source (override / file:line / default)
studio-niri binds --conflicts             # keys bound more than once, and which wins
studio-niri reset [input|layout.gaps|…]   # drop overrides and re-render
```

Status: Phase 0 (dev loop, glass bar + dock placeholder) and Phase 1 theme engine (render, apply, install). See [docs/PLAN.md](docs/PLAN.md). Themes: [studio-linux-themes](https://github.com/Codys-Wright/studio-linux-themes).
