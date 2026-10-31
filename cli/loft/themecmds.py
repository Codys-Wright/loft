"""`loft theme …` and `loft <kind> …` on the facet model (docs/THEME-ARCHITECTURE.md §8).

Themes resolve through cli/loft/facets: a v2 theme (`loft`, `loft@light`),
an alias (`tokyonight` → loft@dark, `latte` → loft@light, `default`) or a v1
pack, which loads through the v1 adapter. Applying renders the resolved
facets with the render units (cli/loft/render/) through the composition
cache and runs only the reload hooks of units whose output changed, so every
old name keeps working. `LOFT_THEME_ENGINE=v1` restores the pack-only
selection (no catalog, no appearance.json).

Every write goes to <state>/appearance.json and re-applies the active theme
(`--no-apply` skips that).
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from . import hooks, render
from .facets import appearance as A
from .facets import resolve as R
from .facets.model import KINDS, Catalog, FacetError, Theme, get_path, path_patch, read_json
from .pack import Pack, is_pack
from .render import compose

LEGACY = "LOFT_THEME_ENGINE"


def legacy_engine() -> bool:
    return os.environ.get(LEGACY, "").strip().lower() == "v1"


# ── context helpers ─────────────────────────────────────────────────────────


def builtin_packs(ctx) -> Path:
    return ctx.data_dir / "packs"


def catalog(ctx, extra: list[Path] = ()) -> Catalog:
    """The catalog over the theme path, the library (user pack) and the
    built-in packs. The v1 built-ins in themes/ are left out once packs/loft
    has their successor (the `loft` theme and its aliases)."""
    key = tuple(str(p) for p in extra)
    cache = ctx.__dict__.setdefault("_catalogs", {})
    if key not in cache:
        has_loft = (builtin_packs(ctx) / "loft" / "pack.json").is_file()
        dirs = [d for d in ctx.theme_path if not (has_loft and _same(d, ctx.builtin_themes))]
        cache[key] = Catalog(dirs, builtin=builtin_packs(ctx), user=ctx.library, extra_packs=list(extra))
    return cache[key]


def _same(a: Path, b: Path) -> bool:
    try:
        return a.resolve() == b.resolve()
    except OSError:
        return a == b


def library_root(ctx) -> Path:
    if ctx.library is None:
        raise FacetError("the library is turned off (LOFT_LIBRARY=none): nowhere to save")
    return ctx.library


def state_of(ctx) -> dict:
    return A.load(ctx.state_dir)


def select(ctx, ref: str) -> tuple[Catalog, Theme, str | None]:
    """A theme by name (theme[@variant] or an alias), or by pack path."""
    p = Path(ref).expanduser()
    if ("/" in ref or ref.startswith(".")) and (is_pack(p) or (p / "pack.json").is_file()):
        cat = catalog(ctx, [p.resolve()])
        if (p / "pack.json").is_file():
            meta = read_json(p / "pack.json")
            pid = meta.get("id") or p.name
            ids = [t.id for t in cat.themes() if t.pack == pid]
            if not ids:
                raise FacetError(f"{p}: the pack has no themes")
            tid = pid if pid in ids else ids[0]
        else:
            tid = Pack(p).name
        theme, variant = cat.theme(tid)
        return cat, theme, variant
    cat = catalog(ctx)
    theme, variant = cat.theme(ref)
    return cat, theme, variant


def active(ctx, state: dict | None = None) -> tuple[Catalog, Theme, str | None]:
    """The active selection: appearance.json, else what `current` shows
    (by its legacy name), else the default theme."""
    state = state if state is not None else state_of(ctx)
    cat = catalog(ctx)
    if state.get("theme"):
        try:
            theme, _ = cat.theme(state["theme"])
            variant = state.get("variant")
            theme.variant(variant)
            return cat, theme, (None if variant == theme.base_id else variant)
        except FacetError:
            pass
    name = ctx.current_name()
    for ref in ([name] if name else []) + ["default"]:
        try:
            theme, variant = cat.theme(ref)
            return cat, theme, variant
        except FacetError:
            continue
    raise FacetError("no active theme (loft theme apply NAME)")


def resolved(ctx, cat: Catalog, theme: Theme, variant: str | None, state: dict | None) -> R.Resolved:
    return R.resolve(cat, theme, variant, state)


def v1_pack(res: R.Resolved) -> Pack | None:
    """The v1 pack a selection was adapted or migrated from (for validation
    and curated vibes), if any (render/identity.py)."""
    from .render.identity import v1_pack as find

    return find(res)


def _validate_v1(ctx, res: R.Resolved) -> None:
    """A v1 pack that doesn't validate still fails apply/render, as before."""
    pack = v1_pack(res)
    if pack is not None:
        ctx.validate(pack)


