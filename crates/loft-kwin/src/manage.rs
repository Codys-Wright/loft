//! Managing the user's KDE Activities from Loft (docs/KWIN.md §4.2):
//! create, rename, re-icon, reorder and remove. Every change goes to KDE
//! itself, so Plasma, KWin and the "Switch to activity" keys see it; Loft
//! keeps no list of its own.
//!
//! - **Names and icons** are kactivitymanagerd's (`AddActivity`,
//!   `SetActivityName`, `SetActivityIcon`, `RemoveActivity`).
//! - **Order.** KDE stores none: kactivitymanagerd and plasma-activities sort
//!   by name, Plasma's activity switcher by last use. What KDE does keep is
//!   each Activity's "Switch to activity" shortcut (kglobalaccel's
//!   `ActivityManager` component, `switch-to-activity-<uuid>`), and Loft's
//!   order is those keys' digits (activities.rs `order`). So the order *is*
//!   the keys: reordering hands the digit keys in use ("slots": Meta+1, …,
//!   Meta+0) to the Activities in their new order (`key_changes`), and a new
//!   Activity gets the first free one (Meta+1…9, then Meta+0). The keys are
//!   set in two passes (every changed Activity loses its slot first), since
//!   kglobalaccel only grabs a key for the first action that has it.
//! - **Remove**: the windows only on that Activity would end up on every
//!   Activity (KWin drops the id from their list, and an empty list is "all"),
//!   so they move to its neighbour in Loft's order first, and when it is the
//!   current one Loft switches to that neighbour (kactivitymanagerd would pick
//!   the next by name). The other Activities keep their keys.
//! - **Rename**: Loft's settings for an Activity linked by its old name
//!   (a library document's `activity`) are linked by id instead, and window
//!   rules whose `open-on-activity` names it name the new one (`fix_links`,
//!   through loft-niri, which owns those files). loft-kwin's daemon does this
//!   for every rename it sees, Plasma's too (main.rs `activities_changed`).
//!
//! The shell sends `{"cmd": "activity", "op": …}` on stdin and gets
//! `{"ActivityEdit": {op, ok, id, name, error, notes}}`; `loft-kwin spaces
//! new|rename|icon|move|order|remove` goes through the running daemon (its
//! `Activity` D-Bus method), or straight to KDE when there is none.

use std::collections::HashMap;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use zbus::Connection;

use crate::activities::{self, Activity, META, Shortcut};

/// The digit keys an Activity can hold as its position, in order:
/// Meta+1 … Meta+9, Meta+0.
pub fn slot_keys() -> Vec<i32> {
    (1..=9).chain([0]).map(|d| META | (0x30 + d)).collect()
}

/// Names compare without case, spaces, `-` and `_` (as window rules do:
/// "System-Configuration" = "system configuration").
pub fn norm(s: &str) -> String {
    s.chars().filter(|c| !matches!(c, ' ' | '-' | '_')).flat_map(char::to_lowercase).collect()
}

/// An Activity by id, by position (the digit of its key), or by name.
pub fn find<'a>(list: &'a [Activity], key: &str) -> Option<&'a Activity> {
    let k = key.trim();
    list.iter()
        .find(|a| a.id == k)
        .or_else(|| list.iter().find(|a| a.position.is_some_and(|p| p.to_string() == k)))
        .or_else(|| list.iter().find(|a| norm(&a.name) == norm(k)))
}

/// A name for a new or renamed Activity: not empty, and not another
/// Activity's (Loft finds Activities by name, and so do window rules).
pub fn check_name(list: &[Activity], name: &str, except: Option<&str>) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("give the Activity a name".into());
    }
    if let Some(other) = list.iter().find(|a| Some(a.id.as_str()) != except && norm(&a.name) == norm(name)) {
        return Err(format!("there is an Activity called “{}” already", other.name));
    }
    Ok(name.to_string())
}

/// The first slot no Activity has (any of its keys), if one is left.
pub fn free_slot(list: &[Activity]) -> Option<i32> {
    slot_keys().into_iter().find(|k| !list.iter().any(|a| a.keys.contains(k)))
}

/// `ids` first (those that exist, once each), then the rest in their order.
pub fn new_order(list: &[Activity], ids: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for id in ids {
        if list.iter().any(|a| &a.id == id) && !out.contains(id) {
            out.push(id.clone());
        }
    }
    for a in list {
        if !out.contains(&a.id) {
            out.push(a.id.clone());
        }
    }
    out
}

