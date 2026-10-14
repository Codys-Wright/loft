//! studio-shot: screenshots for agents that need to look at a studio-linux
//! session and pick coordinates. Prints the image path; every image maps to
//! global logical coordinates (stderr / --json say how).

use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::Parser;
use niri_ipc::Action;
use serde_json::json;
use studio_input::niri::{Niri, Rect, bounding, find_output, find_window, window_rect};
use studio_input::session::{self, Fallback, Target};
use studio_input::shot::{self, Frame, auto_step, draw_grid, draw_mark, parse_point};

const AFTER_HELP: &str = "\
Coordinates are global logical pixels — the same ones `studio-input` clicks.
Without a target flag the whole session is captured.

Examples:
  studio-shot --session t1 --max 1600 --grid         # whole session, coordinate grid
  studio-shot --session t1 --window foot --out /tmp/foot.png
  studio-shot --session t1 --zoom 1100,0,500,60 --grid   # crop + upscale the bar's right end
  studio-shot --session t1 --mark 1210,14 --zoom 1100,0,300,100   # check a click target first
  studio-shot out.png                                # the default dev session (old usage)
  studio-shot --live --output DP-3 --max 1600        # the live desktop (read-only)";

#[derive(Debug, Parser)]
#[command(
    name = "studio-shot",
    version,
    about = "Screenshot a niri session for an agent: crop, zoom, coordinate grid, marks",
    after_help = AFTER_HELP,
    allow_negative_numbers = true
)]
struct Cli {
    /// Output file (same as --out).
    #[arg(value_name = "OUT")]
    out_pos: Option<PathBuf>,
    /// Output file (default ./studio-YYYYmmdd-HHMMSS.png). The path is printed.
    #[arg(long, short = 'o')]
    out: Option<PathBuf>,
    /// A studio-dev test session (default: $STUDIO_SESSION, the session this
    /// runs in, else `dev`).
    #[arg(long, short = 's')]
    session: Option<String>,
    /// The desktop this runs in ($WAYLAND_DISPLAY).
    #[arg(long)]
    live: bool,

    /// One output.
    #[arg(long, group = "target")]
    output: Option<String>,
    /// A rectangle X,Y,W,H.
    #[arg(long, group = "target", value_name = "X,Y,W,H")]
    region: Option<String>,
    /// A window: id, app id, title, or a substring of either.
    #[arg(long, group = "target", value_name = "ID|APP_ID|TITLE")]
    window: Option<String>,
    /// The output a layer surface is on, by namespace (niri doesn't report
    /// layer geometry).
    #[arg(long, group = "target", value_name = "NAMESPACE")]
    layer: Option<String>,
    /// Crop X,Y,W,H and upscale (to --max, default 1600) for detail.
    #[arg(long, group = "target", value_name = "X,Y,W,H")]
    zoom: Option<String>,

    /// With --window: have niri render the window alone (even if covered or
    /// on another workspace). niri also copies it to that session's
    /// clipboard, so test sessions only. Automatic there for tiled windows,
    /// whose position niri doesn't report.
    #[arg(long, requires = "window")]
    window_render: bool,
    /// Crop X,Y,W,H, relative to the target's top-left.
    #[arg(long, value_name = "X,Y,W,H")]
    crop: Option<String>,
    /// Multiply the image size by F.
    #[arg(long, value_name = "F")]
    scale: Option<f64>,
    /// Downscale so the longer side is at most N px.
    #[arg(long, value_name = "N")]
    max: Option<u32>,
    /// Wait before capturing.
    #[arg(long, value_name = "MS", default_value_t = 0)]
    delay: u64,
    /// Overlay a labeled coordinate grid (every N logical px; auto without N).
    #[arg(long, value_name = "N", num_args = 0..=1, default_missing_value = "0")]
    grid: Option<f64>,
    /// Draw a crosshair at X,Y (repeatable) — check a click target first.
    #[arg(long, value_name = "X,Y")]
    mark: Vec<String>,
    /// Include the pointer.
    #[arg(long)]
    cursor: bool,
    /// Print {path, region, width, height, px_per_unit, grid} as JSON.
    #[arg(long)]
    json: bool,
}

