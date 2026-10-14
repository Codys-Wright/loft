//! Display roles: displays named by the live layout instead of connectors,
//! so a space made on one desk works on another.
//!
//! A port of `cli/loft/wallsets.py` `roles()` (also `src/services/wallsets.js`);
//! all three are checked against `tests/fixtures/wallsets/layouts.json`.
//!
//! - `main`: the display named in Settings → Displays (connector or
//!   identity), else the largest (ties: leftmost, then topmost)
//! - `left` / `right` / `top` / `bottom` of main, nearest first; further out
//!   `left-2`, `left-3`, …
//! - the shape: `portrait`, `ultrawide` (≥ 2.2:1) or `landscape`
//! - the ordinal `display-1..N` (by x, then y)
//! - `*`: any display
//!
//! Each display's roles are listed most specific first; a space binding is
//! picked by the first of a display's roles the space binds.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::model::{Binding, Fold, Space};
use crate::outputs::{self, Outputs};

pub const ULTRAWIDE: f64 = 2.2;
pub const DIRECTIONS: [&str; 4] = ["left", "right", "top", "bottom"];

/// One enabled display of the layout, in global logical coordinates.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Display {
    /// Connector (`DP-4`, `headless-2`).
    pub name: String,
    /// niri's stable "Make Model Serial" (the connector when nothing is known).
    #[serde(default)]
    pub identity: String,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Display {
    pub fn identity(&self) -> &str {
        if self.identity.is_empty() {
            &self.name
        } else {
            &self.identity
        }
    }

    fn area(&self) -> f64 {
        f64::from(self.width) * f64::from(self.height)
    }

    pub fn center(&self) -> (f64, f64) {
        (
            f64::from(self.x) + f64::from(self.width) / 2.0,
            f64::from(self.y) + f64::from(self.height) / 2.0,
        )
    }

    pub fn shape(&self) -> &'static str {
        if self.height > self.width {
            "portrait"
        } else if f64::from(self.width) / f64::from(self.height.max(1)) >= ULTRAWIDE {
            "ultrawide"
        } else {
            "landscape"
        }
    }

    /// Whether `target` names this display (connector or identity, any case).
    pub fn matches(&self, target: &str) -> bool {
        target.eq_ignore_ascii_case(&self.name) || target.eq_ignore_ascii_case(self.identity())
    }
}

/// The enabled outputs niri reports, left to right.
pub fn displays_from_niri(outs: &Outputs) -> Vec<Display> {
    let mut v: Vec<Display> = outs
        .values()
        .filter_map(|o| {
            let l = o.logical?;
            Some(Display {
                name: o.name.clone(),
                identity: outputs::identity(o),
                x: l.x,
                y: l.y,
                width: l.width as i32,
                height: l.height as i32,
            })
        })
        .collect();
    v.sort_by(|a, b| (a.x, a.y, &a.name).cmp(&(b.x, b.y, &b.name)));
    v
}

/// The display named by `main` (connector or identity), else the largest
/// (ties: leftmost, then topmost).
pub fn main_display<'a>(displays: &'a [Display], main: Option<&str>) -> Option<&'a Display> {
    if let Some(m) = main.filter(|m| !m.is_empty())
        && let Some(hit) = displays.iter().find(|d| d.name == m || d.identity == m)
    {
        return Some(hit);
    }
    displays.iter().min_by(|a, b| {
        b.area()
            .total_cmp(&a.area())
            .then(a.x.cmp(&b.x))
            .then(a.y.cmp(&b.y))
    })
}