def _curated(ctx, res: R.Resolved) -> dict:
    pack = v1_pack(res)
    return ctx.curated(pack) if pack is not None else {}


# ── apply / preview / render ────────────────────────────────────────────────


def composition(ctx, cat: Catalog, res: R.Resolved) -> compose.Composition:
    """Render what the cache lacks and build the composition (§6.2)."""
    _validate_v1(ctx, res)
    src = render.source(res, cat, ctx.template_dir, _curated(ctx, res))
    return compose.compose(src, render.UNITS, ctx.state_dir, render.resolved_doc(res))


def _hook_names(ctx) -> list[str]:
    try:
        return hooks.selected(os.environ.get("LOFT_HOOKS") if "LOFT_HOOKS" in os.environ else None, ctx.dev)
    except ValueError as e:
        raise FacetError(str(e)) from e


def apply_resolved(ctx, cat: Catalog, res: R.Resolved, quiet: bool = False, reload_all: bool = False, verbose: bool = False) -> Path:
    """Compose (cached per unit), point `current` at it, run the reload hooks
    of the units whose digest changed (all of them with `reload_all`)."""
    from .cli import _swap_symlink

    t0 = time.monotonic()
    comp = composition(ctx, cat, res)
    old = compose.units_of(ctx.current.resolve()) if ctx.current.is_symlink() else None
    changed = compose.changed(None if reload_all else old, comp.units)
    _swap_symlink(ctx.current, comp.path)
    compose.gc(ctx.state_dir, compose.pinned_targets(ctx.state_dir))
    ctx.theme = json.loads((comp.path / "theme.json").read_text())
    selected = _hook_names(ctx)
    wanted = render.hooks_for(changed)
    run = [h for h in selected if h in wanted]
    hooks.run(run, ctx)
    # The login screen follows the lock screen (machine opt-in, see greeter.py).
    if "greeter" in selected and not getattr(ctx, "greeter_explicit", False):
        from . import greeter

        greeter.follow(ctx, cat, res)
    for e in res.errors:
        print(f"loft: skipped {e}", file=sys.stderr)
    if verbose:
        ms = (time.monotonic() - t0) * 1000
        print(
            f"loft: rendered {', '.join(comp.rendered) or 'nothing'}; changed {', '.join(changed) or 'nothing'}; "
            f"hooks {', '.join(run) or 'none'} ({ms:.0f} ms)",
            file=sys.stderr,
        )
    if not quiet:
        print(f"loft: applied {res.name}")
    return comp.path


def cmd_apply(ctx, args) -> None:
    from . import greeter

    want_greeter = getattr(args, "greeter", None)
    if want_greeter is not None:
        ctx.greeter_explicit = True  # synced below, in the foreground
    if not args.theme and not args.mode and want_greeter is not None:
        greeter.cmd_sync(ctx, args)  # `loft theme apply --greeter [REF]`: the login screen only
        return
    state = state_of(ctx)
    if args.theme:
        cat, theme, variant = select(ctx, args.theme)
    else:
        if not args.mode:
            raise FacetError("apply what? (loft theme apply THEME[@VARIANT] or --mode light|dark|auto)")
        cat, theme, variant = active(ctx, state)
    if args.mode:
        variant = A.variant_for_mode(theme, args.mode)
        state["mode"] = args.mode
    res = resolved(ctx, cat, theme, variant, state)
    apply_resolved(ctx, cat, res, reload_all=getattr(args, "reload", False), verbose=getattr(args, "verbose", False))
    state["theme"], state["variant"] = theme.id, variant
    A.save(ctx.state_dir, state)
    if want_greeter is not None:
        greeter.cmd_sync(ctx, args)


