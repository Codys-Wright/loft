//! Where windows open under KWin (docs/KWIN.md §4.17): Loft's window rules,
//! and the expected windows of `loft open` and of a Space's apps (`openSpace`,
//! §4.15). bridge.js does the placing; here:
//!
//! - **rules**: `loft-niri --json windows kwin-rules --displays …` turns the
//!   `window-rules` records (niri.json + the Nix seed) into what the script
//!   matches, with display roles resolved on KWin's outputs. Sent to the
//!   script as `setWindowRules` (with the Activities' names, which the script
//!   can't read: from activities.rs's report, the one the shell gets) at
//!   start, when the outputs or Activities change, when one of the rules'
//!   files changes (polled), and on `reloadWindowRules`;
//! - **expected windows**: `expectWindow` with `tree: true` (`loft open`,
//!   and openSpace for each app it starts) is kept here too. An Activity
//!   named that isn't there, or a display, is refused before anything
//!   starts (`dryRun`). The script places a window of the started pid as it
//!   maps; for every later state, a new window whose process descends from
//!   that pid, or (for `fallbackMs`) one of a process older than the start
//!   whose app id matches (an app that hands its window to a running
//!   instance), gets a `placeWindow`. A `loose` expectation (openSpace's)
//!   also lets the script take the first new window matching its app id /
//!   title, as a Space's apps always did.
//!
//! Matching is pure ([`Expect::matches`]); /proc and the queue are the
//! caller's.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use regex::Regex;
use serde_json::{Value, json};

/// How long an expectation waits for windows (`ttl` overrides it).
pub const EXPECT_MS: u64 = 30_000;
/// How long the app-id fallback counts.
pub const FALLBACK_MS: u64 = 10_000;

/// The placement keys an expectation passes on to the script.
const PLACE_KEYS: &[&str] =
    &["activity", "activityName", "desktop", "output", "open", "size", "position", "keepAbove", "follow"];

/// A process's parent and start time (clock ticks after boot), from
/// `/proc/PID/stat`.
pub fn proc_stat(root: &Path, pid: i64) -> Option<(i64, u64)> {
    let text = std::fs::read_to_string(root.join(pid.to_string()).join("stat")).ok()?;
    // `pid (comm) state ppid …`: comm may hold spaces and parens.
    let rest = &text[text.rfind(')')? + 1..];
    let f: Vec<&str> = rest.split_whitespace().collect();
    // After comm: state(0) ppid(1) … starttime is field 22 overall = index 19.
    Some((f.get(1)?.parse().ok()?, f.get(19)?.parse().ok()?))
}

/// Whether `pid` is `root` or descends from it.
pub fn descends(proc_root: &Path, pid: i64, root: i64) -> bool {
    let mut p = pid;
    for _ in 0..64 {
        if p == root {
            return true;
        }
        if p <= 1 {
            return false;
        }
        match proc_stat(proc_root, p) {
            Some((pp, _)) => p = pp,
            None => return false,
        }
    }
    false
}

/// One `loft open`: the windows of a started process tree.
#[derive(Debug, Clone)]
pub struct Expect {
    pub id: String,
    pub root: i64,
    /// The root's start time (ticks), to tell an older process (a running
    /// instance) from a new one.
    pub root_start: Option<u64>,
    pub app_id: Option<Regex>,
    /// openSpace's: the script may also take a new window by app id / title
    /// (`appId`, `appIdFlags`, `title` passed on).
    pub loose: Option<(Option<String>, String, Option<String>)>,
    /// What the script gets: the placement keys.
    pub place: serde_json::Map<String, Value>,
    pub since: Instant,
    pub ttl: Duration,
    pub fallback: Duration,
    /// Windows there before it started (never taken).
    pub before: BTreeSet<String>,
    pub placed: BTreeSet<String>,
    /// Windows to place (0 = every one until ttl).
    pub count: usize,
}

/// An Activity of activities.rs's report, as far as naming goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivityName {
    pub id: String,
    pub name: String,
}

/// The Activities of an `{"Activities": {"activities": [{id, name, …}]}}` report.
pub fn activities_of(report: &Value) -> Vec<ActivityName> {
    report["Activities"]["activities"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|a| Some(ActivityName { id: a["id"].as_str()?.to_string(), name: a["name"].as_str().unwrap_or("").to_string() }))
        .collect()
}

