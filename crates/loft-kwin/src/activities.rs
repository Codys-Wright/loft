//! Spaces are the user's KDE Activities (docs/KWIN.md §4.2). KDE stays the
//! source of truth: this module only **reads** kactivitymanagerd and never
//! creates, renames, re-icons or removes an Activity.
//!
//! The shell asks with `{"cmd":"activities"}` and gets one line back:
//!
//! ```json
//! {"Activities": {"activities": [{"id": "…uuid…", "name": "Default", "icon": "activities",
//!                                 "key": "Meta+1", "position": 1}, …],
//!                 "current": "…uuid…", "error": null}}
//! ```
//!
//! in a stable order: the Activities with a KDE "Switch to activity" shortcut
//! on a digit first, by that digit (1…9, then 0), then the rest in
//! kactivitymanagerd's own order (`order`, pure and unit-tested). The same
//! line is sent again whenever kactivitymanagerd says something changed
//! (an Activity added, removed, renamed, re-iconed, the current one) or
//! kglobalaccel's shortcuts changed (`watch`).
//!
//! Older Loft builds made Activities to match Loft's Space library and kept a
//! `space id → activity` map in `<state>/kwin-activities.json`. Nothing writes
//! that file any more; `loft-kwin spaces prune` still undoes what it records
//! (removes the Activities Loft created, gives an adopted one its old name and
//! icon back) and touches nothing else.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zbus::zvariant::ObjectPath;
use zbus::{Connection, MatchRule, MessageStream, Proxy};

const SERVICE: &str = "org.kde.ActivityManager";
const PATH: &str = "/ActivityManager/Activities";
const IFACE: &str = "org.kde.ActivityManager.Activities";
const MAP_FILE: &str = "kwin-activities.json";
/// kglobalaccel's component for kactivitymanagerd's shortcuts, and the
/// action name of "Switch to activity …" (kactivitymanagerd's
/// `switch-to-activity-<uuid>`).
const KGA: &str = "org.kde.kglobalaccel";
const KGA_COMPONENT: &str = "/component/ActivityManager";
const SWITCH_PREFIX: &str = "switch-to-activity-";

/// An Activity as kactivitymanagerd reports it, with its KDE shortcut.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Activity {
    pub id: String,
    pub name: String,
    pub icon: String,
    /// "Switch to activity" key, QKeySequence text ("Meta+1"), "" without one.
    pub key: String,
    /// The digit of that key (1…9, 0), if it is on one: `spaces focus N`.
    pub position: Option<u32>,
}

// ── Order ────────────────────────────────────────────────────────────────

const META: i32 = 0x1000_0000;
const SHIFT: i32 = 0x0200_0000;
const CTRL: i32 = 0x0400_0000;
const ALT: i32 = 0x0800_0000;
const KEYPAD: i32 = 0x2000_0000;
const MODS: i32 = META | SHIFT | CTRL | ALT | KEYPAD;

/// A Qt key combination (one int: modifiers | key) as QKeySequence's
/// portable text, for the keys this cares about; "" for the rest.
pub fn key_text(k: i32) -> String {
    let base = k & !MODS;
    let key = match base {
        0x30..=0x39 | 0x41..=0x5a => char::from_u32(base as u32).map(String::from),
        0x2d => Some("-".into()),
        0x3d => Some("=".into()),
        0x0100_0030..=0x0100_0052 => Some(format!("F{}", base - 0x0100_0030 + 1)),
        _ => None,
    };
    let Some(key) = key else {
        return String::new();
    };
    let mut parts: Vec<String> = [(META, "Meta"), (CTRL, "Ctrl"), (ALT, "Alt"), (SHIFT, "Shift")]
        .iter()
        .filter(|(m, _)| k & m != 0)
        .map(|(_, n)| n.to_string())
        .collect();
    parts.push(key);
    parts.join("+")
}

/// The digit of a key combination (Meta+1 → 1), if its key is one.
fn digit(k: i32) -> Option<u32> {
    let base = k & !MODS;
    (0x30..=0x39).contains(&base).then(|| (base - 0x30) as u32)
}

/// Sort rank of a digit: 1…9 first, then 0 (as on the keyboard).
fn rank(d: u32) -> u32 {
    if d == 0 { 10 } else { d }
}