fn default_name() -> PathBuf {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as libc::time_t)
        .unwrap_or(0);
    // SAFETY: localtime_r only fills the zeroed tm we own.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    PathBuf::from(format!(
        "studio-{:04}{:02}{:02}-{:02}{:02}{:02}.png",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec
    ))
}

fn grim(target: &Target, region: Rect, cursor: bool) -> Result<image::RgbaImage> {
    let mut cmd = Command::new("grim");
    cmd.env("WAYLAND_DISPLAY", &target.wayland_display)
        .args(["-t", "png", "-l", "0"]);
    if cursor {
        cmd.arg("-c");
    }
    cmd.args(["-g", &region.grim(), "-"]);
    let out = cmd.output().context("running grim (is it on PATH?)")?;
    if !out.status.success() {
        bail!("grim: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(
        image::load_from_memory_with_format(&out.stdout, image::ImageFormat::Png)
            .context("decoding grim's PNG")?
            .to_rgba8(),
    )
}

/// niri renders one window to a file (`screenshot-window --path`).
fn render_window(niri: &Niri, id: u64, cursor: bool) -> Result<image::RgbaImage> {
    let dir = std::env::temp_dir().join(format!("studio-shot-{}", std::process::id()));
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("window.png");
    niri.action(Action::ScreenshotWindow {
        id: Some(id),
        write_to_disk: true,
        show_pointer: cursor,
        path: Some(path.to_string_lossy().into_owned()),
    })?;
    let mut img = None;
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(60));
        if let Ok(i) = image::open(&path) {
            img = Some(i.to_rgba8());
            break;
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    img.context("niri did not write the window screenshot")
}

fn run(cli: Cli) -> Result<()> {
    let target = session::resolve(cli.session.as_deref(), cli.live, Fallback::DefaultSession)?;
    let sock = target
        .niri_socket
        .clone()
        .context("the target has no niri socket")?;
    let niri = Niri::new(&sock);
    if cli.delay > 0 {
        std::thread::sleep(Duration::from_millis(cli.delay));
    }
    let outputs = niri.outputs()?;
    let bounds = bounding(&outputs);
    let mut notes: Vec<String> = Vec::new();

    // What to capture, in global logical coordinates.
    let mut rendered: Option<Frame> = None;
    let mut rect = bounds;
    if let Some(o) = &cli.output {
        rect = find_output(&outputs, o)?.rect;
    } else if let Some(r) = cli.region.as_deref().or(cli.zoom.as_deref()) {
        rect = Rect::parse(r)?;
    } else if let Some(q) = &cli.window {
        let wins = niri.windows()?;
        let w = find_window(&wins, q)?;
        let geo = window_rect(w, &niri.workspaces()?, &outputs);
        // niri reports no position for tiled windows: render the window
        // itself instead (test sessions only — it touches the clipboard).
        let auto_render = geo.is_none() && !target.is_live();
        if auto_render && !cli.window_render {
            notes.push(format!(
                "window #{} has no reported position (tiled); niri rendered it alone",
                w.id
            ));
        }
        if cli.window_render || auto_render {
            if target.is_live() {
                bail!("--window-render also replaces the clipboard; use it in test sessions only");
            }
            let img = render_window(&niri, w.id, cli.cursor)?;
            let region = geo.unwrap_or_else(|| {
                notes.push(format!(
                    "window #{}: coordinates in this image are window-local, not global",
                    w.id
                ));
                let s = outputs.first().map(|o| o.scale).unwrap_or(1.0);
                Rect::new(0.0, 0.0, img.width() as f64 / s, img.height() as f64 / s)
            });
            rendered = Some(Frame::new(img, region));
        } else {
            rect = geo.with_context(|| {
                format!(
                    "window #{} has no reported position (tiled, or not on a visible workspace); capture its output or a --region instead",
                    w.id
                )
            })?;
        }
    } else if let Some(ns) = &cli.layer {
        let layers = niri.layers()?;
        let l = layers
            .iter()
            .find(|l| l.namespace == *ns)
            .or_else(|| layers.iter().find(|l| l.namespace.contains(ns.as_str())))
            .with_context(|| {
                format!(
                    "no layer surface `{ns}` (have: {})",
                    layers
                        .iter()
                        .map(|l| l.namespace.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            })?;
        rect = find_output(&outputs, &l.output)?.rect;
        notes.push(format!(
            "layer `{}` is on {}; niri reports no layer geometry, so this is the whole output",
            l.namespace, l.output
        ));
    }
    let crop = cli.crop.as_deref().map(Rect::parse).transpose()?;

    let mut frame = match rendered {
        Some(f) => match crop {
            Some(c) => {
                let r = f.region;
                f.crop(Rect::new(r.x + c.x, r.y + c.y, c.w, c.h))
                    .context("--crop is outside the window")?
            }
            None => f,
        },
        None => {
            if let Some(c) = crop {
                rect = Rect::new(rect.x + c.x, rect.y + c.y, c.w, c.h)
                    .intersect(rect)
                    .context("--crop is outside the target")?;
            }
            let r = rect
                .intersect(bounds)
                .with_context(|| format!("{rect} is outside every output ({bounds})"))?;
            if r != rect {
                notes.push(format!("clipped to the outputs: {r}"));
            }
            Frame::new(grim(&target, r, cli.cursor)?, r)
        }
    };
    if frame.img.width() == 0 || frame.img.height() == 0 {
        bail!("empty capture");
    }
    if cli.zoom.is_some() {
        frame = frame.grow_to(cli.max.unwrap_or(1600));
    }
    if let Some(f) = cli.scale {
        if f <= 0.0 {
            bail!("--scale must be positive");
        }
        frame = frame.resize(f);
    }
    if let Some(m) = cli.max {
        frame = frame.fit_max(m);
    }
    let mut grid_step = None;
    if let Some(g) = cli.grid {
        let step = if g > 0.0 {
            g
        } else {
            auto_step(frame.region, frame.scale())
        };
        draw_grid(&mut frame, step);
        grid_step = Some(step);
    }
    for m in &cli.mark {
        let (x, y) = parse_point(m)?;
        if !draw_mark(&mut frame, x, y) {
            notes.push(format!("mark {x},{y} is outside the image"));
        }
    }

    let out = cli.out.or(cli.out_pos).unwrap_or_else(default_name);
    if let Some(d) = out.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(d)?;
    }
    frame
        .img
        .save_with_format(&out, image::ImageFormat::Png)
        .with_context(|| format!("writing {}", out.display()))?;
    let r = frame.region;
    let s = frame.scale();
    if cli.json {
        println!(
            "{}",
            json!({
                "path": out, "target": target.name.clone().unwrap_or_else(|| "live".into()),
                "region": r, "width": frame.img.width(), "height": frame.img.height(),
                "px_per_unit": s, "origin_px": frame.origin, "grid": grid_step, "notes": notes,
            })
        );
    } else {
        println!("{}", out.display());
        let (ox, oy) = frame.origin;
        let px = if (ox, oy) == (0, 0) {
            "px".to_string()
        } else {
            format!("(px - ({ox}, {oy}) rulers)")
        };
        eprintln!(
            "studio-shot: {r} → {}x{} px; global = ({}, {}) + {px} / {}{}",
            frame.img.width(),
            frame.img.height(),
            shot::fmt_num(r.x),
            shot::fmt_num(r.y),
            shot::fmt_num((s * 1000.0).round() / 1000.0),
            grid_step
                .map(|g| format!("; grid every {}", shot::fmt_num(g)))
                .unwrap_or_default()
        );
        for n in notes {
            eprintln!("studio-shot: note: {n}");
        }
    }
    Ok(())
}

fn main() {
    // Exit quietly when piped into `head`.
    // SAFETY: setting a signal disposition at startup, before any threads.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
    if let Err(e) = run(Cli::parse()) {
        eprintln!("studio-shot: {e:#}");
        std::process::exit(1);
    }
}
