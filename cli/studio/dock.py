"""The dock's helpers (`studio dock …`): what the shell can't cheaply do in QML.

  apps       desktop entries: file, Exec, MIME types, WM class (for matching)
  recents    recently used files per app: ~/.local/share/recently-used.xbel
             (GTK/KDE), plus VS Code and Zed recent workspaces
  folder     a docked folder's contents, sorted, with icons and cached thumbnails
  trash      how full the trash is
  open       launch a desktop entry with files (field codes expanded)
  show       reveal a file in the file manager (FileManager1.ShowItems)
  autostart  "Open at Login": XDG autostart entries the dock owns

Everything prints JSON for the shell; nothing here deletes or moves user files
(emptying the trash and trashing files are `gio trash` calls in the shell).
"""

from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import urllib.parse
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BOOKMARK_NS = "{http://www.freedesktop.org/standards/desktop-bookmarks}"
MIME_NS = "{http://www.freedesktop.org/standards/shared-mime-info}"
# Marks the autostart entries the dock wrote ("Open at Login").
MARK = "X-Studio-OpenAtLogin"
THUMB_SIZE = 256

# Launchers that open a file with "the default app": the bookmark doesn't say
# which app it was.
GENERIC_OPENERS = {"gio", "xdg-open", "kde-open", "kde-open5", "gnome-open", "exo-open", "handlr", "mimeo"}


# ── environment ─────────────────────────────────────────────────────────────


def _home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME") or _home() / ".local" / "share")


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or _home() / ".config")


def cache_home() -> Path:
    return Path(os.environ.get("XDG_CACHE_HOME") or _home() / ".cache")


def data_dirs() -> list[Path]:
    dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    return [data_home()] + [Path(d) for d in dirs.split(":") if d]


def config_dirs() -> list[Path]:
    dirs = os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg"
    return [Path(d) for d in dirs.split(":") if d]


def user_dir(name: str) -> Path:
    """An XDG user dir (DOWNLOAD, DOCUMENTS, …) from user-dirs.dirs, as xdg-user-dir does."""
    key = f"XDG_{name.upper()}_DIR"
    f = config_home() / "user-dirs.dirs"
    try:
        for line in f.read_text().splitlines():
            line = line.strip()
            if line.startswith(key + "="):
                v = line.split("=", 1)[1].strip().strip('"')
                v = v.replace("$HOME", str(_home()))
                return Path(v)
    except OSError:
        pass
    if os.environ.get(key):
        return Path(os.environ[key])
    fallback = {"DOWNLOAD": "Downloads", "DOCUMENTS": "Documents", "PICTURES": "Pictures",
                "MUSIC": "Music", "VIDEOS": "Videos", "DESKTOP": "Desktop"}  # fmt: skip
    return _home() / fallback.get(name.upper(), "")


def resolve_folder(spec: str) -> Path:
    """`xdg:DOWNLOAD` → the Downloads dir; `~/x` → $HOME/x; else the path."""
    if spec.startswith("xdg:"):
        return user_dir(spec[4:])
    return Path(os.path.expanduser(spec))


# ── desktop entries ─────────────────────────────────────────────────────────


def parse_desktop(path: Path) -> dict[str, str]:
    """The [Desktop Entry] group (unlocalized keys)."""
    out: dict[str, str] = {}
    group = None
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            group = line[1:-1]
            continue
        if group != "Desktop Entry" or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        if "[" in k:
            continue
        out.setdefault(k, v.strip())
    return out


def desktop_files() -> dict[str, Path]:
    """desktop id → file, first in XDG order wins."""
    found: dict[str, Path] = {}
    for d in data_dirs():
        apps = d / "applications"
        if not apps.is_dir():
            continue
        for f in sorted(apps.rglob("*.desktop")):
            did = str(f.relative_to(apps))[: -len(".desktop")].replace("/", "-")
            found.setdefault(did, f)
    return found


