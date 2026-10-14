//! `loft-pointer scroll`: the Auto Scroll helper of scrolling capture
//! (⌘⇧5 → Scrolling → Auto). `loft capture scroll` starts it after the user
//! presses Auto in the HUD; it
//!
//! 1. moves the pointer to the centre of the capture area (`--at`),
//! 2. turns the wheel `--step` notches every `--interval-ms` — down, or
//!    right with `--axis horizontal` (wl_pointer horizontal_scroll: a
//!    timeline, a wide table, a pager with `less -S`),
//! 3. stops on `stop` (then moves the pointer back to `--restore`) or
//!    `abort` (leaves it where it is: the user has the mouse) on stdin, on
//!    EOF (the session went away), at `--timeout` or after `--max-notches`.
//!
//! It only ever sends pointer motion and wheel notches through
//! `zwlr_virtual_pointer_v1` — never a button or a key — and only to the
//! Wayland display named by `--display` (no fallback to $WAYLAND_DISPLAY).
//! Deciding *when* to stop (end of content, the user touching the mouse or
//! keyboard) is the caller's job: the stitcher sees the frames, the shell
//! sees the pointer and keys.
//!
//! stdout: JSON lines — `{"event":"ready","socket",…}`,
//! `{"event":"placed","x","y"}`, `{"event":"notch","n"}`,
//! `{"event":"stopped","reason","notches","restored"}`.
//! stdin: `stop` · `abort` · `interval MS` (change the pace).

use std::io::Read as _;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand, ValueEnum};
use serde_json::{Value, json};

use crate::backend::{Axis, Backend, Wayland};
use crate::niri::{Niri, Rect, bounding};

#[derive(Debug, Parser)]
#[command(
    name = "loft-pointer",
    version,
    about = "Loft's Auto Scroll helper: wheel notches over a point, until told to stop"
)]
pub struct Cli {
    #[command(subcommand)]
    pub cmd: Sub,
}

#[derive(Debug, Subcommand)]
pub enum Sub {
    /// Move the pointer to --at and scroll down at a steady pace until
    /// `stop` / `abort` / EOF on stdin, --timeout or --max-notches.
    Scroll(ScrollArgs),
}

#[derive(Debug, Clone, Args)]
pub struct ScrollArgs {
    /// The Wayland display to act on: a socket name (in $XDG_RUNTIME_DIR)
    /// or an absolute socket path. Required: never taken from the
    /// environment implicitly.
    #[arg(long)]
    pub display: String,
    /// niri's IPC socket, for the output layout (default: $NIRI_SOCKET).
    #[arg(long)]
    pub niri_socket: Option<PathBuf>,
    /// The bounding box of all outputs, X,Y,W,H (instead of asking niri).
    #[arg(long)]
    pub bounds: Option<String>,
    /// Where to scroll: global logical X,Y (the capture area's centre).
    #[arg(long, allow_hyphen_values = true)]
    pub at: String,
    /// Where to put the pointer back after `stop` / --timeout / --max-notches.
    #[arg(long, allow_hyphen_values = true)]
    pub restore: Option<String>,
    /// Notches per turn (1–10); negative scrolls up (or left).
    #[arg(long, default_value_t = 1, allow_hyphen_values = true)]
    pub step: i32,
    /// Which wheel: vertical (down) or horizontal (right).
    #[arg(long, value_enum, default_value_t = WheelAxis::Vertical)]
    pub axis: WheelAxis,
    /// Time between turns, ms (50–5000).
    #[arg(long, default_value_t = 250)]
    pub interval_ms: u64,
    /// Stop after this many seconds.
    #[arg(long, default_value_t = 180)]
    pub timeout: u64,
    /// Stop after this many notches.
    #[arg(long, default_value_t = 4000)]
    pub max_notches: u32,
}

/// The wheel axis on the command line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum WheelAxis {
    Vertical,
    Horizontal,
}

impl From<WheelAxis> for Axis {
    fn from(a: WheelAxis) -> Axis {
        match a {
            WheelAxis::Vertical => Axis::Vertical,
            WheelAxis::Horizontal => Axis::Horizontal,
        }
    }
}

pub const MIN_INTERVAL: Duration = Duration::from_millis(50);
pub const MAX_INTERVAL: Duration = Duration::from_millis(5000);

#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub at: (f64, f64),
    pub restore: Option<(f64, f64)>,
    pub step: i32,
    pub axis: Axis,
    pub interval: Duration,
    pub timeout: Duration,
    pub max_notches: u32,
}

