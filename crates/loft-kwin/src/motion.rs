//! `loft-kwin motion`: Settings → Spaces & Windows → Layout & Motion under
//! KWin (docs/KWIN.md §4.20): KWin's animation speed and its effects.
//!
//! - **Speed**: kdeglobals `[KDE] AnimationDurationFactor` (1 = normal, 0 =
//!   instant, larger = slower), as KDE's Animations page writes it. KWin's
//!   Options watch it with a KConfigWatcher (kwin 6.8.2 `options.cpp`), so a
//!   write with KConfig's notification (`kwriteconfig6 --notify`) takes at
//!   once; KGlobalSettings' `notifyChange` tells running apps, as the KCM does.
//! - **Effects**: kwinrc `[Plugins] <id>Enabled`, then `loadEffect` /
//!   `unloadEffect` on `org.kde.KWin /Effects`, which is what applies it
//!   live (KWin's effect loader reads `[Plugins]` only at start and on a
//!   reconfigure, and a reconfigure never unloads). Like KDE's KCMs, a value
//!   equal to the effect's default removes the key instead of writing it.
//!   Effects in one of KWin's exclusive groups (`X-KWin-Exclusive-Category`)
//!   are a choice: picking one turns the others of the group off.
//! - `fadingpopups` is Loft's: loft-kwin unloads it while it runs (main.rs
//!   `EFFECTS_OFF`), so it's not offered here and `set` refuses it.
//!
//! `loft-kwin motion` prints `{ok, speed, choices, toggles}`; `loft-kwin
//! motion set JSON` applies `{"speed": 0.5, "choices": {"minimize":
//! "magiclamp"}, "effects": {"wobblywindows": true}}` and prints the result.
//! Only effects KWin has (`listOfEffects`) and supports (`areEffectsSupported`)
//! are listed.

use std::collections::HashMap;
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value, json};
use zbus::Connection;

use crate::kwin_proxy;

/// Effects loft-kwin manages itself while it runs (main.rs `EFFECTS_OFF`).
const MANAGED: &[&str] = &["fadingpopups"];

/// One effect: KWin's plugin id, the name shown, and its `EnabledByDefault`
/// (kwin 6.8.2 metadata). `default_fn`: KWin decides the default at runtime
/// (blur's `enabledByDefaultMethod`), so its key is always written.
#[derive(Debug, Clone, Copy)]
pub struct Fx {
    pub id: &'static str,
    pub label: &'static str,
    pub default: bool,
    pub default_fn: bool,
}

const fn fx(id: &'static str, label: &'static str, default: bool) -> Fx {
    Fx { id, label, default, default_fn: false }
}

/// A group of mutually exclusive effects (one of them, or none).
#[derive(Debug)]
pub struct Choice {
    pub id: &'static str,
    pub label: &'static str,
    pub hint: &'static str,
    pub section: &'static str,
    pub options: &'static [Fx],
}

/// One effect with its own switch.
#[derive(Debug)]
pub struct Toggle {
    pub fx: Fx,
    pub hint: &'static str,
    pub section: &'static str,
}

/// KWin's exclusive groups, as KDE's Animations page shows them.
pub const CHOICES: &[Choice] = &[
    Choice {
        id: "open-close",
        label: "Open and close",
        hint: "How windows appear and go away",
        section: "animations",
        options: &[fx("scale", "Scale", true), fx("glide", "Glide", false), fx("fade", "Fade", false)],
    },
    Choice {
        id: "minimize",
        label: "Minimize",
        hint: "How a window goes to the dock",
        section: "animations",
        options: &[fx("squash", "Squash", true), fx("magiclamp", "Magic lamp", false)],
    },
    Choice {
        id: "maximize",
        label: "Maximize",
        hint: "Maximizing and restoring a window",
        section: "animations",
        options: &[fx("maximize", "Stretch", true)],
    },
    Choice {
        id: "fullscreen",
        label: "Full screen",
        hint: "Entering and leaving full screen",
        section: "animations",
        options: &[fx("fullscreen", "Stretch", true)],
    },
    Choice {
        id: "desktop-switch",
        label: "Switching desktops",
        hint: "Between virtual desktops",
        section: "animations",
        options: &[fx("slide", "Slide", true), fx("fadedesktop", "Fade", false)],
    },
    Choice {
        id: "show-desktop",
        label: "Show desktop",
        hint: "Windows moving aside to show the desktop",
        section: "animations",
        options: &[fx("windowaperture", "Aperture", true), fx("eyeonscreen", "Eye on screen", false)],
    },
    Choice {
        id: "magnifier",
        label: "Magnifier",
        hint: "Meta+= / Meta+- to zoom in and out",
        section: "accessibility",
        options: &[fx("zoom", "Zoom", true), fx("magnifier", "Lens", false)],
    },
];

