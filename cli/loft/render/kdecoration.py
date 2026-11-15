"""Unit `kdecoration`: kdecoration.ini, the appearance of Loft's KWin
decoration (dev.loft.decoration, kdecoration/).

The decoration is macOS Tahoe's title bar (kdecoration/tahoe.h): its bar,
title, grey beads, outline and shadow come in a light and a dark set, and the
traffic lights are fixed colors, as on macOS. So the theme only says which
set: `Appearance=light|dark`, from the colors' polarity. (The plugin still
reads [Colors] TitleBarActive / TitleBarInactive / TextActive / TextInactive
and [Metrics] CornerRadius / TitleBarHeight / FontSize when a file sets them;
docs/KWIN.md §4.4.)

The plugin reads `<state>/current/kdecoration.ini` and watches it (and the
`current` link), so no hook: a theme change repaints open windows at once.
Without the file it is Tahoe dark.
"""

from __future__ import annotations

from pathlib import Path

from . import look
from .unit import Source, Unit, template


def inputs(src: Source) -> dict:
    return {"name": src.res.name, "dark": look.dark(src.facet("colors"))}


def variables(i: dict) -> dict[str, str]:
    return {"name": i["name"], "appearance": "dark" if i["dark"] else "light"}


def render(i: dict, template_dir: Path) -> dict:
    return {"kdecoration.ini": template(template_dir, "kdecoration.ini", variables(i))}


UNIT = Unit(
    name="kdecoration",
    reads=("colors",),
    files=("kdecoration.ini",),
    inputs=inputs,
    render=render,
    hook=None,
    module=__file__,
    templates=("kdecoration.ini",),
)
