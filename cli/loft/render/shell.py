"""Unit `shell`: theme.json, every token the shell's Theme singleton reads
(§6.4), and the default wallpaper copied next to it.

The flat v1 keys (name … radii) stay exactly as they were, for Theme.qml's
current properties and the greeter, which reads theme.json with XHR. The
grouped keys are new: `shape.focus` (shadow | ring | both, next to
the v1 radii), `motion` (durations already divided by the
speed, 0 when minimal), `type`, `icons`, `a11y` and `windows` (app
windows' translucency, for loft-niri's window rules).

Identity (theme id, variant, sources, customized kinds) is not in here: it is
the composition's resolved.json, so two selections that look the same share
this file.
"""

from __future__ import annotations

import json
from pathlib import Path

from . import look, wallpapers
from .unit import Source, Unit


def _default_wallpaper(src: Source) -> dict | None:
    """{path, kind, copy}: copy when the image lives in the wallpapers facet's
    own pack (a rendered bundle is self-contained then)."""
    e = wallpapers.default_entry(src.facet("wallpapers"))
    if e is None:
        return None
    origin = src.res.origins.get("wallpapers")
    root = origin.root.resolve() if origin is not None and origin.root is not None else None
    return {"path": str(e["path"]), "copy": bool(root is not None and root in e["path"].parents)}


def inputs(src: Source) -> dict:
    ty = src.facet("typography")
    return {
        "name": src.res.name,
        "colors": src.facet("colors"),
        "material": src.facet("material"),
        # gaps and border are niri's alone
        "shape": {k: src.facet("shape")[k] for k in ("radius", "focus", "shadow")},
        "typography": {k: ty[k] for k in ("ui", "mono", "display")},
        "motion": src.facet("motion"),
        "icons": src.facet("icons"),
        "a11y": dict(src.res.accessibility),
        "wallpaper": _default_wallpaper(src),
    }


def _asset_name(wp: dict | None) -> str | None:
    return "wallpaper" + Path(wp["path"]).suffix.lower() if wp and wp["copy"] else None


def assets(i: dict) -> list:
    dest = _asset_name(i["wallpaper"])
    return [(Path(i["wallpaper"]["path"]), dest)] if dest else []


def motion_tokens(m: dict) -> dict:
    """Theme.motion: what the shell animates with."""
    speed = float(m["speed"])
    minimal = bool(m["minimal"])
    shell = m["shell"]
    return {
        "speed": speed,
        "minimal": minimal,
        "durations": {k: 0 if minimal else round(v / speed) for k, v in shell["durations"].items()},
        "curves": shell["curves"],
        "spring": shell["spring"],
    }


def document(i: dict) -> dict:
    colors, material, shape = i["colors"], i["material"], i["shape"]
    wp = i["wallpaper"]
    radii = {"windowRadius": shape["radius"]["window"], "panelRadius": shape["radius"]["panel"], "controlRadius": shape["radius"]["control"]}
    ty = i["typography"]
    return {
        # v1 keys, unchanged
        "name": i["name"],
        "polarity": colors.get("polarity", "dark"),
        "palette": look.palette(colors),
        "ansi": look.ansi(colors),
        "glass": look.glass(material, shape),
        "wallpaper": {"gradient": look.gradient(colors), "image": _asset_name(wp) or (wp["path"] if wp else "")},
        "fonts": look.fonts(ty),
        "shape": {**radii, "focus": shape["focus"]},
        "bar": {"adaptiveText": bool(material["menuBar"]["adaptiveText"]), "background": bool(material["menuBar"]["background"])},
        "radii": {"window": radii["windowRadius"]},
        # grouped by kind (§6.4)
        "motion": motion_tokens(i["motion"]),
        "type": ty,
        "icons": {"theme": i["icons"]["icons"]["theme"], "fallback": i["icons"]["icons"]["fallback"], "cursor": i["icons"]["cursor"]},
        "a11y": i["a11y"],
        "windows": look.windows(material),
    }


def render(i: dict, template_dir: Path) -> dict:
    return {"theme.json": json.dumps(document(i), indent=2) + "\n"}


UNIT = Unit(
    name="shell",
    reads=("colors", "material", "shape", "typography", "motion", "icons", "wallpapers"),
    files=("theme.json",),
    inputs=inputs,
    render=render,
    hook="shell",
    module=__file__,
    assets=assets,
)
