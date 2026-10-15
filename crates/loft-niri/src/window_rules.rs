//! Settings → Window Rules: translucent windows ("window glass") and the
//! per-app niri window rules Loft writes.
//!
//! Stored in niri.json, rendered into overrides/niri.kdl (included last, so
//! these rules win over earlier ones that set the same property):
//!
//! ```json
//! "window-glass": { "enabled": true, "focused": 0.9, "unfocused": 0.8, "blur": true,
//!                   "defaults-off": ["reaper"] },
//! "window-rules": {
//!   "org.gnome.Nautilus": { "open-on-workspace": "Desktop 2" },
//!   "com.mitchellh.ghostty": { "glass": "native" },
//!   "code": { "glass": "custom", "opacity": 0.97, "opacity-unfocused": 0.9, "blur": false,
//!             "open-floating": true, "open-maximized": true, "open-fullscreen": false,
//!             "default-column-width": 0.5, "square-corners": true,
//!             "block-out-from": "screencast" }
//! }
//! ```
//!
//! - `window-glass`: the user's global values; a missing one falls back to
//!   the theme's (`windows` in `<state>/current/theme.json`, the material
//!   facet's `windows`), then to [`GlassTheme::default`]. `defaults-off`:
//!   built-in "keep opaque" entries ([`DEFAULT_OPAQUE`]) the user turned off.
//! - `glass` per app: absent = the global look; `opaque` = opacity 1;
//!   `custom` = its own `opacity` / `opacity-unfocused` (translucent even
//!   with the global switch off); `native` = opacity 1 + blur, for apps that
//!   draw their own translucent background (terminals' background-opacity),
//!   so their text stays fully opaque. `blur` (true/false) is separate.
//!
//! Order in the fragment: the global rules, then the built-in opaque list,
//! then the per-app rules (sorted by app id), so a user's per-app choice
//! beats the built-in list, which beats the global look. Window rules in the
//! user's own niri config that set `opacity` are excluded from the global
//! rules: niri applies later rules over earlier ones, and the overrides come
//! last, so without that a config's `opacity 0.8` would silently lose.
//!
//! niri has no fullscreen matcher (26.04: `is-focused`, `is-active`,
//! `is-floating`, … but no `is-fullscreen`), so a translucent app stays
//! translucent when fullscreened. Video players and games are on the opaque
//! list for that reason; anything else that goes fullscreen with video
//! (a browser) can be kept opaque per app.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Result, bail};
use serde_json::{Map, Value, json};

use crate::config::ConfigTree;
use crate::kdl_out::{Node, Val};
use crate::render::regex_literal;
use crate::shortcuts::origin_of;
use crate::state::Overrides;

pub const GLASS: &str = "window-glass";
/// The shell's own windows (Quickshell's app id).
pub const SHELL_APP_ID: &str = "^org\\.quickshell$";
pub const RULES: &str = "window-rules";

/// Fields a per-app record may carry (anything else is kept but ignored).
pub const RULE_FIELDS: &[&str] = &[
    "open-on-workspace",
    "open-on-output",
    "glass",
    "opacity",
    "opacity-unfocused",
    "blur",
    "open-floating",
    "open-maximized",
    "open-fullscreen",
    "default-column-width",
    "square-corners",
    "block-out-from",
];

/// One built-in "keep opaque" entry: apps where see-through windows hurt
/// (video, games, color-critical and pro-audio/video work).
pub struct DefaultOpaque {
    pub id: &'static str,
    pub label: &'static str,
    /// niri `app-id` regexes (any of them).
    pub app_ids: &'static [&'static str],
    /// Or a `title` regex (any app).
    pub titles: &'static [&'static str],
}

