"""Capture helpers for the shell (`loft capture …`): scrolling capture and
recording zooms.

  scroll   a scrolling-capture session: grabs the area (grim -t ppm) a few
           times a second while you scroll it, stitches the frames
           (loft.stitch) and prints one JSON line per change —
           {"event": "frame", "height", "frames", "segments": […]} — for the
           live preview. Commands on stdin: `done` writes the PNG and prints
           {"event": "done", "path", …}; `cancel` throws it away; `auto
           [X Y]` starts Auto Scroll (loft-pointer turns the wheel over the
           area; X Y: where to put the pointer back), `stop` / `abort` end it
           (abort: the user moved the pointer, so it stays where it is).
           Auto Scroll also ends by itself at the end of the content (a few
           frames in a row with no new rows although the wheel turned), at
           AUTO_TIMEOUT and at MAX_HEIGHT; {"event": "auto", "state":
           starting|running|stopping|stopped, "reason"} reports it.
  stitch   stitch PPM frames into one tall PNG (batch, for scripts/tests)
  zoom auto    find where the action is in a recording — pointer movement,
               clicks that change the UI, typing — and propose zoom segments
  zoom render  export a recording with zoom segments (and an optional trim)
               as a new file; the original is never touched

Why zooms come from the video: niri 26.04's IPC doesn't report the pointer,
and Wayland only tells a client where the pointer is while it is over that
client's own surfaces. Reading /dev/input would mean listening to raw input
devices, and probing with an invisible overlay would swallow clicks. The
recording itself shows the pointer and everything a click changes, so
`zoom auto` diffs downscaled frames instead: small, local changes are
activity worth zooming into; whole-screen changes (scrolling, switching
windows) are not.

Zoom segments: {"start", "end" (seconds), "zoom" (1–4×), "x", "y" (the
center, 0–1 of the frame)}. Rendering uses ffmpeg's perspective filter with
per-frame expressions — sub-pixel, so pans and zooms don't jitter — and
eases in and out of every segment (smoothstep over `RAMP` seconds).
"""

from __future__ import annotations

import json
import math
import os
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import stitch

# ── Scrolling capture ───────────────────────────────────────────────────

MAX_HEIGHT = 40000  # px: stop growing (a PNG this tall is ~150 MB of pixels)


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def grab(geometry: str, path: Path) -> bool:
    r = subprocess.run(["grim", "-g", geometry, "-t", "ppm", str(path)], capture_output=True)
    return r.returncode == 0 and path.exists()


# ── Auto Scroll ─────────────────────────────────────────────────────────
#
# Only after the user pressed Auto in the HUD: loft-pointer (crates/
# loft-input) puts the pointer in the middle of the area and turns the wheel
# — pointer motion and wheel notches only, never a click or a key — on the
# Wayland display this session runs on. The shell stops it the moment the
# user touches the mouse (the HUD covers the screen except a small hole
# under the pointer) or a key (it holds the keyboard meanwhile).

AUTO_INTERVAL_MS = 250  # between wheel notches
AUTO_MAX_INTERVAL_MS = 1000  # slowest pace after gaps
AUTO_IDLE_FRAMES = 8  # frames in a row with no new rows …
AUTO_IDLE_SECONDS = 1.5  # … for at least this long …
AUTO_IDLE_NOTCHES = 2  # … while the wheel turned this often: the end
AUTO_TIMEOUT = 180.0  # seconds
RESTORE_DELAY = 0.15  # s between telling the shell and moving the pointer back


