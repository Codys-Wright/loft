//! `loft-kwin record …`: screen recording under KWin (no wlr-screencopy, so
//! wf-recorder can't capture). docs/KWIN.md §4.10.
//!
//! KWin's `zkde_screencast_unstable_v1` Wayland protocol turns an output, a
//! window or a region of the desktop into a PipeWire video node; we ask for
//! one, then record the node with `gst-launch-1.0` (pipewiresrc → H.264 →
//! MP4, like wf-recorder's default). The H.264 encoder is the GPU's when it
//! works (NVENC, then VA-API), else x264 (`Encoder`, probed once per login). KWin 6.8 grants the protocol to any
//! session client: no portal, no dialog. A region is streamed by KWin
//! itself (`stream_region`), so area recordings need no crop.
//!
//! Signals, so the shell's Recorder drives it like wf-recorder:
//! SIGINT/SIGTERM finish the file (EOS) and exit 0; SIGTSTP pauses the
//! encoder (SIGSTOP to it; the paused span stays in the file as a held
//! frame, like wf-recorder's: the shell cuts pauses by recording segments,
//! Recorder.qml), SIGCONT resumes it. A stop in the first moments waits until
//! the pipeline has run `MIN_RUN`, so the file always has frames. Exits 1
//! when KWin refuses the stream or the encoder fails.

use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use tokio::io::{AsyncBufReadExt, BufReader};
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
    /// `None` = auto: the first that works of NVENC, VA-API, x264.
    pub encoder: Option<Encoder>,
}

const USAGE: &str = "usage: loft-kwin record screen OUTPUT FILE | window UUID FILE | area X Y W H FILE  \
[--scale S] [--no-pointer] [--audio SOURCE] [--fps N] [--encoder auto|nvenc|va|x264]";

/// The H.264 encoder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Encoder {
    /// NVIDIA's NVENC (`nvh264enc`, gst-plugins-bad's nvcodec): takes the
    /// stream's BGRx as is and converts on the GPU.
    Nvenc,
    /// VA-API (`vapostproc` → `vah264enc`, gst-plugins-bad's va): AMD and
    /// Intel; vapostproc uploads, converts and scales on the GPU.
    Va,
    /// x264 on the CPU: always there.
    X264,
}

impl Encoder {
    /// Auto's order: NVENC, then VA-API, then x264 (never probed).
    pub const AUTO: [Encoder; 3] = [Encoder::Nvenc, Encoder::Va, Encoder::X264];

    pub fn name(self) -> &'static str {
        match self {
            Encoder::Nvenc => "nvenc",
            Encoder::Va => "va",
            Encoder::X264 => "x264",
        }
    }

    /// `auto` (or empty) = `None`.
    pub fn parse(s: &str) -> Result<Option<Encoder>> {
        Ok(match s {
            "" | "auto" => None,
            "nvenc" | "nvh264enc" => Some(Encoder::Nvenc),
            "va" | "vaapi" | "vah264enc" => Some(Encoder::Va),
            "x264" | "x264enc" | "software" => Some(Encoder::X264),
            _ => bail!("--encoder wants auto, nvenc, va or x264"),
        })
    }

    /// Raw video (any format) → H.264 High, I frames every `key` frames, no
    /// B frames (as wf-recorder / x264 zerolatency). `size`: ",width=W,height=H"
    /// or empty. The quality settings land near x264's quantizer 23 on a
    /// desktop (docs/KWIN.md §4.10 has the sizes).
    pub fn chain(self, size: &str, key: u32) -> String {
        let caps = format!("pixel-aspect-ratio=1/1{size}");
        match self {
            Encoder::Nvenc => format!(
                "videoscale ! video/x-raw,{caps} \
                 ! nvh264enc preset=p4 tune=high-quality rc-mode=vbr const-quality=25 gop-size={key} bframes=0 \
                 ! video/x-h264,profile=high"
            ),
            Encoder::Va => format!(
                "vapostproc ! video/x-raw(memory:VAMemory),format=NV12,{caps} \
                 ! vah264enc rate-control=cqp qpi=24 qpp=26 key-int-max={key} b-frames=0 \
                 ! video/x-h264,profile=high"
            ),
            Encoder::X264 => format!(
                "videoconvert ! videoscale ! video/x-raw,format=I420,{caps} \
                 ! x264enc speed-preset=veryfast pass=qual quantizer=23 key-int-max={key} bframes=0 \
                 ! video/x-h264,profile=high"
            ),
        }
    }
}

