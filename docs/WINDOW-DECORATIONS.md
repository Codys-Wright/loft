# macOS-style window buttons

niri draws no decorations. With `prefer-no-csd` (niri/base.kdl), every app that
speaks xdg-decoration — Qt/KDE apps, foot, kitty, Alacritty, WezTerm, mpv,
Chromium/Electron with the system titlebar, SDL games — agrees to server-side
decorations and so has no window buttons at all. GTK apps ignore the protocol
and draw their own (themed) headerbar buttons.

Loft adds the server side, but **no titlebar strip**: like a modern macOS app
(full-size content view, unified toolbar), the traffic lights float over the
window's own top-left corner, and the app's toolbar *is* the top of the
window. A patch to niri (`nix/niri/traffic-lights.patch`, applied to
`niri-loft` after `workspace-layers.patch`; fragment `niri/traffic-lights.kdl`) draws them as part of the tile, so
they scroll, animate, resize, show in the overview and in screencasts with the
window. A shell overlay can't: layer surfaces don't follow niri's scrolling
layout or its animations.

## Which windows get them

A window gets traffic lights when it negotiated server-side decorations
(xdg-decoration `server_side`, or KDE decoration `Server`), it is not
fullscreen, and no window rule turns them off. GTK/libadwaita windows never
negotiate SSD, so they keep their CSD buttons.

```kdl
layout { traffic-lights { on; offset x=14 y=14; } }        // global default
window-rule { match app-id="^mpv$"; traffic-lights { off; } }
window-rule { match app-id=r"^org\.kde\.dolphin$"; traffic-lights { offset x=16 y=18; } }
```

## Geometry

No inset: the tile and window geometry are unchanged, so tiling, sizes and
corner radii stay exactly as they are. The beads are drawn above the window
surface at `offset` from its top-left corner (centered on a 52 px-tall toolbar
by default, like macOS).

They cover whatever the app draws there. Loft makes room where it owns the
look, the way macOS apps reserve the space themselves:

- Qt/KDE apps (Kvantum `Loft`, `dolphin.qss`): the main toolbar gets a
  ~70 px left inset.
- Terminals (foot/kitty/Alacritty/WezTerm configs Loft renders): top padding,
  or a left padding on the first row's height.
- Everything else: the per-app `offset` rule, or `off`.

## Looks (from the Loft theme)

- Three 12–13 px beads, 8 px apart: close `#ff5f57`, hide `#febc2e`,
  zoom `#28c840` — same as `Theme.traffic*` and the GTK template, with the Aqua
  specular dot of `TrafficLights.qml`.
- Grey when the window is unfocused; hovering the group lights all three and
  shows the glyphs (×, −, ⤢), as on macOS.
- No backdrop of their own; they sit on the app's toolbar (glass in Loft's
  themed apps).
- Colors/sizes from `layout { traffic-lights { … } }`, which the theme
  fragment writes, so `loft theme apply` recolors live.

Drawn with cairo into a small texture cached per (scale, focused, hovered,
pressed, colors).

## Behaviour

Only the beads take input; the rest of the top of the window belongs to the
app (moving stays Mod+drag, or the app's own `move` request).

| Input | Does |
|---|---|
| click red | `close-window` |
| click yellow | Loft's Hide (below) |
| click green | toggle fullscreen |
| press and hold green | a window-actions menu (the shell draws it): Fullscreen, Maximize, Tile left/right of …, Move to display …, Move to space … |
| click elsewhere / unfocused window | first click focuses, like any window |

**Hide** — niri 26.04 has no minimize or hide: it doesn't handle xdg
`set_minimized` at all. Loft parks windows on `hidden-<output>`
(`MenuState.hideWindows`). The patch emits an IPC event
`WindowMinimizeRequested { id }` for the yellow bead *and* for the xdg
`set_minimized` request, so GTK's minimize button, the traffic lights and the
menu bar all hide the same way. The shell's `Niri` service listens and calls
`hideWindows`.

**Hold green** — the patch emits `WindowActionsMenuRequested { id, x, y }`
(output-local position of the bead) after ~350 ms held; the shell opens its
menu there and runs the choice through `niri msg action`.

## Where it goes in niri 26.04

- `src/layout/traffic_lights.rs` (new, next to `tab_indicator.rs`, the
  closest precedent): state, layout, render elements, hit-testing.
- `src/layout/tile.rs`: render above the window in `render_inner`;
  `Tile::hit` checks the beads before the window's input region → new
  `HitType::TrafficLight { button }`.
- `src/input/mod.rs`: press/release/hold on a bead instead of forwarding to
  the client; hover state for the glyphs.
- `src/handlers/xdg_shell.rs`: `minimize_request` → the IPC event.
- `src/utils/mod.rs` / `window/mapped.rs`: "has SSD" from the negotiated mode
  (the test `update_tiled_state` already makes).
- `niri-config`: `traffic-lights` in `layout` and window rules; `niri-ipc`:
  the two events. The patch's tests ride on niri's test suite like
  workspace-layers' do.
