"""The login screen following the lock screen (cli/loft/greeter.py) and its
privileged helper (cli/loft/greeter_helper.py), against scratch dirs: the
helper runs unprivileged with --root, the CLI reaches it through
LOFT_GREETER_HELPER instead of pkexec."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

from loft import greeter, greeter_helper
from loft.cli import main

HELPER = Path(greeter_helper.__file__)


def tar_of(entries: list[tuple[str, bytes | None, bytes]]) -> io.BytesIO:
    """(name, data or None for a dir, type) → an in-memory tar."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data, typ in entries:
            ti = tarfile.TarInfo(name)
            ti.type = typ
            if typ == tarfile.SYMTYPE:
                ti.linkname = "/etc/shadow"
            if data is not None:
                ti.size = len(data)
            t.addfile(ti, io.BytesIO(data) if data is not None else None)
    buf.seek(0)
    return buf


GOOD = [
    ("theme.json", b'{"palette": {"bg": "#000000"}}', tarfile.REGTYPE),
    ("greeter.json", b'{"name": "x", "main": "lock/Main.qml", "wallpaper": ""}', tarfile.REGTYPE),
    ("lock", None, tarfile.DIRTYPE),
    ("lock/Main.qml", b"import QtQuick\nItem {}\n", tarfile.REGTYPE),
]


def helper(root: Path, *argv: str, stdin=None) -> tuple[int, str]:
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        rc = greeter_helper.main(["--root", str(root), *argv], stdin=stdin)
    return rc, err.getvalue()