pub const TOGGLES: &[Toggle] = &[
    Toggle { fx: fx("wobblywindows", "Wobbly windows", false), hint: "Windows wobble while you move them", section: "effects" },
    Toggle { fx: fx("fallapart", "Fall apart", false), hint: "Closing windows break into pieces", section: "effects" },
    Toggle { fx: fx("sheet", "Sheet", false), hint: "Dialogs slide out of their window's title", section: "effects" },
    Toggle { fx: fx("slidingpopups", "Sliding popups", true), hint: "Plasma popups slide in from their edge", section: "effects" },
    Toggle { fx: fx("slideback", "Slide back", false), hint: "Windows slide back when another is raised", section: "effects" },
    Toggle { fx: fx("diminactive", "Dim inactive windows", false), hint: "Darken every window but the active one", section: "effects" },
    Toggle { fx: fx("translucency", "Translucency", false), hint: "Windows see-through while you move them", section: "effects" },
    Toggle {
        fx: Fx { id: "blur", label: "Blur", default: true, default_fn: true },
        hint: "Behind translucent windows and panels, with background contrast",
        section: "effects",
    },
    Toggle { fx: fx("frozenapp", "Grey out frozen apps", true), hint: "Desaturate windows that stop responding", section: "effects" },
    Toggle { fx: fx("startupfeedback", "Launch feedback", true), hint: "A bouncing icon by the pointer while an app starts", section: "effects" },
    Toggle { fx: fx("cube", "Cube", false), hint: "Desktops on a cube (the kwin-effects-cube add-on)", section: "effects" },
    Toggle { fx: fx("overview", "Overview", true), hint: "Loft's overview key and the top-left corner open it", section: "windows" },
    Toggle { fx: fx("windowview", "Present windows", true), hint: "Every window side by side", section: "windows" },
    Toggle { fx: fx("shakecursor", "Shake to find the pointer", true), hint: "Shaking the mouse makes the pointer bigger", section: "accessibility" },
    Toggle { fx: fx("trackmouse", "Track mouse", false), hint: "Meta+Ctrl shows where the pointer is", section: "accessibility" },
    Toggle { fx: fx("mouseclick", "Show mouse clicks", false), hint: "Rings where you click (Meta+*)", section: "accessibility" },
];

/// Every effect the page knows.
pub fn catalog() -> impl Iterator<Item = &'static Fx> {
    CHOICES.iter().flat_map(|c| c.options.iter()).chain(TOGGLES.iter().map(|t| &t.fx))
}

pub fn find(id: &str) -> Option<&'static Fx> {
    catalog().find(|f| f.id == id)
}

pub fn choice(id: &str) -> Option<&'static Choice> {
    CHOICES.iter().find(|c| c.id == id)
}

/// The choice an effect belongs to, if any.
pub fn group_of(id: &str) -> Option<&'static Choice> {
    CHOICES.iter().find(|c| c.options.iter().any(|f| f.id == id))
}

// ── Speed ───────────────────────────────────────────────────────────────────

/// KDE's speed steps (kcm_animations' slider, slow → instant).
pub const SPEED_STEPS: &[f64] = &[4.0, 2.0, 1.5, 1.0, 0.75, 0.5, 0.0];

pub fn parse_speed(s: &str) -> f64 {
    s.trim().parse::<f64>().ok().filter(|v| v.is_finite() && *v >= 0.0).unwrap_or(1.0)
}

pub fn check_speed(v: &Value) -> Result<f64> {
    let f = v.as_f64().context("speed: a number (AnimationDurationFactor: 0 instant, 1 normal, 4 slow)")?;
    if !f.is_finite() || !(0.0..=20.0).contains(&f) {
        bail!("speed: {f} is out of range (0 to 20)");
    }
    Ok(f)
}

/// The number as KConfig writes a double (no trailing ".0" noise needed, but
/// KConfig reads "1" and "1.0" alike).
fn speed_text(f: f64) -> String {
    let s = format!("{f:.3}");
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}

// ── Effects: state and plans ────────────────────────────────────────────────

/// What `[Plugins] <id>Enabled` says, or the default when there's no key.
pub fn enabled(fx: &Fx, key: Option<&str>) -> bool {
    match key.map(str::trim) {
        Some("true") => true,
        Some("false") => false,
        _ => fx.default,
    }
}