def exec_argv(exec_line: str) -> list[str]:
    try:
        return shlex.split(exec_line)
    except ValueError:
        return exec_line.split()


def exec_bin(exec_line: str) -> str:
    """The program an Exec line runs (basename), skipping env and assignments.
    File managers quote the whole command ('org.gnome.Decibels %U'): that
    single token is split again."""
    argv = exec_argv(exec_line.replace("&apos;", "'"))
    if len(argv) == 1 and " " in argv[0]:
        argv = exec_argv(argv[0])
    while argv:
        a = argv[0]
        b = os.path.basename(a)
        if b == "env" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a):
            argv = argv[1:]
            continue
        if b == "flatpak" and "run" in argv:
            rest = [x for x in argv[argv.index("run") + 1 :] if not x.startswith("-")]
            return rest[0] if rest else b
        return b
    return ""


def app_info(did: str, f: Path) -> dict:
    e = parse_desktop(f)
    return {
        "id": did,
        "file": str(f),
        "name": e.get("Name", did),
        "exec": e.get("Exec", ""),
        "bin": exec_bin(e.get("Exec", "")),
        "mime": [m for m in e.get("MimeType", "").split(";") if m],
        "wmclass": e.get("StartupWMClass", ""),
        "icon": e.get("Icon", ""),
        "hidden": e.get("NoDisplay", "").lower() == "true" or e.get("Hidden", "").lower() == "true",
    }


def all_apps() -> dict[str, dict]:
    return {did: app_info(did, f) for did, f in desktop_files().items()}


# ── file kinds ──────────────────────────────────────────────────────────────

EXTRA_TYPES = {
    ".appimage": "application/vnd.appimage",
    ".iso": "application/x-cd-image",
    ".deb": "application/vnd.debian.binary-package",
    ".rpm": "application/x-rpm",
    ".flatpakref": "application/vnd.flatpak.ref",
    ".zst": "application/zstd",
    ".7z": "application/x-7z-compressed",
    ".rar": "application/vnd.rar",
    ".kdl": "text/plain",
    ".md": "text/markdown",
    ".nix": "text/x-nix",
    ".rs": "text/rust",
    ".qml": "text/x-qml",
    ".rpp": "application/x-reaper-project",
    ".wav": "audio/x-wav",
    ".flac": "audio/flac",
    ".webp": "image/webp",
    ".avif": "image/avif",
    ".heic": "image/heic",
    ".mkv": "video/x-matroska",
    ".webm": "video/webm",
}
ARCHIVES = {"zip", "x-tar", "gzip", "x-bzip2", "x-xz", "zstd", "x-7z-compressed", "vnd.rar", "x-compressed-tar"}


def mime_of(p: Path, is_dir: bool | None = None) -> str:
    if is_dir if is_dir is not None else p.is_dir():
        return "inode/directory"
    ext = p.suffix.lower()
    if ext in EXTRA_TYPES:
        return EXTRA_TYPES[ext]
    t, enc = mimetypes.guess_type(p.name, strict=False)
    if enc in ("gzip", "bzip2", "xz") and (t is None or t == "application/x-tar"):
        return "application/x-compressed-tar" if t else {"gzip": "application/gzip", "bzip2": "application/x-bzip2", "xz": "application/x-xz"}[enc]
    return t or "application/octet-stream"


def icons_for(mime: str) -> tuple[str, str]:
    """(specific, generic) freedesktop icon names for a MIME type."""
    if mime == "inode/directory":
        return "folder", "folder"
    top, _, sub = mime.partition("/")
    specific = mime.replace("/", "-")
    if top == "application" and sub in ARCHIVES:
        return specific, "package-x-generic"
    if mime == "application/pdf":
        return "application-pdf", "x-office-document"
    if top in ("image", "video", "audio", "text"):
        return specific, f"{top}-x-generic"
    if sub in ("x-executable", "vnd.appimage", "x-sharedlib"):
        return specific, "application-x-executable"
    return specific, "text-x-generic" if sub.endswith("json") or sub.endswith("xml") else "unknown"


