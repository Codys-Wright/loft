"""Value forms every facet kind but Colors may use (docs/THEME-ARCHITECTURE.md §2):

  polar values      {"dark": x, "light": y} → the side matching the resolved polarity
  color references  "@bg" (any palette role), "@mix(bg,#ffffff,0.5)", "@alpha(text,0.22)"
"""

from __future__ import annotations

import re

from .. import color

FN = re.compile(r"^@(?P<fn>mix|alpha)\((?P<args>[^()]*)\)$")
ROLE = re.compile(r"^@?(?P<role>[A-Za-z][A-Za-z0-9_]*)$")


class RefError(ValueError):
    pass


def is_polar(v) -> bool:
    return isinstance(v, dict) and len(v) == 2 and set(v) == {"dark", "light"}


def polar(data, polarity: str):
    """Replace every {dark, light} object by the side for `polarity`."""
    side = "light" if polarity == "light" else "dark"
    if is_polar(data):
        return polar(data[side], polarity)
    if isinstance(data, dict):
        return {k: polar(v, polarity) for k, v in data.items()}
    if isinstance(data, list):
        return [polar(v, polarity) for v in data]
    return data


def _color_arg(arg: str, palette: dict) -> str:
    arg = arg.strip()
    if color.HEX.match(arg):
        return arg
    m = ROLE.match(arg)
    if m and isinstance(palette.get(m["role"]), str):
        return palette[m["role"]]
    raise RefError(f"unknown color {arg!r} (a palette role or #rrggbb)")


def _number(arg: str) -> float:
    try:
        x = float(arg)
    except ValueError:
        raise RefError(f"expected a number, got {arg!r}") from None
    if not 0 <= x <= 1:
        raise RefError(f"{arg} is not in 0..1")
    return x


def color_ref(value: str, palette: dict) -> str:
    """One `@…` reference → a #rrggbb (or #rrggbbaa for @alpha) color."""
    m = FN.match(value)
    if m:
        args = [a for a in m["args"].split(",")]
        if m["fn"] == "mix":
            if len(args) != 3:
                raise RefError(f"{value}: @mix(a, b, t) takes 3 arguments")
            return color.mix(_color_arg(args[0], palette), _color_arg(args[1], palette), _number(args[2]))
        if len(args) != 2:
            raise RefError(f"{value}: @alpha(c, a) takes 2 arguments")
        return color.with_alpha(_color_arg(args[0], palette), _number(args[1]))
    m = ROLE.match(value)
    if m and isinstance(palette.get(m["role"]), str):
        return palette[m["role"]]
    raise RefError(f"bad color reference {value!r} (@role, @mix(a,b,t), @alpha(c,a))")


def resolve(data, palette: dict):
    """Replace every string starting with `@` by the color it names."""
    if isinstance(data, str) and data.startswith("@"):
        return color_ref(data, palette)
    if isinstance(data, dict):
        return {k: resolve(v, palette) for k, v in data.items()}
    if isinstance(data, list):
        return [resolve(v, palette) for v in data]
    return data
