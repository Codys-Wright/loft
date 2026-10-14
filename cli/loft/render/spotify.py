"""Unit `spotify`: spicetify.ini, the palette as a scheme for spicetify-themes'
`text` theme. `loft spotify` merges its sections into the text theme's
color.ini; the hook re-syncs Loft's Spicetify install (cli/loft/spotify.py),
whose loft-live.js swaps the colors in live. A pack's apps/spicetify.ini
replaces it.

  colors  the palette and polarity (foregrounds pushed to readable contrast)
"""

from __future__ import annotations

from pathlib import Path

from .. import color as c
from .. import palette
from . import look
from .unit import Source, Unit, template


def inputs(src: Source) -> dict:
    return {"name": src.res.name, "colors": {k: src.facet("colors")[k] for k in ("polarity", "palette")}}


def spicetify_scheme(p: dict[str, str], dark: bool) -> dict[str, str]:
    """The palette as a scheme for spicetify-themes' `text` theme (its
    color.ini keys plus Spicetify's base colors), hex without `#`.

    text paints nearly everything from a handful of keys: `main` is every
    background (sidebar, player and cards derive from it in its user.css),
    `text`/`subtext` the foregrounds, `header`/`banner` titles and the
    ASCII banner, `accent*`/`button*` controls and the playing row,
    `border-inactive` card fills and hairlines, `highlight` hover/press.
    Foregrounds are pushed to readable contrast on `main` (light themes
    too); the accent keeps 3:1, so it stays visible as a fill and as text.
    """
    pc = palette.ensure_contrast
    bg = c.hex6(p["bg"])
    text = pc(p["text"], bg, 7.0)
    subtext = pc(p["subtext"], bg, 4.5)
    accent = pc(p["accent"], bg, 3.0)
    accent2 = pc(p["accent2"], bg, 3.0)
    surface = c.hex6(p["surface"])
    # Card fills and borders: a visible step from main, whatever the pack's surface.
    border = surface if c.contrast(surface, bg) >= 1.12 else c.mix(bg, p["overlay"], 0.45)
    s = {
        "text": text,
        "subtext": subtext,
        "main": bg,
        "main-elevated": surface,
        "highlight": c.mix(bg, p["overlay"], 0.7),
        "highlight-elevated": c.hex6(p["overlay"]),
        "sidebar": bg,
        "player": bg,
        "card": surface,
        "shadow": "000000" if dark else c.mix(p["overlay"], "#000000", 0.35),
        "selected-row": subtext,
        "button": accent,
        "button-active": accent,
        "button-disabled": pc(c.mix(p["overlay"], p["subtext"], 0.3), bg, 1.6),
        "tab-active": surface,
        "notification": accent2,
        "notification-error": pc(p["urgent"], bg, 3.0),
        "misc": c.hex6(p["overlay"]),
        "accent": accent,
        "accent-active": accent,
        "accent-inactive": c.mix(bg, surface, 0.5),
        "banner": accent,
        "border-active": accent,
        "border-inactive": border,
        "header": pc(c.mix(p["subtext"], bg, 0.3), bg, 3.0),
    }
    return {k: v.lstrip("#").lower() for k, v in s.items()}


def render(i: dict, template_dir: Path) -> dict:
    v = {"name": i["name"]}
    v.update({f"spice_{k.replace('-', '_')}": val for k, val in spicetify_scheme(look.palette(i["colors"]), look.dark(i["colors"])).items()})
    return {"spicetify.ini": template(template_dir, "spicetify.ini", v)}


UNIT = Unit(name="spotify", reads=("colors",), files=("spicetify.ini",), inputs=inputs, render=render, hook="spotify", module=__file__, templates=("spicetify.ini",))
