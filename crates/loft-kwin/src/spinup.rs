//! Opening a Space's apps under KWin (docs/KWIN.md §4.15): the shell sends
//! `{"cmd": "openSpace", "space", "activity", "focus", "apps": [...]}` with
//! the apps `loft-niri space specs --displays` resolved (each with the
//! display its role is on). Here:
//!
//! - **find**: a window of the Space's Activity that matches the app
//!   (`match.appId` / `title` regexes and `cwd`, all that are given; with
//!   none, the app id ends in the command's name: `konsole` →
//!   `org.kde.konsole`). Each window counts once. A window on every
//!   Activity, or on another Space's, is never taken;
//! - **place**: a found window on another display moves to its role's
//!   (`moveToOutput`), as niri's spin-up moves it to its workspace;
//! - **start** what's missing (unless `launch` is off), in its own process
//!   group, and tell the script to expect its window (`expectWindow`: by
//!   pid, else app id, for 20 s): bridge.js puts it on the Activity and the
//!   display, and maximizes / fullscreens it, as it appears;
//! - an app started less than 20 s ago whose window hasn't shown up yet is
//!   not started again (two Opens in a row);
//! - answer `{"SpaceOpened": {space, apps: [{app, display, window, spawn}],
//!   notes}}`.
//!
//! The planning is pure ([`plan`]); spawning and the queue are main.rs's.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use regex::Regex;
use serde::Deserialize;
use serde_json::{Value, json};

/// How long the script waits for a started app's window.
pub const EXPECT_MS: u64 = 20_000;

#[derive(Debug, Clone, Default, Deserialize)]
pub struct MatchReq {
    #[serde(rename = "appId", default)]
    pub app_id: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
}

/// One app of `space specs`.
#[derive(Debug, Clone, Deserialize)]
pub struct AppReq {
    pub app: String,
    #[serde(default)]
    pub display: Option<String>,
    #[serde(default)]
    pub exec: Vec<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub launch: bool,
    #[serde(default)]
    pub open: String,
    #[serde(rename = "match", default)]
    pub matcher: MatchReq,
}

/// A window of the shell's state (crate::state's records).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Win {
    pub uuid: String,
    pub app_id: String,
    pub title: String,
    pub pid: i64,
    pub activities: Vec<String>,
    pub output: String,
    pub cwd: Option<PathBuf>,
}

