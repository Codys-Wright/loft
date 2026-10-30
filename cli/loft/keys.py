"""Loft's keyboard layer: the macOS-style keymap, rendered into xremap's config.

Loft owns the remaps; xremap runs them. Three layers, later wins:

  keymap/mac.json                       Loft's defaults: app classes (terminals,
                                        browsers, …) and named groups of remaps
  $XDG_CONFIG_HOME/loft/keyboard.json   the Nix seed (programs.loft.keyboard)
  <state>/overrides/keymap.json         runtime changes (`loft keys …`, agents)

plus the shell's Apps to leave alone (<state>/overrides/keyboard.json,
`leaveAlone`, src/services/Shortcuts.qml): every remap is off in those apps.

A layer (seed or runtime) is

  {"groups":  {"symbols": true, "browser": false},        group on / off
   "apps":    {"com.foo.Bar": {"like": ["terminals"],     join app classes
                               "off": ["text-editing"],   groups off in this app
                               "remap": {"Super_L-k": "Ctrl-k"}}},  own remaps (win)
   "remap":   {"Super_L-F1": "F1"},                       own remaps, every app
   "extraGroups": [ {id, name, section, application?, remap, on?}, … ],
   "classes": {"daws": {"name": "DAWs", "apps": ["REAPER"]}}}

The output, <state>/xremap/config.json, is what xremap reads with
`--watch=config` (it reloads on every write, so only changes are written):
per-app remaps first (xremap uses the first entry that matches), then the
everywhere remaps, then the groups in order. Every edit renders and checks the
whole config (entry shapes, key names) before it is saved.

  loft keys show [--json]                    groups, classes, app rules, leave-alone
  loft keys group ID [on|off|default]        turn a group on / off
  loft keys app APP [--like C] [--off G] [--remap FROM=TO] [--leave-alone] …
                                             one app's rule; no options = what applies to it
  loft keys remap FROM=TO … [--unmap FROM]   remaps in every app
  loft keys xremap                           write xremap's config (the shell and the
                                             xremap service run this)
  loft keys render [--group ID]              print a config (e.g. dual-role keys only)
  loft keys leave-alone [--json]             the apps to leave alone
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
from collections.abc import Sequence
from pathlib import Path

SECTIONS = ("modmap", "keymap", "experimental_map")
KEYMAP_DIR = Path(__file__).parent / "keymap"
DEFAULTS = KEYMAP_DIR / "mac.json"
# Group fields that are Loft's, not xremap's.
META = ("id", "section", "on", "description")

MOD_RE = re.compile(r"^(shift|ctrl|control|c|alt|m|super|win|windows|meta)(_l|_r)?$", re.I)
# niri app ids (some have spaces: "Code - OSS").
ID_APP = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+: -]{0,199}$")


class KeysError(SystemExit):
    def __init__(self, msg: str):
        super().__init__(f"loft keys: {msg}")


# ── Files ───────────────────────────────────────────────────────────────────


def config_file(state_dir: Path) -> Path:
    """The shell's file: Apps to leave alone (+ pauseShellShortcuts)."""
    return state_dir / "overrides" / "keyboard.json"


def runtime_file(state_dir: Path) -> Path:
    return state_dir / "overrides" / "keymap.json"


def seed_file() -> Path:
    if os.environ.get("LOFT_KEYMAP_SEED"):
        return Path(os.environ["LOFT_KEYMAP_SEED"])
    home = os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config"
    return Path(home) / "loft" / "keyboard.json"


def xremap_dir(state_dir: Path) -> Path:
    return state_dir / "xremap"


def output_file(state_dir: Path) -> Path:
    return xremap_dir(state_dir) / "config.json"


def _read_json(path: Path, what: str) -> dict:
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        raise KeysError(f"can't read {what} {path}: {e}")
    if not isinstance(data, dict):
        raise KeysError(f"{what} {path}: expected a JSON object")
    return data


def _write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    tmp.write_text(text)
    tmp.replace(path)


def _dump(data) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def defaults() -> dict:
    return json.loads(DEFAULTS.read_text())


def evdev_keys() -> set[str]:
    return set((KEYMAP_DIR / "evdev-keys.txt").read_text().split())


# ── Apps to leave alone (the shell's list) ──────────────────────────────────


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


