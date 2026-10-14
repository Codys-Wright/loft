"""Spotify themed by Loft: a writable, Spicetify-patched copy of the Nix Spotify.

Nix builds Spotify into the read-only store, so Spicetify can't patch it at
runtime and a build-time patch (spicetify-nix) can't follow Loft's runtime
themes. Loft keeps its own copy instead, under <root> (default
$XDG_DATA_HOME/loft/spotify, $LOFT_SPOTIFY_DIR):

  app/                  the Spotify tree (share/spotify of the package): the
                        binary and Apps/ are real, writable copies (Spotify
                        finds Apps/ next to /proc/self/exe; Spicetify patches
                        it), every other file is a symlink into the store
  bin/spotify           the package's wrapper, rewritten to exec app/ with the
                        same environment
  spicetify/            SPICETIFY_CONFIG: config-xpui.ini, Themes/text (the
                        upstream text theme + this theme's scheme), Extensions,
                        CustomApps
  spicetify-state/      SPICETIFY_STATE: Spicetify's backup of the stock Apps
  prefs                 the version Spicetify checks backups against
                        (`app.last-launched-version`), from the package, so a
                        Nix update never looks like a stale backup
  installed.json        what is installed: source store path, version, and a
                        digest of the Spicetify inputs

What to install comes from <config> ($LOFT_SPOTIFY_CONFIG, default
$XDG_CONFIG_HOME/loft/spotify.json, written by `programs.loft.spotify`):

  {"package": "/nix/store/…-spotify-1.2.95…", "version": "1.2.95…",
   "spicetify": "/nix/store/…-spicetify-cli-2.45.3",
   "textTheme": "/nix/store/…-spicetify-text",      # user.css + color.ini
   "extensions": ["/nix/store/…/adblock.js", …],
   "customApps": {"marketplace": "/nix/store/…"}}

`setup` is idempotent: a new package store path re-copies and re-applies,
changed extensions / apps / theme re-apply, otherwise nothing happens. It
never touches a running copy (the update waits for the next launch), and
never starts or stops Spotify (`spicetify -n`).

Colors: the active theme's `spicetify.ini` (render unit, or a pack's
`apps/spicetify.ini`) holds color.ini sections; the first is the theme's
scheme (`loft`, generated from the palette, unless the pack brings its own,
e.g. Cozytile's `cozy`). `sync` (the `spotify` reload hook) merges them into
Themes/text/color.ini after upstream's schemes, selects the scheme and
writes app/Apps/xpui/colors.css, which is what `spicetify refresh` would
write. The loft-live.js extension re-reads colors.css while Spotify runs and
swaps the variables in place, so playback never stops.

Settings (<state>/overrides/spotify.json): `follow` (default true: the
theme's scheme) and `scheme` (the text theme scheme used when not following).
"""

from __future__ import annotations

import configparser
import contextlib
import fcntl
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

THEME = "text"
LIVE_JS = "loft-live.js"
UPSTREAM_INI = "upstream-color.ini"
DEFAULT_SCHEME = "loft"

# Spicetify's base colors (src/utils/color.go BaseColorList): a scheme that
# lacks one gets this default in colors.css.
BASE_COLORS = {
    "text": "ffffff",
    "subtext": "b3b3b3",
    "main": "121212",
    "main-elevated": "242424",
    "highlight": "1a1a1a",
    "highlight-elevated": "2a2a2a",
    "sidebar": "000000",
    "player": "181818",
    "card": "282828",
    "shadow": "000000",
    "selected-row": "ffffff",
    "button": "1db954",
    "button-active": "1ed760",
    "button-disabled": "535353",
    "tab-active": "333333",
    "notification": "4687d6",
    "notification-error": "e22134",
    "misc": "7f7f7f",
}
# The text theme's own keys (its color.ini); with BASE_COLORS, every key the
# generated `loft` scheme carries.
TEXT_KEYS = (
    "accent",
    "accent-active",
    "accent-inactive",
    "banner",
    "border-active",
    "border-inactive",
    "header",
    "highlight",
    "main",
    "notification",
    "notification-error",
    "subtext",
    "text",
)
SCHEME_KEYS = tuple(dict.fromkeys(TEXT_KEYS + tuple(BASE_COLORS)))


class SpotifyError(Exception):
    pass


# ── paths and config ────────────────────────────────────────────────────────


def _env(key: str) -> str | None:
    return os.environ.get(key) or None