/// The keys each Activity gets for this order: the slots in use, in slot
/// order, go to the first ones; an Activity keeps its other keys. When one
/// without a slot moves in among those with one, free digits are added so
/// none of them loses its key. Only the Activities whose keys change are
/// listed.
pub fn key_changes(list: &[Activity], ids: &[String]) -> Vec<(String, Vec<i32>)> {
    let order = new_order(list, ids);
    let slots = slots_for(list, &order);
    let mut out = Vec::new();
    for (i, id) in order.iter().enumerate() {
        let Some(a) = list.iter().find(|a| &a.id == id) else { continue };
        let want = slots.get(i).copied();
        let mut keys: Vec<i32> = want.into_iter().collect();
        for k in &a.keys {
            if Some(*k) != a.slot && !slots.contains(k) && !keys.contains(k) {
                keys.push(*k);
            }
        }
        let mut before = a.keys.clone();
        let mut after = keys.clone();
        before.sort_unstable();
        after.sort_unstable();
        if before != after {
            out.push((id.clone(), keys));
        }
    }
    out
}

/// The slots the first Activities of `order` get, in slot order.
fn slots_for(list: &[Activity], order: &[String]) -> Vec<i32> {
    let mut slots: Vec<i32> = list.iter().filter_map(|a| a.slot).collect();
    let last_keyed = order
        .iter()
        .enumerate()
        .filter(|(_, id)| list.iter().any(|a| &a.id == *id && a.slot.is_some()))
        .map(|(i, _)| i + 1)
        .max()
        .unwrap_or(0);
    let mut free = slot_keys().into_iter().filter(|k| !list.iter().any(|a| a.keys.contains(k)));
    while slots.len() < last_keyed.min(slot_keys().len()) {
        let Some(k) = free.next() else { break };
        slots.push(k);
    }
    slots.sort_by_key(|k| {
        let d = activities::digit(*k).unwrap_or(0);
        (activities::rank(d), k & META == 0)
    });
    slots
}

/// How many Activities are left without a ⌘ number in this order.
pub fn unkeyed_after(list: &[Activity], ids: &[String]) -> usize {
    let order = new_order(list, ids);
    order.len().saturating_sub(slots_for(list, &order).len())
}

/// What removing an Activity does around it.
#[derive(Debug, Clone, PartialEq)]
pub struct RemovePlan {
    pub id: String,
    pub name: String,
    /// Where its windows go, and where Loft switches if it is current: the
    /// next Activity in Loft's order (the previous one for the last).
    pub target: String,
    pub target_name: String,
    pub switch: bool,
    /// Windows (KWin uuids) on that Activity alone.
    pub moves: Vec<String>,
}

/// `windows`: (uuid, its activities) for every window.
pub fn remove_plan(list: &[Activity], current: &str, key: &str, windows: &[(String, Vec<String>)]) -> Result<RemovePlan, String> {
    let a = find(list, key).ok_or_else(|| format!("no KDE Activity {key:?}"))?;
    if list.len() < 2 {
        return Err(format!("“{}” is the only Activity; KDE needs one", a.name));
    }
    let i = list.iter().position(|x| x.id == a.id).unwrap_or(0);
    let t = if i + 1 < list.len() { &list[i + 1] } else { &list[i - 1] };
    let moves = windows.iter().filter(|(_, acts)| acts.len() == 1 && acts[0] == a.id).map(|(w, _)| w.clone()).collect();
    Ok(RemovePlan {
        id: a.id.clone(),
        name: a.name.clone(),
        target: t.id.clone(),
        target_name: t.name.clone(),
        switch: current == a.id,
        moves,
    })
}

