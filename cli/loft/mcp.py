"""`loft mcp`: a Model Context Protocol server over stdio, so an AI agent can
drive the desktop (niri + the Loft shell) with structured tools instead of
clicking pixels. The tools are in mcptools.py; this module is the protocol.

MCP over stdio is JSON-RPC 2.0, one message per line (no embedded newlines).
Implemented by hand (no `mcp` SDK in the CLI's Python): `initialize`,
`notifications/initialized`, `ping`, `tools/list`, `tools/call`. Everything
that is not a protocol message goes to stderr — stdout belongs to the client,
and every subprocess gets its own stdout pipe (never ours).
"""

from __future__ import annotations

import json
import re
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Callable, TextIO

PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_VERSIONS = (PROTOCOL_VERSION, "2025-03-26", "2024-11-05")
SERVER_NAME = "loft"
SERVER_VERSION = "0.1.0"

# JSON-RPC error codes.
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603


class ToolError(Exception):
    """A tool failed in a way the caller should read (→ `isError: true`)."""


@dataclass
class Image:
    """An image tool result: PNG bytes plus a JSON-able description."""

    png: bytes
    info: dict = field(default_factory=dict)


@dataclass
class Tool:
    name: str
    description: str
    schema: dict
    fn: Callable[[dict], Any]
    read_only: bool = False
    title: str | None = None

    def listing(self) -> dict:
        out = {"name": self.name, "description": self.description, "inputSchema": self.schema}
        if self.title:
            out["title"] = self.title
        out["annotations"] = {
            "readOnlyHint": self.read_only,
            "destructiveHint": False,
            "openWorldHint": False,
        }
        return out


# ── a strict JSON Schema subset (what the tool schemas use) ─────────────────

_TYPES = {
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "array": lambda v: isinstance(v, list),
    "object": lambda v: isinstance(v, dict),
    "null": lambda v: v is None,
}


def validate(value: Any, schema: dict, where: str = "arguments") -> None:
    """Raise ToolError naming the first violation. Supports type (one or a
    list), enum, properties / required / additionalProperties (bool or schema),
    items, min/maxItems, min/maxLength, pattern, minimum / maximum."""
    types = schema.get("type")
    if types is not None:
        tl = [types] if isinstance(types, str) else list(types)
        if not any(_TYPES[t](value) for t in tl):
            raise ToolError(f"{where}: expected {' or '.join(tl)}, got {json.dumps(value)[:60]}")
    if "enum" in schema and value not in schema["enum"]:
        raise ToolError(f"{where}: must be one of {', '.join(map(json.dumps, schema['enum']))}")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            raise ToolError(f"{where}: too short (min {schema['minLength']})")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise ToolError(f"{where}: too long (max {schema['maxLength']})")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise ToolError(f"{where}: {json.dumps(value)[:60]} does not match {schema['pattern']}")
    if _TYPES["number"](value):
        if "minimum" in schema and value < schema["minimum"]:
            raise ToolError(f"{where}: must be ≥ {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            raise ToolError(f"{where}: must be ≤ {schema['maximum']}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            raise ToolError(f"{where}: needs at least {schema['minItems']} item(s)")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise ToolError(f"{where}: at most {schema['maxItems']} items")
        if "items" in schema:
            for i, v in enumerate(value):
                validate(v, schema["items"], f"{where}[{i}]")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for k in schema.get("required", []):
            if k not in value:
                raise ToolError(f"{where}: missing required '{k}'")
        extra = schema.get("additionalProperties", True)
        for k, v in value.items():
            if k in props:
                validate(v, props[k], f"{where}.{k}")
            elif extra is False:
                raise ToolError(f"{where}: unknown field '{k}' (allowed: {', '.join(props) or 'none'})")
            elif isinstance(extra, dict):
                validate(v, extra, f"{where}.{k}")


# ── server ──────────────────────────────────────────────────────────────────


def log(msg: str) -> None:
    """One line on stderr (never stdout: that is the protocol channel)."""
    print(f"loft-mcp {time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", file=sys.stderr, flush=True)


def _short(args: dict) -> str:
    s = json.dumps(args, ensure_ascii=False, separators=(",", ":"))
    return s if len(s) <= 200 else s[:197] + "…"


def tool_result(value: Any) -> dict:
    """A tool's return value → a CallToolResult."""
    import base64

    if isinstance(value, Image):
        content = [{"type": "image", "data": base64.b64encode(value.png).decode(), "mimeType": "image/png"}]
        if value.info:
            content.append({"type": "text", "text": json.dumps(value.info)})
        return {"content": content, "isError": False}
    if isinstance(value, str):
        return {"content": [{"type": "text", "text": value}], "isError": False}
    out = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}], "isError": False}
    if isinstance(value, dict):
        out["structuredContent"] = value
    return out


def error_result(msg: str) -> dict:
    return {"content": [{"type": "text", "text": msg}], "isError": True}