class AutoStop:
    """When Auto Scroll should stop by itself: the end of the content
    (AUTO_IDLE_FRAMES frames in a row, AUTO_IDLE_SECONDS long, with no new
    rows although the wheel turned AUTO_IDLE_NOTCHES times) or the timeout.
    Feed it every frame's match kind and every notch the helper reports."""

    def __init__(self, start: float, idle_frames: int = AUTO_IDLE_FRAMES, idle_seconds: float = AUTO_IDLE_SECONDS, idle_notches: int = AUTO_IDLE_NOTCHES, timeout: float = AUTO_TIMEOUT):
        self.start = start
        self.idle_frames, self.idle_seconds, self.idle_notches, self.timeout = idle_frames, idle_seconds, idle_notches, timeout
        self.idle = 0
        self.last_progress = start
        self.notches = 0
        self.notches_at_progress = 0

    def notch(self) -> None:
        self.notches += 1

    def frame(self, kind: str, now: float) -> str | None:
        """'end', 'timeout' or None (keep going)."""
        if kind in ("added", "gap"):
            self.idle = 0
            self.last_progress = now
            self.notches_at_progress = self.notches
        else:
            self.idle += 1
        if now - self.start >= self.timeout:
            return "timeout"
        if self.idle >= self.idle_frames and now - self.last_progress >= self.idle_seconds and self.notches - self.notches_at_progress >= self.idle_notches:
            return "end"
        return None


def area_center(geometry: str) -> tuple[int, int]:
    """The middle of a grim geometry "X,Y WxH" (whole px, rounded down —
    the HUD's hole is centred on the same point)."""
    pos, size = geometry.split()
    x, y = (int(float(v)) for v in pos.split(","))
    w, h = (int(float(v)) for v in size.split("x"))
    return x + w // 2, y + h // 2


def pointer_command(at: tuple[int, int], restore: tuple[float, float] | None, interval_ms: int = AUTO_INTERVAL_MS) -> list[str]:
    """loft-pointer's argv, on this session's own Wayland display (the
    shell's, which started us) — never any other."""
    exe = os.environ.get("LOFT_POINTER") or shutil.which("loft-pointer")
    if not exe:
        raise RuntimeError("loft-pointer is not installed")
    display = os.environ.get("WAYLAND_DISPLAY", "")
    if not display:
        raise RuntimeError("$WAYLAND_DISPLAY is not set")
    if not os.path.isabs(display) and os.environ.get("XDG_RUNTIME_DIR"):
        # Spelled out: the socket this session's shell is connected to.
        display = os.path.join(os.environ["XDG_RUNTIME_DIR"], display)
    cmd = [exe, "scroll", "--display", display, "--at", f"{at[0]},{at[1]}", "--interval-ms", str(interval_ms), "--timeout", str(int(AUTO_TIMEOUT) + 10)]
    if os.environ.get("NIRI_SOCKET"):
        cmd += ["--niri-socket", os.environ["NIRI_SOCKET"]]
    if restore is not None:
        cmd += ["--restore", f"{restore[0]:g},{restore[1]:g}"]
    return cmd


class PointerHelper:
    """A running loft-pointer: commands in, JSON events out (non-blocking)."""

    def __init__(self, argv: list[str]):
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.set_blocking(self.p.stdout.fileno(), False)
        self.buf = b""
        self.closed = False

    def fileno(self) -> int | None:
        return None if self.closed else self.p.stdout.fileno()

    def send(self, line: str) -> None:
        try:
            self.p.stdin.write((line + "\n").encode())
            self.p.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass

    def events(self) -> list[dict]:
        out: list[dict] = []
        while not self.closed:
            try:
                chunk = self.p.stdout.read(65536)
            except BlockingIOError:
                break
            if chunk is None:
                break
            if chunk == b"":
                self.closed = True
                break
            self.buf += chunk
        *lines, self.buf = self.buf.split(b"\n")
        for line in lines:
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out

    def error(self) -> str:
        """Its stderr, once it has exited."""
        try:
            self.p.wait(timeout=2)
            return (self.p.stderr.read() or b"").decode(errors="replace").strip()
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return ""

    def close(self, cmd: str = "stop") -> list[dict]:
        """Stop it (`stop` restores the pointer, `abort` doesn't) and return
        its last events."""
        self.send(cmd)
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
        rest = b""
        if not self.p.stdout.closed:
            os.set_blocking(self.p.stdout.fileno(), True)
            rest = self.p.stdout.read() or b""
        self.closed = True
        out = []
        for line in (self.buf + rest).split(b"\n"):
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        self.buf = b""
        for f in (self.p.stdout, self.p.stderr):
            if not f.closed:
                f.close()
        return out


