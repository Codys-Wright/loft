"""Unit tests for wallpaper sets (cli/studio/wallsets.py, `studio wallpaper …`):
display roles and set resolution (the fixture shared with
tests/wallsets.test.js), image framing, auto picks, pack `wallpaperSets`
(format, validation, render, export) and the CLI against a scratch state.
Offline: images are generated here and ffmpeg is disabled.
"""

from __future__ import annotations

import json
import os
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from studio import palette, wallsets
from studio.pack import Pack, PackError, normalized_manifest
from test_importers import make_png
from test_vibes import HAVE_JSONSCHEMA, ROOT, studio, write

FIXTURE = json.loads((ROOT / "tests" / "fixtures" / "wallsets" / "layouts.json").read_text())
CODY = FIXTURE["cases"][0]["layout"]

NIGHT = {
    "bg": "#1a1b26", "surface": "#24283b", "overlay": "#414868", "text": "#c0caf5", "subtext": "#a9b1d6",
    "accent": "#7aa2f7", "accent2": "#bb9af7", "urgent": "#f7768e", "ok": "#9ece6a", "warn": "#e0af68",
}  # fmt: skip
DAY = dict(NIGHT, bg="#e1e2e7", surface="#d0d5e3", text="#3760bf", accent="#2e7de9", accent2="#9854f1")

NAVY = (22, 24, 40)


def blob(cx: float, cy: float, rgb=(90, 140, 255), r: float = 0.12, w: int = 64, h: int = 36, bg=NAVY):
    """A dark image with one bright disc centered at (cx, cy) (fractions)."""

    def px(x, y):
        dx, dy = (x + 0.5) / w - cx, ((y + 0.5) / h - cy) * h / w
        return rgb if dx * dx + dy * dy < r * r else bg

    return make_png(w, h, px)


def two_blobs(w: int = 64, h: int = 36):
    def px(x, y):
        for cx in (0.08, 0.92):
            dx, dy = (x + 0.5) / w - cx, ((y + 0.5) / h - 0.5) * h / w
            if dx * dx + dy * dy < 0.085**2:
                return (90, 140, 255)
        return NAVY

    return make_png(w, h, px)


class Roles(unittest.TestCase):
    """The same expectations as tests/wallsets.test.js."""

    def test_fixture(self):
        for c in FIXTURE["cases"]:
            lay = c["layout"]
            self.assertEqual(wallsets.roles(lay["outputs"], lay["main"]), c["roles"], c["name"])
            self.assertEqual(wallsets.resolve_set(c["set"], lay), c["resolved"], c["name"])
            self.assertEqual(wallsets.coverage(c["set"], lay), c["coverage"], c["name"])
            if "effective" in c:
                self.assertEqual(wallsets.capture("saved", lay, c["effective"]), c["captured"], c["name"])

    def test_capture_round_trip(self):
        c = FIXTURE["cases"][0]
        back = wallsets.resolve_set(wallsets.capture("x", c["layout"], c["effective"]), c["layout"])
        self.assertEqual(back["displays"], c["effective"]["displays"])
        for k, p in back["workspaces"].items():
            self.assertEqual(p, c["effective"]["workspaces"][k])

    def test_best_set(self):
        sets = [{"name": "one", "displays": {"main": "/a"}}, {"name": "three", "displays": {"main": "/a", "left": "/b", "right": "/c"}}]
        self.assertEqual(wallsets.best_set(sets, CODY)["name"], "three")
        self.assertIsNone(wallsets.best_set([{"name": "any", "displays": {"*": "/a"}}], CODY))

    def test_layout_from_niri(self):
        outs = {
            "DP-4": {"make": "Microstep", "model": "MPG491CX OLED", "serial": None, "logical": {"x": 1440, "y": 0, "width": 5120, "height": 1440}},
            "HDMI-A-1": {"make": "X", "model": "Y", "serial": "Z", "logical": None},
        }
        wss = [{"id": 1, "idx": 1, "name": "main", "output": "DP-4"}, {"id": 2, "idx": 2, "name": None, "output": "DP-4"}]
        lay = wallsets.layout_from_niri(outs, wss, "DP-4")
        self.assertEqual([o["identity"] for o in lay["outputs"]], ["Microstep MPG491CX OLED Unknown"])  # disabled one left out
        self.assertEqual(lay["workspaces"][1], {"output": "DP-4", "idx": 2, "name": ""})


