//! `loft-kwin shot …`: screenshots through KWin's `org.kde.KWin.ScreenShot2`
//! (KWin has no wlr-screencopy, so grim can't capture). docs/KWIN.md §4.7.
//!
//! KWin answers each Capture* call with the image's metadata (width, height,
//! stride, QImage format) and writes the raw pixels into the pipe we pass;
//! we read them, convert to RGBA and write a PNG.

use std::collections::HashMap;
use std::io::Read;
use std::os::fd::OwnedFd;
use std::path::Path;

use anyhow::{Context, Result, bail};
use zbus::Connection;
use zbus::zvariant::{Fd, OwnedValue, Value};

const DEST: &str = "org.kde.KWin";
const PATH: &str = "/org/kde/KWin/ScreenShot2";
const IFACE: &str = "org.kde.KWin.ScreenShot2";

/// What to capture.
#[derive(Debug, PartialEq)]
pub enum Target {
    /// One output by connector name (DP-2), at its native resolution.
    Screen(String),
    /// A window by KWin's internalId ("{uuid}"), with its title bar.
    Window(String),
    /// A rectangle in global logical coordinates, at native resolution.
    Area { x: i32, y: i32, w: u32, h: u32 },
    /// Every output, one image.
    Workspace,
}

pub struct Request {
    pub target: Target,
    pub pointer: bool,
    /// Downscale so the longer side is at most this many px (thumbnails).
    pub max: Option<u32>,
    pub out: String,
}

const USAGE: &str = "usage: loft-kwin shot screen OUTPUT FILE | window UUID FILE | area X Y W H FILE | workspace FILE  [--pointer] [--max PX]";

/// Pulls `--max PX` out of `args`.
fn take_max(args: &mut Vec<&str>) -> Result<Option<u32>> {
    let Some(i) = args.iter().position(|a| *a == "--max") else { return Ok(None) };
    let v = args.get(i + 1).context("--max needs a size in px")?;
    let n: u32 = v.parse().with_context(|| format!("not a size: {v}"))?;
    if n == 0 {
        bail!("--max 0");
    }
    args.drain(i..i + 2);
    Ok(Some(n))
}

/// `shot` arguments (after the subcommand) → a request.
pub fn parse(args: &[String]) -> Result<Request> {
    let pointer = args.iter().any(|a| a == "--pointer");
    let mut a: Vec<&str> = args.iter().map(String::as_str).filter(|a| *a != "--pointer").collect();
    let max = take_max(&mut a)?;
    let num = |s: &str| s.parse::<i64>().with_context(|| format!("not a number: {s}"));
    let (target, out) = match a.as_slice() {
        ["screen", name, out] => (Target::Screen(name.to_string()), out),
        ["window", uuid, out] => (Target::Window(uuid.to_string()), out),
        ["area", x, y, w, h, out] => {
            let (w, h) = (num(w)?, num(h)?);
            if w <= 0 || h <= 0 {
                bail!("empty area {w}x{h}");
            }
            (Target::Area { x: num(x)? as i32, y: num(y)? as i32, w: w as u32, h: h as u32 }, out)
        }
        ["workspace", out] => (Target::Workspace, out),
        _ => bail!("{USAGE}"),
    };
    Ok(Request { target, pointer, max, out: out.to_string() })
}

/// `thumbs` arguments: `DIR MAX UUID…` (docs/KWIN.md §4.8).
pub struct Thumbs {
    pub dir: String,
    pub max: u32,
    pub windows: Vec<String>,
}

const THUMBS_USAGE: &str = "usage: loft-kwin thumbs DIR MAX_PX UUID...";

pub fn parse_thumbs(args: &[String]) -> Result<Thumbs> {
    let [dir, max, windows @ ..] = args else { bail!("{THUMBS_USAGE}") };
    let max: u32 = max.parse().ok().filter(|n| *n > 0).with_context(|| format!("{THUMBS_USAGE} (MAX_PX: {max})"))?;
    if windows.is_empty() {
        bail!("{THUMBS_USAGE}");
    }
    Ok(Thumbs { dir: dir.clone(), max, windows: windows.to_vec() })
}

/// The thumbnail file for a window: its uuid without braces.
pub fn thumb_name(uuid: &str) -> String {
    let id: String = uuid.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
    format!("{id}.png")
}

