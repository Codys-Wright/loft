//! Spaces as KDE Activities (docs/KWIN.md §4.2): one Activity per Space.
//!
//! The shell sends the Space list (`{"cmd":"syncSpaces","spaces":[{id, name,
//! icon, template}]}`); this module makes kactivitymanagerd match it and keeps
//! the `space id ↔ activity id` map in Loft's state dir
//! (`<state>/kwin-activities.json`):
//!
//! ```json
//! { "spaces": { "main": { "activity": "…uuid…", "adopted": { "name": "Default", "icon": "" } },
//!               "music": { "activity": "…uuid…" } } }
//! ```
//!
//! - A Space without an Activity gets a new one (`AddActivity`). The very
//!   first sync (no map yet) lets the first Space **adopt** the current
//!   Activity instead, so the windows already open belong to a Space; its
//!   old name and icon are recorded in `adopted`.
//! - A Space's name and icon follow the document (`SetActivityName`,
//!   `SetActivityIcon`; Loft's glyph icons become a freedesktop icon name).
//! - A Space that's gone (deleted, archived) loses its Activity
//!   (`RemoveActivity`); an adopted one gets its old name and icon back and is
//!   kept. So is an Activity the user removed in Plasma: its Space gets a new one.
//! - `loft-kwin spaces prune` undoes it all: removes every Activity Loft
//!   created, gives adopted ones back their name and icon, and deletes the map.
//!
//! The plan (`plan`) is pure and unit-tested; `sync` / `prune` run it over D-Bus.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use zbus::{Connection, Proxy};

const SERVICE: &str = "org.kde.ActivityManager";
const PATH: &str = "/ActivityManager/Activities";
const IFACE: &str = "org.kde.ActivityManager.Activities";
const MAP_FILE: &str = "kwin-activities.json";

/// A Space as the shell sends it.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct SpaceInfo {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub icon: String,
    #[serde(default)]
    pub template: Option<String>,
}

/// An Activity as kactivitymanagerd reports it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Activity {
    pub id: String,
    pub name: String,
    pub icon: String,
}

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

/// One change to kactivitymanagerd (or to the map).
#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    /// Create an Activity for the space.
    Add {
        space: String,
        name: String,
        icon: String,
    },
    /// The first Space takes over the current Activity.
    Adopt {
        space: String,
        activity: String,
        prev: Adopted,
        name: String,
        icon: String,
    },
    Rename {
        activity: String,
        name: String,
    },
    SetIcon {
        activity: String,
        icon: String,
    },
    /// Loft created it and its Space is gone.
    Remove {
        space: String,
        activity: String,
    },
    /// An adopted Activity whose Space is gone: old name and icon back.
    Restore {
        space: String,
        activity: String,
        prev: Adopted,
    },
    /// The user removed the Activity in Plasma: forget it (an Add follows).
    Forget {
        space: String,
    },
}

/// Plasma's icon for a Space: the document's `icon` when it is already an
/// icon name, else one per built-in / template, else Plasma's activities icon.
/// (Loft's icons are Nerd Font glyphs, which Plasma can't show.)
pub fn kde_icon(s: &SpaceInfo) -> String {
    let i = s.icon.trim();
    if !i.is_empty()
        && i.chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    {
        return i.to_string();
    }
    let by = |k: &str| match k {
        "main" => Some("user-desktop"),
        "music" => Some("audio-x-generic"),
        "video" => Some("video-x-generic"),
        "comms" => Some("internet-mail"),
        "gaming" => Some("applications-games"),
        "task" => Some("view-task"),
        "project" => Some("folder-development"),
        _ => None,
    };
    by(&s.id)
        .or_else(|| s.template.as_deref().and_then(by))
        .unwrap_or("activities")
        .to_string()
}

fn display_name(s: &SpaceInfo) -> String {
    if s.name.trim().is_empty() {
        s.id.clone()
    } else {
        s.name.clone()
    }
}

