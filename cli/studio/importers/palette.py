"""Palette derivation for importers: image sampling, quantization, role mapping.

Dependency choice: no new Python modules. Images are sampled through
`ffmpeg` when it is on PATH (stills of any format *and* video frames, scaled
down by ffmpeg itself; the Nix-packaged `studio` puts ffmpeg-headless on its
PATH, whose libraries Quickshell's closure already carries). Without ffmpeg,
PNGs are decoded by the small pure-Python decoder below (stdlib zlib); other
formats then yield no samples and the importer falls back to a neutral
palette. Quantization is median cut refined by a few k-means passes, in pure
Python on at most a few thousand pixels.

Role mapping (`scheme`) takes whatever an importer knows (explicit colors
from a theme's config, or swatches from an image) and fills the ten semantic
roles of themes/schema.json, keeping given colors as they are unless they
fail a minimum contrast against bg.
"""

from __future__ import annotations

import colorsys
import shutil
import struct
import subprocess
import zlib
from pathlib import Path

from .. import color

RGB = tuple[int, int, int]

# ── image sampling ──────────────────────────────────────────────────────────

SAMPLE_SIZE = 64  # pixels per side handed to the quantizer
VIDEO_EXT = {".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v", ".gif"}


def sniff(path: Path) -> str:
    """'png' | 'jpg' | 'webp' | 'gif' | 'video' | 'unknown', by magic bytes."""
    try:
        with open(path, "rb") as f:
            head = f.read(16)
    except OSError:
        return "unknown"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if head.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if head[4:8] == b"ftyp" or head.startswith(b"\x1aE\xdf\xa3"):
        return "video"
    return "unknown"


def is_video(path: Path) -> bool:
    return sniff(path) == "video" or (sniff(path) == "unknown" and path.suffix.lower() in VIDEO_EXT)


def have_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


def _ffmpeg(args: list[str]) -> bytes:
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", *args], capture_output=True)
    return r.stdout if r.returncode == 0 else b""


