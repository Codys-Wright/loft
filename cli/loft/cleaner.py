"""Cleaner (`loft clean …`): reclaimable space, and clearing your own caches.

  scan       user caches (~/.cache/* one row each, browser and app caches,
             thumbnails, Electron apps' caches under ~/.config, ~/.npm/_cacache),
             the Trash, Loft's own cache, messaging-download folders with a
             retention rule, and the Nix profiles' generations (count, dates);
             plus the cached result of `store`
  store      the slow part (minutes): `nix-store --gc --print-dead` (a dry
             run, nothing is deleted) and the paths only older generations
             keep alive, summed with `nix path-info` → <state>/cache/cleaner-store.json
  clear      delete the contents of the given cache rows (ids from `scan`),
             empty the Trash, or move expired messaging downloads to the Trash
  schedule   status | set | off: a systemd *user* timer running `loft clean run`
             for user caches only (never the Nix store)
  run        what the timer runs: prune files older than N days in the
             scheduled caches, purge old Trash items, retention rules
  commands   the garbage-collection commands to run yourself (sudo for the
             system profile; Loft never runs them)

Nothing here touches the Nix store, the profiles, or anything outside your
home and Loft's state dir. LOFT_TEST_HOME replaces $HOME (and ignores the
XDG_* overrides) for everything this module lists or deletes, and keeps
`schedule` from calling systemctl — tests point it at a scratch tree.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

# ~/.cache/<name> → (label, group)
KNOWN = {
    "mozilla": ("Firefox", "Browsers"),
    "zen": ("Zen Browser", "Browsers"),
    "librewolf": ("LibreWolf", "Browsers"),
    "google-chrome": ("Google Chrome", "Browsers"),
    "chromium": ("Chromium", "Browsers"),
    "BraveSoftware": ("Brave", "Browsers"),
    "vivaldi": ("Vivaldi", "Browsers"),
    "microsoft-edge": ("Microsoft Edge", "Browsers"),
    "epiphany": ("GNOME Web", "Browsers"),
    "thumbnails": ("Thumbnails", "Thumbnails"),
    "nix": ("Nix fetcher & eval cache", "Developer"),
    "pip": ("pip", "Developer"),
    "pypoetry": ("Poetry", "Developer"),
    "uv": ("uv", "Developer"),
    "go-build": ("Go build cache", "Developer"),
    "yarn": ("Yarn", "Developer"),
    "pnpm": ("pnpm", "Developer"),
    "bun": ("Bun", "Developer"),
    "deno": ("Deno", "Developer"),
    "node-gyp": ("node-gyp", "Developer"),
    "ms-playwright": ("Playwright browsers", "Developer"),
    "cargo": ("Cargo", "Developer"),
    "sccache": ("sccache", "Developer"),
    "JetBrains": ("JetBrains IDEs", "Developer"),
    "typescript": ("TypeScript", "Developer"),
    "huggingface": ("Hugging Face models", "Developer"),
    "mesa_shader_cache": ("Mesa shader cache", "System"),
    "mesa_shader_cache_db": ("Mesa shader cache", "System"),
    "nvidia": ("NVIDIA shader cache", "System"),
    "fontconfig": ("Font cache", "System"),
    "spotify": ("Spotify", "Apps"),
    "tracker3": ("GNOME search index", "System"),
    "kioexec": ("KDE downloads", "System"),
    "cliphist": ("Clipboard history", "Keep"),
    "keepassxc": ("KeePassXC", "Keep"),
    "loft": ("Loft", "Loft"),
}
# Electron/Chromium apps keep their caches next to their data in ~/.config/<app>/.
ELECTRON_CACHES = ("Cache", "Code Cache", "GPUCache", "DawnCache", "DawnWebGPUCache", "DawnGraphiteCache", "Service Worker/CacheStorage", "CachedData", "CachedExtensionVSIXs")
ELECTRON_NAMES = {"Code": "VS Code", "VSCodium": "VSCodium", "discord": "Discord", "Slack": "Slack", "obsidian": "Obsidian", "Signal": "Signal", "Element": "Element", "spotify": "Spotify", "teams-for-linux": "Teams", "Cursor": "Cursor", "zed": "Zed"}
# Messaging apps' download folders (retention rules default to these when they exist).
MESSAGING_DEFAULTS = ["~/Downloads/Telegram Desktop", "~/Downloads/WhatsApp", "~/Downloads/Signal", "~/Downloads/Discord"]


# ── environment ─────────────────────────────────────────────────────────────


def test_home() -> Path | None:
    v = os.environ.get("LOFT_TEST_HOME")
    return Path(v) if v else None


def home() -> Path:
    return test_home() or Path(os.environ.get("HOME") or Path.home())


def _xdg(var: str, rel: str) -> Path:
    if test_home() is None and os.environ.get(var):
        return Path(os.environ[var])
    return home() / rel


def cache_home() -> Path:
    return _xdg("XDG_CACHE_HOME", ".cache")


def config_home() -> Path:
    return _xdg("XDG_CONFIG_HOME", ".config")


def data_home() -> Path:
    return _xdg("XDG_DATA_HOME", ".local/share")


def state_home() -> Path:
    return _xdg("XDG_STATE_HOME", ".local/state")


def config_file() -> Path:
    return config_home() / "loft" / "cleaner.json"


DEFAULT_CONFIG = {"schedule": None, "retention": []}


def load_config() -> dict:
    try:
        c = json.loads(config_file().read_text())
    except (OSError, json.JSONDecodeError):
        c = {}
    return {**DEFAULT_CONFIG, **c}


def save_config(c: dict) -> None:
    f = config_file()
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(c, indent=2) + "\n")
    tmp.replace(f)


def expand(p: str) -> Path:
    return home() / p[2:] if p.startswith("~/") else Path(p)


def tilde(p: Path) -> str:
    h = str(home())
    s = str(p)
    return "~" + s[len(h) :] if s.startswith(h + "/") else s


# ── sizes ───────────────────────────────────────────────────────────────────


def du(path: Path, older_than: float | None = None) -> tuple[int, int]:
    """(bytes on disk, files) under path, without following symlinks;
    with older_than (a timestamp), only files modified before it."""
    total = files = 0
    stack = [str(path)]
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                elif older_than is None or st.st_mtime < older_than:
                    total += st.st_blocks * 512
                    files += 1
    return total, files


# ── scan ────────────────────────────────────────────────────────────────────


def _rows_caches(state_dir: Path) -> list[dict]:
    rows = []
    ch = cache_home()
    try:
        entries = sorted(ch.iterdir()) if ch.is_dir() else []
    except OSError:
        entries = []
    for e in entries:
        if e.is_symlink():
            continue
        label, group = KNOWN.get(e.name, (e.name, "Apps"))
        if e.name.startswith(("google-chrome", "chromium")):
            label, group = KNOWN.get(e.name.split("-beta")[0], (e.name, "Browsers"))
        rows.append({"id": f"cache:{e.name}", "label": label, "group": group, "path": str(e), "kind": "contents" if e.is_dir() else "file"})
    cfg = config_home()
    if cfg.is_dir():
        for app in sorted(cfg.iterdir()):
            if app.is_symlink() or not app.is_dir():
                continue
            parts = [app / c for c in ELECTRON_CACHES if (app / c).is_dir() and not (app / c).is_symlink()]
            if parts:
                rows.append({
                    "id": f"electron:{app.name}",
                    "label": f"{ELECTRON_NAMES.get(app.name, app.name)} (app cache)",
                    "group": "Browsers" if app.name in ("google-chrome", "chromium", "BraveSoftware") else "Apps",
                    "path": str(app),
                    "paths": [str(p) for p in parts],
                    "kind": "contents",
                })
    npm = home() / ".npm" / "_cacache"
    if npm.is_dir():
        rows.append({"id": "npm", "label": "npm", "group": "Developer", "path": str(npm), "kind": "contents"})
    own = state_dir / "cache"
    if own.is_dir():
        rows.append({"id": "loft", "label": "Loft (thumbnails, wallpaper samples, update summaries)", "group": "Loft", "path": str(own), "kind": "contents"})
    trash = data_home() / "Trash"
    if trash.is_dir():
        rows.append({"id": "trash", "label": "Trash", "group": "Trash", "path": str(trash), "kind": "trash"})
    return rows


def _measure(row: dict) -> dict:
    paths = [Path(p) for p in row.get("paths", [row["path"]])]
    size = files = 0
    for p in paths:
        if row["kind"] == "file":
            try:
                st = p.stat(follow_symlinks=False)
                size, files = size + st.st_blocks * 512, files + 1
            except OSError:
                pass
        else:
            b, n = du(p)
            size, files = size + b, files + n
    if row["kind"] == "trash":
        try:
            files = sum(1 for _ in (Path(row["path"]) / "files").iterdir())
        except OSError:
            files = 0
    return {**row, "bytes": size, "files": files}


def generations() -> list[dict]:
    """Every Nix profile's generations: count, current, dates (read-only)."""
    user = os.environ.get("USER") or ""
    sh = state_home() / "nix" / "profiles"
    profiles = [
        ("system", "NixOS system", Path("/nix/var/nix/profiles"), "system", True),
        ("profile", "User profile (nix profile / nix-env)", sh, "profile", False),
        ("home-manager", "Home Manager", sh, "home-manager", False),
    ]
    legacy = Path("/nix/var/nix/profiles/per-user") / user
    out = []
    for pid, label, d, name, root in profiles:
        if not (d / name).is_symlink() and pid != "system" and (legacy / name).is_symlink():
            d = legacy
        link = d / name
        if not link.is_symlink():
            continue
        try:
            cur = int(os.readlink(link).rsplit("-", 2)[-2])
        except (OSError, ValueError, IndexError):
            cur = None
        gens = []
        try:
            for e in os.scandir(d):
                n = e.name
                if n.startswith(name + "-") and n.endswith("-link"):
                    num = n[len(name) + 1 : -5]
                    if num.isdigit():
                        gens.append((int(num), e.stat(follow_symlinks=False).st_mtime))
        except OSError:
            continue
        gens.sort()
        older = [g for g in gens if g[0] != cur]
        out.append({
            "id": pid,
            "label": label,
            "profile": str(link),
            "needsRoot": root,
            "count": len(gens),
            "current": cur,
            "older": len(older),
            "oldest": int(gens[0][1]) if gens else None,
            "newest": int(gens[-1][1]) if gens else None,
            "olderDates": [int(t) for _, t in older[-3:]],
        })
    return out