class Helper(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_install_and_reset(self):
        rc, err = helper(self.root, "install", "wuwa", stdin=tar_of(GOOD))
        self.assertEqual(rc, 0, err)
        link = self.root / "greeter"
        self.assertTrue(link.is_symlink())
        self.assertFalse(os.readlink(link).startswith("/"))  # relative: survives a moved root
        self.assertEqual((link / "lock" / "Main.qml").stat().st_mode & 0o777, 0o644)
        self.assertEqual((link / "lock").stat().st_mode & 0o777, 0o755)
        first = link.resolve()
        rc, err = helper(self.root, "install", "wuwa", stdin=tar_of(GOOD))
        self.assertEqual(rc, 0, err)
        self.assertNotEqual(link.resolve(), first)
        self.assertEqual(len(list((self.root / "themes").iterdir())), 1)  # the old copy is gone
        rc, err = helper(self.root, "reset")
        self.assertEqual(rc, 0, err)
        self.assertFalse(link.exists() or link.is_symlink())
        self.assertEqual(list((self.root / "themes").iterdir()), [])

    def refused(self, entries, name="x", why=""):
        before = os.readlink(self.root / "greeter") if (self.root / "greeter").is_symlink() else None
        rc, err = helper(self.root, "install", name, stdin=tar_of(entries))
        self.assertEqual(rc, 1, err)
        self.assertIn(why, err)
        after = os.readlink(self.root / "greeter") if (self.root / "greeter").is_symlink() else None
        self.assertEqual(before, after)  # a refused install never touches the live one
        self.assertEqual([p for p in (self.root / "themes").iterdir() if p.name != (after or "").split("/")[-1]], [])

    def test_refusals(self):
        helper(self.root, "install", "ok", stdin=tar_of(GOOD))
        self.refused(GOOD + [("lock/evil", None, tarfile.SYMTYPE)], why="only regular files")
        self.refused(GOOD + [("lock/dev", None, tarfile.CHRTYPE)], why="only regular files")
        self.refused(GOOD + [("../escape", b"x", tarfile.REGTYPE)], why="bad path")
        self.refused(GOOD + [("/etc/passwd", b"x", tarfile.REGTYPE)], why="bad path")
        self.refused(GOOD + [("bin/sh", b"x", tarfile.REGTYPE)], why="unexpected entry")
        self.refused(GOOD[1:], why="theme.json and greeter.json are required")
        self.refused(GOOD, name="../x", why="bad name")
        bad_main = [GOOD[0], ("greeter.json", b'{"main": "theme.json"}', tarfile.REGTYPE)]
        self.refused(bad_main, why="main")
        old = greeter_helper.DEFAULT_MAX_BYTES
        greeter_helper.DEFAULT_MAX_BYTES = 10
        try:
            self.refused(GOOD, why="larger than")
        finally:
            greeter_helper.DEFAULT_MAX_BYTES = old

    def test_root_flag_refused_as_root(self):
        if os.geteuid() != 0:
            self.skipTest("only meaningful as root")
        self.assertEqual(greeter_helper.main(["--root", str(self.root), "reset"]), 2)


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class Sync(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.root = self.tmp / "var-lib-loft"
        self.state = self.tmp / "state"
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "LOFT_STATE_DIR": str(self.state),
                "LOFT_HOOKS": "none",
                "LOFT_THEME_INDEX": "none",
                "LOFT_LIBRARY": "none",
                "LOFT_GREETER_CONFIG": str(self.tmp / "nope.json"),
                "LOFT_GREETER_DIR": str(self.root / "greeter"),
                "LOFT_GREETER_HELPER": f"{sys.executable} -B {HELPER} --root {self.root}",
            }
        )
        for k in ("LOFT_THEME_PATH", "LOFT_DATA_DIR"):
            os.environ.pop(k, None)
        rc, _, err = loft("theme", "apply", "loft")
        self.assertEqual(rc, 0, err)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def meta(self) -> dict:
        return json.loads((self.root / "greeter" / "greeter.json").read_text())

    def test_sync_status_reset(self):
        rc, out, err = loft("greeter", "sync")
        self.assertEqual(rc, 0, err)
        m = self.meta()
        self.assertEqual(m["format"], "builtin")
        self.assertEqual(m["main"], "")
        self.assertEqual(
            json.loads((self.root / "greeter" / "theme.json").read_text()),
            json.loads((self.state / "current" / "theme.json").read_text()),
        )
        rc, out, _ = loft("greeter", "status", "--json")
        s = json.loads(out)
        self.assertFalse(s["enabled"])  # no /etc marker in this test
        self.assertEqual(s["installed"]["key"], m["key"])
        rc, _, err = loft("greeter", "reset")
        self.assertEqual(rc, 0, err)
        self.assertFalse((self.root / "greeter").exists())

    def test_apply_greeter_flag(self):
        rc, out, err = loft("theme", "apply", "--greeter")
        self.assertEqual(rc, 0, err)
        self.assertIn("login screen", out)
        self.assertTrue((self.root / "greeter" / "greeter.json").is_file())

    def test_pack_design(self):
        """A qylock-style design: its dir becomes lock/, `config` lands in theme.conf."""
        d = self.tmp / "pack" / "lock" / "qylock"
        (d / "font").mkdir(parents=True)
        (d / "Main.qml").write_text("import QtQuick\nItem {}\n")
        (d / "theme.conf").write_text("[General]\nbackground=bg.mp4\ntype=video\n")
        (d / "font" / "a.ttf").write_bytes(b"\0")
        os.symlink("/etc/hostname", d / "outside")  # never follows a link out of the design
        p = object.__new__(greeter.Plan)
        p.design = {"format": "qylock", "path": str(d), "config": {"type": "image", "accent": "#fff"}}
        p.source, p.label, p.format = "lock:x/y", "Y", "qylock"
        p.lock_dir, p.main = d.resolve(), "lock/Main.qml"
        p.theme_json = self.state / "current" / "theme.json"
        p.wallpaper, p.name = None, "x-y"
        files = dict(p.files())
        self.assertEqual(sorted(files), ["greeter.json", "lock/Main.qml", "lock/font/a.ttf", "lock/theme.conf", "theme.json"])
        conf = files["lock/theme.conf"].decode()
        self.assertIn("type=image\n", conf)
        self.assertIn("background=bg.mp4\n", conf)
        self.assertIn("accent=#fff\n", conf)
        buf = io.BytesIO()
        p.write_tar(buf)
        buf.seek(0)
        rc, err = helper(self.root, "install", p.name, stdin=buf)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.meta()["main"], "lock/Main.qml")
        self.assertTrue((self.root / "greeter" / "lock" / "font" / "a.ttf").is_file())

    def test_follow(self):
        """With the machine's marker and the `greeter` hook, an apply re-syncs
        in the background; with the same look again, it doesn't."""
        (self.tmp / "greeter.json").write_text(json.dumps({"helper": "unused", "followLock": True}))
        os.environ["LOFT_GREETER_CONFIG"] = str(self.tmp / "greeter.json")
        os.environ["LOFT_HOOKS"] = "greeter"
        rc, _, err = loft("material", "set", "glass.opacity", "0.31")
        self.assertEqual(rc, 0, err)
        f = self.root / "greeter" / "greeter.json"
        for _ in range(100):
            if f.is_file():
                break
            time.sleep(0.1)
        self.assertTrue(f.is_file(), (self.state / "greeter-sync.log").read_text() if (self.state / "greeter-sync.log").exists() else "")
        rc, _, err = loft("greeter", "follow", "off")
        self.assertEqual(rc, 0, err)
        rc, out, _ = loft("greeter", "status", "--json")
        self.assertFalse(json.loads(out)["follow"])


if __name__ == "__main__":
    unittest.main()
