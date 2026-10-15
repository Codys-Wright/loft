//! Writing space documents (Settings → Spaces, SPACES.md P6): create, patch,
//! delete, reorder, and "New Space from Current Desktop".
//!
//! Every write is validated before it touches the disk: the library is
//! loaded with the change overlaid ([`Catalog::load_overlay`]), and a change
//! that adds a problem (an unknown role, a workspace another space owns, a
//! template parameter missing …) is refused with that problem.
//!
//! The library's singletons replace the built-in set as soon as it has any
//! (`model`), so the first write that touches a singleton **seeds** the
//! library with the built-ins first (§12.9: copied once, never overwritten).
//! An instance (`instances/<id>.json`) keeps its template's fields: a patch
//! goes into its `overrides` (merge patch), except `order`, `archived` and
//! `params`, which are the instance's own.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value, json};

use super::apps::Win;
use super::expr::slug;
use super::model::{BUILTIN, Catalog, Env, Overlay, merge_patch};
use super::plan::State;
use super::roles;
use crate::state::write_atomic;

/// Ids name files and workspaces: lowercase letters, digits, `-` and `_`.
pub fn validate_id(id: &str) -> Result<()> {
    let ok = !id.is_empty()
        && id.len() <= 48
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
        && id.chars().next().is_some_and(|c| c.is_ascii_alphanumeric());
    if !ok {
        bail!("`{id}` isn't a usable space id (a–z, 0–9, - and _, up to 48)");
    }
    Ok(())
}

fn kind(doc: &Value) -> &str {
    doc.get("kind").and_then(Value::as_str).unwrap_or("")
}

/// The library's own singletons (files at its top level), from disk.
fn own_singletons(dir: &Path) -> bool {
    std::fs::read_dir(dir).is_ok_and(|rd| {
        rd.filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == "json"))
            .any(|p| {
                std::fs::read_to_string(&p)
                    .ok()
                    .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                    .is_some_and(|v| kind(&v) == "space")
            })
    })
}

/// The built-in singletons as library files, when the library has none
/// of its own yet (else nothing).
pub fn seed_overlay(dir: &Path) -> Overlay {
    let mut o = Overlay::new();
    if own_singletons(dir) {
        return o;
    }
    for (name, text) in BUILTIN {
        let v: Value = serde_json::from_str(text).expect("built-in space documents are valid JSON");
        if kind(&v) == "space" {
            o.insert(dir.join(format!("{name}.json")), Some(v));
        }
    }
    o
}

/// What a write did.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Written {
    pub ok: bool,
    /// The space written (None: deleted).
    pub id: Option<String>,
    pub written: Vec<PathBuf>,
    pub removed: Vec<PathBuf>,
}

/// Validate `overlay` against the library, then write it. `expect`: a
/// space id that must exist afterwards.
fn commit(dir: &Path, env: &Env, overlay: Overlay, expect: Option<&str>) -> Result<Written> {
    let before = Catalog::load(Some(dir), env);
    let after = Catalog::load_overlay(Some(dir), env, &overlay);
    let new: Vec<&String> = after
        .problems
        .iter()
        .filter(|p| !before.problems.contains(p))
        .collect();
    if !new.is_empty() {
        bail!(
            "{}",
            new.iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join("; ")
        );
    }
    if let Some(id) = expect
        && !after.spaces.iter().any(|s| s.id == id)
    {
        bail!("space `{id}` didn't load after the change");
    }
    let mut out = Written {
        ok: true,
        id: expect.map(String::from),
        written: Vec::new(),
        removed: Vec::new(),
    };
    for (p, v) in overlay {
        match v {
            Some(v) => {
                let text = serde_json::to_string_pretty(&v)? + "\n";
                write_atomic(&p, &text).with_context(|| format!("writing {}", p.display()))?;
                out.written.push(p);
            }
            None => match std::fs::remove_file(&p) {
                Ok(()) => out.removed.push(p),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e).with_context(|| format!("removing {}", p.display())),
            },
        }
    }
    Ok(out)
}

fn next_order(cat: &Catalog) -> f64 {
    cat.spaces
        .iter()
        .map(|s| s.order)
        .fold(0.0, f64::max)
        .floor()
        + 1.0
}

