"""`loft theme browse|search|info` over the themes index, `install NAME`
from it, and `loft theme index build|where` (index.py, indexgen.py).

An entry is installed through the paths that already exist: an importer
entry as `IMPORTER:ID[@REV]`, a git entry by fetching its repo at `rev` and
installing the pack at `path` (cli.cmd_install's pack-root install).
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

from . import index as I
from . import indexgen


def _fail(msg: str):
    from .cli import Fail

    return Fail(msg)


def load(ctx, refresh: bool = False) -> dict:
    """The index (refetched with refresh); an error when there is none."""
    if I.disabled():
        raise _fail("the themes index is off (LOFT_THEME_INDEX=none)")
    if refresh:
        ctx._index = I.load(ctx.state_dir, refresh=True)
    idx = ctx.index()
    if not idx:
        raise _fail(f"no themes index (couldn't read {I.source()})")
    return idx


def installed_names(ctx) -> set[str]:
    """Pack dir names and ids, theme ids and theme@variant refs installed."""
    from . import themecmds
    from .facets import FacetError
    from .pack import is_any_pack, pack_id

    out: set[str] = set()
    for d in ctx.user_dirs + [p for p in ctx.theme_path if p not in ctx.user_dirs]:
        for sub in sorted(d.iterdir()) if d.is_dir() else []:
            if sub.is_dir() and is_any_pack(sub):
                out.add(sub.name)
                try:
                    out.add(pack_id(sub))
                except Exception:  # noqa: BLE001 — a broken pack is still a name
                    pass
    try:
        for t in themecmds.catalog(ctx).themes():
            out.add(t.id)
            if t.base_id:
                out.add(f"{t.id}@{t.base_id}")
            out.update(f"{t.id}@{v}" for v in t.variant_ids())
    except FacetError:
        pass
    return out


def is_installed(e: dict, names: set[str]) -> bool:
    return e["name"] in names or (e.get("theme") or "") in names


def _row(e: dict, names: set[str]) -> dict:
    return dict(e, installed=is_installed(e, names), install=I.install_ref(e)[1], preview=I.preview(e))


def cmd_browse(ctx, args) -> None:
    idx = load(ctx, getattr(args, "refresh", False))
    rows = I.search(idx, " ".join(getattr(args, "query", None) or []), getattr(args, "collection", None))
    names = installed_names(ctx)
    if getattr(args, "installed", False):
        rows = [e for e in rows if is_installed(e, names)]
    if getattr(args, "available", False):
        rows = [e for e in rows if not is_installed(e, names)]
    if args.json:
        print(json.dumps([_row(e, names) for e in rows]))
        return
    if not rows:
        print("(nothing in the themes index matches)" if getattr(args, "query", None) else "(the themes index is empty)")
        return
    for e in rows:
        mark = "i" if is_installed(e, names) else " "
        theme = e.get("theme") or ""
        print(f"{mark} {e['name']:30} {e['collection']:12} {theme if theme != e['name'] else '':22} {e['title']}")


def cmd_info(ctx, args) -> None:
    idx = load(ctx, getattr(args, "refresh", False))
    try:
        e = I.find(idx, args.name)
    except I.IndexLookupError as err:
        raise _fail(str(err)) from err
    names = installed_names(ctx)
    row = _row(e, names)
    row["vibes"] = I.vibe_names(idx).get(e["name"], [])
    if args.json:
        print(json.dumps(row, indent=2))
        return
    print(f"{e['name']}  ({e['title']})")
    for label, val in (
        ("description", e.get("description")),
        ("collection", e["collection"]),
        ("theme", e.get("theme")),
        ("license", e.get("license")),
        ("install", row["install"]),
        ("installed", "yes" if row["installed"] else "no"),
        ("vibes", ", ".join(row["vibes"])),
        ("tags", ", ".join(e["tags"])),
    ):
        if val:
            print(f"  {label:12} {val}")
    pv = I.preview(e)
    if pv.get("palette"):
        pal = " ".join(f"{k}={v}" for k, v in pv["palette"].items())
        print(f"  {'palette':12} {pv.get('polarity', '')} ({pv.get('paletteFrom', '?')}): {pal}")
    if pv.get("image"):
        print(f"  {'preview':12} {pv['image']}")
    if e.get("curated"):
        print(f"  {'curated':12} {', '.join(sorted(e['curated'].get('palette', {})))}" + (" + polarity" if e["curated"].get("polarity") else ""))


def lookup(ctx, name: str) -> dict | None:
    """The index entry `install NAME` means, or None when there is no index
    (the caller reports NAME as not a path / URL)."""
    if I.disabled():
        return None
    idx = ctx.index()
    if not idx:
        return None
    try:
        return I.find(idx, name)
    except I.IndexLookupError as err:
        raise _fail(str(err)) from err


def install_entry(ctx, args, e: dict) -> None:
    """Install an index entry through the importer or git install path."""
    from . import cli

    kind, ref, rev, path = I.install_ref(e)
    print(f"loft: {e['name']} from the themes index ({ref}{'@' + rev if rev else ''}{' ' + path if path else ''})")
    if kind == "importer":
        args.source = ref
        cli._import(ctx, args)
        return
    if getattr(args, "subdir", None) is None:
        args.subdir = path
    if kind == "url":
        args.source = ref
        cli.cmd_install(ctx, args)
        return
    cli.install_git(ctx, args, ref, rev)


def cmd_index_where(ctx, args) -> None:
    src = I.source()
    cache = I.cache_path(ctx.state_dir)
    out = {"source": src, "disabled": I.disabled(), "default": I.DEFAULT_URL}
    if cache and cache.is_file():
        out["cache"] = str(cache)
        out["cacheAge"] = int(time.time() - cache.stat().st_mtime)
    idx = {} if I.disabled() else ctx.index()
    out["version"] = idx.get("version")
    out["entries"] = len(I.entries(idx)) if idx else 0
    if args.json:
        print(json.dumps(out))
        return
    print(f"source   {src}" + ("  (off)" if out["disabled"] else ""))
    if "cache" in out:
        print(f"cache    {out['cache']} ({out['cacheAge'] // 60} min old)")
    print(f"entries  {out['entries']}" + (f" (format {out['version']})" if out["version"] else ""))


def cmd_index_build(ctx, args) -> None:
    repo = Path(args.repo)
    if not repo.is_dir():
        raise _fail(f"{repo}: not a directory (a loft-themes checkout)")
    try:
        data = indexgen.build(
            repo,
            builtin=ctx.data_dir / "packs",
            rev=args.rev,
            importers=not args.no_importers,
            extract=True if args.extract == "all" else set(args.extract.split(",")) if args.extract else False,
            log=lambda m: print(f"loft: {m}", file=sys.stderr),
        )
    except indexgen.BuildError as e:
        raise _fail(str(e)) from e
    text = indexgen.dumps(data)
    out = Path(args.output) if args.output else repo / "index.json"
    if args.output == "-":
        sys.stdout.write(text)
        return
    if args.check:
        old = out.read_text() if out.is_file() else ""
        if old != text:
            raise _fail(f"{out} is out of date (regenerate it with `loft theme index build`)")
        print(f"loft: {out} is up to date ({len(data['entries'])} entries)")
        return
    out.write_text(text)
    print(f"loft: wrote {out} ({len(data['entries'])} entries)")


def add_parsers(sub) -> None:
    s = sub.add_parser(
        "browse",
        help="list the themes index: Loft's own packs and the importers' themes (i = installed)",
        description="Entries of the themes index ($LOFT_THEME_INDEX, default loft-themes on GitHub; cached a day). "
        "`loft theme install NAME` installs one.",
    )
    s.add_argument("query", nargs="*", help="only entries matching every word (name, title, tags, vibe groups, …)")
    s.add_argument("--collection", help="only this collection (loft-themes, cozytile, qylock, …)")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--installed", action="store_true", help="only installed ones")
    g.add_argument("--available", action="store_true", help="only ones not installed")
    s.add_argument("--refresh", action="store_true", help="refetch the index now")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_browse)

    s = sub.add_parser("search", help="search the themes index (= browse QUERY…)")
    s.add_argument("query", nargs="+")
    s.add_argument("--collection")
    s.add_argument("--refresh", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_browse)

    s = sub.add_parser("info", help="one themes index entry: source, palette, preview, vibes")
    s.add_argument("name", help="entry name, the theme it becomes (cozytile@sakura) or IMPORTER:ID")
    s.add_argument("--refresh", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_info)

    p = sub.add_parser("index", help="the themes index: where it's read from; build one (loft-themes)")
    isub = p.add_subparsers(dest="index_cmd", required=True)
    s = isub.add_parser("where", help="the index source, cache and size")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_index_where)
    s = isub.add_parser(
        "build",
        help="generate index.json for a loft-themes checkout (packs/, catalog.json, importer catalogs)",
        description=(indexgen.__doc__ or "").split("\n\n")[0],
    )
    s.add_argument("repo", nargs="?", default=".", help="the loft-themes checkout (default: .)")
    s.add_argument("-o", "--output", help="output file (default: REPO/index.json; - = stdout)")
    s.add_argument("--rev", help="branch or tag the repo's packs install from (default: catalog.json rev, else main)")
    s.add_argument("--no-importers", action="store_true", help="don't fetch upstream catalogs; keep the previous importer entries")
    s.add_argument(
        "--extract",
        nargs="?",
        const="all",
        metavar="IMPORTER,…",
        help="run the imports (all importers, or these) to record each theme's derived palette (downloads every theme)",
    )
    s.add_argument("--check", action="store_true", help="fail when the output file differs (CI)")
    s.set_defaults(fn=cmd_index_build)