def reapply(ctx, state: dict, args=None) -> None:
    """After a write: re-apply the active theme with the new user layer."""
    if args is not None and getattr(args, "no_apply", False):
        return
    ctx.__dict__.pop("_catalogs", None)  # saved facets / themes / variants
    cat, theme, variant = active(ctx, state)
    apply_resolved(ctx, cat, resolved(ctx, cat, theme, variant, state))


def cmd_preview(ctx, args) -> None:
    """Render a selection into a composition and point the shell (only) at it
    (§6.3): `current`, niri, terminals and GTK stay as they are. `--stop`
    returns the shell to `current`."""
    link = ctx.state_dir / "preview"
    if args.stop:
        if link.is_symlink():
            link.unlink()
        if not args.no_shell:
            hooks.preview(ctx, None)
        print("loft: preview stopped")
        return
    if not args.theme:
        raise FacetError("preview what? (loft theme preview THEME[@VARIANT] or --stop)")
    from .cli import _swap_symlink

    state = state_of(ctx)
    cat, theme, variant = select(ctx, args.theme)
    if args.mode:
        variant = A.variant_for_mode(theme, args.mode)
    res = resolved(ctx, cat, theme, variant, None if args.no_user else state)
    comp = composition(ctx, cat, res)
    _swap_symlink(link, comp.path)
    compose.gc(ctx.state_dir, compose.pinned_targets(ctx.state_dir))
    if not args.no_shell:
        hooks.preview(ctx, comp.path)
    for e in res.errors:
        print(f"loft: skipped {e}", file=sys.stderr)
    if args.json:
        print(json.dumps({"ref": res.ref, "name": res.name, "dir": str(comp.path), "rendered": comp.rendered, "units": comp.units}))
    else:
        print(comp.path)


def cmd_render(ctx, args) -> None:
    cat, theme, variant = select(ctx, args.pack)
    res = resolved(ctx, cat, theme, variant, None if args.no_user else state_of(ctx))
    _validate_v1(ctx, res)
    render.render_to(res, cat, Path(args.outdir), ctx.template_dir, _curated(ctx, res))
    for e in res.errors:
        print(f"loft: skipped {e}", file=sys.stderr)


def legacy_select(ctx, pack: Pack) -> tuple[Catalog, Theme, str | None]:
    """LOFT_THEME_ENGINE=v1: the pack alone, through the v1 adapter."""
    cat = Catalog([], builtin=None, user=None, extra_packs=[pack.path.resolve()])
    theme, variant = cat.theme(pack.name)
    return cat, theme, variant


# ── theme list / current / variants / state / diff ──────────────────────────


def theme_json(cat: Catalog, t: Theme, active_ref: tuple | None = None) -> dict:
    variants = []
    if t.base_id:
        variants.append({"id": t.base_id, "name": (t.doc.get("base") or {}).get("name") or t.base_id, "base": True})
    for v in t.variants():
        variants.append({"id": v["id"], "name": v.get("name") or v["id"], **({"user": True} if v.get("user") else {}), **({"extends": v["extends"]} if v.get("extends") else {})})
    out = {
        "id": t.id,
        "name": t.name,
        "pack": t.pack,
        "collection": t.doc.get("collection") or ("user" if not t.readonly else "installed"),
        "description": t.doc.get("description", ""),
        "readonly": t.readonly,
        "variants": variants,
        "appearance": t.doc.get("appearance") or {},
        "aliases": t.doc.get("aliases") or [],
    }
    try:
        colors = R.resolve(cat, t, None).facets["colors"]
        out["polarity"], out["palette"] = colors["polarity"], colors["palette"]
    except FacetError:
        pass
    if active_ref and active_ref[0] == t.id:
        out["active"] = active_ref[1] or t.base_id or True
    return out


