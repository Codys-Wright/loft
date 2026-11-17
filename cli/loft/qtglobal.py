"""Global Qt style (programs.loft.qt.global, Settings → Appearance → "Theme all
Qt apps"): while Loft is the shell, every Qt / KDE app uses Loft's Kvantum
theme and color scheme, not only the apps programs.loft.qt lists
(qtapps.py). docs/KWIN.md §4.14.

What `apply` writes (and records, so `revert` can put it back):

  ~/.config/kdeglobals
    [KDE] widgetStyle            kvantum, or kvantum-dark for a dark theme
    [General] ColorScheme        Loft
    [General] ColorSchemeHash    sha1 of Loft.colors (what System Settings writes)
    [Colors:*] [ColorEffects:*] [WM]
                                 every key of the rendered Loft.colors, copied
                                 the way plasma-apply-colorscheme copies a scheme
  ~/.config/Kvantum/kvantum.kvconfig
    [General] theme              Loft

then KConfig's change notification (org.kde.kconfig.notify.ConfigChanged on
/kdeglobals, what `kwriteconfig6 --notify` sends) and KGlobalSettings'
notifyChange (palette, style), so apps running with Plasma's platform theme
re-read the palette and re-create their style live.

The record is <state>/qt-global.prev: per key the user's own value (null =
the key wasn't in the user's file) and the value Loft wrote. `revert` puts a
key back only while it still holds Loft's value (a choice made in System
Settings meanwhile wins), deleting keys that weren't there, then forgets the
record. A re-apply (the `qt` hook on a theme change) keeps the recorded
originals; a key someone else changed since Loft wrote it is recorded afresh.

Lifecycle: the shell's unit runs `loft qt global start` after it starts
(applies when the switch is on) and `loft qt global stop` after it stops
(reverts), under Plasma (loft-plasma-shell) and niri (loft-shell). The switch
itself is `loft qt global on|off` (<state>/qt-global, else qt.json's
"global"); it applies / reverts at once while the shell runs.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

from . import qtapps
from .qtapps import THEME, ini_get, ini_set

RECORD = "qt-global.prev"
CHOICE = "qt-global"
# Groups of a color scheme that a scheme switch copies into kdeglobals.
COLOR_GROUP_PREFIXES = ("Colors:", "ColorEffects:")
COLOR_GROUPS = ("WM",)


def kdeglobals() -> Path:
    return qtapps.config_home() / "kdeglobals"


def kvantum_chooser() -> Path:
    return qtapps.config_home() / "Kvantum" / "kvantum.kvconfig"


def scheme_file() -> Path:
    return qtapps.data_home() / "color-schemes" / f"{THEME}.colors"


def runtime_marker() -> Path:
    """Exists while the shell runs (`start` … `stop`)."""
    rt = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(rt) / "loft" / "qt-global-session"


# ── INI helpers on top of qtapps' ───────────────────────────────────────────


def ini_groups(text: str) -> dict[str, dict[str, str]]:
    """{group: {key: value}} of a KConfig file, in order; keys with KConfig
    flags (`key[$e]`, locale `key[de]`) are left out."""
    out: dict[str, dict[str, str]] = {}
    cur = None
    for line in text.splitlines():
        m = qtapps._GROUP.match(line)
        if m:
            cur = m.group(1)
            out.setdefault(cur, {})
            continue
        s = line.strip()
        if cur is None or not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        k = k.strip()
        if "[" in k:
            continue
        out[cur][k] = v.strip()
    return out


def ini_delete(text: str, group: str, key: str) -> str:
    """`text` without group/key (and without the group header once it is
    empty). Everything else stays byte for byte."""
    lines = text.splitlines()
    cur, start, drop = None, None, None
    for i, line in enumerate(lines):
        m = qtapps._GROUP.match(line)
        if m:
            cur = m.group(1)
            if cur == group:
                start = i
            continue
        if cur == group and "=" in line and line.split("=", 1)[0].strip() == key:
            drop = i
            break
    if drop is None:
        return text
    del lines[drop]
    # The group is empty now: drop its header and one blank line before it.
    if start is not None:
        end = start + 1
        while end < len(lines) and not qtapps._GROUP.match(lines[end]):
            if lines[end].strip():
                break
            end += 1
        else:
            del lines[start:end]
            # The last group: drop the blank line that separated it too.
            if start == len(lines) and start > 0 and not lines[start - 1].strip():
                del lines[start - 1]
    return ("\n".join(lines) + "\n") if any(x.strip() for x in lines) else ""


def _read(path: Path) -> str:
    try:
        return path.read_text()
    except FileNotFoundError:
        return ""


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.loft-tmp")
    tmp.write_text(text)
    tmp.replace(path)


# ── what Loft owns ──────────────────────────────────────────────────────────


def dark_scheme(colors: dict[str, dict[str, str]]) -> bool:
    """Whether the scheme's window background is dark (Kvantum's kvantum-dark)."""
    bg = colors.get("Colors:Window", {}).get("BackgroundNormal", "")
    try:
        r, g, b = (int(x) for x in bg.split(",")[:3])
    except ValueError:
        return False
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.5


def wanted(scheme_text: str) -> dict[str, list[tuple[str, str, str]]]:
    """{file name: [(group, key, value)]}: everything global mode sets, from
    the rendered color scheme's text."""
    colors = ini_groups(scheme_text)
    kg: list[tuple[str, str, str]] = [
        ("KDE", "widgetStyle", "kvantum-dark" if dark_scheme(colors) else "kvantum"),
        ("General", "ColorScheme", THEME),
        ("General", "ColorSchemeHash", hashlib.sha1(scheme_text.encode()).hexdigest()),
    ]
    for group, keys in colors.items():
        if group.startswith(COLOR_GROUP_PREFIXES) or group in COLOR_GROUPS:
            kg += [(group, k, v) for k, v in keys.items()]
    return {"kdeglobals": kg, "kvantum": [("General", "theme", THEME)]}


