#!/usr/bin/env python3
"""Drive `loft mcp` against a loft-dev test session, over stdio like an agent.

Not a unit test (needs a running session; tests/test_mcp.py is the session-free
part). Usage, from a checkout:

    nohup nix run .#dev -- --session loftmcp "$PWD" > /tmp/loftmcp.log 2>&1 &
    until [ -f "$XDG_RUNTIME_DIR/loft-dev-loftmcp/session.env" ]; do sleep 0.2; done; sleep 3
    python3 tests/mcp_session.py loftmcp -- $(nix build --no-link --print-out-paths .#loft)/bin/loft
    nix run .#dev -- --stop loftmcp

The server runs as `LOFT_SESSION=NAME <loft> --dev mcp`, so every niri / grim /
quickshell call goes to the session (checked: the server's outputs must be the
session's, and session.env's NIRI_SOCKET must name it). Screenshots land in
/tmp/loft-mcp-NAME-*.png.
"""

from __future__ import annotations

import base64
import json
import os
import struct
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    name = sys.argv[1] if len(sys.argv) > 1 else "loftmcp"
    loft = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else [sys.executable, "-B", str(Path(__file__).resolve().parents[1] / "cli" / "loft")]
    env_file = Path(f"/run/user/{os.getuid()}/loft-dev-{name}/session.env")
    session = dict(line.split("=", 1) for line in env_file.read_text().splitlines() if "=" in line)
    assert f"loft-dev-{name}" in session["NIRI_SOCKET"], session["NIRI_SOCKET"]
    env = dict(os.environ, LOFT_SESSION=name, **{k: session[k] for k in ("NIRI_SOCKET", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")})
    env.pop("DISPLAY", None)

    p = subprocess.Popen([*loft, "--dev", "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
    ids = iter(range(1, 10_000))

    def req(method, params=None):
        mid = next(ids)
        p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}) + "\n")
        p.stdin.flush()
        resp = json.loads(p.stdout.readline())
        assert resp.get("id") == mid, resp
        if "error" in resp:
            raise SystemExit(f"{method}: {resp['error']}")
        return resp["result"]

    def tool(name_, args=None, expect_error=False):
        r = req("tools/call", {"name": name_, "arguments": args or {}})
        texts = [c["text"] for c in r["content"] if c["type"] == "text"]
        ok = r["isError"] == expect_error
        print(f"{'PASS' if ok else 'FAIL'} {name_} {json.dumps(args or {})[:90]} → {(texts[0] if texts else '[image]')[:160]}")
        if not ok:
            raise SystemExit(1)
        return r

    def data(r):
        return json.loads(next(c["text"] for c in r["content"] if c["type"] == "text"))

    init = req("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp_session", "version": "0"}})
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    p.stdin.flush()
    print(f"server {init['serverInfo']} protocol {init['protocolVersion']}")
    tools = [t["name"] for t in req("tools/list")["tools"]]
    print(f"{len(tools)} tools: {', '.join(tools)}")

    outs = data(tool("list_outputs"))["outputs"]
    session_outputs = {o["name"] for o in outs}
    assert session_outputs <= {"winit"} | {f"headless-{i}" for i in range(1, 10)}, f"not the test session's outputs: {session_outputs}"

    # Two windows to play with.
    for i in (1, 2):
        tool("launch", {"command": ["foot", "--app-id", f"dev.loftmcp.t{i}", "--title", f"loftmcp {i}"]})
    for _ in range(50):
        wins = data(tool("list_windows"))["windows"]
        mine = [w for w in wins if (w["app_id"] or "").startswith("dev.loftmcp.")]
        if len(mine) >= 2:
            break
        time.sleep(0.2)
    assert len(mine) >= 2, wins
    a, b = mine[0]["id"], mine[1]["id"]
    tool("list_workspaces")
    tool("focus_window", {"id": a})
    assert data(tool("focused_window"))["window"]["id"] == a
    tool("move_window_to_workspace", {"id": b, "workspace": 2, "focus": False})
    wb = next(w for w in data(tool("list_windows"))["windows"] if w["id"] == b)
    assert wb["workspace"]["idx"] == 2, wb
    tool("set_window_floating", {"id": a, "floating": True})
    time.sleep(0.5)
    wa = next(w for w in data(tool("list_windows"))["windows"] if w["id"] == a)
    assert wa["floating"] and wa.get("rect"), wa
    tool("set_column_width", {"id": b, "proportion": 0.5})
    tool("focus_window", {"id": a})
    tool("toggle_overview", {"state": "open"})
    time.sleep(0.4)
    tool("toggle_overview", {"state": "close"})
    tool("focus_window", {"id": 999999}, expect_error=True)
    tool("move_window_to_monitor", {"id": a, "output": "nope"}, expect_error=True)

    time.sleep(0.8)
    for label, r in (
        ("output", tool("screenshot_output", {"max_width": 1280})),
        ("output-full", tool("screenshot_output")),
        ("window-floating", tool("screenshot_window", {"id": a, "max_width": 640})),
        ("window-tiled", tool("screenshot_window", {"id": b})),
    ):
        img = next(c for c in r["content"] if c["type"] == "image")
        png = base64.b64decode(img["data"])
        assert png[:8] == b"\x89PNG\r\n\x1a\n", label
        w, h = struct.unpack(">II", png[16:24])
        info = data(r)
        assert (info["width"], info["height"]) == (w, h), (info, w, h)
        out = Path(f"/tmp/loft-mcp-{name}-{label}.png")
        out.write_bytes(png)
        print(f"  {label}: {w}x{h} ({len(png)} bytes, {info.get('method', 'grim')}) → {out}")

    tool("loft_windows_list")
    tool("loft_windows_rule", {"app_id": "dev.loftmcp.t1", "fields": {"open-floating": True, "default-column-width": 0.5}})
    rule = data(tool("loft_windows_rule", {"app_id": "dev.loftmcp.t1"}))
    assert "open-floating" in rule["output"], rule
    tool("loft_windows_rule", {"app_id": "dev.loftmcp.t1", "fields": {"open-floating": None, "default-column-width": None}})
    tool("loft_windows_rule", {"app_id": "dev.loftmcp.t1", "fields": {"bogus": 1}}, expect_error=True)
    themes = data(tool("loft_theme_list"))
    print(f"  current theme {themes['current']}, {len(themes['themes'])} themes")
    tool("loft_appearance_get")
    tool("loft_niri_show")
    tool("loft_niri_set", {"key": "layout.gaps", "value": "12"})
    tool("shell_ipc_list")
    tool("shell_ipc_call", {"target": "theme", "function": "current"})
    tool("shell_ipc_call", {"target": "island", "function": "toggle"})
    tool("shell_ipc_call", {"target": "island", "function": "close"})
    tool("shell_ipc_call", {"target": "timers", "function": "list"})
    tool("shell_ipc_call", {"target": "theme", "function": "current", "args": ["x"]}, expect_error=True)
    tool("shell_ipc_call", {"target": "lock", "function": "lock"}, expect_error=True)
    tool("close_window", {"id": b})

    p.stdin.close()
    p.wait(timeout=10)
    print("all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