/// A space's document as it would be edited: from the overlay, else its
/// library file, else (a built-in) the seeded copy. → (path, document).
fn editable(
    cat: &Catalog,
    dir: &Path,
    id: &str,
    overlay: &mut Overlay,
) -> Result<(PathBuf, Value)> {
    let s = cat
        .spaces
        .iter()
        .find(|s| s.id == id)
        .with_context(|| format!("no space `{id}`"))?;
    let path = match &s.source {
        Some(p) => p.clone(),
        None => {
            let path = dir.join(format!("{id}.json"));
            if !overlay.contains_key(&path) {
                for (p, v) in seed_overlay(dir) {
                    overlay.entry(p).or_insert(v);
                }
            }
            path
        }
    };
    let doc = match overlay.get(&path) {
        Some(Some(v)) => v.clone(),
        Some(None) => bail!("space `{id}` is being deleted"),
        None => {
            let t = std::fs::read_to_string(&path)
                .with_context(|| format!("reading {}", path.display()))?;
            serde_json::from_str(&t).with_context(|| format!("parsing {}", path.display()))?
        }
    };
    Ok((path, doc))
}

/// Apply a merge patch to a space (into `overlay`, not written).
fn patch_into(
    cat: &Catalog,
    dir: &Path,
    id: &str,
    patch: &Value,
    overlay: &mut Overlay,
) -> Result<()> {
    let p = patch.as_object().context("a patch is a JSON object")?;
    for k in ["id", "kind", "template", "$schema"] {
        if p.contains_key(k) {
            bail!("`{k}` can't be changed (make a new space instead)");
        }
    }
    let (path, mut doc) = editable(cat, dir, id, overlay)?;
    if kind(&doc) == "space-instance" {
        let o = doc
            .as_object_mut()
            .context("an instance is a JSON object")?;
        let mut rest = Map::new();
        for (k, v) in p {
            match k.as_str() {
                "order" | "archived" => {
                    if v.is_null() {
                        o.remove(k);
                    } else {
                        o.insert(k.clone(), v.clone());
                    }
                }
                "params" => merge_patch(o.entry("params").or_insert(json!({})), v),
                _ => {
                    rest.insert(k.clone(), v.clone());
                }
            }
        }
        if !rest.is_empty() {
            merge_patch(
                o.entry("overrides").or_insert(json!({})),
                &Value::Object(rest),
            );
        }
    } else {
        merge_patch(&mut doc, patch);
    }
    overlay.insert(path, Some(doc));
    Ok(())
}

/// Create a space: a singleton (`"kind": "space"`, written as `<id>.json`)
/// or an instance of a template (`instances/<id>.json`). `replace`: an
/// existing space of that id is overwritten.
pub fn save(dir: &Path, env: &Env, mut doc: Value, replace: bool) -> Result<Written> {
    let cat = Catalog::load(Some(dir), env);
    let o = doc
        .as_object_mut()
        .context("a space document is a JSON object")?;
    if !o.contains_key("order") {
        o.insert("order".into(), json!(next_order(&cat)));
    }
    let mut overlay = Overlay::new();
    let (id, path) = match kind(&doc) {
        "space" => {
            let id = doc
                .get("id")
                .and_then(Value::as_str)
                .context("a space needs an `id`")?
                .to_string();
            validate_id(&id)?;
            overlay.extend(seed_overlay(dir));
            (id.clone(), dir.join(format!("{id}.json")))
        }
        "space-instance" => {
            let tid = doc.get("template").and_then(Value::as_str).unwrap_or("");
            let t = cat
                .templates
                .get(tid)
                .with_context(|| format!("no template `{tid}`"))?;
            let id = super::model::instantiate(t, Some(&doc), env)?.id;
            validate_id(&id)?;
            (id.clone(), dir.join("instances").join(format!("{id}.json")))
        }
        k => bail!("can't save a document of kind `{k}` (space or space-instance)"),
    };
    if let Some(s) = cat.spaces.iter().find(|s| s.id == id) {
        if !replace {
            bail!("there's already a space `{id}` ({})", s.name);
        }
        if let Some(src) = &s.source
            && *src != path
        {
            overlay.insert(src.clone(), None);
        }
    }
    overlay.insert(path, Some(doc));
    commit(dir, env, overlay, Some(&id))
}

