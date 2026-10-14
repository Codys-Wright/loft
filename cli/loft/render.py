"""Render a theme pack into per-consumer config fragments.

Templates (templates/render/*) are plain files with `${var}` placeholders
(Python string.Template; `$$` is a literal `$`). All color math happens
here, in one flat variable table, so templates stay declarative and every
consumer derives from the same normalized theme. A pack's `apps/<file>`
replaces the generated file of the same name.

The Nix build runs this same code for the built-in packs, so a theme looks
identical whether it came from the store or was installed at runtime.
"""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path
from string import Template

from . import color, palette
from .pack import Pack, normalize, normalized_manifest

c = color


def variables(norm: dict, fonts_set: bool) -> dict[str, str]:
    p = norm["palette"]
    g = norm["glass"]
    dark = norm["polarity"] != "light"
    ansi = norm["ansi"]
    v: dict[str, str] = {
        "name": norm["name"],
        "polarity": norm["polarity"],
        "color_scheme": "prefer-dark" if dark else "prefer-light",
    }
    v.update({role: p[role] for role in ("bg", "surface", "overlay", "text", "subtext", "accent", "accent2", "urgent", "ok", "warn")})
    v.update({f"color{i}": col for i, col in enumerate(ansi)})

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
            "glass_blur": "true" if g["blur"] else "false",
            "glass_xray": "true" if g["xray"] else "false",
            "glass_tint": g["tint"],
            "glass_opacity": c.num(g["opacity"]),
            "glass_border": g["border"],
            "glass_border_opacity": c.num(g["borderOpacity"]),
            "glass_fill": c.rgba(g["tint"], g["opacity"]),
            "glass_stroke": c.rgba(g["border"], g["borderOpacity"]),
            "glass_radius": c.num(g["radius"]),
            "glass_noise": c.num(g["noise"]),
            "glass_saturation": c.num(g["saturation"]),
            "terminal_opacity": c.num(g["terminalOpacity"]),
            "shadow": g["shadow"],
            # Inactive windows: the same shadow, much fainter (Golden Gate
            # makes the focused window stand out).
            "shadow_inactive": c.with_alpha(g["shadow"], c.parse(g["shadow"])[3] * 0.4),
            "window_radius": c.num(norm["shape"]["windowRadius"]),
            "panel_radius": c.num(norm["shape"]["panelRadius"]),
            "control_radius": c.num(norm["shape"]["controlRadius"]),
            # Traffic lights (close / minimize / zoom), Aqua colors: fixed
            # across themes so they read the same everywhere.
            "traffic_close": "#ff5f57",
            "traffic_minimize": "#febc2e",
            "traffic_zoom": "#28c840",
            "traffic_inactive": c.rgba(p["text"], 0.22),
            "traffic_glyph": "rgba(0, 0, 0, 0.55)",
            "specular": c.rgba("#ffffff", min(1.0, g["specular"] * (0.35 if dark else 0.7))),
            "edge_dark": c.rgba("#000000", g["edgeDarken"] * 0.5),
            "focus_active": c.with_alpha(p["accent"], 0.8),
            "focus_inactive": "#00000000",
            "launcher_glass": c.rgba(g["tint"], min(g["opacity"] * 1.6, 0.92)),
            "launcher_selection": c.rgba(p["text"], 0.12),
            # Glass sidebars in GTK apps (Nautilus): the theme's glass tint over
            # the blur niri draws behind the window; opaque without blur. Dense
            # enough that sidebar text stays readable over any wallpaper (a
            # light theme over a dark wallpaper needs the most).
            "gtk_sidebar_glass": (
                c.rgba(
                    c.mix(g["tint"], p["surface"], 0.5),
                    min(max(g["opacity"] * 1.4, 0.62 if dark else 0.72), 0.88),
                )
                if g["blur"]
                else p["surface"]
            ),
            "gtk_sidebar_hover": c.rgba(p["text"], 0.07),
            "gtk_sidebar_selected": c.rgba(p["text"], 0.13 if dark else 0.1),
            "gtk_hairline": c.rgba(p["text"], 0.1 if dark else 0.14),
            # Selected files / items: the accent as a tint, so the item's own
            # text color stays readable on every palette.
            "gtk_selection": c.rgba(p["accent"], 0.32 if dark else 0.24),
            "gtk_selection_hover": c.rgba(p["accent"], 0.4 if dark else 0.3),
            # Raised surfaces (popovers, menus, dialogs, cards): a step toward
            # the text side in dark themes, toward white in light ones.
            "gtk_raised": p["surface"] if dark else c.mix(p["bg"], "#ffffff", 0.6),
            "niri_blur": "on" if g["blur"] else "off",
            "kitty_blur": "1" if g["blur"] else "0",
            "wallpaper_image": norm["wallpaper"]["image"],
        }
    )

    # Conditional snippets: computed here so templates need no logic.
    v["niri_xray_rules"] = (
        ""
        if g["xray"]
        else (
            "\n// This theme turns xray off: blur what is really behind each surface.\n"
            "window-rule {\n    background-effect {\n        xray false\n    }\n}\n"
            "layer-rule {\n    background-effect {\n        xray false\n    }\n}\n"
        )
    )
    v.update({f"spice_{k.replace('-', '_')}": val for k, val in spicetify_scheme(p, dark).items()})

    f = norm["fonts"]
    # Only packs that declare fonts take over the terminal font.
    v["kitty_fonts"] = f"font_family {f['mono']}\nfont_size {c.num(f['size'])}\n" if fonts_set else ""
    v["ghostty_fonts"] = f"font-family = {f['mono']}\nfont-size = {c.num(f['size'])}\n" if fonts_set else ""
    return v