# ── thumbnails ──────────────────────────────────────────────────────────────


def _have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def freedesktop_thumb(p: Path, mtime: float) -> str | None:
    """An up-to-date thumbnail another app already made (~/.cache/thumbnails)."""
    uri = p.resolve().as_uri()
    digest = hashlib.md5(uri.encode()).hexdigest()
    for size in ("large", "x-large", "normal"):
        t = cache_home() / "thumbnails" / size / f"{digest}.png"
        try:
            if t.stat().st_mtime >= mtime:
                return str(t)
        except OSError:
            continue
    return None


def thumb_path(state_dir: Path, p: Path, st: os.stat_result) -> Path:
    key = hashlib.sha1(f"{p}:{st.st_mtime_ns}:{st.st_size}".encode()).hexdigest()
    return Path(state_dir) / "cache" / "thumbs" / f"dock-{key}.jpg"


def make_thumb(state_dir: Path, p: Path, st: os.stat_result, mime: str) -> str | None:
    """A ≤256 px JPEG in <state>/cache/thumbs (keyed by path, mtime and size)."""
    out = thumb_path(state_dir, p, st)
    if out.is_file():
        return str(out)
    top = mime.split("/")[0]
    tmp = out.with_name(f".{out.stem}.{os.getpid()}.jpg")
    out.parent.mkdir(parents=True, exist_ok=True)
    if top in ("image", "video") and _have("ffmpeg"):
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y"]
        if top == "video":
            cmd += ["-ss", "1"]
        cmd += ["-i", str(p), "-frames:v", "1",
                "-vf", f"scale='min({THUMB_SIZE},iw)':'min({THUMB_SIZE},ih)':force_original_aspect_ratio=decrease:flags=area",
                "-q:v", "4", str(tmp)]  # fmt: skip
    elif mime == "application/pdf" and _have("pdftoppm"):
        cmd = ["pdftoppm", "-jpeg", "-singlefile", "-f", "1", "-scale-to", str(THUMB_SIZE), str(p), str(tmp)[: -len(".jpg")]]
    else:
        return None
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        tmp.unlink(missing_ok=True)
        return None
    if r.returncode != 0 or not tmp.is_file() or tmp.stat().st_size == 0:
        tmp.unlink(missing_ok=True)
        return None
    os.replace(tmp, out)
    return str(out)


THUMBABLE = ("image/", "video/", "application/pdf")


# ── folders ─────────────────────────────────────────────────────────────────

SORTS = ("added", "name", "modified", "kind")


def folder(spec: str, *, sort: str = "added", limit: int = 60, thumbs: int = 24, state_dir: Path | None = None) -> dict:
    """A docked folder: newest (or sorted) entries with kind, icon and thumbnail.

    `added` is the inode change time — Linux keeps no "date added", but moving
    or downloading a file into the folder updates it."""
    root = resolve_folder(spec)
    res = {"spec": spec, "path": str(root), "name": root.name or str(root), "exists": root.is_dir(), "count": 0, "items": []}
    if not root.is_dir():
        return res
    entries = []
    try:
        it = list(os.scandir(root))
    except OSError:
        return res
    for e in it:
        if e.name.startswith("."):
            continue
        try:
            st = e.stat()
            is_dir = e.is_dir()
        except OSError:
            continue
        p = Path(e.path)
        mime = mime_of(p, is_dir)
        icon, generic = icons_for(mime)
        entries.append({
            "path": e.path, "name": e.name, "dir": is_dir, "mime": mime, "icon": icon, "generic": generic,
            "size": st.st_size, "modified": int(st.st_mtime), "added": int(max(st.st_ctime, st.st_mtime)),
            "partial": e.name.endswith((".part", ".crdownload", ".download")), "_st": st,
        })  # fmt: skip
    res["count"] = len(entries)
    keys = {
        "added": lambda x: (-x["added"], x["name"].lower()),
        "modified": lambda x: (-x["modified"], x["name"].lower()),
        "name": lambda x: (not x["dir"], x["name"].lower()),
        "kind": lambda x: (not x["dir"], x["mime"], x["name"].lower()),
    }
    entries.sort(key=keys.get(sort, keys["added"]))
    if limit >= 0:
        entries = entries[:limit]

    def thumb(x):
        st = x.pop("_st")
        if x["dir"] or not x["mime"].startswith(THUMBABLE):
            return
        t = freedesktop_thumb(Path(x["path"]), st.st_mtime)
        if t is None and state_dir is not None and thumb.budget > 0:
            thumb.budget -= 1
            t = make_thumb(state_dir, Path(x["path"]), st, x["mime"])
        if t:
            x["thumb"] = t

    thumb.budget = thumbs
    # Cached ones are instant; generating runs a few ffmpegs at once.
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(thumb, entries))
    res["items"] = entries
    return res


