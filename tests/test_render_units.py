"""Render units, the composition cache and hook diffing
(docs/THEME-ARCHITECTURE.md §6, phase B).

Run: PYTHONPATH=cli python3 -m unittest tests.test_render_units -v
Everything runs against scratch dirs; hooks are recorded, never run.
"""

from __future__ import annotations

import contextlib
import copy
import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from loft import hooks, render
from loft.cli import main
from loft.facets import resolve as R
from loft.facets.model import KINDS, Catalog
from loft.render import compose, niri

ROOT = Path(__file__).resolve().parent.parent
V1 = ROOT / "tests" / "fixtures" / "v1packs"
TEMPLATES = ROOT / "templates" / "render"


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class Env(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "XDG_STATE_HOME": str(self.tmp / "xstate"),
                "XDG_CONFIG_HOME": str(self.tmp / "config"),
                "LOFT_STATE_DIR": str(self.tmp / "state"),
                "LOFT_LIBRARY": str(self.tmp / "lib"),
                "LOFT_THEME_INDEX": "none",
                "LOFT_THEME_PATH": f"{V1}:{ROOT / 'themes'}",
                "LOFT_HOOKS": "all",  # recorded below, never run
            }
        )
        for k in ("LOFT_DATA_DIR", "LOFT_THEME_ENGINE"):
            os.environ.pop(k, None)
        self.ran: list[list[str]] = []
        self.previews: list = []
        p1 = mock.patch.object(hooks, "run", lambda names, ctx: self.ran.append(list(names)))
        p2 = mock.patch.object(hooks, "preview", lambda ctx, d: self.previews.append(d))
        p1.start()
        p2.start()
        self.addCleanup(p1.stop)
        self.addCleanup(p2.stop)
        self.state = self.tmp / "state"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def ok(self, *argv: str) -> str:
        rc, out, err = loft(*argv)
        self.assertEqual(rc, 0, err)
        return out + err

    def apply(self, *argv: str) -> dict:
        """Run a command that applies; return {rendered, changed, hooks}."""
        self.ran.clear()
        before = compose.units_of((self.state / "current").resolve()) if (self.state / "current").is_symlink() else None
        n = len(self._units())
        self.ok(*argv)
        after = compose.units_of((self.state / "current").resolve())
        return {
            "changed": sorted(compose.changed(before, after)),
            "rendered": len(self._units()) - n,
            "hooks": self.ran[-1] if self.ran else [],
        }

    def _units(self) -> list[Path]:
        root = compose.units_root(self.state)
        return [d for u in root.iterdir() for d in u.iterdir()] if root.is_dir() else []


class Declarations(unittest.TestCase):
    """Each unit's cache key moves with the kinds it reads, and only those."""

    def setUp(self):
        self.cat = Catalog([V1], builtin=ROOT / "packs")

    def digests(self, res) -> dict:
        src = render.source(res, self.cat, TEMPLATES)
        return {p.unit.name: p.digest for p in compose.plan(src, render.UNITS)}

    def test_units_cover_every_file(self):
        names = [u.name for u in render.UNITS]
        self.assertEqual(len(names), len(set(names)))
        for u in render.UNITS:
            self.assertTrue(set(u.reads) <= set(KINDS), u.name)
            for t in u.templates:
                self.assertTrue((TEMPLATES / t).is_file(), t)
        self.assertEqual(sorted(t.name for t in TEMPLATES.iterdir()), sorted(t for u in render.UNITS for t in u.templates))

    def test_a_kind_moves_only_its_readers(self):
        t, v = self.cat.theme("cozytile-sakura")
        base = R.resolve(self.cat, t, v)
        d0 = self.digests(base)
        perturb = {
            "colors": lambda f: f["palette"].update(accent="#123456"),
            "material": lambda f: f["blur"].update(enabled=not f["blur"]["enabled"]),
            "motion": lambda f: f.update(speed=1.5),
            "shape": lambda f: f["radius"].update(window=3),
            "typography": lambda f: f["ui"].update(family="Inter"),
            "icons": lambda f: f["icons"].update(theme="MacTahoe"),
            "launcher": lambda f: f.update(glass=1.2),
            "wallpapers": lambda f: f.update(default=None, collection=[], dirs=[]),
            "lock": lambda f: f.update(format="builtin", path=None),
            "sounds": lambda f: f.update(theme="freedesktop"),
        }
        for kind, fn in perturb.items():
            res = copy.copy(base)
            res.facets = copy.deepcopy(base.facets)
            fn(res.facets[kind])
            moved = {u for u, d in self.digests(res).items() if d != d0[u]}
            readers = {u.name for u in render.UNITS if kind in u.reads}
            if readers:  # sounds: nothing renders it yet (gsettings, phase I)
                self.assertTrue(moved, kind)
            self.assertTrue(moved <= readers, f"{kind}: {sorted(moved - readers)} moved without reading it")

    def test_salt_is_per_unit(self):
        src = TEMPLATES
        tmp = Path(tempfile.mkdtemp())
        try:
            shutil.copytree(src, tmp / "t", copy_function=shutil.copyfile)
            (tmp / "t").chmod(0o755)  # the source may be read-only (the Nix store)
            before = {u.name: u.salt(tmp / "t") for u in render.UNITS}
            with open(tmp / "t" / "gtk.css", "a") as f:
                f.write("/* edited */\n")
            after = {u.name: u.salt(tmp / "t") for u in render.UNITS}
            self.assertEqual([n for n in before if before[n] != after[n]], ["gtk"])
        finally:
            shutil.rmtree(tmp)


