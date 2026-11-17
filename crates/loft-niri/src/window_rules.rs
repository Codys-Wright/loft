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
//! **Where a window opens** (docs/KWIN.md §4.17). A record's key is the app
//! id it matches exactly, unless `match-app-id` (a regex) replaces that; then
//! the key is just the rule's name (`agents-coding`). `match-title` adds a
//! title regex, `exclude-app-id` / `exclude-title` leave windows out. Then:
//!
//! | field | niri | KWin (loft-bridge.js) |
//! |---|---|---|
//! | `open-on-output` | connector / identity, or a display role (`main`, `right`, …) resolved on the live outputs | same, resolved on KWin's outputs |
//! | `open-on-workspace` | named workspace | the virtual desktop of that name (when no `open-on-desktop`) |
//! | `open-on-desktop` | a name becomes `open-on-workspace` (when that is unset); a number is ignored | virtual desktop: number (1 = first) or name |
//! | `open-on-activity` | ignored | the user's KDE Activity, by name (case and `-`/`_`/space ignored) |
//! | `open-fullscreen` / `open-maximized` | same | same |
//! | `open-size` | `WxH` / `W%xH%`: `default-column-width` (unless that is set) + `default-window-height` | the frame's size |
//! | `open-position` | ignored | `center`, `left` / `right` (that half of the work area), `X,Y` (in the output) |
//! | `keep-above` | ignored | keep above |
//! | `follow` | `open-focused` | true: switch to its Activity / desktop and focus it; false: you stay where you are |
//!
//! **Nix seed.** `programs.loft.windowRules` writes the same records to
//! `$XDG_CONFIG_HOME/loft/window-rules.json` ([`seed_path`]); per field the
//! runtime record (Settings, `loft windows rule`) wins over it.
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
    "match-app-id",
    "match-title",
    "exclude-app-id",
    "exclude-title",
    "open-on-activity",
    "open-on-desktop",
    "open-size",
    "open-position",
    "keep-above",
    "follow",
];

/// Fields only KWin acts on (niri ignores them; `open-on-desktop` partly).
pub const KWIN_FIELDS: &[&str] = &["open-on-activity", "open-on-desktop", "open-position", "keep-above"];

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

fn str_field<'a>(rec: &'a Map<String, Value>, k: &str) -> Option<&'a str> {
    rec.get(k).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// The app-id regex a record matches: `match-app-id`, else its key exactly.
pub fn app_id_regex(app: &str, rec: &Map<String, Value>) -> String {
    str_field(rec, "match-app-id").map_or_else(|| format!("^{}$", regex_literal(app)), str::to_string)
}

/// A record's `match` node (app id, and title when given).
fn rule_match(app: &str, rec: &Map<String, Value>) -> Node {
    let mut m = Node::new("match").prop("app-id", Val::Str(app_id_regex(app, rec)));
    if let Some(t) = str_field(rec, "match-title") {
        m = m.prop("title", Val::Str(t.to_string()));
    }
    m
}

/// A record's `exclude` nodes (each leaves out what it matches).
fn rule_excludes(rec: &Map<String, Value>) -> Vec<Node> {
    let mut v = Vec::new();
    if let Some(a) = str_field(rec, "exclude-app-id") {
        v.push(Node::new("exclude").prop("app-id", Val::Str(a.to_string())));
    }
    if let Some(t) = str_field(rec, "exclude-title") {
        v.push(Node::new("exclude").prop("title", Val::Str(t.to_string())));
    }
    v
}

/// One side of `open-size`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Dim {
    Px(u32),
    /// Share of the output's work area, 0–1.
    Share(f64),
}

impl Dim {
    fn parse(s: &str) -> Option<Dim> {
        let s = s.trim();
        if let Some(p) = s.strip_suffix('%') {
            let f: f64 = p.trim().parse().ok()?;
            return (f > 0.0 && f <= 100.0).then_some(Dim::Share(f / 100.0));
        }
        let n: u32 = s.parse().ok()?;
        (n > 0 && n <= 32768).then_some(Dim::Px(n))
    }

