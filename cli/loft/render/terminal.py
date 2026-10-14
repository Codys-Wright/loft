"""Units `kitty` and `ghostty`: the terminals' colors, glass and (when the
typography facet applies to terminals) font.

  colors      foreground/background, selection, cursor, tabs, 16 ANSI colors
  material    background opacity (terminals.opacity, else 0.85 with blur) and blur
  typography  mono family and size, only with applyTo.terminals

Hooks: SIGUSR1 (kitty), SIGUSR2 (ghostty).
"""

from __future__ import annotations

from pathlib import Path

from .. import color as c
from . import look
from .unit import Source, Unit, template


def inputs(src: Source) -> dict:
    m, ty = src.facet("material"), src.facet("typography")
    return {
        "name": src.res.name,
        "colors": {k: src.facet("colors")[k] for k in ("polarity", "palette", "ansi")},
        "terminal": {"opacity": look.terminal_opacity(m), "blur": bool(m["blur"]["enabled"])},
        "font": look.terminal_font(ty),
    }


def _vars(i: dict) -> dict[str, str]:
    v = look.palette_vars(i["name"], i["colors"])
    v["terminal_opacity"] = c.num(i["terminal"]["opacity"])
    return v


def render_kitty(i: dict, template_dir: Path) -> dict:
    v = _vars(i)
    v["kitty_blur"] = "1" if i["terminal"]["blur"] else "0"
    f = i["font"]
    v["kitty_fonts"] = f"font_family {f[0]}\nfont_size {f[1]}\n" if f else ""
    return {"kitty.conf": template(template_dir, "kitty.conf", v)}


def render_ghostty(i: dict, template_dir: Path) -> dict:
    v = _vars(i)
    v["glass_blur"] = "true" if i["terminal"]["blur"] else "false"
    f = i["font"]
    v["ghostty_fonts"] = f"font-family = {f[0]}\nfont-size = {f[1]}\n" if f else ""
    return {"ghostty.conf": template(template_dir, "ghostty.conf", v)}


READS = ("colors", "material", "typography")

KITTY = Unit(name="kitty", reads=READS, files=("kitty.conf",), inputs=inputs, render=render_kitty, hook="kitty", module=__file__, templates=("kitty.conf",))
GHOSTTY = Unit(name="ghostty", reads=READS, files=("ghostty.conf",), inputs=inputs, render=render_ghostty, hook="ghostty", module=__file__, templates=("ghostty.conf",))
