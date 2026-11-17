//! `loft-kwin input`: Settings → Keyboard & Mouse under KWin (docs/KWIN.md §4.12).
//!
//! niri keeps keyboard layouts and pointer settings in its config
//! (`input.keyboard.xkb`, `input.mouse`, `input.touchpad`); KDE keeps them in
//! two places, and this maps Loft's niri-named settings onto both:
//!
//! - **Layouts**: kxkbrc `[Layout]` (LayoutList, VariantList, Options,
//!   ResetOldOptions, Use). KWin's KeyboardLayout watches kxkbrc with a
//!   KConfigWatcher, so writing it and sending KConfig's `ConfigChanged`
//!   notification (what `kwriteconfig6 --notify` does) makes KWin rebuild the
//!   keymap at once; `org.kde.keyboard /Layouts` then reports the new list.
//! - **Mouse and trackpad**: per device, through KWin's
//!   `/org/kde/KWin/InputDevice/<sysName>` (`org.kde.KWin.InputDevice`,
//!   libinput devices only). Setting a property applies it live and KWin
//!   writes it to kcminputrc `[Libinput][vendor][product][name]` itself
//!   (Device::writeEntry); we write the same keys too, as KDE's mouse KCM
//!   would, so the value survives login whatever KWin version runs. Like
//!   niri's `input.mouse` / `input.touchpad`, one change goes to every
//!   device of that kind that supports it.
//!
//! `loft-kwin input` prints the state; `loft-kwin input set JSON` applies
//! `{"keyboard": {"layout": "us,de"}, "mouse": {"accel-speed": 0.2},
//! "touchpad": {"tap": true}}` and prints what it did.

use std::collections::HashMap;
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value, json};
use zbus::zvariant::{OwnedValue, Value as ZValue};
use zbus::{Connection, Proxy};

const KWIN: &str = "org.kde.KWin";
const MANAGER_PATH: &str = "/org/kde/KWin/InputDevice";
const MANAGER_IFACE: &str = "org.kde.KWin.InputDeviceManager";
const DEVICE_IFACE: &str = "org.kde.KWin.InputDevice";

/// Which of niri's sections a device belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Mouse,
    Touchpad,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Mouse => "mouse",
            Kind::Touchpad => "touchpad",
        }
    }

    fn from_name(s: &str) -> Option<Kind> {
        match s {
            "mouse" => Some(Kind::Mouse),
            "touchpad" => Some(Kind::Touchpad),
            _ => None,
        }
    }
}

/// One libinput device as KWin reports it (its D-Bus properties, as JSON).
#[derive(Debug, Clone)]
pub struct Device {
    pub sys_name: String,
    pub props: Map<String, Value>,
}

impl Device {
    fn flag(&self, k: &str) -> bool {
        self.props.get(k).and_then(Value::as_bool).unwrap_or(false)
    }

    fn num(&self, k: &str) -> Option<f64> {
        self.props.get(k).and_then(Value::as_f64)
    }

    pub fn name(&self) -> &str {
        self.props.get("name").and_then(Value::as_str).unwrap_or("")
    }

    /// Mouse = a pointer that isn't a touchpad, touchscreen or tablet tool.
    pub fn kind(&self) -> Option<Kind> {
        if self.flag("touchpad") {
            Some(Kind::Touchpad)
        } else if self.flag("pointer") && !self.flag("touch") && !self.flag("tabletTool") && !self.flag("tabletPad") {
            Some(Kind::Mouse)
        } else {
            None
        }
    }

    /// kcminputrc's group path for it, as KWin builds it (Connection::applyDeviceConfig).
    pub fn config_groups(&self) -> Option<[String; 4]> {
        let vendor = self.num("vendor")?;
        let product = self.num("product")?;
        Some(["Libinput".into(), format!("{}", vendor as u64), format!("{}", product as u64), self.name().to_string()])
    }
}

/// A niri setting Loft shows, and how it lands on a KWin device.
#[derive(Debug)]
pub struct Setting {
    /// niri's key under `input.mouse.` / `input.touchpad.`.
    pub key: &'static str,
    pub kinds: &'static [Kind],
    /// What on the device says it can do it.
    supports: Support,
    /// kcminputrc key (Device's s_configData).
    config_key: &'static str,
}

