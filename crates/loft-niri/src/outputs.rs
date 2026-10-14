//! Outputs: niri-ipc's `Output` → the shell's JSON, stable identities, and
//! the changes `output set` applies live and records.

use std::collections::HashMap;

use anyhow::{Context, Result, bail};
use niri_ipc::{
    ConfiguredMode, ConfiguredPosition, ModeToSet, OutputAction, PositionToSet, ScaleToSet,
    Transform, VrrToSet,
};
use serde_json::{Map, Value, json};

pub type Outputs = HashMap<String, niri_ipc::Output>;

fn known(s: &str) -> Option<&str> {
    (s != "Unknown" && !s.is_empty()).then_some(s)
}

/// niri's stable name for an output: "Make Model Serial" (Unknown for
/// missing parts), or the connector when nothing is known (e.g. winit).
pub fn identity(o: &niri_ipc::Output) -> String {
    let make = known(&o.make);
    let model = known(&o.model);
    let serial = o.serial.as_deref().and_then(known);
    if make.is_none() && model.is_none() && serial.is_none() {
        return o.name.clone();
    }
    format!(
        "{} {} {}",
        make.unwrap_or("Unknown"),
        model.unwrap_or("Unknown"),
        serial.unwrap_or("Unknown")
    )
}

/// niri's `OutputName::matches`: by connector, or by "make model serial"
/// (case-insensitive).
pub fn matches(o: &niri_ipc::Output, target: &str) -> bool {
    if target.eq_ignore_ascii_case(&o.name) {
        return true;
    }
    let make = known(&o.make);
    let model = known(&o.model);
    let serial = o.serial.as_deref().and_then(known);
    if make.is_none() && model.is_none() && serial.is_none() {
        return false;
    }
    target.eq_ignore_ascii_case(&format!(
        "{} {} {}",
        make.unwrap_or("Unknown"),
        model.unwrap_or("Unknown"),
        serial.unwrap_or("Unknown")
    ))
}

pub fn find<'a>(outputs: &'a Outputs, target: &str) -> Option<&'a niri_ipc::Output> {
    let mut v: Vec<_> = outputs.values().collect();
    v.sort_by(|a, b| a.name.cmp(&b.name));
    v.into_iter().find(|o| matches(o, target))
}

pub fn transform_name(t: Transform) -> &'static str {
    match t {
        Transform::Normal => "normal",
        Transform::_90 => "90",
        Transform::_180 => "180",
        Transform::_270 => "270",
        Transform::Flipped => "flipped",
        Transform::Flipped90 => "flipped-90",
        Transform::Flipped180 => "flipped-180",
        Transform::Flipped270 => "flipped-270",
    }
}

pub fn parse_transform(s: &str) -> Result<Transform> {
    Ok(match s.to_ascii_lowercase().as_str() {
        "normal" | "0" => Transform::Normal,
        "90" => Transform::_90,
        "180" => Transform::_180,
        "270" => Transform::_270,
        "flipped" => Transform::Flipped,
        "flipped-90" => Transform::Flipped90,
        "flipped-180" => Transform::Flipped180,
        "flipped-270" => Transform::Flipped270,
        _ => bail!("unknown transform `{s}` (normal, 90, 180, 270, flipped, flipped-90/180/270)"),
    })
}

/// `2560x1440@143.912` — niri's mode syntax, refresh with millihertz precision.
pub fn mode_string(m: &niri_ipc::Mode) -> String {
    format!(
        "{}x{}@{:.3}",
        m.width,
        m.height,
        m.refresh_rate as f64 / 1000.0
    )
}

pub fn parse_mode(s: &str) -> Result<ConfiguredMode> {
    let (size, refresh) = match s.split_once('@') {
        Some((a, b)) => (a, Some(b.trim_end_matches("Hz").parse::<f64>()?)),
        None => (s, None),
    };
    let (w, h) = size
        .split_once('x')
        .with_context(|| format!("mode `{s}`: expected WxH[@R]"))?;
    Ok(ConfiguredMode {
        width: w.trim().parse()?,
        height: h.trim().parse()?,
        refresh,
    })
}

pub fn info(o: &niri_ipc::Output, override_: Option<&Value>) -> Value {
    let modes: Vec<Value> = o
        .modes
        .iter()
        .enumerate()
        .map(|(i, m)| {
            json!({
                "width": m.width,
                "height": m.height,
                "refresh": m.refresh_rate as f64 / 1000.0,
                "refresh_mhz": m.refresh_rate,
                "preferred": m.is_preferred,
                "current": o.current_mode == Some(i),
                "mode": mode_string(m),
            })
        })
        .collect();
    let current = o.current_mode.and_then(|i| o.modes.get(i));
    json!({
        "name": o.name,
        "make": o.make,
        "model": o.model,
        "serial": o.serial,
        "identity": identity(o),
        "description": format!("{} {}", known(&o.make).unwrap_or(""), known(&o.model).unwrap_or(&o.name)).trim(),
        "physical_size": o.physical_size.map(|(w, h)| json!([w, h])),
        "modes": modes,
        "current_mode": o.current_mode,
        "mode": current.map(mode_string),
        "is_custom_mode": o.is_custom_mode,
        "enabled": o.logical.is_some(),
        "scale": o.logical.map(|l| l.scale),
        "transform": o.logical.map(|l| transform_name(l.transform)).unwrap_or("normal"),
        "logical": o.logical.map(|l| json!({ "x": l.x, "y": l.y, "width": l.width, "height": l.height })),
        "vrr_supported": o.vrr_supported,
        "vrr_enabled": o.vrr_enabled,
        "override": override_.cloned(),
    })
}

