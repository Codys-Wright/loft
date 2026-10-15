//! Space documents (`schemas/space-1.json`) → resolved [`Space`]s.
//!
//! - A **singleton** (`"kind": "space"`) is used as is (strings may still
//!   use `${id}`, `${state}`, `${home}`, `${profiles}`).
//! - A **template** (`"kind": "space-template"`) has `params` and an
//!   `instance` naming pattern; an **instance** (`"kind": "space-instance"`)
//!   fills the params in. Instantiating interpolates every string
//!   (`expr`), drops apps whose `when` is false, then applies the instance's
//!   `overrides` (RFC 7386 merge patch).
//!
//! Where documents come from ([`Catalog::load`]):
//!
//! - built-in templates and singletons: `spaces/templates/*.json` in the
//!   repo, compiled in;
//! - the library, `$LOFT_SPACES_DIR` (default `<$LOFT_LIBRARY>/Spaces`, i.e. `~/Documents/Loft/Spaces`;
//!   `LOFT_LIBRARY=none` turns it off): `<id>.json` singletons,
//!   `templates/*.json` (override built-ins by id), `instances/*.json`.
//!
//! The library's singletons replace the built-in ones as a set as soon as
//! it has any (seeding copies the built-ins there first, §12.9); without
//! any, the built-in singletons are the spaces.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Serialize;
use serde_json::{Map, Value, json};

use super::expr::{self, Ctx};
use super::roles;

/// The built-in documents (`spaces/templates/`), in `order`.
pub const BUILTIN: &[(&str, &str)] = &[
    (
        "main",
        include_str!("../../../../spaces/templates/main.json"),
    ),
    (
        "music",
        include_str!("../../../../spaces/templates/music.json"),
    ),
    (
        "video",
        include_str!("../../../../spaces/templates/video.json"),
    ),
    (
        "comms",
        include_str!("../../../../spaces/templates/comms.json"),
    ),
    (
        "gaming",
        include_str!("../../../../spaces/templates/gaming.json"),
    ),
    (
        "task",
        include_str!("../../../../spaces/templates/task.json"),
    ),
    (
        "project",
        include_str!("../../../../spaces/templates/project.json"),
    ),
];

/// A bound display whose role has no display in the layout (§3.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Fold {
    /// Its workspace lives on main's display, right below the space's main workspace.
    #[default]
    Stack,
    /// No workspace of its own: its apps join main's workspace as columns.
    Columns,
    /// Left out while the display is missing.
    Skip,
}

/// Where keyboard focus lands on activation (§3.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Target {
    #[default]
    Main,
    /// The display you were on, when the space binds it (else main).
    Stay,
}

/// What a space puts on one role.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Binding {
    Keep,
    Bound(Bound),
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Bound {
    pub workspace: String,
    /// Apps in column order (resolved JSON; spin-up is phase P3's).
    pub apps: Vec<Value>,
    /// niri workspace `layout {}` overrides, KDL as JSON (see `render`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub layout: Option<Map<String, Value>>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Space {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub order: f64,
    /// Instances: the template they were made from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template: Option<String>,
    pub displays: BTreeMap<String, Binding>,
    pub fold: Fold,
    pub target: Target,
    pub startup: String,
    pub archived: bool,
    /// The whole resolved document (dock, bar, menubar, focus, theme,
    /// facets, wallpapers … for the shell).
    pub doc: Value,
    /// The library file it came from (None: a built-in).
    #[serde(skip)]
    pub source: Option<PathBuf>,
}

impl Space {
    /// The binding of a role (`None`: the space doesn't name it).
    pub fn binding(&self, role: &str) -> Option<&Binding> {
        self.displays.get(role)
    }

    /// Every workspace the space owns, `main`'s first.
    pub fn workspaces(&self) -> Vec<(&str, &Bound)> {
        let mut v: Vec<(&str, &Bound)> = self
            .displays
            .iter()
            .filter_map(|(r, b)| match b {
                Binding::Bound(b) => Some((r.as_str(), b)),
                Binding::Keep => None,
            })
            .collect();
        v.sort_by_key(|(r, _)| *r != "main");
        v
    }

