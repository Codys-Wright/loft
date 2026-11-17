//! `loft-kwin record …`: screen recording under KWin (no wlr-screencopy, so
//! wf-recorder can't capture). docs/KWIN.md §4.8.
//!
//! KWin's `zkde_screencast_unstable_v1` Wayland protocol turns an output, a
//! window or a region of the desktop into a PipeWire video node; we ask for
//! one, then record the node with `gst-launch-1.0` (pipewiresrc → x264 →
//! MP4, like wf-recorder's default). KWin 6.8 grants the protocol to any
//! session client: no portal, no dialog. A region is streamed by KWin
//! itself (`stream_region`), so area recordings need no crop.
//!
//! Signals, so the shell's Recorder drives it like wf-recorder:
//! SIGINT/SIGTERM finish the file (EOS) and exit 0; SIGTSTP pauses the
//! encoder (SIGSTOP to it), SIGCONT resumes it. Exits 1 when KWin refuses
//! the stream or the encoder fails.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::mpsc;
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{wl_output, wl_registry};
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, WEnum};
use wayland_protocols_plasma::screencast::v1::client::zkde_screencast_stream_unstable_v1::{
    self as stream_v1, ZkdeScreencastStreamUnstableV1,
};
use wayland_protocols_plasma::screencast::v1::client::zkde_screencast_unstable_v1::{
    self as screencast_v1, ZkdeScreencastUnstableV1,
};

/// What to record.
#[derive(Debug, PartialEq)]
pub enum Target {
    /// One output by connector name (DP-2), at its native resolution.
    Screen(String),
    /// A window by KWin's internalId ("{uuid}").
    Window(String),
    /// A rectangle in global logical coordinates, at `scale` pixels per
    /// logical pixel.
    Area { x: i32, y: i32, w: u32, h: u32, scale: f64 },
}

#[derive(Debug, PartialEq)]
pub struct Request {
    pub target: Target,
    pub pointer: bool,
    /// A PulseAudio source for the audio track ("default" = the default
    /// source, "@DEFAULT_MONITOR@" = what the default sink plays); none = no audio.
    pub audio: Option<String>,
    pub fps: u32,
    pub out: String,
}

const USAGE: &str = "usage: loft-kwin record screen OUTPUT FILE | window UUID FILE | area X Y W H FILE  \
[--scale S] [--no-pointer] [--audio SOURCE] [--fps N]";

/// `record` arguments (after the subcommand) → a request.
pub fn parse(args: &[String]) -> Result<Request> {
    let mut pointer = true;
    let mut audio = None;
    let mut fps = 30;
    let mut scale = 1.0;
    let mut pos: Vec<&str> = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut value = |flag: &str| it.next().map(String::as_str).with_context(|| format!("{flag} wants a value"));
        match a.as_str() {
            "--no-pointer" => pointer = false,
            "--pointer" => pointer = true,
            "--audio" => audio = Some(value("--audio")?.to_string()).filter(|s| !s.is_empty() && s != "none"),
            "--fps" => fps = value("--fps")?.parse().context("--fps wants a number")?,
            "--scale" => scale = value("--scale")?.parse().context("--scale wants a number")?,
            _ => pos.push(a),
        }
    }
    if !(1..=240).contains(&fps) {
        bail!("--fps wants 1-240");
    }
    if !(scale > 0.0 && scale <= 8.0) {
        bail!("--scale wants a number from 0 to 8");
    }
    let num = |s: &str| s.parse::<i64>().with_context(|| format!("not a number: {s}"));
    let (target, out) = match pos.as_slice() {
        ["screen", name, out] => (Target::Screen(name.to_string()), out),
        ["window", uuid, out] => (Target::Window(uuid.to_string()), out),
        ["area", x, y, w, h, out] => {
            let (w, h) = (num(w)?, num(h)?);
            if w <= 0 || h <= 0 {
                bail!("empty area {w}x{h}");
            }
            (Target::Area { x: num(x)? as i32, y: num(y)? as i32, w: w as u32, h: h as u32, scale }, out)
        }
        _ => bail!("{USAGE}"),
    };
    Ok(Request { target, pointer, audio, fps, out: out.to_string() })
}

/// The frame size the encoder gets: H.264 4:2:0 wants even sides, so an odd
/// side loses a pixel (videoscale; a no-op when already even).
pub fn even_size(w: u32, h: u32) -> (u32, u32) {
    ((w & !1).max(2), (h & !1).max(2))
}

