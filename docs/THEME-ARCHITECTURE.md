# Theme architecture: facets, themes, variants

Status: **spec, partly implemented**: phases A (model + resolver), B (render units,
composition cache, hook diffing), C (packs, library, migration) and D (CLI surface) have landed; see [§9 Status](#status). It replaces the "a theme is one pack
with one `theme.json`" model of [THEME-FORMAT.md](THEME-FORMAT.md) and absorbs the
`wallsets` branch (multi-display wallpaper sets). The companion spec
[SPACES.md](SPACES.md) uses this model to give each functional space its own theme
or wallpapers.

Cody's brief: *blur and animations should be separate from the theme, and a full theme
picks animations and the rest. The theme elements are Colors, Wallpapers, Animations,
Blur and so on. Themes are collections of those settings. Any one of them can be
overridden and saved as a new theme, or better, as a variation, so there aren't lots of
duplicate themes.*

## 0. Names (the Loft rename)

This spec uses the Loft names. Until the rename lands, read them as follows:

| Loft (this spec) | Today |
|---|---|
| `loft` CLI, `cli/loft/` | `studio` CLI, `cli/studio/` |
| `~/.local/state/loft/` (`$LOFT_STATE_DIR`) | `~/.local/state/studio-linux/` (`$STUDIO_STATE_DIR`) |
| `~/.local/share/loft/packs/` | `~/.local/share/studio-linux/themes/` |
| library `~/Documents/Loft/` (`$LOFT_LIBRARY`) | `~/Documents/Themes/` (`$STUDIO_LIBRARY`) |
| `LOFT_*` env (reads `STUDIO_*` as a fallback for one release) | `STUDIO_*` |
| `loft-dev`, `loft-shot`, `loft-input`, `loft-niri` | `studio-dev`, `studio-shot`, `studio-input`, `studio-niri` |
| SDDM theme `loft`, `/var/lib/loft/greeter` | SDDM theme `studio`, `/var/lib/studio-linux/greeter` |
| `programs.loft` (NixOS / home-manager) | `programs.studio-linux` |
| `skills/loft-drive` | `skills/studio-drive` |
| themes repo `loft-themes` | `studio-linux-themes` |

## 1. The model in one picture

```
            ┌──────────────── Theme "cozytile" ─────────────────┐
            │ name, author, tags, preview, collection           │
            │ facets:  colors ─────────► colors:cozy            │
            │          wallpapers ─────► wallpapers:cozy        │
            │          material ───────► material:imported      │   facets are separate,
            │          motion ─────────► motion:loft            │   reusable documents,
            │          shape ──────────► shape:loft             │   referenced by id
            │          typography ─────► typography:loft        │
            │          icons ──────────► icons:system           │
            │          lock ───────────► lock:cozytile/cozy     │
            │          launcher ───────► launcher:spotlight     │
            │ variants: sakura  { colors, wallpapers, lock }    │   small overrides,
            │           carbon  { colors, wallpapers, lock }    │   never copies
            └───────────────────────────────────────────────────┘
                      ▲ selected theme + variant
   user layer:   pins (all themes) · customizations (this theme) · space override · accessibility
                      │
                      ▼  loft resolve → one resolved document per facet → render units → current/
```

- A **facet** is one independent aspect of the look, stored as its own JSON document
  (`colors:tokyonight-night`, `motion:snappy`). Facets don't know about themes.
- A **theme** is a named collection: one facet choice per kind, plus metadata. It holds
  references, and inline data only where it patches a referenced facet.
- A **variant** is a named delta on a theme ("Storm", "Light", "Minimal motion"): a few
  facet selections, layered on the theme. No pack is copied.
- The **user layer** holds customizations on top of the active theme (shown as
  "Customized"), *pins* (choices kept for every theme), the active space's override and
  accessibility switches. "Save as Variant…" turns customizations into a variant (the
  diff only); "Save as New Theme…" writes a new theme of references.

## 2. Facets

Ten kinds. "Pure data" facets are read by the shell or lock as resolved JSON. "Rendered"
facets also feed per-app files (niri KDL, GTK CSS, terminals, walker) or system settings.

| Kind | id prefix | Pure data / rendered | Consumers |
|---|---|---|---|
| Colors | `colors:` | rendered | shell tokens, niri (ring/border/overview), GTK, kitty, Ghostty, walker, lock, greeter, `color-scheme` |
| Wallpapers | `wallpapers:` | pure data | shell wallpaper layer, WallpaperTone, lock (`lock.wallpaper`), greeter (promoted copy) |
| Material | `material:` | rendered | shell GlassSurface tokens, niri `blur {}` + xray rules, terminal opacity / blur, walker glass |
| Motion | `motion:` | rendered | shell animation tokens, niri `animations {}` |
| Shape | `shape:` | rendered | shell radii, niri window rule radius, gaps, border, focus ring, shadows, GTK radius |
| Typography | `typography:` | rendered | shell fonts, GTK `font-name` / `monospace-font-name`, kitty / Ghostty font, walker CSS |
| Icons & Cursor | `icons:` | rendered (settings) | shell icon theme, GTK `icon-theme`, `cursor-theme` / `cursor-size`, niri `cursor {}` |
| Lock & Login | `lock:` | pure data (+ greeter promotion) | lock screen loader, SDDM greeter |
| Launcher | `launcher:` | rendered | walker theme (layout + CSS) |
| Sounds (optional) | `sounds:` | pure data (+ settings) | shell event sounds, `org.gnome.desktop.sound theme-name` |

Every facet document has the same envelope:

```json
{
  "$schema": "https://loft.dev/schema/facet-1.json",
  "kind": "material",
  "id": "liquid-glass",
  "name": "Liquid Glass",
  "description": "Golden Gate glass: blur, tinted fill, dark rim, bright specular",
  "author": "Loft",
  "tags": ["glass"],
  "preview": "previews/liquid-glass.png",
  "data": { … kind-specific … }
}
```

Two value forms are allowed in every kind except Colors:

- **Polar values**: an object with exactly the keys `dark` and `light`, e.g.
  `"opacity": {"dark": 0.45, "light": 0.5}`, is replaced by the side that matches the
  resolved Colors polarity. This is how one facet serves light and dark themes. Today's
  defaults already work this way in `pack.normalize`.
- **Color references**: `"@bg"` … `"@warn"` (any palette role), `"@mix(bg,#ffffff,0.5)"`,
  `"@alpha(text,0.22)"`. These are resolved against the resolved palette. With them, the
  44 imported glass blocks (41 distinct today, but only because `tint` copies `bg`; there are just four opacity/border presets) become
  three facets.

### 2.1 Colors

Data: palette and polarity, from today's `theme.json` `polarity`, `palette`, `ansi` and
`wallpaper.gradient`. The gradient belongs here because it is pure color: it is the
fallback when the Wallpapers facet has no image.

```json
{
  "kind": "colors", "id": "tokyonight-night", "name": "Tokyo Night",
  "source": "https://github.com/folke/tokyonight.nvim", "license": "Apache-2.0",
  "data": {
    "polarity": "dark",
    "palette": { "bg": "#1a1b26", "surface": "#24283b", "overlay": "#414868",
                 "text": "#c0caf5", "subtext": "#a9b1d6", "accent": "#7aa2f7",
                 "accent2": "#bb9af7", "urgent": "#f7768e", "ok": "#9ece6a", "warn": "#e0af68" },
    "ansi": null,
    "gradient": ["#16161e", "#2a3a6e", "#6b4fa3"]
  }
}
```

Rendered into: shell tokens (`Theme.bg` …), `niri.kdl` (focus ring, border, overview
backdrop, shadow color comes from Shape + polarity), `gtk.css`, `kitty.conf`,
`ghostty.conf` colors, `walker.css`, `gsettings color-scheme`. Role rules, contrast
fixes and ANSI derivation stay in `palette.py` / `pack.derive_ansi`.

### 2.2 Wallpapers (absorbs `wallsets`)

Data: a collection, a default, optional named **sets** (multi-display arrangements by
role, from `wallsets`), and default behavior (rotation, per-workspace, auto-fill).
Paths are relative to the document's pack, or absolute.

```json
{
  "kind": "wallpapers", "id": "genshin", "name": "Genshin: four times of day",
  "data": {
    "collection": [
      "wallpapers/dawn.jpg",
      { "path": "wallpapers/day.jpg", "video": "lock/qylock/day.mp4" },
      "wallpapers/dusk.jpg", "wallpapers/night.jpg"
    ],
    "dirs": ["wallpapers/"],
    "default": "wallpapers/day.jpg",
    "behavior": { "rotate": 0, "perWorkspace": false, "auto": false },
    "sets": [
      { "name": "Day and night", "displays": { "main": "wallpapers/day.jpg",
                                              "left": "wallpapers/night.jpg", "*": "wallpapers/dusk.jpg" },
        "workspaces": { "main#2": "wallpapers/dawn.jpg" } }
    ],
    "related": ["wallpapers:qylock-star-rail"]
  }
}
```

- `collection` keeps today's item shape (`path | {path, video?, preview?}`). `dirs`
  replaces the implicit `wallpapers/` scan.
- `sets` is `wallsets`' `wallpaperSet` unchanged: display roles `main`,
  `left|right|top|bottom[-N]`, `portrait|landscape|ultrawide`, `display-N`, `*`, and
  workspace keys `<niri name>` or `<role>#<idx>`. The pack's best-covering set applies on
  a multi-display layout while the user has made no choice, the same rule `wallsets`
  implements.
- `related` replaces manifest `vibes.wallpapers`. Curated links are now facet refs, not
  `<pack>:<file>`.
- Machine-specific keys (niri identities such as `"Microstep MPG491CX OLED Unknown"`)
  are allowed **only in the user layer**, never in a pack.

The user's choices are a patch on this facet, stored as customizations (§4). Every key
`wallsets` keeps in `perTheme.<theme>` maps one to one onto `data.arrangement`:

```json
"arrangement": {
  "wallpaper": "",                                  // one image on every display
  "displays":  { "<identity|role>": "/abs/x.jpg" },
  "workspaces":{ "<name>|<identity>#<idx>": "/abs/y.jpg" },
  "sameAll":   { "<identity>": true },
  "auto": true, "autoSeed": 3,
  "activeSet": "Day and night"
}
```

Saved sets (`wallsets`' `sets` in `perTheme`) become **standalone wallpapers facets** in
the library (`Wallpapers/Sets/<id>.json`). "Save Set…" is "save this arrangement as a
Wallpapers facet", and any theme can then use it. What a screen shows keeps `wallsets`'
precedence order exactly (workspace choice > pack set for W > display base > auto >
rotation / per-workspace > default). Only where the choices come from changes.

Not rendered. The resolved document goes into `current/wallpapers.json`, which the shell
(`Vibes.qml` / `wallsets.js`), the lock and the pickers read. The vibe ranking
(`loft wallpapers vibes`) is unchanged and ranks against the resolved Colors.

### 2.3 Material (glass, blur, transparency)

Data: today's `glass.*` (minus `radius` and `shadow`), `bar.*`, and the defaults behind
Settings → Appearance.

```json
{
  "kind": "material", "id": "liquid-glass", "name": "Liquid Glass",
  "data": {
    "blur": { "enabled": true, "xray": true, "noise": 0.02, "saturation": 1.6 },
    "glass": {
      "opacity": { "dark": 0.45, "light": 0.5 },
      "tint": { "dark": "@bg", "light": "@mix(bg,#ffffff,0.5)" },
      "border": "#ffffff", "borderOpacity": { "dark": 0.14, "light": 0.6 },
      "edgeDarken": { "dark": 0.35, "light": 0.18 },
      "specular": { "dark": 0.5, "light": 0.75 }
    },
    "terminals": { "opacity": null, "blur": true },
    "windows": { "translucent": true, "opacity": { "focused": 0.9, "unfocused": 0.8 }, "blur": true },
    "menuBar": { "background": false, "adaptiveText": true }
  }
}
```

`glass.opacity` is the **Liquid Glass slider's default**. Moving the slider writes a
customization patch `{"glass": {"opacity": 0.35}}`. `terminals.opacity: null` means
"0.85 with blur, else 1", as today. **Reduce Transparency** is an accessibility switch
(§4.4), not material data. It clamps the resolved material (flat fills, `blur.enabled =
false`, menu bar background on), so every material behaves the same under it.

`windows` is app windows' translucency: theme.json `windows` (off without blur, so a
glassless theme and Reduce Transparency keep windows opaque), which loft-niri turns into
niri window rules (Settings → Window Rules overrides it per user and per app).

Rendered into: shell `Theme.glass*` tokens, `niri.kdl` `blur {}` + xray rules, kitty
`background_opacity` / `background_blur`, Ghostty opacity, `walker.css` glass.

### 2.4 Motion (animations)

Data: one speed, the shell's duration and curve tokens, niri's `animations` block, and
an optional "minimal" flag.

```json
{
  "kind": "motion", "id": "loft", "name": "Loft",
  "data": {
    "speed": 1.0,
    "shell": {
      "durations": { "instant": 90, "fast": 160, "normal": 260, "slow": 420 },
      "curves": {
        "standard":   [0.2, 0.0, 0.0, 1.0],
        "emphasized": [0.05, 0.7, 0.1, 1.0],
        "exit":       [0.3, 0.0, 0.8, 0.15]
      },
      "spring": { "damping": 0.82, "stiffness": 380 }
    },
    "niri": {
      "workspace-switch": { "spring": { "damping-ratio": 1.0, "stiffness": 1000, "epsilon": 0.0001 } },
      "window-open":  { "duration-ms": 150, "curve": "ease-out-expo" },
      "window-close": { "duration-ms": 150, "curve": "ease-out-quad" },
      "horizontal-view-movement": { "spring": { "damping-ratio": 1.0, "stiffness": 800, "epsilon": 0.0001 } },
      "window-movement": { "spring": { "damping-ratio": 1.0, "stiffness": 800, "epsilon": 0.0001 } },
      "window-resize":   { "spring": { "damping-ratio": 1.0, "stiffness": 800, "epsilon": 0.0001 } },
      "overview-open-close": { "spring": { "damping-ratio": 1.0, "stiffness": 800, "epsilon": 0.0001 } }
    },
    "minimal": false
  }
}
```

- `speed` multiplies every shell duration (÷) and becomes niri's `slowdown` (= 1/speed).
  It replaces Settings → Layout & Motion's "Animation speed", which writes
  `animations.slowdown` into `overrides/niri.json` today.
- `niri` keys are niri's own animation names and fields, passed through by the renderer
  (validated with `niri validate`). An omitted key keeps niri's default.
- Shipped facets: `motion:loft` (default), `motion:snappy` (speed 1.5, shorter springs),
  `motion:calm` (speed 0.8), `motion:minimal` (`minimal: true`: crossfades only in the
  shell, niri `animations { off }`).
- **Reduce Motion** (accessibility) forces `minimal` behavior on top of any motion.

Rendered into: `niri.kdl` `animations {}` and shell tokens. Shell code stops
hard-coding durations (197 `Behavior` / `duration` / `easing` sites today) and reads
`Theme.motion.dur("fast")` / `Theme.motion.curve("standard")` (§6.4).

### 2.5 Shape

Data: radii (today's `shape.*` plus `glass.radius`), gaps, border, focus ring, shadows.
"Focus ring vs shadows" is an explicit choice.

```json
{
  "kind": "shape", "id": "loft", "name": "Golden Gate",
  "data": {
    "radius": { "window": 12, "panel": 18, "control": 8, "surface": 14 },
    "gaps": 8,
    "focus": "shadow",
    "focusRing": { "width": 2 },
    "border": { "enabled": false, "width": 1 },
    "shadow": {
      "softness": 30, "spread": 4, "offset": { "x": 0, "y": 6 },
      "opacity": { "dark": 0.4, "light": 0.18 }, "inactive": 0.4
    }
  }
}
```

`focus` is `"shadow"` (Golden Gate: the focused window has the larger, deeper shadow and
no ring), `"ring"` (ring in `@accent`, small shadows), or `"both"`. The shadow color is
black at the polar opacity, which reproduces today's `#00000066` / `#0000002e`.
`gaps: null` leaves niri's / the user's gaps alone. Gaps are layout as much as look, so
a `layout.gaps` override in `overrides/niri.json` always wins.

Rendered into: `niri.kdl` (window rule radius + clip, `layout { gaps, focus-ring,
border, shadow }`), `gtk.css` radius, shell `Theme.*Radius`.

### 2.6 Typography

```json
{
  "kind": "typography", "id": "loft", "name": "System",
  "data": {
    "ui":      { "family": null, "size": 11, "weight": "regular" },
    "mono":    { "family": "JetBrainsMono Nerd Font", "size": 11 },
    "display": { "family": null },
    "applyTo": { "terminals": false, "gtk": false },
    "fonts": []
  }
}
```

`family: null` means the font the shell ships (`$LOFT_UI_FONT`), which is today's
behavior. `applyTo` keeps today's rule that only packs which declare fonts take over the
terminal font, and extends it to GTK. `fonts` lists font files shipped in the pack. On
apply they are linked into `~/.local/share/fonts/loft/<pack>/` and `fc-cache` runs once.
qylock packs carry fonts today under `lock/qylock/font/`.

Rendered into: shell `Theme.fontUi` / `fontMono` / sizes, kitty / Ghostty font lines,
`walker.css` font, and with `applyTo.gtk` `gsettings org.gnome.desktop.interface
font-name / monospace-font-name`.

### 2.7 Icons & Cursor

```json
{
  "kind": "icons", "id": "mactahoe", "name": "MacTahoe",
  "data": {
    "icons":  { "theme": "MacTahoe-blue", "fallback": "Adwaita" },
    "cursor": { "theme": "MacTahoe-cursors", "size": 24 },
    "requires": ["mactahoe-icon-theme", "mactahoe-cursors"]
  }
}
```

`icons:system` (the default) sets nothing, so home-manager's `gtk.iconTheme` /
`programs.loft.iconTheme` stay in charge. Themes are names that must already be
installed. `loft icons list` checks `$XDG_DATA_DIRS/icons`, and the UI greys out missing
ones and shows the `requires` package names. A Nix-built system can't install icon
themes at runtime, so they come from `programs.loft.extraIconThemes`.

Rendered (settings, not files): `gsettings icon-theme`, `cursor-theme`, `cursor-size`;
`niri.kdl` `cursor { xcursor-theme; xcursor-size }`. The shell reads its icon theme from
`QS_ICON_THEME` at startup, so an icon change asks the shell to restart (Quickshell
can't switch it live). New windows pick up the cursor, and running apps keep theirs.

### 2.8 Lock & Login

A lock facet **is** a lock design: today's `lockDesign` plus options for the built-in
one.

```json
{
  "kind": "lock", "id": "qylock-forest", "name": "Forest",
  "data": {
    "format": "qylock", "path": "lock/qylock", "preview": "lock/qylock/preview.png",
    "config": { "font": "Pixelify Sans" },
    "wallpaper": "design",
    "greeter": "same"
  }
}
```

- `format`: `loft` (Main.qml against [THEME-FORMAT-LOCK.md](THEME-FORMAT-LOCK.md)),
  `qylock`, or `builtin` (`lock:loft`: the macOS-style card; its options
  `clock`, `nowPlaying`, `blur` live in `data.options`).
- `config` overlays the design's `theme.conf` (the SDDM `config` map).
- `wallpaper`: `"design"` (its own background), `"desktop"` (what the screen shows, as
  `lock.wallpaper` today), or a path.
- `greeter`: `"same"`, `"builtin"`, or another `lock:` ref. The greeter is
  machine-wide: `loft theme apply --greeter` promotes the resolved lock and colors (plus
  the wallpaper when `greeter` uses it) to `/var/lib/loft/greeter` through the polkit
  helper.
- Pure data. `current/manifest.json` keeps `lock` / `locks` for the loaders, so
  `src/lock/` and `lock/sddm/` don't change.

### 2.9 Launcher

```json
{ "kind": "launcher", "id": "spotlight", "name": "Spotlight",
  "data": { "style": "spotlight", "css": null, "layout": null, "width": 680, "glass": 1.6 } }
```

`style` picks a walker theme under `launcher/walker/themes/<style>` (Loft's own), or a
pack's `css` / `layout` files. `glass` is the launcher's glass strength relative to the
material (today's hard-coded `opacity × 1.6`). Rendered into `walker.css` (it `@import`s
the colors part) and the walker theme symlink.

### 2.10 Sounds (optional)

```json
{ "kind": "sounds", "id": "none", "data": { "theme": null, "events": {}, "volumeFeedback": false } }
```

`theme` is a freedesktop sound theme name (`gsettings org.gnome.desktop.sound
theme-name`). `events` maps Loft events (`lock`, `unlock`, `screenshot`, `notification`,
`trash`, `volume`) to files in the pack. It is pure data for the shell, and ships after
everything else.

### 2.11 What is *not* a facet

Layout (column widths, struts, center-focused-column), keybinds, displays, dock contents
and menu bar items are behavior, not look. They stay in `overrides/niri.json` /
`overrides/shell.json`. Spaces can switch some of them (SPACES.md). Traffic-light
colors and badge colors stay fixed product tokens.

## 3. Themes and variants

### 3.1 Theme document

```json
{
  "$schema": "https://loft.dev/schema/theme-2.json",
  "kind": "theme",
  "id": "loft",
  "name": "Loft",
  "author": "Loft",
  "description": "The default: Tokyo Night by night, Catppuccin Latte by day, on Liquid Glass",
  "tags": ["default", "glass"],
  "collection": "builtin",
  "preview": "previews/loft-dark.png",
  "facets": {
    "colors": "colors:tokyonight-night",
    "material": "material:liquid-glass",
    "motion": "motion:loft",
    "shape": "shape:loft",
    "typography": "typography:loft",
    "icons": "icons:system",
    "lock": "lock:loft",
    "launcher": "launcher:spotlight"
  },
  "base": { "id": "dark", "name": "Dark" },
  "variants": [
    { "id": "light", "name": "Light", "preview": "previews/loft-light.png",
      "facets": {
        "colors": "colors:catppuccin-latte",
        "material": { "ref": "material:liquid-glass", "patch": { "glass": { "tint": "#ffffff" } } }
      } }
  ],
  "appearance": { "dark": "dark", "light": "light" },
  "aliases": ["tokyonight", "latte@light", "default"]
}
```

- `facets` maps a kind to a **selection**. An omitted kind takes the product default
  (`<kind>:loft`, or `wallpapers:none`, which shows the colors' gradient).
- `base` names the theme without any variant applied, so it shows up as a chip. Without
  `base` the chip says the theme's name.
- `appearance` maps the global Light / Dark / Auto switch to variants. The switch is
  enabled only for the polarities a theme maps.
- `collection` groups themes in pickers and menus (`builtin`, `cozytile`, `qylock`,
  `user`, or anything else).
- `aliases` keep old names working: `loft theme apply tokyonight`, and today's
  `perTheme.tokyonight` keys (`alias@variant` points at a variant).

### 3.2 Selections

A **selection** (one facet slot in a theme, variant, pin, customization or space) is one
of:

| Form | Meaning |
|---|---|
| `"colors:x"` | shorthand for `{"ref": "colors:x"}` |
| `{"ref": R}` | the facet document R |
| `{"patch": P}` | JSON Merge Patch (RFC 7386) of P onto the result so far |
| `{"ref": R, "patch": P}` | R, then P |
| `{"inline": D}` | an anonymous facet whose `data` is D (packs only, for one-off values) |

### 3.3 Variants

```json
"variants": [
  { "id": "storm", "name": "Storm", "facets": { "colors": "colors:tokyonight-storm" } },
  { "id": "storm-calm", "name": "Storm, minimal motion", "extends": "storm",
    "facets": { "motion": "motion:minimal" } }
]
```

`extends` names another variant of the same theme (at most 4 deep, no cycles). A
variant's facets are applied after its ancestors'. Variant ids are unique per theme.
On the command line and in IPC a variant is `theme@variant` (`cozytile@sakura`).

**User variants on read-only themes.** Built-in and imported themes are read-only. Saving
a variant of one writes a **theme extension** to the library. It is merged into the
theme's variant list and marked "yours":

```json
// ~/Documents/Loft/Themes/cozytile.variants.json
{ "kind": "theme-extension", "extends": "theme:cozytile",
  "variants": [ { "id": "sakura-glassy", "name": "Sakura, clear glass", "extends": "sakura",
                  "facets": { "material": { "patch": { "glass": { "opacity": 0.2 } } } } } ] }
```

### 3.4 Resolution: exact order and merge rules

For each facet kind `k`, with the theme `T`, variant chain `V₁ … Vₙ` (root ancestor
first) and the user state from §4:

```
layers(k) =  T.facets[k]
          ++ V₁.facets[k] … Vₙ.facets[k]
          ++ pins[k]
          ++ space.facets[k]                  (when the active space overrides k; SPACES.md)
          ++ customizations[T]["*"][k]
          ++ customizations[T][Vₙ][k]

S := ⊥
for sel in layers(k):                          # absent layers are skipped
    if sel has ref:    S := copy(doc(sel.ref).data)        # REPLACE: discards everything below
    if sel has inline: S := copy(sel.inline)
    if sel has patch:  S := merge_patch(S ?? {}, sel.patch)  # RFC 7386: objects recurse,
                                                              # arrays and scalars replace,
                                                              # null deletes the key
R := fill(defaults[k], S)       # deep: missing keys only; arrays are never merged
R := polar(R, colors.polarity)  # {dark, light} → one side          (not for colors)
R := refs(R, colors.palette)    # "@role", "@mix(…)", "@alpha(…)"   (not for colors)
R := accessibility(k, R)        # Reduce Motion / Reduce Transparency / Increase Contrast
```

- **A reference replaces, a patch deep-merges.** Picking another facet in a layer
  discards the patches below it. A customized slider survives a variant change only if
  the variant doesn't re-reference that kind.
- Colors resolve first, because every other kind needs `polarity` and `palette`.
- Pins sit **below** the active space and per-theme customizations: the more specific a
  choice is, the more it wins.
- `fill` uses the product default document of the kind (`defaults/<kind>.json`, the
  values `pack.normalize` hard-codes today). It is what makes a facet that sets
  three keys valid.
- Validation happens on the final `R` (`schemas/<kind>.json`). A failing layer is
  reported with its source (`customizations.cozytile.*.material: glass/opacity: 1.4 >
  1`), and that layer is dropped. Apply never fails because of a bad customization.

## 4. User state

### 4.1 Files

```
~/.local/state/loft/
  appearance.json        selection, appearance mode, pins, customizations, accessibility (§4.2)
  current -> rendered/compositions/<hash>      the active composition (§6)
  rendered/units/<unit>/<digest>/…             per-unit render cache
  rendered/compositions/<hash>/                symlinks to units + resolved.json
  overrides/shell.json   non-theme shell settings (dock, island, …; appearance/perTheme migrate out)
  overrides/niri.json    niri overrides (animations.* migrate out to Motion)
```

### 4.2 `appearance.json`

```json
{
  "version": 1,
  "theme": "cozytile",
  "variant": "sakura",
  "mode": "dark",
  "pins": {
    "typography": "typography:sf-pro",
    "material": { "patch": { "glass": { "opacity": 0.35 }, "menuBar": { "background": false } } }
  },
  "customizations": {
    "cozytile": {
      "*":      { "motion": "motion:snappy" },
      "sakura": { "wallpapers": { "patch": { "arrangement": {
                    "displays": { "Microstep MPG491CX OLED Unknown": "/home/cody/Documents/Loft/Wallpapers/Topics/Avatar - The Last Airbender/aang.jpg" },
                    "auto": true } } } }
    }
  },
  "accessibility": { "reduceMotion": false, "reduceTransparency": false, "increaseContrast": false }
}
```

- `mode`: `light | dark | auto`. Applying a mode picks `theme.appearance[mode]`. `auto`
  follows the Night Light schedule.
- **Where a customization is stored** (the one non-obvious rule): when you change kind
  `k` while on variant `V`, it goes under `customizations[T][V]` if `V` or one of its
  ancestors selects `k`, otherwise under `customizations[T]["*"]`. Effect: on a
  Light/Dark theme whose variants only change colors, a material tweak applies to both
  polarities, while a palette tweak on Dark stays on Dark.
- A pin is the same selection, applied to every theme. The UI sets it with "Use for All
  Themes" on a facet row.
- `loft` is the only writer (the shell calls it). The file is watched, and edits apply
  on the next `loft theme apply` (the CLI runs it after every write).

### 4.3 Customized, reset, save

| Action | Effect |
|---|---|
| "Customized" badge on kind `k` | `customizations[T]["*"][k]` or `[T][V][k]` exists |
| "All themes" badge on `k` | `pins[k]` exists and no customization overrides it |
| Reset `k` | delete both customization slots of `k` for `T` (pins untouched) |
| Reset Customizations | delete `customizations[T]` |
| **Save as Variant…** (name) | new variant `{id, name, extends: V (if any), facets: {k: C[k]}}`, where `C[k]` is the two customization slots of `k` folded into one selection (the last ref wins; patches after it are merged). It is written into the theme (user theme) or its extension (read-only theme), then `customizations[T]` is cleared and the new variant is selected. Pins are not copied |
| **Save as New Theme…** (name, ☑ include all-theme choices, ☐ include variants) | new `Themes/<id>.json` whose `facets[k]` is every layer of `k` folded into one selection: `{ref: last ref, patch: merged patches after it}`. That is references plus small patches, never copied data. `basedOn: "cozytile@sakura"`. With variants on, the theme's variants are copied too (they are references, so they stay small) |
| **Save Facet As…** (on a facet page) | promote the resolved `k` into a named facet (`Materials/my-glass.json`) and replace the customization with a ref to it, so other themes can use it |

### 4.4 Accessibility

`reduceTransparency` (today `appearance.reduceTransparency`) makes material flat and
opaque, turns blur off and gives the menu bar a background. `reduceMotion` makes motion
minimal. `increaseContrast` is new: text and subtext reach 7:1, and borders become 100 %
`overlay`. These are system preferences. The Theme pages show and toggle them, but they
are stored outside themes and are never saved into a variant.

## 5. Storage and format

### 5.1 Pack v2 (the unit of install, update, export and license)

```
cozytile/                         one importer = one pack (partial installs allowed)
  pack.json                       identity, license, upstream, what it provides
  themes/cozytile.json
  facets/colors/{cozy,sakura,natura,everforest,carbon}.json
  facets/wallpapers/{cozy,sakura,natura,everforest,carbon}.json
  facets/lock/{cozy,sakura,natura,everforest,carbon}.json
  locks/<name>/…                  design dirs (QML, theme.conf, fonts, backgrounds)
  wallpapers/…                    images
  previews/…
  apps/<file>                     hand-written consumer files (as today; replaces a rendered unit's file)
```

```json
// pack.json
{
  "$schema": "https://loft.dev/schema/pack-2.json",
  "format": 2,
  "id": "cozytile", "name": "Cozytile", "author": "Darkkal44", "version": "0.0.0+bca91c3f6874",
  "license": "NOASSERTION", "source": "https://github.com/Darkkal44/Cozytile",
  "upstream": { "importer": "cozytile", "url": "https://github.com/Darkkal44/Cozytile",
                "ref": "HEAD", "commit": "bca91c3f6874c6b66826adda938b6ab0e5689a44" }
}
```

Facets are found by walking `facets/<kind>/*.json`, and themes by walking `themes/*.json`.
A pack never needs to list them. `loft pack index` caches the walk in
`<state>/cache/facets.json`, keyed by pack mtimes.

**v1 compatibility.** A directory with `theme.json` and no `pack.json` is a v1 pack. It
loads through an adapter that synthesizes `colors:`, `material:`, `shape:`,
`typography:` (if `fonts`), `wallpapers:` (if any image), `lock:` (each design) and a
`theme:` with the pack's name. Old packs from the themes index keep working with no
migration.

### 5.2 The library

```
~/Documents/Loft/                 ($LOFT_LIBRARY; moved from ~/Documents/Themes, which becomes a symlink)
  Themes/<id>.json                your themes (Save as New Theme…)
  Themes/<theme>.variants.json    your variants of read-only themes
  Colors/<id>.json                your palettes
  Materials/  Motion/  Shapes/  Typography/  Icons/  Launcher/  Sounds/   <id>.json
  Locks/<id>/                     your lock designs (+ facet doc Locks/<id>.json, optional)
  Wallpapers/
    Topics/<Topic>/…              your images (as today)
    Sets/<id>.json                saved arrangements = wallpapers facets
    Colors/ Tones/ Themes/        generated views (as today; `loft library sort`)
  Packs/<pack>/                   installed packs (importers, downloads)
  Spaces/                         see SPACES.md
  .loft-library.json              generated index (was .studio-library.json)
```

The library root acts as an implicit writable pack with id `user`. Its kind folders hold
loose facet documents, and the `kind` field must match the folder.

### 5.3 Ids and references

- Grammar: `<kind>:<name>` or `<kind>:<pack>/<name>`, with `name` and `pack` matching
  `^[a-z0-9][a-z0-9._-]*$`. Themes: `<theme>` or `<theme>@<variant>`.
- An unqualified name is looked up in: **(1)** the pack of the document that refers to
  it, **(2)** `user`, **(3)** built-ins, **(4)** every other pack. If (4) finds more than
  one, that's an error, and `validate` lists the qualified spellings.
- Built-in facets live in the repo as the `loft` pack: `themes/` becomes
  `packs/loft/{pack.json,themes/,facets/,previews/}` and holds `colors:tokyonight-night`,
  `colors:catppuccin-latte`, `material:{liquid-glass,imported,imported-dense}`,
  `motion:{loft,snappy,calm,minimal}`, `shape:loft`, `typography:loft`,
  `icons:{system,mactahoe}`, `lock:loft`, `launcher:spotlight`, `sounds:none`.

### 5.4 Schemas and versioning

- `schemas/pack-2.json`, `schemas/theme-2.json`, `schemas/facet-1.json` (the envelope),
  plus `schemas/facets/<kind>.json` for each kind's `data`. Today's `themes/schema.json`
  stays as `schemas/pack-1.json` for the v1 adapter.
- `pack.json` `format` (2) is the pack format version. A facet's `$schema` URL carries
  its own version (`facet-1`), so a kind's data can evolve on its own:
  `schemas/facets/motion-2.json` plus an upgrader in `cli/loft/facets/<kind>.py`
  (`upgrade(data, from_version)`).
- `appearance.json` `version` is migrated in place by the CLI, the way `Settings.qml`
  migrates `glassOpacity` today.

### 5.5 Migration (`loft library migrate`, dry run by default)

Steps, each idempotent:

1. Move `~/Documents/Themes` to `~/Documents/Loft` and leave a symlink at the old path.
   Move `~/.local/state/studio-linux` to `~/.local/state/loft`, and `.studio-library.json`
   to `.loft-library.json`.
2. **Convert every v1 pack** through the v1 adapter, then **deduplicate**. Facets with
   equal resolved `data` (after rewriting `tint == bg` as `"@bg"` and light tints as
   `"@mix(bg,#ffffff,0.5)"`, and after rewriting the polar defaults) merge into one
   facet. Lock designs and images are compared by content hash, so identical files are
   hard-linked rather than copied.
3. **Group into themes with variants**, with explicit rules, not guesses:
   - packs whose `upstream.importer` + `upstream.url` match and that the importer declares
     as one rice (cozytile: all five) become one theme with variants;
   - packs with an identical colors facet (and identical wallpapers) become one theme
     with variants that differ in what's left (qylock osu / osumania: only the lock);
   - `x` + `x-dark` / `x-light` siblings become one theme with `appearance` variants
     (qylock material-you / material-you-dark, today's `baseName` rule in
     `DesktopMenu.qml`);
   - built-in `tokyonight` + `latte` become `loft` with `dark` / `light`.
4. Write `aliases` so every old pack name resolves (`qylock-osumania` →
   `qylock-osu@mania`).
5. **Convert user state**:
   - `overrides/shell.json` `appearance.{glass, blur, barBackground, barAdaptiveText}`
     were global, so they become **pins** (material patches). For Cody that is
     `pins.material.patch = {glass: {opacity: 0.35}, menuBar: {background: false}}`;
   - `appearance.reduceTransparency` → `accessibility.reduceTransparency`;
   - `perTheme.<name>.{wallpaper, displays, workspaces, sameAll, auto, autoSeed,
     activeSet}` → `customizations[<theme>][<variant or *>].wallpapers.patch.arrangement`
     (the name goes through the aliases). `perTheme.<name>.sets` → `Wallpapers/Sets/*.json`.
     `perTheme.<name>.lockDesign` → a `lock` customization ref (`"builtin"` → `lock:loft`);
   - global `wallpaper.{rotate, perWorkspace}` and `lock.design` → pins;
   - `overrides/niri.json` `animations.off` / `animations.slowdown` → a motion pin
     (`{ref: motion:minimal}` / `{patch: {speed: 1/slowdown}}`), removed from niri.json.
   - the original files are kept as `*.pre-loft.json`.
6. Re-render and apply the same theme. The result is checked to look the same (§8 test
   M1).

**Cody's packs** (2 built-in + 44 in `~/Documents/Themes/Packs`, inspected read-only):

| Input | Becomes |
|---|---|
| `tokyonight`, `latte` (built-in) | theme `loft`: variants Dark / Light. Facets: 2 colors, material `liquid-glass` (Light variant patches `tint: #ffffff`), shape / motion / typography / lock / launcher `loft`. The gradients move into the colors |
| `cozytile-{cozy,sakura,natura,everforest,carbon}` (5) | theme `cozytile`: base Cozy + variants Sakura, Natura, Everforest, Carbon (`appearance`: dark → cozy, light → carbon). 5 colors, 5 wallpapers (Natura's has 2 images), 5 locks (the `greeter/` designs). All share material `imported` (their glass is `palette.glass(busy=False)`: 0.48 / 0.52, `tint @bg`) and every other facet |
| `qylock-material-you` + `qylock-material-you-dark` | theme `qylock-material-you`: Light / Dark variants (2 colors, 2 wallpapers, 2 locks) |
| `qylock-osu` + `qylock-osumania` (same palette, same 7 wallpapers; only the lock differs) | theme `qylock-osu`: base osu! + variant Mania. 1 colors, 1 wallpapers, 2 locks |
| the other 35 qylock packs | 35 themes (collection `qylock`), each 1 colors + 1 wallpapers + 1 lock |
| `qylock-nothing` (no image) | no wallpapers facet (its colors' gradient); material `imported` (no background to be busy) |
| glass of every qylock pack with a background | material `imported-dense` (`palette.glass(busy=True)`: 0.55 / 0.60) |

Totals: **46 packs → 39 themes with 7 variants** (loft 1, cozytile 4, material-you 1, osu 1;
11 chips counting the bases). Facets: **45 colors** (2 + 5 + 38),
**42 wallpapers** (5 + 37), **45 locks** (built-in + 5 + 39), **3 materials**, and
**one each** of motion, shape, typography, icons, launcher, all shared by every theme.
Today the same information is spread over 46 `theme.json`s (the 44 installed ones carry 41 distinct glass blocks)
and 46 copies of every other default. The 588 MB of `Packs/` stay where they are, since
only JSON moves. osu / osumania share their 37 MB through hard links.

Why 35 + 2 qylock themes and not one "Qylock" theme with 37 variants: each qylock design
is a different lock and different art, picked by name. Variants are for *versions of one
look*. The menu and the picker group them by `collection` (§7), so the long list costs
nothing (open question Q1).

**Importers write v2.** `cozytile` writes into a single `cozytile` pack: `cozytile:sakura`
adds only that variant's facets and assets, and variants whose facets aren't installed
show as "Get…" chips. `qylock:<theme>` writes `qylock-<theme>` with a theme, a colors, a
wallpapers and a lock facet, and refers to `material:imported-dense` instead of writing
a glass block. The pairs in step 3 are declared in `importers/qylock.py` (`VARIANT_OF =
{"osumania": ("osu", "mania"), "material-you-dark": ("material-you", "dark")}`).

## 6. Rendering pipeline

### 6.1 Render units

`loft theme apply` composes the resolved facets into **units**. Each unit declares the
facet kinds it reads, and its cache key covers only those.

| Unit | Output files / effect | Reads | Live reload hook |
|---|---|---|---|
| `shell` | `theme.json` (all shell tokens, grouped by kind; §6.4) | all | `qs ipc call theme reload` |
| `manifest` | `manifest.json` (lock designs, greeter, identity) | lock, colors | lock reads it at each lock |
| `wallpapers` | `wallpapers.json` (resolved collection, sets, arrangement) | wallpapers, colors | `qs ipc call vibes refresh` |
| `niri` | `niri.kdl` (colors, blur, radius, gaps, ring/border/shadow, animations, cursor) | colors, material, shape, motion, icons | `niri msg action load-config-file` |
| `gtk` | `gtk.css` | colors, shape | gsettings `color-scheme` (CSS for new windows) |
| `gsettings` | no file: `color-scheme`, `icon-theme`, `cursor-*`, `font-name`, `monospace-font-name`, sound theme | colors, icons, typography, sounds | itself |
| `kitty` | `kitty.conf` | colors, material, typography | SIGUSR1 |
| `ghostty` | `ghostty.conf` | colors, material, typography | SIGUSR2 |
| `walker` | `walker.css` + theme link | colors, material, launcher, typography | next open |
| `fonts` | links in `~/.local/share/fonts/loft/` | typography | `fc-cache` (once) |
| `noctalia` | `noctalia.json` (transition only) | colors | its watcher |

### 6.2 Cache and composition

```
digest(unit) = sha256(renderer_salt(unit) + canonical_json({k: R[k] for k in unit.reads})
                      + asset_fingerprints(unit))
rendered/units/<unit>/<digest>/<files>         written once, reused forever (GC: keep 8 per unit)
rendered/compositions/<sha(sorted unit digests)>/
    theme.json -> ../../units/shell/<d>/theme.json      (symlinks)
    niri.kdl   -> ../../units/niri/<d>/niri.kdl
    …
    resolved.json     {theme, variant, sources: {k: [layers…]}, customized: [k…], pinned: [k…], units: {unit: digest}}
current -> rendered/compositions/<hash>                 (atomic swap, as today)
```

- `renderer_salt(unit)` hashes only that unit's template and code, so editing
  `templates/render/gtk.css` re-renders only `gtk`.
- Asset fingerprints are file names and sizes, as today's `NOT_RENDERED` rule does.
  Videos never slow an apply.
- **Hooks run only for units whose digest changed**, found by comparing the old and new
  `resolved.json` `units`. Switching Motion changes `shell` and `niri`, so it reloads
  the shell and niri and leaves GTK, terminals and walker alone. Moving the glass slider
  changes `shell`, `niri` (only if blur changed), `kitty` / `ghostty` (terminal opacity)
  and `walker`. Switching wallpapers changes `wallpapers` only.
- A cache hit (switching back to a theme or variant you've used) is resolve + symlink
  swap + hooks, under 150 ms with no rendering. Spaces rely on this.
- `LOFT_HOOKS` keeps its meaning. The hook names are the unit names.

### 6.3 Live preview without writing

Pickers preview before they commit: `loft theme preview cozytile@sakura` renders into a
composition and points the shell (only) at it through `qs ipc call theme preview <dir>`.
Niri, terminals and GTK don't change until Apply, and Esc goes back. The Liquid Glass
slider keeps its in-shell `Theme.glassPreview` and commits on release
(`loft material set glass.opacity 0.35`).

### 6.4 What the shell's `Theme` singleton exposes

`theme.json` (unit `shell`) is grouped by kind. `Theme.qml` keeps every current flat
property (`Theme.bg`, `Theme.glassFill`, `Theme.windowRadius` …), so no component has to
change on day one, and adds:

| Property / function | Meaning |
|---|---|
| `Theme.id`, `Theme.variant`, `Theme.label` | `"cozytile"`, `"sakura"`, `"Cozytile Sakura"` (`Theme.name` = `id` for compatibility) |
| `Theme.sources` | `{kind: {ref, customized, pinned, label}}` for the Theme pages |
| `Theme.customized` | list of customized kinds (drives the badges) |
| `Theme.motion.speed`, `.minimal`, `dur(name)`, `curve(name)` | durations in ms, already divided by speed (0 when minimal); `curve()` returns an `easing` value (`Easing.BezierSpline` + `bezierCurve`) for `NumberAnimation { easing: Theme.motion.curve("standard") }` |
| `Theme.motion.spring(name)` | `{damping, spring}` for `SpringAnimation` |
| `Theme.type.ui / mono / display` | font families and sizes (`Theme.fontUi` stays) |
| `Theme.shape.focus` | `"shadow" \| "ring" \| "both"` (shell windows follow it) |
| `Theme.icons.theme`, `.cursor` | informational; the shell restarts itself when `icons.theme` changes |
| `Theme.a11y.reduceMotion / reduceTransparency / increaseContrast` | resolved switches |

`ThemeManager.qml` becomes the shell's front end to the CLI:
`themes` (`loft theme list --json`: themes with variants, collection, swatch, preview,
installed state), `facets(kind)` (`loft <kind> list --json`), `apply(theme, variant)`,
`setFacet(kind, ref)`, `patchFacet(kind, patch)`, `reset(kind)`,
`saveVariant(name)`, `saveTheme(name, opts)`, `pin(kind, on)`. Vibes.qml keeps the
`wallsets` resolution but reads its choices from `current/wallpapers.json` (the resolved
arrangement) and writes them with `loft wallpapers …` instead of
`Settings.perTheme`.

## 7. UI

Golden Gate styling throughout ([DESIGN-GOLDEN-GATE.md](DESIGN-GOLDEN-GATE.md)): edge-to-edge
sidebar with colored badges, uniform toolbar, glass cards, icons only on common actions.

### 7.1 Settings: one Theme section

Today's top-level **Appearance**, **Wallpaper** and **Lock Screen** pages, and the
motion half of **Layout & Motion**, move under one sidebar entry, **Theme**. Its sub-pages
are the facets:

```
 ┌ Sidebar ───────────────┐
 │ 🎨 Theme               │  → overview
 │     Colors             │  (sub-rows: indented, no badge, shown while Theme is
 │     Wallpapers         │   selected or the sidebar search matches them)
 │     Material           │
 │     Animations         │
 │     Shape              │
 │     Typography         │
 │     Icons & Cursor     │
 │     Lock & Login       │
 │     Launcher           │
 │     Sounds             │  (hidden until the Sounds facet ships)
 │ ▢ Dock                 │
 │ ▢ Dynamic Island       │
 │ ▢ Displays             │
 │ ▢ Keyboard & Mouse     │
 │ ▢ Layout               │  (was "Layout & Motion"; Motion moved to Theme → Animations)
 │ …                      │
 └────────────────────────┘
```

Section ids become `theme`, `theme/colors`, `theme/wallpapers`, `theme/material`,
`theme/motion`, `theme/shape`, `theme/typography`, `theme/icons`, `theme/lock`,
`theme/launcher`, `theme/sounds`. `SettingsApp.sections` gains `parent: "theme"` for
the children.

**Theme overview** (`theme`):

1. **Theme picker**: cards (the existing mini-desktop card: wallpaper strip, glass bar,
   accent dots, now from `preview` when present), grouped by collection with a
   collection filter (All · Built-in · Yours · Cozytile · Qylock). The active card shows
   its **variant chips** under it (`Dark · Light`, `Cozy · Sakura · Natura · Everforest
   · Carbon`). Your own variants have a dot, and uninstalled ones are dimmed "Get…".
   Light / Dark / Auto sits as a segmented control above the picker and is enabled
   for the polarities the theme maps.
2. **Facet rows**, one per kind. Each shows: badge icon · kind name · current choice
   ("Tokyo Night", "Liquid Glass · 35 %") · a **Customized** badge with a reset (↺) or
   an **All Themes** badge · a chevron to the facet page. Example:
   `Material   Liquid Glass · 35 %   [All Themes]  ›`.
3. Toolbar buttons: **Save as Variant…**, **Save as New Theme…** (enabled when something
   is customized), and a **⋯** menu with Reset Customizations, Export Theme…, Show in
   Library.

**Facet pages** share one layout: a **browser** of that kind's facets (cards with a live
mini preview, grouped "This theme · Yours · Installed"), then that kind's
**controls**, which write customization patches, then "Use for All Themes" and "Save
Facet As…".

| Page | Browser cards | Controls (become patches) | Moved from |
|---|---|---|---|
| Colors | palette swatch strips, polarity | accent / accent2 pickers, Increase Contrast | (new) |
| Wallpapers | wallpapers facets and saved sets | everything on today's WallpaperPage: the theme's collection, Library (Topic / Color / Theme), rotate, per workspace, per-display + `wallsets` (Sets, auto-fill, shuffle) | Wallpaper page |
| Material | glass previews over the current wallpaper | Liquid Glass slider, blur, menu bar background, adaptive bar text, Reduce Transparency (accessibility) | Appearance page |
| Animations | motion facets with a looping demo | speed, minimal, niri on/off, Reduce Motion | Layout & Motion → Motion card |
| Shape | window / panel radii previews | radii sliders, gaps, focus: shadow / ring / both, border | (new) |
| Typography | font cards | UI / mono family + size, apply to terminals / GTK | (new) |
| Icons & Cursor | icon theme grids, cursor strips | cursor size | (new) |
| Lock & Login | lock design previews (`LockPreviewCard`) | wallpaper: design / desktop, greeter: same / built-in / …, Preview, "Use at login" (promote) | Lock Screen page |
| Launcher | walker styles | width, glass strength | (new) |

**Migrating pages and IPC.** `WallpaperPage.qml` → `theme/WallpapersPage.qml` and
`LockScreenPage.qml` → `theme/LockPage.qml` move as they are first. The inline
Appearance block in `SettingsApp.qml` becomes `theme/MaterialPage.qml`, and the theme
cards become `theme/ThemeOverview.qml`. IPC keeps the old names as aliases:

| Old | New |
|---|---|
| `settings wallpaper` | `settings theme wallpapers` (alias kept) |
| `settings lockscreen` | `settings theme lock` (alias kept) |
| `Panels.settingsSection = "appearance"` | `"theme"`; `"appearance"` maps to `"theme/material"` |
| `themes open` | opens `theme`; new `themes apply <theme[@variant]>`, `themes variant <id>` |
| `settings layout` | `settings layout` (the Motion card is gone; it links to Theme → Animations) |
| `desktopmenu appearance` / `wallpaper` | open Theme ▸ Material ▸ / Theme ▸ Wallpapers ▸ (aliases) |

The new IPC is `settings theme [page]`, where `page` is a facet kind or empty for the
overview.

### 7.2 Desktop right-click menu: everything under Theme ▸

```
Change Wallpaper…                     (kept top-level: macOS parity, the most-used item)
──────────
Theme ▸   ◉ Dark   ○ Light   ○ Auto                       ← appearance mode (radio)
          ──────────
          Loft          ▸ ✓ Dark · Light                  ← themes with variants are submenus
          Cozytile      ▸ ✓ Cozy · Sakura · Natura · Everforest · Carbon
          Qylock        ▸ Clockwork · … · Wuwa (35)       ← collection submenu, swatches
          Yours         ▸ …
          ──────────
          Colors        ▸ This theme's · Recent · Browse…
          Wallpapers    ▸ Next · Previous · Shuffle · Sets ▸ · Goes with … · Use on All Displays · Browse Library…
          Material      ▸ Liquid Glass ▸ Clear / Default / Tinted · Reduce Transparency · Show Menu Bar Background
          Animations    ▸ Loft · Snappy · Calm · Minimal · Reduce Motion
          Shape         ▸ Golden Gate · … · Focus: Shadow / Ring
          Typography    ▸ …
          Icons & Cursor▸ …
          Lock          ▸ This theme's · Built-in · Preview Lock
          ──────────
          Save as Variant…
          Save as New Theme…
          Reset Customizations             (enabled when customized)
          Theme Settings…
──────────
Display Settings… · Dock Settings… · …   (unchanged)
```

- Today's top-level **Wallpaper ▸** and **Appearance ▸** fold into Theme ▸.
  **Change Wallpaper…** stays top-level and opens Theme → Wallpapers, because that is
  the first item of the macOS desktop menu and Cody's most used.
- The theme list is a level-2 submenu per collection (themes with variants: level 3, as
  radio items), within the menu's 4 levels (`items0..items3`). A single-variant theme is
  a plain radio item.
- Facet submenus list at most 8 choices (the theme's own, then the most recent, then
  "Browse…"). A customized facet's label gets a dot (`Material •`).
- `Settings.desktopMenu.items` loses `wallpaper` and `appearance`. On load they are
  merged into `theme` so a user's ordering survives. IPC `desktopmenu theme` stays, and
  `appearance` / `wallpaper` open the matching Theme submenu.

### 7.3 Elsewhere

The Control Center Display tile's Dark / Light switch calls `themes mode light|dark`.
The wallpaper picker (`wallpaper toggle`) shows wallpapers facets and sets above the
images.

## 8. CLI

```sh
loft theme list [--json] [--collection C]          # themes, variants, installed state
loft theme current [--json]                        # theme@variant + customized/pinned kinds
loft theme apply <theme>[@<variant>] [--mode light|dark|auto] [--greeter]
loft theme variants <theme>                        # incl. yours and not-installed
loft theme diff [<theme>[@<variant>]]              # layers per kind: what customizations/pins change
loft theme reset [<kind>…|--all]                   # drop customizations for the active theme
loft theme save-variant <name> [--theme T]         # customizations → variant (diff only)
loft theme save-as <id> [--name N] [--with-pins] [--with-variants]
loft theme preview <theme>[@<variant>]             # shell-only preview (§6.3); `--stop`
loft theme render <theme>[@v] <outdir>             # every unit, no apply
loft theme validate <pack|theme|facet>…
loft theme install|remove|export …                 # as today, for packs
loft theme migrate [--apply]                       # §5.5 (also `loft library migrate`)

loft <kind> list [--json] [--theme T]               # kind ∈ colors wallpapers material motion shape typography icons lock launcher sounds
loft <kind> show [<ref>] [--resolved]               # the facet, or what the active theme resolves to
loft <kind> apply <ref> [--pin]                     # customization (or pin): select another facet
loft <kind> set <path> <value> [--pin]              # patch: loft material set glass.opacity 0.35
loft <kind> reset [--pin]
loft <kind> save-as <id>                            # resolved → Library/<Kind>/<id>.json
loft <kind> import <file|dir|url>                   # colors: base16/base24 YAML, kitty.conf, iTerm2, Ghostty,
                                                    #   VS Code / Zed themes, pywal JSON;
                                                    # wallpapers: a folder → a facet; lock: an SDDM/qylock dir
loft wallpapers plan|sets|set|shuffle|auto|vibes …  # `wallsets` commands, now operating on the wallpapers facet
```

Importers map into facets: `cozytile` → colors + wallpapers + lock per variant of one
theme. `qylock` → colors + wallpapers + lock (+ typography `fonts` when the design ships
fonts the shell can use) for one theme, with material `imported-dense`. A future
`base16:` importer → colors only (`loft colors import base16:gruvbox-dark-hard`).

## 9. Implementation plan

The renames (P0) are assumed done or done first. Each phase lists the files it owns. Phases
in the same row can run in parallel.

| Phase | Owns | Depends on | Parallel with |
|---|---|---|---|
| **A. Model + resolver** | `cli/loft/facets/` (new: `model.py`, `resolve.py`, `refs.py`, `defaults/*.json`), `schemas/`, v1 adapter in `pack.py`, `tests/test_resolve.py` | — | B0 |
| **B0. wallsets lands** | merge the `wallsets` branch as is (it is consumed, not rewritten) | — | A |
| **B. Units + composition cache + hook diffing** | `render.py` → `cli/loft/render/` (one module per unit), `hooks.py`, `cli.py` `apply` / `preview`, `nix/checks.nix` goldens | A | C, D |
| **C. Pack v2 + library + migration + importers** | `pack.py`, `library.py`, `importers/{cozytile,qylock}.py`, `cli/loft/migrate.py`, `packs/loft/` (built-ins), `tests/test_migrate.py` with fixtures copied from 3 real packs | A, B0 | B, D |
| **D. CLI surface** | `cli.py` argparse (`theme …`, `<kind> …`), `appearance.json` IO, save-variant / save-as / diff / reset | A | B, C |
| **E. Shell plumbing** | `Theme.qml` (grouped tokens, motion API), `ThemeManager.qml`, `Vibes.qml` / `wallsets.js` reading `wallpapers.json`, `Settings.qml` (drop `appearance` / `perTheme` writes, migrate) | B, D | F, G |
| **F. Settings → Theme** | `src/settings/theme/*` (Overview + one page per kind), `SettingsApp.qml` sidebar children + IPC aliases. After the overview lands, one agent per facet page | E | G |
| **G. Desktop menu** | `src/desktopmenu/DesktopMenu.qml`, `DesktopMenuPage.qml` item migration | E | F |
| **H. Motion adoption** | replace hard-coded durations / easings (197 sites) with `Theme.motion.*`, one agent per `src/<dir>` | E | F, G, I |
| **I. Typography, Icons & Cursor, Launcher units** | `render/{gsettings,fonts,walker}.py`, `templates/render/*`, shell restart on icon change, `nix/modules/home.nix` (`extraIconThemes`, fonts) | B | F, G, H |
| **J. Docs** | rewrite THEME-FORMAT.md as the v2 reference, README Themes section, FEATURES.md rows | C, D | anything |

### Status

**Done: A (model + resolver), B (units + cache + hook diffing), D (CLI surface), golden gate.** Code is in `cli/loft/facets/`
(`model.py` catalog, ids and merge rules; `refs.py`; `resolve.py`; `schema.py`, a
JSON Schema subset checker so bare `python3` behaves like the Nix CLI;
`appearance.py` for `appearance.json`, saves and pins) and
`cli/loft/themecmds.py`, with schemas in `schemas/` and the built-ins as the v2
pack `packs/loft/`. Tests are in `tests/test_resolve.py`, and the `theme-golden`
check also renders `loft@dark` / `loft@light`.

- **Phase B (done): units, composition cache, hook diffing.** `cli/loft/render/`
  has one module per unit (`shell`, `manifest`, `wallpapers`, `niri`, `gtk`,
  `kitty` + `ghostty` in `terminal.py`, `walker`, `noctalia`, `spotify`; shared
  rules in `look.py`, the cache in `compose.py`). `compat.py` is gone. Each unit
  declares `reads` and an `inputs(resolved)` projection; `render(inputs)` sees
  nothing else, so `sha256(salt + inputs + assets + apps override)` is a complete
  key. Projections are finer than whole kinds where it matters: `shell` keys on
  the default wallpaper (not the arrangement) and on shape radii / focus / shadow
  (not gaps / border); `kitty` / `ghostty` on the terminal opacity, not
  `glass.opacity`. Measured: motion → `shell`, `niri`; `glass.opacity` → `shell`,
  `gtk`, `walker` (hooks shell, gtk); `blur.enabled` → + `niri`, `kitty`,
  `ghostty`; gaps → `niri`; an arrangement → `wallpapers` only; launcher glass →
  `walker` (no hook). `loft theme apply` re-renders only new digests and runs
  only the hooks of changed units (`--reload` runs them all, `-v` says what
  happened); a cache hit is ~5 ms of composing on top of resolve.
  `loft theme preview T[@V] [--stop] [--no-shell] [--json]` composes without
  touching `current`, points `<state>/preview` at it and calls `qs ipc call theme
  preview <dir>` (phase E implements that IPC). `LOFT_THEME_ENGINE=v1` now means
  "the pack alone" (no catalog, no appearance.json) through the same units.
- **New output (intended golden changes):** `theme.json` gains `shape.focus`,
  `motion` (speed, minimal, durations ÷ speed or 0, curves, spring), `type`,
  `icons`, `a11y`; `niri.kdl` renders `shape.focus` (`on` + width for `ring` /
  `both`, plus a small focused shadow for `ring`; `focus-ring { off }` for
  `"shadow"`), `shape.border` (`off` / `on` + width), `shape.gaps` (only when
  set) and `animations {}` (only when motion isn't the default: `off` when
  minimal, `slowdown 1/speed`, the facet's `niri` keys passed through);
  `wallpapers.json` is new. Every other byte is unchanged: `tests/test_resolve.py`
  compares the frozen v1 renderer (`tests/v1_reference.py`) with the units minus
  exactly these additions, for the built-ins and v1 fixtures.
- **Decision (2026-10-14): the default `shape.focus` is `"both"`, not `"shadow"`**
  (`defaults/shape.json`; `shape:loft` inherits it): Cody keeps the accent focus
  ring, so the built-in look is unchanged (ring on, width 2, same colors; the
  only new niri.kdl lines are the explicit `on` / `width 2`). `"shadow"` stays
  available as a choice.
- **Deviations in B:** the composition hash covers resolved.json as well as the
  unit digests (two selections with the same files but different sources get
  their own resolved.json); identity is only in resolved.json, never in
  `theme.json`, so `loft@dark` and the v1 pack `tokyonight` still render the same
  files; `walker` doesn't read typography and there is no `gsettings` / `fonts`
  unit yet (phase I); the `spicetify.ini` unit is named `spotify` after its hook.
- **Still not rendered (phase I):** icons / cursor (gsettings, niri `cursor {}`),
  typography beyond the v1 `fonts` (gsettings, walker), sounds, lock options;
  shape shadow geometry (softness / spread / offset stay base.kdl's).
- Bundles keep v1 names: `Resolved.name` is the alias that points at the
  selection (`loft@dark` → `tokyonight`), else `theme@variant`, so `perTheme`
  keys and `Theme.name` don't change.
- **The catalog** is built from the library root (implicit pack `user`), the theme
  path's pack dirs and `packs/`. The built-in v1 `themes/` dir is left out while
  `packs/loft` exists, because its packs are now aliases of `loft`. `themes/`
  stays for `loft-themes-builtin`, `theme validate` and the goldens until C.
  Saves write into today's library root (`$LOFT_LIBRARY`, `~/Documents/Themes`):
  `Themes/<id>.json`, `Themes/<theme>.variants.json`, and kind folders
  (`Materials/` …). C moves that root to `~/Documents/Loft`.
- **CLI:** `theme list --themes [--collection C] [--json]`, which leaves plain
  `theme list [--json]` as the v1 pack list the shell reads; `theme current
  --json`; `theme apply [T[@V]] [--mode] [--greeter [REF]]` (`loft greeter sync|status|reset|follow`); `theme render T[@V]
  OUT [--no-user]`; `theme variants`, `state`, `diff`, `reset`, `save-variant`,
  `save-as`; `theme accessibility --reduce-motion|--reduce-transparency|
  --increase-contrast on|off` (not in §8; the Theme pages need it); and
  `loft <kind> list|show|apply|set|reset|save-as [--pin]`. Every write re-applies
  unless `--no-apply` is given. Not done: the shell side of `preview` (E), `migrate` (C),
  `<kind> import` (C), and `loft wallpapers plan|sets|…` (the `wallsets`
  commands stay under `loft wallpaper`). B added `preview`, `apply --reload / -v`.
- **Deviations from the text above, all small:**
  - §4.2 storage rule: "selects k" means a ref or inline facet. A variant that
    only patches k shares the `"*"` slot. On the base, a kind goes under the base
    id when some variant replaces it, so a Dark palette tweak doesn't leak into
    Light.
  - `loft`'s Light variant patches the material (`tint`) without re-referencing
    it, so the glass slider stays per theme (decision 3).
  - `save-variant` clears only the `"*"` slot and the current variant's slot.
    `reset KIND` drops those same two slots.
  - Shape has `shadow.color` (null means black at the polar opacity), which
    carries v1 `glass.shadow`.
  - Lock data has `main` / `background`, and wallpaper items may note `kind`.
  - Typography `mono.family: null` means `monospace` (v1), not JetBrainsMono.
  - Auto mode uses 07:00–19:00 (or `$LOFT_AUTO_POLARITY`) until a Night Light
    schedule exists.
- **Pins vs saves:** a pin sits above theme and variant data. When a pin and a
  customization touch the same keys, saving the customization into a variant or
  theme lets the pin win again. `save-variant` / `save-as` print a note when the
  look changes.

**Done: C (pack v2 + library + migration + importers).** `cli/loft/migrate.py`,
v2 pack IO in `pack.py` (`validate_v2`, `write_doc`), `library.py`, the
importers, `tests/test_migrate.py` (six real packs, media stubbed).

- **Library root** `~/Documents/Loft` (`$LOFT_LIBRARY`; `programs.loft.library`'s
  default). While it doesn't exist and `~/Documents/Themes` does, the old root
  is used, so deploying before migrating changes nothing. Spaces follow the
  library (`$LOFT_SPACES_DIR`, else `$LOFT_LIBRARY/Spaces`: QML and loft-niri).
- **`loft library migrate [--apply] [--undo [REPORT]]`** (also `loft theme
  migrate`) does §5.5 steps 1–5 with these choices:
  - v1 packs are converted **in place**: each gets `pack.json` and
    `facets/<kind>/*.json` (adapter ids, so lock names and renders stay the
    same) and keeps `theme.json` / `manifest.json` for the v1 readers (the
    shell's `theme list --json`, `library sort`, vibes, `wallpaper` sets).
    A grouped theme lives in its base's pack; cozytile's in a new JSON-only
    `Packs/cozytile`, referring to `colors:cozytile-sakura/…` etc.
  - Variants carry their member pack's identity (`author`, `version`,
    `source`, `upstream`) and a `v1` link (`{path, greeter?, vibes?}`, relative
    to the theme's pack) that the render units read for curated vibes and the
    greeter; the colors facet's envelope `apps` names the palette's `apps/`
    dir (a variant's `spicetify.ini`); `render/identity.py` gives both to the
    `manifest` unit and the units' apps/ overrides (`spotify`, `apps`).
  - Grouping rules: an importer's `RICE` (cozytile), its `VARIANT_OF`
    (qylock), same colors + wallpapers, `x` / `x-dark|light`. Base chip ids:
    the member's short name, or its polarity for a light/dark pair.
  - User state is merged into `appearance.json` (nothing overwritten);
    `shell.json` / `niri.json` are copied to `*.pre-loft.json` but **left as
    they are**: the shell reads `appearance` / `perTheme` and niri.json's
    `animations` until phase E. Customizations go under the slot the old name
    meant (`perTheme.tokyonight` → `customizations.loft.dark`), not `"*"`.
  - The report is saved under `<state>/migration/`; `--undo` reverses it
    (hard links stay: same content).
- **M1 with renders** on a copy of Cody's library: all 46 old names render
  byte for byte the same through their aliases (library root swapped), except
  `qylock-osumania`'s manifest, whose wallpapers are osu's now (one facet,
  hard-linked files).
- **Importers write v2** (`--v1` / `LOFT_IMPORT_FORMAT=1` for the old packs,
  which the shell's picker lists until phase E). A variant brings its base;
  later installs add variants to the pack. `theme install|update|export|
  remove|validate` handle v2 packs; export includes the packs a theme uses,
  and remove refuses a pack another theme uses (`--with-deps`).

**Test strategy.**

- **Unit** (pytest, `nix flake check`): the resolver (layer order, ref-replaces /
  patch-merges, the `[T][V]` vs `[T]["*"]` storage rule, polar and `@` refs,
  accessibility clamps, bad layers dropped), the save-variant / save-as round trip
  (resolve(save-as(X)) == resolve(X)), migration fixtures, cache keys (switching motion
  changes exactly `{shell, niri}`).
- **Golden**: `loft theme render loft@dark` must be byte-identical to today's
  `studio theme render tokyonight` for every unit (likewise `latte`, and two imported
  packs through the v1 adapter). This is the regression gate for phases A–C.
- **Headless sessions** ([TESTING.md](TESTING.md), `skills/loft-drive`): each agent
  uses its own `loft-dev --session <phase>` (today `studio-dev`) and runs `loft --dev
  theme apply cozytile@sakura`, then `loft-shot --session <phase> --grid`. Add an IPC
  `theme state` (resolved.json, sources, customized) so agents assert on JSON before
  pixels. UI phases drive the Settings pages and the desktop menu with `loft-input`
  (`desktopmenu state` already returns the item tree).
- **M1, migration visual check**: on a copy of Cody's library (`LOFT_LIBRARY=/tmp/…`,
  never the live one), migrate, apply each of the 46 old names through its alias, and
  compare `loft-shot` captures before and after (pixel diff < 0.5 %).
- **Multi-display**: wallpaper sets and spaces need several outputs. Phase B0 / SPACES
  P0 adds `loft-dev --session NAME --outputs 3440x1440,1440x2560,2560x1440` (headless
  sway `create_output`).

## 10. Risks

- **Hidden coupling to `theme.json`'s flat shape.** The greeter (`lock/sddm/`) reads
  `theme.json` with XHR and has no Quickshell. Unit `shell` keeps the old flat keys next
  to the grouped ones until the greeter is updated.
- **Cache explosion.** Composition dirs are cheap symlink sets, and units are GC'd to 8
  digests each. A space that switches themes reuses compositions.
- **Icon theme switching needs a shell restart** (`QS_ICON_THEME`). It is acceptable as
  an explicit action, but not on every space switch.
- **GTK3 / Qt apps don't re-theme live.** Only `color-scheme` is live for GTK4 /
  libadwaita. That's the same as today, and it is documented on the Theme overview.
- **Customizations of a theme that disappears** (pack removed): they are kept, shown
  under Theme → ⋯ → "Customizations of removed themes", and can be deleted or
  reattached.
- **Merge-patch can't patch inside arrays.** Wallpaper `collection` and `sets` are
  replaced whole by a patch. Arrangement maps are objects on purpose.

## 11. Decisions (Cody, 2026-10-14: "go with defaults")

1. **Qylock**: 37 themes in a `qylock` collection (variants are for versions of one look);
   cozytile is one theme with variants.
2. **Built-in default**: one `loft` theme with **Dark** (Tokyo Night) and **Light**
   (Latte) variants; `tokyonight` / `latte` stay as aliases.
3. **Today's glass 0.35** migrates as an **All Themes pin** (behavior unchanged). From now
   on the Liquid Glass slider is per theme, with an "All Themes" toggle.
4. **Library root** moves to **`~/Documents/Loft`** (Themes, Spaces, Wallpapers);
   `~/Documents/Themes` is migrated (dry run first) and left as a symlink.
5. **Auto appearance** follows the **Night Light schedule** (sunset / sunrise).
6. **Fonts**: a theme may set the UI font (and mono / lock fonts); accessibility clamps
   still apply.
7. **Icons & Cursor** are a facet themes may set (shell restart on change, themes must be
   pre-installed); **MacTahoe** (blue) stays the default.
8. **Sounds**: later — keep the facet in the model, no UI or assets yet.
