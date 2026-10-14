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
  Below the default, `Theme.text` / `subtext` become contrast-aware: when the
  palette's text would not reach 4.5:1 on the glass over this wallpaper
  (`Theme.onGlass`), they turn white or near-black.
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
  backdrop).
  `programs.loft.gtk` (default on) imports it from `~/.config/gtk-{3,4}.0/gtk.css`
  and puts the window buttons on the left (settings.ini + GNOME's `button-layout`
  key, which libadwaita reads through the portal).
- **Glass sidebars (Nautilus)** — the same `gtk.css` makes Files' window
  transparent, its `.sidebar-pane` a thin tint of the theme's glass
  (`gtk_sidebar_glass`; opaque when the theme turns blur off) and its file view
  opaque; a niri window rule (`templates/render/niri.kdl`) blurs behind it.
  Edge-to-edge, a hairline instead of a shadow, accent-colored sidebar icons,
  rounded selection pills, traffic lights in the sidebar like Finder's.

## Not copied
- The notch, HDR UI highlights, and iOS-style app icon layers.
