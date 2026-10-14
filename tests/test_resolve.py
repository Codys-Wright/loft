"""The facet model (docs/THEME-ARCHITECTURE.md): resolver, user layer, saves,
the v1 adapter and the golden gate (resolved themes render byte for byte
like today's packs).

Run: PYTHONPATH=cli python3 -m unittest tests.test_resolve -v
Everything runs against scratch dirs (state, library, XDG), hooks off.
"""

from __future__ import annotations

import contextlib
import filecmp
import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

import v1_reference
from loft import color
from loft.cli import main
from loft.facets import appearance as A
from loft.facets import refs, schema
from loft.facets import resolve as R
from loft.facets.model import Catalog, FacetError, compose_patches, fill, fold, merge_patch
from loft.pack import Pack

ROOT = Path(__file__).resolve().parent.parent
BUILTIN = ROOT / "packs"
GOLDEN = ROOT / "tests" / "golden"
V1 = ROOT / "tests" / "fixtures" / "v1packs"
GLASSLESS = ROOT / "tests" / "fixtures" / "glassless"


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


def write(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc))


def facet(kind: str, fid: str, data: dict, **meta) -> dict:
    return {"kind": kind, "id": fid, "name": meta.pop("name", fid), "data": data, **meta}


def same_tree(a: Path, b: Path, ignore: tuple = ()) -> list[str]:
    """Differences between two directories (names and bytes), [] when equal."""
    out: list[str] = []
    cmp = filecmp.dircmp(a, b, ignore=list(ignore))
    out += [f"only in {a}: {n}" for n in cmp.left_only] + [f"only in {b}: {n}" for n in cmp.right_only]
    for n in cmp.common_files:
        if (a / n).read_bytes() != (b / n).read_bytes():
            out.append(f"differs: {n}")
    for d in cmp.common_dirs:
        out += same_tree(a / d, b / d)
    return out


# What phase B added to every render (docs/THEME-ARCHITECTURE.md §6): the
# grouped shell tokens, niri's focus ring / border switches, wallpapers.json.
# The default look keeps today's ring (focus "both", width 2): only the explicit
# `on` / `width` lines are new in niri.kdl.
# Everything else must stay byte-identical to the frozen v1 renderer.
NIRI_ADDED = (
    (
        '    // shape.focus: "shadow" marks the focused window with its deeper shadow\n'
        '    // alone (no ring); "ring" and "both" draw the ring, focusRing.width wide.\n'
    ),
    "        on\n        width 2\n",  # shape.focus "both" (the default): base.kdl's ring, explicit
    "    border {\n        off\n",  # shape.border off (the default, as base.kdl)
)


def without_additions(d: Path, into: Path) -> Path:
    """A copy of render dir `d` with phase B's additions taken out."""
    shutil.copytree(d, into, symlinks=False, copy_function=shutil.copyfile)
    for p in [into, *into.rglob("*")]:  # the source may be read-only (the Nix store)
        p.chmod(0o755 if p.is_dir() else 0o644)
    (into / "wallpapers.json").unlink()
    t = json.loads((into / "theme.json").read_text())
    for k in ("motion", "type", "icons", "a11y"):
        t.pop(k)
    t["shape"].pop("focus")
    (into / "theme.json").write_text(json.dumps(t, indent=2) + "\n")
    kdl = (into / "niri.kdl").read_text()
    for chunk in NIRI_ADDED:
        kdl = kdl.replace(chunk, "    border {\n" if chunk.startswith("    border") else "")
    kdl = kdl.replace("    // shape.border: drawn or not, and how wide.\n", "    // Colors only: whether the border is drawn stays the base/consumer's call.\n")
    (into / "niri.kdl").write_text(kdl)
    return into


