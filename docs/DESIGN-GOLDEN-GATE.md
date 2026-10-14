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

## Not copied
- The notch, HDR UI highlights, and iOS-style app icon layers.
