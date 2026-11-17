//! Spaces under KWin (docs/KWIN.md §4.2, §4.15): the pure parts loft-niri
//! still does there, with KWin's outputs and windows given as JSON instead
//! of read from niri.
//!
//! - [`specs`]: a space's apps on the layout, each with the **display** its
//!   role resolves to (`space specs --displays`). loft-kwin starts the
//!   missing ones in the space's Activity and puts every window on its
//!   display (crates/loft-kwin/src/spinup.rs).
//! - [`capture_state`]: KWin's windows of the current Activity → the State
//!   and windows [`super::edit::capture`] takes (`space capture --displays
//!   --windows`): one active workspace per display, columns left to right.

use serde::Deserialize;
use serde_json::{Value, json};

use super::apps::{self, Open};
use super::model::Space;
use super::plan::State;
use super::roles::{self, Display};

/// `space specs`: `{space, startup, apps: [{app, role, display, exec, cwd,
/// launch, open, width, match: {appId, title, cwd}}], notes}`. `display` is
/// null for an app whose role has no display (a fold that skipped it is in
/// `notes` instead); a stacked or column fold lands on main's.
pub fn specs(space: &Space, displays: &[Display], main: Option<&str>, home: &str) -> Value {
    let res = roles::resolve(space, displays, main);
    let (specs, notes) = apps::specs(space, &res, apps::UNIT_PREFIX, home);
    let rows: Vec<Value> = specs
        .iter()
        .map(|s| {
            let display = res
                .display_of(&s.workspace)
                .or(res.main.as_ref())
                .map(|d| d.name.clone());
            let re = |r: &Option<regex::Regex>| r.as_ref().map(|r| r.as_str().to_string());
            json!({
                "app": s.app,
                "role": s.role,
                "display": display,
                "exec": s.exec,
                "cwd": s.cwd,
                "launch": s.launch,
                "open": match s.open {
                    Open::Normal => "normal",
                    Open::Maximized => "maximized",
                    Open::Fullscreen => "fullscreen",
                    Open::Floating => "floating",
                },
                "width": s.width,
                "match": {
                    "appId": re(&s.matcher.app_id),
                    "title": re(&s.matcher.title),
                    "cwd": s.matcher.cwd.as_ref().map(|p| p.to_string_lossy().into_owned()),
                },
            })
        })
        .collect();
    json!({ "space": space.id, "startup": space.startup, "apps": rows, "notes": notes })
}

/// A KWin window for `space capture --windows`: KWin.qml's records, cut
/// down (`geometry` is output-local, `[x, y, width, height]`).
#[derive(Debug, Clone, Deserialize)]
pub struct KWinWindow {
    pub app_id: String,
    #[serde(default)]
    pub pid: i32,
    pub output: String,
    #[serde(default)]
    pub geometry: [f64; 4],
    #[serde(default)]
    pub maximized: bool,
}

