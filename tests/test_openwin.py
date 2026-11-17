"""`loft open` (cli/loft/openwin.py) and the `open` MCP tool, against a fake loft-kwin."""

from __future__ import annotations

import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

from loft import mcp, mcptools, openwin

STATE = {
    "windows": [],
    "workspaces": [
        {"id": 1, "idx": 1, "name": None, "output": "WL-0", "kwin_desktop": "d1"},
        {"id": 2, "idx": 2, "name": "Two", "output": "WL-0", "kwin_desktop": "d2"},
        {"id": 3, "idx": 1, "name": None, "output": "WL-1", "kwin_desktop": "d1"},
        {"id": 4, "idx": 2, "name": "Two", "output": "WL-1", "kwin_desktop": "d2"},
    ],
    "outputs": [{"name": "WL-0", "geometry": [0, 0, 1280, 800]}, {"name": "WL-1", "geometry": [1280, 0, 1280, 800]}],
    "activities": ["a-default", "a-coding"],
}

# Records argv; `expect` answers like loft-kwin (a role → WL-1, `left` fails).
FAKE = r"""#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
with open(os.environ["FAKE_KWIN_LOG"], "a") as f:
    f.write(json.dumps(a) + "\n")
if a == ["state"]:
    if os.environ.get("FAKE_KWIN_DOWN"):
        sys.stderr.write("Error: dev.loft.KWinBridge isn't on the session bus\n")
        sys.exit(1)
    print(open(os.environ["FAKE_KWIN_DATA"]).read())
elif a[:1] == ["expect"]:
    r = json.loads(a[1])
    if r.get("output") == "left":
        sys.stderr.write("Error: no display is `left` now (displays: WL-0: main, WL-1: right)\n")
        sys.exit(1)
    if r.get("activityName") and r["activityName"].lower() not in ("default", "coding"):
        sys.stderr.write('Error: no KDE Activity named "%s" (Activities: Coding, Default)\n' % r["activityName"])
        sys.exit(1)
    print(json.dumps({"id": r["id"], "pid": r["pid"], "output": {"right": "WL-1", "main": "WL-0"}.get(r.get("output"), r.get("output"))}))
else:
    sys.exit(2)
"""


def call(server, name, args):
    rx = io.StringIO(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}) + "\n")
    tx = io.StringIO()
    server.serve(rx, tx)
    return json.loads(tx.getvalue().splitlines()[0])


@contextmanager
def _env(env: dict):
    old = dict(os.environ)
    os.environ.clear()
    os.environ.update(env)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(old)


class Pure(unittest.TestCase):
    def test_request_for_the_users_ask(self):
        r = openwin.request({"command": ["konsole"], "activity": "Coding", "desktop": "2", "monitor": "right", "size": "1200x800"}, 4242)
        self.assertEqual(r["pid"], 4242)
        self.assertEqual(r["activityName"], "Coding")
        self.assertEqual(r["desktop"], 2)
        self.assertEqual(r["output"], "right")
        self.assertEqual(r["size"], {"w": {"px": 1200}, "h": {"px": 800}})
        self.assertFalse(r["follow"])
        self.assertEqual((r["appId"], r["appIdFlags"]), ("(^|\\.)konsole$", "i"))
        self.assertEqual((r["ttl"], r["count"]), (30000, 0))
        r = openwin.request({"command": ["/usr/bin/ghostty"], "fullscreen": True, "follow": True, "desktop": "Two", "app_id": "^x$"}, 7)
        self.assertEqual((r["open"], r["follow"], r["desktop"], r["appId"], r["appIdFlags"]), ("fullscreen", True, "Two", "^x$", ""))

    def test_sizes_and_positions(self):
        self.assertEqual(openwin.parse_size("60%x80%"), {"w": {"share": 0.6}, "h": {"share": 0.8}})
        for bad in ("12x", "0x10", "120%x10", "axb"):
            with self.assertRaises(openwin.OpenError):
                openwin.parse_size(bad)
        self.assertEqual(openwin.parse_position("10, -20"), [10, -20])
        self.assertEqual(openwin.parse_position("left"), "left")
        with self.assertRaises(openwin.OpenError):
            openwin.parse_position("middle")
        with self.assertRaises(openwin.OpenError):
            openwin.check_options({"command": ["x"], "fullscreen": True, "size": "10x10"})
        with self.assertRaises(openwin.OpenError):
            openwin.check_options({"command": []})

    def test_niri_actions(self):
        self.assertEqual(
            openwin.niri_actions({"desktop": 2, "size": "50%x900", "follow": True}, 9, "DP-2"),
            [
                ["move-window-to-monitor", "--id", "9", "DP-2"],
                ["move-window-to-workspace", "--window-id", "9", "--focus", "false", "2"],
                ["set-window-width", "--id", "9", "50%"],
                ["set-window-height", "--id", "9", "900"],
                ["focus-window", "--id", "9"],
            ],
        )
        self.assertEqual(openwin.niri_actions({"fullscreen": True}, 3, None), [["fullscreen-window", "--id", "3"]])

    def test_targets_are_checked(self):
        openwin.check_kwin_targets({"activity": "coding", "desktop": "2"}, STATE)
        openwin.check_kwin_targets({"activity": "a-coding", "desktop": "two"}, STATE)
        with self.assertRaisesRegex(openwin.OpenError, "no desktop 3 \\(KWin has 2\\)"):
            openwin.check_kwin_targets({"desktop": 3}, STATE)

    def test_descends(self):
        self.assertTrue(openwin.descends(os.getpid(), os.getppid()))
        self.assertFalse(openwin.descends(os.getppid(), os.getpid()))


