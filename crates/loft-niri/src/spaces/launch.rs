//! The live side of spin-up / restore (SPACES.md §4): read windows and
//! `/proc`, spawn apps in transient systemd scopes, wait for their windows,
//! send the placement and order actions, keep `runtime.json`.
//!
//! - `open`: activate (unless `--no-focus`), find, spawn what's missing,
//!   wait (10 s), place, order the columns of new windows, focus main's
//!   first app.
//! - `gather`: find + place, never spawn. A window that had to move
//!   (gathered back, or into main's workspace by a `columns` fold) is put
//!   at its declared column.
//! - `close`: `CloseWindow` for the space's windows (claimed, or in its
//!   apps' scopes); an instance's workspaces lose their names so niri drops
//!   them when empty. The instance file stays.
//! - `focus` ([`focus`]): records what the `keep` displays show, brings
//!   them back when the space was already active, and spins the space up
//!   on its first activation in a session (`startup: "first-activate"`,
//!   §12.4: lazy restore).
//!
//! Spawning: `systemd-run --user --scope --unit <prefix>-<space>-<app>.scope
//! -- <exec>` in the app's cwd. An active unit of that name means the app is
//! already running (its window may still be coming): it is never started
//! twice. Without a reachable user manager the command is spawned directly
//! and its pid's descendants stand in for the scope.
//!
//! Test sessions (TESTING.md) have their own `XDG_RUNTIME_DIR`, so the
//! user manager isn't reachable from inside them.
//! `LOFT_SPACES_SYSTEMD_RUNTIME_DIR=/run/user/<uid>` reaches it anyway: only
//! `systemctl` / `systemd-run` see that runtime dir, and the app gets the
//! session's back (`env XDG_RUNTIME_DIR=… DBUS_SESSION_BUS_ADDRESS=…`).
//! `LOFT_SPACES_UNIT_PREFIX` keeps a test session's units apart.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use niri_ipc::{Action, Request, Response, WorkspaceReferenceArg};
use serde::Serialize;

use super::apps::{self, AppSpec, Found, How, Win};
use super::live;
use super::model::{Binding, Catalog, Space};
use super::plan::{self, Plan, State};
use super::roles;
use super::runtime::{self, Runtime};

#[derive(Debug, Clone)]
pub struct Opts {
    pub state_dir: PathBuf,
    pub main: Option<String>,
    pub prefix: String,
    pub timeout: Duration,
    pub home: String,
    /// The user manager's runtime dir, when it isn't ours (test sessions).
    pub systemd_runtime: Option<String>,
    pub proc_root: PathBuf,
}

