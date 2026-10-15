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


# ── The Transparency and Blur dials ─────────────────────────────────────────
#
# appearance.json `transparency` (resolve.dials; Resolved.transparency, empty
# under Reduce Transparency). `level` is one master dial for every
# translucent thing Loft draws or configures:
#
#     0 Solid ─────────── 0.5 the theme's own values ─────────── 1 Clear
#
# Below 0.5 each value moves linearly from the theme's toward opaque; above
# it toward that consumer's clearest allowed value (CLEAR). The clear half is
# shaped per consumer, by what the alpha covers:
#
#   windows    niri's window opacity fades the WHOLE window, text included,
#              so it gets a floor (0.55 focused, 0.4 the rest) and an
#              ease-in curve (u^1.6): most of the slider's clear half only
#              thins the window a little, and the last stretch is where the
#              text actually starts to fade. The window you type in keeps
#              more body than the others. (Clearer still is an Advanced
#              override away: those sliders go down to 0.3.) Apps that draw
#              their own translucent background, like terminals with Window
#              Rules → "App's own", keep opacity 1 and fully opaque text.
#   terminals  background-opacity only touches the background: the text is
#              drawn opaque on top, so it can go much clearer (0.3), linearly.
#   gtk        the glass sidebar tint (Nautilus): its labels sit on it, over
#              niri's blur, so 0.3 with a gentle curve (u^1.25).
#   shell      the shell's own glass (Theme.qml) applies the same level to
#              glass.opacity itself, with its own legibility floor
#              (Theme.legibleAlpha + text shadows), so it may reach clear.
#
# `blur` (0 Clear … 1 Frosted) replaces the theme's blur radius: 0 turns
# niri's blur off everywhere (windows stay translucent, just unblurred).
# `terminals` / `gtk` are absolute overrides (Settings → Appearance →
# Advanced); the window overrides are loft-niri's own (`window-glass`).

LEVEL_THEME = 0.5
CLEAR = {"focused": 0.55, "unfocused": 0.4, "terminals": 0.3, "gtk": 0.3}
CURVE = {"focused": 1.6, "unfocused": 1.6, "terminals": 1.0, "gtk": 1.25}


def dial(theme_value: float, level: float | None, clear: float, curve: float = 1.0) -> float:
    """theme_value moved by the master level (see above); level None = as is."""
    v = float(theme_value)
    if level is None:
        return v
    level = min(1.0, max(0.0, float(level)))
    if level <= LEVEL_THEME:
        u = (LEVEL_THEME - level) / LEVEL_THEME
        out = v + (1.0 - v) * u
    else:
        u = ((level - LEVEL_THEME) / (1 - LEVEL_THEME)) ** curve
        lo = min(clear, v)  # a theme already clearer than the floor keeps its value
        out = v + (lo - v) * u
    return round(out, 3)


def _level(tr: dict | None) -> float | None:
    return (tr or {}).get("level")


def terminal_opacity(material: dict, tr: dict | None = None) -> float:
    """Terminals need more body than shell glass: 0.85 with blur, else opaque;
    then the dials (an absolute `terminals` override wins over the level)."""
    t = material["terminals"].get("opacity")
    base = float(t) if t is not None else (0.85 if material["blur"]["enabled"] else 1.0)
    tr = tr or {}
    if "terminals" in tr:
        return round(float(tr["terminals"]), 3)
    return dial(base, _level(tr), CLEAR["terminals"], CURVE["terminals"])


def windows(material: dict, tr: dict | None = None) -> dict:
    """theme.json `windows`: app windows' translucency, read by loft-niri
    (crates/loft-niri/src/window_rules.rs), which writes the niri rules. No
    translucent windows without blur (glassless themes, Reduce Transparency).
    The master level scales the opacities; loft-niri's own `window-glass`
    values (Advanced, Window Rules) still win over these."""
    w, on = material["windows"], bool(material["blur"]["enabled"])
    lv = _level(tr)
    return {
        "translucent": bool(w["translucent"]) and on,
        "opacity": {k: dial(w["opacity"][k], lv, CLEAR[k], CURVE[k]) for k in ("focused", "unfocused")},
        "blur": bool(w["blur"]) and on,
    }


