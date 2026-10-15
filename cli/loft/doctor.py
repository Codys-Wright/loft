"""`loft doctor perf`: is the shell keeping up, and if not, why.

Asks the running shell (`quickshell ipc … call perf status`, src/services/
Perf.qml) for its own numbers: CPU % and RSS, main-thread (event loop) lag
p50 / p99 / max over the last 30 s, video wallpapers loaded / playing and how
they decode, wallpaper surfaces, child processes, reloads. Then adds what the
shell can't see itself: its child processes by name (duplicates after a
reload, zombies) and, from the journal, whether Qt has been copying video
frames back to the CPU ("vaExportSurfaceHandle failed": the VAAPI zero-copy
path isn't working).

Exit status: 0 = fine, 1 = trouble (see the verdict lines), 2 = no shell.
"""

from __future__ import annotations

import json
import subprocess
from collections import Counter
from pathlib import Path


def _ipc(shell_path: str, pid: int | None, target: str, fn: str) -> dict | None:
    sel = ["--pid", str(pid)] if pid else ["--any-display", "--path", shell_path]
    try:
        r = subprocess.run(["quickshell", "ipc", *sel, "call", target, fn], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def _name(argv: list[str]) -> str:
    """A short label: the program and its first two real arguments
    (interpreter flags dropped, paths shortened to their last part)."""
    words = [Path(argv[0]).name.removeprefix(".").removesuffix("-wrapped")]
    for a in argv[1:]:
        if a.startswith("-") or "\n" in a or "," in a or len(a) > 60:
            continue  # flags, inline scripts, event lists
        words.append(Path(a).name if "/" in a else a)
        if len(words) == 4:
            break
    return " ".join(words)


def children(pid: int) -> list[dict]:
    out = []
    try:
        kids = Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
    except OSError:
        return out
    for k in kids:
        try:
            stat = Path(f"/proc/{k}/stat").read_text()
            state = stat[stat.rindex(")") + 2]
            cmd = Path(f"/proc/{k}/cmdline").read_bytes().split(b"\0")
            argv = [c.decode(errors="replace") for c in cmd if c]
            name = _name(argv) if argv else stat[stat.index("(") + 1 : stat.rindex(")")].lstrip(".")
        except (OSError, ValueError):
            continue
        out.append({"pid": int(k), "state": state, "name": name, "argv": argv})
    return out


def journal_copyback(pid: int) -> int:
    """How many "vaExportSurfaceHandle failed" lines this shell process logged."""
    try:
        r = subprocess.run(
            ["journalctl", "--user", f"_PID={pid}", "--no-pager", "-o", "cat", "-g", "vaExportSurfaceHandle failed"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return -1
    return len([line for line in r.stdout.splitlines() if "vaExportSurfaceHandle" in line])


def verdicts(s: dict, kids: list[dict], copyback: int) -> list[str]:
    bad = []
    lag = s.get("lag", {})
    if lag.get("p99", 0) > 50:
        bad.append(f"main thread lag p99 {lag['p99']} ms (> 50 ms): the shell stutters")
    if s.get("cpu", 0) > 60:
        bad.append(f"shell CPU {s['cpu']}% (> 60%)")
    v = s.get("videos", {})
    if copyback > 0 and v.get("playing", 0) > 0:
        bad.append(
            f"video frames are copied back to the CPU ({copyback} 'vaExportSurfaceHandle failed' in the journal): "
            "QtMultimedia without Loft's zero-copy fix, or QT_FFMPEG_DECODING_HW_DEVICE_TYPES overridden"
        )
    # The same long-running helper twice (same command line): one is left
    # over. One-shot commands (sh -c …, a quick `loft …`) come and go.
    same = Counter("\0".join(k["argv"]) for k in kids if k["state"] != "Z" and k["argv"] and Path(k["argv"][0]).name not in ("sh", "bash"))
    dups = [f"{_name(a.split(chr(0)))} ×{c}" for a, c in same.items() if c > 1]
    if dups:
        bad.append("duplicate helper processes (left over from a reload?): " + ", ".join(dups))
    zombies = [k for k in kids if k["state"] == "Z"]
    if len(zombies) > 3:
        bad.append(f"{len(zombies)} zombie children")
    return bad


def cmd_perf(ctx, a) -> None:
    pid = a.pid
    s = _ipc(str(ctx.shell_path), pid, "perf", "status")
    if s is None:
        print("loft doctor perf: no running shell answered (`quickshell ipc … call perf status`)")
        raise SystemExit(2)
    pid = pid or s.get("pid")
    kids = children(pid) if pid else []
    copyback = journal_copyback(pid) if pid else -1
    s["children"] = kids
    s["copyBack"] = copyback
    bad = verdicts(s, kids, copyback)
    s["trouble"] = bad
    if a.json:
        print(json.dumps(s, indent=1))
        raise SystemExit(1 if bad else 0)

    lag = s.get("lag", {})
    v = s.get("videos", {})
    print(f"shell        pid {pid}, up {s.get('uptime', 0) // 60} min, {s.get('reloads', 0)} reload(s)")
    print(f"cpu          {s.get('cpu', 0)}% now, {s.get('cpuAvg', 0)}% over {s.get('window', 30)} s · rss {s.get('rssMB', 0)} MB")
    print(f"main thread  lag p50 {lag.get('p50', 0)} ms · p99 {lag.get('p99', 0)} ms · max {lag.get('max', 0)} ms · stalls>50ms {lag.get('stalls', 0)}")
    print(f"videos       {v.get('playing', 0)} playing / {v.get('loaded', 0)} loaded · decode: {v.get('decode', '?')}"
          + (f" · held: {v['held']}" if v.get("held") else "")
          + (f" · copy-back seen {copyback}×" if copyback > 0 else ""))
    for p in v.get("players", []):
        state = "playing" if p.get("playing") else ("held: " + p["held"] if p.get("held") else "paused")
        print(f"               {p.get('screen', '?'):<10} {state:<26} {'display copy' if p.get('copy') else 'original':<13} {p.get('size', '')}  {p.get('path', '')}")
    print(f"surfaces     {s.get('surfaces', 0)} wallpaper surfaces")
    print(f"children     {len(kids)}: " + ", ".join(f"{k['name']}{' (zombie)' if k['state'] == 'Z' else ''}" for k in kids))
    if s.get("hints"):
        print("shell says   " + "; ".join(s["hints"]))
    print()
    if bad:
        for b in bad:
            print(f"TROUBLE  {b}")
        raise SystemExit(1)
    print("OK")


def add_parser(top) -> None:
    doc = top.add_parser("doctor", help="checks: `loft doctor perf` (shell CPU, lag, video wallpapers, helpers)")
    sub = doc.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("perf", help="the running shell's CPU, memory, main-thread lag, videos and helper processes", description=__doc__)
    s.add_argument("--pid", type=int, help="the shell's pid (default: the shell for this display)")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_perf)

