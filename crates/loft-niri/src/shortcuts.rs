//! Settings → Keyboard Shortcuts: user changes to keybinds.
//!
//! niri merges `binds` across includes and a later bind of the same key
//! replaces an earlier one (a duplicate *within* one `binds` block is an
//! error; checked against niri 26.04 with `niri validate`). The overrides
//! fragment is included last, so a bind written there wins over Loft's own
//! (base.kdl, shell-binds) and over the user's niri config alike. niri has no
//! way to *remove* a bind set in an earlier file, so a disabled shortcut is
//! rebound to a no-op (`spawn "true"`): the key does nothing (it doesn't reach
//! apps either).
//!
//! Stored in niri.json under `binds`, keyed by the normalized combo:
//!
//! ```json
//! "binds": {
//!   "Mod+Shift+T": { "disabled": true, "moved_to": "Mod+Alt+T" },
//!   "Mod+Alt+T":   { "action": "spawn", "args": ["…", "themes", "open"], "title": "Themes",
//!                    "props": { "repeat": false }, "moved_from": "Mod+Shift+T" },
//!   "Mod+Ctrl+X":  { "action": "spawn", "args": ["kitty"], "title": "Kitty" },
//!   "Mod+Ctrl+Y":  { "action": "toggle-overview", "off": true }
//! }
//! ```
//!
//! - `disabled`: the key is swallowed. With `moved_to`, the bind moved there
//!   (the record at `moved_to` carries `moved_from` back).
//! - an action record without `moved_from` is a custom shortcut (or one that
//!   took a default's key; that default shows as replaced).
//! - `off`: a custom shortcut switched off (not rendered).
//!
//! Extra fields are kept as they are (the shell stores `loft`: the Quick
//! Panel action id a custom shortcut runs).

use std::collections::BTreeMap;

use anyhow::{Result, bail};
use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::binds::{Bind, normalize};
use crate::kdl_out::{Node, Val};
use crate::state::Overrides;

/// `Mod+Shift+T` from any spelling (`shift+mod+t`); errors on an unknown
/// modifier or a missing key.
pub fn canonical(combo: &str) -> Result<String> {
    let combo = combo.trim();
    if combo.is_empty() {
        bail!("empty shortcut");
    }
    let (mods, trigger) = normalize(combo);
    if mods.iter().any(|m| m == "?") {
        bail!("`{combo}`: unknown modifier (use Mod, Super, Ctrl, Alt, Shift)");
    }
    if trigger.is_empty() {
        bail!("`{combo}`: no key");
    }
    if trigger
        .chars()
        .any(|c| c.is_whitespace() || "{}\";=".contains(c))
    {
        bail!("`{combo}`: not a key name");
    }
    Ok(mods
        .into_iter()
        .chain(std::iter::once(trigger))
        .collect::<Vec<_>>()
        .join("+"))
}

fn lc(s: &str) -> String {
    s.to_lowercase()
}

/// The `binds` records: lowercase combo → (combo, record).
fn records(ov: &Overrides) -> Records {
    let mut out = BTreeMap::new();
    if let Some(m) = ov.0.get("binds").and_then(Value::as_object) {
        for (k, v) in m {
            if let (Ok(c), Some(r)) = (canonical(k), v.as_object()) {
                out.insert(lc(&c), (c, r.clone()));
            }
        }
    }
    out
}

fn store(ov: &mut Overrides, recs: &Records) {
    if recs.is_empty() {
        ov.0.remove("binds");
        return;
    }
    let mut m = Map::new();
    for (c, r) in recs.values() {
        m.insert(c.clone(), Value::Object(r.clone()));
    }
    ov.0.insert("binds".into(), Value::Object(m));
}

fn flag(r: &Map<String, Value>, k: &str) -> bool {
    r.get(k).and_then(Value::as_bool).unwrap_or(false)
}

fn str_field<'a>(r: &'a Map<String, Value>, k: &str) -> Option<&'a str> {
    r.get(k).and_then(Value::as_str)
}

fn is_action(r: &Map<String, Value>) -> bool {
    !flag(r, "disabled") && str_field(r, "action").is_some_and(|a| !a.is_empty())
}

type Records = BTreeMap<String, (String, Map<String, Value>)>;

/// A record's `moved_from`, lowercased and normalized.
fn moved_from(r: &Map<String, Value>) -> Option<String> {
    canonical(str_field(r, "moved_from")?).ok().map(|c| lc(&c))
}

/// Where the default on `key` moved to: the (first) action record that came
/// from it, other than on its own key.
fn moved_target(recs: &Records, key: &str) -> Option<String> {
    recs.iter()
        .find(|(k, (_, r))| {
            k.as_str() != key && is_action(r) && moved_from(r).as_deref() == Some(key)
        })
        .map(|(k, _)| k.clone())
}