impl Opts {
    pub fn from_env(state_dir: &Path, main: Option<String>) -> Self {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        Opts {
            state_dir: state_dir.to_path_buf(),
            main,
            prefix: var("LOFT_SPACES_UNIT_PREFIX").unwrap_or_else(|| apps::UNIT_PREFIX.into()),
            timeout: Duration::from_secs(10),
            home: var("HOME").unwrap_or_default(),
            systemd_runtime: var("LOFT_SPACES_SYSTEMD_RUNTIME_DIR"),
            proc_root: PathBuf::from("/proc"),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct AppReport {
    pub app: String,
    pub role: String,
    pub workspace: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub how: Option<How>,
    /// started: spawned now; running: its unit was already active.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spawn: Option<&'static str>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Report {
    pub space: String,
    pub apps: Vec<AppReport>,
    pub actions: Vec<Action>,
    pub notes: Vec<String>,
    /// The activation rounds sent, if any.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub rounds: Vec<Plan>,
}

impl Report {
    pub fn text(&self) -> String {
        let mut out: Vec<String> = self
            .apps
            .iter()
            .map(|a| {
                let w = a.window.map_or("—".to_string(), |w| format!("window {w}"));
                let how = a.how.map_or(String::new(), |h| {
                    let v = serde_json::to_value(h).unwrap_or_default();
                    format!(" ({})", v.as_str().unwrap_or(""))
                });
                let sp = a.spawn.map_or(String::new(), |s| format!(" [{s}]"));
                format!(
                    "{:12} {:8} → {:14} {w}{how}{sp}",
                    a.app, a.role, a.workspace
                )
            })
            .collect();
        out.extend(self.notes.iter().map(|n| format!("note: {n}")));
        out.join("\n")
    }
}

/// niri's windows with what `/proc` says about their processes.
pub fn windows(opts: &Opts, lineage: bool) -> Result<Vec<Win>> {
    let reply = live::pipeline(&[Request::Windows])?
        .pop()
        .context("no reply from niri")?;
    let Response::Windows(ws) = reply.map_err(|e| anyhow::anyhow!("niri: {e}"))? else {
        anyhow::bail!("unexpected reply from niri");
    };
    Ok(ws
        .iter()
        .map(|w| {
            let mut x = Win::from_niri(w);
            if let Some(pid) = w.pid {
                (x.cgroup, x.cwd) = apps::proc_info(&opts.proc_root, pid);
                if lineage {
                    x.lineage = apps::lineage(&opts.proc_root, pid);
                }
            }
            x
        })
        .collect())
}

fn ws_names(st: &State) -> BTreeMap<u64, String> {
    st.workspaces
        .iter()
        .filter_map(|w| Some((w.id, w.name.clone()?)))
        .collect()
}

fn all_claims(rt: &Runtime) -> BTreeMap<u64, (String, String)> {
    rt.claims
        .iter()
        .map(|(w, c)| (*w, (c.space.clone(), c.app.clone())))
        .collect()
}

fn systemctl(opts: &Opts) -> Command {
    let mut c = Command::new("systemctl");
    if let Some(rt) = &opts.systemd_runtime {
        c.env("XDG_RUNTIME_DIR", rt)
            .env("DBUS_SESSION_BUS_ADDRESS", format!("unix:path={rt}/bus"));
    }
    c.arg("--user")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    c
}

/// Whether the systemd user manager answers.
fn have_systemd(opts: &Opts) -> bool {
    std::env::var_os("LOFT_SPACES_NO_SCOPES").is_none()
        && systemctl(opts)
            .args(["show", "--property=Version"])
            .status()
            .is_ok_and(|s| s.success())
}

fn unit_active(opts: &Opts, unit: &str) -> bool {
    systemctl(opts)
        .args(["is-active", "--quiet", unit])
        .status()
        .is_ok_and(|s| s.success())
}

enum Spawned {
    Started(Option<i32>),
    Running,
}

fn spawn(spec: &AppSpec, opts: &Opts, scopes: bool) -> Result<Spawned> {
    use std::os::unix::process::CommandExt;
    if scopes && unit_active(opts, &spec.unit) {
        return Ok(Spawned::Running);
    }
    let mut cmd = if scopes {
        let mut c = Command::new("systemd-run");
        c.args([
            "--user",
            "--scope",
            "--quiet",
            "--collect",
            "--unit",
            &spec.unit,
            "--",
        ]);
        if let Some(rt) = &opts.systemd_runtime {
            // Only systemd-run talks to that manager; the app gets ours back.
            c.env("XDG_RUNTIME_DIR", rt)
                .env("DBUS_SESSION_BUS_ADDRESS", format!("unix:path={rt}/bus"));
            c.arg("env");
            for k in ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
                match std::env::var(k) {
                    Ok(v) => c.arg(format!("{k}={v}")),
                    Err(_) => c.args(["-u", k]),
                };
            }
        }
        c.args(&spec.exec);
        c
    } else {
        let mut c = Command::new(&spec.exec[0]);
        c.args(&spec.exec[1..]);
        c
    };
    if let Some(d) = spec.cwd.as_deref().filter(|d| Path::new(d).is_dir()) {
        cmd.current_dir(d);
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0);
    let mut child = cmd
        .spawn()
        .with_context(|| format!("starting `{}`", spec.exec.join(" ")))?;
    let pid = i32::try_from(child.id()).ok();
    // Reap it if it exits while we wait (editors hand off and exit).
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(Spawned::Started(if scopes { None } else { pid }))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Spawn what's missing, place, order once.
    Open,
    /// Place what's there.
    Gather,
}

/// Find, spawn (Open), wait, place, order (Open). Doesn't activate.
fn spin(space: &Space, opts: &Opts, mode: Mode, report: &mut Report) -> Result<()> {
    let session = runtime::session_key();
    let st = live::read_state(opts.main.clone())?;
    let res = roles::resolve(space, &st.displays, st.main.as_deref());
    let (mut specs, notes) = apps::specs(space, &res, &opts.prefix, &opts.home);
    report.notes.extend(notes);
    let wins = windows(opts, false)?;
    let alive: BTreeSet<u64> = wins.iter().map(|w| w.id).collect();
    let rt = runtime::update(&opts.state_dir, &session, |rt| {
        rt.prune(&alive);
        rt.clone()
    })?;
    let claims = all_claims(&rt);
    let mine = rt.claims_of(&space.id);
    let mut found = apps::find(&specs, &wins, &claims, &ws_names(&st), &opts.prefix);
    let mut spawned: Vec<Option<&'static str>> = vec![None; specs.len()];

    if mode == Mode::Open {
        let missing: Vec<usize> = (0..specs.len())
            .filter(|&i| found[i].is_none() && specs[i].launch)
            .collect();
        if !missing.is_empty() {
            let scopes = have_systemd(opts);
            if !scopes {
                report
                    .notes
                    .push("no systemd user manager: spawning without scopes".into());
            }
            for &i in &missing {
                match spawn(&specs[i], opts, scopes) {
                    Ok(Spawned::Started(pid)) => {
                        specs[i].pid = pid;
                        spawned[i] = Some("started");
                    }
                    Ok(Spawned::Running) => spawned[i] = Some("running"),
                    Err(e) => report.notes.push(format!("{}: {e:#}", specs[i].app)),
                }
            }
            // Wait for the windows (editors that hand off to a running
            // process are found by app-id + title within the timeout).
            let waiting = |found: &[Option<Found>]| {
                (0..specs.len()).any(|i| spawned[i].is_some() && found[i].is_none())
            };
            let deadline = Instant::now() + opts.timeout;
            let lineage = specs.iter().any(|s| s.pid.is_some());
            while waiting(&found) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(150));
                let wins = windows(opts, lineage)?;
                let st = live::read_state(opts.main.clone())?;
                found = apps::find(&specs, &wins, &claims, &ws_names(&st), &opts.prefix);
            }
            for i in 0..specs.len() {
                if spawned[i].is_some() && found[i].is_none() {
                    report.notes.push(format!(
                        "Couldn't find the {} window (waited {} s)",
                        specs[i].app,
                        opts.timeout.as_secs()
                    ));
                }
            }
        }
    }

