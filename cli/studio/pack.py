"""Theme packs: load, validate, hash and normalize.

A pack is a directory with `theme.json` (the core: palette + glass) and
`manifest.json` (name, author, version, license, source), plus optional
assets and `apps/<consumer file>` overrides. See docs/THEME-FORMAT.md.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from . import color

ROLES = ("bg", "surface", "overlay", "text", "subtext", "accent", "accent2", "urgent", "ok", "warn")

# Files and dirs never part of a pack's identity or an installed copy.
IGNORED = {".git", ".github", "__pycache__", ".DS_Store"}


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
        for p in self.files():
            h.update(str(p.relative_to(self.path)).encode() + b"\0")
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
    image = w.get("image", "")
    if image and not image.startswith("/"):
        # Copied next to theme.json so a rendered bundle is self-contained;
        # relative paths resolve against the rendered theme.json's directory.
        dest = "wallpaper" + Path(image).suffix
        assets.append((pack.path / image, dest))
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


def normalized_manifest(pack: Pack) -> dict:
    m = pack.manifest or {}
    return {
        "name": pack.name,
        "author": m.get("author", ""),
        "version": m.get("version", "0.0.0"),
        "license": m.get("license", "NOASSERTION"),
        "source": m.get("source", ""),
        "description": m.get("description", ""),
    }
