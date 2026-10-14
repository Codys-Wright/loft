//! Activation as a pure function: niri's state + a space → the IPC actions
//! (SPACES.md §3). `loft-niri space plan` prints them; `space focus`
//! sends them, pipelined on one connection.
//!
//! **Ensure** (§3.2): every workspace of the space must exist on the
//! display its role resolves to (a stacked fold: main's display).
//! - missing → claim the empty unnamed workspace niri keeps last on that
//!   display: `FocusMonitor` + `SetWorkspaceName { Id }`. The focus is a
//!   workaround: niri 26.04 only appends the next empty workspace when the
//!   renamed one is on the *focused* monitor (layout/mod.rs
//!   `set_workspace_name`). The new trailing workspace's id isn't known
//!   until niri says, so a second creation on one display needs a new
//!   round (`Plan::incomplete`).
//! - on another display (a fold that came back, or niri moved it on an
//!   unplug) → `MoveWorkspaceToMonitor`.
//! - created or moved → `MoveWorkspaceToIndex` into space order (only
//!   those: a workspace you reordered by hand stays where you put it).
//!
//! **Activate** (§3.1), measured in P0: niri applies pipelined actions one
//! event-loop turn apart (≈0.1 ms) and an idle display renders right after
//! the first. So the target's workspace is focused first (that first
//! frame already shows the target focused), then the other displays,
//! farthest first, then the target again. Displays already showing their
//! workspace are left alone (no focus hop, no pointer jump).

use std::collections::BTreeMap;

use niri_ipc::{Action, WorkspaceReferenceArg};
use serde::Serialize;

use super::model::{Catalog, Space, Target};
use super::roles::{self, Display, Resolution};

/// What `plan` needs to know about niri.
#[derive(Debug, Clone, Default)]
pub struct State {
    pub displays: Vec<Display>,
    pub workspaces: Vec<niri_ipc::Workspace>,
    pub focused_window: Option<u64>,
    /// Settings → Displays' main display (connector or identity).
    pub main: Option<String>,
}