    // Place against fresh state (new windows, ensured workspaces).
    let st = live::read_state(opts.main.clone())?;
    let wins = windows(opts, false)?;
    let fresh: BTreeSet<u64> = specs
        .iter()
        .zip(&found)
        .filter_map(|(s, f)| {
            let f = f.as_ref()?;
            (mine.get(&f.window) != Some(&s.app)).then_some(f.window)
        })
        .collect();
    let (actions, notes) = apps::place(&st, &specs, &found, &wins, &fresh);
    report.notes.extend(notes);
    live::send(&actions)?;
    // Columns: at spin-up, and for windows that just moved into a
    // workspace (gathered back, or folded into main's), against where the
    // windows are now. Columns you rearranged in place are left alone.
    let mut touched = fresh.clone();
    touched.extend(actions.iter().filter_map(|a| match a {
        Action::MoveWindowToWorkspace {
            window_id: Some(id),
            ..
        } => Some(*id),
        _ => None,
    }));
    report.actions.extend(actions);
    if !touched.is_empty() {
        std::thread::sleep(Duration::from_millis(50));
        let wins = windows(opts, false)?;
        let (actions, _) = apps::order(&specs, &found, &wins, &touched);
        live::send(&actions)?;
        report.actions.extend(actions);
    }

    // Claims: this space's apps → their windows.
    let claims: BTreeMap<u64, String> = specs
        .iter()
        .zip(&found)
        .filter_map(|(s, f)| Some((f.as_ref()?.window, s.app.clone())))
        .collect();
    runtime::update(&opts.state_dir, &session, |rt| {
        // Keep claims of apps the layout leaves out right now (a skip fold).
        let mut all = rt.claims_of(&space.id);
        all.retain(|w, app| !claims.contains_key(w) && !specs.iter().any(|s| &s.app == app));
        all.extend(claims.clone());
        rt.set_claims(&space.id, &all);
    })?;
    report.apps = specs
        .iter()
        .zip(&found)
        .zip(&spawned)
        .map(|((s, f), sp)| AppReport {
            app: s.app.clone(),
            role: s.role.clone(),
            workspace: s.workspace.clone(),
            window: f.as_ref().map(|f| f.window),
            how: f.as_ref().map(|f| f.how),
            spawn: *sp,
        })
        .collect();
    Ok(())
}

/// The first app of main's workspace that has a window.
fn first_main(report: &Report) -> Option<u64> {
    report
        .apps
        .iter()
        .filter(|a| a.window.is_some())
        .min_by_key(|a| a.role != "main")
        .and_then(|a| a.window)
}

