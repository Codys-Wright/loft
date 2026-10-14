"""Scrolling capture: stitch screenshots of a scrolling area into one tall image.

Frames are grabbed from the same screen rectangle while its content scrolls
(grim -t ppm). Consecutive frames are compared row by row: every pixel row
gets a hash, and the scroll distance between two frames is the vertical
shift that lines up the most rows of the new frame with the previous one.

  * Sticky headers and footers (toolbars, tab bars, status lines) are rows
    that sit at the same place in both frames. They are left out of the
    matching and kept once: the header from the first frame, the footer from
    the last.
  * Rows of a single color (blank lines, margins) match anything, so they
    don't count as evidence for a shift.
  * The rightmost few pixels are ignored when hashing: overlay scrollbars
    move as the content scrolls.
  * A frame that matches its predecessor 1:1, or only changed in a few rows
    (a blinking caret), adds nothing. A frame that only lines up with a
    *negative* shift (scrolled back up) adds nothing either. A frame that
    lines up with nothing (scrolled further than one screen between grabs)
    is appended whole below the rest and counted as a gap.

Pure Python: frames are binary PPM (P6), the result is written as PNG with
zlib, so the stitcher needs no imaging library.
"""

from __future__ import annotations

import os
import struct
import zlib
from dataclasses import dataclass, field
from pathlib import Path

# ── Images ──────────────────────────────────────────────────────────────


@dataclass
class Image:
    width: int
    height: int
    data: bytes  # RGB, row-major, 3 bytes per pixel

    def row(self, y: int) -> bytes:
        n = self.width * 3
        return self.data[y * n : (y + 1) * n]


def _ppm_token(buf: bytes, i: int) -> tuple[bytes, int]:
    while True:
        while buf[i : i + 1].isspace():
            i += 1
        if buf[i : i + 1] == b"#":
            while buf[i : i + 1] not in (b"\n", b""):
                i += 1
            continue
        break
    j = i
    while j < len(buf) and not buf[j : j + 1].isspace():
        j += 1
    return buf[i:j], j


def parse_ppm(buf: bytes) -> Image:
    magic, i = _ppm_token(buf, 0)
    if magic != b"P6":
        raise ValueError("not a binary PPM (P6)")
    w, i = _ppm_token(buf, i)
    h, i = _ppm_token(buf, i)
    mx, i = _ppm_token(buf, i)
    width, height, maxval = int(w), int(h), int(mx)
    if maxval != 255:
        raise ValueError(f"unsupported PPM maxval {maxval}")
    i += 1  # the single whitespace after maxval
    data = buf[i : i + width * height * 3]
    if len(data) != width * height * 3:
        raise ValueError("truncated PPM")
    return Image(width, height, data)


def read_ppm(path: str | os.PathLike) -> Image:
    return parse_ppm(Path(path).read_bytes())


def ppm_bytes(img: Image) -> bytes:
    return b"P6\n%d %d\n255\n" % (img.width, img.height) + img.data


def write_ppm(path: str | os.PathLike, img: Image) -> None:
    Path(path).write_bytes(ppm_bytes(img))


def png_bytes(width: int, height: int, rows) -> bytes:
    """An 8-bit RGB PNG from an iterable of `height` rows of RGB bytes."""

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    comp = zlib.compressobj(6)
    parts = []
    n = 0
    for r in rows:
        parts.append(comp.compress(b"\x00" + r))
        n += 1
    if n != height:
        raise ValueError(f"expected {height} rows, got {n}")
    parts.append(comp.flush())
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", b"".join(parts)) + chunk(b"IEND", b"")