#[derive(Debug)]
enum Support {
    /// The device has the property at all (scrollFactor: every libinput pointer).
    Has(&'static str),
    Flag(&'static str),
    Both(&'static str, &'static str),
    Tap,
}

const BOTH: &[Kind] = &[Kind::Mouse, Kind::Touchpad];
const TOUCHPAD: &[Kind] = &[Kind::Touchpad];
const MOUSE: &[Kind] = &[Kind::Mouse];

pub static SETTINGS: &[Setting] = &[
    Setting { key: "accel-speed", kinds: BOTH, supports: Support::Flag("supportsPointerAcceleration"), config_key: "PointerAcceleration" },
    Setting {
        key: "accel-profile",
        kinds: BOTH,
        supports: Support::Both("supportsPointerAccelerationProfileFlat", "supportsPointerAccelerationProfileAdaptive"),
        config_key: "PointerAccelerationProfile",
    },
    Setting { key: "natural-scroll", kinds: BOTH, supports: Support::Flag("supportsNaturalScroll"), config_key: "NaturalScroll" },
    Setting { key: "scroll-factor", kinds: BOTH, supports: Support::Has("scrollFactor"), config_key: "ScrollFactor" },
    Setting { key: "left-handed", kinds: BOTH, supports: Support::Flag("supportsLeftHanded"), config_key: "LeftHanded" },
    Setting { key: "middle-emulation", kinds: MOUSE, supports: Support::Flag("supportsMiddleEmulation"), config_key: "MiddleButtonEmulation" },
    Setting { key: "tap", kinds: TOUCHPAD, supports: Support::Tap, config_key: "TapToClick" },
    Setting { key: "drag", kinds: TOUCHPAD, supports: Support::Tap, config_key: "TapAndDrag" },
    Setting { key: "dwt", kinds: TOUCHPAD, supports: Support::Flag("supportsDisableWhileTyping"), config_key: "DisableWhileTyping" },
];

pub fn setting(key: &str) -> Option<&'static Setting> {
    SETTINGS.iter().find(|s| s.key == key)
}

/// libinput's accel profile bits, as kcminputrc stores them.
const PROFILE_FLAT: u32 = 1;
const PROFILE_ADAPTIVE: u32 = 2;

impl Setting {
    pub fn supported_by(&self, d: &Device) -> bool {
        d.kind().is_some_and(|k| self.kinds.contains(&k))
            && match self.supports {
                Support::Has(p) => d.props.contains_key(p),
                Support::Flag(f) => d.flag(f),
                Support::Both(a, b) => d.flag(a) && d.flag(b),
                Support::Tap => d.num("tapFingerCount").unwrap_or(0.0) > 0.0,
            }
    }

    /// The device's current value, in niri's terms.
    pub fn read(&self, d: &Device) -> Option<Value> {
        let b = |k: &str| d.props.get(k).and_then(Value::as_bool).map(Value::from);
        match self.key {
            "accel-speed" => d.num("pointerAcceleration").map(|v| json!((v * 100.0).round() / 100.0)),
            "accel-profile" => Some(json!(if d.flag("pointerAccelerationProfileFlat") { "flat" } else { "adaptive" })),
            "natural-scroll" => b("naturalScroll"),
            "scroll-factor" => d.num("scrollFactor").map(|v| json!((v * 100.0).round() / 100.0)),
            "left-handed" => b("leftHanded"),
            "middle-emulation" => b("middleEmulation"),
            "tap" => b("tapToClick"),
            "drag" => b("tapAndDrag"),
            "dwt" => b("disableWhileTyping"),
            _ => None,
        }
    }

