"""Unit tests for vibes: multi-wallpaper / multi-lock packs, curated links
(manifest + themes index), palette distance and ranking, the image palette
cache. Offline: the index is a local file, images are generated here, and
ffmpeg is disabled so results don't depend on the host.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from studio import color, index, palette, vibes
from studio.cli import main
from studio.pack import Pack, PackError, normalized_manifest
from test_importers import make_png

ROOT = Path(__file__).resolve().parent.parent
THEMES = ROOT / "themes"

try:
    import jsonschema  # noqa: F401

    HAVE_JSONSCHEMA = True
except ImportError:
    HAVE_JSONSCHEMA = False


def studio(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


def solid(rgb):
    return lambda x, y: rgb


def write(path: Path, data: bytes | str | dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, dict):
        data = json.dumps(data)
    path.write_bytes(data.encode() if isinstance(data, str) else data)
    return path


PINK_DARK = {
    "bg": "#282738", "surface": "#353446", "overlay": "#4b4a5e", "text": "#efe6e4", "subtext": "#c9c0c8",
    "accent": "#e5b9c6", "accent2": "#cfb3e5", "urgent": "#f07a8a", "ok": "#8fd19e", "warn": "#e6c07b",
}  # fmt: skip
LAVENDER_DARK = dict(PINK_DARK, accent="#caa9e0", accent2="#e5b9c6")
GREEN_DARK = dict(PINK_DARK, bg="#232a2e", surface="#2d353b", text="#d3c6aa", accent="#86918a", accent2="#a7c080")
GREY_LIGHT = dict(PINK_DARK, bg="#cccccc", surface="#bdbdbd", text="#474747", accent="#333333", accent2="#7a5a30")


def make_pack(root: Path, name: str, pal: dict, polarity: str = "dark", theme: dict | None = None, manifest: dict | None = None) -> Path:
    d = root / name
    write(d / "theme.json", {"polarity": polarity, "palette": pal, **(theme or {})})
    write(d / "manifest.json", {"name": name, "author": "t", "version": "1.0.0", "license": "CC0-1.0", **(manifest or {})})
    return d


class Distance(unittest.TestCase):
    def test_ciede2000_reference_pairs(self):
        # Sharma, Wu & Dalal (2005) test data.
        for lab1, lab2, expected in [
            ((50, 2.6772, -79.7751), (50, 0, -82.7485), 2.0425),
            ((50, 2.5, 0), (73, 25, -18), 27.1492),
            ((2.0776, 0.0795, -1.1350), (0.9033, -0.0636, -0.5514), 0.9082),
        ]:
            self.assertAlmostEqual(color.delta_e(lab1, lab2), expected, places=3)
        self.assertAlmostEqual(color.to_lab("#ffffff")[0], 100, places=3)
        self.assertEqual(color.delta_e("#123456", "#123456"), 0)

    def test_palette_distance(self):
        self.assertEqual(vibes.palette_distance(PINK_DARK, PINK_DARK), 0)
        # Swapped accents are the same vibe.
        self.assertEqual(vibes.palette_distance(PINK_DARK, dict(PINK_DARK, accent=PINK_DARK["accent2"], accent2=PINK_DARK["accent"])), 0)
        lav = vibes.palette_distance(PINK_DARK, LAVENDER_DARK)
        green = vibes.palette_distance(PINK_DARK, GREEN_DARK)
        grey = vibes.palette_distance(PINK_DARK, GREY_LIGHT, "dark", "light")
        self.assertLess(lav, 10)
        self.assertLess(lav, green)
        self.assertLess(green, grey)
        # Polarity alone costs the penalty.
        self.assertAlmostEqual(vibes.palette_distance(PINK_DARK, PINK_DARK, "dark", "light"), vibes.POLARITY_PENALTY)
        self.assertGreater(vibes.score(0), vibes.score(lav))

    def test_swatch_distance(self):
        a = [("#282738", 0.7), ("#e5b9c6", 0.3)]
        self.assertEqual(vibes.swatch_distance(a, a), 0)
        self.assertLess(vibes.swatch_distance(a, [("#2a2a3a", 0.8), ("#e0b0c0", 0.2)]), vibes.swatch_distance(a, [("#a0d0a0", 1.0)]))
        self.assertEqual(vibes.swatch_distance(a, []), float("inf"))
        self.assertEqual(len(vibes.palette_swatches(PINK_DARK)), 5)


class Format(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def rich_pack(self) -> Path:
        d = make_pack(
            self.tmp,
            "rich",
            PINK_DARK,
            theme={"wallpaper": {"images": ["extra/one.png", {"path": "extra/frame.jpg", "video": "extra/clip.mp4"}]}},
            manifest={
                "lock": {"format": "studio", "path": "lock"},
                "locks": [{"name": "alt", "path": "designs/alt", "preview": "designs/alt.png"}],
                "vibes": {"wallpapers": ["other:walls/b.png"], "locks": ["other"]},
            },
        )
        png = make_png(4, 4, solid((200, 100, 120)))
        write(d / "extra" / "one.png", png)
        write(d / "extra" / "frame.jpg", b"\xff\xd8\xff\xe0frame")
        write(d / "extra" / "clip.mp4", b"\0\0\0\x18ftypmp42")
        write(d / "wallpapers" / "a.png", png)
        write(d / "wallpapers" / "b.jpg", b"\xff\xd8\xff\xe0b")
        write(d / "wallpapers" / "b.webm", b"\x1aE\xdf\xa3webm")  # paired with b.jpg
        write(d / "wallpapers" / "only.mp4", b"\0\0\0\x18ftypmp42")
        write(d / "wallpapers" / "notes.txt", "not an image")
        write(d / "lock" / "Main.qml", "import QtQuick\nItem {}\n")
        write(d / "designs" / "alt" / "metadata.desktop", "[SddmGreeterTheme]\nName=Alt Design\nMainScript=Entry.qml\n")
        write(d / "designs" / "alt" / "Entry.qml", "import QtQuick\nItem {}\n")
        write(d / "designs" / "alt" / "theme.conf", "[General]\nbackground=bg.png\n")
        write(d / "designs" / "alt" / "bg.png", png)
        write(d / "designs" / "alt.png", png)
        write(d / "locks" / "third" / "Main.qml", "import QtQuick\nItem {}\n")
        write(d / "locks" / "third" / "preview.png", png)
        return d

    def test_wallpaper_collection(self):
        d = self.rich_pack()
        p = Pack(d)
        entries = [(str(e["path"].relative_to(p.path)), e["kind"], str(e["video"].relative_to(p.path)) if "video" in e else None) for e in p.wallpaper_entries()]
        self.assertEqual(
            entries,
            [
                ("extra/one.png", "image", None),
                ("extra/frame.jpg", "image", "extra/clip.mp4"),
                ("wallpapers/a.png", "image", None),
                ("wallpapers/b.jpg", "image", "wallpapers/b.webm"),
                ("wallpapers/only.mp4", "video", "wallpapers/only.mp4"),
            ],
        )
        # No `image`: the first still is the default.
        self.assertEqual(p.default_wallpaper()["path"], p.path / "extra/one.png")

    def test_lock_collection(self):
        p = Pack(self.rich_pack())
        locks = p.lock_entries()
        self.assertEqual([(lk["name"], lk["format"]) for lk in locks], [("rich", "studio"), ("alt", "qylock"), ("third", "studio")])
        alt = locks[1]
        self.assertEqual(alt["main"], p.path / "designs/alt/Entry.qml")  # MainScript
        self.assertEqual(alt["preview"], p.path / "designs/alt.png")
        self.assertEqual(alt["background"], p.path / "designs/alt/bg.png")
        self.assertEqual(locks[2]["preview"], p.path / "locks/third/preview.png")

    def test_normalized_manifest(self):
        p = Pack(self.rich_pack())
        m = normalized_manifest(p, {"wallpapers": [{"path": "/x/y.png", "source_pack": "other", "kind": "image"}], "locks": []})
        self.assertTrue(all(Path(w["path"]).is_absolute() for w in m["wallpapers"]))
        self.assertEqual(m["wallpapers"][-1], {"path": "/x/y.png", "source_pack": "other", "kind": "image", "curated": True})
        self.assertEqual(m["defaults"], {"wallpaper": str(p.path / "extra/one.png"), "lock": str(p.path / "lock")})
        self.assertEqual(m["lock"], {"name": "rich", "format": "studio", "path": str(p.path / "lock"), "main": str(p.path / "lock/Main.qml")})
        self.assertEqual(m["locks"][1]["source_pack"], "rich")
        self.assertEqual(m["vibes"]["locks"], ["other"])

    def test_render_copies_default(self):
        d = self.rich_pack()
        out = self.tmp / "out"
        rc, _, err = studio("theme", "render", str(d), str(out))
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads((out / "theme.json").read_text())["wallpaper"]["image"], "wallpaper.png")
        self.assertEqual((out / "wallpaper.png").read_bytes(), (d / "extra/one.png").read_bytes())
        m = json.loads((out / "manifest.json").read_text())
        self.assertEqual(len(m["wallpapers"]), 5)
        self.assertEqual(len(m["locks"]), 3)

    def test_backward_compatible(self):
        # A pack from before: one `wallpaper.image`, `lock/Main.qml`, no lists.
        d = make_pack(self.tmp, "old", PINK_DARK, theme={"wallpaper": {"image": "wall.png"}})
        write(d / "wall.png", make_png(2, 2, solid((1, 2, 3))))
        write(d / "lock" / "Main.qml", "import QtQuick\nItem {}\n")
        m = normalized_manifest(Pack(d))
        self.assertEqual(m["lock"]["format"], "studio")
        self.assertEqual(m["lock"]["path"], str(d.resolve() / "lock"))
        self.assertEqual([w["path"] for w in m["wallpapers"]], [str(d.resolve() / "wall.png")])
        # And a pack with nothing: empty lists, empty defaults, no `lock`.
        m = normalized_manifest(Pack(THEMES / "tokyonight"))
        self.assertEqual((m["wallpapers"], m["locks"], m["defaults"]), ([], [], {"wallpaper": "", "lock": ""}))
        self.assertNotIn("lock", m)

    def test_digest(self):
        d = self.rich_pack()
        base = Pack(d).digest()
        # Non-default collection files are listed (name + size), not hashed.
        (d / "wallpapers" / "a.png").write_bytes(b"\0" * (d / "wallpapers" / "a.png").stat().st_size)
        self.assertEqual(Pack(d).digest(), base)
        write(d / "wallpapers" / "new.png", make_png(2, 2, solid((9, 9, 9))))
        self.assertNotEqual(Pack(d).digest(), base)
        # The default wallpaper is copied into the bundle: its content counts.
        d2 = make_pack(self.tmp, "d2", PINK_DARK)
        write(d2 / "wallpapers" / "a.png", make_png(2, 2, solid((1, 1, 1))))
        before = Pack(d2).digest()
        write(d2 / "wallpapers" / "a.png", make_png(2, 2, solid((2, 2, 2))))
        self.assertNotEqual(Pack(d2).digest(), before)

    def test_validate_missing(self):
        d = make_pack(self.tmp, "broken", PINK_DARK, theme={"wallpaper": {"images": ["nope.png"]}}, manifest={"locks": [{"path": "missing"}]})
        with self.assertRaises(PackError) as cm:
            Pack(d).validate(THEMES / "schema.json")
        self.assertIn("wallpaper/images/0: nope.png", str(cm.exception))
        self.assertIn("locks/0/path: missing", str(cm.exception))

    @unittest.skipUnless(HAVE_JSONSCHEMA, "needs jsonschema")
    def test_schema(self):
        d = self.rich_pack()
        Pack(d).validate(THEMES / "schema.json", require_manifest=True)
        m = json.loads((d / "manifest.json").read_text())
        m["vibes"] = {"wallpaper": ["x"]}  # typo
        m["locks"][0]["format"] = "sddm"
        (d / "manifest.json").write_text(json.dumps(m))
        with self.assertRaises(PackError) as cm:
            Pack(d).validate(THEMES / "schema.json")
        self.assertIn("vibes", str(cm.exception))
        self.assertIn("sddm", str(cm.exception))


class Index(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def test_links(self):
        idx = {"vibes": [{"packs": ["a", "b", "c"], "locks": ["d:x", "a:mine"]}, {"packs": ["a", "e"]}, "junk"]}
        self.assertEqual(index.links_for(idx, "a"), {"wallpapers": ["b", "c", "e"], "locks": ["b", "c", "d:x", "e"]})
        self.assertEqual(index.links_for(idx, "z"), {"wallpapers": [], "locks": []})
        self.assertEqual(index.merge_links({"locks": ["x"]}, None, {"locks": ["x", "y"]}), {"wallpapers": [], "locks": ["x", "y"]})

    def test_load_local_and_disabled(self):
        f = write(self.tmp / "index.json", {"vibes": [{"packs": ["a", "b"]}]})
        os.environ["STUDIO_THEME_INDEX"] = str(f)
        self.assertEqual(index.load(self.tmp)["vibes"][0]["packs"], ["a", "b"])
        os.environ["STUDIO_THEME_INDEX"] = f"file://{f}"
        self.assertIn("vibes", index.load(None))
        os.environ["STUDIO_THEME_INDEX"] = "none"
        self.assertEqual(index.load(self.tmp), {})
        os.environ["STUDIO_THEME_INDEX"] = str(self.tmp / "missing.json")
        self.assertEqual(index.load(self.tmp), {})

    def test_remote_falls_back_to_cache(self):
        os.environ["STUDIO_THEME_INDEX"] = "https://example.invalid/index.json"
        with mock.patch("urllib.request.urlopen", side_effect=OSError("offline")):
            self.assertEqual(index.load(self.tmp), {})
            write(self.tmp / "cache" / "index.json", {"vibes": [], "_source": "https://example.invalid/index.json"})
            os.utime(self.tmp / "cache" / "index.json", (0, 0))  # stale: refetch fails, stale copy used
            self.assertEqual(index.load(self.tmp)["vibes"], [])


class Ranking(unittest.TestCase):
    """`studio theme vibes` over a scratch theme path."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.packs = self.tmp / "packs"
        self.state = self.tmp / "state"
        self.idx = write(self.tmp / "index.json", {"vibes": [{"name": "sakura", "packs": ["sakura", "pixel", "absent"]}]})
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "STUDIO_STATE_DIR": str(self.state),
                "STUDIO_HOOKS": "none",
                "STUDIO_THEME_PATH": str(self.packs),
                "STUDIO_THEME_INDEX": str(self.idx),
            }
        )
        os.environ.pop("STUDIO_LIBRARY", None)
        self.noff = mock.patch.object(palette, "have_ffmpeg", return_value=False)
        self.noff.start()
        navy_pink = lambda x, y: (40, 39, 56) if (x + y) % 3 else (229, 185, 198)  # noqa: E731
        sakura = make_pack(self.packs, "sakura", PINK_DARK, theme={"wallpaper": {"image": "wallpapers/s.png"}})
        write(sakura / "wallpapers" / "s.png", make_png(12, 12, navy_pink))
        write(sakura / "lock" / "Main.qml", "import QtQuick\nItem {}\n")
        cozy = make_pack(self.packs, "cozy", LAVENDER_DARK)
        write(cozy / "wallpapers" / "c.png", make_png(12, 12, lambda x, y: (40, 39, 56) if (x + y) % 3 else (202, 169, 224)))
        write(cozy / "locks" / "cozy-lock" / "Main.qml", "import QtQuick\nItem {}\n")
        forest = make_pack(self.packs, "forest", GREEN_DARK)
        write(forest / "wallpapers" / "f.png", make_png(12, 12, solid((60, 90, 60))))
        write(forest / "locks" / "forest-lock" / "Main.qml", "import QtQuick\nItem {}\n")
        paper = make_pack(self.packs, "paper", GREY_LIGHT, polarity="light")
        write(paper / "wallpapers" / "p.png", make_png(12, 12, solid((210, 210, 205))))
        # Linked to sakura by the index, though its palette is far away.
        pixel = make_pack(self.packs, "pixel", GREY_LIGHT, polarity="light", manifest={"lock": {"path": "lock/qylock", "name": "px"}})
        write(pixel / "wallpapers" / "frame.png", make_png(12, 12, solid((240, 244, 243))))
        write(pixel / "lock" / "qylock" / "metadata.desktop", "[SddmGreeterTheme]\nName=Pixel\n")
        write(pixel / "lock" / "qylock" / "Main.qml", "import QtQuick\nItem {}\n")
        self.loose = self.tmp / "Pictures"
        write(self.loose / "pinkish.png", make_png(12, 12, navy_pink))
        write(self.loose / "lime.png", make_png(12, 12, solid((160, 255, 40))))
        write(self.loose / "readme.txt", "x")

    def tearDown(self):
        self.noff.stop()
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def vibes(self, *args) -> dict:
        rc, out, err = studio("theme", "vibes", *args, "--json")
        self.assertEqual(rc, 0, err)
        return json.loads(out)

    def test_rank(self):
        v = self.vibes("sakura", "--dir", str(self.loose))
        walls = [(w["origin"], w["source_pack"], Path(w["path"]).name) for w in v["wallpapers"]]
        self.assertEqual(walls[0], ("own", "sakura", "s.png"))
        self.assertEqual(walls[1], ("curated", "pixel", "frame.png"))  # index link, first despite its palette
        matches = [(s, n) for o, s, n in walls if o == "match"]
        # The loose pink image ranks by its own colors; the lime one last.
        self.assertEqual(matches[0], ("", "pinkish.png"))
        self.assertLess(matches.index(("cozy", "c.png")), matches.index(("forest", "f.png")))
        self.assertLess(matches.index(("forest", "f.png")), matches.index(("paper", "p.png")))
        self.assertEqual(matches[-1], ("", "lime.png"))
        ds = [w["distance"] for w in v["wallpapers"] if w["origin"] == "match"]
        self.assertEqual(ds, sorted(ds))
        self.assertTrue(all(0 < w["score"] <= 1 for w in v["wallpapers"] if w["origin"] == "match"))

        locks = [(lk["origin"], lk["source_pack"], lk["name"]) for lk in v["locks"]]
        self.assertEqual(locks, [("own", "sakura", "sakura"), ("curated", "pixel", "px"), ("match", "cozy", "cozy-lock"), ("match", "forest", "forest-lock")])
        cozy_lock = v["locks"][2]
        self.assertEqual(cozy_lock["palette"]["accent"], LAVENDER_DARK["accent"])  # for the preview card
        self.assertTrue(cozy_lock["background"].endswith("c.png"))  # its pack's wallpaper
        self.assertEqual(v["defaults"]["lock"], str((self.packs / "sakura" / "lock").resolve()))

        self.assertEqual(len(self.vibes("sakura", "--limit", "1")["wallpapers"]), 3)

    def test_missing_links_skipped_and_text(self):
        shutil.rmtree(self.packs / "pixel")
        v = self.vibes("sakura")
        self.assertNotIn("curated", [w["origin"] for w in v["wallpapers"]])
        rc, out, err = studio("theme", "vibes", "sakura")
        self.assertEqual(rc, 0, err)
        self.assertIn("own", out)
        self.assertIn("cozy-lock", out)

    def test_manifest_refs(self):
        m = json.loads((self.packs / "forest" / "manifest.json").read_text())
        m["vibes"] = {"wallpapers": ["paper:wallpapers/p.png", "nope:x.png", "cozy:missing.png"], "locks": ["cozy:cozy-lock", "cozy:other"]}
        (self.packs / "forest" / "manifest.json").write_text(json.dumps(m))
        v = self.vibes("forest")
        cur = [(w["source_pack"], Path(w["path"]).name) for w in v["wallpapers"] if w["origin"] == "curated"]
        self.assertEqual(cur, [("paper", "p.png")])
        self.assertEqual([lk["name"] for lk in v["locks"] if lk["origin"] == "curated"], ["cozy-lock"])

    def test_cache(self):
        calls = []
        real = palette.sample

        def counting(path):
            calls.append(path)
            return real(path)

        with mock.patch.object(palette, "sample", side_effect=counting):
            self.vibes("sakura")
            first = len(calls)
            self.assertGreater(first, 0)
            self.vibes("sakura")
            self.assertEqual(len(calls), first)  # all cached
            # Same content elsewhere: cached by hash, not by path.
            shutil.copy(self.packs / "cozy" / "wallpapers" / "c.png", self.packs / "cozy" / "wallpapers" / "c2.png")
            self.vibes("sakura")
            self.assertEqual(len(calls), first)
        cache = json.loads((self.state / "cache" / "palettes.json").read_text())
        self.assertEqual(cache["version"], vibes.PaletteCache.VERSION)
        some = next(iter(v for v in cache["palettes"].values() if v))
        self.assertIn("swatches", some)

    def test_current_and_list(self):
        self.assertEqual(studio("theme", "apply", "sakura")[0], 0)
        self.assertEqual(self.vibes()["theme"], "sakura")
        rc, out, _ = studio("theme", "list", "--json")
        by = {p["name"]: p for p in json.loads(out)}
        self.assertEqual(by["sakura"]["vibes"], ["pixel"])
        self.assertEqual(by["sakura"]["locks"], ["sakura"])
        self.assertEqual(by["cozy"]["wallpapers"], 1)
        self.assertTrue(by["cozy"]["wallpaper"]["default"].endswith("c.png"))
        # The rendered manifest lists curated assets with absolute paths.
        m = json.loads((self.state / "current" / "manifest.json").read_text())
        self.assertEqual([w["source_pack"] for w in m["wallpapers"]], ["sakura", "pixel"])
        self.assertTrue(m["wallpapers"][1]["curated"])

    def test_apply_rerenders_when_linked_pack_appears(self):
        shutil.move(str(self.packs / "pixel"), str(self.tmp / "pixel-away"))
        studio("theme", "apply", "sakura")
        first = (self.state / "current").resolve()
        shutil.move(str(self.tmp / "pixel-away"), str(self.packs / "pixel"))
        studio("theme", "apply", "sakura")
        self.assertNotEqual((self.state / "current").resolve(), first)

    def test_importer_writes_index_links(self):
        from studio.importers import add_index_vibes

        d = make_pack(self.tmp / "staging", "absent", PINK_DARK, manifest={"vibes": {"locks": ["x:y"]}})
        add_index_vibes(d, json.loads(self.idx.read_text()))
        m = json.loads((d / "manifest.json").read_text())
        self.assertEqual(m["vibes"], {"wallpapers": ["sakura", "pixel"], "locks": ["x:y", "sakura", "pixel"]})


if __name__ == "__main__":
    unittest.main()