    fn json(self) -> Value {
        match self {
            Dim::Px(n) => json!({ "px": n }),
            Dim::Share(f) => json!({ "share": f }),
        }
    }

    /// niri's `{ fixed N }` / `{ proportion F }`.
    fn node(self, name: &str) -> Node {
        match self {
            Dim::Px(n) => Node::new(name).child(Node::new("fixed").arg(Val::Int(i64::from(n)))),
            Dim::Share(f) => Node::new(name).child(Node::new("proportion").arg(Val::Float(f))),
        }
    }
}

/// `open-size`: `1200x800`, `60%x80%`, `50%x900`.
pub fn parse_size(s: &str) -> Option<(Dim, Dim)> {
    let (w, h) = s.split_once(['x', 'X', '×'])?;
    Some((Dim::parse(w)?, Dim::parse(h)?))
}

/// `open-position`: `center`, `left`, `right` (that half), or `X,Y`.
pub fn parse_position(s: &str) -> Option<Value> {
    match s.trim() {
        p @ ("center" | "left" | "right") => Some(json!(p)),
        p => {
            let (x, y) = p.split_once(',')?;
            let x: i32 = x.trim().parse().ok()?;
            let y: i32 = y.trim().parse().ok()?;
            Some(json!([x, y]))
        }
    }
}

/// connector → its display roles (crate::spaces::roles), for `open-on-output`.
pub type RoleMap = BTreeMap<String, Vec<String>>;

/// `open-on-output`: a connector / identity as is; a role → the connector
/// that has it (None: no display has that role now).
pub fn resolve_output(target: &str, roles: &RoleMap) -> Option<String> {
    let t = target.trim();
    if roles.contains_key(t) {
        return Some(t.to_string());
    }
    if crate::spaces::roles::is_known_role(t) {
        // `*`: any, so no constraint worth writing.
        if t == "*" {
            return None;
        }
        return roles.iter().find(|(_, rs)| rs.iter().any(|r| r == t)).map(|(c, _)| c.clone());
    }
    Some(t.to_string())
}

/// Where the Nix seed (`programs.loft.windowRules`) is: $LOFT_WINDOW_RULES,
/// else $XDG_CONFIG_HOME/loft/window-rules.json, else ~/.config/loft/….
pub fn seed_path() -> std::path::PathBuf {
    if let Some(p) = std::env::var_os("LOFT_WINDOW_RULES").filter(|p| !p.is_empty()) {
        return p.into();
    }
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|d| !d.is_empty())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config"));
    base.join("loft").join("window-rules.json")
}

/// The seed's records (`{name: {field: value}}`); none when it's missing.
/// A bad file is reported on stderr and ignored.
pub fn load_seed(path: &Path) -> Map<String, Value> {
    let Ok(text) = std::fs::read_to_string(path) else { return Map::new() };
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Object(m)) => {
            // `{"window-rules": {...}}` too.
            match m.get(RULES) {
                Some(Value::Object(r)) => r.clone(),
                _ => m,
            }
        }
        Ok(_) | Err(_) => {
            eprintln!("loft-niri: {}: expected {{\"app\": {{field: value}}}}; ignored", path.display());
            Map::new()
        }
    }
}

/// The overrides with the seed's records under them: per field, the
/// runtime record wins. Bad seed fields are dropped (with a note).
pub fn with_seed(ov: &Overrides, seed: &Map<String, Value>) -> Overrides {
    if seed.is_empty() {
        return ov.clone();
    }
    let mut out = ov.clone();
    let mut merged: Map<String, Value> = Map::new();
    for (app, rec) in seed {
        let Some(rec) = rec.as_object() else { continue };
        let mut clean = Map::new();
        for (k, v) in rec {
            match validate_field(app, k, v) {
                Ok(()) => drop(clean.insert(k.clone(), v.clone())),
                Err(e) => eprintln!("loft-niri: window-rules seed: {e}"),
            }
        }
        merged.insert(app.clone(), Value::Object(clean));
    }
    if let Some(runtime) = ov.0.get(RULES).and_then(Value::as_object) {
        for (app, rec) in runtime {
            let Some(rec) = rec.as_object() else { continue };
            let entry = merged.entry(app.clone()).or_insert_with(|| Value::Object(Map::new()));
            let e = entry.as_object_mut().unwrap();
            for (k, v) in rec {
                e.insert(k.clone(), v.clone());
            }
        }
    }
    out.0.insert(RULES.into(), Value::Object(merged));
    out
}