/// What makes kactivitymanagerd match `spaces` (in order). `fresh`: no map
/// was ever written, so the first Space may adopt `current`.
pub fn plan(
    map: &Map,
    spaces: &[SpaceInfo],
    activities: &[Activity],
    current: &str,
    fresh: bool,
) -> Vec<Op> {
    let mut ops = Vec::new();
    let exists = |id: &str| activities.iter().find(|a| a.id == id);
    let wanted: Vec<&str> = spaces.iter().map(|s| s.id.as_str()).collect();

    // Spaces that are gone first, so a removed Activity can't be the one
    // switched to afterwards.
    for (space, e) in &map.spaces {
        if wanted.contains(&space.as_str()) {
            continue;
        }
        match (&e.adopted, exists(&e.activity)) {
            (_, None) => ops.push(Op::Forget {
                space: space.clone(),
            }),
            (Some(prev), Some(_)) => ops.push(Op::Restore {
                space: space.clone(),
                activity: e.activity.clone(),
                prev: prev.clone(),
            }),
            (None, Some(_)) => ops.push(Op::Remove {
                space: space.clone(),
                activity: e.activity.clone(),
            }),
        }
    }

    // Activities the map already gives a Space (a stale map could name one twice).
    let mut taken: Vec<&str> = map
        .spaces
        .iter()
        .filter(|(s, _)| wanted.contains(&s.as_str()))
        .map(|(_, e)| e.activity.as_str())
        .collect();
    for (i, s) in spaces.iter().enumerate() {
        let name = display_name(s);
        let icon = kde_icon(s);
        match map.spaces.get(&s.id).map(|e| (e, exists(&e.activity))) {
            Some((e, Some(a))) => {
                if a.name != name {
                    ops.push(Op::Rename {
                        activity: e.activity.clone(),
                        name: name.clone(),
                    });
                }
                if a.icon != icon {
                    ops.push(Op::SetIcon {
                        activity: e.activity.clone(),
                        icon,
                    });
                }
            }
            other => {
                if other.is_some() {
                    ops.push(Op::Forget {
                        space: s.id.clone(),
                    });
                }
                let adoptable = fresh && i == 0 && !current.is_empty() && !taken.contains(&current);
                match exists(current).filter(|_| adoptable) {
                    Some(a) => {
                        taken.push(current);
                        ops.push(Op::Adopt {
                            space: s.id.clone(),
                            activity: a.id.clone(),
                            prev: Adopted {
                                name: a.name.clone(),
                                icon: a.icon.clone(),
                            },
                            name,
                            icon,
                        });
                    }
                    None => ops.push(Op::Add {
                        space: s.id.clone(),
                        name,
                        icon,
                    }),
                }
            }
        }
    }
    ops
}

/// What `prune` does with the map: every Activity Loft created goes, adopted
/// ones get their name and icon back. Activities already gone are skipped.
pub fn prune_plan(map: &Map, activities: &[Activity]) -> Vec<Op> {
    map.spaces
        .iter()
        .filter(|(_, e)| activities.iter().any(|a| a.id == e.activity))
        .map(|(space, e)| match &e.adopted {
            Some(prev) => Op::Restore {
                space: space.clone(),
                activity: e.activity.clone(),
                prev: prev.clone(),
            },
            None => Op::Remove {
                space: space.clone(),
                activity: e.activity.clone(),
            },
        })
        .collect()
}

// ── State ────────────────────────────────────────────────────────────────

/// Loft's state dir: $LOFT_STATE_DIR, else $XDG_STATE_HOME/loft, else
/// ~/.local/state/loft (as the shell and the CLI).
pub fn state_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("LOFT_STATE_DIR").filter(|d| !d.is_empty()) {
        return d.into();
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
        });
    base.join("loft")
}

pub fn map_path(state: &Path) -> PathBuf {
    state.join(MAP_FILE)
}