/// The kwinrc entry for an effect turned on or off: Some(value) to write,
/// None to remove the key (the value is the default; KDE's KCMs do the same).
pub fn entry(fx: &Fx, on: bool) -> Option<&'static str> {
    if !fx.default_fn && on == fx.default {
        None
    } else if on {
        Some("true")
    } else {
        Some("false")
    }
}

/// A batch as effect changes, in order: choices first (the picked one on,
/// the rest of its group off), then switches. A switch for an effect in a
/// group turns the group's others off when it turns one on.
pub fn plan(batch: &Map<String, Value>) -> Result<Vec<(&'static Fx, bool)>> {
    let mut out: Vec<(&'static Fx, bool)> = Vec::new();
    let push = |f: &'static Fx, on: bool, out: &mut Vec<(&'static Fx, bool)>| {
        out.retain(|(g, _)| g.id != f.id);
        out.push((f, on));
    };
    if let Some(c) = batch.get("choices") {
        let c = c.as_object().context("choices: an object of group → effect id (or \"none\")")?;
        for (gid, pick) in c {
            let g = choice(gid).with_context(|| format!("choices: no group `{gid}`"))?;
            let pick = pick.as_str().with_context(|| format!("choices.{gid}: an effect id or \"none\""))?;
            if pick != "none" && !g.options.iter().any(|f| f.id == pick) {
                bail!("choices.{gid}: `{pick}` isn't one of {}", g.options.iter().map(|f| f.id).collect::<Vec<_>>().join(", "));
            }
            for f in g.options {
                push(f, f.id == pick, &mut out);
            }
        }
    }
    if let Some(e) = batch.get("effects") {
        let e = e.as_object().context("effects: an object of effect id → true/false")?;
        for (id, on) in e {
            if MANAGED.contains(&id.as_str()) {
                bail!("effects.{id}: Loft turns this one off while it runs (docs/KWIN.md §4.20)");
            }
            let f = find(id).with_context(|| format!("effects: no effect `{id}` on this page"))?;
            let on = on.as_bool().with_context(|| format!("effects.{id}: true or false"))?;
            if on && let Some(g) = group_of(id) {
                for o in g.options.iter().filter(|o| o.id != f.id) {
                    push(o, false, &mut out);
                }
            }
            push(f, on, &mut out);
        }
    }
    // Unloads before loads, so two of a group are never on at once.
    out.sort_by_key(|(_, on)| *on);
    Ok(out)
}

/// The page's state from what KWin has and the kwinrc keys.
/// `keys`: `<id>Enabled` → value, for the effects that have one.
pub fn report(speed: f64, available: &[String], keys: &HashMap<String, String>, loaded: &[String]) -> Value {
    let has = |id: &str| available.iter().any(|a| a == id);
    let fx_json = |f: &Fx| {
        let on = enabled(f, keys.get(f.id).map(String::as_str));
        json!({
            "id": f.id, "label": f.label, "on": on, "default": f.default,
            "loaded": loaded.iter().any(|l| l == f.id),
        })
    };
    let choices: Vec<Value> = CHOICES
        .iter()
        .filter_map(|c| {
            let opts: Vec<&Fx> = c.options.iter().filter(|f| has(f.id)).collect();
            if opts.is_empty() {
                return None;
            }
            let current = opts
                .iter()
                .find(|f| enabled(f, keys.get(f.id).map(String::as_str)))
                .map(|f| f.id)
                .unwrap_or("none");
            let default = opts.iter().find(|f| f.default).map(|f| f.id).unwrap_or("none");
            Some(json!({
                "id": c.id, "label": c.label, "hint": c.hint, "section": c.section,
                "options": opts.iter().map(|f| fx_json(f)).collect::<Vec<_>>(),
                "current": current, "default": default,
            }))
        })
        .collect();
    let toggles: Vec<Value> = TOGGLES
        .iter()
        .filter(|t| has(t.fx.id))
        .map(|t| {
            let mut v = fx_json(&t.fx);
            v["hint"] = json!(t.hint);
            v["section"] = json!(t.section);
            v
        })
        .collect();
    json!({ "ok": true, "speed": speed, "steps": SPEED_STEPS, "choices": choices, "toggles": toggles })
}

// ── Config and D-Bus ────────────────────────────────────────────────────────

fn read_key(file: &str, group: &str, key: &str) -> Option<String> {
    let o = Command::new("kreadconfig6").args(["--file", file, "--group", group, "--key", key]).output().ok()?;
    if !o.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
    (!s.is_empty()).then_some(s)
}