/// Drop the records the default on `key` moved to.
fn drop_targets(recs: &mut Records, key: &str) {
    recs.retain(|k, (_, r)| {
        k.as_str() == key || !(is_action(r) && moved_from(r).as_deref() == Some(key))
    });
}

fn json_val(v: &Value) -> Val {
    match v {
        Value::String(s) => Val::Str(s.clone()),
        Value::Bool(b) => Val::Bool(*b),
        Value::Number(n) => match n.as_i64() {
            Some(i) => Val::Int(i),
            None => Val::Float(n.as_f64().unwrap_or(0.0)),
        },
        Value::Null => Val::Null,
        other => Val::Str(other.to_string()),
    }
}

/// The fragment's `binds { … }` section (None when nothing is overridden).
pub fn render(ov: &Overrides) -> Option<Node> {
    let mut section = Node::new("binds");
    for (combo, r) in records(ov).into_values() {
        if flag(&r, "disabled") {
            section.children.push(
                Node::new(combo)
                    .prop("hotkey-overlay-title", Val::Null)
                    .child(Node::new("spawn").arg(Val::Str("true".into()))),
            );
            continue;
        }
        if flag(&r, "off") || !is_action(&r) {
            continue;
        }
        let mut n = Node::new(combo);
        if let Some(props) = r.get("props").and_then(Value::as_object) {
            for (k, v) in props {
                if k != "hotkey-overlay-title" {
                    n.props.push((k.clone(), json_val(v)));
                }
            }
        }
        match r.get("title") {
            Some(Value::String(t)) => n
                .props
                .push(("hotkey-overlay-title".into(), Val::Str(t.clone()))),
            Some(Value::Null) => n.props.push(("hotkey-overlay-title".into(), Val::Null)),
            _ => {}
        }
        let mut a = Node::new(str_field(&r, "action").unwrap());
        for v in r
            .get("args")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            a.args.push(json_val(v));
        }
        if let Some(ap) = r.get("action_props").and_then(Value::as_object) {
            for (k, v) in ap {
                a.props.push((k.clone(), json_val(v)));
            }
        }
        section.children.push(n.child(a));
    }
    (!section.children.is_empty()).then_some(section)
}

// ── Rows for the Settings page ──────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct Shortcut {
    /// `d:<default combo>` for a bind from the config, `c:<combo>` for a custom one.
    pub id: String,
    /// The key it's on now (None: disabled).
    pub combo: Option<String>,
    pub modifiers: Vec<String>,
    pub trigger: String,
    /// The config's key (None for custom shortcuts).
    pub default_combo: Option<String>,
    /// hotkey-overlay-title, or a readable name made from the action.
    pub label: String,
    /// Has a hotkey-overlay-title (false: the label was made up).
    pub titled: bool,
    pub action: String,
    pub args: Vec<Value>,
    pub action_props: Map<String, Value>,
    pub action_text: String,
    /// A short line for the UI: `shell IPC: themes open`, `kitty -e htop`, …
    pub detail: String,
    /// Loft, Windows, Workspaces, Displays, Screenshots, Media & Hardware,
    /// System, Apps, Custom, Other.
    pub category: String,
    /// loft (base.kdl / shell-binds), config (the user's niri config),
    /// theme, custom.
    pub origin: String,
    pub file: Option<String>,
    pub line: Option<usize>,
    /// default · moved · disabled · replaced · custom · custom-off
    pub state: String,
    /// The row now on this default's key (state `replaced`).
    pub replaced_by: Option<String>,
    /// Earlier definitions of the same key in the config (file:line).
    pub also_defined: Vec<String>,
    /// The record to recreate this shortcut elsewhere.
    pub record: Map<String, Value>,
    /// The Quick Panel action a custom shortcut runs (shell-owned field).
    pub loft: Option<String>,
}

/// Where a config file comes from, by its path.
pub fn origin_of(file: &str) -> &'static str {
    let p = std::path::Path::new(file);
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let parent = p
        .parent()
        .and_then(|d| d.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or("");
    if name.contains("shell-binds") || (name == "base.kdl" && parent.ends_with("niri")) {
        "loft"
    } else if name == "niri.kdl" && parent == "current" {
        "theme"
    } else {
        "config"
    }
}

fn arg_strs(args: &[Value]) -> Vec<String> {
    args.iter()
        .map(|a| match a {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        })
        .collect()
}

/// The Loft shell IPC target a spawn runs (`… quickshell ipc … call TARGET FN`).
fn ipc_target(args: &[String]) -> Option<(String, String)> {
    let i = args.iter().position(|a| a == "call")?;
    if !args.iter().take(i).any(|a| a == "ipc") {
        return None;
    }
    Some((
        args.get(i + 1)?.clone(),
        args.get(i + 2).cloned().unwrap_or_default(),
    ))
}

