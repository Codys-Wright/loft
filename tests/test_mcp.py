"""Unit tests for `loft mcp` (cli/loft/mcp.py, mcptools.py) that need no
desktop: JSON-RPC framing over a pipe, the schema validator, tool listing,
error results, the Quickshell IPC allowlist and `ipc show` parsing, and the
niri tools against a fake `niri` on PATH. The live part (a real session) is
tests/mcp_session.py, run by hand against a loft-dev session.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from loft import mcp, mcptools

CLI = Path(__file__).resolve().parents[1] / "cli" / "loft"

WINDOWS = [
    {"id": 2, "title": "foot", "app_id": "foot", "pid": 10, "workspace_id": 1, "is_focused": False, "is_floating": False, "is_urgent": False,
     "layout": {"pos_in_scrolling_layout": [1, 1], "tile_size": [782.0, 870.0], "window_size": [782, 870], "tile_pos_in_workspace_view": None, "window_offset_in_tile": [0.0, 0.0]}},
    {"id": 3, "title": "notes", "app_id": "dev.test.app", "pid": 11, "workspace_id": 1, "is_focused": True, "is_floating": True, "is_urgent": False,
     "layout": {"pos_in_scrolling_layout": None, "tile_size": [400.0, 300.0], "window_size": [400, 300], "tile_pos_in_workspace_view": [100.0, 50.0], "window_offset_in_tile": [0.0, 0.0]}},
]
WORKSPACES = [
    {"id": 1, "idx": 1, "name": "code", "output": "DP-1", "is_urgent": False, "is_active": True, "is_focused": True, "active_window_id": 3},
    {"id": 4, "idx": 2, "name": None, "output": "DP-1", "is_urgent": False, "is_active": False, "is_focused": False, "active_window_id": None},
]
OUTPUTS = {"DP-1": {"name": "DP-1", "make": "Dell", "model": "U2720Q", "serial": "ABC", "modes": [{"width": 3840, "height": 2160, "refresh_rate": 60000, "is_preferred": True}],
                    "current_mode": 0, "logical": {"x": 1000, "y": 0, "width": 1920, "height": 1080, "scale": 2.0, "transform": "Normal"}}}

FAKE_NIRI = r"""#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
with open(os.environ["FAKE_NIRI_LOG"], "a") as f:
    f.write(json.dumps(a) + "\n")
data = json.load(open(os.environ["FAKE_NIRI_DATA"]))
if a[:2] == ["msg", "--json"]:
    print(json.dumps(data[a[2]]))
elif a[:2] == ["msg", "action"]:
    pass
else:
    sys.exit(2)