/// gst-launch-1.0's argv for recording PipeWire node `node` into
/// `req.out`. `size`: the stream's pixel size when known (then odd sides
/// are trimmed to even); without it the stream's own size is kept.
pub fn pipeline(node: u32, size: Option<(u32, u32)>, req: &Request) -> Vec<String> {
    let mut caps = "video/x-raw,format=I420,pixel-aspect-ratio=1/1".to_string();
    if let Some((w, h)) = size {
        let (w, h) = even_size(w, h);
        caps = format!("{caps},width={w},height={h}");
    }
    let mut p = format!(
        // keepalive-time: KWin sends frames on damage only; resend the last
        // one so a still screen still fills the timeline. always-copy: KWin
        // reuses its buffers.
        "pipewiresrc path={node} do-timestamp=true keepalive-time=500 always-copy=true \
         ! videorate ! video/x-raw,framerate={fps}/1 \
         ! videoconvert ! videoscale ! {caps} \
         ! x264enc speed-preset=veryfast pass=qual quantizer=23 key-int-max={key} bframes=0 \
         ! video/x-h264,profile=high ! h264parse ! queue ! mux. ",
        fps = req.fps,
        key = req.fps * 2,
    );
    if let Some(src) = &req.audio {
        let device = if src == "default" { String::new() } else { format!(" device={src}") };
        p.push_str(&format!(
            "pulsesrc{device} do-timestamp=true ! audioconvert ! audioresample ! audio/x-raw,channels=2 \
             ! avenc_aac ! aacparse ! queue ! mux. "
        ));
    }
    p.push_str(&format!("mp4mux name=mux ! filesink location={}", gst_quote(&req.out)));
    let mut argv = vec!["gst-launch-1.0".to_string(), "-e".to_string(), "-q".to_string()];
    argv.extend(split_launch(&p));
    argv
}

/// gst-launch parses its argv joined by spaces; a location with spaces or
/// quotes goes in double quotes (backslash-escaped inside).
fn gst_quote(s: &str) -> String {
    if s.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+,:@%~".contains(c)) {
        s.to_string()
    } else {
        format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
    }
}

