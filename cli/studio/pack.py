"""Theme packs: load, validate, hash and normalize.

A pack is a directory with `theme.json` (the core: palette + glass) and
`manifest.json` (name, author, version, license, source), plus optional
assets and `apps/<consumer file>` overrides. See docs/THEME-FORMAT.md.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from . import color, palette

ROLES = ("bg", "surface", "overlay", "text", "subtext", "accent", "accent2", "urgent", "ok", "warn")

# Files and dirs never part of a pack's identity or an installed copy.
IGNORED = {".git", ".github", "__pycache__", ".DS_Store"}

# Top-level dirs the renderer never reads (lock/greeter designs and wallpaper
# collections, often with large videos): only their file names and sizes go
# into the render-cache digest, so `apply` stays cheap. (The rendered
# manifest lists them, so adding or removing one still re-renders.)
NOT_RENDERED = {"lock", "locks", "greeter", "wallpapers"}

WALLPAPER_DIR = "wallpapers"
LOCKS_DIR = "locks"
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".avif", ".jxl"}
VIDEO_EXT = {".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v"}
PREVIEW_NAMES = ("preview", "screenshot")
LOCK_FORMATS = ("studio", "qylock")


def slug(text: str, fallback: str = "lock") -> str:
    return re.sub(r"[^a-z0-9._-]+", "-", text.lower()).strip("-._") or fallback


def media_kind(path: Path) -> str | None:
    """'image' | 'video' | None, by extension, else by magic bytes."""
    ext = path.suffix.lower()
    if ext in VIDEO_EXT:
        return "video"
    if ext in IMAGE_EXT:
        return "image"
    kind = palette.sniff(path)
    if kind == "video":
        return "video"
    return "image" if kind in ("png", "jpg", "webp", "gif") else None


def read_kv(path: Path) -> dict[str, str]:
    """key=value lines (metadata.desktop, theme.conf); first wins, keys as written."""
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if "=" in line and not line.startswith(("#", ";", "[")):
            k, v = line.split("=", 1)
            out.setdefault(k.strip(), v.strip().strip('"'))
    return out


class PackError(Exception):
    pass


def is_pack(path: Path) -> bool:
    return (path / "theme.json").is_file()


def _read_json(path: Path) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        raise PackError(f"{path}: invalid JSON: {e}") from e
    if not isinstance(data, dict):
        raise PackError(f"{path}: expected a JSON object")
    return data


class Pack:
    def __init__(self, path: Path):
        self.path = Path(path).resolve()
        if not is_pack(self.path):
            raise PackError(f"{path}: not a theme pack (no theme.json)")
        self.theme = _read_json(self.path / "theme.json")
        mf = self.path / "manifest.json"
        self.manifest = _read_json(mf) if mf.is_file() else None

    @property
    def name(self) -> str:
        # The manifest is canonical; older packs only had theme.json's name.
        if self.manifest and self.manifest.get("name"):
            return self.manifest["name"]
        return self.theme.get("name") or self.path.name

    def abspath(self, p: str) -> Path:
        q = Path(p).expanduser()
        return q if q.is_absolute() else self.path / q

    # ── wallpapers ──────────────────────────────────────────────────────

    def wallpaper_entries(self) -> list[dict]:
        """The pack's wallpaper collection, in order:
        `wallpaper.image`, `wallpaper.images`, then `wallpapers/` (sorted).

        Each entry: {path, kind ("image" | "video"), video?, preview?} with
        absolute Paths. A still with a video (`{"path", "video"}` in
        theme.json, or `wallpapers/x.jpg` next to `wallpapers/x.mp4`) is one
        image entry that notes its video; a video without a still is a
        "video" entry (listed, flagged: the shell's image layer can't show it).
        """
        w = self.theme.get("wallpaper")
        w = w if isinstance(w, dict) else {}
        raw: list = []
        if isinstance(w.get("image"), str) and w["image"]:
            raw.append(w["image"])
        raw += [i for i in w.get("images", []) if isinstance(i, (str, dict))]
        out: list[dict] = []
        seen: dict[str, dict | None] = {}

        def key(p: Path) -> str:
            try:
                return str(p.resolve())
            except OSError:
                return str(p)

        def add(path: Path, video: Path | None = None, preview: Path | None = None) -> None:
            k = key(path)
            if k in seen:
                # Listed twice (e.g. `image` and an `images` entry noting its
                # video): one entry, with the extra details merged in.
                e = seen[k]
                if e is not None:
                    if video is not None:
                        e["video"] = video
                    if preview is not None:
                        e.setdefault("preview", preview)
                return
            if video is not None:
                seen[key(video)] = None
            kind = media_kind(path) or "image"
            e: dict = {"path": path, "kind": kind}
            if video is not None:
                e["video"] = video
            elif kind == "video":
                e["video"] = path
            if preview is not None:
                e["preview"] = preview
            seen[k] = e
            out.append(e)

        for item in raw:
            if isinstance(item, str):
                add(self.abspath(item))
            elif isinstance(item.get("path"), str):
                add(
                    self.abspath(item["path"]),
                    self.abspath(item["video"]) if isinstance(item.get("video"), str) else None,
                    self.abspath(item["preview"]) if isinstance(item.get("preview"), str) else None,
                )
        wdir = self.path / WALLPAPER_DIR
        if wdir.is_dir():
            files = [(p, media_kind(p)) for p in sorted(wdir.iterdir()) if p.is_file() and not p.name.startswith(".")]
            files = [(p, k) for p, k in files if k]
            stills = {p.stem for p, k in files if k == "image"}
            videos = {p.stem: p for p, k in files if k == "video"}
            for p, k in files:
                if k == "video" and p.stem in stills:
                    continue  # shown through its still
                if key(p) in seen:
                    continue
                add(p, videos.get(p.stem) if k == "image" else None)
        return out

    def default_wallpaper(self) -> dict | None:
        """`wallpaper.image` when set, else the collection's first still."""
        entries = self.wallpaper_entries()
        w = self.theme.get("wallpaper")
        if isinstance(w, dict) and isinstance(w.get("image"), str) and w["image"] and entries:
            return entries[0]
        return next((e for e in entries if e["kind"] == "image"), None)

    # ── lock designs ────────────────────────────────────────────────────

    def lock_entries(self) -> list[dict]:
        """Lock designs, the default first: manifest `lock` (else the
        conventional `lock/Main.qml`), then `locks`, then `locks/<dir>/`.

        Each: {name, format, path, main, preview?, background?} (Paths)."""
        m = self.manifest or {}
        specs: list[dict] = []
        if isinstance(m.get("lock"), dict) and m["lock"].get("path"):
            specs.append(dict(m["lock"], _auto=False))
        elif (self.path / "lock" / "Main.qml").is_file():
            specs.append({"format": "studio", "path": "lock", "_auto": True})
        specs += [dict(spec, _auto=False) for spec in m.get("locks", []) if isinstance(spec, dict) and spec.get("path")]
        ldir = self.path / LOCKS_DIR
        if ldir.is_dir():
            for d in sorted(ldir.iterdir()):
                if d.is_dir() and ((d / "Main.qml").is_file() or (d / "metadata.desktop").is_file()):
                    specs.append({"path": str(d), "_auto": True, "_dirname": True})
        out: list[dict] = []
        seen_paths: set[str] = set()
        names: set[str] = set()
        for spec in specs:
            path = self.abspath(spec["path"])
            if str(path) in seen_paths:
                continue
            seen_paths.add(str(path))
            meta = read_kv(path / "metadata.desktop")
            fmt = spec.get("format") or ("qylock" if meta else "studio")
            main = path / (meta.get("MainScript") or "Main.qml") if fmt == "qylock" else path / "Main.qml"
            name = spec.get("name") or (
                slug(meta["Name"]) if meta.get("Name") else slug(path.name) if spec.get("_dirname") else slug(self.name)
            )
            base, n = name, 2
            while name in names:
                name, n = f"{base}-{n}", n + 1
            names.add(name)
            e: dict = {"name": name, "format": fmt, "path": path, "main": main}
            if isinstance(spec.get("preview"), str):
                e["preview"] = self.abspath(spec["preview"])
            else:
                for stem in PREVIEW_NAMES:
                    hit = next((p for p in sorted(path.glob(stem + ".*")) if p.suffix.lower() in IMAGE_EXT), None)
                    if hit:
                        e["preview"] = hit
                        break
            if fmt == "qylock":
                conf = read_kv(path / (meta.get("ConfigFile") or "theme.conf"))
                bg = conf.get("background", "")
                if bg and (path / bg).is_file() and media_kind(path / bg) == "image":
                    e["background"] = path / bg
            out.append(e)
        return out

    def files(self) -> list[Path]:
        out = []
        for p in sorted(self.path.rglob("*")):
            rel = p.relative_to(self.path)
            if any(part in IGNORED for part in rel.parts) or not p.is_file():
                continue
            out.append(p)
        return out

    def digest(self, salt: str = "") -> str:
        """Content hash of the pack (plus renderer salt), for the render cache."""
        h = hashlib.sha256(salt.encode())
        default = self.default_wallpaper()
        copied = str(default["path"]) if default else ""
        for p in self.files():
            rel = p.relative_to(self.path)
            h.update(str(rel).encode() + b"\0")
            if rel.parts[0] in NOT_RENDERED and str(p) != copied:
                h.update(str(p.stat().st_size).encode() + b"\0")
            else:
                h.update(p.read_bytes() + b"\0")
        return h.hexdigest()[:16]

    def validate(self, schema_path: Path, require_manifest: bool = False) -> None:
        """Raise PackError with every problem found.

        Uses jsonschema when available (always, in the Nix-packaged CLI) and
        falls back to the essential checks when run with a bare python3.
        """
        errors: list[str] = []
        if self.manifest is None and require_manifest:
            errors.append("manifest.json: missing")
        try:
            import jsonschema  # type: ignore
        except ImportError:
            jsonschema = None
        schema = json.loads(Path(schema_path).read_text())
        if jsonschema is not None:
            docs = [("theme.json", "theme", self.theme)]
            if self.manifest is not None:
                docs.append(("manifest.json", "manifest", self.manifest))
            for fname, defn, doc in docs:
                sub = {"$schema": schema["$schema"], "$defs": schema["$defs"], "$ref": f"#/$defs/{defn}"}
                v = jsonschema.Draft202012Validator(sub)
                for err in sorted(v.iter_errors(doc), key=lambda e: list(e.path)):
                    where = "/".join(str(p) for p in err.path) or "(root)"
                    errors.append(f"{fname}: {where}: {err.message}")
        else:
            errors += _basic_check(self.theme)
        img = self.theme.get("wallpaper", {}).get("image") if isinstance(self.theme.get("wallpaper"), dict) else None
        if isinstance(img, str) and img and not img.startswith("/"):
            if not (self.path / img).is_file():
                errors.append(f"theme.json: wallpaper/image: {img} not found in the pack")
        w = self.theme.get("wallpaper") if isinstance(self.theme.get("wallpaper"), dict) else {}
        images = w.get("images") if isinstance(w.get("images"), list) else []
        for i, item in enumerate(images):
            refs = [("", item)] if isinstance(item, str) else [(f"/{k}", item.get(k)) for k in ("path", "video", "preview")] if isinstance(item, dict) else []
            for sub, ref in refs:
                if isinstance(ref, str) and ref and not ref.startswith("/") and not (self.path / ref).is_file():
                    errors.append(f"theme.json: wallpaper/images/{i}{sub}: {ref} not found in the pack")
        m = self.manifest or {}
        specs = [("lock", m.get("lock"))] + [(f"locks/{i}", spec) for i, spec in enumerate(m.get("locks", []) if isinstance(m.get("locks"), list) else [])]
        for where, spec in specs:
            if isinstance(spec, dict) and isinstance(spec.get("path"), str) and not spec["path"].startswith("/"):
                if not (self.path / spec["path"]).is_dir():
                    errors.append(f"manifest.json: {where}/path: {spec['path']} not found in the pack")
        if errors:
            raise PackError(f"{self.path}: invalid theme pack\n  " + "\n  ".join(errors))


