"""Loft's keyboard shortcuts in a Plasma session (docs/KWIN.md §4, §5): the niri
binds in niri/shell-binds.kdl.in, plus the user's changes from Settings →
Keyboard Shortcuts (<state>/overrides/niri.json, loft-niri's shortcuts.rs),
turned into a KWin script that registers one kglobalaccel shortcut per action.

KWin scripts can't run processes, so a shortcut's callback asks the user's
systemd to start `loft-plasma-key@<id>:<n>.service` (StartUnit over D-Bus, a
fresh instance per press so quick repeats aren't merged into one job). That
template unit runs `<out>/actions/<id>`, a shell script with the bind's
command. Actions niri does itself (toggle-overview, fullscreen-window,
close-window) become KWin calls inside the script.

The script and its shortcuts exist only while Loft's shell runs: the
loft-plasma-shell unit loads it after start and, on stop, unloads it and
unregisters every name in <out>/names from kglobalaccel, so kglobalshortcutsrc
keeps nothing of Loft's.

  loft keys kwin render --binds RENDERED.kdl --out DIR [--overrides niri.json]
  loft keys kwin claim --names DIR/names     take Loft's keys off other shortcuts
  loft keys kwin release                     give them back

Mod and Super are both Meta here: the KWin session has no ISO_Level3_Shift
window-manager key (niri/base.kdl `mod-key`). The keyboard layer makes the
WM key (Caps Lock / Esc / Right Ctrl held) send Meta in Plasma instead
(keys.py, LOFT_WM_KEY=meta), so the same physical keys reach these shortcuts.
"""

from __future__ import annotations

import json
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path

SCRIPT_NAME = "loft-keys"
UNIT_PREFIX = "loft-plasma-key@"
# KWin's own action names (kglobalaccel component "kwin").
KWIN_CLOSE = "Window Close"
KWIN_OVERVIEW = "Overview"

# niri modifier → Qt. Qt's portable text orders them Meta, Ctrl, Alt, Shift.
QT_MODS = {
    "mod": "Meta",
    "super": "Meta",
    "win": "Meta",
    "iso_level3_shift": "Meta",
    "mod5": "Meta",
    "ctrl": "Ctrl",
    "control": "Ctrl",
    "alt": "Alt",
    "shift": "Shift",
}
QT_MOD_ORDER = ["Meta", "Ctrl", "Alt", "Shift"]

# xkb keysym names (as niri takes them, case-insensitive) → QKeySequence
# portable text. Qt's xkb table (qxkbcommon.cpp) maps XF86LaunchA to
# Key_LaunchA, whose name is "Launch (A)".
QT_KEYS = {
    "period": ".",
    "comma": ",",
    "slash": "/",
    "backslash": "\\",
    "semicolon": ";",
    "apostrophe": "'",
    "grave": "`",
    "minus": "-",
    "equal": "=",
    "bracketleft": "[",
    "bracketright": "]",
    "space": "Space",
    "tab": "Tab",
    "escape": "Esc",
    "return": "Return",
    "backspace": "Backspace",
    "delete": "Del",
    "insert": "Ins",
    "home": "Home",
    "end": "End",
    "page_up": "PgUp",
    "prior": "PgUp",
    "page_down": "PgDown",
    "next": "PgDown",
    "left": "Left",
    "right": "Right",
    "up": "Up",
    "down": "Down",
    "print": "Print",
    "pause": "Pause",
    "menu": "Menu",
    "xf86monbrightnessup": "Monitor Brightness Up",
    "xf86monbrightnessdown": "Monitor Brightness Down",
    "xf86audioraisevolume": "Volume Up",
    "xf86audiolowervolume": "Volume Down",
    "xf86audiomute": "Volume Mute",
    "xf86audiomicmute": "Microphone Mute",
    "xf86audioplay": "Media Play",
    "xf86audiopause": "Media Pause",
    "xf86audiostop": "Media Stop",
    "xf86audionext": "Media Next",
    "xf86audioprev": "Media Previous",
    **{f"xf86launch{c.lower()}": f"Launch ({c})" for c in "0123456789ABCDEF"},
    **{f"f{n}": f"F{n}" for n in range(1, 36)},
}


