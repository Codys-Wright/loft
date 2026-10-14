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
  lock/<design>/      # optional lock screen / greeter design, declared by manifest `lock`
  greeter/            # optional greeter art (e.g. an imported SDDM theme), kept for the greeter
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

Optional keys:

| Key | Meaning |
|---|---|
| `upstream` | Written by importers: `{"importer", "url", "ref", "commit", "path"}`, the exact upstream tree the pack was converted from |
| `lock` | `{"format", "path"}`: a lock screen / greeter design shipped in the pack (below). Absent: the default design, colored by the palette |

### Lock designs (`lock`)

```json
"lock": { "format": "qylock", "path": "lock/qylock" }
```

`path` is relative to the pack (or absolute). Format `qylock` is an
SDDM-API QML theme directory as qylock ships them: `metadata.desktop`
(`MainScript`, default `Main.qml`), `theme.conf` (the design's own settings:
`background`, `type=image|video|color`, `color`, `font`, …), its fonts
under `font/`, and its backgrounds (images or videos). The design is run by
the lock/greeter loader through qylock's SDDM shim (`SddmComponents`,
`QtMultimedia`, `Qt5Compat.GraphicalEffects` imports), never by the
renderer.

The rendered bundle's `manifest.json` carries `lock` with `path` made
absolute (pointing into the installed pack), so the lock reads
`<state>/current/manifest.json` and loads `<lock.path>/<MainScript>`. The
lock directory is not copied into the bundle and not part of the render
cache key (`lock/` and `greeter/` are skipped), so a 50 MB video doesn't slow
`apply`.

Overriding: edit `manifest.json` to point `lock.path` at another design
directory (relative or absolute), or delete `lock` to get the default
design with the pack's palette; drop your own qylock-format design into
`lock/<dir>/` of any pack and declare it the same way.

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

## Importers

`studio theme install <importer>:<theme>` converts an upstream theme into a
pack at install time (nothing third-party is vendored in this repo):

```sh
studio theme install --list cozytile:              # what an importer offers
studio theme install cozytile:all                  # cozytile-cozy, -sakura, -natura, -everforest, -carbon
studio theme install qylock:pixel-sakura,forest    # qylock-pixel-sakura, qylock-forest
studio theme install qylock:field@<branch|tag|full sha>   # pin the upstream tree
studio theme install --force cozytile:sakura       # replace an installed pack
```

Fetching is git, blob-less and sparse: one depth-1 fetch of the trees (a few
hundred KB, also what `--list` reads), then only the files a theme needs.
`STUDIO_<IMPORTER>_URL` overrides the upstream repo (mirrors, tests). Packs
are built in a staging dir, validated against the schema, then moved into
`~/.local/share/studio-linux/themes/`. `all` skips installed packs; a single
installed theme is an error without `--force`.

| Importer | Upstream (license) | Pack | Palette | Assets |
|---|---|---|---|---|
| `cozytile` | [Darkkal44/Cozytile](https://github.com/Darkkal44/Cozytile) (none: `NOASSERTION`) | `cozytile-<theme>` | Its own config: bg = the theme switcher's `wal -b` color (= qtile bar), surface = qtile widget pills, text = rofi foreground, accent = qtile workspace/widget foreground, accent2 = the rofi/qtile/SDDM highlight most distinct from the accent. A theme that loads a pywal JSON (Carbon: `e-ink.json`) takes bg/text/accent from its `special` colors | The switcher's wallpaper → `wallpaper.*`; `sddm-themes/<Name>/` → `greeter/` |
| `qylock` | [Darkkal44/qylock](https://github.com/Darkkal44/qylock) (GPL-3.0) | `qylock-<theme>` | `theme.conf` colors (`type=color` + `color` = bg, `accentColor`, `mainColor`, `containerColor`, `themeMode`; a lone `color` is the design's text color, or its accent when saturated), the rest from the background: a still, or a frame ~1 s into a video, quantized by median cut + k-means. No ffmpeg and a video: neutral dark palette | `themes/<theme>/` → `lock/qylock/` (+ `lock` in the manifest); a still background (or the video frame) → `wallpaper.*` |

Both fill roles the upstream lacks the same way (`cli/studio/importers/palette.py`):
overlay and subtext are mixed from surface/text/bg; urgent/ok/warn are red,
green and yellow hues nudged toward the accent; text and accents are pushed
to 4.5:1 / 3:1 contrast against bg only when they fall short; polarity
follows bg's luminance. The result is an ordinary pack: edit its
`theme.json` afterwards like any other.

Image sampling uses `ffmpeg` when it is on PATH (any image format, video
frames; the Nix-packaged `studio` has it) and otherwise a small pure-Python
PNG decoder, so a bare `python3` with no extra modules still imports PNG
backgrounds.

An importer is a module registered in `cli/studio/importers/__init__.py`
with `list_themes`, `resolve`, `pack_name`, `install(theme, dest, up)` and an
optional batched `prefetch`; the themes index
([studio-linux-themes](https://github.com/Codys-Wright/studio-linux-themes)
`index.json`, `"importers"`) names them by that key.

## Authoring

```sh
studio theme new mytheme --from latte   # → ~/.local/share/studio-linux/themes/mytheme
$EDITOR ~/.local/share/studio-linux/themes/mytheme/theme.json
studio theme apply mytheme              # re-renders when the pack changed
studio theme export mytheme -o mytheme.tar.zst
```