/// Write (Some) or remove (None) a key, with KConfig's change notification.
fn write_key(file: &str, group: &str, key: &str, value: Option<&str>) -> Result<()> {
    let mut cmd = Command::new("kwriteconfig6");
    cmd.args(["--notify", "--file", file, "--group", group, "--key", key]);
    match value {
        Some(v) => cmd.arg(v),
        None => cmd.arg("--delete"),
    };
    let st = cmd.status().context("running kwriteconfig6")?;
    if !st.success() {
        bail!("kwriteconfig6 --file {file} --group {group} --key {key} failed ({st})");
    }
    Ok(())
}

pub fn read_speed() -> f64 {
    read_key("kdeglobals", "KDE", "AnimationDurationFactor").map(|s| parse_speed(&s)).unwrap_or(1.0)
}

async fn effects_proxy(conn: &Connection) -> Result<zbus::Proxy<'static>> {
    kwin_proxy(conn, "/Effects", "org.kde.kwin.Effects")
        .await
        .context("KWin's /Effects (is this a KWin session?)")
}

pub async fn state(conn: &Connection) -> Result<Value> {
    let fx = effects_proxy(conn).await?;
    let all: Vec<String> = fx.get_property("listOfEffects").await.context("KWin's listOfEffects")?;
    let loaded: Vec<String> = fx.get_property("loadedEffects").await.unwrap_or_default();
    let known: Vec<String> = catalog().map(|f| f.id.to_string()).filter(|id| all.contains(id)).collect();
    let supported: Vec<bool> = fx.call("areEffectsSupported", &(known.clone(),)).await.unwrap_or_else(|_| vec![true; known.len()]);
    let available: Vec<String> =
        known.into_iter().zip(supported).filter_map(|(id, ok)| ok.then_some(id)).collect();
    let keys: HashMap<String, String> = available
        .iter()
        .filter_map(|id| read_key("kwinrc", "Plugins", &format!("{id}Enabled")).map(|v| (id.clone(), v)))
        .collect();
    Ok(report(read_speed(), &available, &keys, &loaded))
}

pub async fn apply(conn: &Connection, batch: &Map<String, Value>) -> Result<Value> {
    for k in batch.keys() {
        if !matches!(k.as_str(), "speed" | "choices" | "effects") {
            bail!("motion set: unknown key `{k}` (speed, choices, effects)");
        }
    }
    let speed = batch.get("speed").map(check_speed).transpose()?;
    let changes = plan(batch)?;
    if let Some(f) = speed {
        write_key("kdeglobals", "KDE", "AnimationDurationFactor", Some(&speed_text(f)))?;
        // What kcm_animations sends after saving: apps re-read their settings.
        let _ = conn
            .emit_signal(None::<&str>, "/KGlobalSettings", "org.kde.KGlobalSettings", "notifyChange", &(3i32, 0i32))
            .await;
    }
    if !changes.is_empty() {
        let fx = effects_proxy(conn).await?;
        let all: Vec<String> = fx.get_property("listOfEffects").await.unwrap_or_default();
        for (f, on) in &changes {
            write_key("kwinrc", "Plugins", &format!("{}Enabled", f.id), entry(f, *on))?;
            if !all.iter().any(|a| a == f.id) {
                continue;
            }
            let loaded: bool = fx.call("isEffectLoaded", &(f.id,)).await.unwrap_or(false);
            if *on && !loaded {
                let ok: bool = fx.call("loadEffect", &(f.id,)).await.with_context(|| format!("loading {}", f.id))?;
                if !ok {
                    bail!("KWin couldn't load the {} effect", f.label);
                }
            } else if !*on && loaded {
                let _: () = fx.call("unloadEffect", &(f.id,)).await.with_context(|| format!("unloading {}", f.id))?;
            }
        }
    }
    state(conn).await
}