def cmd_theme_list(ctx, args) -> None:
    cat = catalog(ctx)
    try:
        _, at, av = active(ctx)
        act = (at.id, av)
    except FacetError:
        act = None
    themes = [t for t in cat.themes() if not args.collection or (t.doc.get("collection") or "") == args.collection]
    themes.sort(key=lambda t: (t.doc.get("collection") != "builtin", t.doc.get("collection") or "", t.id))
    if args.json:
        print(json.dumps([theme_json(cat, t, act) for t in themes]))
        return
    for t in themes:
        vs = ([t.base_id] if t.base_id else []) + t.variant_ids()
        mark = "*" if act and act[0] == t.id else " "
        print(f"{mark} {t.id:28} {(t.doc.get('collection') or ''):10} {' · '.join(vs)}")


def cmd_current(ctx, args) -> None:
    if not args.json:
        f = ctx.current / "theme.json"
        if not f.is_file():
            print("(none — the shell uses its built-in default)")
            return
        print(json.loads(f.read_text()).get("name") or ctx.current.resolve().name)
        return
    state = state_of(ctx)
    cat, theme, variant = active(ctx, state)
    res = resolved(ctx, cat, theme, variant, state)
    print(json.dumps({"theme": theme.id, "variant": variant, "ref": res.ref, "name": res.name, "label": theme.label_of(variant), "customized": res.customized, "pinned": res.pinned}))


def cmd_variants(ctx, args) -> None:
    cat, theme, _ = select(ctx, args.theme) if args.theme else active(ctx)
    info = theme_json(cat, theme)
    if args.json:
        print(json.dumps(info["variants"]))
        return
    for v in info["variants"]:
        tags = [x for x in ("base" if v.get("base") else "", "yours" if v.get("user") else "", f"extends {v['extends']}" if v.get("extends") else "") if x]
        print(f"{theme.id}@{v['id']:20} {v['name']}" + (f"  ({', '.join(tags)})" if tags else ""))


def cmd_state(ctx, args) -> None:
    """Everything a UI (or a test) needs, as one JSON document."""
    state = state_of(ctx)
    if args.theme:
        cat, theme, variant = select(ctx, args.theme)
    else:
        cat, theme, variant = active(ctx, state)
    res = resolved(ctx, cat, theme, variant, state)
    out = res.to_json()
    out["mode"] = state.get("mode")
    # The appearances the theme maps to a variant (`apply --mode`): Settings
    # offers Prefer Light / Prefer Dark only when it has both.
    app = theme.doc.get("appearance")
    out["modes"] = sorted(app) if isinstance(app, dict) else []
    out["current"] = ctx.current_name()
    out["file"] = str(A.path(ctx.state_dir))
    out["catalogErrors"] = cat.errors
    print(json.dumps(out, indent=None if args.compact else 2))


def cmd_diff(ctx, args) -> None:
    """What pins, the space and customizations change, per kind."""
    state = state_of(ctx)
    cat, theme, variant = select(ctx, args.theme) if args.theme else active(ctx, state)
    plain = R.resolve(cat, theme, variant, {"accessibility": state.get("accessibility")})
    full = R.resolve(cat, theme, variant, state)
    out = {}
    for k in KINDS:
        layers = [ly for ly in full.sources[k]["layers"] if not ly["source"].startswith(("theme:", "variant:"))]
        ch = R.changes(plain.facets[k], full.facets[k])
        if layers or ch:
            out[k] = {"layers": layers, "changes": [{"path": p, "before": a, "after": b} for p, a, b in ch]}
    if args.json:
        print(json.dumps({"ref": full.ref, "kinds": out, "errors": full.errors}))
        return
    if not out:
        print(f"{full.ref}: nothing customized or pinned")
    for k, d in out.items():
        print(f"{k}:")
        for ly in d["layers"]:
            print(f"  {ly['source']:32} {json.dumps(ly['selection'])}")
        for c in d["changes"]:
            print(f"    {c['path']}: {json.dumps(c['before'])} → {json.dumps(c['after'])}")
    for e in full.errors:
        print(f"skipped: {e}")