def trash_info() -> dict:
    files = data_home() / "Trash" / "files"
    try:
        count = sum(1 for _ in os.scandir(files))
    except OSError:
        count = 0
    return {"path": str(files), "count": count, "full": count > 0}


def trash_empty() -> dict:
    """Empty the home trash ($XDG_DATA_HOME/Trash: files + info). Trash
    folders on other volumes (.Trash-UID) are left alone."""
    root = data_home() / "Trash"
    removed = 0
    for sub in ("files", "info", "expunged"):
        d = root / sub
        if not d.is_dir():
            continue
        for e in os.scandir(d):
            p = Path(e.path)
            try:
                if e.is_dir(follow_symlinks=False):
                    shutil.rmtree(p)
                else:
                    p.unlink()
                removed += sub == "files"
            except OSError:
                pass
    try:
        (root / "directorysizes").unlink()
    except OSError:
        pass
    return {"path": str(root / "files"), "removed": removed, "count": trash_info()["count"]}


# ── recent files ────────────────────────────────────────────────────────────


def read_xbel(path: Path | None = None) -> list[dict]:
    """Bookmarks of recently-used.xbel, newest first: path, mime, when, and
    the (name, exec) of every app that recorded it."""
    path = path or data_home() / "recently-used.xbel"
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return []
    out = []
    for b in root.iter("bookmark"):
        href = b.get("href", "")
        if not href.startswith("file://"):
            continue
        p = urllib.parse.unquote(urllib.parse.urlparse(href).path)
        mime_el = b.find(f".//{MIME_NS}mime-type")
        apps = []
        for a in b.iter(f"{BOOKMARK_NS}application"):
            apps.append({"name": a.get("name", ""), "exec": a.get("exec", ""), "modified": a.get("modified", "")})
        when = max([a["modified"] for a in apps] + [b.get("modified", ""), b.get("visited", "")])
        out.append({"path": p, "mime": mime_el.get("type") if mime_el is not None else "", "when": when, "apps": apps})
    out.sort(key=lambda x: x["when"], reverse=True)
    return out


def _match_ids(app: dict, by_bin: dict[str, list[str]], ids: set[str]) -> list[str]:
    """Desktop ids that a bookmark's application record means.

    File managers record the app they opened the file *with* in `exec`
    (Nautilus: name=org.gnome.Nautilus exec='org.gnome.Decibels %U'), so the
    program in exec decides; the name only counts when exec runs that same
    app (or nothing)."""
    b = exec_bin(app["exec"])
    if b in GENERIC_OPENERS:
        return []
    found = list(by_bin.get(b, []))
    if b in ids and b not in found:
        found.append(b)
    name = app["name"]
    if name in ids and (not b or b == name or name in by_bin.get(b, [])) and name not in found:
        found.append(name)
    return found