# Shift + a key that types another symbol: KWin matches the shifted symbol
# without Shift (checked with KWin 6.8: Mod+Shift+5 fires `Meta+%`, never
# `Meta+Shift+5`; Mod+Shift+Period fires `Meta+>`). Letters keep Shift. This
# is the US layout, as niri's keysyms in shell-binds assume.
QT_SHIFTED = {
    "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
    ".": ">", ",": "<", "/": "?", ";": ":", "'": '"', "`": "~", "-": "_", "=": "+", "[": "{", "]": "}",
    "\\": "|",
}


class KwinKeysError(Exception):
    pass


@dataclass
class Bind:
    combo: str
    action: str
    args: list = field(default_factory=list)
    title: str | None = None
    origin: str = "shell-binds"


@dataclass
class Action:
    id: str
    keys: str
    text: str
    # "exec": run `command` through the template unit; "kwin": `js` in the script.
    kind: str
    command: list[str] | None = None
    js: str | None = None
    combo: str = ""


# ── KDL (the subset shell-binds uses: one bind per line) ────────────────

_TOKEN = re.compile(r'\s*(?:(?P<str>"(?:[^"\\]|\\.)*")|(?P<word>[^\s;"=]+(?:=(?:"(?:[^"\\]|\\.)*"|[^\s;]+))?)|(?P<semi>;))')
_ESC = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "/": "/"}


def _unquote(s: str) -> str:
    return re.sub(r"\\(.)", lambda m: _ESC.get(m.group(1), m.group(1)), s[1:-1])


def _value(v: str):
    if v.startswith('"'):
        return _unquote(v)
    if v in ("null", "#null"):
        return None
    if v in ("true", "#true"):
        return True
    if v in ("false", "#false"):
        return False
    try:
        return int(v)
    except ValueError:
        return v


def _tokens(text: str) -> list[tuple[str, str]]:
    out, pos = [], 0
    text = text.rstrip()
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m or m.end() == pos:
            raise KwinKeysError(f"can't parse {text[pos:]!r}")
        pos = m.end()
        kind = m.lastgroup or ""
        out.append((kind, m.group(kind) or ""))
    return out


_BIND_LINE = re.compile(r"^\s*(?P<combo>[A-Za-z0-9_+]+)(?P<props>[^{]*)\{(?P<body>.*)\}\s*$")


def parse_binds(text: str) -> list[Bind]:
    """The binds in the top-level `binds { }` section (not recent-windows)."""
    binds: list[Bind] = []
    inside = False
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("//", 1)[0] if not raw.lstrip().startswith("//") else ""
        stripped = line.strip()
        if not inside:
            if re.match(r"^binds\s*\{\s*$", line.rstrip()):
                inside = True
            continue
        if stripped == "}":
            inside = False
            continue
        if not stripped:
            continue
        # Comments after the body would be cut above; `//` inside a string
        # (a URL) is not expected in shell-binds.
        m = _BIND_LINE.match(raw)
        if not m:
            raise KwinKeysError(f"line {n}: not a one-line bind: {raw.strip()!r}")
        title = None
        for kind, tok in _tokens(m.group("props")):
            if kind == "word" and "=" in tok:
                k, v = tok.split("=", 1)
                if k == "hotkey-overlay-title":
                    v = _value(v)
                    title = v if isinstance(v, str) else None
        body = [t for t in _tokens(m.group("body"))]
        words = [(k, t) for k, t in body if k != "semi"]
        if not words:
            raise KwinKeysError(f"line {n}: empty action")
        action = words[0][1]
        args = [_value(t) for k, t in words[1:] if not (k == "word" and "=" in t)]
        binds.append(Bind(combo=m.group("combo"), action=action, args=args, title=title))
    return binds


# ── Runtime changes (loft-niri's overrides) ─────────────────────────────


def _norm(combo: str) -> str:
    """Order- and case-insensitive key for matching niri combos."""
    *mods, key = combo.split("+")
    return "+".join(sorted(m.lower() for m in mods) + [key.lower()])


