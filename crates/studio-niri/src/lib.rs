//! studio-niri: the niri settings backend of studio-linux.
//!
//! Runtime niri settings changed in Studio Settings are stored as JSON in
//! `$STUDIO_STATE_DIR/overrides/niri.json` and rendered into
//! `overrides/niri.kdl`, which the studio sessions include (see `render` for
//! where and why). The user's own KDL is never edited.

pub mod binds;
pub mod config;
pub mod ipc;
pub mod kdl_out;
pub mod keys;
pub mod outputs;
pub mod render;
pub mod state;

use std::path::Path;

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value, json};

use crate::config::ConfigTree;
use crate::outputs::OutputChange;
use crate::render::{RenderOpts, RenderResult};
use crate::state::{Overrides, Paths};

/// Live outputs when niri is reachable.
pub fn live_outputs() -> Option<outputs::Outputs> {
    ipc::available().then(ipc::outputs).and_then(Result::ok)
}

/// Every managed setting: effective value and where it comes from.
pub fn show(paths: &Paths, entry: Option<&Path>) -> Result<Value> {
    let ov = Overrides::load(&paths.json)?;
    let tree = render::base_tree(entry, paths);
    let mut keys = Map::new();
    for def in keys::KEYS {
        let mut d = def.describe();
        let (cfg, at) = match &tree {
            Some(t) => {
                let c = keys::config_value(t, def);
                (
                    c.value,
                    c.node
                        .map(|n| (n.file.path.display().to_string(), n.line())),
                )
            }
            None => (def.default_value(), None),
        };
        let ovv = ov.get(def.key).and_then(|v| def.parse(v).ok());
        d["config"] = cfg.clone();
        d["source"] = json!(match (&ovv, &at) {
            (Some(_), _) => "override",
            (None, Some(_)) => "config",
            (None, None) => "default",
        });
        if let Some((file, line)) = at {
            d["file"] = json!(file);
            d["line"] = json!(line);
        }
        d["override"] = ovv.clone().unwrap_or(Value::Null);
        d["value"] = ovv.unwrap_or(cfg);
        keys.insert(def.key.to_string(), d);
    }
    Ok(json!({
        "state_dir": paths.state,
        "overrides_json": paths.json,
        "overrides_kdl": paths.kdl,
        "config": tree.as_ref().map(|t| t.entry.clone()),
        "config_errors": tree.as_ref().map(|t| t.errors.clone()).unwrap_or_default(),
        "keys": keys,
        "outputs": ov.outputs().cloned().unwrap_or_default(),
        "overrides": Value::Object(ov.0.clone()),
    }))
}

/// A batch of changes — what the shell sends (`studio-niri apply DATA`):
///
/// ```json
/// { "outputs": { "<identity|connector>": { "mode": "2560x1440@143.912", "scale": 1.25,
///                "position": { "x": 0, "y": 0 }, "transform": "90", "vrr": true, "off": false } },
///   "set":   { "layout.gaps": 8 },
///   "unset": [ "input.mouse" ],
///   "reset_outputs": [ "<identity>" ],
///   "window_rules": { "<app-id>": { "open-on-workspace": "Desktop 2" } | null },
///   "live": true, "record": true, "render": true }
/// ```
#[derive(Debug, Clone, Copy)]
pub struct ApplyOpts<'a> {
    pub entry: Option<&'a Path>,
    pub validate: bool,
    pub reload: bool,
}

pub fn apply(paths: &Paths, data: &Value, opts: ApplyOpts) -> Result<Value> {
    let live = data.get("live").and_then(Value::as_bool).unwrap_or(true);
    let record = data.get("record").and_then(Value::as_bool).unwrap_or(true);
    let do_render = data
        .get("render")
        .and_then(Value::as_bool)
        .unwrap_or(record);
    let prev = Overrides::load(&paths.json)?;
    let mut ov = prev.clone();
    let live_outs = live_outputs();
    let mut applied = Vec::new();

    if let Some(outs) = data.get("outputs").and_then(Value::as_object) {
        for (target, change) in outs {
            let change = OutputChange::from_json(change)?;
            let found = live_outs.as_ref().and_then(|l| outputs::find(l, target));
            if live {
                match found {
                    Some(o) => {
                        ipc::apply_output(&o.name, change.actions()?)?;
                        applied.push(o.name.clone());
                    }
                    None if !record => bail!("no live output matches `{target}`"),
                    None => {}
                }
            }
            if record {
                let id = found
                    .map(outputs::identity)
                    .unwrap_or_else(|| target.clone());
                change.record(ov.output_mut(&id))?;
            }
        }
    }
    if record {
        if let Some(set) = data.get("set").and_then(Value::as_object) {
            for (k, v) in set {
                let def = keys::find(k)?;
                ov.set(def.key, def.parse(v)?);
            }
        }
        for k in data
            .get("unset")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(k) = k.as_str() {
                ov.remove(k);
            }
        }
        // The dock's Assign To: whole records replaced, null removes.
        for (section, field) in [
            ("window-rules", "window_rules"),
            ("workspaces", "workspaces"),
        ] {
            if let Some(m) = data.get(field).and_then(Value::as_object) {
                for (k, v) in m {
                    match v {
                        Value::Object(_) => {
                            let sec =
                                ov.0.entry(section)
                                    .or_insert_with(|| Value::Object(Map::new()));
                            if !sec.is_object() {
                                *sec = Value::Object(Map::new());
                            }
                            sec.as_object_mut().unwrap().insert(k.clone(), v.clone());
                        }
                        Value::Null => {
                            if let Some(sec) = ov.0.get_mut(section).and_then(Value::as_object_mut)
                            {
                                sec.remove(k);
                            }
                        }
                        _ => bail!("{field}.{k}: expected an object or null"),
                    }
                }
            }
        }
        for id in data
            .get("reset_outputs")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(id) = id.as_str() {
                ov.remove_output(id);
            }
        }
    }
    ov.prune();
    let rendered = if record {
        commit(paths, &prev, &ov, do_render, opts)?
    } else {
        false
    };
    Ok(json!({ "ok": true, "applied_live": applied, "rendered": rendered }))
}

/// Save the new overrides and (optionally) render them; if niri rejects the
/// rendered fragment, put the previous overrides back.
pub fn commit(
    paths: &Paths,
    prev: &Overrides,
    new: &Overrides,
    render: bool,
    opts: ApplyOpts,
) -> Result<bool> {
    if new != prev || !paths.json.exists() {
        new.save(&paths.json)?;
    }
    if !render {
        return Ok(false);
    }
    let live = live_outputs();
    let res = render::render_to_disk(
        paths,
        &RenderOpts {
            entry: opts.entry,
            validate: opts.validate,
            reload: opts.reload,
            live: live.as_ref(),
        },
    );
    match res {
        Ok(RenderResult::Written) => Ok(true),
        Ok(RenderResult::Unchanged) => Ok(false),
        Err(e) => {
            prev.save(&paths.json)
                .context("restoring the previous overrides")?;
            Err(e)
        }
    }
}

pub fn load_tree(entry: Option<&Path>) -> Result<ConfigTree> {
    let entry = entry.context(
        "no niri config found (pass --config, or set $STUDIO_NIRI_CONFIG / $NIRI_CONFIG)",
    )?;
    ConfigTree::load(entry, &|_| false)
}
