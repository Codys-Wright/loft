//! Spin-up and restore as pure functions (SPACES.md §4): a space on a live
//! layout → the apps it wants where; live windows + claims → which window
//! is which app; then the actions that place and order them.
//!
//! **Matching**, strongest first, per app in plan order:
//! 1. the window this instance/app already **claimed** (runtime.json);
//! 2. a window whose process sits in the app's **scope**
//!    (`systemd-run --user --scope --unit <prefix>-<space>-<app>`: the
//!    cgroup tags every descendant, through wrappers and forks);
//! 3. `match`: the `appId` and `title` regexes and the `cwd` prefix (the
//!    window's pid → `/proc/<pid>/cwd`), all that are given.
//!
//! A window claimed by another space or app, or sitting in another app's
//! scope, is never matched by 3, so two Project instances don't steal each
//! other's windows. Among several candidates: one already on the app's
//! workspace first, then the oldest (lowest id).
//!
//! **Placement**: `MoveWindowToWorkspace { focus: false }` when the window
//! is elsewhere; for a window claimed just now (spun up or gathered for the
//! first time) also its width / maximized / fullscreen / floating. A window
//! the space already had keeps whatever you did to it.
//!
//! **Order**: when a workspace got new windows (spun up, newly claimed, or
//! moved in: gathered back, folded in) and its declared apps aren't left
//! to right in declared order, `FocusWindow` + `MoveColumnToIndex` for
//! each. Columns you rearranged without anything moving in stay put.
//!
//! **Folds** (§3.3): a `stack`ed role's apps go to its workspace (on
//! main's display); a `columns` role's apps join main's workspace: left /
//! top roles before main's apps, the others after; `skip` leaves them out.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use niri_ipc::{Action, SizeChange, WorkspaceReferenceArg};
use regex::Regex;
use serde::Serialize;
use serde_json::Value;

use super::model::{Binding, Fold, Space};
use super::plan::State;
use super::roles::Resolution;

/// The systemd unit prefix of spun-up apps (`loft-space`); a test session
/// uses its own (`$LOFT_SPACES_UNIT_PREFIX`).
pub const UNIT_PREFIX: &str = "loft-space";

/// A folded-in column's width when its app declares none (`columns` fold).
pub const FOLD_WIDTH: f64 = 0.5;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Open {
    #[default]
    Normal,
    Maximized,
    Fullscreen,
    Floating,
}

#[derive(Debug, Clone, Default)]
pub struct Matcher {
    pub app_id: Option<Regex>,
    pub title: Option<Regex>,
    pub cwd: Option<PathBuf>,
}

impl Matcher {
    pub fn is_empty(&self) -> bool {
        self.app_id.is_none() && self.title.is_none() && self.cwd.is_none()
    }

    pub fn matches(&self, w: &Win) -> bool {
        if self.is_empty() {
            return false;
        }
        let re = |re: &Option<Regex>, s: &Option<String>| match re {
            None => true,
            Some(re) => s.as_deref().is_some_and(|s| re.is_match(s)),
        };
        re(&self.app_id, &w.app_id)
            && re(&self.title, &w.title)
            && self
                .cwd
                .as_ref()
                .is_none_or(|want| w.cwd.as_ref().is_some_and(|c| c.starts_with(want)))
    }
}

/// One app of a space, resolved on the current layout.
#[derive(Debug, Clone, Serialize)]
pub struct AppSpec {
    pub space: String,
    pub app: String,
    /// The role it's declared on.
    pub role: String,
    /// The workspace it goes to now (main's for a `columns` fold).
    pub workspace: String,
    /// Position among the workspace's apps, 0-based.
    pub column: usize,
    pub exec: Vec<String>,
    /// Where it's spawned (`~` expanded).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub launch: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    pub open: Open,
    #[serde(skip)]
    pub matcher: Matcher,
    pub unit: String,
    /// Spawned without a scope (no systemd user manager): the child's pid;
    /// windows of its descendants are this app's, like a scope's.
    #[serde(skip)]
    pub pid: Option<i32>,
    /// Folded into main's workspace as a column (`fold: "columns"`).
    pub folded: bool,
}

/// `~` / `~/…` → `$HOME/…`.
pub fn expand_home(s: &str, home: &str) -> String {
    if s == "~" {
        home.to_string()
    } else if let Some(rest) = s.strip_prefix("~/") {
        format!("{}/{rest}", home.trim_end_matches('/'))
    } else {
        s.to_string()
    }
}

/// A systemd unit name for an app: unit-name-safe, `.scope`.
pub fn unit_name(prefix: &str, space: &str, app: &str) -> String {
    let clean = |s: &str| -> String {
        s.chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                    c
                } else {
                    '_'
                }
            })
            .collect()
    };
    format!("{}-{}-{}.scope", clean(prefix), clean(space), clean(app))
}