def apply_overrides(binds: list[Bind], overrides: dict) -> list[Bind]:
    """Settings → Keyboard Shortcuts on top: a `disabled` key loses its bind, an
    action record (custom, or a moved default) replaces or adds one, `off`
    records are skipped. Records for keys Loft doesn't bind (niri's own binds
    in base.kdl) only matter when they carry an action."""
    recs = overrides.get("binds") if isinstance(overrides, dict) else None
    if not isinstance(recs, dict):
        return list(binds)
    out = {_norm(b.combo): b for b in binds}
    order = [_norm(b.combo) for b in binds]
    for combo, r in recs.items():
        if not isinstance(r, dict):
            continue
        k = _norm(combo)
        if r.get("disabled"):
            out.pop(k, None)
            continue
        if r.get("off") or not isinstance(r.get("action"), str):
            continue
        args = r.get("args")
        args = args if isinstance(args, list) else []
        title = r.get("title")
        title = title if isinstance(title, str) else None
        if k not in out:
            order.append(k)
        out[k] = Bind(combo=combo, action=r["action"], args=list(args), title=title, origin="overrides")
    return [out[k] for k in order if k in out]


# ── Translation ─────────────────────────────────────────────────────────


def qt_keys(combo: str) -> str | None:
    """`Mod+Shift+R` → `Meta+Shift+R` (QKeySequence portable text), None when
    the key has no Qt name here (mouse/wheel triggers, unknown keysyms)."""
    *mods, key = combo.split("+")
    qmods = set()
    for m in mods:
        q = QT_MODS.get(m.strip().lower())
        if q is None:
            return None
        qmods.add(q)
    k = key.strip()
    if len(k) == 1 and k.isalnum():
        qk = k.upper()
    else:
        qk = QT_KEYS.get(k.lower())
        if qk is None:
            return None
    if "Shift" in qmods and qk in QT_SHIFTED:
        qmods.discard("Shift")
        qk = QT_SHIFTED[qk]
    return "+".join([m for m in QT_MOD_ORDER if m in qmods] + [qk])


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:48] or "action"


def _ipc_args(args: list) -> list[str] | None:
    """The `<target> <function> [args]` of a `quickshell ipc … call` command."""
    for i, a in enumerate(args):
        if a == "call" and i > 0 and "ipc" in args[:i]:
            return [str(x) for x in args[i + 1 :]]
    return None


def _base_id(b: Bind) -> str:
    if b.action == "spawn":
        ipc = _ipc_args(b.args)
        if b.args and b.args[0] == "sh" and "loft-quit" in b.args:
            return "quit"
        if ipc and b.origin == "spaces":
            return _slug("-".join(ipc))  # spaces-focus-3, spaces-movewindow-3
        if ipc:
            return _slug("-".join(ipc[:2]))
        if b.args and str(b.args[0]).endswith("loft-launcher"):
            return _slug("launcher-" + "-".join(str(a) for a in b.args[1:2]))
        if b.title:
            return _slug(b.title)
        return _slug(Path(str(b.args[0])).name if b.args else "spawn")
    return _slug(b.action)


# niri's `close-window` fallback in the quit guard, as KWin's.
_NIRI_CLOSE = "niri msg action close-window"
_KWIN_CLOSE_SH = f"qdbus org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut {shlex.quote(KWIN_CLOSE)}"


def _command(b: Bind) -> list[str]:
    return [str(a).replace(_NIRI_CLOSE, _KWIN_CLOSE_SH) for a in b.args]


def _kwin_js(action: str) -> str | None:
    if action == "toggle-overview":
        return f'loftKwin("{KWIN_OVERVIEW}");'
    if action == "fullscreen-window":
        return "var w = workspace.activeWindow; if (w) w.fullScreen = !w.fullScreen;"
    if action == "close-window":
        return "var w = workspace.activeWindow; if (w) w.closeWindow();"
    return None