def vscode_recents() -> list[dict]:
    out = []
    for flavor in ("Code", "VSCodium", "Code - OSS"):
        db = config_home() / flavor / "User" / "globalStorage" / "state.vscdb"
        if not db.is_file():
            continue
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
            row = con.execute("SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'").fetchone()
            con.close()
        except sqlite3.Error:
            continue
        if not row:
            continue
        try:
            entries = json.loads(row[0]).get("entries", [])
        except (ValueError, AttributeError):
            continue
        for e in entries:
            uri = e.get("folderUri") or e.get("fileUri") or (e.get("workspace") or {}).get("configPath")
            if isinstance(uri, str) and uri.startswith("file://"):
                out.append({"path": urllib.parse.unquote(urllib.parse.urlparse(uri).path), "flavor": flavor})
    return out


def zed_recents() -> list[dict]:
    out = []
    base = data_home() / "zed" / "db"
    for db in sorted(base.glob("0-*/db.sqlite")) if base.is_dir() else []:
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
            rows = con.execute(
                "SELECT paths, timestamp FROM workspaces WHERE remote_connection_id IS NULL AND paths IS NOT NULL ORDER BY timestamp DESC LIMIT 30"
            ).fetchall()
            con.close()
        except sqlite3.Error:
            continue
        for paths, ts in rows:
            first = (paths or "").split("\n")[0].strip()
            if first:
                out.append({"path": first, "when": ts})
    return out


def default_apps() -> dict[str, str]:
    """MIME type → default desktop id, from the mimeapps.list files (first wins)."""
    files = [config_home() / "mimeapps.list"] + [c / "mimeapps.list" for c in config_dirs()]
    files += [d / "applications" / "mimeapps.list" for d in data_dirs()]
    out: dict[str, str] = {}
    for f in files:
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        group = None
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                group = line[1:-1]
            elif group == "Default Applications" and "=" in line:
                k, v = line.split("=", 1)
                first = next((x for x in v.split(";") if x), "")
                if first:
                    out.setdefault(k.strip(), first.removesuffix(".desktop"))
    return out


def _item(path: str) -> dict | None:
    p = Path(path)
    try:
        is_dir = p.is_dir()
        exists = is_dir or p.exists()
    except OSError:
        return None
    if not exists:
        return None
    mime = mime_of(p, is_dir)
    icon, generic = icons_for(mime)
    return {"path": path, "name": p.name or path, "dir": is_dir, "mime": mime, "icon": icon, "generic": generic}


def recents(
    *, limit: int = 10, apps: dict[str, dict] | None = None, xbel: Path | None = None, defaults: dict[str, str] | None = None
) -> dict:
    """Recent files per desktop id: what the app itself opened first, then
    (to fill up) recent files of the MIME types it is the default app for."""
    defaults = defaults if defaults is not None else default_apps()
    apps = apps if apps is not None else all_apps()
    ids = set(apps)
    by_bin: dict[str, list[str]] = {}
    for did, a in apps.items():
        if a["bin"]:
            by_bin.setdefault(a["bin"], []).append(did)
    marks = read_xbel(xbel)
    direct: dict[str, list[str]] = {}
    for m in marks:
        for a in m["apps"]:
            for did in _match_ids(a, by_bin, ids):
                lst = direct.setdefault(did, [])
                if m["path"] not in lst:
                    lst.append(m["path"])

    # Editors keep their own lists of recent folders.
    for did, a in apps.items():
        extra = []
        if a["bin"] in ("code", "codium", "code-oss") or did in ("code", "codium", "code-oss"):
            extra = [r["path"] for r in vscode_recents()]
        elif a["bin"] in ("zed", "zeditor", "zedit") or did.startswith("dev.zed."):
            extra = [r["path"] for r in zed_recents()]
        if extra:
            lst = direct.setdefault(did, [])
            for p in extra:
                if p not in lst:
                    lst.append(p)

    by_app: dict[str, list[dict]] = {}
    exists_cache: dict[str, dict | None] = {}

    def item(p):
        if p not in exists_cache:
            exists_cache[p] = _item(p)
        return exists_cache[p]

    for did, a in apps.items():
        out: list[dict] = []
        seen = set()
        for p in direct.get(did, []):
            if len(out) >= limit:
                break
            it = item(p)
            if it and p not in seen:
                seen.add(p)
                out.append(dict(it, source="app"))
        types = {t for t in a["mime"] if defaults.get(t) == did}
        if len(out) < limit and types and not a["hidden"]:
            for m in marks:
                if len(out) >= limit:
                    break
                if m["mime"] in types and m["path"] not in seen:
                    it = item(m["path"])
                    if it:
                        seen.add(m["path"])
                        out.append(dict(it, source="type"))
        if out:
            by_app[did] = out
    return {"byApp": by_app}


