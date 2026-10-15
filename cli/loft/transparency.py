"""`loft appearance …`: the Transparency and Blur dials.

    loft appearance status [--json]
    loft appearance transparency [0..1 | theme]   0 Solid … 0.5 the theme's … 1 Clear
    loft appearance blur [0..1 | theme]           0 Clear (no blur) … 1 Frosted
    loft appearance terminals [0..1 | theme]      terminal background opacity (override)
    loft appearance gtk [0..1 | theme]            GTK glass sidebar alpha (override)
    loft appearance set KEY=VALUE…                several at once (the shell's sliders)
    loft appearance reset                         every dial back to the theme

Stored in <state>/appearance.json `transparency` (the user layer, never the
theme files); the theme's material facet is what they scale from
(render/look.py has the curves). A change re-applies the active theme: only
the units whose output changed re-render, and only their hooks run (niri
reloads, with loft-niri re-rendering the window rules; ghostty / kitty get
their reload signal; the shell re-reads theme.json). The window opacity
overrides of Settings → Window Rules are loft-niri's (`loft windows glass
--focused F`) and still win over the master dial; the shell's own glass
override is Settings → Appearance → Liquid Glass.

Writes are serialized with a lock, so a burst of calls (a dragged slider)
lands in order and the last value wins.
"""

from __future__ import annotations

import fcntl
import json
from contextlib import contextmanager

from . import themecmds
from .facets import appearance as A
from .facets import resolve as R
from .render import look

KEYS = {"transparency": "level", "level": "level", "blur": "blur", "terminals": "terminals", "gtk": "gtk"}
CLEAR_WORDS = ("theme", "default", "reset", "none", "null", "-")


@contextmanager
def _locked(ctx):
    ctx.state_dir.mkdir(parents=True, exist_ok=True)
    with open(ctx.state_dir / ".appearance.lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def parse_value(text: str) -> float | None:
    if text.strip().lower() in CLEAR_WORDS:
        return None
    try:
        v = float(text.rstrip("%")) / (100 if text.endswith("%") else 1)
    except ValueError as e:
        raise ValueError(f"not a number in 0..1 (or `theme`): {text}") from e
    if not 0 <= v <= 1:
        raise ValueError(f"out of range 0..1: {text}")
    return v


def status(ctx) -> dict:
    """The dials, what they produce and the theme's own values."""
    state = themecmds.state_of(ctx)
    cat, theme, variant = themecmds.active(ctx, state)
    res = themecmds.resolved(ctx, cat, theme, variant, state)
    m = res.facets["material"]
    out = look.transparency(m, res.transparency, res.accessibility, res.polarity != "light")
    out["stored"] = dict(state.get("transparency") or {})
    out["windows"] = look.windows(m, res.transparency)
    return out


def update(ctx, changes: dict[str, float | None], quiet: bool = True) -> dict:
    """Store the changes (None drops a key) and re-apply the active theme."""
    with _locked(ctx):
        state = themecmds.state_of(ctx)
        tr = dict(state.get("transparency") or {})
        for k, v in changes.items():
            if v is None:
                tr.pop(k, None)
            else:
                tr[k] = v
        state["transparency"] = R.dials(tr)
        A.save(ctx.state_dir, state)
        cat, theme, variant = themecmds.active(ctx, state)
        themecmds.apply_resolved(ctx, cat, themecmds.resolved(ctx, cat, theme, variant, state), quiet=quiet)
    return state["transparency"]


def _print(ctx, args) -> None:
    s = status(ctx)
    if args.json:
        print(json.dumps(s))
        return
    e = s["effective"]

    def pct(v):
        return f"{round(v * 100)}%"

    def mark(k):
        return "" if s["stored"].get(k) is None else " (set)"

    print(f"transparency  {pct(e['level'])}{mark('level')}   (0 Solid · 50% the theme · 100% Clear)")
    print(f"blur          {pct(e['blur']) if e['blurOn'] else 'off'}{mark('blur')}   (theme {pct(s['theme']['blur'])})")
    print(f"windows       focused {pct(s['windows']['opacity']['focused'])}, others {pct(s['windows']['opacity']['unfocused'])}   (Window Rules overrides win)")
    print(f"terminals     {pct(e['terminals'])}{mark('terminals')}   (theme {pct(s['theme']['terminals'])})")
    print(f"gtk glass     {pct(e['gtk'])}{mark('gtk')}   (theme {pct(s['theme']['gtk'])})")
    if s["reduced"]:
        print("Reduce Transparency is on: it wins over the dials.")


def cmd(ctx, args) -> None:
    what = args.what
    if what == "status":
        _print(ctx, args)
        return
    if what == "reset":
        update(ctx, {k: None for k in R.DIALS})
        _print(ctx, args)
        return
    if what == "set":
        changes = {}
        for item in args.values:
            k, sep, v = item.partition("=")
            if not sep or k not in KEYS:
                raise ValueError(f"set KEY=VALUE (keys: {', '.join(KEYS)}): {item}")
            changes[KEYS[k]] = parse_value(v)
        update(ctx, changes)
        _print(ctx, args)
        return
    key = KEYS[what]
    if not args.values:
        s = status(ctx)
        v = s["effective"][key]
        print(json.dumps({"key": what, "value": v, "stored": s["stored"].get(key)}) if args.json else f"{what} {round(v * 100)}%")
        return
    if len(args.values) != 1:
        raise ValueError(f"loft appearance {what} [0..1 | theme]")
    update(ctx, {key: parse_value(args.values[0])})
    _print(ctx, args)


def add_parser(top) -> None:
    p = top.add_parser(
        "appearance",
        help="the Transparency and Blur dials (Settings → Appearance)",
        description="status · transparency [0..1|theme] (0 Solid, 0.5 the theme, 1 Clear) · blur [0..1|theme] (0 no blur, "
        "1 frosted) · terminals [0..1|theme] · gtk [0..1|theme] · set KEY=VALUE… · reset. Values may be percentages (80%).",
    )
    p.add_argument("what", choices=["status", "transparency", "level", "blur", "terminals", "gtk", "set", "reset"])
    p.add_argument("values", nargs="*")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=lambda ctx, args: _run(ctx, args))


def _run(ctx, args) -> None:
    from .facets import FacetError

    try:
        cmd(ctx, args)
    except ValueError as e:
        raise FacetError(str(e)) from e