class Framing(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.noff = mock.patch.object(palette, "have_ffmpeg", return_value=False)
        self.noff.start()

    def tearDown(self):
        self.noff.stop()
        shutil.rmtree(self.tmp)

    def test_image_size(self):
        self.assertEqual(wallsets.image_size(write(self.tmp / "a.png", make_png(7, 3, lambda x, y: NAVY))), (7, 3))
        # A baseline JPEG header: SOI, APP0, SOF0 (height 1600, width 3832).
        jpeg = b"\xff\xd8" + b"\xff\xe0\x00\x04ab" + b"\xff\xc0\x00\x11\x08\x06\x40\x0e\xf8\x03" + b"\x00" * 9
        self.assertEqual(wallsets.image_size(write(self.tmp / "b.jpg", jpeg)), (3832, 1600))
        gif = b"GIF89a" + (300).to_bytes(2, "little") + (200).to_bytes(2, "little")
        self.assertEqual(wallsets.image_size(write(self.tmp / "c.gif", gif)), (300, 200))
        self.assertIsNone(wallsets.image_size(write(self.tmp / "d.txt", "nope")))

    def test_focus_follows_the_subject(self):
        left = wallsets.framing(write(self.tmp / "l.png", blob(0.2, 0.5)))
        right = wallsets.framing(write(self.tmp / "r.png", blob(0.8, 0.3)))
        self.assertEqual(left["size"], [64, 36])
        self.assertLess(left["focus"][0], 0.3)
        self.assertGreater(right["focus"][0], 0.7)
        self.assertLess(right["focus"][1], 0.45)
        self.assertAlmostEqual(sum(left["cols"]), 1.0, places=2)
        self.assertEqual(len(left["rows"]), wallsets.FRAMING_BINS)

    def test_interest_kept(self):
        single = wallsets.framing(write(self.tmp / "s.png", blob(0.3, 0.5)))
        spread = wallsets.framing(write(self.tmp / "t.png", two_blobs()))
        portrait = 1440 / 2560
        self.assertGreater(wallsets.interest_kept(single, portrait), 0.8)  # cropped around its subject
        self.assertLess(wallsets.interest_kept(spread, portrait), 0.6)  # one subject at each edge
        self.assertEqual(wallsets.interest_kept(single, 64 / 36), 1.0)  # same shape: nothing lost
        self.assertEqual(wallsets.interest_kept(None, portrait), 1.0)
        self.assertEqual(wallsets.crop_window(0.05, 0.3), (0.0, 0.3))
        self.assertEqual(wallsets.crop_window(0.95, 0.3), (0.7, 1.0))


class Plan(unittest.TestCase):
    """`studio wallpaper …` over a scratch theme path and state."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.packs = self.tmp / "packs"
        self.state = self.tmp / "state"
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "STUDIO_STATE_DIR": str(self.state),
                "STUDIO_HOOKS": "none",
                "STUDIO_THEME_PATH": str(self.packs),
                "STUDIO_THEME_INDEX": "none",
                "STUDIO_LIBRARY": "none",
            }
        )
        self.noff = mock.patch.object(palette, "have_ffmpeg", return_value=False)
        self.noff.start()
        night = self.packs / "night"
        write(night / "manifest.json", {"name": "night", "author": "t", "version": "1.0.0", "license": "CC0-1.0"})
        walls = {
            "w1.png": blob(0.5, 0.5),
            "w2.png": blob(0.3, 0.4, (110, 120, 250)),
            "w3.png": blob(0.7, 0.6, (70, 150, 240)),
            "w4.png": blob(0.5, 0.3, (120, 100, 230)),
            "w5.png": blob(0.4, 0.7, (80, 130, 255)),
            "w6.png": blob(0.6, 0.5, (100, 160, 250), r=0.15),
            "w7.png": blob(0.5, 0.5, (60, 110, 230), r=0.1),
            "spread.png": two_blobs(),
            "light.png": make_png(64, 36, lambda x, y: (225, 226, 231) if (x + y) % 5 else (46, 125, 233)),
        }
        for name, data in walls.items():
            write(night / "wallpapers" / name, data)
        theme = {
            "polarity": "dark",
            "palette": NIGHT,
            "wallpaper": {"image": "wallpapers/w1.png"},
            "wallpaperSets": [
                {"name": "pair", "displays": {"main": "wallpapers/w2.png", "left": "wallpapers/w3.png"}},
                {"name": "trio", "displays": {"main": "wallpapers/w4.png", "left": "wallpapers/w5.png", "right": "wallpapers/w6.png"}, "workspaces": {"music": "wallpapers/w7.png"}},
            ],
        }
        write(night / "theme.json", theme)
        day = self.packs / "day"
        write(day / "manifest.json", {"name": "day", "author": "t", "version": "1.0.0", "license": "CC0-1.0"})
        write(day / "theme.json", {"polarity": "light", "palette": DAY})
        write(day / "wallpapers" / "d.png", make_png(64, 36, lambda x, y: (230, 232, 240)))
        self.layout = self.tmp / "layout.json"
        write(self.layout, CODY)

    def tearDown(self):
        self.noff.stop()
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def run_ok(self, *argv) -> str:
        rc, out, err = studio(*argv)
        self.assertEqual(rc, 0, err)
        return out

    def plan(self, *extra) -> dict:
        return json.loads(self.run_ok("wallpaper", "plan", "--theme", "night", "--layout", f"@{self.layout}", "--json", *extra))

    def shell(self) -> dict:
        return json.loads((self.state / "overrides" / "shell.json").read_text())

    def test_auto_picks(self):
        p = self.plan()
        self.assertEqual(p["tone"], "Dark")
        self.assertTrue(p["autoDefault"])
        self.assertTrue(p["auto"])
        pool = {Path(c["path"]).name for c in p["pool"]}
        self.assertIn("light.png", pool)  # the theme's own, for the picker — but never auto-picked
        # The pack's set covering all three displays fills the displays (no explicit choices).
        self.assertEqual(p["packSet"]["name"], "trio")
        self.assertEqual(Path(p["packSet"]["workspaces"]["music"]).name, "w7.png")
        self.assertEqual(p["displays"], {})  # every display has a base from the set
        picks = list(p["workspaces"].values())
        names = {Path(x).name for x in picks}
        self.assertNotIn("light.png", names)
        self.assertNotIn("d.png", names)  # the light theme's
        # Workspace 1 shows the base; music has the set's; the rest get auto picks.
        self.assertEqual(set(p["workspaces"]), {"Microstep MPG491CX OLED Unknown#5", "recording", "notes", "Acer Technologies XV271U M3 1321033793LAJ#4"})
        self.assertEqual(len(set(picks)), len(picks))  # distinct while the pool lasts
        used = {Path(x).name for x in p["packSet"]["displays"].values()}
        self.assertFalse(used & names)  # and different from the bases
        self.assertEqual(self.plan(), p)  # deterministic
        self.assertIn("w4.png", " ".join(p["framing"]))  # set images get framing too

    def test_explicit_choices_keep_the_pack_set_out(self):
        night = self.packs / "night" / "wallpapers"
        choices = {"displays": {"Microstep MPG491CX OLED Unknown": str(night / "w2.png")}, "sameAll": {"Acer Technologies XV271U M3 13210337C3LAJ": True}}
        p = self.plan("--choices", json.dumps(choices))
        # The other two displays get auto bases; the right one shows its base everywhere.
        self.assertEqual(set(p["displays"]), {"Acer Technologies XV271U M3 1321033793LAJ", "Acer Technologies XV271U M3 13210337C3LAJ"})
        self.assertNotIn("recording", p["workspaces"])
        self.assertIn("music", p["workspaces"])
        self.assertNotIn(str(night / "w2.png"), p["workspaces"].values())
        self.assertNotIn("light.png", {Path(x).name for x in list(p["workspaces"].values()) + list(p["displays"].values())})

    def test_shuffle_reseeds(self):
        choices = {"displays": {"Microstep MPG491CX OLED Unknown": str(self.packs / "night" / "wallpapers" / "w2.png")}}
        seen = set()
        for seed in range(6):
            p = self.plan("--choices", json.dumps(dict(choices, autoSeed=seed)))
            seen.add(json.dumps([p["displays"], p["workspaces"]], sort_keys=True))
        self.assertGreater(len(seen), 1)

    def test_portrait_prefers_a_croppable_image(self):
        lay = {"outputs": [{"name": "DP-5", "identity": "P", "x": 0, "y": 0, "width": 1440, "height": 2560}], "main": "", "workspaces": []}
        write(self.layout, lay)
        for seed in range(6):
            p = self.plan("--choices", json.dumps({"autoSeed": seed}))
            self.assertNotEqual(Path(p["displays"]["P"]).name, "spread.png", seed)
            self.assertIsNone(p["packSet"])  # one display: packs' sets stay out
        kept = {Path(c["path"]).name: c["kept"]["P"] for c in p["pool"]}
        self.assertLess(kept["spread.png"], kept["w1.png"])

    def test_auto_default_needs_enough_images(self):
        for n in ("w3", "w4", "w5", "w6", "w7"):
            (self.packs / "night" / "wallpapers" / f"{n}.png").unlink()
        theme = json.loads((self.packs / "night" / "theme.json").read_text())
        theme.pop("wallpaperSets")
        write(self.packs / "night" / "theme.json", theme)
        p = self.plan()
        self.assertFalse(p["autoDefault"])
        self.assertFalse(p["auto"])
        self.assertTrue(self.plan("--choices", '{"auto": true}')["auto"])

    def test_sets_cli(self):
        night = self.packs / "night" / "wallpapers"
        lay = ["--theme", "night", "--layout", f"@{self.layout}"]
        out = self.run_ok("wallpaper", "sets", "--theme", "night")
        self.assertIn("pair", out)
        self.assertIn("trio", out)
        # Apply a pack's set: explicit display + workspace choices by identity.
        self.run_ok("wallpaper", "set", "apply", "trio", *lay)
        c = self.shell()["perTheme"]["night"]
        self.assertEqual(c["activeSet"], "trio")
        self.assertEqual(c["displays"]["Acer Technologies XV271U M3 13210337C3LAJ"], str(night / "w6.png"))
        self.assertEqual(c["workspaces"], {"music": str(night / "w7.png")})
        # Save what is on screen (incl. auto picks), then apply it back after a change.
        self.run_ok("wallpaper", "set", "save", "mine", *lay)
        c = self.shell()["perTheme"]["night"]
        mine = next(s for s in c["sets"] if s["name"] == "mine")
        self.assertEqual(mine["displays"], {"left": str(night / "w5.png"), "main": str(night / "w4.png"), "right": str(night / "w6.png")})
        self.assertEqual(mine["workspaces"]["music"], str(night / "w7.png"))
        self.assertIn("main#5", mine["workspaces"])  # an auto pick, captured by role
        self.run_ok("wallpaper", "set", "apply", "pair", *lay)
        self.assertNotIn("Acer Technologies XV271U M3 13210337C3LAJ", self.shell()["perTheme"]["night"]["displays"])
        self.run_ok("wallpaper", "set", "apply", "mine", *lay)
        c = self.shell()["perTheme"]["night"]
        self.assertEqual(c["displays"]["Acer Technologies XV271U M3 13210337C3LAJ"], str(night / "w6.png"))
        self.assertEqual(c["workspaces"]["Microstep MPG491CX OLED Unknown#5"], mine["workspaces"]["main#5"])
        sets = json.loads(self.run_ok("wallpaper", "sets", "--theme", "night", "--json"))
        self.assertEqual([(s["name"], s["origin"]) for s in sets["sets"]], [("pair", "pack"), ("trio", "pack"), ("mine", "user")])
        self.assertEqual(sets["activeSet"], "mine")
        # Delete: saved ones only.
        self.assertEqual(studio("wallpaper", "set", "delete", "trio", "--theme", "night")[0], 1)
        self.run_ok("wallpaper", "set", "delete", "mine", "--theme", "night")
        self.assertNotIn("activeSet", self.shell()["perTheme"]["night"])
        self.assertEqual(studio("wallpaper", "set", "apply", "nope", *lay)[0], 1)

    def test_shuffle_and_auto_cli(self):
        write(self.state / "overrides" / "shell.json", {"dock": {"iconSize": 40}, "perTheme": {"night": {"rotate": 5}}})
        self.run_ok("wallpaper", "shuffle", "--theme", "night")
        self.run_ok("wallpaper", "shuffle", "--theme", "night")
        self.run_ok("wallpaper", "auto", "off", "--theme", "night")
        s = self.shell()
        self.assertEqual(s["dock"], {"iconSize": 40})  # the rest of the file is kept
        self.assertEqual(s["perTheme"]["night"], {"rotate": 5, "autoSeed": 2, "auto": False})
        self.assertFalse(self.plan()["auto"])
        self.run_ok("wallpaper", "auto", "default", "--theme", "night")
        self.assertNotIn("auto", self.shell()["perTheme"]["night"])

    def test_text_plan(self):
        out = self.run_ok("wallpaper", "plan", "--theme", "night", "--layout", f"@{self.layout}")
        self.assertIn("DP-4", out)
        self.assertIn("[main, ultrawide, display-2]", out)
        self.assertIn("music", out)

    def test_save_into_a_pack(self):
        lay = ["--theme", "night", "--layout", f"@{self.layout}"]
        loose = write(self.tmp / "Pictures" / "far.png", blob(0.5, 0.5, (100, 120, 240)))
        write(
            self.state / "overrides" / "shell.json",
            {"perTheme": {"night": {"displays": {"Microstep MPG491CX OLED Unknown": str(loose)}, "sameAll": {k["identity"]: True for k in CODY["outputs"]}}}},
        )
        mine = self.packs / "mine"
        shutil.copytree(self.packs / "night", mine)
        m = json.loads((mine / "manifest.json").read_text())
        write(mine / "manifest.json", dict(m, name="mine"))
        self.run_ok("wallpaper", "set", "save", "desk", *lay, "--pack", str(mine))
        theme = json.loads((mine / "theme.json").read_text())
        desk = next(s for s in theme["wallpaperSets"] if s["name"] == "desk")
        self.assertEqual(desk["displays"]["main"], "wallpapers/far.png")  # copied in, relative
        self.assertTrue((mine / "wallpapers" / "far.png").is_file())
        self.assertTrue(desk["displays"]["left"].startswith("wallpapers/"))
        self.assertNotIn("workspaces", desk)  # "same on all workspaces" everywhere
        if HAVE_JSONSCHEMA:
            self.run_ok("theme", "validate", str(mine))


class PackFormat(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        os.environ.update({"HOME": str(self.tmp / "home"), "STUDIO_THEME_INDEX": "none", "STUDIO_LIBRARY": "none", "STUDIO_STATE_DIR": str(self.tmp / "state")})
        d = self.tmp / "p"
        write(d / "manifest.json", {"name": "p", "author": "t", "version": "1.0.0", "license": "CC0-1.0"})
        write(d / "wallpapers" / "a.png", blob(0.5, 0.5))
        write(d / "sets" / "b.png", blob(0.2, 0.5))
        self.theme = {
            "palette": NIGHT,
            "wallpaperSets": [{"name": "desk", "description": "two screens", "displays": {"main": "wallpapers/a.png", "left": "sets/b.png"}, "workspaces": {"music": "sets/b.png", "main#2": "/abs/elsewhere.png"}}],
        }
        write(d / "theme.json", self.theme)
        self.dir = d

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def test_parse_and_manifest(self):
        pack = Pack(self.dir)
        (s,) = pack.wallpaper_sets()
        self.assertEqual(s["displays"]["left"], self.dir.resolve() / "sets" / "b.png")
        self.assertEqual(s["workspaces"]["main#2"], Path("/abs/elsewhere.png"))
        m = normalized_manifest(pack)
        self.assertEqual(m["wallpaperSets"][0]["displays"]["main"], str(self.dir.resolve() / "wallpapers" / "a.png"))
        # Packs without sets: no key (the built-ins' goldens are unchanged).
        write(self.dir / "theme.json", {"palette": NIGHT})
        self.assertNotIn("wallpaperSets", normalized_manifest(Pack(self.dir)))

    def test_render(self):
        out = self.tmp / "out"
        rc, _, err = studio("theme", "render", str(self.dir), str(out))
        self.assertEqual(rc, 0, err)
        m = json.loads((out / "manifest.json").read_text())
        self.assertEqual(m["wallpaperSets"][0]["name"], "desk")
        self.assertNotIn("wallpaperSets", json.loads((out / "theme.json").read_text()))

    def test_validate(self):
        schema = ROOT / "themes" / "schema.json"
        Pack(self.dir).validate(schema, require_manifest=True)
        bad = json.loads(json.dumps(self.theme))
        bad["wallpaperSets"][0]["displays"]["left"] = "sets/missing.png"
        bad["wallpaperSets"].append({"name": "desk", "displays": {"sideways": "wallpapers/a.png"}})
        write(self.dir / "theme.json", bad)
        with self.assertRaises(PackError) as e:
            Pack(self.dir).validate(schema)
        msg = str(e.exception)
        self.assertIn("wallpaperSets/0/displays/left: sets/missing.png not found", msg)
        self.assertIn("'desk' is used twice", msg)
        self.assertIn("sideways", msg)  # an unknown role (schema or basic check)
        with mock.patch.dict("sys.modules", {"jsonschema": None}):  # the bare-python3 fallback
            with self.assertRaises(PackError) as e:
                Pack(self.dir).validate(schema)
            self.assertIn("wallpaperSets/1/displays/sideways: unknown display role", str(e.exception))

    @unittest.skipUnless(HAVE_JSONSCHEMA, "needs jsonschema")
    def test_schema(self):
        rc, out, err = studio("theme", "validate", str(self.dir))
        self.assertEqual(rc, 0, err)
        bad = json.loads(json.dumps(self.theme))
        bad["wallpaperSets"][0]["extra"] = 1
        write(self.dir / "theme.json", bad)
        rc, _, err = studio("theme", "validate", str(self.dir))
        self.assertEqual(rc, 1)
        self.assertIn("wallpaperSets/0", err)

    def test_export_carries_set_images(self):
        os.environ["STUDIO_THEME_PATH"] = str(self.tmp)
        out = self.tmp / "p.tar.gz"
        rc, _, err = studio("theme", "export", "p", "-o", str(out))
        self.assertEqual(rc, 0, err)
        with tarfile.open(out) as tf:
            names = tf.getnames()
        self.assertIn("p/sets/b.png", names)
        self.assertIn("p/wallpapers/a.png", names)
        # …and installs back as a valid pack.
        rc, _, err = studio("theme", "install", str(out))
        self.assertEqual(rc, 0, err)


if __name__ == "__main__":
    unittest.main()
