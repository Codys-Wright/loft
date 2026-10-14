"""Apps to leave alone (Settings → Keyboard Shortcuts): Loft's list, applied to xremap.

The list lives in <state>/overrides/keyboard.json (`leaveAlone`: niri app ids),
written by the shell (src/services/Shortcuts.qml). The shell's own window
shortcuts skip those apps by themselves; keyboard remaps live in xremap,
whose config is the consumer's (Nix). This turns that config into one where
every modmap / keymap / experimental_map entry is off in the listed apps
(`application: { not: [...] }`, xremap ≥ 0.10 with niri support):

  loft keys leave-alone                    the list
  loft keys xremap --base BASE.json        record BASE (the consumer's xremap config,
                                           as JSON) and write <state>/xremap/config.json
  loft keys xremap                         rewrite it from the recorded base (the
                                           shell runs this when the list changes);
                                           does nothing until a base was recorded

xremap reads the output (JSON is YAML) and, run with `--watch=config`, reloads
it when it changes. Wiring it up is the consumer's part: the xremap service
runs `loft keys xremap --base …` before starting and points at the output
(docs/FEATURES.md, "Apps to leave alone").
"""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path

SECTIONS = ("modmap", "keymap", "experimental_map")


def config_file(state_dir: Path) -> Path:
    return state_dir / "overrides" / "keyboard.json"


def xremap_dir(state_dir: Path) -> Path:
    return state_dir / "xremap"


def leave_alone(state_dir: Path) -> list[str]:
    """The app ids, in order, without blanks or duplicates."""
    try:
        data = json.loads(config_file(state_dir).read_text())
    except (OSError, ValueError):
        return []
    listed = data.get("leaveAlone") if isinstance(data, dict) else None
    out: list[str] = []
    for a in listed if isinstance(listed, list) else []:
        if isinstance(a, str) and a.strip() and a.strip() not in out:
            out.append(a.strip())
    return out


def _as_list(v) -> list:
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def exclude(config: dict, apps: list[str]) -> dict:
    """`config` with every remap entry off in `apps`.

    An entry without `application` gets `not: apps`; one with `not` gets the
    apps added; one with `only` loses them from its list (xremap ignores `not`
    when `only` is set, so an `only` regex that matches a listed app can't be
    narrowed — such entries stay as they are).
    """
    out = copy.deepcopy(config)
    # A leading "/" would make xremap read the id as a regex.
    apps = [a for a in apps if not a.startswith("/")]
    if not apps:
        return out
    for section in SECTIONS:
        for entry in out.get(section) or []:
            if not isinstance(entry, dict):
                continue
            app = entry.get("application")
            if not isinstance(app, dict):
                entry["application"] = {"not": list(apps)}
            elif app.get("only") is not None:
                app["only"] = [a for a in _as_list(app["only"]) if a not in apps]
            elif app.get("not") is not None:
                listed = _as_list(app["not"])
                app["not"] = listed + [a for a in apps if a not in listed]
            else:
                app["not"] = list(apps)
    return out


def _write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    tmp.write_text(text)
    tmp.replace(path)


def write_xremap(state_dir: Path, base: Path | None = None) -> dict:
    """Record `base` (when given) and write <state>/xremap/config.json.

    Returns {"written": path | None, "base": path | None, "apps": [...]}.
    """
    d = xremap_dir(state_dir)
    record = d / "base"
    if base is not None:
        base = base.expanduser().resolve()
        _write_atomic(record, f"{base}\n")
    elif record.exists():
        base = Path(record.read_text().strip())
    apps = leave_alone(state_dir)
    if base is None:
        return {"written": None, "base": None, "apps": apps}
    try:
        config = json.loads(base.read_text())
    except (OSError, ValueError) as e:
        raise SystemExit(f"loft: can't read the xremap base config {base}: {e} (it must be JSON)")
    if not isinstance(config, dict):
        raise SystemExit(f"loft: {base}: expected a JSON object")
    out = d / "config.json"
    text = json.dumps(exclude(config, apps), indent=2) + "\n"
    # xremap --watch=config reloads on every write: only write changes.
    if not out.exists() or out.read_text() != text:
        _write_atomic(out, text)
    return {"written": str(out), "base": str(base), "apps": apps}


def add_parser(top, state_dir_of) -> None:
    k = top.add_parser("keys", help="keyboard: apps to leave alone (applied to xremap)")
    sub = k.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("leave-alone", help="the apps Loft's shortcuts and remaps leave alone")
    s.add_argument("--json", action="store_true")

    def _list(ctx, a):
        apps = leave_alone(state_dir_of(ctx))
        print(json.dumps(apps) if a.json else "\n".join(apps))

    s.set_defaults(fn=_list)

    s = sub.add_parser("xremap", help="write xremap's config with the remaps off in those apps")
    s.add_argument("--base", help="the consumer's xremap config as JSON (recorded for later runs)")

    def _xremap(ctx, a):
        r = write_xremap(state_dir_of(ctx), Path(a.base) if a.base else None)
        if r["written"] is None:
            print("loft: no xremap base recorded yet (the xremap service passes --base); nothing to do")
        else:
            print(f"{r['written']}: remaps off in {len(r['apps'])} app(s)")

    s.set_defaults(fn=_xremap)