pub fn category(action: &str, args: &[Value], trigger: &str) -> &'static str {
    let a = arg_strs(args);
    if action.starts_with("screenshot") {
        return "Screenshots";
    }
    if action == "spawn" || action == "spawn-sh" {
        if let Some((target, _)) = ipc_target(&a) {
            return if target == "capture" {
                "Screenshots"
            } else {
                "Loft"
            };
        }
        let joined = a.join(" ");
        if joined.contains("loft-launcher") || joined.contains("loft-quit") {
            return "Loft";
        }
        if trigger.starts_with("XF86")
            || ["wpctl", "pactl", "brightnessctl", "playerctl", "pamixer"]
                .iter()
                .any(|t| a.first().is_some_and(|f| f.ends_with(t)))
        {
            return "Media & Hardware";
        }
        return "Apps";
    }
    if trigger.starts_with("XF86") {
        return "Media & Hardware";
    }
    if action.contains("workspace") {
        return "Workspaces";
    }
    if action.contains("monitor") {
        return "Displays";
    }
    if [
        "quit",
        "suspend",
        "power-off-monitors",
        "power-on-monitors",
        "show-hotkey-overlay",
        "toggle-overview",
        "open-overview",
        "close-overview",
        "toggle-keyboard-shortcuts-inhibit",
        "do-screen-transition",
        "switch-layout",
        "load-config-file",
    ]
    .contains(&action)
        || action.starts_with("debug")
    {
        return "System";
    }
    if action.contains("window")
        || action.contains("column")
        || action.contains("fullscreen")
        || action.contains("consume")
        || action.contains("expel")
        || action.contains("preset")
        || action.contains("height")
        || action.contains("width")
        || action.contains("floating")
        || action.contains("tiling")
        || action.starts_with("center")
        || action.starts_with("maximize")
        || action.starts_with("focus")
        || action.starts_with("move")
        || action.starts_with("swap")
    {
        return "Windows";
    }
    "Other"
}

/// `focus-column-left` → "Focus column left"; spawns name the program.
pub fn humanize(action: &str, args: &[Value]) -> String {
    let a = arg_strs(args);
    if action == "spawn" || action == "spawn-sh" {
        if let Some((target, f)) = ipc_target(&a) {
            return format!("Loft: {target} {f}").trim().to_string();
        }
        let prog = a
            .first()
            .map(|p| p.rsplit('/').next().unwrap_or(p).to_string())
            .unwrap_or_default();
        let rest: Vec<_> = a.iter().skip(1).take(3).cloned().collect();
        return if rest.is_empty() {
            format!("Run {prog}")
        } else {
            format!("Run {prog} {}", rest.join(" "))
        };
    }
    let mut s = action.replace('-', " ");
    if let Some(f) = s.get(..1) {
        s = f.to_uppercase() + &s[1..];
    }
    for v in args {
        s.push(' ');
        s.push_str(&match v {
            Value::String(x) => x.clone(),
            other => other.to_string(),
        });
    }
    s
}

/// The action, shortened for a list row.
pub fn detail(action: &str, args: &[Value], action_text: &str) -> String {
    let a = arg_strs(args);
    if action == "spawn" || action == "spawn-sh" {
        if let Some((target, f)) = ipc_target(&a) {
            let rest: Vec<_> = a
                .iter()
                .skip_while(|x| *x != "call")
                .skip(3)
                .cloned()
                .collect();
            return format!("shell IPC: {target} {f} {}", rest.join(" "))
                .trim()
                .to_string();
        }
        // The ⌘Q bind: `sh -c '"$@" quit key || …' loft-quit <ipc…>`.
        if a.iter().any(|x| x == "loft-quit") {
            return "shell IPC: quit key (close, or hold to quit)".into();
        }
        let mut parts: Vec<String> = a.clone();
        if let Some(p) = parts.first_mut() {
            *p = p.rsplit('/').next().unwrap_or(p).to_string();
        }
        return parts.join(" ");
    }
    action_text.to_string()
}

fn record_of(b: &Bind) -> Map<String, Value> {
    let mut r = Map::new();
    r.insert("action".into(), json!(b.action));
    if !b.args.is_empty() {
        r.insert("args".into(), Value::Array(b.args.clone()));
    }
    if !b.action_props.is_empty() {
        r.insert("action_props".into(), Value::Object(b.action_props.clone()));
    }
    if let Some(t) = &b.title {
        r.insert("title".into(), t.clone());
    }
    if !b.props.is_empty() {
        r.insert("props".into(), Value::Object(b.props.clone()));
    }
    r
}

fn keys_of(combo: &str) -> (Vec<String>, String) {
    normalize(combo)
}