/// The Activities in Loft's order: those whose "Switch to activity" shortcut
/// is on a digit by that digit (1…9, then 0; Meta+… preferred when an action
/// has several keys), then the rest in kactivitymanagerd's order. `keys`:
/// activity id → its shortcut's key combinations (Qt ints).
pub fn order(listed: Vec<(String, String, String)>, keys: &HashMap<String, Vec<i32>>) -> Vec<Activity> {
    let mut out: Vec<(u32, usize, Activity)> = listed
        .into_iter()
        .enumerate()
        .map(|(i, (id, name, icon))| {
            let ks = keys.get(&id).cloned().unwrap_or_default();
            // A digit key, Meta ones first; else the first key there is.
            let best = ks
                .iter()
                .copied()
                .filter(|k| digit(*k).is_some())
                .min_by_key(|k| (k & META == 0, rank(digit(*k).unwrap_or(0))))
                .or_else(|| ks.first().copied());
            let position = best.and_then(digit);
            let key = best.map(key_text).unwrap_or_default();
            let sort = position.map(rank).unwrap_or(u32::MAX);
            (sort, i, Activity { id, name, icon, key, position })
        })
        .collect();
    out.sort_by_key(|(sort, i, _)| (*sort, *i));
    // Two Activities can't both be ⌘N: the later one keeps its key but loses
    // the position (KDE would only fire one of them anyway).
    let mut seen = Vec::new();
    for (_, _, a) in out.iter_mut() {
        if let Some(p) = a.position {
            if seen.contains(&p) {
                a.position = None;
            } else {
                seen.push(p);
            }
        }
    }
    out.into_iter().map(|(_, _, a)| a).collect()
}

/// Every Qt key int in a D-Bus value: `ai` (one int per combination) or
/// `a(ai)` / `a(aiaiaiai)` (a key sequence per entry: its first key).
fn key_ints(v: &zbus::zvariant::Value<'_>) -> Vec<i32> {
    use zbus::zvariant::Value as V;
    fn first(v: &V<'_>) -> Option<i32> {
        match v {
            V::I32(k) => Some(*k).filter(|k| *k != 0),
            V::U32(k) => Some(*k as i32).filter(|k| *k != 0),
            V::Array(a) => a.iter().find_map(first),
            V::Structure(s) => s.fields().iter().find_map(first),
            V::Value(b) => first(b),
            _ => None,
        }
    }
    match v {
        V::Array(a) => a.iter().filter_map(first).collect(),
        V::Value(b) => key_ints(b),
        other => first(other).into_iter().collect(),
    }
}

/// activity id → the keys of its "Switch to activity" shortcut, from
/// kglobalaccel (empty when it or the component isn't there).
pub async fn switch_keys(conn: &Connection) -> HashMap<String, Vec<i32>> {
    let mut out = HashMap::new();
    let Ok(path) = ObjectPath::try_from(KGA_COMPONENT) else { return out };
    let Ok(p) = Proxy::new(conn, KGA, path, "org.kde.kglobalaccel.Component").await else {
        return out;
    };
    // (action, actionFriendly, component, componentFriendly, context,
    // contextFriendly, keys, defaultKeys) per action.
    let Ok(msg) = p.call_method("allShortcutInfos", &()).await else { return out };
    let body = msg.body();
    let Ok(args) = body.deserialize::<zbus::zvariant::Structure<'_>>() else {
        return out;
    };
    let Some(zbus::zvariant::Value::Array(rows)) = args.fields().first() else { return out };
    for r in rows.iter() {
        let zbus::zvariant::Value::Structure(r) = r else { continue };
        let f = r.fields();
        let Some(zbus::zvariant::Value::Str(action)) = f.first() else { continue };
        let Some(id) = action.as_str().strip_prefix(SWITCH_PREFIX) else { continue };
        if let Some(keys) = f.get(6) {
            out.insert(id.to_string(), key_ints(keys));
        }
    }
    out
}

// ── kactivitymanagerd ────────────────────────────────────────────────────

pub async fn proxy(conn: &Connection) -> Result<Proxy<'static>> {
    Ok(Proxy::new(conn, SERVICE, PATH, IFACE).await?)
}

