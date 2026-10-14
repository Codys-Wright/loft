# Theme pack format

A **theme pack** is a directory. The machine-readable spec is
[`themes/schema.json`](../themes/schema.json) (JSON Schema 2020-12;
`studio theme validate <pack>` checks against it).

```
<name>/
  manifest.json       # who/what/license (required to install)
  theme.json          # the core: palette + glass (required)
  wall.png …          # optional assets, referenced from theme.json
  apps/<file>         # optional hand-written consumer files (override generated ones)
```

## manifest.json

```json
{
  "name": "tokyonight",
  "author": "studio-linux",
  "version": "1.0.0",
  "license": "Apache-2.0",
  "source": "https://github.com/folke/tokyonight.nvim",
  "description": "optional"
}
```

`name` is the pack's identity (`^[a-z0-9][a-z0-9._-]*$`; `default` is reserved
for the alias). `license` is an SPDX id, or `NOASSERTION`. `source` says where
the design comes from.

## theme.json

Only `palette` is required; every other key has a default. The normalized
`theme.json` written by `studio theme render` has every key filled in, and
that is what the shell reads.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `polarity` | `dark` \| `light` | `dark` | Drives defaults, ANSI ramp, GTK color-scheme |
| `palette.{bg,surface,overlay,text,subtext,accent,accent2,urgent,ok,warn}` | `#rrggbb` | required | Semantic roles every component reads. Extra `#rrggbb` keys pass through |
| `ansi` | 16 × `#rrggbb` | derived | Terminal colors; derived from the palette when absent |
| `glass.blur` | bool | `true` | Compositor blur. `false` turns niri blur **off** entirely and makes terminals opaque |
| `glass.xray` | bool | `true` | Blur only the wallpaper (cheap). `false` = real blur of what is behind |
| `glass.tint` | `#rrggbb` | `palette.bg` | Glass fill color |
| `glass.opacity` | 0..1 | 0.45 dark / 0.5 light | Glass fill opacity |
| `glass.border`, `glass.borderOpacity` | `#rrggbb`, 0..1 | `#ffffff`, 0.14 dark / 0.6 light | Glass hairline |
| `glass.radius` | px | 14 | Shell surface corner radius |
| `glass.noise`, `glass.saturation` | number | 0.02, 1.6 | niri blur noise / saturation |
| `glass.terminalOpacity` | 0..1 | 0.85 with blur, else 1 | kitty / Ghostty background opacity |
| `glass.shadow` | `#rrggbbaa` | `#00000066` dark / `#0000002e` light | niri window shadow |
| `wallpaper.gradient` | `#rrggbb[]` | bg → accent → accent2 blend | Shell fallback wallpaper |
| `wallpaper.image` | path | `""` | Relative to the pack (copied into the rendered bundle as `wallpaper.<ext>`), or absolute |
| `fonts.{ui,mono,size}` | string, string, number | sans-serif, monospace, 11 | Declaring `fonts` also sets the terminal font |
| `radii.window` | px | 12 | niri window corner radius |

Colors are `#rrggbb`. The only alpha color, `glass.shadow`, is CSS order
`#rrggbbaa` (Qt's `#aarrggbb` is never used in packs).

A legacy top-level `name` is accepted; `manifest.json`'s name wins.

## Rendered bundle

`studio theme render <pack> <outdir>` (and `apply`, into
`$STUDIO_STATE_DIR/rendered/<name>/<hash>/`) writes:

| File | Consumer | How it is used | Live reload on `apply` |
|---|---|---|---|
| `theme.json` | the shell | `$STUDIO_THEME_FILE` = `<state>/current/theme.json` | `quickshell ipc … call theme reload` |
| `manifest.json` | the theme selector | normalized manifest | — |
| `niri.kdl` | niri | `include optional=true "<state>/current/niri.kdl"` after `base.kdl` | niri watches the include (by canonical path); `niri msg action load-config-file` makes it immediate |
| `kitty.conf` | kitty | `include ~/.local/state/studio-linux/current/kitty.conf` | `SIGUSR1` |
| `ghostty.conf` | Ghostty | `config-file = ?~/.local/state/studio-linux/current/ghostty.conf` | `SIGUSR2` |
| `gtk.css` | GTK 3/4, libadwaita | `@import url("file://…/current/gtk.css");` from `~/.config/gtk-{3,4}.0/gtk.css` | `gsettings … color-scheme prefer-dark/light` |
| `walker.css` | walker | studio's walker theme `@import`s it as `colors.css` | walker re-reads CSS on every open |
| `noctalia.json` | Noctalia (transition only) | its `colors.json` | its own watcher |

The templates live in [`templates/render/`](../templates/render) and use
`${var}` placeholders (Python `string.Template`); the variables are computed in
`cli/studio/render.py`. A file in the pack's `apps/` replaces the generated file
of the same name (`theme.json` and `manifest.json` are always generated).
Extra `apps/` files (for consumers without a template yet) are copied as is.

## Authoring

```sh
studio theme new mytheme --from latte   # → ~/.local/share/studio-linux/themes/mytheme
$EDITOR ~/.local/share/studio-linux/themes/mytheme/theme.json
studio theme apply mytheme              # re-renders when the pack changed
studio theme export mytheme -o mytheme.tar.zst
```