def translate(binds: list[Bind]) -> tuple[list[Action], list[str]]:
    """(actions, skipped reasons). Binds whose keys collapse to the same Qt
    sequence (Mod+Space and Super+Space are both Meta+Space) keep the first."""
    actions: list[Action] = []
    skipped: list[str] = []
    seen_keys: dict[str, str] = {}
    ids: set[str] = set()
    # Titles by command, so a `hotkey-overlay-title=null` twin is named too.
    titles: dict[str, str] = {}
    for b in binds:
        if b.title:
            titles.setdefault(json.dumps([b.action, b.args]), b.title)
    for b in binds:
        keys = qt_keys(b.combo)
        if keys is None:
            skipped.append(f"{b.combo}: no Qt key name")
            continue
        if keys in seen_keys:
            if seen_keys[keys] != b.combo:
                skipped.append(f"{b.combo}: same key as {seen_keys[keys]} here ({keys})")
            continue
        if b.action == "spawn":
            if not b.args:
                skipped.append(f"{b.combo}: spawn without a command")
                continue
            kind, command, js = "exec", _command(b), None
        else:
            js = _kwin_js(b.action)
            if js is None:
                skipped.append(f"{b.combo}: niri action `{b.action}` has no KWin counterpart")
                continue
            kind, command = "kwin", None
        base = _base_id(b)
        aid, n = base, 2
        while aid in ids:
            aid, n = f"{base}-{n}", n + 1
        ids.add(aid)
        seen_keys[keys] = b.combo
        title = b.title or titles.get(json.dumps([b.action, b.args])) or aid
        actions.append(Action(id=aid, keys=keys, text=f"Loft: {title}", kind=kind, command=command, js=js, combo=b.combo))
    return actions, skipped


# ── Output ──────────────────────────────────────────────────────────────


def _js_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def render_js(actions: list[Action]) -> str:
    lines = [
        "// Loft's shortcuts in a Plasma session. Generated by `loft keys kwin`",
        "// (cli/loft/kwinkeys.py) from niri/shell-binds.kdl.in and Settings →",
        "// Keyboard Shortcuts; loaded by loft-plasma-shell.service while Loft runs.",
        "// KWin scripts can't run processes: the user's systemd runs the command",
        f"// (`{UNIT_PREFIX}<id>:<n>.service`, a new instance per press).",
        "var loftSeq = Date.now() % 1000000;",
        "function loftRun(id) {",
        "    loftSeq += 1;",
        '    callDBus("org.freedesktop.systemd1", "/org/freedesktop/systemd1",',
        '        "org.freedesktop.systemd1.Manager", "StartUnit",',
        f'        {_js_str(UNIT_PREFIX)} + id + ":" + loftSeq + ".service", "replace");',
        "}",
        "function loftKwin(name) {",
        '    callDBus("org.kde.kglobalaccel", "/component/kwin",',
        '        "org.kde.kglobalaccel.Component", "invokeShortcut", name);',
        "}",
    ]
    for a in actions:
        body = f"loftRun({_js_str(a.id)});" if a.kind == "exec" else a.js
        lines.append(
            f"registerShortcut({_js_str(name_of(a))}, {_js_str(a.text)}, {_js_str(a.keys)}, function () {{ {body} }});"
        )
    return "\n".join(lines) + "\n"


def name_of(a: Action) -> str:
    """The kglobalaccel action name (component "kwin")."""
    return f"loft-{a.id}"


def write(out: Path, actions: list[Action]) -> None:
    """<out>/loft-keys.js, <out>/actions/<id> (the commands), <out>/names (to
    unregister on stop), <out>/actions.json (for people and tests)."""
    out.mkdir(parents=True, exist_ok=True)
    adir = out / "actions"
    adir.mkdir(exist_ok=True)
    for old in adir.iterdir():
        old.unlink()
    for a in actions:
        if a.kind == "exec" and a.command:
            (adir / a.id).write_text("exec " + shlex.join(a.command) + "\n")
    (out / f"{SCRIPT_NAME}.js").write_text(render_js(actions))
    (out / "names").write_text("".join(name_of(a) + "\n" for a in actions))
    (out / "actions.json").write_text(
        json.dumps(
            [{"id": a.id, "name": name_of(a), "keys": a.keys, "from": a.combo, "text": a.text, "kind": a.kind,
              "command": a.command} for a in actions],
            indent=2,
            ensure_ascii=False,
        )
        + "\n"
    )