def _basic_check(theme: dict) -> list[str]:
    errors = []
    pal = theme.get("palette")
    if not isinstance(pal, dict):
        return ["theme.json: palette: required object"]
    for role in ROLES:
        v = pal.get(role)
        if not isinstance(v, str) or not color.HEX.match(v) or len(v) != 7:
            errors.append(f"theme.json: palette/{role}: expected #rrggbb, got {v!r}")
    if theme.get("polarity", "dark") not in ("dark", "light"):
        errors.append("theme.json: polarity: expected dark or light")
    return errors


def derive_ansi(pal: dict, dark: bool) -> list[str]:
    """16 terminal colors from the semantic palette.

    Normal hues map to the roles (red=urgent, green=ok, yellow=warn,
    blue=accent, magenta=accent2) and cyan is the accent rotated to 190°.
    The black/white slots come from the surface ramp so terminals sit on the
    same grays as the shell; bright variants step toward the text side.
    """
    step = 0.08 if dark else -0.08
    hues = [pal["urgent"], pal["ok"], pal["warn"], pal["accent"], pal["accent2"], color.with_hue(pal["accent"], 190)]
    if dark:
        black, white, bright_black, bright_white = pal["surface"], pal["subtext"], pal["overlay"], pal["text"]
    else:
        black, white, bright_black, bright_white = pal["text"], pal["overlay"], pal["subtext"], pal["surface"]
    normal = [black] + hues + [white]
    bright = [bright_black] + [color.lighten(c, step) for c in hues] + [bright_white]
    return [color.hex6(c) for c in normal + bright]


