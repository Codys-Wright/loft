"""Consumer-ready values from resolved facets, shared by the units.

These are the rules `pack.normalize_theme` applied to a v1 theme.json, split
by facet kind so each unit computes only what it reads. Each function takes
the (already resolved: polar values picked, @color refs replaced) data of the
kinds named in its signature, nothing else.
"""

from __future__ import annotations

from .. import color as c
from .. import palette as pal_
from ..pack import ROLES, derive_ansi


def dark(colors: dict) -> bool:
    return colors.get("polarity", "dark") != "light"


def palette(colors: dict) -> dict:
    """The ten roles as lowercase #rrggbb, extra entries (base16 slots …) kept."""
    p_in = colors["palette"]
    p = {role: c.hex6(p_in[role]) for role in ROLES}
    p.update({k: v for k, v in p_in.items() if k not in p})
    return p


def ansi(colors: dict) -> list[str]:
    if colors.get("ansi") is not None:
        return [c.hex6(x) for x in colors["ansi"]]
    return derive_ansi(palette(colors), dark(colors))


def gradient(colors: dict) -> list[str]:
    """The wallpaper fallback: the colors' own gradient, else one from bg toward the accents."""
    p = palette(colors)
    return [c.hex6(x) for x in colors.get("gradient") or []] or [
        p["bg"],
        c.mix(p["bg"], p["accent"], 0.35),
        c.mix(p["bg"], p["accent2"], 0.6),
    ]


def shadow(shape: dict) -> str:
    """The focused window's shadow color: shape.shadow.color, else black at
    the (polar) shadow opacity (#00000066 dark, #0000002e light)."""
    s = shape["shadow"]
    return (s["color"] if s.get("color") else c.with_alpha("#000000", s["opacity"])).lower()


def shadow_inactive(shape: dict) -> str:
    sh = shadow(shape)
    return c.with_alpha(sh, c.parse(sh)[3] * shape["shadow"]["inactive"])


def terminal_opacity(material: dict) -> float:
    """Terminals need more body than shell glass: 0.85 with blur, else opaque."""
    t = material["terminals"].get("opacity")
    return float(t) if t is not None else (0.85 if material["blur"]["enabled"] else 1.0)


def glass(material: dict, shape: dict) -> dict:
    """The v1 `glass` block of theme.json (key order kept)."""
    m, g = material, material["glass"]
    return {
        "blur": bool(m["blur"]["enabled"]),
        "xray": bool(m["blur"]["xray"]),
        "tint": c.hex6(g["tint"]),
        "opacity": float(g["opacity"]),
        "border": c.hex6(g["border"]),
        "borderOpacity": float(g["borderOpacity"]),
        "radius": shape["radius"]["surface"],
        "noise": float(m["blur"]["noise"]),
        "saturation": float(m["blur"]["saturation"]),
        "terminalOpacity": terminal_opacity(m),
        "shadow": shadow(shape),
        "edgeDarken": float(g["edgeDarken"]),
        "specular": float(g["specular"]),
    }


def fonts(typography: dict) -> dict:
    """v1 `fonts`: null families are the shell's / the terminal's own."""
    t = typography
    return {"ui": t["ui"]["family"] or "sans-serif", "mono": t["mono"]["family"] or "monospace", "size": t["mono"]["size"]}


def palette_vars(name: str, colors: dict) -> dict[str, str]:
    """Template variables every palette consumer shares."""
    p = palette(colors)
    d = dark(colors)
    v: dict[str, str] = {
        "name": name,
        "polarity": colors.get("polarity", "dark"),
        "color_scheme": "prefer-dark" if d else "prefer-light",
    }
    v.update({role: p[role] for role in ROLES})
    v.update({f"color{i}": col for i, col in enumerate(ansi(colors))})
    # Foregrounds that stay readable on the colored roles.
    for role in ("accent", "accent2", "urgent", "ok", "warn"):
        v[f"on_{role}"] = c.readable_on(p[role], p["bg"], p["text"])
    v.update(
        {
            "cursor": p["text"],
            "cursor_text": p["bg"],
            "selection_bg": p["overlay"],
            "selection_fg": p["text"],
            # Raised surfaces step from bg toward the text side.
            "bg_alt": c.mix(p["bg"], p["surface"], 0.5),
            "surface_alt": c.mix(p["surface"], p["overlay"], 0.5),
            "dim": c.mix(p["subtext"], p["bg"], 0.35),
        }
    )
    return v


def terminal_font(typography: dict) -> tuple[str, str] | None:
    """(family, size) when the theme takes over the terminal font (applyTo.terminals)."""
    if not typography["applyTo"]["terminals"]:
        return None
    f = fonts(typography)
    return f["mono"], c.num(f["size"])


ensure_contrast = pal_.ensure_contrast
