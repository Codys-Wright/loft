"""Flake update summary (`loft updates …`): NixOS's "App updates".

  check  copy the system flake's tracked files into a scratch dir, run
         `nix flake update --output-lock-file` THERE (the real flake and its
         lock are only read), then compare the two locks: every direct input
         with old → new revision and date, the commit count between them
         (GitHub compare API, through `gh` when it is logged in), the nixpkgs
         version, and — when nixpkgs moved — the version bumps of the
         installed packages (system + home-manager profile) whose names are
         nixpkgs attributes. Nothing is built or switched. The result is cached
         in <state>/cache/updates.json, which the shell watches.
  show   the cached result
  diff   compare two lock files (no network, no nix): what `check` does after
         updating; for tests and for comparing by hand

Applying the update is up to you: the result carries the commands
(`just update && just switch` when the flake has a justfile with those
recipes, else `nix flake update` + `nixos-rebuild switch`).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def default_flake() -> Path | None:
    env = os.environ.get("LOFT_FLAKE")
    cands = [Path(env).expanduser()] if env else []
    cands += [Path.home() / ".flake", Path("/etc/nixos")]
    for c in cands:
        if (c / "flake.nix").is_file():
            return c
    return None


def cache_file(state_dir: Path) -> Path:
    return state_dir / "cache" / "updates.json"


def stage(msg: str, **kw) -> None:
    print(json.dumps({"stage": msg, **kw}), flush=True)


# ── lock files ──────────────────────────────────────────────────────────────

TARBALL_NAME = re.compile(r"/([a-z][a-z0-9-]*?)-(\d[\w.]*?)\.([0-9a-f]{7,40})/[^/]*$")


def describe(node: dict) -> dict:
    """A lock node → { type, source, rev, date, ref, version, github: (owner, repo) }."""
    lk = node.get("locked", {})
    orig = node.get("original", {})
    t = lk.get("type", "")
    out = {
        "type": t,
        "rev": lk.get("rev"),
        "narHash": lk.get("narHash"),
        "date": lk.get("lastModified"),
        "ref": orig.get("ref") or lk.get("ref"),
        "version": None,
        "github": None,
    }
    if t in ("github", "gitlab", "sourcehut"):
        out["source"] = f"{t}:{lk.get('owner')}/{lk.get('repo')}"
        if t == "github":
            out["github"] = [lk.get("owner"), lk.get("repo")]
    elif t == "git":
        url = lk.get("url", "")
        out["source"] = url
        m = re.search(r"github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$", url)
        if m:
            out["github"] = [m.group(1), m.group(2)]
    elif t == "tarball" or t == "file":
        url = lk.get("url", "")
        out["source"] = url
        # https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1080803.419fe0f449b3/nixexprs.tar.zst
        m = TARBALL_NAME.search(url)
        if m:
            out["version"] = m.group(2)
            out["rev"] = out["rev"] or m.group(3)
            if m.group(1) in ("nixpkgs", "nixos"):
                out["github"] = ["NixOS", "nixpkgs"]
    elif t == "path":
        out["source"] = lk.get("path", "")
    else:
        out["source"] = lk.get("url") or t
    return out


def _resolve(lock: dict, ref) -> str | None:
    """An input reference (node key, or a `follows` path) → node key."""
    if isinstance(ref, str):
        return ref
    node = lock["root"]
    for name in ref:
        nxt = lock["nodes"][node].get("inputs", {}).get(name)
        if nxt is None:
            return None
        node = _resolve(lock, nxt)
        if node is None:
            return None
    return node


def compare_locks(old: dict, new: dict) -> dict:
    """Direct inputs old → new, plus how many indirect nodes changed."""
    root_old = old["nodes"][old["root"]].get("inputs", {})
    root_new = new["nodes"][new["root"]].get("inputs", {})
    inputs = []
    for name in sorted(set(root_old) | set(root_new)):
        ko = _resolve(old, root_old[name]) if name in root_old else None
        kn = _resolve(new, root_new[name]) if name in root_new else None
        o = describe(old["nodes"][ko]) if ko else None
        n = describe(new["nodes"][kn]) if kn else None
        follows = not isinstance(root_new.get(name, root_old.get(name)), str)
        changed = (o or {}).get("narHash") != (n or {}).get("narHash") or (o or {}).get("rev") != (n or {}).get("rev")
        inputs.append({"name": name, "old": o, "new": n, "changed": changed and not follows, "follows": follows})
    direct = {v for v in root_new.values() if isinstance(v, str)}
    indirect = 0
    for key, node in new["nodes"].items():
        if key == new["root"] or key in direct:
            continue
        on = old["nodes"].get(key)
        if on is None or on.get("locked", {}).get("narHash") != node.get("locked", {}).get("narHash"):
            indirect += 1
    return {"inputs": inputs, "indirectChanged": indirect}


# ── GitHub ──────────────────────────────────────────────────────────────────


def commits_between(owner: str, repo: str, old: str, new: str, timeout: float = 20) -> dict:
    """{ commits, url } between two revisions (commits: None when unknown)."""
    url = f"https://github.com/{owner}/{repo}/compare/{old}...{new}"
    api = f"repos/{owner}/{repo}/compare/{old}...{new}"
    if shutil.which("gh"):
        try:
            r = subprocess.run(["gh", "api", api, "--jq", ".total_commits"], capture_output=True, text=True, timeout=timeout)
            if r.returncode == 0 and r.stdout.strip().isdigit():
                return {"commits": int(r.stdout.strip()), "url": url}
        except (OSError, subprocess.TimeoutExpired):
            pass
    try:
        req = urllib.request.Request(f"https://api.github.com/{api}", headers={"Accept": "application/vnd.github+json", "User-Agent": "loft-updates"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return {"commits": json.load(r).get("total_commits"), "url": url}
    except Exception:
        return {"commits": None, "url": url}


# ── packages ────────────────────────────────────────────────────────────────

VERSION_START = re.compile(r"-(?=\d)")
# Multiple-output store paths: firefox-142.0-man, acl-2.4.0-bin.
OUTPUT_SUFFIX = re.compile(r"(-(bin|man|dev|lib|doc|devdoc|info|out|debug|udev|static|terminfo|py|data))+$")


def parse_name(store_path: str) -> tuple[str, str] | None:
    """/nix/store/<hash>-firefox-142.0.1 → ("firefox", "142.0.1"), like builtins.parseDrvName."""
    base = Path(store_path).name
    if len(base) < 34 or base[32] != "-":
        return None
    name = base[33:]
    m = VERSION_START.search(name)
    if not m:
        return None
    version = OUTPUT_SUFFIX.sub("", name[m.end() :])
    return name[: m.start()], version


def installed_packages() -> dict[str, str]:
    """pname → version of the system's and the home-manager profile's packages."""
    roots = ["/run/current-system/sw"]
    hm = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "nix/profiles/home-manager/home-path"
    if hm.exists():
        roots.append(str(hm))
    pkgs: dict[str, str] = {}
    for r in roots:
        try:
            out = subprocess.run(["nix-store", "-q", "--references", r], capture_output=True, text=True, timeout=60).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        for line in out.split():
            p = parse_name(line)
            if p and not p[0].endswith(("-man", "-doc", "-info", "-dev")):
                pkgs.setdefault(p[0], p[1])
    return pkgs


def _fetch_attrs(node: dict) -> dict:
    lk = node.get("locked", {})
    keep = ("type", "owner", "repo", "rev", "url", "narHash", "ref", "host")
    return {k: lk[k] for k in keep if k in lk}


NIX_PKG_VERSIONS = """
let
  src = builtins.fetchTree (builtins.fromJSON (builtins.readFile {lock}));
  names = builtins.fromJSON (builtins.readFile {names});
  pkgs = import src { system = builtins.currentSystem; config = { allowUnfree = true; allowAliases = false; }; overlays = []; };
  ver = n: let v = (pkgs.${n}.version or null); r = builtins.tryEval (builtins.deepSeq v v); in if r.success then r.value else null;
