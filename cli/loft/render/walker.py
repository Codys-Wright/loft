"""Unit `walker`: walker.css, the colors Spotlight's walker theme imports
(colors.css → <state>/current/walker.css; walker re-reads it on every open,
so there is no hook).

  colors    the palette
  material  the glass tint, opacity and stroke
  launcher  `glass`: the launcher sheet's glass strength relative to the
            material (opacity × glass, at most 0.92)
"""

from __future__ import annotations

from pathlib import Path

from .. import color as c
from . import look
from .unit import Source, Unit, template


def inputs(src: Source) -> dict:
    g = src.facet("material")["glass"]
    return {
        "name": src.res.name,
        "colors": {k: src.facet("colors")[k] for k in ("polarity", "palette")},
        "glass": {k: g[k] for k in ("tint", "opacity", "border", "borderOpacity")},
        "launcher": {"glass": src.facet("launcher")["glass"]},
    }


def render(i: dict, template_dir: Path) -> dict:
    v = look.palette_vars(i["name"], i["colors"])
    p = look.palette(i["colors"])
    g = i["glass"]
    tint, opacity = c.hex6(g["tint"]), float(g["opacity"])
    v["launcher_glass"] = c.rgba(tint, min(opacity * float(i["launcher"]["glass"]), 0.92))
    v["glass_stroke"] = c.rgba(c.hex6(g["border"]), float(g["borderOpacity"]))
    v["launcher_selection"] = c.rgba(p["text"], 0.12)
    return {"walker.css": template(template_dir, "walker.css", v)}


UNIT = Unit(
    name="walker",
    reads=("colors", "material", "launcher"),
    files=("walker.css",),
    inputs=inputs,
    render=render,
    hook=None,
    module=__file__,
    templates=("walker.css",),
)
