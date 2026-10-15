# Design target: macOS 27 "Golden Gate" Liquid Glass

Loft's UI follows macOS Golden Gate (WWDC June 2026), not Tahoe. Themes still
choose the palette; this is the *shape and material* every theme renders with.
Sources: Apple's Golden Gate announcement coverage (MacRumors, 9to5Mac, June 9
2026) and menu-bar write-ups (publicspace.net). Where Apple gave no numbers, the
values below are ours — tokens, so themes can tune them.

## What changed from Tahoe, and what Loft does

| Golden Gate | Loft |
|---|---|
| **Liquid Glass slider** (Settings › Appearance) — one continuous control from *ultraclear* to *fully tinted*, replacing Clear/Tinted | `Settings.appearance.glass` 0..1 (0 = ultraclear, 1 = fully tinted). Drives fill opacity, tint strength and text-shadow strength of every GlassSurface together. Themes set the default (`glass.opacity` becomes the slider's default). |
| **More uniform refraction, improved contrast**; depth from a **darkened edge and brighter specular highlights** | GlassSurface: a 1 px darker inner rim (edge darken token) + a brighter, wider top specular; contrast-aware text color on glass. No per-surface ad-hoc opacities — everything reads from the glass tokens. |
| **Menu bar has no background** — titles sit on the wallpaper, white/black chosen from the wallpaper's brightness; *Show menu bar background* switch adds a translucent backdrop | Bar default: transparent, text/icons switch light/dark from the wallpaper luminance under the bar (sampled per output, re-sampled on wallpaper change), soft text shadow for legibility. Setting `bar.background` (off by default) restores the glass strip. |
| **Reduce transparency** → flat fills (light grey / near-black) for menu bar, menus, sidebars, Control Center, widgets | `Settings.appearance.reduceTransparency`: GlassSurface renders a flat opaque fill, blur off, everywhere. |
| Menu bar drawn as **one surface**; built-in **overflow arrow** when items don't fit; **⌘-drag** reorders/removes status items | One bar surface per output (already). Overflow » at the right edge when the status row runs out of room. Super-drag (Cmd) on a status item reorders it or drags it off the bar. |
| **Menus use icons selectively** — only on common actions, not every item | Menus (app menu, global menu, extras): icons only on a short list of common actions (New, Open, Save, Share, Copy/Paste, Settings, Quit-like); everything else text-only. |
| **One corner radius for all windows**, less rounded than Tahoe | One `window.radius` token applied to every window via niri (`geometry-corner-radius` + `clip-to-geometry`) and to Loft's own windows. |
| **Active window more distinct** (window shadows, opacity) | niri shadows: stronger/larger on the focused window, faint on inactive ones; Loft windows dim their glass slightly when inactive. |
| **Sidebars edge-to-edge**, no floating/inset, no sidebar shadow; **sidebar icons in color again** | Settings app (and Loft windows with sidebars): flush full-height sidebar, colored rounded-square icon badges (System Settings style). |
| **Uniform toolbars** | One toolbar component (title, controls, search) for Loft windows. |
| **Traffic lights redesigned — Aqua-like Liquid Glass** | Loft's own windows draw glassy red/yellow/green buttons (close / hide / full screen) with a specular dot; the GTK template styles headerbar buttons to match where apps allow. |
| **Control Center**: consistent closing animation; Settings › Control Center switch per item (Wi-Fi, Bluetooth, Battery, Sound, Focus) for showing it in the menu bar | Open and close share one animation curve; every control has "Show in menu bar". |
| Notification Center / Control Center follow the glass slider | Yes — no separate opacity settings. |

## Tokens (theme.json `glass`, `shape`)
- `glass.opacity` → default of the Liquid Glass slider
- `glass.edgeDarken`, `glass.specular` (0..1)
- `shape.windowRadius` (default 12), `shape.panelRadius` (default 18), `shape.controlRadius`
- `bar.adaptiveText` (true), `bar.background` (false)

## How it is built (foundation)

- **Material** — `src/components/GlassSurface.qml`, all values from `Theme`:
  fill `Theme.fillFor(strength)` (tint × the slider; strength > 1 for windows
  and panels, < 1 for cards inside them), hairline, darkened inner rim
  (`Theme.edgeColor`), top sheen + specular line (`Theme.sheenColor`,
  `specularColor`), `active: false` dims an inactive window's glass,
  `clear: true` is the light frost of the dock and the menu bar background
  (`Theme.clearFillFor`). A nested surface leaves the text shadow to the
  outermost one.
- **Liquid Glass slider** — `Theme.glass` (0..1) = `Settings.appearance.glass`
  (−1 → the theme's `glass.opacity`); `Theme.glassPreview` shows a value live
  while the slider drags and is saved on release. It sets the fill opacity
  (1:1, so a theme's default looks as before), the tint strength (fades toward
  neutral below the default) and the text shadow (none at/above the default).
  Text on panels and windows keeps the palette's colors (only the menu bar
  adapts, per screen); instead, below the default an outer surface
  (strength ≥ 1) never gets clearer than its palette text needs for 3:1 over
  the worst wallpaper among the screens (`Theme.legibleAlpha`: the darkest
  for dark text, the lightest for light text), and the text shadow does the
  rest. A surface can still opt in to adaptive text with `Theme.onGlassFor`.
- **Reduce transparency** — `Theme.reduceTransparency`: `Theme.blur` is off
  everywhere, `fillFor` returns opaque theme colors (`flatFill`), the bar gets
  its (flat) background.
- **Menu bar** — `src/bar/Bar.qml`: transparent; `services/WallpaperTone.qml`
  samples the image each screen shows (cropped like the wallpaper layer, the
  strip under the bar and the whole screen, ffmpeg → 16 columns each), cached
  per image and screen size; the gradient fallback is read from the theme.
  Per-output colors: `Theme.barTextFor(screen)`, `barSubtextFor`,
  `barOnTextFor` (text on a pill of barText), `barShadowFor`,
  `barDarkTextFor`; `Theme.barText` / `barShadow` are first-screen shorthands.
  The bar's whole content gets one soft MultiEffect shadow.
- **Windows** — niri (`niri/base.kdl` + the theme fragment): one
  `geometry-corner-radius` (`shape.windowRadius`) with `clip-to-geometry`;
  shadow `color` / `inactive-color` from `glass.shadow`, and a larger
  shadow on `is-focused=true`.
- **Shell windows** — `components/WindowChrome.qml` (edge-to-edge sidebar,
  search, toolbar, traffic lights, active/inactive), `SidebarItem.qml`,
  `IconBadge.qml` (`Theme.badgeColor(name)`: Apple system colors),
  `TrafficLights.qml`. Settings and System Monitor use the chrome; the
  Scratchpad keeps its tab bar and gets the lights, radius and dimming.
- **GTK / libadwaita** — `templates/render/gtk.css`: accent and palette, the
  window radius, traffic-light window buttons (glyphs on hover, grey in
  backdrop or when the compositor can't act on them).
  `programs.loft.gtk` (default on) imports it from `~/.config/gtk-{3,4}.0/gtk.css`
  and puts the window buttons on the left (settings.ini + GNOME's `button-layout`
  key, which libadwaita reads through the portal).
- **Golden Gate sidebars (every libadwaita app)** — any `.sidebar-pane` is
  edge to edge (no inset card, margin or shadow), the theme's sidebar color, a
  hairline toward the content, rows in the text color with accent icons and a
  soft selection pill (Settings-like apps, Characters, …). GTK's own file
  chooser gets the same rows.
- **Glass sidebars (Nautilus and its file chooser)** — the same `gtk.css` makes
  Files' window (`.nautilus-window`) and the portal file chooser GTK apps get
  (`.nautilus-file-chooser`: xdg-desktop-portal-gnome hands it to Nautilus)
  transparent, the `.sidebar-pane` a tint of the theme's glass
  (`gtk_sidebar_glass`, dense enough to read over any wallpaper; opaque when the
  theme turns blur off) and the file view opaque; a niri window rule
  (`templates/render/niri.kdl`, `org.gnome.Nautilus`) blurs behind it. Narrow
  windows (collapsed split view) go opaque. Selected files are an accent tint,
  grey in the background, like Finder's; traffic lights sit in the sidebar.
  Glass is per app on purpose: GTK CSS can't match an app id and libadwaita
  gives windows no per-app class, so a generic transparent window would show
  the desktop unblurred in every app niri doesn't blur. A new glass app needs
  its window class in gtk.css and its app id in niri.kdl, together.
- **Dolphin (Qt) glass** — `programs.loft.qt`: the `qt` unit renders a Kvantum
  theme and a KDE color scheme from the palette; Kvantum paints the window as
  the same glass tint (toolbar, Places panel and status bar sit on it), the
  file view stays opaque, selections are accent-tint pills. niri.kdl blurs
  `org.kde.dolphin`. Unlike Nautilus the toolbar spans the window (Dolphin's
  layout), and there are no traffic lights: Qt apps draw no window buttons on
  niri. Assigned to Dolphin only (Kvantum `[Applications]`, dolphinrc keys),
  never as a global Qt style.
- **GTK 4 base theme (optional)** — `programs.loft.gtkBase.{dark,light}`: a full
  libadwaita stylesheet (MacTahoe's `-l` CSS: Tahoe toolbars, pill buttons, Finder
  path bar) imported under the theme's gtk.css. The `gtk` hook links
  `<state>/gtk-base.css` to the one matching the theme's polarity. MacTahoe
  hardcodes its own greys and blue (#2E7CF7) instead of libadwaita's named
  colors, so gtk.css repeats those selectors with the palette: opaque windows
  (MacTahoe's blur build makes every `.background` 75% translucent, which
  niri doesn't blur), headerbars, views, opaque popovers / menus / dialogs
  (`gtk_raised`: surface in dark themes, near-white in light ones), and the
  accent on selections, checked / suggested buttons, switches, checks, sliders,
  progress, links, focus rings and rubberbands. Disabled window buttons (niri has
  no minimize) are grey. The same rules cover GTK 3 apps on MacTahoe's GTK 3
  theme.

## Not copied
- The notch, HDR UI highlights, and iOS-style app icon layers.