    pub fn main_workspace(&self) -> Option<&str> {
        match self.displays.get("main") {
            Some(Binding::Bound(b)) => Some(&b.workspace),
            _ => None,
        }
    }

    /// niri matches workspace names case-insensitively.
    pub fn owns(&self, workspace: &str) -> bool {
        self.workspaces()
            .iter()
            .any(|(_, b)| b.workspace.eq_ignore_ascii_case(workspace))
    }
}

/// RFC 7386 JSON merge patch.
pub fn merge_patch(target: &mut Value, patch: &Value) {
    let Value::Object(p) = patch else {
        *target = patch.clone();
        return;
    };
    if !target.is_object() {
        *target = Value::Object(Map::new());
    }
    let t = target.as_object_mut().unwrap();
    for (k, v) in p {
        if v.is_null() {
            t.remove(k);
        } else {
            merge_patch(t.entry(k.clone()).or_insert(Value::Null), v);
        }
    }
}

/// What `${state}`, `${home}` and `${profiles}` stand for.
#[derive(Debug, Clone)]
pub struct Env {
    pub state: String,
    pub home: String,
    /// Where per-instance browser profiles live (Chromium `--user-data-dir`,
    /// §12.5): `$LOFT_SPACES_PROFILES`, else `<state>/browser`.
    pub profiles: String,
}

impl Env {
    pub fn from_process(state: &Path) -> Self {
        let profiles = std::env::var_os("LOFT_SPACES_PROFILES")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| state.join("browser"));
        Env {
            state: state.display().to_string(),
            home: std::env::var("HOME").unwrap_or_default(),
            profiles: profiles.display().to_string(),
        }
    }
}

fn kind(doc: &Value) -> &str {
    doc.get("kind").and_then(Value::as_str).unwrap_or("")
}

fn str_field<'a>(doc: &'a Value, key: &str) -> Option<&'a str> {
    doc.get(key).and_then(Value::as_str)
}

/// Drop apps whose `when` is falsy (and the `when` keys themselves).
fn filter_apps(displays: &mut Value) {
    let Some(m) = displays.as_object_mut() else {
        return;
    };
    for b in m.values_mut() {
        if let Some(apps) = b.get_mut("apps").and_then(Value::as_array_mut) {
            apps.retain(|a| a.get("when").is_none_or(expr::truthy));
            for a in apps.iter_mut() {
                if let Some(o) = a.as_object_mut() {
                    o.remove("when");
                }
            }
        }
    }
}

/// A singleton (`template` of kind "space", `instance` None) or a template
/// filled in by an instance → the resolved space.
pub fn instantiate(template: &Value, instance: Option<&Value>, env: &Env) -> Result<Space> {
    let mut ctx = Ctx::new();
    ctx.insert("state".into(), json!(env.state));
    ctx.insert("home".into(), json!(env.home));
    ctx.insert("profiles".into(), json!(env.profiles));
    let mut doc = template.clone();
    let tid = str_field(template, "id").unwrap_or("?").to_string();
    let (id, name, base) = match (kind(template), instance) {
        ("space", None) => {
            let id = tid.clone();
            ctx.insert("id".into(), json!(id));
            let name = str_field(template, "name").unwrap_or(&id).to_string();
            (id.clone(), name, id)
        }
        ("space-template", Some(inst)) => {
            let given = inst
                .get("params")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            let params = template
                .get("params")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            for (k, def) in &params {
                let v = match given.get(k) {
                    Some(v) => v.clone(),
                    None if def.get("required").and_then(Value::as_bool) == Some(true) => {
                        bail!("template `{tid}`: missing required parameter `{k}`")
                    }
                    None => def.get("default").cloned().unwrap_or(Value::Null),
                };
                ctx.insert(k.clone(), v);
            }
            for k in given.keys() {
                if !params.contains_key(k) {
                    bail!("template `{tid}` has no parameter `{k}`");
                }
            }
            let pattern = template.get("instance").cloned().unwrap_or(json!({}));
            let id = match str_field(inst, "id") {
                Some(id) => id.to_string(),
                None => expr::text(&expr::interpolate(
                    pattern.get("id").unwrap_or(&json!(tid)),
                    &ctx,
                )?),
            };
            ctx.insert("id".into(), json!(id));
            let name = match pattern.get("name") {
                Some(n) => expr::text(&expr::interpolate(n, &ctx)?),
                None => id.clone(),
            };
            let base = match pattern.get("workspace") {
                Some(w) => expr::text(&expr::interpolate(w, &ctx)?),
                None => id.clone(),
            };
            (id, name, base)
        }
        ("space-template", None) => bail!("`{tid}` is a template: make an instance of it"),
        (k, _) => bail!("`{tid}`: not a space or space template (kind `{k}`)"),
    };
    if id.is_empty() || base.is_empty() {
        bail!("`{tid}`: the instance id / workspace interpolates to nothing");
    }

    let o = doc
        .as_object_mut()
        .context("a space document is a JSON object")?;
    for k in ["kind", "params", "instance", "$schema"] {
        o.remove(k);
    }
    let mut doc =
        expr::interpolate(&doc, &ctx).with_context(|| format!("interpolating `{tid}`"))?;
    if let Some(d) = doc.get_mut("displays") {
        filter_apps(d);
    }
    let o = doc.as_object_mut().unwrap();
    o.insert("id".into(), json!(id));
    o.insert("name".into(), json!(name));
    if let Some(inst) = instance {
        o.insert("template".into(), json!(tid));
        for k in ["order", "archived", "created"] {
            if let Some(v) = inst.get(k) {
                o.insert(k.into(), v.clone());
            }
        }
        if let Some(p) = inst.get("overrides") {
            merge_patch(&mut doc, p);
        }
    }
    parse_space(doc, &base)
}