def root_dir() -> Path:
    if _env("LOFT_SPOTIFY_DIR"):
        return Path(os.environ["LOFT_SPOTIFY_DIR"])
    data = Path(_env("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return data / "loft" / "spotify"


def config_file() -> Path:
    if _env("LOFT_SPOTIFY_CONFIG"):
        return Path(os.environ["LOFT_SPOTIFY_CONFIG"])
    config = Path(_env("XDG_CONFIG_HOME") or Path.home() / ".config")
    return config / "loft" / "spotify.json"


def settings_file(state_dir: Path) -> Path:
    return Path(state_dir) / "overrides" / "spotify.json"


@dataclass
class Config:
    package: Path
    spicetify: Path
    text_theme: Path
    live_js: Path
    version: str = ""
    extensions: list[Path] = field(default_factory=list)
    custom_apps: dict[str, Path] = field(default_factory=dict)

    @property
    def spicetify_bin(self) -> Path:
        p = self.spicetify
        return p if p.is_file() else p / "bin" / "spicetify"


def store_version(package: Path) -> str:
    """`1.2.95.453.g0eeebbed` from /nix/store/<hash>-spotify-1.2.95.453.g0eeebbed."""
    m = re.match(r"^(?:[0-9a-z]{32}-)?spotify(?:-unwrapped)?-(\d[^/]*)$", Path(package).name)
    return m.group(1) if m else ""


def load_config(data_dir: Path, overrides: dict | None = None) -> Config | None:
    """The install config (HM's spotify.json) with command-line overrides,
    or None when there is nothing to install from."""
    raw: dict = {}
    f = config_file()
    if f.is_file():
        try:
            raw = json.loads(f.read_text())
        except ValueError as e:
            raise SpotifyError(f"{f}: {e}") from e
    raw.update({k: v for k, v in (overrides or {}).items() if v not in (None, [], {})})
    if not raw.get("package"):
        return None
    spicetify = raw.get("spicetify") or shutil.which("spicetify")
    if not spicetify:
        raise SpotifyError("no spicetify-cli (set `spicetify` in the config or put it on PATH)")
    text_theme = raw.get("textTheme")
    if not text_theme:
        raise SpotifyError("no text theme (`textTheme`: a directory with user.css and color.ini)")
    package = Path(raw["package"])
    return Config(
        package=package,
        spicetify=Path(spicetify),
        text_theme=Path(text_theme),
        live_js=Path(raw.get("liveJs") or Path(data_dir) / "spicetify" / LIVE_JS),
        version=raw.get("version") or store_version(package) or "0",
        extensions=[Path(p) for p in raw.get("extensions") or []],
        custom_apps={str(k): Path(v) for k, v in (raw.get("customApps") or {}).items()},
    )


def read_json(path: Path) -> dict:
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_atomic(path: Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    tmp.write_text(text)
    if mode is not None:
        tmp.chmod(mode)
    tmp.replace(path)


# ── settings ────────────────────────────────────────────────────────────────


PINNED = "pinned"


def load_settings(state_dir: Path) -> dict:
    """follow (default on), scheme (used while not following) and pinned
    (the colors that were showing when following was turned off: scheme
    `pinned`)."""
    s = read_json(settings_file(state_dir))
    pinned = s.get("pinned")
    return {
        "follow": s.get("follow") is not False,
        "scheme": s.get("scheme") if isinstance(s.get("scheme"), str) and s.get("scheme") else None,
        "pinned": {k: v for k, v in pinned.items() if isinstance(v, str)} if isinstance(pinned, dict) and pinned else None,
    }


def save_settings(state_dir: Path, **changes) -> dict:
    s = load_settings(state_dir)
    s.update(changes)
    write_atomic(settings_file(state_dir), json.dumps(s, indent=2) + "\n")
    return s


# ── color.ini ───────────────────────────────────────────────────────────────


def parse_ini(text: str) -> dict[str, dict[str, str]]:
    """color.ini sections in order: {scheme: {key: hex6 without #}}.

    Lenient like Spicetify (go-ini): `;`/`#` comments, `key = value` or
    `key=value`, values with or without `#`."""
    out: dict[str, dict[str, str]] = {}
    cur: dict[str, str] | None = None
    for line in text.splitlines():
        s = line.strip()
        if not s or s[0] in ";#":
            continue
        m = re.match(r"^\[(.+)\]$", s)
        if m:
            cur = out.setdefault(m.group(1).strip(), {})
            continue
        if cur is not None and "=" in s:
            k, v = s.split("=", 1)
            v = v.split(";")[0].strip().lstrip("#").lower()
            if re.fullmatch(r"[0-9a-f]{6}", v):
                cur[k.strip()] = v
    return out


def format_ini(schemes: dict[str, dict[str, str]], header: str = "") -> str:
    lines = [f"; {line}" for line in header.splitlines()] + ([""] if header else [])
    for name, keys in schemes.items():
        lines.append(f"[{name}]")
        width = max((len(k) for k in keys), default=0)
        lines += [f"{k.ljust(width)} = {v}" for k, v in keys.items()]
        lines.append("")
    return "\n".join(lines)


def merge_schemes(upstream: dict, theme: dict) -> dict:
    """Upstream's schemes, then the theme's (a theme scheme with an upstream
    name replaces it, in the theme's place)."""
    out = {k: v for k, v in upstream.items() if k not in theme}
    out.update(theme)
    return out


def colors_css(scheme: dict[str, str]) -> str:
    """xpui/colors.css for a scheme, as Spicetify writes it (getColorCSS):
    every key, base colors filled in, then the rgb triplets."""
    merged = dict(BASE_COLORS)
    merged.update(scheme)
    keys = sorted(merged)
    hexes = [f"    --spice-{k}: #{merged[k]};" for k in keys]
    rgbs = [f"    --spice-rgb-{k}: {int(merged[k][0:2], 16)},{int(merged[k][2:4], 16)},{int(merged[k][4:6], 16)};" for k in keys]
    return ":root {\n" + "\n".join(hexes) + "\n\n" + "\n".join(rgbs) + "\n}\n"


def theme_schemes(bundle: Path | None) -> dict[str, dict[str, str]]:
    """The schemes the active rendered theme carries (its spicetify.ini)."""
    if bundle is None:
        return {}
    try:
        return parse_ini((Path(bundle) / "spicetify.ini").read_text())
    except OSError:
        return {}


def choose_scheme(settings: dict, theme: dict, available: dict, current: str | None) -> str:
    """Following: the theme's first scheme (else `loft`). Not following: the
    chosen scheme, else whatever is selected now."""
    if settings["follow"]:
        return next(iter(theme), DEFAULT_SCHEME)
    for name in (settings.get("scheme"), current):
        if name and name in available:
            return name
    return next(iter(theme), DEFAULT_SCHEME)


# ── the writable copy ───────────────────────────────────────────────────────


EXEC_LINE = re.compile(r"^\s*exec\b")


def exec_targets(text: str, src: Path) -> list[str]:
    """Paths under src a wrapper script execs, relative to src."""
    prefix = str(src).rstrip("/") + "/"
    out = []
    for line in text.splitlines():
        if EXEC_LINE.match(line):
            out += re.findall(re.escape(prefix) + r"""([^"'\s]+)""", line)
    return out


def rewrite_wrapper(text: str, src: Path, dest: Path) -> str:
    """The nixpkgs (makeWrapper) wrapper, exec'ing the copy under dest
    instead of src. Only `exec` lines change: the environment it sets up
    (LD_LIBRARY_PATH into the store, XDG_DATA_DIRS, …) stays the same."""
    prefix = str(src).rstrip("/") + "/"
    lines, n = [], 0
    for line in text.splitlines(keepends=True):
        if EXEC_LINE.match(line) and prefix in line:
            line = line.replace(prefix, str(dest).rstrip("/") + "/")
            n += 1
        lines.append(line)
    if n == 0:
        raise SpotifyError(f"the Spotify wrapper doesn't exec anything under {src}; unknown package layout")
    return "".join(lines)


def _is_script(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(2) == b"#!"
    except OSError:
        return False


def _make_writable(root: Path) -> None:
    for p in [root, *root.rglob("*")]:
        if not p.is_symlink():
            p.chmod(p.stat().st_mode | 0o200)


def copy_spotify(package: Path, app: Path, launcher: Path, final: Path | None = None) -> None:
    """Build the runnable copy: app/ mirrors <package>/share/spotify and
    launcher is the package's bin/spotify, both exec'ing `final` (where app/
    will be renamed to; default app itself).

    Real copies: Apps/ (Spicetify's target) and every file the wrappers exec
    (the binary: CEF and Spotify locate resources and Apps/ from the
    executable's real path), wrapper scripts rewritten. Everything else is a
    symlink into the store (libcef.so alone is ~240 MB)."""
    src = Path(package) / "share" / "spotify"
    wrapper = Path(package) / "bin" / "spotify"
    if not (src / "Apps").is_dir() or not wrapper.exists():
        raise SpotifyError(f"{package} doesn't look like a Spotify package (no share/spotify/Apps or bin/spotify)")
    final = Path(final or app)
    app.mkdir(parents=True)

    real: set[str] = set()
    # The launcher's exec chain, and every wrapper script in the tree itself
    # (share/spotify/spotify: what `spicetify restart` runs).
    queue = [wrapper.resolve()] + [p for p in sorted(src.iterdir()) if p.is_file() and _is_script(p) and exec_targets(p.read_text(errors="replace"), src)]
    real.update(p.name for p in queue[1:])
    launcher_text = None
    while queue:
        w = queue.pop()
        if not _is_script(w):
            continue
        text = w.read_text(errors="replace")
        targets = exec_targets(text, src)
        if w == wrapper.resolve() and launcher_text is None:
            launcher_text = rewrite_wrapper(text, src, final)
        for t in targets:
            if t not in real:
                real.add(t)
                queue.append(src / t)

    for entry in sorted(src.iterdir()):
        name, dest = entry.name, app / entry.name
        if name == "Apps":
            shutil.copytree(entry, dest, symlinks=False)
        elif name in real:
            if _is_script(entry) and exec_targets(entry.read_text(errors="replace"), src):
                write_atomic(dest, rewrite_wrapper(entry.read_text(errors="replace"), src, final), 0o755)
            else:
                shutil.copyfile(entry, dest)
                dest.chmod(0o755)
        else:
            dest.symlink_to(entry)
    _make_writable(app / "Apps")
    if launcher_text is None:
        raise SpotifyError(f"{wrapper} is not a wrapper script")
    write_atomic(launcher, launcher_text, 0o755)


def running_pids(app: Path) -> list[int]:
    """This user's processes running the copy's binary (any file under app/)."""
    try:
        prefix = str(Path(app).resolve()) + "/"
    except OSError:
        return []
    uid = os.getuid()
    out = []
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            if d.stat().st_uid != uid:
                continue
            exe = os.readlink(d / "exe")
        except OSError:
            continue
        if exe.startswith(prefix):
            out.append(int(d.name))
    return out


# ── spicetify ───────────────────────────────────────────────────────────────


def spicetify_env(root: Path) -> dict[str, str]:
    env = dict(os.environ)
    env["SPICETIFY_CONFIG"] = str(root / "spicetify")
    env["SPICETIFY_STATE"] = str(root / "spicetify-state")
    return env


def _ini_read(path: Path) -> configparser.ConfigParser:
    cp = configparser.ConfigParser(interpolation=None, strict=False, comment_prefixes=(";", "#"), inline_comment_prefixes=None)
    cp.optionxform = str  # type: ignore[assignment]
    try:
        cp.read_string(path.read_text())
    except (OSError, configparser.Error):
        pass
    return cp


def write_spicetify_config(root: Path, cfg: Config, scheme: str, keep_backup: bool) -> None:
    """config-xpui.ini: Loft's paths and choices; Spicetify's own [Backup]
    record survives unless the copy was just rebuilt."""
    path = root / "spicetify" / "config-xpui.ini"
    old = _ini_read(path)
    exts = [LIVE_JS] + [p.name for p in cfg.extensions if p.name != LIVE_JS]
    sections = {
        "Setting": {
            "spotify_path": str(root / "app"),
            "prefs_path": str(root / "prefs"),
            "current_theme": THEME,
            "color_scheme": scheme,
            "inject_css": "1",
            "inject_theme_js": "1",
            "replace_colors": "1",
            "overwrite_assets": "0",
            "spotify_launch_flags": "",
            "check_spicetify_update": "0",
            "always_enable_devtools": "0",
        },
        "Preprocesses": {
            "disable_sentry": "1",
            "disable_ui_logging": "1",
            "remove_rtl_rule": "1",
            "expose_apis": "1",
        },
        "AdditionalOptions": {
            "extensions": "|".join(dict.fromkeys(exts)),
            "custom_apps": "|".join(cfg.custom_apps),
            "sidebar_config": "1",
            "home_config": "1",
            "experimental_features": "1",
        },
        "Patch": {},
        "Backup": dict(old["Backup"]) if keep_backup and old.has_section("Backup") else {},
    }
    buf = io.StringIO()
    buf.write("; Written by `loft spotify` (cli/loft/spotify.py); edits are replaced.\n")
    for name, keys in sections.items():
        buf.write(f"[{name}]\n")
        for k, v in keys.items():
            buf.write(f"{k} = {v}\n")
        buf.write("\n")
    write_atomic(path, buf.getvalue())


def set_color_scheme(root: Path, scheme: str) -> None:
    path = root / "spicetify" / "config-xpui.ini"
    if not path.is_file():
        return
    text = path.read_text()
    new, n = re.subn(r"(?m)^(color_scheme\s*=).*$", lambda m: f"{m.group(1)} {scheme}", text)
    if n and new != text:
        write_atomic(path, new)


def current_color_scheme(root: Path) -> str | None:
    cp = _ini_read(root / "spicetify" / "config-xpui.ini")
    return cp.get("Setting", "color_scheme", fallback=None) or None


def _copy_tree(src: Path, dest: Path) -> None:
    if dest.exists() or dest.is_symlink():
        shutil.rmtree(dest) if dest.is_dir() and not dest.is_symlink() else dest.unlink()
    if Path(src).is_dir():
        shutil.copytree(src, dest, symlinks=False)
        _make_writable(dest)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)
        dest.chmod(0o644)


def install_userdata(root: Path, cfg: Config, bundle: Path | None, settings: dict | None = None) -> None:
    """Themes/text, Extensions/, CustomApps/ in SPICETIFY_CONFIG, rebuilt
    from the config (what Loft installed before and no longer lists goes)."""
    sp = root / "spicetify"
    theme = sp / "Themes" / THEME
    if theme.exists():
        shutil.rmtree(theme)
    theme.mkdir(parents=True)
    css = cfg.text_theme / "user.css"
    if not css.is_file():
        raise SpotifyError(f"{cfg.text_theme}: no user.css (textTheme must be spicetify-themes' text/ directory)")
    shutil.copyfile(css, theme / "user.css")
    (theme / "user.css").chmod(0o644)
    # Upstream's schemes, kept pristine: every sync merges the theme's into them.
    write_atomic(root / UPSTREAM_INI, (cfg.text_theme / "color.ini").read_text() if (cfg.text_theme / "color.ini").is_file() else "")
    write_color_ini(root, bundle, settings or {})

    for d in ("Extensions", "CustomApps"):
        if (sp / d).exists():
            shutil.rmtree(sp / d)
        (sp / d).mkdir(parents=True)
    if not cfg.live_js.is_file():
        raise SpotifyError(f"{cfg.live_js}: missing (Loft's live recolor extension)")
    _copy_tree(cfg.live_js, sp / "Extensions" / LIVE_JS)
    for ext in cfg.extensions:
        if not ext.is_file():
            raise SpotifyError(f"extension {ext}: not a file (give the .js itself)")
        _copy_tree(ext, sp / "Extensions" / ext.name)
    for name, path in cfg.custom_apps.items():
        if not Path(path).is_dir():
            raise SpotifyError(f"custom app {name} ({path}): not a directory")
        _copy_tree(Path(path), sp / "CustomApps" / name)


def upstream_schemes(ini: Path) -> dict[str, dict[str, str]]:
    try:
        return parse_ini(Path(ini).read_text())
    except OSError:
        return {}


def all_schemes(upstream_ini: Path, bundle: Path | None, settings: dict) -> dict[str, dict[str, str]]:
    """Upstream's schemes, the theme's, then `pinned` when there is one."""
    schemes = merge_schemes(upstream_schemes(upstream_ini), theme_schemes(bundle))
    if settings.get("pinned"):
        schemes = merge_schemes(schemes, {PINNED: settings["pinned"]})
    return schemes


def write_color_ini(root: Path, bundle: Path | None, settings: dict) -> dict[str, dict[str, str]]:
    schemes = all_schemes(root / UPSTREAM_INI, bundle, settings)
    if DEFAULT_SCHEME not in schemes:
        # No theme active yet: Spicetify needs the selected scheme to exist.
        schemes[DEFAULT_SCHEME] = {k: BASE_COLORS.get(k, "1db954") for k in SCHEME_KEYS}
    write_atomic(
        root / "spicetify" / "Themes" / THEME / "color.ini",
        format_ini(schemes, "spicetify-themes' text schemes, then the active Loft theme's (`loft spotify sync`)."),
    )
    return schemes


def run_spicetify(root: Path, cfg: Config, *commands: str) -> str:
    """`spicetify -n <commands>`: -n, so it never kills or starts Spotify."""
    argv = [str(cfg.spicetify_bin), "-n", *commands]
    try:
        r = subprocess.run(argv, env=spicetify_env(root), capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise SpotifyError(f"spicetify {' '.join(commands)}: {e}") from e
    out = (r.stdout + r.stderr).strip()
    # Spicetify reports some failures (e.g. a bad path) with exit code 0.
    if r.returncode != 0 or re.search(r"(?m)^\s*(error|fatal)\b", _strip_ansi(out), re.I):
        raise SpotifyError(f"spicetify {' '.join(commands)} failed:\n{out}")
    return out


def _strip_ansi(s: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", s)


# ── setup / sync / status ───────────────────────────────────────────────────


def _hash_path(h, p: Path) -> None:
    p = Path(p)
    h.update(str(p).encode() + b"\0")
    if p.is_file():
        h.update(p.read_bytes())
    elif p.is_dir():
        for q in sorted(p.rglob("*")):
            if q.is_file():
                h.update(str(q.relative_to(p)).encode() + b"\0" + q.read_bytes())


def inputs_digest(cfg: Config) -> str:
    """Changes when anything Spicetify applies changes (not the colors: those
    are synced without spicetify)."""
    h = hashlib.sha256()
    h.update(str(cfg.spicetify.resolve()).encode())
    _hash_path(h, cfg.text_theme / "user.css")
    _hash_path(h, cfg.live_js)
    for p in cfg.extensions:
        _hash_path(h, p)
    for name, p in sorted(cfg.custom_apps.items()):
        h.update(name.encode() + b"\0")
        _hash_path(h, p)
    return h.hexdigest()


def needs(root: Path, cfg: Config) -> str | None:
    """What setup would do: "copy" (none yet, or a new package), "apply"
    (Spicetify inputs changed, or the patch is missing), or None."""
    rec = read_json(root / "installed.json")
    app = root / "app"
    if rec.get("source") != str(cfg.package.resolve()) or not (app / "Apps").is_dir() or not (root / "bin" / "spotify").is_file():
        return "copy"
    if rec.get("digest") != inputs_digest(cfg) or not (app / "Apps" / "xpui" / "index.html").is_file():
        return "apply"
    return None


@contextlib.contextmanager
def _locked(root: Path):
    """One setup at a time (the login service and the launcher may race)."""
    root.mkdir(parents=True, exist_ok=True)
    with open(root / ".lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def setup(root: Path, cfg: Config, state_dir: Path, *, force: bool = False, bundle: Path | None = None, log=print) -> str:
    """Make <root> match cfg. Returns what happened: "copied", "applied",
    "up-to-date" or "deferred" (Spotify is running from the old copy)."""
    root = Path(root)
    with _locked(root):
        return _setup(root, cfg, state_dir, force=force, bundle=bundle, log=log)


def _setup(root: Path, cfg: Config, state_dir: Path, *, force: bool, bundle: Path | None, log) -> str:
    todo = "copy" if force else needs(root, cfg)
    if todo is None:
        return "up-to-date"
    app = root / "app"
    if running_pids(app):
        log(f"loft: Spotify is running; the {'update' if todo == 'copy' else 're-apply'} waits for its next launch")
        return "deferred"

    root.mkdir(parents=True, exist_ok=True)
    if todo == "copy":
        log(f"loft: copying Spotify {cfg.version} into {app}")
        tmp = root / f".app.new-{os.getpid()}"
        tmp_bin = root / "bin" / f".spotify.new-{os.getpid()}"
        for p in (tmp, tmp_bin):
            if p.is_dir():
                shutil.rmtree(p)
        try:
            copy_spotify(cfg.package, tmp, tmp_bin, final=app)
        except BaseException:
            if tmp.exists():
                _make_writable(tmp)
            shutil.rmtree(tmp, ignore_errors=True)
            tmp_bin.unlink(missing_ok=True)
            raise
        if app.exists():
            shutil.rmtree(app)
        tmp.rename(app)
        tmp_bin.replace(root / "bin" / "spotify")
        # A fresh copy: Spicetify's backup of the old one is void.
        shutil.rmtree(root / "spicetify-state", ignore_errors=True)
        (root / "installed.json").unlink(missing_ok=True)

    write_atomic(root / "prefs", f'app.last-launched-version="{cfg.version}"\n')
    settings = load_settings(state_dir)
    schemes = all_schemes(cfg.text_theme / "color.ini", bundle, settings)
    scheme = choose_scheme(settings, theme_schemes(bundle), schemes, current_color_scheme(root))
    write_spicetify_config(root, cfg, scheme, keep_backup=todo != "copy")
    install_userdata(root, cfg, bundle, settings)
    backed_up = (root / "spicetify-state" / "Backup").is_dir() and any((root / "spicetify-state" / "Backup").iterdir())
    log("loft: spicetify " + ("apply" if backed_up else "backup apply"))
    run_spicetify(root, cfg, *(["apply"] if backed_up else ["backup", "apply"]))
    sync(root, state_dir, bundle)
    rec = {
        "source": str(cfg.package.resolve()),
        "version": cfg.version,
        "spicetify": str(cfg.spicetify.resolve()),
        "digest": inputs_digest(cfg),
        "extensions": [LIVE_JS] + [p.name for p in cfg.extensions if p.name != LIVE_JS],
        "customApps": sorted(cfg.custom_apps),
    }
    write_atomic(root / "installed.json", json.dumps(rec, indent=2) + "\n")
    return "copied" if todo == "copy" else "applied"


def is_set_up(root: Path) -> bool:
    """Spicetify has patched the copy (xpui/ is extracted)."""
    return (Path(root) / "app" / "Apps" / "xpui" / "index.html").is_file()


def sync(root: Path, state_dir: Path, bundle: Path | None) -> dict | None:
    """Recolor the installed Spotify for the active theme (the reload hook).

    Writes Themes/text/color.ini (upstream + the theme's schemes), selects
    the scheme in config-xpui.ini and writes xpui/colors.css, which the
    loft-live.js extension picks up in a running Spotify. Returns
    {"scheme", "colors"} or None when Spotify isn't set up (a no-op)."""
    root = Path(root)
    if not is_set_up(root):
        return None
    settings = load_settings(state_dir)
    schemes = write_color_ini(root, bundle, settings)
    scheme = choose_scheme(settings, theme_schemes(bundle), schemes, current_color_scheme(root))
    set_color_scheme(root, scheme)
    css = colors_css(schemes.get(scheme) or {})
    dest = root / "app" / "Apps" / "xpui" / "colors.css"
    if not dest.exists() or dest.read_text() != css:
        write_atomic(dest, css, 0o644)
    return {"scheme": scheme, "colors": str(dest)}


def status(root: Path, state_dir: Path, data_dir: Path, bundle: Path | None) -> dict:
    root = Path(root)
    out: dict = {"root": str(root), "configured": False, "setUp": is_set_up(root)}
    rec = read_json(root / "installed.json")
    out["installed"] = rec or None
    try:
        cfg = load_config(data_dir)
    except SpotifyError as e:
        cfg, out["error"] = None, str(e)
    if cfg is not None:
        out["configured"] = True
        out["version"] = cfg.version
        try:
            out["pending"] = needs(root, cfg)
        except OSError as e:
            out["pending"], out["error"] = "copy", str(e)
    upstream_ini = root / UPSTREAM_INI
    if not upstream_ini.is_file() and cfg is not None:
        upstream_ini = cfg.text_theme / "color.ini"
    out["running"] = bool(running_pids(root / "app"))
    settings = load_settings(state_dir)
    theme = theme_schemes(bundle)
    schemes = all_schemes(upstream_ini, bundle, settings)
    out.update(
        {
            "follow": settings["follow"],
            "scheme": settings["scheme"],
            "activeScheme": current_color_scheme(root) if out["setUp"] else None,
            "themeSchemes": list(theme) or [DEFAULT_SCHEME],
            # The theme's first, then pinned, then upstream's.
            "schemes": list(dict.fromkeys([*theme, *([PINNED] if PINNED in schemes else []), *schemes])),
        }
    )
    return out


# ── CLI ─────────────────────────────────────────────────────────────────────


def _overrides(a) -> dict:
    apps = {}
    for spec in getattr(a, "custom_app", None) or []:
        name, sep, path = spec.partition("=")
        if not sep:
            raise SpotifyError(f"--custom-app {spec}: expected NAME=PATH")
        apps[name] = path
    return {
        "package": getattr(a, "package", None),
        "spicetify": getattr(a, "spicetify", None),
        "textTheme": getattr(a, "text_theme", None),
        "extensions": getattr(a, "extension", None),
        "customApps": apps,
    }


def _bundle(ctx) -> Path | None:
    cur = ctx.current
    return cur if (cur / "theme.json").is_file() else None


def add_parser(top, fail) -> None:
    """`fail(msg)` raises the CLI's error type."""
    sp = top.add_parser("spotify", help="Spotify themed by Loft (a writable Spicetify install)")
    sub = sp.add_subparsers(dest="cmd", required=True)

    def install_args(s) -> None:
        s.add_argument("--package", help="the Spotify package (store path; default: the config's)")
        s.add_argument("--spicetify", help="spicetify-cli (package or binary)")
        s.add_argument("--text-theme", help="spicetify-themes' text/ directory")
        s.add_argument("--extension", action="append", help="an extension .js (repeatable)")
        s.add_argument("--custom-app", action="append", metavar="NAME=PATH", help="a custom app directory (repeatable)")

    def cfg_of(ctx, a) -> Config:
        cfg = load_config(ctx.data_dir, _overrides(a))
        if cfg is None:
            fail(f"no Spotify configured ({config_file()} or --package; programs.loft.spotify writes it)")
        return cfg

    def wrap(fn):
        def run(ctx, a):
            try:
                fn(ctx, a)
            except SpotifyError as e:
                fail(str(e))

        return run

    s = sub.add_parser("setup", help="copy + patch Spotify when needed (idempotent)")
    install_args(s)
    s.add_argument("--force", action="store_true", help="re-copy and re-apply even when up to date")
    s.add_argument("-q", "--quiet", action="store_true")

    def _setup(ctx, a):
        cfg = cfg_of(ctx, a)
        log = (lambda *_: None) if a.quiet else (lambda m: print(m, file=sys.stderr))
        r = setup(root_dir(), cfg, ctx.state_dir, force=a.force, bundle=_bundle(ctx), log=log)
        if not a.quiet:
            print(f"loft: Spotify {cfg.version}: {r}")

    s.set_defaults(fn=wrap(_setup))

    s = sub.add_parser("reapply", help="run spicetify apply again (Settings → Re-apply)")
    install_args(s)

    def _reapply(ctx, a):
        cfg = cfg_of(ctx, a)
        root = root_dir()
        if needs(root, cfg) == "copy":
            r = setup(root, cfg, ctx.state_dir, bundle=_bundle(ctx), log=lambda m: print(m, file=sys.stderr))
        else:
            # Explicit: also while Spotify runs (it picks the patch up on
            # its next start; nothing is stopped).
            write_spicetify_config(root, cfg, current_color_scheme(root) or DEFAULT_SCHEME, keep_backup=True)
            install_userdata(root, cfg, _bundle(ctx), load_settings(ctx.state_dir))
            run_spicetify(root, cfg, "apply")
            sync(root, ctx.state_dir, _bundle(ctx))
            rec = read_json(root / "installed.json")
            rec["digest"] = inputs_digest(cfg)
            write_atomic(root / "installed.json", json.dumps(rec, indent=2) + "\n")
            r = "applied"
        print(f"loft: Spotify: {r}")

    s.set_defaults(fn=wrap(_reapply))

    s = sub.add_parser("run", help="launch the themed Spotify (set up first when needed)")
    s.add_argument("args", nargs="*", help="passed to Spotify (after --)")

    def _run(ctx, a):
        root = root_dir()
        fallback = None
        try:
            cfg = load_config(ctx.data_dir)
            if cfg is not None:
                fallback = cfg.package / "bin" / "spotify"
                setup(root, cfg, ctx.state_dir, bundle=_bundle(ctx), log=lambda m: print(m, file=sys.stderr))
            sync(root, ctx.state_dir, _bundle(ctx))
        except (SpotifyError, OSError) as e:
            print(f"loft: Spotify setup failed, starting it unthemed: {e}", file=sys.stderr)
        exe = root / "bin" / "spotify"
        if not is_set_up(root) or not exe.is_file():
            if fallback is None or not fallback.exists():
                fail("Spotify isn't set up and no package is configured")
            exe = fallback
        sys.stdout.flush()
        os.execv(str(exe), [str(exe), *a.args])

    s.set_defaults(fn=_run)

    s = sub.add_parser("sync", help="recolor Spotify for the active theme (the `spotify` reload hook)")

    def _sync(ctx, a):
        r = sync(root_dir(), ctx.state_dir, _bundle(ctx))
        print("loft: Spotify isn't set up; nothing to do" if r is None else f"loft: Spotify scheme {r['scheme']}")

    s.set_defaults(fn=wrap(_sync))

    s = sub.add_parser("follow", help="follow the Loft theme (on) or keep a fixed scheme (off)")
    s.add_argument("state", choices=["on", "off"])

    def _follow(ctx, a):
        if a.state == "on":
            save_settings(ctx.state_dir, follow=True)
        else:
            settings = load_settings(ctx.state_dir)
            root = root_dir()
            upstream = upstream_schemes(root / UPSTREAM_INI)
            if settings["follow"] or settings["scheme"] not in upstream:
                # Keep what shows now: the theme's colors, pinned.
                schemes = all_schemes(root / UPSTREAM_INI, _bundle(ctx), settings)
                showing = choose_scheme(settings, theme_schemes(_bundle(ctx)), schemes, current_color_scheme(root))
                pinned = schemes.get(showing) or theme_schemes(_bundle(ctx)).get(DEFAULT_SCHEME)
                save_settings(ctx.state_dir, follow=False, scheme=PINNED if pinned else settings["scheme"], pinned=pinned)
            else:
                save_settings(ctx.state_dir, follow=False)
        r = sync(root_dir(), ctx.state_dir, _bundle(ctx))
        print(f"loft: Spotify follows the theme: {a.state}" + (f" (scheme {r['scheme']})" if r else ""))

    s.set_defaults(fn=wrap(_follow))

    s = sub.add_parser("scheme", help="use a text theme scheme (turns following off); `theme` follows again")
    s.add_argument("name")

    def _scheme(ctx, a):
        if a.name in ("theme", "auto", "follow"):
            save_settings(ctx.state_dir, follow=True, scheme=None)
        else:
            st = status(root_dir(), ctx.state_dir, ctx.data_dir, _bundle(ctx))
            if st["schemes"] and a.name not in st["schemes"]:
                fail(f"no scheme {a.name!r} (have: {', '.join(st['schemes'])})")
            save_settings(ctx.state_dir, follow=False, scheme=a.name)
        r = sync(root_dir(), ctx.state_dir, _bundle(ctx))
        print(f"loft: Spotify scheme {r['scheme'] if r else a.name}" + ("" if r else " (applies once Spotify is set up)"))

    s.set_defaults(fn=wrap(_scheme))

    s = sub.add_parser("status", help="installed version, pending update, scheme")
    s.add_argument("--json", action="store_true")

    def _status(ctx, a):
        st = status(root_dir(), ctx.state_dir, ctx.data_dir, _bundle(ctx))
        if a.json:
            print(json.dumps(st))
            return
        inst = st.get("installed") or {}
        print(f"configured  {'yes' if st['configured'] else 'no'}")
        print(f"set up      {('yes, Spotify ' + inst.get('version', '?')) if st['setUp'] else 'no'}")
        if st.get("pending"):
            print(f"pending     {st['pending']} (on the next `loft spotify setup` / launch)")
        print(f"running     {'yes' if st['running'] else 'no'}")
        print(f"follow      {'on' if st['follow'] else 'off'}")
        print(f"scheme      {st.get('activeScheme') or '-'}")
        if st.get("error"):
            print(f"error       {st['error']}")

    s.set_defaults(fn=wrap(_status))

    s = sub.add_parser("schemes", help="the text theme schemes (the theme's first)")

    def _schemes(ctx, a):
        print("\n".join(status(root_dir(), ctx.state_dir, ctx.data_dir, _bundle(ctx))["schemes"]))

    s.set_defaults(fn=wrap(_schemes))

    s = sub.add_parser("remove", help="delete Loft's Spotify copy (not Spotify's own data)")

    def _remove(ctx, a):
        root = root_dir()
        if running_pids(root / "app"):
            fail("Spotify is running from it; quit it first")
        if root.exists():
            shutil.rmtree(root)
        print(f"loft: removed {root}")

    s.set_defaults(fn=wrap(_remove))