def set_leave_alone(state_dir: Path, app: str, on: bool) -> None:
    """Add / remove one app, keeping the shell's other keys (it reloads the file)."""
    f = config_file(state_dir)
    try:
        data = json.loads(f.read_text())
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    apps = [a for a in leave_alone(state_dir) if a != app]
    if on:
        apps.append(app)
    data["leaveAlone"] = apps
    data.setdefault("pauseShellShortcuts", True)
    _write_atomic(f, json.dumps(data, indent=4) + "\n")


def _as_list(v) -> list:
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def _exclude_entry(entry: dict, apps: list[str]) -> None:
    """Turn `entry` off in `apps`: an `only` list loses them, a `not` list (or
    none) gains them. xremap ignores `not` when `only` is set, so an `only`
    regex that matches one of the apps can't be narrowed."""
    apps = [a for a in apps if not a.startswith("/")]  # "/…/" would be a regex
    if not apps:
        return
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


def exclude(config: dict, apps: list[str]) -> dict:
    """`config` with every remap entry off in `apps`."""
    out = copy.deepcopy(config)
    for section in SECTIONS:
        for entry in out.get(section) or []:
            if isinstance(entry, dict):
                _exclude_entry(entry, apps)
    return out


# ── Layers ──────────────────────────────────────────────────────────────────


def layers(state_dir: Path) -> list[tuple[str, dict]]:
    """[(source, layer)] after the defaults: the Nix seed, then runtime."""
    return [
        ("nix", _read_json(seed_file(), "the keyboard seed")),
        ("runtime", _read_json(runtime_file(state_dir), "the keymap overrides")),
    ]


def resolve(state_dir: Path, runtime: dict | None = None) -> dict:
    """The effective model: classes, groups (with on + source), apps, remap.

    `runtime` replaces the runtime layer (an edit being checked)."""
    base = defaults()
    ls = layers(state_dir)
    if runtime is not None:
        ls[-1] = ("runtime", runtime)

    classes = {cid: {"name": c.get("name", cid), "apps": list(c.get("apps", [])), "source": "loft"} for cid, c in base["classes"].items()}
    groups: list[dict] = [dict(g, source="loft") for g in base["groups"]]
    vmods = list(base.get("virtual_modifiers", []))
    apps: dict[str, dict] = {}
    remap: dict = {}
    for source, layer in ls:
        for cid, c in (layer.get("classes") or {}).items():
            if not isinstance(c, dict):
                raise KeysError(f"{source} classes.{cid}: expected an object")
            cur = classes.setdefault(cid, {"name": c.get("name", cid), "apps": [], "source": source})
            cur["apps"] += [a for a in c.get("apps", []) if a not in cur["apps"]]
        for g in layer.get("extraGroups") or []:
            if not isinstance(g, dict) or not g.get("id"):
                raise KeysError(f"{source} extraGroups: every group needs an id")
            groups = [x for x in groups if x["id"] != g["id"]] + [dict(g, source=source)]
        for gid, on in (layer.get("groups") or {}).items():
            for g in groups:
                if g["id"] == gid:
                    g["on"] = bool(on)
                    g["onSource"] = source
        for app, rule in (layer.get("apps") or {}).items():
            if not isinstance(rule, dict):
                raise KeysError(f"{source} apps.{app}: expected an object")
            cur = apps.setdefault(app, {"like": [], "off": [], "remap": {}, "source": source})
            for k in ("like", "off"):
                if k in rule:
                    cur[k] = list(rule[k])
            for k, v in (rule.get("remap") or {}).items():
                if v is None:
                    cur["remap"].pop(k, None)
                else:
                    cur["remap"][k] = v
            cur["source"] = source
        for k, v in (layer.get("remap") or {}).items():
            if v is None:
                remap.pop(k, None)
            else:
                remap[k] = v
        vmods += [v for v in layer.get("virtual_modifiers", []) if v not in vmods]

    for app, rule in apps.items():
        for cid in rule["like"]:
            if cid not in classes:
                raise KeysError(f"apps.{app}.like: no class {cid!r} (classes: {', '.join(classes)})")
            if app not in classes[cid]["apps"]:
                classes[cid]["apps"].append(app)
        for gid in rule["off"]:
            if not any(g["id"] == gid for g in groups):
                raise KeysError(f"apps.{app}.off: no group {gid!r}")
    return {"classes": classes, "groups": groups, "apps": apps, "remap": remap, "virtual_modifiers": vmods}