fn parse_space(doc: Value, base: &str) -> Result<Space> {
    let id = str_field(&doc, "id").unwrap_or_default().to_string();
    let mut displays = BTreeMap::new();
    if let Some(m) = doc.get("displays").and_then(Value::as_object) {
        for (role, b) in m {
            if !roles::is_known_role(role) {
                bail!("space `{id}`: unknown display role `{role}`");
            }
            let binding = match b {
                Value::Null => Binding::Keep,
                Value::String(s) if s == "keep" => Binding::Keep,
                Value::Object(o) => {
                    let workspace = match o.get("workspace") {
                        Some(Value::String(w)) if !w.is_empty() => w.clone(),
                        Some(Value::Null) | None if role == "main" => base.to_string(),
                        Some(Value::Null) | None => format!("{base}/{role}"),
                        Some(other) => bail!("space `{id}`: displays.{role}.workspace: {other}"),
                    };
                    let apps = match o.get("apps") {
                        Some(Value::Array(a)) => a.clone(),
                        None | Some(Value::Null) => Vec::new(),
                        Some(_) => bail!("space `{id}`: displays.{role}.apps is not a list"),
                    };
                    for a in &apps {
                        if a.get("id")
                            .and_then(Value::as_str)
                            .is_none_or(str::is_empty)
                        {
                            bail!("space `{id}`: an app on `{role}` has no id");
                        }
                    }
                    let layout = match o.get("layout") {
                        Some(Value::Object(l)) => Some(l.clone()),
                        None | Some(Value::Null) => None,
                        Some(_) => bail!("space `{id}`: displays.{role}.layout is not an object"),
                    };
                    Binding::Bound(Bound {
                        workspace,
                        apps,
                        layout,
                    })
                }
                other => bail!(
                    "space `{id}`: displays.{role}: expected \"keep\" or an object, got {other}"
                ),
            };
            displays.insert(role.clone(), binding);
        }
    }
    let enum_field = |key: &str, values: &[&str]| -> Result<Option<String>> {
        match doc.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) if values.contains(&s.as_str()) => Ok(Some(s.clone())),
            Some(v) => bail!("space `{id}`: {key} must be one of {values:?}, got {v}"),
        }
    };
    let fold = match enum_field("fold", &["stack", "columns", "skip"])?.as_deref() {
        Some("columns") => Fold::Columns,
        Some("skip") => Fold::Skip,
        _ => Fold::Stack,
    };
    let target = match enum_field("target", &["main", "stay"])?.as_deref() {
        Some("stay") => Target::Stay,
        _ => Target::Main,
    };
    let startup = enum_field("startup", &["first-activate", "login", "never"])?
        .unwrap_or_else(|| "first-activate".into());
    Ok(Space {
        name: str_field(&doc, "name").unwrap_or(&id).to_string(),
        icon: str_field(&doc, "icon").unwrap_or("").to_string(),
        order: doc.get("order").and_then(Value::as_f64).unwrap_or(100.0),
        template: str_field(&doc, "template").map(String::from),
        archived: doc
            .get("archived")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        displays,
        fold,
        target,
        startup,
        id,
        doc,
        source: None,
    })
}