/// KWin's windows → a State with one active workspace per display (ids
/// 1…n) and niri-shaped windows on them, columns by their left edge.
/// KWin windows all float, but the space's apps are declared as tiles, so
/// they're captured as such (maximized → `open: maximized`, else a width).
pub fn capture_state(
    displays: Vec<Display>,
    wins: &[KWinWindow],
    main: Option<String>,
) -> (State, Vec<apps::Win>) {
    let workspaces: Vec<niri_ipc::Workspace> = displays
        .iter()
        .enumerate()
        .map(|(i, d)| niri_ipc::Workspace {
            id: i as u64 + 1,
            idx: 1,
            name: None,
            output: Some(d.name.clone()),
            is_urgent: false,
            is_active: true,
            is_focused: false,
            active_window_id: None,
        })
        .collect();
    let mut out = Vec::new();
    for (i, d) in displays.iter().enumerate() {
        let mut on: Vec<(usize, &KWinWindow)> = wins
            .iter()
            .enumerate()
            .filter(|(_, w)| w.output == d.name && !w.app_id.is_empty())
            .collect();
        on.sort_by(|a, b| a.1.geometry[0].total_cmp(&b.1.geometry[0]).then(a.0.cmp(&b.0)));
        for (col, (n, w)) in on.into_iter().enumerate() {
            let width = if w.maximized { d.width } else { w.geometry[2].round() as i32 };
            out.push(apps::Win {
                id: n as u64 + 1,
                app_id: Some(w.app_id.clone()),
                pid: (w.pid > 0).then_some(w.pid),
                workspace_id: Some(i as u64 + 1),
                column: Some(col + 1),
                size: (width, w.geometry[3].round() as i32),
                ..Default::default()
            });
        }
    }
    let st = State {
        displays,
        workspaces,
        focused_window: None,
        main,
    };
    (st, out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spaces::edit;
    use crate::spaces::model::Catalog;
    use crate::spaces::model::tests::env;

    fn two() -> Vec<Display> {
        let d = |name: &str, x: i32| Display {
            name: name.into(),
            identity: name.into(),
            x,
            y: 0,
            width: 1280,
            height: 800,
        };
        vec![d("WL-0", 0), d("WL-1", 1280)]
    }

    fn space(doc: Value) -> Space {
        let dir = std::env::temp_dir().join(format!("loft-kwin-specs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("t.json"), doc.to_string()).unwrap();
        let cat = Catalog::load(Some(&dir), &env());
        let _ = std::fs::remove_dir_all(&dir);
        assert!(cat.problems.is_empty(), "{:?}", cat.problems);
        cat.find("t").unwrap().clone()
    }

    #[test]
    fn specs_name_the_display_of_each_role() {
        let s = space(json!({
            "kind": "space", "id": "t", "name": "T",
            "displays": {
                "main": { "apps": [{ "id": "kwrite", "exec": ["kwrite"], "match": { "appId": "^org\\.kde\\.kwrite$" } }] },
                "right": { "apps": [{ "id": "konsole", "exec": ["konsole"], "open": "maximized" }] },
                "*": "keep"
            }
        }));
        let v = specs(&s, &two(), Some("WL-0"), "/home/x");
        let apps = v["apps"].as_array().unwrap();
        assert_eq!(apps.len(), 2, "{v}");
        assert_eq!(apps[0]["app"], "kwrite");
        assert_eq!(apps[0]["display"], "WL-0");
        assert_eq!(apps[0]["match"]["appId"], "^org\\.kde\\.kwrite$");
        assert_eq!(apps[1]["app"], "konsole");
        assert_eq!(apps[1]["display"], "WL-1");
        assert_eq!(apps[1]["open"], "maximized");
        assert_eq!(apps[1]["match"]["appId"], Value::Null);
        assert_eq!(v["startup"], "first-activate");

        // One display: right stacks onto main's (the default fold).
        let one = &two()[..1];
        let v = specs(&s, one, None, "/home/x");
        assert_eq!(v["apps"][1]["display"], "WL-0", "{v}");
    }

    #[test]
    fn capture_from_kwin_windows() {
        let w = |app: &str, pid: i32, out: &str, x: f64, width: f64, maximized: bool| KWinWindow {
            app_id: app.into(),
            pid,
            output: out.into(),
            geometry: [x, 0.0, width, 600.0],
            maximized,
        };
        let wins = vec![
            w("org.kde.konsole", 11, "WL-1", 0.0, 1280.0, true),
            w("org.kde.kwrite", 10, "WL-0", 600.0, 640.0, false),
            w("org.kde.dolphin", 12, "WL-0", 10.0, 420.0, false),
        ];
        let (st, ws) = capture_state(two(), &wins, Some("WL-0".into()));
        let cmds = |pid: i32| Some(vec![format!("cmd{pid}")]);
        let doc = edit::capture(&st, &ws, &cmds, "now", "Now", "");
        let d = &doc["displays"];
        let ids: Vec<_> = d["main"]["apps"].as_array().unwrap().iter().map(|a| a["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["dolphin", "kwrite"], "left to right: {doc}");
        assert_eq!(d["main"]["apps"][1]["exec"], json!(["cmd10"]));
        assert_eq!(d["main"]["apps"][1]["width"], json!(0.5));
        assert_eq!(d["main"]["apps"][1]["match"]["appId"], json!("^org\\.kde\\.kwrite$"));
        // The other display took its role (right of main).
        let other = d.as_object().unwrap().iter().find(|(k, v)| *k != "main" && *k != "*" && v.is_object()).unwrap();
        assert_eq!(other.1["apps"][0]["id"], "konsole");
        assert_eq!(other.1["apps"][0]["open"], "maximized");
    }
}