# Theme blur strength ↔ niri's passes/offset. niri samples `passes` times,
# each `offset` further out (it clamps passes to 1..31, offset to 0..100); the
# product default (passes 3, offset 4) sits at 0.5, the dial's top (passes 4,
# offset 7) is a heavy frost, its bottom (1, ~1) barely softens.
def blur_strength(passes: int, offset: float) -> float:
    """Where a theme's passes/offset sit on the 0..1 Blur dial."""
    return round(min(1.0, max(0.05, (float(offset) - 1) / 6)), 3)


def blur(material: dict, tr: dict | None = None) -> dict:
    """niri's global blur: {on, strength, passes, offset, noise, saturation}.
    `on` false = niri's `off` (also for blur windows ask for); strength 0 is
    the Blur dial's Clear. Noise and saturation fade toward neutral as the
    dial goes below the theme's own strength (a light blur with a heavy
    grain looks dirty)."""
    b = material["blur"]
    passes, offset = int(b.get("passes", 3)), float(b.get("offset", 4))
    noise, sat = float(b["noise"]), float(b["saturation"])
    s0 = blur_strength(passes, offset)
    out = {"on": bool(b["enabled"]), "strength": s0, "passes": passes, "offset": offset, "noise": noise, "saturation": sat, "xray": bool(b["xray"])}
    s = (tr or {}).get("blur")
    if not out["on"]:
        return dict(out, strength=0.0)
    if s is None:
        return out
    s = min(1.0, max(0.0, float(s)))
    if s <= 0:
        return dict(out, on=False, strength=0.0)
    k = min(1.0, s / s0)
    return {
        **out,
        "on": True,
        "strength": round(s, 3),
        "passes": 1 + int(3 * s + 0.5),
        "offset": round(1 + 6 * s, 2),
        "noise": round(noise * k, 4),
        "saturation": round(1 + (sat - 1) * k, 3),
    }


def gtk_glass_alpha(material: dict, dark_: bool, tr: dict | None = None) -> float:
    """The GTK glass sidebar's tint alpha: dense enough that sidebar text
    reads over any wallpaper at the theme's level (a light theme over a dark
    wallpaper needs the most), then the dials."""
    g = material["glass"]
    base = min(max(float(g["opacity"]) * 1.4, 0.62 if dark_ else 0.72), 0.88)
    tr = tr or {}
    if "gtk" in tr:
        return round(float(tr["gtk"]), 3)
    return dial(base, _level(tr), CLEAR["gtk"], CURVE["gtk"])


def transparency(material: dict, tr: dict | None, a11y: dict | None, dark_: bool) -> dict:
    """theme.json `transparency`: the dials and what they produced, for the
    shell (Theme.qml applies `level` to its own glass) and Settings."""
    tr = tr or {}
    bl = blur(material, tr)
    return {
        "level": tr.get("level"),
        "blur": tr.get("blur"),
        "terminals": tr.get("terminals"),
        "gtk": tr.get("gtk"),
        "reduced": bool((a11y or {}).get("reduceTransparency")),
        "effective": {
            "level": tr.get("level", LEVEL_THEME),
            "blur": bl["strength"],
            "blurOn": bl["on"],
            "terminals": terminal_opacity(material, tr),
            "gtk": gtk_glass_alpha(material, dark_, tr),
        },
        "theme": {
            "blur": blur_strength(material["blur"].get("passes", 3), material["blur"].get("offset", 4)) if material["blur"]["enabled"] else 0.0,
            "terminals": terminal_opacity(material),
            "gtk": gtk_glass_alpha(material, dark_),
            "windows": windows(material)["opacity"],
        },
    }


def glass(material: dict, shape: dict, tr: dict | None = None) -> dict:
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
        "terminalOpacity": terminal_opacity(m, tr),
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
