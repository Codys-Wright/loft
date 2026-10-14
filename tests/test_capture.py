"""Capture helpers (cli/loft/capture.py): the scrolling-capture session loop
with a fake grabber, Auto Scroll (when it stops, with a fake loft-pointer), the zoom curve and its ffmpeg expressions, finding zoom
segments in activity, and a real zoomed export of a generated video.
"""

from __future__ import annotations

import io
import json
import os
import re
import sys
import shutil
import subprocess
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from loft import capture, stitch
from test_stitch import W, document, frame


class ScrollSessionTest(unittest.TestCase):
    def test_session_streams_frames_and_writes_png(self):
        doc, h = document(900, seed=23), 240
        offs = iter([0, 0, 120, 250, 250, 400])

        def grabber(geometry, path):
            self.assertEqual(geometry, "10,20 160x240")
            stitch.write_ppm(path, frame(doc[(o := next(offs)) : o + h]))
            return True

        with tempfile.TemporaryDirectory() as td:
            work, out = Path(td) / "work", Path(td) / "out" / "long.png"
            cmds = iter([None] * 6 + ["done"])
            buf = io.StringIO()
            with redirect_stdout(buf):
                code = capture.scroll_session("10,20 160x240", work, out, grabber=grabber, commands=cmds)
            self.assertEqual(code, 0)
            events = [json.loads(line) for line in buf.getvalue().splitlines()]
            frames = [e for e in events if e["event"] == "frame"]
            self.assertEqual([e["height"] for e in frames if e["status"] == "added"], [240, 360, 490, 640])
            self.assertEqual(events[-1]["event"], "done")
            self.assertEqual(events[-1]["height"], 640)
            img = stitch.read_png(out)
            self.assertEqual(img.data, b"".join(doc[:640]))
            self.assertFalse(work.exists(), "frames are cleaned up")

    def test_cancel_writes_nothing(self):
        doc = document(300)
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "x.png"
            buf = io.StringIO()
            with redirect_stdout(buf):
                capture.scroll_session(
                    "0,0 160x200",
                    Path(td) / "w",
                    out,
                    grabber=lambda g, p: stitch.write_ppm(p, frame(doc[:200])) or True,
                    commands=iter([None, "cancel"]),
                )
            self.assertFalse(out.exists())
            self.assertIn('"cancelled"', buf.getvalue())


class AutoStopTest(unittest.TestCase):
    def test_end_of_content_needs_idle_frames_time_and_notches(self):
        a = capture.AutoStop(0.0, idle_frames=4, idle_seconds=1.0, idle_notches=2, timeout=60)
        t = 0.0
        # Before the wheel turns nothing moves: never the end.
        for _ in range(20):
            t += 0.12
            self.assertIsNone(a.frame("same", t))
        a.notch()
        t += 0.12
        self.assertIsNone(a.frame("added", t))
        # Idle frames, but the wheel turned only once since: keep going.
        for _ in range(12):
            t += 0.12
            self.assertIsNone(a.frame("same", t))
        a.notch()
        a.notch()
        t += 0.12
        self.assertEqual(a.frame("same", t), "end")

    def test_progress_resets_and_back_counts_as_idle(self):
        a = capture.AutoStop(0.0, idle_frames=3, idle_seconds=0.5, idle_notches=1, timeout=60)
        a.notch()
        self.assertIsNone(a.frame("same", 0.2))
        self.assertIsNone(a.frame("back", 0.4))
        self.assertIsNone(a.frame("gap", 0.6), "a gap is new rows too")
        a.notch()
        self.assertIsNone(a.frame("same", 0.8))
        self.assertIsNone(a.frame("same", 1.0))
        self.assertEqual(a.frame("back", 1.2), "end")

    def test_timeout(self):
        a = capture.AutoStop(10.0, timeout=5)
        self.assertIsNone(a.frame("added", 14.9))
        self.assertEqual(a.frame("added", 15.0), "timeout")

    def test_area_center_and_command(self):
        self.assertEqual(capture.area_center("10,20 161x241"), (90, 140))
        env = {"LOFT_POINTER": "/x/loft-pointer", "WAYLAND_DISPLAY": "wayland-7", "XDG_RUNTIME_DIR": "/run/s", "NIRI_SOCKET": "/run/n.sock"}
        with mock.patch.dict(os.environ, env, clear=True):
            cmd = capture.pointer_command((90, 140), (5.5, 6), 250)
        self.assertEqual(cmd[:6], ["/x/loft-pointer", "scroll", "--display", "/run/s/wayland-7", "--at", "90,140"])
        self.assertIn("--niri-socket", cmd)
        self.assertEqual(cmd[-2:], ["--restore", "5.5,6"])
        with mock.patch.dict(os.environ, {"LOFT_POINTER": "/x/loft-pointer"}, clear=True):
            with self.assertRaises(RuntimeError, msg="no display, no helper"):
                capture.pointer_command((1, 2), None)


