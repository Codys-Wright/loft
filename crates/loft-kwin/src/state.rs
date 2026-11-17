//! KWin snapshots (from loft-bridge.js) → the niri-shaped records the shell's
//! `Compositor` service uses (docs/KWIN.md §2).
//!
//! KWin identifies windows and virtual desktops by UUID; the shell expects
//! integer ids where a higher id means a newer window, and one workspace per
//! output (niri's model). So the model keeps:
//! - a window id per UUID, assigned in the order windows are first seen;
//! - a workspace id per (desktop, output) pair: KWin's desktops span every
//!   output, so each output shows "its" copy of the current desktop;
//! - a focus timestamp per window, stamped when it becomes the active one.

use std::collections::HashMap;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Snapshot {
    #[serde(default)]
    pub windows: Vec<KWindow>,
    #[serde(default)]
    pub desktops: Vec<KDesktop>,
    #[serde(default)]
    pub current_desktop: String,
    #[serde(default)]
    pub screens: Vec<KScreen>,
    #[serde(default)]
    pub active_screen: String,
    #[serde(default)]
    pub active_window: String,
    #[serde(default)]
    pub activities: Vec<String>,
    #[serde(default)]
    pub current_activity: String,
    /// KWin's Overview / Grid View / Present Windows effect is running.
    #[serde(default)]
    pub overview: bool,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct KWindow {
    pub uuid: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub app_id: String,
    #[serde(default)]
    pub pid: i64,
    /// Empty: on all desktops.
    #[serde(default)]
    pub desktops: Vec<String>,
    #[serde(default)]
    pub output: String,
    /// x, y, width, height (global logical px).
    #[serde(default)]
    pub geometry: [f64; 4],
    #[serde(default)]
    pub minimized: bool,
    #[serde(default)]
    pub fullscreen: bool,
    #[serde(default)]
    pub maximized: bool,
    #[serde(default)]
    pub keep_above: bool,
    #[serde(default)]
    pub urgent: bool,
    #[serde(default)]
    pub activities: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct KDesktop {
    pub id: String,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct KScreen {
    pub name: String,
    #[serde(default)]
    pub geometry: [f64; 4],
    /// EDID vendor as KWin reports it: the 3-letter PNP id ("ACR").
    #[serde(default)]
    pub manufacturer: String,
    /// Sometimes prefixed with the connector ("DP-2-MPG491CX OLED").
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub serial: String,
    #[serde(default)]
    pub scale: f64,
}

/// niri's display identity, "Make Model Serial" (what Loft's settings key
/// displays by: wallpapers, roles, main display), from KWin's output info.
/// niri spells the vendor out from the PNP id database and writes "Unknown"
/// for a missing serial; KWin gives the PNP id, may prefix the model with
/// the connector, and leaves the serial empty. With nothing known (virtual
/// outputs: no EDID) it's the connector, as niri does.
pub fn identity(screen: &KScreen, pnp: &HashMap<String, String>) -> String {
    let make = pnp
        .get(&screen.manufacturer)
        .cloned()
        .unwrap_or_else(|| screen.manufacturer.clone());
    let prefix = format!("{}-", screen.name);
    let model = screen.model.strip_prefix(&prefix).unwrap_or(&screen.model);
    let model = if model == screen.name { "" } else { model };
    if make.is_empty() && model.is_empty() && screen.serial.is_empty() {
        return screen.name.clone();
    }
    let or_unknown = |s: &str| if s.is_empty() { "Unknown".to_string() } else { s.to_string() };
    format!("{} {} {}", or_unknown(&make), or_unknown(model), or_unknown(&screen.serial))
}

/// hwdata's pnp.ids: "ACR\tAcer Technologies" lines.
pub fn parse_pnp_ids(text: &str) -> HashMap<String, String> {
    text.lines()
        .filter_map(|l| l.split_once('\t'))
        .map(|(id, name)| (id.trim().to_string(), name.trim().to_string()))
        .collect()
}

#[derive(Debug, Default)]
pub struct Model {
    /// PNP id → vendor name (hwdata's pnp.ids), for display identities.
    pub pnp: HashMap<String, String>,
    window_ids: HashMap<String, u64>,
    next_window: u64,
    workspace_ids: HashMap<(String, String), u64>,
    next_workspace: u64,
    focus_stamps: HashMap<String, Duration>,
    last_active: String,
}

/// KDE's default desktop names ("Desktop 1", …) say nothing the dots don't;
/// niri's unnamed workspaces have no name, so these don't either.
fn is_default_name(name: &str, index: usize) -> bool {
    name.is_empty() || name == format!("Desktop {}", index + 1)
}

impl Model {
    pub fn new() -> Self {
        Self {
            next_window: 1,
            next_workspace: 1,
            ..Default::default()
        }
    }

    fn window_id(&mut self, uuid: &str) -> u64 {
        if let Some(id) = self.window_ids.get(uuid) {
            return *id;
        }
        let id = self.next_window;
        self.next_window += 1;
        self.window_ids.insert(uuid.to_string(), id);
        id
    }

    fn workspace_id(&mut self, desktop: &str, output: &str) -> u64 {
        let key = (desktop.to_string(), output.to_string());
        if let Some(id) = self.workspace_ids.get(&key) {
            return *id;
        }
        let id = self.next_workspace;
        self.next_workspace += 1;
        self.workspace_ids.insert(key, id);
        id
    }

    /// The shell's state for this snapshot. `now` stamps a newly active window.
    pub fn update(&mut self, snap: &Snapshot, now: Duration) -> Value {
        // Forget what's gone, so ids don't leak (a new window never reuses one).
        self.window_ids
            .retain(|uuid, _| snap.windows.iter().any(|w| &w.uuid == uuid));
        self.focus_stamps
            .retain(|uuid, _| snap.windows.iter().any(|w| &w.uuid == uuid));
        self.workspace_ids.retain(|(d, o), _| {
            snap.desktops.iter().any(|x| &x.id == d) && snap.screens.iter().any(|s| &s.name == o)
        });

        if !snap.active_window.is_empty() && snap.active_window != self.last_active {
            self.focus_stamps.insert(snap.active_window.clone(), now);
        }
        self.last_active = snap.active_window.clone();

        let active = snap.windows.iter().find(|w| w.uuid == snap.active_window);
        let focused_output = active
            .map(|w| w.output.clone())
            .filter(|o| !o.is_empty())
            .unwrap_or_else(|| snap.active_screen.clone());

        // Workspace ids in desktop order, then output order.
        for d in &snap.desktops {
            for s in &snap.screens {
                self.workspace_id(&d.id, &s.name);
            }
        }

        // Windows next (ids in first-seen order), so workspaces can name
        // their active window.
        let mut windows = Vec::new();
        let mut placed: Vec<(u64, u64, &KWindow)> = Vec::new(); // (window id, workspace id, window)
        // Stable order for new ids: the order KWin lists them (stacking).
        for w in &snap.windows {
            let id = self.window_id(&w.uuid);
            let desktop = w
                .desktops
                .first()
                .cloned()
                .unwrap_or_else(|| snap.current_desktop.clone());
            let output = if w.output.is_empty() {
                focused_output.clone()
            } else {
                w.output.clone()
            };
            let ws = self.workspace_id(&desktop, &output);
            placed.push((id, ws, w));
        }

        for (id, ws, w) in &placed {
            let screen = snap.screens.iter().find(|s| s.name == w.output);
            let (sx, sy) = screen.map(|s| (s.geometry[0], s.geometry[1])).unwrap_or((0.0, 0.0));
            let [x, y, width, height] = w.geometry;
            let mut record = json!({
                "id": id,
                "title": w.title,
                "app_id": w.app_id,
                "pid": w.pid,
                "workspace_id": ws,
                "is_focused": w.uuid == snap.active_window,
                "is_floating": true,
                "is_urgent": w.urgent,
                "is_minimized": w.minimized,
                "is_fullscreen": w.fullscreen,
                "is_maximized": w.maximized,
                "is_keep_above": w.keep_above,
                "layout": {
                    "window_size": [width.round() as i64, height.round() as i64],
                    "tile_size": [width, height],
                    "tile_pos_in_workspace_view": [x - sx, y - sy],
                    "pos_in_scrolling_layout": null,
                },
                "kwin_uuid": w.uuid,
                "kwin_desktops": w.desktops,
                "kwin_activities": w.activities,
            });
            if let Some(t) = self.focus_stamps.get(&w.uuid) {
                record["focus_timestamp"] = json!({ "secs": t.as_secs(), "nanos": t.subsec_nanos() });
            }
            windows.push(record);
        }
        windows.sort_by_key(|w| w["id"].as_u64().unwrap_or(0));

        let mut workspaces = Vec::new();
        for s in &snap.screens {
            for (i, d) in snap.desktops.iter().enumerate() {
                let id = self.workspace_id(&d.id, &s.name);
                let is_active = d.id == snap.current_desktop;
                let on_it: Vec<&(u64, u64, &KWindow)> = placed.iter().filter(|(_, ws, _)| *ws == id).collect();
                let active_window = on_it
                    .iter()
                    .find(|(_, _, w)| w.uuid == snap.active_window)
                    .map(|(wid, _, _)| *wid);
                workspaces.push(json!({
                    "id": id,
                    "idx": i + 1,
                    "name": if is_default_name(&d.name, i) { Value::Null } else { Value::from(d.name.clone()) },
                    "output": s.name,
                    "is_active": is_active,
                    "is_focused": is_active && s.name == focused_output,
                    "is_urgent": on_it.iter().any(|(_, _, w)| w.urgent),
                    "active_window_id": active_window,
                    "kwin_desktop": d.id,
                }));
            }
        }

        json!({
            "windows": windows,
            "workspaces": workspaces,
            "outputs": snap.screens.iter().map(|s| json!({
                "name": s.name,
                "geometry": s.geometry,
                "identity": identity(s, &self.pnp),
                "scale": if s.scale > 0.0 { s.scale } else { 1.0 },
                "model": s.model.strip_prefix(&format!("{}-", s.name)).unwrap_or(&s.model),
            })).collect::<Vec<_>>(),
            "activities": snap.activities,
            "current_activity": snap.current_activity,
            "overview_open": snap.overview,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(windows: Vec<KWindow>, active: &str) -> Snapshot {
        Snapshot {
            windows,
            desktops: vec![
                KDesktop { id: "d1".into(), name: "Desktop 1".into() },
                KDesktop { id: "d2".into(), name: "Music".into() },
            ],
            current_desktop: "d1".into(),
            screens: vec![
                KScreen { name: "DP-1".into(), geometry: [0.0, 0.0, 2560.0, 1440.0], ..Default::default() },
                KScreen { name: "DP-2".into(), geometry: [2560.0, 0.0, 1920.0, 1080.0], ..Default::default() },
            ],
            active_screen: "DP-1".into(),
            active_window: active.into(),
            ..Default::default()
        }
    }

    fn win(uuid: &str, desktop: &str, output: &str) -> KWindow {
        KWindow {
            uuid: uuid.into(),
            app_id: format!("app.{uuid}"),
            desktops: if desktop.is_empty() { vec![] } else { vec![desktop.into()] },
            output: output.into(),
            geometry: [2660.0, 100.0, 800.0, 600.0],
            ..Default::default()
        }
    }

    fn by_id(state: &Value, key: &str, id: u64) -> Value {
        state[key].as_array().unwrap().iter().find(|x| x["id"] == id).unwrap().clone()
    }

    #[test]
    fn display_identities_match_niri() {
        // What KWin 6.8.2 reported for THEBATTLESHIP's displays, and the
        // identities niri gave them (Loft's settings key by these).
        let pnp = parse_pnp_ids("ACR\tAcer Technologies\nMSI\tMicrostep\n");
        let msi = KScreen {
            name: "DP-2".into(),
            manufacturer: "MSI".into(),
            model: "DP-2-MPG491CX OLED".into(),
            serial: "".into(),
            ..Default::default()
        };
        assert_eq!(identity(&msi, &pnp), "Microstep MPG491CX OLED Unknown");
        let acer = KScreen {
            name: "DP-3".into(),
            manufacturer: "ACR".into(),
            model: "XV271U M3".into(),
            serial: "1321033793LAJ".into(),
            ..Default::default()
        };
        assert_eq!(identity(&acer, &pnp), "Acer Technologies XV271U M3 1321033793LAJ");
        // Unknown vendor id: kept as is.
        let odd = KScreen { name: "HDMI-A-1".into(), manufacturer: "ZZZ".into(), model: "X".into(), serial: "1".into(), ..Default::default() };
        assert_eq!(identity(&odd, &pnp), "ZZZ X 1");
        // No EDID (KWin's nested and virtual outputs): the connector, like niri.
        let virt = KScreen { name: "WL-0".into(), model: "WL-0".into(), ..Default::default() };
        assert_eq!(identity(&virt, &pnp), "WL-0");
        let bare = KScreen { name: "Virtual-1".into(), ..Default::default() };
        assert_eq!(identity(&bare, &pnp), "Virtual-1");
    }

    #[test]
    fn window_ids_are_stable_and_ascending_by_first_sight() {
        let mut m = Model::new();
        let s1 = m.update(&snap(vec![win("a", "d1", "DP-1"), win("b", "d1", "DP-1")], "a"), Duration::from_secs(1));
        let ids: Vec<u64> = s1["windows"].as_array().unwrap().iter().map(|w| w["id"].as_u64().unwrap()).collect();
        assert_eq!(ids, vec![1, 2]);
        // b goes away, c appears: a keeps 1, c is newer than anything before.
        let s2 = m.update(&snap(vec![win("a", "d1", "DP-1"), win("c", "d1", "DP-1")], "a"), Duration::from_secs(2));
        let titles: Vec<(u64, String)> = s2["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| (w["id"].as_u64().unwrap(), w["kwin_uuid"].as_str().unwrap().to_string()))
            .collect();
        assert_eq!(titles, vec![(1, "a".into()), (3, "c".into())]);
    }

    #[test]
    fn one_workspace_per_desktop_and_output() {
        let mut m = Model::new();
        let s = m.update(&snap(vec![win("a", "d2", "DP-2")], "a"), Duration::from_secs(1));
        let ws = s["workspaces"].as_array().unwrap();
        assert_eq!(ws.len(), 4);
        let a = &s["windows"][0];
        let home = by_id(&s, "workspaces", a["workspace_id"].as_u64().unwrap());
        assert_eq!(home["output"], "DP-2");
        assert_eq!(home["kwin_desktop"], "d2");
        assert_eq!(home["idx"], 2);
        assert_eq!(home["name"], "Music");
        assert_eq!(home["active_window_id"], a["id"]);
        // Default names are dropped, like niri's unnamed workspaces.
        let first = ws.iter().find(|w| w["kwin_desktop"] == "d1" && w["output"] == "DP-1").unwrap();
        assert!(first["name"].is_null());
    }

    #[test]
    fn active_and_focused_follow_the_current_desktop_and_active_window() {
        let mut m = Model::new();
        let s = m.update(&snap(vec![win("a", "d1", "DP-2")], "a"), Duration::from_secs(1));
        let ws = s["workspaces"].as_array().unwrap();
        let active: Vec<_> = ws.iter().filter(|w| w["is_active"] == true).collect();
        assert_eq!(active.len(), 2, "the current desktop is active on every output");
        let focused: Vec<_> = ws.iter().filter(|w| w["is_focused"] == true).collect();
        assert_eq!(focused.len(), 1);
        assert_eq!(focused[0]["output"], "DP-2", "focus follows the active window's output");
        assert_eq!(s["windows"][0]["is_focused"], true);
        // Position is relative to the window's output.
        assert_eq!(s["windows"][0]["layout"]["tile_pos_in_workspace_view"], json!([100.0, 100.0]));
    }

    #[test]
    fn no_active_window_focuses_the_active_screen() {
        let mut m = Model::new();
        let s = m.update(&snap(vec![win("a", "d1", "DP-2")], ""), Duration::from_secs(1));
        let focused: Vec<_> = s["workspaces"].as_array().unwrap().iter().filter(|w| w["is_focused"] == true).collect();
        assert_eq!(focused.len(), 1);
        assert_eq!(focused[0]["output"], "DP-1");
    }

    #[test]
    fn windows_on_all_desktops_sit_on_the_current_one() {
        let mut m = Model::new();
        let s = m.update(&snap(vec![win("a", "", "DP-1")], "a"), Duration::from_secs(1));
        let home = by_id(&s, "workspaces", s["windows"][0]["workspace_id"].as_u64().unwrap());
        assert_eq!(home["kwin_desktop"], "d1");
    }

    #[test]
    fn focus_timestamps_mark_activation_order() {
        let mut m = Model::new();
        let two = vec![win("a", "d1", "DP-1"), win("b", "d1", "DP-1")];
        m.update(&snap(two.clone(), "a"), Duration::from_secs(10));
        let s = m.update(&snap(two.clone(), "b"), Duration::from_secs(20));
        let stamp = |uuid: &str| {
            s["windows"]
                .as_array()
                .unwrap()
                .iter()
                .find(|w| w["kwin_uuid"] == uuid)
                .unwrap()["focus_timestamp"]["secs"]
                .as_u64()
                .unwrap()
        };
        assert_eq!(stamp("a"), 10);
        assert_eq!(stamp("b"), 20);
        // Re-sending the same active window doesn't restamp it.
        let s = m.update(&snap(two, "b"), Duration::from_secs(30));
        let b = s["windows"].as_array().unwrap().iter().find(|w| w["kwin_uuid"] == "b").unwrap().clone();
        assert_eq!(b["focus_timestamp"]["secs"], 20);
    }

    #[test]
    fn overview_state_passes_through() {
        let mut m = Model::new();
        let closed = m.update(&snap(vec![], ""), Duration::from_secs(1));
        assert_eq!(closed["overview_open"], false);
        let mut open = snap(vec![], "");
        open.overview = true;
        assert_eq!(m.update(&open, Duration::from_secs(2))["overview_open"], true);
        // An older script that doesn't send it: closed.
        let old: Snapshot = serde_json::from_str(r#"{"windows": [], "desktops": []}"#).unwrap();
        assert_eq!(m.update(&old, Duration::from_secs(3))["overview_open"], false);
    }
}