fn matcher(m: Option<&Value>, home: &str) -> Result<Matcher, String> {
    let Some(Value::Object(m)) = m else {
        return Ok(Matcher::default());
    };
    let re = |k: &str| -> Result<Option<Regex>, String> {
        match m.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()) {
            None => Ok(None),
            Some(s) => Regex::new(s)
                .map(Some)
                .map_err(|e| format!("match.{k} `{s}`: {e}")),
        }
    };
    Ok(Matcher {
        app_id: re("appId")?,
        title: re("title")?,
        cwd: m
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(|s| PathBuf::from(expand_home(s, home))),
    })
}

/// Roles that fold *before* main's apps as columns.
fn folds_before(role: &str) -> bool {
    role.starts_with("left") || role.starts_with("top")
}

/// The space's apps on this layout, in plan order (main's workspace first,
/// then the others; columns in declared order), plus notes on what was
/// left out.
pub fn specs(
    space: &Space,
    res: &Resolution,
    prefix: &str,
    home: &str,
) -> (Vec<AppSpec>, Vec<String>) {
    let mut notes = Vec::new();
    let main_ws = space.main_workspace().map(String::from);
    // workspace → [(sort key, role, app json)]
    type Column = ((i32, usize), String, Value, bool);
    let mut lists: Vec<(String, Vec<Column>)> = Vec::new();
    let mut push = |ws: &str, key: (i32, usize), role: &str, app: &Value, folded: bool| {
        let i = match lists.iter().position(|(w, _)| w == ws) {
            Some(i) => i,
            None => {
                lists.push((ws.to_string(), Vec::new()));
                lists.len() - 1
            }
        };
        lists[i]
            .1
            .push((key, role.to_string(), app.clone(), folded));
    };
    for (role, b) in space.workspaces() {
        if b.apps.is_empty() {
            continue;
        }
        let placed = res
            .placements
            .iter()
            .any(|p| p.role.as_deref() == Some(role) && p.workspace.is_some());
        let fold = res.folded.iter().find(|f| f.role == role).map(|f| f.fold);
        let (ws, group) = match (placed, fold) {
            (true, _) | (false, Some(Fold::Stack)) => (b.workspace.clone(), 1),
            (false, Some(Fold::Columns)) => match &main_ws {
                Some(m) if role != "main" => (m.clone(), if folds_before(role) { 0 } else { 2 }),
                _ => {
                    notes.push(format!(
                        "{role}: folded into columns, but no main workspace"
                    ));
                    continue;
                }
            },
            (false, Some(Fold::Skip)) => {
                notes.push(format!("{role}: no display, skipped (fold: skip)"));
                continue;
            }
            (false, None) => {
                notes.push(format!("{role}: no display takes it"));
                continue;
            }
        };
        // Columns from several folded roles: in role order, by side.
        let rank = space
            .workspaces()
            .iter()
            .position(|(r, _)| *r == role)
            .unwrap_or(0);
        for (i, app) in b.apps.iter().enumerate() {
            let group = if role == "main" { 1 } else { group };
            push(&ws, (group, rank * 1000 + i), role, app, group != 1);
        }
    }
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    // main's workspace first.
    lists.sort_by_key(|(w, _)| Some(w) != main_ws.as_ref());
    for (ws, mut apps) in lists {
        apps.sort_by_key(|(k, ..)| *k);
        for (column, (_, role, a, folded)) in apps.into_iter().enumerate() {
            let id = a["id"].as_str().unwrap_or_default().to_string();
            if !seen.insert(id.clone()) {
                notes.push(format!(
                    "app `{id}` is declared twice; the second is ignored"
                ));
                continue;
            }
            let m = match matcher(a.get("match"), home) {
                Ok(m) => m,
                Err(e) => {
                    notes.push(format!("app `{id}`: {e}"));
                    continue;
                }
            };
            let cwd = a
                .get("cwd")
                .or_else(|| space.doc.get("cwd"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(|s| expand_home(s, home));
            let exec: Vec<String> = a
                .get("exec")
                .and_then(Value::as_array)
                .map(|v| {
                    v.iter()
                        .filter_map(Value::as_str)
                        .map(|s| expand_home(s, home))
                        .collect()
                })
                .unwrap_or_default();
            let open = match a.get("open").and_then(Value::as_str) {
                Some("maximized") => Open::Maximized,
                Some("fullscreen") => Open::Fullscreen,
                Some("floating") => Open::Floating,
                _ => Open::Normal,
            };
            out.push(AppSpec {
                unit: unit_name(prefix, &space.id, &id),
                space: space.id.clone(),
                role,
                workspace: ws.clone(),
                column,
                launch: a.get("launch").is_none_or(super::expr::truthy) && !exec.is_empty(),
                exec,
                cwd,
                width: a.get("width").and_then(Value::as_f64),
                open,
                matcher: m,
                pid: None,
                folded,
                app: id,
            });
        }
    }
    (out, notes)
}

/// A live window, with what `/proc` says about its process.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Win {
    pub id: u64,
    pub app_id: Option<String>,
    pub title: Option<String>,
    pub pid: Option<i32>,
    pub workspace_id: Option<u64>,
    pub floating: bool,
    /// Column in the scrolling layout, 1-based.
    pub column: Option<usize>,
    pub size: (i32, i32),
    /// The process's cgroup path (`/user.slice/…/app.slice/x.scope`).
    pub cgroup: Option<String>,
    pub cwd: Option<PathBuf>,
    /// The pid and its ancestors (only read when an app was spawned
    /// without a scope).
    pub lineage: Vec<i32>,
}

impl Win {
    pub fn from_niri(w: &niri_ipc::Window) -> Self {
        Win {
            id: w.id,
            app_id: w.app_id.clone(),
            title: w.title.clone(),
            pid: w.pid,
            workspace_id: w.workspace_id,
            floating: w.is_floating,
            column: w.layout.pos_in_scrolling_layout.map(|p| p.0),
            size: w.layout.window_size,
            cgroup: None,
            cwd: None,
            lineage: Vec::new(),
        }
    }

    /// The app's scope, or (spawned without one) a descendant of its pid.
    pub fn spawned_by(&self, s: &AppSpec) -> bool {
        self.in_unit(&s.unit) || s.pid.is_some_and(|p| self.lineage.contains(&p))
    }

    pub fn in_unit(&self, unit: &str) -> bool {
        self.cgroup
            .as_deref()
            .is_some_and(|c| c.split('/').any(|p| p == unit))
    }

    /// In some spun-up app's scope (any space's).
    pub fn in_space_scope(&self, prefix: &str) -> bool {
        let pre = format!("{prefix}-");
        self.cgroup.as_deref().is_some_and(|c| {
            c.split('/')
                .any(|p| p.starts_with(&pre) && p.ends_with(".scope"))
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum How {
    Claimed,
    Scope,
    Match,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Found {
    pub window: u64,
    pub how: How,
}

/// Which window is which app (parallel to `specs`). `claims`: window →
/// (space, app) for every space; `ws_names`: workspace id → name.
pub fn find(
    specs: &[AppSpec],
    wins: &[Win],
    claims: &BTreeMap<u64, (String, String)>,
    ws_names: &BTreeMap<u64, String>,
    prefix: &str,
) -> Vec<Option<Found>> {
    let mut used: BTreeSet<u64> = BTreeSet::new();
    let mut out: Vec<Option<Found>> = vec![None; specs.len()];
    let mut sorted: Vec<&Win> = wins.iter().collect();
    sorted.sort_by_key(|w| w.id);
    let owner = |w: &Win| claims.get(&w.id);
    // 1. claims, 2. scopes: for every app before any regex.
    for (i, s) in specs.iter().enumerate() {
        let mine = sorted.iter().find(|w| {
            owner(w).is_some_and(|(sp, app)| *sp == s.space && *app == s.app)
                && !used.contains(&w.id)
        });
        if let Some(w) = mine {
            used.insert(w.id);
            out[i] = Some(Found {
                window: w.id,
                how: How::Claimed,
            });
        }
    }
    for (i, s) in specs.iter().enumerate() {
        if out[i].is_some() {
            continue;
        }
        let w = sorted.iter().find(|w| {
            w.spawned_by(s)
                && !used.contains(&w.id)
                && owner(w).is_none_or(|(sp, app)| *sp == s.space && *app == s.app)
        });
        if let Some(w) = w {
            used.insert(w.id);
            out[i] = Some(Found {
                window: w.id,
                how: How::Scope,
            });
        }
    }
    // 3. match: free windows only.
    for (i, s) in specs.iter().enumerate() {
        if out[i].is_some() {
            continue;
        }
        let on_ws = |w: &Win| {
            w.workspace_id
                .and_then(|id| ws_names.get(&id))
                .is_some_and(|n| n.eq_ignore_ascii_case(&s.workspace))
        };
        let mut cands: Vec<&&Win> = sorted
            .iter()
            .filter(|w| {
                !used.contains(&w.id)
                    && owner(w).is_none()
                    && !w.in_space_scope(prefix)
                    && s.matcher.matches(w)
            })
            .collect();
        cands.sort_by_key(|w| (!on_ws(w), w.id));
        if let Some(w) = cands.first() {
            used.insert(w.id);
            out[i] = Some(Found {
                window: w.id,
                how: How::Match,
            });
        }
    }
    out
}

fn ws_id(st: &State, name: &str) -> Option<u64> {
    st.workspaces
        .iter()
        .find(|w| {
            w.name
                .as_deref()
                .is_some_and(|n| n.eq_ignore_ascii_case(name))
        })
        .map(|w| w.id)
}

/// Move found windows to their workspaces; size the `fresh` ones (claimed
/// in this run).
pub fn place(
    st: &State,
    specs: &[AppSpec],
    found: &[Option<Found>],
    wins: &[Win],
    fresh: &BTreeSet<u64>,
) -> (Vec<Action>, Vec<String>) {
    let mut actions = Vec::new();
    let mut notes = Vec::new();
    for (s, f) in specs.iter().zip(found) {
        let Some(f) = f else { continue };
        let Some(w) = wins.iter().find(|w| w.id == f.window) else {
            continue;
        };
        let Some(target) = ws_id(st, &s.workspace) else {
            notes.push(format!(
                "`{}`: workspace `{}` doesn't exist",
                s.app, s.workspace
            ));
            continue;
        };
        if w.workspace_id != Some(target) {
            actions.push(Action::MoveWindowToWorkspace {
                window_id: Some(w.id),
                reference: WorkspaceReferenceArg::Name(s.workspace.clone()),
                focus: false,
            });
        }
        // Sized when claimed just now, or when it had to move (its declared
        // size on its own workspace, a column's in a fold); a window that
        // stayed put keeps whatever you did to it.
        let moved = w.workspace_id != Some(target);
        let is_fresh = fresh.contains(&w.id);
        if !is_fresh && !moved {
            continue;
        }
        let id = Some(w.id);
        let proportion = |p: f64| Action::SetWindowWidth {
            id,
            change: SizeChange::SetProportion((p * 10000.0).round() / 100.0),
        };
        if s.folded {
            // A column among main's: never maximized or fullscreen there.
            if !w.floating {
                actions.push(proportion(s.width.unwrap_or(FOLD_WIDTH)));
            }
            continue;
        }
        match s.open {
            // Toggles: only for windows claimed just now.
            Open::Floating if is_fresh && !w.floating => {
                actions.push(Action::MoveWindowToFloating { id })
            }
            Open::Fullscreen if is_fresh => {
                // A toggle: only when it isn't already (a window rule may
                // have opened it fullscreen).
                let output = st
                    .workspaces
                    .iter()
                    .find(|x| x.id == target)
                    .and_then(|x| x.output.as_deref());
                let full = st
                    .displays
                    .iter()
                    .find(|d| Some(d.name.as_str()) == output)
                    .is_some_and(|d| w.size == (d.width, d.height));
                if !full {
                    actions.push(Action::FullscreenWindow { id });
                }
            }
            // niri's maximize-column is a toggle too; a full-width column
            // is the same thing, set idempotently.
            Open::Maximized if !w.floating => actions.push(proportion(1.0)),
            Open::Normal if !w.floating => {
                if let Some(p) = s.width {
                    actions.push(proportion(p));
                }
            }
            _ => {}
        }
    }
    (actions, notes)
}

/// Column order at spin-up, against the windows *after* placement: for
/// each workspace that got a fresh window, when its declared apps aren't
/// left to right in declared order, focus each and move its column to
/// its index. Returns the actions and the window to focus last (the first
/// app of main's workspace), when anything was reordered.
pub fn order(
    specs: &[AppSpec],
    found: &[Option<Found>],
    wins: &[Win],
    fresh: &BTreeSet<u64>,
) -> (Vec<Action>, Option<u64>) {
    let mut actions = Vec::new();
    let mut by_ws: Vec<(&str, Vec<(usize, &Win)>)> = Vec::new();
    for (s, f) in specs.iter().zip(found) {
        let Some(w) = f
            .as_ref()
            .and_then(|f| wins.iter().find(|w| w.id == f.window))
        else {
            continue;
        };
        if w.floating {
            continue;
        }
        match by_ws.iter_mut().find(|(ws, _)| *ws == s.workspace) {
            Some((_, v)) => v.push((s.column, w)),
            None => by_ws.push((&s.workspace, vec![(s.column, w)])),
        }
    }
    for (_, mut list) in by_ws {
        if !list.iter().any(|(_, w)| fresh.contains(&w.id)) {
            continue;
        }
        list.sort_by_key(|(c, _)| *c);
        let cols: Vec<Option<usize>> = list.iter().map(|(_, w)| w.column).collect();
        let in_order = cols.iter().all(Option::is_some) && cols.windows(2).all(|p| p[0] < p[1]);
        if in_order {
            continue;
        }
        for (idx, (_, w)) in list.iter().enumerate() {
            actions.push(Action::FocusWindow { id: w.id });
            actions.push(Action::MoveColumnToIndex { index: idx + 1 });
        }
    }
    // Focus ends on main's first app whenever anything moved.
    let last = if actions.is_empty() {
        None
    } else {
        specs
            .iter()
            .zip(found)
            .filter(|(_, f)| f.is_some())
            .min_by_key(|(s, _)| {
                (
                    s.role != "main",
                    s.workspace != specs[0].workspace,
                    s.column,
                )
            })
            .and_then(|(_, f)| f.as_ref().map(|f| f.window))
    };
    if let Some(id) = last {
        actions.push(Action::FocusWindow { id });
    }
    (actions, last)
}

/// What `/proc` says about a pid: its cgroup path and working directory.
pub fn proc_info(proc_root: &Path, pid: i32) -> (Option<String>, Option<PathBuf>) {
    let base = proc_root.join(pid.to_string());
    let cgroup = std::fs::read_to_string(base.join("cgroup"))
        .ok()
        .and_then(|t| {
            // cgroup v2: "0::/path"; v1 hybrids: prefer the unified line.
            t.lines()
                .find_map(|l| l.strip_prefix("0::").map(String::from))
                .or_else(|| {
                    t.lines()
                        .find(|l| l.contains(":name=systemd:"))
                        .and_then(|l| l.rsplit(':').next().map(String::from))
                })
        });
    let cwd = std::fs::read_link(base.join("cwd")).ok();
    (cgroup, cwd)
}

/// A pid and its ancestors, nearest first (at most 32).
pub fn lineage(proc_root: &Path, pid: i32) -> Vec<i32> {
    let mut out = vec![pid];
    let mut cur = pid;
    while out.len() < 32 {
        let Ok(stat) = std::fs::read_to_string(proc_root.join(cur.to_string()).join("stat")) else {
            break;
        };
        // "pid (comm) state ppid …": comm may contain spaces and parens.
        let Some(ppid) = stat
            .rsplit_once(')')
            .and_then(|(_, rest)| rest.split_whitespace().nth(1))
            .and_then(|p| p.parse::<i32>().ok())
        else {
            break;
        };
        if ppid <= 1 {
            break;
        }
        out.push(ppid);
        cur = ppid;
    }
    out
}

/// Whether `space` binds anything to launch or gather at all.
pub fn has_apps(space: &Space) -> bool {
    space.displays.values().any(|b| match b {
        Binding::Bound(b) => !b.apps.is_empty(),
        Binding::Keep => false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spaces::model::tests::{catalog, env};
    use crate::spaces::roles::{self, Display, tests::desk};
    use serde_json::json;

    fn laptop() -> Vec<Display> {
        vec![Display {
            name: "eDP-1".into(),
            identity: "BOE".into(),
            x: 0,
            y: 0,
            width: 1920,
            height: 1200,
        }]
    }

    fn win(id: u64, app_id: &str, title: &str, ws: u64) -> Win {
        Win {
            id,
            app_id: Some(app_id.into()),
            title: Some(title.into()),
            pid: Some(1000 + id as i32),
            workspace_id: Some(ws),
            column: Some(1),
            size: (800, 600),
            ..Default::default()
        }
    }

    fn summary(specs: &[AppSpec]) -> Vec<String> {
        specs
            .iter()
            .map(|s| format!("{}:{}@{}#{}", s.role, s.app, s.workspace, s.column))
            .collect()
    }

    #[test]
    fn specs_follow_the_layout() {
        let cat = catalog();
        let loft = cat.find("proj-loft").unwrap();
        let res = roles::resolve(loft, &desk(), None);
        let (specs, notes) = specs(loft, &res, UNIT_PREFIX, &env().home);
        assert!(notes.is_empty(), "{notes:?}");
        assert_eq!(
            summary(&specs),
            [
                "main:editor@loft#0",
                "main:debug@loft#1",
                "left:docs@loft/left#0",
                "right:preview@loft/right#0",
            ]
        );
        let ed = &specs[0];
        // `~` is expanded for exec and cwd; the space's cwd is the default.
        assert_eq!(ed.exec, ["zeditor", "/home/u/Development/loft"]);
        assert_eq!(ed.cwd.as_deref(), Some("/home/u/Development/loft"));
        assert_eq!(ed.unit, "loft-space-proj-loft-editor.scope");
        assert_eq!(ed.width, Some(0.67));
        assert_eq!(specs[2].open, Open::Maximized);
        // Chromium: one profile per instance *and* app (the docs window
        // must not hand off to the preview's browser process).
        assert!(
            specs[2]
                .exec
                .contains(&"--user-data-dir=/state/browser/proj-loft/docs".to_string())
        );
        // A native preview window is only gathered.
        let inf = cat.find("proj-inferno").unwrap();
        let res = roles::resolve(inf, &desk(), None);
        let (specs, _) = super::specs(inf, &res, UNIT_PREFIX, "/home/u");
        let app = specs.iter().find(|s| s.app == "preview-app").unwrap();
        assert!(!app.launch);
        assert_eq!(
            app.matcher.app_id.as_ref().unwrap().as_str(),
            "^inferno-gui$"
        );
    }

    #[test]
    fn folds_on_a_laptop() {
        let cat = catalog();
        let mut loft = cat.find("proj-loft").unwrap().clone();
        let res = |s: &Space| roles::resolve(s, &laptop(), None);
        // stack (default): each role's apps on its own workspace, stacked on main's display.
        let (s, _) = specs(&loft, &res(&loft), UNIT_PREFIX, "/h");
        assert_eq!(
            summary(&s),
            [
                "main:editor@loft#0",
                "main:debug@loft#1",
                "left:docs@loft/left#0",
                "right:preview@loft/right#0",
            ]
        );
        // columns: left before main's apps, right after, all on main's workspace.
        loft.fold = Fold::Columns;
        let (s, notes) = specs(&loft, &res(&loft), UNIT_PREFIX, "/h");
        assert!(notes.is_empty());
        assert_eq!(
            summary(&s),
            [
                "left:docs@loft#0",
                "main:editor@loft#1",
                "main:debug@loft#2",
                "right:preview@loft#3",
            ]
        );
        // skip: only main's.
        loft.fold = Fold::Skip;
        let (s, notes) = specs(&loft, &res(&loft), UNIT_PREFIX, "/h");
        assert_eq!(summary(&s), ["main:editor@loft#0", "main:debug@loft#1"]);
        assert_eq!(notes.len(), 2);
    }

    fn loft_specs() -> Vec<AppSpec> {
        let cat = catalog();
        let loft = cat.find("proj-loft").unwrap();
        specs(
            loft,
            &roles::resolve(loft, &desk(), None),
            UNIT_PREFIX,
            "/home/u",
        )
        .0
    }

    #[test]
    fn matching_prefers_claims_then_scopes_then_regexes() {
        let specs = loft_specs();
        let names = BTreeMap::from([(1, "loft".to_string()), (2, "main".to_string())]);
        let mut docs = win(5, "chromium", "Quickshell docs", 2);
        docs.cgroup = Some("/user.slice/app.slice/loft-space-proj-loft-docs.scope".into());
        let mut debug_by_class = win(6, "loft.proj-loft.debug", "zsh", 2);
        // A Zed window in another space's scope is not ours, even though it matches.
        let mut foreign_zed = win(3, "dev.zed.Zed", "loft — main.rs", 1);
        foreign_zed.cgroup = Some("/user.slice/app.slice/loft-space-proj-x-editor.scope".into());
        let zed_elsewhere = win(4, "dev.zed.Zed", "loft — README.md", 2);
        let zed_here = win(7, "dev.zed.Zed", "loft — lib.rs", 1);
        let other_zed = win(8, "dev.zed.Zed", "inferno — lib.rs", 1);
        debug_by_class.column = Some(2);
        let wins = vec![
            docs,
            debug_by_class,
            foreign_zed,
            zed_elsewhere,
            zed_here,
            other_zed,
        ];
        let f = find(&specs, &wins, &BTreeMap::new(), &names, UNIT_PREFIX);
        let got: Vec<_> = f
            .iter()
            .map(|f| f.as_ref().map(|f| (f.window, f.how)))
            .collect();
        assert_eq!(
            got,
            [
                // On the workspace already beats older.
                Some((7, How::Match)),
                Some((6, How::Match)),
                // The scope wins although the app-id doesn't match.
                Some((5, How::Scope)),
                None,
            ]
        );
        // A claim sticks even when the title no longer matches.
        let mut wins2 = wins.clone();
        wins2[3].title = Some("Untitled".into());
        let claims = BTreeMap::from([(4, ("proj-loft".to_string(), "editor".to_string()))]);
        let f = find(&specs, &wins2, &claims, &names, UNIT_PREFIX);
        assert_eq!(
            f[0],
            Some(Found {
                window: 4,
                how: How::Claimed
            })
        );
    }

    #[test]
    fn two_project_instances_never_share_a_window() {
        let cat = catalog();
        // Two instances of one template whose folders have one basename:
        // the editor title regex matches both projects' windows.
        let t = &cat.templates["project"];
        let inst = |name: &str, dir: &str| {
            crate::spaces::model::instantiate(
                t,
                Some(&json!({ "kind": "space-instance", "template": "project",
                              "params": { "name": name, "dir": dir } })),
                &env(),
            )
            .unwrap()
        };
        let a = inst("A", "/w/a/loft");
        let b = inst("B", "/w/b/loft");
        let spec_of =
            |s: &Space| specs(s, &roles::resolve(s, &desk(), None), UNIT_PREFIX, "/home/u").0;
        let (sa, sb) = (spec_of(&a), spec_of(&b));
        let names = BTreeMap::from([(1, "a".to_string()), (2, "b".to_string())]);
        let wins = vec![
            win(10, "dev.zed.Zed", "loft — a.rs", 1),
            win(11, "dev.zed.Zed", "loft — b.rs", 2),
        ];
        // A gathers first: it takes the window on its own workspace.
        let fa = find(&sa, &wins, &BTreeMap::new(), &names, UNIT_PREFIX);
        assert_eq!(fa[0].as_ref().unwrap().window, 10);
        let mut claims = BTreeMap::new();
        for (s, f) in sa.iter().zip(&fa) {
            if let Some(f) = f {
                claims.insert(f.window, (s.space.clone(), s.app.clone()));
            }
        }
        // B can't take A's claimed window, and gets the other.
        let fb = find(&sb, &wins, &claims, &names, UNIT_PREFIX);
        assert_eq!(fb[0].as_ref().unwrap().window, 11);
        // With only A's window open, B finds nothing (and would spawn).
        let fb = find(&sb, &wins[..1], &claims, &names, UNIT_PREFIX);
        assert!(fb[0].is_none());
        // `cwd` tells them apart without claims: a match with a cwd prefix.
        let mut sb2 = sb.clone();
        sb2[0].matcher.cwd = Some("/w/b/loft".into());
        let mut w = wins.clone();
        w[0].cwd = Some("/w/a/loft".into());
        w[1].cwd = Some("/w/b/loft/src".into());
        let names_flat = BTreeMap::new();
        let fb = find(&sb2, &w, &BTreeMap::new(), &names_flat, UNIT_PREFIX);
        assert_eq!(fb[0].as_ref().unwrap().window, 11);
        // The scopes are per instance: B's debug terminal is never A's.
        let mut t = win(12, "kitty", "zsh", 1);
        t.cgroup = Some("/x/loft-space-proj-b-debug.scope".into());
        let fa = find(&sa, &[t.clone()], &BTreeMap::new(), &names, UNIT_PREFIX);
        assert!(fa.iter().all(Option::is_none));
        let fb = find(&sb, &[t], &BTreeMap::new(), &names, UNIT_PREFIX);
        assert_eq!(
            fb[1],
            Some(Found {
                window: 12,
                how: How::Scope
            })
        );
    }

    fn wsx(id: u64, name: &str, out: &str) -> niri_ipc::Workspace {
        niri_ipc::Workspace {
            id,
            idx: id as u8,
            name: Some(name.into()),
            output: Some(out.into()),
            is_urgent: false,
            is_active: true,
            is_focused: false,
            active_window_id: None,
        }
    }

    fn wire(a: &[Action]) -> Vec<Value> {
        a.iter().map(|a| serde_json::to_value(a).unwrap()).collect()
    }

    #[test]
    fn placement_golden_actions() {
        let specs = loft_specs();
        let st = State {
            displays: desk(),
            workspaces: vec![
                wsx(1, "loft", "DP-4"),
                wsx(2, "loft/left", "DP-5"),
                wsx(3, "loft/right", "DP-3"),
                wsx(4, "main", "DP-4"),
            ],
            ..Default::default()
        };
        // Freshly spawned: everything landed on `main` (the focused workspace).
        let mut wins = vec![
            win(20, "dev.zed.Zed", "loft", 4),
            win(21, "loft.proj-loft.debug", "zsh", 4),
            win(22, "loft.proj-loft.docs", "docs", 4),
            win(23, "loft.proj-loft.preview", "app", 3),
        ];
        let found: Vec<Option<Found>> = wins
            .iter()
            .map(|w| {
                Some(Found {
                    window: w.id,
                    how: How::Scope,
                })
            })
            .collect();
        let fresh: BTreeSet<u64> = [20, 21, 22, 23].into();
        let (a, notes) = place(&st, &specs, &found, &wins, &fresh);
        assert!(notes.is_empty());
        let mv = |id: u64, ws: &str| json!({ "MoveWindowToWorkspace": { "window_id": id, "reference": { "Name": ws }, "focus": false } });
        let width = |id: u64, p: f64| json!({ "SetWindowWidth": { "id": id, "change": { "SetProportion": p } } });
        assert_eq!(
            wire(&a),
            [
                mv(20, "loft"),
                width(20, 67.0),
                mv(21, "loft"),
                width(21, 33.0),
                mv(22, "loft/left"),
                width(22, 100.0),
                // Already on its workspace: only sized.
                width(23, 100.0),
            ]
        );
        // Restoring later (ours already): what had to move comes back at its
        // declared size; what stayed put keeps the size you gave it.
        let (a, _) = place(&st, &specs, &found, &wins, &BTreeSet::new());
        assert_eq!(
            wire(&a),
            [
                mv(20, "loft"),
                width(20, 67.0),
                mv(21, "loft"),
                width(21, 33.0),
                mv(22, "loft/left"),
                width(22, 100.0),
            ]
        );
        let mut home = wins.clone();
        for (w, ws) in home.iter_mut().zip([1, 1, 2, 3]) {
            w.workspace_id = Some(ws);
        }
        assert!(
            place(&st, &specs, &found, &home, &BTreeSet::new())
                .0
                .is_empty()
        );

        // Order after placement: debug ended up left of the editor.
        wins[0].workspace_id = Some(1);
        wins[0].column = Some(2);
        wins[1].workspace_id = Some(1);
        wins[1].column = Some(1);
        let (a, last) = order(&specs, &found, &wins, &fresh);
        let fwin = |id: u64| json!({ "FocusWindow": { "id": id } });
        let col = |i: usize| json!({ "MoveColumnToIndex": { "index": i } });
        assert_eq!(wire(&a), [fwin(20), col(1), fwin(21), col(2), fwin(20)]);
        assert_eq!(last, Some(20));
        // In order already, or nothing fresh: nothing to do.
        wins[0].column = Some(1);
        wins[1].column = Some(3);
        assert!(order(&specs, &found, &wins, &fresh).0.is_empty());
        wins[1].column = Some(1);
        wins[0].column = Some(2);
        assert!(order(&specs, &found, &wins, &BTreeSet::new()).0.is_empty());
    }

    #[test]
    fn fullscreen_and_floating_are_not_toggled_twice() {
        let mut specs = loft_specs();
        specs.truncate(2);
        specs[0].open = Open::Fullscreen;
        specs[1].open = Open::Floating;
        let st = State {
            displays: desk(),
            workspaces: vec![wsx(1, "loft", "DP-4")],
            ..Default::default()
        };
        let main = desk().into_iter().find(|d| d.name == "DP-4").unwrap();
        let mut wins = vec![win(1, "a", "a", 1), win(2, "b", "b", 1)];
        let found = vec![
            Some(Found {
                window: 1,
                how: How::Scope,
            }),
            Some(Found {
                window: 2,
                how: How::Scope,
            }),
        ];
        let fresh: BTreeSet<u64> = [1, 2].into();
        let (a, _) = place(&st, &specs, &found, &wins, &fresh);
        assert_eq!(
            wire(&a),
            [
                json!({ "FullscreenWindow": { "id": 1 } }),
                json!({ "MoveWindowToFloating": { "id": 2 } }),
            ]
        );
        // A window rule already did both.
        wins[0].size = (main.width, main.height);
        wins[1].floating = true;
        assert!(place(&st, &specs, &found, &wins, &fresh).0.is_empty());
    }

    #[test]
    fn columns_fold_moves_the_apps_into_main() {
        let cat = catalog();
        let mut loft = cat.find("proj-loft").unwrap().clone();
        loft.fold = Fold::Columns;
        let res = roles::resolve(&loft, &laptop(), None);
        let (specs, _) = specs(&loft, &res, UNIT_PREFIX, "/h");
        let st = State {
            displays: laptop(),
            workspaces: vec![wsx(1, "loft", "eDP-1"), wsx(2, "loft/left", "eDP-1")],
            ..Default::default()
        };
        // docs sat on its own (stacked) workspace before; now it joins main's.
        let mut wins = vec![
            win(30, "loft.proj-loft.docs", "d", 2),
            win(31, "dev.zed.Zed", "loft", 1),
            win(32, "loft.proj-loft.debug", "t", 1),
            win(33, "loft.proj-loft.preview", "p", 1),
        ];
        let found: Vec<Option<Found>> = [30, 31, 32, 33]
            .iter()
            .map(|&w| {
                Some(Found {
                    window: w,
                    how: How::Scope,
                })
            })
            .collect();
        // Already ours (no fresh claims): it moves, and becomes a column.
        let (a, _) = place(&st, &specs, &found, &wins, &BTreeSet::new());
        assert_eq!(
            wire(&a),
            [
                json!({ "MoveWindowToWorkspace": { "window_id": 30, "reference": { "Name": "loft" }, "focus": false } }),
                // Maximized on its own display, half a column in main's.
                json!({ "SetWindowWidth": { "id": 30, "change": { "SetProportion": 50.0 } } }),
            ]
        );
        // docs lands after the focused column: order puts it first.
        wins[0].workspace_id = Some(1);
        for (w, c) in wins.iter_mut().zip([2, 1, 3, 4]) {
            w.column = Some(c);
        }
        let moved_in: BTreeSet<u64> = [30].into();
        let (a, _) = order(&specs, &found, &wins, &moved_in);
        let ids: Vec<u64> = a
            .iter()
            .filter_map(|a| match a {
                Action::FocusWindow { id } => Some(*id),
                _ => None,
            })
            .collect();
        assert_eq!(ids, [30, 31, 32, 33, 31]);
    }

    #[test]
    fn unit_names_and_proc() {
        assert_eq!(
            unit_name("loft-space", "proj-a", "pre view/x"),
            "loft-space-proj-a-pre_view_x.scope"
        );
        let d = crate::config::tests_support::scratch("spaces-proc");
        std::fs::create_dir_all(d.join("42")).unwrap();
        std::fs::write(
            d.join("42/cgroup"),
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/loft-space-a-b.scope\n",
        )
        .unwrap();
        std::os::unix::fs::symlink("/w/a", d.join("42/cwd")).unwrap();
        let (cg, cwd) = proc_info(&d, 42);
        let w = Win {
            cgroup: cg,
            cwd,
            ..Default::default()
        };
        assert!(w.in_unit("loft-space-a-b.scope"));
        assert!(w.in_space_scope("loft-space"));
        assert!(!w.in_space_scope("loft-dev"));
        assert_eq!(w.cwd.as_deref(), Some(Path::new("/w/a")));
        assert_eq!(proc_info(&d, 7), (None, None));
        // Without scopes: the spawned pid's descendants.
        std::fs::write(d.join("42/stat"), "42 (my (app) x) S 41 42 0\n").unwrap();
        std::fs::create_dir_all(d.join("41")).unwrap();
        std::fs::write(d.join("41/stat"), "41 (sh) S 40 41 0\n").unwrap();
        assert_eq!(lineage(&d, 42), [42, 41, 40]);
        let mut spec = loft_specs().remove(0);
        spec.pid = Some(41);
        let w = Win {
            lineage: lineage(&d, 42),
            ..Default::default()
        };
        assert!(w.spawned_by(&spec));
    }
}