def start_pointer(at: tuple[int, int], restore: tuple[float, float] | None, interval_ms: int) -> PointerHelper:
    return PointerHelper(pointer_command(at, restore, interval_ms))


def scroll_session(
    geometry: str,
    work: Path,
    out: Path,
    interval: float = 0.12,
    grabber=grab,
    commands=None,
    helper_factory=start_pointer,
    clock=time.monotonic,
    restore_delay: float = RESTORE_DELAY,
) -> int:
    """Run until `done` / `cancel` on stdin (or `commands`, an iterator of
    lines, for tests). Returns the exit code."""
    work.mkdir(parents=True, exist_ok=True)
    st = stitch.Stitcher()
    n = 0
    status = ""
    auto: dict | None = None  # {helper, stop: AutoStop, pace, running}

    def auto_start(args: list[str]) -> None:
        nonlocal auto
        if auto is not None:
            return
        restore = None
        if len(args) == 2:
            try:
                restore = (float(args[0]), float(args[1]))
            except ValueError:
                restore = None
        emit({"event": "auto", "state": "starting"})
        try:
            helper = helper_factory(area_center(geometry), restore, AUTO_INTERVAL_MS)
        except (OSError, RuntimeError, ValueError) as e:
            emit({"event": "auto", "state": "stopped", "reason": "unavailable", "message": str(e)})
            return
        auto = {"helper": helper, "stop": AutoStop(clock()), "pace": AUTO_INTERVAL_MS, "running": False}

    def auto_end(reason: str, cmd: str = "stop") -> None:
        """Stop the helper (cmd `stop`: it puts the pointer back; `abort`:
        it doesn't) and report why."""
        nonlocal auto
        if auto is None:
            return
        a, auto = auto, None
        emit({"event": "auto", "state": "stopping", "reason": reason})
        if cmd == "stop" and restore_delay:
            time.sleep(restore_delay)  # the shell drops its pointer guard first
        last = a["helper"].close(cmd)
        stopped = next((e for e in reversed(last) if e.get("event") == "stopped"), {})
        emit({"event": "auto", "state": "stopped", "reason": reason, "notches": stopped.get("notches", a["stop"].notches), "restored": bool(stopped.get("restored"))})

    def auto_events() -> None:
        nonlocal auto
        if auto is None:
            return
        h = auto["helper"]
        for e in h.events():
            ev = e.get("event")
            if ev == "placed" and not auto["running"]:
                auto["running"] = True
                emit({"event": "auto", "state": "running", "x": e.get("x"), "y": e.get("y")})
            elif ev == "notch":
                auto["stop"].notch()
            elif ev == "stopped":
                # It stopped by itself (its own timeout / notch cap).
                reason = {"timeout": "timeout", "max-notches": "limit"}.get(e.get("reason"), "error")
                auto = None
                h.close("abort")  # reap it
                emit({"event": "auto", "state": "stopped", "reason": reason, "notches": e.get("notches", 0), "restored": bool(e.get("restored"))})
                return
        if h.fileno() is None:
            # Gone without saying why: it failed.
            auto = None
            message = h.error() or "loft-pointer exited"
            h.close("abort")
            emit({"event": "auto", "state": "stopped", "reason": "error", "message": message})

    def finish() -> int:
        if not st.frames:
            emit({"event": "error", "message": "nothing captured"})
            return 1
        out.parent.mkdir(parents=True, exist_ok=True)
        w, h = st.compose(out)
        emit({"event": "done", "path": str(out), "width": w, "height": h, "frames": len(st.frames), "gaps": st.gaps})
        return 0

    def cleanup() -> None:
        if auto is not None:
            auto["helper"].close("abort")
        shutil.rmtree(work, ignore_errors=True)

    try:
        while True:
            line = None
            if commands is not None:
                line = next(commands, None)
            else:
                fds = [sys.stdin]
                if auto is not None and auto["helper"].fileno() is not None:
                    fds.append(auto["helper"])
                ready, _, _ = select.select(fds, [], [], interval)
                if sys.stdin in ready:
                    line = sys.stdin.readline()
                    if line == "":
                        line = "cancel"  # the shell went away
            auto_events()
            if line is not None:
                cmd, *args = line.split() or [""]
                if cmd == "done":
                    auto_end("done")
                    return finish()
                if cmd == "cancel":
                    auto_end("cancel")
                    emit({"event": "cancelled"})
                    return 0
                if cmd == "auto":
                    auto_start(args)
                elif cmd == "stop":
                    auto_end("stop")
                elif cmd == "abort":
                    auto_end("pointer", "abort")
            n += 1
            f = work / f"frame-{n:05}.ppm"
            if not grabber(geometry, f):
                emit({"event": "error", "message": "grim failed"})
                return 1
            m = st.add(f)
            if m.kind not in ("added", "gap"):
                f.unlink(missing_ok=True)
            if auto is not None:
                if m.kind == "gap" and auto["pace"] < AUTO_MAX_INTERVAL_MS:
                    # Scrolled past a whole frame between grabs: slow down.
                    auto["pace"] = min(AUTO_MAX_INTERVAL_MS, int(auto["pace"] * 1.5))
                    auto["helper"].send(f"interval {auto['pace']}")
                why = auto["stop"].frame(m.kind, clock())
                if why:
                    auto_end(why)
            if m.kind != status or m.kind in ("added", "gap"):
                status = m.kind
                emit(
                    {
                        "event": "frame",
                        "status": m.kind,
                        "width": st.width,
                        "frameHeight": st.height,
                        "height": sum(s["h"] for s in st.segments()),
                        "frames": len(st.frames),
                        "gaps": st.gaps,
                        "segments": st.segments(),
                    }
                )
            if st.total_height >= MAX_HEIGHT:
                auto_end("limit")
                emit({"event": "limit", "height": st.total_height})
                return finish()
    finally:
        cleanup()