def store_cache_file(state_dir: Path) -> Path:
    return state_dir / "cache" / "cleaner-store.json"


def retention_rows(cfg: dict) -> list[dict]:
    rows = []
    for i, r in enumerate(cfg.get("retention") or []):
        p = expand(r["path"])
        days = int(r.get("days", 30))
        b, n = du(p, older_than=time.time() - days * 86400) if p.is_dir() else (0, 0)
        tb, tn = du(p) if p.is_dir() else (0, 0)
        rows.append({"id": f"retention:{i}", "path": r["path"], "days": days, "exists": p.is_dir(), "bytes": b, "files": n, "totalBytes": tb, "totalFiles": tn})
    return rows


def suggest_retention() -> list[str]:
    return [p for p in MESSAGING_DEFAULTS if expand(p).is_dir()]


def scan(state_dir: Path) -> dict:
    rows = _rows_caches(state_dir)
    with ThreadPoolExecutor(max_workers=6) as ex:
        rows = list(ex.map(_measure, rows))
    rows.sort(key=lambda r: -r["bytes"])
    cfg = load_config()
    try:
        store = json.loads(store_cache_file(state_dir).read_text())
    except (OSError, json.JSONDecodeError):
        store = None
    return {
        "home": str(home()),
        "testHome": test_home() is not None,
        "scannedAt": int(time.time()),
        "caches": rows,
        "cacheBytes": sum(r["bytes"] for r in rows if r["group"] not in ("Keep",)),
        "generations": generations(),
        "store": store,
        "retention": retention_rows(cfg),
        "suggestedRetention": [p for p in suggest_retention() if p not in [r["path"] for r in cfg.get("retention") or []]],
        "schedule": cfg.get("schedule"),
        "commands": gc_commands(),
    }


