"""The tools `loft mcp` serves (protocol: mcp.py).

- niri: read windows / workspaces / outputs; focus, move, float, fullscreen,
  maximize, column width, workspaces, overview, spawn — `niri msg` against
  $NIRI_SOCKET.
- screenshots: an output (grim -o) or a window (grim -g for a visible
  floating window, else niri's own render), PNG, downscaled to `max_width`.
- loft: window rules, themes, appearance, niri settings — the `loft` CLI in a
  subprocess (the same Python, the same --dev targeting).
- shell: Quickshell IPC to the running Loft shell, limited to SHELL_ALLOW.

Nothing here powers off, logs out, locks, kills processes or deletes data.
Every subprocess gets stdin=/dev/null and its own stdout pipe: the server's
stdin/stdout are the protocol channel.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from .mcp import Image, Tool, ToolError

INSTRUCTIONS = (
    "Controls Cody's Loft desktop (niri scrolling compositor + Quickshell shell). Window and "
    "workspace ids come from list_windows / list_workspaces; ids are stable while a window lives. "
    "Prefer these structured tools over pixel coordinates. Screenshots are PNGs scaled to "
    "max_width; the accompanying JSON gives the logical region they cover. Toggle actions "
    "(fullscreen_window, maximize_*) flip state: read list_windows first."
)

# Quickshell IPC the agent may call: target → functions. Left out on purpose:
# lock, systemmenu (restart / shut down / log out), quit, phone (calls, SMS),
# action (arbitrary Everyday actions), cleaning (blocks input), clipboard
# (contents, wipe), camera, capture, recorder, mic, audio, pwclock (live
# audio routing), and `enter` in the bar menus (it activates the item under
# the cursor: Lock Screen, Wi-Fi off …).
SHELL_ALLOW: dict[str, frozenset[str]] = {
    t: frozenset(fns.split())
    for t, fns in {
        "ai": "refresh",
        "alerts": "test",
        "appmenu": "toggle global close right left down up",
        "arrange": "open apply",
        "calendar": "refresh events",
        "controlcenter": "toggle close expand wifi bluetooth sound display focus nowPlaying back toggleDnd",
        "desktopmenu": "open close toggle theme appearance wallpaper screenshot down up right left esc state",
        "displays": "status",
        "downloads": "list",
        "drives": "list refresh",
        "extras": "show wifi wifiDetails bluetooth bluetoothDetails sound soundDetails nowPlaying focus "
        "display battery clock camera inputSource overflow details close down up left right esc",
        "focus": "toggle start stop pause",
        "fullscreen": "status reveal conceal",
        "island": "toggle close next prev page media system usage notifications live calendar timers "
        "controls ai scratchpad flash",
        "keepawake": "on off toggle minutes status",
        "library": "refresh summary",
        "media": "status",
        "mixer": "toggle open close settings",
        "monitor": "toggle open close overview processes network disks",
        "motion": "status scale reduce",
        "notifications": "test pending",
        "osd": "message",
        "perf": "status",
        "quickpanel": "toggle open close settings",
        "radial": "toggle open close settings",
        "scratchpad": "toggle open close",
        "settings": "toggle displays input layout keybinds windowrules features desktopmenu quickpanel "
        "radialmenu wallpaper lockscreen capture island menubar spotlight phone dock spaces open",
        "shelf": "toggle open close list",
        "shell": "reload lastError",
        "snippets": "toggle open close settings",
        "spaces": "focus next prev list active switcher",
        "switcher": "next prev commit cancel",
        "theme": "current reload",
        "themes": "cycle open",
        "timers": "start stopwatch pause stop clear silence list",
        "transparency": "status setLevel setBlur",
        "utilities": "toggle open close ports updates cleaner media",
        "vibes": "current refresh next prev",
        "videowallpapers": "stats",
        "wallpaper": "toggle next prev sets applySet shuffle status refreshPlan",
        "windowrules": "status open opaque translucent glassOn glassOff toggleGlass toggleOpaqueFocused",
        "wswallpapers": "stats",
    }.items()
}

IDENT = r"^[A-Za-z][A-Za-z0-9_]{0,63}$"
APP_ID = r"^[A-Za-z0-9][A-Za-z0-9._+:-]{0,199}$"
OUTPUT = r"^[A-Za-z0-9][A-Za-z0-9 ._+:-]{0,127}$"


# ── environment and subprocesses ────────────────────────────────────────────


def env_problems() -> list[str]:
    out = []
    sock = os.environ.get("NIRI_SOCKET")
    if not sock:
        out.append("NIRI_SOCKET is not set (start the server from the desktop session's environment)")
    elif not Path(sock).exists():
        out.append(f"NIRI_SOCKET={sock} does not exist (niri not running, or a stale environment)")
    if not os.environ.get("WAYLAND_DISPLAY"):
        out.append("WAYLAND_DISPLAY is not set (screenshots and the shell need the session's display)")
    return out


def _need_session() -> None:
    problems = env_problems()
    if problems:
        raise ToolError("no desktop session: " + "; ".join(problems))


def run(argv: list[str], timeout: float = 15, input: bytes | None = None) -> bytes:
    """Run a program; its stdout, or ToolError with its stderr."""
    exe = shutil.which(argv[0])
    if exe is None:
        raise ToolError(f"{argv[0]} is not on PATH")
    try:
        r = subprocess.run(
            [exe, *argv[1:]],
            input=input,
            stdin=None if input is not None else subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise ToolError(f"{argv[0]} timed out after {timeout:g} s") from None
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).decode(errors="replace").strip()
        raise ToolError(f"{' '.join(argv[:3])} failed ({r.returncode}): {msg[-800:] or 'no output'}")
    return r.stdout


def niri_json(what: str):
    _need_session()
    try:
        return json.loads(run(["niri", "msg", "--json", what]))
    except ValueError as e:
        raise ToolError(f"niri msg {what}: bad JSON ({e})") from None


def niri_action(*args: str) -> None:
    _need_session()
    run(["niri", "msg", "action", *args])


# ── niri: reading ───────────────────────────────────────────────────────────


def _outputs() -> dict[str, dict]:
    return niri_json("outputs")


def _workspaces() -> list[dict]:
    return niri_json("workspaces")


def _windows() -> list[dict]:
    return niri_json("windows")


def _window(wid: int) -> dict:
    for w in _windows():
        if w.get("id") == wid:
            return w
    raise ToolError(f"no window with id {wid} (list_windows shows the open ones)")


def _output_name(name: str) -> str:
    outs = _outputs()
    if name in outs:
        return name
    for o in outs.values():  # "Make Model Serial" identity also works
        ident = " ".join(str(o.get(k) or "Unknown") for k in ("make", "model", "serial"))
        if name == ident:
            return o["name"]
    raise ToolError(f"no output {name!r}; outputs: {', '.join(sorted(outs))}")


def _workspace_ref(ref) -> str:
    """A workspace index (int, on the focused output) or name → niri's reference."""
    if isinstance(ref, int):
        if not 1 <= ref <= 255:
            raise ToolError("workspace index must be 1–255")
        return str(ref)
    names = [w.get("name") for w in _workspaces() if w.get("name")]
    if ref not in names:
        raise ToolError(f"no workspace named {ref!r}; named workspaces: {', '.join(names) or 'none'}")
    return ref