/// Where the library's space documents live: `$LOFT_SPACES_DIR`, else
/// `<library>/Spaces`, the library being `$LOFT_LIBRARY` (default
/// `~/Documents/Loft`; `none` / `off` turns it off), as in cli/loft/library.py.
pub fn library_dir() -> Option<PathBuf> {
    let lib = std::env::var("LOFT_LIBRARY").unwrap_or_default();
    let lib = lib.trim();
    if lib == "none" || lib == "off" {
        return None;
    }
    if let Some(v) = std::env::var_os("LOFT_SPACES_DIR").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(v));
    }
    let home = std::env::home_dir();
    let root = match lib.strip_prefix("~/") {
        _ if lib.is_empty() => home?.join("Documents/Loft"),
        Some(rest) => home?.join(rest),
        None => PathBuf::from(lib),
    };
    Some(root.join("Spaces"))
}

/// All spaces: active and archived, ordered; plus what couldn't be loaded.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Catalog {
    pub spaces: Vec<Space>,
    /// Template id → document (built-ins overridden by the library's).
    #[serde(skip)]
    pub templates: BTreeMap<String, Value>,
    /// Problems: unreadable or invalid documents (skipped), duplicate ids
    /// or workspace names.
    pub problems: Vec<String>,
}

/// Documents to see in place of what's on disk (path → document, or None:
/// as if deleted), so an edit is validated before it's written.
pub type Overlay = BTreeMap<PathBuf, Option<Value>>;

fn read_docs(dir: &Path, overlay: &Overlay) -> Vec<(PathBuf, Result<Value>)> {
    let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|e| e == "json") && p.is_file())
                .collect()
        })
        .unwrap_or_default();
    for p in overlay.keys() {
        if p.parent() == Some(dir) && !paths.contains(p) {
            paths.push(p.clone());
        }
    }
    paths.sort();
    paths
        .into_iter()
        .filter_map(|p| {
            let v = match overlay.get(&p) {
                Some(None) => return None,
                Some(Some(v)) => Ok(v.clone()),
                None => std::fs::read_to_string(&p)
                    .with_context(|| format!("reading {}", p.display()))
                    .and_then(|t| {
                        serde_json::from_str(&t)
                            .with_context(|| format!("parsing {}", p.display()))
                    }),
            };
            Some((p, v))
        })
        .collect()
}

impl Catalog {
    pub fn load(dir: Option<&Path>, env: &Env) -> Catalog {
        Self::load_overlay(dir, env, &Overlay::new())
    }