# ── the Nix store (slow, read-only) ─────────────────────────────────────────


def _narsizes(paths: list[str]) -> int:
    if not paths:
        return 0
    r = subprocess.run(["nix", "path-info", "--json", "--stdin"], input="\n".join(paths), capture_output=True, text=True)
    try:
        d = json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return 0
    vals = d.values() if isinstance(d, dict) else d
    return sum((v or {}).get("narSize", 0) for v in vals)


def _closure(roots: list[str]) -> set[str]:
    if not roots:
        return set()
    r = subprocess.run(["nix-store", "-q", "--requisites", *roots], capture_output=True, text=True)
    return set(r.stdout.split())


def store_scan(state_dir: Path) -> dict:
    t0 = time.time()
    print(json.dumps({"stage": "finding dead store paths (nix-store --gc --print-dead, a dry run)"}), flush=True)
    r = subprocess.run(["nix-store", "--gc", "--print-dead"], capture_output=True, text=True)
    dead = [l for l in r.stdout.split() if l.startswith("/nix/store/")]
    print(json.dumps({"stage": "measuring", "dead": len(dead)}), flush=True)
    dead_bytes = _narsizes(dead)
    # What older generations alone keep alive: their closures minus every
    # current generation's.
    gens = {}
    for g in generations():
        d = Path(g["profile"]).parent
        name = Path(g["profile"]).name
        targets = []
        for e in os.scandir(d):
            if e.name.startswith(name + "-") and e.name.endswith("-link"):
                try:
                    targets.append((e.name, os.path.realpath(e.path)))
                except OSError:
                    pass
        cur = os.path.realpath(g["profile"])
        older = sorted({t for _, t in targets if t != cur})
        gens[g["id"]] = {"current": cur, "older": older}
    current_roots = [v["current"] for v in gens.values()]
    keep = _closure(current_roots)
    held = {}
    for gid, v in gens.items():
        only = _closure(v["older"]) - keep if v["older"] else set()
        held[gid] = {"paths": len(only), "bytes": _narsizes(sorted(only))}
    out = {
        "checkedAt": int(time.time()),
        "seconds": round(time.time() - t0, 1),
        "deadPaths": len(dead),
        "deadBytes": dead_bytes,
        "heldByOlderGenerations": held,
        "error": None if r.returncode == 0 else (r.stderr.strip().splitlines() or ["nix-store failed"])[-1],
    }
    f = store_cache_file(state_dir)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(out, indent=1))
    return out