/// RGBA8 `w`×`h` → at most `max` px on the longer side, by averaging each
/// destination pixel's source box (alpha-weighted). Smaller images pass
/// through.
pub fn downscale(rgba: &[u8], w: u32, h: u32, max: u32) -> (u32, u32, Vec<u8>) {
    if w.max(h) <= max {
        return (w, h, rgba.to_vec());
    }
    let k = max as f64 / w.max(h) as f64;
    let dw = ((w as f64 * k).round() as u32).max(1);
    let dh = ((h as f64 * k).round() as u32).max(1);
    let (sw, sh) = (w as usize, h as usize);
    let mut out = Vec::with_capacity(dw as usize * dh as usize * 4);
    for dy in 0..dh as usize {
        let y0 = dy * sh / dh as usize;
        let y1 = ((dy + 1) * sh / dh as usize).max(y0 + 1);
        for dx in 0..dw as usize {
            let x0 = dx * sw / dw as usize;
            let x1 = ((dx + 1) * sw / dw as usize).max(x0 + 1);
            let (mut r, mut g, mut b, mut a, mut n) = (0u64, 0u64, 0u64, 0u64, 0u64);
            for y in y0..y1 {
                let row = &rgba[(y * sw + x0) * 4..(y * sw + x1) * 4];
                for px in row.as_chunks::<4>().0 {
                    let pa = px[3] as u64;
                    r += px[0] as u64 * pa;
                    g += px[1] as u64 * pa;
                    b += px[2] as u64 * pa;
                    a += pa;
                    n += 1;
                }
            }
            let avg = |c: u64| c.checked_div(a).unwrap_or(0) as u8;
            out.extend_from_slice(&[avg(r), avg(g), avg(b), ((a + n / 2) / n) as u8]);
        }
    }
    (dw, dh, out)
}

/// KWin's raw image → tightly packed RGBA8. `format` is a QImage::Format:
/// 4 RGB32, 5 ARGB32, 6 ARGB32_Premultiplied (32-bit 0xAARRGGBB words: B G R A
/// in memory), 16 RGBX8888, 17 RGBA8888, 18 RGBA8888_Premultiplied (R G B A),
/// 25 RGBX64, 26 RGBA64, 27 RGBA64_Premultiplied (16-bit little-endian
/// channels, R G B A; HDR outputs).
pub fn to_rgba(data: &[u8], width: u32, height: u32, stride: u32, format: u32) -> Result<Vec<u8>> {
    let (bgra, opaque, premultiplied, wide) = match format {
        4 => (true, true, false, false),
        5 => (true, false, false, false),
        6 => (true, false, true, false),
        16 => (false, true, false, false),
        17 => (false, false, false, false),
        18 => (false, false, true, false),
        25 => (false, true, false, true),
        26 => (false, false, false, true),
        27 => (false, false, true, true),
        f => bail!("unsupported QImage format {f}"),
    };
    let bpp = if wide { 8 } else { 4 };
    let (w, h, stride) = (width as usize, height as usize, stride as usize);
    if stride < w * bpp || data.len() < stride * h.saturating_sub(1) + w * bpp {
        bail!("short image: {} bytes for {width}x{height} (stride {stride})", data.len());
    }
    let mut out = Vec::with_capacity(w * h * 4);
    for row in 0..h {
        let line = &data[row * stride..row * stride + w * bpp];
        for px in line.chunks_exact(bpp) {
            // Channels in memory order, as 8 bits.
            let c = |i: usize| -> u8 { if wide { px[i * 2 + 1] } else { px[i] } };
            let (r, g, b) = if bgra { (c(2), c(1), c(0)) } else { (c(0), c(1), c(2)) };
            let a = if opaque { 255 } else { c(3) };
            let un = |v: u8| -> u8 {
                if !premultiplied || a == 255 || a == 0 {
                    v
                } else {
                    ((v as u32 * 255 + a as u32 / 2) / a as u32).min(255) as u8
                }
            };
            out.extend_from_slice(&[un(r), un(g), un(b), a]);
        }
    }
    Ok(out)
}

fn get_u32(meta: &HashMap<String, OwnedValue>, key: &str) -> Result<u32> {
    let v = meta.get(key).with_context(|| format!("KWin's reply has no {key}"))?;
    u32::try_from(v).or_else(|_| i32::try_from(v).map(|n| n as u32)).with_context(|| format!("{key} isn't a number"))
}