    /// [`Catalog::load`], seeing `overlay` in place of the files it names.
    pub fn load_overlay(dir: Option<&Path>, env: &Env, overlay: &Overlay) -> Catalog {
        let mut cat = Catalog::default();
        let mut singletons: BTreeMap<String, (Option<PathBuf>, Value)> = BTreeMap::new();
        for (name, text) in BUILTIN {
            let v: Value =
                serde_json::from_str(text).expect("built-in space documents are valid JSON");
            match kind(&v) {
                "space-template" => {
                    cat.templates.insert(name.to_string(), v);
                }
                _ => {
                    singletons.insert(name.to_string(), (None, v));
                }
            }
        }
        let mut instances = Vec::new();
        if let Some(dir) = dir {
            let mut own: BTreeMap<String, (Option<PathBuf>, Value)> = BTreeMap::new();
            for (p, doc) in read_docs(dir, overlay) {
                match doc {
                    Ok(v) if kind(&v) == "space" => {
                        let id = str_field(&v, "id").unwrap_or_default().to_string();
                        own.insert(id, (Some(p), v));
                    }
                    Ok(v) => cat.problems.push(format!(
                        "{}: kind `{}` belongs in templates/ or instances/",
                        p.display(),
                        kind(&v)
                    )),
                    Err(e) => cat.problems.push(format!("{e:#}")),
                }
            }
            if !own.is_empty() {
                singletons = own;
            }
            for (p, doc) in read_docs(&dir.join("templates"), overlay) {
                match doc {
                    Ok(v) if kind(&v) == "space-template" => {
                        let id = str_field(&v, "id").unwrap_or_default().to_string();
                        cat.templates.insert(id, v);
                    }
                    Ok(_) => cat
                        .problems
                        .push(format!("{}: not a space template", p.display())),
                    Err(e) => cat.problems.push(format!("{e:#}")),
                }
            }
            for (p, doc) in read_docs(&dir.join("instances"), overlay) {
                match doc {
                    Ok(v) if kind(&v) == "space-instance" => instances.push((p, v)),
                    Ok(_) => cat
                        .problems
                        .push(format!("{}: not a space instance", p.display())),
                    Err(e) => cat.problems.push(format!("{e:#}")),
                }
            }
        }
        for (id, (path, doc)) in &singletons {
            match instantiate(doc, None, env) {
                Ok(mut s) => {
                    s.source = path.clone();
                    cat.spaces.push(s)
                }
                Err(e) => cat.problems.push(format!("space `{id}`: {e:#}")),
            }
        }
        for (p, inst) in &instances {
            let tid = str_field(inst, "template").unwrap_or_default();
            let res = match cat.templates.get(tid) {
                Some(t) => instantiate(t, Some(inst), env),
                None => Err(anyhow::anyhow!("no template `{tid}`")),
            };
            match res {
                Ok(mut s) => {
                    s.source = Some(p.clone());
                    cat.spaces.push(s)
                }
                Err(e) => cat.problems.push(format!("{}: {e:#}", p.display())),
            }
        }
        cat.spaces
            .sort_by(|a, b| a.order.total_cmp(&b.order).then(a.id.cmp(&b.id)));
        cat.check();
        cat
    }

    /// Two spaces with one id, or one workspace name claimed twice: the
    /// later space (in order) is dropped.
    fn check(&mut self) {
        let mut ids = BTreeSet::new();
        let mut names: BTreeMap<String, String> = BTreeMap::new();
        let mut keep = Vec::new();
        for s in std::mem::take(&mut self.spaces) {
            if !ids.insert(s.id.clone()) {
                self.problems.push(format!(
                    "space `{}` is defined twice; the second is ignored",
                    s.id
                ));
                continue;
            }
            let mut clash = None;
            let mut mine = BTreeSet::new();
            for (_, b) in s.workspaces() {
                let k = b.workspace.to_lowercase();
                if let Some(owner) = names.get(&k) {
                    clash = Some((b.workspace.clone(), owner.clone()));
                    break;
                }
                if !mine.insert(k) {
                    clash = Some((b.workspace.clone(), s.id.clone()));
                    break;
                }
            }
            if let Some((ws, owner)) = clash {
                self.problems.push(format!(
                    "space `{}`: workspace `{ws}` is already `{owner}`'s; the space is ignored",
                    s.id
                ));
                continue;
            }
            for k in mine {
                names.insert(k, s.id.clone());
            }
            keep.push(s);
        }
        self.spaces = keep;
    }

    /// The spaces Mod+1…9 and the switcher cycle through, in order.
    pub fn active(&self) -> Vec<&Space> {
        self.spaces.iter().filter(|s| !s.archived).collect()
    }

    /// By id, or by 1-based position among the active spaces.
    pub fn find(&self, key: &str) -> Option<&Space> {
        if let Ok(n) = key.parse::<usize>() {
            return n.checked_sub(1).and_then(|i| self.active().get(i).copied());
        }
        self.spaces.iter().find(|s| s.id == key)
    }

    /// The space a workspace belongs to.
    pub fn owner(&self, workspace: &str) -> Option<&Space> {
        self.spaces.iter().find(|s| s.owns(workspace))
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    pub fn env() -> Env {
        Env {
            state: "/state".into(),
            home: "/home/u".into(),
            profiles: "/state/browser".into(),
        }
    }

    pub fn fixture_library() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/spaces/library")
    }

