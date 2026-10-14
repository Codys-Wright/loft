"""Unit tests for the theme importers (cozytile:, qylock:).

No network: palettes are checked against config snippets and images
generated here, and the install path runs against small local git repos
laid out like the upstream ones (LOFT_<IMPORTER>_URL points at them).
ffmpeg is disabled so results don't depend on the host.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

from loft import color
from loft.cli import main
from loft import palette
from loft.importers import REGISTRY, ImporterError, cozytile, parse_ref, qylock
from loft.importers.upstream import literal

ROOT = Path(__file__).resolve().parent.parent

try:
    import jsonschema  # noqa: F401

    HAVE_JSONSCHEMA = True
except ImportError:
    HAVE_JSONSCHEMA = False


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


# ── tiny PNG encoder (exercises every filter type the decoder undoes) ──────


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def make_png(width: int, height: int, pixel, *, alpha: bool = False, filters=(0, 1, 2, 3, 4)) -> bytes:
    """pixel(x, y) -> (r, g, b); rows cycle through `filters`."""
    bpp = 4 if alpha else 3
    raw = bytearray()
    prev = bytearray(width * bpp)
    for y in range(height):
        line = bytearray()
        for x in range(width):
            r, g, b = pixel(x, y)
            line += bytes((r, g, b, 200) if alpha else (r, g, b))
        f = filters[y % len(filters)]
        enc = bytearray(len(line))
        for i, v in enumerate(line):
            a = line[i - bpp] if i >= bpp else 0
            up = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            pred = [0, a, up, (a + up) >> 1, _paeth(a, up, c)][f]
            enc[i] = (v - pred) & 0xFF
        raw += bytes([f]) + enc
        prev = line

    def chunk(t: bytes, d: bytes) -> bytes:
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6 if alpha else 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


def two_tone(x, y):
    """Top 3/4 dark navy, bottom 1/4 saturated orange, a gradient row in between."""
    if y < 12:
        return (20, 24, 40)
    if y == 12:
        return (x * 16 % 256, 100, 50)
    return (240, 140, 40)


class Palette(unittest.TestCase):
    def test_png_roundtrip_all_filters(self):
        for alpha in (False, True):
            data = make_png(16, 16, two_tone, alpha=alpha)
            px = palette.decode_png(data, max_side=16)
            self.assertEqual(len(px), 256)
            self.assertEqual(px[0], (20, 24, 40))
            self.assertEqual(px[12 * 16 + 5], (80, 100, 50))
            self.assertEqual(px[-1], (240, 140, 40))

    def test_png_sampling_and_errors(self):
        px = palette.decode_png(make_png(64, 64, two_tone), max_side=16)
        self.assertEqual(len(px), 16 * 16)  # every 4th row and column
        with self.assertRaises(palette.PNGError):
            palette.decode_png(b"GIF89a....")

    def test_sniff(self):
        tmp = Path(tempfile.mkdtemp())
        try:
            (tmp / "a").write_bytes(make_png(2, 2, two_tone))
            (tmp / "b").write_bytes(b"\xff\xd8\xff\xe0" + b"\0" * 12)
            (tmp / "c.mp4").write_bytes(b"\0\0\0\x18ftypmp42" + b"\0" * 8)
            self.assertEqual([palette.sniff(tmp / n) for n in "ab"], ["png", "jpg"])
            self.assertTrue(palette.is_video(tmp / "c.mp4"))
            with mock.patch.object(palette, "have_ffmpeg", return_value=False):
                self.assertEqual(len(palette.sample(tmp / "a")), 4)
                self.assertEqual(palette.sample(tmp / "b"), [])  # JPEG needs ffmpeg
        finally:
            shutil.rmtree(tmp)

    def test_quantize(self):
        px = [(20, 24, 40)] * 300 + [(240, 140, 40)] * 100 + [(30, 200, 90)] * 20
        sw = palette.quantize(px, k=4)
        self.assertEqual(sw[0][0], "#141828")
        self.assertAlmostEqual(sw[0][1], 300 / 420, places=3)
        self.assertIn("#f08c28", [c for c, _ in sw])
        self.assertAlmostEqual(sum(w for _, w in sw), 1.0, places=6)
        self.assertEqual(palette.quantize([]), [])
        self.assertEqual(palette.quantize(px, k=4), sw)  # deterministic

    def test_scheme_from_swatches(self):
        sw = [("#141828", 0.7), ("#f08c28", 0.25), ("#1ec85a", 0.05)]
        pol, pal = palette.scheme(swatches=sw)
        self.assertEqual(pol, "dark")
        self.assertEqual(set(pal), {"bg", "surface", "overlay", "text", "subtext", "accent", "accent2", "urgent", "ok", "warn"})
        self.assertLess(color.luminance(pal["bg"]), 0.03)
        self.assertGreaterEqual(color.contrast(pal["text"], pal["bg"]), 7)
        for role in ("accent", "accent2", "urgent", "ok", "warn", "subtext"):
            self.assertGreaterEqual(color.contrast(pal[role], pal["bg"]), 3.0, role)
        self.assertLess(palette.hue_distance(pal["accent"], "#f08c28"), 5)  # the orange
        self.assertGreaterEqual(palette.hue_distance(pal["accent2"], pal["accent"]), 35)

    def test_scheme_light_and_given(self):
        pol, pal = palette.scheme(swatches=[("#f4f1ea", 0.8), ("#3366cc", 0.2)])
        self.assertEqual(pol, "light")
        self.assertGreater(color.luminance(pal["bg"]), 0.8)
        pol, pal = palette.scheme(bg="#282738", text="#efe6e4", accent="#e5b9c6", surface="#353446")
        self.assertEqual(pol, "dark")
        self.assertEqual((pal["bg"], pal["text"], pal["accent"], pal["surface"]), ("#282738", "#efe6e4", "#e5b9c6", "#353446"))
        # Too-dark accent on a dark bg gets lifted to 3:1.
        _, pal = palette.scheme(bg="#101010", accent="#202060")
        self.assertGreaterEqual(color.contrast(pal["accent"], "#101010"), 3.0)

    def test_neutral_fallback(self):
        pol, pal = palette.scheme()
        self.assertEqual(pol, "dark")
        self.assertEqual(pal["bg"], palette.NEUTRAL_DARK["bg"])

    def test_glass(self):
        g = palette.glass("dark", {"bg": "#101010"})
        self.assertEqual(g["tint"], "#101010")
        self.assertTrue(g["blur"] and g["xray"])
        self.assertGreater(palette.glass("dark", {"bg": "#101010"}, busy=True)["opacity"], g["opacity"])


# ── cozytile ────────────────────────────────────────────────────────────────

RASI = """
configuration { modi: "drun"; }
/* global */
* {
    font:                        "JetBrains Mono Nerd Font 11";
    background:                  #282739;
    background-alt:              #353447;
    foreground:                  #efe6e4;
    selected:                    #E6B9C6;
    active:                      #D6A8AC;
    urgent:                      #AA7490;
}
window { background-color: #000000; }
"""

QTILE = """
colors = []
# border_normal="#ff0000",
bar = Bar([
    widget.Spacer(background="#282738"),
    widget.GroupBox(active="#E5B9C6", block_highlight_text_color="#CFB3E5", inactive="#282738",
                    background="#353446", foreground="#4B427E"),
    widget.TextBox(background="#353446", foreground="#E5B9C6"),
    widget.TextBox(background="#353446", foreground="#E5B9C6"),
    widget.Clock(background="#353446", foreground="#E5B9C6"),
], background="#282738")
"""

DUNST = """
[global]
    frame_color = "#282738"
[urgency_normal]
    background = "#282738"
    foreground = "#ffd5cd"
    timeout = 10
[urgency_critical]
    foreground = "#ff0000"
"""

SAKURA_SWITCHER = """#!/bin/bash
cp -r ~/Themes/Sakura/. ~/ &&
wal -b 282738 -i ~/Wallpaper/120_-_KnFPX73.jpg &&
qtile cmd-obj -o cmd -f restart
"""

CARBON_SWITCHER = """#!/bin/bash
cp -r ~/Themes/Carbon/. ~/ &&
wal -i ~/Wallpaper/a_road_going_through_a_desert.jpeg && wal -f ~/Wallpaper/e-ink.json &&
"""

EINK = """{
  "special": { "background": "#CCCCCC", "foreground": "#474747", "cursor": "#333333" },
  "colors": { "color0": "#CCCCCC", "color4": "#333333", "color5": "#808080" }
}"""


class Cozytile(unittest.TestCase):
    def test_parsers(self):
        self.assertEqual(cozytile.parse_rasi(RASI)["selected"], "#e6b9c6")
        self.assertNotIn("background-color", cozytile.parse_rasi(RASI))
        q = cozytile.parse_qtile(QTILE)
        self.assertEqual((q["widget_bg"], q["bar_bg"], q["widget_fg"]), ("#353446", "#282738", "#e5b9c6"))
        self.assertEqual(q["block_highlight_text_color"], "#cfb3e5")
        self.assertEqual(cozytile.parse_dunst(DUNST), {"background": "#282738", "foreground": "#ffd5cd"})
        self.assertEqual(
            cozytile.parse_switcher(SAKURA_SWITCHER), {"wallpaper": "Wallpaper/120_-_KnFPX73.jpg", "wal_bg": "#282738"}
        )
        sw = cozytile.parse_switcher(CARBON_SWITCHER)
        self.assertEqual(sw["pywal_json"], "Wallpaper/e-ink.json")
        self.assertEqual(sw["wallpaper"], "Wallpaper/a_road_going_through_a_desert.jpeg")
        self.assertEqual(cozytile.parse_pywal(EINK)["special.background"], "#cccccc")

    def test_derive_dark(self):
        pol, pal = cozytile.derive(
            rasi=cozytile.parse_rasi(RASI),
            qtile=cozytile.parse_qtile(QTILE),
            dunst=cozytile.parse_dunst(DUNST),
            switcher=cozytile.parse_switcher(SAKURA_SWITCHER),
            sddm={"accentColor": "#e5b9c6"},
        )
        self.assertEqual(pol, "dark")
        self.assertEqual(pal["bg"], "#282738")  # wal -b
        self.assertEqual(pal["surface"], "#353446")  # qtile widget pills
        self.assertEqual(pal["text"], "#efe6e4")  # rofi foreground
        self.assertEqual(pal["accent"], "#e5b9c6")  # qtile active
        self.assertEqual(pal["accent2"], "#cfb3e5")  # the most distinct highlight

    def test_derive_pywal_light(self):
        pol, pal = cozytile.derive(
            rasi={"background": "#1b2125", "foreground": "#cccccc", "selected": "#b6b6b6"},
            qtile={},
            dunst={},
            switcher=cozytile.parse_switcher(CARBON_SWITCHER),
            pywal=cozytile.parse_pywal(EINK),
            sddm={"accentColor": "#ffb86c"},
        )
        self.assertEqual(pol, "light")
        self.assertEqual((pal["bg"], pal["text"], pal["accent"]), ("#cccccc", "#474747", "#333333"))
        self.assertLess(palette.hue_distance(pal["accent2"], "#ffb86c"), 6)  # SDDM orange, darkened
        self.assertGreaterEqual(color.contrast(pal["accent2"], pal["bg"]), 3.0)

    def test_derive_needs_colors(self):
        with self.assertRaises(ImporterError):
            cozytile.derive(rasi={}, qtile={}, dunst={}, switcher={})


# ── qylock ──────────────────────────────────────────────────────────────────


class Qylock(unittest.TestCase):
    def test_conf_hints(self):
        h = qylock.hints(qylock.parse_conf("[General]\ntype=color\ncolor=#131218\nfont=Google-Sans\n"))
        self.assertEqual(h, {"bg": "#131218", "polarity": "dark"})
        h = qylock.hints(qylock.parse_conf("[General]\nbackground=bg.mp4\ntype=video\ncolor=#df7a8c\n"))
        self.assertEqual(h, {"accent": "#df7a8c"})  # saturated → accent
        h = qylock.hints(qylock.parse_conf("[General]\ncolor=#f0ede8\nthemeMode=light\n"))
        self.assertEqual(h, {"polarity": "light", "text_on_bg": "#f0ede8"})
        h = qylock.hints(qylock.parse_conf("[General]\nmainColor=#cceeff\naccentColor=#ffcc00\ncontainerColor=#1a1a4a\n"))
        self.assertEqual(h, {"accent": "#ffcc00", "text": "#cceeff", "surface": "#1a1a4a"})
        self.assertEqual(qylock.hints({"accentcolor": "#80ff0000"})["accent"], "#ff0000")  # Qt #aarrggbb

    def test_palette_for(self):
        sw = [("#141828", 0.7), ("#f08c28", 0.3)]
        pol, pal = qylock.palette_for({"color": "#f0ede8"}, sw)
        self.assertEqual(pol, "dark")
        self.assertEqual(pal["text"], "#f0ede8")  # the design's text color reads on bg
        pol, pal = qylock.palette_for({"type": "color", "color": "#000000"}, [])
        self.assertEqual(pal["bg"], "#000000")

    def test_find_background(self):
        tmp = Path(tempfile.mkdtemp())
        try:
            (tmp / "font").mkdir()
            (tmp / "font" / "big.ttf").write_bytes(b"\0" * 5000)
            (tmp / "logo.png").write_bytes(make_png(40, 40, two_tone))
            (tmp / "background").mkdir()
            (tmp / "background" / "A").write_bytes(make_png(8, 8, two_tone))
            (tmp / "background" / "B").write_bytes(make_png(16, 16, two_tone))
            (tmp / "day.mp4").write_bytes(b"\0\0\0\x18ftypmp42" + b"\0" * 8)
            self.assertEqual(qylock.find_background(tmp, {}).name, "B")  # largest, not the logo
            self.assertEqual(qylock.find_background(tmp, {"background": "day.png"}).name, "day.mp4")
            self.assertEqual(qylock.find_background(tmp, {"background": "background/A"}).name, "A")
        finally:
            shutil.rmtree(tmp)

    def test_pack_names(self):
        self.assertEqual(qylock.pack_name("Genshin"), "qylock-genshin")
        self.assertEqual(qylock.pack_name("windows_7"), "qylock-windows_7")
        self.assertEqual(cozytile.pack_name("Everforest"), "cozytile-everforest")


class Refs(unittest.TestCase):
    def test_parse_ref(self):
        mod, themes, ref = parse_ref("qylock:pixel-sakura,forest@abc123")
        self.assertIs(mod, REGISTRY["qylock"])
        self.assertEqual((themes, ref), (["pixel-sakura", "forest"], "abc123"))
        self.assertEqual(parse_ref("cozytile:all")[1:], (["all"], None))
        with self.assertRaises(ImporterError):
            parse_ref("nope:x")

    def test_literal(self):
        self.assertEqual(literal("Wallpaper/pexels (1)[x].jpg"), "/Wallpaper/pexels (1)\\[x\\].jpg")


# ── end to end against local "upstream" repos ───────────────────────────────


def git_repo(root: Path, files: dict[str, bytes | str]) -> str:
    for rel, data in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data.encode() if isinstance(data, str) else data)
    git = ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"]
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "."], check=True)
    subprocess.run(git + ["commit", "-qm", "upstream"], check=True)
    return f"file://{root}"


def navy_pink(x, y):
    """A dark navy image with pink: Sakura's colors, nothing like Carbon's greys."""
    return (40, 39, 56) if (x + y) % 4 else (229, 185, 198)


def cozytile_repo(root: Path) -> str:
    files: dict[str, bytes | str] = {
        "README.md": "cozytile",
        "Wallpaper/120_-_KnFPX73.jpg": b"\xff\xd8\xff\xe0fakejpeg",
        "Wallpaper/a_road_going_through_a_desert.jpeg": b"\xff\xd8\xff\xe0fakejpeg2",
        "Wallpaper/e-ink.json": EINK,
        # Shipped but set by no theme: given to the closest palette (Sakura).
        "Wallpaper/pexels (1).png": make_png(16, 16, navy_pink),
    }
    for name, switcher in (("Sakura", SAKURA_SWITCHER), ("Carbon", CARBON_SWITCHER)):
        low = name.lower()
        files[f".config/rofi/theme_scripts/{name}"] = switcher
        files[f".config/rofi/settings/launcher/{low}.rasi"] = RASI
        files[f"Themes/{name}/.config/qtile/config.py"] = QTILE
        files[f"Themes/{name}/.config/dunst/dunstrc"] = DUNST
        files[f"sddm-themes/{name}/Main.qml"] = "import QtQuick\nItem {}\n"
        files[f"sddm-themes/{name}/theme.conf"] = "[General]\nbackground=Background.jpg\naccentColor=#ffb86c\n"
        # Carbon's greeter background is its wallpaper (as upstream); Sakura's differs here.
        files[f"sddm-themes/{name}/Background.jpg"] = b"\xff\xd8\xff\xe0fakejpeg2" if name == "Carbon" else b"\xff\xd8\xff\xe0bg"
        files[f"sddm-themes/{name}/font/.gitkeep"] = ""
    return git_repo(root, files)


def qylock_repo(root: Path) -> str:
    return git_repo(
        root,
        {
            "README.md": "qylock",
            "themes/still/Main.qml": "import QtQuick\nItem {}\n",
            "themes/still/metadata.desktop": "[SddmGreeterTheme]\nName=still\nDescription=Still Theme\nAuthor=someone\nMainScript=Main.qml\n",
            "themes/still/theme.conf": "[General]\nbackground=bg.png\ntype=image\ncolor=#f0ede8\n",
            "themes/still/bg.png": make_png(32, 32, two_tone),
            "themes/still/font/X.ttf": b"\0" * 10,
            "themes/Video/Main.qml": "import QtQuick\nItem {}\n",
            "themes/Video/theme.conf": "[General]\nbackground=bg.mp4\ntype=video\ncolor=#df7a8c\n",
            "themes/Video/bg.mp4": b"\0\0\0\x18ftypmp42" + b"\0" * 64,
            "themes/solid/Main.qml": "import QtQuick\nItem {}\n",
            "themes/solid/theme.conf": "[General]\ntype=color\ncolor=#eef6f0\n",
            # Several backgrounds (osu-style) and day/night videos (Genshin-style).
            "themes/multi/Main.qml": "import QtQuick\nItem {}\n",
            "themes/multi/theme.conf": "[General]\nbackground=background/A Glow.jpg\n",
            "themes/multi/background/A Glow.jpg": b"\xff\xd8\xff\xe0" + b"a" * 250_000,
            "themes/multi/background/B Glow.jpg": b"\xff\xd8\xff\xe0" + b"b" * 250_000,
            "themes/multi/logo.png": make_png(40, 40, two_tone),
            "themes/multi/sprite.png": b"\x89PNG\r\n\x1a\n" + b"s" * 1000,
            "themes/clips/Main.qml": "import QtQuick\nItem {}\n",
            "themes/clips/theme.conf": "[General]\nbackground=day.mp4\n",
            "themes/clips/day.mp4": b"\0\0\0\x18ftypmp42" + b"d" * 250_000,
            "themes/clips/night.mp4": b"\0\0\0\x18ftypmp42" + b"n" * 250_000,
        },
    )


@unittest.skipUnless(shutil.which("git"), "needs git")
class Install(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.user = self.tmp / "data" / "loft" / "themes"
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "LOFT_STATE_DIR": str(self.tmp / "state"),
                "LOFT_HOOKS": "none",
                "LOFT_THEME_INDEX": "none",
                "LOFT_COZYTILE_URL": cozytile_repo(self.tmp / "cozytile"),
                "LOFT_QYLOCK_URL": qylock_repo(self.tmp / "qylock"),
            }
        )
        for k in ("LOFT_THEME_PATH", "LOFT_DATA_DIR", "LOFT_LIBRARY"):
            os.environ.pop(k, None)
        self.noff = mock.patch.object(palette, "have_ffmpeg", return_value=False)
        self.noff.start()

    def tearDown(self):
        self.noff.stop()
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def test_list(self):
        rc, out, err = loft("theme", "install", "--list", "cozytile:")
        self.assertEqual(rc, 0, err)
        self.assertEqual([line.split()[0] for line in out.splitlines()], ["cozytile-carbon", "cozytile-sakura"])
        rc, out, err = loft("theme", "install", "--list", "qylock")
        self.assertEqual(rc, 0, err)
        self.assertIn("qylock-video", out)
        self.assertIn("qylock-multi", out)
        self.assertEqual(loft("theme", "install", "--list", "./somewhere")[0], 1)

    def test_cozytile_all(self):
        rc, out, err = loft("theme", "install", "cozytile:all")
        self.assertEqual(rc, 0, err)
        sakura = self.user / "cozytile-sakura"
        theme = json.loads((sakura / "theme.json").read_text())
        self.assertEqual(theme["palette"]["bg"], "#282738")
        # The switcher's wallpaper (default), the greeter's different background, the orphan.
        self.assertEqual(theme["wallpaper"], {"image": "wallpapers/120_-_knfpx73.jpg", "images": ["greeter/Background.jpg"]})
        self.assertEqual(sorted(p.name for p in (sakura / "wallpapers").iterdir()), ["120_-_knfpx73.jpg", "pexels-1.png"])
        self.assertTrue((sakura / "greeter" / "Main.qml").is_file())
        self.assertFalse((sakura / "greeter" / "font" / ".gitkeep").exists())
        m = json.loads((sakura / "manifest.json").read_text())
        self.assertEqual((m["license"], m["upstream"]["importer"]), ("NOASSERTION", "cozytile"))
        self.assertRegex(m["upstream"]["commit"], "^[0-9a-f]{40}$")
        self.assertEqual(m["lock"], {"name": "sakura", "format": "qylock", "path": "greeter"})
        from loft.pack import Pack

        walls = [str(e["path"].relative_to(sakura)) for e in Pack(sakura).wallpaper_entries()]
        self.assertEqual(walls, ["wallpapers/120_-_knfpx73.jpg", "greeter/Background.jpg", "wallpapers/pexels-1.png"])
        carbon_dir = self.user / "cozytile-carbon"
        carbon = json.loads((carbon_dir / "theme.json").read_text())
        self.assertEqual(carbon["polarity"], "light")
        # Same file as the greeter's background: referenced, not copied again.
        self.assertEqual(carbon["wallpaper"], {"image": "greeter/Background.jpg"})
        self.assertFalse((carbon_dir / "wallpapers").exists())

        # Re-running `all` skips installed packs; a single theme refuses; --force replaces.
        rc, out, _ = loft("theme", "install", "cozytile:all")
        self.assertEqual(rc, 0)
        self.assertIn("skipped", out)
        rc, _, err = loft("theme", "install", "cozytile:sakura")
        self.assertEqual(rc, 1)
        self.assertIn("--force", err)
        (sakura / "marker").write_text("x")
        self.assertEqual(loft("theme", "install", "--force", "cozytile:Sakura")[0], 0)
        self.assertFalse((sakura / "marker").exists())
        # No staging leftovers next to the packs.
        self.assertEqual(sorted(p.name for p in self.user.iterdir()), ["cozytile-carbon", "cozytile-sakura"])

        rc, _, err = loft("theme", "apply", "cozytile-sakura")
        self.assertEqual(rc, 0, err)

    def test_qylock(self):
        rc, out, err = loft("theme", "install", "qylock:all")
        self.assertEqual(rc, 0, err)
        still = self.user / "qylock-still"
        m = json.loads((still / "manifest.json").read_text())
        self.assertEqual(m["lock"], {"format": "qylock", "path": "lock/qylock"})
        self.assertEqual((m["author"], m["license"]), ("someone", "GPL-3.0"))
        self.assertTrue((still / "lock" / "qylock" / "Main.qml").is_file())
        self.assertTrue((still / "lock" / "qylock" / "font" / "X.ttf").is_file())
        t = json.loads((still / "theme.json").read_text())
        self.assertEqual(t["wallpaper"]["image"], "lock/qylock/bg.png")  # in place, no copy
        self.assertEqual(t["polarity"], "dark")  # mostly navy
        self.assertLess(palette.hue_distance(t["palette"]["accent"], "#f08c28"), 10)
        self.assertIn("palette from bg.png", m["description"])

        # Video without ffmpeg: listed as is (a flagged video entry, no still),
        # conf accent on a neutral palette.
        v = json.loads((self.user / "qylock-video" / "theme.json").read_text())
        self.assertEqual(v["wallpaper"], {"images": ["lock/qylock/bg.mp4"]})
        from loft.pack import Pack

        vp = Pack(self.user / "qylock-video")
        self.assertEqual([e["kind"] for e in vp.wallpaper_entries()], ["video"])
        self.assertIsNone(vp.default_wallpaper())
        self.assertEqual(v["palette"]["accent"], "#df7a8c")
        self.assertEqual(v["palette"]["bg"], palette.NEUTRAL_DARK["bg"])

        s = json.loads((self.user / "qylock-solid" / "theme.json").read_text())
        self.assertEqual((s["polarity"], s["palette"]["bg"]), ("light", "#eef6f0"))

        # The rendered manifest points the lock loader at the installed design.
        out_dir = self.tmp / "r"
        rc, _, err = loft("theme", "render", "qylock-still", str(out_dir))
        self.assertEqual(rc, 0, err)
        rm = json.loads((out_dir / "manifest.json").read_text())
        self.assertEqual(rm["lock"]["path"], str((still / "lock" / "qylock").resolve()))

    def test_qylock_backgrounds(self):
        self.assertEqual(loft("theme", "install", "qylock:multi")[0], 0)
        t = json.loads((self.user / "qylock-multi" / "theme.json").read_text())
        self.assertEqual(t["wallpaper"], {"image": "lock/qylock/background/A Glow.jpg", "images": ["lock/qylock/background/B Glow.jpg"]})
        self.assertIn("2 backgrounds", json.loads((self.user / "qylock-multi" / "manifest.json").read_text())["description"])

        # Videos with ffmpeg: a still frame per video in wallpapers/, noting the video.
        def frame(video, out):
            out.write_bytes(make_png(4, 4, two_tone))
            return True

        with (
            mock.patch.object(palette, "have_ffmpeg", return_value=True),
            mock.patch.object(palette, "ffmpeg_frame", side_effect=frame),
            mock.patch.object(palette, "ffmpeg_sample", return_value=[(20, 24, 40)] * 50 + [(240, 140, 40)] * 20),
        ):
            self.assertEqual(loft("theme", "install", "qylock:clips")[0], 0)
        clips = self.user / "qylock-clips"
        t = json.loads((clips / "theme.json").read_text())
        self.assertEqual(
            t["wallpaper"],
            {"images": [{"path": "wallpapers/day.jpg", "video": "lock/qylock/day.mp4"}, {"path": "wallpapers/night.jpg", "video": "lock/qylock/night.mp4"}]},
        )
        from loft.pack import Pack

        p = Pack(clips)
        self.assertEqual(p.default_wallpaper()["path"], clips.resolve() / "wallpapers/day.jpg")
        self.assertEqual(p.default_wallpaper()["video"], clips.resolve() / "lock/qylock/day.mp4")

    def test_lock_dir_not_in_digest(self):
        self.assertEqual(loft("theme", "install", "qylock:still")[0], 0)
        from loft.pack import Pack

        p = Pack(self.user / "qylock-still")
        d = p.digest()
        main = self.user / "qylock-still" / "lock" / "qylock" / "Main.qml"
        main.write_text("x" * len(main.read_bytes()))  # same size: lock/ is listed, not hashed
        self.assertEqual(Pack(p.path).digest(), d)
        (self.user / "qylock-still" / "lock" / "qylock" / "extra.qml").write_text("new file")
        self.assertNotEqual(Pack(p.path).digest(), d)

    @unittest.skipUnless(HAVE_JSONSCHEMA, "needs jsonschema")
    def test_installed_packs_validate(self):
        self.assertEqual(loft("theme", "install", "qylock:all")[0], 0)
        self.assertEqual(loft("theme", "install", "cozytile:all")[0], 0)
        names = sorted(p.name for p in self.user.iterdir())
        rc, _, err = loft("theme", "validate", *names)
        self.assertEqual(rc, 0, err)

    def test_errors(self):
        rc, _, err = loft("theme", "install", "qylock:does-not-exist")
        self.assertEqual(rc, 1)
        self.assertIn("no qylock theme", err)
        rc, _, err = loft("theme", "install", "cozytile:")
        self.assertEqual(rc, 1)
        self.assertIn("cozytile:all", err)
        os.environ["LOFT_QYLOCK_URL"] = f"file://{self.tmp}/missing"
        rc, _, err = loft("theme", "install", "qylock:still")
        self.assertEqual(rc, 1)
        self.assertIn("network down", err)
        self.assertFalse(self.user.exists() and any(self.user.iterdir()))


if __name__ == "__main__":
    unittest.main()