in { lib = (import (src + "/lib")).version; versions = builtins.listToAttrs (map (n: { name = n; value = ver n; }) names); }
"""


def nixpkgs_versions(node: dict, names: list[str], tmp: Path, timeout: float = 240) -> dict | None:
    lock = tmp / "nixpkgs-src.json"
    lock.write_text(json.dumps(_fetch_attrs(node)))
    nf = tmp / "names.json"
    nf.write_text(json.dumps(names))
    expr = NIX_PKG_VERSIONS.replace("{lock}", str(lock)).replace("{names}", str(nf))
    try:
        r = subprocess.run(["nix", "eval", "--impure", "--json", "--expr", expr], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return {"error": r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "nix eval failed"}
    return json.loads(r.stdout)


def version_key(v: str):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.\-+_]", v)]


def package_bumps(installed: dict[str, str], available: dict[str, str | None]) -> list[dict]:
    out = []
    for name, have in sorted(installed.items()):
        new = available.get(name)
        if not isinstance(new, str) or not new or new == have:
            continue
        try:
            kind = "downgrade" if version_key(new) < version_key(have) else "upgrade"
        except TypeError:
            kind = "change"
        # A "downgrade" is nearly always two packages sharing a name (KDE's
        # ark 26.08 vs nixpkgs' ark 0.1): not worth showing.
        if kind != "downgrade":
            out.append({"name": name, "from": have, "to": new, "kind": kind})
    return out


# ── the check ───────────────────────────────────────────────────────────────


def copy_flake(src: Path, dst: Path) -> int:
    """The flake's git-tracked files (what nix sees) into dst; a plain copy without git."""
    dst.mkdir(parents=True, exist_ok=True)
    files: list[str]
    try:
        r = subprocess.run(["git", "-C", str(src), "ls-files", "-z"], capture_output=True, timeout=60)
        files = [f for f in r.stdout.decode().split("\0") if f] if r.returncode == 0 else []
    except OSError:
        files = []
    if not files:
        shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".git", "result", "result-*"))
        return sum(1 for _ in dst.rglob("*"))
    n = 0
    for f in files:
        s = src / f
        if not (s.exists() or s.is_symlink()):
            continue  # deleted in the working tree
        d = dst / f
        d.parent.mkdir(parents=True, exist_ok=True)
        if s.is_symlink():
            os.symlink(os.readlink(s), d)
        else:
            shutil.copy2(s, d)
        n += 1
    return n


