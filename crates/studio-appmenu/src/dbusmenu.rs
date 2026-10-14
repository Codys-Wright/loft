//! com.canonical.dbusmenu: what Qt (QDBusMenuBar), appmenu-gtk-module and
//! Electron/Chromium (X11) export. Spec: libdbusmenu's com.canonical.dbusmenu.xml.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};
use zbus::Connection;
use zbus::zvariant::{OwnedValue, Type, Value};

use crate::protocol::{MenuItem, Toggle, normalize_chord, tidy_separators};
use crate::raw::Prop;

pub const IFACE: &str = "com.canonical.dbusmenu";

/// One layout node: (ia{sv}av).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RawNode {
    pub id: i32,
    #[serde(default)]
    pub props: BTreeMap<String, Prop>,
    #[serde(default)]
    pub children: Vec<RawNode>,
}

#[derive(Debug, Deserialize, Type)]
struct Layout(i32, HashMap<String, OwnedValue>, Vec<OwnedValue>);

impl RawNode {
    fn from_layout(l: &Layout) -> RawNode {
        RawNode {
            id: l.0,
            props: l
                .1
                .iter()
                .filter_map(|(k, v)| Some((k.clone(), Prop::from_value(v)?)))
                .collect(),
            children: l.2.iter().filter_map(|c| RawNode::from_value(c)).collect(),
        }
    }

    /// A child entry of `av`: a variant holding (ia{sv}av).
    pub fn from_value(v: &Value<'_>) -> Option<RawNode> {
        match v {
            Value::Value(inner) => RawNode::from_value(inner),
            Value::Structure(s) => {
                let [Value::I32(id), Value::Dict(props), Value::Array(children)] = s.fields()
                else {
                    return None;
                };
                Some(RawNode {
                    id: *id,
                    props: props
                        .iter()
                        .filter_map(|(k, v)| {
                            let Value::Str(k) = k else { return None };
                            Some((k.to_string(), Prop::from_value(v)?))
                        })
                        .collect(),
                    children: children.iter().filter_map(RawNode::from_value).collect(),
                })
            }
            _ => None,
        }
    }
}

/// The root's children (File, Edit, …) as shell items.
pub fn to_items(root: &RawNode) -> Vec<MenuItem> {
    tidy_separators(root.children.iter().filter_map(convert).collect())
}

fn convert(node: &RawNode) -> Option<MenuItem> {
    let p = &node.props;
    if p.get("visible").and_then(Prop::as_bool) == Some(false) {
        return None;
    }
    if p.get("type").and_then(Prop::as_str) == Some("separator") {
        return Some(MenuItem::separator(node.id));
    }
    let mut item = MenuItem::labelled(node.id, p.get("label").and_then(Prop::as_str).unwrap_or(""));
    item.enabled = p.get("enabled").and_then(Prop::as_bool).unwrap_or(true);
    item.toggle = match p.get("toggle-type").and_then(Prop::as_str) {
        Some("checkmark") => Some(Toggle::Check),
        Some("radio") => Some(Toggle::Radio),
        _ => None,
    };
    item.checked = item.toggle.is_some() && p.get("toggle-state").and_then(Prop::as_int) == Some(1);
    if let Some(Prop::Keys(chords)) = p.get("shortcut") {
        item.shortcut = chords
            .iter()
            .filter(|c| !c.is_empty())
            .map(|c| normalize_chord(c))
            .collect();
    }
    item.icon = p
        .get("icon-name")
        .and_then(Prop::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from);
    item.children = tidy_separators(node.children.iter().filter_map(convert).collect());
    item.submenu = p.get("children-display").and_then(Prop::as_str) == Some("submenu")
        || !item.children.is_empty();
    Some(item)
}

// ── Bus calls ───────────────────────────────────────────────────────────