def ffmpeg_sample(path: Path, size: int = SAMPLE_SIZE) -> list[RGB]:
    """Downscaled pixels of an image, or of a frame ~1 s into a video."""
    scale = f"scale={size}:{size}:flags=area"
    out = b""
    seeks = (["-ss", "1"], []) if is_video(path) else ([],)
    for seek in seeks:
        out = _ffmpeg([*seek, "-i", str(path), "-frames:v", "1", "-vf", scale, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
        if out:
            break
    return [tuple(out[i : i + 3]) for i in range(0, len(out) - 2, 3)]  # type: ignore[misc]


def ffmpeg_frame(video: Path, out: Path) -> bool:
    """Write a full-size still of the video's frame ~1 s in (for the wallpaper)."""
    for seek in (["-ss", "1"], []):
        _ffmpeg(["-y", *seek, "-i", str(video), "-frames:v", "1", "-update", "1", str(out)])
        if out.is_file() and out.stat().st_size > 0:
            return True
    return False


class PNGError(ValueError):
    pass


def decode_png(data: bytes, max_side: int = SAMPLE_SIZE) -> list[RGB]:
    """Pure-Python PNG decode, sampled down to about max_side × max_side pixels.

    Handles 8/16-bit gray, RGB, palette, gray+alpha and RGBA, non-interlaced.
    Every row has to be unfiltered (filters chain row to row), so this is
    O(width × height) in Python: fine for wallpapers up to ~4K (a few
    seconds); ffmpeg is preferred when present.
    """
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise PNGError("not a PNG")
    pos, idat, plte = 8, [], b""
    w = h = depth = ctype = interlace = 0
    while pos + 8 <= len(data):
        length, typ = struct.unpack(">I4s", data[pos : pos + 8])
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if typ == b"IHDR":
            w, h, depth, ctype, _comp, _filt, interlace = struct.unpack(">IIBBBBB", chunk)
        elif typ == b"PLTE":
            plte = chunk
        elif typ == b"IDAT":
            idat.append(chunk)
        elif typ == b"IEND":
            break
    if not w or not h:
        raise PNGError("no IHDR")
    if interlace:
        raise PNGError("interlaced PNGs are not supported")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if channels is None or depth not in (8, 16) and not (ctype == 3 and depth == 8):
        raise PNGError(f"unsupported PNG (color type {ctype}, depth {depth})")
    bpp = channels * depth // 8
    stride = w * bpp
    raw = zlib.decompress(b"".join(idat))
    step = max(1, max(w, h) // max_side)
    prev = bytearray(stride)
    out: list[RGB] = []
    off = 0
    for y in range(h):
        ftype = raw[off]
        line = bytearray(raw[off + 1 : off + 1 + stride])
        off += 1 + stride
        if ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            line = bytearray((a + b) & 0xFF for a, b in zip(line, prev))
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif ftype != 0:
            raise PNGError(f"bad filter type {ftype}")
        prev = line
        if y % step:
            continue
        hi = 2 if depth == 16 else 1  # 16-bit: take the high byte
        for x in range(0, w, step):
            px = line[x * bpp : (x + 1) * bpp]
            if ctype == 3:
                i = px[0] * 3
                out.append(tuple(plte[i : i + 3]) if i + 3 <= len(plte) else (0, 0, 0))  # type: ignore[arg-type]
            elif ctype in (0, 4):
                g = px[0]
                out.append((g, g, g))
            else:
                out.append((px[0], px[hi], px[2 * hi]))
    return out


def sample(path: Path) -> list[RGB]:
    """Pixels of an image or video frame for quantization ([] if unreadable)."""
    path = Path(path)
    if have_ffmpeg():
        px = ffmpeg_sample(path)
        if px:
            return px
    if sniff(path) == "png":
        try:
            return decode_png(path.read_bytes())
        except (PNGError, zlib.error, struct.error):
            return []
    return []


# ── quantization ────────────────────────────────────────────────────────────


def quantize(pixels: list[RGB], k: int = 8, iters: int = 6) -> list[tuple[str, float]]:
    """Dominant colors as [(#rrggbb, weight)], heaviest first. Deterministic."""
    if not pixels:
        return []
    # Median cut: split the box with the widest channel range at its median.
    boxes = [list(pixels)]
    while len(boxes) < k:
        best, best_range, best_ch = -1, 0, 0
        for i, box in enumerate(boxes):
            if len(box) < 2:
                continue
            for ch in range(3):
                vals = [p[ch] for p in box]
                r = max(vals) - min(vals)
                if r > best_range:
                    best, best_range, best_ch = i, r, ch
        if best < 0 or best_range == 0:
            break
        box = sorted(boxes.pop(best), key=lambda p: p[best_ch])
        mid = len(box) // 2
        boxes += [box[:mid], box[mid:]]
    centers = [tuple(sum(p[c] for p in b) / len(b) for c in range(3)) for b in boxes if b]
    # k-means refinement from the median-cut centers.
    counts = [0] * len(centers)
    for _ in range(iters):
        sums = [[0.0, 0.0, 0.0] for _ in centers]
        counts = [0] * len(centers)
        for p in pixels:
            j = min(range(len(centers)), key=lambda i: _d2(p, centers[i]))
            s = sums[j]
            s[0] += p[0]
            s[1] += p[1]
            s[2] += p[2]
            counts[j] += 1
        centers = [tuple(s[c] / n for c in range(3)) if n else centers[i] for i, (s, n) in enumerate(zip(sums, counts))]
    total = sum(counts) or 1
    out = [(_hex(c), n / total) for c, n in zip(centers, counts) if n]
    # Merge clusters that converged onto the same color.
    merged: dict[str, float] = {}
    for h, wgt in out:
        merged[h] = merged.get(h, 0.0) + wgt
    return sorted(merged.items(), key=lambda t: -t[1])


def _d2(p, q) -> float:
    return (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 + (p[2] - q[2]) ** 2


def _hex(c) -> str:
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(v))) for v in c)


# ── color math ──────────────────────────────────────────────────────────────


def hls(c: str) -> tuple[float, float, float]:
    r, g, b, _ = color.parse(c)
    return colorsys.rgb_to_hls(r, g, b)


def from_hls(h: float, l: float, s: float) -> str:
    r, g, b = colorsys.hls_to_rgb(h % 1.0, min(1.0, max(0.0, l)), min(1.0, max(0.0, s)))
    return _hex((r * 255, g * 255, b * 255))


def chroma(c: str) -> float:
    r, g, b, _ = color.parse(c)
    return max(r, g, b) - min(r, g, b)


def hue_distance(a: str, b: str) -> float:
    """0..180 degrees."""
    d = abs(hls(a)[0] - hls(b)[0]) * 360
    return min(d, 360 - d)


def tone(c: str, *, l: tuple[float, float] = (0.0, 1.0), s: tuple[float, float] = (0.0, 1.0)) -> str:
    """Clamp HSL lightness and saturation into ranges, keeping hue."""
    h, li, si = hls(c)
    return from_hls(h, min(max(li, l[0]), l[1]), min(max(si, s[0]), s[1]))


def ensure_contrast(fg: str, bg: str, minimum: float) -> str:
    """Move fg's lightness away from bg until it reaches the contrast ratio."""
    if color.contrast(fg, bg) >= minimum:
        return color.hex6(fg)
    h, l, s = hls(fg)
    direction = 1 if color.luminance(bg) < 0.18 else -1
    for _ in range(40):
        l += 0.02 * direction
        cand = from_hls(h, l, s)
        if color.contrast(cand, bg) >= minimum or l <= 0 or l >= 1:
            return cand
    return from_hls(h, l, s)


def polarity_of(bg: str) -> str:
    return "light" if color.luminance(bg) > 0.3 else "dark"


# Semantic hues for urgent/ok/warn, nudged toward the accent (harmonized).
SEMANTIC_HUES = {"urgent": 355.0, "ok": 130.0, "warn": 40.0}


def semantic(role: str, accent: str, bg: str, dark: bool) -> str:
    base = SEMANTIC_HUES[role]
    ah = hls(accent)[0] * 360
    delta = (ah - base + 180) % 360 - 180
    hue = base + max(-12.0, min(12.0, delta * 0.15))
    s = min(max(hls(accent)[2], 0.5), 0.75)
    l = 0.68 if dark else 0.42
    return ensure_contrast(from_hls(hue / 360, l, s), bg, 3.0)


def pick_distinct(base: str, candidates: list[str]) -> str | None:
    """The candidate that differs most from base in hue (weighted by how
    colorful it is) and, secondarily, in RGB distance."""
    best, best_score = None, -1.0
    for c in candidates:
        if not c or color.hex6(c) == color.hex6(base):
            continue
        hd = hue_distance(base, c) / 180 * min(1.0, chroma(c) / 0.15)
        rd = (_d2(_rgb(base), _rgb(c)) ** 0.5) / 441.7
        score = hd + 0.25 * rd
        if score > best_score:
            best, best_score = color.hex6(c), score
    return best


def _rgb(c: str) -> RGB:
    r, g, b, _ = color.parse(c)
    return (round(r * 255), round(g * 255), round(b * 255))


# ── role mapping ────────────────────────────────────────────────────────────

NEUTRAL_DARK = {"bg": "#16171d", "text": "#d6d8e0", "accent": "#8aa4d6"}


def scheme(
    *,
    bg: str | None = None,
    text: str | None = None,
    accent: str | None = None,
    accent2: str | None = None,
    surface: str | None = None,
    overlay: str | None = None,
    subtext: str | None = None,
    urgent: str | None = None,
    ok: str | None = None,
    warn: str | None = None,
    polarity: str | None = None,
    swatches: list[tuple[str, float]] | None = None,
) -> tuple[str, dict[str, str]]:
    """(polarity, palette with all ten roles).

    Explicit colors win; missing ones come from image swatches when given,
    then from derivations of bg/text/accent. Given colors are kept as is,
    except that text and accents are pushed to minimum contrast against bg.
    """
    sw = [(color.hex6(c), w) for c, w in (swatches or [])]
    if polarity is None:
        if bg:
            polarity = polarity_of(bg)
        elif sw:
            mean_l = sum(hls(c)[1] * w for c, w in sw) / (sum(w for _, w in sw) or 1)
            polarity = "light" if mean_l > 0.62 else "dark"
        else:
            polarity = "dark"
    dark = polarity != "light"

    if bg is None:
        if sw:
            heavy = [c for c, w in sw if w >= 0.06] or [c for c, _ in sw]
            pick = min(heavy, key=lambda c: hls(c)[1]) if dark else max(heavy, key=lambda c: hls(c)[1])
            bg = tone(pick, l=(0.06, 0.12), s=(0.0, 0.35)) if dark else tone(pick, l=(0.93, 0.97), s=(0.0, 0.3))
        else:
            bg = NEUTRAL_DARK["bg"] if dark else "#eff0f3"
    bg = color.hex6(bg)
    bh, bl, bs = hls(bg)

    if text is None:
        text = from_hls(bh, 0.88, min(bs, 0.25)) if dark else from_hls(bh, 0.22, min(bs, 0.25))
    text = ensure_contrast(text, bg, 4.5)

    if accent is None:
        colorful = sorted(sw, key=lambda t: -(chroma(t[0]) * t[1] ** 0.35))
        if colorful and chroma(colorful[0][0]) > 0.06:
            accent = colorful[0][0]
            accent = tone(accent, l=(0.6, 0.78), s=(0.45, 0.9)) if dark else tone(accent, l=(0.35, 0.5), s=(0.45, 0.9))
        else:
            accent = NEUTRAL_DARK["accent"] if dark else "#3b5fa8"
    accent = ensure_contrast(accent, bg, 3.0)

    if accent2 is None:
        cands = [c for c, _ in sw if chroma(c) > 0.06 and hue_distance(c, accent) >= 35]
        if cands:
            accent2 = pick_distinct(accent, cands) or cands[0]
            accent2 = tone(accent2, l=(0.6, 0.8), s=(0.4, 0.9)) if dark else tone(accent2, l=(0.33, 0.5), s=(0.4, 0.9))
        else:
            ah, al, as_ = hls(accent)
            accent2 = from_hls(ah + 50 / 360, al, as_)
    accent2 = ensure_contrast(accent2, bg, 3.0)

    if surface is None:
        surface = from_hls(bh, bl + (0.06 if dark else -0.035), bs)
    if overlay is None:
        overlay = color.mix(surface, text, 0.22)
    if subtext is None:
        subtext = color.mix(text, bg, 0.3)
    subtext = ensure_contrast(subtext, bg, 3.0)

    pal = {
        "bg": bg,
        "surface": color.hex6(surface),
        "overlay": color.hex6(overlay),
        "text": text,
        "subtext": subtext,
        "accent": accent,
        "accent2": accent2,
        "urgent": color.hex6(urgent) if urgent else semantic("urgent", accent, bg, dark),
        "ok": color.hex6(ok) if ok else semantic("ok", accent, bg, dark),
        "warn": color.hex6(warn) if warn else semantic("warn", accent, bg, dark),
    }
    return polarity, pal


def glass(polarity: str, pal: dict[str, str], *, busy: bool = False) -> dict:
    """A sensible glass block: tinted with bg, a touch more opaque over busy wallpapers."""
    dark = polarity != "light"
    return {
        "blur": True,
        "xray": True,
        "tint": pal["bg"] if dark else color.mix(pal["bg"], "#ffffff", 0.5),
        "opacity": (0.55 if busy else 0.48) if dark else (0.6 if busy else 0.52),
        "border": "#ffffff",
        "borderOpacity": 0.12 if dark else 0.55,
        "radius": 14,
    }