fn action_text_of(r: &Map<String, Value>) -> String {
    let mut s = str_field(r, "action").unwrap_or("").to_string();
    for a in r
        .get("args")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        s.push(' ');
        s.push_str(&a.to_string());
    }
    if let Some(ap) = r.get("action_props").and_then(Value::as_object) {
        for (k, v) in ap {
            s.push_str(&format!(" {k}={v}"));
        }
    }
    s
}

/// The effective binds of the config (without our fragment): lowercase
/// combo → the winning definition, plus the earlier ones it shadows.
fn defaults(base: &[Bind]) -> (Vec<&Bind>, BTreeMap<String, Vec<String>>) {
    let mut eff = Vec::new();
    let mut shadowed: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for b in base {
        if b.shadowed {
            shadowed
                .entry(lc(&b.combo))
                .or_default()
                .push(format!("{}:{}", b.file, b.line));
        } else {
            eff.push(b);
        }
    }
    (eff, shadowed)
}

pub fn rows(base: &[Bind], ov: &Overrides) -> Vec<Shortcut> {
    let recs = records(ov);
    let (eff, shadowed) = defaults(base);
    let default_set: BTreeMap<String, &Bind> = eff.iter().map(|b| (lc(&b.combo), *b)).collect();
    let mut out = Vec::new();
    // Action records shown under the default they moved from.
    let mut claimed: Vec<String> = Vec::new();

    for b in &eff {
        let key = lc(&b.combo);
        let title = b.title.as_ref().and_then(Value::as_str).map(str::to_string);
        let mut row = Shortcut {
            id: format!("d:{}", b.combo),
            combo: Some(b.combo.clone()),
            modifiers: b.modifiers.clone(),
            trigger: b.trigger.clone(),
            default_combo: Some(b.combo.clone()),
            label: title
                .clone()
                .unwrap_or_else(|| humanize(&b.action, &b.args)),
            titled: title.is_some(),
            action: b.action.clone(),
            args: b.args.clone(),
            action_props: b.action_props.clone(),
            action_text: b.action_text.clone(),
            detail: detail(&b.action, &b.args, &b.action_text),
            category: category(&b.action, &b.args, &b.trigger).to_string(),
            origin: origin_of(&b.file).to_string(),
            file: Some(b.file.clone()),
            line: Some(b.line),
            state: "default".into(),
            replaced_by: None,
            also_defined: shadowed.get(&key).cloned().unwrap_or_default(),
            record: record_of(b),
            loft: None,
        };
        // Moved: an action record elsewhere that came from this key.
        if let Some(ml) = moved_target(&recs, &key) {
            let mc = recs[&ml].0.clone();
            let (m, t) = keys_of(&mc);
            row.modifiers = m;
            row.trigger = t;
            row.combo = Some(mc);
            row.state = "moved".into();
            claimed.push(ml);
        } else if let Some((_, r)) = recs.get(&key) {
            if flag(r, "disabled") {
                row.combo = None;
                row.state = "disabled".into();
            } else if is_action(r) && !flag(r, "off") {
                row.state = "replaced".into();
                let owner = moved_from(r)
                    .filter(|f| *f != key && default_set.contains_key(f))
                    .filter(|f| moved_target(&recs, f).as_deref() == Some(key.as_str()));
                row.replaced_by = Some(match owner {
                    Some(f) => format!("d:{}", default_set[&f].combo),
                    None => format!("c:{}", recs[&key].0),
                });
            }
        }
        out.push(row);
    }

    for (key, (combo, r)) in &recs {
        if !is_action(r) || claimed.contains(key) {
            continue;
        }
        // A moved record is claimed by its origin's row above; a dangling
        // one (its origin no longer points here) shows as custom.
        let (m, t) = keys_of(combo);
        let title = str_field(r, "title").map(str::to_string);
        let action = str_field(r, "action").unwrap_or("").to_string();
        let args: Vec<Value> = r
            .get("args")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let off = flag(r, "off");
        out.push(Shortcut {
            id: format!("c:{combo}"),
            combo: Some(combo.clone()),
            modifiers: m,
            trigger: t,
            default_combo: None,
            label: title.clone().unwrap_or_else(|| humanize(&action, &args)),
            titled: title.is_some(),
            detail: detail(&action, &args, &action_text_of(r)),
            action_text: action_text_of(r),
            category: "Custom".into(),
            origin: "custom".into(),
            file: None,
            line: None,
            state: if off { "custom-off" } else { "custom" }.into(),
            replaced_by: None,
            also_defined: Vec::new(),
            action_props: r
                .get("action_props")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default(),
            action,
            args,
            loft: str_field(r, "loft").map(str::to_string),
            record: r.clone(),
        });
    }
    out
}

// ── Edits ────────────────────────────────────────────────────────────────

