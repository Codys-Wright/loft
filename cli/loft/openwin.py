"""`loft open`: start a program and put its windows somewhere (docs/KWIN.md §4.17).

For sessions and agents whose windows can't be told apart by app id (every
agent terminal is a ghostty / kitty / konsole):

  loft open [--activity NAME] [--desktop N|NAME] [--monitor ROLE|CONNECTOR]
            [--fullscreen | --maximized | --size WxH] [--position center|left|right|X,Y]
            [--keep-above] [--follow] [--app-id REGEX] [--count N] [--ttl S] -- COMMAND…

The command starts detached (`systemd-run --user --scope`, like the launcher,
else in its own session) in this environment and directory. Then:

- **KWin** (Loft's shell running in Plasma): loft-kwin is told to expect the
  windows of that process tree (`loft-kwin expect`): every new window whose
  process is the started one or descends from it, for `--ttl` seconds
  (`--count` to stop earlier), goes to the Activity (the user's KDE
  Activity, by name), the desktop (number or name), the display (a role:
  main / left / right / … or a connector) and gets the size / full screen /
  maximized. If the app hands its window to an instance that was already
  running, a window of that older process whose app id matches `--app-id`
  (default: ends in the command's name) counts too, for 10 s. Without
  `--follow` you stay where you are.
- **niri**: the same through niri's IPC (event stream, then `move-window-to-
  monitor`, `move-window-to-workspace`, …), for the first `--count` window(s)
  (default 1), waiting up to `--ttl`. `--desktop N` is the workspace index on
  the target display (or a workspace name); `--activity`, `--position` and
  `--keep-above` have no niri meaning and are reported as ignored.

Exit 1 with the reason when there is no Loft session to place windows in;
nothing is started then.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path


class OpenError(Exception):
    pass


SIZE = re.compile(r"^\s*(\d+)(%?)\s*[xX×]\s*(\d+)(%?)\s*$")


def parse_size(s: str) -> dict:
    """`1200x800`, `60%x80%` → {"w": {"px": 1200} | {"share": 0.6}, "h": …}."""
    m = SIZE.match(s or "")
    if not m:
        raise OpenError(f"--size {s!r}: expected WxH (pixels) or W%xH% (of the display)")

    def dim(n: str, pct: str) -> dict:
        v = int(n)
        if pct:
            if not 0 < v <= 100:
                raise OpenError(f"--size {s!r}: a percentage is 1–100")
            return {"share": v / 100}
        if not 0 < v <= 32768:
            raise OpenError(f"--size {s!r}: pixels are 1–32768")
        return {"px": v}

    return {"w": dim(m.group(1), m.group(2)), "h": dim(m.group(3), m.group(4))}


def parse_position(s: str):
    s = (s or "").strip()
    if s in ("center", "left", "right"):
        return s
    m = re.match(r"^(-?\d+)\s*,\s*(-?\d+)$", s)
    if not m:
        raise OpenError(f"--position {s!r}: expected center, left, right or X,Y")
    return [int(m.group(1)), int(m.group(2))]


def guess_app_id(argv: list[str]) -> str:
    """The app id a command's windows probably have: ends in its name."""
    name = os.path.basename(argv[0]).lower()
    return f"(^|\\.){re.escape(name)}$"


def request(opts: dict, pid: int) -> dict:
    """The `loft-kwin expect` request for a started pid."""
    r: dict = {"pid": pid, "id": opts.get("id") or f"open-{uuid.uuid4().hex[:8]}"}
    if opts.get("activity"):
        r["activityName"] = opts["activity"]
    d = opts.get("desktop")
    if d not in (None, ""):
        r["desktop"] = int(d) if isinstance(d, int) or str(d).isdigit() else str(d)
    if opts.get("monitor"):
        r["output"] = opts["monitor"]
    if opts.get("fullscreen"):
        r["open"] = "fullscreen"
    elif opts.get("maximized"):
        r["open"] = "maximized"
    if opts.get("size"):
        r["size"] = parse_size(opts["size"])
    if opts.get("position"):
        r["position"] = parse_position(opts["position"])
    if opts.get("keep_above"):
        r["keepAbove"] = True
    r["follow"] = bool(opts.get("follow"))
    r["appId"] = opts.get("app_id") or guess_app_id(opts["command"])
    r["appIdFlags"] = "" if opts.get("app_id") else "i"
    r["ttl"] = int(float(opts.get("ttl") or 30) * 1000)
    r["count"] = int(opts.get("count") or 0)
    return r


