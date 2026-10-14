//! The runtime overrides store: `$STUDIO_STATE_DIR/overrides/niri.json`.
//!
//! Plain nested JSON mirroring niri's KDL names, so `studio save` can later
//! promote it into a consumer's config as data:
//!
//! ```json
//! {
//!   "input": { "mouse": { "accel-speed": 0.2 } },
//!   "layout": { "gaps": 8 },
//!   "outputs": {
//!     "Dell Inc. DELL U2720Q ABC123": { "mode": "3840x2160@59.997", "scale": 1.5,
//!                                        "position": { "x": 0, "y": 0 } }
//!   }
//! }
//! ```
//!
//! Outputs are keyed by niri's stable "Make Model Serial" identity, never the
//! connector name (connectors renumber across reboots and replugs).

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{Map, Value};

pub fn state_dir(explicit: Option<&Path>) -> PathBuf {
    if let Some(p) = explicit {
        return p.to_path_buf();
    }
    if let Some(v) = std::env::var_os("STUDIO_STATE_DIR").filter(|v| !v.is_empty()) {
        return PathBuf::from(v);
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::home_dir()
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(".local/state")
        });
    base.join("studio-linux")
}

#[derive(Debug, Clone)]
pub struct Paths {
    pub state: PathBuf,
    pub json: PathBuf,
    pub kdl: PathBuf,
}

impl Paths {
    pub fn new(state: PathBuf) -> Self {
        let dir = state.join("overrides");
        Paths {
            json: dir.join("niri.json"),
            kdl: dir.join("niri.kdl"),
            state,
        }
    }

    pub fn dir(&self) -> &Path {
        self.json.parent().unwrap()
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Overrides(pub Map<String, Value>);

impl Overrides {
    pub fn load(path: &Path) -> Result<Self> {
        match std::fs::read_to_string(path) {
            Ok(text) if text.trim().is_empty() => Ok(Self::default()),
            Ok(text) => {
                let v: Value = serde_json::from_str(&text)
                    .with_context(|| format!("parsing {}", path.display()))?;
                match v {
                    Value::Object(m) => Ok(Overrides(m)),
                    _ => anyhow::bail!("{}: expected a JSON object", path.display()),
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let mut text = serde_json::to_string_pretty(&Value::Object(self.0.clone()))?;
        text.push('\n');
        write_atomic(path, &text)
    }

    /// The value at a dotted key (`layout.struts.top`).
    pub fn get(&self, key: &str) -> Option<&Value> {
        let mut parts = key.split('.');
        let mut cur = self.0.get(parts.next()?)?;
        for p in parts {
            cur = cur.get(p)?;
        }
        Some(cur)
    }

    pub fn set(&mut self, key: &str, value: Value) {
        let parts: Vec<&str> = key.split('.').collect();
        let mut cur = &mut self.0;
        for p in &parts[..parts.len() - 1] {
            let e = cur
                .entry(p.to_string())
                .or_insert_with(|| Value::Object(Map::new()));
            if !e.is_object() {
                *e = Value::Object(Map::new());
            }
            cur = e.as_object_mut().unwrap();
        }
        cur.insert(parts[parts.len() - 1].to_string(), value);
    }

    /// Remove a dotted key or a whole section (`input`, `input.mouse`).
    /// Returns whether anything was removed.
    pub fn remove(&mut self, key: &str) -> bool {
        let parts: Vec<&str> = key.split('.').collect();
        let removed = remove_in(&mut self.0, &parts);
        prune(&mut self.0);
        removed
    }

    pub fn outputs(&self) -> Option<&Map<String, Value>> {
        self.0.get("outputs")?.as_object()
    }

    pub fn output_mut(&mut self, identity: &str) -> &mut Map<String, Value> {
        let outs = self
            .0
            .entry("outputs")
            .or_insert_with(|| Value::Object(Map::new()));
        if !outs.is_object() {
            *outs = Value::Object(Map::new());
        }
        let o = outs
            .as_object_mut()
            .unwrap()
            .entry(identity.to_string())
            .or_insert_with(|| Value::Object(Map::new()));
        if !o.is_object() {
            *o = Value::Object(Map::new());
        }
        o.as_object_mut().unwrap()
    }

    pub fn remove_output(&mut self, identity: &str) -> bool {
        let removed = self
            .0
            .get_mut("outputs")
            .and_then(Value::as_object_mut)
            .and_then(|m| {
                let k = m.keys().find(|k| k.eq_ignore_ascii_case(identity))?.clone();
                m.remove(&k)
            })
            .is_some();
        prune(&mut self.0);
        removed
    }

    pub fn prune(&mut self) {
        prune(&mut self.0);
    }
}

fn remove_in(m: &mut Map<String, Value>, parts: &[&str]) -> bool {
    match parts {
        [] => false,
        [last] => m.remove(*last).is_some(),
        [first, rest @ ..] => m
            .get_mut(*first)
            .and_then(Value::as_object_mut)
            .is_some_and(|sub| remove_in(sub, rest)),
    }
}

fn prune(m: &mut Map<String, Value>) {
    m.retain(|_, v| {
        if let Value::Object(sub) = v {
            prune(sub);
            !sub.is_empty()
        } else {
            true
        }
    });
}

/// Write via a temp file + rename, so readers never see a partial file.
pub fn write_atomic(path: &Path, text: &str) -> Result<()> {
    let dir = path.parent().context("path has no parent")?;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(
        ".{}.tmp-{}",
        path.file_name().unwrap().to_string_lossy(),
        std::process::id()
    ));
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn dotted_set_get_remove_prunes() {
        let mut o = Overrides::default();
        o.set("input.mouse.accel-speed", json!(0.2));
        o.set("layout.gaps", json!(8));
        o.output_mut("Dell Inc. DELL U2720Q ABC")
            .insert("scale".into(), json!(1.5));
        assert_eq!(o.get("input.mouse.accel-speed"), Some(&json!(0.2)));
        assert!(o.remove("input.mouse.accel-speed"));
        assert!(o.0.get("input").is_none(), "empty sections are pruned");
        assert!(o.remove_output("dell inc. dell u2720q abc"));
        assert_eq!(Value::Object(o.0), json!({ "layout": { "gaps": 8 } }));
    }
}