    /// The built-ins + the fixture library's two Project instances.
    pub fn catalog() -> Catalog {
        let cat = Catalog::load(Some(&fixture_library()), &env());
        assert!(cat.problems.is_empty(), "{:?}", cat.problems);
        cat
    }

    #[test]
    fn builtins_load_in_the_decided_order() {
        let cat = Catalog::load(None, &env());
        assert!(cat.problems.is_empty(), "{:?}", cat.problems);
        let ids: Vec<_> = cat.active().iter().map(|s| s.id.as_str()).collect();
        // §12.6: Main, Music, Video, Comms, Gaming, Task.
        assert_eq!(ids, ["main", "music", "video", "comms", "gaming", "task"]);
        assert!(cat.templates.contains_key("project"));
        // Today's workspace names stay (§12.1).
        let main_ws: Vec<_> = cat
            .active()
            .iter()
            .map(|s| s.main_workspace().unwrap())
            .collect();
        assert_eq!(
            main_ws,
            ["main", "music", "video", "comms/main", "gaming", "task"]
        );
    }

    #[test]
    fn singleton_bindings_follow_the_decisions() {
        let cat = Catalog::load(None, &env());
        let s = |id| cat.find(id).unwrap();
        // Music and Gaming keep the left display (chat stays visible, §12.2).
        for id in ["music", "gaming"] {
            assert_eq!(s(id).binding("left"), Some(&Binding::Keep), "{id}");
        }
        // Communication lives on the left display, calls on main.
        let comms = s("comms");
        let ws = |sp: &Space, r: &str| match sp.binding(r) {
            Some(Binding::Bound(b)) => b.workspace.clone(),
            other => panic!("{r}: {other:?}"),
        };
        assert_eq!(ws(comms, "left"), "comms");
        // Defaults: <id>/<role>.
        assert_eq!(ws(s("music"), "right"), "music/right");
        // Video: Resolve center, OBS right (§12.8); Gaming streams right.
        assert_eq!(ws(s("video"), "right"), "recording");
        assert_eq!(ws(s("gaming"), "right"), "stream");
        match s("gaming").binding("main") {
            Some(Binding::Bound(b)) => {
                assert_eq!(
                    b.layout.as_ref().unwrap()["focus-ring"],
                    json!({ "off": true })
                )
            }
            other => panic!("{other:?}"),
        }
        // Task starts blank.
        assert!(
            s("task")
                .workspaces()
                .iter()
                .all(|(_, b)| b.apps.is_empty())
        );
        assert_eq!(cat.find("2").unwrap().id, "music");
        assert!(cat.find("0").is_none() && cat.find("7").is_none());
        assert_eq!(cat.owner("MUSIC/right").unwrap().id, "music");
    }

