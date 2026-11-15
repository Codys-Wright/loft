"""Unit `kdecoration`: kdecoration.ini, the colors and metrics of Loft's KWin
decoration (dev.loft.decoration, kdecoration/), so a window under KWin wears
the same title bar as under niri-loft (render/niri.py's niri-loft.kdl).

  colors    the bar as gtk.css draws GTK header bars (surface focused, bg in
            the backdrop), title text / subtext, the unfocused beads' grey
  shape     the window radius (the bar's top corners and the window's
            bottom ones), the focused / unfocused shadow colors

The plugin reads `<state>/current/kdecoration.ini` and watches it (and the
`current` link), so no hook: a theme change repaints open windows at once.
Without the file it falls back to its built-in defaults (the same as
niri/title-bar.kdl's).
"""

from __future__ import annotations

from pathlib import Path

from .. import color as c
from . import look
from .unit import Source, Unit, template


def inputs(src: Source) -> dict:
    sh = src.facet("shape")
    return {
        "name": src.res.name,
        "palette": {k: v for k, v in look.palette(src.facet("colors")).items() if k in look.ROLES},
        "shape": {"radius": {"window": sh["radius"]["window"]}, "shadow": sh["shadow"]},
    }


def variables(i: dict) -> dict[str, str]:
    p, sh = i["palette"], i["shape"]
    return {
        "name": i["name"],
        # The same colors niri-loft's bar gets (render/niri.py).
        "title_bar_active": p["surface"],
        "title_bar_inactive": p["bg"],
        "title_bar_text": p["text"],
        "title_bar_text_inactive": p["subtext"],
        # Aqua beads, fixed across themes like gtk.css's (render/gtk.py).
        "traffic_close": "#ff5f57",
        "traffic_minimize": "#febc2e",
        "traffic_zoom": "#28c840",
        "traffic_inactive": c.with_alpha(p["text"], 0.22),
        "traffic_glyph": c.with_alpha("#000000", 0.55),
        "window_radius": c.num(sh["radius"]["window"]),
        "shadow": look.shadow(sh),
        "shadow_inactive": look.shadow_inactive(sh),
    }


def render(i: dict, template_dir: Path) -> dict:
    return {"kdecoration.ini": template(template_dir, "kdecoration.ini", variables(i))}


UNIT = Unit(
    name="kdecoration",
    reads=("colors", "shape"),
    files=("kdecoration.ini",),
    inputs=inputs,
    render=render,
    hook=None,
    module=__file__,
    templates=("kdecoration.ini",),
)
