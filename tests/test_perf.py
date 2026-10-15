"""Video wallpaper copies (cli/loft/wallvideo.py) and `loft doctor perf` (cli/loft/doctor.py)."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from loft import doctor, wallvideo

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None


class PlanTest(unittest.TestCase):
    INFO = {"codec": "hevc", "width": 5120, "height": 2560, "pix_fmt": "yuv420p10le"}

    def test_ultrawide_crop_keeps_full_width(self):
        # 5120x1440 screen covering a 2:1 frame: full width, the middle 56 %.
        p = wallvideo.plan(self.INFO, (0, 0.21875, 1, 0.5625), (5120, 1440))
        self.assertEqual((p["cw"], p["ch"]), (5120, 1440))
        self.assertEqual((p["cx"], p["cy"]), (0, 560))
        self.assertEqual((p["tw"], p["th"]), (5120, 1440))

    def test_downscales_to_the_screen(self):
        p = wallvideo.plan(self.INFO, (0.1, 0, 0.5625, 1), (1440, 2560))
        self.assertEqual((p["tw"], p["th"]), (1440, 2560))
        self.assertLessEqual(p["cx"] + p["cw"], 5120)

    def test_never_upscales_and_stays_even(self):
        small = {"codec": "h264", "width": 1000, "height": 500, "pix_fmt": "yuv420p"}
        p = wallvideo.plan(small, (0, 0, 1, 1), (2560, 1440))
        self.assertLessEqual(p["tw"], 1000)
        self.assertLessEqual(p["th"], 500)
        self.assertEqual(p["tw"] % 2, 0)
        self.assertEqual(p["th"] % 2, 0)

    def test_crop_is_clamped_inside_the_frame(self):
        p = wallvideo.plan(self.INFO, (0.9, 0.9, 0.5, 0.5), (640, 320))
        self.assertLessEqual(p["cx"] + p["cw"], 5120)
        self.assertLessEqual(p["cy"] + p["ch"], 2560)

    def test_worth_it(self):
        eight = {"codec": "h264", "width": 2560, "height": 1440, "pix_fmt": "yuv420p"}
        same = wallvideo.plan(eight, (0, 0, 1, 1), (2560, 1440))
        self.assertFalse(wallvideo.worth_it(eight, same))  # nothing to gain
        self.assertTrue(wallvideo.worth_it(self.INFO, wallvideo.plan(self.INFO, (0, 0, 1, 1), (5120, 2560))))  # 10-bit → 8-bit
        smaller = wallvideo.plan(eight, (0, 0, 1, 1), (1280, 720))
        self.assertTrue(wallvideo.worth_it(eight, smaller))


@unittest.skipUnless(HAVE_FFMPEG, "needs ffmpeg")
class MakeVariantTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.src = self.tmp / "clip.mp4"
        subprocess.run(
            ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=512x256:rate=24", "-t", "1",
             "-pix_fmt", "yuv420p", "-c:v", "libx264", str(self.src)],
            check=True,
        )
        self.env = mock.patch.dict(os.environ, {"LOFT_VIDEO_CACHE": str(self.tmp / "cache")})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.tmp)

    def test_makes_once_then_caches(self):
        r = wallvideo.make_variant(self.src, (0, 0.25, 1, 0.5), (256, 64), force_software=True)
        self.assertFalse(r["cached"])
        out = Path(r["path"])
        self.assertTrue(out.is_file())
        self.assertEqual(out.parent, self.tmp / "cache")
        probe = wallvideo.probe(out)
        self.assertEqual((probe["width"], probe["height"]), (256, 64))
        self.assertEqual(probe["pix_fmt"], "yuv420p")
        again = wallvideo.make_variant(self.src, (0, 0.25, 1, 0.5), (256, 64), force_software=True)
        self.assertTrue(again["cached"])
        self.assertEqual(again["path"], r["path"])
        self.assertTrue(self.src.is_file())  # the original is never touched

    def test_original_when_no_gain(self):
        r = wallvideo.make_variant(self.src, (0, 0, 1, 1), (512, 256), force_software=True)
        self.assertTrue(r.get("useOriginal"))
        self.assertEqual(Path(r["path"]), self.src.resolve())


class DoctorTest(unittest.TestCase):
    def test_names(self):
        self.assertEqual(doctor._name(["/nix/store/x/bin/python3", "-B", "/a/cli/loft", "island", "downloads", "--watch"]), "python3 loft island downloads")
        self.assertEqual(doctor._name(["/run/current-system/sw/bin/nmcli", "monitor"]), "nmcli monitor")
        self.assertEqual(doctor._name(["inotifywait", "-m", "-q", "-e", "create,delete", "--format", "%e", "/home/u/Downloads"]), "inotifywait %e Downloads")

    def test_verdicts(self):
        kid = lambda pid, argv, state="S": {"pid": pid, "state": state, "name": doctor._name(argv), "argv": argv}
        ok = {"lag": {"p99": 4}, "cpu": 3, "videos": {"playing": 3}}
        self.assertEqual(doctor.verdicts(ok, [kid(1, ["nmcli", "monitor"])], 0), [])
        dup = doctor.verdicts(ok, [kid(1, ["nmcli", "monitor"]), kid(2, ["nmcli", "monitor"]), kid(3, ["sh", "-c", "x"]), kid(4, ["sh", "-c", "x"])], 0)
        self.assertEqual(len(dup), 1)
        self.assertIn("nmcli monitor ×2", dup[0])
        slow = doctor.verdicts({"lag": {"p99": 120}, "cpu": 97, "videos": {"playing": 3}}, [], 40)
        self.assertEqual(len(slow), 3)
        zombies = doctor.verdicts(ok, [kid(i, ["wl-paste"], "Z") for i in range(5)], 0)
        self.assertEqual(len(zombies), 1)


if __name__ == "__main__":
    unittest.main()
