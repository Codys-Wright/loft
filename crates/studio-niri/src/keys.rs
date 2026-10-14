//! The niri settings studio-niri manages (input, layout, animations).
//!
//! Each key is named like its KDL path (`input.mouse.accel-speed`), so the
//! overrides JSON reads like the config it becomes. Theme-owned settings
//! (focus ring / border colors, blur, shadows, corner radius) are not here:
//! they come from the theme fragment.
//!
//! niri merges config parts differently per section, and that decides how
//! an override must be written:
//! - `unit == path`: a field niri merges on its own (e.g. `layout.gaps`), so
//!   the override is just that one node;
//! - otherwise `unit` is a block niri *replaces* whole when it appears again
//!   (`input.mouse`, `input.touchpad`, `input.keyboard.xkb`, `layout.struts`),
//!   so the override re-emits the effective block with our fields changed.

use anyhow::{Result, bail};
use serde_json::{Value, json};

use crate::config::{ConfigTree, NodeRef};
use crate::kdl_out::{Node, Val};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind {
    Int {
        min: i64,
        max: i64,
    },
    /// niri `FloatOrInt` (written as an integer when integral).
    Number {
        min: f64,
        max: f64,
    },
    /// A strict f64 field.
    Float {
        min: f64,
        max: f64,
    },
    Str,
    Enum(&'static [&'static str]),
    /// A bare flag child: present = on.
    Flag,
    /// `{ proportion X; }` / `{ fixed N; }` — a number is a proportion,
    /// `{"fixed": N}` a fixed width.
    Size,
    /// A list of sizes (preset-column-widths).
    Sizes,
    /// `animations { off }` / `animations { on }` (merged as a flag pair).
    AnimOff,
}

#[derive(Debug)]
pub struct KeyDef {
    pub key: &'static str,
    /// The node path niri merges as one unit (see module docs).
    pub unit: &'static [&'static str],
    /// The child of `unit` holding the value; `None` = `unit` itself.
    pub field: Option<&'static str>,
    pub kind: Kind,
    pub label: &'static str,
}

impl KeyDef {
    pub fn default_value(&self) -> Value {
        match self.key {
            "input.keyboard.repeat-delay" => json!(600),
            "input.keyboard.repeat-rate" => json!(25),
            "input.keyboard.xkb.layout"
            | "input.keyboard.xkb.variant"
            | "input.keyboard.xkb.options" => json!(""),
            "input.mouse.accel-speed" | "input.touchpad.accel-speed" => json!(0.0),
            "input.mouse.accel-profile" | "input.touchpad.accel-profile" => json!("adaptive"),
            "layout.gaps" => json!(16.0),
            "layout.center-focused-column" => json!("never"),
            "layout.default-column-width" => json!(0.5),
            "layout.preset-column-widths" => json!([0.33333, 0.5, 0.66667]),
            "animations.slowdown" => json!(1.0),
            k if k.starts_with("layout.struts.") => json!(0.0),
            _ => match self.kind {
                Kind::Flag | Kind::AnimOff => json!(false),
                _ => Value::Null,
            },
        }
    }

    pub fn kind_name(&self) -> &'static str {
        match self.kind {
            Kind::Int { .. } => "int",
            Kind::Number { .. } | Kind::Float { .. } => "number",
            Kind::Str => "string",
            Kind::Enum(_) => "enum",
            Kind::Flag | Kind::AnimOff => "bool",
            Kind::Size => "size",
            Kind::Sizes => "sizes",
        }
    }

    pub fn describe(&self) -> Value {
        let mut v = json!({
            "key": self.key,
            "label": self.label,
            "kind": self.kind_name(),
            "default": self.default_value(),
        });
        match self.kind {
            Kind::Int { min, max } => {
                v["min"] = json!(min);
                v["max"] = json!(max);
            }
            Kind::Number { min, max } | Kind::Float { min, max } => {
                v["min"] = json!(min);
                v["max"] = json!(max);
            }
            Kind::Enum(opts) => v["options"] = json!(opts),
            _ => {}
        }
        v
    }

    /// The node path of the value (`unit` + `field`).
    pub fn path(&self) -> Vec<&'static str> {
        let mut p = self.unit.to_vec();
        if let Some(f) = self.field {
            p.push(f);
        }
        p
    }
}

