"""Capture helpers (cli/loft/capture.py): the scrolling-capture session loop
with a fake grabber, the zoom curve and its ffmpeg expressions, finding zoom
segments in activity, and a real zoomed export of a generated video.
"""

from __future__ import annotations

import io
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

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