def _path(name: str) -> Path:
    return kdeglobals() if name == "kdeglobals" else kvantum_chooser()


def _record_path(state_dir: Path) -> Path:
    return Path(state_dir) / RECORD


def read_record(state_dir: Path) -> dict:
    try:
        doc = json.loads(_record_path(state_dir).read_text())
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


# ── apply / revert ──────────────────────────────────────────────────────────


def apply(state_dir: Path) -> list[str]:
    """Write the keys in `wanted`, recording what was there. Returns notes."""
    notes = [n for n in qtapps.link_theme(state_dir) if n]
    try:
        scheme_text = scheme_file().read_text()
    except OSError as e:
        raise RuntimeError(f"no Loft color scheme to apply ({scheme_file()}: {e.strerror}); apply a theme first") from e
    rec = read_record(state_dir)
    changed: dict[str, list[tuple[str, str]]] = {}
    for name, entries in wanted(scheme_text).items():
        path = _path(name)
        text = before = _read(path)
        keys = rec.setdefault(name, {})
        for group, key, value in entries:
            have = ini_get(text, group, key)
            slot = f"{group}\x1f{key}"
            r = keys.get(slot)
            # First time, or someone else wrote the key since Loft did: that
            # value is what revert should give back.
            if r is None or have != r.get("ours"):
                keys[slot] = {"prev": have, "ours": value}
            else:
                r["ours"] = value
            if have != value:
                text = ini_set(text, group, key, value)
                changed.setdefault(name, []).append((group, key))
        if text != before:
            _write(path, text)
            notes.append(f"{path}: {len(changed.get(name, []))} keys")
    _record_path(state_dir).parent.mkdir(parents=True, exist_ok=True)
    _write(_record_path(state_dir), json.dumps(rec, indent=1, sort_keys=True) + "\n")
    # Always notify: a theme change re-points the Kvantum theme's files with
    # the same widgetStyle, and the style must be re-created to read them.
    notify(changed.get("kdeglobals", []) or [("KDE", "widgetStyle")], style=True)
    return notes


def revert(state_dir: Path) -> list[str]:
    """Put the recorded keys back (those still Loft's), then forget the record."""
    rec = read_record(state_dir)
    if not rec:
        return []
    notes: list[str] = []
    touched: list[tuple[str, str]] = []
    for name, keys in rec.items():
        if not isinstance(keys, dict):
            continue
        path = _path(name)
        text = before = _read(path)
        n = 0
        for slot, r in keys.items():
            group, _, key = slot.partition("\x1f")
            if not isinstance(r, dict) or ini_get(text, group, key) != r.get("ours"):
                continue
            prev = r.get("prev")
            text = ini_delete(text, group, key) if prev is None else ini_set(text, group, key, prev)
            n += 1
            if name == "kdeglobals":
                touched.append((group, key))
        if text != before:
            if text or path.exists():
                _write(path, text)
            notes.append(f"{path}: {n} keys back")
    _record_path(state_dir).unlink(missing_ok=True)
    if touched:
        notify(touched, style=True)
    return notes


# ── KConfig / KGlobalSettings notifications ─────────────────────────────────


def _ay(s: str) -> list[str]:
    b = s.encode()
    return [str(len(b)), *map(str, b)]


