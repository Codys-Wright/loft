//! Every keybind in the active niri config tree, with where it comes from and
//! whether a later definition overrides it (niri: a later `binds` section
//! replaces earlier binds of the same key).

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::config::ConfigTree;

#[derive(Debug, Clone, Serialize)]
pub struct Bind {
    /// As written in the config.
    pub key: String,
    /// Normalized: canonical modifier names and order (`Mod+Shift+T`).
    pub combo: String,
    pub modifiers: Vec<String>,
    pub trigger: String,
    /// The action node name (`spawn`, `focus-column-left`, …).
    pub action: String,
    pub args: Vec<Value>,
    pub action_props: Map<String, Value>,
    /// `spawn "foot" "-e" "htop"` — the action as KDL.
    pub action_text: String,
    /// `hotkey-overlay-title` (null when hidden with `=null`, absent when unset).
    pub title: Option<Value>,
    /// Other bind properties: repeat, cooldown-ms, allow-when-locked, …
    pub props: Map<String, Value>,
    pub file: String,
    pub line: usize,
    pub shadowed: bool,
    /// `file:line` of the definition that wins, when shadowed.
    pub shadowed_by: Option<String>,
}

const MODS: &[(&[&str], &str)] = &[
    (&["mod"], "Mod"),
    (&["super", "win"], "Super"),
    (&["ctrl", "control"], "Ctrl"),
    (&["alt"], "Alt"),
    (&["shift"], "Shift"),
    (&["iso_level3_shift", "mod5"], "ISO_Level3_Shift"),
    (&["iso_level5_shift", "mod3"], "ISO_Level5_Shift"),
];

const TRIGGERS: &[&str] = &[
    "MouseLeft",
    "MouseRight",
    "MouseMiddle",
    "MouseBack",
    "MouseForward",
    "WheelScrollDown",
    "WheelScrollUp",
    "WheelScrollLeft",
    "WheelScrollRight",
    "TouchpadScrollDown",
    "TouchpadScrollUp",
    "TouchpadScrollLeft",
    "TouchpadScrollRight",
];

/// (modifiers in canonical order, trigger) — niri matches modifiers as a set
/// and key names case-insensitively.
pub fn normalize(key: &str) -> (Vec<String>, String) {
    let mut parts: Vec<&str> = key.split('+').collect();
    let trigger = parts.pop().unwrap_or("").trim();
    let mut mods: Vec<&str> = Vec::new();
    for p in parts {
        let p = p.trim().to_ascii_lowercase();
        match MODS.iter().find(|(names, _)| names.contains(&p.as_str())) {
            Some((_, canon)) => {
                if !mods.contains(canon) {
                    mods.push(canon);
                }
            }
            None => mods.push("?"),
        }
    }
    mods.sort_by_key(|m| MODS.iter().position(|(_, c)| c == m).unwrap_or(usize::MAX));
    let trigger = if let Some(t) = TRIGGERS.iter().find(|t| t.eq_ignore_ascii_case(trigger)) {
        t.to_string()
    } else if trigger.chars().count() == 1 {
        trigger.to_uppercase()
    } else if trigger.chars().all(|c| !c.is_uppercase()) {
        // `slash` and `Slash` are the same keysym; show it capitalized.
        let mut c = trigger.chars();
        c.next()
            .map(|f| f.to_uppercase().chain(c).collect())
            .unwrap_or_default()
    } else {
        trigger.to_string()
    };
    (mods.into_iter().map(String::from).collect(), trigger)
}

fn kdl_json(v: &kdl::KdlValue) -> Value {
    match v {
        kdl::KdlValue::String(s) => json!(s),
        kdl::KdlValue::Integer(i) => json!(*i as i64),
        kdl::KdlValue::Float(f) => json!(f),
        kdl::KdlValue::Bool(b) => json!(b),
        kdl::KdlValue::Null => Value::Null,
    }
}

fn action_text(name: &str, args: &[Value], props: &Map<String, Value>) -> String {
    let mut s = name.to_string();
    for a in args {
        s.push(' ');
        s.push_str(&a.to_string());
    }
    for (k, v) in props {
        s.push_str(&format!(" {k}={v}"));
    }
    s
}