/// connector → its roles, most specific first.
pub fn roles(displays: &[Display], main: Option<&str>) -> BTreeMap<String, Vec<String>> {
    let mut out = BTreeMap::new();
    let Some(m) = main_display(displays, main) else {
        return out;
    };
    let (mcx, mcy) = m.center();
    let (mx2, my2) = (m.x + m.width, m.y + m.height);
    // direction → (gap, offset from main's center line, connector)
    let mut groups: BTreeMap<&str, Vec<(f64, f64, &str)>> =
        DIRECTIONS.iter().map(|d| (*d, Vec::new())).collect();
    for o in displays {
        if o.name == m.name {
            continue;
        }
        let (ox2, oy2) = (o.x + o.width, o.y + o.height);
        let (cx, cy) = o.center();
        let entry = if ox2 <= m.x {
            ("left", f64::from(m.x - ox2), (cy - mcy).abs())
        } else if o.x >= mx2 {
            ("right", f64::from(o.x - mx2), (cy - mcy).abs())
        } else if oy2 <= m.y {
            ("top", f64::from(m.y - oy2), (cx - mcx).abs())
        } else if o.y >= my2 {
            ("bottom", f64::from(o.y - my2), (cx - mcx).abs())
        } else {
            continue; // overlapping main: no positional role
        };
        groups
            .get_mut(entry.0)
            .unwrap()
            .push((entry.1, entry.2, &o.name));
    }
    let mut positional: BTreeMap<&str, String> = BTreeMap::new();
    positional.insert(&m.name, "main".into());
    for (dir, mut items) in groups {
        items.sort_by(|a, b| {
            a.0.total_cmp(&b.0)
                .then(a.1.total_cmp(&b.1))
                .then(a.2.cmp(b.2))
        });
        for (i, (_, _, name)) in items.into_iter().enumerate() {
            let role = if i == 0 {
                dir.to_string()
            } else {
                format!("{dir}-{}", i + 1)
            };
            positional.insert(name, role);
        }
    }
    let mut by_pos: Vec<&Display> = displays.iter().collect();
    by_pos.sort_by(|a, b| (a.x, a.y, &a.name).cmp(&(b.x, b.y, &b.name)));
    for (i, o) in by_pos.into_iter().enumerate() {
        let mut rs: Vec<String> = positional
            .get(o.name.as_str())
            .cloned()
            .into_iter()
            .collect();
        rs.push(o.shape().into());
        rs.push(format!("display-{}", i + 1));
        rs.push("*".into());
        out.insert(o.name.clone(), rs);
    }
    out
}

/// Whether a role names a display by where it is (`main`, `left`, `left-2`, …),
/// as opposed to its shape, ordinal or `*`.
pub fn is_positional(role: &str) -> bool {
    role == "main"
        || DIRECTIONS.iter().any(|d| {
            role == *d
                || role
                    .strip_prefix(d)
                    .and_then(|r| r.strip_prefix('-'))
                    .is_some_and(|n| n.parse::<u32>().is_ok_and(|n| n >= 2))
        })
}

/// Every role name the layout model knows (for validating space documents).
pub fn is_known_role(role: &str) -> bool {
    is_positional(role)
        || matches!(role, "portrait" | "landscape" | "ultrawide" | "*")
        || role
            .strip_prefix("display-")
            .is_some_and(|n| n.parse::<u32>().is_ok_and(|n| n >= 1))
}

