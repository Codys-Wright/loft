"""Unit `niri`: niri.kdl, included right after Loft's base.kdl.

  colors    focus ring / border / urgent colors, overview backdrop, ⌘Tab highlight
  material  blur on/off, passes/offset (only when not base.kdl's 3/4), noise,
            saturation, xray; through the Blur dial (render/look.py: Clear =
            `off`, windows stay translucent)
  shape     window radius, shadow colors (inactive = shadow.inactive × the
            focused one's alpha), gaps (when set), the focus style (`shadow`:
            no ring; `ring`: ring, small focused shadow; `both`), border
  motion    `animations {}`: off when minimal, slowdown = 1/speed, and the
            facet's `niri` keys passed through as niri's own nodes

Nothing is written for motion at its defaults (speed 1, no niri keys), so
niri's defaults apply. overrides/niri.kdl is included after this file, so a
user's `layout.gaps` or animation override still wins.
"""

from __future__ import annotations

import json
from pathlib import Path

from .. import color as c
from . import look
from .unit import Source, Unit, template

IND = "    "


def inputs(src: Source) -> dict:
    return {
        "name": src.res.name,
        "palette": look.palette(src.facet("colors")),
        "blur": look.blur(src.facet("material"), src.res.transparency),
        "shape": src.facet("shape"),
        "motion": {k: src.facet("motion")[k] for k in ("speed", "minimal", "niri")},
    }


def kdl_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        s = repr(v)
        return s if any(ch in s for ch in ".en") else s + ".0"
    return json.dumps(str(v), ensure_ascii=False)


def _node(key: str, val, depth: int) -> list[str]:
    """One niri animation setting as KDL: `true` → a bare flag, false/null →
    omitted, scalars and arrays → arguments, an object inside an animation →
    properties (`spring damping-ratio=1.0 …`), a top-level object → a block."""
    pad = IND * depth
    if val is None or val is False:
        return []
    if val is True:
        return [pad + key]
    if isinstance(val, list):
        return [pad + key + "".join(" " + kdl_value(x) for x in val)]
    if isinstance(val, dict):
        if depth >= 2:
            return [pad + key + "".join(f" {k}={kdl_value(x)}" for k, x in val.items())]
        lines = [pad + key + " {"]
        for k, x in val.items():
            lines += _node(k, x, depth + 1)
        return lines + [pad + "}"]
    return [pad + f"{key} {kdl_value(val)}"]


def animations(m: dict) -> str:
    if m["minimal"]:
        body = [IND + "off"]
        why = "motion is minimal (or Reduce Motion is on): niri animates nothing"
    else:
        body = []
        speed = float(m["speed"])
        if speed != 1.0:
            body.append(IND + f"slowdown {kdl_value(float(c.num(1 / speed)))}")
        for k, v in (m.get("niri") or {}).items():
            body += _node(k, v, 1)
        if not body:
            return ""
        why = f"motion: speed {c.num(speed)} (slowdown = 1/speed) and the facet's niri animations"
    return f"\n// {why}.\nanimations {{\n" + "\n".join(body) + "\n}\n"


def focus(shape: dict) -> tuple[str, str]:
    """(focus-ring on/off lines, extra window rules) for shape.focus."""
    style = shape["focus"]
    ring = "on\n" + IND * 2 + f"width {kdl_value(shape['focusRing']['width'])}" if style in ("ring", "both") else "off"
    rules = ""
    if style == "ring":
        # The ring marks the focused window: give it base.kdl's small shadow
        # instead of the larger, deeper one.
        rules = (
            "\n// shape.focus \"ring\": the ring marks the focused window, so its shadow stays small.\n"
            "window-rule {\n    match is-focused=true\n    shadow {\n        softness 16\n        spread 1\n        offset x=0 y=4\n    }\n}\n"
        )
    return ring, rules


def blur_quality(b: dict) -> str:
    """passes / offset lines, only where they differ from base.kdl's (so the
    product default renders as before)."""
    out = ""
    if int(b["passes"]) != 3:
        out += f"\n{IND}passes {int(b['passes'])}"
    if float(b["offset"]) != 4.0:
        out += f"\n{IND}offset {kdl_value(float(b['offset']))}"
    return out


def variables(i: dict) -> dict[str, str]:
    p, b, sh = i["palette"], i["blur"], i["shape"]
    ring, rules = focus(sh)
    border = sh["border"]
    return {
        "name": i["name"],
        "accent": p["accent"],
        "urgent": p["urgent"],
        "overlay": p["overlay"],
        "bg": p["bg"],
        "focus_active": c.with_alpha(p["accent"], 0.8),
        "focus_inactive": "#00000000",
        "shadow": look.shadow(sh),
        # Inactive windows: the same shadow, much fainter (Golden Gate makes
        # the focused window stand out).
        "shadow_inactive": look.shadow_inactive(sh),
        "window_radius": c.num(sh["radius"]["window"]),
        "niri_blur": ("on" if b["on"] else "off") + blur_quality(b),
        "glass_noise": c.num(float(b["noise"])),
        "glass_saturation": c.num(float(b["saturation"])),
        "niri_xray_rules": (
            ""
            if b["xray"]
            else (
                "\n// This theme turns xray off: blur what is really behind each surface.\n"
                "window-rule {\n    background-effect {\n        xray false\n    }\n}\n"
                "layer-rule {\n    background-effect {\n        xray false\n    }\n}\n"
            )
        ),
        "niri_gaps": "" if sh.get("gaps") is None else f"{IND}// shape.gaps\n{IND}gaps {kdl_value(sh['gaps'])}\n\n",
        "niri_focus_ring": ring,
        "niri_border": ("on\n" + IND * 2 + f"width {kdl_value(border['width'])}") if border["enabled"] else "off",
        "niri_focus_rules": rules,
        "niri_animations": animations(i["motion"]),
    }


def render(i: dict, template_dir: Path) -> dict:
    return {"niri.kdl": template(template_dir, "niri.kdl", variables(i))}


UNIT = Unit(
    name="niri",
    reads=("colors", "material", "shape", "motion"),
    files=("niri.kdl",),
    inputs=inputs,
    render=render,
    hook="niri",
    module=__file__,
    templates=("niri.kdl",),
)