# Spaces under KWin are the user's KDE Activities (docs/KWIN.md §4.2), and
# KDE's own keys for them stay KDE's: Meta+1…9/0 are kactivitymanagerd's
# "Switch to activity" shortcuts, Meta+Ctrl+←/→ (what ⌃←/→ sends through the
# keyboard layer) KWin's "Switch One Desktop to the Left/Right" — the virtual
# desktops inside the Activity, as ⌃←/→ steps Spaces on macOS. So Loft binds
# neither here, and never takes a key from these components.
KDE_OWNED_IPC = (["spaces", "prev"], ["spaces", "next"])
PROTECTED_COMPONENTS = {"ActivityManager"}
# Loft actions that give their key up when another action has it, instead of
# taking it: ⌘⇧N (move to Space N) is only Loft's where KDE binds nothing.
YIELD_PREFIXES = ("loft-spaces-movewindow-",)


def space_binds(binds: list[Bind]) -> list[Bind]:
    """Spaces under KWin (docs/KWIN.md §4.2): niri gets Mod+1…9 / Mod+Shift+1…9
    from loft-niri's spaces.kdl, which KWin never sees. Here Mod+1…9 (switch)
    stay KDE's own "Switch to activity" shortcuts; only Mod+Shift+1…9, 0 go to
    the shell (`spaces moveWindow N`: the Space whose KDE key is Meta+N), with
    the IPC command of shell-binds' own `spaces` binds. Each yields to a KDE
    action that has the same key (`claim`)."""
    proto = next((b for b in binds if b.action == "spawn" and (_ipc_args(b.args) or [""])[0] == "spaces"), None)
    if proto is None:
        return []
    ipc = _ipc_args(proto.args) or []
    prefix = proto.args[: len(proto.args) - len(ipc)]
    return [
        Bind(combo=f"Mod+Shift+{n}", action="spawn", args=[*prefix, "spaces", "moveWindow", str(n)],
             title=f"Move Window to Space {n}", origin="spaces")
        for n in [*range(1, 10), 0]
    ]


def kde_owned(b: Bind) -> bool:
    """A shell bind that KDE does itself under KWin (⌃←/→: desktops)."""
    ipc = _ipc_args(b.args) if b.action == "spawn" else None
    return bool(ipc) and any(ipc[: len(k)] == list(k) for k in KDE_OWNED_IPC)


def build(binds_text: str, overrides: dict | None = None) -> tuple[list[Action], list[str]]:
    binds = parse_binds(binds_text)
    kde = [f"{b.combo}: KDE's own here (desktops inside the Activity)" for b in binds if kde_owned(b)]
    binds = [b for b in binds if not kde_owned(b)]
    # After shell-binds, before the user's changes: a moved or disabled key wins.
    binds = binds + space_binds(binds)
    if overrides:
        binds = apply_overrides(binds, overrides)
    actions, skipped = translate(binds)
    return actions, kde + skipped


# ── Keys other actions hold (record + revert) ───────────────────────────
#
# kglobalaccel accepts a key that another action already has, and then the
# other one wins (checked with KWin 6.8: Meta+I opened System Settings, not
# the Island). So while Loft runs, the keys it binds are taken off their other
# owners (KWin's Walk Through Windows, Window Close, Switch One Desktop…,
# plasmashell, System Settings, emojier …) and given back when it stops. The
# record lives in Loft's state dir, not the runtime dir, so a session that
# ended without a stop job is still put right at the next start (of Loft's
# shell or of plasmashell).

KGA = "org.kde.kglobalaccel"
KGA_IFACE = "org.kde.KGlobalAccel"
COMP_IFACE = "org.kde.kglobalaccel.Component"