def gc_commands() -> list[dict]:
    nh = shutil.which("nh") is not None
    cmds = [
        {"label": "Delete your old profile generations (14 days) and collect garbage", "command": "nix-collect-garbage --delete-older-than 14d", "sudo": False},
        {"label": "Also the system's generations (needs sudo; boot entries for them go away)", "command": "sudo nix-collect-garbage --delete-older-than 14d", "sudo": True},
        {"label": "Just collect garbage (keeps every generation)", "command": "nix-store --gc", "sudo": False},
    ]
    if nh:
        cmds.insert(0, {"label": "nh: keep the last 5 generations of everything, collect garbage", "command": "nh clean all --keep 5", "sudo": True})
    return cmds


# ── clearing ────────────────────────────────────────────────────────────────


def _inside(p: Path, roots: list[Path]) -> bool:
    try:
        rp = p.resolve()
    except OSError:
        return False
    return any(rp == r.resolve() or r.resolve() in rp.parents for r in roots)


def _remove(p: Path) -> tuple[int, int]:
    """Delete p (never following symlinks); (bytes freed, failures)."""
    try:
        st = p.lstat()
    except OSError:
        return 0, 0
    if p.is_dir() and not p.is_symlink():
        b, _ = du(p)
        errors = []
        shutil.rmtree(p, onerror=lambda f, path, exc: errors.append(path))
        return (b if not errors else max(0, b - du(p)[0])), len(errors)
    try:
        p.unlink()
        return st.st_blocks * 512, 0
    except OSError:
        return 0, 1


def _clear_contents(d: Path, older_than: float | None = None) -> tuple[int, int, int]:
    """Delete what's inside d (with older_than: only files modified before it,
    then empty folders). (bytes, items, failures)."""
    freed = items = fails = 0
    if not d.is_dir() or d.is_symlink():
        return 0, 0, 0
    if older_than is None:
        for c in list(d.iterdir()):
            b, f = _remove(c)
            freed, items, fails = freed + b, items + 1, fails + f
        return freed, items, fails
    for root, dirs, files in os.walk(d, topdown=False):
        for f in files:
            p = Path(root) / f
            try:
                st = p.lstat()
            except OSError:
                continue
            if st.st_mtime < older_than:
                try:
                    p.unlink()
                    freed, items = freed + st.st_blocks * 512, items + 1
                except OSError:
                    fails += 1
        if Path(root) != d:
            try:
                os.rmdir(root)  # only when now empty
            except OSError:
                pass
    return freed, items, fails


