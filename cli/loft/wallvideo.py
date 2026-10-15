"""Display-sized copies of live (video) wallpapers (`loft wallpaper video-variant`).

Live wallpapers are often 5K, 10-bit HEVC, scaled to cover each screen and
cropped around a focus point, so most of every decoded frame is never seen.
The shell (src/services/VideoWallpapers.qml) asks for a copy of exactly what a
screen shows: the visible crop of the frame (fractions x, y, w, h) at the
screen's pixel size (never upscaled), 8-bit 4:2:0 (NV12), which every hardware
decoder and Qt's zero-copy path take.

  - NVIDIA (an NVENC-capable ffmpeg and the driver loaded): decoded with NVDEC,
    scaled with scale_cuda, encoded with hevc_nvenc (a few seconds per clip).
  - Otherwise: decoded and scaled in software, encoded with libx264 (libx265
    above 4096 px wide, beyond H.264 hardware decoders), at low priority.

Copies live in $XDG_CACHE_HOME/loft/wallpaper-video ($LOFT_VIDEO_CACHE), named after the source,
its size and mtime, the crop and the output size; the original is never
touched. A copy that would not be meaningfully smaller than the original
(less than ~15% fewer pixels, same bit depth) is not made: the original is
used (`useOriginal`). Copies unused for 30 days are pruned.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

VERSION = 1  # bump to remake every copy (encoder settings changed)
PRUNE_DAYS = 30


def cache_dir() -> Path:
    if os.environ.get("LOFT_VIDEO_CACHE"):  # test sessions (loft-dev --session)
        return Path(os.environ["LOFT_VIDEO_CACHE"])
    base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return base / "loft" / "wallpaper-video"


def _even(v: float) -> int:
    return max(2, int(round(v / 2)) * 2)


def probe(src: Path) -> dict:
    r = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,width,height,pix_fmt",
            "-of", "json", str(src),
        ],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError(f"ffprobe: {r.stderr.strip() or r.returncode}")
    streams = json.loads(r.stdout).get("streams") or []
    if not streams:
        raise RuntimeError("no video stream")
    s = streams[0]
    return {"codec": s.get("codec_name", ""), "width": int(s["width"]), "height": int(s["height"]), "pix_fmt": s.get("pix_fmt", "")}


def has_nvenc() -> bool:
    if not Path("/proc/driver/nvidia/version").exists():
        return False
    r = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=20)
    return "hevc_nvenc" in r.stdout


def plan(info: dict, crop: tuple[float, float, float, float], size: tuple[int, int]) -> dict:
    """Source crop (pixels) and output size for a crop given in fractions."""
    vw, vh = info["width"], info["height"]
    x, y, w, h = crop
    w = min(max(w, 0.0), 1.0)
    h = min(max(h, 0.0), 1.0)
    x = min(max(x, 0.0), 1.0 - w)
    y = min(max(y, 0.0), 1.0 - h)
    cw, ch = max(2, round(w * vw)), max(2, round(h * vh))
    cx, cy = round(x * vw), round(y * vh)
    tw, th = size
    # Never upscale: a screen with more pixels than the crop gets the crop's size.
    f = min(1.0, cw / max(1, tw), ch / max(1, th))
    tw, th = _even(tw * f), _even(th * f)
    return {"cx": cx, "cy": cy, "cw": cw, "ch": ch, "tw": tw, "th": th}


def worth_it(info: dict, p: dict) -> bool:
    ten_bit = "10" in info["pix_fmt"] or "12" in info["pix_fmt"]
    return ten_bit or p["tw"] * p["th"] < 0.85 * info["width"] * info["height"]


def _ffmpeg_nvenc(src: Path, info: dict, p: dict, out: Path) -> list[str]:
    # Scale the whole frame on the GPU so the crop comes out at the target
    # size, download as NV12 and crop (a pointer offset), encode with NVENC.
    s = p["tw"] / p["cw"]
    sw, sh = _even(info["width"] * s), _even(info["height"] * s)
    ox = min(max(0, round(p["cx"] * s)), sw - p["tw"])
    oy = min(max(0, round(p["cy"] * s)), sh - p["th"])
    vf = f"scale_cuda={sw}:{sh}:format=nv12,hwdownload,format=nv12,crop={p['tw']}:{p['th']}:{ox}:{oy}"
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-hwaccel", "cuda", "-hwaccel_output_format", "cuda", "-i", str(src),
        "-vf", vf, "-c:v", "hevc_nvenc", "-preset", "p5", "-tune", "hq", "-rc", "vbr", "-cq", "22",
        "-pix_fmt", "nv12", "-an", "-movflags", "+faststart", "-f", "mp4", str(out),
    ]


def _ffmpeg_software(src: Path, p: dict, out: Path, nvenc: bool) -> list[str]:
    vf = f"crop={p['cw']}:{p['ch']}:{p['cx']}:{p['cy']},scale={p['tw']}:{p['th']}:flags=lanczos,format=nv12"
    if nvenc:
        enc = ["-c:v", "hevc_nvenc", "-preset", "p5", "-tune", "hq", "-rc", "vbr", "-cq", "22"]
    elif p["tw"] <= 4096 and p["th"] <= 4096:
        enc = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"]
    else:
        enc = ["-c:v", "libx265", "-preset", "fast", "-crf", "22", "-pix_fmt", "yuv420p", "-tag:v", "hvc1"]
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src),
        "-vf", vf, *enc, "-an", "-movflags", "+faststart", "-f", "mp4", str(out),
    ]


def prune(d: Path, keep: Path | None = None) -> None:
    cutoff = time.time() - PRUNE_DAYS * 86400
    for f in d.glob("*.mp4"):
        try:
            st = f.stat()
            if f != keep and max(st.st_atime, st.st_mtime) < cutoff:
                f.unlink()
        except OSError:
            pass
    for f in d.glob(".*.part.mp4"):
        try:
            if f.stat().st_mtime < time.time() - 3600:
                f.unlink()
        except OSError:
            pass


def make_variant(src: Path, crop: tuple[float, float, float, float], size: tuple[int, int], *, force_software: bool = False) -> dict:
    src = src.expanduser().resolve()
    st = src.stat()
    r3 = tuple(round(v, 3) for v in crop)
    key = f"{src}|{st.st_size}|{st.st_mtime_ns}|{r3}|{size[0]}x{size[1]}|v{VERSION}"
    digest = hashlib.sha1(key.encode()).hexdigest()[:16]
    d = cache_dir()
    out = d / f"{src.stem[:60]}-{size[0]}x{size[1]}-{digest}.mp4"
    if out.exists() and out.stat().st_size > 0:
        os.utime(out)  # keeps it from being pruned
        return {"path": str(out), "cached": True}

    info = probe(src)
    p = plan(info, crop, size)
    if not worth_it(info, p):
        return {"path": str(src), "cached": True, "useOriginal": True, "width": info["width"], "height": info["height"]}

    d.mkdir(parents=True, exist_ok=True)
    tmp = d / f".{out.stem}.{os.getpid()}.part.mp4"
    nvenc = not force_software and has_nvenc()
    attempts = ([("nvdec+nvenc", _ffmpeg_nvenc(src, info, p, tmp))] if nvenc else []) + [
        ("hevc_nvenc" if nvenc else "software", _ffmpeg_software(src, p, tmp, nvenc))
    ]
    t0 = time.monotonic()
    err = ""
    for name, cmd in attempts:
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode == 0 and tmp.exists() and tmp.stat().st_size > 0:
            os.replace(tmp, out)
            prune(d, keep=out)
            return {
                "path": str(out), "cached": False, "encoder": name,
                "seconds": round(time.monotonic() - t0, 1), "width": p["tw"], "height": p["th"],
                "source": f"{info['width']}x{info['height']} {info['codec']} {info['pix_fmt']}",
            }
        err = (r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1]
    tmp.unlink(missing_ok=True)
    raise RuntimeError(err)


def cmd_variant(_ctx, a) -> None:
    from .cli import Fail  # late: cli imports this module

    try:
        crop = tuple(float(v) for v in a.crop.split(","))
        w, h = (int(v) for v in a.size.lower().split("x"))
        if len(crop) != 4:
            raise ValueError
    except ValueError:
        raise Fail("--crop is X,Y,W,H (fractions of the frame), --size is WxH")
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise Fail("ffmpeg / ffprobe not on PATH")
    try:
        r = make_variant(Path(a.video), crop, (w, h), force_software=a.software)
    except (OSError, RuntimeError, subprocess.SubprocessError) as e:
        raise Fail(f"video-variant: {e}")
    print(json.dumps(r) if a.json else r["path"])


def add_wallpaper_parser(sub) -> None:
    s = sub.add_parser(
        "video-variant",
        help="a display-sized 8-bit copy of a live wallpaper's visible crop (cached; prints its path)",
        description=__doc__,
    )
    s.add_argument("video")
    s.add_argument("--crop", default="0,0,1,1", help="X,Y,W,H: the visible part, as fractions of the frame")
    s.add_argument("--size", required=True, help="WxH: the screen's size in pixels")
    s.add_argument("--software", action="store_true", help="don't use NVDEC/NVENC")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_variant)