def normalize(pack: Pack) -> tuple[dict, list[tuple[Path, str]]]:
    """The theme with every key filled in, plus assets to copy alongside it.

    This is what the shell reads (`current/theme.json`) and what every
    template renders from, so defaults live in exactly one place.
    """
    t = pack.theme
    pal_in = t["palette"]
    polarity = t.get("polarity", "dark")
    dark = polarity != "light"

    pal = {role: color.hex6(pal_in[role]) for role in ROLES}
    # Extra palette entries (e.g. base16 slots) pass through for consumers.
    pal.update({k: v for k, v in pal_in.items() if k not in pal})

    g = t.get("glass", {})
    blur = bool(g.get("blur", True))
    glass = {
        "blur": blur,
        "xray": bool(g.get("xray", True)),
        "tint": color.hex6(g.get("tint", pal["bg"])),
        "opacity": float(g.get("opacity", 0.45 if dark else 0.5)),
        "border": color.hex6(g.get("border", "#ffffff")),
        "borderOpacity": float(g.get("borderOpacity", 0.14 if dark else 0.6)),
        "radius": g.get("radius", 14),
        "noise": float(g.get("noise", 0.02)),
        "saturation": float(g.get("saturation", 1.6)),
        # Terminals need more body than shell glass to stay readable.
        "terminalOpacity": float(g.get("terminalOpacity", 0.85 if blur else 1.0)),
        "shadow": g.get("shadow", "#00000066" if dark else "#0000002e").lower(),
    }

    assets: list[tuple[Path, str]] = []
    w = t.get("wallpaper", {})
    gradient = [color.hex6(c) for c in w.get("gradient", [])] or [
        pal["bg"],
        color.mix(pal["bg"], pal["accent"], 0.35),
        color.mix(pal["bg"], pal["accent2"], 0.6),
    ]
    # The default wallpaper: `wallpaper.image`, else the collection's first still.
    default = pack.default_wallpaper()
    image = str(default["path"]) if default else ""
    if default and pack.path in default["path"].parents:
        # Copied next to theme.json so a rendered bundle is self-contained;
        # relative paths resolve against the rendered theme.json's directory.
        dest = "wallpaper" + default["path"].suffix.lower()
        assets.append((default["path"], dest))
        image = dest
    wallpaper = {"gradient": gradient, "image": image}

    f = t.get("fonts", {})
    fonts = {"ui": f.get("ui", "sans-serif"), "mono": f.get("mono", "monospace"), "size": f.get("size", 11)}

    ansi = [color.hex6(c) for c in t["ansi"]] if "ansi" in t else derive_ansi(pal, dark)

    norm = {
        "name": pack.name,
        "polarity": polarity,
        "palette": pal,
        "ansi": ansi,
        "glass": glass,
        "wallpaper": wallpaper,
        "fonts": fonts,
        "radii": {"window": t.get("radii", {}).get("window", 12)},
    }
    return norm, assets