    /// A niri value → the D-Bus property writes, and the kcminputrc entry.
    pub fn plan(&self, v: &Value) -> Result<(Vec<(&'static str, PropValue)>, String)> {
        let flag = |prop: &'static str| -> Result<(Vec<(&'static str, PropValue)>, String)> {
            let on = v.as_bool().with_context(|| format!("{}: wants true or false, got {v}", self.key))?;
            Ok((vec![(prop, PropValue::Bool(on))], on.to_string()))
        };
        match self.key {
            "accel-speed" => {
                let n = v.as_f64().with_context(|| format!("accel-speed: wants a number, got {v}"))?;
                if !(-1.0..=1.0).contains(&n) {
                    bail!("accel-speed: {n} is outside -1…1");
                }
                // KWin stores it as text with three decimals (setPointerAccelerationFromString).
                Ok((vec![("pointerAcceleration", PropValue::Double(n))], format!("{n:.3}")))
            }
            "accel-profile" => match v.as_str() {
                Some("flat") => Ok((vec![("pointerAccelerationProfileFlat", PropValue::Bool(true))], PROFILE_FLAT.to_string())),
                Some("adaptive") => {
                    Ok((vec![("pointerAccelerationProfileAdaptive", PropValue::Bool(true))], PROFILE_ADAPTIVE.to_string()))
                }
                _ => bail!("accel-profile: wants \"flat\" or \"adaptive\", got {v}"),
            },
            "scroll-factor" => {
                let n = v.as_f64().with_context(|| format!("scroll-factor: wants a number, got {v}"))?;
                if !(n > 0.0 && n <= 10.0) {
                    bail!("scroll-factor: {n} is outside 0…10");
                }
                Ok((vec![("scrollFactor", PropValue::Double(n))], format!("{n}")))
            }
            "natural-scroll" => flag("naturalScroll"),
            "left-handed" => flag("leftHanded"),
            "middle-emulation" => flag("middleEmulation"),
            "tap" => flag("tapToClick"),
            "drag" => flag("tapAndDrag"),
            "dwt" => flag("disableWhileTyping"),
            _ => bail!("unknown setting {}", self.key),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum PropValue {
    Bool(bool),
    Double(f64),
}

/// The state of one section ("mouse" / "touchpad"): its devices, which
/// settings at least one of them supports, and the first one's values
/// (niri has one value per section; KDE one per device).
pub fn section(devices: &[Device], kind: Kind) -> Value {
    let mine: Vec<&Device> = devices.iter().filter(|d| d.kind() == Some(kind)).collect();
    let mut supported = Vec::new();
    let mut values = Map::new();
    for s in SETTINGS.iter().filter(|s| s.kinds.contains(&kind)) {
        let Some(first) = mine.iter().find(|d| s.supported_by(d)) else { continue };
        supported.push(json!(s.key));
        if let Some(v) = s.read(first) {
            values.insert(s.key.into(), v);
        }
    }
    json!({
        "devices": mine.iter().map(|d| json!(d.name())).collect::<Vec<_>>(),
        "supported": supported,
        "values": values,
    })
}

// ── Keyboard: kxkbrc ─────────────────────────────────────────────────────

/// niri's xkb fields as Loft shows them ("us,de", ",nodeadkeys", "caps:escape").
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Xkb {
    pub layout: String,
    pub variant: String,
    pub options: String,
}

fn clean_list(s: &str) -> Vec<String> {
    if s.trim().is_empty() {
        return Vec::new();
    }
    s.split(',').map(|p| p.trim().to_string()).collect()
}

/// kxkbrc → niri's fields. An unused layout list (Use=false) is the system
/// default, which niri spells as an empty layout. A trailing run of empty
/// variants is dropped (",," reads as no variant).
pub fn xkb_from_config(layout_list: &str, variant_list: &str, options: &str, use_layouts: bool, reset_options: bool) -> Xkb {
    let layouts = if use_layouts { clean_list(layout_list) } else { Vec::new() };
    let mut variants = if layouts.is_empty() { Vec::new() } else { clean_list(variant_list) };
    variants.truncate(layouts.len());
    while variants.last().is_some_and(String::is_empty) {
        variants.pop();
    }
    Xkb {
        layout: layouts.join(","),
        variant: variants.join(","),
        options: if reset_options { clean_list(options).into_iter().filter(|o| !o.is_empty()).collect::<Vec<_>>().join(",") } else { String::new() },
    }
}

/// niri's fields → kxkbrc [Layout] entries, as the keyboard KCM writes them.
/// VariantList gets one entry per layout. Options always replace the
/// system's (ResetOldOptions=true): niri's options are the whole list too.
pub fn xkb_entries(x: &Xkb) -> Result<Vec<(&'static str, String)>> {
    let layouts = clean_list(&x.layout);
    if layouts.iter().any(String::is_empty) {
        bail!("layout: an empty name in {:?}", x.layout);
    }
    let mut variants = clean_list(&x.variant);
    if variants.len() > layouts.len() {
        bail!("variant: {} variants for {} layouts", variants.len(), layouts.len().max(1));
    }
    variants.resize(layouts.len(), String::new());
    let options: Vec<String> = clean_list(&x.options).into_iter().filter(|o| !o.is_empty()).collect();
    let valid = |s: &str| s.chars().all(|c| c.is_ascii_alphanumeric() || "_-:+()".contains(c));
    for v in layouts.iter().chain(&variants).chain(&options) {
        if !valid(v) {
            bail!("{v:?} isn't an XKB name");
        }
    }
    Ok(vec![
        ("LayoutList", layouts.join(",")),
        ("VariantList", variants.join(",")),
        ("Use", (!layouts.is_empty()).to_string()),
        ("Options", options.join(",")),
        ("ResetOldOptions", "true".into()),
    ])
}

fn read_config(file: &str, groups: &[&str], key: &str, default: &str) -> String {
    let mut cmd = Command::new("kreadconfig6");
    cmd.args(["--file", file]);
    for g in groups {
        cmd.args(["--group", g]);
    }
    cmd.args(["--key", key, "--default", default]);
    match cmd.output() {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string(),
        _ => default.to_string(),
    }
}

fn write_config(file: &str, groups: &[&str], key: &str, value: &str) -> Result<()> {
    let mut cmd = Command::new("kwriteconfig6");
    cmd.args(["--file", file]);
    for g in groups {
        cmd.args(["--group", g]);
    }
    cmd.args(["--key", key, value]);
    let st = cmd.status().context("running kwriteconfig6")?;
    if !st.success() {
        bail!("kwriteconfig6 --file {file} --key {key} failed ({st})");
    }
    Ok(())
}

pub fn read_xkb() -> Xkb {
    let r = |k: &str, d: &str| read_config("kxkbrc", &["Layout"], k, d);
    xkb_from_config(
        &r("LayoutList", ""),
        &r("VariantList", ""),
        &r("Options", ""),
        r("Use", "false") == "true",
        r("ResetOldOptions", "false") == "true",
    )
}

/// Write kxkbrc and tell KWin, as `kwriteconfig6 --notify` would: one
/// KConfig `ConfigChanged` signal with every key, so KWin rebuilds the
/// keymap once, from a consistent file.
async fn write_xkb(conn: &Connection, x: &Xkb) -> Result<()> {
    let entries = xkb_entries(x)?;
    for (k, v) in &entries {
        write_config("kxkbrc", &["Layout"], k, v)?;
    }
    let keys: Vec<Vec<u8>> = entries.iter().map(|(k, _)| k.as_bytes().to_vec()).collect();
    let changed: HashMap<String, Vec<Vec<u8>>> = HashMap::from([("Layout".to_string(), keys)]);
    conn.emit_signal(None::<&str>, "/kxkbrc", "org.kde.kconfig.notify", "ConfigChanged", &(changed,))
        .await
        .context("notifying kxkbrc's change")?;
    Ok(())
}

// ── Devices: KWin's InputDevice D-Bus ─────────────────────────────────────

/// A D-Bus property value as JSON (the scalar types InputDevice uses).
fn to_json(v: &ZValue) -> Option<Value> {
    Some(match v {
        ZValue::Bool(b) => json!(b),
        ZValue::U8(n) => json!(n),
        ZValue::I16(n) => json!(n),
        ZValue::U16(n) => json!(n),
        ZValue::I32(n) => json!(n),
        ZValue::U32(n) => json!(n),
        ZValue::I64(n) => json!(n),
        ZValue::U64(n) => json!(n),
        ZValue::F64(n) => json!(n),
        ZValue::Str(s) => json!(s.as_str()),
        ZValue::Value(inner) => return to_json(inner),
        _ => return None,
    })
}

pub fn props_to_json(props: &HashMap<String, OwnedValue>) -> Map<String, Value> {
    props.iter().filter_map(|(k, v)| to_json(v).map(|j| (k.clone(), j))).collect()
}

async fn device_proxy<'a>(conn: &Connection, sys_name: &str) -> Result<Proxy<'a>> {
    Ok(zbus::proxy::Builder::new(conn)
        .destination(KWIN)?
        .path(format!("{MANAGER_PATH}/{sys_name}"))?
        .interface(DEVICE_IFACE)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await?)
}

/// KWin's libinput devices. None when KWin has no device manager (a nested
/// KWin, whose input comes from its host, has no libinput).
pub async fn devices(conn: &Connection) -> Result<Option<Vec<Device>>> {
    let mgr: Proxy = zbus::proxy::Builder::new(conn)
        .destination(KWIN)?
        .path(MANAGER_PATH)?
        .interface(MANAGER_IFACE)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await?;
    let names: Vec<String> = match mgr.get_property("devicesSysNames").await {
        Ok(n) => n,
        Err(_) => return Ok(None),
    };
    let mut out = Vec::new();
    for sys_name in names {
        let props = zbus::fdo::PropertiesProxy::builder(conn)
            .destination(KWIN)?
            .path(format!("{MANAGER_PATH}/{sys_name}"))?
            .build()
            .await?;
        let Ok(all) = props.get_all(zbus::names::InterfaceName::try_from(DEVICE_IFACE)?).await else { continue };
        out.push(Device { sys_name, props: props_to_json(&all) });
    }
    Ok(Some(out))
}

pub async fn state(conn: &Connection) -> Result<Value> {
    let xkb = read_xkb();
    let devs = devices(conn).await?;
    let list = devs.clone().unwrap_or_default();
    Ok(json!({
        "ok": true,
        "keyboard": { "layout": xkb.layout, "variant": xkb.variant, "options": xkb.options },
        "libinput": devs.is_some(),
        "mouse": section(&list, Kind::Mouse),
        "touchpad": section(&list, Kind::Touchpad),
        "devices": list.iter().map(|d| json!({
            "sys_name": d.sys_name,
            "name": d.name(),
            "kind": d.kind().map(Kind::name),
        })).collect::<Vec<_>>(),
    }))
}

/// One planned device write: which device, which setting, the property
/// writes and the kcminputrc entry.
#[derive(Debug)]
pub struct DeviceWrite<'a> {
    pub device: &'a Device,
    pub setting: &'static Setting,
    pub props: Vec<(&'static str, PropValue)>,
    pub config_value: String,
}

/// `{"mouse": {"accel-speed": 0.2}, "touchpad": {...}}` → the writes, to
/// every device of that kind that supports the setting. Unknown sections or
/// settings, and bad values, are errors before anything is written.
pub fn plan_devices<'a>(devices: &'a [Device], batch: &Map<String, Value>) -> Result<Vec<DeviceWrite<'a>>> {
    let mut out = Vec::new();
    for (section, changes) in batch {
        let Some(kind) = Kind::from_name(section) else {
            if section == "keyboard" {
                continue;
            }
            bail!("unknown section {section:?} (keyboard, mouse, touchpad)");
        };
        let changes = changes.as_object().with_context(|| format!("{section}: wants an object"))?;
        for (key, v) in changes {
            let s = setting(key).filter(|s| s.kinds.contains(&kind)).with_context(|| format!("{section}: unknown setting {key:?}"))?;
            let (props, config_value) = s.plan(v)?;
            for d in devices.iter().filter(|d| s.supported_by(d)) {
                if d.kind() == Some(kind) {
                    out.push(DeviceWrite { device: d, setting: s, props: props.clone(), config_value: config_value.clone() });
                }
            }
        }
    }
    Ok(out)
}

fn parse_xkb_change(current: &Xkb, change: &Map<String, Value>) -> Result<Xkb> {
    let mut x = current.clone();
    for (k, v) in change {
        let s = v.as_str().with_context(|| format!("keyboard.{k}: wants a string"))?.trim().to_string();
        match k.as_str() {
            "layout" => x.layout = s,
            "variant" => x.variant = s,
            "options" => x.options = s,
            _ => bail!("keyboard: unknown setting {k:?} (layout, variant, options)"),
        }
    }
    Ok(x)
}

pub async fn apply(conn: &Connection, batch: &Map<String, Value>) -> Result<Value> {
    // Check everything before writing anything.
    let xkb = match batch.get("keyboard") {
        Some(Value::Object(change)) => {
            let x = parse_xkb_change(&read_xkb(), change)?;
            xkb_entries(&x)?;
            Some(x)
        }
        Some(_) => bail!("keyboard: wants an object"),
        None => None,
    };
    let devs = devices(conn).await?.unwrap_or_default();
    let writes = plan_devices(&devs, batch)?;
    let asked = batch.iter().any(|(k, v)| k != "keyboard" && v.as_object().is_some_and(|o| !o.is_empty()));
    if asked && writes.is_empty() {
        bail!("no mouse or trackpad here supports that (KWin lists {} input devices)", devs.len());
    }

    if let Some(x) = &xkb {
        write_xkb(conn, x).await?;
    }
    let mut applied = Vec::new();
    for w in &writes {
        set_props(conn, w).await?;
        if let Some(groups) = w.device.config_groups() {
            let g: Vec<&str> = groups.iter().map(String::as_str).collect();
            write_config("kcminputrc", &g, w.setting.config_key, &w.config_value)?;
        }
        applied.push(json!({ "device": w.device.name(), "sys_name": w.device.sys_name, "setting": w.setting.key }));
    }
    Ok(json!({ "ok": true, "keyboard": xkb.is_some(), "applied": applied }))
}

/// The live half of a device write: KWin applies it (and records it in kcminputrc).
async fn set_props(conn: &Connection, w: &DeviceWrite<'_>) -> Result<()> {
    let p = device_proxy(conn, &w.device.sys_name).await?;
    for (prop, v) in &w.props {
        let r = match v {
            PropValue::Bool(b) => p.set_property(prop, *b).await,
            PropValue::Double(n) => p.set_property(prop, *n).await,
        };
        r.with_context(|| format!("{}: setting {prop}", w.device.name()))?;
    }
    Ok(())
}

pub async fn cli(args: &[String]) -> Result<()> {
    let result = async {
        let conn = Connection::session().await.context("the session bus")?;
        match args.first().map(String::as_str) {
            None | Some("list") => state(&conn).await,
            Some("set") => {
                let b = args.get(1).context("usage: loft-kwin input set '{\"mouse\": {\"accel-speed\": 0.2}}'")?;
                let batch: Map<String, Value> = serde_json::from_str(b).context("input set: bad JSON")?;
                apply(&conn, &batch).await
            }
            Some(other) => bail!("input: unknown command `{other}` (list, set)"),
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

    fn dev(sys: &str, props: Value) -> Device {
        Device { sys_name: sys.into(), props: props.as_object().unwrap().clone() }
    }

    fn mouse() -> Device {
        dev(
            "event5",
            json!({
                "name": "Logitech USB Optical Mouse", "vendor": 1133, "product": 49271,
                "pointer": true, "touchpad": false, "keyboard": false,
                "supportsPointerAcceleration": true, "pointerAcceleration": 0.25,
                "supportsPointerAccelerationProfileFlat": true, "supportsPointerAccelerationProfileAdaptive": true,
                "pointerAccelerationProfileFlat": true, "pointerAccelerationProfileAdaptive": false,
                "supportsNaturalScroll": true, "naturalScroll": false,
                "supportsLeftHanded": true, "leftHanded": false,
                "supportsMiddleEmulation": true, "middleEmulation": true,
                "scrollFactor": 1.0, "tapFingerCount": 0,
            }),
        )
    }

    fn touchpad() -> Device {
        dev(
            "event7",
            json!({
                "name": "SYNA2B31:00 06CB:CD3E Touchpad", "vendor": 1739, "product": 52542,
                "pointer": true, "touchpad": true,
                "supportsPointerAcceleration": true, "pointerAcceleration": 0.0,
                "supportsPointerAccelerationProfileFlat": true, "supportsPointerAccelerationProfileAdaptive": true,
                "pointerAccelerationProfileFlat": false, "pointerAccelerationProfileAdaptive": true,
                "supportsNaturalScroll": true, "naturalScroll": true,
                "supportsDisableWhileTyping": true, "disableWhileTyping": true,
                "supportsLeftHanded": true, "leftHanded": false,
                "supportsMiddleEmulation": false,
                "tapFingerCount": 3, "tapToClick": true, "tapAndDrag": true, "scrollFactor": 0.5,
            }),
        )
    }

    fn keyboard() -> Device {
        dev("event2", json!({ "name": "AT Translated Set 2 keyboard", "keyboard": true, "pointer": false }))
    }

    #[test]
    fn kinds() {
        assert_eq!(mouse().kind(), Some(Kind::Mouse));
        assert_eq!(touchpad().kind(), Some(Kind::Touchpad));
        assert_eq!(keyboard().kind(), None);
        let pen = dev("event9", json!({ "pointer": true, "tabletTool": true }));
        assert_eq!(pen.kind(), None);
    }

    #[test]
    fn config_groups_like_kwin() {
        assert_eq!(
            mouse().config_groups().unwrap(),
            ["Libinput".to_string(), "1133".into(), "49271".into(), "Logitech USB Optical Mouse".into()]
        );
        assert!(keyboard().config_groups().is_none());
    }

    #[test]
    fn sections_report_support_and_values() {
        let devs = vec![mouse(), touchpad(), keyboard()];
        let m = section(&devs, Kind::Mouse);
        assert_eq!(m["devices"], json!(["Logitech USB Optical Mouse"]));
        assert_eq!(
            m["supported"],
            json!(["accel-speed", "accel-profile", "natural-scroll", "scroll-factor", "left-handed", "middle-emulation"])
        );
        assert_eq!(m["values"]["accel-speed"], json!(0.25));
        assert_eq!(m["values"]["accel-profile"], json!("flat"));
        assert_eq!(m["values"]["middle-emulation"], json!(true));

        let t = section(&devs, Kind::Touchpad);
        let sup: Vec<&str> = t["supported"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
        assert!(sup.contains(&"tap") && sup.contains(&"dwt") && sup.contains(&"drag"));
        assert!(!sup.contains(&"middle-emulation"));
        assert_eq!(t["values"]["accel-profile"], json!("adaptive"));
        assert_eq!(t["values"]["natural-scroll"], json!(true));
        assert_eq!(t["values"]["scroll-factor"], json!(0.5));

        // No touchpad: nothing supported, the page hides the card.
        let none = section(&[mouse()], Kind::Touchpad);
        assert_eq!(none["supported"], json!([]));
        assert_eq!(none["devices"], json!([]));
    }

    #[test]
    fn plans_map_niri_values() {
        let (p, c) = setting("accel-speed").unwrap().plan(&json!(0.2)).unwrap();
        assert_eq!(p, vec![("pointerAcceleration", PropValue::Double(0.2))]);
        assert_eq!(c, "0.200");
        let (p, c) = setting("accel-profile").unwrap().plan(&json!("flat")).unwrap();
        assert_eq!(p, vec![("pointerAccelerationProfileFlat", PropValue::Bool(true))]);
        assert_eq!(c, "1");
        let (p, c) = setting("accel-profile").unwrap().plan(&json!("adaptive")).unwrap();
        assert_eq!(p, vec![("pointerAccelerationProfileAdaptive", PropValue::Bool(true))]);
        assert_eq!(c, "2");
        let (p, c) = setting("tap").unwrap().plan(&json!(false)).unwrap();
        assert_eq!(p, vec![("tapToClick", PropValue::Bool(false))]);
        assert_eq!(c, "false");
        let (_, c) = setting("scroll-factor").unwrap().plan(&json!(1.5)).unwrap();
        assert_eq!(c, "1.5");

        assert!(setting("accel-speed").unwrap().plan(&json!(2)).is_err());
        assert!(setting("accel-profile").unwrap().plan(&json!("custom")).is_err());
        assert!(setting("dwt").unwrap().plan(&json!("yes")).is_err());
        assert!(setting("scroll-factor").unwrap().plan(&json!(0)).is_err());
    }

    #[test]
    fn device_batches_go_to_every_supporting_device() {
        let mut second = mouse();
        second.sys_name = "event6".into();
        second.props.insert("supportsMiddleEmulation".into(), json!(false));
        let devs = vec![mouse(), second, touchpad(), keyboard()];

        let b = json!({ "mouse": { "natural-scroll": true }, "touchpad": { "tap": false } });
        let w = plan_devices(&devs, b.as_object().unwrap()).unwrap();
        let got: Vec<(&str, &str)> = w.iter().map(|w| (w.device.sys_name.as_str(), w.setting.key)).collect();
        assert_eq!(got, vec![("event5", "natural-scroll"), ("event6", "natural-scroll"), ("event7", "tap")]);

        // Only the mouse that can emulate the middle button gets it.
        let b = json!({ "mouse": { "middle-emulation": false } });
        let w = plan_devices(&devs, b.as_object().unwrap()).unwrap();
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].device.sys_name, "event5");

        // A touchpad-only setting under mouse, an unknown section, a bad value: errors.
        for bad in [json!({ "mouse": { "tap": true } }), json!({ "pen": {} }), json!({ "mouse": { "accel-speed": "fast" } })] {
            assert!(plan_devices(&devs, bad.as_object().unwrap()).is_err(), "{bad}");
        }
        // The keyboard section isn't a device write.
        let b = json!({ "keyboard": { "layout": "us" } });
        assert!(plan_devices(&devs, b.as_object().unwrap()).unwrap().is_empty());
    }

    #[test]
    fn xkb_reads_kxkbrc() {
        assert_eq!(
            xkb_from_config("us,de", ",nodeadkeys", "caps:escape,compose:ralt", true, true),
            Xkb { layout: "us,de".into(), variant: ",nodeadkeys".into(), options: "caps:escape,compose:ralt".into() }
        );
        // Variants for layouts that are left, and empty trailing ones, drop.
        assert_eq!(xkb_from_config("us", "dvorak,,", "", true, true).variant, "dvorak");
        assert_eq!(xkb_from_config("us,de", ",", "", true, true).variant, "");
        // Use=false: KDE's layouts aren't configured, so the system's apply.
        assert_eq!(xkb_from_config("us,de", "", "", false, true), Xkb::default());
        // Options only replace the system's with ResetOldOptions.
        assert_eq!(xkb_from_config("us", "", "caps:escape", true, false).options, "");
    }

    #[test]
    fn xkb_writes_like_the_kcm() {
        let x = Xkb { layout: "us, de".into(), variant: "dvorak".into(), options: "caps:escape, ".into() };
        let e = xkb_entries(&x).unwrap();
        let get = |k: &str| e.iter().find(|(key, _)| *key == k).unwrap().1.clone();
        assert_eq!(get("LayoutList"), "us,de");
        assert_eq!(get("VariantList"), "dvorak,");
        assert_eq!(get("Use"), "true");
        assert_eq!(get("Options"), "caps:escape");
        assert_eq!(get("ResetOldOptions"), "true");

        let empty = xkb_entries(&Xkb::default()).unwrap();
        assert!(empty.contains(&("Use", "false".into())));
        assert!(empty.contains(&("LayoutList", String::new())));

        assert!(xkb_entries(&Xkb { layout: "us".into(), variant: "a,b".into(), ..Default::default() }).is_err());
        assert!(xkb_entries(&Xkb { layout: "us,,de".into(), ..Default::default() }).is_err());
        assert!(xkb_entries(&Xkb { layout: "us;rm -rf".into(), ..Default::default() }).is_err());
    }

    #[test]
    fn xkb_changes_merge() {
        let cur = Xkb { layout: "us".into(), variant: "".into(), options: "caps:escape".into() };
        let ch = json!({ "layout": " us,de " });
        let x = parse_xkb_change(&cur, ch.as_object().unwrap()).unwrap();
        assert_eq!(x.layout, "us,de");
        assert_eq!(x.options, "caps:escape");
        assert!(parse_xkb_change(&cur, json!({ "model": "pc105" }).as_object().unwrap()).is_err());
    }

    #[test]
    fn dbus_values_to_json() {
        let mut m = HashMap::new();
        m.insert("pointer".to_string(), OwnedValue::from(true));
        m.insert("vendor".to_string(), OwnedValue::from(1133u32));
        m.insert("pointerAcceleration".to_string(), OwnedValue::from(0.5f64));
        m.insert("name".to_string(), OwnedValue::try_from(ZValue::from("Mouse")).unwrap());
        let j = props_to_json(&m);
        assert_eq!(j["pointer"], json!(true));
        assert_eq!(j["vendor"], json!(1133));
        assert_eq!(j["pointerAcceleration"], json!(0.5));
        assert_eq!(j["name"], json!("Mouse"));
    }

    // A stand-in for KWin's InputDeviceManager and one libinput mouse, over a
    // peer-to-peer connection: the D-Bus half of `input` / `input set`
    // (nested KWins have no libinput devices to test against).
    struct FakeManager;

    #[zbus::interface(name = "org.kde.KWin.InputDeviceManager")]
    impl FakeManager {
        #[zbus(property, name = "devicesSysNames")]
        fn devices_sys_names(&self) -> Vec<String> {
            vec!["event5".into()]
        }
    }

    struct FakeMouse {
        accel: f64,
        natural: bool,
    }

    #[zbus::interface(name = "org.kde.KWin.InputDevice")]
    impl FakeMouse {
        #[zbus(property, name = "name")]
        fn name(&self) -> String {
            "Fake Mouse".into()
        }
        #[zbus(property, name = "sysName")]
        fn sys_name(&self) -> String {
            "event5".into()
        }
        #[zbus(property, name = "vendor")]
        fn vendor(&self) -> u32 {
            1133
        }
        #[zbus(property, name = "product")]
        fn product(&self) -> u32 {
            49271
        }
        #[zbus(property, name = "pointer")]
        fn pointer(&self) -> bool {
            true
        }
        #[zbus(property, name = "touchpad")]
        fn touchpad(&self) -> bool {
            false
        }
        #[zbus(property, name = "supportsPointerAcceleration")]
        fn supports_accel(&self) -> bool {
            true
        }
        #[zbus(property, name = "pointerAcceleration")]
        fn accel(&self) -> f64 {
            self.accel
        }
        #[zbus(property, name = "pointerAcceleration")]
        fn set_accel(&mut self, v: f64) {
            self.accel = v;
        }
        #[zbus(property, name = "supportsNaturalScroll")]
        fn supports_natural(&self) -> bool {
            true
        }
        #[zbus(property, name = "naturalScroll")]
        fn natural(&self) -> bool {
            self.natural
        }
        #[zbus(property, name = "naturalScroll")]
        fn set_natural(&mut self, v: bool) {
            self.natural = v;
        }
    }

    #[tokio::test]
    async fn devices_over_dbus() {
        let (a, b) = tokio::net::UnixStream::pair().unwrap();
        let guid = zbus::Guid::generate();
        let server = zbus::connection::Builder::unix_stream(a)
            .server(guid)
            .unwrap()
            .p2p()
            .serve_at(MANAGER_PATH, FakeManager)
            .unwrap()
            .serve_at(format!("{MANAGER_PATH}/event5"), FakeMouse { accel: 0.0, natural: false })
            .unwrap()
            .build();
        let client = zbus::connection::Builder::unix_stream(b).p2p().build();
        let (server, client) = tokio::join!(server, client);
        let (server, client) = (server.unwrap(), client.unwrap());

        let devs = devices(&client).await.unwrap().expect("a device manager");
        assert_eq!(devs.len(), 1);
        assert_eq!(devs[0].kind(), Some(Kind::Mouse));
        assert_eq!(devs[0].config_groups().unwrap()[1], "1133");
        let m = section(&devs, Kind::Mouse);
        assert_eq!(m["supported"], json!(["accel-speed", "natural-scroll"]));
        assert_eq!(m["values"]["natural-scroll"], json!(false));

        let batch = json!({ "mouse": { "accel-speed": -0.4, "natural-scroll": true } });
        let writes = plan_devices(&devs, batch.as_object().unwrap()).unwrap();
        assert_eq!(writes.len(), 2);
        for w in &writes {
            set_props(&client, w).await.unwrap();
        }
        let iface = server.object_server().interface::<_, FakeMouse>(format!("{MANAGER_PATH}/event5")).await.unwrap();
        assert_eq!(iface.get().await.accel, -0.4);
        assert!(iface.get().await.natural);

        let again = devices(&client).await.unwrap().unwrap();
        let m = section(&again, Kind::Mouse);
        assert_eq!(m["values"]["accel-speed"], json!(-0.4));
        assert_eq!(m["values"]["natural-scroll"], json!(true));
    }
}
