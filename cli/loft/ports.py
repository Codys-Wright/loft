"""Port manager (`loft ports …`): who is listening on which port.

  list   listening TCP sockets and bound UDP sockets from /proc/net/{tcp,udp}{,6},
         grouped per (protocol, port, process), with the owning process when it
         is yours (/proc/<pid>/fd is readable only for your own processes; other
         users' and root's sockets are listed with their uid and no pid), its
         working directory and the project it runs in (the nearest folder with
         .git, package.json, Cargo.toml, flake.nix …), and a dev-server guess
  stop   SIGTERM (or --force: SIGKILL) one of your own processes, after
         checking it is still yours and, with --port, still listening there

Everything prints JSON for the shell (src/services/Ports.qml).
"""

from __future__ import annotations

import json
import os
import signal
import socket
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# /proc/net/tcp state column.
TCP_LISTEN = "0A"
UDP_UNCONN = "07"

# Folders that mark a project root (dev servers run inside one).
PROJECT_MARKERS = (
    ".git",
    "package.json",
    "Cargo.toml",
    "flake.nix",
    "pyproject.toml",
    "go.mod",
    "deno.json",
    "Gemfile",
    "composer.json",
    "mix.exs",
    "pom.xml",
    "build.gradle",
)

# Programs that usually are a dev server when they listen.
DEV_PROGRAMS = {
    "node", "bun", "deno", "npm", "pnpm", "yarn", "npx", "vite", "next-server", "nuxt", "astro",
    "python", "python3", "uvicorn", "gunicorn", "flask", "django", "jupyter", "jupyter-lab",
    "ruby", "rails", "puma", "php", "php-fpm", "java", "go", "air", "cargo", "dx", "trunk",
    "hugo", "zola", "jekyll", "mkdocs", "caddy", "http-server", "serve", "live-server",
    "storybook", "webpack", "esbuild", "parcel", "gatsby", "remix", "wrangler", "miniflare",
    "beam.smp", "elixir", "dotnet", "streamlit", "gradio", "ollama", "tauri",
}
# Ports dev tools default to.
DEV_PORTS = {
    1420, 3000, 3001, 3002, 3003, 4000, 4200, 4321, 4173, 5000, 5001, 5173, 5174, 5500,
    6006, 7860, 8000, 8001, 8008, 8080, 8081, 8088, 8501, 8787, 8888, 9000, 9229,
}
# Ports that usually speak HTTP even when not a dev server.
HTTP_PORTS = {80, 443, 631, 3000, 5000, 8000, 8008, 8080, 8081, 8088, 8443, 8888, 9000, 9090}


# ── /proc parsing ───────────────────────────────────────────────────────────


def _hex_ip4(h: str) -> str:
    b = bytes.fromhex(h)[::-1]
    return socket.inet_ntop(socket.AF_INET, b)


def _hex_ip6(h: str) -> str:
    raw = bytes.fromhex(h)
    # Four 32-bit words, each in host (little-endian) order.
    b = b"".join(raw[i : i + 4][::-1] for i in range(0, 16, 4))
    return socket.inet_ntop(socket.AF_INET6, b)


def parse_net(text: str, proto: str, v6: bool) -> list[dict]:
    """Rows of /proc/net/{tcp,udp}{,6}: listening TCP, unconnected UDP."""
    out = []
    for line in text.splitlines()[1:]:
        f = line.split()
        if len(f) < 10:
            continue
        local, remote, st = f[1], f[2], f[3]
        if proto == "tcp" and st != TCP_LISTEN:
            continue
        if proto == "udp":
            rport = int(remote.rsplit(":", 1)[1], 16)
            if st != UDP_UNCONN or rport != 0:
                continue
        ip_hex, port_hex = local.rsplit(":", 1)
        try:
            ip = _hex_ip6(ip_hex) if v6 else _hex_ip4(ip_hex)
        except (ValueError, OSError):
            continue
        out.append({"proto": proto, "v6": v6, "address": ip, "port": int(port_hex, 16), "uid": int(f[7]), "inode": int(f[9])})
    return out


def read_sockets(proc: Path) -> list[dict]:
    rows = []
    for name, proto, v6 in (("tcp", "tcp", False), ("tcp6", "tcp", True), ("udp", "udp", False), ("udp6", "udp", True)):
        try:
            rows += parse_net((proc / "net" / name).read_text(), proto, v6)
        except OSError:
            pass
    return rows