# ── theme writes ────────────────────────────────────────────────────────────


def cmd_reset(ctx, args) -> None:
    state = state_of(ctx)
    cat, theme, variant = active(ctx, state)
    if not args.all and not args.kinds:
        raise FacetError("reset what? (KIND… or --all)")
    bad = [k for k in args.kinds if k not in KINDS]
    if bad:
        raise FacetError(f"unknown kind(s) {', '.join(bad)} (kinds: {', '.join(KINDS)})")
    dropped = A.reset(state, theme, None if args.all else args.kinds, variant=variant)
    A.save(ctx.state_dir, state)
    print(f"loft: reset {', '.join(dropped) if dropped else 'nothing (not customized)'}")
    reapply(ctx, state, args)


def _report_roundtrip(ctx, before: R.Resolved, state: dict) -> None:
    """Saving must not change the look; when a pin re-applies on top of what
    was a customization, say so."""
    cat, theme, variant = active(ctx, state)
    after = R.resolve(cat, theme, variant, state)
    for k in KINDS:
        if after.facets[k] != before.facets[k]:
            how = "the All Themes choice applies on top of it now" if k in state.get("pins", {}) else "it resolves differently"
            print(f"loft: note: {k} looks different after saving ({how})")


def cmd_save_variant(ctx, args) -> None:
    state = state_of(ctx)
    if args.theme:
        cat, theme, variant = select(ctx, args.theme)
    else:
        cat, theme, variant = active(ctx, state)
    r = A.save_variant(cat, state, theme, variant, args.name, ctx.library)
    A.save(ctx.state_dir, state)
    ctx.__dict__.pop("_catalogs", None)
    _report_roundtrip(ctx, r["before"], state)
    print(f"loft: saved {theme.id}@{r['variant']['id']} → {r['file']}")
    reapply(ctx, state, args)


def cmd_save_as(ctx, args) -> None:
    state = state_of(ctx)
    cat, theme, variant = active(ctx, state)
    r = A.save_as(cat, state, theme, variant, args.id, args.name, library_root(ctx), with_pins=args.with_pins, with_variants=args.with_variants)
    A.save(ctx.state_dir, state)
    ctx.__dict__.pop("_catalogs", None)
    _report_roundtrip(ctx, r["before"], state)
    print(f"loft: saved {args.id} → {r['file']}")
    reapply(ctx, state, args)


def cmd_accessibility(ctx, args) -> None:
    state = state_of(ctx)
    changed = False
    for key, val in (("reduceMotion", args.reduce_motion), ("reduceTransparency", args.reduce_transparency), ("increaseContrast", args.increase_contrast)):
        if val is not None:
            state["accessibility"][key] = val == "on"
            changed = True
    if changed:
        A.save(ctx.state_dir, state)
        reapply(ctx, state, args)
    print(json.dumps(state["accessibility"]) if args.json or not changed else "loft: accessibility " + ", ".join(f"{k} {'on' if v else 'off'}" for k, v in state["accessibility"].items()))


# ── loft <kind> … ───────────────────────────────────────────────────────────


def _value(text: str):
    try:
        return json.loads(text)
    except ValueError:
        return text


def kind_list(ctx, args) -> None:
    k = args.kind
    state = state_of(ctx)
    cat, theme, variant = select(ctx, args.theme) if args.theme else active(ctx, state)
    res = R.resolve(cat, theme, variant, state)
    in_theme = set()
    for raw in R.layers(theme, variant, k):
        try:
            sel = raw[1] if isinstance(raw[1], dict) else {"ref": raw[1]}
            if "ref" in sel:
                in_theme.add(cat.facet(sel["ref"], k, theme.pack).id)
        except FacetError:
            pass
    cur = res.sources[k]["ref"]
    rows = [
        {"id": f.id, "name": f.label, "pack": f.pack, "description": f.doc.get("description", ""), "active": f.id == cur, "theme": f.id in in_theme}
        for f in cat.facets(k)
    ]
    if args.json:
        print(json.dumps(rows))
        return
    for r in rows:
        mark = "*" if r["active"] else ("t" if r["theme"] else " ")
        print(f"{mark} {r['id']:44} {r['name']}")