/// (id, name, icon) in kactivitymanagerd's order, and the current one.
pub async fn list(p: &Proxy<'_>) -> Result<(Vec<(String, String, String)>, String)> {
    let ids: Vec<String> = p
        .call("ListActivities", &())
        .await
        .context("kactivitymanagerd (org.kde.ActivityManager) isn't answering")?;
    let mut out = Vec::new();
    for id in ids {
        let name: String = p.call("ActivityName", &(id.as_str(),)).await.unwrap_or_default();
        let icon: String = p.call("ActivityIcon", &(id.as_str(),)).await.unwrap_or_default();
        out.push((id, name, icon));
    }
    let current: String = p.call("CurrentActivity", &()).await.unwrap_or_default();
    Ok((out, current))
}

/// The shell's `{"Activities": …}` line.
pub async fn report(conn: &Connection) -> Value {
    let got = async {
        let p = proxy(conn).await?;
        list(&p).await
    }
    .await;
    match got {
        Ok((listed, current)) => {
            let keys = switch_keys(conn).await;
            json!({ "Activities": { "activities": order(listed, &keys), "current": current, "error": null } })
        }
        Err(e) => json!({ "Activities": { "activities": [], "current": "", "error": format!("{e:#}") } }),
    }
}

/// Send the report again whenever kactivitymanagerd or kglobalaccel change
/// something (debounced: switching sends a few signals at once), and when
/// kactivitymanagerd (re)starts.
pub async fn watch(conn: Connection, emit: impl Fn(&Value)) {
    let rules = [
        MatchRule::builder().msg_type(zbus::message::Type::Signal).interface(IFACE).map(|b| b.build()),
        MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface("org.kde.KGlobalAccel")
            .and_then(|b| b.member("yourShortcutsChanged"))
            .map(|b| b.build()),
        MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface("org.freedesktop.DBus")
            .and_then(|b| b.member("NameOwnerChanged"))
            .and_then(|b| b.add_arg(SERVICE))
            .map(|b| b.build()),
    ];
    let mut streams = Vec::new();
    for r in rules.into_iter().flatten() {
        match MessageStream::for_match_rule(r, &conn, Some(64)).await {
            Ok(s) => streams.push(s),
            Err(e) => eprintln!("loft-kwin: can't watch activities: {e}"),
        }
    }
    if streams.is_empty() {
        return;
    }
    // The first report, without being asked.
    emit(&report(&conn).await);
    let mut all = futures_util::stream::select_all(streams);
    while all.next().await.is_some() {
        // Let the burst finish, then report once.
        let _ = tokio::time::timeout(Duration::from_millis(150), async {
            while all.next().await.is_some() {}
        })
        .await;
        emit(&report(&conn).await);
    }
}

// ── The old map, for `prune` ─────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Adopted {
    pub name: String,
    #[serde(default)]
    pub icon: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Entry {
    pub activity: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adopted: Option<Adopted>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Map {
    #[serde(default)]
    pub spaces: BTreeMap<String, Entry>,
}

/// What `prune` does to an Activity recorded in the old map.
#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    /// Loft created it: remove it.
    Remove { space: String, activity: String },
    /// A Space adopted the user's Activity: its old name and icon back.
    Restore { space: String, activity: String, prev: Adopted },
}

/// `prune`'s plan: only Activities in the map that still exist; every other
/// Activity is the user's and isn't touched.
pub fn prune_plan(map: &Map, existing: &[String]) -> Vec<Op> {
    map.spaces
        .iter()
        .filter(|(_, e)| existing.contains(&e.activity))
        .map(|(space, e)| match &e.adopted {
            Some(prev) => Op::Restore { space: space.clone(), activity: e.activity.clone(), prev: prev.clone() },
            None => Op::Remove { space: space.clone(), activity: e.activity.clone() },
        })
        .collect()
}

/// Loft's state dir: $LOFT_STATE_DIR, else $XDG_STATE_HOME/loft, else
/// ~/.local/state/loft (as the shell and the CLI).
pub fn state_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("LOFT_STATE_DIR").filter(|d| !d.is_empty()) {
        return d.into();
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"));
    base.join("loft")
}

pub fn map_path(state: &Path) -> PathBuf {
    state.join(MAP_FILE)
}

