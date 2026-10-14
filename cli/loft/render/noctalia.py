"""Unit `noctalia`: noctalia.json, Noctalia's color scheme (transition only;
its own watcher picks the file up)."""

from __future__ import annotations

from pathlib import Path

from . import look
from .unit import Source, Unit, template


def inputs(src: Source) -> dict:
    return {"name": src.res.name, "colors": {k: src.facet("colors")[k] for k in ("polarity", "palette")}}


def render(i: dict, template_dir: Path) -> dict:
    return {"noctalia.json": template(template_dir, "noctalia.json", look.palette_vars(i["name"], i["colors"]))}


UNIT = Unit(name="noctalia", reads=("colors",), files=("noctalia.json",), inputs=inputs, render=render, hook=None, module=__file__, templates=("noctalia.json",))