/// All outputs, ordered left-to-right then top-to-bottom (disabled last),
/// with each one's recorded override.
pub fn list(outputs: &Outputs, overrides: Option<&Map<String, Value>>) -> Value {
    let mut v: Vec<&niri_ipc::Output> = outputs.values().collect();
    v.sort_by_key(|o| match o.logical {
        Some(l) => (0, l.x, l.y, o.name.clone()),
        None => (1, 0, 0, o.name.clone()),
    });
    Value::Array(
        v.into_iter()
            .map(|o| {
                let id = identity(o);
                let ov = overrides.and_then(|m| {
                    m.iter()
                        .find(|(k, _)| matches(o, k) || k.eq_ignore_ascii_case(&id))
                        .map(|(_, v)| v)
                });
                info(o, ov)
            })
            .collect(),
    )
}

/// One `output set`: every field optional; `auto` clears the setting back
/// to niri's automatic choice.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct OutputChange {
    pub mode: Option<String>,
    pub scale: Option<String>,
    pub position: Option<String>,
    pub transform: Option<String>,
    pub vrr: Option<String>,
    /// Some(true) = off, Some(false) = on.
    pub off: Option<bool>,
}

impl OutputChange {
    pub fn from_json(v: &Value) -> Result<Self> {
        let s = |k: &str| -> Option<String> {
            v.get(k).filter(|x| !x.is_null()).map(|x| match x {
                Value::String(s) => s.clone(),
                Value::Object(o) => format!(
                    "{},{}",
                    o.get("x").and_then(Value::as_i64).unwrap_or(0),
                    o.get("y").and_then(Value::as_i64).unwrap_or(0)
                ),
                Value::Bool(b) => if *b { "on" } else { "off" }.to_string(),
                other => other.to_string(),
            })
        };
        Ok(OutputChange {
            mode: s("mode"),
            scale: s("scale"),
            position: s("position"),
            transform: s("transform"),
            vrr: s("vrr"),
            off: v.get("off").and_then(Value::as_bool),
        })
    }

    /// The IPC actions that apply this change live (On before anything else).
    pub fn actions(&self) -> Result<Vec<OutputAction>> {
        let mut out = Vec::new();
        match self.off {
            Some(true) => return Ok(vec![OutputAction::Off]),
            Some(false) => out.push(OutputAction::On),
            None => {}
        }
        if let Some(m) = &self.mode {
            let mode = if m == "auto" {
                ModeToSet::Automatic
            } else {
                ModeToSet::Specific(parse_mode(m)?)
            };
            out.push(OutputAction::Mode { mode });
        }
        if let Some(s) = &self.scale {
            let scale = if s == "auto" {
                ScaleToSet::Automatic
            } else {
                ScaleToSet::Specific(parse_scale(s)?)
            };
            out.push(OutputAction::Scale { scale });
        }
        if let Some(t) = &self.transform {
            out.push(OutputAction::Transform {
                transform: parse_transform(t)?,
            });
        }
        if let Some(p) = &self.position {
            let position = if p == "auto" {
                PositionToSet::Automatic
            } else {
                let (x, y) = parse_position(p)?;
                PositionToSet::Specific(ConfiguredPosition { x, y })
            };
            out.push(OutputAction::Position { position });
        }
        if let Some(v) = &self.vrr {
            let (vrr, on_demand) = parse_vrr(v)?;
            out.push(OutputAction::Vrr {
                vrr: VrrToSet { vrr, on_demand },
            });
        }
        Ok(out)
    }

    /// Fold this change into an output's override record.
    pub fn record(&self, rec: &mut Map<String, Value>) -> Result<()> {
        let mut put = |k: &str, v: Value| {
            rec.insert(k.to_string(), v);
        };
        if let Some(m) = &self.mode {
            if m != "auto" {
                parse_mode(m)?;
            }
            put("mode", json!(m));
        }
        if let Some(s) = &self.scale {
            put(
                "scale",
                if s == "auto" {
                    json!("auto")
                } else {
                    json!(parse_scale(s)?)
                },
            );
        }
        if let Some(t) = &self.transform {
            put("transform", json!(transform_name(parse_transform(t)?)));
        }
        if let Some(p) = &self.position {
            put(
                "position",
                if p == "auto" {
                    json!("auto")
                } else {
                    let (x, y) = parse_position(p)?;
                    json!({ "x": x, "y": y })
                },
            );
        }
        if let Some(v) = &self.vrr {
            put(
                "vrr",
                match parse_vrr(v)? {
                    (true, true) => json!("on-demand"),
                    (b, _) => json!(b),
                },
            );
        }
        if let Some(off) = self.off {
            put("off", json!(off));
        }
        Ok(())
    }
}