/// Activate with the per-space memory: record what `keep` displays show,
/// restore them when the space was already active. Returns the rounds.
pub fn activate(cat: &Catalog, space: &Space, opts: &Opts) -> Result<Vec<Plan>> {
    let session = runtime::session_key();
    let rt = runtime::load(&opts.state_dir);
    let memory = rt
        .memory
        .get(&space.id)
        .map(|m| m.keep.clone())
        .unwrap_or_default();
    let order = cat.active();
    let mut record: Option<BTreeMap<String, String>> = None;
    let plans = live::run(opts.main.clone(), |st| {
        let already = plan::active_space(st, cat).is_some_and(|a| a.id == space.id);
        if record.is_none() {
            // Keep displays don't change on activation (unless restored):
            // what they show now is what the space keeps.
            record = Some(if already && !memory.is_empty() {
                memory.clone()
            } else {
                plan::keep_shown(st, space)
            });
        }
        let restore = if already {
            memory.clone()
        } else {
            BTreeMap::new()
        };
        plan::activate_with(st, space, &order, &restore)
    })?;
    let rec = record.unwrap_or_default();
    runtime::update(&opts.state_dir, &session, |rt| {
        rt.active = Some(space.id.clone());
        if rec.is_empty() {
            rt.memory.remove(&space.id);
        } else {
            rt.memory.entry(space.id.clone()).or_default().keep = rec;
        }
    })?;
    Ok(plans)
}

/// `space focus`: activate, then spin up on the first activation of the
/// session (`startup: "first-activate"`).
pub fn focus(cat: &Catalog, space: &Space, opts: &Opts, spin_up: bool) -> Result<Report> {
    let rounds = activate(cat, space, opts)?;
    let mut report = Report {
        space: space.id.clone(),
        rounds,
        ..Default::default()
    };
    if spin_up && space.startup == "first-activate" && apps::has_apps(space) {
        let first = runtime::update(&opts.state_dir, &runtime::session_key(), |rt| {
            rt.opened.insert(space.id.clone())
        })?;
        if first {
            settle(cat, space, opts, Mode::Open, true, &mut report)?;
        }
    }
    Ok(report)
}

/// Spin, then put focus where it belongs.
fn settle(
    cat: &Catalog,
    space: &Space,
    opts: &Opts,
    mode: Mode,
    focused: bool,
    report: &mut Report,
) -> Result<()> {
    let before = live::read_state(opts.main.clone())?;
    spin(space, opts, mode, report)?;
    let reordered = report
        .actions
        .iter()
        .any(|a| matches!(a, Action::MoveColumnToIndex { .. }));
    let spawned = report.apps.iter().any(|a| a.spawn.is_some());
    if focused {
        // Windows moved in with focus off: make sure every display shows
        // the space; after a spin-up focus lands on main's first app.
        let order = cat.active();
        report.rounds.extend(live::run(opts.main.clone(), |st| {
            plan::activate(st, space, &order)
        })?);
        if (spawned || reordered)
            && let Some(w) = first_main(report)
        {
            live::send(&[Action::FocusWindow { id: w }])?;
        }
    } else if reordered && let Some(w) = before.focused_window {
        // Ordering moved focus around: give it back.
        live::send(&[Action::FocusWindow { id: w }])?;
    }
    Ok(())
}

/// `space open`: restore a space (find first, so open windows are
/// gathered, not duplicated). `focus`: activate it too.
pub fn open(cat: &Catalog, space: &Space, opts: &Opts, focus: bool) -> Result<Report> {
    let mut report = Report {
        space: space.id.clone(),
        ..Default::default()
    };
    runtime::update(&opts.state_dir, &runtime::session_key(), |rt| {
        rt.opened.insert(space.id.clone());
    })?;
    let order = cat.active();
    report.rounds = if focus {
        activate(cat, space, opts)?
    } else {
        live::run(opts.main.clone(), |st| plan::ensure_only(st, space, &order))?
    };
    settle(cat, space, opts, Mode::Open, focus, &mut report)?;
    Ok(report)
}

/// `space gather`: pull matching windows back into the space.
pub fn gather(cat: &Catalog, space: &Space, opts: &Opts) -> Result<Report> {
    let mut report = Report {
        space: space.id.clone(),
        ..Default::default()
    };
    let order = cat.active();
    report.rounds = live::run(opts.main.clone(), |st| plan::ensure_only(st, space, &order))?;
    settle(cat, space, opts, Mode::Gather, false, &mut report)?;
    Ok(report)
}

