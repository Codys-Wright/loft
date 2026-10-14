"""Unit tests for the library (cli/studio/library.py): color buckets, the
generated symlink views (idempotent, never touching real files or links it
didn't make), `add`, and the library as theme path / install target / vibes
source. Offline: images are generated here and ffmpeg is disabled.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from studio import library, palette
from test_importers import make_png
from test_vibes import GREEN_DARK, PINK_DARK, make_pack, studio, write

BLUE = (40, 80, 170)
PINK = (235, 120, 170)
GREEN = (40, 150, 60)
GRAY = (120, 120, 120)


def stripes(a, b):
    return lambda x, y: a if x % 2 else b


class Buckets(unittest.TestCase):
    def test_families(self):
        self.assertEqual(library.swatch_family("#808080")[0], None)
        for c, fam in [
            ("#2850aa", "Blue"),
            ("#1e7486", "Teal"),
            ("#3c9a3c", "Green"),
            ("#e0c040", "Yellow"),
            ("#ef9a5e", "Orange"),
            ("#642401", "Orange"),  # dark but glowing: ember
            ("#7d4520", "Brown"),  # dark, dull orange
            ("#c81e1e", "Red"),
            ("#b58a95", "Pink"),  # dusty rose
            ("#7d1d76", "Purple"),
            ("#6a3cb4", "Purple"),
            ("#e070b0", "Pink"),
        ]:
            self.assertEqual(library.swatch_family(c)[0], fam, c)

    def test_classify(self):
        c = library.classify([["#2850aa", 0.7], ["#101010", 0.3]])
        self.assertEqual(c["colors"], ["Blue"])
        self.assertEqual(c["tone"], "Dark")
        # Two strong families: both folders, stronger first.
        c = library.classify([["#2850aa", 0.5], ["#e07a30", 0.4], ["#ffffff", 0.1]])
        self.assertEqual(c["colors"], ["Blue", "Orange"])
        # A weak second family doesn't count.
        self.assertEqual(library.classify([["#2850aa", 0.8], ["#e07a30", 0.05], ["#202020", 0.15]])["colors"], ["Blue"])
        # Barely colored: Monochrome; light.
        c = library.classify([["#d8d8dc", 0.8], ["#c8c4c0", 0.2]])
        self.assertEqual((c["colors"], c["tone"]), (["Monochrome"], "Light"))


class Views(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.lib = self.tmp / "Themes"
        self.state = self.tmp / "state"
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "STUDIO_STATE_DIR": str(self.state),
                "STUDIO_HOOKS": "none",
                "STUDIO_THEME_INDEX": "none",
                "STUDIO_LIBRARY": str(self.lib),
            }
        )
        for k in ("STUDIO_THEME_PATH", "STUDIO_DATA_DIR"):
            os.environ.pop(k, None)
        self.noff = mock.patch.object(palette, "have_ffmpeg", return_value=False)
        self.noff.start()
        packs = self.lib / "Packs"
        pink = make_pack(packs, "pinky", PINK_DARK, theme={"wallpaper": {"image": "wallpapers/p.png"}})
        write(pink / "wallpapers" / "p.png", make_png(8, 8, stripes(PINK, (40, 39, 56))))
        make_pack(packs, "forest", GREEN_DARK)
        self.topic = self.lib / "Wallpapers" / "Topics" / "Sea"
        write(self.topic / "blue.png", make_png(8, 8, lambda x, y: BLUE))
        write(self.topic / "night" / "deep.png", make_png(8, 8, lambda x, y: (10, 20, 60)))
        write(self.topic / "gray.png", make_png(8, 8, lambda x, y: GRAY))
        write(self.topic / "notes.txt", "not an image")
        write(self.lib / "Wallpapers" / "Topics" / "Woods" / "green.png", make_png(8, 8, stripes(GREEN, BLUE)))

    def tearDown(self):
        self.noff.stop()
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def sort(self) -> dict:
        rc, out, err = studio("library", "sort", "--json")
        self.assertEqual(rc, 0, err)
        return json.loads(out)

    def links(self) -> dict[str, str]:
        out = {}
        for p in (self.lib / "Wallpapers").rglob("*"):
            if p.is_symlink():
                out[str(p.relative_to(self.lib))] = os.path.realpath(p)
        return out

    def test_sort(self):
        real = sorted(str(p) for p in self.lib.rglob("*") if p.is_file() and not p.is_symlink())
        idx = self.sort()
        by_name = {r["name"]: r for r in idx["images"]}
        self.assertEqual(set(by_name), {"blue.png", "deep.png", "gray.png", "green.png", "p.png"})
        self.assertEqual(by_name["blue.png"]["colors"], ["Blue"])
        self.assertEqual(by_name["gray.png"]["colors"], ["Monochrome"])
        self.assertEqual(by_name["green.png"]["colors"], ["Green", "Blue"])
        self.assertEqual(by_name["p.png"]["source"], "pack")
        self.assertEqual(by_name["deep.png"]["label"], "Sea - night")
        self.assertEqual([t["name"] for t in idx["topics"]], ["Sea", "Woods"])

        links = self.links()
        blue = str(self.topic / "blue.png")
        self.assertEqual(links["Wallpapers/Colors/Blue/Sea - blue.png"], blue)
        self.assertEqual(links["Wallpapers/Colors/Green/Woods - green.png"], links["Wallpapers/Colors/Blue/Woods - green.png"])
        self.assertIn("Wallpapers/Colors/Monochrome/Sea - gray.png", links)
        self.assertIn("Wallpapers/Tones/Dark/Sea - night - deep.png", links)
        self.assertIn("Wallpapers/Colors/Pink/pinky - p.png", links)
        # Relative links inside the library.
        self.assertFalse(os.readlink(self.lib / "Wallpapers/Colors/Blue/Sea - blue.png").startswith("/"))
        # A theme's own wallpaper is always in its view.
        pinky = next(t for t in idx["themes"] if t["name"] == "pinky")
        self.assertEqual(pinky["images"][0]["origin"], "own")
        self.assertIn("Wallpapers/Themes/pinky/pinky - p.png", links)
        self.assertIn("tokyonight", [t["name"] for t in idx["themes"]])  # built-ins get views too
        self.assertTrue((self.lib / "README.md").read_text().startswith(library.README_MARK))
        # Real files untouched.
        self.assertEqual(real, sorted(str(p) for p in self.lib.rglob("*") if p.is_file() and not p.is_symlink() and p.name not in ("README.md", library.MANIFEST)))

        # Idempotent.
        again = self.sort()
        self.assertEqual(again["changes"], {"created": 0, "removed": 0})
        self.assertEqual(self.links(), links)

        # status reads the saved index.
        rc, out, _ = studio("library", "status")
        self.assertEqual(rc, 0)
        self.assertIn("Sea", out)

    def test_only_own_links_are_removed(self):
        self.sort()
        blue_dir = self.lib / "Wallpapers" / "Colors" / "Blue"
        mine = write(blue_dir / "Sea - blue.png.keep", b"real file")
        foreign_link = blue_dir / "my link.png"
        foreign_link.symlink_to(self.topic / "gray.png")
        # A real file where sort wants to put a link: the link gets another name.
        (self.lib / "Wallpapers/Colors/Monochrome/Sea - gray.png").unlink()
        write(self.lib / "Wallpapers/Colors/Monochrome/Sea - gray.png", b"user's own")
        (self.topic / "blue.png").unlink()
        idx = self.sort()
        links = self.links()
        self.assertNotIn("Wallpapers/Colors/Blue/Sea - blue.png", links)
        self.assertTrue(mine.is_file())
        self.assertTrue(foreign_link.is_symlink())
        self.assertEqual((self.lib / "Wallpapers/Colors/Monochrome/Sea - gray.png").read_bytes(), b"user's own")
        self.assertIn("Wallpapers/Colors/Monochrome/Sea - gray (2).png", links)
        self.assertNotIn("blue.png", [r["name"] for r in idx["images"]])
        # Emptied generated folders go away; ones holding user files stay.
        (self.lib / "Wallpapers" / "Topics" / "Woods" / "green.png").unlink()
        self.sort()
        self.assertFalse((self.lib / "Wallpapers/Colors/Green").exists())
        self.assertTrue(blue_dir.is_dir())

    def test_user_readme_kept(self):
        write(self.lib / "README.md", "# mine\n")
        self.sort()
        self.assertEqual((self.lib / "README.md").read_text(), "# mine\n")

    def test_add(self):
        src = self.tmp / "in"
        a = write(src / "a.png", make_png(4, 4, lambda x, y: PINK))
        b = write(src / "b.png", make_png(4, 4, lambda x, y: GREEN))
        rc, out, err = studio("library", "add", str(a), str(b), "--topic", "New Topic")
        self.assertEqual(rc, 0, err)
        dest = self.lib / "Wallpapers" / "Topics" / "New Topic"
        self.assertTrue((dest / "a.png").is_file() and a.is_file())
        self.assertIn("Wallpapers/Colors/Pink/New Topic - a.png", self.links())
        # Same content again: skipped; same name, other content: renamed; --move.
        c = write(self.tmp / "other" / "a.png", make_png(4, 4, lambda x, y: BLUE))
        rc, _, err = studio("library", "add", str(a), str(c), "--topic", "New Topic", "--move", "--no-sort")
        self.assertEqual(rc, 0, err)
        self.assertTrue((dest / "a (2).png").is_file())
        self.assertFalse(c.exists())
        self.assertFalse(a.exists())  # moved = gone from the source, already there
        rc, _, err = studio("library", "add", str(self.tmp / "nope.txt"), "--topic", "X")
        self.assertEqual(rc, 1)
        rc, _, err = studio("library", "add", str(b), "--topic", "../escape")
        self.assertEqual(rc, 1)

    def test_theme_path_install_and_vibes(self):
        rc, out, _ = studio("theme", "list")
        self.assertEqual(out.split(), ["forest", "latte", "pinky", "tokyonight"])
        rc, out, err = studio("theme", "new", "mine", "--from", "latte")
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.lib / "Packs" / "mine" / "theme.json").is_file())
        rc, _, err = studio("theme", "remove", "mine")
        self.assertEqual(rc, 0, err)
        # The old data dir is still searched (it may hold packs, or link here).
        legacy = self.tmp / "data" / "studio-linux" / "themes"
        make_pack(legacy, "oldie", GREEN_DARK)
        rc, out, _ = studio("theme", "list")
        self.assertIn("oldie", out.split())
        rc, _, err = studio("theme", "remove", "oldie")
        self.assertEqual(rc, 0, err)
        # Topic images rank among the vibes, recursively, with their topic.
        rc, out, err = studio("theme", "vibes", "pinky", "--json")
        self.assertEqual(rc, 0, err)
        topics = {Path(w["path"]).name: w["topic"] for w in json.loads(out)["wallpapers"] if w.get("topic")}
        self.assertEqual(topics, {"blue.png": "Sea", "deep.png": "Sea", "gray.png": "Sea", "green.png": "Woods"})
        rc, out, _ = studio("theme", "vibes", "pinky", "--json", "--no-library")
        self.assertFalse(any(w.get("topic") for w in json.loads(out)["wallpapers"]))

    def test_legacy_symlink_into_library(self):
        legacy = self.tmp / "data" / "studio-linux" / "themes"
        legacy.parent.mkdir(parents=True)
        legacy.symlink_to(self.lib / "Packs")
        rc, out, _ = studio("theme", "list")
        self.assertEqual(out.split(), ["forest", "latte", "pinky", "tokyonight"])
        self.assertTrue(legacy.is_symlink())

    def test_no_library(self):
        os.environ["STUDIO_LIBRARY"] = str(self.tmp / "absent")
        rc, out, _ = studio("library", "sort", "--json")
        self.assertEqual((rc, json.loads(out)["exists"]), (0, False))
        self.assertEqual(studio("library", "sort")[0], 1)
        self.assertFalse((self.tmp / "absent").exists())
        os.environ["STUDIO_LIBRARY"] = "none"
        rc, out, _ = studio("theme", "list")
        self.assertEqual(out.split(), ["latte", "tokyonight"])


if __name__ == "__main__":
    unittest.main()