def _ws_brief(ws: dict | None) -> dict | None:
    if ws is None:
        return None
    return {"id": ws.get("id"), "idx": ws.get("idx"), "name": ws.get("name"), "output": ws.get("output")}


def _window_info(w: dict, workspaces: dict[int, dict], outputs: dict[str, dict]) -> dict:
    ws = workspaces.get(w.get("workspace_id"))
    layout = w.get("layout") or {}
    out = {
        "id": w.get("id"),
        "app_id": w.get("app_id"),
        "title": w.get("title"),
        "pid": w.get("pid"),
        "workspace": _ws_brief(ws),
        "output": ws.get("output") if ws else None,
        "focused": bool(w.get("is_focused")),
        "floating": bool(w.get("is_floating")),
        "urgent": bool(w.get("is_urgent")),
        "size": layout.get("window_size"),
        "column": (layout.get("pos_in_scrolling_layout") or [None])[0],
        "row": (layout.get("pos_in_scrolling_layout") or [None, None])[1],
    }
    rect = _window_rect(w, ws, outputs)
    if rect:
        out["rect"] = rect  # global logical px; niri gives positions for floating windows only
    return out


def _window_rect(w: dict, ws: dict | None, outputs: dict[str, dict]) -> list[float] | None:
    layout = w.get("layout") or {}
    pos, size = layout.get("tile_pos_in_workspace_view"), layout.get("window_size")
    if not pos or not size or not ws:
        return None
    lo = (outputs.get(ws.get("output")) or {}).get("logical") or {}
    off = layout.get("window_offset_in_tile") or [0, 0]
    return [lo.get("x", 0) + pos[0] + off[0], lo.get("y", 0) + pos[1] + off[1], size[0], size[1]]