/// The old map, and whether one exists.
pub fn load(path: &Path) -> (Map, bool) {
    match std::fs::read_to_string(path) {
        Ok(text) => match serde_json::from_str(&text) {
            Ok(m) => (m, true),
            Err(e) => {
                eprintln!("loft-kwin: {}: {e}; ignoring it", path.display());
                (Map::default(), true)
            }
        },
        Err(_) => (Map::default(), false),
    }
}

pub fn save(path: &Path, map: &Map) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(map)? + "\n")?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

async fn apply(p: &Proxy<'_>, map: &mut Map, ops: &[Op]) -> Vec<String> {
    let mut errors = Vec::new();
    for op in ops {
        let r: Result<()> = async {
            match op {
                Op::Remove { space, activity } => {
                    let () = p.call("RemoveActivity", &(activity.as_str(),)).await?;
                    map.spaces.remove(space);
                }
                Op::Restore { space, activity, prev } => {
                    let () = p.call("SetActivityName", &(activity.as_str(), prev.name.as_str())).await?;
                    let () = p.call("SetActivityIcon", &(activity.as_str(), prev.icon.as_str())).await?;
                    map.spaces.remove(space);
                }
            }
            Ok(())
        }
        .await;
        if let Err(e) = r {
            errors.push(format!("{op:?}: {e:#}"));
        }
    }
    errors
}

/// `loft-kwin spaces list` / `prune [--dry-run]`.
pub async fn cli(args: &[String]) -> Result<()> {
    let sub = args.first().map(String::as_str).unwrap_or("list");
    let dry = args.iter().any(|a| a == "--dry-run" || a == "-n");
    let conn = Connection::session().await?;
    let path = map_path(&state_dir());
    let (mut map, existed) = load(&path);
    match sub {
        "list" => {
            let mut r = report(&conn).await;
            if existed {
                r["Activities"]["legacyMap"] = serde_json::to_value(&map)?;
            }
            println!("{}", serde_json::to_string_pretty(&r)?);
        }
        "prune" => {
            if !existed {
                println!("no activities of Loft's (no {})", path.display());
                return Ok(());
            }
            let p = proxy(&conn).await?;
            let (listed, _) = list(&p).await?;
            let existing: Vec<String> = listed.into_iter().map(|(id, _, _)| id).collect();
            let ops = prune_plan(&map, &existing);
            for op in &ops {
                let line = match op {
                    Op::Remove { space, activity } => format!("remove {activity} (made for space {space})"),
                    Op::Restore { space, activity, prev } => {
                        format!("restore {activity} as {:?} (adopted by space {space})", prev.name)
                    }
                };
                println!("{}{line}", if dry { "would " } else { "" });
            }
            if dry {
                return Ok(());
            }
            let errors = apply(&p, &mut map, &ops).await;
            for e in &errors {
                eprintln!("loft-kwin: {e}");
            }
            if !errors.is_empty() {
                // Keep what couldn't be undone for the next try.
                save(&path, &map)?;
                anyhow::bail!("{} activit{} left as they were", errors.len(), if errors.len() == 1 { "y" } else { "ies" });
            }
            std::fs::remove_file(&path).with_context(|| format!("removing {}", path.display()))?;
            if ops.is_empty() {
                println!("no activities of Loft's");
            }
        }
        other => anyhow::bail!("loft-kwin spaces: unknown command {other:?} (list | prune [--dry-run])"),
    }
    Ok(())
}