class FakePointer:
    """Stands in for loft-pointer: placed on the first poll, then one notch
    per poll (the session polls once per frame)."""

    def __init__(self, at, restore, pace, self_stop=None):
        self.at, self.restore, self.pace = at, restore, pace
        self.sent: list[str] = []
        self.closed_with = None
        self.placed = False
        self.notches = 0
        self.self_stop = self_stop

    def fileno(self):
        return None if self.closed_with else 0

    def events(self):
        if not self.placed:
            self.placed = True
            return [{"event": "placed", "x": self.at[0], "y": self.at[1]}]
        if self.self_stop and self.notches >= 3:
            return [{"event": "stopped", "reason": self.self_stop, "notches": self.notches, "restored": True}]
        self.notches += 1
        return [{"event": "notch", "n": self.notches}]

    def send(self, line):
        self.sent.append(line)

    def close(self, cmd="stop"):
        self.closed_with = cmd
        return [{"event": "stopped", "reason": cmd, "notches": self.notches, "restored": cmd == "stop"}]


class AutoScrollSessionTest(unittest.TestCase):
    def run_session(self, doc, h, step, cmds, **pointer):
        made: list[FakePointer] = []
        clock = [0.0]

        def factory(at, restore, pace):
            made.append(FakePointer(at, restore, pace, **pointer))
            return made[-1]

        def grabber(geometry, path):
            clock[0] += 0.12
            off = min(made[0].notches * step, len(doc) - h) if made else 0
            stitch.write_ppm(path, frame(doc[off : off + h]))
            return True

        td = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, td)
        out = Path(td) / "auto.png"
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = capture.scroll_session(
                "10,20 160x240", Path(td) / "w", out, grabber=grabber, commands=iter(cmds), helper_factory=factory, clock=lambda: clock[0], restore_delay=0
            )
        events = [json.loads(line) for line in buf.getvalue().splitlines()]
        return code, events, made, out

    def test_scrolls_to_the_end_by_itself_and_restores_the_pointer(self):
        doc, h = document(900, seed=5), 240
        code, events, made, out = self.run_session(doc, h, 60, [None, "auto 700 950"] + [None] * 60 + ["done"])
        self.assertEqual(code, 0)
        p = made[0]
        self.assertEqual(p.at, (90, 140), "the middle of the area")
        self.assertEqual(p.restore, (700.0, 950.0))
        self.assertEqual(p.closed_with, "stop", "stop: the pointer goes back")
        auto = [(e["state"], e.get("reason")) for e in events if e["event"] == "auto"]
        self.assertEqual(auto, [("starting", None), ("running", None), ("stopping", "end"), ("stopped", "end")])
        stopped = [e for e in events if e["event"] == "auto" and e["state"] == "stopped"][0]
        self.assertTrue(stopped["restored"])
        # It stopped soon after the content ran out (11 notches of 60 rows).
        self.assertLess(stopped["notches"], 11 + 20)
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(stitch.read_png(out).data, b"".join(doc), "continuous, top to bottom")

    def test_abort_leaves_the_pointer_and_stop_restores_it(self):
        doc = document(900, seed=6)
        for cmd, reason, closed in (("abort", "pointer", "abort"), ("stop", "stop", "stop")):
            code, events, made, _ = self.run_session(doc, 240, 40, [None, "auto", None, None, cmd, None, "cancel"])
            self.assertEqual(code, 0)
            self.assertEqual(made[0].closed_with, closed)
            self.assertIsNone(made[0].restore)
            last = [e for e in events if e["event"] == "auto"][-1]
            self.assertEqual((last["state"], last["reason"]), ("stopped", reason))
            self.assertEqual(last["restored"], closed == "stop")
            self.assertEqual(events[-1]["event"], "cancelled")

    def test_done_while_running_stops_it_first(self):
        code, events, made, out = self.run_session(document(900, seed=7), 240, 40, [None, "auto", None, None, None, "done"])
        self.assertEqual(code, 0)
        self.assertEqual(made[0].closed_with, "stop")
        kinds = [(e["event"], e.get("state")) for e in events]
        self.assertLess(kinds.index(("auto", "stopped")), kinds.index(("done", None)))
        self.assertTrue(out.exists())

    def test_gaps_slow_it_down(self):
        _, _, made, _ = self.run_session(document(2000, seed=8), 240, 300, [None, "auto"] + [None] * 5 + ["cancel"])
        self.assertIn("interval 375", made[0].sent)

    def test_helper_stopping_by_itself_and_missing_helper(self):
        _, events, made, _ = self.run_session(document(900, seed=9), 240, 40, [None, "auto"] + [None] * 8 + ["cancel"], self_stop="timeout")
        last = [e for e in events if e["event"] == "auto"][-1]
        self.assertEqual((last["state"], last["reason"]), ("stopped", "timeout"))

        def missing(*_a):
            raise RuntimeError("loft-pointer is not installed")

        buf = io.StringIO()
        with tempfile.TemporaryDirectory() as td, redirect_stdout(buf):
            capture.scroll_session(
                "0,0 160x200",
                Path(td) / "w",
                Path(td) / "x.png",
                grabber=lambda g, p: stitch.write_ppm(p, frame(document(300)[:200])) or True,
                commands=iter([None, "auto", None, "cancel"]),
                helper_factory=missing,
            )
        auto = [json.loads(line) for line in buf.getvalue().splitlines() if '"auto"' in line]
        self.assertEqual(auto[-1]["reason"], "unavailable")


