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


# ── perceptual distance (CIELAB, D65) ───────────────────────────────────────

_D65 = (0.95047, 1.0, 1.08883)


def to_lab(c: str) -> tuple[float, float, float]:
    """sRGB → CIELAB (D65, 2°): L in 0..100, a/b roughly -128..127."""

    def lin(x: float) -> float:
        return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4

    r, g, b, _ = parse(c)
    r, g, b = lin(r), lin(g), lin(b)
    x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / _D65[0]
    y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / _D65[1]
    z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / _D65[2]

    def f(t: float) -> float:
        return t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116

    fx, fy, fz = f(x), f(y), f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def delta_e(a, b) -> float:
    """CIEDE2000 color difference between two colors (hex strings or Lab tuples).

    ~1 is a just-noticeable difference, ~10 clearly different, 50+ unrelated.
    """
    import math

    l1, a1, b1 = to_lab(a) if isinstance(a, str) else a
    l2, a2, b2 = to_lab(b) if isinstance(b, str) else b
    c1, c2 = math.hypot(a1, b1), math.hypot(a2, b2)
    cm = (c1 + c2) / 2
    g = 0.5 * (1 - math.sqrt(cm**7 / (cm**7 + 25**7)))
    a1p, a2p = a1 * (1 + g), a2 * (1 + g)
    c1p, c2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360 if c1p else 0.0
    h2p = math.degrees(math.atan2(b2, a2p)) % 360 if c2p else 0.0
    dl = l2 - l1
    dc = c2p - c1p
    if c1p * c2p == 0:
        dh = 0.0
    else:
        dh = h2p - h1p
        if dh > 180:
            dh -= 360
        elif dh < -180:
            dh += 360
    dH = 2 * math.sqrt(c1p * c2p) * math.sin(math.radians(dh / 2))
    lm = (l1 + l2) / 2
    cmp_ = (c1p + c2p) / 2
    if c1p * c2p == 0:
        hm = h1p + h2p
    elif abs(h1p - h2p) <= 180:
        hm = (h1p + h2p) / 2
    else:
        hm = (h1p + h2p + 360) / 2 if h1p + h2p < 360 else (h1p + h2p - 360) / 2
    t = (
        1
        - 0.17 * math.cos(math.radians(hm - 30))
        + 0.24 * math.cos(math.radians(2 * hm))
        + 0.32 * math.cos(math.radians(3 * hm + 6))
        - 0.20 * math.cos(math.radians(4 * hm - 63))
    )
    sl = 1 + 0.015 * (lm - 50) ** 2 / math.sqrt(20 + (lm - 50) ** 2)
    sc = 1 + 0.045 * cmp_
    sh = 1 + 0.015 * cmp_ * t
    rt = -2 * math.sqrt(cmp_**7 / (cmp_**7 + 25**7)) * math.sin(math.radians(60 * math.exp(-(((hm - 275) / 25) ** 2))))
    return math.sqrt((dl / sl) ** 2 + (dc / sc) ** 2 + (dH / sh) ** 2 + rt * (dc / sc) * (dH / sh))