class Niri(unittest.TestCase):
    def test_motion_and_shape_kdl(self):
        m = {"speed": 1.0, "minimal": False, "niri": {}}
        self.assertEqual(niri.animations(m), "")
        self.assertIn("animations {\n    off\n}", niri.animations(dict(m, minimal=True)))
        out = niri.animations(
            {
                "speed": 1.5,
                "minimal": False,
                "niri": {
                    "workspace-switch": {"spring": {"damping-ratio": 1.0, "stiffness": 1000, "epsilon": 0.0001}},
                    "window-open": {"duration-ms": 150, "curve": "ease-out-expo"},
                    "window-close": {"off": True},
                    "window-resize": {"duration-ms": 200, "curve": ["cubic-bezier", 0.05, 0.7, 0.1, 1]},
                },
            }
        )
        self.assertIn("    slowdown 0.666667\n", out)
        self.assertIn("    workspace-switch {\n        spring damping-ratio=1.0 stiffness=1000 epsilon=0.0001\n    }\n", out)
        self.assertIn('    window-open {\n        duration-ms 150\n        curve "ease-out-expo"\n    }\n', out)
        self.assertIn("    window-close {\n        off\n    }\n", out)
        self.assertIn('        curve "cubic-bezier" 0.05 0.7 0.1 1\n', out)
        self.assertIn("slowdown 2.0", niri.animations({"speed": 0.5, "minimal": False, "niri": {}}))
        shape = {"focus": "ring", "focusRing": {"width": 3}}
        ring, rules = niri.focus(shape)
        self.assertEqual(ring, "on\n        width 3")
        self.assertIn("match is-focused=true", rules)
        self.assertEqual(niri.focus(dict(shape, focus="both"))[1], "")
        self.assertEqual(niri.focus(dict(shape, focus="shadow")), ("off", ""))