def update_commands(flake: Path) -> list[str]:
    jf = flake / "justfile"
    if jf.is_file():
        text = jf.read_text(errors="replace")
        if re.search(r"^update\s*:", text, re.M) and re.search(r"^switch\s*:", text, re.M):
            return [f"cd {_tilde(flake)}", "just update", "just switch"]
    if shutil.which("nh"):
        return [f"nh os switch --update {_tilde(flake)}"]
    return [f"nix flake update --flake {_tilde(flake)}", f"sudo nixos-rebuild switch --flake {_tilde(flake)}"]


def _tilde(p: Path) -> str:
    h = str(Path.home())
    s = str(p)
    return "~" + s[len(h) :] if s == h or s.startswith(h + "/") else s


def summarize(old: dict, new: dict, flake: Path, *, commits: bool = True, packages: bool = True, tmp: Path | None = None, progress=None) -> dict:
    progress = progress or (lambda *a, **k: None)
    res = compare_locks(old, new)
    changed = [i for i in res["inputs"] if i["changed"] and i["old"] and i["new"]]
    if commits:
        progress("comparing revisions", count=len(changed))

        def job(i):
            o, n = i["old"], i["new"]
            if o.get("github") and o.get("rev") and n.get("rev"):
                return commits_between(*o["github"], o["rev"], n["rev"])
            return {"commits": None, "url": None}

        with ThreadPoolExecutor(max_workers=8) as ex:
            for i, c in zip(changed, ex.map(job, changed)):
                i.update(c)
    out = {
        "flake": str(flake),
        "checkedAt": int(time.time()),
        "inputs": res["inputs"],
        "changedCount": len(changed),
        "indirectChanged": res["indirectChanged"],
        "nixpkgs": None,
        "packages": [],
        "packagesNote": "",
        "commands": update_commands(flake),
    }
    np_old = old["nodes"].get(_resolve(old, old["nodes"][old["root"]]["inputs"].get("nixpkgs", "")) or "")
    np_new = new["nodes"].get(_resolve(new, new["nodes"][new["root"]]["inputs"].get("nixpkgs", "")) or "")
    if np_old and np_new:
        do, dn = describe(np_old), describe(np_new)
        out["nixpkgs"] = {"old": do.get("version"), "new": dn.get("version"), "changed": do.get("narHash") != dn.get("narHash")}
        if packages and out["nixpkgs"]["changed"] and tmp is not None:
            progress("evaluating package versions in the new nixpkgs")
            inst = installed_packages()
            ev = nixpkgs_versions(np_new, sorted(inst), tmp)
            if ev is None or "error" in ev:
                out["packagesNote"] = f"couldn't evaluate the new nixpkgs: {(ev or {}).get('error', 'timed out')}"
            else:
                out["nixpkgs"]["new"] = out["nixpkgs"]["new"] or ev.get("lib")
                out["packages"] = package_bumps(inst, ev.get("versions", {}))
                out["packagesNote"] = f"{len(inst)} installed packages (system + home-manager) checked by name against the new nixpkgs; packages from other inputs and overlays aren't included"
    return out