def wallpaper_json(e: dict, source: str, **extra) -> dict:
    out = {"path": str(e["path"]), "source_pack": source, "kind": e["kind"]}
    for k in ("video", "preview"):
        if k in e:
            out[k] = str(e[k])
    out.update(extra)
    return out


def lock_json(e: dict, source: str, **extra) -> dict:
    out = {"name": e["name"], "format": e["format"], "path": str(e["path"]), "main": str(e["main"]), "source_pack": source}
    for k in ("preview", "background"):
        if k in e:
            out[k] = str(e[k])
    out.update(extra)
    return out


def normalized_manifest(pack: Pack, curated: dict | None = None) -> dict:
    """The manifest the shell reads: identity, plus every wallpaper and lock
    design with absolute paths (the pack's own, then `curated` ones resolved
    from other installed packs), and the defaults."""
    m = pack.manifest or {}
    out = {
        "name": pack.name,
        "author": m.get("author", ""),
        "version": m.get("version", "0.0.0"),
        "license": m.get("license", "NOASSERTION"),
        "source": m.get("source", ""),
        "description": m.get("description", ""),
    }
    if isinstance(m.get("upstream"), dict):
        out["upstream"] = m["upstream"]
    # Lock designs and wallpapers are not copied into the rendered bundle:
    # the loader and the shell read them from the pack (absolute paths).
    curated = curated or {}
    walls = [wallpaper_json(e, pack.name) for e in pack.wallpaper_entries()]
    seen = {w["path"] for w in walls}
    for w in curated.get("wallpapers", []):
        if w["path"] not in seen:
            seen.add(w["path"])
            walls.append(dict(w, curated=True))
    locks = [lock_json(e, pack.name) for e in pack.lock_entries()]
    seen = {lk["path"] for lk in locks}
    for lk in curated.get("locks", []):
        if lk["path"] not in seen:
            seen.add(lk["path"])
            locks.append(dict(lk, curated=True))
    default_wall = pack.default_wallpaper()
    out["wallpapers"] = walls
    out["locks"] = locks
    out["defaults"] = {
        "wallpaper": str(default_wall["path"]) if default_wall else "",
        "lock": locks[0]["path"] if locks and not locks[0].get("curated") else "",
    }
    if out["defaults"]["lock"]:
        d = locks[0]
        # Shorthand for loaders that only know one design.
        out["lock"] = {"name": d["name"], "format": d["format"], "path": d["path"], "main": d["main"]}
    if isinstance(m.get("vibes"), dict):
        out["vibes"] = m["vibes"]
    if (pack.path / "greeter").is_dir():
        out["greeter"] = {"path": str(pack.path / "greeter")}
    return out
