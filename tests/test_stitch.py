"""Scrolling capture's stitcher (cli/loft/stitch.py) on synthetic frames:
plain scrolling, a sticky header + footer, a partial last frame, the
no-overlap fallback, scrolling back up, a moving scrollbar and a blinking
caret — plus the PPM/PNG codecs. Pure Python, no screen needed.
"""

from __future__ import annotations

import random
import tempfile
import unittest
from pathlib import Path

from loft import stitch
from loft.stitch import Image

W = 160
BG = bytes((250, 250, 250))


def document(rows: int, seed: int = 7) -> list[bytes]:
    """A page of "text": 16 px lines, 12 rows of ink + 4 blank rows each,
    with a blank paragraph break now and then."""
    rnd = random.Random(seed)
    out: list[bytes] = []
    while len(out) < rows:
        if rnd.random() < 0.12:
            out.extend([BG * W] * 16)
            continue
        for _ in range(12):
            out.append(bytes(rnd.randrange(256) for _ in range(W * 3)))
        out.extend([BG * W] * 4)
    return out[:rows]


def band(color: tuple[int, int, int], rows: int, label: int = 0) -> list[bytes]:
    """A solid bar with a little pattern so its rows are informative."""
    row = bytearray(bytes(color) * W)
    for x in range(10, 40):
        row[x * 3 : x * 3 + 3] = bytes(((label * 37 + x) % 256, 20, 200))
    return [bytes(row)] * rows


def frame(rows: list[bytes]) -> Image:
    return Image(W, len(rows), b"".join(rows))


class Frames:
    """Writes frames as PPM files into a temp dir."""

    def __init__(self, tmp: Path):
        self.tmp, self.n = tmp, 0

    def __call__(self, rows: list[bytes]) -> str:
        self.n += 1
        p = self.tmp / f"f{self.n:03}.ppm"
        stitch.write_ppm(p, frame(rows))
        return str(p)


class StitchTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.tmp = Path(self._td.name)
        self.frames = Frames(self.tmp)

    def tearDown(self):
        self._td.cleanup()

    def stitched(self, paths: list[str]) -> tuple[Image, dict]:
        out = self.tmp / "out.png"
        info = stitch.stitch_files(paths, str(out))
        return stitch.read_png(out), info

    def assertRows(self, img: Image, rows: list[bytes]):
        self.assertEqual((img.width, img.height), (W, len(rows)))
        for y, r in enumerate(rows):
            if img.row(y) != r:
                self.fail(f"row {y} differs")

    def test_codecs_roundtrip(self):
        doc = document(50)
        p = self.tmp / "x.ppm"
        stitch.write_ppm(p, frame(doc))
        img = stitch.read_ppm(p)
        self.assertEqual(img.data, b"".join(doc))
        png = self.tmp / "x.png"
        png.write_bytes(stitch.png_bytes(W, 50, iter(doc)))
        self.assertEqual(stitch.read_png(png).data, img.data)
        with_comment = b"P6\n# grim\n160 1\n255\n" + doc[0]
        self.assertEqual(stitch.parse_ppm(with_comment).data, doc[0])

    def test_plain_scrolling(self):
        doc, h = document(1400), 300
        offs = [0, 37, 180, 333, 520, 700, 850]
        img, info = self.stitched([self.frames(doc[o : o + h]) for o in offs])
        self.assertRows(img, doc[: offs[-1] + h])
        self.assertEqual(info["gaps"], 0)
        self.assertEqual(info["kept"], len(offs))

    def test_sticky_header_and_footer(self):
        doc, h = document(1400, seed=3), 320
        head, foot = band((30, 30, 60), 40, 1), band((60, 30, 30), 24, 2)
        view = h - len(head) - len(foot)
        offs = [0, 120, 240, 390, 500]
        paths = [self.frames(head + doc[o : o + view] + foot) for o in offs]
        img, info = self.stitched(paths)
        self.assertRows(img, head + doc[: offs[-1] + view] + foot)
        self.assertGreaterEqual(info["header"], 40)
        self.assertGreaterEqual(info["footer"], 24)

    def test_partial_last_frame(self):
        doc, h = document(700, seed=11), 300
        # The last scroll stops short: the page ended.
        offs = [0, 200, 371, 400]
        img, _ = self.stitched([self.frames(doc[o : o + h]) for o in offs])
        self.assertRows(img, doc)

    def test_no_overlap_falls_back_to_appending(self):
        doc, h = document(1400, seed=5), 200
        offs = [0, 150, 900]  # 150 → 900 skips more than a screen
        img, info = self.stitched([self.frames(doc[o : o + h]) for o in offs])
        self.assertEqual(info["gaps"], 1)
        self.assertRows(img, doc[: 150 + h] + doc[900 : 900 + h])

    def test_repeats_and_scrolling_back_add_nothing(self):
        doc, h = document(1000, seed=9), 250
        offs = [0, 0, 200, 120, 200, 380]
        img, info = self.stitched([self.frames(doc[o : o + h]) for o in offs])
        self.assertRows(img, doc[: 380 + h])
        self.assertEqual(info["kinds"].get("same"), 2)  # the repeat, and 200 again after going back
        self.assertEqual(info["kinds"].get("back"), 1)

    def test_moving_scrollbar_is_ignored(self):
        doc, h = document(1200, seed=13), 300
        offs = [0, 150, 310, 470]

        def with_bar(rows: list[bytes], off: int) -> list[bytes]:
            out = []
            thumb = off // 4
            for y, r in enumerate(rows):
                b = bytearray(r)
                if thumb <= y < thumb + 60:
                    b[(W - 4) * 3 :] = bytes((90, 90, 90)) * 4
                out.append(bytes(b))
            return out

        img, info = self.stitched([self.frames(with_bar(doc[o : o + h], o)) for o in offs])
        self.assertEqual(info["gaps"], 0)
        self.assertEqual(img.height, offs[-1] + h)
        # Away from the bar, every row is the document's.
        cut = (W - 24) * 3
        for y in range(img.height):
            self.assertEqual(img.row(y)[:cut], doc[y][:cut])

    def test_blinking_caret_is_not_a_scroll(self):
        doc, h = document(600, seed=17), 300
        a = doc[0:h]
        b = list(a)
        for y in (100, 101, 102):
            r = bytearray(b[y])
            r[30:33] = b"\x00\x00\x00"
            b[y] = bytes(r)
        img, info = self.stitched([self.frames(a), self.frames(b), self.frames(doc[150 : 150 + h])])
        self.assertEqual(info["kinds"].get("same"), 1)
        self.assertEqual(img.height, 150 + h)

    def test_segments_for_the_live_preview(self):
        doc, h = document(900, seed=19), 200
        st = stitch.Stitcher()
        for o in (0, 90, 200):
            st.add(self.frames(doc[o : o + h]))
        segs = st.segments()
        self.assertEqual(sum(s["h"] for s in segs), 200 + h)
        self.assertEqual([s["y"] for s in segs], [0, h, h + 90])
        self.assertEqual(st.total_height, 200 + h)


if __name__ == "__main__":
    unittest.main()