def check_options(opts: dict) -> None:
    if not opts.get("command"):
        raise OpenError("nothing to start: loft open [OPTIONS] -- COMMAND…")
    picks = [k for k in ("fullscreen", "maximized", "size") if opts.get(k)]
    if len(picks) > 1:
        raise OpenError("pick one of --fullscreen, --maximized, --size")
    if opts.get("size"):
        parse_size(opts["size"])
    if opts.get("position"):
        parse_position(opts["position"])


# ── which session ──────────────────────────────────────────────────────────


def session() -> str:
    """As Compositor.qml: $LOFT_COMPOSITOR, else niri with $NIRI_SOCKET, else
    kwin when XDG_CURRENT_DESKTOP has KDE."""
    forced = os.environ.get("LOFT_COMPOSITOR", "")
    if forced in ("niri", "kwin"):
        return forced
    if os.environ.get("NIRI_SOCKET"):
        return "niri"
    if "KDE" in os.environ.get("XDG_CURRENT_DESKTOP", "").split(":"):
        return "kwin"
    return ""


def kwin_bin() -> str:
    return os.environ.get("LOFT_KWIN_BIN") or "loft-kwin"


def _run(argv: list[str], timeout: float = 10) -> subprocess.CompletedProcess:
    exe = shutil.which(argv[0])
    if not exe:
        raise OpenError(f"{argv[0]} is not on PATH")
    return subprocess.run([exe, *argv[1:]], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)


def kwin_state() -> dict:
    r = _run([kwin_bin(), "state"], timeout=5)
    if r.returncode != 0:
        raise OpenError(
            "Loft's shell isn't running under KWin here (no dev.loft.KWinBridge on the session bus), "
            "so nothing could place the windows; nothing was started"
            + (f" ({r.stderr.strip()[-300:]})" if r.stderr.strip() else "")
        )
    return json.loads(r.stdout)


def _norm(s: str) -> str:
    return re.sub(r"[\s_\-]+", "", str(s).lower())


def check_kwin_targets(opts: dict, state: dict) -> list[str]:
    """Refuse a desktop that doesn't exist (before starting anything). An
    Activity or a display is loft-kwin's to check (its dry run): it has the
    Activities from the same report as the shell's Spaces."""
    notes = []
    d = opts.get("desktop")
    if d not in (None, ""):
        desks: list[tuple[str, str]] = []
        for w in state.get("workspaces", []):
            k = (w.get("kwin_desktop"), w.get("name") or "")
            if k not in desks:
                desks.append(k)
        if str(d).isdigit():
            if not 1 <= int(d) <= len(desks):
                raise OpenError(f"no desktop {d} (KWin has {len(desks)})")
        elif not any(_norm(n) == _norm(d) for _, n in desks):
            raise OpenError(f"no desktop named {d!r} (named: {', '.join(n for _, n in desks if n) or 'none'})")
    return notes


# ── starting it ────────────────────────────────────────────────────────────