class Scratch(unittest.TestCase):
    """A library with a user theme (`cozy`: base + variants that change
    colors only, one extending another) and loose facets."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.lib = self.tmp / "lib"
        write(self.lib / "Colors" / "rose.json", facet("colors", "rose", {"polarity": "dark", "palette": dict(PAL, accent="#ff0088")}))
        write(self.lib / "Colors" / "paper.json", facet("colors", "paper", {"polarity": "light", "palette": dict(PAL, bg="#f4f1ea", text="#202020")}))
        write(self.lib / "Materials" / "frost.json", facet("material", "frost", {"glass": {"opacity": 0.2, "tint": "@mix(accent,bg,0.5)"}}))
        write(self.lib / "Motion" / "slow.json", facet("motion", "slow", {"speed": 0.5}))
        write(self.lib / "Typography" / "serif.json", facet("typography", "serif", {"ui": {"family": "Serif"}}))
        write(
            self.lib / "Themes" / "cozy.json",
            {
                "kind": "theme",
                "id": "cozy",
                "name": "Cozy",
                "facets": {"colors": "colors:rose", "material": "material:liquid-glass"},
                "base": {"id": "night", "name": "Night"},
                "variants": [
                    {"id": "paper", "name": "Paper", "facets": {"colors": "colors:paper"}},
                    {"id": "calm", "name": "Paper, calm", "extends": "paper", "facets": {"motion": "motion:slow"}},
                    {"id": "loop-a", "extends": "loop-b"},
                    {"id": "loop-b", "extends": "loop-a"},
                ],
                "appearance": {"dark": "night", "light": "paper"},
            },
        )
        self.cat = Catalog([V1], builtin=BUILTIN, user=self.lib)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def resolve(self, ref: str, state: dict | None = None) -> R.Resolved:
        t, v = self.cat.theme(ref)
        return R.resolve(self.cat, t, v, state)


PAL = {
    "bg": "#1a1b26",
    "surface": "#24283b",
    "overlay": "#414868",
    "text": "#c0caf5",
    "subtext": "#a9b1d6",
    "accent": "#7aa2f7",
    "accent2": "#bb9af7",
    "urgent": "#f7768e",
    "ok": "#9ece6a",
    "warn": "#e0af68",
}


class MergeRules(unittest.TestCase):
    def test_merge_patch(self):
        self.assertEqual(merge_patch({"a": {"b": 1, "c": 2}, "d": [1]}, {"a": {"b": None, "e": 3}, "d": [2]}), {"a": {"c": 2, "e": 3}, "d": [2]})
        self.assertEqual(merge_patch(None, {"x": None, "y": 1}), {"y": 1})

    def test_compose_matches_sequential(self):
        base = {"glass": {"opacity": 0.4, "tint": "#000000"}, "blur": {"enabled": True}}
        p1 = {"glass": {"opacity": 0.3}, "blur": None}
        p2 = {"glass": {"tint": "#ffffff"}, "menuBar": {"background": True}}
        self.assertEqual(merge_patch(merge_patch(base, p1), p2), merge_patch(base, compose_patches(p1, p2)))

    def test_fold_last_ref_wins(self):
        sel = fold([{"ref": "a:x", "patch": {"k": 1}}, {"patch": {"j": 2}}, {"ref": "a:y"}, {"patch": {"m": 3}}])
        self.assertEqual(sel, {"ref": "a:y", "patch": {"m": 3}})
        self.assertEqual(fold([{"patch": {"a": {"b": 1}}}, {"patch": {"a": {"c": 2}}}]), {"patch": {"a": {"b": 1, "c": 2}}})
        self.assertIsNone(fold([]))

    def test_fill_never_merges_arrays(self):
        self.assertEqual(fill({"a": [1, 2], "b": {"c": 1, "d": 2}}, {"a": [9], "b": {"c": 5}}), {"a": [9], "b": {"c": 5, "d": 2}})


class Resolution(Scratch):
    def test_layer_order(self):
        # theme ref → variant ref → pin patch → "*" patch → variant-slot patch
        state = {
            "pins": {"colors": {"patch": {"palette": {"ok": "#00ff00", "warn": "#111111"}}}},
            "customizations": {
                "cozy": {
                    "*": {"colors": {"patch": {"palette": {"warn": "#222222"}}}},
                    "paper": {"colors": {"patch": {"palette": {"accent2": "#333333"}}}},
                }
            },
        }
        res = self.resolve("cozy@paper", state)
        pal = res.facets["colors"]["palette"]
        self.assertEqual(pal["bg"], "#f4f1ea")  # the variant's ref replaced the theme's
        self.assertEqual((pal["ok"], pal["warn"], pal["accent2"]), ("#00ff00", "#222222", "#333333"))
        self.assertEqual(
            [ly["source"] for ly in res.sources["colors"]["layers"]],
            ["theme:cozy", "variant:cozy@paper", "pins", "customizations.cozy.*", "customizations.cozy.paper"],
        )
        self.assertEqual(res.sources["colors"]["ref"], "colors:user/paper")
        self.assertTrue(res.sources["colors"]["customized"])
        self.assertEqual(res.errors, [])

    def test_ref_replaces_patch_merges(self):
        state = {
            "pins": {"material": {"patch": {"glass": {"opacity": 0.35}}}},
            "customizations": {"cozy": {"*": {"material": {"ref": "material:frost", "patch": {"blur": {"noise": 0.1}}}}}},
        }
        m = self.resolve("cozy", state).facets["material"]
        self.assertEqual(m["glass"]["opacity"], 0.2)  # frost's: the pin's patch below the ref is gone
        self.assertEqual(m["blur"]["noise"], 0.1)
        self.assertEqual(m["blur"]["saturation"], 1.6)  # filled from defaults/material.json
        # Without the ref, the pin's patch merges into the theme's facet.
        m = self.resolve("cozy", {"pins": state["pins"]}).facets["material"]
        self.assertEqual(m["glass"]["opacity"], 0.35)
        self.assertEqual(m["glass"]["borderOpacity"], 0.14)
        # null deletes a key, and fill brings the default back.
        m = self.resolve("cozy", {"customizations": {"cozy": {"*": {"material": {"patch": {"glass": {"border": None}}}}}}}).facets["material"]
        self.assertEqual(m["glass"]["border"], "#ffffff")

    def test_variant_extends_chain(self):
        res = self.resolve("cozy@calm")
        self.assertEqual(res.facets["colors"]["palette"]["bg"], "#f4f1ea")  # from paper
        self.assertEqual(res.facets["motion"]["speed"], 0.5)
        res = self.resolve("cozy@loop-a")  # a cycle: reported, the theme alone resolves
        self.assertTrue(any("cycle" in e for e in res.errors))
        self.assertEqual(res.facets["colors"]["palette"]["accent"], "#ff0088")

    def test_storage_rule(self):
        cozy, _ = self.cat.theme("cozy")
        # Variants that change colors only: a material tweak is shared ("*"),
        # a palette tweak stays on its side.
        self.assertEqual(R.customization_slot(cozy, "paper", "material"), "*")
        self.assertEqual(R.customization_slot(cozy, "paper", "colors"), "paper")
        self.assertEqual(R.customization_slot(cozy, "calm", "colors"), "calm")  # an ancestor replaces it
        self.assertEqual(R.customization_slot(cozy, "calm", "motion"), "calm")
        self.assertEqual(R.customization_slot(cozy, None, "colors"), "night")  # the base: Paper replaces colors
        self.assertEqual(R.customization_slot(cozy, None, "material"), "*")
        loft, _ = self.cat.theme("loft")
        self.assertEqual(R.customization_slot(loft, "light", "material"), "*")  # Light only patches the material
        self.assertEqual(R.customization_slot(loft, "light", "colors"), "light")
        # Written through set_selection, a Night palette tweak doesn't reach Paper.
        state = A.empty()
        A.set_selection(state, cozy, None, "colors", {"patch": {"palette": {"accent": "#abcdef"}}})
        A.set_selection(state, cozy, None, "material", {"patch": {"glass": {"opacity": 0.3}}})
        self.assertEqual(set(state["customizations"]["cozy"]), {"night", "*"})
        self.assertEqual(self.resolve("cozy", state).facets["colors"]["palette"]["accent"], "#abcdef")
        paper = self.resolve("cozy@paper", state)
        self.assertEqual(paper.facets["colors"]["palette"]["accent"], PAL["accent"])
        self.assertEqual(paper.facets["material"]["glass"]["opacity"], 0.3)

    def test_polar_and_color_refs(self):
        dark = self.resolve("loft").facets["material"]["glass"]
        light = self.resolve("loft@light").facets["material"]["glass"]
        self.assertEqual((dark["opacity"], dark["tint"]), (0.45, "#1a1b26"))  # @bg
        self.assertEqual((light["opacity"], light["tint"]), (0.5, "#ffffff"))  # Light's patch
        # liquid-glass's own light tint is @mix(bg,#ffffff,0.5).
        t, _ = self.cat.theme("cozy")
        res = R.resolve(self.cat, t, "paper")
        self.assertEqual(res.facets["material"]["glass"]["tint"], color.mix("#f4f1ea", "#ffffff", 0.5))
        # @mix / @alpha and a partial polar object (the other side comes from the default).
        state = {
            "customizations": {
                "cozy": {
                    "*": {
                        "material": {"ref": "material:frost", "patch": {"glass": {"specular": {"dark": 0.9}}}},
                        "shape": {"patch": {"shadow": {"color": "@alpha(accent,0.5)"}}},
                    }
                }
            }
        }
        res = self.resolve("cozy", state)
        g = res.facets["material"]["glass"]
        self.assertEqual(g["tint"], color.mix("#ff0088", PAL["bg"], 0.5))
        self.assertEqual(res.facets["shape"]["shadow"]["color"], "#ff008880")
        # An alpha color where the schema wants #rrggbb drops that layer.
        bad = {"customizations": {"cozy": {"*": {"material": {"patch": {"glass": {"tint": "@alpha(accent,0.5)"}}}}}}}
        self.assertIn("glass/tint", "\n".join(self.resolve("cozy", bad).errors))
        self.assertEqual(g["specular"], 0.9)
        g = self.resolve("cozy@paper", state).facets["material"]["glass"]
        self.assertEqual(g["specular"], 0.75)
        self.assertEqual(refs.color_ref("@mix(bg, #ffffff, 0.5)", PAL), color.mix(PAL["bg"], "#ffffff", 0.5))
        with self.assertRaises(refs.RefError):
            refs.color_ref("@nope", PAL)

    def test_accessibility_clamps(self):
        a11y = {"accessibility": {"reduceTransparency": True, "reduceMotion": True, "increaseContrast": True}}
        res = self.resolve("cozy@paper", a11y)
        m = res.facets["material"]
        self.assertFalse(m["blur"]["enabled"])
        self.assertEqual((m["glass"]["opacity"], m["terminals"]["opacity"]), (1.0, 1.0))
        self.assertTrue(m["menuBar"]["background"])
        self.assertTrue(res.facets["motion"]["minimal"])
        pal = res.facets["colors"]["palette"]
        for role in ("text", "subtext"):
            self.assertGreaterEqual(color.contrast(pal[role], pal["bg"]), 7.0)
        self.assertEqual((m["glass"]["border"], m["glass"]["borderOpacity"]), (pal["overlay"], 1.0))
        # Clamps also beat a customization that asks for glass.
        st = dict(a11y, customizations={"cozy": {"*": {"material": {"patch": {"glass": {"opacity": 0.1}}}}}})
        self.assertEqual(self.resolve("cozy", st).facets["material"]["glass"]["opacity"], 1.0)

    def test_bad_layers_dropped(self):
        state = {
            "pins": {"motion": "motion:does-not-exist", "shape": {"bogus": 1}},
            "customizations": {
                "cozy": {
                    "*": {
                        "material": {"patch": {"glass": {"opacity": 1.4}}},
                        "colors": {"patch": {"palette": {"accent": "red"}}},
                        "launcher": {"patch": {"tint": "@nope"}},
                    },
                    "night": {"typography": {"patch": {"ui": {"size": 12}}}},
                }
            },
        }
        res = self.resolve("cozy", state)
        errs = "\n".join(res.errors)
        self.assertIn("customizations.cozy.*.material: glass/opacity: 1.4 > 1", errs)
        self.assertIn("customizations.cozy.*.colors: palette/accent", errs)
        self.assertIn("pins.motion: no facet motion:does-not-exist", errs)
        self.assertIn("pins.shape: bad selection", errs)
        self.assertIn("customizations.cozy.*.launcher", errs)
        # The rest still resolves: the bad layers are simply not there.
        self.assertEqual(res.facets["material"]["glass"]["opacity"], 0.45)
        self.assertEqual(res.facets["colors"]["palette"]["accent"], "#ff0088")
        self.assertEqual(res.facets["typography"]["ui"]["size"], 12)
        self.assertEqual([ly["source"] for ly in res.sources["material"]["layers"]], ["theme:cozy"])

    def test_aliases_and_v1_adapter(self):
        for ref, want in (("tokyonight", ("loft", None)), ("latte", ("loft", "light")), ("default", ("loft", None)), ("loft@dark", ("loft", None))):
            t, v = self.cat.theme(ref)
            self.assertEqual((t.id, v), want, ref)
        self.assertEqual(self.resolve("latte").name, "latte")
        self.assertEqual(self.resolve("loft").name, "tokyonight")
        self.assertEqual(self.resolve("cozy@paper").name, "cozy@paper")
        res = self.resolve("cozytile-sakura")
        self.assertEqual(res.sources["colors"]["ref"], "colors:cozytile-sakura/cozytile-sakura")
        self.assertEqual(res.sources["lock"]["ref"], "lock:cozytile-sakura/sakura")
        self.assertEqual(res.sources["motion"]["ref"], None)  # not in a v1 pack: the default
        self.assertEqual(res.facets["material"]["glass"]["opacity"], 0.48)
        self.assertEqual(res.facets["lock"]["format"], "qylock")
        self.assertTrue(res.facets["wallpapers"]["default"].endswith("greeter/Background.jpg"))
        # An unqualified ref finds the only pack that has it; built-ins win over packs.
        self.assertEqual(self.cat.facet("colors:qylock-genshin").pack, "qylock-genshin")
        self.assertEqual(self.cat.facet("motion:snappy").id, "motion:loft/snappy")
        with self.assertRaises(FacetError):
            self.cat.theme("cozy@nope")

    def test_user_layer_file(self):
        state_dir = self.tmp / "state"
        state_dir.mkdir()
        (state_dir / "appearance.json").write_text(json.dumps({"version": 1, "theme": 3, "mode": "sideways", "pins": {"bogus": {}, "motion": "motion:calm"}}))
        st = A.load(state_dir)
        self.assertEqual((st["theme"], st["mode"], st["pins"]), (None, None, {"motion": "motion:calm"}))
        A.save(state_dir, dict(st, customizations={"x": {"*": {}}}))
        self.assertEqual(A.load(state_dir)["customizations"], {})
        (state_dir / "appearance.json").write_text("{not json")
        self.assertEqual(A.load(state_dir), A.empty())


class Saving(Scratch):
    """resolve(save-as(X)) == resolve(X); save-variant keeps only the diff."""

    STATE = {
        "pins": {"typography": "typography:serif", "shape": {"patch": {"radius": {"window": 10}}}},
        "customizations": {
            "cozy": {
                "*": {"motion": "motion:snappy", "material": {"patch": {"glass": {"opacity": 0.3}}}},
                "paper": {"colors": {"patch": {"palette": {"accent": "#00aa88"}}}},
            }
        },
    }

    def state(self) -> dict:
        return json.loads(json.dumps(dict(A.empty(), **self.STATE)))

    def reload(self) -> None:
        self.cat = Catalog([V1], builtin=BUILTIN, user=self.lib)

    def test_save_as_round_trip(self):
        for with_pins in (False, True):
            state = self.state()
            before = self.resolve("cozy@paper", state)
            t, v = self.cat.theme("cozy@paper")
            r = A.save_as(self.cat, state, t, v, f"mine{int(with_pins)}", "Mine", self.lib, with_pins=with_pins, with_variants=True)
            doc = json.loads(Path(r["file"]).read_text())
            self.assertEqual(doc["basedOn"], "cozy@paper")
            # References plus small patches, qualified; never copied data.
            self.assertEqual(doc["facets"]["colors"], {"ref": "colors:user/paper", "patch": {"palette": {"accent": "#00aa88"}}})
            self.assertEqual(doc["facets"]["motion"], "motion:loft/snappy")
            self.assertEqual(doc["facets"]["material"], {"ref": "material:loft/liquid-glass", "patch": {"glass": {"opacity": 0.3}}})
            self.assertEqual("typography" in doc["facets"], with_pins)
            self.assertEqual([v["id"] for v in doc["variants"]], ["paper", "calm", "loop-a", "loop-b"])
            self.assertEqual((state["theme"], state["variant"]), (f"mine{int(with_pins)}", None))
            self.reload()
            after = self.resolve(f"mine{int(with_pins)}", state)
            self.assertEqual(after.facets, before.facets)
            self.assertEqual(after.customized, [])
            self.assertTrue(schema.check_doc("theme-2.json", doc) == [], schema.check_doc("theme-2.json", doc))

    def test_save_variant_round_trip(self):
        state = self.state()
        before = self.resolve("cozy@paper", state)
        t, v = self.cat.theme("cozy@paper")
        r = A.save_variant(self.cat, state, t, v, "Mint Paper", self.lib)
        self.assertEqual(r["variant"]["id"], "mint-paper")
        self.assertEqual(r["variant"]["extends"], "paper")
        self.assertEqual(set(r["variant"]["facets"]), {"motion", "material", "colors"})  # only the diff, no pins
        self.assertNotIn("cozy", {k for k, v in state["customizations"].items() if v})
        self.assertEqual((state["theme"], state["variant"]), ("cozy", "mint-paper"))
        self.reload()
        after = self.resolve("cozy@mint-paper", state)
        self.assertEqual(after.facets, before.facets)
        self.assertEqual(after.customized, [])
        # A read-only theme gets an extension file instead, marked yours.
        state = self.state()
        state["customizations"]["loft"] = {"*": {"motion": "motion:calm"}}
        t, v = self.cat.theme("loft@light")
        A.save_variant(self.cat, state, t, v, "Calm", self.lib)
        self.reload()
        loft, _ = self.cat.theme("loft")
        self.assertEqual([v for v in loft.variants() if v.get("user")][0]["id"], "calm")
        self.assertTrue((self.lib / "Themes" / "loft.variants.json").is_file())
        self.assertEqual(self.resolve("loft@calm", state).facets["motion"]["speed"], 0.8)

    def test_save_facet(self):
        state = self.state()
        t, v = self.cat.theme("cozy@paper")
        before = self.resolve("cozy@paper", state)
        r = A.save_facet(self.cat, state, t, v, "material", "my-glass", "My glass", self.lib)
        self.assertEqual(r["ref"], "material:user/my-glass")
        self.assertEqual(state["customizations"]["cozy"]["*"]["material"], "material:user/my-glass")
        self.reload()
        self.assertEqual(self.resolve("cozy@paper", state).facets["material"], before.facets["material"])


class Schemas(unittest.TestCase):
    def test_builtin_pack_documents(self):
        self.assertEqual(schema.check_doc("pack-2.json", json.loads((BUILTIN / "loft" / "pack.json").read_text())), [])
        for p in sorted((BUILTIN / "loft" / "facets").rglob("*.json")):
            self.assertEqual(schema.check_doc("facet-1.json", json.loads(p.read_text())), [], p)
        for p in sorted((BUILTIN / "loft" / "themes").glob("*.json")):
            self.assertEqual(schema.check_doc("theme-2.json", json.loads(p.read_text())), [], p)
        cat = Catalog([], builtin=BUILTIN)
        self.assertEqual(cat.errors, [])
        for f in [f for k in ("material", "motion", "icons", "lock", "launcher", "sounds") for f in cat.facets(k)]:
            _, _, _, errs = R.resolve_kind(cat, f.kind, [("t", f.id, None, "theme")], "dark", PAL)
            self.assertEqual(errs, [], f.id)

    def test_unknown_keyword_refused(self):
        with self.assertRaises(ValueError):
            schema.errors(1, {"multipleOf": 2})


class Env(unittest.TestCase):
    """Scratch HOME / XDG / state / library; the v1 fixtures on the theme path."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "XDG_STATE_HOME": str(self.tmp / "xstate"),
                "LOFT_STATE_DIR": str(self.tmp / "state"),
                "LOFT_LIBRARY": str(self.tmp / "lib"),
                "LOFT_HOOKS": "none",
                "LOFT_THEME_INDEX": "none",
                "LOFT_THEME_PATH": f"{V1}:{ROOT / 'themes'}",
            }
        )
        for k in ("LOFT_DATA_DIR", "LOFT_THEME_ENGINE"):
            os.environ.pop(k, None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)