def _expand(names, classes: dict, where: str) -> list[str]:
    out: list[str] = []
    for n in _as_list(names):
        if isinstance(n, str) and n.startswith("@"):
            if n[1:] not in classes:
                raise KeysError(f"{where}: no class {n[1:]!r}")
            out += [a for a in classes[n[1:]]["apps"] if a not in out]
        elif n not in out:
            out.append(n)
    return out


def render(model: dict, only_groups: list[str] | None = None, leave: Sequence[str] = (), with_apps: bool = True) -> dict:
    """The xremap config for `model` (resolve()).

    `only_groups`: just those groups (on or not), no app or everywhere remaps."""
    cfg: dict = {"virtual_modifiers": list(model["virtual_modifiers"]), "modmap": [], "keymap": []}
    if only_groups is None and with_apps:
        for app, rule in model["apps"].items():
            if rule["remap"]:
                cfg["keymap"].append({"name": f"{app} (loft keys app)", "application": {"only": [app]}, "remap": dict(rule["remap"])})
        if model["remap"]:
            cfg["keymap"].append({"name": "Every app (loft keys remap)", "remap": dict(model["remap"])})
    off_in: dict[str, list[str]] = {}
    for app, rule in model["apps"].items():
        for gid in rule["off"]:
            off_in.setdefault(gid, []).append(app)
    for g in model["groups"]:
        if only_groups is not None:
            if g["id"] not in only_groups:
                continue
        elif not g.get("on", True):
            continue
        section = g.get("section", "keymap")
        if section not in SECTIONS:
            raise KeysError(f"group {g['id']}: section must be one of {', '.join(SECTIONS)}")
        entry = {"name": g.get("name", g["id"])}
        entry.update({k: copy.deepcopy(v) for k, v in g.items() if k not in META + ("name", "source", "onSource")})
        app = entry.get("application")
        if isinstance(app, dict):
            entry["application"] = {k: _expand(v, model["classes"], f"group {g['id']}.application.{k}") for k, v in app.items()}
        if with_apps and off_in.get(g["id"]):
            _exclude_entry(entry, off_in[g["id"]])
        cfg.setdefault(section, []).append(entry)
    out = exclude(cfg, list(leave)) if leave else cfg
    return {k: v for k, v in out.items() if v or k == "keymap"}


# ── Checking ────────────────────────────────────────────────────────────────


def _key_ok(tok: str, keys: set[str]) -> bool:
    return tok.upper() in keys or bool(MOD_RE.match(tok))


def check_combo(combo, keys: set[str], where: str, modmap: bool = False) -> None:
    if not isinstance(combo, str) or not combo:
        raise KeysError(f"{where}: expected a key name, got {combo!r}")
    parts = [combo] if modmap else combo.split("-")
    *mods, key = parts
    for m in mods:
        if not MOD_RE.match(m):
            raise KeysError(f"{where}: {m!r} in {combo!r} isn't a modifier (Shift, Ctrl/C, Alt/M, Super/Win, with _L/_R)")
    if not _key_ok(key, keys):
        raise KeysError(f"{where}: unknown key {key!r} in {combo!r} (evdev names without KEY_: a, Esc, CapsLock, LeftBrace, F13 …)")


def _check_action(v, keys: set[str], where: str, modmap: bool) -> None:
    if v is None:
        return
    if isinstance(v, str):
        check_combo(v, keys, where, modmap)
    elif isinstance(v, list):
        for i, x in enumerate(v):
            _check_action(x, keys, f"{where}[{i}]", modmap)
    elif isinstance(v, dict):
        # Multi-purpose keys (tap / hold) are checked; other xremap actions
        # (launch, remap, set_mark, …) pass through.
        for k in ("tap", "hold", "alone"):
            if k in v:
                _check_action(v[k], keys, f"{where}.{k}", modmap)
    else:
        raise KeysError(f"{where}: expected a key, a list or an action object")


def check(config: dict) -> None:
    keys = evdev_keys()
    for section in SECTIONS:
        entries = config.get(section) or []
        if not isinstance(entries, list):
            raise KeysError(f"{section}: expected a list")
        for i, e in enumerate(entries):
            where = f"{section}[{i}] {e.get('name', '') if isinstance(e, dict) else ''}".strip()
            if not isinstance(e, dict) or not isinstance(e.get("remap"), dict):
                raise KeysError(f"{where}: needs a remap object")
            app = e.get("application")
            if app is not None:
                if not isinstance(app, dict) or set(app) - {"only", "not"}:
                    raise KeysError(f"{where}: application takes only / not")
                for v in app.values():
                    if not all(isinstance(a, str) and a for a in _as_list(v)):
                        raise KeysError(f"{where}: application lists hold app ids")
            for k, v in e["remap"].items():
                check_combo(k, keys, f"{where} remap", modmap=section == "modmap")
                _check_action(v, keys, f"{where} remap.{k}", modmap=section == "modmap")