def inode_owners(proc: Path) -> dict[int, int]:
    """socket inode → pid, for every process whose fds we may read (our own)."""
    owners: dict[int, int] = {}
    for d in proc.iterdir():
        if not d.name.isdigit():
            continue
        try:
            fds = os.scandir(d / "fd")
        except OSError:
            continue
        with fds:
            for fd in fds:
                try:
                    t = os.readlink(fd.path)
                except OSError:
                    continue
                if t.startswith("socket:["):
                    owners.setdefault(int(t[8:-1]), int(d.name))
    return owners


def _read(p: Path) -> str | None:
    try:
        return p.read_text()
    except OSError:
        return None


def project_of(cwd: str | None, home: str) -> dict | None:
    """The nearest folder at or above cwd with a project marker (not $HOME or /)."""
    if not cwd:
        return None
    p = Path(cwd)
    stop = {Path(home), Path("/")}
    for d in [p, *p.parents]:
        if d in stop:
            return None
        for m in PROJECT_MARKERS:
            if (d / m).exists():
                return {"name": d.name, "path": str(d), "marker": m}
    return None


def process_info(proc: Path, pid: int, home: str) -> dict:
    d = proc / str(pid)
    comm = (_read(d / "comm") or "").strip()
    raw = _read(d / "cmdline") or ""
    argv = [a for a in raw.split("\0") if a]
    try:
        cwd = os.readlink(d / "cwd")
    except OSError:
        cwd = None
    uid = None
    for line in (_read(d / "status") or "").splitlines():
        if line.startswith("Uid:"):
            uid = int(line.split()[1])
            break
    exe = Path(argv[0]).name if argv else comm
    # Interpreters: name the script / module too ("python3 -m http.server").
    detail = ""
    script = ""
    if exe.startswith(("python", "node", "bun", "deno", "ruby", "php")) and len(argv) > 1:
        rest = [a for a in argv[1:] if not a.startswith("-")]
        if "-m" in argv[1:]:
            i = argv.index("-m")
            detail = argv[i + 1] if i + 1 < len(argv) else ""
        elif rest:
            script = rest[0]
            detail = Path(script).name
            if detail.startswith(".") and detail.endswith("-wrapped"):
                detail = detail[1 : -len("-wrapped")]
    # comm is cut at 15 bytes and nix wrappers rename the program
    # (".sunshine-wrapped"): prefer argv[0] when it is the same program.
    same = comm and exe and (exe.startswith(comm[:15]) or comm.lstrip(".").startswith(exe))
    name = exe if same else (comm or exe)
    # An installed program run by an interpreter: call it by its own name.
    if script and (script.startswith("/nix/store/") or "/bin/" in script):
        name = detail
    return {
        "pid": pid,
        "name": name,
        "exe": exe,
        "detail": detail,
        "script": script,
        "command": " ".join(argv)[:400],
        "cwd": cwd,
        "project": project_of(cwd, home),
        "uid": uid,
    }


def _is_dev(proc_info: dict | None, port: int, mine: bool, proto: str = "tcp") -> bool:
    """Your own TCP server run from a project folder, by a dev tool, or on a dev port."""
    if not mine or proc_info is None or port < 1024 or proto != "tcp":
        return False
    if proc_info["project"] is not None:
        return True
    if proc_info.get("script", "").startswith("/nix/store/"):
        return port in DEV_PORTS  # an installed tool, not your code
    names = {proc_info["name"].lower(), proc_info["exe"].lower(), proc_info["detail"].lower()}
    if names & DEV_PROGRAMS or any(n.startswith(("python3.", "node")) for n in names):
        return True
    return port in DEV_PORTS


def _local(addr: str) -> bool:
    return addr in ("0.0.0.0", "::", "127.0.0.1", "::1") or addr.startswith("127.")


def url_for(addresses: list[str], port: int) -> str:
    if any(_local(a) for a in addresses):
        host = "localhost"
    else:
        a = addresses[0]
        host = f"[{a}]" if ":" in a else a
    scheme = "https" if port in (443, 8443) else "http"
    return f"{scheme}://{host}:{port}"