class GoldenGate(Env):
    """`loft theme render loft@dark` = today's tokyonight render, byte for
    byte (likewise latte), and v1 packs through the adapter = their v1 render."""

    def test_builtins_match_goldens(self):
        for ref, golden in (("loft@dark", "tokyonight"), ("loft", "tokyonight"), ("loft@light", "latte"), ("tokyonight", "tokyonight"), ("latte", "latte")):
            out = self.tmp / "out" / ref
            rc, _, err = loft("theme", "render", ref, str(out))
            self.assertEqual(rc, 0, err)
            self.assertEqual(same_tree(GOLDEN / golden, out), [], ref)

    def test_v1_packs_through_the_adapter(self):
        """Every byte the v1 renderer (frozen in tests/v1_reference.py) wrote
        is still written through the adapter + render units, apart from the
        documented additions."""
        for path in (V1 / "cozytile-sakura", V1 / "qylock-genshin", GLASSLESS, ROOT / "themes" / "tokyonight", ROOT / "themes" / "latte"):
            pack = Pack(path)
            v1 = self.tmp / "v1" / pack.name
            v1_reference.render(pack, v1)
            for ref in (pack.name, str(path)):
                if ref == pack.name and path.parent != V1:
                    continue  # not on the theme path by name (tokyonight is the loft alias: test above)
                out = self.tmp / "v2" / pack.name / ref.replace("/", "_")
                rc, _, err = loft("theme", "render", ref, str(out))
                self.assertEqual(rc, 0, err)
                stripped = without_additions(out, self.tmp / "v2-stripped" / pack.name / ref.replace("/", "_"))
                self.assertEqual(same_tree(v1, stripped), [], ref)

    def test_goldens_are_v1_plus_additions(self):
        for name in ("tokyonight", "latte"):
            v1 = self.tmp / "v1" / name
            v1_reference.render(Pack(ROOT / "themes" / name), v1)
            self.assertEqual(same_tree(v1, without_additions(GOLDEN / name, self.tmp / "g" / name)), [], name)

    def test_apply_keeps_v1_names_and_cache(self):
        rc, out, err = loft("theme", "apply", "default")
        self.assertEqual((rc, out.strip()), (0, "loft: applied tokyonight"), err)
        cur = self.tmp / "state" / "current"
        self.assertEqual(cur.resolve().parent, (self.tmp / "state" / "rendered" / "compositions").resolve())
        self.assertEqual(same_tree(GOLDEN / "tokyonight", cur.resolve(), ignore=("resolved.json",)), [])
        first = cur.resolve()
        loft("theme", "apply", "loft@dark")
        self.assertEqual(cur.resolve(), first)  # same resolved look → same cached render
        rc, _, err = loft("theme", "apply", "cozytile-sakura")
        self.assertEqual(rc, 0, err)
        self.assertEqual(loft("theme", "current")[1].strip(), "cozytile-sakura")

    def test_legacy_engine_switch(self):
        os.environ["LOFT_THEME_ENGINE"] = "v1"
        rc, _, err = loft("theme", "apply", "tokyonight")
        self.assertEqual(rc, 0, err)
        self.assertFalse((self.tmp / "state" / "appearance.json").exists())
        rc, _, err = loft("theme", "apply", "loft@dark")  # v2 names need the facet engine
        self.assertEqual(rc, 1)