def notify(keys: list[tuple[str, str]], style: bool) -> None:
    """ConfigChanged on /kdeglobals (KConfigWatcher: platform theme, KColorScheme
    users) and KGlobalSettings notifyChange (0 = palette, 2 = style). Quietly
    nothing without a session bus."""
    if os.environ.get("LOFT_QT_GLOBAL_NO_NOTIFY") == "1":
        return
    groups: dict[str, list[str]] = {}
    for g, k in keys:
        groups.setdefault(g, [])
        if k not in groups[g]:
            groups[g].append(k)
    args = ["a{saay}", str(len(groups))]
    for g, ks in groups.items():
        args += [g, str(len(ks))]
        for k in ks:
            args += _ay(k)
    calls = [["/kdeglobals", "org.kde.kconfig.notify", "ConfigChanged", *args],
             ["/KGlobalSettings", "org.kde.KGlobalSettings", "notifyChange", "ii", "0", "0"]]
    if style:
        calls.append(["/KGlobalSettings", "org.kde.KGlobalSettings", "notifyChange", "ii", "2", "0"])
    for c in calls:
        try:
            subprocess.run(["busctl", "--user", "emit", *c], capture_output=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return


# ── the switch and the session ──────────────────────────────────────────────


def enabled(state_dir: Path) -> bool:
    """<state>/qt-global (Settings' switch), else qt.json's "global"."""
    try:
        v = (Path(state_dir) / CHOICE).read_text().strip()
        if v in ("on", "off"):
            return v == "on"
    except OSError:
        pass
    doc = qtapps.settings() or {}
    return bool(doc.get("global"))


def set_choice(state_dir: Path, on: bool) -> list[str]:
    Path(state_dir).mkdir(parents=True, exist_ok=True)
    _write(Path(state_dir) / CHOICE, "on\n" if on else "off\n")
    if not runtime_marker().exists():
        return ["saved; applies when Loft's shell starts" if on else "saved"]
    return apply(state_dir) if on else revert(state_dir)


def start(state_dir: Path) -> list[str]:
    m = runtime_marker()
    m.parent.mkdir(parents=True, exist_ok=True)
    m.write_text(str(os.getpid()) + "\n")
    if enabled(state_dir):
        return apply(state_dir)
    return revert(state_dir)  # turned off while the shell was down


def stop(state_dir: Path) -> list[str]:
    runtime_marker().unlink(missing_ok=True)
    return revert(state_dir)


def follow_theme(state_dir: Path) -> list[str]:
    """The `qt` hook: re-apply after a theme change while applied."""
    if not read_record(state_dir) or not runtime_marker().exists():
        return []
    return apply(state_dir)


def status(state_dir: Path) -> dict:
    rec = read_record(state_dir)
    return {
        "configured": qtapps.settings() is not None,
        "enabled": enabled(state_dir),
        "session": runtime_marker().exists(),
        "applied": bool(rec),
        "widgetStyle": ini_get(_read(kdeglobals()), "KDE", "widgetStyle"),
        "colorScheme": ini_get(_read(kdeglobals()), "General", "ColorScheme"),
        "kvantumTheme": ini_get(_read(kvantum_chooser()), "General", "theme"),
        "keys": {name: len(keys) for name, keys in rec.items() if isinstance(keys, dict)},
    }


def add_parser(qsub, state_dir_of) -> None:
    g = qsub.add_parser("global", help="every Qt / KDE app in Loft's Kvantum theme + color scheme while Loft runs (docs/KWIN.md §4.14)")
    gsub = g.add_subparsers(dest="global_cmd", required=True)

    def runner(fn):
        def _run(ctx, a):
            try:
                for n in fn(Path(state_dir_of(ctx))):
                    print(n)
            except RuntimeError as e:
                raise SystemExit(f"loft qt global: {e}")
        return _run

    for name, fn, h in (
        ("on", lambda s: set_choice(s, True), "turn it on (applies now while the shell runs)"),
        ("off", lambda s: set_choice(s, False), "turn it off (reverts now)"),
        ("start", start, "the shell started: apply if on (the unit's ExecStartPost)"),
        ("stop", stop, "the shell stopped: put the recorded keys back (ExecStopPost)"),
        ("apply", apply, "write the keys now, whatever the switch says"),
        ("revert", revert, "put the recorded keys back now"),
    ):
        p = gsub.add_parser(name, help=h)
        p.set_defaults(fn=runner(fn))

    p = gsub.add_parser("status", help="the switch, whether it's applied, the current values")
    p.add_argument("--json", action="store_true")

    def _status(ctx, a):
        s = status(Path(state_dir_of(ctx)))
        if a.json:
            print(json.dumps(s))
        else:
            for k, v in s.items():
                print(f"{k}: {v}")

    p.set_defaults(fn=_status)
