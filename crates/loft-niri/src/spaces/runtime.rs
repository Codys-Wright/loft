//! `<state>/spaces/runtime.json`: what the spaces know about the running
//! session (SPACES.md §4, §7).
//!
//! ```json
//! { "version": 1,
//!   "session": "<boot id>:<niri socket>",
//!   "claims": { "42": { "space": "proj-loft", "app": "editor" } },
//!   "opened": ["proj-loft"],
//!   "active": "proj-loft",
//!   "memory": { "music": { "keep": { "niri headless 1": "comms" } } } }
//! ```
//!
//! - **claims**: window id → the space instance and app that own it, so two
//!   instances of one template never take each other's windows. niri's
//!   window ids only mean something inside one niri process, so claims (and
//!   `opened`) belong to a **session** (boot id + niri's socket path, which
//!   carries niri's pid) and are dropped when it changes.
//! - **opened**: spaces spun up in this session (`startup:
//!   "first-activate"` runs once per session: after a reboot or a niri
//!   restart the workspaces come back and apps start on the first
//!   activation, §12.4).
//! - **memory**: per space, what each `keep` display (by identity) showed
//!   when the space was activated, so activating the active space again
//!   brings those displays back (§3.1). It outlives sessions: workspace
//!   names are stable.
//!
//! Writers merge under a lock (`runtime.lock`): read, change, write
//! atomically. Nothing waits on a window while holding it.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::state::write_atomic;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Claim {
    pub space: String,
    pub app: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpaceMemory {
    /// Display identity → the workspace it showed.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub keep: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Runtime {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub claims: BTreeMap<u64, Claim>,
    #[serde(default)]
    pub opened: BTreeSet<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<String>,
    #[serde(default)]
    pub memory: BTreeMap<String, SpaceMemory>,
}

impl Runtime {
    /// Start a new session: claims and `opened` are niri-process scoped.
    pub fn enter(&mut self, session: &str) {
        if self.session != session {
            self.session = session.to_string();
            self.claims.clear();
            self.opened.clear();
            self.active = None;
        }
        self.version = 1;
    }

    /// Drop claims on windows that are gone.
    pub fn prune(&mut self, alive: &BTreeSet<u64>) {
        self.claims.retain(|id, _| alive.contains(id));
    }

    /// The claims of one space: window → app.
    pub fn claims_of(&self, space: &str) -> BTreeMap<u64, String> {
        self.claims
            .iter()
            .filter(|(_, c)| c.space == space)
            .map(|(w, c)| (*w, c.app.clone()))
            .collect()
    }

    /// Replace one space's claims.
    pub fn set_claims(&mut self, space: &str, claims: &BTreeMap<u64, String>) {
        self.claims.retain(|_, c| c.space != space);
        for (w, app) in claims {
            self.claims.insert(
                *w,
                Claim {
                    space: space.to_string(),
                    app: app.clone(),
                },
            );
        }
    }

    pub fn forget(&mut self, space: &str) {
        self.claims.retain(|_, c| c.space != space);
        self.opened.remove(space);
    }
}

/// `<boot id>:<niri socket>`: claims are only valid inside this.
pub fn session_key() -> String {
    let boot = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let sock = std::env::var(niri_ipc::socket::SOCKET_PATH_ENV).unwrap_or_default();
    format!("{boot}:{sock}")
}

pub fn path(state_dir: &Path) -> PathBuf {
    state_dir.join("spaces/runtime.json")
}

/// Read (a missing or broken file is an empty runtime).
pub fn load(state_dir: &Path) -> Runtime {
    std::fs::read_to_string(path(state_dir))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// Read, change, write, under `runtime.lock`; the session is entered first.
pub fn update<T>(state_dir: &Path, session: &str, f: impl FnOnce(&mut Runtime) -> T) -> Result<T> {
    let p = path(state_dir);
    let dir = p.parent().unwrap();
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let lock = File::create(dir.join("runtime.lock"))?;
    lock.lock().context("locking runtime.json")?;
    let mut rt = load(state_dir);
    rt.enter(session);
    let before = rt.clone();
    let out = f(&mut rt);
    if rt != before || !p.exists() {
        write_atomic(&p, &(serde_json::to_string_pretty(&rt)? + "\n"))?;
    }
    drop(lock);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_session_drops_claims_but_keeps_memory() {
        let d = crate::config::tests_support::scratch("spaces-runtime");
        update(&d, "boot:a", |rt| {
            rt.set_claims("proj-loft", &BTreeMap::from([(7, "editor".to_string())]));
            rt.opened.insert("proj-loft".into());
            rt.memory
                .entry("music".into())
                .or_default()
                .keep
                .insert("niri headless 1".into(), "comms".into());
        })
        .unwrap();
        let text = std::fs::read_to_string(path(&d)).unwrap();
        assert!(text.contains("\"7\""), "{text}");
        // Same session: everything is there.
        let rt = update(&d, "boot:a", |rt| rt.clone()).unwrap();
        assert_eq!(
            rt.claims_of("proj-loft"),
            BTreeMap::from([(7, "editor".into())])
        );
        assert!(rt.opened.contains("proj-loft"));
        // niri restarted: window ids are meaningless now.
        let rt = update(&d, "boot:b", |rt| rt.clone()).unwrap();
        assert!(rt.claims.is_empty() && rt.opened.is_empty());
        assert_eq!(rt.memory["music"].keep["niri headless 1"], "comms");
    }

    #[test]
    fn set_claims_only_touches_one_space() {
        let mut rt = Runtime::default();
        rt.set_claims(
            "a",
            &BTreeMap::from([(1, "x".to_string()), (2, "y".to_string())]),
        );
        rt.set_claims("b", &BTreeMap::from([(3, "x".to_string())]));
        rt.set_claims("a", &BTreeMap::from([(2, "y".to_string())]));
        assert_eq!(rt.claims.len(), 2);
        assert_eq!(rt.claims[&3].space, "b");
        rt.prune(&BTreeSet::from([3]));
        assert_eq!(rt.claims.keys().copied().collect::<Vec<_>>(), [3]);
        rt.forget("b");
        assert!(rt.claims.is_empty());
    }
}