pub fn parse_point(s: &str) -> Result<(f64, f64)> {
    let nums: Vec<f64> = s
        .split([',', ' '])
        .filter(|p| !p.is_empty())
        .map(|p| p.trim().parse::<f64>())
        .collect::<std::result::Result<_, _>>()
        .with_context(|| format!("bad point `{s}` (want X,Y)"))?;
    match nums[..] {
        [x, y] if x.is_finite() && y.is_finite() => Ok((x, y)),
        _ => bail!("bad point `{s}` (want X,Y)"),
    }
}

impl Plan {
    pub fn from_args(a: &ScrollArgs) -> Result<Plan> {
        if a.step == 0 || a.step.abs() > 10 {
            bail!("--step must be 1–10 notches (negative: up)");
        }
        let interval = Duration::from_millis(a.interval_ms);
        if !(MIN_INTERVAL..=MAX_INTERVAL).contains(&interval) {
            bail!("--interval-ms must be 50–5000");
        }
        if a.timeout == 0 || a.timeout > 900 {
            bail!("--timeout must be 1–900 s");
        }
        Ok(Plan {
            at: parse_point(&a.at)?,
            restore: a.restore.as_deref().map(parse_point).transpose()?,
            step: a.step,
            axis: a.axis.into(),
            interval,
            timeout: Duration::from_secs(a.timeout),
            max_notches: a.max_notches,
        })
    }
}

/// A line on stdin.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// Stop and put the pointer back (`--restore`).
    Stop,
    /// Stop and leave the pointer alone: the user moved it.
    Abort,
    /// A new pace.
    Interval(Duration),
}

pub fn parse_command(line: &str) -> Option<Command> {
    let mut w = line.split_whitespace();
    match (w.next()?, w.next(), w.next()) {
        ("stop", None, _) => Some(Command::Stop),
        ("abort", None, _) => Some(Command::Abort),
        ("interval", Some(ms), None) => {
            let ms: u64 = ms.parse().ok()?;
            Some(Command::Interval(
                Duration::from_millis(ms).clamp(MIN_INTERVAL, MAX_INTERVAL),
            ))
        }
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Stop,
    Abort,
    /// stdin closed: whoever started us is gone.
    Eof,
    Timeout,
    MaxNotches,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Stop => "stop",
            Reason::Abort => "abort",
            Reason::Eof => "eof",
            Reason::Timeout => "timeout",
            Reason::MaxNotches => "max-notches",
        }
    }

    /// Whether to move the pointer back afterwards. Not after `abort` (the
    /// user has the mouse) or EOF (nobody asked).
    pub fn restores(self) -> bool {
        matches!(self, Reason::Stop | Reason::Timeout | Reason::MaxNotches)
    }
}

/// What waiting for a command gave.
#[derive(Debug, Clone, PartialEq)]
pub enum Input {
    Line(String),
    Idle,
    Eof,
}

/// Commands on stdin (or a script in tests) and the time.
pub trait Control {
    /// Elapsed since the start.
    fn now(&self) -> Duration;
    /// Wait up to `d` for a line.
    fn wait(&mut self, d: Duration) -> Input;
}

/// Run a plan. Only `motion_abs` and `wheel` are ever called on `be`.
pub fn run(
    be: &mut dyn Backend,
    bounds: Rect,
    plan: &Plan,
    ctl: &mut dyn Control,
    emit: &mut dyn FnMut(Value),
) -> Result<Reason> {
    be.motion_abs(plan.at.0, plan.at.1, bounds)?;
    be.sync()?;
    emit(json!({"event": "placed", "x": plan.at.0, "y": plan.at.1}));

    let mut interval = plan.interval;
    // The first turn after one interval: the capture gets a frame of where
    // it starts.
    let mut next = ctl.now() + interval;
    let mut notches: u32 = 0;
    let reason = loop {
        let now = ctl.now();
        if now >= plan.timeout {
            break Reason::Timeout;
        }
        if notches >= plan.max_notches {
            break Reason::MaxNotches;
        }
        if now >= next {
            be.wheel(plan.axis, plan.step)?;
            be.sync()?;
            notches += 1;
            emit(json!({"event": "notch", "n": notches}));
            next += interval;
            if next <= now {
                next = now + interval;
            }
            continue;
        }
        let wait = (next - now).min(plan.timeout - now);
        match ctl.wait(wait) {
            Input::Idle => {}
            Input::Eof => break Reason::Eof,
            Input::Line(l) => match parse_command(&l) {
                Some(Command::Stop) => break Reason::Stop,
                Some(Command::Abort) => break Reason::Abort,
                Some(Command::Interval(d)) => {
                    // Re-time the next turn from the last one.
                    next = next - interval + d;
                    interval = d;
                }
                None => {
                    if !l.trim().is_empty() {
                        emit(
                            json!({"event": "error", "message": format!("unknown command `{}`", l.trim())}),
                        );
                    }
                }
            },
        }
    };
    let mut restored = false;
    if reason.restores()
        && let Some((x, y)) = plan.restore
    {
        be.motion_abs(x, y, bounds)?;
        be.sync()?;
        restored = true;
    }
    emit(
        json!({"event": "stopped", "reason": reason.as_str(), "notches": notches, "restored": restored}),
    );
    Ok(reason)
}