/// The windows of a `State` (workspace → output), with each process's cwd
/// from `proc_root` when an app matches on it.
pub fn windows_from_state(state: &Value, proc_root: Option<&Path>) -> Vec<Win> {
    let outputs: std::collections::BTreeMap<u64, String> = state["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|w| Some((w["id"].as_u64()?, w["output"].as_str()?.to_string())))
        .collect();
    state["windows"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|w| {
            let pid = w["pid"].as_i64().unwrap_or(0);
            Win {
                uuid: w["kwin_uuid"].as_str().unwrap_or("").to_string(),
                app_id: w["app_id"].as_str().unwrap_or("").to_string(),
                title: w["title"].as_str().unwrap_or("").to_string(),
                pid,
                activities: w["kwin_activities"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|a| a.as_str().map(String::from))
                    .collect(),
                output: w["workspace_id"].as_u64().and_then(|id| outputs.get(&id).cloned()).unwrap_or_default(),
                cwd: proc_root.filter(|_| pid > 0).and_then(|r| std::fs::read_link(r.join(pid.to_string()).join("cwd")).ok()),
            }
        })
        .collect()
}

/// How an app recognizes its windows.
#[derive(Debug, Clone)]
pub struct Matcher {
    app_id: Option<Regex>,
    title: Option<Regex>,
    cwd: Option<PathBuf>,
    /// No `match`: the app id is the command's name, or ends in `.name`.
    guess: Option<String>,
}

impl Matcher {
    pub fn new(a: &AppReq) -> Result<Matcher, String> {
        let re = |k: &str, s: &Option<String>| -> Result<Option<Regex>, String> {
            match s.as_deref().filter(|s| !s.is_empty()) {
                None => Ok(None),
                Some(s) => Regex::new(s).map(Some).map_err(|e| format!("match.{k} `{s}`: {e}")),
            }
        };
        let app_id = re("appId", &a.matcher.app_id)?;
        let title = re("title", &a.matcher.title)?;
        let cwd = a.matcher.cwd.as_deref().filter(|s| !s.is_empty()).map(PathBuf::from);
        let guess = (app_id.is_none() && title.is_none() && cwd.is_none())
            .then(|| a.exec.first().map(|e| e.rsplit('/').next().unwrap_or(e).to_lowercase()))
            .flatten()
            .filter(|g| !g.is_empty());
        Ok(Matcher { app_id, title, cwd, guess })
    }

    pub fn matches(&self, w: &Win) -> bool {
        if let Some(g) = &self.guess {
            let id = w.app_id.to_lowercase();
            return id == *g || id.ends_with(&format!(".{g}"));
        }
        if self.app_id.is_none() && self.title.is_none() && self.cwd.is_none() {
            return false;
        }
        self.app_id.as_ref().is_none_or(|r| r.is_match(&w.app_id))
            && self.title.as_ref().is_none_or(|r| r.is_match(&w.title))
            && self.cwd.as_ref().is_none_or(|c| w.cwd.as_ref().is_some_and(|d| d.starts_with(c)))
    }

    /// The app-id pattern for the script's `expectWindow` (a JS RegExp:
    /// the documents' patterns are plain enough to mean the same there),
    /// and its flags.
    pub fn js_app_id(&self) -> Option<(String, &'static str)> {
        if let Some(g) = &self.guess {
            return Some((format!("(^|\\.){}$", regex::escape(g)), "i"));
        }
        self.app_id.as_ref().map(|r| (r.as_str().to_string(), ""))
    }

    pub fn js_title(&self) -> Option<String> {
        self.title.as_ref().map(|r| r.as_str().to_string())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    /// Open already; `move_to`: the display it should be on, if not there.
    Found { app: usize, uuid: String, move_to: Option<String> },
    Spawn { app: usize },
    /// Started a moment ago; its window is still coming.
    Starting { app: usize },
    /// Not open, and nothing to start it with.
    Missing { app: usize },
}

/// Which app is which window of `activity`, and what to start.
/// `starting`: apps (by name) started recently whose window isn't there.
pub fn plan(apps: &[AppReq], matchers: &[Option<Matcher>], wins: &[Win], activity: &str, starting: &BTreeSet<String>) -> Vec<Step> {
    let mut used: BTreeSet<&str> = BTreeSet::new();
    let mut steps = Vec::new();
    for (i, a) in apps.iter().enumerate() {
        let Some(m) = &matchers[i] else { continue };
        let mut cands: Vec<&Win> = wins
            .iter()
            .filter(|w| !used.contains(w.uuid.as_str()) && w.activities.iter().any(|x| x == activity) && m.matches(w))
            .collect();
        // One already on its display first.
        cands.sort_by_key(|w| a.display.as_deref() != Some(w.output.as_str()));
        if let Some(w) = cands.first() {
            used.insert(&w.uuid);
            let move_to = a.display.clone().filter(|d| !d.is_empty() && *d != w.output);
            steps.push(Step::Found { app: i, uuid: w.uuid.clone(), move_to });
        } else if starting.contains(&a.app) {
            steps.push(Step::Starting { app: i });
        } else if a.launch && !a.exec.is_empty() {
            steps.push(Step::Spawn { app: i });
        } else {
            steps.push(Step::Missing { app: i });
        }
    }
    steps
}

/// The script's `expectWindow` for a started app.
pub fn expect_cmd(a: &AppReq, m: &Matcher, activity: &str, pid: Option<u32>) -> Value {
    let (app_id, flags) = m.js_app_id().map_or((None, ""), |(p, f)| (Some(p), f));
    json!({
        "cmd": "expectWindow",
        "app": a.app,
        "activity": activity,
        "output": a.display,
        "pid": pid,
        "appId": app_id,
        "appIdFlags": flags,
        "title": m.js_title(),
        "open": a.open,
        "ttl": EXPECT_MS,
    })
}

/// Start an app in its own process group; its pid.
pub fn spawn(a: &AppReq) -> std::io::Result<u32> {
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new(&a.exec[0]);
    cmd.args(&a.exec[1..]);
    if let Some(d) = a.cwd.as_deref().filter(|d| Path::new(d).is_dir()) {
        cmd.current_dir(d);
    }
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
    let mut child = cmd.spawn()?;
    let pid = child.id();
    // Reap it whenever it exits (apps that hand off to a running instance).
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(pid)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(name: &str, display: &str, exec: &[&str], app_id: Option<&str>) -> AppReq {
        AppReq {
            app: name.into(),
            display: Some(display.into()),
            exec: exec.iter().map(|s| s.to_string()).collect(),
            cwd: None,
            launch: !exec.is_empty(),
            open: "normal".into(),
            matcher: MatchReq { app_id: app_id.map(String::from), ..Default::default() },
        }
    }

    fn win(uuid: &str, app_id: &str, activity: &str, output: &str) -> Win {
        Win {
            uuid: uuid.into(),
            app_id: app_id.into(),
            activities: if activity.is_empty() { vec![] } else { vec![activity.into()] },
            output: output.into(),
            ..Default::default()
        }
    }

    fn matchers(apps: &[AppReq]) -> Vec<Option<Matcher>> {
        apps.iter().map(|a| Matcher::new(a).ok()).collect()
    }

    #[test]
    fn finds_in_the_activity_starts_the_rest() {
        let apps = vec![
            app("kwrite", "WL-0", &["kwrite"], Some(r"^org\.kde\.kwrite$")),
            app("konsole", "WL-1", &["/nix/store/x/bin/konsole"], None),
            app("notes", "WL-0", &[], Some("^notes$")),
        ];
        let wins = vec![
            // KWrite of another Activity, and one on every Activity: not ours.
            win("{a}", "org.kde.kwrite", "other", "WL-0"),
            win("{b}", "org.kde.kwrite", "", "WL-0"),
            // Konsole here, on the wrong display: found, moved.
            win("{c}", "org.kde.konsole", "act", "WL-0"),
        ];
        let steps = plan(&apps, &matchers(&apps), &wins, "act", &BTreeSet::new());
        assert_eq!(
            steps,
            vec![
                Step::Spawn { app: 0 },
                Step::Found { app: 1, uuid: "{c}".into(), move_to: Some("WL-1".into()) },
                Step::Missing { app: 2 },
            ]
        );
    }

    #[test]
    fn a_window_counts_once_and_prefers_its_display() {
        let apps = vec![
            app("term", "WL-1", &["konsole"], None),
            app("term-2", "WL-0", &["konsole"], None),
            app("term-3", "WL-0", &["konsole"], None),
        ];
        let wins = vec![win("{x}", "org.kde.konsole", "act", "WL-0"), win("{y}", "org.kde.konsole", "act", "WL-1")];
        let started: BTreeSet<String> = ["term-3".to_string()].into();
        let steps = plan(&apps, &matchers(&apps), &wins, "act", &started);
        assert_eq!(
            steps,
            vec![
                Step::Found { app: 0, uuid: "{y}".into(), move_to: None },
                Step::Found { app: 1, uuid: "{x}".into(), move_to: None },
                Step::Starting { app: 2 },
            ]
        );
    }

    #[test]
    fn guessing_and_the_scripts_pattern() {
        let a = app("konsole", "WL-1", &["konsole", "--new-tab"], None);
        let m = Matcher::new(&a).unwrap();
        assert!(m.matches(&win("u", "org.kde.konsole", "", "")));
        assert!(m.matches(&win("u", "Konsole", "", "")));
        assert!(!m.matches(&win("u", "org.kde.konsolex", "", "")));
        assert_eq!(m.js_app_id(), Some((r"(^|\.)konsole$".into(), "i")));
        let cmd = expect_cmd(&a, &m, "act", Some(42));
        assert_eq!(cmd["output"], "WL-1");
        assert_eq!(cmd["pid"], 42);
        assert_eq!(cmd["appIdFlags"], "i");

        let b = app("kw", "WL-0", &["kwrite"], Some("[bad"));
        assert!(Matcher::new(&b).unwrap_err().contains("match.appId"));
    }

    #[test]
    fn windows_from_the_state() {
        let state = json!({
            "workspaces": [{"id": 1, "output": "WL-0"}, {"id": 2, "output": "WL-1"}],
            "windows": [{"kwin_uuid": "{u}", "app_id": "org.kde.kwrite", "title": "t", "pid": 0,
                         "workspace_id": 2, "kwin_activities": ["act"]}]
        });
        let w = windows_from_state(&state, None);
        assert_eq!(w[0].output, "WL-1");
        assert_eq!(w[0].activities, ["act"]);
    }
}
