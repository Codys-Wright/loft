//! Which desktop to talk to: a named loft-dev test session (its
//! `session.env`), or — only when asked with `--live` — the desktop this
//! process runs in.
//!
//! `loft-dev --session NAME` keeps its runtime dir at
//! `$XDG_RUNTIME_DIR/loft-dev-NAME` (the default session, `dev`, at
//! `$XDG_RUNTIME_DIR/loft-dev`), with a `session.env`:
//!
//! ```text
//! NIRI_SOCKET=/run/user/1000/niri.wayland-3.1234.sock
//! WAYLAND_DISPLAY=wayland-3
//! LOFT_NIRI_CONFIG=/run/user/1000/loft-dev-agent1/config.kdl
//! LOFT_SESSION=agent1
//! NIRI_PID=1234
//! …
//! ```
//!
//! KDE sessions (`loft-dev --compositor kwin`) have no niri: their
//! session.env says `LOFT_DEV_COMPOSITOR=kwin`, `WAYLAND_DISPLAY` is KWin's
//! socket (for clients), `LOFT_DEV_HOST_DISPLAY` the headless host KWin is a
//! window in (where input and screenshots go), and `LOFT_DEV_OUTPUT_RECTS`
//! the outputs' layout (`WL-0=0,0,1600x1000+WL-1=1600,0,1600x1000`; `+`, so the file
//! still sources in a shell).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::niri::{Niri, OutputRect, Rect};

pub const DEFAULT_SESSION: &str = "dev";

#[derive(Debug, Clone)]
pub struct Target {
    /// Session name, None for the live desktop.
    pub name: Option<String>,
    pub wayland_display: String,
    pub niri_socket: Option<PathBuf>,
    /// The niri entry config (for `bind`).
    pub niri_config: Option<PathBuf>,
    /// Whether niri runs nested (winit) — decides `mod-key` vs `mod-key-nested`.
    pub nested: bool,
    /// The compositor: `niri`, or `kwin` (a KDE session from loft-dev).
    pub compositor: String,
    /// Fixed output layout (KDE sessions: the host's outputs).
    pub fixed_outputs: Option<Vec<OutputRect>>,
    pub env: BTreeMap<String, String>,
}

impl Target {
    pub fn is_live(&self) -> bool {
        self.name.is_none()
    }

    pub fn is_kwin(&self) -> bool {
        self.compositor == "kwin"
    }

    /// Enabled outputs, left to right: niri's, or the session's fixed layout.
    pub fn outputs(&self) -> Result<Vec<OutputRect>> {
        if let Some(o) = &self.fixed_outputs {
            return Ok(o.clone());
        }
        let s = self
            .niri_socket
            .as_ref()
            .with_context(|| format!("{} has no niri socket ($NIRI_SOCKET)", self.label()))?;
        Niri::new(s).outputs()
    }

    pub fn label(&self) -> String {
        match &self.name {
            Some(n) => format!("session `{n}` ({})", self.wayland_display),
            None => format!("the LIVE desktop ({})", self.wayland_display),
        }
    }

    /// Path of the Wayland socket.
    pub fn socket_path(&self) -> PathBuf {
        let d = Path::new(&self.wayland_display);
        if d.is_absolute() {
            d.to_path_buf()
        } else {
            runtime_dir().join(d)
        }
    }
}

pub fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })))
}

pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
        && !name.starts_with('.')
}

pub fn session_dir(name: &str) -> PathBuf {
    if name == DEFAULT_SESSION {
        runtime_dir().join("loft-dev")
    } else {
        runtime_dir().join(format!("loft-dev-{name}"))
    }
}

pub fn parse_env(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|l| {
            let l = l.trim();
            if l.starts_with('#') {
                return None;
            }
            let (k, v) = l.split_once('=')?;
            Some((k.trim().to_string(), v.to_string()))
        })
        .collect()
}

fn pid_alive(pid: &str) -> bool {
    !pid.is_empty() && Path::new(&format!("/proc/{pid}")).exists()
}

/// The niri pid recorded for a session (NIRI_PID, else from the socket name
/// `niri.wayland-N.PID.sock`).
pub fn niri_pid(env: &BTreeMap<String, String>) -> Option<String> {
    env.get("NIRI_PID").cloned().or_else(|| {
        let s = env.get("NIRI_SOCKET")?;
        let stem = s.strip_suffix(".sock")?;
        Some(stem.rsplit('.').next()?.to_string())
    })
}