pub fn patch(dir: &Path, env: &Env, id: &str, p: &Value) -> Result<Written> {
    let cat = Catalog::load(Some(dir), env);
    let mut overlay = Overlay::new();
    patch_into(&cat, dir, id, p, &mut overlay)?;
    commit(dir, env, overlay, Some(id))
}

/// Delete a space's document. The library keeps at least one singleton
/// (without any, the built-in set would come back).
pub fn delete(dir: &Path, env: &Env, id: &str) -> Result<Written> {
    let cat = Catalog::load(Some(dir), env);
    let mut overlay = Overlay::new();
    let (path, doc) = editable(&cat, dir, id, &mut overlay)?;
    overlay.insert(path, None);
    if kind(&doc) == "space" {
        let left = overlay
            .iter()
            .filter(|(p, v)| p.parent() == Some(dir) && v.is_some())
            .count()
            + cat
                .spaces
                .iter()
                .filter(|s| {
                    s.template.is_none()
                        && s.source.as_ref().is_some_and(|p| !overlay.contains_key(p))
                })
                .count();
        if left == 0 {
            bail!("`{id}` is the last space; make another one before deleting it");
        }
    }
    let mut w = commit(dir, env, overlay, None)?;
    w.id = None;
    Ok(w)
}

/// Put the given spaces first, in this order (`order` 1, 2, …); the rest
/// follow in their current order.
pub fn reorder(dir: &Path, env: &Env, ids: &[String]) -> Result<Written> {
    let cat = Catalog::load(Some(dir), env);
    let mut all: Vec<String> = Vec::new();
    for id in ids {
        if !cat.spaces.iter().any(|s| &s.id == id) {
            bail!("no space `{id}`");
        }
        if !all.contains(id) {
            all.push(id.clone());
        }
    }
    for s in &cat.spaces {
        if !all.contains(&s.id) {
            all.push(s.id.clone());
        }
    }
    let mut overlay = Overlay::new();
    for (i, id) in all.iter().enumerate() {
        let want = (i + 1) as f64;
        if cat.spaces.iter().find(|s| &s.id == id).map(|s| s.order) != Some(want) {
            patch_into(&cat, dir, id, &json!({ "order": i + 1 }), &mut overlay)?;
        }
    }
    commit(dir, env, overlay, ids.first().map(String::as_str))
}

// ── New Space from Current Desktop ───────────────────────────────────────

/// A process's command line (`/proc/<pid>/cmdline`), made portable: Nix
/// store paths become the command's name (`.kitty-wrapped` → `kitty`), and
/// an interpreter running a store script gives way to the script.
pub fn command_of(proc_root: &Path, pid: i32) -> Option<Vec<String>> {
    let raw = std::fs::read(proc_root.join(pid.to_string()).join("cmdline")).ok()?;
    let mut args: Vec<String> = raw
        .split(|b| *b == 0)
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect();
    while args.last().is_some_and(String::is_empty) {
        args.pop();
    }
    portable_command(args)
}

pub fn portable_command(mut args: Vec<String>) -> Option<Vec<String>> {
    let base = |s: &str| s.rsplit('/').next().unwrap_or(s).to_string();
    let interpreter = |s: &str| {
        let b = base(s);
        [
            "python", "perl", "node", "bash", "sh", "ruby", "electron", "env",
        ]
        .iter()
        .any(|i| b.starts_with(i))
    };
    while args.len() > 1 && interpreter(&args[0]) && args[1].starts_with("/nix/store/") {
        args.remove(0);
    }
    let first = args.first()?.clone();
    if first.is_empty() {
        return None;
    }
    if first.starts_with("/nix/store/")
        || first.starts_with("/run/current-system/")
        || first.contains("/.nix-profile/")
        || first.starts_with("/etc/profiles/")
    {
        let mut b = base(&first);
        if let Some(x) = b.strip_prefix('.') {
            b = x.to_string();
        }
        if let Some(x) = b.strip_suffix("-wrapped") {
            b = x.to_string();
        }
        args[0] = b;
    }
    Some(args)
}