/// `record` arguments (after the subcommand) → a request.
pub fn parse(args: &[String]) -> Result<Request> {
    let mut pointer = true;
    let mut audio = None;
    let mut fps = 30;
    let mut scale = 1.0;
    let mut encoder = Encoder::parse(&std::env::var("LOFT_RECORD_ENCODER").unwrap_or_default()).unwrap_or(None);
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
            "--encoder" => encoder = Encoder::parse(value("--encoder")?)?,
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
    Ok(Request { target, pointer, audio, fps, out: out.to_string(), encoder })
}

/// The frame size the encoder gets: H.264 4:2:0 wants even sides, so an odd
/// side loses a pixel (videoscale; a no-op when already even).
pub fn even_size(w: u32, h: u32) -> (u32, u32) {
    ((w & !1).max(2), (h & !1).max(2))
}

/// gst-launch-1.0's argv for recording PipeWire node `node` into
/// `req.out` with `enc`. `size`: the stream's pixel size when known (then
/// odd sides are trimmed to even); without it the stream's own size is kept.
/// Not quiet: run() reads "Setting pipeline to PLAYING" from stdout.
pub fn pipeline(node: u32, size: Option<(u32, u32)>, req: &Request, enc: Encoder) -> Vec<String> {
    let size = size.map(|(w, h)| even_size(w, h)).map(|(w, h)| format!(",width={w},height={h}")).unwrap_or_default();
    let mut p = format!(
        // keepalive-time: KWin sends frames on damage only; resend the last
        // one so a still screen still fills the timeline. always-copy: KWin
        // reuses its buffers.
        "pipewiresrc path={node} do-timestamp=true keepalive-time=500 always-copy=true \
         ! videorate ! video/x-raw,framerate={fps}/1 \
         ! {chain} ! h264parse ! queue ! mux. ",
        fps = req.fps,
        chain = enc.chain(&size, req.fps * 2),
    );
    if let Some(src) = &req.audio {
        let device = if src == "default" { String::new() } else { format!(" device={src}") };
        p.push_str(&format!(
            "pulsesrc{device} do-timestamp=true ! audioconvert ! audioresample ! audio/x-raw,channels=2 \
             ! avenc_aac ! aacparse ! queue ! mux. "
        ));
    }
    p.push_str(&format!("mp4mux name=mux ! filesink location={}", gst_quote(&req.out)));
    let mut argv = vec!["gst-launch-1.0".to_string(), "-e".to_string()];
    argv.extend(split_launch(&p));
    argv
}

/// A short test encode with `enc` (GPU encoders register even when the
/// device can't open, e.g. no CUDA driver): gst-launch's argv.
pub fn probe_pipeline(enc: Encoder) -> Vec<String> {
    let p = format!(
        "videotestsrc num-buffers=3 ! video/x-raw,format=BGRx,width=320,height=180,framerate=30/1 \
         ! {} ! h264parse ! fakesink",
        enc.chain("", 60)
    );
    let mut argv = vec!["gst-launch-1.0".to_string(), "-q".to_string()];
    argv.extend(split_launch(&p));
    argv
}

async fn probe(enc: Encoder) -> bool {
    let argv = probe_pipeline(enc);
    let child = tokio::process::Command::new(&argv[0])
        .args(&argv[1..])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .status();
    // The first run after a plugin change also scans the registry (seconds).
    matches!(tokio::time::timeout(Duration::from_secs(20), child).await, Ok(Ok(s)) if s.success())
}