/// id → name, for the script.
pub fn names_by_id(list: &[ActivityName]) -> BTreeMap<String, String> {
    list.iter().map(|a| (a.id.clone(), a.name.clone())).collect()
}

/// A name as the script compares them: case, spaces, `-` and `_` ignored.
pub fn norm_name(s: &str) -> String {
    s.chars().filter(|c| !c.is_whitespace() && *c != '-' && *c != '_').flat_map(char::to_lowercase).collect()
}

/// An Activity by id or (loosely) by name.
pub fn find_activity<'a>(want: &str, list: &'a [ActivityName]) -> Option<&'a ActivityName> {
    let n = norm_name(want);
    list.iter().find(|a| a.id == want).or_else(|| list.iter().find(|a| norm_name(&a.name) == n))
}

/// The roles, plus every output of the state as a connector (so a connector
/// is known even when loft-niri's rules couldn't be read).
pub fn with_outputs(roles: &BTreeMap<String, Vec<String>>, state: &Value) -> BTreeMap<String, Vec<String>> {
    let mut out = roles.clone();
    for o in state["outputs"].as_array().into_iter().flatten() {
        if let Some(n) = o["name"].as_str().filter(|n| !n.is_empty()) {
            out.entry(n.to_string()).or_default();
        }
    }
    out
}

/// A window of the state, as far as matching goes.
#[derive(Debug, Clone, PartialEq)]
pub struct Win {
    pub uuid: String,
    pub app_id: String,
    pub pid: i64,
}

pub fn windows_of(state: &Value) -> Vec<Win> {
    state["windows"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|w| Win {
            uuid: w["kwin_uuid"].as_str().unwrap_or("").to_string(),
            app_id: w["app_id"].as_str().unwrap_or("").to_string(),
            pid: w["pid"].as_i64().unwrap_or(0),
        })
        .filter(|w| !w.uuid.is_empty())
        .collect()
}

/// How a window relates to the started process.
pub trait Procs {
    fn descends(&self, pid: i64, root: i64) -> bool;
    fn start(&self, pid: i64) -> Option<u64>;
}

pub struct RealProcs(pub PathBuf);

impl Procs for RealProcs {
    fn descends(&self, pid: i64, root: i64) -> bool {
        descends(&self.0, pid, root)
    }
    fn start(&self, pid: i64) -> Option<u64> {
        proc_stat(&self.0, pid).map(|(_, s)| s)
    }
}

impl Expect {
    /// From the command (`expectWindow` with `tree`), the current windows,
    /// roles (an `output` that is a role becomes its connector) and
    /// Activities (an `activityName` must be one; empty = not known, any
    /// name passes and the script decides).
    pub fn new(
        cmd: &Value,
        now_windows: &[Win],
        roles: &BTreeMap<String, Vec<String>>,
        activities: &[ActivityName],
        procs: &dyn Procs,
    ) -> Result<Expect, String> {
        let root = cmd["pid"].as_i64().filter(|p| *p > 1).ok_or("expectWindow: no pid")?;
        let app_id = match cmd["appId"].as_str().filter(|s| !s.is_empty()) {
            Some(s) => {
                let flags = cmd["appIdFlags"].as_str().unwrap_or("");
                let src = if flags.contains('i') { format!("(?i){s}") } else { s.to_string() };
                Some(Regex::new(&src).map_err(|e| format!("appId `{s}`: {e}"))?)
            }
            None => None,
        };
        let mut place = serde_json::Map::new();
        for k in PLACE_KEYS {
            if let Some(v) = cmd.get(*k).filter(|v| !v.is_null()) {
                place.insert((*k).to_string(), v.clone());
            }
        }
        if let Some(o) = place.get("output").and_then(Value::as_str).map(str::to_string) {
            match resolve_output(&o, roles) {
                Some(c) => drop(place.insert("output".into(), json!(c))),
                None => return Err(format!("no display is `{o}` now (displays: {})", describe_roles(roles))),
            }
        }
        if let Some(n) = place.get("activityName").and_then(Value::as_str).filter(|n| !n.is_empty())
            && !activities.is_empty()
            && find_activity(n, activities).is_none()
        {
            let mut have: Vec<&str> = activities.iter().map(|a| a.name.as_str()).collect();
            have.sort_unstable();
            return Err(format!("no KDE Activity named {n:?} (Activities: {})", have.join(", ")));
        }
        let str_of = |k: &str| cmd[k].as_str().filter(|s| !s.is_empty()).map(String::from);
        let loose = (cmd["loose"] == true)
            .then(|| (str_of("appId"), cmd["appIdFlags"].as_str().unwrap_or("").to_string(), str_of("title")));
        let ms = |k: &str, d: u64| Duration::from_millis(cmd[k].as_u64().unwrap_or(d));
        Ok(Expect {
            id: cmd["id"].as_str().unwrap_or("").to_string(),
            root,
            root_start: procs.start(root),
            app_id,
            loose,
            place,
            since: Instant::now(),
            ttl: ms("ttl", EXPECT_MS),
            fallback: ms("fallbackMs", FALLBACK_MS),
            before: now_windows.iter().filter(|w| !procs.descends(w.pid, root)).map(|w| w.uuid.clone()).collect(),
            placed: BTreeSet::new(),
            count: cmd["count"].as_u64().unwrap_or(0) as usize,
        })
    }