/// Apply the shell's shortcut operations to the overrides:
///
/// ```json
/// [ { "op": "set",     "id": "d:Mod+Shift+T", "combo": "Mod+Alt+T" },
///   { "op": "disable", "id": "d:Mod+O" },  { "op": "enable", "id": "d:Mod+O" },
///   { "op": "reset",   "id": "d:Mod+O" },  { "op": "reset",  "id": "c:Mod+Ctrl+X" },
///   { "op": "add", "combo": "Mod+Ctrl+X", "record": { "action": "spawn", "args": ["kitty"] } },
///   { "op": "reset_all" } ]
/// ```
///
/// `set` takes the key even when another shortcut has it (the UI asked):
/// that one shows as replaced. Moving a default back onto its own key
/// restores it.
pub fn apply_ops(ov: &mut Overrides, base: &[Bind], ops: &[Value]) -> Result<()> {
    let (eff, _) = defaults(base);
    let default_set: BTreeMap<String, &Bind> = eff.iter().map(|b| (lc(&b.combo), *b)).collect();
    let mut recs = records(ov);

    enum Target {
        Default(String, String), // lc, combo
        Custom(String),          // lc
    }
    let resolve = |id: &str, recs: &Records| -> Result<Target> {
        if let Some(c) = id.strip_prefix("d:") {
            let k = lc(&canonical(c)?);
            match default_set.get(&k) {
                Some(b) => Ok(Target::Default(k, b.combo.clone())),
                None => bail!("no shortcut `{c}` in the niri config"),
            }
        } else if let Some(c) = id.strip_prefix("c:") {
            let k = lc(&canonical(c)?);
            if recs.contains_key(&k) {
                Ok(Target::Custom(k))
            } else {
                bail!("no custom shortcut `{c}`")
            }
        } else {
            bail!("bad shortcut id `{id}`")
        }
    };
    // The default's own key holds someone else's shortcut (it was replaced).
    let taken = |recs: &Records, k: &str| recs.get(k).is_some_and(|(_, r)| is_action(r));
    let marker = |moved_to: Option<&str>| {
        let mut d = Map::new();
        d.insert("disabled".into(), json!(true));
        if let Some(m) = moved_to {
            d.insert("moved_to".into(), json!(m));
        }
        d
    };

    for op in ops {
        let name = op.get("op").and_then(Value::as_str).unwrap_or("");
        let id = op.get("id").and_then(Value::as_str).unwrap_or("");
        match name {
            "reset_all" => recs.clear(),
            "add" => {
                let combo = canonical(op.get("combo").and_then(Value::as_str).unwrap_or(""))?;
                let Some(r) = op.get("record").and_then(Value::as_object) else {
                    bail!("add: missing record");
                };
                if !is_action(r) {
                    bail!("add: the record needs an action");
                }
                let mut r = r.clone();
                r.remove("moved_from");
                r.remove("disabled");
                recs.insert(lc(&combo), (combo, r));
            }
            "set" => {
                let new = canonical(op.get("combo").and_then(Value::as_str).unwrap_or(""))?;
                let nl = lc(&new);
                match resolve(id, &recs)? {
                    Target::Default(k, c) => {
                        drop_targets(&mut recs, &k);
                        if nl == k {
                            // Home again (whoever had the key is replaced).
                            recs.remove(&k);
                        } else {
                            let mut r = record_of(default_set[&k]);
                            r.insert("moved_from".into(), json!(c));
                            // Switch the old key off, unless someone else has it.
                            if !taken(&recs, &k) {
                                recs.insert(k, (c, marker(Some(&new))));
                            }
                            recs.insert(nl, (new, r));
                        }
                    }
                    Target::Custom(k) => {
                        if nl != k {
                            let (_, r) = recs.remove(&k).unwrap();
                            recs.insert(nl, (new, r));
                        }
                    }
                }
            }
            "disable" => match resolve(id, &recs)? {
                Target::Default(k, c) => {
                    drop_targets(&mut recs, &k);
                    if !taken(&recs, &k) {
                        recs.insert(k, (c, marker(None)));
                    }
                }
                Target::Custom(k) => {
                    recs.get_mut(&k)
                        .unwrap()
                        .1
                        .insert("off".into(), json!(true));
                }
            },
            "enable" => match resolve(id, &recs)? {
                Target::Default(k, _) => {
                    if moved_target(&recs, &k).is_none()
                        && recs.get(&k).is_some_and(|(_, r)| flag(r, "disabled"))
                    {
                        recs.remove(&k);
                    }
                }
                Target::Custom(k) => {
                    recs.get_mut(&k).unwrap().1.remove("off");
                }
            },
            "reset" => match resolve(id, &recs)? {
                Target::Default(k, _) => {
                    drop_targets(&mut recs, &k);
                    // Another default moved onto this key: send it home too.
                    if let Some((_, r)) = recs.remove(&k)
                        && is_action(&r)
                        && let Some(f) = moved_from(&r)
                        && recs.get(&f).is_some_and(|(_, fr)| flag(fr, "disabled"))
                    {
                        recs.remove(&f);
                    }
                }
                Target::Custom(k) => {
                    recs.remove(&k);
                }
            },
            other => bail!("unknown shortcut op `{other}`"),
        }
    }
    store(ov, &recs);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::binds::collect;
    use crate::config::ConfigTree;
    use crate::config::tests_support::scratch;
    use crate::kdl_out::write_doc;

    fn base(name: &str) -> Vec<Bind> {
        let d = scratch(name);
        std::fs::create_dir_all(d.join("niri")).unwrap();
        std::fs::write(
            d.join("niri/base.kdl"),
            r#"binds {
    Mod+O { toggle-overview; }
    Mod+Q { close-window; }
    Mod+1 { focus-workspace 1; }
}
"#,
        )
        .unwrap();
        std::fs::write(
            d.join("loft-shell-binds.kdl"),
            r#"binds {
    Mod+Shift+T hotkey-overlay-title="Themes" { spawn "/qs" "ipc" "--path" "/src" "call" "themes" "open"; }
    Super+Shift+4 hotkey-overlay-title="Capture Area" { spawn "/qs" "ipc" "call" "capture" "area"; }
    Mod+Q cooldown-ms=100 hotkey-overlay-title="Close Window" { spawn "sh" "-c" "x" "loft-quit"; }
}
"#,
        )
        .unwrap();
        std::fs::write(
            d.join("config.kdl"),
            r#"include "niri/base.kdl"
include "loft-shell-binds.kdl"
binds {
    Mod+Return { spawn "kitty"; }
    XF86AudioRaiseVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+"; }
}
"#,
        )
        .unwrap();
        let t = ConfigTree::load(&d.join("config.kdl"), &|_| false).unwrap();
        assert!(t.errors.is_empty(), "{:?}", t.errors);
        collect(&t)
    }

    fn row<'a>(rows: &'a [Shortcut], id: &str) -> &'a Shortcut {
        rows.iter()
            .find(|r| r.id == id)
            .unwrap_or_else(|| panic!("no row {id}"))
    }

    #[test]
    fn canonical_combos() {
        assert_eq!(canonical("shift+mod+t").unwrap(), "Mod+Shift+T");
        assert_eq!(canonical("Ctrl+Alt+slash").unwrap(), "Ctrl+Alt+Slash");
        assert!(canonical("Hyper+T").is_err());
        assert!(canonical("Mod+").is_err());
        assert!(canonical("").is_err());
    }

    #[test]
    fn rows_categories_and_origins() {
        let b = base("sc-rows");
        let r = rows(&b, &Overrides::default());
        assert_eq!(row(&r, "d:Mod+O").category, "System");
        assert_eq!(row(&r, "d:Mod+O").label, "Toggle overview");
        assert_eq!(row(&r, "d:Mod+O").origin, "loft");
        assert_eq!(row(&r, "d:Mod+1").category, "Workspaces");
        assert_eq!(row(&r, "d:Mod+Shift+T").category, "Loft");
        assert_eq!(row(&r, "d:Mod+Shift+T").label, "Themes");
        assert_eq!(row(&r, "d:Super+Shift+4").category, "Screenshots");
        assert_eq!(row(&r, "d:Mod+Return").category, "Apps");
        assert_eq!(row(&r, "d:Mod+Return").origin, "config");
        assert_eq!(
            row(&r, "d:XF86AudioRaiseVolume").category,
            "Media & Hardware"
        );
        // Mod+Q: the shell-binds one wins, base.kdl's is listed as shadowed.
        let q = row(&r, "d:Mod+Q");
        assert_eq!(q.category, "Loft");
        assert_eq!(q.also_defined.len(), 1);
        assert!(q.also_defined[0].contains("base.kdl"));
        assert_eq!(r.iter().filter(|x| x.id == "d:Mod+Q").count(), 1);
        assert!(r.iter().all(|x| x.state == "default"));
    }

    #[test]
    fn move_disable_replace_reset() {
        let b = base("sc-ops");
        let mut ov = Overrides::default();
        // Move Themes to Mod+Alt+T.
        apply_ops(
            &mut ov,
            &b,
            &[json!({ "op": "set", "id": "d:Mod+Shift+T", "combo": "alt+mod+t" })],
        )
        .unwrap();
        let r = rows(&b, &ov);
        let t = row(&r, "d:Mod+Shift+T");
        assert_eq!(t.state, "moved");
        assert_eq!(t.combo.as_deref(), Some("Mod+Alt+T"));
        assert_eq!(
            (t.modifiers.clone(), t.trigger.clone()),
            (vec!["Mod".into(), "Alt".into()], "T".into())
        );
        assert!(
            !r.iter().any(|x| x.id.starts_with("c:")),
            "the moved record is not a custom row"
        );
        assert_eq!(
            ov.0["binds"]["Mod+Alt+T"]["props"],
            Value::Null,
            "no props on Themes"
        );
        assert_eq!(ov.0["binds"]["Mod+Alt+T"]["title"], json!("Themes"));

        // Move it again: the old target goes away.
        apply_ops(
            &mut ov,
            &b,
            &[json!({ "op": "set", "id": "d:Mod+Shift+T", "combo": "Mod+Ctrl+T" })],
        )
        .unwrap();
        let keys: Vec<_> = ov.0["binds"].as_object().unwrap().keys().cloned().collect();
        assert_eq!(keys, vec!["Mod+Ctrl+T", "Mod+Shift+T"]);

        // Move the overview onto Mod+1: workspace 1 is replaced.
        apply_ops(
            &mut ov,
            &b,
            &[json!({ "op": "set", "id": "d:Mod+O", "combo": "Mod+1" })],
        )
        .unwrap();
        let r = rows(&b, &ov);
        assert_eq!(row(&r, "d:Mod+1").state, "replaced");
        assert_eq!(row(&r, "d:Mod+1").replaced_by.as_deref(), Some("d:Mod+O"));
        assert_eq!(row(&r, "d:Mod+O").combo.as_deref(), Some("Mod+1"));

        // Restoring workspace 1 sends the overview home as well.
        apply_ops(&mut ov, &b, &[json!({ "op": "reset", "id": "d:Mod+1" })]).unwrap();
        let r = rows(&b, &ov);
        assert_eq!(row(&r, "d:Mod+1").state, "default");
        assert_eq!(row(&r, "d:Mod+O").state, "default");

        // Disable / enable.
        apply_ops(&mut ov, &b, &[json!({ "op": "disable", "id": "d:Mod+O" })]).unwrap();
        let r = rows(&b, &ov);
        assert_eq!(row(&r, "d:Mod+O").state, "disabled");
        assert_eq!(row(&r, "d:Mod+O").combo, None);
        apply_ops(&mut ov, &b, &[json!({ "op": "enable", "id": "d:Mod+O" })]).unwrap();
        assert_eq!(row(&rows(&b, &ov), "d:Mod+O").state, "default");

        // Moving back onto its own key restores it.
        apply_ops(
            &mut ov,
            &b,
            &[json!({ "op": "set", "id": "d:Mod+Shift+T", "combo": "Mod+Shift+T" })],
        )
        .unwrap();
        assert!(ov.0.get("binds").is_none(), "{:?}", ov.0);
    }

    #[test]
    fn moving_a_replaced_default_keeps_the_one_on_its_key() {
        let b = base("sc-replaced-move");
        let mut ov = Overrides::default();
        apply_ops(
            &mut ov,
            &b,
            &[
                json!({ "op": "set", "id": "d:Mod+O", "combo": "Mod+1" }),
                json!({ "op": "set", "id": "d:Mod+1", "combo": "Mod+2" }),
            ],
        )
        .unwrap();
        let r = rows(&b, &ov);
        let o = row(&r, "d:Mod+O");
        let one = row(&r, "d:Mod+1");
        assert_eq!(
            (o.state.as_str(), o.combo.as_deref()),
            ("moved", Some("Mod+1"))
        );
        assert_eq!(
            (one.state.as_str(), one.combo.as_deref()),
            ("moved", Some("Mod+2"))
        );
        let text = write_doc(&[render(&ov).unwrap()]);
        assert!(
            text.contains("Mod+1 {\n        toggle-overview\n"),
            "{text}"
        );
        assert!(
            text.contains("Mod+2 {\n        focus-workspace 1\n"),
            "{text}"
        );
        // Disabling the workspace bind leaves the overview on Mod+1.
        apply_ops(&mut ov, &b, &[json!({ "op": "disable", "id": "d:Mod+1" })]).unwrap();
        let r = rows(&b, &ov);
        assert_eq!(row(&r, "d:Mod+O").combo.as_deref(), Some("Mod+1"));
        assert_eq!(row(&r, "d:Mod+1").state, "replaced");
        assert_eq!(row(&r, "d:Mod+Shift+T").detail, "shell IPC: themes open");
        assert_eq!(row(&r, "d:Mod+Return").detail, "kitty");
        assert_eq!(row(&r, "d:Mod+O").detail, "toggle-overview");
        assert!(row(&r, "d:Mod+Q").detail.starts_with("shell IPC: quit key"));
    }

    #[test]
    fn custom_shortcuts() {
        let b = base("sc-custom");
        let mut ov = Overrides::default();
        apply_ops(
            &mut ov,
            &b,
            &[json!({ "op": "add", "combo": "Mod+Return", "record": { "action": "spawn", "args": ["foot"], "title": "Foot", "loft": null } })],
        )
        .unwrap();
        let r = rows(&b, &ov);
        assert_eq!(row(&r, "d:Mod+Return").state, "replaced");
        assert_eq!(
            row(&r, "d:Mod+Return").replaced_by.as_deref(),
            Some("c:Mod+Return")
        );
        let c = row(&r, "c:Mod+Return");
        assert_eq!(
            (c.state.as_str(), c.category.as_str(), c.label.as_str()),
            ("custom", "Custom", "Foot")
        );

        apply_ops(
            &mut ov,
            &b,
            &[
                json!({ "op": "set", "id": "c:Mod+Return", "combo": "Mod+Ctrl+Return" }),
                json!({ "op": "disable", "id": "c:Mod+Ctrl+Return" }),
            ],
        )
        .unwrap();
        let r = rows(&b, &ov);
        assert_eq!(row(&r, "d:Mod+Return").state, "default");
        assert_eq!(row(&r, "c:Mod+Ctrl+Return").state, "custom-off");
        assert!(
            render(&ov).is_none(),
            "an off custom shortcut renders nothing"
        );

        assert!(
            apply_ops(
                &mut ov,
                &b,
                &[json!({ "op": "add", "combo": "Mod+X", "record": {} })]
            )
            .is_err()
        );
        assert!(
            apply_ops(
                &mut ov,
                &b,
                &[json!({ "op": "set", "id": "d:Mod+Z", "combo": "Mod+X" })]
            )
            .is_err()
        );
        apply_ops(&mut ov, &b, &[json!({ "op": "reset_all" })]).unwrap();
        assert!(ov.0.get("binds").is_none());
    }

    #[test]
    fn renders_binds() {
        let b = base("sc-render");
        let mut ov = Overrides::default();
        apply_ops(
            &mut ov,
            &b,
            &[
                json!({ "op": "set", "id": "d:Mod+Q", "combo": "Mod+W" }),
                json!({ "op": "disable", "id": "d:Mod+O" }),
            ],
        )
        .unwrap();
        let text = write_doc(&[render(&ov).unwrap()]);
        assert_eq!(
            text,
            r#"binds {
    Mod+O hotkey-overlay-title=null {
        spawn "true"
    }
    Mod+Q hotkey-overlay-title=null {
        spawn "true"
    }
    Mod+W cooldown-ms=100 hotkey-overlay-title="Close Window" {
        spawn "sh" "-c" "x" "loft-quit"
    }
}
"#
        );
    }

    #[test]
    fn apply_validates_and_rolls_back() {
        let Some(_) = crate::render::find_niri() else {
            eprintln!("niri not on PATH; skipping");
            return;
        };
        let d = scratch("sc-apply");
        let paths = crate::state::Paths::new(d.join("state"));
        std::fs::write(
            d.join("config.kdl"),
            format!(
                "include optional=true \"{0}\"\nbinds {{\n    Mod+T {{ spawn \"foot\"; }}\n    Mod+O {{ toggle-overview; }}\n}}\ninclude optional=true \"{0}\"\n",
                paths.kdl.display()
            ),
        )
        .unwrap();
        let opts = crate::ApplyOpts {
            entry: Some(&d.join("config.kdl")),
            validate: true,
            reload: false,
        };
        // Moving Mod+T onto Mod+O and disabling nothing else: the fragment
        // (included twice) redefines keys from the config, which niri allows.
        crate::apply(
            &paths,
            &json!({ "bind_ops": [{ "op": "set", "id": "d:Mod+T", "combo": "Mod+O" }] }),
            opts,
        )
        .unwrap();
        let text = std::fs::read_to_string(&paths.kdl).unwrap();
        assert!(text.contains("Mod+O {\n        spawn \"foot\""), "{text}");
        let saved = std::fs::read_to_string(&paths.json).unwrap();

        // A key niri doesn't know: rejected by `niri validate`, and the
        // previous overrides stay.
        let err = crate::apply(
            &paths,
            &json!({ "bind_ops": [{ "op": "add", "combo": "Mod+NoSuchKey", "record": { "action": "spawn", "args": ["x"] } }] }),
            opts,
        )
        .unwrap_err();
        assert!(format!("{err:#}").contains("niri rejected"), "{err:#}");
        assert_eq!(std::fs::read_to_string(&paths.json).unwrap(), saved);
        assert_eq!(std::fs::read_to_string(&paths.kdl).unwrap(), text);
    }
}