pub const DEFAULT_OPAQUE: &[DefaultOpaque] = &[
    DefaultOpaque {
        id: "mpv",
        label: "mpv",
        app_ids: &["^mpv$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "vlc",
        label: "VLC",
        app_ids: &["^vlc$", "^org\\.videolan\\.VLC$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "celluloid",
        label: "Celluloid",
        app_ids: &["^io\\.github\\.celluloid_player\\.Celluloid$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "gnome-videos",
        label: "Videos (Totem, Showtime)",
        app_ids: &["^org\\.gnome\\.Totem$", "^org\\.gnome\\.Showtime$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "haruna",
        label: "Haruna",
        app_ids: &["^org\\.kde\\.haruna$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "pip",
        label: "Picture-in-Picture",
        app_ids: &[],
        titles: &["^Picture-in-Picture$"],
    },
    DefaultOpaque {
        id: "steam-games",
        label: "Steam games",
        app_ids: &["^steam_app_", "^steam_proton$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "gamescope",
        label: "gamescope",
        app_ids: &["^gamescope$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "wine",
        label: "Wine / Proton programs (.exe)",
        app_ids: &["\\.exe$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "reaper",
        label: "REAPER",
        app_ids: &["^REAPER$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "obs",
        label: "OBS Studio",
        app_ids: &["^com\\.obsproject\\.Studio$", "^obs$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "resolve",
        label: "DaVinci Resolve",
        app_ids: &["^resolve$", "^DaVinci Resolve"],
        titles: &[],
    },
    DefaultOpaque {
        id: "blender",
        label: "Blender",
        app_ids: &["^blender$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "gimp",
        label: "GIMP",
        app_ids: &["^gimp", "^org\\.gimp\\.GIMP$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "krita",
        label: "Krita",
        app_ids: &["^krita$", "^org\\.kde\\.krita$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "inkscape",
        label: "Inkscape",
        app_ids: &["^org\\.inkscape\\.Inkscape$"],
        titles: &[],
    },
    DefaultOpaque {
        id: "image-viewers",
        label: "Image viewers (Loupe, Eye of GNOME, Gwenview, imv, feh, swayimg)",
        app_ids: &[
            "^org\\.gnome\\.Loupe$",
            "^org\\.gnome\\.eog$",
            "^org\\.kde\\.gwenview$",
            "^imv$",
            "^feh$",
            "^swayimg$",
        ],
        titles: &[],
    },
];

/// Global translucency: the theme's values (or the user's).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GlassTheme {
    pub enabled: bool,
    pub focused: f64,
    pub unfocused: f64,
    pub blur: bool,
}

impl Default for GlassTheme {
    /// Matches cli/loft/facets/defaults/material.json `windows`.
    fn default() -> Self {
        GlassTheme {
            enabled: true,
            focused: 0.9,
            unfocused: 0.8,
            blur: true,
        }
    }
}

impl GlassTheme {
    /// `windows` of the rendered theme.json (`translucent`, `opacity.focused`,
    /// `opacity.unfocused`, `blur`); missing keys keep the defaults.
    pub fn from_theme_json(v: &Value) -> Self {
        let mut g = GlassTheme::default();
        let Some(w) = v.get("windows") else { return g };
        if let Some(b) = w.get("translucent").and_then(Value::as_bool) {
            g.enabled = b;
        }
        if let Some(f) = w.pointer("/opacity/focused").and_then(Value::as_f64) {
            g.focused = clamp(f);
        }
        if let Some(f) = w.pointer("/opacity/unfocused").and_then(Value::as_f64) {
            g.unfocused = clamp(f);
        }
        if let Some(b) = w.get("blur").and_then(Value::as_bool) {
            g.blur = b;
        }
        g
    }

    /// The active theme's values: `<state>/current/theme.json`.
    pub fn load(state: &Path) -> Self {
        std::fs::read_to_string(state.join("current").join("theme.json"))
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .map(|v| Self::from_theme_json(&v))
            .unwrap_or_default()
    }

    fn json(&self) -> Value {
        json!({ "enabled": self.enabled, "focused": self.focused, "unfocused": self.unfocused, "blur": self.blur })
    }
}

fn clamp(f: f64) -> f64 {
    (f.clamp(0.05, 1.0) * 1000.0).round() / 1000.0
}

fn glass_section(ov: &Overrides) -> Option<&Map<String, Value>> {
    ov.0.get(GLASS).and_then(Value::as_object)
}

/// The theme's values with the user's on top.
pub fn effective(ov: &Overrides, theme: &GlassTheme) -> GlassTheme {
    let mut g = *theme;
    if let Some(u) = glass_section(ov) {
        if let Some(b) = u.get("enabled").and_then(Value::as_bool) {
            g.enabled = b;
        }
        if let Some(f) = u.get("focused").and_then(Value::as_f64) {
            g.focused = clamp(f);
        }
        if let Some(f) = u.get("unfocused").and_then(Value::as_f64) {
            g.unfocused = clamp(f);
        }
        if let Some(b) = u.get("blur").and_then(Value::as_bool) {
            g.blur = b;
        }
    }
    g
}

pub fn defaults_off(ov: &Overrides) -> Vec<String> {
    glass_section(ov)
        .and_then(|g| g.get("defaults-off"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

pub fn default_by_id(id: &str) -> Option<&'static DefaultOpaque> {
    DEFAULT_OPAQUE.iter().find(|d| d.id == id)
}

/// The built-in entry whose app-id regexes match this app id.
pub fn default_for_app(app_id: &str) -> Option<&'static DefaultOpaque> {
    DEFAULT_OPAQUE.iter().find(|d| {
        d.app_ids
            .iter()
            .any(|r| regex::Regex::new(r).is_ok_and(|re| re.is_match(app_id)))
    })
}

fn rules(ov: &Overrides) -> BTreeMap<&String, &Map<String, Value>> {
    ov.0.get(RULES)
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| Some((k, v.as_object()?)))
                .collect()
        })
        .unwrap_or_default()
}

fn app_match(app: &str) -> Node {
    Node::new("match").prop("app-id", Val::Str(format!("^{}$", regex_literal(app))))
}

/// niri draws the focus ring / border as a solid rectangle behind a window
/// by default (`draw-border-with-background`), which a translucent window
/// shows instead of the blurred desktop as soon as it's focused. Every rule
/// that makes windows see-through turns it off.
fn no_border_background() -> Node {
    Node::new("draw-border-with-background").arg(Val::Bool(false))
}

fn blur_node(on: bool) -> Node {
    Node::new("background-effect").child(Node::new("blur").arg(Val::Bool(on)))
}

/// A config window-rule's `match` turned into an `exclude` with the same
/// properties (so the global glass leaves those windows to the config).
fn as_exclude(m: &kdl::KdlNode) -> Node {
    let mut n = Node::from_kdl(m);
    n.name = "exclude".into();
    n
}

/// Window rules in the user's own config (not Loft's base.kdl / theme) that
/// set `opacity`: their matches.
fn config_opacity_matches(base: Option<&ConfigTree>) -> Vec<Node> {
    let Some(t) = base else { return Vec::new() };
    let mut out: Vec<Node> = Vec::new();
    for r in t.find_all(&["window-rule"]) {
        if origin_of(&r.file.path.display().to_string()) != "config" {
            continue;
        }
        if !r
            .node
            .iter_children()
            .any(|c| c.name().value() == "opacity")
        {
            continue;
        }
        for m in r
            .node
            .iter_children()
            .filter(|c| c.name().value() == "match")
        {
            let n = as_exclude(m);
            if !out.contains(&n) {
                out.push(n);
            }
        }
    }
    out
}

/// The global rules + the built-in opaque list + the per-app rules.
/// `theme`: None leaves the global look and the built-in list out (only the
/// per-app rules), for callers that don't manage window glass.
pub fn render(ov: &Overrides, base: Option<&ConfigTree>, theme: Option<&GlassTheme>) -> Vec<Node> {
    let managed = theme.is_some();
    let g = effective(ov, theme.unwrap_or(&GlassTheme::default()));
    let mut nodes = Vec::new();
    if managed && g.enabled {
        // Loft's own windows (Settings, Utilities, …: Quickshell) draw their
        // own glass; niri's opacity would only fade their text.
        let mut excludes = vec![Node::new("exclude").prop("app-id", Val::Str(SHELL_APP_ID.into()))];
        excludes.extend(config_opacity_matches(base));
        let mut all = Node::new("window-rule");
        all.children.extend(excludes.iter().cloned());
        all = all.child(Node::new("opacity").arg(Val::Float(g.focused)));
        all = all.child(no_border_background());
        if g.blur {
            all = all.child(blur_node(true));
        }
        nodes.push(all);
        let mut unf =
            Node::new("window-rule").child(Node::new("match").prop("is-focused", Val::Bool(false)));
        unf.children.extend(excludes);
        nodes.push(unf.child(Node::new("opacity").arg(Val::Float(g.unfocused))));

        let off = defaults_off(ov);
        let mut keep = Node::new("window-rule");
        for d in DEFAULT_OPAQUE
            .iter()
            .filter(|d| !off.iter().any(|o| o == d.id))
        {
            for r in d.app_ids {
                keep = keep.child(Node::new("match").prop("app-id", Val::Str((*r).into())));
            }
            for r in d.titles {
                keep = keep.child(Node::new("match").prop("title", Val::Str((*r).into())));
            }
        }
        if !keep.children.is_empty() {
            nodes.push(
                keep.child(Node::new("opacity").arg(Val::Float(1.0)))
                    .child(blur_node(false)),
            );
        }
    }
    for (app, rec) in rules(ov) {
        nodes.extend(render_app(app, rec, &g));
    }
    nodes
}

/// One app's rules (none when its record is empty).
pub fn render_app(app: &str, rec: &Map<String, Value>, g: &GlassTheme) -> Vec<Node> {
    let mut n = Node::new("window-rule").child(app_match(app));
    let mut unfocused = None;
    let blur = rec.get("blur").and_then(Value::as_bool);
    match rec.get("glass").and_then(Value::as_str) {
        Some("opaque") => {
            n = n.child(Node::new("opacity").arg(Val::Float(1.0)));
            if let Some(b) = blur {
                n = n.child(blur_node(b));
            }
        }
        Some("native") => {
            n = n.child(Node::new("opacity").arg(Val::Float(1.0)));
            n = n.child(no_border_background());
            n = n.child(blur_node(blur.unwrap_or(true)));
        }
        Some("custom") => {
            let f = rec
                .get("opacity")
                .and_then(Value::as_f64)
                .map(clamp)
                .unwrap_or(g.focused);
            let u = rec
                .get("opacity-unfocused")
                .and_then(Value::as_f64)
                .map(clamp)
                .unwrap_or_else(|| clamp(f - (g.focused - g.unfocused).max(0.0)));
            n = n.child(Node::new("opacity").arg(Val::Float(f)));
            n = n.child(no_border_background());
            n = n.child(blur_node(blur.unwrap_or(true)));
            unfocused = Some(u);
        }
        _ => {
            if let Some(b) = blur {
                n = n.child(blur_node(b));
            }
        }
    }
    for key in ["open-on-workspace", "open-on-output"] {
        if let Some(v) = rec
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            n = n.child(Node::new(key).arg(Val::Str(v.to_string())));
        }
    }
    for key in ["open-floating", "open-maximized", "open-fullscreen"] {
        if let Some(b) = rec.get(key).and_then(Value::as_bool) {
            n = n.child(Node::new(key).arg(Val::Bool(b)));
        }
    }
    if let Some(p) = rec.get("default-column-width").and_then(Value::as_f64) {
        n = n.child(
            Node::new("default-column-width")
                .child(Node::new("proportion").arg(Val::Float(p.clamp(0.05, 1.0)))),
        );
    }
    if rec.get("square-corners").and_then(Value::as_bool) == Some(true) {
        n = n.child(Node::new("geometry-corner-radius").arg(Val::Int(0)));
    }
    if let Some(b) = rec
        .get("block-out-from")
        .and_then(Value::as_str)
        .filter(|s| matches!(*s, "screencast" | "screen-capture"))
    {
        n = n.child(Node::new("block-out-from").arg(Val::Str(b.to_string())));
    }
    let mut out = Vec::new();
    if n.children.len() > 1 {
        out.push(n);
    }
    if let Some(u) = unfocused {
        out.push(
            Node::new("window-rule")
                .child(app_match(app).prop("is-focused", Val::Bool(false)))
                .child(Node::new("opacity").arg(Val::Float(u))),
        );
    }
    out
}

fn validate_field(app: &str, k: &str, v: &Value) -> Result<()> {
    let ok = match k {
        "open-on-workspace" | "open-on-output" => v.is_string(),
        "glass" => matches!(v.as_str(), Some("opaque" | "custom" | "native")),
        "opacity" | "opacity-unfocused" => v.as_f64().is_some_and(|f| (0.0..=1.0).contains(&f)),
        "default-column-width" => v.as_f64().is_some_and(|f| f > 0.0 && f <= 1.0),
        "blur" | "open-floating" | "open-maximized" | "open-fullscreen" | "square-corners" => {
            v.is_boolean()
        }
        "block-out-from" => matches!(v.as_str(), Some("screencast" | "screen-capture")),
        _ => bail!(
            "window_rules.{app}: unknown field `{k}` (known: {})",
            RULE_FIELDS.join(", ")
        ),
    };
    if !ok {
        bail!("window_rules.{app}.{k}: bad value {v}");
    }
    Ok(())
}

/// `window_rules` of an apply batch: per app, fields merged (`null` drops a
/// field); `null` for the whole app drops its record.
pub fn apply_rules(ov: &mut Overrides, m: &Map<String, Value>) -> Result<()> {
    for (app, v) in m {
        if app.trim().is_empty() {
            bail!("window_rules: empty app id");
        }
        match v {
            Value::Null => {
                if let Some(sec) = ov.0.get_mut(RULES).and_then(Value::as_object_mut) {
                    sec.remove(app);
                }
            }
            Value::Object(fields) => {
                for (k, x) in fields {
                    if !x.is_null() {
                        validate_field(app, k, x)?;
                    }
                }
                let sec =
                    ov.0.entry(RULES)
                        .or_insert_with(|| Value::Object(Map::new()));
                if !sec.is_object() {
                    *sec = Value::Object(Map::new());
                }
                let rec = sec
                    .as_object_mut()
                    .unwrap()
                    .entry(app.clone())
                    .or_insert_with(|| Value::Object(Map::new()));
                if !rec.is_object() {
                    *rec = Value::Object(Map::new());
                }
                let rec = rec.as_object_mut().unwrap();
                for (k, x) in fields {
                    if x.is_null() {
                        rec.remove(k);
                    } else {
                        rec.insert(k.clone(), x.clone());
                    }
                }
                // Custom opacity without `glass: custom` means nothing.
                if rec.get("glass").and_then(Value::as_str) != Some("custom") {
                    rec.remove("opacity");
                    rec.remove("opacity-unfocused");
                }
            }
            _ => bail!("window_rules.{app}: expected an object or null"),
        }
    }
    Ok(())
}

/// `window_glass` of an apply batch: `enabled`, `focused`, `unfocused`,
/// `blur` (null = the theme's), `defaults-off` (the whole list).
pub fn apply_glass(ov: &mut Overrides, m: &Map<String, Value>) -> Result<()> {
    for (k, v) in m {
        let ok = v.is_null()
            || match k.as_str() {
                "enabled" | "blur" => v.is_boolean(),
                "focused" | "unfocused" => v.as_f64().is_some_and(|f| (0.05..=1.0).contains(&f)),
                "defaults-off" => v.as_array().is_some_and(|a| {
                    a.iter()
                        .all(|x| x.as_str().is_some_and(|s| default_by_id(s).is_some()))
                }),
                _ => bail!(
                    "window_glass: unknown key `{k}` (enabled, focused, unfocused, blur, defaults-off)"
                ),
            };
        if !ok {
            bail!("window_glass.{k}: bad value {v}");
        }
        if v.is_null() || v.as_array().is_some_and(Vec::is_empty) {
            ov.remove(&format!("{GLASS}.{k}"));
        } else {
            let sec =
                ov.0.entry(GLASS)
                    .or_insert_with(|| Value::Object(Map::new()));
            if !sec.is_object() {
                *sec = Value::Object(Map::new());
            }
            sec.as_object_mut().unwrap().insert(k.clone(), v.clone());
        }
    }
    Ok(())
}

/// Whether this app is kept opaque (a per-app `glass: opaque`, or a built-in
/// entry that is on), and through what.
pub fn opaque_state(ov: &Overrides, app: &str) -> (bool, Option<&'static str>) {
    let rec = rules(ov).get(&app.to_string()).copied();
    if let Some(g) = rec.and_then(|r| r.get("glass")).and_then(Value::as_str) {
        return (g == "opaque", None);
    }
    match default_for_app(app) {
        Some(d) => (!defaults_off(ov).iter().any(|o| o == d.id), Some(d.id)),
        None => (false, None),
    }
}

/// The batch that keeps an app opaque (or not): through its built-in entry
/// when it has one (and no per-app glass choice), else its own record.
pub fn opaque_batch(ov: &Overrides, app: &str, on: bool) -> Value {
    let rec_glass = rules(ov)
        .get(&app.to_string())
        .and_then(|r| r.get("glass"))
        .and_then(Value::as_str)
        .map(str::to_string);
    match (default_for_app(app), rec_glass.as_deref()) {
        (Some(d), None | Some("opaque")) => {
            let mut off = defaults_off(ov);
            off.retain(|o| o != d.id);
            if !on {
                off.push(d.id.to_string());
            }
            let mut b = json!({ "window_glass": { "defaults-off": off } });
            if rec_glass.is_some() {
                b["window_rules"] = json!({ app: { "glass": null } });
            }
            b
        }
        // custom / native on a built-in app: already not opaque.
        (Some(_), Some(_)) if !on => json!({}),
        _ => {
            json!({ "window_rules": { app: { "glass": if on { json!("opaque") } else { Value::Null } } } })
        }
    }
}

/// A written node on one line: `shadow { softness 40; spread 4 }`.
fn one_line(text: &str) -> String {
    let mut out = String::new();
    for l in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
        if !out.is_empty() {
            out.push_str(if out.ends_with('{') || l == "}" {
                " "
            } else {
                "; "
            });
        }
        out.push_str(l);
    }
    out
}

/// One window-rule from the config tree, for the Window Rules page.
fn describe_config_rule(r: crate::config::NodeRef<'_>) -> Value {
    let mut matches = Vec::new();
    let mut excludes = Vec::new();
    let mut app_ids = Vec::new();
    let mut settings = Vec::new();
    let mut sets_opacity = false;
    for c in r.node.iter_children() {
        let name = c.name().value();
        let text = {
            let mut s = String::new();
            Node::from_kdl(c).write(&mut s, 0);
            let s = one_line(&s);
            // `match app-id="…"` → `app-id="…"` (the list says match / except).
            match name {
                "match" | "exclude" => s[name.len()..].trim().to_string(),
                _ => s,
            }
        };
        match name {
            "match" => {
                if let Some(a) = c.get("app-id").and_then(|v| v.as_string()) {
                    app_ids.push(a.to_string());
                }
                matches.push(text);
            }
            "exclude" => excludes.push(text),
            _ => {
                if name == "opacity" {
                    sets_opacity = true;
                }
                settings.push(text);
            }
        }
    }
    let file = r.file.path.display().to_string();
    json!({
        "file": file,
        "line": r.line(),
        "origin": origin_of(&file),
        "app_ids": app_ids,
        "matches": matches,
        "excludes": excludes,
        "settings": settings,
        "sets_opacity": sets_opacity,
    })
}

/// Everything the Window Rules page shows.
pub fn list(ov: &Overrides, base: Option<&ConfigTree>, theme: &GlassTheme) -> Value {
    let g = effective(ov, theme);
    let off = defaults_off(ov);
    let user = glass_section(ov).cloned().unwrap_or_default();
    let defaults: Vec<Value> = DEFAULT_OPAQUE
        .iter()
        .map(|d| {
            json!({
                "id": d.id, "label": d.label, "app_ids": d.app_ids, "titles": d.titles,
                "on": !off.iter().any(|o| o == d.id),
            })
        })
        .collect();
    let config: Vec<Value> = base
        .map(|t| {
            t.find_all(&["window-rule"])
                .into_iter()
                .map(describe_config_rule)
                .collect()
        })
        .unwrap_or_default();
    json!({
        "glass": {
            "effective": g.json(),
            "theme": theme.json(),
            "user": user,
        },
        "defaults": defaults,
        "rules": ov.0.get(RULES).cloned().unwrap_or_else(|| json!({})),
        "config": config,
        "fields": RULE_FIELDS,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kdl_out::write_doc;

    fn ov(v: Value) -> Overrides {
        Overrides(v.as_object().unwrap().clone())
    }

    #[test]
    fn global_rules_then_defaults_then_apps() {
        let o = ov(json!({
            "window-glass": { "focused": 0.85, "defaults-off": ["reaper"] },
            "window-rules": {
                "kitty": { "glass": "native" },
                "code": { "glass": "custom", "opacity": 0.8, "open-floating": true, "square-corners": true },
                "mpv": { "blur": true }
            }
        }));
        let out = write_doc(&render(&o, None, Some(&GlassTheme::default())));
        assert!(out.starts_with("window-rule {\n    exclude app-id=\"^org\\\\.quickshell$\"\n    opacity 0.85\n    draw-border-with-background false\n    background-effect {\n        blur true\n    }\n}\n"), "{out}");
        assert!(
            out.contains("window-rule {\n    match is-focused=false\n    exclude app-id=\"^org\\\\.quickshell$\"\n    opacity 0.8\n}\n"),
            "{out}"
        );
        assert!(
            out.contains("    match app-id=\"^mpv$\"\n    match app-id=\"^vlc$\"\n"),
            "{out}"
        );
        assert!(!out.contains("REAPER"), "{out}");
        assert!(
            out.contains("    match title=\"^Picture-in-Picture$\"\n"),
            "{out}"
        );
        assert!(out.contains("window-rule {\n    match app-id=\"^code$\"\n    opacity 0.8\n    draw-border-with-background false\n    background-effect {\n        blur true\n    }\n    open-floating true\n    geometry-corner-radius 0\n}\n"), "{out}");
        // Unfocused follows the focused value down by the global step (0.85 → 0.8).
        assert!(
            out.contains(
                "window-rule {\n    match app-id=\"^code$\" is-focused=false\n    opacity 0.75\n}\n"
            ),
            "{out}"
        );
        assert!(out.contains("window-rule {\n    match app-id=\"^kitty$\"\n    opacity 1.0\n    draw-border-with-background false\n    background-effect {\n        blur true\n    }\n}\n"), "{out}");
        // Per-app rules come after the built-in list.
        let defaults_at = out.find("^vlc$").unwrap();
        assert!(
            out.find("^mpv$\"\n    background-effect").unwrap() > defaults_at,
            "{out}"
        );
    }

    #[test]
    fn switched_off_leaves_only_per_app_rules() {
        let o = ov(json!({
            "window-glass": { "enabled": false },
            "window-rules": { "foot": { "glass": "custom", "opacity": 0.9, "opacity-unfocused": 0.85 } }
        }));
        let out = write_doc(&render(&o, None, Some(&GlassTheme::default())));
        assert_eq!(
            out,
            "window-rule {\n    match app-id=\"^foot$\"\n    opacity 0.9\n    draw-border-with-background false\n    background-effect {\n        blur true\n    }\n}\n\nwindow-rule {\n    match app-id=\"^foot$\" is-focused=false\n    opacity 0.85\n}\n"
        );
        let themed_off = GlassTheme {
            enabled: false,
            ..GlassTheme::default()
        };
        assert!(render(&Overrides::default(), None, Some(&themed_off)).is_empty());
    }

    #[test]
    fn config_opacity_rules_are_excluded() {
        let d = crate::config::tests_support::scratch("glass-config");
        std::fs::write(
            d.join("config.kdl"),
            "window-rule {\n    match app-id=\"^kitty$\" is-focused=false\n    opacity 0.9\n}\nwindow-rule {\n    match app-id=\"^firefox$\"\n    open-maximized true\n}\n",
        )
        .unwrap();
        let tree = ConfigTree::load(&d.join("config.kdl"), &|_| false).unwrap();
        let out = write_doc(&render(
            &Overrides::default(),
            Some(&tree),
            Some(&GlassTheme::default()),
        ));
        assert!(
            out.starts_with(
                "window-rule {\n    exclude app-id=\"^org\\\\.quickshell$\"\n    exclude app-id=\"^kitty$\" is-focused=false\n    opacity 0.9\n"
            ),
            "{out}"
        );
        assert!(!out.contains("firefox"), "{out}");
        let l = list(&Overrides::default(), Some(&tree), &GlassTheme::default());
        assert_eq!(l["config"][0]["line"], 1);
        assert_eq!(l["config"][0]["origin"], "config");
        assert_eq!(l["config"][0]["sets_opacity"], true);
        assert_eq!(l["config"][0]["app_ids"][0], "^kitty$");
        assert_eq!(l["config"][1]["settings"][0], "open-maximized true");
        assert_eq!(
            l["config"][0]["matches"][0],
            "app-id=\"^kitty$\" is-focused=false"
        );
        assert_eq!(
            one_line("shadow {\n    softness 40\n    offset x=0 y=4\n}\n"),
            "shadow { softness 40; offset x=0 y=4 }"
        );
    }

    #[test]
    fn merge_and_opaque_toggles() {
        let mut o = Overrides::default();
        apply_rules(
            &mut o,
            json!({ "foot": { "open-on-workspace": "Desktop 2" } })
                .as_object()
                .unwrap(),
        )
        .unwrap();
        apply_rules(
            &mut o,
            json!({ "foot": { "glass": "opaque", "blur": false } })
                .as_object()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            o.0["window-rules"]["foot"],
            json!({ "open-on-workspace": "Desktop 2", "glass": "opaque", "blur": false })
        );
        assert_eq!(opaque_state(&o, "foot"), (true, None));
        apply_rules(
            &mut o,
            json!({ "foot": { "glass": null } }).as_object().unwrap(),
        )
        .unwrap();
        assert_eq!(opaque_state(&o, "foot"), (false, None));
        assert!(
            apply_rules(
                &mut o,
                json!({ "foot": { "glass": "clear" } }).as_object().unwrap()
            )
            .is_err()
        );
        assert!(
            apply_rules(
                &mut o,
                json!({ "foot": { "wobbly": true } }).as_object().unwrap()
            )
            .is_err()
        );

        // A built-in app: through defaults-off.
        assert_eq!(opaque_state(&o, "mpv"), (true, Some("mpv")));
        let b = opaque_batch(&o, "mpv", false);
        assert_eq!(b, json!({ "window_glass": { "defaults-off": ["mpv"] } }));
        apply_glass(&mut o, b["window_glass"].as_object().unwrap()).unwrap();
        assert_eq!(opaque_state(&o, "mpv"), (false, Some("mpv")));
        assert_eq!(
            opaque_state(&o, "steam_app_1091500"),
            (true, Some("steam-games"))
        );
        let b = opaque_batch(&o, "mpv", true);
        apply_glass(&mut o, b["window_glass"].as_object().unwrap()).unwrap();
        assert!(o.0.get("window-glass").is_none(), "{:?}", o.0);
        assert_eq!(
            opaque_batch(&o, "foot", true),
            json!({ "window_rules": { "foot": { "glass": "opaque" } } })
        );
        assert!(
            apply_glass(
                &mut o,
                json!({ "defaults-off": ["nope"] }).as_object().unwrap()
            )
            .is_err()
        );
        assert!(apply_glass(&mut o, json!({ "focused": 2 }).as_object().unwrap()).is_err());
    }

    #[test]
    fn theme_values() {
        let t = GlassTheme::from_theme_json(
            &json!({ "windows": { "translucent": false, "opacity": { "focused": 0.9, "unfocused": 0.8 }, "blur": false } }),
        );
        assert_eq!(
            t,
            GlassTheme {
                enabled: false,
                focused: 0.9,
                unfocused: 0.8,
                blur: false
            }
        );
        assert_eq!(
            GlassTheme::from_theme_json(&json!({})),
            GlassTheme::default()
        );
    }
}