class Commands(Env):
    """`loft theme …` / `loft <kind> …` against scratch state."""

    def state(self) -> dict:
        rc, out, err = loft("theme", "state")
        self.assertEqual(rc, 0, err)
        return json.loads(out)

    def test_customize_diff_reset(self):
        loft("theme", "apply", "latte")
        rc, out, err = loft("material", "set", "glass.opacity", "0.35")
        self.assertEqual(rc, 0, err)
        self.assertIn("customizations.loft.*", out)
        self.assertIn('"opacity": 0.35', (self.tmp / "state" / "current" / "theme.json").read_text())
        rc, _, err = loft("material", "set", "glass.opacity", "1.4")
        self.assertEqual(rc, 1)
        self.assertIn("1.4 > 1", err)
        loft("colors", "set", "palette.accent", '"#ff0000"')
        loft("motion", "apply", "motion:snappy")
        st = self.state()
        self.assertEqual((st["theme"], st["variant"], st["name"]), ("loft", "light", "latte"))
        self.assertEqual(st["customized"], ["colors", "material", "motion"])
        self.assertEqual(st["facets"]["colors"]["palette"]["accent"], "#ff0000")
        rc, out, _ = loft("theme", "diff", "--json")
        d = json.loads(out)
        self.assertEqual(sorted(d["kinds"]), ["colors", "material", "motion"])
        self.assertEqual(d["kinds"]["material"]["changes"], [{"path": "glass.opacity", "before": 0.5, "after": 0.35}])
        # Dark doesn't get Light's palette tweak; it does share the glass.
        loft("theme", "apply", "--mode", "dark")
        st = self.state()
        self.assertEqual((st["ref"], st["mode"]), ("loft", "dark"))
        self.assertEqual(st["facets"]["colors"]["palette"]["accent"], "#7aa2f7")
        self.assertEqual(st["facets"]["material"]["glass"]["opacity"], 0.35)
        loft("theme", "reset", "material")
        self.assertEqual(self.state()["facets"]["material"]["glass"]["opacity"], 0.45)
        loft("theme", "apply", "latte")
        loft("theme", "reset", "--all")
        self.assertEqual(self.state()["customized"], [])
        self.assertEqual(same_tree(GOLDEN / "latte", (self.tmp / "state" / "current").resolve(), ignore=("resolved.json",)), [])

    def test_pins_and_accessibility(self):
        loft("theme", "apply", "cozytile-sakura")
        loft("material", "set", "glass.opacity", "0.3", "--pin")
        self.assertEqual(self.state()["pinned"], ["material"])
        loft("theme", "apply", "tokyonight")
        self.assertEqual(self.state()["facets"]["material"]["glass"]["opacity"], 0.3)
        rc, out, _ = loft("theme", "accessibility", "--reduce-transparency", "on")
        self.assertEqual(rc, 0)
        st = self.state()
        self.assertFalse(st["facets"]["material"]["blur"]["enabled"])
        self.assertIn("\n    off\n", (self.tmp / "state" / "current" / "niri.kdl").read_text())
        loft("theme", "accessibility", "--reduce-transparency", "off")
        loft("material", "reset", "--pin")
        self.assertEqual(self.state()["pinned"], [])

    def test_save_commands(self):
        loft("theme", "apply", "latte")
        loft("motion", "apply", "motion:calm")
        rc, out, err = loft("theme", "save-variant", "Calm Latte")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("note:", out)
        st = self.state()
        self.assertEqual((st["ref"], st["customized"]), ("loft@calm-latte", []))
        self.assertEqual(st["facets"]["motion"]["speed"], 0.8)
        rc, out, _ = loft("theme", "variants", "loft", "--json")
        self.assertIn({"id": "calm-latte", "name": "Calm Latte", "user": True, "extends": "light"}, json.loads(out))
        loft("colors", "set", "palette.accent", '"#00ff00"')
        rc, out, err = loft("theme", "save-as", "green", "--name", "Green")
        self.assertEqual(rc, 0, err)
        st = self.state()
        self.assertEqual((st["ref"], st["name"]), ("green", "green"))
        self.assertEqual(st["facets"]["colors"]["palette"]["accent"], "#00ff00")
        self.assertEqual(st["facets"]["motion"]["speed"], 0.8)
        rc, out, _ = loft("theme", "list", "--themes", "--json")
        self.assertIn("green", [t["id"] for t in json.loads(out)])
        rc, out, err = loft("material", "save-as", "my-glass")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.state()["sources"]["material"]["ref"], "material:user/my-glass")
        rc, out, _ = loft("material", "list", "--json")
        self.assertIn("material:user/my-glass", [r["id"] for r in json.loads(out) if r["active"]])

    def test_old_list_and_render_paths_unchanged(self):
        rc, out, _ = loft("theme", "list")
        self.assertEqual(out.split(), ["cozytile-sakura", "latte", "qylock-genshin", "tokyonight"])
        rc, out, _ = loft("theme", "list", "--json")
        self.assertEqual([t["name"] for t in json.loads(out)], ["cozytile-sakura", "latte", "qylock-genshin", "tokyonight"])


if __name__ == "__main__":
    unittest.main()