# ── Recording zooms ─────────────────────────────────────────────────────

RAMP = 0.6  # seconds to ease in / out
MIN_ZOOM, MAX_ZOOM = 1.0, 4.0


def clean_segments(segs: list[dict], duration: float | None = None) -> list[dict]:
    """Sorted, clamped, non-overlapping segments (a later one starts where
    an earlier one would overlap it)."""
    out: list[dict] = []
    for s in sorted(segs, key=lambda s: float(s["start"])):
        a, b = float(s["start"]), float(s["end"])
        if duration is not None:
            a, b = max(0.0, min(a, duration)), max(0.0, min(b, duration))
        if out and a < out[-1]["end"]:
            a = out[-1]["end"]
        if b - a < 0.2:
            continue
        out.append(
            {
                "start": round(a, 3),
                "end": round(b, 3),
                "zoom": round(min(MAX_ZOOM, max(MIN_ZOOM, float(s.get("zoom", 2.0)))), 3),
                "x": round(min(1.0, max(0.0, float(s.get("x", 0.5)))), 4),
                "y": round(min(1.0, max(0.0, float(s.get("y", 0.5)))), 4),
            }
        )
    return out


def _smooth(p: float) -> float:
    p = min(1.0, max(0.0, p))
    return p * p * (3 - 2 * p)


def zoom_at(segs: list[dict], t: float) -> tuple[float, float, float]:
    """(zoom, x, y) at time t — the same curve the ffmpeg expressions draw."""
    for s in segs:
        if s["start"] <= t <= s["end"]:
            r = min(RAMP, (s["end"] - s["start"]) / 3)
            env = _smooth((t - s["start"]) / r) * _smooth((s["end"] - t) / r)
            return 1 + (s["zoom"] - 1) * env, s["x"], s["y"]
    return 1.0, 0.5, 0.5