/// The windows `close` closes: claimed by the space, or in one of its
/// apps' scopes (never a window that only matches a regex).
pub fn close_targets(space: &Space, wins: &[Win], rt: &Runtime, prefix: &str) -> Vec<u64> {
    let units: Vec<String> = space
        .displays
        .values()
        .filter_map(|b| match b {
            Binding::Bound(b) => Some(b.apps.iter()),
            Binding::Keep => None,
        })
        .flatten()
        .filter_map(|a| a.get("id").and_then(serde_json::Value::as_str))
        .map(|app| apps::unit_name(prefix, &space.id, app))
        .collect();
    let mut out: Vec<u64> = wins
        .iter()
        .filter(|w| {
            rt.claims.get(&w.id).is_some_and(|c| c.space == space.id)
                || units.iter().any(|u| w.in_unit(u))
        })
        .map(|w| w.id)
        .collect();
    out.sort_unstable();
    out
}

/// `space close`.
pub fn close(space: &Space, opts: &Opts) -> Result<Report> {
    let session = runtime::session_key();
    let mut report = Report {
        space: space.id.clone(),
        ..Default::default()
    };
    let wins = windows(opts, false)?;
    let alive: BTreeSet<u64> = wins.iter().map(|w| w.id).collect();
    let rt = runtime::update(&opts.state_dir, &session, |rt| {
        rt.prune(&alive);
        rt.clone()
    })?;
    let st = live::read_state(opts.main.clone())?;
    let mut actions: Vec<Action> = close_targets(space, &wins, &rt, &opts.prefix)
        .into_iter()
        .map(|id| Action::CloseWindow { id: Some(id) })
        .collect();
    if space.template.is_some() {
        for (_, b) in space.workspaces() {
            let exists = st.workspaces.iter().any(|w| {
                w.name
                    .as_deref()
                    .is_some_and(|n| n.eq_ignore_ascii_case(&b.workspace))
            });
            if exists {
                actions.push(Action::UnsetWorkspaceName {
                    reference: Some(WorkspaceReferenceArg::Name(b.workspace.clone())),
                });
            }
        }
    }
    live::send(&actions)?;
    report.actions = actions;
    runtime::update(&opts.state_dir, &session, |rt| rt.forget(&space.id))?;
    Ok(report)
}

/// `space apps`: which window is which app right now; changes nothing.
pub fn inspect(space: &Space, opts: &Opts) -> Result<Report> {
    let st = live::read_state(opts.main.clone())?;
    let res = roles::resolve(space, &st.displays, st.main.as_deref());
    let (specs, notes) = apps::specs(space, &res, &opts.prefix, &opts.home);
    let wins = windows(opts, false)?;
    let mut rt = runtime::load(&opts.state_dir);
    rt.enter(&runtime::session_key());
    let found = apps::find(
        &specs,
        &wins,
        &all_claims(&rt),
        &ws_names(&st),
        &opts.prefix,
    );
    Ok(Report {
        space: space.id.clone(),
        apps: specs
            .iter()
            .zip(&found)
            .map(|(s, f)| AppReport {
                app: s.app.clone(),
                role: s.role.clone(),
                workspace: s.workspace.clone(),
                window: f.as_ref().map(|f| f.window),
                how: f.as_ref().map(|f| f.how),
                spawn: None,
            })
            .collect(),
        notes,
        ..Default::default()
    })
}

/// `space startup`: open the spaces whose `startup` is `login`, without
/// switching to them.
pub fn startup(cat: &Catalog, opts: &Opts) -> Result<Vec<Report>> {
    cat.active()
        .into_iter()
        .filter(|s| s.startup == "login" && apps::has_apps(s))
        .map(|s| open(cat, s, opts, false))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spaces::model::tests::catalog;
    use crate::spaces::runtime::Claim;

    #[test]
    fn close_takes_claims_and_scopes_only() {
        let cat = catalog();
        let loft = cat.find("proj-loft").unwrap();
        let mut rt = Runtime::default();
        let claim = |space: &str| Claim {
            space: space.into(),
            app: "editor".into(),
        };
        rt.claims.insert(1, claim("proj-loft"));
        rt.claims.insert(2, claim("proj-inferno"));
        let w = |id: u64, cg: Option<&str>| Win {
            id,
            app_id: Some("dev.zed.Zed".into()),
            title: Some("loft".into()),
            cgroup: cg.map(String::from),
            ..Default::default()
        };
        let wins = vec![
            w(1, None),
            w(2, None),
            w(3, Some("/a/loft-space-proj-loft-debug.scope")),
            w(4, Some("/a/loft-space-proj-inferno-debug.scope")),
            // Matches the editor regex, but nobody claimed it: not closed.
            w(5, None),
        ];
        assert_eq!(close_targets(loft, &wins, &rt, "loft-space"), [1, 3]);
    }
}