def list_windows(a: dict) -> dict:
    outputs = _outputs()
    workspaces = {w["id"]: w for w in _workspaces()}
    wins = [_window_info(w, workspaces, outputs) for w in _windows()]
    if a.get("app_id"):
        wins = [w for w in wins if w["app_id"] == a["app_id"]]
    wins.sort(key=lambda w: ((w["workspace"] or {}).get("output") or "", (w["workspace"] or {}).get("idx") or 0, w["column"] or 0, w["row"] or 0))
    return {"windows": wins}


def focused_window(a: dict) -> dict:
    outputs = _outputs()
    workspaces = {w["id"]: w for w in _workspaces()}
    for w in _windows():
        if w.get("is_focused"):
            return {"window": _window_info(w, workspaces, outputs)}
    return {"window": None}


def list_workspaces(a: dict) -> dict:
    wins = _windows()
    out = []
    for ws in sorted(_workspaces(), key=lambda w: (w.get("output") or "", w.get("idx") or 0)):
        out.append(
            {
                "id": ws.get("id"),
                "idx": ws.get("idx"),
                "name": ws.get("name"),
                "output": ws.get("output"),
                "active": bool(ws.get("is_active")),
                "focused": bool(ws.get("is_focused")),
                "urgent": bool(ws.get("is_urgent")),
                "active_window_id": ws.get("active_window_id"),
                "windows": sum(1 for w in wins if w.get("workspace_id") == ws.get("id")),
            }
        )
    return {"workspaces": out}


def list_outputs(a: dict) -> dict:
    out = []
    focused = None
    try:
        focused = (niri_json("focused-output") or {}).get("name")
    except ToolError:
        pass
    for o in _outputs().values():
        mode = None
        if o.get("current_mode") is not None and o.get("modes"):
            m = o["modes"][o["current_mode"]]
            mode = {"width": m["width"], "height": m["height"], "refresh_hz": round(m["refresh_rate"] / 1000, 2)}
        out.append(
            {
                "name": o.get("name"),
                "identity": " ".join(str(o.get(k) or "Unknown") for k in ("make", "model", "serial")),
                "mode": mode,
                "logical": o.get("logical"),  # x, y, width, height (logical px), scale, transform; null = off
                "focused": o.get("name") == focused,
            }
        )
    out.sort(key=lambda o: ((o["logical"] or {}).get("x", 1 << 30), o["name"]))
    return {"outputs": out}


# ── niri: acting ────────────────────────────────────────────────────────────


def _ok(**info) -> dict:
    return {"ok": True, **info}


def focus_window(a: dict) -> dict:
    _window(a["id"])
    niri_action("focus-window", "--id", str(a["id"]))
    return _ok(focused=a["id"])


def close_window(a: dict) -> dict:
    w = _window(a["id"])
    niri_action("close-window", "--id", str(a["id"]))
    return _ok(closed=a["id"], app_id=w.get("app_id"), note="asked the app to close; it may show a save dialog")


def move_window_to_workspace(a: dict) -> dict:
    _window(a["id"])
    ref = _workspace_ref(a["workspace"])
    niri_action("move-window-to-workspace", "--window-id", str(a["id"]), "--focus", "true" if a.get("focus") else "false", ref)
    return _ok(window=a["id"], workspace=a["workspace"])


def move_window_to_monitor(a: dict) -> dict:
    _window(a["id"])
    out = _output_name(a["output"])
    niri_action("move-window-to-monitor", "--id", str(a["id"]), out)
    return _ok(window=a["id"], output=out)


def set_window_floating(a: dict) -> dict:
    _window(a["id"])
    niri_action("move-window-to-floating" if a["floating"] else "move-window-to-tiling", "--id", str(a["id"]))
    return _ok(window=a["id"], floating=a["floating"])


def fullscreen_window(a: dict) -> dict:
    _window(a["id"])
    niri_action("fullscreen-window", "--id", str(a["id"]))
    return _ok(window=a["id"], toggled="fullscreen")