pub fn parse_scale(s: &str) -> Result<f64> {
    let v: f64 = s.trim().parse()?;
    if !(0.25..=10.0).contains(&v) {
        bail!("scale must be in 0.25..=10");
    }
    Ok(v)
}

pub fn parse_position(s: &str) -> Result<(i32, i32)> {
    let (x, y) = s
        .split_once([',', 'x', ' '])
        .with_context(|| format!("position `{s}`: expected X,Y"))?;
    Ok((x.trim().parse()?, y.trim().parse()?))
}

pub fn parse_vrr(s: &str) -> Result<(bool, bool)> {
    Ok(match s.to_ascii_lowercase().as_str() {
        "on" | "true" | "1" => (true, false),
        "off" | "false" | "0" => (false, false),
        "on-demand" => (true, true),
        _ => bail!("vrr: expected on, off or on-demand"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn fixture() -> Outputs {
        serde_json::from_str(include_str!("../tests/fixtures/outputs-three.json")).unwrap()
    }

    #[test]
    fn identities_and_matching() {
        let outs = fixture();
        let uw = &outs["DP-1"];
        assert_eq!(
            identity(uw),
            "Samsung Electric Company Odyssey G95NC H1AK500000"
        );
        assert!(matches(uw, "dp-1"));
        assert!(matches(
            uw,
            "samsung electric company odyssey g95nc h1ak500000"
        ));
        assert!(!matches(uw, "Samsung Electric Company Odyssey G95NC"));
        // No serial → "Unknown" stands in.
        assert_eq!(
            identity(&outs["HDMI-A-1"]),
            "LG Electronics LG ULTRAGEAR Unknown"
        );
        assert_eq!(
            find(&outs, "LG Electronics LG ULTRAGEAR Unknown")
                .unwrap()
                .name,
            "HDMI-A-1"
        );
    }

    #[test]
    fn output_json_shape() {
        let outs = fixture();
        let l = list(&outs, None);
        let names: Vec<_> = l
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["name"].as_str().unwrap())
            .collect();
        // Left to right: portrait at x=-1440, ultrawide at 0, 1440p at 5120.
        assert_eq!(names, vec!["DP-2", "DP-1", "HDMI-A-1"]);
        let uw = &l[1];
        assert_eq!(uw["mode"], "5120x1440@239.761");
        assert_eq!(uw["scale"], 1.0);
        assert_eq!(uw["logical"]["width"], 5120);
        assert_eq!(uw["vrr_supported"], true);
        assert_eq!(uw["modes"].as_array().unwrap().len(), 3);
        assert_eq!(uw["modes"][0]["current"], true);
        let portrait = &l[0];
        assert_eq!(portrait["transform"], "90");
        assert_eq!(portrait["logical"]["height"], 2560);
    }

    #[test]
    fn disabled_output_without_edid() {
        let outs: Outputs =
            serde_json::from_str(include_str!("../tests/fixtures/outputs-disabled.json")).unwrap();
        // Nothing known about it: the connector is its only name.
        assert_eq!(identity(&outs["eDP-1"]), "eDP-1");
        assert!(!matches(&outs["eDP-1"], "Unknown Unknown Unknown"));
        let o = &list(&outs, None)[0];
        assert_eq!(o["enabled"], false);
        assert_eq!(o["mode"], Value::Null);
        assert_eq!(o["logical"], Value::Null);
        assert_eq!(o["modes"][0]["mode"], "2880x1800@60.000");
    }

    #[test]
    fn changes_to_actions_and_records() {
        let c = OutputChange {
            mode: Some("2560x1440@143.912".into()),
            scale: Some("1.25".into()),
            position: Some("5120,0".into()),
            vrr: Some("on-demand".into()),
            off: Some(false),
            ..Default::default()
        };
        let a = c.actions().unwrap();
        // The wire format niri 26.04 expects.
        let wire: Vec<Value> = a.iter().map(|a| serde_json::to_value(a).unwrap()).collect();
        assert_eq!(
            wire,
            vec![
                json!("On"),
                json!({ "Mode": { "mode": { "Specific": { "width": 2560, "height": 1440, "refresh": 143.912 } } } }),
                json!({ "Scale": { "scale": { "Specific": 1.25 } } }),
                json!({ "Position": { "position": { "Specific": { "x": 5120, "y": 0 } } } }),
                json!({ "Vrr": { "vrr": { "vrr": true, "on_demand": true } } }),
            ]
        );
        let mut rec = Map::new();
        c.record(&mut rec).unwrap();
        assert_eq!(
            Value::Object(rec),
            json!({ "mode": "2560x1440@143.912", "scale": 1.25, "position": { "x": 5120, "y": 0 },
                    "vrr": "on-demand", "off": false })
        );
        assert!(
            OutputChange {
                mode: Some("wide".into()),
                ..Default::default()
            }
            .actions()
            .is_err()
        );
    }
}