"""


def rpc(server: mcp.Server, *msgs) -> list[dict]:
    rx = io.StringIO("".join(json.dumps(m) + "\n" for m in msgs))
    tx = io.StringIO()
    server.serve(rx, tx)
    return [json.loads(line) for line in tx.getvalue().splitlines()]


def call(server, name, args=None, mid=1):
    (resp,) = rpc(server, {"jsonrpc": "2.0", "id": mid, "method": "tools/call", "params": {"name": name, "arguments": args or {}}})
    return resp


class Protocol(unittest.TestCase):
    def setUp(self):
        self.server = mcp.Server(mcptools.tools(), mcptools.INSTRUCTIONS)

    def test_handshake_and_list(self):
        out = rpc(
            self.server,
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "ping"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/list"},
        )
        self.assertEqual([r["id"] for r in out], [1, 2, 3])  # no reply to the notification
        init = out[0]["result"]
        self.assertEqual(init["protocolVersion"], "2025-06-18")
        self.assertIn("tools", init["capabilities"])
        self.assertEqual(init["serverInfo"]["name"], "loft")
        self.assertEqual(out[1]["result"], {})
        names = [t["name"] for t in out[2]["result"]["tools"]]
        for want in ("list_windows", "screenshot_output", "shell_ipc_call", "loft_windows_rule", "loft_niri_set"):
            self.assertIn(want, names)
        self.assertEqual(len(names), len(set(names)))
        for t in out[2]["result"]["tools"]:
            self.assertEqual(t["inputSchema"]["type"], "object", t["name"])
            self.assertFalse(t["inputSchema"]["additionalProperties"], t["name"])
            self.assertTrue(t["description"] and "\n" not in t["description"], t["name"])
        self.assertTrue(self.server.initialized)

    def test_older_version_is_echoed_unknown_gets_ours(self):
        (r,) = rpc(self.server, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}})
        self.assertEqual(r["result"]["protocolVersion"], "2024-11-05")
        (r,) = rpc(self.server, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}})
        self.assertEqual(r["result"]["protocolVersion"], mcp.PROTOCOL_VERSION)

    def test_jsonrpc_errors(self):
        tx = io.StringIO()
        self.server.serve(io.StringIO('{"jsonrpc": "2.0", "id": 1, "method": \n[1,2]\n{"id": 5, "method": "ping"}\n'), tx)
        codes = [json.loads(line)["error"]["code"] for line in tx.getvalue().splitlines()]
        self.assertEqual(codes, [mcp.PARSE_ERROR, mcp.INVALID_REQUEST, mcp.INVALID_REQUEST])
        (r,) = rpc(self.server, {"jsonrpc": "2.0", "id": "x", "method": "resources/list"})
        self.assertEqual((r["id"], r["error"]["code"]), ("x", mcp.METHOD_NOT_FOUND))
        r = call(self.server, "power_off")
        self.assertEqual(r["error"]["code"], mcp.INVALID_PARAMS)

    def test_bad_arguments_are_tool_errors(self):
        for name, args, needle in [
            ("focus_window", {}, "missing required 'id'"),
            ("focus_window", {"id": "3"}, "expected integer"),
            ("focus_window", {"id": True}, "expected integer"),
            ("focus_window", {"id": 0}, "≥ 1"),
            ("focus_window", {"id": 3, "extra": 1}, "unknown field 'extra'"),
            ("set_column_width", {"id": 3, "proportion": 2}, "≤ 1"),
            ("launch", {"command": []}, "at least 1"),
            ("toggle_overview", {"state": "maybe"}, "one of"),
            ("shell_ipc_call", {"target": "lock", "function": "lock"}, "not allowed"),
            ("shell_ipc_call", {"target": "systemmenu", "function": "shutdown"}, "not allowed"),
            ("shell_ipc_call", {"target": "x;rm", "function": "f"}, "does not match"),
            ("loft_niri_set", {"key": "layout.gaps", "value": "8\nx"}, "does not match"),
        ]:
            r = call(self.server, name, args)["result"]
            self.assertTrue(r["isError"], (name, args))
            self.assertIn(needle, r["content"][0]["text"], (name, args))

    def test_missing_session_is_a_clear_error(self):
        env = {k: v for k, v in os.environ.items() if k not in ("NIRI_SOCKET", "WAYLAND_DISPLAY")}
        with _env(env):
            r = call(self.server, "list_windows")["result"]
        self.assertTrue(r["isError"])
        self.assertIn("NIRI_SOCKET is not set", r["content"][0]["text"])

    def test_results(self):
        r = mcp.tool_result({"a": 1})
        self.assertEqual(r["structuredContent"], {"a": 1})
        self.assertEqual(json.loads(r["content"][0]["text"]), {"a": 1})
        png = _png(4, 3)
        r = mcp.tool_result(mcp.Image(png, {"width": 4}))
        self.assertEqual(r["content"][0]["type"], "image")
        self.assertEqual(r["content"][0]["mimeType"], "image/png")
        self.assertEqual(mcptools.png_size(png), (4, 3))

    def test_stdio_subprocess(self):
        """The real entry point: stdout carries only protocol lines."""
        env = {k: v for k, v in os.environ.items() if k not in ("NIRI_SOCKET", "WAYLAND_DISPLAY")}
        msgs = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_outputs"}},
        ]
        p = subprocess.run([sys.executable, "-B", str(CLI), "mcp"], input="".join(json.dumps(m) + "\n" for m in msgs),
                           capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = [json.loads(line) for line in p.stdout.splitlines()]
        self.assertEqual([r["id"] for r in lines], [1, 2])
        self.assertTrue(lines[1]["result"]["isError"])
        self.assertIn("warning: NIRI_SOCKET is not set", p.stderr)
        self.assertIn("call list_outputs {} → error", p.stderr)


class Allowlist(unittest.TestCase):
    def test_nothing_destructive(self):
        for target in ("lock", "systemmenu", "quit", "phone", "action", "cleaning", "clipboard", "camera", "recorder", "pwclock", "audio", "mic", "capture"):
            self.assertNotIn(target, mcptools.SHELL_ALLOW)
        for target, fns in mcptools.SHELL_ALLOW.items():
            self.assertNotIn("enter", fns, target)
            banned = {"wipe", "deleteSet", "hardReload", "shutdown", "restart", "logout", "reset", "clear", "devUnlock"}
            if target == "timers":
                banned.discard("clear")  # clears finished timers only
            self.assertFalse(banned & fns, target)

    def test_allowlist_matches_the_shell(self):
        """Every allowed function exists in some IpcHandler in src/ (catches renames)."""
        src = Path(__file__).resolve().parents[1] / "src"
        if not src.is_dir():
            self.skipTest("no src/ in this tree")
        text = "\n".join(p.read_text(errors="replace") for p in src.rglob("*.qml") if "IpcHandler" in p.read_text(errors="replace"))
        for target, fns in mcptools.SHELL_ALLOW.items():
            self.assertIn(f'target: "{target}"', text, target)
            for fn in fns:
                self.assertRegex(text, rf"function {fn}\(", f"{target}.{fn}")

    def test_parse_ipc_show(self):
        shown = mcptools.parse_ipc_show(
            "target timers\n  function start(spec: string, label: string): void\n  function list(): string\n"
            "target motion\n  function scale(factor: real): void\n"
        )
        self.assertEqual(shown["timers"]["start"]["params"], [("spec", "string"), ("label", "string")])
        self.assertEqual(shown["timers"]["list"], {"params": [], "returns": "string"})
        self.assertEqual(shown["motion"]["scale"]["params"], [("factor", "real")])
        self.assertEqual(mcptools._ipc_arg(True, "bool", "x"), "true")
        self.assertEqual(mcptools._ipc_arg(0.5, "real", "x"), "0.5")
        with self.assertRaises(mcp.ToolError):
            mcptools._ipc_arg("abc", "int", "x")


class FakeNiri(unittest.TestCase):
    """The niri tools against a fake `niri msg` (records argv, serves fixtures)."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="loft-mcp-"))
        self.addCleanup(shutil.rmtree, self.dir)
        bin_ = self.dir / "bin"
        bin_.mkdir()
        (bin_ / "niri").write_text(FAKE_NIRI.replace("/usr/bin/env python3", sys.executable))
        (bin_ / "niri").chmod(0o755)
        data = self.dir / "data.json"
        data.write_text(json.dumps({"windows": WINDOWS, "workspaces": WORKSPACES, "outputs": OUTPUTS, "focused-output": OUTPUTS["DP-1"]}))
        sock = self.dir / "niri.sock"
        sock.touch()
        self.log = self.dir / "log"
        self.log.touch()
        env = dict(os.environ, PATH=f"{bin_}:{os.environ.get('PATH', '')}", NIRI_SOCKET=str(sock), WAYLAND_DISPLAY="wayland-test",
                   FAKE_NIRI_LOG=str(self.log), FAKE_NIRI_DATA=str(data))
        ctx = _env(env)
        ctx.__enter__()
        self.addCleanup(ctx.__exit__, None, None, None)
        self.server = mcp.Server(mcptools.tools())

    def actions(self):
        return [json.loads(line)[2:] for line in self.log.read_text().splitlines() if json.loads(line)[1] == "action"]

    def ok(self, name, args=None):
        r = call(self.server, name, args)["result"]
        self.assertFalse(r["isError"], r["content"][0]["text"])
        return json.loads(r["content"][0]["text"])

    def test_list_windows(self):
        wins = self.ok("list_windows")["windows"]
        self.assertEqual([w["id"] for w in wins], [3, 2])  # floating (no column) first, then columns
        tiled = next(w for w in wins if w["id"] == 2)
        self.assertEqual(tiled["workspace"], {"id": 1, "idx": 1, "name": "code", "output": "DP-1"})
        self.assertEqual((tiled["column"], tiled["row"], tiled["floating"]), (1, 1, False))
        self.assertNotIn("rect", tiled)
        floating = next(w for w in wins if w["id"] == 3)
        self.assertEqual(floating["rect"], [1100.0, 50.0, 400, 300])  # output x + position in view
        self.assertEqual(self.ok("list_windows", {"app_id": "foot"})["windows"][0]["id"], 2)
        self.assertEqual(self.ok("focused_window")["window"]["id"], 3)

    def test_workspaces_outputs(self):
        ws = self.ok("list_workspaces")["workspaces"]
        self.assertEqual([(w["idx"], w["windows"]) for w in ws], [(1, 2), (2, 0)])
        (o,) = self.ok("list_outputs")["outputs"]
        self.assertEqual((o["name"], o["identity"], o["focused"]), ("DP-1", "Dell U2720Q ABC", True))
        self.assertEqual(o["mode"], {"width": 3840, "height": 2160, "refresh_hz": 60.0})

    def test_actions(self):
        self.ok("focus_window", {"id": 2})
        self.ok("move_window_to_workspace", {"id": 2, "workspace": "code", "focus": True})
        self.ok("move_window_to_workspace", {"id": 2, "workspace": 2})
        self.ok("move_window_to_monitor", {"id": 3, "output": "Dell U2720Q ABC"})
        self.ok("set_window_floating", {"id": 2, "floating": True})
        self.ok("set_window_floating", {"id": 3, "floating": False})
        self.ok("set_column_width", {"id": 2, "proportion": 0.5})
        self.ok("toggle_overview", {"state": "open"})
        self.ok("launch", {"command": ["foot", "-e", "sh", "-c", "echo hi; sleep 1"]})
        self.assertEqual(
            self.actions(),
            [
                ["focus-window", "--id", "2"],
                ["move-window-to-workspace", "--window-id", "2", "--focus", "true", "code"],
                ["move-window-to-workspace", "--window-id", "2", "--focus", "false", "2"],
                ["move-window-to-monitor", "--id", "3", "DP-1"],
                ["move-window-to-floating", "--id", "2"],
                ["move-window-to-tiling", "--id", "3"],
                ["focus-window", "--id", "2"],
                ["set-column-width", "50%"],
                ["open-overview"],
                ["spawn", "--", "foot", "-e", "sh", "-c", "echo hi; sleep 1"],
            ],
        )

    def test_unknown_targets_do_nothing(self):
        for name, args, needle in [
            ("focus_window", {"id": 99}, "no window with id 99"),
            ("move_window_to_workspace", {"id": 2, "workspace": "nope"}, "no workspace named 'nope'"),
            ("move_window_to_monitor", {"id": 2, "output": "HDMI-9"}, "no output 'HDMI-9'"),
        ]:
            r = call(self.server, name, args)["result"]
            self.assertTrue(r["isError"])
            self.assertIn(needle, r["content"][0]["text"])
        self.assertEqual(self.actions(), [])


class _env:
    """Swap os.environ for a block."""

    def __init__(self, env):
        self.env = env

    def __enter__(self):
        self.saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(self.env)

    def __exit__(self, *exc):
        os.environ.clear()
        os.environ.update(self.saved)


def _png(w: int, h: int) -> bytes:
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    raw = b"".join(b"\0" + b"\0\0\0" * w for _ in range(h))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


if __name__ == "__main__":
    unittest.main()
