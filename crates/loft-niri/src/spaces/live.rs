//! The live side of spaces: read niri's state, send a plan pipelined on
//! one connection, render `spaces.kdl` to disk.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use niri_ipc::{Action, Reply, Request, Response};
use serde_json::Value;

use super::model::{Catalog, Space};
use super::plan::{self, Plan, State};
use super::roles;
use crate::config;
use crate::state::write_atomic;

/// Write every request, then read every reply: one connection, no reads in
/// between, so niri applies them back to back (SPACES.md §3.1).
pub fn pipeline(reqs: &[Request]) -> Result<Vec<Reply>> {
    let path = std::env::var_os(niri_ipc::socket::SOCKET_PATH_ENV)
        .filter(|v| !v.is_empty())
        .context("$NIRI_SOCKET is not set")?;
    let stream = UnixStream::connect(&path).context("connecting to niri ($NIRI_SOCKET)")?;
    let mut buf = Vec::new();
    for r in reqs {
        serde_json::to_writer(&mut buf, r)?;
        buf.push(b'\n');
    }
    (&stream).write_all(&buf).context("talking to niri")?;
    let mut reader = BufReader::new(&stream);
    let mut replies = Vec::with_capacity(reqs.len());
    for _ in reqs {
        let mut line = String::new();
        reader
            .read_line(&mut line)
            .context("reading niri's reply")?;
        replies.push(serde_json::from_str(&line).context("parsing niri's reply")?);
    }
    Ok(replies)
}

/// Settings → Displays' main display: `overrides/shell.json` `displays.main`.
pub fn main_from_settings(state_dir: &Path) -> Option<String> {
    let text = std::fs::read_to_string(state_dir.join("overrides/shell.json")).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v.pointer("/displays/main")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// niri's outputs, workspaces and focused window, in one round trip.
pub fn read_state(main: Option<String>) -> Result<State> {
    let replies = pipeline(&[
        Request::Outputs,
        Request::Workspaces,
        Request::FocusedWindow,
    ])?;
    let mut st = State {
        main,
        ..Default::default()
    };
    for r in replies {
        match r.map_err(|e| anyhow::anyhow!("niri: {e}"))? {
            Response::Outputs(o) => st.displays = roles::displays_from_niri(&o),
            Response::Workspaces(w) => st.workspaces = w,
            Response::FocusedWindow(w) => st.focused_window = w.map(|w| w.id),
            other => bail!("unexpected reply from niri: {other:?}"),
        }
    }
    Ok(st)
}

/// A recorded state for offline plans: `{"outputs": niri msg -j outputs,
/// "workspaces": niri msg -j workspaces, "focused_window": id | null}`.
pub fn state_from_file(path: &Path, main: Option<String>) -> Result<State> {
    let v: Value = serde_json::from_str(
        &std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?,
    )
    .with_context(|| format!("parsing {}", path.display()))?;
    let outs: crate::outputs::Outputs = serde_json::from_value(v["outputs"].clone())
        .context("`outputs`: expected `niri msg -j outputs`")?;
    Ok(State {
        displays: roles::displays_from_niri(&outs),
        workspaces: serde_json::from_value(v["workspaces"].clone())
            .context("`workspaces`: expected `niri msg -j workspaces`")?,
        focused_window: v["focused_window"].as_u64(),
        main,
    })
}

pub fn send(actions: &[Action]) -> Result<()> {
    if actions.is_empty() {
        return Ok(());
    }
    let reqs: Vec<Request> = actions.iter().cloned().map(Request::Action).collect();
    for (r, a) in pipeline(&reqs)?.into_iter().zip(actions) {
        if let Err(e) = r {
            bail!("niri refused {a:?}: {e}");
        }
    }
    Ok(())
}

/// Plan against the live state and send, for as many rounds as ensure
/// needs (a second workspace created on one display waits for niri to
/// append the next empty one). Returns the plans sent.
pub fn run(main: Option<String>, mut plan_fn: impl FnMut(&State) -> Plan) -> Result<Vec<Plan>> {
    let mut sent = Vec::new();
    for _ in 0..4 {
        let st = read_state(main.clone())?;
        let p = plan_fn(&st);
        send(&p.actions)?;
        let again = p.incomplete;
        sent.push(p);
        if !again {
            return Ok(sent);
        }
    }
    bail!("ensure didn't settle after 4 rounds")
}

pub fn focus(cat: &Catalog, space: &Space, main: Option<String>) -> Result<Vec<Plan>> {
    let order = cat.active();
    run(main, |st| plan::activate(st, space, &order))
}

pub fn spaces_kdl(state_dir: &Path) -> PathBuf {
    state_dir.join("overrides/spaces.kdl")
}

/// Write `spaces.kdl` if it changed: `niri validate` the session's config
/// with the candidate in its place first (unless `validate` is off), swap
/// it in atomically, ask niri to reload. Returns whether it was written.
pub fn render_to_disk(
    state_dir: &Path,
    text: &str,
    entry: Option<&Path>,
    validate: bool,
    reload: bool,
) -> Result<bool> {
    let target = spaces_kdl(state_dir);
    if std::fs::read_to_string(&target).ok().as_deref() == Some(text) {
        return Ok(false);
    }
    let dir = target.parent().unwrap();
    std::fs::create_dir_all(dir)?;
    let candidate = dir.join(format!(".spaces.kdl.candidate-{}", std::process::id()));
    std::fs::write(&candidate, text)?;
    if validate {
        let res = validate_with(entry, &target, &candidate);
        if let Err(e) = res {
            let _ = std::fs::remove_file(&candidate);
            return Err(e);
        }
    }
    std::fs::rename(&candidate, &target).or_else(|_| write_atomic(&target, text))?;
    if reload {
        crate::ipc::reload_config();
    }
    Ok(true)
}

fn validate_with(entry: Option<&Path>, target: &Path, candidate: &Path) -> Result<()> {
    let niri = crate::render::find_niri()
        .context("`niri` is not on PATH, cannot validate (pass --no-validate to skip)")?;
    let scratch = target
        .parent()
        .unwrap()
        .join(format!(".validate-spaces-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch)?;
    let result = (|| {
        let cfg = match entry {
            Some(e) if e.exists() => config::materialize(e, target, candidate, &scratch)?,
            _ => candidate.to_path_buf(),
        };
        let out = Command::new(&niri)
            .args(["validate", "-c"])
            .arg(&cfg)
            .output()
            .with_context(|| format!("running {} validate", niri.display()))?;
        if !out.status.success() {
            bail!(
                "niri rejected spaces.kdl:\n{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
        }
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(&scratch);
    result
}