    pub fn expired(&self, now: Instant) -> bool {
        now.duration_since(self.since) >= self.ttl || (self.count > 0 && self.placed.len() >= self.count)
    }

    /// Whether `w` is one of this process's new windows.
    pub fn matches(&self, w: &Win, now: Instant, procs: &dyn Procs) -> bool {
        if self.before.contains(&w.uuid) || self.placed.contains(&w.uuid) || w.pid <= 0 {
            return false;
        }
        if procs.descends(w.pid, self.root) {
            return true;
        }
        // A running instance took the request: its process is older than
        // ours. A new, unrelated one (you opened the app yourself) isn't.
        let older = match (procs.start(w.pid), self.root_start) {
            (Some(a), Some(b)) => a < b,
            _ => false,
        };
        older && now.duration_since(self.since) < self.fallback && self.app_id.as_ref().is_some_and(|r| r.is_match(&w.app_id))
    }

    /// The script's command for a window.
    pub fn place_cmd(&self, uuid: &str) -> Value {
        let mut m = self.place.clone();
        m.insert("cmd".into(), json!("placeWindow"));
        m.insert("window".into(), json!(uuid));
        m.insert("id".into(), json!(self.id));
        Value::Object(m)
    }

    /// The script's own `expectWindow`: the pid (its app id / title too when
    /// `loose`); the process tree is ours.
    pub fn script_cmd(&self) -> Value {
        let mut m = self.place.clone();
        m.insert("cmd".into(), json!("expectWindow"));
        m.insert("id".into(), json!(self.id));
        m.insert("pid".into(), json!(self.root));
        m.insert("count".into(), json!(self.count));
        m.insert("ttl".into(), json!(self.ttl.as_millis() as u64));
        if let Some((app_id, flags, title)) = &self.loose {
            m.insert("appId".into(), json!(app_id));
            m.insert("appIdFlags".into(), json!(flags));
            m.insert("title".into(), json!(title));
        }
        Value::Object(m)
    }
}

/// A role (`right`, `main`, `display-2`) → its connector; a connector as is.
pub fn resolve_output(target: &str, roles: &BTreeMap<String, Vec<String>>) -> Option<String> {
    if target.is_empty() || roles.contains_key(target) {
        return Some(target.to_string());
    }
    if let Some((c, _)) = roles.iter().find(|(c, _)| c.eq_ignore_ascii_case(target)) {
        return Some(c.clone());
    }
    roles.iter().find(|(_, rs)| rs.iter().any(|r| r == target)).map(|(c, _)| c.clone())
}

pub fn describe_roles(roles: &BTreeMap<String, Vec<String>>) -> String {
    if roles.is_empty() {
        return "none known".into();
    }
    roles.iter().map(|(c, rs)| format!("{c}: {}", rs.join(" "))).collect::<Vec<_>>().join(", ")
}

/// `--displays` for loft-niri, from the state's outputs.
pub fn displays_arg(state: &Value) -> String {
    let ds: Vec<Value> = state["outputs"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|o| json!({ "name": o["name"], "identity": o["identity"], "geometry": o["geometry"] }))
        .collect();
    Value::Array(ds).to_string()
}

