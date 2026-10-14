"""Shallow, sparse fetches of an upstream git repo for the importers.

Nothing upstream is vendored: an importer fetches at install time, and only
what it needs. `Upstream` makes one blob-less, depth-1 fetch of a ref (trees
only, a few hundred KB even for qylock's ~1.2 GB repo), lists directories
with `git ls-tree`, and materializes just the requested paths through a
non-cone sparse checkout, so blobs outside them are never downloaded.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


class ImporterError(Exception):
    """A user-facing importer failure (network, upstream layout, unknown theme)."""


def _git_env() -> dict[str, str]:
    env = dict(os.environ)
    # Never prompt (no credentials are needed for public repos) and never
    # pick up the user's hooks/templates in the scratch repo.
    env.update({"GIT_TERMINAL_PROMPT": "0", "GIT_TEMPLATE_DIR": "", "GIT_CONFIG_NOSYSTEM": "1"})
    return env


class Upstream:
    """One upstream repo at one ref, fetched lazily into a scratch dir.

    url defaults can be overridden per importer with an environment variable
    (STUDIO_<IMPORTER>_URL), which the tests use to point at a local repo.
    """

    def __init__(self, url: str, ref: str | None = None, *, verbose: bool = True):
        self.url = url
        self.ref = ref or "HEAD"
        self.verbose = verbose
        self._dir: Path | None = None
        self._tmp: tempfile.TemporaryDirectory | None = None
        self.commit = ""
        self._paths: list[str] = []
        self.fetched_bytes = 0
        self.fetch_seconds = 0.0

    # ── plumbing ────────────────────────────────────────────────────────────

    def _git(self, *args: str, capture: bool = True, what: str | None = None) -> str:
        if shutil.which("git") is None:
            raise ImporterError("importers need git on PATH")
        cmd = ["git", "-C", str(self._dir), "-c", "advice.detachedHead=false", *args]
        r = subprocess.run(cmd, env=_git_env(), capture_output=True, text=True)
        if r.returncode != 0:
            msg = (r.stderr or r.stdout).strip().splitlines()
            detail = msg[-1] if msg else f"exit {r.returncode}"
            raise ImporterError(f"{self.url}: {what or 'git ' + args[0]} failed: {detail}")
        return r.stdout if capture else ""

    def log(self, msg: str) -> None:
        if self.verbose:
            print(f"studio: {msg}", flush=True)

    @property
    def dir(self) -> Path:
        """The checkout (fetching the ref's trees on first use)."""
        if self._dir is None:
            self._tmp = tempfile.TemporaryDirectory(prefix="studio-import-")
            self._dir = Path(self._tmp.name) / "repo"
            self._dir.mkdir()
            t0 = time.monotonic()
            self._git("init", "--quiet")
            self._git("remote", "add", "origin", self.url)
            self.log(f"fetching {self.url} ({self.ref}, trees only)")
            # Blob-less + depth 1: only commit and tree objects come down here.
            self._git(
                "fetch", "--quiet", "--depth", "1", "--filter=blob:none", "origin", self.ref,
                what=f"fetching {self.ref} (network down, or no such branch/tag/commit?)",
            )
            self.commit = self._git("rev-parse", "FETCH_HEAD").strip()
            self._git("sparse-checkout", "init", "--no-cone")
            self.fetch_seconds += time.monotonic() - t0
            self.fetched_bytes += _du(self._dir / ".git")
        return self._dir

    def close(self) -> None:
        if self._tmp is not None:
            self._tmp.cleanup()
            self._tmp = None
            self._dir = None

    def __enter__(self) -> "Upstream":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ── queries ─────────────────────────────────────────────────────────────

    def ls(self, path: str = "") -> list[tuple[str, str]]:
        """(name, type) entries of a directory at the fetched commit; type is
        "tree" or "blob". Reads trees only (no `-l`: sizes would make git
        download every blob in a blob-less clone, one request each)."""
        self.dir  # noqa: B018 — ensure fetched
        spec = f"{self.commit}:{path}" if path else self.commit
        out = self._git("ls-tree", spec, what=f"listing {path or '/'}")
        entries = []
        for line in out.splitlines():
            meta, name = line.split("\t", 1)
            entries.append((name, meta.split()[1]))
        return entries

    def checkout(self, *patterns: str) -> Path:
        """Materialize these paths (gitignore-style patterns); return the checkout root.

        Only the matching blobs are downloaded. Patterns accumulate across calls.
        """
        new = [p for p in patterns if p not in self._paths]
        if new:
            before = _du(self.dir / ".git")
            t0 = time.monotonic()
            self._paths += new
            self._git("sparse-checkout", "set", "--no-cone", *self._paths)
            # `checkout` fetches the missing blobs from the promisor remote.
            self._git("checkout", "--quiet", self.commit, what="downloading files (network?)")
            self.fetch_seconds += time.monotonic() - t0
            self.fetched_bytes += max(0, _du(self.dir / ".git") - before)
        return self.dir


def literal(path: str) -> str:
    """A sparse-checkout pattern matching exactly this repo path (anchored, globs escaped)."""
    return "/" + re.sub(r"([\\*?\[\]!#])", r"\\\1", path.strip("/"))


def _du(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def human(n: float) -> str:
    for unit in ("B", "KB", "MB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"