# ── launching ───────────────────────────────────────────────────────────────


def expand_exec(exec_line: str, files: list[str], *, name: str = "", icon: str = "", desktop: str = "") -> list[list[str]]:
    """argv(s) for an Exec line with field codes expanded (one process per
    file for %f / %u when several are given)."""
    argv = exec_argv(exec_line)
    uris = [Path(f).absolute().as_uri() if not urllib.parse.urlparse(f).scheme else f for f in files]
    paths = [urllib.parse.unquote(urllib.parse.urlparse(u).path) if u.startswith("file://") else u for u in uris]
    single = any(a in ("%f", "%u") for a in argv)
    runs = [[p] for p in paths] if single and len(paths) > 1 else [paths]
    runs_u = [[u] for u in uris] if single and len(uris) > 1 else [uris]
    out = []
    for ps, us in zip(runs, runs_u):
        cmd: list[str] = []
        for a in argv:
            if a == "%f":
                cmd += ps[:1]
            elif a == "%F":
                cmd += ps
            elif a == "%u":
                cmd += us[:1]
            elif a == "%U":
                cmd += us
            elif a == "%i":
                cmd += ["--icon", icon] if icon else []
            elif a == "%c":
                cmd.append(name)
            elif a == "%k":
                cmd.append(desktop)
            elif a in ("%d", "%D", "%n", "%N", "%v", "%m"):
                continue
            else:
                cmd.append(a.replace("%%", "%"))
        out.append(cmd)
    return out