def kind_show(ctx, args) -> None:
    k = args.kind
    if args.ref:
        cat = catalog(ctx)
        f = cat.facet(args.ref, k)
        doc = dict(f.doc, id=f.id)
        if args.resolved:
            res = R.resolve(cat, *active(ctx)[1:], state_of(ctx))
            data, _, _, errs = R.resolve_kind(cat, k, [("ref", f.id, None, "theme")], res.polarity, res.facets["colors"]["palette"], res.accessibility)
            doc["data"] = data
            if errs:
                doc["errors"] = errs
        print(json.dumps(doc, indent=2))
        return
    state = state_of(ctx)
    cat, theme, variant = active(ctx, state)
    res = R.resolve(cat, theme, variant, state)
    print(json.dumps({"kind": k, "theme": res.ref, "source": res.sources[k], "data": res.facets[k]}, indent=2))


def kind_apply(ctx, args) -> None:
    state = state_of(ctx)
    cat, theme, variant = active(ctx, state)
    f = cat.facet(args.ref, args.kind)
    where = A.set_selection(state, theme, variant, args.kind, f.id, pin=args.pin)
    A.save(ctx.state_dir, state)
    print(f"loft: {args.kind} → {f.id} ({where})")
    reapply(ctx, state, args)


def kind_set(ctx, args) -> None:
    state = state_of(ctx)
    cat, theme, variant = active(ctx, state)
    patch = path_patch(args.path, _value(args.value))
    # Check it before storing: a bad value is an error here, not a skipped layer.
    trial = json.loads(json.dumps(state))
    A.set_selection(trial, theme, variant, args.kind, {"patch": patch}, pin=args.pin)
    res = R.resolve(cat, theme, variant, trial)
    errs = [e for e in res.errors if e.split(": ", 1)[0].endswith("." + args.kind) and ("pins" in e if args.pin else "customizations" in e)]
    if errs:
        raise FacetError("; ".join(errs))
    where = A.set_selection(state, theme, variant, args.kind, {"patch": patch}, pin=args.pin)
    A.save(ctx.state_dir, state)
    got = get_path(res.facets[args.kind], args.path.split("."))
    print(f"loft: {args.kind}.{args.path} = {json.dumps(got)} ({where})")
    reapply(ctx, state, args)


def kind_reset(ctx, args) -> None:
    state = state_of(ctx)
    _, theme, variant = active(ctx, state)
    dropped = A.reset(state, theme, [args.kind], pin=args.pin, variant=variant)
    A.save(ctx.state_dir, state)
    print(f"loft: reset {', '.join(dropped) if dropped else 'nothing'}")
    reapply(ctx, state, args)


def kind_save_as(ctx, args) -> None:
    state = state_of(ctx)
    cat, theme, variant = active(ctx, state)
    r = A.save_facet(cat, state, theme, variant, args.kind, args.id, args.name, library_root(ctx), pin=args.pin)
    A.save(ctx.state_dir, state)
    print(f"loft: saved {r['ref']} → {r['file']}")
    reapply(ctx, state, args)


# ── argparse ────────────────────────────────────────────────────────────────


