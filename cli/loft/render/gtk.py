"""Unit `gtk`: gtk.css, imported by ~/.config/gtk-{3,4}.0/gtk.css.

  colors    libadwaita named colors, Loft's palette, color-scheme
  material  glass sidebars (tint over niri's blur, opaque without blur; its alpha
            through the Transparency dial, render/look.py), specular
  shape     the window radius

Hook: gsettings color-scheme and the polarity's GTK base stylesheet (the
CSS itself applies to new windows).
"""

from __future__ import annotations

from pathlib import Path

from .. import color as c
from . import look
from .unit import Source, Unit, template


def inputs(src: Source) -> dict:
    m = src.facet("material")
    return {
        "name": src.res.name,
        "colors": {k: src.facet("colors")[k] for k in ("polarity", "palette")},
        "glass": {"blur": m["blur"]["enabled"], "tint": m["glass"]["tint"], "opacity": m["glass"]["opacity"], "specular": m["glass"]["specular"]},
        # Only what the dial changes here (cache key): the sidebar alpha.
        "transparency": {k: v for k, v in src.res.transparency.items() if k in ("level", "gtk")},
        "windowRadius": src.facet("shape")["radius"]["window"],
    }


def variables(i: dict) -> dict[str, str]:
    v = look.palette_vars(i["name"], i["colors"])
    p = look.palette(i["colors"])
    dark = look.dark(i["colors"])
    g = i["glass"]
    tint, blur = c.hex6(g["tint"]), bool(g["blur"])
    alpha = look.gtk_glass_alpha({"glass": {"opacity": g["opacity"]}}, dark, i.get("transparency"))
    v.update(
        {
            "window_radius": c.num(i["windowRadius"]),
            # Traffic lights (close / minimize / zoom), Aqua colors: fixed
            # across themes so they read the same everywhere.
            "traffic_close": "#ff5f57",
            "traffic_minimize": "#febc2e",
            "traffic_zoom": "#28c840",
            "traffic_inactive": c.rgba(p["text"], 0.22),
            "traffic_glyph": "rgba(0, 0, 0, 0.55)",
            "specular": c.rgba("#ffffff", min(1.0, float(g["specular"]) * (0.35 if dark else 0.7))),
            # Glass sidebars in GTK apps (Nautilus): the theme's glass tint over
            # the blur niri draws behind the window; opaque without blur. The
            # alpha (look.gtk_glass_alpha) is dense enough that sidebar text
            # reads over any wallpaper at the theme's level, then the dial's.
            "gtk_sidebar_glass": (c.rgba(c.mix(tint, p["surface"], 0.5), alpha) if blur else p["surface"]),
            "gtk_sidebar_hover": c.rgba(p["text"], 0.07),
            "gtk_sidebar_selected": c.rgba(p["text"], 0.13 if dark else 0.1),
            "gtk_hairline": c.rgba(p["text"], 0.1 if dark else 0.14),
            # Selected files / items: the accent as a tint, so the item's own
            # text color stays readable on every palette.
            "gtk_selection": c.rgba(p["accent"], 0.32 if dark else 0.24),
            "gtk_selection_hover": c.rgba(p["accent"], 0.4 if dark else 0.3),
            # Raised surfaces (popovers, menus, dialogs, cards): a step toward
            # the text side in dark themes, toward white in light ones.
            "gtk_raised": p["surface"] if dark else c.mix(p["bg"], "#ffffff", 0.6),
        }
    )
    return v


def render(i: dict, template_dir: Path) -> dict:
    return {"gtk.css": template(template_dir, "gtk.css", variables(i))}


UNIT = Unit(
    name="gtk",
    reads=("colors", "material", "shape"),
    files=("gtk.css",),
    inputs=inputs,
    render=render,
    hook="gtk",
    module=__file__,
    templates=("gtk.css",),
)