def viewport(segs: list[dict], t: float, w: float, h: float) -> tuple[float, float, float, float]:
    """The source rectangle (x, y, w, h) shown at time t."""
    z, cx, cy = zoom_at(segs, t)
    vw, vh = w / z, h / z
    x = min(max(cx * w - vw / 2, 0), w - vw)
    y = min(max(cy * h - vh / 2, 0), h - vh)
    return x, y, vw, vh


def _num(v: float) -> str:
    return f"{v:.4f}".rstrip("0").rstrip(".") or "0"


def zoom_exprs(segs: list[dict], fps: float, offset: float = 0.0) -> dict[str, str]:
    """ffmpeg perspective corner expressions (x0 … y3) for the segments.
    T is the source time: frame number / fps + offset (the trim start)."""
    T = f"(in/{_num(fps)}+{_num(offset)})"

    def smooth(p: str) -> str:
        return f"(clip({p},0,1)*clip({p},0,1)*(3-2*clip({p},0,1)))"

    z = "1"
    cx = cy = "0.5"
    for s in reversed(segs):
        a, b = s["start"], s["end"]
        r = min(RAMP, (b - a) / 3)
        env = f"{smooth(f'({T}-{_num(a)})/{_num(r)}')}*{smooth(f'({_num(b)}-{T})/{_num(r)}')}"
        inside = f"between({T},{_num(a)},{_num(b)})"
        z = f"if({inside},1+{_num(s['zoom'] - 1)}*{env},{z})"
        cx = f"if({inside},{_num(s['x'])},{cx})"
        cy = f"if({inside},{_num(s['y'])},{cy})"
    vw, vh = f"(W/({z}))", f"(H/({z}))"
    x = f"clip(({cx})*W-{vw}/2,0,W-{vw})"
    y = f"clip(({cy})*H-{vh}/2,0,H-{vh})"
    return {
        "x0": x,
        "y0": y,
        "x1": f"{x}+{vw}",
        "y1": y,
        "x2": x,
        "y2": f"{y}+{vh}",
        "x3": f"{x}+{vw}",
        "y3": f"{y}+{vh}",
    }


def probe(path: str) -> dict:
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_entries", "format=duration:stream=codec_type,width,height,avg_frame_rate,r_frame_rate", path],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        raise SystemExit(f"loft: can't read {path}: {r.stderr.strip()}")
    info = json.loads(r.stdout or "{}")
    v = next((s for s in info.get("streams", []) if s.get("codec_type") == "video"), {})

    def rate(s: str) -> float:
        try:
            a, b = s.split("/")
            return float(a) / float(b) if float(b) else 0.0
        except (ValueError, AttributeError):
            return 0.0

    fps = rate(v.get("avg_frame_rate", "")) or rate(v.get("r_frame_rate", ""))
    return {
        "duration": float(info.get("format", {}).get("duration") or 0),
        "width": int(v.get("width") or 0),
        "height": int(v.get("height") or 0),
        "fps": fps,
        "audio": any(s.get("codec_type") == "audio" for s in info.get("streams", [])),
    }


def render_command(src: str, out: str, segs: list[dict], info: dict, start: float = 0.0, end: float | None = None) -> list[str]:
    fps = min(60.0, max(15.0, round(info.get("fps") or 30)))
    ex = zoom_exprs(segs, fps, start)
    corners = ":".join(f"{k}='{v}'" for k, v in ex.items())
    vf = f"fps={_num(fps)},perspective={corners}:interpolation=linear:eval=frame,format=yuv420p"
    cmd = ["ffmpeg", "-v", "error", "-y"]
    if start > 0:
        cmd += ["-ss", f"{start:.3f}"]
    if end is not None:
        cmd += ["-to", f"{end:.3f}"]
    cmd += ["-i", src, "-map", "0:v:0", "-map", "0:a?", "-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-c:a", "copy", out]
    return cmd


def zoomed_name(src: str) -> str:
    p = Path(src)
    out = p.with_name(f"{p.stem}-zoomed{p.suffix or '.mp4'}")
    n = 2
    while out.exists():
        out = p.with_name(f"{p.stem}-zoomed-{n}{p.suffix or '.mp4'}")
        n += 1
    return str(out)


