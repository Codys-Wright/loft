"""Loft's idle settings under KDE (docs/KWIN.md §4.20).

Under niri, swayidle does Loft's idle (lock, displays off; programs.loft.idle).
Under KWin, idle is Plasma's: kscreenlocker (inside KWin) locks, PowerDevil
turns the displays off and suspends. So while Loft is the shell of a Plasma
session, Loft's settings (Settings → Lock & Sleep, else
programs.loft.idle, else the defaults below) are written into their config:

  ~/.config/kscreenlockerrc
    [Daemon] Autolock         lock after idle at all
             Timeout          minutes (a double: 0.5 = 30 s)
             Lock             true (Autolock locks, not only blanks)
             LockGrace        seconds after the lock that a key / move unlocks
             LockOnResume     lock before sleep
  ~/.config/powerdevilrc, for each profile [AC] [Battery] [LowBattery]
    [<p>][Display] TurnOffDisplayWhenIdle, TurnOffDisplayIdleTimeoutSec
    [<p>][SuspendAndShutdown] AutoSuspendAction (1 = sleep, 0 = nothing),
                              AutoSuspendIdleTimeoutSec

then kscreenlocker re-reads its file (org.kde.screensaver.configure on
org.freedesktop.ScreenSaver /ScreenSaver) and PowerDevil reloads its profile
(org.kde.Solid.PowerManagement.refreshStatus). Both apply live.

Record and revert as for the global Qt style (qtglobal.py): <state>/kde-idle.prev
holds, per key, the user's own value (null = not in the file) and Loft's.
`revert` gives a key back only while it still holds Loft's value, then
forgets the record. The shell applies (at start and on every change, under
KWin only); loft-plasma-shell's ExecStopPost and plasmashell's ExecStartPre
revert, so a plain Plasma session gets the user's KDE values back.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from . import qtapps
from .qtapps import ini_get, ini_set
from .qtglobal import _read, _write, ini_delete

RECORD = "kde-idle.prev"
PROFILES = ("AC", "Battery", "LowBattery")
FILES = ("kscreenlockerrc", "powerdevilrc")

# Loft's own defaults: what swayidle does under niri with programs.loft.idle's
# defaults (lock after 5 min, displays off after 10), no idle suspend (swayidle
# has none), always lock before sleep (its before-sleep), and KDE's grace.
DEFAULTS = {"lockAfter": 300, "screenOffAfter": 600, "suspendAfter": 0, "lockOnResume": True, "lockGrace": 5}
# KDE's own defaults (kscreenlockersettings.kcfg; PowerDevil 6's
# powerdevilsettingsdefaults.cpp for AC on a desktop that can suspend), for
# reading back a file that doesn't set a key.
KDE_DEFAULTS = {"Autolock": "true", "Timeout": "5", "LockGrace": "5", "LockOnResume": "true",
                "TurnOffDisplayWhenIdle": "true", "TurnOffDisplayIdleTimeoutSec": "600",
                "AutoSuspendAction": "1", "AutoSuspendIdleTimeoutSec": "900"}


def config_file(name: str) -> Path:
    return qtapps.config_home() / name


def defaults_file() -> Path:
    """programs.loft.idle, written by the home-manager module."""
    return qtapps.config_home() / "loft" / "idle.json"


def shell_overrides(state_dir: Path) -> Path:
    return Path(state_dir) / "overrides" / "shell.json"


def _load(path: Path) -> dict:
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def _seconds(v) -> int | None:
    """A timing from a layer: an int ≥ 0 (0 = never), null = never (Nix);
    None for 'not set here' (missing, -1, junk)."""
    if v is None:
        return 0
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return int(v) if v >= 0 else None


def settings(state_dir: Path, given: dict | None = None) -> dict:
    """The effective settings: built-in < programs.loft.idle (idle.json) <
    Settings (shell.json's "idle") < `given` (what the shell passes, the
    same shape as shell.json's "idle"). Timings in seconds, 0 = never."""
    out = dict(DEFAULTS)
    nix = _load(defaults_file())
    for k in ("lockAfter", "screenOffAfter", "suspendAfter"):
        if k in nix and (s := _seconds(nix[k])) is not None:
            out[k] = s
    layers = [_load(shell_overrides(state_dir)).get("idle")]
    if given is not None:
        layers.append(given)
    for layer in layers:
        if not isinstance(layer, dict):
            continue
        for k in ("lockAfter", "screenOffAfter", "suspendAfter", "lockGrace"):
            if k in layer and layer[k] is not None and (s := _seconds(layer[k])) is not None:
                out[k] = s
        v = layer.get("lockOnResume")
        if isinstance(v, bool):
            out["lockOnResume"] = v
        elif isinstance(v, int) and v in (0, 1):
            out["lockOnResume"] = bool(v)
    return out


def _bool(b: bool) -> str:
    return "true" if b else "false"


def _minutes(seconds: int) -> str:
    m = seconds / 60
    return str(int(m)) if m == int(m) else f"{m:.4f}".rstrip("0")


def wanted(s: dict) -> dict[str, list[tuple[str, str, str]]]:
    """{file: [(group, key, value)]} for the effective settings `s`."""
    lock: list[tuple[str, str, str]] = [("Daemon", "Autolock", _bool(s["lockAfter"] > 0))]
    if s["lockAfter"] > 0:
        lock += [("Daemon", "Timeout", _minutes(s["lockAfter"])), ("Daemon", "Lock", "true")]
    lock += [("Daemon", "LockGrace", str(s["lockGrace"])), ("Daemon", "LockOnResume", _bool(s["lockOnResume"]))]
    power: list[tuple[str, str, str]] = []
    for p in PROFILES:
        power.append((f"{p}][Display", "TurnOffDisplayWhenIdle", _bool(s["screenOffAfter"] > 0)))
        if s["screenOffAfter"] > 0:
            power.append((f"{p}][Display", "TurnOffDisplayIdleTimeoutSec", str(s["screenOffAfter"])))
        power.append((f"{p}][SuspendAndShutdown", "AutoSuspendAction", "1" if s["suspendAfter"] > 0 else "0"))
        if s["suspendAfter"] > 0:
            power.append((f"{p}][SuspendAndShutdown", "AutoSuspendIdleTimeoutSec", str(s["suspendAfter"])))
    return {"kscreenlockerrc": lock, "powerdevilrc": power}


def _record_path(state_dir: Path) -> Path:
    return Path(state_dir) / RECORD


def read_record(state_dir: Path) -> dict:
    return _load(_record_path(state_dir))


# ── apply / revert ──────────────────────────────────────────────────────────


def apply(state_dir: Path, given: dict | None = None) -> list[str]:
    """Write Loft's settings into KDE's files, recording what was there."""
    s = settings(state_dir, given)
    rec = read_record(state_dir)
    notes: list[str] = []
    changed: set[str] = set()
    for name, entries in wanted(s).items():
        path = config_file(name)
        text = before = _read(path)
        keys = rec.setdefault(name, {})
        n = 0
        for group, key, value in entries:
            have = ini_get(text, group, key)
            slot = f"{group}\x1f{key}"
            r = keys.get(slot)
            # First time, or someone else wrote the key since Loft did (System
            # Settings while Loft ran): that is what revert gives back.
            if r is None or have != r.get("ours"):
                keys[slot] = {"prev": have, "ours": value}
            else:
                r["ours"] = value
            if have != value:
                text = ini_set(text, group, key, value)
                n += 1
        if text != before:
            _write(path, text)
            changed.add(name)
            notes.append(f"{path}: {n} keys")
    _record_path(state_dir).parent.mkdir(parents=True, exist_ok=True)
    _write(_record_path(state_dir), json.dumps(rec, indent=1, sort_keys=True) + "\n")
    notes += notify(changed)
    return notes


def revert(state_dir: Path) -> list[str]:
    """Put the recorded keys back (those still Loft's), then forget the record."""
    rec = read_record(state_dir)
    if not rec:
        return []
    notes: list[str] = []
    changed: set[str] = set()
    for name, keys in rec.items():
        if name not in FILES or not isinstance(keys, dict):
            continue
        path = config_file(name)
        text = before = _read(path)
        n = 0
        for slot, r in keys.items():
            group, _, key = slot.partition("\x1f")
            if not isinstance(r, dict) or ini_get(text, group, key) != r.get("ours"):
                continue
            prev = r.get("prev")
            text = ini_delete(text, group, key) if prev is None else ini_set(text, group, key, prev)
            n += 1
        if text != before:
            if text or path.exists():
                _write(path, text)
            changed.add(name)
            notes.append(f"{path}: {n} keys back")
    _record_path(state_dir).unlink(missing_ok=True)
    notes += notify(changed)
    return notes


# ── telling kscreenlocker and PowerDevil ────────────────────────────────────

RELOAD = {
    # kscreenlocker (in KWin): KScreenSaverSettings::load(), new idle timeout.
    "kscreenlockerrc": ("org.freedesktop.ScreenSaver", "/ScreenSaver", "org.kde.screensaver", "configure"),
    # PowerDevil: reparseConfiguration() + loadProfile(force) (the KCM's call).
    "powerdevilrc": ("org.kde.Solid.PowerManagement", "/org/kde/Solid/PowerManagement", "org.kde.Solid.PowerManagement", "refreshStatus"),
}


def notify(files: set[str]) -> list[str]:
    """Ask the daemons whose files changed to re-read them. Quietly nothing
    without a session bus or the service (they read the file when they start)."""
    if os.environ.get("LOFT_IDLE_NO_NOTIFY") == "1":
        return []
    notes = []
    for name in sorted(files):
        service, path, iface, method = RELOAD[name]
        try:
            r = subprocess.run(["busctl", "--user", "--timeout=5", "call", service, path, iface, method],
                               capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError) as e:
            notes.append(f"{service}: not told ({e})")
            continue
        notes.append(f"{service}: reloaded" if r.returncode == 0 else f"{service}: not running ({r.stderr.strip() or r.returncode})")
    return notes


# ── reading back ────────────────────────────────────────────────────────────


def kde_values(profile: str = "AC") -> dict:
    """What KDE's files say now (KDE's defaults where a key isn't set), in
    Loft's terms."""
    lock = _read(config_file("kscreenlockerrc"))
    power = _read(config_file("powerdevilrc"))

    def get(text, group, key):
        v = ini_get(text, group, key)
        return KDE_DEFAULTS[key] if v is None else v

    def num(v, default=0.0):
        try:
            return float(v)
        except ValueError:
            return default

    autolock = get(lock, "Daemon", "Autolock") == "true"
    off = get(power, f"{profile}][Display", "TurnOffDisplayWhenIdle") == "true"
    suspend = get(power, f"{profile}][SuspendAndShutdown", "AutoSuspendAction") == "1"
    return {
        "lockAfter": round(num(get(lock, "Daemon", "Timeout")) * 60) if autolock else 0,
        "screenOffAfter": int(num(get(power, f"{profile}][Display", "TurnOffDisplayIdleTimeoutSec"))) if off else 0,
        "suspendAfter": int(num(get(power, f"{profile}][SuspendAndShutdown", "AutoSuspendIdleTimeoutSec"))) if suspend else 0,
        "lockOnResume": get(lock, "Daemon", "LockOnResume") == "true",
        "lockGrace": int(num(get(lock, "Daemon", "LockGrace"))),
    }


def status(state_dir: Path, given: dict | None = None) -> dict:
    s = settings(state_dir, given)
    kde = kde_values()
    return {"settings": s, "kde": kde, "matches": kde == s, "applied": bool(read_record(state_dir)),
            "defaults": str(defaults_file())}


def add_parser(top, state_dir_of) -> None:
    p = top.add_parser("idle", help="Loft's idle settings (lock, displays off, suspend) in KDE's kscreenlockerrc / powerdevilrc while Loft runs under Plasma (docs/KWIN.md §4.20)")
    sub = p.add_subparsers(dest="idle_cmd", required=True)

    def given_of(a):
        if not getattr(a, "settings", None):
            return None
        try:
            v = json.loads(a.settings)
        except ValueError as e:
            raise SystemExit(f"loft idle: --settings: {e}")
        return v if isinstance(v, dict) else None

    q = sub.add_parser("apply", help="write Loft's settings into KDE's files (recording KDE's) and reload kscreenlocker / PowerDevil")
    q.add_argument("--settings", help="the shell's Settings.idle as JSON (else shell.json's)")

    def _apply(ctx, a):
        for n in apply(Path(state_dir_of(ctx)), given_of(a)):
            print(n)

    q.set_defaults(fn=_apply)

    q = sub.add_parser("revert", help="give KDE's own values back (keys still Loft's) and forget the record")

    def _revert(ctx, a):
        for n in revert(Path(state_dir_of(ctx))):
            print(n)

    q.set_defaults(fn=_revert)

    q = sub.add_parser("status", help="Loft's effective settings and what KDE's files say")
    q.add_argument("--settings", help="the shell's Settings.idle as JSON")
    q.add_argument("--json", action="store_true")

    def _status(ctx, a):
        st = status(Path(state_dir_of(ctx)), given_of(a))
        if a.json:
            print(json.dumps(st))
        else:
            for k, v in st.items():
                print(f"{k}: {v}")

    q.set_defaults(fn=_status)