class Busctl:
    """kglobalaccel over `busctl` (the session bus, or --address)."""

    def __init__(self, address: str | None = None, busctl: str = "busctl"):
        self.base = [busctl, f"--address={address}"] if address else [busctl, "--user"]

    def _call(self, path: str, iface: str, method: str, *sig_args: str):
        import subprocess

        out = subprocess.run(
            [*self.base, "--json=short", "call", KGA, path, iface, method, *sig_args],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        return json.loads(out)["data"] if out else None

    def components(self) -> list[str]:
        return list(self._call("/kglobalaccel", KGA_IFACE, "allComponents")[0])

    def infos(self, path: str) -> list[list]:
        """(action, actionFriendly, component, componentFriendly, context,
        contextFriendly, keys, defaultKeys) per action."""
        return [list(i) for i in self._call(path, COMP_IFACE, "allShortcutInfos")[0]]

    def keys(self, action_id: list[str]) -> list[list[int]]:
        """The action's key sequences, each as its keys (a QKeySequence comes
        as four ints, 0 past its length)."""
        raw = self._call("/kglobalaccel", KGA_IFACE, "shortcutKeys", "as", str(len(action_id)), *action_id)[0]
        out = []
        for seq in raw:
            seq = seq[0] if seq and isinstance(seq[0], list) else seq
            ks = [int(k) for k in seq if int(k)]
            if ks:
                out.append(ks)
        return out

    def set_foreign(self, action_id: list[str], keys: list[list[int]]) -> None:
        args = ["asa(ai)", str(len(action_id)), *action_id, str(len(keys))]
        for k in keys:
            args += [str(len(k)), *map(str, k)]
        self._call("/kglobalaccel", KGA_IFACE, "setForeignShortcutKeys", *args)


def _read_record(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    return [r for r in data if isinstance(r, dict) and isinstance(r.get("id"), list)] if isinstance(data, list) else []


def give_back_protected(bus, record: Path) -> list[dict]:
    """Older Loft builds took KDE's activity keys (ActivityManager's "Switch to
    activity …") for their own Spaces: give those back and drop them from the
    record, so the next release can't take them away again either."""
    taken = _read_record(record)
    back = [t for t in taken if t["id"][0] in PROTECTED_COMPONENTS]
    if not back:
        return []
    for t in back:
        try:
            bus.set_foreign(t["id"], [list(k) for k in t.get("keys", [])])
        except Exception as e:  # keep going: the others must get theirs
            print(f"loft keys kwin: couldn't give {t['id'][:2]} its keys back: {e}")
    rest = [t for t in taken if t["id"][0] not in PROTECTED_COMPONENTS]
    if rest:
        record.write_text(json.dumps(rest, indent=2) + "\n")
    elif record.exists():
        record.unlink()
    return back


def _is_default_context(r) -> bool:
    return r[4] in ("", "default")


def claim(bus, names: set[str], record: Path) -> list[dict]:
    """Take Loft's keys (those of the `kwin` actions in `names`) off every
    other action that has one; append what was taken to `record` (an action
    already in it keeps its first, original keys). Returns the new entries.

    Never from PROTECTED_COMPONENTS (KDE's Activities): a key one of those
    has stays theirs (and KDE's action wins it). A Loft action in
    YIELD_PREFIXES whose key another action has gives its key up instead."""
    give_back_protected(bus, record)
    infos = {path: bus.infos(path) for path in bus.components()}
    rows = [r for rs in infos.values() for r in rs]
    is_ours = lambda r: r[2] == "kwin" and r[0] in names  # noqa: E731
    held: set[int] = {int(k) for r in rows if not is_ours(r) and _is_default_context(r) for k in r[6] if int(k)}
    kde: set[int] = {int(k) for r in rows if r[2] in PROTECTED_COMPONENTS for k in r[6] if int(k)}
    ours: set[int] = set()
    for r in rows:
        if not is_ours(r):
            continue
        keys = {int(k) for k in r[6] if int(k)}
        if r[0].startswith(YIELD_PREFIXES) and keys & held:
            bus.set_foreign([r[2], r[0], r[3], r[1]], [])
            print(f"left {r[1]} without a key: another shortcut has it")
            continue
        ours.update(keys - kde)
    taken = _read_record(record)
    known = {tuple(t["id"][:2]) for t in taken}
    new: list[dict] = []
    for r in rows:
        action, friendly, comp, comp_friendly = r[0], r[1], r[2], r[3]
        if is_ours(r) or comp in PROTECTED_COMPONENTS or not ours.intersection(int(k) for k in r[6]):
            continue
        if not _is_default_context(r):
            continue
        aid = [comp, action, comp_friendly, friendly]
        keys = bus.keys(aid)
        keep = [k for k in keys if not (len(k) == 1 and k[0] in ours)]
        entry = {"id": aid, "keys": keys}
        if tuple(aid[:2]) not in known:
            taken.append(entry)
            known.add(tuple(aid[:2]))
        new.append(entry)
        bus.set_foreign(aid, keep)
    if new:
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(json.dumps(taken, indent=2) + "\n")
    return new


def release(bus, record: Path) -> list[dict]:
    """Give the recorded keys back, then forget the record."""
    taken = _read_record(record)
    done = []
    for t in taken:
        try:
            bus.set_foreign(t["id"], [list(k) for k in t.get("keys", [])])
            done.append(t)
        except Exception as e:  # one stale action must not keep the others' keys
            print(f"loft keys kwin: couldn't give {t['id'][:2]} its keys back: {e}")
    if record.exists():
        record.unlink()
    return done


def add_parser(sub, state_dir_of) -> None:
    k = sub.add_parser("kwin", help="Loft's shortcuts in a Plasma session: the KWin script, and the keys it takes (docs/KWIN.md)")
    ksub = k.add_subparsers(dest="kwin_cmd", required=True)

    def record_of(ctx, a) -> Path:
        return Path(a.record) if a.record else Path(state_dir_of(ctx)) / "kwin-shortcuts-taken.json"

    s = ksub.add_parser("render", help="write loft-keys.js, actions/, names into a directory")
    s.add_argument("--binds", required=True, help="the rendered shell-binds KDL (IPC command filled in)")
    s.add_argument("--out", required=True)
    s.add_argument("--overrides", help="loft-niri's overrides (default <state>/overrides/niri.json)")

    def _render(ctx, a):
        ov_path = Path(a.overrides) if a.overrides else Path(state_dir_of(ctx)) / "overrides" / "niri.json"
        overrides = {}
        if ov_path.exists():
            try:
                overrides = json.loads(ov_path.read_text())
            except (OSError, json.JSONDecodeError) as e:
                print(f"loft keys kwin: ignoring {ov_path}: {e}")
        actions, skipped = build(Path(a.binds).read_text(), overrides)
        write(Path(a.out), actions)
        print(f"{len(actions)} shortcuts → {Path(a.out) / (SCRIPT_NAME + '.js')}")
        for s_ in skipped:
            print(f"  skipped {s_}")

    s.set_defaults(fn=_render)

    s = ksub.add_parser("claim", help="take Loft's keys off the other shortcuts that have them (recorded)")
    s.add_argument("--names", required=True, help="the names file `render` wrote")
    s.add_argument("--record", help="default <state>/kwin-shortcuts-taken.json")
    s.add_argument("--address", help="D-Bus address (default: the session bus)")

    def _claim(ctx, a):
        names = {n.strip() for n in Path(a.names).read_text().splitlines() if n.strip()}
        for t in claim(Busctl(a.address), names, record_of(ctx, a)):
            print(f"took {t['id'][2]} / {t['id'][3]} ({t['id'][0]})")

    s.set_defaults(fn=_claim)

    s = ksub.add_parser("release", help="give the keys `claim` took back")
    s.add_argument("--record", help="default <state>/kwin-shortcuts-taken.json")
    s.add_argument("--address", help="D-Bus address (default: the session bus)")

    def _release(ctx, a):
        for t in release(Busctl(a.address), record_of(ctx, a)):
            print(f"gave back {t['id'][2]} / {t['id'][3]} ({t['id'][0]})")

    s.set_defaults(fn=_release)
