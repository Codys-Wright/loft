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

from . import color
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
            "window_radius": c.num(norm["radii"]["window"]),
            "focus_active": c.with_alpha(p["accent"], 0.8),
            "focus_inactive": "#00000000",
            "launcher_glass": c.rgba(g["tint"], min(g["opacity"] * 1.6, 0.92)),
            "launcher_selection": c.rgba(p["text"], 0.12),
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
    f = norm["fonts"]
    # Only packs that declare fonts take over the terminal font.
    v["kitty_fonts"] = f"font_family {f['mono']}\nfont_size {c.num(f['size'])}\n" if fonts_set else ""
    v["ghostty_fonts"] = f"font-family = {f['mono']}\nfont-size = {c.num(f['size'])}\n" if fonts_set else ""
    return v


def template_dir_default() -> Path:
    return Path(__file__).resolve().parents[2] / "templates" / "render"


def renderer_salt(template_dir: Path) -> str:
    """Changes whenever templates or renderer code change (render cache key)."""
    h = hashlib.sha256()
    here = Path(__file__).resolve().parent
    for p in sorted(template_dir.iterdir()) + [here / "render.py", here / "pack.py", here / "color.py"]:
        h.update(p.name.encode() + b"\0" + p.read_bytes())
    return h.hexdigest()


def render(pack: Pack, outdir: Path, template_dir: Path) -> list[str]:
    """Write every consumer file for `pack` into outdir; return their names."""
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    norm, assets = normalize(pack)
    vars_ = variables(norm, fonts_set="fonts" in pack.theme)
    written = []

    def write(name: str, text: str) -> None:
        (outdir / name).write_text(text, encoding="utf-8")
        written.append(name)

    write("theme.json", json.dumps(norm, indent=2) + "\n")
    write("manifest.json", json.dumps(normalized_manifest(pack), indent=2) + "\n")
    for tpl in sorted(Path(template_dir).iterdir()):
        if tpl.is_file():
            write(tpl.name, Template(tpl.read_text(encoding="utf-8")).substitute(vars_))

    for src, dest in assets:
        shutil.copyfile(src, outdir / dest)
        written.append(dest)

    apps = pack.path / "apps"
    if apps.is_dir():
        for p in sorted(apps.rglob("*")):
            rel = p.relative_to(apps)
            # theme.json is the shell's contract and is always generated.
            if p.is_file() and str(rel) not in ("theme.json", "manifest.json"):
                (outdir / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, outdir / rel)
                if str(rel) not in written:
                    written.append(str(rel))
    return written