const ACCEL_PROFILES: &[&str] = &["adaptive", "flat"];
const CENTER: &[&str] = &["never", "always", "on-overflow"];

macro_rules! key {
    ($key:literal, [$($unit:literal),*], $field:expr, $kind:expr, $label:literal) => {
        KeyDef { key: $key, unit: &[$($unit),*], field: $field, kind: $kind, label: $label }
    };
}

pub static KEYS: &[KeyDef] = &[
    key!(
        "input.keyboard.xkb.layout",
        ["input", "keyboard", "xkb"],
        Some("layout"),
        Kind::Str,
        "Keyboard layout"
    ),
    key!(
        "input.keyboard.xkb.variant",
        ["input", "keyboard", "xkb"],
        Some("variant"),
        Kind::Str,
        "Layout variant"
    ),
    key!(
        "input.keyboard.xkb.options",
        ["input", "keyboard", "xkb"],
        Some("options"),
        Kind::Str,
        "XKB options"
    ),
    key!(
        "input.keyboard.repeat-delay",
        ["input", "keyboard", "repeat-delay"],
        None,
        Kind::Int {
            min: 100,
            max: 2000
        },
        "Key repeat delay"
    ),
    key!(
        "input.keyboard.repeat-rate",
        ["input", "keyboard", "repeat-rate"],
        None,
        Kind::Int { min: 1, max: 100 },
        "Key repeat rate"
    ),
    key!(
        "input.mouse.accel-speed",
        ["input", "mouse"],
        Some("accel-speed"),
        Kind::Number {
            min: -1.0,
            max: 1.0
        },
        "Pointer speed"
    ),
    key!(
        "input.mouse.accel-profile",
        ["input", "mouse"],
        Some("accel-profile"),
        Kind::Enum(ACCEL_PROFILES),
        "Acceleration"
    ),
    key!(
        "input.mouse.natural-scroll",
        ["input", "mouse"],
        Some("natural-scroll"),
        Kind::Flag,
        "Natural scrolling"
    ),
    key!(
        "input.touchpad.accel-speed",
        ["input", "touchpad"],
        Some("accel-speed"),
        Kind::Number {
            min: -1.0,
            max: 1.0
        },
        "Pointer speed"
    ),
    key!(
        "input.touchpad.accel-profile",
        ["input", "touchpad"],
        Some("accel-profile"),
        Kind::Enum(ACCEL_PROFILES),
        "Acceleration"
    ),
    key!(
        "input.touchpad.natural-scroll",
        ["input", "touchpad"],
        Some("natural-scroll"),
        Kind::Flag,
        "Natural scrolling"
    ),
    key!(
        "input.touchpad.tap",
        ["input", "touchpad"],
        Some("tap"),
        Kind::Flag,
        "Tap to click"
    ),
    key!(
        "input.touchpad.dwt",
        ["input", "touchpad"],
        Some("dwt"),
        Kind::Flag,
        "Disable while typing"
    ),
    key!(
        "layout.gaps",
        ["layout", "gaps"],
        None,
        Kind::Number {
            min: 0.0,
            max: 64.0
        },
        "Gaps"
    ),
    key!(
        "layout.center-focused-column",
        ["layout", "center-focused-column"],
        None,
        Kind::Enum(CENTER),
        "Center focused column"
    ),
    key!(
        "layout.default-column-width",
        ["layout", "default-column-width"],
        None,
        Kind::Size,
        "Default column width"
    ),
    key!(
        "layout.preset-column-widths",
        ["layout", "preset-column-widths"],
        None,
        Kind::Sizes,
        "Preset column widths"
    ),
    key!(
        "layout.struts.left",
        ["layout", "struts"],
        Some("left"),
        Kind::Number {
            min: -4096.0,
            max: 4096.0
        },
        "Strut left"
    ),
    key!(
        "layout.struts.right",
        ["layout", "struts"],
        Some("right"),
        Kind::Number {
            min: -4096.0,
            max: 4096.0
        },
        "Strut right"
    ),
    key!(
        "layout.struts.top",
        ["layout", "struts"],
        Some("top"),
        Kind::Number {
            min: -4096.0,
            max: 4096.0
        },
        "Strut top"
    ),
    key!(
        "layout.struts.bottom",
        ["layout", "struts"],
        Some("bottom"),
        Kind::Number {
            min: -4096.0,
            max: 4096.0
        },
        "Strut bottom"
    ),
    key!(
        "animations.slowdown",
        ["animations", "slowdown"],
        None,
        Kind::Float {
            min: 0.05,
            max: 10.0
        },
        "Animation slowdown"
    ),
    key!(
        "animations.off",
        ["animations", "off"],
        None,
        Kind::AnimOff,
        "Animations off"
    ),
];

