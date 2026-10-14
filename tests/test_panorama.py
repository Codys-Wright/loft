"""Workspace panorama (cli/loft/panorama.py): the layout math against niri
26.04 JSON recorded in a test session (tests/fixtures/panorama — positions
checked against the session's pixels), niri's "fit" rule, the floating
window workarounds, the width cap, and a whole run against a fake niri that
draws its strip into frames (no compositor needed).
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from loft import panorama as P
from loft import stitch

FIX = Path(__file__).parent / "fixtures" / "panorama"
OUT = {"name": "winit", "width": 1600, "height": 1000, "scale": 1.0}
# The session: menu bar 30 px, an always-shown 48 px dock (76 px zone), gaps 12.
PARAMS = P.Params(gaps=12, insets=(0, 0, 30, 76), radius=12)


def windows() -> list[dict]:
    return json.loads((FIX / "windows.json").read_text())


class LayoutTest(unittest.TestCase):
    def test_columns_from_the_recorded_session(self):
        lay = P.plan([w for w in windows() if not w["is_floating"]], 1, OUT, PARAMS)
        self.assertEqual((lay.working.x, lay.working.y, lay.working.w, lay.working.h), (0, 30, 1600, 894))
        cols = lay.columns
        self.assertEqual([c.width for c in cols], [517, 782, 1046, 500, 782])
        self.assertEqual([c.mode for c in cols], ["normal", "normal", "normal", "normal", "tabbed"])
        # Strip: Σ (width + gaps); the panorama keeps a gap's margin at both ends.
        self.assertEqual([c.strip_x for c in cols], [0, 529, 1323, 2381, 2893])
        self.assertEqual([c.canvas_x for c in cols], [12, 541, 1335, 2393, 2905])
        self.assertEqual((lay.width, lay.height), (3699, 1000))
        # center-column: (working width - column width) / 2 — as grabbed.
        self.assertEqual([c.screen_x for c in cols], [541.5, 409, 277, 550, 409])
        stack = cols[1]
        r1, r2 = (lay.tile_rect(stack, t) for t in stack.tiles)
        self.assertEqual((r1.x, r1.y, r1.w, r1.h), (409, 42, 782, 429))
        self.assertEqual((r2.x, r2.y), (409, 42 + 429 + 12), "stacked: a gap below the first")
        tabs = cols[4]
        self.assertEqual({lay.tile_rect(tabs, t).y for t in tabs.tiles}, {42}, "tabs share the top")
        self.assertTrue(any("tabbed" in n for n in lay.notes))
        self.assertEqual(lay.canvas_pos(stack, stack.tiles[1]), (541, 483))
        # Pixel rects round half away from zero, like niri.
        self.assertEqual(P.px_rect(lay.tile_rect(cols[0], cols[0].tiles[0]), 1.0), (542, 42, 517, 870))
        # Every column centered once, the whole tile.
        self.assertTrue(all(len(c.takes) == 1 and c.takes[0].via is None for c in cols))

    def test_floating_window_moves_columns_to_the_edge(self):
        lay = P.plan(windows(), 1, OUT, PARAMS)
        self.assertEqual([f["id"] for f in lay.floating], [9])
        cols = lay.columns
        # Floating at 818: column 1 is looked at left-aligned (center column 2
        # first, then focus 1 — niri's fit puts it at working.x + gaps).
        self.assertEqual((cols[0].takes[0].via, cols[0].takes[0].x), (1, 12))
        self.assertEqual(cols[0].takes[0].actions(0), [("focus-column", "2"), ("center-column",), ("focus-column", "1")])
        self.assertEqual(cols[3].takes[0].x, 12)
        # 1046 px don't fit beside it anywhere: patches, and what's left over.
        self.assertGreater(len(cols[2].takes), 1)
        self.assertTrue(cols[2].hidden)
        # The last column can only be reached from the left: covered.
        self.assertTrue(cols[4].hidden)

    def test_fit(self):
        lay = P.plan([w for w in windows() if not w["is_floating"]], 1, OUT, PARAMS)
        c1, c2, c3, c4, _ = lay.columns
        view = c4.strip_x - c4.screen_x  # column 4 centered
        self.assertEqual(P.fit_x(lay, view, c3), 12, "to the left: left edge + gaps")
        view = c1.strip_x - c1.screen_x
        self.assertEqual(P.fit_x(lay, view, c2), 1600 - 12 - 782, "to the right: right edge - gaps")
        self.assertEqual(P.fit_x(lay, view, c1), c1.screen_x, "visible: stays")

    def test_fullscreen_maximized_single_empty(self):
        def win(i, col, tile, w, h, **kw):
            return {"id": i, "workspace_id": 1, "is_floating": False, "layout": {"pos_in_scrolling_layout": [col, tile], "tile_size": [w, h]}, **kw}

        lay = P.plan([win(1, 1, 1, 1600, 1000)], 1, OUT, PARAMS)
        c = lay.columns[0]
        self.assertEqual((c.mode, c.screen_x, lay.width), ("fullscreen", 0, 1624))
        r = lay.tile_rect(c, c.tiles[0])
        self.assertEqual((r.x, r.y), (0, 0))
        self.assertEqual(lay.canvas_pos(c, c.tiles[0]), (12, 0))

        lay = P.plan([win(1, 1, 1, 1600, 894), win(2, 2, 1, 500, 870)], 1, OUT, PARAMS)
        self.assertEqual([c.mode for c in lay.columns], ["maximized", "normal"])
        self.assertEqual(lay.tile_rect(lay.columns[0], lay.columns[0].tiles[0]).y, 30)

        lay = P.plan([win(1, 1, 1, 782, 870)], 1, OUT, PARAMS)
        self.assertEqual((len(lay.columns), lay.width, lay.columns[0].screen_x), (1, 806, 409))

        self.assertEqual(P.plan([], 1, OUT, PARAMS).columns, [])

    def test_width_cap_keeps_the_columns_that_fit(self):
        many = [{"id": i, "workspace_id": 1, "is_floating": False, "layout": {"pos_in_scrolling_layout": [i, 1], "tile_size": [1500, 870]}} for i in range(1, 40)]
        lay = P.plan(many, 1, OUT, PARAMS)
        self.assertLessEqual(lay.width, P.MAX_WIDTH)
        self.assertEqual(len(lay.columns) + len(lay.left_out), 39)
        self.assertEqual(len(lay.columns), (40000 - 12) // 1512)
        self.assertTrue(any("limit" in n for n in lay.notes))
        hidpi = P.plan(many, 1, {**OUT, "scale": 2.0}, PARAMS)
        self.assertLessEqual(hidpi.width * 2, P.MAX_WIDTH, "the cap is in pixels")

    def test_working_area_rounds_to_physical_pixels(self):
        parent, wa = P.working_area(1600, 1000, P.Params(gaps=8, insets=(0, 0, 30.3, 0), struts=(10, 0, 0, 0)), 1.5)
        self.assertAlmostEqual(wa.y * 1.5, round(wa.y * 1.5))
        self.assertEqual(wa.x, 10)
        self.assertAlmostEqual(wa.y + wa.h, 1000)


# ── A whole run against a fake niri ─────────────────────────────────────

SW, SH = 400, 250
SMALL = P.Params(gaps=4, insets=(0, 0, 10, 0), radius=3)


def small_windows(floating_at: tuple[float, float] | None = None) -> list[dict]:
    def win(i, col, tile, w, h):
        return {"id": i, "workspace_id": 1, "is_floating": False, "is_focused": False, "layout": {"pos_in_scrolling_layout": [col, tile], "tile_size": [w, h], "tile_pos_in_workspace_view": None}}

    ws = [win(1, 1, 1, 120, 232), win(2, 2, 1, 180, 114), win(3, 2, 2, 180, 114), win(4, 3, 1, 260, 232), win(5, 4, 1, 100, 232), win(6, 5, 1, 180, 232), win(7, 5, 2, 180, 232)]
    if floating_at:
        ws.append({"id": 9, "workspace_id": 1, "is_floating": True, "is_focused": True, "layout": {"pos_in_scrolling_layout": None, "tile_size": [150, 120], "tile_pos_in_workspace_view": list(floating_at)}})
    return ws


def color(wid: int) -> bytes:
    return bytes(((wid * 53) % 200 + 40, (wid * 97) % 200 + 40, (wid * 31) % 200 + 40))


class FakeNiri:
    """A workspace strip that moves like niri's (center-column, fit on
    focus) and draws itself: each tile a solid color with a darker band
    along its top so positions show, floating windows on top, a wallpaper
    that doesn't move."""

    def __init__(self, floating_at=None):
        self.wins = small_windows(floating_at)
        self.lay = P.plan([w for w in self.wins if not w["is_floating"]], 1, {"name": "o", "width": SW, "height": SH, "scale": 1}, SMALL)
        self.col = 2  # 0-based active column
        self.tab = {5: 7}  # tabbed column 5: its second tile is active
        c = self.lay.columns[self.col]
        self.view = c.strip_x - P.fit_x(self.lay, 0.0, c)
        self.focus = 9 if floating_at else 4
        self.actions: list[tuple[str, ...]] = []

    def floats(self):
        return [w for w in self.wins if w["is_floating"]]

    def active_tile(self, c):
        if c.mode == "tabbed":
            return self.tab.get(c.index + 1, c.tiles[0].id)
        return c.tiles[0].id

    def query(self, what):
        if what == "outputs":
            return {"o": {"name": "o", "logical": {"x": 0, "y": 0, "width": SW, "height": SH, "scale": 1.0}}}
        if what == "focused-output":
            return {"name": "o"}
        if what == "workspaces":
            return [{"id": 1, "idx": 1, "output": "o", "is_active": True, "is_focused": True, "active_window_id": self.focus}]
        if what == "windows":
            for w in self.wins:
                w["is_focused"] = w["id"] == self.focus
            return json.loads(json.dumps(self.wins))
        if what == "focused-window":
            return {"id": self.focus}
        raise AssertionError(what)

    def action(self, *a):
        self.actions.append(a)
        cols = self.lay.columns
        if a[0] == "focus-column":
            self.col = int(a[1]) - 1
            c = cols[self.col]
            self.view = c.strip_x - P.fit_x(self.lay, self.view, c)
            self.focus = self.active_tile(c)
        elif a[0] in ("focus-column-first", "focus-column-last"):
            self.action("focus-column", "1" if a[0].endswith("first") else str(len(cols)))
        elif a[0] == "center-column":
            assert self.focus != 9, "center-column on a floating window moves it"
            c = cols[self.col]
            self.view = c.strip_x - c.screen_x
        elif a[0] == "focus-window":
            wid = int(a[2])
            self.focus = wid
            for c in cols:
                if any(t.id == wid for t in c.tiles):
                    self.col = c.index
                    self.view = c.strip_x - P.fit_x(self.lay, self.view, c)
        elif a[0] == "move-floating-window":
            w = next(w for w in self.wins if w["id"] == int(a[2]))
            pos = w["layout"]["tile_pos_in_workspace_view"]
            # niri keeps a sliver on screen
            pos[0] = min(SW - 30, pos[0] + float(a[4]))
            pos[1] = pos[1] + float(a[6])
        elif a[0] == "center-visible-columns":
            pass
        else:
            raise AssertionError(a)

    def grab(self) -> stitch.Image:
        rows = [bytearray(bytes((20 + y % 7, 30, 60 + (y // 5) % 9)) * SW) for y in range(SH)]

        def fill(x, y, w, h, rgb, band=None):
            for yy in range(max(0, int(y)), min(SH, int(y + h))):
                cc = band if band is not None and yy < y + 3 else rgb
                for xx in range(max(0, int(x)), min(SW, int(x + w))):
                    rows[yy][xx * 3 : xx * 3 + 3] = cc

        for c in self.lay.columns:
            sx = c.strip_x - self.view
            if c.mode == "tabbed":
                tiles = [t for t in c.tiles if t.id == self.active_tile(c)]
            else:
                tiles = c.tiles
            for t in tiles:
                r = self.lay.tile_rect(c, t, sx)
                fill(r.x, r.y, r.w, r.h, color(t.id), bytes((0, 0, 0)))
        for f in self.floats():
            x, y = f["layout"]["tile_pos_in_workspace_view"]
            fill(x, y, *f["layout"]["tile_size"], bytes((255, 0, 255)))
        return stitch.Image(SW, SH, b"".join(bytes(r) for r in rows))


class SessionTest(unittest.TestCase):
    def run_session(self, fake):
        clock = [0.0]

        def sleep(s):
            clock[0] += s

        ses = P.Session(fake, fake.grab, sleep=sleep, clock=lambda: clock[0])
        lay, shots, state = ses.run(None, SMALL)
        td = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(td, ignore_errors=True))
        out = Path(td) / "pano.png"
        w, h = P.compose(lay, shots, out, "#101010")
        return lay, state, stitch.read_png(out), (w, h)

    def pixel(self, img, x, y):
        return img.data[(y * img.width + x) * 3 : (y * img.width + x) * 3 + 3]

    def assert_tiles(self, lay, img, skip=()):
        for c in lay.columns:
            for t in c.tiles:
                if t.id in skip:
                    continue
                x, y = lay.canvas_pos(c, t)
                x, y = int(x), int(y)
                # Inside (away from the rounded corners): the tile's color;
                # its top band sits exactly at its top.
                self.assertEqual(self.pixel(img, x + int(t.w) // 2, y + int(t.h) // 2), color(t.id), f"tile {t.id}")
                self.assertEqual(self.pixel(img, x + int(t.w) // 2, y), b"\0\0\0", f"tile {t.id} top")
                self.assertEqual(self.pixel(img, x + int(t.w) // 2, y + 3), color(t.id), f"tile {t.id} top")
                self.assertEqual(self.pixel(img, x + int(t.w) - 1, y + int(t.h) // 2), color(t.id), f"tile {t.id} right edge")
                self.assertEqual(self.pixel(img, x + int(t.w), y + int(t.h) // 2), b"\x10\x10\x10", f"tile {t.id}: background right of it")
                # The rounded corner shows the backdrop.
                self.assertEqual(self.pixel(img, x, y), b"\x10\x10\x10")

    def test_every_column_side_by_side_and_focus_back(self):
        fake = FakeNiri()
        lay, state, img, size = self.run_session(fake)
        self.assertEqual(size, (4 + 120 + 4 + 180 + 4 + 260 + 4 + 100 + 4 + 180 + 4, SH))
        self.assert_tiles(lay, img, skip=(6,))  # the inactive tab
        self.assertEqual(state["stops"], 5)
        self.assertEqual(state["view"], "exact")
        self.assertEqual((fake.focus, fake.col), (4, 2), "focus and the view come back")
        self.assertNotIn(b"\xff\x00\xff", img.data)

    def test_floating_window_is_left_out_and_put_back(self):
        fake = FakeNiri(floating_at=(140.0, 60.0))
        lay, state, img, _ = self.run_session(fake)
        self.assert_tiles(lay, img, skip=(6,))
        # No floating pixels anywhere in the panorama.
        mag = sum(1 for i in range(0, len(img.data), 3) if img.data[i : i + 3] == b"\xff\x00\xff")
        self.assertEqual(mag, 0)
        self.assertEqual(fake.floats()[0]["layout"]["tile_pos_in_workspace_view"], [140.0, 60.0], "back where it was")
        self.assertEqual(fake.focus, 9, "the floating window has focus again")
        self.assertTrue(any("floating" in n for n in lay.notes))

    def test_empty_workspace(self):
        fake = FakeNiri()
        fake.wins = []
        with self.assertRaises(P.EmptyWorkspace):
            P.Session(fake, fake.grab, sleep=lambda s: None).run(None, SMALL)


class PixelsTest(unittest.TestCase):
    def test_hex_and_corners(self):
        self.assertEqual(P.hex_color("#1e1e2e"), (0x1E, 0x1E, 0x2E))
        self.assertEqual(P.hex_color("#801e1e2e"), (0x1E, 0x1E, 0x2E), "Qt #aarrggbb")
        a = P.corner_alpha(8)
        self.assertEqual(a[0][0], 0.0)
        self.assertEqual(a[7][7], 1.0)
        self.assertTrue(any(0 < v < 1 for row in a for v in row), "anti-aliased edge")

    def test_view_match_finds_a_shift(self):
        fake = FakeNiri()
        a = fake.grab()
        fake.view -= 3
        b = fake.grab()
        frac, dx = P.view_match(a, b, (10, 240))
        self.assertEqual(dx, 3)
        self.assertGreater(frac, 0.9)


if __name__ == "__main__":
    unittest.main()