def check(flake: Path, state_dir: Path, *, packages: bool = True, timeout: float = 1200) -> dict:
    t0 = time.time()
    tmp = Path(tempfile.mkdtemp(prefix="loft-updates-"))
    try:
        stage("copying the flake", flake=str(flake))
        work = tmp / "flake"
        copy_flake(flake, work)
        if not (work / "flake.lock").is_file():
            raise RuntimeError(f"{flake} has no flake.lock")
        new_lock = tmp / "new.lock"
        stage("nix flake update (in a copy)")
        r = subprocess.run(
            ["nix", "flake", "update", "--flake", f"path:{work}", "--output-lock-file", str(new_lock)],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if r.returncode != 0 or not new_lock.is_file():
            err = r.stderr.strip().splitlines()
            raise RuntimeError("nix flake update failed: " + (" ".join(err[-3:]) if err else f"exit {r.returncode}"))
        old = json.loads((work / "flake.lock").read_text())
        new = json.loads(new_lock.read_text())
        out = summarize(old, new, flake, packages=packages, tmp=tmp, progress=stage)
        out["seconds"] = round(time.time() - t0, 1)
        out["error"] = None
    except (RuntimeError, OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        out = {"flake": str(flake), "checkedAt": int(time.time()), "error": str(e), "inputs": [], "commands": update_commands(flake)}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    cf = cache_file(state_dir)
    cf.parent.mkdir(parents=True, exist_ok=True)
    tmpf = cf.with_suffix(".tmp")
    tmpf.write_text(json.dumps(out, indent=1))
    tmpf.replace(cf)
    return out


# ── CLI ─────────────────────────────────────────────────────────────────────


def add_parser(top, state_dir_of) -> None:
    up = top.add_parser("updates", help="flake update summary: what `nix flake update` would change (never switches)")
    sub = up.add_subparsers(dest="cmd", required=True)

    def flake_of(a) -> Path:
        f = Path(a.flake).expanduser() if a.flake else default_flake()
        if f is None or not (f / "flake.nix").is_file():
            raise SystemExit("loft: no flake (pass --flake DIR or set LOFT_FLAKE)")
        return f.resolve()

    s = sub.add_parser("check", help="update a scratch copy's lock and summarize (cached)")
    s.add_argument("--flake", help="the system flake (default: $LOFT_FLAKE, ~/.flake, /etc/nixos)")
    s.add_argument("--no-packages", action="store_true", help="skip evaluating package versions")

    def _check(ctx, a):
        out = check(flake_of(a), state_dir_of(ctx), packages=not a.no_packages)
        print(json.dumps({"stage": "done", "error": out.get("error"), "changed": out.get("changedCount", 0)}), flush=True)
        if out.get("error"):
            raise SystemExit(1)

    s.set_defaults(fn=_check)

    s = sub.add_parser("show", help="the cached summary")
    s.set_defaults(fn=lambda ctx, a: print(cache_file(state_dir_of(ctx)).read_text() if cache_file(state_dir_of(ctx)).exists() else "{}"))

    s = sub.add_parser("diff", help="compare two lock files (offline)")
    s.add_argument("old")
    s.add_argument("new")
    s.add_argument("--commits", action="store_true", help="also ask GitHub for commit counts")

    def _diff(ctx, a):
        old = json.loads(Path(a.old).read_text())
        new = json.loads(Path(a.new).read_text())
        print(json.dumps(summarize(old, new, Path(a.old).parent, commits=a.commits, packages=False)))

    s.set_defaults(fn=_diff)