def maximize_window(a: dict) -> dict:
    _window(a["id"])
    niri_action("maximize-window-to-edges", "--id", str(a["id"]))
    return _ok(window=a["id"], toggled="maximized-to-edges")


def maximize_column(a: dict) -> dict:
    _window(a["id"])
    niri_action("focus-window", "--id", str(a["id"]))
    niri_action("maximize-column")
    return _ok(window=a["id"], toggled="maximized column", focused=a["id"])


def set_column_width(a: dict) -> dict:
    _window(a["id"])
    pct = round(a["proportion"] * 100, 2)
    niri_action("focus-window", "--id", str(a["id"]))
    niri_action("set-column-width", f"{pct:g}%")
    return _ok(window=a["id"], width=f"{pct:g}%", focused=a["id"])


def center_window(a: dict) -> dict:
    _window(a["id"])
    niri_action("center-window", "--id", str(a["id"]))
    return _ok(window=a["id"])


def focus_workspace(a: dict) -> dict:
    ref = _workspace_ref(a["workspace"])
    niri_action("focus-workspace", ref)
    return _ok(workspace=a["workspace"])


def focus_output(a: dict) -> dict:
    out = _output_name(a["output"])
    niri_action("focus-monitor", out)
    return _ok(output=out)


def toggle_overview(a: dict) -> dict:
    state = a.get("state", "toggle")
    niri_action({"toggle": "toggle-overview", "open": "open-overview", "close": "close-overview"}[state])
    return _ok(overview=state)


def launch(a: dict) -> dict:
    cmd = a["command"]
    if any("\0" in c for c in cmd):
        raise ToolError("command: NUL bytes are not allowed")
    niri_action("spawn", "--", *cmd)
    return _ok(spawned=cmd, note="started by niri in the session; use list_windows to find its window")


def spotlight_open(a: dict) -> dict:
    niri_action("spawn", "--", "loft-launcher", "open")
    return _ok(opened="spotlight")


# ── screenshots ─────────────────────────────────────────────────────────────


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ToolError("screenshot is not a PNG")
    return struct.unpack(">II", data[16:24])


def _shrink(png: bytes, max_width: int) -> bytes:
    """Scale a PNG down to max_width (ImageMagick, when on PATH)."""
    w, _ = png_size(png)
    if w <= max_width or not shutil.which("magick"):
        return png
    return run(["magick", "png:-", "-resize", f"{max_width}x>", "png:-"], input=png, timeout=30)


def screenshot_output(a: dict) -> Image:
    _need_session()
    outs = _outputs()
    name = _output_name(a["output"]) if a.get("output") else (niri_json("focused-output") or {}).get("name")
    lo = (outs.get(name) or {}).get("logical")
    if not lo:
        raise ToolError(f"output {name!r} is off")
    max_w = a.get("max_width", 1920)
    scale = min(lo.get("scale", 1.0), max_w / lo["width"])
    png = run(["grim", "-t", "png", "-o", name, "-s", f"{scale:.4f}", "-"], timeout=30)
    png = _shrink(png, max_w)  # grim rounds; never exceed what was asked
    w, h = png_size(png)
    return Image(png, {"output": name, "region": [lo["x"], lo["y"], lo["width"], lo["height"]], "width": w, "height": h, "px_per_logical": round(w / lo["width"], 4)})


def screenshot_window(a: dict) -> Image:
    _need_session()
    w = _window(a["id"])
    max_w = a.get("max_width", 1920)
    outputs = _outputs()
    workspaces = {x["id"]: x for x in _workspaces()}
    ws = workspaces.get(w.get("workspace_id"))
    rect = _window_rect(w, ws, outputs)
    if rect and ws and ws.get("is_active"):
        # A visible floating window: grim the rectangle (what is on screen).
        x, y, rw, rh = (int(round(v)) for v in rect)
        scale = min(((outputs.get(ws["output"]) or {}).get("logical") or {}).get("scale", 1.0), max_w / max(rw, 1))
        png = _shrink(run(["grim", "-t", "png", "-g", f"{x},{y} {rw}x{rh}", "-s", f"{scale:.4f}", "-"], timeout=30), max_w)
        pw, ph = png_size(png)
        return Image(png, {"window": w["id"], "method": "grim", "region": [x, y, rw, rh], "width": pw, "height": ph})
    # Tiled (niri reports no position) or off-screen: niri renders the window
    # alone. That also copies it to the clipboard, so put text back after.
    saved = _clipboard_text()
    with tempfile.TemporaryDirectory(prefix="loft-mcp-") as d:
        path = Path(d) / "window.png"
        niri_action("screenshot-window", "--id", str(w["id"]), "--write-to-disk", "true", "--path", str(path))
        png = _wait_png(path)
    _clipboard_restore(saved)
    png = _shrink(png, max_w)
    pw, ph = png_size(png)
    return Image(png, {"window": w["id"], "method": "niri-render", "region": None, "width": pw, "height": ph, "note": "window-local image (tiled windows have no screen position)"})