// --- stdin + wall clock --------------------------------------------------------

struct Stdin {
    start: Instant,
    buf: Vec<u8>,
    eof: bool,
}

impl Stdin {
    fn take_line(&mut self) -> Option<String> {
        let i = self.buf.iter().position(|&b| b == b'\n')?;
        let line: Vec<u8> = self.buf.drain(..=i).collect();
        Some(String::from_utf8_lossy(&line).trim().to_string())
    }
}

impl Control for Stdin {
    fn now(&self) -> Duration {
        self.start.elapsed()
    }

    fn wait(&mut self, d: Duration) -> Input {
        if let Some(l) = self.take_line() {
            return Input::Line(l);
        }
        if self.eof {
            return Input::Eof;
        }
        let mut fds = libc::pollfd {
            fd: 0,
            events: libc::POLLIN,
            revents: 0,
        };
        let ms = d.as_millis().min(i32::MAX as u128) as i32;
        // SAFETY: one valid pollfd for the duration of the call.
        let r = unsafe { libc::poll(&mut fds, 1, ms) };
        if r <= 0 {
            return Input::Idle;
        }
        let mut chunk = [0u8; 512];
        match std::io::stdin().lock().read(&mut chunk) {
            Ok(0) | Err(_) => {
                self.eof = true;
                // A last line without a newline still counts.
                if !self.buf.is_empty() {
                    self.buf.push(b'\n');
                    return self.take_line().map_or(Input::Eof, Input::Line);
                }
                Input::Eof
            }
            Ok(n) => {
                self.buf.extend_from_slice(&chunk[..n]);
                self.take_line().map_or(Input::Idle, Input::Line)
            }
        }
    }
}

fn socket_path(display: &str) -> PathBuf {
    let d = std::path::Path::new(display);
    if d.is_absolute() {
        d.to_path_buf()
    } else {
        crate::session::runtime_dir().join(d)
    }
}