/// Where auto's pick is kept: per login (the runtime dir), and per plugin
/// set (the wrapper's GStreamer path), so a new driver or GStreamer
/// probes again.
fn cache_path() -> Option<std::path::PathBuf> {
    std::env::var_os("XDG_RUNTIME_DIR").map(|d| std::path::Path::new(&d).join("loft-kwin-encoder"))
}

fn cache_key() -> String {
    std::env::var("GST_PLUGIN_SYSTEM_PATH_1_0").unwrap_or_default()
}

/// The cache file's content for `enc` → the encoder it names, if it was
/// written for `key`.
pub fn cached(content: &str, key: &str) -> Option<Encoder> {
    let (k, name) = content.rsplit_once('\n')?;
    if k != key {
        return None;
    }
    Encoder::parse(name.trim()).ok().flatten()
}

fn forget_cache() {
    if let Some(p) = cache_path() {
        let _ = std::fs::remove_file(p);
    }
}

/// Builds GStreamer's plugin registry and caches auto's pick (the daemon
/// calls this after login). The registry lives in XDG_CACHE_HOME, the pick in
/// the runtime dir, so one can be there without the other: a tiny pipeline
/// always runs. Quiet: no output, failures ignored.
pub async fn warm_up() {
    let _ = tokio::process::Command::new("gst-launch-1.0")
        .args(["-q", "fakesrc", "num-buffers=1", "!", "fakesink"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .status()
        .await;
    let _ = choose(None).await;
}

/// The encoder to use: the requested one, else auto's (cached, or the first
/// of `Encoder::AUTO` whose probe works).
async fn choose(requested: Option<Encoder>) -> Encoder {
    if let Some(e) = requested {
        return e;
    }
    let key = cache_key();
    if let Some(e) = cache_path().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|c| cached(&c, &key)) {
        return e;
    }
    let mut pick = Encoder::X264;
    for e in Encoder::AUTO {
        if e == Encoder::X264 || probe(e).await {
            pick = e;
            break;
        }
    }
    if let Some(p) = cache_path() {
        let _ = std::fs::write(p, format!("{key}\n{}", pick.name()));
    }
    pick
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

/// How long the pipeline runs (from PLAYING) before a stop is passed on: a
/// stop in the first moments (or during the first plugin scan, before the
/// pipeline exists) used to leave a file with no or one frame.
pub const MIN_RUN: Duration = Duration::from_millis(1000);

/// When a stop asked for at `asked` reaches gst-launch: right away once it has
/// played `MIN_RUN`, else when it will have; `None` while it isn't playing
/// yet (then up to `START_WAIT` after the ask).
pub fn stop_at(asked: Instant, playing: Option<Instant>) -> Option<Instant> {
    playing.map(|p| asked.max(p + MIN_RUN))
}

/// The longest a stop waits for the pipeline to start playing.
const START_WAIT: Duration = Duration::from_secs(15);

/// What one gst-launch run ended with.
enum Ended {
    /// Finished (exit 0 after our SIGINT, or the stream ended).
    Done,
    /// gst-launch failed; `early`: before a stop was asked and before the
    /// file had anything in it (a GPU encoder that doesn't work here).
    Failed { status: std::process::ExitStatus, early: bool },
}

pub async fn run(req: &Request) -> Result<()> {
    if let Some(dir) = std::path::Path::new(&req.out).parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    // Probing (and the first plugin scan) runs while KWin sets the stream up.
    let requested = req.encoder;
    let chosen = tokio::spawn(choose(requested));
    let (mut events, size) = open_stream(req)?;
    let node = match tokio::time::timeout(Duration::from_secs(10), events.recv()).await {
        Ok(Some(StreamEvent::Created(node))) => node,
        Ok(Some(StreamEvent::Failed(e))) => bail!("KWin refused the stream: {e}"),
        Ok(Some(StreamEvent::Closed)) | Ok(None) => bail!("KWin closed the stream before it started"),
        Err(_) => bail!("KWin didn't start the stream in 10 s (is PipeWire running?)"),
    };
    let mut enc = chosen.await.unwrap_or(Encoder::X264);
    eprintln!("loft-kwin: recording PipeWire node {node} into {} ({})", req.out, enc.name());

    // Handlers first: a disposition that's handled resets to the default in
    // the child on exec, while an inherited SIG_IGN (a background job of a
    // script) would stay and gst-launch would ignore our SIGINT.
    let mut sigs = Signals {
        int: signal(SignalKind::interrupt())?,
        term: signal(SignalKind::terminate())?,
        tstp: signal(SignalKind::from_raw(libc::SIGTSTP))?,
        cont: signal(SignalKind::from_raw(libc::SIGCONT))?,
    };
    let mut stop_asked = None;
    loop {
        match record_once(req, node, size, enc, &mut sigs, &mut events, &mut stop_asked).await? {
            Ended::Done => break,
            Ended::Failed { early: true, .. } if enc != Encoder::X264 => {
                eprintln!("loft-kwin: {} failed here; recording with x264", enc.name());
                if requested.is_none() {
                    forget_cache();
                    if let Some(p) = cache_path() {
                        let _ = std::fs::write(p, format!("{}\n{}", cache_key(), Encoder::X264.name()));
                    }
                }
                enc = Encoder::X264;
            }
            Ended::Failed { status, .. } => bail!("gst-launch-1.0 failed ({status})"),
        }
    }
    if std::fs::metadata(&req.out).map(|m| m.len() == 0).unwrap_or(true) {
        bail!("no recording written to {}", req.out);
    }
    Ok(())
}

struct Signals {
    int: tokio::signal::unix::Signal,
    term: tokio::signal::unix::Signal,
    tstp: tokio::signal::unix::Signal,
    cont: tokio::signal::unix::Signal,
}

/// One gst-launch run into `req.out`. `stop_asked`: when a stop came in
/// (kept across a retry with x264).
async fn record_once(
    req: &Request,
    node: u32,
    size: Option<PixelSize>,
    enc: Encoder,
    sigs: &mut Signals,
    events: &mut mpsc::UnboundedReceiver<StreamEvent>,
    stop_asked: &mut Option<Instant>,
) -> Result<Ended> {
    let argv = pipeline(node, size, req, enc);
    let mut child = tokio::process::Command::new(&argv[0])
        .args(&argv[1..])
        .stdout(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting {}", argv[0]))?;
    let pid = child.id();
    // gst-launch says "Setting pipeline to PLAYING ..." once it is; the rest
    // of its chatter goes nowhere.
    let (play_tx, mut play_rx) = mpsc::unbounded_channel();
    if let Some(out) = child.stdout.take() {
        tokio::spawn(async move {
            let mut lines = BufReader::new(out).lines();
            while let Ok(Some(l)) = lines.next_line().await {
                if l.contains("Setting pipeline to PLAYING") {
                    let _ = play_tx.send(());
                }
            }
        });
    }
    let mut playing: Option<Instant> = None;
    let mut chatter = true; // stdout still open
    let mut sent = false; // SIGINT passed on
    let mut paused = false;
    let status = loop {
        // A pending stop: due when stop_at says, or START_WAIT after the ask.
        let due = stop_asked.filter(|_| !sent).map(|a| stop_at(a, playing).unwrap_or(a + START_WAIT));
        let sleep = tokio::time::sleep_until(due.unwrap_or_else(|| Instant::now() + Duration::from_secs(3600)).into());
        tokio::select! {
            s = child.wait() => break s?,
            _ = sigs.int.recv() => { stop_asked.get_or_insert_with(Instant::now); }
            _ = sigs.term.recv() => { stop_asked.get_or_insert_with(Instant::now); }
            _ = sigs.tstp.recv(), if stop_asked.is_none() => { paused = true; kill(pid, libc::SIGSTOP); }
            _ = sigs.cont.recv() => { paused = false; kill(pid, libc::SIGCONT); }
            line = play_rx.recv(), if chatter => match line {
                Some(()) => { playing.get_or_insert_with(Instant::now); }
                None => chatter = false,
            },
            _ = sleep, if due.is_some() => {
                sent = true;
                kill(pid, libc::SIGCONT);
                kill(pid, libc::SIGINT);
            }
            ev = events.recv(), if stop_asked.is_none() => match ev {
                Some(StreamEvent::Closed) | None => {
                    // The source went away (window closed, output unplugged):
                    // finish what we have.
                    eprintln!("loft-kwin: KWin closed the stream; finishing the file");
                    stop_asked.get_or_insert_with(Instant::now);
                }
                Some(StreamEvent::Failed(e)) => eprintln!("loft-kwin: stream: {e}"),
                Some(StreamEvent::Created(_)) => {}
            },
        }
        // A stop resumes a paused encoder (it can't finish while stopped).
        if stop_asked.is_some() && paused {
            paused = false;
            kill(pid, libc::SIGCONT);
        }
    };
    if status.success() {
        return Ok(Ended::Done);
    }
    let empty = std::fs::metadata(&req.out).map(|m| m.len() == 0).unwrap_or(true);
    Ok(Ended::Failed { status, early: !sent && empty })
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
    fn encoders() {
        assert_eq!(parse(&args("screen WL-0 o.mp4 --encoder va")).unwrap().encoder, Some(Encoder::Va));
        assert_eq!(parse(&args("screen WL-0 o.mp4 --encoder auto")).unwrap().encoder, None);
        assert!(parse(&args("screen WL-0 o.mp4 --encoder qsv")).is_err());
        let va = Encoder::Va.chain(",width=300,height=200", 60);
        assert!(va.contains("video/x-raw(memory:VAMemory),format=NV12,pixel-aspect-ratio=1/1,width=300,height=200"), "{va}");
        assert!(va.contains("key-int-max=60"));
        let probe = probe_pipeline(Encoder::Nvenc).join(" ");
        assert!(probe.starts_with("gst-launch-1.0 -q videotestsrc num-buffers=3 "), "{probe}");
        assert!(probe.ends_with("h264parse ! fakesink"), "{probe}");
        assert_eq!(cached("/a:/b\nva", "/a:/b"), Some(Encoder::Va));
        assert_eq!(cached("/a:/b\nva", "/a:/c"), None);
        assert_eq!(cached("garbage", ""), None);
    }

    #[test]
    fn early_stops_wait_for_the_pipeline() {
        let t0 = Instant::now();
        assert_eq!(stop_at(t0, None), None);
        assert_eq!(stop_at(t0, Some(t0)), Some(t0 + MIN_RUN));
        let later = t0 + Duration::from_secs(5);
        assert_eq!(stop_at(later, Some(t0)), Some(later));
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
        let p = pipeline(42, Some((301, 200)), &r, Encoder::X264);
        assert_eq!(&p[..2], ["gst-launch-1.0", "-e"]);
        let joined = p.join(" ");
        assert!(joined.starts_with("gst-launch-1.0 -e pipewiresrc path=42 "));
        assert!(joined.contains("x264enc"));
        assert!(joined.contains("width=300,height=200"));
        assert!(!joined.contains("pulsesrc"));
        assert!(joined.ends_with("filesink location=/tmp/rec.mp4"), "{joined}");

        let r = Request {
            target: Target::Screen("WL-0".into()),
            pointer: true,
            audio: Some("default".into()),
            fps: 30,
            out: "/tmp/a b\"c.mp4".into(),
            encoder: None,
        };
        let p = pipeline(7, None, &r, Encoder::Nvenc);
        assert!(p.iter().any(|w| w == "nvh264enc"));
        assert!(p.iter().any(|w| w == "pulsesrc"));
        assert!(!p.join(" ").contains("width="));
        assert_eq!(p.last().unwrap(), "location=\"/tmp/a b\\\"c.mp4\"");
    }
}
