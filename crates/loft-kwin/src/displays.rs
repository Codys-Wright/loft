//! `loft-kwin displays`: Settings → Displays under KWin (docs/KWIN.md §4.8).
//!
//! Reads KScreen's view of the outputs (`kscreen-doctor -j` for modes and
//! geometry, `kscreen-doctor -o` for what the JSON leaves out: enabled, VRR,
//! HDR) and prints them in loft-niri's `outputs` shape, so the Displays page
//! renders the same records under either compositor. `displays set` turns the
//! page's staged changes into one atomic `kscreen-doctor output.…` call.
//! KScreen applies and persists the result itself; Loft records nothing.
//!
//! Identities ("Make Model Serial") aren't in KScreen's output: the shell
//! fills them in from the bridge's screens (crate::state::identity).

use std::collections::HashMap;
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Map, Value, json};

#[derive(Debug, Clone, Deserialize)]
pub struct KsSize {
    pub width: i64,
    pub height: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KsPoint {
    pub x: i64,
    pub y: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KsMode {
    pub id: String,
    #[serde(default)]
    pub refresh_rate: f64,
    pub size: KsSize,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KsOutput {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub connected: bool,
    /// Not in 6.8's `-j` (it is in the text output); kept in case a version has it.
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub modes: Vec<KsMode>,
    #[serde(default)]
    pub current_mode_id: String,
    #[serde(default)]
    pub preferred_modes: Vec<String>,
    pub pos: Option<KsPoint>,
    #[serde(default = "one")]
    pub scale: f64,
    /// KScreen::Output::Rotation: None 1, Left 2, Inverted 4, Right 8,
    /// Flipped 16, Flipped90 32, Flipped180 64, Flipped270 128.
    #[serde(default = "rotation_none")]
    pub rotation: u32,
    /// 1 = primary; 0 = none (disabled).
    #[serde(default)]
    pub priority: u32,
    #[serde(rename = "sizeMM")]
    pub size_mm: Option<KsSize>,
}

fn one() -> f64 {
    1.0
}

fn rotation_none() -> u32 {
    1
}

#[derive(Debug, Deserialize)]
struct KsConfig {
    #[serde(default)]
    outputs: Vec<KsOutput>,
}

pub fn parse_json(text: &str) -> Result<Vec<KsOutput>> {
    let c: KsConfig = serde_json::from_str(text).context("kscreen-doctor -j: bad JSON")?;
    Ok(c.outputs)
}

/// What `kscreen-doctor -o` says that `-j` doesn't.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TextInfo {
    /// "enabled" / "disabled"; None when the output can't be disabled
    /// ("disable unsupported", e.g. KWin's nested outputs: always on).
    pub enabled: Option<bool>,
    pub can_disable: bool,
    /// VRR policy, lowercase ("never", "automatic", "always"); None = incapable.
    pub vrr: Option<String>,
    /// HDR on/off; None = incapable.
    pub hdr: Option<bool>,
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// `kscreen-doctor -o`, by connector. Each output is an `Output: ID NAME UUID`
/// line, then one fact per line (some versions put the first ones on the
/// header line: "Output: 1 eDP-1 enabled connected …").
pub fn parse_text(text: &str) -> HashMap<String, TextInfo> {
    let mut out = HashMap::new();
    let mut cur: Option<(String, TextInfo)> = None;
    let fact = |info: &mut TextInfo, line: &str| {
        let l = line.trim();
        match l {
            "enabled" => {
                info.enabled = Some(true);
                info.can_disable = true;
            }
            "disabled" => {
                info.enabled = Some(false);
                info.can_disable = true;
            }
            "disable unsupported" => info.can_disable = false,
            _ => {
                if let Some(v) = l.strip_prefix("Vrr:") {
                    let v = v.trim().to_ascii_lowercase();
                    info.vrr = (v != "incapable" && !v.is_empty()).then_some(v);
                } else if let Some(v) = l.strip_prefix("HDR:") {
                    info.hdr = match v.trim().to_ascii_lowercase().as_str() {
                        "enabled" => Some(true),
                        "disabled" => Some(false),
                        _ => None,
                    };
                }
            }
        }
    };
    for raw in strip_ansi(text).lines() {
        if let Some(rest) = raw.trim_start().strip_prefix("Output:") {
            if let Some((name, info)) = cur.take() {
                out.insert(name, info);
            }
            let mut words = rest.split_whitespace();
            let _id = words.next();
            let Some(name) = words.next() else { continue };
            let mut info = TextInfo::default();
            // The rest of a one-line header: "enabled connected priority 1 …".
            for w in words {
                fact(&mut info, w);
            }
            cur = Some((name.to_string(), info));
        } else if let Some((_, info)) = cur.as_mut() {
            fact(info, raw);
        }
    }
    if let Some((name, info)) = cur.take() {
        out.insert(name, info);
    }
    out
}

/// KScreen rotation → niri's transform names (what the page speaks).
/// KScreen's Left is a 90° counter-clockwise turn, wl_output's 90.
pub fn transform_name(rotation: u32) -> &'static str {
    match rotation {
        2 => "90",
        4 => "180",
        8 => "270",
        16 => "flipped",
        32 => "flipped-90",
        64 => "flipped-180",
        128 => "flipped-270",
        _ => "normal",
    }
}

/// niri transform name → kscreen-doctor's `rotation.<value>`.
pub fn rotation_arg(transform: &str) -> Result<&'static str> {
    Ok(match transform.to_ascii_lowercase().as_str() {
        "normal" | "0" | "none" => "none",
        "90" => "left",
        "180" => "inverted",
        "270" => "right",
        "flipped" => "flipped",
        "flipped-90" => "flipped90",
        "flipped-180" => "flipped180",
        "flipped-270" => "flipped270",
        _ => bail!("unknown transform `{transform}`"),
    })
}

fn mode_string(m: &KsMode) -> String {
    format!("{}x{}@{:.3}", m.size.width, m.size.height, m.refresh_rate)
}

fn is_rotated(rotation: u32) -> bool {
    matches!(rotation, 2 | 8 | 32 | 128)
}

/// Whether an output is on: the text output's word, else the JSON's, else
/// whether it has a current mode (an output that can't be disabled is on).
fn enabled(o: &KsOutput, t: Option<&TextInfo>) -> bool {
    t.and_then(|t| t.enabled)
        .or(o.enabled)
        .unwrap_or_else(|| o.connected && o.modes.iter().any(|m| m.id == o.current_mode_id))
}

/// One output as loft-niri's `outputs` record (crates/loft-niri/src/outputs.rs
/// `info`), plus KScreen's extras: `primary`, `can_disable`, `vrr_policy`,
/// `hdr_supported`, `hdr_enabled`, `kscreen_id`.
pub fn info(o: &KsOutput, t: Option<&TextInfo>) -> Value {
    let on = enabled(o, t);
    let current = o.modes.iter().position(|m| m.id == o.current_mode_id);
    let modes: Vec<Value> = o
        .modes
        .iter()
        .map(|m| {
            json!({
                "id": m.id,
                "width": m.size.width,
                "height": m.size.height,
                "refresh": m.refresh_rate,
                "refresh_mhz": (m.refresh_rate * 1000.0).round() as i64,
                "preferred": o.preferred_modes.contains(&m.id),
                "current": m.id == o.current_mode_id,
                "mode": mode_string(m),
            })
        })
        .collect();
    let mode = current.map(|i| &o.modes[i]);
    let logical = match (on, mode, &o.pos) {
        (true, Some(m), Some(p)) => {
            let (w, h) = if is_rotated(o.rotation) {
                (m.size.height, m.size.width)
            } else {
                (m.size.width, m.size.height)
            };
            let s = if o.scale > 0.0 { o.scale } else { 1.0 };
            json!({ "x": p.x, "y": p.y,
                    "width": (w as f64 / s).round() as i64,
                    "height": (h as f64 / s).round() as i64 })
        }
        _ => Value::Null,
    };
    let physical = o
        .size_mm
        .as_ref()
        .filter(|s| s.width > 0 && s.height > 0)
        .map(|s| json!([s.width, s.height]));
    let vrr = t.and_then(|t| t.vrr.clone());
    let hdr = t.and_then(|t| t.hdr);
    json!({
        "name": o.name,
        "make": "",
        "model": "",
        "serial": Value::Null,
        // The shell swaps in the bridge's "Make Model Serial".
        "identity": o.name,
        "description": o.name,
        "physical_size": physical,
        "modes": modes,
        "current_mode": current,
        "mode": mode.map(mode_string),
        "is_custom_mode": false,
        "enabled": on,
        "scale": on.then_some(o.scale),
        "transform": transform_name(o.rotation),
        "logical": logical,
        "vrr_supported": vrr.is_some(),
        "vrr_enabled": vrr.as_deref().is_some_and(|v| v != "never"),
        "vrr_policy": vrr,
        "hdr_supported": hdr.is_some(),
        "hdr_enabled": hdr.unwrap_or(false),
        "primary": o.priority == 1,
        "can_disable": t.map(|t| t.can_disable).unwrap_or(true),
        "kscreen_id": o.id,
        "override": Value::Null,
    })
}

/// Every output, left to right then top to bottom, disabled ones last
/// (loft-niri's order).
pub fn list(outputs: &[KsOutput], text: &HashMap<String, TextInfo>) -> Value {
    let mut v: Vec<Value> = outputs.iter().map(|o| info(o, text.get(&o.name))).collect();
    v.sort_by_key(|r| match r["logical"].as_object() {
        Some(l) => (
            0,
            l["x"].as_i64().unwrap_or(0),
            l["y"].as_i64().unwrap_or(0),
            r["name"].as_str().unwrap_or("").to_string(),
        ),
        None => (1, 0, 0, r["name"].as_str().unwrap_or("").to_string()),
    });
    Value::Array(v)
}

fn parse_mode(s: &str) -> Result<(i64, i64, Option<f64>)> {
    let (size, refresh) = match s.split_once('@') {
        Some((a, b)) => (a, Some(b.trim_end_matches("Hz").parse::<f64>()?)),
        None => (s, None),
    };
    let (w, h) = size
        .split_once('x')
        .with_context(|| format!("mode `{s}`: expected WxH[@R]"))?;
    Ok((w.trim().parse()?, h.trim().parse()?, refresh))
}

/// The KScreen mode id for `WxH[@R]`: that size, the nearest refresh rate
/// (the highest when none is given).
fn mode_id(o: &KsOutput, mode: &str) -> Result<String> {
    let (w, h, refresh) = parse_mode(mode)?;
    let mut cands: Vec<&KsMode> = o
        .modes
        .iter()
        .filter(|m| m.size.width == w && m.size.height == h)
        .collect();
    match refresh {
        Some(r) => cands.sort_by(|a, b| {
            (a.refresh_rate - r)
                .abs()
                .total_cmp(&(b.refresh_rate - r).abs())
        }),
        None => cands.sort_by(|a, b| b.refresh_rate.total_cmp(&a.refresh_rate)),
    }
    cands
        .first()
        .map(|m| m.id.clone())
        .with_context(|| format!("{}: no mode {mode}", o.name))
}

fn scale_arg(s: f64) -> String {
    // 1.25 → "1.25", 2.0 → "2".
    let t = format!("{s:.4}");
    t.trim_end_matches('0').trim_end_matches('.').to_string()
}

/// The page's changes, by connector (`{ "DP-1": { mode, scale, transform,
/// position: {x, y}, off, vrr, hdr, primary } }`), as kscreen-doctor's
/// arguments. Unknown connectors and fields are errors, not skipped.
pub fn apply_args(outputs: &[KsOutput], changes: &Map<String, Value>) -> Result<Vec<String>> {
    let mut args = Vec::new();
    let mut names: Vec<&String> = changes.keys().collect();
    names.sort();
    for name in names {
        let change = changes[name]
            .as_object()
            .with_context(|| format!("{name}: change must be an object"))?;
        let o = outputs
            .iter()
            .find(|o| o.name == *name)
            .with_context(|| format!("no output {name}"))?;
        let arg = |k: &str, v: &str| format!("output.{}.{k}.{v}", o.name);
        // Turning one on comes first, so its other settings apply to it.
        if let Some(off) = change.get("off") {
            let off = off
                .as_bool()
                .with_context(|| format!("{name}: off must be a boolean"))?;
            args.push(format!(
                "output.{}.{}",
                o.name,
                if off { "disable" } else { "enable" }
            ));
            if off {
                continue;
            }
        }
        let mut keys: Vec<&String> = change.keys().collect();
        keys.sort();
        for k in keys {
            let v = &change[k];
            match k.as_str() {
                "off" => {}
                "mode" => {
                    let m = v
                        .as_str()
                        .with_context(|| format!("{name}: mode must be a string"))?;
                    args.push(arg("mode", &mode_id(o, m)?));
                }
                "scale" => {
                    let s = v
                        .as_f64()
                        .filter(|s| *s > 0.0)
                        .with_context(|| format!("{name}: bad scale"))?;
                    args.push(arg("scale", &scale_arg(s)));
                }
                "transform" => {
                    let t = v
                        .as_str()
                        .with_context(|| format!("{name}: transform must be a string"))?;
                    args.push(arg("rotation", rotation_arg(t)?));
                }
                "position" => {
                    let x = v["x"]
                        .as_f64()
                        .with_context(|| format!("{name}: position.x"))?
                        .round() as i64;
                    let y = v["y"]
                        .as_f64()
                        .with_context(|| format!("{name}: position.y"))?
                        .round() as i64;
                    args.push(arg("position", &format!("{x},{y}")));
                }
                "vrr" => {
                    // On = KScreen's "automatic" (Plasma's default: adaptive
                    // sync for fullscreen apps), or a policy by name.
                    let p = match v {
                        Value::Bool(true) => "automatic".to_string(),
                        Value::Bool(false) => "never".to_string(),
                        Value::String(s)
                            if ["never", "automatic", "always"].contains(&s.as_str()) =>
                        {
                            s.clone()
                        }
                        _ => bail!("{name}: vrr must be a boolean or never/automatic/always"),
                    };
                    args.push(arg("vrrpolicy", &p));
                }
                "hdr" => {
                    let on = v
                        .as_bool()
                        .with_context(|| format!("{name}: hdr must be a boolean"))?;
                    args.push(arg("hdr", if on { "enable" } else { "disable" }));
                }
                "primary" => {
                    if v.as_bool() == Some(true) {
                        args.push(format!("output.{}.primary", o.name));
                    }
                }
                _ => bail!("{name}: KScreen can't set `{k}`"),
            }
        }
    }
    Ok(args)
}

fn doctor() -> String {
    std::env::var("LOFT_KSCREEN_DOCTOR").unwrap_or_else(|_| "kscreen-doctor".into())
}

fn run_doctor(args: &[String]) -> Result<String> {
    let out = Command::new(doctor())
        .args(args)
        .output()
        .with_context(|| format!("can't run {}", doctor()))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        bail!(
            "kscreen-doctor {}: {}",
            args.join(" "),
            strip_ansi(err.trim())
        );
    }
    Ok(stdout)
}