/// For tests: an owned D-Bus value of Qt keys.
#[cfg(test)]
fn ov<T: Into<zbus::zvariant::Value<'static>>>(v: T) -> zbus::zvariant::OwnedValue {
    zbus::zvariant::OwnedValue::try_from(v.into()).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acts(names: &[&str]) -> Vec<(String, String, String)> {
        names.iter().map(|n| (n.to_lowercase(), n.to_string(), "activities".to_string())).collect()
    }
    fn keys(pairs: &[(&str, i32)]) -> HashMap<String, Vec<i32>> {
        pairs.iter().map(|(id, k)| (id.to_string(), vec![*k])).collect()
    }
    const M: i32 = META;

    #[test]
    fn ordered_by_their_switch_keys_then_kdes_order() {
        // The user's setup: Meta+1…6 and Meta+0, listed by KDE in another order.
        let listed = acts(&["Gaming", "Default", "Ignition", "Coding", "System-Configuration", "Music", "Editing", "Spare"]);
        let k = keys(&[
            ("default", M | 0x31),
            ("music", M | 0x32),
            ("coding", M | 0x33),
            ("gaming", M | 0x34),
            ("editing", M | 0x35),
            ("ignition", M | 0x36),
            ("system-configuration", M | 0x30),
        ]);
        let got = order(listed, &k);
        let names: Vec<&str> = got.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, ["Default", "Music", "Coding", "Gaming", "Editing", "Ignition", "System-Configuration", "Spare"]);
        assert_eq!(got[0].key, "Meta+1");
        assert_eq!(got[0].position, Some(1));
        assert_eq!(got[6].key, "Meta+0");
        assert_eq!(got[6].position, Some(0));
        assert_eq!(got[7].key, "");
        assert_eq!(got[7].position, None);
    }

    #[test]
    fn without_shortcuts_kdes_order_stays() {
        let got = order(acts(&["B", "A", "C"]), &HashMap::new());
        let names: Vec<&str> = got.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, ["B", "A", "C"]);
    }

    #[test]
    fn a_non_digit_key_is_shown_but_doesnt_order() {
        let got = order(acts(&["A", "B"]), &keys(&[("a", M | CTRL | 0x41), ("b", M | 0x32)]));
        assert_eq!(got[0].name, "B");
        assert_eq!(got[1].key, "Meta+Ctrl+A");
        assert_eq!(got[1].position, None);
    }

    #[test]
    fn a_digit_used_twice_keeps_one_position() {
        let got = order(acts(&["A", "B"]), &keys(&[("a", M | 0x31), ("b", M | 0x31)]));
        assert_eq!(got[0].position, Some(1));
        assert_eq!(got[1].position, None);
        assert_eq!(got[1].key, "Meta+1");
    }

    #[test]
    fn key_texts() {
        assert_eq!(key_text(M | 0x31), "Meta+1");
        assert_eq!(key_text(M | SHIFT | 0x5a), "Meta+Shift+Z");
        assert_eq!(key_text(CTRL | (0x0100_0030 + 4)), "Ctrl+F5");
        assert_eq!(key_text(M | 0x0100_0012), "");
    }

    #[test]
    fn keys_from_either_dbus_shape() {
        // ai: one int per key combination.
        let v = ov(vec![M | 0x31, 0]);
        assert_eq!(key_ints(&v), vec![M | 0x31]);
        // a(ai): a key sequence per entry.
        let s = zbus::zvariant::StructureBuilder::new().add_field(vec![M | 0x32, 0, 0, 0]).build().unwrap();
        let v = ov(zbus::zvariant::Value::from(vec![zbus::zvariant::Value::from(s)]));
        assert_eq!(key_ints(&v), vec![M | 0x32]);
    }

    #[test]
    fn prune_touches_only_what_loft_made() {
        let mut map = Map::default();
        map.spaces.insert(
            "main".into(),
            Entry { activity: "def".into(), adopted: Some(Adopted { name: "Default".into(), icon: "".into() }) },
        );
        map.spaces.insert("music".into(), Entry { activity: "a2".into(), adopted: None });
        map.spaces.insert("gone".into(), Entry { activity: "a3".into(), adopted: None });
        let existing = ["def".to_string(), "a2".into(), "mine".into()];
        assert_eq!(
            prune_plan(&map, &existing),
            vec![
                Op::Restore {
                    space: "main".into(),
                    activity: "def".into(),
                    prev: Adopted { name: "Default".into(), icon: "".into() }
                },
                Op::Remove { space: "music".into(), activity: "a2".into() },
            ]
        );
        assert!(prune_plan(&Map::default(), &existing).is_empty());
    }

    #[test]
    fn map_round_trips() {
        let dir = std::env::temp_dir().join(format!("loft-kwin-act-{}", std::process::id()));
        let path = map_path(&dir);
        let (m, existed) = load(&path);
        assert!(!existed && m.spaces.is_empty());
        let mut map = Map::default();
        map.spaces.insert("main".into(), Entry { activity: "a1".into(), adopted: None });
        save(&path, &map).unwrap();
        let (back, existed) = load(&path);
        assert!(existed);
        assert_eq!(back, map);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