# Activity → zoom segments.

ANALYSIS_W = 192
ANALYSIS_FPS = 10
DIFF = 14  # gray levels: a changed pixel
BIG = 0.18  # changed fraction: a scene change (scrolling, a new window)


def activity(frames, w: int, h: int, fps: float = ANALYSIS_FPS) -> list[dict]:
    """Per pair of downscaled gray frames with a small, local change:
    {t, x, y, w, h} (bbox center + size, 0–1). Scene changes come out as
    {t, scene: true}."""
    events: list[dict] = []
    prev = None
    for i, f in enumerate(frames):
        if prev is not None:
            xs: list[int] = []
            ys: list[int] = []
            n = 0
            for y in range(h):
                o = y * w
                a, b = prev[o : o + w], f[o : o + w]
                if a == b:
                    continue
                for x in range(w):
                    if abs(a[x] - b[x]) > DIFF:
                        n += 1
                        xs.append(x)
                        ys.append(y)
            t = i / fps
            if n > BIG * w * h:
                events.append({"t": t, "scene": True})
            elif n >= 2:
                x0, x1, y0, y1 = min(xs), max(xs) + 1, min(ys), max(ys) + 1
                events.append({"t": t, "x": (x0 + x1) / 2 / w, "y": (y0 + y1) / 2 / h, "w": (x1 - x0) / w, "h": (y1 - y0) / h})
        prev = f
    return events


def segments_from_activity(events: list[dict], duration: float, zoom: float = 2.0) -> list[dict]:
    """Group local activity that stays in one area into zoom segments."""
    clusters: list[dict] = []
    cur: dict | None = None

    def close():
        nonlocal cur
        if cur and cur["last"] - cur["first"] >= 0.6 and cur["n"] >= 3:
            clusters.append(cur)
        cur = None

    for e in events:
        if e.get("scene"):
            close()
            continue
        if cur is not None:
            near = math.hypot(e["x"] - cur["cx"], e["y"] - cur["cy"]) < 0.22
            if e["t"] - cur["last"] > 1.6 or not near:
                close()
        if cur is None:
            cur = {"first": e["t"], "last": e["t"], "n": 0, "cx": e["x"], "cy": e["y"], "x0": 1.0, "y0": 1.0, "x1": 0.0, "y1": 0.0}
        cur["n"] += 1
        cur["last"] = e["t"]
        k = 1 / cur["n"]
        cur["cx"] += (e["x"] - cur["cx"]) * k
        cur["cy"] += (e["y"] - cur["cy"]) * k
        cur["x0"] = min(cur["x0"], e["x"] - e["w"] / 2)
        cur["y0"] = min(cur["y0"], e["y"] - e["h"] / 2)
        cur["x1"] = max(cur["x1"], e["x"] + e["w"] / 2)
        cur["y1"] = max(cur["y1"], e["y"] + e["h"] / 2)
    close()

    segs = []
    for c in clusters:
        span = max(c["x1"] - c["x0"], c["y1"] - c["y0"], 0.05)
        z = min(zoom, max(1.3, 0.8 / span))
        segs.append(
            {
                "start": max(0.0, c["first"] - 0.5),
                "end": min(duration, c["last"] + 1.2),
                "zoom": round(z, 2),
                "x": (c["x0"] + c["x1"]) / 2,
                "y": (c["y0"] + c["y1"]) / 2,
            }
        )
    # Merge neighbours in the same area; drop what's too short to read.
    merged: list[dict] = []
    for s in segs:
        if merged and s["start"] - merged[-1]["end"] < 0.8 and math.hypot(s["x"] - merged[-1]["x"], s["y"] - merged[-1]["y"]) < 0.2:
            m = merged[-1]
            m["end"] = s["end"]
            m["zoom"] = min(m["zoom"], s["zoom"])
            continue
        merged.append(dict(s))
    return clean_segments([s for s in merged if s["end"] - s["start"] >= 1.2], duration)