/// A space on a live layout: which workspace each display shows.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Resolution {
    /// The main display (None: no displays).
    pub main: Option<Display>,
    /// Every display, main first then left to right, with what the space
    /// puts there (`None`: keep).
    pub placements: Vec<Placement>,
    /// Bound roles with no display (§3.3), in role order.
    pub folded: Vec<FoldedRole>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Placement {
    pub display: Display,
    /// The role the display took (`None`: the space binds none of its roles).
    pub role: Option<String>,
    /// The workspace, unless the binding is `keep`.
    pub workspace: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct FoldedRole {
    pub role: String,
    pub workspace: String,
    pub fold: Fold,
}

impl Resolution {
    /// Where a workspace of the space lives: the display it's placed on,
    /// or main's for a stacked fold.
    pub fn display_of(&self, workspace: &str) -> Option<&Display> {
        self.placements
            .iter()
            .find(|p| {
                p.workspace
                    .as_deref()
                    .is_some_and(|w| w.eq_ignore_ascii_case(workspace))
            })
            .map(|p| &p.display)
            .or_else(|| {
                self.folded
                    .iter()
                    .find(|f| f.fold == Fold::Stack && f.workspace.eq_ignore_ascii_case(workspace))
                    .and(self.main.as_ref())
            })
    }

    /// The workspace a display shows in this space (None: keep).
    pub fn workspace_on(&self, display: &str) -> Option<&str> {
        self.placements
            .iter()
            .find(|p| p.display.name == display)
            .and_then(|p| p.workspace.as_deref())
    }

    /// Workspaces stacked on main's display, in role order.
    pub fn stacked(&self) -> impl Iterator<Item = &FoldedRole> {
        self.folded.iter().filter(|f| f.fold == Fold::Stack)
    }
}

/// Each display takes the first of its roles the space binds (a workspace
/// goes to one display only: the first to take it, main first). A bound
/// role no display has folds by the space's `fold` (a role some display
/// has but passed over for a more specific one is just an alternative).
pub fn resolve(space: &Space, displays: &[Display], main: Option<&str>) -> Resolution {
    let rs = roles(displays, main);
    let m = main_display(displays, main).cloned();
    let mut ordered: Vec<&Display> = displays.iter().collect();
    ordered.sort_by_key(|d| (Some(&d.name) != m.as_ref().map(|m| &m.name), d.x, d.y));
    let mut taken: Vec<&str> = Vec::new();
    let mut placements = Vec::new();
    for d in ordered {
        let mut placement = Placement {
            display: d.clone(),
            role: None,
            workspace: None,
        };
        for r in rs.get(&d.name).into_iter().flatten() {
            match space.binding(r) {
                None => continue,
                Some(Binding::Keep) => {
                    placement.role = Some(r.clone());
                    break;
                }
                Some(Binding::Bound(b)) => {
                    if taken.contains(&r.as_str()) {
                        continue;
                    }
                    taken.push(r);
                    placement.role = Some(r.clone());
                    placement.workspace = Some(b.workspace.clone());
                    break;
                }
            }
        }
        placements.push(placement);
    }
    let all_roles: Vec<&String> = rs.values().flatten().collect();
    let folded = space
        .workspaces()
        .into_iter()
        .filter(|(r, _)| *r != "*" && !taken.contains(r) && !all_roles.iter().any(|x| x == r))
        .filter(|_| !displays.is_empty())
        .map(|(r, b)| FoldedRole {
            role: r.to_string(),
            workspace: b.workspace.clone(),
            fold: space.fold,
        })
        .collect();
    Resolution {
        main: m,
        placements,
        folded,
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use serde_json::Value;

    /// The wallsets fixtures: the same cases the Python and JS ports pass.
    pub fn fixture_cases() -> Vec<Value> {
        let v: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/wallsets/layouts.json"
        ))
        .unwrap();
        v["cases"].as_array().unwrap().clone()
    }

    #[test]
    fn roles_match_the_wallsets_fixtures() {
        let cases = fixture_cases();
        assert!(cases.len() >= 5);
        for case in cases {
            let layout = &case["layout"];
            let displays: Vec<Display> = serde_json::from_value(layout["outputs"].clone()).unwrap();
            let main = layout["main"].as_str();
            let got = roles(&displays, main);
            let want: BTreeMap<String, Vec<String>> =
                serde_json::from_value(case["roles"].clone()).unwrap();
            assert_eq!(got, want, "case: {}", case["name"]);
        }
    }

    #[test]
    fn main_falls_back_to_the_largest() {
        let d = |name: &str, x, w, h| Display {
            name: name.into(),
            identity: String::new(),
            x,
            y: 0,
            width: w,
            height: h,
        };
        let ds = vec![d("A", 0, 1920, 1080), d("B", 1920, 2560, 1440)];
        assert_eq!(main_display(&ds, None).unwrap().name, "B");
        assert_eq!(main_display(&ds, Some("nope")).unwrap().name, "B");
        assert_eq!(main_display(&ds, Some("A")).unwrap().name, "A");
        // Equal areas: the leftmost.
        let ds = vec![d("R", 1920, 1920, 1080), d("L", 0, 1920, 1080)];
        assert_eq!(main_display(&ds, None).unwrap().name, "L");
        assert!(main_display(&[], None).is_none());
    }

    #[test]
    fn niri_outputs_become_displays() {
        let outs: Outputs =
            serde_json::from_str(include_str!("../../tests/fixtures/outputs-three.json")).unwrap();
        let ds = displays_from_niri(&outs);
        let names: Vec<_> = ds.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(names, vec!["DP-2", "DP-1", "HDMI-A-1"]);
        let rs = roles(&ds, None);
        assert_eq!(rs["DP-1"][0], "main");
        assert_eq!(rs["DP-2"][..2], ["left", "portrait"]);
        assert_eq!(rs["HDMI-A-1"][0], "right");
        assert_eq!(
            ds[1].identity(),
            "Samsung Electric Company Odyssey G95NC H1AK500000"
        );
    }

    #[test]
    fn role_names() {
        for r in ["main", "left", "right-2", "bottom-3"] {
            assert!(is_positional(r), "{r}");
        }
        for r in ["left-1", "left-x", "portrait", "display-1", "*", "lefty"] {
            assert!(!is_positional(r), "{r}");
        }
        for r in [
            "portrait",
            "ultrawide",
            "landscape",
            "display-3",
            "*",
            "top",
        ] {
            assert!(is_known_role(r), "{r}");
        }
        for r in ["display-0", "middle", ""] {
            assert!(!is_known_role(r), "{r}");
        }
    }

    pub fn desk() -> Vec<Display> {
        let case = &fixture_cases()[0];
        serde_json::from_value(case["layout"]["outputs"].clone()).unwrap()
    }

    fn placed(r: &Resolution) -> Vec<(String, Option<String>)> {
        r.placements
            .iter()
            .map(|p| (p.display.name.clone(), p.workspace.clone()))
            .collect()
    }

    #[test]
    fn spaces_resolve_on_cody_s_desk() {
        let cat = super::super::model::tests::catalog();
        let ds = desk(); // DP-5 left portrait, DP-4 main ultrawide, DP-3 right
        let r = resolve(cat.find("music").unwrap(), &ds, None);
        assert_eq!(
            placed(&r),
            [
                ("DP-4".into(), Some("music".into())),
                ("DP-5".into(), None),
                ("DP-3".into(), Some("music/right".into()))
            ]
        );
        assert_eq!(r.placements[1].role.as_deref(), Some("left"));
        assert!(r.folded.is_empty());
        let r = resolve(cat.find("comms").unwrap(), &ds, None);
        assert_eq!(r.workspace_on("DP-5"), Some("comms"));
        assert_eq!(r.workspace_on("DP-3"), None, "unbound right: keep");
        let r = resolve(cat.find("proj-loft").unwrap(), &ds, None);
        assert_eq!(r.workspace_on("DP-5"), Some("loft/left"));
        assert_eq!(r.display_of("LOFT/right").unwrap().name, "DP-3");
    }

    #[test]
    fn missing_displays_fold() {
        let cat = super::super::model::tests::catalog();
        let laptop = vec![Display {
            name: "eDP-1".into(),
            identity: "BOE 0x0BCA Unknown".into(),
            x: 0,
            y: 0,
            width: 1920,
            height: 1200,
        }];
        let r = resolve(cat.find("proj-loft").unwrap(), &laptop, None);
        assert_eq!(placed(&r), [("eDP-1".into(), Some("loft".into()))]);
        let f: Vec<_> = r
            .folded
            .iter()
            .map(|f| (f.role.as_str(), f.workspace.as_str(), f.fold))
            .collect();
        assert_eq!(
            f,
            [
                ("left", "loft/left", Fold::Stack),
                ("right", "loft/right", Fold::Stack)
            ]
        );
        assert_eq!(r.display_of("loft/right").unwrap().name, "eDP-1");

        // A portrait-only binding isn't folded when a display has the role
        // but took a more specific binding.
        let mut s = cat.find("task").unwrap().clone();
        s.displays.insert(
            "portrait".into(),
            Binding::Bound(super::super::model::Bound {
                workspace: "tall".into(),
                apps: vec![],
                layout: None,
            }),
        );
        let r = resolve(&s, &desk(), None);
        assert_eq!(r.workspace_on("DP-5"), Some("notes"));
        assert!(r.folded.is_empty());
        assert!(resolve(&s, &[], None).placements.is_empty());
    }
}