/// One capture: (width, height, RGBA8).
async fn capture(conn: &Connection, target: &Target, pointer: bool) -> Result<(u32, u32, Vec<u8>)> {
    let (mut reader, writer) = std::io::pipe()?;
    let writer: OwnedFd = writer.into();
    // KWin writes after it replies, from its own thread: read concurrently,
    // or a large image fills the pipe and both sides wait.
    let read = std::thread::spawn(move || {
        let mut buf = Vec::new();
        reader.read_to_end(&mut buf).map(|_| buf)
    });

    let mut opts: HashMap<&str, Value> = HashMap::new();
    opts.insert("include-cursor", Value::from(pointer));
    let fd = Fd::from(&writer);
    let reply = match target {
        Target::Screen(name) => {
            opts.insert("native-resolution", Value::from(true));
            conn.call_method(Some(DEST), PATH, Some(IFACE), "CaptureScreen", &(name.as_str(), &opts, fd)).await
        }
        Target::Window(uuid) => {
            opts.insert("include-decoration", Value::from(true));
            opts.insert("include-shadow", Value::from(false));
            conn.call_method(Some(DEST), PATH, Some(IFACE), "CaptureWindow", &(uuid.as_str(), &opts, fd)).await
        }
        Target::Area { x, y, w, h } => {
            opts.insert("native-resolution", Value::from(true));
            conn.call_method(Some(DEST), PATH, Some(IFACE), "CaptureArea", &(*x, *y, *w, *h, &opts, fd)).await
        }
        Target::Workspace => {
            opts.insert("native-resolution", Value::from(true));
            conn.call_method(Some(DEST), PATH, Some(IFACE), "CaptureWorkspace", &(&opts, fd)).await
        }
    };
    // Our end of the pipe must close for the reader to see EOF once KWin
    // closes its copy (also when it refused: then nothing is written).
    drop(writer);
    let reply = reply.context("KWin refused the screenshot (ScreenShot2)");
    let data = read.join().map_err(|_| anyhow::anyhow!("pipe reader panicked"))??;
    let meta: HashMap<String, OwnedValue> = reply?.body().deserialize()?;

    let (w, h) = (get_u32(&meta, "width")?, get_u32(&meta, "height")?);
    let rgba = to_rgba(&data, w, h, get_u32(&meta, "stride")?, get_u32(&meta, "format")?)?;
    Ok((w, h, rgba))
}

/// Capture and write the PNG.
pub async fn run(req: &Request) -> Result<()> {
    let conn = Connection::session().await?;
    let (w, h, rgba) = capture(&conn, &req.target, req.pointer).await?;
    let (w, h, rgba) = match req.max {
        Some(max) => downscale(&rgba, w, h, max),
        None => (w, h, rgba),
    };
    write_png(Path::new(&req.out), w, h, &rgba)
}

/// `loft-kwin thumbs`: window stills for the dock preview and the switcher,
/// several windows over one connection. Writes DIR/<uuid>.png per window
/// and prints one JSON line each: `{"window", "path", "width", "height",
/// "ms"}` or `{"window", "error"}` (minimized windows can't be captured).
pub async fn thumbs(t: &Thumbs) -> Result<()> {
    let conn = Connection::session().await?;
    for uuid in &t.windows {
        let start = std::time::Instant::now();
        let path = Path::new(&t.dir).join(thumb_name(uuid));
        let res = async {
            let (w, h, rgba) = capture(&conn, &Target::Window(uuid.clone()), false).await?;
            let (w, h, rgba) = downscale(&rgba, w, h, t.max);
            write_png(&path, w, h, &rgba)?;
            Ok::<_, anyhow::Error>((w, h))
        }
        .await;
        let line = match res {
            Ok((w, h)) => serde_json::json!({
                "window": uuid, "path": path.to_string_lossy(), "width": w, "height": h,
                "ms": start.elapsed().as_millis() as u64,
            }),
            Err(e) => serde_json::json!({ "window": uuid, "error": format!("{e:#}") }),
        };
        println!("{line}");
    }
    Ok(())
}

