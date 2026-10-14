"""Small color helpers for deriving consumer colors from a theme palette.

Colors are "#rrggbb" (or "#rrggbbaa", CSS order) strings in and out; math
happens on 0..1 floats. Kept dependency-free so the renderer runs anywhere.
"""

from __future__ import annotations

import colorsys
import re

HEX = re.compile(r"^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$")


def parse(c: str) -> tuple[float, float, float, float]:
    m = HEX.match(c)
    if not m:
        raise ValueError(f"not a #rrggbb[aa] color: {c!r}")
    rgb = m.group(1)
    a = int(m.group(2), 16) / 255 if m.group(2) else 1.0
    return (int(rgb[0:2], 16) / 255, int(rgb[2:4], 16) / 255, int(rgb[4:6], 16) / 255, a)


def _byte(x: float) -> int:
    return max(0, min(255, round(x * 255)))


def hex6(c: str) -> str:
    """Normalize to lowercase #rrggbb (drops alpha)."""
    r, g, b, _ = parse(c)
    return "#%02x%02x%02x" % (_byte(r), _byte(g), _byte(b))


def with_alpha(c: str, a: float) -> str:
    """#rrggbbaa with the given alpha (CSS / niri order, not Qt's #aarrggbb)."""
    return hex6(c) + "%02x" % _byte(a)


def rgba(c: str, a: float) -> str:
    """CSS rgba() — understood by GTK 3/4 CSS, unlike #rrggbbaa."""
    r, g, b, _ = parse(c)
    return f"rgba({_byte(r)}, {_byte(g)}, {_byte(b)}, {num(a)})"


def mix(a: str, b: str, t: float) -> str:
    """Linear blend from a (t=0) to b (t=1)."""
    ar, ag, ab, _ = parse(a)
    br, bg, bb, _ = parse(b)
    return "#%02x%02x%02x" % (
        _byte(ar + (br - ar) * t),
        _byte(ag + (bg - ag) * t),
        _byte(ab + (bb - ab) * t),
    )


def _hls(c: str) -> tuple[float, float, float]:
    r, g, b, _ = parse(c)
    return colorsys.rgb_to_hls(r, g, b)


def _from_hls(h: float, l: float, s: float) -> str:
    r, g, b = colorsys.hls_to_rgb(h % 1.0, max(0.0, min(1.0, l)), max(0.0, min(1.0, s)))
    return "#%02x%02x%02x" % (_byte(r), _byte(g), _byte(b))


def lighten(c: str, amount: float) -> str:
    """Shift HSL lightness by amount (negative darkens)."""
    h, l, s = _hls(c)
    return _from_hls(h, l + amount, s)


def with_hue(c: str, degrees: float) -> str:
    """Same lightness/saturation, different hue — e.g. a cyan from the accent."""
    _, l, s = _hls(c)
    return _from_hls(degrees / 360, l, s)


def luminance(c: str) -> float:
    """WCAG relative luminance."""

    def lin(x: float) -> float:
        return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4

    r, g, b, _ = parse(c)
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def contrast(a: str, b: str) -> float:
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def readable_on(bg: str, *candidates: str) -> str:
    """The candidate with the best contrast against bg."""
    return max(candidates, key=lambda c: contrast(bg, c))


def num(x: float) -> str:
    """Stable, short number formatting for config files (0.45, 1.6, 14)."""
    return f"{x:g}"
