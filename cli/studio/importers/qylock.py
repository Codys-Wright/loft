"""qylock: Darkkal44/qylock lock/greeter designs as studio packs.

qylock is ~1.2 GB (video backgrounds), so it is never cloned: one blob-less
depth-1 fetch gives the tree (for listing), then a sparse checkout downloads
only `themes/<theme>/`. The whole theme directory (QML, fonts, images,
videos, theme.conf, metadata.desktop) becomes the pack's `lock/qylock/`,
and the manifest declares it:

  "lock": {"format": "qylock", "path": "lock/qylock"}

The lock screen / greeter loader runs that design through qylock's SDDM
shim (docs/THEME-FORMAT.md, "Lock designs").

Palette: theme.conf colors when present (`type=color` + `color` = a solid
background; `accentColor`; `mainColor`/`containerColor`; `themeMode`
light/dark; a lone `color` is the lock's text color, or its accent when
it is saturated). Everything else comes from the background: a still image,
or a frame ~1 s into a video, quantized (median cut + k-means, palette.py).
Video frames need ffmpeg; without it (and without config colors) the pack
gets a neutral dark palette, editable afterwards.

Wallpapers: every background of the theme (theme.conf's, plus other large
images/videos such as osu's background/A..G or Genshin's dawn/day/dusk/night).
Stills are referenced in place (lock/qylock/…, no second copy); a video gets
a still frame in wallpapers/ that notes the video ({"path", "video"}).
"""

from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

from .. import color
from .. import palette
from .upstream import ImporterError, Upstream, literal

NAME = "qylock"
URL = "https://github.com/Darkkal44/qylock"
LICENSE = "GPL-3.0"
DESCRIPTION = "Darkkal44's qylock SDDM/Quickshell lock designs (lock design + derived palette)"

LOCK_PATH = "lock/qylock"
NOT_BACKGROUND = re.compile(r"(logo|avatar|pfp|title|icon|preview|screenshot)", re.I)
SKIP_EXT = {".qml", ".js", ".ttf", ".otf", ".woff", ".woff2", ".conf", ".desktop", ".md", ".txt", ".json", ".svg", ".qmldir"}


def pack_name(theme: str) -> str:
    slug = re.sub(r"[^a-z0-9._-]+", "-", theme.lower()).strip("-")
    return f"qylock-{slug}"


def list_themes(up: Upstream) -> list[str]:
    up.dir  # noqa: B018 — fetch first, so fetch errors surface as they are
    try:
        entries = up.ls("themes")
    except ImporterError as e:
        raise ImporterError(f"{up.url} @ {up.ref} has no themes/ directory; has the upstream layout changed?") from e
    return sorted((n for n, typ in entries if typ == "tree"), key=str.lower)


def resolve(up: Upstream, theme: str) -> str:
    themes = list_themes(up)
    for t in themes:
        if t == theme:
            return t
    for t in themes:
        if t.lower() == theme.lower() or pack_name(t) == theme.lower() or pack_name(t) == pack_name(theme):
            return t
    raise ImporterError(f"no qylock theme '{theme}' (`studio theme install --list qylock:` lists them)")


# ── pure helpers (unit-tested) ──────────────────────────────────────────────