# ── Writing ─────────────────────────────────────────────────────────────────


def xremap_following(state_dir: Path) -> bool:
    """Whether a running xremap reads <state>/xremap/config.json."""
    want = str(output_file(state_dir))
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            argv = (p / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if argv and Path(argv[0].decode(errors="replace")).name == "xremap" and want.encode() in argv:
            return True
    return False


def write_xremap(state_dir: Path) -> dict:
    """Render and write <state>/xremap/config.json (only when it changed).

    Returns {"written": path, "changed": bool, "apps": leave-alone list, "groups": on ids}."""
    model = resolve(state_dir)
    apps = leave_alone(state_dir)
    cfg = render(model, leave=apps)
    check(cfg)
    out = output_file(state_dir)
    text = _dump(cfg)
    changed = not out.exists() or out.read_text() != text
    if changed:
        _write_atomic(out, text)
    # The old Nix-recorded base (before Loft owned the keymap) no longer applies.
    (xremap_dir(state_dir) / "base").unlink(missing_ok=True)
    return {"written": str(out), "changed": changed, "apps": apps, "groups": [g["id"] for g in model["groups"] if g.get("on", True)]}


def edit(state_dir: Path, mutate) -> dict:
    """Apply `mutate(layer)` to the runtime layer, check the result, save, write."""
    f = runtime_file(state_dir)
    layer = copy.deepcopy(_read_json(f, "the keymap overrides"))
    mutate(layer)
    for k in ("groups", "apps", "remap"):
        if k in layer and not layer[k]:
            del layer[k]
    check(render(resolve(state_dir, runtime=layer), leave=leave_alone(state_dir)))
    _write_atomic(f, _dump(layer))
    return write_xremap(state_dir)


def _matches(app: str, names: list[str]) -> bool:
    for n in names:
        if n.startswith("/") and n.endswith("/") and len(n) > 1:
            if re.search(n[1:-1], app):
                return True
        elif n == app:
            return True
    return False


def app_view(state_dir: Path, app: str) -> dict:
    """What reaches `app`: its rule, its classes and every group that applies."""
    model = resolve(state_dir)
    rule = model["apps"].get(app, {"like": [], "off": [], "remap": {}, "source": None})
    left = app in leave_alone(state_dir)
    groups = []
    for g in model["groups"]:
        a = g.get("application") or {}
        if "only" in a:
            hits = _matches(app, _expand(a["only"], model["classes"], g["id"]))
        else:
            hits = not _matches(app, _expand(a.get("not"), model["classes"], g["id"]))
        on = g.get("on", True)
        why = "off" if not on else "leave alone" if left else "off for this app" if g["id"] in rule["off"] else None if hits else "not for this app"
        groups.append({"id": g["id"], "name": g.get("name", g["id"]), "applies": on and hits and not left and g["id"] not in rule["off"], "why": why})
    return {
        "app": app,
        "leaveAlone": left,
        "classes": [cid for cid, c in model["classes"].items() if _matches(app, c["apps"])],
        "rule": rule,
        "groups": groups,
    }


def _pair(s: str) -> tuple[str, str | list[str]]:
    k, sep, v = s.partition("=")
    if not sep or not k.strip():
        raise KeysError(f"{s!r}: expected FROM=TO (e.g. Super_L-k=Ctrl-k; TO may be a,b for a sequence)")
    vs = [x.strip() for x in v.split(",") if x.strip()]
    return k.strip(), vs[0] if len(vs) == 1 else vs


def status_line(state_dir: Path, r: dict) -> str:
    """One line for Settings (KeybindsPage: "Following this list — …")."""
    if not xremap_following(state_dir):
        return f"loft: xremap isn't reading {r['written']} (programs.loft.keyboard.enable)"
    return f"{r['written']}: {len(r['groups'])} groups on, remaps off in {len(r['apps'])} app(s)"


# ── CLI ─────────────────────────────────────────────────────────────────────


def _print_show(state_dir: Path) -> None:
    model = resolve(state_dir)
    print("Groups (loft keys group ID on|off):")
    for g in model["groups"]:
        mark = "on " if g.get("on", True) else "off"
        src = f"  [{g.get('onSource') or g['source']}]" if (g.get("onSource") or g["source"]) != "loft" else ""
        print(f"  {mark}  {g['id']:<22} {g.get('name', '')}{src}")
    print("\nClasses (loft keys app APP --like CLASS):")
    for cid, c in model["classes"].items():
        print(f"  {cid:<14} {', '.join(c['apps'])}")
    if model["apps"]:
        print("\nApp rules:")
        for app, r in model["apps"].items():
            bits = [f"like {', '.join(r['like'])}"] * bool(r["like"]) + [f"off {', '.join(r['off'])}"] * bool(r["off"])
            bits += [f"{k} → {v}" for k, v in r["remap"].items()]
            print(f"  {app}  [{r['source']}]  " + "; ".join(bits))
    if model["remap"]:
        print("\nEvery app:")
        for k, v in model["remap"].items():
            print(f"  {k} → {v}")
    apps = leave_alone(state_dir)
    print(f"\nLeft alone: {', '.join(apps) if apps else '(none)'}")
    out = output_file(state_dir)
    print(f"\nxremap: {out} ({'xremap is reading it' if xremap_following(state_dir) else 'no xremap reads it'})")


def _print_app(v: dict) -> None:
    print(f"{v['app']}{'  (left alone: no remaps)' if v['leaveAlone'] else ''}")
    print(f"  classes: {', '.join(v['classes']) or '(none)'}")
    r = v["rule"]
    if r["remap"]:
        print("  own remaps:")
        for k, x in r["remap"].items():
            print(f"    {k} → {x}")
    print("  groups:")
    for g in v["groups"]:
        print(f"    {'✓' if g['applies'] else '·'} {g['id']:<22} {g['why'] or ''}")


def add_parser(top, state_dir_of) -> None:
    k = top.add_parser("keys", help="keyboard: Loft's macOS-style remaps (xremap), per-app rules, apps to leave alone")
    sub = k.add_subparsers(dest="cmd", required=True)

    def done(ctx, r):
        print(status_line(state_dir_of(ctx), r))

    s = sub.add_parser("show", help="groups, classes, per-app rules and apps left alone")
    s.add_argument("--json", action="store_true")

    def _show(ctx, a):
        st = state_dir_of(ctx)
        if a.json:
            m = resolve(st)
            m["leaveAlone"] = leave_alone(st)
            m["xremap"] = {"config": str(output_file(st)), "following": xremap_following(st)}
            print(json.dumps(m, indent=2, ensure_ascii=False))
        else:
            _print_show(st)

    s.set_defaults(fn=_show)

    s = sub.add_parser("group", help="turn a group of remaps on or off")
    s.add_argument("id")
    s.add_argument("state", nargs="?", choices=["on", "off", "default"])

    def _group(ctx, a):
        st = state_dir_of(ctx)
        groups = {g["id"]: g for g in resolve(st)["groups"]}
        if a.id not in groups:
            raise KeysError(f"no group {a.id!r} (loft keys show)")
        if a.state is None:
            print(json.dumps(groups[a.id], indent=2, ensure_ascii=False))
            return

        def mutate(layer):
            gs = layer.setdefault("groups", {})
            if a.state == "default":
                gs.pop(a.id, None)
            else:
                gs[a.id] = a.state == "on"

        done(ctx, edit(st, mutate))

    s.set_defaults(fn=_group)

    s = sub.add_parser("app", help="one app's keyboard rule; no options = what reaches it")
    s.add_argument("app", help="niri app id (niri msg windows)")
    s.add_argument("--like", action="append", default=[], metavar="CLASS", help="treat it as one of a class (terminals, browsers …)")
    s.add_argument("--unlike", action="append", default=[], metavar="CLASS")
    s.add_argument("--off", action="append", default=[], metavar="GROUP", help="a group's remaps off in this app")
    s.add_argument("--on", action="append", default=[], metavar="GROUP", help="undo --off")
    s.add_argument("--remap", action="append", default=[], metavar="FROM=TO", help="this app's own remap (wins over groups)")
    s.add_argument("--unmap", action="append", default=[], metavar="FROM")
    s.add_argument("--leave-alone", action=argparse.BooleanOptionalAction, default=None, help="no Loft remaps or window shortcuts in this app")
    s.add_argument("--reset", action="store_true", help="drop this app's runtime rule first")
    s.add_argument("--json", action="store_true")

    def _app(ctx, a):
        st = state_dir_of(ctx)
        if not ID_APP.match(a.app):
            raise KeysError(f"{a.app!r}: not an app id")
        changes = a.like or a.unlike or a.off or a.on or a.remap or a.unmap or a.reset
        if a.leave_alone is not None:
            set_leave_alone(st, a.app, a.leave_alone)
        if changes:
            pairs = [_pair(p) for p in a.remap]

            def mutate(layer):
                apps = layer.setdefault("apps", {})
                if a.reset:
                    apps.pop(a.app, None)
                rule = apps.get(a.app, {})
                # What the layers below runtime give (the Nix seed): the
                # base an unset field falls back to.
                below = {k: v for k, v in layer.items() if k != "apps"}
                below["apps"] = {x: y for x, y in apps.items() if x != a.app}
                cur = resolve(st, runtime=below)["apps"].get(a.app, {"like": [], "off": []})
                like = [c for c in (rule.get("like", cur["like"])) if c not in a.unlike]
                rule["like"] = like + [c for c in a.like if c not in like]
                off = [g for g in rule.get("off", cur["off"]) if g not in a.on]
                rule["off"] = off + [g for g in a.off if g not in off]
                rm = rule.setdefault("remap", {})
                for f, t in pairs:
                    rm[f] = t
                for f in a.unmap:
                    if f in rm:
                        del rm[f]
                    else:
                        rm[f] = None  # drops a Nix-seeded remap
                rule = {x: y for x, y in rule.items() if y}
                if rule:
                    apps[a.app] = rule
                else:
                    apps.pop(a.app, None)

            r = edit(st, mutate)
        elif a.leave_alone is not None:
            r = write_xremap(st)
        else:
            r = None
        v = app_view(st, a.app)
        if a.json:
            print(json.dumps(v, indent=2, ensure_ascii=False))
        else:
            _print_app(v)
            if r:
                done(ctx, r)

    s.set_defaults(fn=_app)

    s = sub.add_parser("remap", help="remaps in every app (custom; per-app ones still win)")
    s.add_argument("pairs", nargs="*", metavar="FROM=TO")
    s.add_argument("--unmap", action="append", default=[], metavar="FROM")

    def _remap(ctx, a):
        st = state_dir_of(ctx)
        if not a.pairs and not a.unmap:
            print(json.dumps(resolve(st)["remap"], indent=2, ensure_ascii=False))
            return
        pairs = [_pair(p) for p in a.pairs]

        def mutate(layer):
            rm = layer.setdefault("remap", {})
            for f, t in pairs:
                rm[f] = t
            for f in a.unmap:
                if f in rm:
                    del rm[f]
                else:
                    rm[f] = None

        done(ctx, edit(st, mutate))

    s.set_defaults(fn=_remap)

    s = sub.add_parser("xremap", help="write xremap's config (<state>/xremap/config.json)")
    s.add_argument("--base", help=argparse.SUPPRESS)

    def _xremap(ctx, a):
        if a.base:
            # Before Loft owned the keymap the consumer passed its own config;
            # failing makes that consumer's fallback use it as it is.
            raise KeysError("--base is gone: Loft owns the keymap now (programs.loft.keyboard; seed in ~/.config/loft/keyboard.json)")
        done(ctx, write_xremap(state_dir_of(ctx)))

    s.set_defaults(fn=_xremap)

    s = sub.add_parser("render", help="print an xremap config (to stdout)")
    s.add_argument("--group", action="append", metavar="ID", help="only these groups (on or off), no per-app remaps")
    s.add_argument("--out", help="write here instead (only when it changed)")

    def _render(ctx, a):
        st = state_dir_of(ctx)
        cfg = render(resolve(st), only_groups=a.group, leave=leave_alone(st))
        check(cfg)
        if a.out:
            out = Path(a.out)
            if not out.exists() or out.read_text() != _dump(cfg):
                _write_atomic(out, _dump(cfg))
        else:
            print(_dump(cfg), end="")

    s.set_defaults(fn=_render)

    s = sub.add_parser("leave-alone", help="the apps Loft's shortcuts and remaps leave alone")
    s.add_argument("--json", action="store_true")

    def _list(ctx, a):
        apps = leave_alone(state_dir_of(ctx))
        print(json.dumps(apps) if a.json else "\n".join(apps))

    s.set_defaults(fn=_list)