def trash_file(p: Path) -> bool:
    """Move p to the home Trash (freedesktop trash spec)."""
    t = data_home() / "Trash"
    (t / "files").mkdir(parents=True, exist_ok=True)
    (t / "info").mkdir(parents=True, exist_ok=True)
    name = p.name
    i = 1
    while (t / "files" / name).exists() or (t / "info" / f"{name}.trashinfo").exists():
        name = f"{p.stem}.{i}{p.suffix}"
        i += 1
    info = f"[Trash Info]\nPath={urllib.parse.quote(str(p.absolute()))}\nDeletionDate={datetime.now().strftime('%Y-%m-%dT%H:%M:%S')}\n"
    (t / "info" / f"{name}.trashinfo").write_text(info)
    try:
        shutil.move(str(p), t / "files" / name)
    except OSError:
        (t / "info" / f"{name}.trashinfo").unlink(missing_ok=True)
        return False
    return True


def empty_trash(older_than: float | None = None) -> tuple[int, int, int]:
    t = data_home() / "Trash"
    freed = items = fails = 0
    info = t / "info"
    if older_than is None:
        for sub in ("files", "info", "expunged"):
            b, n, f = _clear_contents(t / sub)
            freed, fails = freed + b, fails + f
            if sub == "files":
                items = n
        try:
            (t / "directorysizes").unlink()
        except OSError:
            pass
        return freed, items, fails
    if not info.is_dir():
        return 0, 0, 0
    for ti in info.glob("*.trashinfo"):
        date = None
        for line in ti.read_text(errors="replace").splitlines():
            if line.startswith("DeletionDate="):
                try:
                    date = datetime.fromisoformat(line.split("=", 1)[1]).timestamp()
                except ValueError:
                    pass
        if date is not None and date < older_than:
            b, f = _remove(t / "files" / ti.name[: -len(".trashinfo")])
            ti.unlink(missing_ok=True)
            freed, items, fails = freed + b, items + 1, fails + f
    return freed, items, fails


def retention_apply(rule: dict) -> tuple[int, int, int]:
    """Move files older than the rule's days to the Trash."""
    d = expand(rule["path"])
    if not d.is_dir() or d.is_symlink() or not _inside(d, [home()]):
        return 0, 0, 0
    cutoff = time.time() - int(rule.get("days", 30)) * 86400
    freed = items = fails = 0
    for e in list(d.iterdir()):
        try:
            st = e.lstat()
        except OSError:
            continue
        newest = st.st_mtime
        if e.is_dir() and not e.is_symlink():
            for root, _, files in os.walk(e):
                for f in files:
                    try:
                        newest = max(newest, (Path(root) / f).lstat().st_mtime)
                    except OSError:
                        pass
        if newest >= cutoff:
            continue
        b = du(e)[0] if e.is_dir() else st.st_blocks * 512
        if trash_file(e):
            freed, items = freed + b, items + 1
        else:
            fails += 1
    return freed, items, fails