def parse_conf(text: str) -> dict[str, str]:
    """theme.conf keys (any section; first wins), lower-cased keys."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("#", ";", "[")) or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out.setdefault(k.strip().lower(), v.strip().strip('"'))
    return out


def _hexval(v: str | None) -> str | None:
    if v and re.fullmatch(r"#[0-9a-fA-F]{6}", v):
        return v.lower()
    if v and re.fullmatch(r"#[0-9a-fA-F]{8}", v):  # Qt #aarrggbb
        return "#" + v[3:].lower()
    return None


def hints(conf: dict[str, str]) -> dict:
    """scheme() keyword hints from a parsed theme.conf."""
    h: dict = {}
    mode = conf.get("thememode", "").lower()
    if mode in ("light", "dark"):
        h["polarity"] = mode
    c = _hexval(conf.get("color"))
    if conf.get("type", "").lower() == "color" and c:
        h["bg"] = c
        h.setdefault("polarity", palette.polarity_of(c))
        c = None
    if a := _hexval(conf.get("accentcolor")):
        h["accent"] = a
    if m := _hexval(conf.get("maincolor")):
        h["text"] = m
    if s := _hexval(conf.get("containercolor")):
        h["surface"] = s
    if c:
        if palette.chroma(c) > 0.25:
            h.setdefault("accent", c)
        else:
            h.setdefault("text_on_bg", c)  # the lock's text color: only usable as text on a matching bg
    return h


def palette_for(conf: dict[str, str], swatches: list[tuple[str, float]]) -> tuple[str, dict[str, str]]:
    h = hints(conf)
    lock_text = h.pop("text_on_bg", None)
    polarity, pal = palette.scheme(swatches=swatches, **h)
    if lock_text and "text" not in h:
        # Keep the design's own text color when it reads on our bg.
        if color.contrast(lock_text, pal["bg"]) >= 7:
            pal["text"] = lock_text
            pal["subtext"] = palette.ensure_contrast(color.mix(lock_text, pal["bg"], 0.3), pal["bg"], 3.0)
    return polarity, pal


def find_background(theme_dir: Path, conf: dict[str, str]) -> Path | None:
    """The theme's background file: theme.conf's `background`, else the largest
    image/video that isn't a logo/avatar (osu's extensionless background/A …)."""
    name = conf.get("background", "")
    if name:
        p = theme_dir / name
        if p.is_file():
            return p
        # e.g. Genshin: background=day.png, but only day.mp4 ships.
        for alt in sorted(theme_dir.glob(Path(name).stem + ".*")):
            if alt.is_file() and alt.suffix.lower() not in SKIP_EXT:
                return alt
    cands = []
    for p in theme_dir.rglob("*"):
        if not p.is_file() or p.suffix.lower() in SKIP_EXT or NOT_BACKGROUND.search(p.name):
            continue
        if any(part.lower() in ("font", "fonts") for part in p.relative_to(theme_dir).parts):
            continue
        if palette.sniff(p) == "unknown" and p.suffix.lower() not in palette.VIDEO_EXT:
            continue
        cands.append(p)
    return max(cands, key=lambda p: (p.stat().st_size, str(p)), default=None)


# Other media in a theme dir at least this big are alternative backgrounds
# (osu's background/A..G Glow.jpg, Genshin's dawn/day/dusk/night.mp4), not
# decorations (terraria's ter1..5.png sprites, logos, avatars).
MIN_BACKGROUND_BYTES = 200_000


def find_backgrounds(theme_dir: Path, conf: dict[str, str]) -> list[Path]:
    """Every background of a theme, the primary (find_background) first."""
    primary = find_background(theme_dir, conf)
    out = [primary] if primary else []
    for p in sorted(theme_dir.rglob("*")):
        if p in out or not p.is_file() or p.suffix.lower() in SKIP_EXT or NOT_BACKGROUND.search(p.name):
            continue
        if any(part.lower() in ("font", "fonts") for part in p.relative_to(theme_dir).parts):
            continue
        if palette.sniff(p) == "unknown" and p.suffix.lower() not in palette.VIDEO_EXT:
            continue
        if p.stat().st_size >= MIN_BACKGROUND_BYTES:
            out.append(p)
    return out


def parse_desktop(text: str) -> dict[str, str]:
    return parse_conf(text)


def slug_name(rel: Path) -> str:
    return re.sub(r"[^a-z0-9._-]+", "-", str(rel.with_suffix("")).lower()).strip("-._") or "background"


# ── install ─────────────────────────────────────────────────────────────────


def prefetch(up: Upstream, themes: list[str]) -> None:
    """Download all requested theme dirs in one round trip."""
    up.log(f"qylock: downloading {len(themes)} theme(s): {', '.join(themes)}")
    up.checkout(*(literal(f"themes/{t}") + "/" for t in themes))


def install(theme: str, dest: Path, up: Upstream | None = None) -> dict:
    """Write the pack for `theme` into dest (a new, empty directory)."""
    own = up is None
    up = up or Upstream(URL)
    try:
        theme = resolve(up, theme)
        path = f"themes/{theme}"
        root = up.checkout(literal(path) + "/")
        src = root / path
        if not src.is_dir():
            raise ImporterError(f"{path}: missing after checkout")

        dest.mkdir(parents=True, exist_ok=True)
        lock = dest / LOCK_PATH
        shutil.copytree(src, lock, ignore=shutil.ignore_patterns(".git", ".gitkeep", "__pycache__"))

        conf = parse_conf((src / "theme.conf").read_text(errors="replace")) if (src / "theme.conf").is_file() else {}
        meta = parse_desktop((src / "metadata.desktop").read_text(errors="replace")) if (src / "metadata.desktop").is_file() else {}
        backgrounds = find_backgrounds(src, conf)
        bgfile = backgrounds[0] if backgrounds else None

        theme_json: dict = {}
        notes = []
        swatches: list[tuple[str, float]] = []
        if bgfile is not None:
            video = palette.is_video(bgfile)
            if video and not palette.have_ffmpeg():
                notes.append("video background, no ffmpeg: palette not extracted")
            else:
                swatches = palette.quantize(palette.sample(bgfile))
                if swatches:
                    notes.append(f"palette from {'a frame of ' if video else ''}{bgfile.name}")
        # Wallpapers: every background, in place inside the design (stills),
        # or a frame of each video (wallpapers/<name>.jpg, noting the video);
        # without ffmpeg a video is listed as is (flagged: no still to show).
        images: list = []
        for bg in backgrounds:
            rel = f"{LOCK_PATH}/{bg.relative_to(src)}"
            if not palette.is_video(bg):
                if palette.sniff(bg) in ("png", "jpg", "webp", "gif"):
                    images.append(rel)
                continue
            frame = dest / "wallpapers" / (slug_name(bg.relative_to(src)) + ".jpg")
            frame.parent.mkdir(exist_ok=True)
            if palette.have_ffmpeg() and palette.ffmpeg_frame(bg, frame):
                images.append({"path": str(frame.relative_to(dest)), "video": rel})
            else:
                images.append(rel)
        # The default is the first still: `image` for a plain one; a video's
        # frame stays an `images` entry (first) so it keeps its video note.
        if images and isinstance(images[0], str) and not palette.is_video(dest / images[0]):
            theme_json["wallpaper"] = {"image": images[0]}
            if images[1:]:
                theme_json["wallpaper"]["images"] = images[1:]
        elif images:
            theme_json["wallpaper"] = {"images": images}
        if len(backgrounds) > 1:
            notes.append(f"{len(backgrounds)} backgrounds")
        h = hints(conf)
        if any(k in h for k in ("bg", "accent", "text", "surface", "polarity")):
            notes.append("theme.conf colors")
        if not swatches and "bg" not in h:
            notes.append("neutral fallback palette")
        polarity, pal = palette_for(conf, swatches)
        theme_json = {"polarity": polarity, "palette": pal, "glass": palette.glass(polarity, pal, busy=bool(swatches)), **theme_json}
        (dest / "theme.json").write_text(json.dumps(theme_json, indent=2) + "\n")
        if (dest / "wallpapers").is_dir() and not any((dest / "wallpapers").iterdir()):
            (dest / "wallpapers").rmdir()

        desc = meta.get("description") or f"qylock {theme}"
        manifest = {
            "name": pack_name(theme),
            "author": meta.get("author") or "Darkkal44",
            "version": "0.0.0+" + up.commit[:12],
            "license": LICENSE,
            "source": f"{URL}/tree/{up.commit}/{path}",
            "description": f"{desc} (imported: {', '.join(notes) or 'defaults'})",
            "upstream": {"importer": NAME, "url": up.url, "ref": up.ref, "commit": up.commit, "path": path},
            "lock": {"format": "qylock", "path": LOCK_PATH},
        }
        (dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest
    finally:
        if own:
            up.close()
