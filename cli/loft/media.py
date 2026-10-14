"""Media tools (`loft media …`): compress, convert, GIF, watermark, extract audio.

  probe    what each file is (video / image / audio), its size, duration
           and dimensions (ffprobe)
  recent   the newest media files in Downloads, Desktop, Videos and Pictures
  open     show files in the Utilities window's Media Tools (desktop entry,
           Spotlight, "Open With")
  run OP   process files with ffmpeg / ImageMagick (`magick`), printing one
           JSON line per event — {"event": "start"|"progress"|"done"|"error"|
           "finished", …} — so the shell can show progress
             compress   video → H.264/AAC MP4: small (720p) · balanced (1080p) · high
             convert    images → png / jpg / webp / avif, quality, max size
             gif        video → GIF (palette per clip): fps, width
             watermark  text or an image in a corner, on images and videos
             audio      video/audio → m4a / mp3 / flac / wav
           Outputs go next to each original (or --out DIR) with a suffix
           (photo-converted.webp, clip-compressed.mp4 …); nothing is ever
           overwritten. --dry-run prints the commands instead.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

VIDEO_EXT = {".mp4", ".mkv", ".mov", ".webm", ".avi", ".m4v", ".mpg", ".mpeg", ".wmv", ".flv", ".ts", ".3gp", ".ogv"}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".avif", ".gif", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".jxl", ".ico", ".svg"}
AUDIO_EXT = {".mp3", ".m4a", ".aac", ".flac", ".wav", ".ogg", ".opus", ".wma", ".aiff", ".aif"}

COMPRESS = {
    "small": {"label": "Small · 720p", "width": 1280, "crf": 30, "preset": "veryfast", "audio": "96k"},
    "balanced": {"label": "Balanced · 1080p", "width": 1920, "crf": 26, "preset": "medium", "audio": "128k"},
    "high": {"label": "High quality", "width": None, "crf": 21, "preset": "slow", "audio": "160k"},
}
IMAGE_FORMATS = ("png", "jpg", "webp", "avif")
AUDIO_FORMATS = {
    "m4a": ["-c:a", "aac", "-b:a", "192k"],
    "mp3": ["-c:a", "libmp3lame", "-q:a", "2"],
    "flac": ["-c:a", "flac"],
    "wav": ["-c:a", "pcm_s16le"],
}
POSITIONS = {
    # magick gravity, ffmpeg overlay x:y (W/H = video, w/h = overlay), drawtext x:y
    "top-left": ("NorthWest", "{m}:{m}", "{m}:{m}"),
    "top-right": ("NorthEast", "W-w-{m}:{m}", "w-tw-{m}:{m}"),
    "bottom-left": ("SouthWest", "{m}:H-h-{m}", "{m}:h-th-{m}"),
    "bottom-right": ("SouthEast", "W-w-{m}:H-h-{m}", "w-tw-{m}:h-th-{m}"),
    "center": ("Center", "(W-w)/2:(H-h)/2", "(w-tw)/2:(h-th)/2"),
}
OPS = ("compress", "convert", "gif", "watermark", "audio")


def kind_of(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in VIDEO_EXT:
        return "video"
    if ext in IMAGE_EXT:
        return "image"
    if ext in AUDIO_EXT:
        return "audio"
    mt = mimetypes.guess_type(path.name)[0] or ""
    return mt.split("/")[0] if mt.split("/")[0] in ("video", "image", "audio") else "other"


def ops_for(kind: str) -> list[str]:
    return {"video": ["compress", "gif", "watermark", "audio"], "image": ["convert", "watermark"], "audio": ["audio"]}.get(kind, [])


def ffprobe(path: Path) -> dict:
    if not shutil.which("ffprobe"):
        return {}
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json", "-show_entries", "format=duration:stream=codec_type,width,height", str(path)],
            capture_output=True,
            text=True,
            timeout=20,
        )
        d = json.loads(r.stdout or "{}")
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return {}
    out = {}
    try:
        out["duration"] = float(d.get("format", {}).get("duration"))
    except (TypeError, ValueError):
        pass
    for s in d.get("streams", []):
        if s.get("codec_type") == "video" and s.get("width"):
            out["width"], out["height"] = s["width"], s["height"]
            break
    out["hasAudio"] = any(s.get("codec_type") == "audio" for s in d.get("streams", []))
    return out


def probe(paths: list[str]) -> list[dict]:
    out = []
    for p in paths:
        path = Path(p).expanduser()
        k = kind_of(path)
        try:
            size = path.stat().st_size
        except OSError:
            out.append({"path": str(path), "name": path.name, "kind": k, "missing": True, "ops": []})
            continue
        info = {"path": str(path), "name": path.name, "kind": k, "bytes": size, "ops": ops_for(k)}
        if k in ("video", "audio", "image"):
            info.update(ffprobe(path))
        out.append(info)
    return out


def _home() -> Path:
    v = os.environ.get("LOFT_TEST_HOME")
    return Path(v) if v else Path.home()


def user_dir(key: str, default: str) -> Path:
    """XDG user dirs (~/.config/user-dirs.dirs), e.g. DOWNLOAD → ~/Downloads."""
    h = _home()
    try:
        for line in (h / ".config" / "user-dirs.dirs").read_text().splitlines():
            m = re.match(rf'XDG_{key}_DIR="(.*)"', line.strip())
            if m:
                return Path(m.group(1).replace("$HOME", str(h)))
    except OSError:
        pass
    return h / default


def recent(limit: int = 12) -> list[dict]:
    dirs = [user_dir("DOWNLOAD", "Downloads"), user_dir("DESKTOP", "Desktop"), user_dir("VIDEOS", "Videos"), user_dir("PICTURES", "Pictures")]
    files = []
    for d in dirs:
        try:
            it = list(os.scandir(d))
        except OSError:
            continue
        for e in it:
            if e.is_file() and kind_of(Path(e.name)) in ("video", "image", "audio") and not e.name.startswith("."):
                try:
                    files.append((e.stat().st_mtime, e.path))
                except OSError:
                    pass
    files.sort(reverse=True)
    seen, out = set(), []
    for t, p in files:
        if p in seen:
            continue
        seen.add(p)
        k = kind_of(Path(p))
        out.append({"path": p, "name": Path(p).name, "kind": k, "mtime": int(t), "ops": ops_for(k), "bytes": os.path.getsize(p)})
        if len(out) >= limit:
            break
    return out


# ── commands ────────────────────────────────────────────────────────────────


def unique(path: Path) -> Path:
    if not path.exists():
        return path
    i = 2
    while True:
        c = path.with_name(f"{path.stem}-{i}{path.suffix}")
        if not c.exists():
            return c
        i += 1


def output_for(src: Path, op: str, ext: str, out_dir: Path | None) -> Path:
    suffix = {"compress": "compressed", "convert": "converted", "gif": "", "watermark": "watermarked", "audio": ""}[op]
    stem = f"{src.stem}-{suffix}" if suffix else src.stem
    d = out_dir or src.parent
    return unique(d / f"{stem}.{ext}")


def _magick() -> list[str]:
    if shutil.which("magick"):
        return ["magick"]
    return ["convert"]


def plan(op: str, src: Path, opts: dict, out_dir: Path | None) -> tuple[list[str], Path, str]:
    """(argv, output, tool) for one file."""
    k = kind_of(src)
    m = int(opts.get("margin", 24))
    if op == "compress":
        if k != "video":
            raise ValueError("compress takes videos")
        p = COMPRESS[opts.get("preset", "balanced")]
        out = output_for(src, op, "mp4", out_dir)
        vf = ["-vf", f"scale='trunc(min({p['width']},iw)/2)*2':-2"] if p["width"] else ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        argv = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", str(src), *vf, "-c:v", "libx264", "-crf", str(p["crf"]), "-preset", p["preset"], "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", p["audio"], "-movflags", "+faststart", str(out)]
        return argv, out, "ffmpeg"
    if op == "gif":
        if k != "video":
            raise ValueError("Make GIF takes videos")
        fps = int(opts.get("fps", 15))
        width = int(opts.get("width", 640))
        out = output_for(src, op, "gif", out_dir)
        vf = f"fps={fps},scale='min({width},iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5"
        argv = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", str(src)]
        if opts.get("seconds"):
            argv += ["-t", str(float(opts["seconds"]))]
        argv += ["-vf", vf, "-loop", "0", str(out)]
        return argv, out, "ffmpeg"
    if op == "audio":
        if k not in ("video", "audio"):
            raise ValueError("extract audio takes videos or audio")
        fmt = opts.get("format", "m4a")
        out = output_for(src, op, fmt, out_dir)
        argv = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", str(src), "-vn", *AUDIO_FORMATS[fmt], str(out)]
        return argv, out, "ffmpeg"
    if op == "convert":
        if k != "image":
            raise ValueError("convert takes images")
        fmt = opts.get("format", "webp")
        out = output_for(src, op, fmt, out_dir)
        argv = [*_magick(), str(src) + ("[0]" if src.suffix.lower() == ".gif" else ""), "-auto-orient"]
        if opts.get("maxSize"):
            argv += ["-resize", f"{int(opts['maxSize'])}x{int(opts['maxSize'])}>"]
        elif opts.get("scale") and int(opts["scale"]) != 100:
            argv += ["-resize", f"{int(opts['scale'])}%"]
        if fmt in ("jpg", "webp", "avif"):
            argv += ["-quality", str(int(opts.get("quality", 82)))]
        if fmt == "jpg":
            argv += ["-background", "white", "-alpha", "remove", "-alpha", "off"]
        if opts.get("strip", True):
            argv += ["-strip"]
        argv += [str(out)]
        return argv, out, "magick"
    if op == "watermark":
        pos = POSITIONS[opts.get("position", "bottom-right")]
        opacity = float(opts.get("opacity", 0.6))
        text = opts.get("text") or ""
        image = opts.get("image") or ""
        if not text and not image:
            raise ValueError("watermark needs text or an image")
        if k == "image":
            out = output_for(src, op, src.suffix.lstrip(".").lower() or "png", out_dir)
            argv = [*_magick(), str(src), "-auto-orient"]
            if image:
                # The mark at a fifth of the picture's width, faded to `opacity`.
                mark_w = max(16, int(image_width(src) * 0.2))
                argv += ["(", str(Path(image).expanduser()), "-resize", f"{mark_w}x", "-alpha", "set", "-channel", "A", "-evaluate", "multiply", f"{opacity:.2f}", "+channel", ")"]
                argv += ["-gravity", pos[0], "-geometry", f"+{m}+{m}", "-compose", "over", "-composite"]
            else:
                argv += ["-gravity", pos[0], "-fill", f"rgba(255,255,255,{opacity:.2f})", "-stroke", f"rgba(0,0,0,{opacity * 0.5:.2f})", "-strokewidth", "1"]
                argv += ["-pointsize", "%[fx:max(14,h*0.04)]", "-annotate", f"+{m}+{m}", text]
            argv += [str(out)]
            return argv, out, "magick"
        if k == "video":
            out = output_for(src, op, "mp4", out_dir)
            argv = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", str(src)]
            if image:
                argv += ["-i", str(Path(image).expanduser())]
                xy = pos[1].format(m=m)
                fc = f"[1:v][0:v]scale2ref=w='iw*0.2':h='ow/mdar'[wm][v];[wm]format=rgba,colorchannelmixer=aa={opacity:.2f}[w];[v][w]overlay={xy}:format=auto,format=yuv420p[out]"
                argv += ["-filter_complex", fc, "-map", "[out]", "-map", "0:a?"]
            else:
                x, y = pos[2].format(m=m).split(":")
                esc = text.replace("\\", "\\\\").replace("'", "’").replace(":", "\\:").replace("%", "\\%")
                font = opts.get("fontfile") or find_font()
                ff = f"fontfile='{font}':" if font else ""
                vf = f"drawtext={ff}text='{esc}':fontcolor=white@{opacity:.2f}:borderw=1:bordercolor=black@{opacity * 0.5:.2f}:fontsize='max(14,h*0.04)':x={x}:y={y},format=yuv420p"
                argv += ["-vf", vf]
            argv += ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-c:a", "copy", "-movflags", "+faststart", str(out)]
            return argv, out, "ffmpeg"
        raise ValueError("watermark takes images or videos")
    raise ValueError(f"unknown operation {op}")


def image_width(path: Path) -> int:
    try:
        r = subprocess.run([*_magick(), "identify", "-format", "%w\n", str(path)] if _magick() == ["magick"] else ["identify", "-format", "%w\n", str(path)], capture_output=True, text=True, timeout=20)
        return int(r.stdout.split()[0])
    except (OSError, subprocess.TimeoutExpired, ValueError, IndexError):
        return 1000


def find_font() -> str | None:
    env = os.environ.get("LOFT_UI_FONT") or os.environ.get("STUDIO_UI_FONT")
    if env and Path(env).is_file():
        return env
    if shutil.which("fc-match"):
        try:
            r = subprocess.run(["fc-match", "-f", "%{file}", "sans:bold"], capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and Path(r.stdout).is_file():
                return r.stdout
        except (OSError, subprocess.TimeoutExpired):
            pass
    return None


def emit(**kw) -> None:
    print(json.dumps(kw), flush=True)


def _run_ffmpeg(argv: list[str], duration: float | None, on_progress) -> tuple[int, str]:
    argv = argv[:1] + ["-progress", "pipe:1", "-nostats", "-loglevel", "error"] + argv[1:]
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    last = -1.0
    assert p.stdout is not None
    for line in p.stdout:
        if line.startswith("out_time_us=") and duration:
            try:
                t = int(line.split("=", 1)[1]) / 1e6
            except ValueError:
                continue
            frac = max(0.0, min(1.0, t / duration))
            if frac - last >= 0.01:
                last = frac
                on_progress(frac)
    err = p.stderr.read() if p.stderr else ""
    return p.wait(), err


def run(op: str, files: list[str], opts: dict, out_dir: Path | None = None, dry_run: bool = False) -> list[str]:
    srcs = [Path(f).expanduser() for f in files]
    outputs = []
    n = len(srcs)
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
    for i, src in enumerate(srcs):
        try:
            argv, out, tool = plan(op, src, opts, out_dir)
        except (ValueError, KeyError) as e:
            emit(event="error", index=i, file=str(src), message=str(e))
            continue
        if dry_run:
            emit(event="plan", index=i, file=str(src), output=str(out), argv=argv)
            continue
        if not shutil.which(argv[0]):
            emit(event="error", index=i, file=str(src), message=f"{argv[0]} is not installed")
            continue
        emit(event="start", index=i, count=n, file=str(src), output=str(out))
        if tool == "ffmpeg":
            dur = ffprobe(src).get("duration")
            if op == "gif" and opts.get("seconds"):
                dur = min(dur or 1e9, float(opts["seconds"]))
            code, err = _run_ffmpeg(argv, dur, lambda f: emit(event="progress", index=i, progress=round(f, 3), overall=round((i + f) / n, 3)))
        else:
            r = subprocess.run(argv, capture_output=True, text=True)
            code, err = r.returncode, r.stderr
        if code != 0 or not out.exists():
            try:
                out.unlink()
            except OSError:
                pass
            emit(event="error", index=i, file=str(src), message=(err.strip().splitlines() or [f"exit {code}"])[-1][:300])
            continue
        outputs.append(str(out))
        emit(event="done", index=i, file=str(src), output=str(out), inBytes=src.stat().st_size, outBytes=out.stat().st_size, overall=round((i + 1) / n, 3))
    emit(event="finished", outputs=outputs, count=n)
    return outputs


def capabilities() -> dict:
    caps = {"ffmpeg": shutil.which("ffmpeg") is not None, "magick": shutil.which("magick") is not None or shutil.which("convert") is not None}
    caps["avif"] = False
    if caps["magick"]:
        try:
            r = subprocess.run([*_magick(), "-list", "format"], capture_output=True, text=True, timeout=10)
            caps["avif"] = re.search(r"^\s*AVIF\*?\s+(\S+\s+)?rw", r.stdout, re.M) is not None
        except (OSError, subprocess.TimeoutExpired):
            pass
    return caps


# ── CLI ─────────────────────────────────────────────────────────────────────


def add_parser(top, shell_path_of) -> None:
    from . import utilities

    md = top.add_parser("media", help="media tools: compress, convert, GIF, watermark, extract audio")
    sub = md.add_subparsers(dest="cmd", required=True)
    utilities.register_media_open(sub, shell_path_of)

    s = sub.add_parser("probe", help="kind, size, duration and dimensions of files")
    s.add_argument("files", nargs="+")
    s.set_defaults(fn=lambda ctx, a: print(json.dumps(probe(a.files))))

    s = sub.add_parser("recent", help="the newest media files in Downloads, Desktop, Videos, Pictures")
    s.add_argument("--limit", type=int, default=12)
    s.set_defaults(fn=lambda ctx, a: print(json.dumps(recent(a.limit))))

    s = sub.add_parser("caps", help="which tools and formats are available")
    s.set_defaults(fn=lambda ctx, a: print(json.dumps(capabilities())))

    s = sub.add_parser("run", help="process files; JSON lines of progress")
    s.add_argument("op", choices=OPS)
    s.add_argument("files", nargs="+")
    s.add_argument("--out", help="output folder (default: next to each file)")
    s.add_argument("--preset", choices=list(COMPRESS), default="balanced", help="compress")
    s.add_argument("--format", help="convert: png|jpg|webp|avif · audio: m4a|mp3|flac|wav")
    s.add_argument("--quality", type=int, default=82, help="convert: 1-100")
    s.add_argument("--max-size", type=int, help="convert: longest side in px")
    s.add_argument("--scale", type=int, help="convert: percent")
    s.add_argument("--fps", type=int, default=15, help="gif")
    s.add_argument("--width", type=int, default=640, help="gif")
    s.add_argument("--seconds", type=float, help="gif: only the first N seconds")
    s.add_argument("--text", help="watermark text")
    s.add_argument("--image", help="watermark image")
    s.add_argument("--position", choices=list(POSITIONS), default="bottom-right")
    s.add_argument("--opacity", type=float, default=0.6)
    s.add_argument("--dry-run", action="store_true")

    def _run(ctx, a):
        opts = {"preset": a.preset, "quality": a.quality, "maxSize": a.max_size, "scale": a.scale, "fps": a.fps, "width": a.width, "seconds": a.seconds, "text": a.text, "image": a.image, "position": a.position, "opacity": a.opacity}
        if a.format:
            opts["format"] = a.format
        if a.op == "audio" and a.format and a.format not in AUDIO_FORMATS:
            raise SystemExit(f"loft: audio formats: {', '.join(AUDIO_FORMATS)}")
        if a.op == "convert" and a.format and a.format not in IMAGE_FORMATS:
            raise SystemExit(f"loft: image formats: {', '.join(IMAGE_FORMATS)}")
        outs = run(a.op, a.files, opts, Path(a.out).expanduser() if a.out else None, a.dry_run)
        if not outs and not a.dry_run:
            sys.exit(1)

    s.set_defaults(fn=_run)
