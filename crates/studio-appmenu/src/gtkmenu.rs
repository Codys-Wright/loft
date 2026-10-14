//! org.gtk.Menus + org.gtk.Actions: the menubar a GtkApplication exports at
//! `<app path>/menus/menubar` (gtk_application_set_menubar), with `app.*`
//! actions at `<app path>` and `win.*` actions at `<app path>/window/<n>`.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};
use zbus::Connection;
use zbus::zvariant::{OwnedValue, Signature, Value};

use crate::protocol::{MenuItem, Toggle, gtk_accel, tidy_separators};
use crate::raw::Prop;

pub const MENUS: &str = "org.gtk.Menus";
pub const ACTIONS: &str = "org.gtk.Actions";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RawMenu {
    pub group: u32,
    pub menu: u32,
    pub items: Vec<BTreeMap<String, Prop>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RawAction {
    pub enabled: bool,
    #[serde(default)]
    pub state: Option<Prop>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct RawGtk {
    pub menus: Vec<RawMenu>,
    /// "app.quit", "win.close", …
    pub actions: BTreeMap<String, RawAction>,
}

/// What clicking an item does: Activate(name, [target]) on its group.
#[derive(Debug, Clone, PartialEq)]
pub struct Activation {
    /// "app" or "win".
    pub group: String,
    pub name: String,
    pub target: Option<Prop>,
}

#[derive(Debug, Default)]
pub struct Built {
    pub items: Vec<MenuItem>,
    pub activations: HashMap<i32, Activation>,
}

pub fn build(raw: &RawGtk) -> Built {
    let menus: HashMap<(u32, u32), &RawMenu> =
        raw.menus.iter().map(|m| ((m.group, m.menu), m)).collect();
    let mut b = Builder {
        menus,
        actions: &raw.actions,
        next_id: 1,
        out: Built::default(),
        depth: 0,
    };
    let items = b.menu((0, 0));
    b.out.items = items;
    b.out
}

struct Builder<'a> {
    menus: HashMap<(u32, u32), &'a RawMenu>,
    actions: &'a BTreeMap<String, RawAction>,
    next_id: i32,
    out: Built,
    depth: u32,
}

impl Builder<'_> {
    fn id(&mut self) -> i32 {
        self.next_id += 1;
        self.next_id - 1
    }

    fn menu(&mut self, key: (u32, u32)) -> Vec<MenuItem> {
        // Links can't be cyclic in GMenu, but don't trust the bus.
        if self.depth > 16 {
            return Vec::new();
        }
        self.depth += 1;
        let mut items = Vec::new();
        let entries = self
            .menus
            .get(&key)
            .map(|m| m.items.clone())
            .unwrap_or_default();
        for attrs in &entries {
            if let Some(section) = attrs.get(":section").and_then(Prop::as_pair) {
                let sep = self.id();
                items.push(MenuItem::separator(sep));
                let mut inner = self.menu(section);
                // A labelled section gets its label as a disabled header.
                if let Some(label) = attrs.get("label").and_then(Prop::as_str) {
                    let mut header = MenuItem::labelled(self.id(), label);
                    header.enabled = false;
                    inner.insert(0, header);
                }
                items.extend(inner);
                let sep = self.id();
                items.push(MenuItem::separator(sep));
            } else if let Some(sub) = attrs.get(":submenu").and_then(Prop::as_pair) {
                let mut item = MenuItem::labelled(
                    self.id(),
                    attrs.get("label").and_then(Prop::as_str).unwrap_or(""),
                );
                item.submenu = true;
                item.children = self.menu(sub);
                items.push(item);
            } else if let Some(item) = self.action_item(attrs) {
                items.push(item);
            }
        }
        self.depth -= 1;
        tidy_separators(items)
    }

    fn action_item(&mut self, attrs: &BTreeMap<String, Prop>) -> Option<MenuItem> {
        let action = attrs.get("action").and_then(Prop::as_str);
        let state = action.and_then(|a| self.actions.get(a));
        match attrs.get("hidden-when").and_then(Prop::as_str) {
            Some("action-missing") if state.is_none() => return None,
            Some("action-disabled") if !state.is_some_and(|s| s.enabled) => return None,
            _ => {}
        }
        let id = self.id();
        let mut item =
            MenuItem::labelled(id, attrs.get("label").and_then(Prop::as_str).unwrap_or(""));
        let target = attrs.get("target").cloned();
        let split = action.and_then(|a| a.split_once('.'));
        // Unknown action groups can't be activated.
        item.enabled =
            split.is_some_and(|(g, _)| g == "app" || g == "win") && state.is_none_or(|s| s.enabled);
        match (state.and_then(|s| s.state.as_ref()), &target) {
            (Some(Prop::Bool(on)), None) => {
                item.toggle = Some(Toggle::Check);
                item.checked = *on;
            }
            (Some(current), Some(t)) => {
                item.toggle = Some(Toggle::Radio);
                item.checked = current == t;
            }
            _ => {}
        }
        if let Some(accel) = attrs.get("accel").and_then(Prop::as_str) {
            let chord = gtk_accel(accel);
            if !chord.is_empty() {
                item.shortcut = vec![chord];
            }
        }
        if let Some((group, name)) = split {
            self.out.activations.insert(
                id,
                Activation {
                    group: group.to_string(),
                    name: name.to_string(),
                    target,
                },
            );
        }
        Some(item)
    }
}