fn write_png(path: &Path, w: u32, h: u32, rgba: &[u8]) -> Result<()> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    // Write beside, then rename: a watcher never sees half a PNG.
    let tmp = path.with_extension("png.part");
    {
        let file = std::io::BufWriter::new(std::fs::File::create(&tmp).with_context(|| format!("{}", tmp.display()))?);
        let mut enc = png::Encoder::new(file, w, h);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Fast);
        enc.write_header()?.write_image_data(rgba)?;
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &str) -> Vec<String> {
        s.split_whitespace().map(String::from).collect()
    }

    #[test]
    fn parses_targets() {
        let r = parse(&args("screen DP-2 /tmp/a.png --pointer")).unwrap();
        assert_eq!(r.target, Target::Screen("DP-2".into()));
        assert!(r.pointer);
        assert_eq!(r.out, "/tmp/a.png");
        let r = parse(&args("area -10 20 300 200 b.png")).unwrap();
        assert_eq!(r.target, Target::Area { x: -10, y: 20, w: 300, h: 200 });
        assert!(!r.pointer);
        assert_eq!(parse(&args("window {abc} c.png")).unwrap().target, Target::Window("{abc}".into()));
        assert_eq!(parse(&args("workspace d.png")).unwrap().target, Target::Workspace);
        assert!(parse(&args("area 0 0 0 5 e.png")).is_err());
        assert!(parse(&args("screen DP-2")).is_err());
        let r = parse(&args("window {abc} --max 320 c.png")).unwrap();
        assert_eq!((r.max, r.out.as_str()), (Some(320), "c.png"));
        assert!(parse(&args("window {abc} c.png --max")).is_err());
        assert!(parse(&args("window {abc} c.png --max 0")).is_err());
    }

    #[test]
    fn parses_thumbs() {
        let t = parse_thumbs(&args("/run/t 440 {a} {b}")).unwrap();
        assert_eq!((t.dir.as_str(), t.max, t.windows.len()), ("/run/t", 440, 2));
        assert!(parse_thumbs(&args("/run/t 440")).is_err());
        assert!(parse_thumbs(&args("/run/t big {a}")).is_err());
        assert_eq!(thumb_name("{0f3c-9a/..}"), "0f3c-9a.png");
    }

    #[test]
    fn downscales() {
        // 4×2 → max 2: 2×1, each the average of a 2×2 box.
        let mut img = Vec::new();
        for y in 0..2u8 {
            for x in 0..4u8 {
                img.extend_from_slice(&[if x < 2 { 100 + y * 20 } else { 0 }, 50, 200, 255]);
            }
        }
        let (w, h, out) = downscale(&img, 4, 2, 2);
        assert_eq!((w, h), (2, 1));
        assert_eq!(out, [110, 50, 200, 255, 0, 50, 200, 255]);
        // Transparent pixels don't darken the average.
        let (_, _, out) = downscale(&[255, 0, 0, 255, 0, 0, 0, 0], 2, 1, 1);
        assert_eq!(out, [255, 0, 0, 128]);
        // Already small: unchanged.
        assert_eq!(downscale(&img, 4, 2, 4).2, img);
        // Odd sizes keep the aspect and never hit zero.
        let big = vec![255u8; 1000 * 3 * 4];
        let (w, h, _) = downscale(&big, 1000, 3, 100);
        assert_eq!((w, h), (100, 1));
    }

    #[test]
    fn converts_formats() {
        // One opaque orange pixel (r=255 g=128 b=0) per format, stride 8
        // (4 bytes of row padding).
        let bgra = [0, 128, 255, 255, 9, 9, 9, 9];
        assert_eq!(to_rgba(&bgra, 1, 1, 8, 6).unwrap(), [255, 128, 0, 255]);
        // RGB32 ignores the alpha byte.
        assert_eq!(to_rgba(&[0, 128, 255, 7], 1, 1, 4, 4).unwrap(), [255, 128, 0, 255]);
        assert_eq!(to_rgba(&[255, 128, 0, 255], 1, 1, 4, 17).unwrap(), [255, 128, 0, 255]);
        // RGBX8888 (what KWin 6.8 hands back) ignores the X byte.
        assert_eq!(to_rgba(&[255, 128, 0, 3], 1, 1, 4, 16).unwrap(), [255, 128, 0, 255]);
        // RGBA64: the high byte of each little-endian 16-bit channel.
        assert_eq!(to_rgba(&[0x10, 0xff, 0x00, 0x80, 0x00, 0x00, 0xff, 0xff], 1, 1, 8, 26).unwrap(), [255, 128, 0, 255]);
        // Premultiplied half-transparent white → white at alpha 128.
        assert_eq!(to_rgba(&[128, 128, 128, 128], 1, 1, 4, 6).unwrap(), [255, 255, 255, 128]);
        // Two rows honor the stride.
        let two = [1, 2, 3, 255, 0, 0, 0, 0, 4, 5, 6, 255, 0, 0, 0, 0];
        assert_eq!(to_rgba(&two, 1, 2, 8, 5).unwrap(), [3, 2, 1, 255, 6, 5, 4, 255]);
        assert!(to_rgba(&[0; 3], 1, 1, 4, 6).is_err());
        assert!(to_rgba(&[0; 4], 1, 1, 4, 99).is_err());
    }
}