def _wait_png(path: Path, timeout: float = 5) -> bytes:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            data = path.read_bytes()
            if data.endswith(b"IEND\xaeB`\x82"):
                return data
        except OSError:
            pass
        time.sleep(0.05)
    raise ToolError("niri did not write the window screenshot")


def _clipboard_text() -> bytes | None:
    if not shutil.which("wl-paste"):
        return None
    try:
        types = run(["wl-paste", "--list-types"], timeout=2).decode(errors="replace").split()
        if "text/plain;charset=utf-8" in types:
            return run(["wl-paste", "--no-newline", "--type", "text/plain;charset=utf-8"], timeout=2)
    except ToolError:
        pass
    return None


def _clipboard_restore(text: bytes | None) -> None:
    if text is None or not shutil.which("wl-copy"):
        return
    try:  # wl-copy stays in the background serving the selection: never give it our stdout
        subprocess.run(["wl-copy"], input=text, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        pass


# ── loft CLI ────────────────────────────────────────────────────────────────


class LoftCli:
    def __init__(self, dev: bool):
        self.dev = dev

    def __call__(self, *args: str, timeout: float = 60) -> str:
        # This same package, as `python3 cli/loft …` (what bin/loft runs).
        pkg = Path(__file__).resolve().parent
        argv = [sys.executable, "-B", str(pkg), *(["--dev"] if self.dev else []), *args]
        try:
            r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise ToolError(f"loft {' '.join(args[:2])} timed out") from None
        out = r.stdout.decode(errors="replace").strip()
        if r.returncode != 0:
            err = r.stderr.decode(errors="replace").strip()
            raise ToolError(f"loft {' '.join(args)} failed ({r.returncode}): {(err or out)[-800:]}")
        return out

    def json(self, *args: str):
        out = self(*args)
        try:
            return json.loads(out)
        except ValueError:
            return {"output": out}


RULE_FIELDS = {
    "open-on-workspace",
    "open-on-output",
    "open-floating",
    "open-maximized",
    "open-fullscreen",
    "default-column-width",
    "glass",
    "opacity",
    "opacity-unfocused",
    "blur",
    "square-corners",
    "block-out-from",
}

APPEARANCE_KEYS = ("transparency", "blur", "terminals", "gtk")


def loft_tools(loft: LoftCli) -> list[Tool]:
    def windows_list(a):
        return loft.json("windows", "--json", "list")

    def windows_rule(a):
        args = []
        for k, v in (a.get("fields") or {}).items():
            if k not in RULE_FIELDS:
                raise ToolError(f"fields.{k}: unknown rule field (allowed: {', '.join(sorted(RULE_FIELDS))})")
            if isinstance(v, bool):
                v = "true" if v else "false"
            elif v is None:
                v = ""
            v = str(v)
            if "\n" in v or len(v) > 200:
                raise ToolError(f"fields.{k}: bad value")
            args.append(f"{k}={v}")
        return {"app_id": a["app_id"], "output": loft("windows", "rule", a["app_id"], *args)}

    def theme_list(a):
        packs = loft.json("theme", "list", "--json")
        if isinstance(packs, list):
            packs = [{"name": p.get("name"), "polarity": p.get("polarity")} for p in packs if isinstance(p, dict)]
        current = loft("theme", "current").splitlines()
        return {"current": current[0] if current else None, "themes": packs}

    def theme_apply(a):
        args = ["theme", "apply", a["name"]]
        if a.get("mode"):
            args += ["--mode", a["mode"]]
        return {"applied": a["name"], "output": loft(*args, timeout=120)}

    def appearance_get(a):
        return loft.json("appearance", "status", "--json")

    def appearance_set(a):
        pairs = []
        for k in APPEARANCE_KEYS:
            if k in a:
                v = a[k]
                pairs.append(f"{k}={v if isinstance(v, str) else f'{v:g}'}")
        if not pairs:
            raise ToolError(f"give at least one of {', '.join(APPEARANCE_KEYS)}")
        loft("appearance", "set", *pairs)
        return loft.json("appearance", "status", "--json")

    def niri_show(a):
        return loft.json("niri", "show", "--json")

    def niri_keys(a):
        return loft.json("niri", "keys", "--json")

    def niri_set(a):
        if "\n" in a["value"] or "\r" in a["value"]:
            raise ToolError("value: one line only")
        return {"key": a["key"], "value": a["value"], "output": loft("niri", "set", "--render", a["key"], a["value"])}

    level = {"type": ["number", "string"], "minimum": 0, "maximum": 1, "pattern": r"^(theme|(0(\.\d+)?|1(\.0+)?)|\d{1,3}%)$"}
    return [
        Tool("loft_windows_list", "Loft's window settings: glass (translucency) on/off, apps kept opaque, and every per-app window rule.", _obj({}), windows_list, read_only=True),
        Tool(
            "loft_windows_rule",
            "Show or edit Loft's per-app niri window rule for one exact app id (applies when windows open). "
            "fields: open-on-workspace (name), open-on-output, open-floating/open-maximized/open-fullscreen (bool), "
            "default-column-width (0-1), glass (opaque|custom|native), opacity, opacity-unfocused, blur (bool), "
            "square-corners, block-out-from (screencast|screen-capture); null/\"\" drops a field. No fields = show.",
            _obj(
                {
                    "app_id": {"type": "string", "pattern": APP_ID},
                    "fields": {"type": "object", "additionalProperties": {"type": ["string", "number", "boolean", "null"]}},
                },
                ["app_id"],
            ),
            windows_rule,
        ),
        Tool("loft_theme_list", "List installed Loft themes (name, light/dark) and the current one.", _obj({}), theme_list, read_only=True),
        Tool(
            "loft_theme_apply",
            "Apply a Loft theme by name (re-themes the shell, niri, terminals, GTK …).",
            _obj({"name": {"type": "string", "pattern": r"^[A-Za-z0-9][A-Za-z0-9._@:-]{0,99}$"}, "mode": {"enum": ["light", "dark", "auto"]}}, ["name"]),
            theme_apply,
        ),
        Tool("loft_appearance_get", "Read Loft's Transparency / Blur dials (stored and effective values).", _obj({}), appearance_get, read_only=True),
        Tool(
            "loft_appearance_set",
            "Set Loft's appearance dials: transparency (0 solid … 0.5 theme … 1 clear), blur, terminals, gtk — each 0-1, a percentage, or \"theme\".",
            _obj({k: level for k in APPEARANCE_KEYS}),
            appearance_set,
        ),
        Tool("loft_niri_show", "Every niri setting Loft manages (layout, input, animations …): effective value and where it comes from.", _obj({}), niri_show, read_only=True),
        Tool("loft_niri_keys", "The niri setting keys loft_niri_set accepts, with their types.", _obj({}), niri_keys, read_only=True),
        Tool(
            "loft_niri_set",
            "Set one Loft-managed niri setting (e.g. layout.gaps 8), then validate and reload niri.",
            _obj({"key": {"type": "string", "pattern": r"^[a-z][a-z0-9-]*(\.[a-z0-9-]+)+$"}, "value": {"type": "string", "minLength": 1, "maxLength": 200, "pattern": r"^[^\n]*$"}}, ["key", "value"]),
            niri_set,
        ),
    ]


# ── Quickshell IPC ──────────────────────────────────────────────────────────


def shell_pid() -> int:
    """The running Loft shell's Quickshell instance: $LOFT_SHELL_PID, else the
    newest instance whose config is $LOFT_SHELL_PATH, else the newest Loft-like
    one (a src/shell.qml), else the only one."""
    _need_session()
    if os.environ.get("LOFT_SHELL_PID", "").isdigit():
        return int(os.environ["LOFT_SHELL_PID"])
    try:
        inst = json.loads(run(["quickshell", "list", "--all", "--json"], timeout=5) or b"[]")
    except ValueError:
        inst = []
    if not inst:
        raise ToolError("no Quickshell instance is running in this session (is the Loft shell up?)")
    inst.sort(key=lambda i: i.get("launch_time") or "", reverse=True)
    want = os.environ.get("LOFT_SHELL_PATH")
    for pick in (
        lambda i: want and Path(i.get("config_path", "")).parent == Path(want),
        lambda i: (Path(i.get("config_path", "")).parent / "services" / "Perf.qml").exists(),
        lambda i: len(inst) == 1,
    ):
        for i in inst:
            if pick(i):
                return int(i["pid"])
    raise ToolError("several Quickshell instances and none is the Loft shell; set LOFT_SHELL_PID")


def _qs(*args: str, timeout: float = 10) -> str:
    return run(["quickshell", "ipc", "--pid", str(shell_pid()), *args], timeout=timeout).decode(errors="replace")


def parse_ipc_show(text: str) -> dict[str, dict[str, dict]]:
    """`quickshell ipc show` → {target: {function: {"params": [(name, type)], "returns": type}}}."""
    out: dict[str, dict[str, dict]] = {}
    target = None
    for line in text.splitlines():
        m = re.match(r"^target (\S+)", line)
        if m:
            target = m.group(1)
            out[target] = {}
            continue
        m = re.match(r"^\s+function (\w+)\((.*)\): *(\S+)", line)
        if m and target:
            params = []
            for p in filter(None, (x.strip() for x in m.group(2).split(","))):
                name, _, typ = p.partition(":")
                params.append((name.strip(), typ.strip() or "string"))
            out[target][m.group(1)] = {"params": params, "returns": m.group(3)}
    return out


def shell_ipc_list(a: dict) -> dict:
    shown = parse_ipc_show(_qs("show"))
    targets = {}
    for t in sorted(shown):
        allowed = SHELL_ALLOW.get(t, frozenset())
        fns = {f: s for f, s in shown[t].items() if f in allowed}
        if fns:
            targets[t] = [f"{f}({', '.join(f'{n}: {ty}' for n, ty in s['params'])}): {s['returns']}" for f, s in sorted(fns.items())]
    return {"targets": targets, "note": "only these targets/functions may be called with shell_ipc_call"}


def _ipc_arg(v, typ: str, where: str) -> str:
    if typ == "bool":
        if isinstance(v, bool):
            return "true" if v else "false"
        if v in ("true", "false"):
            return v
    elif typ == "int":
        if isinstance(v, int) and not isinstance(v, bool) or isinstance(v, str) and re.fullmatch(r"-?\d{1,9}", v):
            return str(v)
    elif typ == "real":
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return f"{v:g}"
        if isinstance(v, str) and re.fullmatch(r"-?\d+(\.\d+)?", v):
            return v
    else:
        if isinstance(v, str) and len(v) <= 500 and "\0" not in v:
            return v
    raise ToolError(f"{where}: expected {typ}")


def shell_ipc_call(a: dict) -> dict:
    target, fn, args = a["target"], a["function"], a.get("args") or []
    if fn not in SHELL_ALLOW.get(target, frozenset()):
        raise ToolError(f"{target}.{fn} is not allowed (shell_ipc_list shows what is)")
    shown = parse_ipc_show(_qs("show"))
    sig = shown.get(target, {}).get(fn)
    if sig is None:
        raise ToolError(f"the running shell has no {target}.{fn} (module switched off?)")
    if len(args) != len(sig["params"]):
        want = ", ".join(f"{n}: {t}" for n, t in sig["params"]) or "no arguments"
        raise ToolError(f"{target}.{fn} takes ({want}), got {len(args)} argument(s)")
    argv = [_ipc_arg(v, t, f"args[{i}] ({n})") for i, (v, (n, t)) in enumerate(zip(args, sig["params"]))]
    out = _qs("call", target, fn, *argv).strip()
    try:
        value = json.loads(out) if out else None
    except ValueError:
        value = out
    return {"target": target, "function": fn, "result": value}


# ── the tool list ───────────────────────────────────────────────────────────


def _obj(props: dict, required: list[str] | None = None) -> dict:
    s = {"type": "object", "properties": props, "additionalProperties": False}
    if required:
        s["required"] = required
    return s


WID = {"type": "integer", "minimum": 1, "description": "window id (list_windows)"}
WS = {"type": ["integer", "string"], "minimum": 1, "maximum": 255, "minLength": 1, "maxLength": 100, "description": "workspace index (on the focused output) or name"}
OUT = {"type": "string", "pattern": OUTPUT, "description": "output connector (e.g. DP-4) or \"Make Model Serial\""}
MAXW = {"type": "integer", "minimum": 256, "maximum": 3840, "description": "max image width in px (default 1920)"}


def tools(dev: bool = False) -> list[Tool]:
    T = Tool
    return [
        T("list_windows", "List open windows: id, app_id, title, workspace, output, focused, floating, size, column/row, rect (floating only).", _obj({"app_id": {"type": "string", "pattern": APP_ID}}), list_windows, read_only=True),
        T("focused_window", "The focused window (same fields as list_windows), or null.", _obj({}), focused_window, read_only=True),
        T("list_workspaces", "List workspaces per output: id, idx, name, active, focused, window count.", _obj({}), list_workspaces, read_only=True),
        T("list_outputs", "List displays: connector name, identity, mode, logical position/size/scale, focused.", _obj({}), list_outputs, read_only=True),
        T("focus_window", "Focus a window by id (switches to its workspace/output).", _obj({"id": WID}, ["id"]), focus_window),
        T("close_window", "Ask a window to close (like clicking its close button; the app may prompt).", _obj({"id": WID}, ["id"]), close_window),
        T("move_window_to_workspace", "Move a window to a workspace (index or name); focus=true follows it.", _obj({"id": WID, "workspace": WS, "focus": {"type": "boolean"}}, ["id", "workspace"]), move_window_to_workspace),
        T("move_window_to_monitor", "Move a window to another display.", _obj({"id": WID, "output": OUT}, ["id", "output"]), move_window_to_monitor),
        T("set_window_floating", "Make a window floating (true) or tiled (false).", _obj({"id": WID, "floating": {"type": "boolean"}}, ["id", "floating"]), set_window_floating),
        T("fullscreen_window", "Toggle fullscreen for a window.", _obj({"id": WID}, ["id"]), fullscreen_window),
        T("maximize_window", "Toggle maximize-to-edges for a window (fills the output, keeps bar space off).", _obj({"id": WID}, ["id"]), maximize_window),
        T("maximize_column", "Focus a window and toggle maximizing its column (full output width).", _obj({"id": WID}, ["id"]), maximize_column),
        T("set_column_width", "Focus a window and set its column width as a proportion of the output (0.1-1).", _obj({"id": WID, "proportion": {"type": "number", "minimum": 0.1, "maximum": 1}}, ["id", "proportion"]), set_column_width),
        T("center_window", "Center a window on its output (scrolls the view to it).", _obj({"id": WID}, ["id"]), center_window),
        T("focus_workspace", "Switch to a workspace by index (on the focused output) or name.", _obj({"workspace": WS}, ["workspace"]), focus_workspace),
        T("focus_output", "Move focus to a display.", _obj({"output": OUT}, ["output"]), focus_output),
        T("toggle_overview", "Open, close or toggle niri's overview (all workspaces zoomed out).", _obj({"state": {"enum": ["toggle", "open", "close"]}}), toggle_overview),
        T("launch", "Start a program in the desktop session: command as argv list, e.g. [\"foot\", \"-e\", \"htop\"].", _obj({"command": {"type": "array", "minItems": 1, "maxItems": 64, "items": {"type": "string", "minLength": 1, "maxLength": 4096}}}, ["command"]), launch),
        T("spotlight_open", "Open Loft's Spotlight launcher on the focused display.", _obj({}), spotlight_open),
        T("screenshot_output", "Screenshot a display (default: the focused one) as a PNG, scaled to max_width.", _obj({"output": OUT, "max_width": MAXW}), screenshot_output, read_only=True),
        T("screenshot_window", "Screenshot one window as a PNG, scaled to max_width (tiled/off-screen windows are rendered by niri).", _obj({"id": WID, "max_width": MAXW}, ["id"]), screenshot_window, read_only=True),
        *loft_tools(LoftCli(dev)),
        T("shell_ipc_list", "List the Loft shell's IPC targets and functions that shell_ipc_call may use, with signatures.", _obj({}), shell_ipc_list, read_only=True),
        T(
            "shell_ipc_call",
            "Call a Loft shell IPC function (island, controlcenter, settings, mixer, monitor, wallpaper, timers …); args match its signature.",
            _obj(
                {
                    "target": {"type": "string", "pattern": IDENT},
                    "function": {"type": "string", "pattern": IDENT},
                    "args": {"type": "array", "maxItems": 8, "items": {"type": ["string", "number", "boolean"]}},
                },
                ["target", "function"],
            ),
            shell_ipc_call,
        ),
    ]