class PointerHelperTest(unittest.TestCase):
    """PointerHelper's pipes against a stand-in program (no Wayland)."""

    def test_events_and_stop(self):
        with tempfile.TemporaryDirectory() as td:
            prog = Path(td) / "fake-pointer"
            prog.write_text(
                f"#!{sys.executable}\n"
                "import json, sys\n"
                "print(json.dumps({'event': 'placed', 'x': 1, 'y': 2}), flush=True)\n"
                "print(json.dumps({'event': 'notch', 'n': 1}), flush=True)\n"
                "for line in sys.stdin:\n"
                "    if line.strip() in ('stop', 'abort'):\n"
                "        print(json.dumps({'event': 'stopped', 'reason': line.strip(), 'notches': 1, 'restored': line.strip() == 'stop'}), flush=True)\n"
                "        break\n"
            )
            prog.chmod(0o755)
            with mock.patch.dict(os.environ, {"LOFT_POINTER": str(prog), "WAYLAND_DISPLAY": "wayland-test"}):
                h = capture.start_pointer((1, 2), (3, 4), 250)
            seen = []
            for _ in range(100):
                seen += h.events()
                if len(seen) >= 2:
                    break
                time.sleep(0.02)
            self.assertEqual([e["event"] for e in seen], ["placed", "notch"])
            last = h.close("stop")
            self.assertEqual(last[-1], {"event": "stopped", "reason": "stop", "notches": 1, "restored": True})
            self.assertIsNone(h.fileno())