/// The roles of niri's live outputs (`main` from Settings → Displays).
pub fn niri_roles(live: Option<&crate::outputs::Outputs>, main: Option<&str>) -> RoleMap {
    live.map(|o| {
        let ds = crate::spaces::roles::displays_from_niri(o);
        crate::spaces::roles::roles(&ds, main)
    })
    .unwrap_or_default()
}

/// The records as loft-bridge.js applies them under KWin (docs/KWIN.md
/// §4.17): only records that place windows, with JS-ready regexes and the
/// output resolved on `roles` (`output_role` keeps what was asked).
pub fn kwin_rules(ov: &Overrides, roles: &RoleMap) -> Value {
    let mut out = Vec::new();
    for (app, rec) in rules(ov) {
        let b = |k: &str| rec.get(k).and_then(Value::as_bool);
        let open = if b("open-fullscreen") == Some(true) {
            "fullscreen"
        } else if b("open-maximized") == Some(true) {
            "maximized"
        } else {
            ""
        };
        let desktop = rec
            .get("open-on-desktop")
            .filter(|v| v.is_u64() || v.as_str().is_some_and(|s| !s.is_empty()))
            .cloned()
            .or_else(|| str_field(rec, "open-on-workspace").map(|s| json!(s)));
        let role = str_field(rec, "open-on-output");
        let size = str_field(rec, "open-size").and_then(parse_size);
        let position = str_field(rec, "open-position").and_then(parse_position);
        let activity = str_field(rec, "open-on-activity");
        let keep_above = b("keep-above");
        let places = !open.is_empty() || desktop.is_some() || role.is_some() || size.is_some() || position.is_some() || activity.is_some() || keep_above.is_some();
        if !places {
            continue;
        }
        out.push(json!({
            "name": app,
            "appId": app_id_regex(app, rec),
            "title": str_field(rec, "match-title"),
            "excludeAppId": str_field(rec, "exclude-app-id"),
            "excludeTitle": str_field(rec, "exclude-title"),
            "activityName": activity,
            "desktop": desktop,
            "output": role.and_then(|r| resolve_output(r, roles)),
            "outputRole": role,
            "open": open,
            "size": size.map(|(w, h)| json!({ "w": w.json(), "h": h.json() })),
            "position": position,
            "keepAbove": keep_above,
            "follow": b("follow").unwrap_or(false),
        }));
    }
    Value::Array(out)
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
/// `roles`: the live outputs' display roles, for `open-on-output` roles.
pub fn render(ov: &Overrides, base: Option<&ConfigTree>, theme: Option<&GlassTheme>, roles: &RoleMap) -> Vec<Node> {
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
        nodes.extend(render_app(app, rec, &g, roles));
    }
    nodes
}

