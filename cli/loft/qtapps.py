"""Qt / KDE apps in the Loft look (programs.loft.qt; render unit `qt`).

What the `qt` hook does after `loft theme apply`, and `loft qt sync` on
demand. Nothing is global, and nothing happens unless home-manager wrote
~/.config/loft/qt.json (programs.loft.qt.enable):

  {"apps": ["dolphin"], "iconTheme": "MacTahoe-blue", "dolphinDefaults": true}

1. Links the rendered files in under stable names, pointing at
   <state>/current/… (so a theme switch re-points them for free):
     ~/.config/Kvantum/Loft/Loft.{kvconfig,svg}  → kvantum.{kvconfig,svg}
     ~/.local/share/color-schemes/Loft.colors   → kde.colors
   A real file of that name (not a symlink) is left alone.
2. Assigns the Kvantum theme `Loft` to the listed apps only:
   ~/.config/Kvantum/kvantum.kvconfig [Applications] Loft=dolphin. The global
   `theme=` (what every other Kvantum app uses) is not touched; a new file
   copies it from a system-wide kvantum.kvconfig, which the user file hides.
3. Writes targeted keys into each app's own rc file (kwriteconfig-style, the
   rest of the file is kept as it is):
     [KDE] widgetStyle=kvantum       KStyleManager reads it only when no KDE
                                     platform theme runs: under Plasma the
                                     app keeps Plasma's style
     [UiSettings] ColorScheme=Loft   KColorSchemeManager: the app palette and
                                     KColorScheme (Dolphin's view background)
     [Icons] Theme=<iconTheme>       when qt.json names one
   and, for Dolphin with dolphinDefaults, a few Finder-like defaults that are
   written only when the key is absent (a choice made in Dolphin wins).

Qt apps read all of this when they start: a running Dolphin keeps the old
look until it is restarted (Kvantum has no live reload, and without a KDE
platform theme nothing tells the app its color scheme changed).
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

THEME = "Loft"

# (group, key, value): written only when the key is absent.
DOLPHIN_DEFAULTS = (
    # Finder-sized sidebar icons.
    ("PlacesPanel", "IconSize", "16"),
    # Icon-only toolbar (Split, Search), like Finder's.
    ("MainWindow][Toolbar mainToolBar", "ToolButtonStyle", "IconOnly"),
    # Panels without title bars (Dolphin's default; kept explicit).
    ("General", "LockPanels", "true"),
)


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")


def data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")


def settings() -> dict | None:
    """~/.config/loft/qt.json, or None when Qt theming is off."""
    try:
        doc = json.loads((config_home() / "loft" / "qt.json").read_text())
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


# ── KConfig / QSettings INI, edited in place ────────────────────────────────

_GROUP = re.compile(r"^\s*\[(.*)\]\s*$")


def ini_get(text: str, group: str, key: str) -> str | None:
    cur = None
    for line in text.splitlines():
        m = _GROUP.match(line)
        if m:
            cur = m.group(1)
            continue
        if cur == group and "=" in line:
            k, v = line.split("=", 1)
            if k.strip() == key:
                return v.strip()
    return None


def ini_set(text: str, group: str, key: str, value: str) -> str:
    """`text` with group/key set to value: the existing line replaced, else
    the key appended to its group, else the group appended. Everything else
    (order, comments, other groups) stays byte for byte."""
    lines = text.splitlines()
    cur = None
    last_in_group = None  # index of the last non-blank line of `group`
    for i, line in enumerate(lines):
        m = _GROUP.match(line)
        if m:
            cur = m.group(1)
            if cur == group:
                last_in_group = i
            continue
        if cur == group:
            if line.strip():
                last_in_group = i
            if "=" in line and line.split("=", 1)[0].strip() == key:
                lines[i] = f"{key}={value}"
                return "\n".join(lines) + "\n"
    if last_in_group is not None:
        lines.insert(last_in_group + 1, f"{key}={value}")
    else:
        if lines and lines[-1].strip():
            lines.append("")
        lines += [f"[{group}]", f"{key}={value}"]
    return "\n".join(lines) + "\n"


def ini_update(path: Path, entries: list[tuple[str, str, str]], only_absent: bool = False) -> list[str]:
    """Apply (group, key, value) entries to the file at path (created when
    missing); returns the "group/key" names it changed. Written atomically,
    and only when something changed."""
    try:
        text = path.read_text()
    except FileNotFoundError:
        text = ""
    out, changed = text, []
    for group, key, value in entries:
        have = ini_get(out, group, key)
        if have == value or (only_absent and have is not None):
            continue
        out = ini_set(out, group, key, value)
        changed.append(f"{group}/{key}")
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.loft-tmp")
        tmp.write_text(out)
        tmp.replace(path)
    return changed


# ── the sync ────────────────────────────────────────────────────────────────


def _link(link: Path, target: Path) -> str | None:
    """Point link at target unless a real file sits there. Returns a note."""
    try:
        if link.is_symlink():
            if os.readlink(link) == str(target):
                return None
            link.unlink()
        elif link.exists():
            return f"left {link} alone (not a symlink)"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)
        return f"linked {link}"
    except OSError as e:
        return f"could not link {link}: {e}"


def _global_kvantum_theme() -> str | None:
    """`theme=` of the first system-wide kvantum.kvconfig (XDG_CONFIG_DIRS):
    what Kvantum used while the user had no file of their own."""
    for d in (os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":"):
        if not d:
            continue
        try:
            text = (Path(d) / "Kvantum" / "kvantum.kvconfig").read_text()
        except OSError:
            continue
        return ini_get(text, "General", "theme")
    return None


def sync(state_dir: Path, doc: dict | None = None) -> list[str]:
    """Steps 1-3 of the module docstring. Returns what it did (for `loft qt sync`)."""
    doc = settings() if doc is None else doc
    if doc is None:
        return []
    apps = [a for a in doc.get("apps") or ["dolphin"] if isinstance(a, str) and a]
    cur = Path(state_dir) / "current"
    cfg, data = config_home(), data_home()
    notes: list[str | None] = [
        _link(cfg / "Kvantum" / THEME / f"{THEME}.kvconfig", cur / "kvantum.kvconfig"),
        _link(cfg / "Kvantum" / THEME / f"{THEME}.svg", cur / "kvantum.svg"),
        _link(data / "color-schemes" / f"{THEME}.colors", cur / "kde.colors"),
    ]

    chooser = cfg / "Kvantum" / "kvantum.kvconfig"
    entries = [("Applications", THEME, ", ".join(apps))]
    if not chooser.exists():
        g = _global_kvantum_theme()
        if g:
            entries.insert(0, ("General", "theme", g))
    notes += [f"{chooser}: {k}" for k in ini_update(chooser, entries)]

    for app in apps:
        rc = cfg / f"{app}rc"
        keys = [("KDE", "widgetStyle", "kvantum"), ("UiSettings", "ColorScheme", THEME)]
        if doc.get("iconTheme"):
            keys.append(("Icons", "Theme", str(doc["iconTheme"])))
        notes += [f"{rc}: {k}" for k in ini_update(rc, keys)]
        if app == "dolphin" and doc.get("dolphinDefaults", True):
            notes += [f"{rc}: {k} (default)" for k in ini_update(rc, list(DOLPHIN_DEFAULTS), only_absent=True)]
    return [n for n in notes if n]
