"""What a selection is known by beyond its resolved facets: identity, the
v1 link and its apps/ dir (docs/THEME-ARCHITECTURE.md §5.5).

A migrated group (cozytile's five packs, qylock osu / osumania) keeps each
member pack's author, version, source, upstream and v1 link on its variant,
and the colors facet of a variant names its palette's apps/ dir (`apps` in
the envelope, e.g. a variant's spicetify.ini), so every variant renders what
its old pack did.
"""

from __future__ import annotations

from pathlib import Path

from ..facets.resolve import Resolved
from ..pack import Pack, is_pack

IDENTITY = ("author", "version", "license", "source", "upstream", "v1")


def identity(res: Resolved) -> dict:
    """The theme's identity keys with the variant chain's own on top."""
    doc = res.theme.doc
    out = {k: doc[k] for k in IDENTITY if k in doc}
    try:
        chain = res.theme.chain(res.variant)
    except Exception:  # noqa: BLE001 — a broken chain resolves as the theme alone
        chain = []
    for v in chain:
        out.update({k: v[k] for k in IDENTITY if k in v})
    return out


def v1_info(res: Resolved) -> dict:
    """The selection's v1 link ({path, greeter?, vibes?}), paths made absolute
    (migrated documents store them relative to the theme's pack)."""
    v1 = identity(res).get("v1")
    if not isinstance(v1, dict):
        return {}
    root = res.theme.root
    out = dict(v1)
    for k in ("path", "greeter"):
        if isinstance(out.get(k), str) and root is not None and not Path(out[k]).is_absolute():
            out[k] = str((root / out[k]).resolve())
    return out


def v1_pack(res: Resolved) -> Pack | None:
    """The v1 pack a selection was adapted or migrated from (validation,
    curated vibes), while its theme.json is still there."""
    v1 = v1_info(res)
    if not v1.get("path") or not is_pack(Path(v1["path"])):
        return None
    return Pack(Path(v1["path"]))


def apps_dir(res: Resolved) -> Path | None:
    """Hand-written consumer files: the colors facet's own `apps` dir
    (relative to its pack), else the theme pack's apps/."""
    origin = res.origins.get("colors")
    rel = origin.doc.get("apps") if origin is not None else None
    if isinstance(rel, str) and rel and origin.root is not None:
        return (Path(origin.root) / rel).resolve()
    return res.theme.root / "apps" if res.theme.root is not None else None