/// `NAME=X,Y,WxH+…` (LOFT_DEV_OUTPUT_RECTS), left to right.
pub fn parse_output_rects(s: &str) -> Result<Vec<OutputRect>> {
    let mut out = Vec::new();
    for part in s.split(['+', ';']).filter(|p| !p.trim().is_empty()) {
        let (name, r) = part
            .split_once('=')
            .with_context(|| format!("bad output `{part}` (want NAME=X,Y,WxH)"))?;
        out.push(OutputRect {
            name: name.trim().to_string(),
            rect: Rect::parse(r)?,
            scale: 1.0,
            transform: "Normal".into(),
        });
    }
    out.sort_by(|a, b| {
        (a.rect.x, a.rect.y)
            .partial_cmp(&(b.rect.x, b.rect.y))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    Ok(out)
}

fn is_kwin(env: &BTreeMap<String, String>) -> bool {
    env.get("LOFT_DEV_COMPOSITOR").is_some_and(|c| c == "kwin")
}

/// Whether a session's compositor still runs (KWin and its host for KDE
/// sessions; niri, and its socket, otherwise).
fn alive(env: &BTreeMap<String, String>) -> bool {
    if is_kwin(env) {
        return ["KWIN_PID", "LOFT_DEV_HOST_PID"]
            .iter()
            .all(|k| env.get(*k).is_some_and(|p| pid_alive(p)));
    }
    niri_pid(env).is_some_and(|p| pid_alive(&p))
        && env
            .get("NIRI_SOCKET")
            .is_some_and(|s| Path::new(s).exists())
}

/// Every loft-dev session dir with a session.env: (name, dir, env, alive).
pub fn list() -> Vec<(String, PathBuf, BTreeMap<String, String>, bool)> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(runtime_dir()) else {
        return out;
    };
    for e in rd.flatten() {
        let file = e.file_name().to_string_lossy().to_string();
        let name = if file == "loft-dev" {
            DEFAULT_SESSION.to_string()
        } else if let Some(n) = file.strip_prefix("loft-dev-") {
            n.to_string()
        } else {
            continue;
        };
        let Ok(text) = std::fs::read_to_string(e.path().join("session.env")) else {
            continue;
        };
        let env = parse_env(&text);
        let alive = alive(&env);
        out.push((name, e.path(), env, alive));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

pub fn load(name: &str) -> Result<Target> {
    if !valid_name(name) {
        bail!("bad session name `{name}` (letters, digits, - _ .)");
    }
    let dir = session_dir(name);
    let file = dir.join("session.env");
    let text = std::fs::read_to_string(&file).with_context(|| {
        format!("no loft-dev session `{name}` ({} missing) — start one with `loft-dev --session {name}`", file.display())
    })?;
    let env = parse_env(&text);
    let kwin = is_kwin(&env);
    // KDE sessions: input and screenshots go to the host KWin runs in.
    let display = env
        .get(if kwin {
            "LOFT_DEV_HOST_DISPLAY"
        } else {
            "WAYLAND_DISPLAY"
        })
        .cloned()
        .with_context(|| format!("{} has no WAYLAND_DISPLAY", file.display()))?;
    if kwin && !alive(&env) {
        bail!(
            "session `{name}` is not running (KWin exited); restart it with `loft-dev --session {name} --compositor kwin`"
        );
    }
    let fixed_outputs = env
        .get("LOFT_DEV_OUTPUT_RECTS")
        .map(|s| parse_output_rects(s))
        .transpose()?;
    if !kwin
        && let Some(pid) = niri_pid(&env)
        && !pid_alive(&pid)
    {
        bail!(
            "session `{name}` is not running (niri {pid} exited); restart it with `loft-dev --session {name}`"
        );
    }
    let niri_config = env
        .get("LOFT_NIRI_CONFIG")
        .map(PathBuf::from)
        .or_else(|| Some(dir.join("config.kdl")).filter(|p| p.exists()));
    Ok(Target {
        name: Some(name.to_string()),
        wayland_display: display,
        niri_socket: env.get("NIRI_SOCKET").map(PathBuf::from),
        niri_config,
        // `loft-dev --outputs` runs niri on virtual outputs, not nested.
        nested: env.get("LOFT_DEV_NESTED").is_none_or(|v| v != "0"),
        compositor: if kwin { "kwin" } else { "niri" }.into(),
        fixed_outputs,
        env,
    })
}

/// The desktop this process runs in ($WAYLAND_DISPLAY / $NIRI_SOCKET).
pub fn live() -> Result<Target> {
    let display = std::env::var("WAYLAND_DISPLAY")
        .ok()
        .filter(|v| !v.is_empty())
        .context("$WAYLAND_DISPLAY is not set")?;
    let niri_socket = std::env::var_os("NIRI_SOCKET")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    let niri_socket_set = niri_socket.is_some();
    Ok(Target {
        name: None,
        wayland_display: display,
        niri_socket,
        niri_config: loft_niri::config::entry_config(None),
        nested: false,
        compositor: if niri_socket_set { "niri" } else { "unknown" }.into(),
        fixed_outputs: None,
        env: BTreeMap::new(),
    })
}

/// How a command picks its target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fallback {
    /// Without --session/--live/$LOFT_SESSION: only $WAYLAND_DISPLAY when
    /// that is itself a loft-dev session (running inside one). Input uses this.
    RefuseLive,
    /// Without a choice: the default `dev` session (loft-shot's old
    /// behaviour).
    DefaultSession,
}

pub fn resolve(session: Option<&str>, live_flag: bool, fallback: Fallback) -> Result<Target> {
    if session.is_some() && live_flag {
        bail!("--session and --live are exclusive");
    }
    if let Some(n) = session {
        return load(n);
    }
    if live_flag {
        return live();
    }
    if let Some(n) = std::env::var("LOFT_SESSION").ok().filter(|v| !v.is_empty()) {
        return load(&n);
    }
    // Running inside a session (a terminal in it, or a script it spawned).
    if let Ok(d) = std::env::var("WAYLAND_DISPLAY")
        && let Some((name, ..)) = list()
            .into_iter()
            .find(|(_, _, env, alive)| *alive && env.get("WAYLAND_DISPLAY") == Some(&d))
    {
        return load(&name);
    }
    match fallback {
        Fallback::DefaultSession => load(DEFAULT_SESSION).map_err(|e| {
            e.context("pass --session NAME for a test session, or --live for this desktop")
        }),
        Fallback::RefuseLive => {
            let running: Vec<String> = list().into_iter().filter(|s| s.3).map(|s| s.0).collect();
            bail!(
                "no target: pass --session NAME (running: {}), or --live to drive the desktop you are sitting at ({})",
                if running.is_empty() {
                    "none".to_string()
                } else {
                    running.join(", ")
                },
                std::env::var("WAYLAND_DISPLAY").unwrap_or_default()
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_session_env() {
        let env = parse_env(
            "NIRI_SOCKET=/run/user/1000/niri.wayland-3.4242.sock\nWAYLAND_DISPLAY=wayland-3\n# c\nLOFT_THEME_PATH=a:b=c\n",
        );
        assert_eq!(env["WAYLAND_DISPLAY"], "wayland-3");
        assert_eq!(env["LOFT_THEME_PATH"], "a:b=c");
        assert_eq!(niri_pid(&env).as_deref(), Some("4242"));
    }

    #[test]
    fn kwin_session_env() {
        let env = parse_env(
            "LOFT_DEV_COMPOSITOR=kwin\nKWIN_PID=999999999\nLOFT_DEV_HOST_PID=1\nLOFT_DEV_OUTPUT_RECTS=WL-1=1600,0,1280x800+WL-0=0,0,1600x1000\n",
        );
        assert!(is_kwin(&env));
        assert!(!alive(&env));
        let o = parse_output_rects(&env["LOFT_DEV_OUTPUT_RECTS"]).unwrap();
        assert_eq!(o[0].name, "WL-0");
        assert_eq!(o[1].rect, Rect::new(1600.0, 0.0, 1280.0, 800.0));
    }

    #[test]
    fn names() {
        assert!(valid_name("agent-1"));
        assert!(valid_name("a_b.c"));
        assert!(!valid_name("../x"));
        assert!(!valid_name("a/b"));
        assert!(!valid_name(""));
        assert!(session_dir("dev").ends_with("loft-dev"));
        assert!(session_dir("x").ends_with("loft-dev-x"));
    }
}