def clear(ids: list[str], state_dir: Path, older_than_days: int | None = None) -> dict:
    rows = {r["id"]: r for r in _rows_caches(state_dir)}
    cfg = load_config()
    roots = [home(), state_dir]
    cutoff = time.time() - older_than_days * 86400 if older_than_days else None
    results = []
    # group:<Group> = every row of that group (the schedule stores groups, so
    # caches that appear later are included).
    expanded: list[str] = []
    for i in ids:
        if i.startswith("group:"):
            expanded += [r["id"] for r in rows.values() if r["group"] == i[6:] and r["group"] != "Keep"]
        elif i not in expanded:
            expanded.append(i)
    for i in expanded:
        if i.startswith("retention:"):
            try:
                rule = (cfg.get("retention") or [])[int(i.split(":", 1)[1])]
            except (ValueError, IndexError):
                results.append({"id": i, "error": "no such rule"})
                continue
            b, n, f = retention_apply(rule)
            results.append({"id": i, "bytes": b, "items": n, "failed": f, "action": "trashed"})
            continue
        row = rows.get(i)
        if row is None:
            results.append({"id": i, "error": "unknown id (scan again)"})
            continue
        if row["group"] == "Keep":
            results.append({"id": i, "error": "kept on purpose (clear it from its app)"})
            continue
        if row["kind"] == "trash":
            b, n, f = empty_trash(cutoff)
        else:
            b = n = f = 0
            for p in [Path(x) for x in row.get("paths", [row["path"]])]:
                if not _inside(p, roots) or p.is_symlink():
                    f += 1
                    continue
                if row["kind"] == "file":
                    if cutoff is None or p.lstat().st_mtime < cutoff:
                        bb, ff = _remove(p)
                        b, n, f = b + bb, n + 1, f + ff
                else:
                    bb, nn, ff = _clear_contents(p, cutoff)
                    b, n, f = b + bb, n + nn, f + ff
        results.append({"id": i, "bytes": b, "items": n, "failed": f, "action": "deleted"})
    return {"results": results, "bytes": sum(r.get("bytes", 0) for r in results)}


# ── schedule (systemd user timer, user caches only) ─────────────────────────

UNIT = "loft-cleaner"


def _units_dir() -> Path:
    return config_home() / "systemd" / "user"


def _loft_exe() -> str:
    return shutil.which("loft") or "loft"


def schedule_set(every: str, older_than: int, categories: list[str], trash_days: int | None, retention: bool) -> dict:
    cfg = load_config()
    cfg["schedule"] = {"every": every, "olderThanDays": older_than, "categories": categories, "trashDays": trash_days, "retention": retention}
    save_config(cfg)
    d = _units_dir()
    d.mkdir(parents=True, exist_ok=True)
    env = f"Environment=LOFT_TEST_HOME={test_home()}\n" if test_home() else ""
    (d / f"{UNIT}.service").write_text(
        "[Unit]\nDescription=Loft Cleaner: prune old user caches\n\n"
        f"[Service]\nType=oneshot\n{env}ExecStart={_loft_exe()} clean run\nNice=19\nIOSchedulingClass=idle\n"
    )
    (d / f"{UNIT}.timer").write_text(
        f"[Unit]\nDescription=Loft Cleaner ({every})\n\n"
        f"[Timer]\nOnCalendar={every}\nPersistent=true\nRandomizedDelaySec=30min\n\n[Install]\nWantedBy=timers.target\n"
    )
    return {**schedule_status(), "systemctl": _systemctl(["daemon-reload"], ["enable", "--now", f"{UNIT}.timer"])}


def schedule_off() -> dict:
    cfg = load_config()
    cfg["schedule"] = None
    save_config(cfg)
    sc = _systemctl(["disable", "--now", f"{UNIT}.timer"])
    for s in ("service", "timer"):
        (_units_dir() / f"{UNIT}.{s}").unlink(missing_ok=True)
    sc2 = _systemctl(["daemon-reload"])
    return {**schedule_status(), "systemctl": sc + sc2}


def _systemctl(*cmds: list[str]) -> list[str]:
    out = []
    for c in cmds:
        argv = ["systemctl", "--user", *c]
        if test_home() is not None:
            out.append("skipped (LOFT_TEST_HOME): " + " ".join(argv))
            continue
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=30)
            out.append(" ".join(argv) + (" ✓" if r.returncode == 0 else f" ✗ {r.stderr.strip()}"))
        except (OSError, subprocess.TimeoutExpired) as e:
            out.append(" ".join(argv) + f" ✗ {e}")
    return out


def schedule_status() -> dict:
    cfg = load_config()
    units = _units_dir()
    return {
        "schedule": cfg.get("schedule"),
        "unitFiles": [str(units / f"{UNIT}.{s}") for s in ("service", "timer") if (units / f"{UNIT}.{s}").exists()],
        "lastRun": cfg.get("lastRun"),
    }