class FakeKWin(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="loft-open-"))
        self.addCleanup(shutil.rmtree, self.dir)
        bin_ = self.dir / "bin"
        bin_.mkdir()
        (bin_ / "loft-kwin").write_text(FAKE.replace("/usr/bin/env python3", sys.executable))
        (bin_ / "loft-kwin").chmod(0o755)
        (self.dir / "state.json").write_text(json.dumps(STATE))
        self.log = self.dir / "log"
        self.log.touch()
        env = {k: v for k, v in os.environ.items() if k not in ("NIRI_SOCKET", "LOFT_COMPOSITOR", "LOFT_KWIN_BIN")}
        # LOFT_OPEN_NO_SCOPE: no systemd-run (and no user manager asked).
        env.update(PATH=f"{bin_}:{os.environ.get('PATH', '')}", XDG_CURRENT_DESKTOP="KDE", WAYLAND_DISPLAY="wayland-test",
                   FAKE_KWIN_LOG=str(self.log), FAKE_KWIN_DATA=str(self.dir / "state.json"), LOFT_OPEN_NO_SCOPE="1")
        ctx = _env(env)
        ctx.__enter__()
        self.addCleanup(ctx.__exit__, None, None, None)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_open(self):
        r = openwin.open_window({"command": ["true"], "activity": "Coding", "desktop": 2, "monitor": "right", "size": "1200x800"})
        self.assertEqual((r["backend"], r["output"], r["unit"]), ("kwin", "WL-1", ""))
        calls = self.calls()
        self.assertEqual(calls[0], ["state"])
        probe = json.loads(calls[1][1])
        self.assertTrue(probe["dryRun"])
        real = json.loads(calls[2][1])
        self.assertNotIn("dryRun", real)
        self.assertEqual(real["pid"], r["pid"])
        self.assertEqual((real["activityName"], real["desktop"], real["output"]), ("Coding", 2, "right"))
        self.assertIn("you stay here", openwin.describe(r))

    def test_nothing_starts_without_a_place(self):
        marker = self.dir / "started"
        cmd = ["sh", "-c", f"touch {marker}"]
        with self.assertRaisesRegex(openwin.OpenError, "no display is `left`"):
            openwin.open_window({"command": cmd, "monitor": "left"})
        with self.assertRaisesRegex(openwin.OpenError, 'no KDE Activity named "Nope".*Coding, Default'):
            openwin.open_window({"command": cmd, "activity": "Nope"})
        os.environ["FAKE_KWIN_DOWN"] = "1"
        with self.assertRaisesRegex(openwin.OpenError, "isn't running under KWin.*nothing was started"):
            openwin.open_window({"command": cmd})
        self.assertFalse(marker.exists())

    def test_mcp_tool(self):
        server = mcp.Server(mcptools.tools())
        r = call(server, "open", {"command": ["true"], "activity": "Coding", "desktop": 2, "monitor": "right", "placement": "fullscreen"})["result"]
        self.assertFalse(r["isError"], r["content"][0]["text"])
        out = json.loads(r["content"][0]["text"])
        self.assertEqual((out["backend"], out["output"]), ("kwin", "WL-1"))
        self.assertEqual(json.loads(self.calls()[-1][1])["open"], "fullscreen")
        r = call(server, "open", {"command": ["true"], "monitor": "left"})["result"]
        self.assertTrue(r["isError"])
        self.assertIn("no display is `left`", r["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