/// A space document capturing what the displays show now: each display's
/// active workspace becomes the space's workspace on that display's role,
/// with its windows as apps (column order and widths; `exec` from the
/// process's command line). Displays showing nothing are `keep`. The space
/// gets its own workspaces (`<id>`, `<id>/<role>`): its first activation
/// gathers the windows there.
pub fn capture(
    st: &State,
    wins: &[Win],
    commands: &dyn Fn(i32) -> Option<Vec<String>>,
    id: &str,
    name: &str,
    icon: &str,
) -> Value {
    let roles_of = roles::roles(&st.displays, st.main.as_deref());
    let main = roles::main_display(&st.displays, st.main.as_deref()).map(|d| d.name.clone());
    let mut displays = Map::new();
    let mut ordered: Vec<&roles::Display> = st.displays.iter().collect();
    ordered.sort_by_key(|d| (Some(&d.name) != main.as_ref(), d.x, d.y));
    for d in ordered {
        let rs = roles_of.get(&d.name).cloned().unwrap_or_default();
        let role = rs
            .iter()
            .find(|r| !displays.contains_key(*r) && *r != "*")
            .cloned();
        let Some(role) = role else { continue };
        let ws = st
            .workspaces
            .iter()
            .find(|w| w.output.as_deref() == Some(&d.name) && w.is_active);
        let mut on: Vec<&Win> = ws
            .map(|ws| {
                wins.iter()
                    .filter(|w| w.workspace_id == Some(ws.id) && w.app_id.is_some())
                    .collect()
            })
            .unwrap_or_default();
        on.sort_by_key(|w| (w.floating, w.column.unwrap_or(usize::MAX), w.id));
        if on.is_empty() && role != "main" {
            displays.insert(role, json!("keep"));
            continue;
        }
        let mut apps: Vec<Value> = Vec::new();
        let mut ids: Vec<String> = Vec::new();
        for w in on {
            let app_id = w.app_id.clone().unwrap_or_default();
            let short = app_id.rsplit('.').next().unwrap_or(&app_id);
            let mut aid = slug(short);
            if aid.is_empty() {
                aid = "app".into();
            }
            let mut n = 2;
            let stem = aid.clone();
            while ids.contains(&aid) {
                aid = format!("{stem}-{n}");
                n += 1;
            }
            ids.push(aid.clone());
            let mut app = Map::new();
            app.insert("id".into(), json!(aid));
            match w.pid.and_then(commands) {
                Some(cmd) => {
                    app.insert("exec".into(), json!(cmd));
                }
                None => {
                    app.insert("launch".into(), json!(false));
                }
            }
            app.insert(
                "match".into(),
                json!({ "appId": format!("^{}$", regex::escape(&app_id)) }),
            );
            if w.floating {
                app.insert("open".into(), json!("floating"));
            } else if d.width > 0 {
                let f = f64::from(w.size.0) / f64::from(d.width);
                if f >= 0.95 {
                    app.insert("open".into(), json!("maximized"));
                } else if f > 0.05 {
                    app.insert("width".into(), json!((f * 100.0).round() / 100.0));
                }
            }
            apps.push(Value::Object(app));
        }
        displays.insert(role, json!({ "apps": apps }));
    }
    displays.insert("*".into(), json!("keep"));
    json!({
        "$schema": "https://loft.dev/schema/space-1.json",
        "kind": "space",
        "id": id,
        "name": name,
        "icon": icon,
        "displays": displays,
        "startup": "first-activate",
    })
}