pub async fn cli(args: &[String]) -> Result<()> {
    let result = async {
        let conn = Connection::session().await.context("the session bus")?;
        match args.first().map(String::as_str) {
            None | Some("list") => state(&conn).await,
            Some("set") => {
                let b = args.get(1).context("usage: loft-kwin motion set '{\"speed\": 0.5, \"effects\": {\"wobblywindows\": true}}'")?;
                let batch: Map<String, Value> = serde_json::from_str(b).context("motion set: bad JSON")?;
                apply(&conn, &batch).await
            }
            Some(other) => bail!("motion: unknown command `{other}` (list, set)"),
        }
    }
    .await;
    let v = result.unwrap_or_else(|e| json!({ "ok": false, "error": format!("{e:#}") }));
    println!("{v}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn batch(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    fn ids(p: &[(&Fx, bool)]) -> Vec<(&'static str, bool)> {
        p.iter().map(|(f, on)| (f.id, *on)).collect()
    }

    #[test]
    fn catalog_ids_are_unique_and_skip_managed() {
        let mut ids: Vec<&str> = catalog().map(|f| f.id).collect();
        let n = ids.len();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), n);
        for m in MANAGED {
            assert!(find(m).is_none());
        }
    }

    #[test]
    fn each_choice_has_at_most_one_default() {
        for c in CHOICES {
            assert!(c.options.iter().filter(|f| f.default).count() <= 1, "{}", c.id);
        }
    }

    #[test]
    fn choice_turns_the_group_off_then_on() {
        let p = plan(&batch(json!({"choices": {"open-close": "glide"}}))).unwrap();
        assert_eq!(ids(&p), vec![("scale", false), ("fade", false), ("glide", true)]);
        let p = plan(&batch(json!({"choices": {"minimize": "none"}}))).unwrap();
        assert_eq!(ids(&p), vec![("squash", false), ("magiclamp", false)]);
    }

    #[test]
    fn switch_in_a_group_is_exclusive() {
        let p = plan(&batch(json!({"effects": {"magiclamp": true, "wobblywindows": true}}))).unwrap();
        assert_eq!(ids(&p), vec![("squash", false), ("magiclamp", true), ("wobblywindows", true)]);
        let p = plan(&batch(json!({"effects": {"diminactive": false}}))).unwrap();
        assert_eq!(ids(&p), vec![("diminactive", false)]);
    }

    #[test]
    fn bad_batches_are_refused() {
        assert!(plan(&batch(json!({"effects": {"fadingpopups": true}}))).is_err());
        assert!(plan(&batch(json!({"effects": {"nope": true}}))).is_err());
        assert!(plan(&batch(json!({"effects": {"blur": "yes"}}))).is_err());
        assert!(plan(&batch(json!({"choices": {"minimize": "glide"}}))).is_err());
        assert!(plan(&batch(json!({"choices": {"nope": "none"}}))).is_err());
        assert!(check_speed(&json!(-1)).is_err());
        assert!(check_speed(&json!("fast")).is_err());
        assert_eq!(check_speed(&json!(0.5)).unwrap(), 0.5);
    }

    #[test]
    fn entries_follow_kde_defaults() {
        let scale = find("scale").unwrap();
        let glide = find("glide").unwrap();
        let blur = find("blur").unwrap();
        assert_eq!(entry(scale, true), None);
        assert_eq!(entry(scale, false), Some("false"));
        assert_eq!(entry(glide, true), Some("true"));
        assert_eq!(entry(glide, false), None);
        assert_eq!(entry(blur, true), Some("true"));
        assert!(enabled(scale, None));
        assert!(!enabled(scale, Some("false")));
        assert!(enabled(glide, Some("true")));
    }

    #[test]
    fn speed_text_and_parse() {
        assert_eq!(speed_text(1.0), "1");
        assert_eq!(speed_text(0.75), "0.75");
        assert_eq!(speed_text(0.0), "0");
        assert_eq!(parse_speed("1.5"), 1.5);
        assert_eq!(parse_speed("junk"), 1.0);
        assert_eq!(parse_speed("-2"), 1.0);
    }

    #[test]
    fn report_lists_what_kwin_has() {
        let available: Vec<String> = ["scale", "glide", "squash", "magiclamp", "wobblywindows", "blur"].map(String::from).to_vec();
        let keys = HashMap::from([("scale".to_string(), "false".to_string()), ("glide".to_string(), "true".to_string())]);
        let r = report(0.5, &available, &keys, &["glide".to_string()]);
        assert_eq!(r["speed"], json!(0.5));
        let choices = r["choices"].as_array().unwrap();
        // fade, maximize, … aren't available: their groups are hidden or trimmed.
        assert_eq!(choices.iter().map(|c| c["id"].as_str().unwrap()).collect::<Vec<_>>(), vec!["open-close", "minimize"]);
        assert_eq!(choices[0]["current"], json!("glide"));
        assert_eq!(choices[0]["default"], json!("scale"));
        assert_eq!(choices[0]["options"].as_array().unwrap().len(), 2);
        assert_eq!(choices[1]["current"], json!("squash"));
        let toggles = r["toggles"].as_array().unwrap();
        assert_eq!(toggles.len(), 2);
        assert_eq!(toggles[0]["id"], json!("wobblywindows"));
        assert_eq!(toggles[0]["on"], json!(false));
        assert_eq!(toggles[1]["on"], json!(true));
    }
}