pub fn collect(tree: &ConfigTree) -> Vec<Bind> {
    let mut binds = Vec::new();
    for section in tree.find_all(&["binds"]) {
        for n in section.node.iter_children() {
            let key = n.name().value().to_string();
            let (modifiers, trigger) = normalize(&key);
            let combo = modifiers
                .iter()
                .cloned()
                .chain(std::iter::once(trigger.clone()))
                .collect::<Vec<_>>()
                .join("+");
            let mut props = Map::new();
            let mut title = None;
            for e in n.entries() {
                match e.name().map(|k| k.value()) {
                    Some("hotkey-overlay-title") => title = Some(kdl_json(e.value())),
                    Some(k) => {
                        props.insert(k.to_string(), kdl_json(e.value()));
                    }
                    None => {}
                }
            }
            let (action, args, action_props) = match n.iter_children().next() {
                Some(a) => {
                    let mut args = Vec::new();
                    let mut ap = Map::new();
                    for e in a.entries() {
                        match e.name() {
                            Some(k) => {
                                ap.insert(k.value().to_string(), kdl_json(e.value()));
                            }
                            None => args.push(kdl_json(e.value())),
                        }
                    }
                    (a.name().value().to_string(), args, ap)
                }
                None => (String::new(), Vec::new(), Map::new()),
            };
            binds.push(Bind {
                action_text: action_text(&action, &args, &action_props),
                key,
                combo,
                modifiers,
                trigger,
                action,
                args,
                action_props,
                title,
                props,
                file: section.file.path.display().to_string(),
                line: section.file.line_of(n),
                shadowed: false,
                shadowed_by: None,
            });
        }
    }
    // The last definition of a key wins.
    let mut last: BTreeMap<String, usize> = BTreeMap::new();
    for (i, b) in binds.iter().enumerate() {
        last.insert(b.combo.to_lowercase(), i);
    }
    for i in 0..binds.len() {
        let w = last[&binds[i].combo.to_lowercase()];
        if w != i {
            let by = format!("{}:{}", binds[w].file, binds[w].line);
            binds[i].shadowed = true;
            binds[i].shadowed_by = Some(by);
        }
    }
    binds
}

/// Keys bound more than once: combo → indices into `binds`, in order.
pub fn conflicts(binds: &[Bind]) -> BTreeMap<String, Vec<usize>> {
    let mut by: BTreeMap<String, (String, Vec<usize>)> = BTreeMap::new();
    for (i, b) in binds.iter().enumerate() {
        by.entry(b.combo.to_lowercase())
            .or_insert_with(|| (b.combo.clone(), Vec::new()))
            .1
            .push(i);
    }
    by.into_values().filter(|(_, v)| v.len() > 1).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::tests_support::scratch;

    #[test]
    fn normalizes_modifiers() {
        assert_eq!(
            normalize("shift+Mod+t"),
            (vec!["Mod".into(), "Shift".into()], "T".into())
        );
        assert_eq!(
            normalize("Control+Alt+Delete"),
            (vec!["Ctrl".into(), "Alt".into()], "Delete".into())
        );
        assert_eq!(normalize("Mod+wheelscrolldown").1, "WheelScrollDown");
        assert_eq!(
            normalize("XF86AudioRaiseVolume"),
            (vec![], "XF86AudioRaiseVolume".into())
        );
    }

    #[test]
    fn lists_binds_across_includes_with_shadowing() {
        let d = scratch("binds");
        std::fs::create_dir_all(d.join("parts")).unwrap();
        std::fs::write(
            d.join("config.kdl"),
            r#"// entry
include "parts/base.kdl"
binds {
    Mod+T hotkey-overlay-title="Terminal" { spawn "foot"; }
    Mod+Shift+Slash { show-hotkey-overlay; }
}
include optional=true "parts/missing.kdl"
include "parts/late.kdl"
"#,
        )
        .unwrap();
        std::fs::write(
            d.join("parts/base.kdl"),
            r#"binds {
    Mod+T { spawn "alacritty"; }
    Mod+Q repeat=false { close-window; }
    XF86AudioRaiseVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.05+"; }
}
"#,
        )
        .unwrap();
        std::fs::write(
            d.join("parts/late.kdl"),
            "binds {\n    shift+mod+slash hotkey-overlay-title=null { spawn \"help\"; }\n}\n",
        )
        .unwrap();
        let tree = ConfigTree::load(&d.join("config.kdl"), &|_| false).unwrap();
        assert!(tree.errors.is_empty(), "{:?}", tree.errors);
        let b = collect(&tree);
        let summary: Vec<_> = b
            .iter()
            .map(|b| (b.combo.as_str(), b.action.as_str(), b.line, b.shadowed))
            .collect();
        assert_eq!(
            summary,
            vec![
                ("Mod+T", "spawn", 2, true),
                ("Mod+Q", "close-window", 3, false),
                ("XF86AudioRaiseVolume", "spawn", 4, false),
                ("Mod+T", "spawn", 4, false),
                ("Mod+Shift+Slash", "show-hotkey-overlay", 5, true),
                ("Mod+Shift+Slash", "spawn", 2, false),
            ]
        );
        assert!(b[0].file.ends_with("parts/base.kdl"));
        assert!(
            b[0].shadowed_by
                .as_deref()
                .unwrap()
                .ends_with("config.kdl:4")
        );
        assert_eq!(b[3].title, Some(json!("Terminal")));
        assert_eq!(b[5].title, Some(Value::Null));
        assert_eq!(b[1].props["repeat"], json!(false));
        assert_eq!(
            b[2].action_text,
            r#"spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.05+""#
        );
        let c = conflicts(&b);
        assert_eq!(c.len(), 2);
        assert_eq!(c["Mod+T"], vec![0, 3]);
        assert_eq!(c["Mod+Shift+Slash"], vec![4, 5]);
    }
}