def probe_http(url: str, timeout: float = 0.6) -> dict | None:
    """A quick GET on a dev server: status and page title (None: not HTTP)."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "loft-ports"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read(16384).decode("utf-8", "replace")
            status = r.status
    except urllib.error.HTTPError as e:
        return {"status": e.code, "title": ""}
    except Exception:
        return None
    title = ""
    lo = body.lower()
    i = lo.find("<title")
    if i >= 0:
        j = lo.find(">", i)
        k = lo.find("</title>", j)
        if j >= 0 and k > j:
            title = " ".join(body[j + 1 : k].split())[:120]
    return {"status": status, "title": title}


def listening(proc: Path = Path("/proc"), uid: int | None = None, home: str | None = None, probe: bool = False) -> dict:
    uid = os.getuid() if uid is None else uid
    home = home or os.environ.get("HOME") or str(Path.home())
    sockets = read_sockets(proc)
    owners = inode_owners(proc)
    infos: dict[int, dict] = {}
    groups: dict[tuple, dict] = {}
    for s in sockets:
        pid = owners.get(s["inode"])
        if pid is not None and pid not in infos:
            infos[pid] = process_info(proc, pid, home)
        key = (s["proto"], s["port"], pid if pid is not None else f"uid{s['uid']}")
        g = groups.get(key)
        if g is None:
            info = infos.get(pid) if pid is not None else None
            mine = s["uid"] == uid
            g = groups[key] = {
                "proto": s["proto"],
                "port": s["port"],
                "addresses": [],
                "uid": s["uid"],
                "mine": mine,
                "pid": pid,
                "process": info,
                "dev": _is_dev(info, s["port"], mine, s["proto"]),
            }
        if s["address"] not in g["addresses"]:
            g["addresses"].append(s["address"])
    rows = []
    for g in groups.values():
        g["public"] = any(a in ("0.0.0.0", "::") for a in g["addresses"])
        g["http"] = g["proto"] == "tcp" and (g["dev"] or g["port"] in HTTP_PORTS)
        g["url"] = url_for(g["addresses"], g["port"]) if g["http"] else None
        rows.append(g)
    if probe:
        targets = [r for r in rows if r["dev"] and r["proto"] == "tcp"]
        with ThreadPoolExecutor(max_workers=8) as ex:
            for r, res in zip(targets, ex.map(lambda r: probe_http(url_for(r["addresses"], r["port"])), targets)):
                r["httpProbe"] = res
                if res is not None:
                    r["http"] = True
                    r["url"] = url_for(r["addresses"], r["port"])
                elif r["port"] not in HTTP_PORTS:
                    r["http"], r["url"] = False, None  # asked, and it doesn't speak HTTP
    rows.sort(key=lambda r: (not r["dev"], not r["mine"], r["proto"], r["port"]))
    return {"uid": uid, "ports": rows}


# ── stopping ────────────────────────────────────────────────────────────────


def stop(pid: int, force: bool = False, port: int | None = None, proc: Path = Path("/proc")) -> dict:
    """Signal one of your own processes; refuses anything else."""
    status = _read(proc / str(pid) / "status")
    if status is None:
        return {"ok": False, "pid": pid, "error": "no such process (it may have exited)"}
    owner = next((int(l.split()[1]) for l in status.splitlines() if l.startswith("Uid:")), None)
    if owner != os.getuid():
        return {"ok": False, "pid": pid, "error": "not your process — stop it with its service or sudo"}
    if port is not None:
        held = {s["inode"] for s in read_sockets(proc) if s["port"] == port}
        mine = {i for i, p in inode_owners(proc).items() if p == pid}
        if not held & mine:
            return {"ok": False, "pid": pid, "error": f"process {pid} no longer listens on {port}"}
    try:
        os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
    except ProcessLookupError:
        return {"ok": False, "pid": pid, "error": "no such process (it may have exited)"}
    except PermissionError:
        return {"ok": False, "pid": pid, "error": "permission denied"}
    return {"ok": True, "pid": pid, "signal": "KILL" if force else "TERM"}


def alive(pid: int, proc: Path = Path("/proc")) -> bool:
    st = _read(proc / str(pid) / "stat")
    if st is None:
        return False
    # A zombie has exited (its parent hasn't reaped it yet).
    return st.rsplit(")", 1)[-1].split()[0] != "Z"


# ── CLI ─────────────────────────────────────────────────────────────────────


def add_parser(top) -> None:
    ports = top.add_parser("ports", help="listening ports and the processes behind them (JSON)")
    sub = ports.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("list", help="listening TCP / bound UDP sockets with their processes")
    s.add_argument("--probe", action="store_true", help="GET each dev server once for its status and page title")
    s.set_defaults(fn=lambda ctx, a: print(json.dumps(listening(probe=a.probe))))

    s = sub.add_parser("stop", help="SIGTERM one of your own processes (--force: SIGKILL)")
    s.add_argument("pid", type=int)
    s.add_argument("--force", action="store_true")
    s.add_argument("--port", type=int, help="only if it still listens on this port")

    def _stop(ctx, a):
        r = stop(a.pid, force=a.force, port=a.port)
        print(json.dumps(r))
        if not r["ok"]:
            raise SystemExit(1)

    s.set_defaults(fn=_stop)

    s = sub.add_parser("alive", help="whether a pid is still running")
    s.add_argument("pid", type=int)
    s.set_defaults(fn=lambda ctx, a: print(json.dumps({"pid": a.pid, "alive": alive(a.pid)})))