/// Group ids referenced by loaded menus but not yet loaded.
pub fn missing_groups(menus: &[RawMenu]) -> Vec<u32> {
    let loaded: std::collections::HashSet<u32> = menus.iter().map(|m| m.group).collect();
    let mut want: Vec<u32> = menus
        .iter()
        .flat_map(|m| m.items.iter())
        .flat_map(|a| [a.get(":section"), a.get(":submenu")])
        .flatten()
        .filter_map(Prop::as_pair)
        .map(|(g, _)| g)
        .filter(|g| !loaded.contains(g))
        .collect();
    want.sort_unstable();
    want.dedup();
    want
}

// ── Bus calls ───────────────────────────────────────────────────────────

type StartReply = Vec<(u32, u32, Vec<HashMap<String, OwnedValue>>)>;

/// Subscribes to the menubar's groups (Start), following links. Returns
/// the menus and the groups to End later.
pub async fn load_menus(
    conn: &Connection,
    service: &str,
    menubar_path: &str,
) -> zbus::Result<(Vec<RawMenu>, Vec<u32>)> {
    let mut menus = Vec::new();
    let mut started = Vec::new();
    let mut want = vec![0u32];
    for _ in 0..12 {
        if want.is_empty() {
            break;
        }
        let reply = conn
            .call_method(
                Some(service),
                menubar_path,
                Some(MENUS),
                "Start",
                &(want.clone(),),
            )
            .await?;
        started.extend(want.iter().copied());
        let groups: StartReply = reply.body().deserialize()?;
        for (group, menu, items) in groups {
            menus.push(RawMenu {
                group,
                menu,
                items: items
                    .iter()
                    .map(|attrs| {
                        attrs
                            .iter()
                            .filter_map(|(k, v)| Some((k.clone(), Prop::from_value(v)?)))
                            .collect()
                    })
                    .collect(),
            });
        }
        want = missing_groups(&menus)
            .into_iter()
            .filter(|g| !started.contains(g))
            .collect();
    }
    Ok((menus, started))
}

pub async fn end(conn: &Connection, service: &str, menubar_path: &str, groups: Vec<u32>) {
    let _ = conn
        .call_method(Some(service), menubar_path, Some(MENUS), "End", &(groups,))
        .await;
}

/// DescribeAll on one action group, keyed "<prefix>.<name>".
pub async fn describe_all(
    conn: &Connection,
    service: &str,
    path: &str,
    prefix: &str,
) -> zbus::Result<BTreeMap<String, RawAction>> {
    let reply = conn
        .call_method(Some(service), path, Some(ACTIONS), "DescribeAll", &())
        .await?;
    let all: HashMap<String, (bool, Signature, Vec<OwnedValue>)> = reply.body().deserialize()?;
    Ok(all
        .into_iter()
        .map(|(name, (enabled, _sig, state))| {
            let state = state.first().and_then(|v| Prop::from_value(v));
            (format!("{prefix}.{name}"), RawAction { enabled, state })
        })
        .collect())
}

pub async fn activate(
    conn: &Connection,
    service: &str,
    path: &str,
    name: &str,
    target: Option<&Prop>,
) -> zbus::Result<()> {
    let params: Vec<Value<'_>> = target.and_then(Prop::to_value).into_iter().collect();
    let platform: HashMap<&str, Value<'_>> = HashMap::new();
    conn.call_method(
        Some(service),
        path,
        Some(ACTIONS),
        "Activate",
        &(name, params, platform),
    )
    .await
    .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> RawGtk {
        serde_json::from_str(include_str!("../tests/fixtures/gtk-menus.json")).unwrap()
    }

    #[test]
    fn builds_menubar() {
        let built = build(&fixture());
        let titles: Vec<_> = built.items.iter().map(|i| i.label.as_str()).collect();
        assert_eq!(titles, ["File", "View"]);
        assert!(built.items.iter().all(|i| i.submenu));

        let file = &built.items[0].children;
        let labels: Vec<_> = file
            .iter()
            .map(|i| if i.separator { "-" } else { i.label.as_str() })
            .collect();
        // Sections become separators; "Print" (hidden-when action-missing) is dropped.
        assert_eq!(labels, ["New Window", "Open…", "-", "Close", "Quit"]);
        assert_eq!(
            file[0].shortcut,
            vec![vec!["Control".to_string(), "N".into()]]
        );
        assert!(!file[1].enabled, "win.open disabled");

        let quit = &file[4];
        let act = &built.activations[&quit.id];
        assert_eq!(
            (act.group.as_str(), act.name.as_str(), act.target.as_ref()),
            ("app", "quit", None)
        );

        let view = &built.items[1].children;
        assert_eq!(
            (view[0].label.as_str(), view[0].toggle, view[0].checked),
            ("Word Wrap", Some(Toggle::Check), true)
        );
        let theme = &view[1];
        assert!(theme.submenu);
        let radios: Vec<_> = theme
            .children
            .iter()
            .map(|i| (i.label.as_str(), i.toggle, i.checked))
            .collect();
        assert_eq!(
            radios,
            [
                ("Light", Some(Toggle::Radio), false),
                ("Dark", Some(Toggle::Radio), true)
            ]
        );
        let dark = &built.activations[&theme.children[1].id];
        assert_eq!(dark.target, Some(Prop::Str("dark".into())));
    }

    #[test]
    fn finds_missing_groups() {
        let raw = fixture();
        assert!(missing_groups(&raw.menus).is_empty());
        let only_root: Vec<_> = raw.menus.iter().filter(|m| m.group == 0).cloned().collect();
        assert_eq!(missing_groups(&only_root), vec![1, 2]);
    }
}