impl State {
    pub fn focused_output(&self) -> Option<&str> {
        self.workspaces
            .iter()
            .find(|w| w.is_focused)
            .and_then(|w| w.output.as_deref())
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Plan {
    pub space: String,
    /// Run in order, on one connection.
    pub actions: Vec<Action>,
    /// Ensure needs another round with niri's new state (then activate).
    pub incomplete: bool,
    pub notes: Vec<String>,
    /// Where keyboard focus ends (connector).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    pub resolution: Resolution,
}

fn name(ws: &str) -> Option<WorkspaceReferenceArg> {
    Some(WorkspaceReferenceArg::Name(ws.to_string()))
}

/// One workspace in the simulation of niri's layout.
#[derive(Debug, Clone)]
struct SimWs {
    /// Unknown for the empty workspace niri appends after a rename.
    id: Option<u64>,
    name: Option<String>,
    empty: bool,
}

/// niri's workspaces per output, updated as actions are planned.
#[derive(Debug, Clone)]
struct Sim {
    outputs: Vec<(String, Vec<SimWs>, usize)>, // name, workspaces, active idx
    focused: Option<String>,
}

impl Sim {
    fn new(st: &State) -> Self {
        let mut outputs: Vec<(String, Vec<SimWs>, usize)> = st
            .displays
            .iter()
            .map(|d| (d.name.clone(), Vec::new(), 0))
            .collect();
        let mut ws: Vec<&niri_ipc::Workspace> = st.workspaces.iter().collect();
        ws.sort_by_key(|w| w.idx);
        for w in ws {
            let Some(o) = outputs.iter_mut().find(|o| Some(&o.0) == w.output.as_ref()) else {
                continue;
            };
            if w.is_active {
                o.2 = o.1.len();
            }
            o.1.push(SimWs {
                id: Some(w.id),
                name: w.name.clone(),
                empty: w.active_window_id.is_none(),
            });
        }
        Sim {
            outputs,
            focused: st.focused_output().map(String::from),
        }
    }

    fn find(&self, ws: &str) -> Option<(usize, usize)> {
        for (oi, o) in self.outputs.iter().enumerate() {
            if let Some(i) = o.1.iter().position(|w| {
                w.name
                    .as_deref()
                    .is_some_and(|n| n.eq_ignore_ascii_case(ws))
            }) {
                return Some((oi, i));
            }
        }
        None
    }

    fn output(&self, name: &str) -> Option<usize> {
        self.outputs.iter().position(|o| o.0 == name)
    }

    fn is_active(&self, ws: &str) -> bool {
        self.find(ws).is_some_and(|(oi, i)| self.outputs[oi].2 == i)
    }

    /// niri `move_workspace_to_output_by_id`: inserted after the target's
    /// active workspace; the old display falls back to a neighbour.
    fn move_to(&mut self, ws: &str, to: usize) {
        let Some((oi, i)) = self.find(ws) else { return };
        let w = self.outputs[oi].1.remove(i);
        let o = &mut self.outputs[oi];
        if o.2 > i || (o.2 == i && o.2 > 0) {
            o.2 -= 1;
        }
        let t = &mut self.outputs[to];
        let at = (t.2 + 1).min(t.1.len());
        t.1.insert(at, w);
    }

    /// niri `move_workspace_to_idx` (0-based here).
    fn move_to_index(&mut self, ws: &str, idx: usize) {
        let Some((oi, i)) = self.find(ws) else { return };
        let o = &mut self.outputs[oi];
        let active_id = o.1.get(o.2).map(|w| (w.id, w.name.clone()));
        let w = o.1.remove(i);
        let idx = idx.min(o.1.len());
        o.1.insert(idx, w);
        if let Some(a) = active_id {
            o.2 =
                o.1.iter()
                    .position(|w| (w.id, w.name.clone()) == a)
                    .unwrap_or(0);
        }
    }

    fn focus(&mut self, ws: &str) {
        if let Some((oi, i)) = self.find(ws) {
            self.outputs[oi].2 = i;
            self.focused = Some(self.outputs[oi].0.clone());
        }
    }
}

/// The rank of a workspace in space order: (space position, role position).
fn rank(cat_order: &[&Space], ws: &str) -> Option<(usize, usize)> {
    cat_order.iter().enumerate().find_map(|(si, s)| {
        s.workspaces()
            .iter()
            .position(|(_, b)| b.workspace.eq_ignore_ascii_case(ws))
            .map(|ri| (si, ri))
    })
}

/// Where `ws` belongs among the other workspaces of its display (0-based):
/// right after the last workspace of an earlier space (or earlier role of
/// the same space), else before the first later one, else first.
fn order_index(list: &[SimWs], ws: &str, order: &[&Space]) -> Option<usize> {
    let r = rank(order, ws)?;
    let others: Vec<Option<(usize, usize)>> = list
        .iter()
        .filter(|w| {
            !w.name
                .as_deref()
                .is_some_and(|n| n.eq_ignore_ascii_case(ws))
        })
        .map(|w| w.name.as_deref().and_then(|n| rank(order, n)))
        .collect();
    if let Some(last_before) = others.iter().rposition(|o| o.is_some_and(|o| o < r)) {
        return Some(last_before + 1);
    }
    if let Some(first_after) = others.iter().position(|o| o.is_some_and(|o| o > r)) {
        return Some(first_after);
    }
    Some(0)
}

/// Ensure the space's workspaces (see the module docs).
fn ensure(sim: &mut Sim, res: &Resolution, order: &[&Space], plan: &mut Plan) {
    let mut wanted: Vec<(String, String)> = res
        .placements
        .iter()
        .filter_map(|p| Some((p.workspace.clone()?, p.display.name.clone())))
        .collect();
    if let Some(m) = &res.main {
        // Stacked folds live on main's display, below the main workspace.
        wanted.extend(res.stacked().map(|f| (f.workspace.clone(), m.name.clone())));
    }
    for (ws, disp) in wanted {
        let Some(to) = sim.output(&disp) else {
            continue;
        };
        let mut placed = false;
        match sim.find(&ws) {
            Some((oi, _)) if oi == to => {}
            Some(_) => {
                plan.actions.push(Action::MoveWorkspaceToMonitor {
                    output: disp.clone(),
                    reference: name(&ws),
                });
                sim.move_to(&ws, to);
                placed = true;
            }
            None => {
                let last = sim.outputs[to].1.last().cloned();
                match last {
                    Some(SimWs {
                        id: Some(id),
                        name: None,
                        empty: true,
                    }) => {
                        if sim.focused.as_deref() != Some(disp.as_str()) {
                            plan.actions.push(Action::FocusMonitor {
                                output: disp.clone(),
                            });
                            sim.focused = Some(disp.clone());
                        }
                        plan.actions.push(Action::SetWorkspaceName {
                            name: ws.clone(),
                            workspace: Some(WorkspaceReferenceArg::Id(id)),
                        });
                        let o = &mut sim.outputs[to].1;
                        o.last_mut().unwrap().name = Some(ws.clone());
                        o.push(SimWs {
                            id: None,
                            name: None,
                            empty: true,
                        });
                        placed = true;
                    }
                    Some(SimWs { id: None, .. }) => {
                        plan.incomplete = true;
                        plan.notes
                            .push(format!("`{ws}` on {disp}: needs another round"));
                    }
                    _ => plan.notes.push(format!(
                        "`{ws}` on {disp}: no empty workspace to claim (niri keeps one last)"
                    )),
                }
            }
        }
        if placed {
            let list = &sim.outputs[to].1;
            let cur = list.iter().position(|w| {
                w.name
                    .as_deref()
                    .is_some_and(|n| n.eq_ignore_ascii_case(&ws))
            });
            if let (Some(cur), Some(want)) = (cur, order_index(list, &ws, order))
                && cur != want
            {
                plan.actions.push(Action::MoveWorkspaceToIndex {
                    index: want + 1,
                    reference: name(&ws),
                });
                sim.move_to_index(&ws, want);
            }
        }
    }
}

/// Activate a space: ensure, then switch every bound display, focus last
/// on the target (`order`: the catalog's spaces in order, for workspace order).
pub fn activate(st: &State, space: &Space, order: &[&Space]) -> Plan {
    activate_with(st, space, order, &BTreeMap::new())
}

/// [`activate`], also bringing `keep` displays back to what they showed
/// (`restore`: display identity → workspace, from runtime.json's per-space
/// memory). The caller passes it when the space is already active (§3.1:
/// "activating the active space restores `keep` displays switched by hand").
pub fn activate_with(
    st: &State,
    space: &Space,
    order: &[&Space],
    restore: &BTreeMap<String, String>,
) -> Plan {
    let res = roles::resolve(space, &st.displays, st.main.as_deref());
    let mut plan = Plan {
        space: space.id.clone(),
        ..Default::default()
    };
    let mut sim = Sim::new(st);
    let focused_before = sim.focused.clone();
    ensure(&mut sim, &res, order, &mut plan);
    if plan.incomplete {
        plan.resolution = res;
        return plan;
    }
    let placed: Vec<(&Display, &str)> = res
        .placements
        .iter()
        .filter_map(|p| Some((&p.display, p.workspace.as_deref()?)))
        .filter(|(_, ws)| sim.find(ws).is_some())
        .collect();
    let on = |d: &str| placed.iter().find(|(x, _)| x.name == d).copied();
    let target = match space.target {
        Target::Stay => focused_before.as_deref().and_then(on),
        Target::Main => None,
    }
    .or_else(|| res.main.as_ref().and_then(|m| on(&m.name)))
    .or_else(|| focused_before.as_deref().and_then(on))
    .or_else(|| placed.first().copied());
    let Some((tdisp, tws)) = target else {
        plan.notes
            .push("nothing to show: the space binds no connected display".into());
        plan.resolution = res;
        return plan;
    };
    let (tcx, tcy) = tdisp.center();
    let mut others: Vec<(&Display, &str)> = placed
        .iter()
        .filter(|(d, ws)| d.name != tdisp.name && !sim.is_active(ws))
        .copied()
        .collect();
    for p in res.placements.iter().filter(|p| p.workspace.is_none()) {
        let Some(ws) = restore.get(p.display.identity()) else {
            continue;
        };
        let here = sim
            .find(ws)
            .is_some_and(|(oi, _)| sim.outputs[oi].0 == p.display.name);
        if here && !sim.is_active(ws) && p.display.name != tdisp.name {
            others.push((&p.display, ws.as_str()));
        }
    }
    others.sort_by(|a, b| {
        let dist = |d: &Display| {
            let (x, y) = d.center();
            (x - tcx).hypot(y - tcy)
        };
        dist(b.0)
            .total_cmp(&dist(a.0))
            .then(a.0.name.cmp(&b.0.name))
    });
    let focus = |ws: &str| Action::FocusWorkspace {
        reference: WorkspaceReferenceArg::Name(ws.to_string()),
    };
    if !others.is_empty() {
        plan.actions.push(focus(tws));
        for (_, ws) in &others {
            plan.actions.push(focus(ws));
            sim.focus(ws);
        }
    }
    plan.actions.push(focus(tws));
    sim.focus(tws);
    plan.target = Some(tdisp.name.clone());
    plan.resolution = res;
    plan
}

/// What each `keep` display shows now (identity → workspace name): the
/// per-space memory recorded when a space is activated.
pub fn keep_shown(st: &State, space: &Space) -> BTreeMap<String, String> {
    let res = roles::resolve(space, &st.displays, st.main.as_deref());
    res.placements
        .iter()
        .filter(|p| p.workspace.is_none())
        .filter_map(|p| {
            let ws = st
                .workspaces
                .iter()
                .find(|w| w.is_active && w.output.as_deref() == Some(p.display.name.as_str()))?;
            Some((p.display.identity().to_string(), ws.name.clone()?))
        })
        .collect()
}

/// Ensure only (`space ensure`): the workspaces exist where they belong;
/// focus goes back where it was.
pub fn ensure_only(st: &State, space: &Space, order: &[&Space]) -> Plan {
    let res = roles::resolve(space, &st.displays, st.main.as_deref());
    let mut plan = Plan {
        space: space.id.clone(),
        ..Default::default()
    };
    let mut sim = Sim::new(st);
    let before = sim.focused.clone();
    ensure(&mut sim, &res, order, &mut plan);
    restore_focus(&mut plan, &sim, before, st.focused_window);
    plan.resolution = res;
    plan
}

fn restore_focus(plan: &mut Plan, sim: &Sim, before: Option<String>, window: Option<u64>) {
    if sim.focused == before {
        return;
    }
    match (window, before) {
        (Some(id), _) => plan.actions.push(Action::FocusWindow { id }),
        (None, Some(o)) => plan.actions.push(Action::FocusMonitor { output: o }),
        _ => {}
    }
}

/// Mod+Shift+N (§6.2): the focused window to the space's workspace on the
/// same role as its display (else main's), without following it.
pub fn move_window(st: &State, space: &Space, order: &[&Space]) -> Plan {
    let res = roles::resolve(space, &st.displays, st.main.as_deref());
    let mut plan = Plan {
        space: space.id.clone(),
        ..Default::default()
    };
    let Some(window) = st.focused_window else {
        plan.notes.push("no focused window".into());
        plan.resolution = res;
        return plan;
    };
    let mut sim = Sim::new(st);
    let before = sim.focused.clone();
    ensure(&mut sim, &res, order, &mut plan);
    let ws = before
        .as_deref()
        .and_then(|o| res.workspace_on(o))
        .or_else(|| res.main.as_ref().and_then(|m| res.workspace_on(&m.name)))
        .or_else(|| space.main_workspace())
        .map(String::from);
    match ws {
        Some(ws) if !plan.incomplete => {
            plan.actions.push(Action::MoveWindowToWorkspace {
                window_id: Some(window),
                reference: WorkspaceReferenceArg::Name(ws),
                focus: false,
            });
            restore_focus(&mut plan, &sim, before, None);
        }
        Some(_) => {}
        None => plan
            .notes
            .push("the space has no workspace to move to".into()),
    }
    plan.resolution = res;
    plan
}

/// Put every display's space workspaces first, in space order (`space
/// order`, run after `render`): niri inserts workspaces that a config
/// *reload* declares at the top of their display, one after another, so a
/// render on a running niri lists them in reverse. Workspaces no space owns
/// keep their order, after the spaces'.
pub fn order_all(st: &State, order: &[&Space]) -> Plan {
    let mut plan = Plan::default();
    let mut sim = Sim::new(st);
    for oi in 0..sim.outputs.len() {
        let mut owned: Vec<(String, (usize, usize))> = sim.outputs[oi]
            .1
            .iter()
            .filter_map(|w| {
                let n = w.name.clone()?;
                rank(order, &n).map(|r| (n, r))
            })
            .collect();
        owned.sort_by_key(|(_, r)| *r);
        for (i, (ws, _)) in owned.iter().enumerate() {
            let cur = sim.find(ws).map(|(_, p)| p);
            if cur != Some(i) {
                plan.actions.push(Action::MoveWorkspaceToIndex {
                    index: i + 1,
                    reference: name(ws),
                });
                sim.move_to_index(ws, i);
            }
        }
    }
    plan
}

/// The active space: the owner of the workspace main's display shows (when
/// that space puts it there), else the owner of the focused workspace.
pub fn active_space<'a>(st: &State, cat: &'a Catalog) -> Option<&'a Space> {
    let main = roles::main_display(&st.displays, st.main.as_deref())?;
    let shown = |out: &str| {
        st.workspaces
            .iter()
            .find(|w| w.is_active && w.output.as_deref() == Some(out))
            .and_then(|w| w.name.as_deref())
    };
    if let Some(s) = shown(&main.name).and_then(|n| cat.owner(n)) {
        return Some(s);
    }
    st.workspaces
        .iter()
        .find(|w| w.is_focused)
        .and_then(|w| w.name.as_deref())
        .and_then(|n| cat.owner(n))
}