/// Library documents (`loft-niri space list --json --archived`) linked to
/// the Activity by its old name (any case), to be linked by id.
pub fn doc_fixes(spaces: &Value, id: &str, old: &str) -> Vec<String> {
    let old = old.to_lowercase();
    spaces["spaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|s| s["doc"]["activity"].as_str().is_some_and(|a| a != id && !old.is_empty() && a.to_lowercase() == old))
        .filter_map(|s| s["id"].as_str().map(String::from))
        .collect()
}

/// Window rules (`loft-niri windows kwin-rules`: `{rules: [{name,
/// activityName}]}`) that open on the old name.
pub fn rule_fixes(rules: &Value, old: &str) -> Vec<String> {
    let old = norm(old);
    rules["rules"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| !old.is_empty() && r["activityName"].as_str().is_some_and(|n| norm(n) == old))
        .filter_map(|r| r["name"].as_str().map(String::from))
        .collect()
}

// ── KDE ──────────────────────────────────────────────────────────────────

/// Set the keys of "Switch to activity" actions: first every one of them
/// without the slots any of them will get, then the final keys.
async fn set_keys(conn: &Connection, shortcuts: &HashMap<String, Shortcut>, changes: &[(String, Vec<i32>)]) -> Result<()> {
    let p = zbus::Proxy::new(conn, activities::KGA, "/kglobalaccel", "org.kde.KGlobalAccel").await?;
    let wanted: Vec<i32> = changes.iter().flat_map(|(_, ks)| ks.iter().copied()).filter(|k| slot_keys().contains(k)).collect();
    async fn set(p: &zbus::Proxy<'_>, sc: Option<&Shortcut>, id: &str, keys: Vec<i32>) -> Result<()> {
        let sc = sc.with_context(|| format!("kglobalaccel has no “Switch to activity” action for {id}"))?;
        let seqs: Vec<(Vec<i32>,)> = keys.into_iter().map(|k| (vec![k],)).collect();
        let () = p.call("setForeignShortcutKeys", &(sc.action_id.clone(), seqs)).await?;
        Ok(())
    }
    for (id, _) in changes {
        let held = shortcuts.get(id).map(|s| s.keys.clone()).unwrap_or_default();
        let keep: Vec<i32> = held.into_iter().filter(|k| !wanted.contains(k) && !slot_keys().contains(k)).collect();
        set(&p, shortcuts.get(id), id, keep).await?;
    }
    for (id, keys) in changes {
        set(&p, shortcuts.get(id), id, keys.clone()).await?;
    }
    Ok(())
}

/// Other global shortcuts on this key ("KWin: Zoom to Actual Size"), which
/// may run instead of the Activity's.
async fn others_on(conn: &Connection, key: i32) -> Vec<String> {
    let Ok(p) = zbus::Proxy::new(conn, activities::KGA, "/kglobalaccel", "org.kde.KGlobalAccel").await else {
        return Vec::new();
    };
    let Ok(msg) = p.call_method("globalShortcutsByKey", &((vec![key],), (0i32,))).await else {
        return Vec::new();
    };
    let body = msg.body();
    let Ok(args) = body.deserialize::<zbus::zvariant::Structure<'_>>() else {
        return Vec::new();
    };
    let Some(zbus::zvariant::Value::Array(rows)) = args.fields().first() else { return Vec::new() };
    let text = |v: Option<&zbus::zvariant::Value<'_>>| match v {
        Some(zbus::zvariant::Value::Str(s)) => s.as_str().to_string(),
        _ => String::new(),
    };
    rows.iter()
        .filter_map(|r| {
            let zbus::zvariant::Value::Structure(r) = r else { return None };
            let f = r.fields();
            let comp = text(f.get(2));
            (comp != "ActivityManager").then(|| format!("{}: {}", text(f.get(3)).trim(), text(f.get(1))))
        })
        .collect()
}