/// What decides whether the rules need sending again: the outputs' names
/// and geometry, and the Activities.
pub fn layout_key(state: &Value) -> String {
    let outs: Vec<String> = state["outputs"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|o| format!("{}:{}", o["name"], o["geometry"]))
        .collect();
    format!("{}|{}", outs.join(","), state["activities"])
}

/// The rules' files' modification times (missing = None).
pub fn mtimes(paths: &[PathBuf]) -> Vec<Option<SystemTime>> {
    paths.iter().map(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok()).collect()
}

/// `loft-niri windows kwin-rules`: `{rules, roles, sources}`.
pub async fn fetch_rules(displays: &str) -> Result<Value, String> {
    let bin = std::env::var("LOFT_NIRI").unwrap_or_else(|_| "loft-niri".into());
    let out = tokio::process::Command::new(&bin)
        .args(["--json", "windows", "kwin-rules", "--displays", displays])
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .map_err(|e| format!("running {bin}: {e}"))?;
    let v: Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("{bin} windows kwin-rules: {e}: {}", String::from_utf8_lossy(&out.stderr).trim()))?;
    if v["ok"] == false {
        return Err(v["error"].as_str().unwrap_or("loft-niri failed").to_string());
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// pid → (ppid, start).
    struct Fake(BTreeMap<i64, (i64, u64)>);

    impl Procs for Fake {
        fn descends(&self, pid: i64, root: i64) -> bool {
            let mut p = pid;
            while p > 1 {
                if p == root {
                    return true;
                }
                p = self.0.get(&p).map_or(0, |x| x.0);
            }
            false
        }
        fn start(&self, pid: i64) -> Option<u64> {
            self.0.get(&pid).map(|x| x.1)
        }
    }

    fn win(uuid: &str, app: &str, pid: i64) -> Win {
        Win { uuid: uuid.into(), app_id: app.into(), pid }
    }

    fn roles() -> BTreeMap<String, Vec<String>> {
        BTreeMap::from([
            ("WL-0".to_string(), vec!["main".to_string(), "landscape".into(), "display-1".into(), "*".into()]),
            ("WL-1".to_string(), vec!["right".to_string(), "landscape".into(), "display-2".into(), "*".into()]),
        ])
    }

    #[test]
    fn tree_and_running_instance() {
        // 100: an old konsole; 200: the one we started (systemd-run → konsole),
        // 201 its child; 300: a konsole you start yourself later.
        let procs = Fake(BTreeMap::from([(100, (1, 10)), (200, (1, 50)), (201, (200, 51)), (300, (1, 60))]));
        let before = [win("{a}", "org.kde.konsole", 100)];
        let cmd = json!({ "cmd": "expectWindow", "tree": true, "id": "o1", "pid": 200, "output": "right",
                          "desktop": 2, "activityName": "Coding", "size": { "w": { "px": 1200 }, "h": { "px": 800 } },
                          "appId": "(^|\\.)konsole$", "appIdFlags": "i" });
        let e = Expect::new(&cmd, &before, &roles(), &[], &procs).unwrap();
        assert_eq!(e.place["output"], "WL-1");
        let now = e.since;
        assert!(!e.matches(&before[0], now, &procs), "there before");
        assert!(e.matches(&win("{b}", "org.kde.konsole", 200), now, &procs));
        assert!(e.matches(&win("{c}", "anything", 201), now, &procs));
        assert!(!e.matches(&win("{d}", "org.kde.konsole", 300), now, &procs), "a newer, unrelated konsole");
        // The old instance opening a new window for us, within the fallback.
        assert!(e.matches(&win("{e}", "org.kde.konsole", 100), now, &procs));
        assert!(!e.matches(&win("{e}", "org.kde.konsole", 100), now + Duration::from_secs(11), &procs));
        let c = e.place_cmd("{b}");
        assert_eq!(c["cmd"], "placeWindow");
        assert_eq!(c["desktop"], 2);
        assert_eq!(c["activityName"], "Coding");
        assert_eq!(e.script_cmd()["pid"], 200);
    }

    #[test]
    fn bad_display_and_pid() {
        let procs = Fake(BTreeMap::new());
        let err = Expect::new(&json!({ "pid": 5, "output": "left" }), &[], &roles(), &[], &procs).unwrap_err();
        assert!(err.contains("no display is `left`"), "{err}");
        assert!(Expect::new(&json!({ "output": "WL-0" }), &[], &roles(), &[], &procs).is_err());
        assert_eq!(resolve_output("wl-1", &roles()).as_deref(), Some("WL-1"));
        assert_eq!(resolve_output("main", &roles()).as_deref(), Some("WL-0"));
    }

    fn acts() -> Vec<ActivityName> {
        activities_of(&json!({ "Activities": { "activities": [
            { "id": "a-def", "name": "Default", "icon": "", "key": "Meta+1", "position": 1 },
            { "id": "a-code", "name": "Coding", "icon": "", "key": "Meta+3", "position": 3 },
            { "id": "a-sun", "name": "Sunday Set", "icon": "", "key": "", "position": null },
        ], "current": "a-def" } }))
    }

    #[test]
    fn activities_by_name_from_the_report() {
        let procs = Fake(BTreeMap::new());
        let a = acts();
        assert_eq!(names_by_id(&a)["a-code"], "Coding");
        assert_eq!(find_activity("coding", &a).map(|x| x.id.as_str()), Some("a-code"));
        assert_eq!(find_activity("sunday_set", &a).map(|x| x.id.as_str()), Some("a-sun"));
        assert_eq!(find_activity("a-def", &a).map(|x| x.name.as_str()), Some("Default"));
        let ok = Expect::new(&json!({ "pid": 5, "activityName": "CODING" }), &[], &roles(), &a, &procs);
        assert!(ok.is_ok());
        let err = Expect::new(&json!({ "pid": 5, "activityName": "Gaming" }), &[], &roles(), &a, &procs).unwrap_err();
        assert_eq!(err, r#"no KDE Activity named "Gaming" (Activities: Coding, Default, Sunday Set)"#);
        // Activities not known yet: the script decides.
        assert!(Expect::new(&json!({ "pid": 5, "activityName": "Gaming" }), &[], &roles(), &[], &procs).is_ok());
    }

    #[test]
    fn loose_passes_the_match_on_and_outputs_are_known() {
        let procs = Fake(BTreeMap::from([(9, (1, 1))]));
        let st = json!({ "outputs": [{ "name": "WL-2" }] });
        let r = with_outputs(&BTreeMap::new(), &st);
        let cmd = json!({ "pid": 9, "loose": true, "appId": "^kw$", "appIdFlags": "i", "title": "x", "output": "WL-2", "count": 1 });
        let e = Expect::new(&cmd, &[], &r, &[], &procs).unwrap();
        let s = e.script_cmd();
        assert_eq!((s["appId"].as_str(), s["appIdFlags"].as_str(), s["title"].as_str()), (Some("^kw$"), Some("i"), Some("x")));
        assert_eq!(s["output"], "WL-2");
        let strict = Expect::new(&json!({ "pid": 9, "appId": "^kw$" }), &[], &r, &[], &procs).unwrap();
        assert!(strict.script_cmd().get("appId").is_none());
    }

    #[test]
    fn count_and_ttl() {
        let procs = Fake(BTreeMap::from([(7, (1, 1))]));
        let mut e = Expect::new(&json!({ "pid": 7, "count": 1, "ttl": 1000 }), &[], &roles(), &[], &procs).unwrap();
        assert!(!e.expired(e.since));
        e.placed.insert("{x}".into());
        assert!(e.expired(e.since));
        e.count = 0;
        assert!(!e.expired(e.since));
        assert!(e.expired(e.since + Duration::from_secs(2)));
    }

    #[test]
    fn proc_stat_parses_odd_names() {
        let d = std::env::temp_dir().join(format!("loft-kwin-proc-{}", std::process::id()));
        std::fs::create_dir_all(d.join("42")).unwrap();
        std::fs::write(d.join("42/stat"), "42 (a (b) c) S 7 42 42 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 12345 0 0").unwrap();
        assert_eq!(proc_stat(&d, 42), Some((7, 12345)));
        assert!(descends(&d, 42, 42));
        assert!(!descends(&d, 42, 9));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn displays_and_layout() {
        let st = json!({ "outputs": [{ "name": "WL-0", "identity": "X", "geometry": [0, 0, 10, 10], "scale": 1 }],
                         "activities": ["a"] });
        assert_eq!(displays_arg(&st), r#"[{"geometry":[0,0,10,10],"identity":"X","name":"WL-0"}]"#);
        assert_eq!(layout_key(&st), r#""WL-0":[0,0,10,10]|["a"]"#);
    }
}
