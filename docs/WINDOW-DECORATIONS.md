# Title bars and window buttons

niri draws no decorations. With `prefer-no-csd` (niri/base.kdl), every app that
speaks xdg-decoration — Qt/KDE apps, foot, kitty, Alacritty, WezTerm, mpv,
Chromium/Electron with the system titlebar, SDL games — agrees to server-side
decorations and so would have no title bar and no window buttons at all. GTK
apps ignore the protocol and draw their own (themed) header bars.

Loft's niri draws that server side the way KWin does: a **title bar strip
above the window**, with the macOS buttons (close / hide / full screen) at its
left and the window title centered. The tile reserves the bar's height, so the
app gets the tile minus the bar and nothing covers its content. A window rule
turns the bar off per app, like KWin's "No titlebar and frame" rule.

A patch to niri (`nix/niri/title-bar.patch`, applied to `niri-loft` after
`workspace-layers.patch`; fragment `niri/title-bar.kdl`) makes the bar part of
the tile, so it scrolls, animates, resizes, shows in the overview and in
screencasts with the window. A shell overlay can't: layer surfaces don't follow
niri's scrolling layout or its animations.

(Before this, the patch floated the three buttons over the window's top-left
corner with no bar, macOS "full-size content view" style. They sat on top of
whatever the app drew there, so the strip replaced them.)

## Compared with KDE

| | KWin (Breeze) | niri-loft |
|---|---|---|
| Who gets one | every window that asks for server-side decorations | the same: xdg-decoration `server_side` or KDE decoration `Server` |
| GTK / libadwaita | their own CSD | their own header bars, no niri bar |
| Content | below the bar | below the bar; the tile reserves its height |
| Buttons | right (configurable) | left, macOS traffic lights |
| Maximized | keeps the bar (unless "borderless maximized windows") | keeps the bar; borders go |
| Full screen | no bar | no bar (it shrinks away with the animation) |
| Drag the bar | moves | moves (tiled: vertical drag moves, horizontal drag scrolls the view, as niri does for GTK header bars) |
| Double-click | maximize | maximize to edges |
| Right-click | window menu | the shell's window menu |
| Per-app off | window rule "No titlebar and frame" | `window-rule { title-bar { off; } }` |

## Config

```kdl
layout {
    title-bar {
        on
        height 30                      // logical px, rounded to whole pixels
        active-color "#2c2c30"         // the focused window's bar
        inactive-color "#222226"
        active-text-color "#e6e6ea"
        inactive-text-color "#8a8a90"
        font "sans 13px"               // a Pango font description
    }
    traffic-lights {                   // the buttons in the bar
        size 12
        spacing 8
        offset x=12 y=0                // x: inset from the bar's left edge
        // close-color, minimize-color, zoom-color, inactive-color, glyph-color
    }
}

window-rule { match app-id="^mpv$"; title-bar { off; } }              // no bar: full tile
window-rule { match app-id=r"^org\.kde\.dolphin$"; title-bar { height 34; } }
window-rule { match app-id="^foot$"; traffic-lights { off; } }        // a bar without buttons
```

`title-bar` is off in stock niri's defaults; `niri/title-bar.kdl` turns it on.
Window rules take every key of the layout block plus `on` / `off`.

`traffic-lights` now styles the buttons inside the bar; they never show without
one. Its `offset y` is ignored (they are centered in the bar), so an old
`offset x=14 y=14` still parses. `traffic-lights { off; }` in a rule keeps the
bar and drops the buttons; to drop both, use `title-bar { off; }`.

Shipped rules: `org.quickshell` (the shell's own windows, which draw their own
chrome) gets no bar. No other app is off by default: mpv and SDL games get a bar
when windowed, as on KDE (full screen has none), and a rule takes it away.

## Geometry

The bar is chrome inside the tile, like niri's border, between the border and
the window:

```
┌ border ──────────────────────────┐
│ ● ● ●         Title              │  ← bar: `height`, as wide as the window
├──────────────────────────────────┤
│ window: tile − bar − 2 × border  │
└──────────────────────────────────┘
```

- `tile_size()` = window + bar (+ border both ways in normal mode). Everything
  that converts between tile and window sizes (`request_tile_size`,
  `tile_height_for_window_height` / `window_height_for_tile_height`, min/max
  sizes, column heights, presets) adds or removes the bar, so column widths,
  proportional heights and `maximize-column` are tile sizes as before and the
  window is shorter by the bar. Widths don't change.
- New windows: the initial configure leaves room for the bar from the
  decoration mode negotiated before the first commit (`toplevel_has_pending_ssd`).
- `window_loc()` puts the window under the bar; floating windows keep their
  window size and their tile grows by the bar.