/// The Activity's shortcut, once kactivitymanagerd has made it (just after
/// `AddActivity`).
async fn shortcuts_with(conn: &Connection, id: &str) -> HashMap<String, Shortcut> {
    for _ in 0..20 {
        let s = activities::shortcuts(conn).await;
        if s.contains_key(id) {
            return s;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    activities::shortcuts(conn).await
}

/// What a running daemon gives an edit: the windows (for `remove`) and a
/// way to move them (its command queue).
pub struct Ctx<'a> {
    pub windows: Vec<(String, Vec<String>)>,
    pub move_window: &'a dyn Fn(&str, &str),
}

/// (uuid, activities) of every window in a `{"windows": …}` state.
pub fn windows_of(state: &Value) -> Vec<(String, Vec<String>)> {
    state["windows"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|w| {
            let id = w["kwin_uuid"].as_str()?.to_string();
            let acts = w["kwin_activities"].as_array().into_iter().flatten().filter_map(|a| a.as_str().map(String::from)).collect();
            Some((id, acts))
        })
        .collect()
}

/// One edit: `{"op": "create", "name", "icon"?}`, `{"op": "rename",
/// "activity", "name"}`, `{"op": "icon", "activity", "icon"}`, `{"op":
/// "reorder", "order": [ids or names]}`, `{"op": "move", "activity", "to":
/// 1-based place}`, `{"op": "remove", "activity"}`.
/// `ctx` is the daemon's (None: `loft-kwin spaces` without one).
pub async fn edit(conn: &Connection, cmd: &Value, ctx: Option<Ctx<'_>>) -> Result<Value> {
    let p = activities::proxy(conn).await?;
    let (list, current) = activities::current(conn).await?;
    let cmd = &resolve_move(&list, cmd).map_err(anyhow::Error::msg)?;
    let op = cmd["op"].as_str().unwrap_or("");
    let s = |k: &str| cmd[k].as_str().unwrap_or("").to_string();
    let which = || find(&list, &s("activity")).with_context(|| format!("no KDE Activity {:?}", s("activity")));
    let mut notes: Vec<String> = Vec::new();
    let mut out = json!({ "op": op });
    match op {
        "create" => {
            let name = check_name(&list, &s("name"), None).map_err(anyhow::Error::msg)?;
            let id: String = p.call("AddActivity", &(name.as_str(),)).await.context("AddActivity")?;
            if id.is_empty() {
                bail!("kactivitymanagerd made no Activity (is adding Activities allowed here?)");
            }
            if !s("icon").is_empty() {
                let () = p.call("SetActivityIcon", &(id.as_str(), s("icon").as_str())).await?;
            }
            match free_slot(&list) {
                Some(key) => {
                    let sc = shortcuts_with(conn, &id).await;
                    set_keys(conn, &sc, &[(id.clone(), vec![key])]).await?;
                    for o in others_on(conn, key).await {
                        notes.push(format!("{} is also {o}; KDE may run that instead", activities::key_text(key)));
                    }
                    out["key"] = json!(activities::key_text(key));
                }
                None => notes.push("every ⌘ number (1…9, 0) has an Activity: this one has none".into()),
            }
            out["id"] = json!(id);
            out["name"] = json!(name);
        }
        "rename" => {
            let a = which()?;
            let name = check_name(&list, &s("name"), Some(&a.id)).map_err(anyhow::Error::msg)?;
            let () = p.call("SetActivityName", &(a.id.as_str(), name.as_str())).await.context("SetActivityName")?;
            out["id"] = json!(a.id);
            out["old"] = json!(a.name);
            out["name"] = json!(name);
            // The daemon fixes the links on the report that follows (for
            // Plasma's renames too); without one, do it here.
            if ctx.is_none() && a.name != name {
                let r = fix_links(&a.id, &a.name, &name).await;
                notes.extend(r["notes"].as_array().into_iter().flatten().filter_map(|n| n.as_str().map(String::from)));
            }
        }
        "icon" => {
            let a = which()?;
            let () = p.call("SetActivityIcon", &(a.id.as_str(), s("icon").as_str())).await.context("SetActivityIcon")?;
            out["id"] = json!(a.id);
            out["name"] = json!(a.name);
        }
        "reorder" => {
            let ids: Vec<String> = cmd["order"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|k| k.as_str())
                .map(|k| find(&list, k).map(|a| a.id.clone()).with_context(|| format!("no KDE Activity {k:?}")))
                .collect::<Result<_>>()?;
            let changes = key_changes(&list, &ids);
            if !changes.is_empty() {
                set_keys(conn, &activities::shortcuts(conn).await, &changes).await?;
            }
            for key in changes.iter().flat_map(|(_, ks)| ks.iter().copied()).filter(|k| slot_keys().contains(k)) {
                for o in others_on(conn, key).await {
                    notes.push(format!("{} is also {o}; KDE may run that instead", activities::key_text(key)));
                }
            }
            let left = unkeyed_after(&list, &ids);
            if left > 0 {
                notes.push(format!(
                    "{left} Activit{} without a ⌘ number stay{} last",
                    if left == 1 { "y" } else { "ies" },
                    if left == 1 { "s" } else { "" }
                ));
            }
            out["order"] = json!(new_order(&list, &ids));
            out["changed"] = json!(changes.len());
        }
        "remove" => {
            let windows = ctx.as_ref().map(|c| c.windows.clone()).unwrap_or_default();
            let plan = remove_plan(&list, &current, &s("activity"), &windows).map_err(anyhow::Error::msg)?;
            if plan.switch {
                let _: bool = p.call("SetCurrentActivity", &(plan.target.as_str(),)).await.unwrap_or(false);
            }
            match &ctx {
                Some(c) => {
                    for w in &plan.moves {
                        (c.move_window)(w, &plan.target);
                    }
                }
                None => notes.push("Loft's shell isn't running: windows only on it are now on every Activity".into()),
            }
            let () = p.call("RemoveActivity", &(plan.id.as_str(),)).await.context("RemoveActivity")?;
            out["id"] = json!(plan.id);
            out["name"] = json!(plan.name);
            out["target"] = json!(plan.target);
            out["moved"] = json!(plan.moves.len());
            if !plan.moves.is_empty() {
                notes.push(format!(
                    "{} window{} moved to “{}”",
                    plan.moves.len(),
                    if plan.moves.len() == 1 { "" } else { "s" },
                    plan.target_name
                ));
            }
        }
        other => bail!("unknown Activity edit {other:?} (create | rename | icon | reorder | remove)"),
    }
    out["ok"] = json!(true);
    out["notes"] = json!(notes);
    Ok(out)
}

/// `edit` as the shell's `{"ActivityEdit": …}` line (errors included).
pub async fn edit_line(conn: &Connection, cmd: &Value, ctx: Option<Ctx<'_>>) -> Value {
    let r = match edit(conn, cmd, ctx).await {
        Ok(v) => v,
        Err(e) => json!({ "op": cmd["op"], "ok": false, "error": format!("{e:#}"), "activity": cmd["activity"], "notes": [] }),
    };
    let mut r = r;
    // The shell's tag, so it knows which answer is its own.
    if !cmd["tag"].is_null() {
        r["tag"] = cmd["tag"].clone();
    }
    json!({ "ActivityEdit": r })
}

async fn loft_niri(args: &[&str]) -> Result<Value, String> {
    let bin = std::env::var("LOFT_NIRI").unwrap_or_else(|_| "loft-niri".into());
    let out = tokio::process::Command::new(&bin)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .map_err(|e| format!("running {bin}: {e}"))?;
    let v: Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("{bin} {}: {e}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))?;
    if v["ok"] == false || !out.status.success() {
        return Err(v["error"].as_str().map(String::from).unwrap_or_else(|| format!("{bin} {} failed", args.first().unwrap_or(&""))));
    }
    Ok(v)
}

/// After a rename: documents linked by the old name are linked by id, and
/// window rules that open on the old name open on the new one. Answers
/// `{id, old, name, docs: [ids], rules: [apps], notes}`.
pub async fn fix_links(id: &str, old: &str, new: &str) -> Value {
    let mut notes = Vec::new();
    let mut docs = Vec::new();
    let mut rules = Vec::new();
    match loft_niri(&["space", "list", "--json", "--archived"]).await {
        Ok(list) => {
            for doc in doc_fixes(&list, id, old) {
                let patch = json!({ "activity": id }).to_string();
                match loft_niri(&["--json", "space", "patch", &doc, &patch]).await {
                    Ok(_) => docs.push(doc),
                    Err(e) => notes.push(format!("couldn't link Loft settings “{doc}” to “{new}”: {e}")),
                }
            }
        }
        Err(e) => notes.push(format!("Loft settings not checked: {e}")),
    }
    match loft_niri(&["--json", "windows", "kwin-rules", "--displays", "[]"]).await {
        Ok(v) => {
            for app in rule_fixes(&v, old) {
                let batch = json!({ "window_rules": { &app: { "open-on-activity": new } } }).to_string();
                match loft_niri(&["--json", "apply", &batch, "--no-validate", "--no-reload"]).await {
                    Ok(_) => rules.push(app),
                    Err(e) => notes.push(format!("window rule {app} still opens on “{old}”: {e}")),
                }
            }
        }
        Err(e) => notes.push(format!("window rules not checked: {e}")),
    }
    if !docs.is_empty() {
        notes.push(format!("Loft settings {} now linked to “{new}” by id", docs.join(", ")));
    }
    if !rules.is_empty() {
        notes.push(format!("window rule{} {} now open{} on “{new}”", if rules.len() == 1 { "" } else { "s" }, rules.join(", "), if rules.len() == 1 { "s" } else { "" }));
    }
    json!({ "id": id, "old": old, "name": new, "docs": docs, "rules": rules, "notes": notes })
}

/// Renamed Activities between two reports: (id, old name, new name).
pub fn renames(before: &[(String, String)], after: &[(String, String)]) -> Vec<(String, String, String)> {
    after
        .iter()
        .filter_map(|(id, name)| {
            let (_, old) = before.iter().find(|(b, _)| b == id)?;
            (old != name && !old.is_empty() && !name.is_empty()).then(|| (id.clone(), old.clone(), name.clone()))
        })
        .collect()
}

/// `loft-kwin spaces new|rename|icon|move|order|remove …`: an edit command
/// from the command line, or None for another verb.
pub fn parse_cli(args: &[String]) -> Option<Result<Value, String>> {
    let rest: Vec<&str> = args.iter().skip(1).map(String::as_str).collect();
    let flag = |name: &str| rest.iter().position(|a| *a == name).and_then(|i| rest.get(i + 1)).map(|s| s.to_string());
    let plain: Vec<&str> = {
        let mut v = Vec::new();
        let mut skip = false;
        for a in &rest {
            if skip {
                skip = false;
            } else if *a == "--icon" {
                skip = true;
            } else {
                v.push(*a);
            }
        }
        v
    };
    let usage = |u: &str| Err(format!("usage: loft-kwin spaces {u}"));
    Some(match args.first().map(String::as_str)? {
        "new" | "create" => match plain.as_slice() {
            [] => usage("new NAME [--icon ICON]"),
            names => Ok(json!({ "op": "create", "name": names.join(" "), "icon": flag("--icon").unwrap_or_default() })),
        },
        "rename" => match plain.as_slice() {
            [which, name @ ..] if !name.is_empty() => Ok(json!({ "op": "rename", "activity": which, "name": name.join(" ") })),
            _ => usage("rename ACTIVITY NEW-NAME"),
        },
        "icon" => match plain.as_slice() {
            [which, icon] => Ok(json!({ "op": "icon", "activity": which, "icon": icon })),
            _ => usage("icon ACTIVITY ICON-NAME"),
        },
        "remove" | "delete" => match plain.as_slice() {
            [which] => Ok(json!({ "op": "remove", "activity": which })),
            _ => usage("remove ACTIVITY"),
        },
        "order" => match plain.as_slice() {
            [] => usage("order ACTIVITY…"),
            ids => Ok(json!({ "op": "reorder", "order": ids })),
        },
        "move" => match plain.as_slice() {
            [which, to] => match to.parse::<usize>() {
                Ok(n) if n >= 1 => Ok(json!({ "op": "move", "activity": which, "to": n })),
                _ => usage("move ACTIVITY POSITION (1 = first)"),
            },
            _ => usage("move ACTIVITY POSITION (1 = first)"),
        },
        _ => return None,
    })
}

/// `move` (one Activity to a 1-based place in Loft's order) as `reorder`.
pub fn resolve_move(list: &[Activity], cmd: &Value) -> Result<Value, String> {
    if cmd["op"] != "move" {
        return Ok(cmd.clone());
    }
    let key = cmd["activity"].as_str().unwrap_or("");
    let a = find(list, key).ok_or_else(|| format!("no KDE Activity {key:?}"))?;
    let mut ids: Vec<String> = list.iter().map(|x| x.id.clone()).filter(|id| id != &a.id).collect();
    let to = cmd["to"].as_u64().unwrap_or(1).max(1) as usize - 1;
    ids.insert(to.min(ids.len()), a.id.clone());
    Ok(json!({ "op": "reorder", "order": ids }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const M: i32 = META;

    fn act(id: &str, keys: &[i32]) -> (String, String, String, Vec<i32>) {
        (id.to_string(), id[..1].to_uppercase() + &id[1..], String::new(), keys.to_vec())
    }
    fn list(rows: &[(String, String, String, Vec<i32>)]) -> Vec<Activity> {
        let listed = rows.iter().map(|(i, n, ic, _)| (i.clone(), n.clone(), ic.clone())).collect();
        let keys = rows.iter().map(|(i, _, _, k)| (i.clone(), k.clone())).collect();
        activities::order(listed, &keys)
    }
    fn names(l: &[Activity]) -> Vec<&str> {
        l.iter().map(|a| a.name.as_str()).collect()
    }
    /// The list after applying key changes.
    fn after(l: &[Activity], changes: &[(String, Vec<i32>)]) -> Vec<Activity> {
        let rows: Vec<_> = l
            .iter()
            .map(|a| {
                let k = changes.iter().find(|(id, _)| id == &a.id).map(|(_, k)| k.clone()).unwrap_or(a.keys.clone());
                (a.id.clone(), a.name.clone(), a.icon.clone(), k)
            })
            .collect();
        list(&rows)
    }

    /// The user's: Default 1 … Ignition 6, System-Configuration 0.
    fn users() -> Vec<Activity> {
        list(&[
            act("editing", &[M | 0x35]),
            act("default", &[M | 0x31]),
            act("ignition", &[M | 0x36]),
            act("music", &[M | 0x32]),
            act("coding", &[M | 0x33]),
            act("gaming", &[M | 0x34]),
            act("system", &[M | 0x30]),
        ])
    }

    #[test]
    fn moving_one_up_swaps_two_keys_and_keeps_the_zero() {
        let l = users();
        assert_eq!(names(&l), ["Default", "Music", "Coding", "Gaming", "Editing", "Ignition", "System"]);
        let ids = ["default", "coding", "music"].map(String::from);
        let ch = key_changes(&l, &ids);
        assert_eq!(ch, vec![("coding".to_string(), vec![M | 0x32]), ("music".to_string(), vec![M | 0x33])]);
        let l2 = after(&l, &ch);
        assert_eq!(names(&l2), ["Default", "Coding", "Music", "Gaming", "Editing", "Ignition", "System"]);
        // System-Configuration to the front: everyone shifts, ⌘0 goes to Ignition.
        let ch = key_changes(&l, &["system".to_string()]);
        let l3 = after(&l, &ch);
        assert_eq!(names(&l3), ["System", "Default", "Music", "Coding", "Gaming", "Editing", "Ignition"]);
        assert_eq!(l3[0].key, "Meta+1");
        assert_eq!(l3[6].key, "Meta+0");
        // The same order again changes nothing.
        let same: Vec<String> = l.iter().map(|a| a.id.clone()).collect();
        assert!(key_changes(&l, &same).is_empty());
    }

    #[test]
    fn other_keys_stay_and_an_unkeyed_one_takes_a_slot_when_moved_in() {
        let l = list(&[act("a", &[M | 0x31, M | CTRL_F1]), act("b", &[M | 0x32]), act("c", &[])]);
        let ch = key_changes(&l, &["c", "a", "b"].map(String::from));
        let l2 = after(&l, &ch);
        assert_eq!(names(&l2), ["C", "A", "B"]);
        assert_eq!(l2[0].keys, vec![M | 0x31]);
        assert_eq!(l2[1].keys, vec![M | 0x32, M | CTRL_F1]);
        // B keeps a key: the next free digit.
        assert_eq!(l2[2].keys, vec![M | 0x33]);
        // An unkeyed one moved among the user's 1…6, 0: the 0 stays last.
        let mut rows = vec![act("x", &[])];
        rows.extend(["a", "b", "c", "d", "e", "f"].iter().enumerate().map(|(i, n)| act(n, &[M | (0x31 + i as i32)])));
        rows.push(act("z", &[M | 0x30]));
        let l = list(&rows);
        let l2 = after(&l, &key_changes(&l, &["x".to_string()]));
        assert_eq!(names(&l2), ["X", "A", "B", "C", "D", "E", "F", "Z"]);
        assert_eq!(l2[6].key, "Meta+7");
        assert_eq!(l2[7].key, "Meta+0");
        // Moved below the keyed ones, it stays without a key.
        let ids: Vec<String> = ["a", "b", "c", "d", "e", "f", "z", "x"].map(String::from).to_vec();
        assert!(key_changes(&l, &ids).is_empty());
    }
    const CTRL_F1: i32 = 0x0400_0000 | 0x0100_0030;

    #[test]
    fn a_new_one_takes_the_first_free_digit() {
        let l = users();
        assert_eq!(free_slot(&l), Some(M | 0x37));
        let gap = list(&[act("a", &[M | 0x31]), act("c", &[M | 0x33])]);
        assert_eq!(free_slot(&gap), Some(M | 0x32));
        let full: Vec<_> = (0..10).map(|d| act(&format!("x{d}"), &[M | (0x30 + d)])).collect();
        assert_eq!(free_slot(&list(&full)), None);
    }

    #[test]
    fn names_are_checked() {
        let l = users();
        assert!(check_name(&l, "  ", None).is_err());
        assert_eq!(check_name(&l, "music", None).unwrap_err(), "there is an Activity called “Music” already");
        assert_eq!(check_name(&l, " Video ", None).unwrap(), "Video");
        // Renaming to itself in another case is fine.
        assert_eq!(check_name(&l, "MUSIC", Some("music")).unwrap(), "MUSIC");
    }

    #[test]
    fn finds_by_id_digit_or_loose_name() {
        let l = list(&[act("default", &[M | 0x31]), ("sys".into(), "System-Configuration".into(), String::new(), vec![M | 0x30])]);
        assert_eq!(find(&l, "default").unwrap().id, "default");
        assert_eq!(find(&l, "0").unwrap().id, "sys");
        assert_eq!(find(&l, "system configuration").unwrap().id, "sys");
        assert!(find(&l, "nope").is_none());
    }

    #[test]
    fn removing_moves_its_own_windows_to_the_next_one() {
        let l = users();
        let wins = vec![
            ("w1".to_string(), vec!["coding".to_string()]),
            ("w2".to_string(), vec!["coding".to_string(), "music".to_string()]),
            ("w3".to_string(), vec![]),
            ("w4".to_string(), vec!["music".to_string()]),
        ];
        let p = remove_plan(&l, "coding", "Coding", &wins).unwrap();
        assert_eq!((p.target.as_str(), p.target_name.as_str(), p.switch), ("gaming", "Gaming", true));
        assert_eq!(p.moves, vec!["w1".to_string()]);
        // The last one's windows go to the one before it.
        let p = remove_plan(&l, "default", "system", &wins).unwrap();
        assert_eq!((p.target.as_str(), p.switch), ("ignition", false));
        assert!(remove_plan(&l[..1], "default", "default", &wins).unwrap_err().contains("only Activity"));
        assert!(remove_plan(&l, "default", "nope", &wins).is_err());
    }

    #[test]
    fn rename_fixes_docs_by_name_and_rules_by_loose_name() {
        let spaces = json!({ "spaces": [
            { "id": "coding", "doc": { "activity": "coding" } },
            { "id": "byid", "doc": { "activity": "uuid-1" } },
            { "id": "music", "doc": { "activity": "Music" } },
            { "id": "plain", "doc": {} },
        ]});
        assert_eq!(doc_fixes(&spaces, "uuid-1", "Coding"), vec!["coding".to_string()]);
        let rules = json!({ "rules": [
            { "name": "org.kde.kwrite", "activityName": "coding" },
            { "name": "konsole", "activityName": "System Configuration" },
            { "name": "dolphin", "activityName": null },
        ]});
        assert_eq!(rule_fixes(&rules, "Coding"), vec!["org.kde.kwrite".to_string()]);
        assert_eq!(rule_fixes(&rules, "System-Configuration"), vec!["konsole".to_string()]);
    }

    #[test]
    fn renames_between_reports() {
        let b = vec![("a".to_string(), "Coding".to_string()), ("b".to_string(), "Music".to_string())];
        let a = vec![("a".to_string(), "Code".to_string()), ("b".to_string(), "Music".to_string()), ("c".to_string(), "New".to_string())];
        assert_eq!(renames(&b, &a), vec![("a".to_string(), "Coding".to_string(), "Code".to_string())]);
    }

    #[test]
    fn cli_commands() {
        let a = |s: &str| s.split(' ').map(String::from).collect::<Vec<_>>();
        assert_eq!(parse_cli(&a("new Live Sound --icon audio-card")).unwrap().unwrap(), json!({"op": "create", "name": "Live Sound", "icon": "audio-card"}));
        assert_eq!(parse_cli(&a("rename 3 Code")).unwrap().unwrap(), json!({"op": "rename", "activity": "3", "name": "Code"}));
        assert_eq!(parse_cli(&a("move gaming 1")).unwrap().unwrap(), json!({"op": "move", "activity": "gaming", "to": 1}));
        assert!(parse_cli(&a("move gaming x")).unwrap().is_err());
        assert!(parse_cli(&a("list")).is_none());
        let l = users();
        let r = resolve_move(&l, &json!({"op": "move", "activity": "gaming", "to": 1})).unwrap();
        assert_eq!(r["order"][0], "gaming");
        assert_eq!(r["order"][1], "default");
    }
}