def spicetify_scheme(p: dict[str, str], dark: bool) -> dict[str, str]:
    """The palette as a scheme for spicetify-themes' `text` theme (its
    color.ini keys plus Spicetify's base colors), hex without `#`.

    text paints nearly everything from a handful of keys: `main` is every
    background (sidebar, player and cards derive from it in its user.css),
    `text`/`subtext` the foregrounds, `header`/`banner` titles and the
    ASCII banner, `accent*`/`button*` controls and the playing row,
    `border-inactive` card fills and hairlines, `highlight` hover/press.
    Foregrounds are pushed to readable contrast on `main` (light themes
    too); the accent keeps 3:1, so it stays visible as a fill and as text.
    """
    pc = palette.ensure_contrast
    bg = c.hex6(p["bg"])
    text = pc(p["text"], bg, 7.0)
    subtext = pc(p["subtext"], bg, 4.5)
    accent = pc(p["accent"], bg, 3.0)
    accent2 = pc(p["accent2"], bg, 3.0)
    surface = c.hex6(p["surface"])
    # Card fills and borders: a visible step from main, whatever the pack's surface.
    border = surface if c.contrast(surface, bg) >= 1.12 else c.mix(bg, p["overlay"], 0.45)
    s = {
        "text": text,
        "subtext": subtext,
        "main": bg,
        "main-elevated": surface,
        "highlight": c.mix(bg, p["overlay"], 0.7),
        "highlight-elevated": c.hex6(p["overlay"]),
        "sidebar": bg,
        "player": bg,
        "card": surface,
        "shadow": "000000" if dark else c.mix(p["overlay"], "#000000", 0.35),
        "selected-row": subtext,
        "button": accent,
        "button-active": accent,
        "button-disabled": pc(c.mix(p["overlay"], p["subtext"], 0.3), bg, 1.6),
        "tab-active": surface,
        "notification": accent2,
        "notification-error": pc(p["urgent"], bg, 3.0),
        "misc": c.hex6(p["overlay"]),
        "accent": accent,
        "accent-active": accent,
        "accent-inactive": c.mix(bg, surface, 0.5),
        "banner": accent,
        "border-active": accent,
        "border-inactive": border,
        "header": pc(c.mix(p["subtext"], bg, 0.3), bg, 3.0),
    }
    return {k: v.lstrip("#").lower() for k, v in s.items()}


def template_dir_default() -> Path:
    return Path(__file__).resolve().parents[2] / "templates" / "render"


def renderer_salt(template_dir: Path) -> str:
    """Changes whenever templates or renderer code change (render cache key)."""
    h = hashlib.sha256()
    here = Path(__file__).resolve().parent
    for p in sorted(template_dir.iterdir()) + [here / "render.py", here / "pack.py", here / "color.py", here / "palette.py"]:
        h.update(p.name.encode() + b"\0" + p.read_bytes())
    return h.hexdigest()


def render(pack: Pack, outdir: Path, template_dir: Path, curated: dict | None = None) -> list[str]:
    """Write every consumer file for `pack` into outdir; return their names.

    `curated`: the pack's vibe links already resolved against the installed
    packs (vibes.resolve), listed in the manifest after the pack's own."""
    norm, assets = normalize(pack)
    return write_bundle(
        Path(outdir), norm, assets, normalized_manifest(pack, curated), "fonts" in pack.theme, template_dir, pack.path / "apps"
    )


def write_bundle(
    outdir: Path, norm: dict, assets: list[tuple[Path, str]], manifest: dict, fonts_set: bool, template_dir: Path, apps: Path | None
) -> list[str]:
    """The rendered bundle: theme.json, manifest.json, every template, the
    copied assets and the pack's apps/ overrides (shared by v1 packs and
    resolved facets, facets/compat.py)."""
    outdir.mkdir(parents=True, exist_ok=True)
    vars_ = variables(norm, fonts_set=fonts_set)
    written = []

    def write(name: str, text: str) -> None:
        (outdir / name).write_text(text, encoding="utf-8")
        written.append(name)

    write("theme.json", json.dumps(norm, indent=2) + "\n")
    write("manifest.json", json.dumps(manifest, indent=2) + "\n")
    for tpl in sorted(Path(template_dir).iterdir()):
        if tpl.is_file():
            write(tpl.name, Template(tpl.read_text(encoding="utf-8")).substitute(vars_))

    for src, dest in assets:
        shutil.copyfile(src, outdir / dest)
        written.append(dest)

    if apps is not None and apps.is_dir():
        for p in sorted(apps.rglob("*")):
            rel = p.relative_to(apps)
            # theme.json is the shell's contract and is always generated.
            if p.is_file() and str(rel) not in ("theme.json", "manifest.json"):
                (outdir / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, outdir / rel)
                if str(rel) not in written:
                    written.append(str(rel))
    return written