class Apply(Env):
    def test_cache_and_hook_diffing(self):
        r = self.apply("theme", "apply", "tokyonight")
        self.assertEqual(r["rendered"], len(render.UNITS))
        self.assertEqual(r["hooks"], ["shell", "niri", "wallpapers", "kitty", "ghostty", "gtk", "qt", "spotify"])
        cur = (self.state / "current").resolve()
        self.assertEqual(cur.parent, compose.compositions_root(self.state).resolve())
        self.assertTrue((self.state / "current" / "theme.json").is_symlink())
        resolved = json.loads((cur / "resolved.json").read_text())
        self.assertEqual((resolved["theme"], resolved["variant"], resolved["name"]), ("loft", None, "tokyonight"))
        self.assertEqual(resolved["base"], "dark")
        self.assertEqual(sorted(resolved["units"]), sorted(u.name for u in render.UNITS))

        # Same look again: nothing rendered, nothing reloaded.
        r = self.apply("theme", "apply", "loft@dark")
        self.assertEqual((r["rendered"], r["changed"], r["hooks"]), (0, [], []))
        self.assertEqual((self.state / "current").resolve(), cur)
        r = self.apply("theme", "apply", "loft@dark", "--reload")
        self.assertEqual(len(r["hooks"]), len(hooks.ALL))

        # Motion: exactly the units that read it.
        r = self.apply("motion", "apply", "motion:snappy")
        self.assertEqual(r["changed"], ["niri", "shell"])
        self.assertEqual(r["rendered"], 2)
        self.assertEqual(r["hooks"], ["shell", "niri"])
        t = json.loads((self.state / "current" / "theme.json").read_text())
        self.assertEqual((t["motion"]["speed"], t["motion"]["durations"]["fast"]), (1.5, 107))
        self.assertIn("slowdown 0.666667", (self.state / "current" / "niri.kdl").read_text())

        # Shape gaps: niri alone (the shell doesn't use gaps).
        r = self.apply("shape", "set", "gaps", "8")
        self.assertEqual((r["changed"], r["hooks"]), (["niri"], ["niri"]))
        self.assertIn("    gaps 8\n", (self.state / "current" / "niri.kdl").read_text())

        # The glass slider: shell, GTK + Qt sidebars, walker — not niri, not the terminals.
        r = self.apply("material", "set", "glass.opacity", "0.3")
        self.assertEqual(r["changed"], ["gtk", "qt", "shell", "walker"])
        self.assertEqual(r["hooks"], ["shell", "gtk", "qt"])

        # Blur off: terminals too (their opacity follows blur), and niri.
        r = self.apply("material", "set", "blur.enabled", "false")
        self.assertEqual(r["changed"], ["ghostty", "gtk", "kitty", "niri", "qt", "shell"])

        # A wallpaper arrangement: wallpapers.json alone — no terminal signal, no niri reload.
        r = self.apply("wallpapers", "set", "arrangement.auto", "true")
        self.assertEqual((r["changed"], r["hooks"]), (["wallpapers"], ["wallpapers"]))

        # Launcher glass: walker alone, which needs no hook.
        r = self.apply("launcher", "set", "glass", "1.2")
        self.assertEqual((r["changed"], r["hooks"]), (["walker"], []))

        # Switching back to a look used before: all cached, symlink swap only.
        self.ok("theme", "reset", "--all")
        r = self.apply("theme", "apply", "tokyonight")
        self.assertEqual((r["rendered"], r["changed"]), (0, []))
        self.assertEqual((self.state / "current").resolve(), cur)

    def test_variant_switch_and_identity(self):
        self.apply("theme", "apply", "loft@dark")
        r = self.apply("theme", "apply", "loft@light")
        # Colors change everything but… nothing: every unit reads the palette or the name.
        self.assertIn("niri", r["changed"])
        self.assertIn("kitty", r["hooks"])
        # A customization equal to the default: same files, new resolved.json.
        before = (self.state / "current").resolve()
        r = self.apply("material", "set", "glass.opacity", "0.5")
        self.assertEqual(r["changed"], [])
        after = (self.state / "current").resolve()
        self.assertNotEqual(before, after)
        self.assertEqual(json.loads((after / "resolved.json").read_text())["customized"], ["material"])

    def test_preview_leaves_current_alone(self):
        self.ok("theme", "apply", "tokyonight")
        cur = (self.state / "current").resolve()
        self.ran.clear()
        rc, out, err = loft("theme", "preview", "cozytile-sakura", "--json")
        self.assertEqual(rc, 0, err)
        p = json.loads(out)
        self.assertEqual((self.state / "current").resolve(), cur)
        self.assertEqual(self.ran, [])  # niri, terminals, GTK untouched
        self.assertEqual(self.previews, [Path(p["dir"])])
        self.assertEqual((self.state / "preview").resolve(), Path(p["dir"]).resolve())
        self.assertEqual(json.loads((Path(p["dir"]) / "theme.json").read_text())["name"], "cozytile-sakura")
        # Applying it afterwards reuses every unit the preview rendered.
        r = self.apply("theme", "apply", "cozytile-sakura")
        self.assertEqual(r["rendered"], 0)
        self.assertEqual((self.state / "current").resolve(), Path(p["dir"]).resolve())
        self.ok("theme", "preview", "--stop")
        self.assertFalse((self.state / "preview").is_symlink())
        self.assertEqual(self.previews[-1], None)

    def test_gc_keeps_pinned(self):
        self.ok("theme", "apply", "tokyonight")
        cur = (self.state / "current").resolve()
        for i in range(4):
            self.ok("colors", "set", "palette.accent", f'"#00000{i}"')
        removed = compose.gc(self.state, compose.pinned_targets(self.state) + [cur], keep_units=1, keep_compositions=1)
        self.assertGreater(removed["units"], 0)
        comps = [d for d in compose.compositions_root(self.state).iterdir()]
        self.assertEqual(sorted(comps), sorted({(self.state / "current").resolve(), cur}))
        for d in comps:  # every kept composition still resolves
            for f in d.iterdir():
                self.assertTrue(f.exists(), f)

    def test_gc_drops_v1_render_dirs(self):
        old = self.state / "rendered" / "tokyonight" / "abc"
        old.mkdir(parents=True)
        (old / "theme.json").write_text("{}")
        (self.state / "current").symlink_to(old)
        r = self.apply("theme", "apply", "tokyonight")
        self.assertEqual(len(r["hooks"]), len(hooks.ALL))  # from a v1 dir: everything reloads
        self.assertFalse(old.exists())

    def test_render_dir_is_flat(self):
        out = self.tmp / "out"
        self.ok("theme", "render", "cozytile-sakura", str(out))
        self.assertFalse(any(p.is_symlink() for p in out.iterdir()))
        self.assertFalse((out / "resolved.json").exists())
        w = json.loads((out / "wallpapers.json").read_text())
        self.assertTrue(w["default"].endswith(".png") or w["default"].endswith(".jpg") or w["default"] == "")


if __name__ == "__main__":
    unittest.main()