/// One app's rules (none when its record is empty).
pub fn render_app(app: &str, rec: &Map<String, Value>, g: &GlassTheme, roles: &RoleMap) -> Vec<Node> {
    let excludes = rule_excludes(rec);
    let mut n = Node::new("window-rule").child(rule_match(app, rec));
    n.children.extend(excludes.iter().cloned());
    let head = n.children.len();
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
    // A desktop name stands for a named workspace on niri; a number has no
    // niri meaning (workspace indexes shift), so it's KWin's only.
    let workspace = str_field(rec, "open-on-workspace").or_else(|| str_field(rec, "open-on-desktop"));
    if let Some(v) = workspace {
        n = n.child(Node::new("open-on-workspace").arg(Val::Str(v.to_string())));
    }
    if let Some(v) = str_field(rec, "open-on-output").and_then(|o| resolve_output(o, roles)) {
        n = n.child(Node::new("open-on-output").arg(Val::Str(v)));
    }
    for key in ["open-floating", "open-maximized", "open-fullscreen"] {
        if let Some(b) = rec.get(key).and_then(Value::as_bool) {
            n = n.child(Node::new(key).arg(Val::Bool(b)));
        }
    }
    if let Some(b) = rec.get("follow").and_then(Value::as_bool) {
        n = n.child(Node::new("open-focused").arg(Val::Bool(b)));
    }
    let size = str_field(rec, "open-size").and_then(parse_size);
    if let Some(p) = rec.get("default-column-width").and_then(Value::as_f64) {
        n = n.child(
            Node::new("default-column-width")
                .child(Node::new("proportion").arg(Val::Float(p.clamp(0.05, 1.0)))),
        );
    } else if let Some((w, _)) = size {
        n = n.child(w.node("default-column-width"));
    }
    if let Some((_, h)) = size {
        n = n.child(h.node("default-window-height"));
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
    if n.children.len() > head {
        out.push(n);
    }
    if let Some(u) = unfocused {
        let mut r = Node::new("window-rule").child(rule_match(app, rec).prop("is-focused", Val::Bool(false)));
        r.children.extend(excludes);
        out.push(r.child(Node::new("opacity").arg(Val::Float(u))));
    }
    out
}

fn validate_field(app: &str, k: &str, v: &Value) -> Result<()> {
    let ok = match k {
        "open-on-workspace" | "open-on-output" | "open-on-activity" => v.is_string(),
        "match-app-id" | "match-title" | "exclude-app-id" | "exclude-title" => {
            let Some(r) = v.as_str() else { bail!("window_rules.{app}.{k}: expected a regex string") };
            if let Err(e) = regex::Regex::new(r) {
                bail!("window_rules.{app}.{k}: bad regex `{r}`: {e}");
            }
            true
        }
        "open-on-desktop" => v.as_u64().is_some_and(|n| n >= 1) || v.as_str().is_some_and(|s| !s.trim().is_empty()),
        "open-size" => v.as_str().is_some_and(|s| parse_size(s).is_some()),
        "open-position" => v.as_str().is_some_and(|s| parse_position(s).is_some()),
        "keep-above" | "follow" => v.is_boolean(),
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
        let out = write_doc(&render(&o, None, Some(&GlassTheme::default()), &RoleMap::new()));
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
        let out = write_doc(&render(&o, None, Some(&GlassTheme::default()), &RoleMap::new()));
        assert_eq!(
            out,
            "window-rule {\n    match app-id=\"^foot$\"\n    opacity 0.9\n    draw-border-with-background false\n    background-effect {\n        blur true\n    }\n}\n\nwindow-rule {\n    match app-id=\"^foot$\" is-focused=false\n    opacity 0.85\n}\n"
        );
        let themed_off = GlassTheme {
            enabled: false,
            ..GlassTheme::default()
        };
        assert!(render(&Overrides::default(), None, Some(&themed_off), &RoleMap::new()).is_empty());
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
            &RoleMap::new(),
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

    fn two_displays() -> RoleMap {
        let ds = vec![
            crate::spaces::roles::Display { name: "WL-0".into(), identity: String::new(), x: 0, y: 0, width: 1920, height: 1080 },
            crate::spaces::roles::Display { name: "WL-1".into(), identity: String::new(), x: 1920, y: 0, width: 1920, height: 1080 },
        ];
        crate::spaces::roles::roles(&ds, Some("WL-0"))
    }

    #[test]
    fn placement_fields_on_niri() {
        let o = ov(json!({ "window-rules": {
            "agents": { "match-app-id": "^com\\.mitchellh\\.ghostty$", "match-title": "^claude",
                        "exclude-title": "scratch", "open-on-output": "right", "open-on-desktop": "code",
                        "open-on-activity": "Coding", "open-size": "60%x900", "follow": false,
                        "keep-above": true, "open-position": "center" },
            "org.kde.kwrite": { "open-on-desktop": 2, "open-on-output": "left-3", "open-fullscreen": true }
        }}));
        let out = write_doc(&render(&o, None, None, &two_displays()));
        assert!(out.contains("window-rule {\n    match app-id=\"^com\\\\.mitchellh\\\\.ghostty$\" title=\"^claude\"\n    exclude title=\"scratch\"\n    open-on-workspace \"code\"\n    open-on-output \"WL-1\"\n    open-focused false\n    default-column-width {\n        proportion 0.6\n    }\n    default-window-height {\n        fixed 900\n    }\n}\n"), "{out}");
        // A numbered desktop and a role no display has: only what niri can do.
        assert!(out.contains("window-rule {\n    match app-id=\"^org\\\\.kde\\\\.kwrite$\"\n    open-fullscreen true\n}\n"), "{out}");
        assert!(!out.contains("Coding") && !out.contains("keep"), "{out}");
    }

    #[test]
    fn kwin_export() {
        let o = ov(json!({ "window-rules": {
            "org.kde.kwrite": { "open-on-activity": "Coding", "open-on-desktop": 2, "open-on-output": "right",
                                "open-fullscreen": true, "glass": "opaque" },
            "konsole": { "open-size": "1200x800", "open-position": "10,20", "open-on-workspace": "Work" },
            "org.gnome.Nautilus": { "glass": "opaque" }
        }}));
        let r = kwin_rules(&o, &two_displays());
        let r = r.as_array().unwrap();
        assert_eq!(r.len(), 2, "{r:?}");
        let k = r.iter().find(|x| x["name"] == "org.kde.kwrite").unwrap();
        assert_eq!(k["appId"], "^org\\.kde\\.kwrite$");
        assert_eq!(k["activityName"], "Coding");
        assert_eq!(k["desktop"], 2);
        assert_eq!(k["output"], "WL-1");
        assert_eq!(k["outputRole"], "right");
        assert_eq!(k["open"], "fullscreen");
        assert_eq!(k["follow"], false);
        let c = r.iter().find(|x| x["name"] == "konsole").unwrap();
        assert_eq!(c["size"], json!({ "w": { "px": 1200 }, "h": { "px": 800 } }));
        assert_eq!(c["position"], json!([10, 20]));
        assert_eq!(c["desktop"], "Work");
        assert_eq!(c["output"], Value::Null);
    }

    #[test]
    fn seed_under_runtime() {
        let seed = json!({
            "org.kde.kwrite": { "open-on-activity": "Coding", "open-fullscreen": true },
            "bad": { "open-size": "huge", "follow": true }
        });
        let o = ov(json!({ "window-rules": { "org.kde.kwrite": { "open-fullscreen": false, "blur": true } } }));
        let m = with_seed(&o, seed.as_object().unwrap());
        assert_eq!(
            m.0[RULES],
            json!({ "org.kde.kwrite": { "open-on-activity": "Coding", "open-fullscreen": false, "blur": true },
                    "bad": { "follow": true } })
        );
        assert_eq!(with_seed(&o, &Map::new()), o);
    }

    #[test]
    fn new_fields_are_checked() {
        let mut o = Overrides::default();
        for bad in [
            json!({ "a": { "open-size": "12x" } }),
            json!({ "a": { "open-size": "0x10" } }),
            json!({ "a": { "open-size": "120%x10" } }),
            json!({ "a": { "open-position": "middle" } }),
            json!({ "a": { "open-on-desktop": 0 } }),
            json!({ "a": { "match-title": "(" } }),
            json!({ "a": { "follow": "yes" } }),
        ] {
            assert!(apply_rules(&mut o, bad.as_object().unwrap()).is_err(), "{bad}");
        }
        let good = json!({ "a": { "open-size": "50%x100%", "open-position": "right", "open-on-desktop": "Two",
                                  "match-title": "^x$", "keep-above": true } });
        apply_rules(&mut o, good.as_object().unwrap()).unwrap();
        assert_eq!(parse_size("1200×800"), Some((Dim::Px(1200), Dim::Px(800))));
        assert_eq!(resolve_output("DP-4", &two_displays()).as_deref(), Some("DP-4"));
        assert_eq!(resolve_output("main", &two_displays()).as_deref(), Some("WL-0"));
        assert_eq!(resolve_output("*", &two_displays()), None);
    }
}