def _user_manager() -> bool:
    """Whether `systemd-run --user` can reach this session's user manager."""
    if not shutil.which("systemd-run") or not shutil.which("systemctl"):
        return False
    try:
        r = subprocess.run(["systemctl", "--user", "is-system-running"], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.stdout.strip() in ("running", "degraded", "starting")


def spawn(argv: list[str], cwd: str | None = None) -> tuple[int, str]:
    """Start argv detached; (pid, scope unit or "")."""
    exe = shutil.which(argv[0])
    if exe is None:
        raise OpenError(f"{argv[0]} is not on PATH")
    devnull = subprocess.DEVNULL
    unit = ""
    full = [exe, *argv[1:]]
    if _user_manager() and not os.environ.get("LOFT_OPEN_NO_SCOPE"):
        unit = f"loft-open-{os.path.basename(argv[0])[:24]}-{uuid.uuid4().hex[:6]}"
        unit = re.sub(r"[^A-Za-z0-9_.-]", "_", unit)
        # --scope runs the command as this process (same pid): systemd-run
        # registers the scope, then execs it.
        full = ["systemd-run", "--user", "--scope", "--collect", "--quiet", f"--unit={unit}", "--", *full]
    p = subprocess.Popen(full, cwd=cwd or None, stdin=devnull, stdout=devnull, stderr=devnull, start_new_session=True)
    return p.pid, unit


# ── KWin ───────────────────────────────────────────────────────────────────


def open_kwin(opts: dict) -> dict:
    state = kwin_state()
    check_kwin_targets(opts, state)
    # A dry run first: a monitor no display has, or an Activity that isn't
    # there, fails before anything starts.
    probe = request(opts, os.getpid())
    probe["dryRun"] = True
    if probe.get("output") or probe.get("activityName"):
        r = _run([kwin_bin(), "expect", json.dumps(probe)], timeout=5)
        if r.returncode != 0:
            raise OpenError((r.stderr.strip().splitlines() or ["loft-kwin expect failed"])[-1].removeprefix("Error: "))
    pid, unit = spawn(opts["command"], opts.get("cwd"))
    req = request(opts, pid)
    r = _run([kwin_bin(), "expect", json.dumps(req)], timeout=5)
    if r.returncode != 0:
        raise OpenError(f"started {opts['command'][0]} (pid {pid}) but loft-kwin refused to place it: {r.stderr.strip()[-300:]}")
    got = json.loads(r.stdout or "{}")
    return {
        "ok": True,
        "backend": "kwin",
        "pid": pid,
        "unit": unit,
        "id": got.get("id"),
        "activity": opts.get("activity"),
        "desktop": req.get("desktop"),
        "output": got.get("output"),
        "monitor": opts.get("monitor"),
        "open": req.get("open") or ("size" if req.get("size") else ""),
        "follow": req["follow"],
        "ttl_s": req["ttl"] / 1000,
    }


# ── niri ───────────────────────────────────────────────────────────────────


def _ppid(pid: int, proc: Path = Path("/proc")) -> int:
    try:
        text = (proc / str(pid) / "stat").read_text()
        return int(text[text.rfind(")") + 1 :].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def descends(pid: int, root: int, proc: Path = Path("/proc")) -> bool:
    p = pid
    for _ in range(64):
        if p == root:
            return True
        if p <= 1:
            return False
        p = _ppid(p, proc)
    return False


def niri_actions(opts: dict, wid: int, output: str | None) -> list[list[str]]:
    """The `niri msg action …` lines that place window `wid`."""
    a: list[list[str]] = []
    w = str(wid)
    if output:
        a.append(["move-window-to-monitor", "--id", w, output])
    d = opts.get("desktop")
    if d not in (None, ""):
        a.append(["move-window-to-workspace", "--window-id", w, "--focus", "false", str(d)])
    if opts.get("fullscreen"):
        a.append(["fullscreen-window", "--id", w])
    elif opts.get("maximized"):
        a.append(["maximize-window-to-edges", "--id", w])
    elif opts.get("size"):
        s = parse_size(opts["size"])
        for k, verb in (("w", "set-window-width"), ("h", "set-window-height")):
            v = s[k]
            a.append([verb, "--id", w, f"{round(v['share'] * 100)}%" if "share" in v else str(v["px"])])
    if opts.get("follow"):
        a.append(["focus-window", "--id", w])
    return a


def niri_output(monitor: str) -> str:
    """A role → its connector (loft-niri's layout); a connector as is."""
    r = _run(["loft-niri", "--json", "space", "list"], timeout=10)
    try:
        layout = json.loads(r.stdout).get("layout") or []
    except ValueError:
        layout = []
    for d in layout:
        if monitor.lower() in (str(d.get("name", "")).lower(), str(d.get("identity", "")).lower()):
            return d["name"]
    for d in layout:
        if monitor in (d.get("roles") or []):
            return d["name"]
    if not layout:
        return monitor
    raise OpenError(f"no display is {monitor!r} now ({', '.join(d['name'] + ': ' + ' '.join(d.get('roles') or []) for d in layout)})")


def open_niri(opts: dict) -> dict:
    sock = os.environ.get("NIRI_SOCKET", "")
    if not sock or not Path(sock).exists():
        raise OpenError("niri isn't reachable (NIRI_SOCKET); nothing was started")
    output = niri_output(opts["monitor"]) if opts.get("monitor") else None
    ignored = [k for k in ("activity", "position", "keep_above") if opts.get(k)]
    before = {w["id"] for w in json.loads(_run(["niri", "msg", "--json", "windows"]).stdout or "[]")}
    stream = subprocess.Popen(["niri", "msg", "--json", "event-stream"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    placed: list[int] = []
    out = stream.stdout
    assert out is not None
    try:
        pid, unit = spawn(opts["command"], opts.get("cwd"))
        want = int(opts.get("count") or 1)
        deadline = time.monotonic() + float(opts.get("ttl") or 30)
        os.set_blocking(out.fileno(), False)
        buf = ""
        while time.monotonic() < deadline and len(placed) < want:
            chunk = out.read() or ""
            if not chunk:
                time.sleep(0.05)
                continue
            buf += chunk
            *lines, buf = buf.split("\n")
            for line in lines:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                wins = []
                if "WindowOpenedOrChanged" in ev:
                    wins = [ev["WindowOpenedOrChanged"]["window"]]
                elif "WindowsChanged" in ev:
                    wins = ev["WindowsChanged"]["windows"]
                for w in wins:
                    if w["id"] in before or w["id"] in placed or not w.get("pid") or not descends(w["pid"], pid):
                        continue
                    for act in niri_actions(opts, w["id"], output):
                        _run(["niri", "msg", "action", *act])
                    placed.append(w["id"])
    finally:
        stream.terminate()
        stream.wait(timeout=2)
    return {
        "ok": True,
        "backend": "niri",
        "pid": pid,
        "unit": unit,
        "windows": placed,
        "output": output,
        "ignored": ignored,
        "note": "" if placed else "no window of that process showed up in time",
    }


def open_window(opts: dict) -> dict:
    check_options(opts)
    s = session()
    if s == "kwin":
        return open_kwin(opts)
    if s == "niri":
        return open_niri(opts)
    raise OpenError("no Loft session here (neither NIRI_SOCKET nor a KDE session); nothing was started")


def describe(r: dict) -> str:
    where = []
    if r.get("activity"):
        where.append(f"Activity {r['activity']}")
    if r.get("desktop") not in (None, ""):
        where.append(f"desktop {r['desktop']}")
    if r.get("output"):
        where.append(r["output"] + (f" ({r['monitor']})" if r.get("monitor") and r["monitor"] != r["output"] else ""))
    if r.get("open"):
        where.append(r["open"])
    s = f"started pid {r['pid']}" + (f" in {r['unit']}.scope" if r.get("unit") else "")
    if r["backend"] == "kwin":
        s += f"; its windows for {r['ttl_s']:g} s go to " + (", ".join(where) or "where they open")
        s += "" if r.get("follow") else " (you stay here)"
    else:
        s += f"; placed niri windows {r['windows']}" if r["windows"] else f"; {r['note']}"
        if r.get("ignored"):
            s += f" (niri has no {', '.join(r['ignored'])})"
    return s


def add_parser(top) -> None:
    p = top.add_parser(
        "open",
        help="start a program and send its windows to an Activity / desktop / display (KWin; niri too)",
        description=(__doc__ or "").split("\n\n", 1)[1],
        formatter_class=__import__("argparse").RawDescriptionHelpFormatter,
    )
    p.add_argument("--activity", help="KDE Activity, by name (KWin)")
    p.add_argument("--desktop", help="virtual desktop: number (1 = first) or name")
    p.add_argument("--monitor", help="display: a role (main, left, right, portrait, display-2 …) or a connector")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--fullscreen", action="store_true")
    g.add_argument("--maximized", action="store_true")
    g.add_argument("--size", help="WxH in pixels, or W%%xH%% of the display")
    p.add_argument("--position", help="center (default with --size), left, right (half the display), or X,Y")
    p.add_argument("--keep-above", action="store_true", help="keep it above other windows (KWin)")
    p.add_argument("--follow", action="store_true", help="switch to it when it opens (default: stay where you are)")
    p.add_argument("--app-id", help="regex for the fallback match when the app hands off to a running instance")
    p.add_argument("--count", type=int, default=None, help="windows to place (KWin default: every one within --ttl; niri: 1)")
    p.add_argument("--ttl", type=float, default=30, help="seconds to wait for its windows (default 30)")
    p.add_argument("--json", action="store_true")
    p.add_argument("command", nargs="*", help="the program and its arguments (after --)")
    p.set_defaults(fn=_cmd)


def _cmd(_ctx, args) -> None:
    cmd = list(args.command)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    opts = {
        "command": cmd,
        "activity": args.activity,
        "desktop": args.desktop,
        "monitor": args.monitor,
        "fullscreen": args.fullscreen,
        "maximized": args.maximized,
        "size": args.size,
        "position": args.position,
        "keep_above": args.keep_above,
        "follow": args.follow,
        "app_id": args.app_id,
        "count": args.count,
        "ttl": args.ttl,
        "cwd": os.getcwd(),
    }
    try:
        r = open_window(opts)
    except OpenError as e:
        print(f"loft open: {e}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(r) if args.json else describe(r))