def launch(desktop: Path, files: list[str], *, dry_run: bool = False) -> list[list[str]]:
    e = parse_desktop(desktop)
    if not e.get("Exec"):
        raise ValueError(f"{desktop}: no Exec")
    cmds = expand_exec(e["Exec"], files, name=e.get("Name", ""), icon=e.get("Icon", ""), desktop=str(desktop))
    if not dry_run:
        cwd = e.get("Path") or None
        for c in cmds:
            subprocess.Popen(c, cwd=cwd, start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # fmt: skip
    return cmds


def show_in_files(path: str) -> str:
    """Reveal `path` in the file manager; returns how."""
    uri = Path(path).absolute().as_uri()
    for cmd in (
        ["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1", "--object-path", "/org/freedesktop/FileManager1",
         "--method", "org.freedesktop.FileManager1.ShowItems", f"['{uri}']", ""],
        ["dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
         "org.freedesktop.FileManager1.ShowItems", f"array:string:{uri}", "string:"],
    ):  # fmt: skip
        if _have(cmd[0]):
            try:
                if subprocess.run(cmd, capture_output=True, timeout=5).returncode == 0:
                    return "FileManager1"
            except subprocess.TimeoutExpired:
                pass
    target = str(Path(path).parent)
    subprocess.Popen(["xdg-open", target], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return "xdg-open"


# ── Open at Login ───────────────────────────────────────────────────────────


def autostart_dir() -> Path:
    return config_home() / "autostart"


def _effective_autostart(did: str) -> tuple[Path | None, dict]:
    """The autostart entry that counts for `did` (user dir shadows system dirs)."""
    for d in [autostart_dir()] + [c / "autostart" for c in config_dirs()]:
        f = d / f"{did}.desktop"
        if f.is_file():
            return f, parse_desktop(f)
    return None, {}


def autostart_enabled(did: str) -> bool:
    f, e = _effective_autostart(did)
    return f is not None and e.get("Hidden", "").lower() != "true"


def autostart_list() -> dict:
    ids = set()
    for d in [autostart_dir()] + [c / "autostart" for c in config_dirs()]:
        if d.is_dir():
            ids |= {f.stem for f in d.glob("*.desktop")}
    return {"enabled": sorted(i for i in ids if autostart_enabled(i)), "dir": str(autostart_dir())}


def autostart_set(did: str, on: bool, *, source: Path | None = None) -> dict:
    """Turn "Open at Login" on or off for desktop id `did`.

    On: the user entry stops being Hidden, or a copy of the app's entry is
    written (marked X-Studio-OpenAtLogin). Off: the dock's own copy is
    removed; anyone else's entry (the user's, a system one) is shadowed with
    Hidden=true — the XDG way — so turning it back on restores it."""
    user = autostart_dir() / f"{did}.desktop"
    mine = user.is_file() and parse_desktop(user).get(MARK) == "true"
    if on:
        if autostart_enabled(did):
            return {"id": did, "enabled": True, "changed": False}
        if user.is_file() and not mine:
            # The user's own entry, hidden: unhide it.
            lines = [ln for ln in user.read_text().splitlines() if not ln.strip().startswith("Hidden=")]
            user.write_text("\n".join(lines) + "\n")
        else:
            if mine:
                # Our Hidden shadow of a system entry: dropping it may be enough.
                user.unlink()
            if not autostart_enabled(did):
                src = source or desktop_files().get(did)
                if src is None:
                    raise ValueError(f"no desktop entry for {did}")
                lines = [ln for ln in _entry_group(Path(src)) if not ln.startswith(("Hidden=", "NoDisplay=", f"{MARK}="))]
                user.parent.mkdir(parents=True, exist_ok=True)
                user.write_text("\n".join(lines + [f"{MARK}=true"]) + "\n")
    else:
        if not autostart_enabled(did):
            return {"id": did, "enabled": False, "changed": False}
        if mine:
            user.unlink()
        if autostart_enabled(did):
            if user.is_file():
                lines = [ln for ln in user.read_text().splitlines() if not ln.strip().startswith("Hidden=")]
                user.write_text("\n".join(lines + ["Hidden=true"]) + "\n")
            else:
                user.parent.mkdir(parents=True, exist_ok=True)
                user.write_text(f"[Desktop Entry]\nType=Application\nName={did}\nHidden=true\n{MARK}=true\n")
    return {"id": did, "enabled": autostart_enabled(did), "changed": True}


def _entry_group(path: Path) -> list[str]:
    """The [Desktop Entry] group's lines (actions dropped)."""
    out, group = [], None
    for line in path.read_text(errors="replace").splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            group = s[1:-1]
            if group == "Desktop Entry":
                out.append(s)
            continue
        if group == "Desktop Entry" and s and not s.startswith("Actions="):
            out.append(s)
    return out or ["[Desktop Entry]"]


def autostart_run(*, once: str | None = None, dry_run: bool = False) -> dict:
    """Start the dock's Open-at-Login entries — for sessions where nothing
    else runs XDG autostart (systemd's xdg-desktop-autostart.target does it
    when the session starts it). `once`: a key (the niri socket) so a shell
    reload doesn't start them again."""
    if once:
        rt = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
        stamp = rt / f"studio-autostart-{hashlib.sha1(once.encode()).hexdigest()[:16]}"
        if stamp.exists():
            return {"started": [], "skipped": "already ran for this session"}
        if not dry_run:
            stamp.touch()
    if _have("systemctl") and not dry_run:
        r = subprocess.run(["systemctl", "--user", "is-active", "--quiet", "xdg-desktop-autostart.target"], capture_output=True)
        if r.returncode == 0:
            return {"started": [], "skipped": "xdg-desktop-autostart.target is active"}
    started = []
    d = autostart_dir()
    for f in sorted(d.glob("*.desktop")) if d.is_dir() else []:
        e = parse_desktop(f)
        if e.get(MARK) != "true" or e.get("Hidden", "").lower() == "true" or not e.get("Exec"):
            continue
        launch(f, [], dry_run=dry_run)
        started.append(f.stem)
    return {"started": started}


# ── CLI ─────────────────────────────────────────────────────────────────────


def add_parser(top, state_dir_of) -> None:
    dock = top.add_parser("dock", help="helpers for the dock (JSON for the shell)")
    sub = dock.add_subparsers(dest="cmd", required=True)

    def out(v):
        print(json.dumps(v))

    s = sub.add_parser("apps", help="desktop entries with Exec, MIME types and WM class")
    s.add_argument("ids", nargs="*")
    s.set_defaults(fn=lambda ctx, a: out({k: v for k, v in all_apps().items() if not a.ids or k in a.ids}))

    s = sub.add_parser("recents", help="recently used files per desktop id")
    s.add_argument("--limit", type=int, default=10)
    s.set_defaults(fn=lambda ctx, a: out(recents(limit=a.limit)))

    s = sub.add_parser("folder", help="a folder's entries, sorted, with icons and thumbnails")
    s.add_argument("path", help="a path, ~/…, or xdg:DOWNLOAD / xdg:DOCUMENTS …")
    s.add_argument("--sort", choices=SORTS, default="added")
    s.add_argument("--limit", type=int, default=60)
    s.add_argument("--thumbs", type=int, default=24, help="make at most N missing thumbnails")
    s.set_defaults(fn=lambda ctx, a: out(folder(a.path, sort=a.sort, limit=a.limit, thumbs=a.thumbs, state_dir=state_dir_of(ctx))))

    s = sub.add_parser("trash", help="how many items are in the trash (--empty: empty it)")
    s.add_argument("--empty", action="store_true", help="erase everything in the home trash")
    s.set_defaults(fn=lambda ctx, a: out(trash_empty() if a.empty else trash_info()))

    s = sub.add_parser("open", help="launch a desktop entry (id or file) with files")
    s.add_argument("entry")
    s.add_argument("files", nargs="*")
    s.add_argument("--dry-run", action="store_true")

    def _open(ctx, a):
        f = Path(a.entry) if a.entry.endswith(".desktop") and "/" in a.entry else desktop_files().get(a.entry)
        if f is None:
            raise SystemExit(f"studio: no desktop entry {a.entry}")
        out({"argv": launch(f, a.files, dry_run=a.dry_run)})

    s.set_defaults(fn=_open)

    s = sub.add_parser("show", help="reveal a file (or a desktop id's .desktop file) in the file manager")
    s.add_argument("path")

    def _show(ctx, a):
        p = a.path
        if not os.path.exists(p) and (f := desktop_files().get(p)) is not None:
            p = str(f)
        out({"via": show_in_files(p), "path": p})

    s.set_defaults(fn=_show)

    s = sub.add_parser("autostart", help="Open at Login (XDG autostart)")
    asub = s.add_subparsers(dest="acmd", required=True)
    t = asub.add_parser("list")
    t.set_defaults(fn=lambda ctx, a: out(autostart_list()))
    t = asub.add_parser("set")
    t.add_argument("id")
    t.add_argument("state", choices=["on", "off"])
    t.set_defaults(fn=lambda ctx, a: out(autostart_set(a.id, a.state == "on")))
    t = asub.add_parser("run", help="start the dock's entries once per session")
    t.add_argument("--once", metavar="KEY")
    t.add_argument("--dry-run", action="store_true")
    t.set_defaults(fn=lambda ctx, a: out(autostart_run(once=a.once, dry_run=a.dry_run)))