class Server:
    def __init__(self, tools: list[Tool], instructions: str = ""):
        self.tools = {t.name: t for t in tools}
        self.instructions = instructions
        self.initialized = False

    # Each handler returns the `result` object or raises _RpcError.
    def _initialize(self, params: dict) -> dict:
        asked = params.get("protocolVersion")
        version = asked if asked in SUPPORTED_VERSIONS else PROTOCOL_VERSION
        client = (params.get("clientInfo") or {}).get("name", "?")
        log(f"initialize client={client} protocol={asked} → {version}")
        out = {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "title": "Loft desktop", "version": SERVER_VERSION},
        }
        if self.instructions:
            out["instructions"] = self.instructions
        return out

    def _tools_list(self, params: dict) -> dict:
        return {"tools": [t.listing() for t in self.tools.values()]}

    def _tools_call(self, params: dict) -> dict:
        name = params.get("name")
        args = params.get("arguments")
        if args is None:
            args = {}
        tool = self.tools.get(name) if isinstance(name, str) else None
        if tool is None:
            raise _RpcError(INVALID_PARAMS, f"unknown tool: {name!r}")
        if not isinstance(args, dict):
            raise _RpcError(INVALID_PARAMS, "arguments must be an object")
        t0 = time.monotonic()
        try:
            validate(args, tool.schema)
            result = tool_result(tool.fn(args))
            status = "ok"
        except ToolError as e:
            result, status = error_result(str(e)), f"error: {e}"
        except Exception as e:  # a bug, not the caller's fault: say so, keep serving
            result, status = error_result(f"internal error in {name}: {type(e).__name__}: {e}"), f"crash: {e!r}"
        ms = int((time.monotonic() - t0) * 1000)
        log(f"call {name} {_short(args)} → {status.splitlines()[0][:200]} ({ms} ms)")
        return result

    def handle(self, msg: Any) -> dict | None:
        """One parsed message → the response to send (None for notifications)."""
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method", ""), str):
            return _error(msg.get("id") if isinstance(msg, dict) else None, INVALID_REQUEST, "not a JSON-RPC 2.0 message")
        method = msg.get("method")
        mid = msg.get("id")
        is_note = "id" not in msg
        if method is None:
            return None  # a response to something we never send; ignore
        if is_note:
            if method == "notifications/initialized":
                self.initialized = True
            return None  # notifications/cancelled etc.: nothing to do (calls are synchronous)
        params = msg.get("params") or {}
        if not isinstance(params, dict):
            return _error(mid, INVALID_PARAMS, "params must be an object")
        handlers = {
            "initialize": self._initialize,
            "ping": lambda p: {},
            "tools/list": self._tools_list,
            "tools/call": self._tools_call,
        }
        h = handlers.get(method)
        if h is None:
            return _error(mid, METHOD_NOT_FOUND, f"method not found: {method}")
        try:
            return {"jsonrpc": "2.0", "id": mid, "result": h(params)}
        except _RpcError as e:
            return _error(mid, e.code, e.message)

    def serve(self, rx: TextIO, tx: TextIO) -> None:
        for line in rx:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError as e:
                self._send(tx, _error(None, PARSE_ERROR, f"parse error: {e}"))
                continue
            if isinstance(msg, list):  # batches were dropped in 2025-06-18
                self._send(tx, _error(None, INVALID_REQUEST, "batches are not supported"))
                continue
            resp = self.handle(msg)
            if resp is not None:
                self._send(tx, resp)

    @staticmethod
    def _send(tx: TextIO, obj: dict) -> None:
        tx.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
        tx.flush()


class _RpcError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _error(mid: Any, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}


# ── CLI ─────────────────────────────────────────────────────────────────────


def add_parser(top) -> None:
    s = top.add_parser(
        "mcp",
        help="MCP server on stdio: niri + Loft shell tools for an AI agent",
        description="Speaks the Model Context Protocol (JSON-RPC 2.0, one message per line) on "
        "stdin/stdout. Needs the desktop session's NIRI_SOCKET and WAYLAND_DISPLAY (plus "
        "XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS). Logs one line per call on stderr. "
        "`--list-tools` prints the tools and exits.",
    )
    s.add_argument("--list-tools", action="store_true", help="print the tools (name: description) and exit")
    s.set_defaults(fn=cmd_mcp)


def cmd_mcp(ctx, args) -> None:
    from . import mcptools

    tools = mcptools.tools(dev=ctx.dev)
    if args.list_tools:
        for t in tools:
            print(f"{t.name}: {t.description}")
        return
    for problem in mcptools.env_problems():
        log(f"warning: {problem}")
    # Line-buffered UTF-8 regardless of the locale the SSH launcher gives us.
    rx = open(sys.stdin.fileno(), "r", encoding="utf-8", errors="replace", closefd=False)
    tx = open(sys.stdout.fileno(), "w", encoding="utf-8", closefd=False)
    log(f"serving {len(tools)} tools on stdio (protocol {PROTOCOL_VERSION})")
    try:
        Server(tools, mcptools.INSTRUCTIONS).serve(rx, tx)
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    log("stdin closed; bye")
