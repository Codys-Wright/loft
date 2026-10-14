//! Which desktop to talk to: a named studio-dev test session (its
//! `session.env`), or — only when asked with `--live` — the desktop this
//! process runs in.
//!
//! `studio-dev --session NAME` keeps its runtime dir at
//! `$XDG_RUNTIME_DIR/studio-dev-NAME` (the default session, `dev`, at
//! `$XDG_RUNTIME_DIR/studio-dev`), with a `session.env`:
//!
//! ```text
//! NIRI_SOCKET=/run/user/1000/niri.wayland-3.1234.sock
//! WAYLAND_DISPLAY=wayland-3
//! STUDIO_NIRI_CONFIG=/run/user/1000/studio-dev-agent1/config.kdl
//! STUDIO_SESSION=agent1
//! NIRI_PID=1234
//! …
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

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
    pub env: BTreeMap<String, String>,
}

impl Target {
    pub fn is_live(&self) -> bool {
        self.name.is_none()
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
        runtime_dir().join("studio-dev")
    } else {
        runtime_dir().join(format!("studio-dev-{name}"))
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

/// Every studio-dev session dir with a session.env: (name, dir, env, alive).
pub fn list() -> Vec<(String, PathBuf, BTreeMap<String, String>, bool)> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(runtime_dir()) else {
        return out;
    };
    for e in rd.flatten() {
        let file = e.file_name().to_string_lossy().to_string();
        let name = if file == "studio-dev" {
            DEFAULT_SESSION.to_string()
        } else if let Some(n) = file.strip_prefix("studio-dev-") {
            n.to_string()
        } else {
            continue;
        };
        let Ok(text) = std::fs::read_to_string(e.path().join("session.env")) else {
            continue;
        };
        let env = parse_env(&text);
        let alive = niri_pid(&env).is_some_and(|p| pid_alive(&p))
            && env
                .get("NIRI_SOCKET")
                .is_some_and(|s| Path::new(s).exists());
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
        format!("no studio-dev session `{name}` ({} missing) — start one with `studio-dev --session {name}`", file.display())
    })?;
    let env = parse_env(&text);
    let display = env
        .get("WAYLAND_DISPLAY")
        .cloned()
        .with_context(|| format!("{} has no WAYLAND_DISPLAY", file.display()))?;
    if let Some(pid) = niri_pid(&env)
        && !pid_alive(&pid)
    {
        bail!(
            "session `{name}` is not running (niri {pid} exited); restart it with `studio-dev --session {name}`"
        );
    }
    let niri_config = env
        .get("STUDIO_NIRI_CONFIG")
        .map(PathBuf::from)
        .or_else(|| Some(dir.join("config.kdl")).filter(|p| p.exists()));
    Ok(Target {
        name: Some(name.to_string()),
        wayland_display: display,
        niri_socket: env.get("NIRI_SOCKET").map(PathBuf::from),
        niri_config,
        nested: true,
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
    Ok(Target {
        name: None,
        wayland_display: display,
        niri_socket,
        niri_config: studio_niri::config::entry_config(None),
        nested: false,
        env: BTreeMap::new(),
    })
}

/// How a command picks its target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fallback {
    /// Without --session/--live/$STUDIO_SESSION: only $WAYLAND_DISPLAY when
    /// that is itself a studio-dev session (running inside one). Input uses this.
    RefuseLive,
    /// Without a choice: the default `dev` session (studio-shot's old
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
    if let Some(n) = std::env::var("STUDIO_SESSION")
        .ok()
        .filter(|v| !v.is_empty())
    {
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
            "NIRI_SOCKET=/run/user/1000/niri.wayland-3.4242.sock\nWAYLAND_DISPLAY=wayland-3\n# c\nSTUDIO_THEME_PATH=a:b=c\n",
        );
        assert_eq!(env["WAYLAND_DISPLAY"], "wayland-3");
        assert_eq!(env["STUDIO_THEME_PATH"], "a:b=c");
        assert_eq!(niri_pid(&env).as_deref(), Some("4242"));
    }

    #[test]
    fn names() {
        assert!(valid_name("agent-1"));
        assert!(valid_name("a_b.c"));
        assert!(!valid_name("../x"));
        assert!(!valid_name("a/b"));
        assert!(!valid_name(""));
        assert!(session_dir("dev").ends_with("studio-dev"));
        assert!(session_dir("x").ends_with("studio-dev-x"));
    }
}