def read_png(path: str | os.PathLike) -> Image:
    """Read an 8-bit RGB/RGBA non-interlaced PNG (for tests and previews)."""
    buf = Path(path).read_bytes()
    if buf[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    i, idat = 8, []
    width = height = ctype = 0
    while i < len(buf):
        (ln,) = struct.unpack(">I", buf[i : i + 4])
        kind, body = buf[i + 4 : i + 8], buf[i + 8 : i + 8 + ln]
        i += 12 + ln
        if kind == b"IHDR":
            width, height, depth, ctype, _c, _f, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError("only 8-bit RGB/RGBA non-interlaced PNGs")
        elif kind == b"IDAT":
            idat.append(body)
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(b"".join(idat))
    stride = width * bpp
    out = bytearray()
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        ft = raw[pos]
        line = bytearray(raw[pos + 1 : pos + 1 + stride])
        pos += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if ft == 1:
                line[x] = (line[x] + a) & 255
            elif ft == 2:
                line[x] = (line[x] + b) & 255
            elif ft == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        if bpp == 4:
            del line[3::4]
        out += line
    return Image(width, height, bytes(out))


# ── Row signatures ──────────────────────────────────────────────────────


def ignored_right(width: int) -> int:
    """Pixels at the right edge left out of the row hashes (scrollbars)."""
    return 0 if width < 64 else min(24, max(8, width // 40))


def signature(img: Image, trim: int | None = None) -> tuple[list[int], list[bool]]:
    """Per row: a hash of its pixels (minus the right edge), and whether the
    row is informative (not a single solid color)."""
    trim = ignored_right(img.width) if trim is None else trim
    n = img.width * 3
    used = (img.width - trim) * 3
    hashes, info = [], []
    d = img.data
    for y in range(img.height):
        o = y * n
        r = d[o : o + used]
        hashes.append(hash(r))
        info.append(r != r[:3] * (used // 3))
    return hashes, info


# ── Matching ────────────────────────────────────────────────────────────


@dataclass
class Match:
    kind: str  # same | added | back | gap
    shift: int = 0  # rows the content moved up (new rows at the bottom)
    top: int = 0  # rows equal at the top of both frames (sticky header)
    bottom: int = 0  # … at the bottom (sticky footer)
    score: float = 0.0


def _prefix(a: list[int], b: list[int]) -> int:
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def match(prev: tuple[list[int], list[bool]], cur: tuple[list[int], list[bool]], threshold: float = 0.9) -> Match:
    """How `cur` continues `prev` (both signatures of equally sized frames)."""
    ph, pinfo = prev
    ch, cinfo = cur
    h = len(ph)
    if ph == ch:
        return Match("same", 0, h, 0, 1.0)
    top = _prefix(ph, ch)
    bottom = _prefix(ph[::-1], ch[::-1])
    body = h - top - bottom
    if body < max(8, h // 10):
        # Only a sliver changed (a caret, a spinner): not a scroll.
        return Match("same", 0, top, bottom, 1.0)

    pb, pinf = ph[top : h - bottom], pinfo[top : h - bottom]
    cb, cinf = ch[top : h - bottom], cinfo[top : h - bottom]

    # Votes: an informative row of `cur` that occurs (rarely) in `prev`
    # suggests the shift between the two positions.
    where: dict[int, list[int]] = {}
    for i, (k, inf) in enumerate(zip(pb, pinf)):
        if inf:
            where.setdefault(k, []).append(i)
    votes: dict[int, int] = {}
    for r, (k, inf) in enumerate(zip(cb, cinf)):
        if not inf:
            continue
        pos = where.get(k)
        if not pos or len(pos) > 4:
            continue
        for p in pos:
            d = p - r
            if d:
                votes[d] = votes.get(d, 0) + 1

    min_overlap = max(4, body // 25)

    def score(d: int) -> tuple[float, int]:
        # Rows r of cur and r + d of prev show the same content.
        lo, hi = max(0, -d), min(body, body - d)
        if hi - lo < min_overlap:
            return 0.0, 0
        hit = tot = 0
        for r in range(lo, hi):
            if cinf[r] or pinf[r + d]:
                tot += 1
                if cb[r] == pb[r + d]:
                    hit += 1
        return (hit / tot if tot else 0.0), tot

    best: tuple[float, int, int] | None = None  # (score, -|d|, d)
    for d, _v in sorted(votes.items(), key=lambda kv: -kv[1])[:12]:
        s, tot = score(d)
        if tot < 3 or s < threshold:
            continue
        cand = (s, -abs(d), d)
        if best is None or cand > best:
            best = cand
    if best is not None:
        d = best[2]
        return Match("added" if d > 0 else "back", d, top, bottom, best[0])
    return Match("gap", body, top, bottom, 0.0)


# ── Stitching ───────────────────────────────────────────────────────────


@dataclass
class Placed:
    path: str
    y: int  # canvas row of the frame's row 0
    shift: int  # rows it moved past the previous kept frame (0 for the first)
    top: int
    bottom: int
    gap: bool = False


@dataclass
class Stitcher:
    """Incremental stitcher. `add` a frame (a PPM path); kept frames stay on
    disk until `compose` writes the result."""

    threshold: float = 0.9
    width: int = 0
    height: int = 0
    frames: list[Placed] = field(default_factory=list)
    gaps: int = 0
    _last: tuple[list[int], list[bool]] | None = None

    def add(self, path: str | os.PathLike, img: Image | None = None) -> Match:
        img = img or read_ppm(path)
        sig = signature(img)
        if not self.frames:
            self.width, self.height = img.width, img.height
            self.frames.append(Placed(str(path), 0, 0, 0, 0))
            self._last = sig
            return Match("added", img.height, 0, 0, 1.0)
        if (img.width, img.height) != (self.width, self.height):
            raise ValueError("frames must all have the same size")
        m = match(self._last, sig, self.threshold)
        if m.kind in ("added", "gap"):
            last = self.frames[-1]
            gap = m.kind == "gap"
            if gap:
                self.gaps += 1
            self.frames.append(Placed(str(path), last.y + m.shift, m.shift, m.top, m.bottom, gap))
            self._last = sig
        return m

    # Rows that never moved between kept frames: kept once.
    def header(self) -> int:
        tops = [f.top for f in self.frames[1:]]
        return min(tops) if tops else 0

    def footer(self) -> int:
        bots = [f.bottom for f in self.frames[1:]]
        return min(bots) if bots else 0

    @property
    def total_height(self) -> int:
        return self.frames[-1].y + self.height if self.frames else 0

    def segments(self) -> list[dict]:
        """Where each kept frame's rows go: [{path, sy, h, y}] — source rows
        [sy, sy + h) of `path` land at canvas row y."""
        if not self.frames:
            return []
        h, foot = self.height, self.footer()
        out = []
        first = self.frames[0]
        if len(self.frames) == 1:
            return [{"path": first.path, "sy": 0, "h": h, "y": 0}]
        out.append({"path": first.path, "sy": 0, "h": h - foot, "y": 0})
        for f in self.frames[1:]:
            n = min(f.shift, h - foot - (f.top if f.gap else 0))
            if n > 0:
                out.append({"path": f.path, "sy": h - foot - n, "h": n, "y": f.y + h - foot - n})
        last = self.frames[-1]
        if foot:
            out.append({"path": last.path, "sy": h - foot, "h": foot, "y": last.y + h - foot})
        return out

    def rows(self):
        """The stitched image's rows, top to bottom."""
        cache: dict[str, Image] = {}
        for s in self.segments():
            img = cache.get(s["path"])
            if img is None:
                cache.clear()  # one frame in memory at a time
                img = cache[s["path"]] = read_ppm(s["path"])
            for y in range(s["sy"], s["sy"] + s["h"]):
                yield img.row(y)

    def compose(self, out: str | os.PathLike) -> tuple[int, int]:
        if not self.frames:
            raise ValueError("no frames")
        segs = self.segments()
        height = sum(s["h"] for s in segs)
        Path(out).write_bytes(png_bytes(self.width, height, self.rows()))
        return self.width, height


def stitch_files(paths: list[str], out: str, threshold: float = 0.9) -> dict:
    """Batch: stitch PPM frames, in order, into a PNG; returns a summary."""
    st = Stitcher(threshold=threshold)
    kinds: dict[str, int] = {}
    for p in paths:
        k = st.add(p).kind
        kinds[k] = kinds.get(k, 0) + 1
    width, height = st.compose(out)
    return {
        "path": str(out),
        "width": width,
        "height": height,
        "frames": len(paths),
        "kept": len(st.frames),
        "gaps": st.gaps,
        "header": st.header(),
        "footer": st.footer(),
        "kinds": kinds,
    }