pub fn find(key: &str) -> Result<&'static KeyDef> {
    KEYS.iter().find(|k| k.key == key).ok_or_else(|| {
        anyhow::anyhow!(
            "unknown setting `{key}` (known: {})",
            KEYS.iter().map(|k| k.key).collect::<Vec<_>>().join(", ")
        )
    })
}

fn parse_bool(s: &str) -> Result<bool> {
    Ok(match s.to_ascii_lowercase().as_str() {
        "1" | "true" | "on" | "yes" => true,
        "0" | "false" | "off" | "no" => false,
        _ => bail!("expected on/off, got `{s}`"),
    })
}

fn parse_size(s: &str) -> Result<Value> {
    let s = s.trim();
    if let Some(px) = s.strip_prefix("fixed:").or_else(|| s.strip_suffix("px")) {
        let n: i64 = px.trim().parse()?;
        return Ok(json!({ "fixed": n }));
    }
    let p: f64 = s.parse()?;
    if !(0.0..=1.0).contains(&p) || p == 0.0 {
        bail!("a proportion is in (0, 1], got {p}");
    }
    Ok(json!(p))
}

impl KeyDef {
    /// Parse a CLI value (or accept a JSON value) into the stored form.
    pub fn parse(&self, raw: &Value) -> Result<Value> {
        let s = match raw {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        Ok(match self.kind {
            Kind::Int { min, max } => {
                let v: f64 = s.trim().parse()?;
                let v = v.round() as i64;
                if !(min..=max).contains(&v) {
                    bail!("{} must be in {min}..={max}", self.key);
                }
                json!(v)
            }
            Kind::Number { min, max } | Kind::Float { min, max } => {
                let v: f64 = s.trim().parse()?;
                if !(min..=max).contains(&v) {
                    bail!("{} must be in {min}..={max}", self.key);
                }
                json!(v)
            }
            Kind::Str => json!(s),
            Kind::Enum(opts) => {
                if !opts.contains(&s.as_str()) {
                    bail!("{} must be one of {}", self.key, opts.join(", "));
                }
                json!(s)
            }
            Kind::Flag | Kind::AnimOff => match raw {
                Value::Bool(b) => json!(b),
                _ => json!(parse_bool(&s)?),
            },
            Kind::Size => match raw {
                Value::Object(_) | Value::Number(_) => raw.clone(),
                _ => parse_size(&s)?,
            },
            Kind::Sizes => match raw {
                Value::Array(a) => Value::Array(a.clone()),
                _ => Value::Array(
                    s.split([',', ' '])
                        .filter(|p| !p.is_empty())
                        .map(parse_size)
                        .collect::<Result<_>>()?,
                ),
            },
        })
    }

    /// The value a config node holds (`node` is the value's node: the field
    /// child, or the unit itself).
    pub fn read(&self, node: &kdl::KdlNode) -> Value {
        let arg = node
            .entries()
            .iter()
            .find(|e| e.name().is_none())
            .map(|e| e.value());
        match self.kind {
            Kind::Int { .. } => arg
                .and_then(|v| v.as_integer())
                .map(|i| json!(i as i64))
                .unwrap_or(Value::Null),
            Kind::Number { .. } | Kind::Float { .. } => arg
                .and_then(|v| v.as_float().or_else(|| v.as_integer().map(|i| i as f64)))
                .map(|f| json!(f))
                .unwrap_or(Value::Null),
            Kind::Str | Kind::Enum(_) => arg
                .and_then(|v| v.as_string())
                .map(|s| json!(s))
                .unwrap_or(Value::Null),
            Kind::Flag | Kind::AnimOff => json!(arg.and_then(|v| v.as_bool()).unwrap_or(true)),
            Kind::Size => node
                .iter_children()
                .next()
                .map(read_size)
                .unwrap_or(Value::Null),
            Kind::Sizes => Value::Array(node.iter_children().map(read_size).collect()),
        }
    }

    /// The value as KDL: the node named `name` carrying it, or `None` when
    /// the value means "leave it out" (a false flag).
    pub fn to_node(&self, name: &str, v: &Value) -> Option<Node> {
        let n = Node::new(name);
        Some(match self.kind {
            Kind::Int { .. } => n.arg(Val::Int(v.as_i64()?)),
            Kind::Number { .. } => n.arg(Val::Number(v.as_f64()?)),
            Kind::Float { .. } => n.arg(Val::Float(v.as_f64()?)),
            Kind::Str | Kind::Enum(_) => n.arg(Val::Str(v.as_str()?.to_string())),
            Kind::Flag => {
                if v.as_bool()? {
                    n
                } else {
                    return None;
                }
            }
            Kind::AnimOff => Node::new(if v.as_bool()? { "off" } else { "on" }),
            Kind::Size => n.child(size_node(v)?),
            Kind::Sizes => {
                let mut n = n;
                for s in v.as_array()? {
                    n = n.child(size_node(s)?);
                }
                n
            }
        })
    }
}

fn read_size(n: &kdl::KdlNode) -> Value {
    let arg = n.entries().first().map(|e| e.value());
    match n.name().value() {
        "proportion" => arg
            .and_then(|v| v.as_float().or_else(|| v.as_integer().map(|i| i as f64)))
            .map(|f| json!(f))
            .unwrap_or(Value::Null),
        "fixed" => arg
            .and_then(|v| v.as_integer())
            .map(|i| json!({ "fixed": i as i64 }))
            .unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

fn size_node(v: &Value) -> Option<Node> {
    if let Some(p) = v.as_f64() {
        return Some(Node::new("proportion").arg(Val::Float(p)));
    }
    let px = v.get("fixed")?.as_i64()?;
    Some(Node::new("fixed").arg(Val::Int(px)))
}

/// Where a key's effective (config) value comes from.
pub struct ConfigValue<'a> {
    pub value: Value,
    pub node: Option<NodeRef<'a>>,
}

/// The value niri ends up with from `tree` alone (no overrides), following
/// niri's merge rules for the key's unit.
pub fn config_value<'a>(tree: &'a ConfigTree, def: &KeyDef) -> ConfigValue<'a> {
    if def.kind == Kind::AnimOff {
        let mut off = false;
        let mut at = None;
        for a in tree.find_all(&["animations"]) {
            for c in a.node.iter_children() {
                match c.name().value() {
                    "off" => {
                        off = true;
                        at = Some(NodeRef {
                            file: a.file,
                            node: c,
                        });
                    }
                    "on" => {
                        off = false;
                        at = Some(NodeRef {
                            file: a.file,
                            node: c,
                        });
                    }
                    _ => {}
                }
            }
        }
        return ConfigValue {
            value: json!(off),
            node: at,
        };
    }
    let Some(unit) = tree.find_last(def.unit) else {
        return ConfigValue {
            value: def.default_value(),
            node: None,
        };
    };
    let node = match def.field {
        None => Some(unit),
        Some(f) => unit
            .node
            .iter_children()
            .filter(|c| c.name().value() == f)
            .last()
            .map(|c| NodeRef {
                file: unit.file,
                node: c,
            }),
    };
    match node {
        Some(n) => {
            let v = def.read(n.node);
            ConfigValue {
                value: if v.is_null() { def.default_value() } else { v },
                node: Some(n),
            }
        }
        // The block is there but the field isn't: niri's default for it
        // (a replaced block doesn't inherit from earlier ones).
        None => ConfigValue {
            value: if def.kind == Kind::Flag {
                json!(false)
            } else {
                def.default_value()
            },
            node: None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cli_values() {
        assert_eq!(
            find("layout.gaps").unwrap().parse(&json!("12")).unwrap(),
            json!(12.0)
        );
        assert!(find("layout.gaps").unwrap().parse(&json!("100")).is_err());
        assert_eq!(
            find("input.touchpad.tap")
                .unwrap()
                .parse(&json!("on"))
                .unwrap(),
            json!(true)
        );
        assert_eq!(
            find("layout.preset-column-widths")
                .unwrap()
                .parse(&json!("0.25,0.5 fixed:800"))
                .unwrap(),
            json!([0.25, 0.5, { "fixed": 800 }])
        );
        assert!(
            find("input.mouse.accel-profile")
                .unwrap()
                .parse(&json!("linear"))
                .is_err()
        );
        assert!(find("nope").is_err());
    }
}