- Maximized (`maximize-window-to-edges`, double-click): the window gets the
  working area minus the bar.
- Full screen: no bar; during the animation the bar height scales with the
  fullscreen progress and fades out.
- Corners: the tile's outline (border, focus ring, shadow) keeps the window
  rule's `geometry-corner-radius`. The bar takes the top corners, and the
  window under it is clipped (`clip-to-geometry`) and blurred with square top
  corners and the rounded bottom ones.
- The bar height is rounded to whole logical pixels, then to physical ones:
  window heights are integers, and a half-pixel bar broke niri's "column fits
  the working area" invariants at scale 2.
- Interactive moves keep the pointer where it grabbed, bar included.

## Looks

- Background: `active-color` / `inactive-color`, top corners rounded with the
  window radius.
- Title: centered on the whole bar (not the space right of the buttons, so it
  lines up with the window), kept clear of the buttons on both sides, ellipsized
  at the end. Drawn with Pango/cairo like niri's MRU titles; the texture is
  cached per title, color and scale, and redrawn ellipsized only when it doesn't
  fit. Windows blocked out from screencasts keep the bar but not the title.
- Buttons: three 12 px beads, 8 px apart: close `#ff5f57`, hide `#febc2e`,
  zoom `#28c840` — same as `Theme.traffic*` and the GTK template, with the Aqua
  specular dot of `TrafficLights.qml`. Grey when the window is unfocused;
  hovering the group lights all three and shows the glyphs (×, −, ⤢).
- The Loft theme doesn't write the bar's colors yet: `niri/title-bar.kdl`
  sets a dark neutral. A theme renderer would write a `title-bar { … }` block
  into a fragment only niri-loft sessions include (stock niri rejects it).

## Behaviour

| Input | Does |
|---|---|
| click red | `close-window` |
| click yellow | Loft's Hide (below) |
| click green | toggle fullscreen |
| press and hold green | the shell's window menu at the button |
| press and drag the bar | niri's interactive move (as a client's own title bar does through xdg `move`) |
| double-click the bar | toggle maximize to edges (as GTK header bars do through xdg `set_maximized`) |
| right-click the bar | the shell's window menu at the pointer |
| Mod+drag, overview | unchanged: the bar is just part of the window |

The window menu (the shell draws it): Fullscreen, Maximize, Tile left/right of
…, Move to display …, Move to space ….

**Hide** — niri 26.04 has no minimize or hide: it doesn't handle xdg
`set_minimized` at all. Loft parks windows on `hidden-<output>`
(`MenuState.hideWindows`). The patch emits an IPC event
`WindowMinimizeRequested { id }` for the yellow button *and* for the xdg
`set_minimized` request, so GTK's minimize button, the traffic lights and the
menu bar all hide the same way. The shell's `Niri` service listens and calls
`hideWindows`.

**Window menu** — the patch emits `WindowActionsMenuRequested { id, output, x,
y }` (output-local pointer position) after ~350 ms on the green button, or on a
right-click on the bar; the shell opens its menu there and runs the choice
through `niri msg action`.

Touch on the bar does nothing yet (only the pointer drives it).

## Where it lives in niri 26.04

- `src/layout/title_bar.rs` (new): the bar's config, background element,
  title texture and hit-testing; it owns the traffic lights.
- `src/layout/traffic_lights.rs` (new): the beads, laid out in the bar.
- `src/layout/tile.rs`: `title_bar_height()` (reserved whatever the sizing
  mode, like the border width), `effective_` (none in fullscreen) and visual
  (animated) heights; every tile/window size conversion; `window_loc()`;
  rendering above the window, below its popups; `Tile::hit` → new
  `HitType::TitleBar { button }` (after the window's input region, so popups
  over the bar keep their input).
- `src/layout/{scrolling,floating,workspace}.rs`: new-window sizes and bounds
  leave room for the bar; a bar height change re-requests column sizes.
- `src/layout/mod.rs`: interactive-move pointer ratios include the bar.
- `src/input/mod.rs`: button press/release/hold, drag, double-click,
  right-click; `src/niri.rs`: hover state for the glyphs.
- `src/handlers/xdg_shell.rs`: `minimize_request` → the IPC event.
- `niri-config`: `title-bar` and `traffic-lights` in `layout` and window rules;
  `niri-ipc`: the two events.
- Tests ride on niri's suite: `src/layout/tests/title_bar.rs` (tiled, floating,
  border, maximized, fullscreen, rules, new-window sizes, hit-testing), the
  random-operations proptests with SSD windows and arbitrary bars
  (`RUN_SLOW_TESTS=1`), unit tests in both modules, and config parsing in
  `niri-config`.