/// The pipeline description → argv words (gst-launch re-joins them), keeping
/// a quoted location in one word.
fn split_launch(p: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut cur = String::new();
    let (mut quoted, mut escaped) = (false, false);
    for c in p.chars() {
        if escaped {
            cur.push(c);
            escaped = false;
            continue;
        }
        match c {
            '\\' if quoted => {
                cur.push(c);
                escaped = true;
            }
            '"' => {
                cur.push(c);
                quoted = !quoted;
            }
            ' ' if !quoted => {
                if !cur.is_empty() {
                    words.push(std::mem::take(&mut cur));
                }
            }
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() {
        words.push(cur);
    }
    words
}

/// A stream's size in device pixels.
type PixelSize = (u32, u32);

/// What the stream thread reports.
#[derive(Debug)]
enum StreamEvent {
    Created(u32),
    Failed(String),
    Closed,
}

#[derive(Default)]
struct Output {
    name: String,
    /// The current mode, in pixels.
    mode: Option<(i32, i32)>,
}

struct State {
    outputs: Vec<(wl_output::WlOutput, Output)>,
    tx: mpsc::UnboundedSender<StreamEvent>,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<wl_output::WlOutput, ()> for State {
    fn event(st: &mut Self, o: &wl_output::WlOutput, ev: wl_output::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        let Some((_, out)) = st.outputs.iter_mut().find(|(p, _)| p == o) else { return };
        match ev {
            wl_output::Event::Name { name } => out.name = name,
            wl_output::Event::Mode { flags: WEnum::Value(f), width, height, .. } if f.contains(wl_output::Mode::Current) => {
                out.mode = Some((width, height));
            }
            _ => {}
        }
    }
}

impl Dispatch<ZkdeScreencastUnstableV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &ZkdeScreencastUnstableV1,
        _: screencast_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZkdeScreencastStreamUnstableV1, ()> for State {
    fn event(
        st: &mut Self,
        _: &ZkdeScreencastStreamUnstableV1,
        ev: stream_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let _ = st.tx.send(match ev {
            stream_v1::Event::Created { node } => StreamEvent::Created(node),
            stream_v1::Event::Failed { error } => StreamEvent::Failed(error),
            stream_v1::Event::Closed => StreamEvent::Closed,
            _ => return,
        });
    }
}

/// KWin's pointer modes (zkde_screencast_unstable_v1.pointer).
const POINTER_HIDDEN: u32 = 1;
const POINTER_EMBEDDED: u32 = 2;

/// Asks KWin for the stream; its events then arrive on the returned
/// channel (a thread dispatches the connection until the process ends,
/// which also ends the stream). Also returns the stream's pixel size when
/// it's known up front (an output's mode, a region × scale).
fn open_stream(req: &Request) -> Result<(mpsc::UnboundedReceiver<StreamEvent>, Option<PixelSize>)> {
    let conn = Connection::connect_to_env().context("connecting to KWin's Wayland socket")?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn).context("listing Wayland globals")?;
    let qh = queue.handle();
    let (tx, rx) = mpsc::unbounded_channel();
    let mut st = State { outputs: Vec::new(), tx };
    let screencast: ZkdeScreencastUnstableV1 = globals
        .bind(&qh, 1..=4, ())
        .context("KWin offers no zkde_screencast_unstable_v1 (is this KWin, with its screencast plugin?)")?;
    for g in globals.contents().clone_list() {
        if g.interface == "wl_output" {
            let o = globals.registry().bind::<wl_output::WlOutput, _, _>(g.name, g.version.min(4), &qh, ());
            st.outputs.push((o, Output::default()));
        }
    }
    queue.roundtrip(&mut st).context("reading the outputs")?;

    let pointer = if req.pointer { POINTER_EMBEDDED } else { POINTER_HIDDEN };
    let size = match &req.target {
        Target::Screen(name) => {
            let Some((o, out)) = st.outputs.iter().find(|(_, out)| out.name == *name) else {
                let names: Vec<&str> = st.outputs.iter().map(|(_, o)| o.name.as_str()).collect();
                bail!("no output {name} (have: {})", names.join(", "));
            };
            screencast.stream_output(o, pointer, &qh, ());
            out.mode.map(|(w, h)| (w.max(0) as u32, h.max(0) as u32))
        }
        Target::Window(uuid) => {
            screencast.stream_window(uuid.clone(), pointer, &qh, ());
            None
        }
        Target::Area { x, y, w, h, scale } => {
            if screencast.version() < 3 {
                bail!("KWin's zkde_screencast is version {}; regions need 3", screencast.version());
            }
            screencast.stream_region(*x, *y, *w, *h, *scale, pointer, &qh, ());
            Some(((*w as f64 * scale).round() as u32, (*h as f64 * scale).round() as u32))
        }
    };
    conn.flush().context("asking KWin for the stream")?;
    std::thread::spawn(move || {
        let _keep = screencast;
        while queue.blocking_dispatch(&mut st).is_ok() {}
        let _ = st.tx.send(StreamEvent::Closed);
    });
    Ok((rx, size))
}

fn kill(pid: Option<u32>, sig: i32) {
    if let Some(pid) = pid {
        // SAFETY: kill(2) on our own child's pid; no memory involved.
        unsafe {
            libc::kill(pid as libc::pid_t, sig);
        }
    }
}

pub async fn run(req: &Request) -> Result<()> {
    if let Some(dir) = std::path::Path::new(&req.out).parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    let (mut events, size) = open_stream(req)?;
    let node = match tokio::time::timeout(Duration::from_secs(10), events.recv()).await {
        Ok(Some(StreamEvent::Created(node))) => node,
        Ok(Some(StreamEvent::Failed(e))) => bail!("KWin refused the stream: {e}"),
        Ok(Some(StreamEvent::Closed)) | Ok(None) => bail!("KWin closed the stream before it started"),
        Err(_) => bail!("KWin didn't start the stream in 10 s (is PipeWire running?)"),
    };
    eprintln!("loft-kwin: recording PipeWire node {node} into {}", req.out);

    // Handlers first: a disposition that's handled resets to the default in
    // the child on exec, while an inherited SIG_IGN (a background job of a
    // script) would stay and gst-launch would ignore our SIGINT.
    let mut int = signal(SignalKind::interrupt())?;
    let mut term = signal(SignalKind::terminate())?;
    let mut tstp = signal(SignalKind::from_raw(libc::SIGTSTP))?;
    let mut cont = signal(SignalKind::from_raw(libc::SIGCONT))?;

    let argv = pipeline(node, size, req);
    let mut child = tokio::process::Command::new(&argv[0])
        .args(&argv[1..])
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting {}", argv[0]))?;
    let pid = child.id();
    let mut stopping = false;
    let status = loop {
        tokio::select! {
            s = child.wait() => break s?,
            _ = int.recv() => { stopping = true; kill(pid, libc::SIGCONT); kill(pid, libc::SIGINT); }
            _ = term.recv() => { stopping = true; kill(pid, libc::SIGCONT); kill(pid, libc::SIGINT); }
            _ = tstp.recv() => kill(pid, libc::SIGSTOP),
            _ = cont.recv() => kill(pid, libc::SIGCONT),
            ev = events.recv(), if !stopping => match ev {
                Some(StreamEvent::Closed) | None => {
                    // The source went away (window closed, output unplugged):
                    // finish what we have.
                    eprintln!("loft-kwin: KWin closed the stream; finishing the file");
                    stopping = true;
                    kill(pid, libc::SIGCONT);
                    kill(pid, libc::SIGINT);
                }
                Some(StreamEvent::Failed(e)) => eprintln!("loft-kwin: stream: {e}"),
                Some(StreamEvent::Created(_)) => {}
            },
        }
    };
    if !status.success() {
        bail!("{} failed ({status})", argv[0]);
    }
    if std::fs::metadata(&req.out).map(|m| m.len() == 0).unwrap_or(true) {
        bail!("no recording written to {}", req.out);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &str) -> Vec<String> {
        s.split_whitespace().map(String::from).collect()
    }

    #[test]
    fn parses_targets_and_flags() {
        let r = parse(&args("screen WL-0 /tmp/a.mp4")).unwrap();
        assert_eq!(r.target, Target::Screen("WL-0".into()));
        assert!(r.pointer);
        assert_eq!((r.audio, r.fps, r.out.as_str()), (None, 30, "/tmp/a.mp4"));

        let r = parse(&args("area 10 -20 300 200 o.mp4 --scale 1.5 --no-pointer --audio @DEFAULT_MONITOR@ --fps 60")).unwrap();
        assert_eq!(r.target, Target::Area { x: 10, y: -20, w: 300, h: 200, scale: 1.5 });
        assert!(!r.pointer);
        assert_eq!(r.audio.as_deref(), Some("@DEFAULT_MONITOR@"));
        assert_eq!(r.fps, 60);

        let r = parse(&args("window {abc} o.mp4 --audio none")).unwrap();
        assert_eq!(r.target, Target::Window("{abc}".into()));
        assert_eq!(r.audio, None);

        assert!(parse(&args("area 0 0 0 10 o.mp4")).is_err());
        assert!(parse(&args("screen o.mp4")).is_err());
        assert!(parse(&args("screen WL-0 o.mp4 --fps 0")).is_err());
        assert!(parse(&args("screen WL-0 o.mp4 --audio")).is_err());
    }

    #[test]
    fn even_sizes() {
        assert_eq!(even_size(1920, 1080), (1920, 1080));
        assert_eq!(even_size(301, 199), (300, 198));
        assert_eq!(even_size(1, 1), (2, 2));
    }

    #[test]
    fn pipeline_shape() {
        let r = parse(&args("area 0 0 301 200 /tmp/rec.mp4")).unwrap();
        let p = pipeline(42, Some((301, 200)), &r);
        assert_eq!(&p[..3], ["gst-launch-1.0", "-e", "-q"]);
        let joined = p.join(" ");
        assert!(joined.starts_with("gst-launch-1.0 -e -q pipewiresrc path=42 "));
        assert!(joined.contains("width=300,height=200"));
        assert!(!joined.contains("pulsesrc"));
        assert!(joined.ends_with("filesink location=/tmp/rec.mp4"), "{joined}");

        let r = Request {
            target: Target::Screen("WL-0".into()),
            pointer: true,
            audio: Some("default".into()),
            fps: 30,
            out: "/tmp/a b\"c.mp4".into(),
        };
        let p = pipeline(7, None, &r);
        assert!(p.iter().any(|w| w == "pulsesrc"));
        assert!(!p.join(" ").contains("width="));
        assert_eq!(p.last().unwrap(), "location=\"/tmp/a b\\\"c.mp4\"");
    }
}