/// The next / previous active space after the current one (wrapping).
pub fn step<'a>(st: &State, cat: &'a Catalog, forward: bool) -> Option<&'a Space> {
    let active = cat.active();
    if active.is_empty() {
        return None;
    }
    let cur = active_space(st, cat).and_then(|s| active.iter().position(|a| a.id == s.id));
    let n = active.len();
    let i = match (cur, forward) {
        (Some(i), true) => (i + 1) % n,
        (Some(i), false) => (i + n - 1) % n,
        (None, true) => 0,
        (None, false) => n - 1,
    };
    Some(active[i])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spaces::model::tests::catalog;
    use crate::spaces::roles::tests::desk;
    use serde_json::{Value, json};

    fn ws(
        id: u64,
        idx: u8,
        name: Option<&str>,
        out: &str,
        active: bool,
        focused: bool,
        win: bool,
    ) -> niri_ipc::Workspace {
        niri_ipc::Workspace {
            id,
            idx,
            name: name.map(String::from),
            output: Some(out.into()),
            is_urgent: false,
            is_active: active,
            is_focused: focused,
            active_window_id: win.then_some(100 + id),
        }
    }

    /// Cody's desk (DP-5 left, DP-4 main, DP-3 right) with Music showing.
    fn music_showing() -> State {
        State {
            displays: desk(),
            workspaces: vec![
                ws(1, 1, Some("main"), "DP-4", false, false, true),
                ws(2, 2, Some("music"), "DP-4", true, true, true),
                ws(3, 3, Some("video"), "DP-4", false, false, false),
                ws(4, 4, None, "DP-4", false, false, false),
                ws(5, 1, Some("comms"), "DP-5", true, false, true),
                ws(6, 2, Some("media"), "DP-5", false, false, false),
                ws(7, 3, None, "DP-5", false, false, false),
                ws(8, 1, Some("music/right"), "DP-3", true, false, true),
                ws(9, 2, Some("recording"), "DP-3", false, false, true),
                ws(10, 3, None, "DP-3", false, false, false),
            ],
            focused_window: Some(102),
            main: None,
        }
    }

    fn wire(p: &Plan) -> Vec<Value> {
        p.actions
            .iter()
            .map(|a| serde_json::to_value(a).unwrap())
            .collect()
    }

    fn fw(n: &str) -> Value {
        json!({ "FocusWorkspace": { "reference": { "Name": n } } })
    }

    #[test]
    fn music_to_video_switches_every_bound_display() {
        let cat = catalog();
        let st = music_showing();
        let p = activate(&st, cat.find("video").unwrap(), &cat.active());
        assert!(!p.incomplete && p.notes.is_empty(), "{:?}", p.notes);
        // Target first and last; others farthest first (right is 2400 px
        // from main's center, left 1965).
        assert_eq!(
            wire(&p),
            [fw("video"), fw("recording"), fw("media"), fw("video")]
        );
        assert_eq!(p.target.as_deref(), Some("DP-4"));
    }

    #[test]
    fn keep_and_already_shown_displays_are_left_alone() {
        let cat = catalog();
        let mut st = music_showing();
        // Gaming: left keep; its right workspace `stream` doesn't exist yet.
        let p = activate(&st, cat.find("gaming").unwrap(), &cat.active());
        assert_eq!(
            wire(&p),
            [
                // gaming is missing too: claim main's trailing empty (focused already)
                json!({ "SetWorkspaceName": { "name": "gaming", "workspace": { "Id": 4 } } }),
                json!({ "FocusMonitor": { "output": "DP-3" } }),
                json!({ "SetWorkspaceName": { "name": "stream", "workspace": { "Id": 10 } } }),
                fw("gaming"),
                fw("stream"),
                fw("gaming"),
            ]
        );
        // Music again while it shows: one refocus of main, nothing else.
        let p = activate(&st, cat.find("music").unwrap(), &cat.active());
        assert_eq!(wire(&p), [fw("music")]);
        // Comms (left + main): left already shows comms.
        st.workspaces[4].is_active = true;
        let p = activate(&st, cat.find("comms").unwrap(), &cat.active());
        assert_eq!(
            wire(&p),
            [
                json!({ "SetWorkspaceName": { "name": "comms/main", "workspace": { "Id": 4 } } }),
                // Comms comes after Video in space order: below `video`.
                fw("comms/main"),
            ]
        );
    }

    #[test]
    fn created_workspaces_move_into_space_order() {
        let cat = catalog();
        let mut st = music_showing();
        // main's trailing empty sits after a hand-made `lab` workspace.
        st.workspaces
            .push(ws(11, 5, Some("lab"), "DP-4", false, false, true));
        st.workspaces[3].idx = 6; // the trailing empty stays last
        let p = activate(&st, cat.find("comms").unwrap(), &cat.active());
        assert_eq!(
            wire(&p)[..2],
            [
                json!({ "SetWorkspaceName": { "name": "comms/main", "workspace": { "Id": 4 } } }),
                // main, music, video, [comms/main], lab
                json!({ "MoveWorkspaceToIndex": { "index": 4, "reference": { "Name": "comms/main" } } }),
            ]
        );
    }

    #[test]
    fn a_workspace_on_the_wrong_display_moves_back() {
        let cat = catalog();
        let mut st = music_showing();
        // An unplug moved music/right to DP-5 (niri's first monitor) and niri
        // didn't bring it back (it was moved explicitly while folded).
        st.workspaces[7].output = Some("DP-5".into());
        st.workspaces[7].idx = 3;
        st.workspaces[7].is_active = false;
        st.workspaces[6].idx = 4;
        st.workspaces[8].is_active = true;
        st.workspaces[8].idx = 1;
        st.workspaces[9].idx = 2;
        let p = activate(&st, cat.find("music").unwrap(), &cat.active());
        assert_eq!(
            wire(&p),
            [
                json!({ "MoveWorkspaceToMonitor": { "output": "DP-3", "reference": { "Name": "music/right" } } }),
                // inserted after DP-3's active `recording` (Video): Music comes first
                json!({ "MoveWorkspaceToIndex": { "index": 1, "reference": { "Name": "music/right" } } }),
                fw("music"),
                fw("music/right"),
                fw("music"),
            ]
        );
    }

    #[test]
    fn fold_stack_on_a_laptop() {
        let cat = catalog();
        let laptop = vec![Display {
            name: "eDP-1".into(),
            identity: "BOE".into(),
            x: 0,
            y: 0,
            width: 1920,
            height: 1200,
        }];
        let st = State {
            displays: laptop,
            workspaces: vec![
                ws(1, 1, Some("main"), "eDP-1", true, true, true),
                ws(2, 2, Some("loft"), "eDP-1", false, false, true),
                ws(3, 3, None, "eDP-1", false, false, false),
            ],
            focused_window: Some(101),
            main: None,
        };
        let p = activate(&st, cat.find("proj-loft").unwrap(), &cat.active());
        // loft/left gets the trailing empty; loft/right needs niri's next one.
        assert!(p.incomplete);
        assert_eq!(
            wire(&p),
            [json!({ "SetWorkspaceName": { "name": "loft/left", "workspace": { "Id": 3 } } })]
        );
        // Next round: niri appended workspace 4.
        let mut st2 = st.clone();
        st2.workspaces[2].name = Some("loft/left".into());
        st2.workspaces
            .push(ws(4, 4, None, "eDP-1", false, false, false));
        let p = activate(&st2, cat.find("proj-loft").unwrap(), &cat.active());
        assert!(!p.incomplete);
        assert_eq!(
            wire(&p),
            [
                json!({ "SetWorkspaceName": { "name": "loft/right", "workspace": { "Id": 4 } } }),
                // Only main is focused; the folds wait below it (Mod+Ctrl+Down).
                fw("loft"),
            ]
        );
        let f: Vec<_> = p
            .resolution
            .folded
            .iter()
            .map(|f| f.role.as_str())
            .collect();
        assert_eq!(f, ["left", "right"]);
    }

    #[test]
    fn fold_columns_and_skip_create_nothing() {
        let cat = catalog();
        let laptop = vec![Display {
            name: "eDP-1".into(),
            identity: "BOE".into(),
            x: 0,
            y: 0,
            width: 1920,
            height: 1200,
        }];
        let st = State {
            displays: laptop,
            workspaces: vec![
                ws(1, 1, Some("loft"), "eDP-1", false, false, true),
                ws(2, 2, None, "eDP-1", true, true, false),
            ],
            focused_window: None,
            main: None,
        };
        for fold in [
            crate::spaces::model::Fold::Columns,
            crate::spaces::model::Fold::Skip,
        ] {
            let mut s = cat.find("proj-loft").unwrap().clone();
            s.fold = fold;
            let p = activate(&st, &s, &cat.active());
            assert_eq!(wire(&p), [fw("loft")], "{fold:?}");
        }
    }

    #[test]
    fn target_stay_keeps_focus_on_a_bound_display() {
        let cat = catalog();
        let mut st = music_showing();
        // Focus is on the right display.
        st.workspaces[1].is_focused = false;
        st.workspaces[7].is_focused = true;
        let mut s = cat.find("video").unwrap().clone();
        s.target = Target::Stay;
        let p = activate(&st, &s, &cat.active());
        assert_eq!(
            wire(&p),
            [fw("recording"), fw("media"), fw("video"), fw("recording")]
        );
        assert_eq!(p.target.as_deref(), Some("DP-3"));
        // Focus on a keep display (left in Music): falls back to main.
        st.workspaces[7].is_focused = false;
        st.workspaces[4].is_focused = true;
        let mut s = cat.find("music").unwrap().clone();
        s.target = Target::Stay;
        assert_eq!(
            activate(&st, &s, &cat.active()).target.as_deref(),
            Some("DP-4")
        );
    }

    #[test]
    fn move_window_goes_to_the_same_role() {
        let cat = catalog();
        let mut st = music_showing();
        // Focused window on the right display → Video's right workspace.
        st.workspaces[1].is_focused = false;
        st.workspaces[7].is_focused = true;
        st.focused_window = Some(108);
        let p = move_window(&st, cat.find("video").unwrap(), &cat.active());
        assert_eq!(
            wire(&p),
            [
                json!({ "MoveWindowToWorkspace": { "window_id": 108, "reference": { "Name": "recording" }, "focus": false } })
            ]
        );
        // From the left display (Gaming keeps it) → Gaming's main workspace,
        // which ensure creates first; focus comes back to the window's display.
        st.workspaces[7].is_focused = false;
        st.workspaces[4].is_focused = true;
        st.focused_window = Some(105);
        let p = move_window(&st, cat.find("gaming").unwrap(), &cat.active());
        let w = wire(&p);
        assert_eq!(w[0], json!({ "FocusMonitor": { "output": "DP-4" } }));
        assert_eq!(
            w[1],
            json!({ "SetWorkspaceName": { "name": "gaming", "workspace": { "Id": 4 } } })
        );
        assert_eq!(
            w[w.len() - 2..],
            [
                json!({ "MoveWindowToWorkspace": { "window_id": 105, "reference": { "Name": "gaming" }, "focus": false } }),
                json!({ "FocusMonitor": { "output": "DP-5" } }),
            ]
        );
    }

    #[test]
    fn activating_the_active_space_restores_keep_displays() {
        let cat = catalog();
        let music = cat.find("music").unwrap();
        let mut st = music_showing();
        // Music was activated while the left display showed comms.
        let memory = keep_shown(&st, music);
        let left = desk().into_iter().find(|d| d.name == "DP-5").unwrap();
        assert_eq!(
            memory.get(left.identity()).map(String::as_str),
            Some("comms")
        );
        // Then the left display was switched to `media` by hand.
        st.workspaces[4].is_active = false;
        st.workspaces[5].is_active = true;
        let p = activate_with(&st, music, &cat.active(), &memory);
        assert_eq!(wire(&p), [fw("music"), fw("comms"), fw("music")]);
        // Without memory (or when it's already showing) just main.
        assert_eq!(wire(&activate(&st, music, &cat.active())), [fw("music")]);
        st.workspaces[4].is_active = true;
        st.workspaces[5].is_active = false;
        assert_eq!(
            wire(&activate_with(&st, music, &cat.active(), &memory)),
            [fw("music")]
        );
        // A remembered workspace that moved to another display stays put.
        st.workspaces[4].is_active = false;
        st.workspaces[5].is_active = true;
        st.workspaces[4].output = Some("DP-3".into());
        assert_eq!(
            wire(&activate_with(&st, music, &cat.active(), &memory)),
            [fw("music")]
        );
    }

    #[test]
    fn order_all_restores_space_order() {
        let cat = catalog();
        let st = State {
            displays: desk(),
            workspaces: vec![
                ws(1, 1, Some("task"), "DP-4", false, false, false),
                ws(2, 2, Some("lab"), "DP-4", false, false, true),
                ws(3, 3, Some("music"), "DP-4", false, false, false),
                ws(4, 4, Some("main"), "DP-4", true, true, false),
                ws(5, 5, None, "DP-4", false, false, false),
                ws(6, 1, Some("comms"), "DP-5", true, false, false),
                ws(7, 2, None, "DP-5", false, false, false),
            ],
            focused_window: None,
            main: None,
        };
        let p = order_all(&st, &cat.active());
        let mi = |i: usize, n: &str| json!({ "MoveWorkspaceToIndex": { "index": i, "reference": { "Name": n } } });
        // main, music, task, then lab and the trailing empty.
        assert_eq!(wire(&p), [mi(1, "main"), mi(2, "music")]);
        // Already in order: nothing to do.
        let mut st2 = st.clone();
        st2.workspaces
            .retain(|w| w.output.as_deref() == Some("DP-5"));
        assert!(order_all(&st2, &cat.active()).actions.is_empty());
    }

    #[test]
    fn active_space_and_stepping() {
        let cat = catalog();
        let st = music_showing();
        assert_eq!(active_space(&st, &cat).unwrap().id, "music");
        assert_eq!(step(&st, &cat, true).unwrap().id, "video");
        assert_eq!(step(&st, &cat, false).unwrap().id, "main");
        let mut st = st;
        for w in &mut st.workspaces {
            w.name = None;
        }
        assert!(active_space(&st, &cat).is_none());
        assert_eq!(step(&st, &cat, true).unwrap().id, "main");
        assert_eq!(step(&st, &cat, false).unwrap().id, "proj-inferno");
    }
}
