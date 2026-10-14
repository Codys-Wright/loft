"""What a render unit is (docs/THEME-ARCHITECTURE.md §6.1).

A unit turns a few resolved facets into one consumer's files. It declares:

  reads    the facet kinds its output depends on (the cache key covers
           exactly what `inputs` takes from them)
  inputs   resolved theme → a JSON document: everything `render` may use.
           `render` sees nothing else, so the digest of `inputs` (plus the
           unit's code and template, plus its assets) is a complete cache key
  render   inputs → {file name: text | (asset source path)}
  hook     the reload hook to run when its output changed (hooks.py), or None

Units never read the resolved theme in `render`; the split is what makes the
per-unit cache (render/compose.py) sound.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from string import Template

from ..facets.model import Catalog
from ..facets.resolve import Resolved

HERE = Path(__file__).resolve().parent
# Code every unit depends on: a change here re-renders every unit.
SHARED = (HERE / "unit.py", HERE / "look.py", HERE.parent / "color.py", HERE.parent / "palette.py", HERE.parent / "pack.py")


@dataclass
class Source:
    """What units are rendered from: the resolved theme and what the
    manifest needs besides it (the catalog, curated vibe links, apps/)."""

    res: Resolved
    catalog: Catalog
    template_dir: Path
    curated: dict = field(default_factory=dict)
    apps: Path | None = None  # the theme's pack apps/ dir: hand-written files that replace generated ones

    def facet(self, kind: str) -> dict:
        return self.res.facets[kind]


@dataclass(frozen=True)
class Unit:
    name: str
    reads: tuple[str, ...]
    files: tuple[str, ...]  # what it writes (assets aside); apps/<file> of the same name replaces it
    inputs: Callable[[Source], dict]
    render: Callable[[dict, Path], dict]  # (inputs, template_dir) → {name: str | Path}
    hook: str | None = None
    module: str = ""  # source file (its bytes are part of the salt)
    templates: tuple[str, ...] = ()
    assets: Callable[[dict], list] = lambda inputs: []  # [(source Path, dest name)] copied as they are

    def salt(self, template_dir: Path) -> str:
        """renderer_salt(unit): this unit's code and templates plus the shared
        helpers — editing templates/render/gtk.css re-renders only `gtk`."""
        h = hashlib.sha256(self.name.encode())
        for p in (Path(self.module), *SHARED, *(Path(template_dir) / t for t in self.templates)):
            h.update(p.name.encode() + b"\0")
            try:
                h.update(p.read_bytes())
            except OSError:
                h.update(b"(missing)")
        return h.hexdigest()


def canonical(doc) -> bytes:
    return json.dumps(doc, sort_keys=True, separators=(",", ":"), default=str).encode()


def template(template_dir: Path, name: str, vars_: dict) -> str:
    return Template((Path(template_dir) / name).read_text(encoding="utf-8")).substitute(vars_)