class ZoomMathTest(unittest.TestCase):
    SEGS = [{"start": 1.0, "end": 4.0, "zoom": 2.0, "x": 0.25, "y": 0.5}]

    def test_clean_segments(self):
        segs = capture.clean_segments(
            [
                {"start": 5, "end": 8, "zoom": 9, "x": 2, "y": -1},
                {"start": 1, "end": 6},
                {"start": 7.9, "end": 8.05},
            ],
            duration=7.5,
        )
        self.assertEqual(segs, [{"start": 1.0, "end": 6.0, "zoom": 2.0, "x": 0.5, "y": 0.5}, {"start": 6.0, "end": 7.5, "zoom": 4.0, "x": 1.0, "y": 0.0}])

    def test_curve_eases_in_and_out(self):
        self.assertEqual(capture.zoom_at(self.SEGS, 0.5)[0], 1.0)
        self.assertEqual(capture.zoom_at(self.SEGS, 1.0)[0], 1.0)
        mid = capture.zoom_at(self.SEGS, 1.3)[0]
        self.assertTrue(1.0 < mid < 2.0)
        self.assertEqual(capture.zoom_at(self.SEGS, 2.5)[0], 2.0)
        self.assertEqual(capture.zoom_at(self.SEGS, 4.0)[0], 1.0)
        # The viewport stays inside the frame at its edge.
        x, y, w, h = capture.viewport([{"start": 0, "end": 3, "zoom": 2, "x": 0.0, "y": 1.0}], 1.5, 320, 240)
        self.assertEqual((x, y, w, h), (0, 120, 160, 120))

    def test_expressions_match_the_curve(self):
        ex = capture.zoom_exprs(self.SEGS, 30)
        for t in (0.0, 1.2, 1.45, 2.5, 3.7, 5.0):
            env = {"W": 320.0, "H": 240.0, "in": t * 30}
            got = [_ffexpr(ex[k], env) for k in ("x0", "y0", "x3", "y3")]
            x, y, w, h = capture.viewport(self.SEGS, t, 320, 240)
            for a, b in zip(got, (x, y, x + w, y + h)):
                self.assertAlmostEqual(a, b, places=3, msg=f"t={t}")

    def test_segments_from_activity(self):
        ev = []
        # Pointer wanders around the top-left, clicks, a menu opens there.
        for i in range(25):
            ev.append({"t": 1 + i * 0.1, "x": 0.2 + (i % 5) * 0.01, "y": 0.3, "w": 0.03, "h": 0.04})
        ev.append({"t": 4.0, "scene": True})  # a scroll: no zoom
        # Typing at the bottom right for two seconds.
        for i in range(20):
            ev.append({"t": 6 + i * 0.1, "x": 0.7 + i * 0.005, "y": 0.8, "w": 0.02, "h": 0.02})
        # A lone blip.
        ev.append({"t": 10.0, "x": 0.5, "y": 0.5, "w": 0.01, "h": 0.01})
        segs = capture.segments_from_activity(ev, duration=12.0)
        self.assertEqual(len(segs), 2)
        a, b = segs
        self.assertAlmostEqual(a["start"], 0.5)
        self.assertLess(a["x"], 0.3)
        self.assertGreater(b["x"], 0.6)
        self.assertGreater(b["y"], 0.7)
        self.assertTrue(all(1.3 <= s["zoom"] <= 2.0 for s in segs))

    def test_activity_finds_local_changes_and_scenes(self):
        w, h = 40, 20
        blank = bytes(w * h)
        dot = bytearray(blank)
        for y in (4, 5):
            dot[y * w + 30 : y * w + 33] = b"\xff\xff\xff"
        full = bytes([200]) * (w * h)
        ev = capture.activity([blank, bytes(dot), bytes(dot), full], w, h, fps=10)
        self.assertEqual(len(ev), 2)
        self.assertAlmostEqual(ev[0]["x"], 31.5 / 40)
        self.assertAlmostEqual(ev[0]["y"], 5 / 20)
        self.assertTrue(ev[1]["scene"])


def _ffexpr(expr: str, env: dict) -> float:
    """Evaluate the subset of ffmpeg's expression language zoom_exprs uses."""
    funcs = {
        "if_": lambda c, a, b: a if c else b,
        "between": lambda x, a, b: 1.0 if a <= x <= b else 0.0,
        "clip": lambda x, a, b: min(max(x, a), b),
    }
    expr = re.sub(r"\bif\(", "if_(", re.sub(r"\bin\b", "in_", expr))
    env = {("in_" if k == "in" else k): v for k, v in env.items()}
    return float(eval(expr, {"__builtins__": {}}, {**funcs, **env}))  # noqa: S307 — our own expressions


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "needs ffmpeg")
class ZoomRenderTest(unittest.TestCase):
    def pixel(self, video: str, t: float, x: int, y: int, w: int = 320) -> tuple[int, ...]:
        raw = subprocess.run(
            ["ffmpeg", "-v", "error", "-ss", str(t), "-i", video, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            capture_output=True,
            check=True,
        ).stdout
        o = (y * w + x) * 3
        return tuple(raw[o : o + 3])

    def test_render_zooms_into_the_left_half(self):
        with tempfile.TemporaryDirectory() as td:
            src, out = f"{td}/in.mp4", f"{td}/in-zoomed.mp4"
            subprocess.run(
                [
                    "ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                    "color=0xd02020:s=320x240:d=4:r=30[a];color=0x2020d0:s=160x240:d=4:r=30[b];[a][b]overlay=160:0",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", src,
                ],
                check=True,
            )  # fmt: skip
            segs = [{"start": 1.0, "end": 3.5, "zoom": 2.0, "x": 0.25, "y": 0.5}]
            info = capture.probe(src)
            subprocess.run(capture.render_command(src, out, segs, info), check=True)
            self.assertAlmostEqual(capture.probe(out)["duration"], 4.0, delta=0.15)
            red = lambda p: p[0] > 150 and p[2] < 100  # noqa: E731
            blue = lambda p: p[2] > 150 and p[0] < 100  # noqa: E731
            self.assertTrue(blue(self.pixel(out, 0.3, 300, 120)), "unzoomed before the segment")
            self.assertTrue(red(self.pixel(out, 2.2, 300, 120)), "zoomed into the red half")
            self.assertTrue(blue(self.pixel(src, 2.2, 300, 120)), "the original is untouched")
            self.assertEqual(capture.zoomed_name(src), f"{td}/in-zoomed-2.mp4")


if __name__ == "__main__":
    unittest.main()