/// The map, and whether one existed.
pub fn load(path: &Path) -> (Map, bool) {
    match std::fs::read_to_string(path) {
        Ok(text) => match serde_json::from_str(&text) {
            Ok(m) => (m, true),
            Err(e) => {
                eprintln!("loft-kwin: {}: {e}; starting a new map", path.display());
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

// ── kactivitymanagerd ────────────────────────────────────────────────────

pub async fn proxy(conn: &Connection) -> Result<Proxy<'static>> {
    Ok(Proxy::new(conn, SERVICE, PATH, IFACE).await?)
}

pub async fn list(p: &Proxy<'_>) -> Result<(Vec<Activity>, String)> {
    let ids: Vec<String> = p
        .call("ListActivities", &())
        .await
        .context("kactivitymanagerd (org.kde.ActivityManager) isn't answering")?;
    let mut out = Vec::new();
    for id in ids {
        let name: String = p
            .call("ActivityName", &(id.as_str(),))
            .await
            .unwrap_or_default();
        let icon: String = p
            .call("ActivityIcon", &(id.as_str(),))
            .await
            .unwrap_or_default();
        out.push(Activity { id, name, icon });
    }
    let current: String = p.call("CurrentActivity", &()).await.unwrap_or_default();
    Ok((out, current))
}

/// Apply `ops`, updating `map`. Errors are collected, not fatal: one bad
/// Activity shouldn't stop the rest.
pub async fn apply(p: &Proxy<'_>, map: &mut Map, ops: &[Op]) -> Vec<String> {
    let mut errors = Vec::new();
    for op in ops {
        let r: Result<()> = async {
            match op {
                Op::Add { space, name, icon } => {
                    let id: String = p.call("AddActivity", &(name.as_str(),)).await?;
                    anyhow::ensure!(!id.is_empty(), "AddActivity refused {name:?}");
                    let () = p
                        .call("SetActivityIcon", &(id.as_str(), icon.as_str()))
                        .await?;
                    map.spaces.insert(
                        space.clone(),
                        Entry {
                            activity: id,
                            adopted: None,
                        },
                    );
                }
                Op::Adopt {
                    space,
                    activity,
                    prev,
                    name,
                    icon,
                } => {
                    let () = p
                        .call("SetActivityName", &(activity.as_str(), name.as_str()))
                        .await?;
                    let () = p
                        .call("SetActivityIcon", &(activity.as_str(), icon.as_str()))
                        .await?;
                    map.spaces.insert(
                        space.clone(),
                        Entry {
                            activity: activity.clone(),
                            adopted: Some(prev.clone()),
                        },
                    );
                }
                Op::Rename { activity, name } => {
                    let () = p
                        .call("SetActivityName", &(activity.as_str(), name.as_str()))
                        .await?;
                }
                Op::SetIcon { activity, icon } => {
                    let () = p
                        .call("SetActivityIcon", &(activity.as_str(), icon.as_str()))
                        .await?;
                }
                Op::Remove { space, activity } => {
                    let () = p.call("RemoveActivity", &(activity.as_str(),)).await?;
                    map.spaces.remove(space);
                }
                Op::Restore {
                    space,
                    activity,
                    prev,
                } => {
                    let () = p
                        .call("SetActivityName", &(activity.as_str(), prev.name.as_str()))
                        .await?;
                    let () = p
                        .call("SetActivityIcon", &(activity.as_str(), prev.icon.as_str()))
                        .await?;
                    map.spaces.remove(space);
                }
                Op::Forget { space } => {
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

/// The shell's `{"Spaces": …}` line: space id → activity id, plus what
/// kactivitymanagerd has now.
pub fn report(map: &Map, activities: &[Activity], current: &str, errors: &[String]) -> Value {
    let m: BTreeMap<&str, &str> = map
        .spaces
        .iter()
        .map(|(s, e)| (s.as_str(), e.activity.as_str()))
        .collect();
    json!({ "Spaces": { "map": m, "activities": activities, "current": current, "errors": errors } })
}

/// Make the Activities match `spaces`; returns the report line.
pub async fn sync(conn: &Connection, state: &Path, spaces: &[SpaceInfo]) -> Result<Value> {
    let p = proxy(conn).await?;
    let path = map_path(state);
    let (mut map, existed) = load(&path);
    let (activities, current) = list(&p).await?;
    let ops = plan(&map, spaces, &activities, &current, !existed);
    let errors = apply(&p, &mut map, &ops).await;
    // Written even when nothing changed: an existing (empty) map means "no
    // more adopting" from now on.
    if !ops.is_empty() || !existed {
        save(&path, &map)?;
    }
    let (activities, current) = list(&p).await?;
    Ok(report(&map, &activities, &current, &errors))
}

/// Is Loft's shell running in this session (its loft-kwin owns the bridge)?
async fn shell_running(conn: &Connection) -> bool {
    let Ok(dbus) = zbus::fdo::DBusProxy::new(conn).await else {
        return false;
    };
    let Ok(name) = zbus::names::BusName::try_from(crate::BUS_NAME) else {
        return false;
    };
    dbus.name_has_owner(name).await.unwrap_or(false)
}

/// `loft-kwin spaces prune [--dry-run] [--force]` / `list`.
pub async fn cli(args: &[String]) -> Result<()> {
    let sub = args.first().map(String::as_str).unwrap_or("list");
    let dry = args.iter().any(|a| a == "--dry-run" || a == "-n");
    let force = args.iter().any(|a| a == "--force" || a == "-f");
    let conn = Connection::session().await?;
    let p = proxy(&conn).await?;
    let path = map_path(&state_dir());
    let (mut map, existed) = load(&path);
    let (activities, current) = list(&p).await?;
    match sub {
        "list" => {
            println!(
                "{}",
                serde_json::to_string_pretty(&report(&map, &activities, &current, &[]))?
            );
        }
        "prune" => {
            // Loft's shell with Spaces on would make them again at once.
            if !dry && !force && shell_running(&conn).await {
                anyhow::bail!(
                    "Loft's shell is running here and would recreate its Spaces' activities; \
                     switch to Plasma's shell first (loft-plasma use plasma), or pass --force"
                );
            }
            let ops = prune_plan(&map, &activities);
            for op in &ops {
                let line = match op {
                    Op::Remove { space, activity } => format!("remove {activity} (space {space})"),
                    Op::Restore {
                        space,
                        activity,
                        prev,
                    } => {
                        format!(
                            "restore {activity} as {:?} (adopted by space {space})",
                            prev.name
                        )
                    }
                    _ => continue,
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
            if errors.is_empty() {
                if existed {
                    std::fs::remove_file(&path)
                        .with_context(|| format!("removing {}", path.display()))?;
                }
            } else {
                // Keep what couldn't be undone for the next try.
                save(&path, &map)?;
                anyhow::bail!(
                    "{} activit{} left as they were",
                    errors.len(),
                    if errors.len() == 1 { "y" } else { "ies" }
                );
            }
            if ops.is_empty() {
                println!("no activities of Loft's");
            }
        }
        other => anyhow::bail!(
            "loft-kwin spaces: unknown command {other:?} (list | prune [--dry-run] [--force])"
        ),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sp(id: &str, name: &str) -> SpaceInfo {
        SpaceInfo {
            id: id.into(),
            name: name.into(),
            icon: "󰕰".into(),
            template: None,
        }
    }
    fn act(id: &str, name: &str, icon: &str) -> Activity {
        Activity {
            id: id.into(),
            name: name.into(),
            icon: icon.into(),
        }
    }
    fn entry(a: &str) -> Entry {
        Entry {
            activity: a.into(),
            adopted: None,
        }
    }

    #[test]
    fn first_sync_adopts_the_current_activity_for_the_first_space() {
        let acts = [act("def", "Default", "")];
        let ops = plan(
            &Map::default(),
            &[sp("main", "Main"), sp("music", "Music")],
            &acts,
            "def",
            true,
        );
        assert_eq!(
            ops,
            vec![
                Op::Adopt {
                    space: "main".into(),
                    activity: "def".into(),
                    prev: Adopted {
                        name: "Default".into(),
                        icon: "".into()
                    },
                    name: "Main".into(),
                    icon: "user-desktop".into(),
                },
                Op::Add {
                    space: "music".into(),
                    name: "Music".into(),
                    icon: "audio-x-generic".into()
                },
            ]
        );
    }

    #[test]
    fn later_syncs_never_adopt() {
        let acts = [act("def", "Default", "")];
        let ops = plan(&Map::default(), &[sp("main", "Main")], &acts, "def", false);
        assert_eq!(
            ops,
            vec![Op::Add {
                space: "main".into(),
                name: "Main".into(),
                icon: "user-desktop".into()
            }]
        );
    }

    #[test]
    fn names_and_icons_follow_the_spaces() {
        let mut map = Map::default();
        map.spaces.insert("main".into(), entry("a1"));
        let acts = [act("a1", "Old", "user-desktop")];
        let mut s = sp("main", "Desk");
        s.icon = "computer".into();
        let ops = plan(&map, &[s], &acts, "a1", false);
        assert_eq!(
            ops,
            vec![
                Op::Rename {
                    activity: "a1".into(),
                    name: "Desk".into()
                },
                Op::SetIcon {
                    activity: "a1".into(),
                    icon: "computer".into()
                },
            ]
        );
        // Already matching: nothing to do.
        let acts = [act("a1", "Main", "user-desktop")];
        assert!(plan(&map, &[sp("main", "Main")], &acts, "a1", false).is_empty());
    }

    #[test]
    fn deleted_spaces_lose_their_activity_and_adopted_ones_are_restored() {
        let mut map = Map::default();
        map.spaces.insert(
            "main".into(),
            Entry {
                activity: "def".into(),
                adopted: Some(Adopted {
                    name: "Default".into(),
                    icon: "x".into(),
                }),
            },
        );
        map.spaces.insert("music".into(), entry("a2"));
        map.spaces.insert("gone".into(), entry("a3"));
        let acts = [
            act("def", "Main", "user-desktop"),
            act("a2", "Music", "audio-x-generic"),
        ];
        let ops = plan(&map, &[], &acts, "def", false);
        assert_eq!(
            ops,
            vec![
                Op::Forget {
                    space: "gone".into()
                },
                Op::Restore {
                    space: "main".into(),
                    activity: "def".into(),
                    prev: Adopted {
                        name: "Default".into(),
                        icon: "x".into()
                    }
                },
                Op::Remove {
                    space: "music".into(),
                    activity: "a2".into()
                },
            ]
        );
    }

    #[test]
    fn an_activity_removed_in_plasma_is_recreated() {
        let mut map = Map::default();
        map.spaces.insert("music".into(), entry("a2"));
        let ops = plan(
            &map,
            &[sp("music", "Music")],
            &[act("def", "Default", "")],
            "def",
            false,
        );
        assert_eq!(
            ops,
            vec![
                Op::Forget {
                    space: "music".into()
                },
                Op::Add {
                    space: "music".into(),
                    name: "Music".into(),
                    icon: "audio-x-generic".into()
                },
            ]
        );
    }

    #[test]
    fn prune_removes_created_and_restores_adopted() {
        let mut map = Map::default();
        map.spaces.insert(
            "main".into(),
            Entry {
                activity: "def".into(),
                adopted: Some(Adopted {
                    name: "Default".into(),
                    icon: "".into(),
                }),
            },
        );
        map.spaces.insert("music".into(), entry("a2"));
        map.spaces.insert("gone".into(), entry("a3"));
        let acts = [
            act("def", "Main", ""),
            act("a2", "Music", ""),
            act("other", "Mine", ""),
        ];
        assert_eq!(
            prune_plan(&map, &acts),
            vec![
                Op::Restore {
                    space: "main".into(),
                    activity: "def".into(),
                    prev: Adopted {
                        name: "Default".into(),
                        icon: "".into()
                    }
                },
                Op::Remove {
                    space: "music".into(),
                    activity: "a2".into()
                },
            ]
        );
    }

    #[test]
    fn plasma_icons_for_glyphs() {
        assert_eq!(kde_icon(&sp("gaming", "")), "applications-games");
        let mut s = sp("loft", "Loft");
        s.template = Some("project".into());
        assert_eq!(kde_icon(&s), "folder-development");
        assert_eq!(kde_icon(&sp("misc", "")), "activities");
        s.icon = "folder-music".into();
        assert_eq!(kde_icon(&s), "folder-music");
        assert_eq!(display_name(&sp("x", " ")), "x");
    }

    #[test]
    fn map_round_trips() {
        let dir = std::env::temp_dir().join(format!("loft-kwin-act-{}", std::process::id()));
        let path = map_path(&dir);
        let (m, existed) = load(&path);
        assert!(!existed && m.spaces.is_empty());
        let mut map = Map::default();
        map.spaces.insert("main".into(), entry("a1"));
        save(&path, &map).unwrap();
        let (back, existed) = load(&path);
        assert!(existed);
        assert_eq!(back, map);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