fn read() -> Result<Vec<KsOutput>> {
    parse_json(&run_doctor(&["-j".into()])?)
}

fn current() -> Result<Value> {
    let outs = read()?;
    // The text output is only for extras; without it the records still render.
    let text = run_doctor(&["-o".into()])
        .map(|t| parse_text(&t))
        .unwrap_or_default();
    Ok(list(&outs, &text))
}

/// `loft-kwin displays [set JSON]`. Prints one JSON object; exits 0 either way
/// so the shell reads `ok` / `error` (as with loft-niri).
pub fn run(args: &[String]) -> Result<()> {
    let result = match args.first().map(String::as_str) {
        None | Some("list") => current().map(|outputs| json!({ "ok": true, "outputs": outputs })),
        Some("set") => {
            let batch = args
                .get(1)
                .context("usage: loft-kwin displays set '{\"DP-1\": {\"scale\": 1.5}}'");
            batch.and_then(|b| {
                let changes: Map<String, Value> =
                    serde_json::from_str(b).context("displays set: bad JSON")?;
                let outs = read()?;
                let argv = apply_args(&outs, &changes)?;
                if !argv.is_empty() {
                    run_doctor(&argv)?;
                }
                Ok(json!({ "ok": true, "args": argv }))
            })
        }
        Some(other) => Err(anyhow::anyhow!(
            "displays: unknown command `{other}` (list, set)"
        )),
    };
    let v = result.unwrap_or_else(|e| json!({ "ok": false, "error": format!("{e:#}") }));
    println!("{v}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // What kscreen-doctor 6.8.2 printed in a nested KWin 6.8.2 session with
    // --output-count 2 (cut to the fields we read), plus a real monitor's
    // shape: several modes, a preferred one, a physical size, rotated, 1.25.
    const JSON: &str = r#"{"outputs":[
      {"clones":[],"connected":true,"currentModeId":"1","followPreferredMode":false,"icon":"","id":1,
       "modes":[{"id":"1","name":"1280x800@60","refreshRate":60,"size":{"height":800,"width":1280}}],
       "name":"WL-1","pos":{"x":1280,"y":0},"preferredModes":[],"priority":1,"replicationSource":0,
       "rotation":1,"scale":1,"size":{"height":800,"width":1280},"sizeMM":{"height":-1,"width":-1},"type":0},
      {"connected":true,"currentModeId":"7","id":2,
       "modes":[{"id":"6","refreshRate":143.912,"size":{"height":1440,"width":2560}},
                {"id":"7","refreshRate":59.951,"size":{"height":1440,"width":2560}},
                {"id":"8","refreshRate":60,"size":{"height":1080,"width":1920}}],
       "name":"DP-2","pos":{"x":0,"y":0},"preferredModes":["6"],"priority":2,
       "rotation":2,"scale":1.25,"sizeMM":{"height":340,"width":600}},
      {"connected":true,"currentModeId":"","id":3,
       "modes":[{"id":"9","refreshRate":60,"size":{"height":1080,"width":1920}}],
       "name":"HDMI-A-1","priority":0,"rotation":1,"scale":1}
    ]}"#;

    const TEXT: &str = "\x1b[01;32mOutput: \x1b[0;0m1 WL-1 74866354\n\
        \tdisable unsupported\n\tconnected\n\tpriority 1\n\tUnknown\n\
        \tModes:  1:1280x800@60.00*! \n\tVrr: incapable\n\tHDR: incapable\n\
        Output: 2 DP-2 abcd\n\tenabled\n\tconnected\n\tpriority 2\n\tDisplayPort\n\
        \tVrr: Automatic\n\tHDR: \x1b[01;33mdisabled\x1b[0m\n\t\tHDR color profile source: EDID\n\
        Output: 3 HDMI-A-1 efgh\n\tdisabled\n\tconnected\n\tVrr: Never\n\tHDR: incapable\n";

    fn outs() -> Vec<KsOutput> {
        parse_json(JSON).unwrap()
    }

    #[test]
    fn text_facts() {
        let t = parse_text(TEXT);
        assert_eq!(
            t["WL-1"],
            TextInfo {
                enabled: None,
                can_disable: false,
                vrr: None,
                hdr: None
            }
        );
        assert_eq!(
            t["DP-2"],
            TextInfo {
                enabled: Some(true),
                can_disable: true,
                vrr: Some("automatic".into()),
                hdr: Some(false)
            }
        );
        assert_eq!(t["HDMI-A-1"].enabled, Some(false));
        assert_eq!(t["HDMI-A-1"].vrr.as_deref(), Some("never"));
        // The one-line header of older versions.
        let one = parse_text("Output: 70 HDMI-2 enabled connected HDMI Modes: 1:800x600@60");
        assert_eq!(one["HDMI-2"].enabled, Some(true));
    }

    #[test]
    fn records_have_loft_niri_shape() {
        let l = list(&outs(), &parse_text(TEXT));
        let names: Vec<&str> = l
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["name"].as_str().unwrap())
            .collect();
        // Left to right, the disabled one last.
        assert_eq!(names, ["DP-2", "WL-1", "HDMI-A-1"]);

        let wl = &l[1];
        assert_eq!(wl["enabled"], true);
        assert_eq!(wl["can_disable"], false);
        assert_eq!(wl["primary"], true);
        assert_eq!(wl["mode"], "1280x800@60.000");
        assert_eq!(
            wl["logical"],
            json!({ "x": 1280, "y": 0, "width": 1280, "height": 800 })
        );
        assert_eq!(wl["physical_size"], Value::Null);
        assert_eq!(wl["vrr_supported"], false);

        let dp = &l[0];
        assert_eq!(dp["transform"], "90");
        assert_eq!(dp["scale"], 1.25);
        // Rotated: 1440×2560 device px, /1.25.
        assert_eq!(
            dp["logical"],
            json!({ "x": 0, "y": 0, "width": 1152, "height": 2048 })
        );
        assert_eq!(dp["mode"], "2560x1440@59.951");
        assert_eq!(dp["current_mode"], 1);
        assert_eq!(dp["modes"][0]["preferred"], true);
        assert_eq!(dp["modes"][0]["refresh_mhz"], 143912);
        assert_eq!(dp["vrr_supported"], true);
        assert_eq!(dp["vrr_enabled"], true);
        assert_eq!(dp["hdr_supported"], true);
        assert_eq!(dp["hdr_enabled"], false);
        assert_eq!(dp["physical_size"], json!([600, 340]));

        let hdmi = &l[2];
        assert_eq!(hdmi["enabled"], false);
        assert_eq!(hdmi["logical"], Value::Null);
        assert_eq!(hdmi["scale"], Value::Null);
        assert_eq!(hdmi["vrr_enabled"], false);
    }

    #[test]
    fn enabled_without_text() {
        // No `-o`: an output with a current mode is on, one without is off.
        let l = list(&outs(), &HashMap::new());
        assert_eq!(l[0]["enabled"], true);
        assert_eq!(l[2]["enabled"], false);
    }

    #[test]
    fn changes_to_args() {
        let changes: Map<String, Value> = serde_json::from_value(json!({
            "DP-2": { "mode": "2560x1440@143.9", "scale": 1.5, "transform": "normal",
                      "position": { "x": 1280.4, "y": -20 }, "vrr": false },
            "WL-1": { "primary": true, "hdr": true }
        }))
        .unwrap();
        assert_eq!(
            apply_args(&outs(), &changes).unwrap(),
            [
                "output.DP-2.mode.6",
                "output.DP-2.position.1280,-20",
                "output.DP-2.scale.1.5",
                "output.DP-2.rotation.none",
                "output.DP-2.vrrpolicy.never",
                "output.WL-1.hdr.enable",
                "output.WL-1.primary",
            ]
        );
    }

    #[test]
    fn enable_first_disable_alone() {
        let changes: Map<String, Value> = serde_json::from_value(json!({
            "HDMI-A-1": { "scale": 2, "off": false, "transform": "270" },
            "DP-2": { "off": true, "scale": 2 }
        }))
        .unwrap();
        assert_eq!(
            apply_args(&outs(), &changes).unwrap(),
            [
                "output.DP-2.disable",
                "output.HDMI-A-1.enable",
                "output.HDMI-A-1.scale.2",
                "output.HDMI-A-1.rotation.right"
            ]
        );
    }

    #[test]
    fn mode_without_refresh_takes_the_highest() {
        assert_eq!(mode_id(&outs()[1], "2560x1440").unwrap(), "6");
        assert_eq!(mode_id(&outs()[1], "2560x1440@60").unwrap(), "7");
        assert!(mode_id(&outs()[1], "800x600").is_err());
    }

    #[test]
    fn bad_changes_are_errors() {
        let bad = |v: Value| apply_args(&outs(), &serde_json::from_value(v).unwrap()).is_err();
        assert!(bad(json!({ "DP-9": { "scale": 1 } })));
        assert!(bad(json!({ "DP-2": { "scale": 0 } })));
        assert!(bad(json!({ "DP-2": { "transform": "sideways" } })));
        assert!(bad(json!({ "DP-2": { "bitdepth": 10 } })));
    }

    #[test]
    fn rotations_round_trip() {
        for (rot, name) in [
            (1, "normal"),
            (2, "90"),
            (4, "180"),
            (8, "270"),
            (16, "flipped"),
            (32, "flipped-90"),
            (64, "flipped-180"),
            (128, "flipped-270"),
        ] {
            assert_eq!(transform_name(rot), name);
            assert!(rotation_arg(name).is_ok());
        }
        assert_eq!(scale_arg(1.25), "1.25");
        assert_eq!(scale_arg(2.0), "2");
        assert_eq!(scale_arg(1.0 + 1e-9), "1");
    }
}