pub fn main_with(cli: Cli) -> Result<()> {
    let Sub::Scroll(a) = cli.cmd;
    let plan = Plan::from_args(&a)?;
    if a.display.trim().is_empty() {
        bail!("--display is empty");
    }
    let socket = socket_path(&a.display);
    let bounds = match &a.bounds {
        Some(b) => Rect::parse(b)?,
        None => {
            let s = a
                .niri_socket
                .clone()
                .or_else(|| std::env::var_os("NIRI_SOCKET").map(PathBuf::from))
                .context("no --bounds, --niri-socket or $NIRI_SOCKET for the output layout")?;
            bounding(&Niri::new(&s).outputs()?)
        }
    };
    for (what, p) in [("--at", Some(plan.at)), ("--restore", plan.restore)] {
        if let Some((x, y)) = p
            && !bounds.contains(x, y)
        {
            bail!("{what} {x},{y} is outside the outputs ({bounds})");
        }
    }
    let mut be = Wayland::connect(&socket, true, None)?;
    let mut out = |v: Value| println!("{v}");
    out(json!({"event": "ready", "socket": socket, "bounds": bounds}));
    let mut ctl = Stdin {
        start: Instant::now(),
        buf: Vec::new(),
        eof: false,
    };
    run(&mut be, bounds, &plan, &mut ctl, &mut out)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    #[derive(Debug, Clone, PartialEq)]
    enum Ev {
        Move(f64, f64),
        Wheel(i32),
        HWheel(i32),
    }

    /// Records what reaches the "compositor"; anything but motion and wheel
    /// fails the test.
    #[derive(Default)]
    struct Fake {
        evs: Vec<(Duration, Ev)>,
        clock: Rc<Cell<Duration>>,
    }

    impl Backend for Fake {
        fn motion_abs(&mut self, x: f64, y: f64, _: Rect) -> Result<()> {
            self.evs.push((self.clock.get(), Ev::Move(x, y)));
            Ok(())
        }
        fn motion_rel(&mut self, _: f64, _: f64) -> Result<()> {
            panic!("relative motion")
        }
        fn button(&mut self, _: u32, _: bool) -> Result<()> {
            panic!("auto scroll must never click")
        }
        fn wheel(&mut self, a: Axis, n: i32) -> Result<()> {
            let ev = match a {
                Axis::Vertical => Ev::Wheel(n),
                Axis::Horizontal => Ev::HWheel(n),
            };
            self.evs.push((self.clock.get(), ev));
            Ok(())
        }
        fn smooth_scroll(&mut self, _: Axis, _: f64, _: bool) -> Result<()> {
            panic!("smooth scroll")
        }
        fn key(&mut self, _: u32, _: bool) -> Result<()> {
            panic!("auto scroll must never type")
        }
        fn modifiers(&mut self, _: u32) -> Result<()> {
            panic!("auto scroll must never type")
        }
        fn sync(&mut self) -> Result<()> {
            Ok(())
        }
    }

    /// A fake clock plus a script of (time, input) lines.
    struct Script {
        clock: Rc<Cell<Duration>>,
        lines: Vec<(Duration, Input)>,
    }

    impl Control for Script {
        fn now(&self) -> Duration {
            self.clock.get()
        }
        fn wait(&mut self, d: Duration) -> Input {
            let now = self.clock.get();
            if let Some((t, _)) = self.lines.first()
                && *t <= now + d
            {
                let (t, i) = self.lines.remove(0);
                self.clock.set(t.max(now));
                return i;
            }
            self.clock.set(now + d);
            Input::Idle
        }
    }

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    fn plan() -> Plan {
        Plan {
            at: (800.0, 500.0),
            restore: Some((1200.0, 900.0)),
            step: 1,
            axis: Axis::Vertical,
            interval: ms(250),
            timeout: Duration::from_secs(180),
            max_notches: 4000,
        }
    }

    fn go(plan: &Plan, lines: Vec<(Duration, Input)>) -> (Reason, Vec<(Duration, Ev)>, Vec<Value>) {
        let clock = Rc::new(Cell::new(Duration::ZERO));
        let mut be = Fake {
            evs: Vec::new(),
            clock: clock.clone(),
        };
        let mut ctl = Script { clock, lines };
        let mut out = Vec::new();
        let r = run(
            &mut be,
            Rect::new(0.0, 0.0, 1600.0, 1000.0),
            plan,
            &mut ctl,
            &mut |v| out.push(v),
        )
        .unwrap();
        (r, be.evs, out)
    }

    fn wheels(evs: &[(Duration, Ev)]) -> Vec<Duration> {
        evs.iter()
            .filter(|(_, e)| matches!(e, Ev::Wheel(_)))
            .map(|(t, _)| *t)
            .collect()
    }

    #[test]
    fn places_then_scrolls_at_a_steady_pace_and_restores_on_stop() {
        let (r, evs, out) = go(&plan(), vec![(ms(1100), Input::Line("stop".into()))]);
        assert_eq!(r, Reason::Stop);
        assert_eq!(evs.first().unwrap().1, Ev::Move(800.0, 500.0));
        assert_eq!(wheels(&evs), vec![ms(250), ms(500), ms(750), ms(1000)]);
        assert_eq!(evs.last().unwrap(), &(ms(1100), Ev::Move(1200.0, 900.0)));
        let last = out.last().unwrap();
        assert_eq!(last["reason"], "stop");
        assert_eq!(last["notches"], 4);
        assert_eq!(last["restored"], true);
    }

    #[test]
    fn horizontal_axis_turns_only_the_horizontal_wheel() {
        let mut p = plan();
        p.axis = Axis::Horizontal;
        let (r, evs, _) = go(&p, vec![(ms(800), Input::Line("stop".into()))]);
        assert_eq!(r, Reason::Stop);
        // Only pointer motion (place + restore) and horizontal notches: the
        // fake backend panics on a click, a key or smooth scrolling.
        assert!(
            evs.iter()
                .all(|(_, e)| matches!(e, Ev::Move(..) | Ev::HWheel(1))),
            "{evs:?}"
        );
        let notches: Vec<_> = evs
            .iter()
            .filter(|(_, e)| matches!(e, Ev::HWheel(_)))
            .map(|(t, _)| *t)
            .collect();
        assert_eq!(notches, vec![ms(250), ms(500), ms(750)]);
        assert_eq!(
            evs.iter()
                .filter(|(_, e)| matches!(e, Ev::Move(..)))
                .count(),
            2
        );
    }

    #[test]
    fn abort_and_eof_leave_the_pointer_alone() {
        for (input, reason) in [
            (Input::Line("abort".into()), Reason::Abort),
            (Input::Eof, Reason::Eof),
        ] {
            let (r, evs, out) = go(&plan(), vec![(ms(600), input)]);
            assert_eq!(r, reason);
            let moves = evs
                .iter()
                .filter(|(_, e)| matches!(e, Ev::Move(..)))
                .count();
            assert_eq!(moves, 1, "only the initial placement");
            assert_eq!(out.last().unwrap()["restored"], false);
        }
    }

    #[test]
    fn stops_at_the_timeout_and_the_notch_cap() {
        let mut p = plan();
        p.timeout = Duration::from_secs(2);
        let (r, evs, _) = go(&p, vec![]);
        assert_eq!(r, Reason::Timeout);
        assert_eq!(wheels(&evs).len(), 7, "250, 500 … 1750 ms");
        assert!(matches!(evs.last().unwrap().1, Ev::Move(1200.0, 900.0)));

        let mut p = plan();
        p.max_notches = 3;
        let (r, evs, _) = go(&p, vec![]);
        assert_eq!(r, Reason::MaxNotches);
        assert_eq!(wheels(&evs).len(), 3);
    }

    #[test]
    fn interval_changes_the_pace() {
        let (_, evs, _) = go(
            &plan(),
            vec![
                (ms(300), Input::Line("interval 500".into())),
                (ms(1800), Input::Line("stop".into())),
            ],
        );
        // 250, then the next one 500 after it, …
        assert_eq!(wheels(&evs), vec![ms(250), ms(750), ms(1250), ms(1750)]);
    }

    #[test]
    fn unknown_lines_are_reported_not_obeyed() {
        let (r, evs, out) = go(
            &plan(),
            vec![
                (ms(100), Input::Line("click 1 2".into())),
                (ms(120), Input::Line("".into())),
                (ms(300), Input::Line("stop".into())),
            ],
        );
        assert_eq!(r, Reason::Stop);
        assert_eq!(wheels(&evs).len(), 1);
        assert_eq!(out.iter().filter(|v| v["event"] == "error").count(), 1);
    }

    #[test]
    fn commands_and_args() {
        assert_eq!(parse_command(" stop \n"), Some(Command::Stop));
        assert_eq!(parse_command("abort"), Some(Command::Abort));
        assert_eq!(
            parse_command("interval 10"),
            Some(Command::Interval(MIN_INTERVAL))
        );
        assert_eq!(
            parse_command("interval 400"),
            Some(Command::Interval(ms(400)))
        );
        assert_eq!(parse_command("interval x"), None);
        assert_eq!(parse_command("stop now"), None);
        assert_eq!(parse_command("click"), None);

        let cli = Cli::try_parse_from([
            "loft-pointer",
            "scroll",
            "--display",
            "wayland-9",
            "--at",
            "100,-20",
            "--restore",
            "5,6",
            "--interval-ms",
            "300",
        ])
        .unwrap();
        let Sub::Scroll(a) = cli.cmd;
        let p = Plan::from_args(&a).unwrap();
        assert_eq!(p.at, (100.0, -20.0));
        assert_eq!(p.restore, Some((5.0, 6.0)));
        assert_eq!(p.interval, ms(300));
        assert_eq!(p.axis, Axis::Vertical, "vertical unless asked");
        let cli = Cli::try_parse_from([
            "loft-pointer",
            "scroll",
            "--display",
            "w",
            "--at",
            "1,2",
            "--axis",
            "horizontal",
        ])
        .unwrap();
        let Sub::Scroll(a) = cli.cmd;
        assert_eq!(Plan::from_args(&a).unwrap().axis, Axis::Horizontal);
        assert!(
            Cli::try_parse_from([
                "loft-pointer",
                "scroll",
                "--display",
                "w",
                "--at",
                "1,2",
                "--axis",
                "diagonal",
            ])
            .is_err()
        );
        assert!(
            Cli::try_parse_from(["loft-pointer", "scroll", "--at", "1,2"]).is_err(),
            "--display is required"
        );
        let bad = |extra: &[&str]| {
            let mut v = vec!["loft-pointer", "scroll", "--display", "w", "--at", "1,2"];
            v.extend_from_slice(extra);
            match Cli::try_parse_from(v) {
                Err(_) => true,
                Ok(c) => {
                    let Sub::Scroll(a) = c.cmd;
                    Plan::from_args(&a).is_err()
                }
            }
        };
        assert!(bad(&["--step", "0"]));
        assert!(bad(&["--step", "50"]));
        assert!(bad(&["--interval-ms", "5"]));
        assert!(bad(&["--timeout", "0"]));
        assert_eq!(socket_path("/x/wayland-3"), PathBuf::from("/x/wayland-3"));
        assert!(socket_path("wayland-3").ends_with("wayland-3"));
    }
}