def add_theme_parsers(sub) -> None:
    """New `loft theme` subcommands (list/apply/render/current stay in cli.py)."""
    s = sub.add_parser("variants", help="a theme's variants (yours included)")
    s.add_argument("theme", nargs="?", help="theme (default: the active one)")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_variants)

    s = sub.add_parser("state", help="the active theme resolved: facets, sources, customized kinds (JSON)")
    s.add_argument("theme", nargs="?", help="theme[@variant] instead of the active one (with your customizations)")
    s.add_argument("--compact", action="store_true", help="one line")
    s.set_defaults(fn=cmd_state)

    s = sub.add_parser("diff", help="what your pins and customizations change, per kind")
    s.add_argument("theme", nargs="?")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_diff)

    s = sub.add_parser("reset", help="drop customizations of the active theme")
    s.add_argument("kinds", nargs="*", metavar="KIND")
    s.add_argument("--all", action="store_true", help="every kind")
    s.add_argument("--no-apply", action="store_true")
    s.set_defaults(fn=cmd_reset)

    s = sub.add_parser("save-variant", help="customizations → a new variant of the theme (only the diff)")
    s.add_argument("name", help="the variant's name (its id is made from it)")
    s.add_argument("--theme", help="theme[@variant] (default: the active one)")
    s.add_argument("--no-apply", action="store_true")
    s.set_defaults(fn=cmd_save_variant)

    s = sub.add_parser("save-as", help="the active look → a new theme in the library (references + patches)")
    s.add_argument("id")
    s.add_argument("--name")
    s.add_argument("--with-pins", action="store_true", help="fold your All Themes choices in too")
    s.add_argument("--with-variants", action="store_true", help="copy the theme's variants")
    s.add_argument("--no-apply", action="store_true")
    s.set_defaults(fn=cmd_save_as)

    s = sub.add_parser("accessibility", help="Reduce Motion / Reduce Transparency / Increase Contrast")
    for flag in ("--reduce-motion", "--reduce-transparency", "--increase-contrast"):
        s.add_argument(flag, choices=["on", "off"])
    s.add_argument("--json", action="store_true")
    s.add_argument("--no-apply", action="store_true")
    s.set_defaults(fn=cmd_accessibility)


KIND_HELP = {
    "colors": "palette and polarity",
    "wallpapers": "the wallpaper collection, sets and your arrangement (facet; `loft wallpaper` runs sets/auto)",
    "material": "glass, blur, transparency",
    "motion": "animations",
    "shape": "radii, gaps, focus ring vs shadows",
    "typography": "fonts",
    "icons": "icon and cursor themes",
    "lock": "lock screen and login design",
    "launcher": "Spotlight's look",
    "sounds": "event sounds",
}


def add_kind_parsers(top) -> None:
    for kind in KINDS:
        p = top.add_parser(kind, help=f"{KIND_HELP[kind]} (a facet of the theme)")
        sub = p.add_subparsers(dest="cmd", required=True)

        s = sub.add_parser("list", help=f"installed {kind} facets (* active, t the theme's)")
        s.add_argument("--json", action="store_true")
        s.add_argument("--theme")
        s.set_defaults(fn=kind_list, kind=kind)

        s = sub.add_parser("show", help="a facet document, or what the active theme resolves to")
        s.add_argument("ref", nargs="?")
        s.add_argument("--resolved", action="store_true", help="with a REF: filled and resolved against the active colors")
        s.set_defaults(fn=kind_show, kind=kind)

        s = sub.add_parser("apply", help="select another facet (a customization of the active theme)")
        s.add_argument("ref")
        s.add_argument("--pin", action="store_true", help="for every theme")
        s.add_argument("--no-apply", action="store_true")
        s.set_defaults(fn=kind_apply, kind=kind)

        s = sub.add_parser("set", help="patch one value: loft material set glass.opacity 0.35")
        s.add_argument("path")
        s.add_argument("value", help="JSON (0.35, true, \"#ffffff\", {…}); anything else is a string")
        s.add_argument("--pin", action="store_true", help="for every theme")
        s.add_argument("--no-apply", action="store_true")
        s.set_defaults(fn=kind_set, kind=kind)

        s = sub.add_parser("reset", help="drop this kind's customizations (or its pin)")
        s.add_argument("--pin", action="store_true")
        s.add_argument("--no-apply", action="store_true")
        s.set_defaults(fn=kind_reset, kind=kind)

        s = sub.add_parser("save-as", help=f"the resolved {kind} → a facet in the library, used by reference")
        s.add_argument("id")
        s.add_argument("--name")
        s.add_argument("--pin", action="store_true", help="make the saved facet an All Themes choice")
        s.add_argument("--no-apply", action="store_true")
        s.set_defaults(fn=kind_save_as, kind=kind)