def run_scheduled(state_dir: Path) -> dict:
    cfg = load_config()
    s = cfg.get("schedule") or {}
    days = int(s.get("olderThanDays") or 30)
    res = clear(list(s.get("categories") or []), state_dir, older_than_days=days)
    if s.get("trashDays"):
        b, n, f = empty_trash(time.time() - int(s["trashDays"]) * 86400)
        res["results"].append({"id": "trash", "bytes": b, "items": n, "failed": f, "action": "purged"})
    if s.get("retention"):
        for i, rule in enumerate(cfg.get("retention") or []):
            b, n, f = retention_apply(rule)
            res["results"].append({"id": f"retention:{i}", "bytes": b, "items": n, "failed": f, "action": "trashed"})
    res["bytes"] = sum(r.get("bytes", 0) for r in res["results"])
    cfg["lastRun"] = {"at": int(time.time()), "bytes": res["bytes"]}
    save_config(cfg)
    return res


# ── CLI ─────────────────────────────────────────────────────────────────────


def add_parser(top, state_dir_of) -> None:
    cl = top.add_parser("clean", help="reclaimable space: caches, Trash, Nix generations and garbage (JSON)")
    sub = cl.add_subparsers(dest="cmd", required=True)

    def out(v):
        print(json.dumps(v))

    s = sub.add_parser("scan", help="caches, Trash, retention rules and generations, with sizes")
    s.set_defaults(fn=lambda ctx, a: out(scan(state_dir_of(ctx))))

    s = sub.add_parser("store", help="dead store paths and what older generations hold (slow, read-only)")
    s.set_defaults(fn=lambda ctx, a: out(store_scan(state_dir_of(ctx))))

    s = sub.add_parser("clear", help="delete the contents of cache rows (ids from scan)")
    s.add_argument("ids", nargs="+")
    s.add_argument("--older-than", type=int, metavar="DAYS", help="only files not modified for DAYS")
    s.add_argument("--yes", action="store_true", help="required: this deletes files")

    def _clear(ctx, a):
        if not a.yes:
            raise SystemExit("loft: clean clear deletes files; pass --yes")
        out(clear(a.ids, state_dir_of(ctx), a.older_than))

    s.set_defaults(fn=_clear)

    s = sub.add_parser("retention", help="messaging-download retention rules")
    rsub = s.add_subparsers(dest="rcmd", required=True)
    t = rsub.add_parser("set", help="add or change a rule: files older than DAYS go to the Trash")
    t.add_argument("path")
    t.add_argument("days", type=int)

    def _rset(ctx, a):
        cfg = load_config()
        rules = [r for r in cfg.get("retention") or [] if r["path"] != a.path]
        rules.append({"path": a.path, "days": a.days})
        cfg["retention"] = rules
        save_config(cfg)
        out(retention_rows(cfg))

    t.set_defaults(fn=_rset)
    t = rsub.add_parser("remove")
    t.add_argument("path")

    def _rrm(ctx, a):
        cfg = load_config()
        cfg["retention"] = [r for r in cfg.get("retention") or [] if r["path"] != a.path]
        save_config(cfg)
        out(retention_rows(cfg))

    t.set_defaults(fn=_rrm)

    s = sub.add_parser("schedule", help="a systemd user timer that prunes user caches")
    ssub = s.add_subparsers(dest="scmd", required=True)
    ssub.add_parser("status").set_defaults(fn=lambda ctx, a: out(schedule_status()))
    t = ssub.add_parser("set")
    t.add_argument("--every", choices=["daily", "weekly", "monthly"], default="weekly")
    t.add_argument("--older-than", type=int, default=30, metavar="DAYS")
    t.add_argument("--categories", default="", help="comma-separated scan ids")
    t.add_argument("--trash-days", type=int, help="also purge Trash items deleted DAYS ago")
    t.add_argument("--retention", action="store_true", help="also apply the retention rules")
    t.set_defaults(fn=lambda ctx, a: out(schedule_set(a.every, a.older_than, [c for c in a.categories.split(",") if c], a.trash_days, a.retention)))
    ssub.add_parser("off").set_defaults(fn=lambda ctx, a: out(schedule_off()))

    s = sub.add_parser("run", help="what the timer runs")
    s.set_defaults(fn=lambda ctx, a: out(run_scheduled(state_dir_of(ctx))))

    s = sub.add_parser("commands", help="garbage-collection commands to run yourself")
    s.set_defaults(fn=lambda ctx, a: out(gc_commands()))