    #[test]
    fn project_instances() {
        let cat = catalog();
        let ids: Vec<_> = cat.active().iter().map(|s| s.id.as_str()).collect();
        // Instances follow the singletons (§12.6); archived ones are hidden.
        assert_eq!(
            ids,
            [
                "main",
                "music",
                "video",
                "comms",
                "gaming",
                "task",
                "proj-loft",
                "proj-inferno"
            ]
        );
        let loft = cat.find("proj-loft").unwrap();
        assert_eq!(loft.name, "Project: loft");
        assert_eq!(loft.template.as_deref(), Some("project"));
        let ws: Vec<_> = loft
            .workspaces()
            .iter()
            .map(|(r, b)| (*r, b.workspace.as_str()))
            .collect();
        // §12.3: center editor + debugger, right preview, left docs.
        assert_eq!(
            ws,
            [
                ("main", "loft"),
                ("left", "loft/left"),
                ("right", "loft/right")
            ]
        );
        let Some(Binding::Bound(main)) = loft.binding("main") else {
            panic!()
        };
        let app_ids: Vec<_> = main
            .apps
            .iter()
            .map(|a| a["id"].as_str().unwrap())
            .collect();
        assert_eq!(app_ids, ["editor", "debug"]);
        assert_eq!(
            main.apps[0]["exec"],
            json!(["zeditor", "~/Development/loft"])
        );
        assert_eq!(main.apps[0]["match"]["title"], json!("^loft\\b"));
        assert_eq!(
            main.apps[1]["match"]["appId"],
            json!("^loft\\.proj-loft\\.debug$")
        );
        assert!(main.apps.iter().all(|a| a.get("when").is_none()));
        // A URL preview → the Chromium app; no command, no native window.
        let Some(Binding::Bound(right)) = loft.binding("right") else {
            panic!()
        };
        assert_eq!(right.apps.len(), 1);
        assert_eq!(
            right.apps[0]["exec"],
            json!([
                "chromium",
                "--app=http://localhost:8080",
                "--class=loft.proj-loft.preview",
                "--user-data-dir=/state/browser/proj-loft/preview"
            ])
        );
        // The instance's overrides patch the space.
        assert_eq!(loft.doc["wallpapers"]["main"], json!("~/Pictures/loft.jpg"));
        assert_eq!(loft.order, 7.0);

        // inferno: a command preview + a native preview window, code editor, no docs.
        let inf = cat.find("proj-inferno").unwrap();
        let Some(Binding::Bound(right)) = inf.binding("right") else {
            panic!()
        };
        let ids: Vec<_> = right
            .apps
            .iter()
            .map(|a| a["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["preview-cmd", "preview-app"]);
        assert_eq!(right.apps[1]["match"], json!({ "appId": "^inferno-gui$" }));
        let Some(Binding::Bound(left)) = inf.binding("left") else {
            panic!()
        };
        assert!(left.apps.is_empty());
        let Some(Binding::Bound(main)) = inf.binding("main") else {
            panic!()
        };
        assert_eq!(main.apps[0]["exec"][0], json!("code"));

        assert!(cat.find("proj-old-thing").unwrap().archived);
    }

    #[test]
    fn instantiation_errors() {
        let cat = Catalog::load(None, &env());
        let t = &cat.templates["project"];
        let e = |inst: Value| instantiate(t, Some(&inst), &env()).unwrap_err().to_string();
        assert!(e(json!({ "kind": "space-instance", "template": "project", "params": { "name": "x" } }))
            .contains("missing required parameter `dir`"));
        assert!(
            e(json!({ "kind": "space-instance", "template": "project",
                          "params": { "name": "x", "dir": "/x", "colour": 1 } }))
            .contains("no parameter `colour`")
        );
        assert!(instantiate(t, None, &env()).is_err());
        let bad = json!({ "kind": "space", "id": "x", "displays": { "middle": "keep" } });
        assert!(
            instantiate(&bad, None, &env())
                .unwrap_err()
                .to_string()
                .contains("unknown display role")
        );
    }

    #[test]
    fn clashing_workspaces_and_ids_are_reported() {
        let d = crate::config::tests_support::scratch("spaces-clash");
        std::fs::create_dir_all(d.join("instances")).unwrap();
        // A project named "music" would take the Music space's workspace.
        std::fs::write(
            d.join("instances/proj-music.json"),
            r#"{ "kind": "space-instance", "template": "project", "params": { "name": "Music", "dir": "/m" } }"#,
        )
        .unwrap();
        std::fs::write(d.join("instances/broken.json"), "{ nope").unwrap();
        // Library singletons replace the built-in set.
        std::fs::write(
            d.join("solo.json"),
            r#"{ "kind": "space", "id": "solo", "name": "Solo", "order": 1, "displays": { "main": { "workspace": "music" } } }"#,
        )
        .unwrap();
        let cat = Catalog::load(Some(&d), &env());
        let ids: Vec<_> = cat.spaces.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, ["solo"]);
        assert_eq!(cat.problems.len(), 2, "{:?}", cat.problems);
        assert!(
            cat.problems
                .iter()
                .any(|p| p.contains("workspace `music` is already `solo`'s"))
        );
        assert!(cat.problems.iter().any(|p| p.contains("broken.json")));
    }

    #[test]
    fn merge_patch_semantics() {
        let mut v = json!({ "a": { "b": 1, "c": 2 }, "d": [1, 2] });
        merge_patch(&mut v, &json!({ "a": { "b": null, "e": 3 }, "d": [3] }));
        assert_eq!(v, json!({ "a": { "c": 2, "e": 3 }, "d": [3] }));
    }
}