/// An unused id for a new space named `name`.
pub fn fresh_id(cat: &Catalog, name: &str) -> String {
    let mut stem = slug(name);
    if stem.is_empty() {
        stem = "space".into();
    }
    stem.truncate(40);
    let taken =
        |id: &str| cat.spaces.iter().any(|s| s.id == id) || cat.spaces.iter().any(|s| s.owns(id));
    if !taken(&stem) {
        return stem;
    }
    (2..)
        .map(|n| format!("{stem}-{n}"))
        .find(|c| !taken(c))
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spaces::model::tests::env;
    use crate::spaces::roles::Display;

    fn scratch(name: &str) -> PathBuf {
        crate::config::tests_support::scratch(name)
    }

    fn names(cat: &Catalog) -> Vec<String> {
        cat.active().iter().map(|s| s.id.clone()).collect()
    }

    #[test]
    fn creating_a_space_seeds_the_builtins_first() {
        let d = scratch("spaces-edit-create");
        let w = save(
            &d,
            &env(),
            json!({ "kind": "space", "id": "writing", "name": "Writing", "icon": "󰏫",
                    "displays": { "main": {}, "*": "keep" } }),
            false,
        )
        .unwrap();
        assert_eq!(w.id.as_deref(), Some("writing"));
        assert!(d.join("music.json").is_file(), "built-ins seeded");
        let cat = Catalog::load(Some(&d), &env());
        assert!(cat.problems.is_empty(), "{:?}", cat.problems);
        assert_eq!(
            names(&cat),
            [
                "main", "music", "video", "comms", "gaming", "task", "writing"
            ]
        );
        // Again: refused, unless replacing.
        let doc =
            json!({ "kind": "space", "id": "writing", "name": "W2", "displays": { "main": {} } });
        assert!(save(&d, &env(), doc.clone(), false).is_err());
        save(&d, &env(), doc, true).unwrap();
        assert_eq!(
            Catalog::load(Some(&d), &env())
                .find("writing")
                .unwrap()
                .name,
            "W2"
        );
    }

    #[test]
    fn invalid_writes_are_refused_and_leave_the_disk_alone() {
        let d = scratch("spaces-edit-invalid");
        // A workspace another space owns.
        let e = save(
            &d,
            &env(),
            json!({ "kind": "space", "id": "beats", "name": "Beats",
                    "displays": { "main": { "workspace": "music" } } }),
            false,
        )
        .unwrap_err();
        assert!(e.to_string().contains("already `music`'s"), "{e}");
        assert!(!d.join("music.json").exists(), "nothing written");
        // Unknown role, bad id.
        assert!(
            save(
                &d,
                &env(),
                json!({ "kind": "space", "id": "x", "displays": { "middle": "keep" } }),
                false
            )
            .unwrap_err()
            .to_string()
            .contains("unknown display role")
        );
        assert!(
            save(
                &d,
                &env(),
                json!({ "kind": "space", "id": "Bad Id" }),
                false
            )
            .is_err()
        );
        assert!(patch(&d, &env(), "music", &json!({ "id": "other" })).is_err());
        assert!(patch(&d, &env(), "music", &json!({ "fold": "sideways" })).is_err());
        assert!(!d.join("music.json").exists());
    }

    #[test]
    fn patch_singletons_and_instances() {
        let d = scratch("spaces-edit-patch");
        // Patching a built-in seeds the set, then edits the copy.
        patch(
            &d,
            &env(),
            "music",
            &json!({ "dock": { "visible": "autohide" }, "bar": { "hidden": true } }),
        )
        .unwrap();
        let cat = Catalog::load(Some(&d), &env());
        let m = cat.find("music").unwrap();
        assert_eq!(m.doc["dock"]["visible"], json!("autohide"));
        assert_eq!(
            m.doc["dock"]["mode"],
            json!("replace"),
            "merge, not replace"
        );
        assert_eq!(m.doc["bar"]["hidden"], json!(true));
        assert_eq!(cat.active().len(), 6);

        // An instance: the patch lands in `overrides`, order on the instance.
        std::fs::create_dir_all(d.join("instances")).unwrap();
        std::fs::write(
            d.join("instances/proj-loft.json"),
            r#"{ "kind": "space-instance", "template": "project", "params": { "name": "loft", "dir": "/l" } }"#,
        )
        .unwrap();
        patch(
            &d,
            &env(),
            "proj-loft",
            &json!({ "icon": "󰣪", "order": 0.5, "focus": { "dnd": true } }),
        )
        .unwrap();
        let raw: Value = serde_json::from_str(
            &std::fs::read_to_string(d.join("instances/proj-loft.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(raw["order"], json!(0.5));
        assert_eq!(raw["overrides"]["icon"], json!("󰣪"));
        assert_eq!(raw["overrides"]["focus"]["dnd"], json!(true));
        let cat = Catalog::load(Some(&d), &env());
        assert_eq!(names(&cat)[0], "proj-loft");
        assert_eq!(cat.find("proj-loft").unwrap().icon, "󰣪");
    }

    #[test]
    fn delete_and_reorder() {
        let d = scratch("spaces-edit-delete");
        delete(&d, &env(), "task").unwrap();
        let cat = Catalog::load(Some(&d), &env());
        assert_eq!(names(&cat), ["main", "music", "video", "comms", "gaming"]);
        reorder(&d, &env(), &["gaming".into(), "main".into()]).unwrap();
        let cat = Catalog::load(Some(&d), &env());
        assert_eq!(names(&cat), ["gaming", "main", "music", "video", "comms"]);
        // The last singleton stays.
        for id in ["gaming", "main", "music", "video"] {
            delete(&d, &env(), id).unwrap();
        }
        assert!(
            delete(&d, &env(), "comms")
                .unwrap_err()
                .to_string()
                .contains("last space")
        );
        assert!(delete(&d, &env(), "nope").is_err());
    }

    #[test]
    fn portable_commands() {
        let v = |a: &[&str]| portable_command(a.iter().map(|s| s.to_string()).collect());
        assert_eq!(
            v(&["/nix/store/abc-kitty/bin/.kitty-wrapped", "--class", "x"]).unwrap(),
            ["kitty", "--class", "x"]
        );
        assert_eq!(
            v(&[
                "/nix/store/p-python3/bin/python3.12",
                "/nix/store/q-app/bin/.qpwgraph-wrapped"
            ])
            .unwrap(),
            ["qpwgraph"]
        );
        assert_eq!(v(&["/usr/bin/foo", "a"]).unwrap(), ["/usr/bin/foo", "a"]);
        assert!(v(&[]).is_none());
    }

    #[test]
    fn capture_the_desktop() {
        let disp = |name: &str, x: i32, w: i32, h: i32| Display {
            name: name.into(),
            identity: name.into(),
            x,
            y: 0,
            width: w,
            height: h,
        };
        let ws = |id: u64, out: &str, active: bool| niri_ipc::Workspace {
            id,
            idx: 1,
            name: None,
            output: Some(out.into()),
            is_urgent: false,
            is_active: active,
            is_focused: false,
            active_window_id: None,
        };
        let st = State {
            displays: vec![
                disp("L", 0, 1440, 2560),
                disp("C", 1440, 3440, 1440),
                disp("R", 4880, 2560, 1440),
            ],
            workspaces: vec![
                ws(1, "L", true),
                ws(2, "C", true),
                ws(3, "R", true),
                ws(4, "C", false),
            ],
            focused_window: None,
            main: None,
        };
        let win = |id: u64, app: &str, wsid: u64, col: usize, w: i32, pid: i32| Win {
            id,
            app_id: Some(app.into()),
            workspace_id: Some(wsid),
            column: Some(col),
            size: (w, 1000),
            pid: Some(pid),
            ..Default::default()
        };
        let wins = vec![
            win(10, "kitty", 2, 2, 1135, 100),
            win(11, "dev.zed.Zed", 2, 1, 2305, 101),
            win(12, "kitty", 2, 3, 1135, 102),
            win(13, "org.rncbc.qpwgraph", 3, 1, 2560, 103),
            win(14, "elsewhere", 4, 1, 100, 104),
        ];
        let cmds = |pid: i32| (pid != 101).then(|| vec![format!("cmd{pid}")]);
        let doc = capture(&st, &wins, &cmds, "now", "Now", "󰕰");
        let d = &doc["displays"];
        let ids: Vec<_> = d["main"]["apps"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["zed", "kitty", "kitty-2"]);
        assert_eq!(
            d["main"]["apps"][0]["launch"],
            json!(false),
            "no command line: gather only"
        );
        assert_eq!(d["main"]["apps"][0]["width"], json!(0.67));
        assert_eq!(d["main"]["apps"][1]["exec"], json!(["cmd100"]));
        assert_eq!(d["main"]["apps"][1]["match"]["appId"], json!("^kitty$"));
        assert_eq!(d["right"]["apps"][0]["open"], json!("maximized"));
        assert_eq!(d["left"], json!("keep"), "an empty display is kept");
        assert_eq!(d["*"], json!("keep"));
        // It's a valid space.
        let s = crate::spaces::model::instantiate(&doc, None, &env()).unwrap();
        assert_eq!(s.main_workspace(), Some("now"));
    }
}