pub async fn get_layout(conn: &Connection, service: &str, path: &str) -> zbus::Result<RawNode> {
    let reply = conn
        .call_method(
            Some(service),
            path,
            Some(IFACE),
            "GetLayout",
            &(0i32, -1i32, Vec::<&str>::new()),
        )
        .await?;
    let (_revision, layout): (u32, Layout) = reply.body().deserialize()?;
    Ok(RawNode::from_layout(&layout))
}

pub async fn event(
    conn: &Connection,
    service: &str,
    path: &str,
    id: i32,
    kind: &str,
) -> zbus::Result<()> {
    conn.call_method(
        Some(service),
        path,
        Some(IFACE),
        "Event",
        &(id, kind, Value::from(0i32), 0u32),
    )
    .await
    .map(|_| ())
}

pub async fn about_to_show(
    conn: &Connection,
    service: &str,
    path: &str,
    id: i32,
) -> zbus::Result<bool> {
    let reply = conn
        .call_method(Some(service), path, Some(IFACE), "AboutToShow", &(id,))
        .await?;
    reply.body().deserialize()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> RawNode {
        serde_json::from_str(include_str!("../tests/fixtures/dbusmenu-qt.json")).unwrap()
    }

    #[test]
    fn parses_qt_layout() {
        let items = to_items(&fixture());
        let titles: Vec<_> = items.iter().map(|i| i.label.as_str()).collect();
        assert_eq!(titles, ["File", "Edit", "View", "Help"]);
        assert!(items.iter().all(|i| i.submenu));
        assert_eq!(items[0].mnemonic.as_deref(), Some("F"));

        let file = &items[0].children;
        // Hidden "Print Preview" dropped; the leading separator too.
        let labels: Vec<_> = file
            .iter()
            .map(|i| if i.separator { "-" } else { i.label.as_str() })
            .collect();
        assert_eq!(
            labels,
            [
                "New",
                "Open…",
                "Open Recent",
                "-",
                "Save",
                "Save As…",
                "-",
                "Quit"
            ]
        );
        assert_eq!(
            file[0].shortcut,
            vec![vec!["Control".to_string(), "N".into()]]
        );
        assert_eq!(file[0].icon.as_deref(), Some("document-new"));
        assert!(file[2].submenu, "lazy submenu without children yet");
        assert!(file[2].children.is_empty());
        assert!(!file[4].enabled, "Save disabled");

        let view = &items[2].children;
        assert_eq!(view[0].toggle, Some(Toggle::Check));
        assert!(view[0].checked);
        assert_eq!(view[1].toggle, Some(Toggle::Check));
        assert!(!view[1].checked);
        let modes = &view[2].children;
        assert_eq!(
            modes
                .iter()
                .map(|m| (m.toggle, m.checked))
                .collect::<Vec<_>>(),
            [(Some(Toggle::Radio), false), (Some(Toggle::Radio), true)]
        );
        // "Ctrl" normalized.
        assert_eq!(
            items[1].children[0].shortcut,
            vec![vec!["Control".to_string(), "Z".into()]]
        );
    }

    #[test]
    fn converts_bus_structures() {
        use zbus::zvariant::{Array, Dict, Signature, StructureBuilder};
        let mut props = Dict::new(&Signature::Str, &Signature::Variant);
        props
            .append(
                Value::from("label"),
                Value::Value(Box::new(Value::from("_Quit"))),
            )
            .unwrap();
        let child = StructureBuilder::new()
            .add_field(5i32)
            .append_field(Value::Dict(props))
            .append_field(Value::Array(Array::new(&Signature::Variant)))
            .build()
            .unwrap();
        let node = RawNode::from_value(&Value::Value(Box::new(Value::Structure(child)))).unwrap();
        assert_eq!(node.id, 5);
        assert_eq!(node.props["label"], Prop::Str("_Quit".into()));
        let item = convert(&node).unwrap();
        assert_eq!(
            (item.label.as_str(), item.mnemonic.as_deref()),
            ("Quit", Some("Q"))
        );
    }
}
