"""Render units: resolved facets → per-consumer files (docs/THEME-ARCHITECTURE.md §6).

One module per unit; each declares the facet kinds it reads and renders from
those resolved facets alone (render/unit.py). Templates (templates/render/*)
are plain files with `${var}` placeholders (Python string.Template; `$$` is a
literal `$`); the color math lives in the unit modules and render/look.py, so
templates stay declarative. A pack's `apps/<file>` replaces the unit file of
the same name.

    unit        files                  reads                                    hook
    shell       theme.json (+ wallpaper.*)  colors material shape typography motion icons wallpapers   shell
    manifest    manifest.json          lock wallpapers colors                    —
    wallpapers  wallpapers.json        wallpapers colors                         wallpapers
    niri        niri.kdl               colors material shape motion              niri
    gtk         gtk.css                colors material shape                     gtk
    qt          kde.colors kvantum.kvconfig kvantum.svg  colors material shape     qt
    kitty       kitty.conf             colors material typography                kitty
    ghostty     ghostty.conf           colors material typography                ghostty
    walker      walker.css             colors material launcher                  —
    noctalia    noctalia.json          colors                                    —
    spotify     spicetify.ini          colors                                    spotify

`loft theme render` writes them flat into a directory; `loft theme apply` and
`preview` go through the composition cache (render/compose.py).

The Nix build runs this same code for the built-in packs, so a theme looks
identical whether it came from the store or was rendered at runtime.
"""

from __future__ import annotations

from pathlib import Path

from ..facets.model import Catalog
from ..facets.resolve import Resolved
from . import compose, gtk, manifest, niri, noctalia, qt, shell, spotify, terminal, walker, wallpapers
from .spotify import spicetify_scheme  # noqa: F401  (tests, spotify tooling)
from .unit import Source, Unit

UNITS: list[Unit] = [
    shell.UNIT,
    manifest.UNIT,
    wallpapers.UNIT,
    niri.UNIT,
    gtk.UNIT,
    qt.UNIT,
    terminal.KITTY,
    terminal.GHOSTTY,
    walker.UNIT,
    noctalia.UNIT,
    spotify.UNIT,
]
BY_NAME = {u.name: u for u in UNITS} | {compose.APPS.name: compose.APPS}


def template_dir_default() -> Path:
    return Path(__file__).resolve().parents[3] / "templates" / "render"


def source(res: Resolved, catalog: Catalog, template_dir: Path, curated: dict | None = None) -> Source:
    from .identity import apps_dir

    return Source(res, catalog, Path(template_dir), curated or {}, apps_dir(res))


def render_to(res: Resolved, catalog: Catalog, outdir: Path, template_dir: Path, curated: dict | None = None) -> list[str]:
    """Every unit's files into outdir (`loft theme render`)."""
    return compose.render_dir(source(res, catalog, template_dir, curated), UNITS, Path(outdir))


def resolved_doc(res: Resolved) -> dict:
    """resolved.json (without `units`, which compose adds): what the Theme
    pages show — identity, where every kind came from, what is customized."""
    t = res.theme
    return {
        "theme": t.id,
        "variant": res.variant,  # None: the base
        "base": t.base_id,
        "ref": res.ref,
        "name": res.name,
        "label": t.label_of(res.variant),
        "polarity": res.polarity,
        "sources": res.sources,
        "customized": res.customized,
        "pinned": res.pinned,
        "accessibility": res.accessibility,
    }


def hooks_for(units: list[str]) -> list[str]:
    """Reload hooks of these units, in unit order, once each."""
    out: list[str] = []
    for u in UNITS:
        if u.name in units and u.hook and u.hook not in out:
            out.append(u.hook)
    return out
