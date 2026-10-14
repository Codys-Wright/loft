# Theme pack format

A **theme pack** is a directory. The machine-readable spec is
[`themes/schema.json`](../themes/schema.json) (JSON Schema 2020-12;
`loft theme validate <pack>` checks against it).

```
<name>/
  manifest.json       # who/what/license (required to install)
  theme.json          # the core: palette + glass (required)
  wall.png …          # optional assets, referenced from theme.json
  wallpapers/         # optional wallpaper collection (images; videos allowed, flagged)
  apps/<file>         # optional hand-written consumer files (override generated ones)
  lock/               # optional lock screen / greeter design (lock/Main.qml, or declared by `lock`)
  locks/<name>/       # optional further lock designs (picked up automatically)
  greeter/            # optional greeter art (e.g. an imported SDDM theme), kept for the greeter
```

## manifest.json

```json
{
  "name": "tokyonight",
  "author": "Loft",
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
| `lock` | `{"name"?, "format"?, "path", "preview"?}`: the pack's default lock screen / greeter design (below). Absent: `lock/Main.qml` when present, else the first of `locks`, else the built-in design colored by the palette |
| `locks` | More lock designs, same shape as `lock` |
| `vibes` | `{"wallpapers": [refs], "locks": [refs]}`: curated links to other packs' assets ([Vibes](#vibes)) |

### Lock designs (`lock`, `locks`)

```json
"lock": { "format": "qylock", "path": "lock/qylock" },
"locks": [ { "name": "night", "path": "locks/night", "preview": "locks/night.png" } ]
```

A pack can ship several designs. The default comes first: `lock` (a
shorthand for one entry), else the conventional `lock/Main.qml` (format
`loft`), then `locks`, then every `locks/<dir>/` holding a `Main.qml` or a
`metadata.desktop`. `name` (unique in the pack, how vibes refer to it)
defaults to `metadata.desktop`'s `Name`, else the pack name (or the
`locks/<dir>` name). `format` defaults to `qylock` when the directory has a
`metadata.desktop`, else `loft`. `preview` (a screenshot for the pickers)
defaults to `preview.*` / `screenshot.*` inside the design; without one the
pickers draw a small card in the source pack's colors over the design's
background (qylock `theme.conf` `background`, else the pack's wallpaper).

`path` is relative to the pack (or absolute). Format `loft` is a
`Main.qml` against [THEME-FORMAT-LOCK.md](THEME-FORMAT-LOCK.md). Format `qylock` is an
SDDM-API QML theme directory as qylock ships them: `metadata.desktop`
(`MainScript`, default `Main.qml`), `theme.conf` (the design's own settings:
`background`, `type=image|video|color`, `color`, `font`, …), its fonts
under `font/`, and its backgrounds (images or videos). The design is run by
the lock/greeter loader through qylock's SDDM shim (`SddmComponents`,
`QtMultimedia`, `Qt5Compat.GraphicalEffects` imports), never by the
renderer.

The rendered bundle's `manifest.json` lists every design (`locks`, with
absolute `path` and `main`, the entry file: a qylock design's `MainScript`)
and the default as `lock`, so the lock reads `<state>/current/manifest.json`
and loads `lock.main`. Lock directories (`lock/`, `locks/`, `greeter/`) are
not copied into the bundle and only their file names and sizes are part of
the render cache key, so a 50 MB video doesn't slow `apply`.

Choosing: Settings → Lock Screen picks any installed pack's design for the
active theme (stored per theme in `overrides/shell.json`, `perTheme.<theme>.lockDesign`;
`builtin` forces the built-in one). The lock loads, in order: that choice,
the theme's default, the built-in design. A design that fails to compile
falls back to the built-in one (the page shows why).

## theme.json

Only `palette` is required; every other key has a default. The normalized
`theme.json` written by `loft theme render` has every key filled in, and
that is what the shell reads.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `polarity` | `dark` \| `light` | `dark` | Drives defaults, ANSI ramp, GTK color-scheme |
| `palette.{bg,surface,overlay,text,subtext,accent,accent2,urgent,ok,warn}` | `#rrggbb` | required | Semantic roles every component reads. Extra `#rrggbb` keys pass through |
| `ansi` | 16 × `#rrggbb` | derived | Terminal colors; derived from the palette when absent |
| `glass.blur` | bool | `true` | Compositor blur. `false` turns niri blur **off** entirely and makes terminals opaque |
| `glass.xray` | bool | `true` | Blur only the wallpaper (cheap). `false` = real blur of what is behind |
| `glass.tint` | `#rrggbb` | `palette.bg` | Glass fill color |
| `glass.opacity` | 0..1 | 0.45 dark / 0.5 light | Glass fill opacity: the default of the Liquid Glass slider (Settings → Appearance; 0 ultraclear … 1 fully tinted) |
| `glass.border`, `glass.borderOpacity` | `#rrggbb`, 0..1 | `#ffffff`, 0.14 dark / 0.6 light | Glass hairline |
| `glass.radius` | px | 14 | Shell surface corner radius |
| `glass.noise`, `glass.saturation` | number | 0.02, 1.6 | niri blur noise / saturation |
| `glass.terminalOpacity` | 0..1 | 0.85 with blur, else 1 | kitty / Ghostty background opacity |
| `glass.shadow` | `#rrggbbaa` | `#00000066` dark / `#0000002e` light | niri shadow of the focused window; inactive windows get the same color at 40 % alpha (`inactive-color`) |
| `glass.edgeDarken` | 0..1 | 0.35 dark / 0.18 light | Darkened inner rim of glass surfaces (depth) |
| `glass.specular` | 0..1 | 0.5 dark / 0.75 light | Top specular highlight of glass surfaces |
| `wallpaper.gradient` | `#rrggbb[]` | bg → accent → accent2 blend | Shell fallback wallpaper |
| `wallpaper.image` | path | first still of the collection | The default wallpaper. Relative to the pack (copied into the rendered bundle as `wallpaper.<ext>`), or absolute |
| `wallpaper.images` | (path \| `{path, video?, preview?}`)[] | `[]` | More wallpapers ([Wallpapers](#wallpapers)) |
| `wallpaperSets` | `{name, description?, displays, workspaces?}`[] | `[]` | Multi-display arrangements by display role ([Wallpaper sets](#wallpaper-sets)) |
| `fonts.{ui,mono,size}` | string, string, number | sans-serif, monospace, 11 | Declaring `fonts` also sets the terminal font |
| `shape.windowRadius` | px | `radii.window`, else 12 | One corner radius for every window: niri's window rule (`geometry-corner-radius` + `clip-to-geometry`), the shell's own windows, GTK/libadwaita CSD |
| `shape.panelRadius` | px | 18 | Shell panels, popovers, cards |
| `shape.controlRadius` | px | 8 | Buttons, fields, sidebar rows |
| `bar.adaptiveText` | bool | `true` | Menu bar text/icons turn light or dark with the wallpaper under the bar (per output) |
| `bar.background` | bool | `false` | Draw a (clear) glass strip behind the menu bar. Golden Gate has none |
| `radii.window` | px | 12 | Legacy spelling of `shape.windowRadius` (which wins); the normalized theme.json still carries it |

Colors are `#rrggbb`. The only alpha color, `glass.shadow`, is CSS order
`#rrggbbaa` (Qt's `#aarrggbb` is never used in packs).

Runtime choices override some of these without touching the pack
(`<state>/overrides/shell.json`, `appearance`): `glass` (the Liquid Glass
slider, −1 = `glass.opacity`), `reduceTransparency` (flat opaque fills, no
blur, the menu bar gets a flat background), `blur`, `barBackground` and
`barAdaptiveText` (−1 = the theme). An older `appearance.glassOpacity`
override is moved into `glass` on load (same 0..1 scale). The material itself
is described in [DESIGN-GOLDEN-GATE.md](DESIGN-GOLDEN-GATE.md).

A legacy top-level `name` is accepted; `manifest.json`'s name wins.

### Wallpapers

A pack's collection, in order: `wallpaper.image`, `wallpaper.images`, then
the files of `wallpapers/` (sorted). An entry is a path, or
`{"path", "video", "preview"}` for a still that stands for a video (the
qylock importer writes a frame of each video background that way); in
`wallpapers/`, `x.jpg` next to `x.mp4` pairs the same way. A video with no
still is listed but flagged (`"kind": "video"`): the shell's image layer
can't play it. The default wallpaper is `wallpaper.image`, else the first
still. Old packs with a single `wallpaper.image` are unchanged.

The shell shows, per screen and its active niri workspace (all stored per
theme in `overrides/shell.json` `perTheme.<theme>`, so switching back restores
them; `cli/loft/wallsets.py` has the rules):

1. the workspace's own choice (`workspaces`: `{"<name>" | "<identity>#<idx>": path}`),
   then the pack's set for it (below) — skipped for a display set to "Use for
   all workspaces" (`sameAll`: `{"<identity>": true}`);
2. with **Auto** on (`auto`; default: on when at least 6 images match the
   theme) and not "same on all workspaces", an auto pick for every workspace
   but the display's first, related to the display's image;
3. the display's image: its choice (`displays`: `{"<niri identity>": path}`),
   the theme-wide choice (`wallpaper`), the pack's set for it, or an auto pick;
4. with rotation (`rotate`, minutes) or per-workspace (`perWorkspace`: niri
   workspace *n* shows the collection's *n*-th) on, one from the collection;
5. the default.

Auto picks (`loft wallpaper plan`) come from the theme's vibe set (own,
curated, then matches scoring ≥ 0.6 — the library's theme-view floor), only
in the theme's tone bucket (Dark / Medium / Light from the library's
classifier: the default wallpaper's tone, else by polarity; never the
opposite one), costed by color distance (to the theme, or for a workspace
to its display's image), a shared color family, the same folder (a series
stays together) and how much of the image's *interest* a display of that
shape keeps (edge + colorfulness saliency, sampled like the swatches,
cached in `<state>/cache/framing.json`). A hash of (seed, theme, display or
workspace, image) breaks near-ties, so picks are stable until Shuffle
(`autoSeed`) and distinct while the pool lasts. The wallpaper layer crops
each image around its interest too, so a landscape image on a portrait
display keeps its subject.

### Wallpaper sets

A set assigns wallpapers by **role**, not connector, so it fits any desk:

```json
"wallpaperSets": [
  {
    "name": "triptych",
    "description": "three displays, a series",
    "displays": { "main": "wallpapers/2020.jpg", "left": "wallpapers/3085.jpg", "right": "wallpapers/1157.jpg", "*": "wallpapers/any.jpg" },
    "workspaces": { "music": "wallpapers/8294.jpg", "main#2": "wallpapers/5635.jpg" }
  }
]
```

Roles come from the live layout: `main` (the largest display, or the one
Settings → Displays names), `left` / `right` / `top` / `bottom` of it
(`left-2` … further out), the shape (`portrait`, `ultrawide` ≥ 2.2:1,
`landscape`), the ordinal `display-1..N` (by x, then y), and `*` (any). A
display takes the first of its roles the set names, in that order. Workspace
keys are a niri workspace name or `<role>#<idx>`. Paths are relative to the
pack (or absolute); `loft theme validate` checks they exist and that role
names are known, the rendered `manifest.json` lists the sets with absolute
paths, and `loft theme export` carries the images like any pack file.

While the user has made no choice for the theme (no `wallpaper`, `displays`
or `workspaces`), the shell applies the pack's set that names the most
displays of a multi-display layout. Applying any set (Settings → Wallpaper →
Sets, `loft wallpaper set apply NAME`, IPC `wallpaper applySet NAME`)
writes its images as display and workspace choices; *Save as Set…* /
`loft wallpaper set save NAME` captures what is on screen (each display's
image under its primary role, workspaces that differ under their name or
`<role>#<idx>`) into `perTheme.<theme>.sets`, or with `--pack DIR` into a
pack's `theme.json` (images copied into its `wallpapers/`).

```sh
loft wallpaper plan [--theme T]              # what every display / workspace shows, and why
loft wallpaper sets                          # the pack's and saved sets
loft wallpaper set apply|save|show|delete NAME [--pack DIR]
loft wallpaper shuffle                       # new auto picks
loft wallpaper auto on|off|default
# --layout '{outputs: [{name, identity, x, y, width, height}], main, workspaces: [{output, idx, name}]}'
# (default: ask niri) and --choices JSON (default: shell.json) make it work without a session.
```

## Rendered bundle

`loft theme render <pack> <outdir>` (and `apply`, into
`$LOFT_STATE_DIR/rendered/<name>/<hash>/`) writes:

| File | Consumer | How it is used | Live reload on `apply` |
|---|---|---|---|
| `theme.json` | the shell | `$LOFT_THEME_FILE` = `<state>/current/theme.json` | `quickshell ipc … call theme reload` |
| `manifest.json` | the theme selector, lock loader, pickers | normalized manifest + `wallpapers` / `locks` / `defaults` with absolute paths (own, then curated) | — |
| `niri.kdl` | niri | `include optional=true "<state>/current/niri.kdl"` after `base.kdl` | niri watches the include (by canonical path); `niri msg action load-config-file` makes it immediate |
| `kitty.conf` | kitty | `include ~/.local/state/loft/current/kitty.conf` | `SIGUSR1` |
| `ghostty.conf` | Ghostty | `config-file = ?~/.local/state/loft/current/ghostty.conf` | `SIGUSR2` |
| `gtk.css` | GTK 3/4, libadwaita | `@import url("file://…/current/gtk.css");` from `~/.config/gtk-{3,4}.0/gtk.css`. Palette + accent, the window radius, traffic-light window buttons (put them on the left with `gtk-decoration-layout=close,minimize,maximize:` in `settings.ini`) | `gsettings … color-scheme prefer-dark/light` |
| `walker.css` | walker | Loft's walker theme `@import`s it as `colors.css` | walker re-reads CSS on every open |
| `noctalia.json` | Noctalia (transition only) | its `colors.json` | its own watcher |

The templates live in [`templates/render/`](../templates/render) and use
`${var}` placeholders (Python `string.Template`); the variables are computed in
`cli/loft/render.py`. A file in the pack's `apps/` replaces the generated file
of the same name (`theme.json` and `manifest.json` are always generated).
Extra `apps/` files (for consumers without a template yet) are copied as is.

## Importers

`loft theme install <importer>:<theme>` converts an upstream theme into a
pack at install time (nothing third-party is vendored in this repo):

```sh
loft theme install --list cozytile:                # what an importer offers
loft theme install cozytile:all                    # cozytile-cozy, -sakura, -natura, -everforest, -carbon
loft theme install qylock:pixel-sakura,forest      # qylock-pixel-sakura, qylock-forest
loft theme install qylock:field@<branch|tag|full sha>     # pin the upstream tree
loft theme install --force cozytile:sakura         # replace an installed pack
```

Fetching is git, blob-less and sparse: one depth-1 fetch of the trees (a few
hundred KB, also what `--list` reads), then only the files a theme needs.
`LOFT_<IMPORTER>_URL` overrides the upstream repo (mirrors, tests). Packs
are built in a staging dir, validated against the schema, then moved into
the library's `Packs/` (`~/Documents/Themes/Packs`, `$LOFT_LIBRARY`) when
it exists, else `~/.local/share/loft/themes/`. `all` skips installed packs; a single
installed theme is an error without `--force`.

| Importer | Upstream (license) | Pack | Palette | Assets |
|---|---|---|---|---|
| `cozytile` | [Darkkal44/Cozytile](https://github.com/Darkkal44/Cozytile) (none: `NOASSERTION`) | `cozytile-<theme>` | Its own config: bg = the theme switcher's `wal -b` color (= qtile bar), surface = qtile widget pills, text = rofi foreground, accent = qtile workspace/widget foreground, accent2 = the rofi/qtile/SDDM highlight most distinct from the accent. A theme that loads a pywal JSON (Carbon: `e-ink.json`) takes bg/text/accent from its `special` colors | `sddm-themes/<Name>/` → `greeter/`, declared as the pack's `lock` (qylock format). Wallpapers: the switcher's (the default; upstream it is the same file as the SDDM `Background`, which is then referenced instead of copied), the SDDM background when it differs, and each `Wallpaper/` image no theme sets, given to the theme whose palette is closest to the image's colors (→ `wallpapers/`) |
| `qylock` | [Darkkal44/qylock](https://github.com/Darkkal44/qylock) (GPL-3.0) | `qylock-<theme>` | `theme.conf` colors (`type=color` + `color` = bg, `accentColor`, `mainColor`, `containerColor`, `themeMode`; a lone `color` is the design's text color, or its accent when saturated), the rest from the background: a still, or a frame ~1 s into a video, quantized by median cut + k-means. No ffmpeg and a video: neutral dark palette | `themes/<theme>/` → `lock/qylock/` (+ `lock` in the manifest). Every background (theme.conf's, plus other images/videos ≥ 200 KB, e.g. osu's `background/A..G`, Genshin's dawn/day/dusk/night) is a wallpaper: stills referenced in place, videos as a frame in `wallpapers/` noting the video (no ffmpeg: the video, flagged) |

Both fill roles the upstream lacks the same way (`cli/loft/palette.py`, shared with vibe matching):
overlay and subtext are mixed from surface/text/bg; urgent/ok/warn are red,
green and yellow hues nudged toward the accent; text and accents are pushed
to 4.5:1 / 3:1 contrast against bg only when they fall short; polarity
follows bg's luminance. The result is an ordinary pack: edit its
`theme.json` afterwards like any other.

Image sampling uses `ffmpeg` when it is on PATH (any image format, video
frames; the Nix-packaged `loft` has it) and otherwise a small pure-Python
PNG decoder, so a bare `python3` with no extra modules still imports PNG
backgrounds.

Vibe links the themes index declares for an imported pack (see below) are
written into its `manifest.json` `vibes`, so they hold offline too.

An importer is a module registered in `cli/loft/importers/__init__.py`
with `list_themes`, `resolve`, `pack_name`, `install(theme, dest, up)` and an
optional batched `prefetch`; the themes index
([loft-themes](https://github.com/Codys-Wright/loft-themes)
`index.json`, `"importers"`) names them by that key.

## Vibes

Which wallpapers and lock designs go with a theme:

```sh
loft theme vibes cozytile-sakura                   # text; default: the current theme
loft theme vibes --json --dir ~/Pictures/Wallpapers --limit 20     # what the shell's pickers read
```

1. **own**: the pack's wallpapers and lock designs;
2. **curated**: refs in the manifest's `vibes`, plus the [themes index](https://github.com/Codys-Wright/loft-themes)
   `"vibes"` groups (`{"name", "packs": [...], "wallpapers"?, "locks"?}`: every
   member gets the others' assets). Refs are `<pack>:<file>` (wallpapers, a
   path in that pack), `<pack>:<lock name>`, or `<pack>` for all of its. Only
   installed packs resolve; the rest are skipped. The rendered manifest lists
   them too (and installing a linked pack re-renders on the next `apply`);
3. **match**: every other installed pack's wallpapers and locks, plus the
   images of `--dir` and the library's topic folders (entries note their `topic`),
   ranked by distance (with a 0..1 `score`).

Distance, in CIELAB (CIEDE2000): between two palettes, the weighted mean
over bg (3), accent (2), surface, text, accent2 (1 each; the accents are
matched either way round), plus 20 when the polarities differ; between two
images, every median-cut / k-means swatch's distance to the nearest swatch of
the other, weighted by its share, both ways. An asset's distance is the mean
of its pack's palette vs the theme's and its image vs the theme's default
wallpaper (a lock: its background, else its pack's wallpaper; a theme with
no wallpaper stands in with its palette). Below ~15 is the same vibe, 30+
unrelated. Image swatches are cached by content hash in
`$LOFT_STATE_DIR/cache/palettes.json`.

The index is read from `$LOFT_THEME_INDEX` (a path, `file://` or http(s)
URL; `none` turns it off), by default the GitHub raw URL, cached a day in
`$LOFT_STATE_DIR/cache/index.json`; unreachable means no index links, never
an error.

## Authoring

```sh
loft theme new mytheme --from latte     # → ~/.local/share/loft/themes/mytheme
$EDITOR ~/.local/share/loft/themes/mytheme/theme.json
loft theme apply mytheme                # re-renders when the pack changed
loft theme export mytheme -o mytheme.tar.zst
```