def analyze(src: str, info: dict | None = None) -> list[dict]:
    info = info or probe(src)
    if not info["width"] or not info["height"]:
        raise SystemExit("loft: no video stream")
    w = ANALYSIS_W
    h = max(2, round(w * info["height"] / info["width"] / 2) * 2)
    p = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", src, "-vf", f"fps={ANALYSIS_FPS},scale={w}:{h}:flags=area,format=gray", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE,
    )

    def frames():
        size = w * h
        while True:
            buf = p.stdout.read(size)
            if len(buf) < size:
                break
            yield buf

    try:
        events = activity(frames(), w, h)
    finally:
        p.stdout.close()
        p.wait()
    return events


def auto_zoom(src: str, zoom: float = 2.0) -> dict:
    info = probe(src)
    events = analyze(src, info)
    return {"duration": info["duration"], "width": info["width"], "height": info["height"], "segments": segments_from_activity(events, info["duration"], zoom)}


# ── CLI ─────────────────────────────────────────────────────────────────


def _segments_arg(text: str) -> list[dict]:
    if text.startswith("@"):
        text = Path(text[1:]).read_text()
    data = json.loads(text)
    return data["segments"] if isinstance(data, dict) else data


def add_parser(top) -> None:
    cap = top.add_parser("capture", help="capture helpers: scrolling capture, recording zooms")
    sub = cap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scroll", help="scrolling-capture session (JSON lines; `done`/`cancel` on stdin)")
    s.add_argument("--geometry", required=True, help='area as grim takes it: "X,Y WxH" (logical)')
    s.add_argument("--out", required=True, help="PNG to write on `done`")
    s.add_argument("--work", help="frame scratch dir (default: next to --out's tmp)")
    s.add_argument("--interval", type=float, default=0.12)

    def _scroll(ctx, a):
        work = Path(a.work) if a.work else Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / f"loft-scroll-{os.getpid()}"
        sys.exit(scroll_session(a.geometry, work, Path(a.out), a.interval))

    s.set_defaults(fn=_scroll)

    s = sub.add_parser("stitch", help="stitch PPM frames (in order) into one PNG")
    s.add_argument("frames", nargs="+")
    s.add_argument("-o", "--out", required=True)
    s.set_defaults(fn=lambda ctx, a: print(json.dumps(stitch.stitch_files(a.frames, a.out))))

    z = sub.add_parser("zoom", help="recording zooms: find (auto) and export (render)")
    zs = z.add_subparsers(dest="zcmd", required=True)

    s = zs.add_parser("auto", help="propose zoom segments from the activity in a recording (JSON)")
    s.add_argument("video")
    s.add_argument("--zoom", type=float, default=2.0, help="the deepest zoom to propose")
    s.set_defaults(fn=lambda ctx, a: print(json.dumps(auto_zoom(a.video, a.zoom))))

    s = zs.add_parser("render", help="export a recording with zoom segments as a new file")
    s.add_argument("video")
    s.add_argument("--segments", required=True, help="JSON list (or @file) of {start,end,zoom,x,y}")
    s.add_argument("--out", help="default: <name>-zoomed.mp4 next to it")
    s.add_argument("--start", type=float, default=0.0, help="trim: first second")
    s.add_argument("--end", type=float, help="trim: last second")
    s.add_argument("--dry-run", action="store_true")

    def _render(ctx, a):
        info = probe(a.video)
        segs = clean_segments(_segments_arg(a.segments), info["duration"] or None)
        out = a.out or zoomed_name(a.video)
        cmd = render_command(a.video, out, segs, info, a.start, a.end)
        if a.dry_run:
            print(json.dumps(cmd))
            return
        t = time.monotonic()
        r = subprocess.run(cmd)
        if r.returncode != 0:
            sys.exit(r.returncode)
        print(json.dumps({"path": out, "segments": len(segs), "seconds": round(time.monotonic() - t, 2)}))

    s.set_defaults(fn=_render)
