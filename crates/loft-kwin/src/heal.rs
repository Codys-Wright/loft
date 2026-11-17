//! Self-healing KWin scripts (docs/KWIN.md §4.18).
//!
//! While loft-kwin runs (= while Loft's shell runs under KWin), two KWin
//! scripts must be loaded and running: our `loft-bridge` (bridge.js) and
//! `loft-keys`, Loft's shortcuts (cli/loft/kwinkeys.py, loaded by the shell
//! unit's `loft-plasma-shortcuts load`). Either can go missing: KWin
//! restarted (`kwin_wayland --replace`, a crash), something unloaded it, or
//! it was loaded but never started (the reused-id bug of #57). Every CHECK
//! this task looks and puts back what's gone, at most once per MIN_GAP per
//! script, one stderr line per heal.
//!
//! - loft-bridge: gone when KWin says it isn't loaded, or when it stopped
//!   long-polling NextCommands (no poll in flight and none for STALE): we
//!   unload and load it again, as at start.
//! - loft-keys: gone when KWin says it isn't loaded twice in a row, while
//!   its rendered file (`$XDG_RUNTIME_DIR/loft/plasma-keys/loft-keys.js`) is
//!   there and older than SETTLE (so a `load` in progress is left alone). The
//!   file is removed by `loft-plasma-shortcuts unload`: a deliberate unload
//!   (Loft stopping, `loft-plasma use plasma`) leaves nothing to heal. With
//!   `LOFT_PLASMA_SHORTCUTS` set (the unit's script), we run its `heal` verb:
//!   the same load the unit does (render, load, start, claim), under its lock,
//!   and only while loft-plasma-shell.service is active (not stopping).
//!   Without it (a test session), we load the rendered file ourselves.
//! - Also, every START_EVERY: `Scripting.start`, which starts any loaded
//!   script that isn't running (and leaves running ones alone), so a
//!   loft-keys that's loaded but was never started comes alive.
//!
//! Nothing runs once loft-kwin is stopping (`stopping`): it unloads the
//! bridge on its way out and must not put it back.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime};

use zbus::Connection;

pub const KEYS_SCRIPT: &str = "loft-keys";
/// How often we look.
const CHECK: Duration = Duration::from_secs(5);
/// No NextCommands poll for this long (and none in flight): the bridge is
/// dead. A poll is answered within crate::POLL (15 s) and the script polls
/// again at once.
pub const STALE: Duration = Duration::from_secs(25);
/// A rendered loft-keys.js younger than this may be a `load` in progress.
pub const SETTLE: Duration = Duration::from_secs(10);
/// At most one heal per script this often (a KWin that keeps dropping a
/// script isn't fought in a tight loop).
const MIN_GAP: Duration = Duration::from_secs(30);
const START_EVERY: Duration = Duration::from_secs(30);
/// The unit's `heal` can wait for KWin's scripting (up to 60 s).
const HEAL_TIMEOUT: Duration = Duration::from_secs(120);

/// The bridge's NextCommands polls: in flight now, and when the last one
/// started or ended.
pub struct Liveness {
    in_flight: AtomicUsize,
    last: Mutex<Instant>,
}

impl Default for Liveness {
    fn default() -> Self {
        Liveness { in_flight: AtomicUsize::new(0), last: Mutex::new(Instant::now()) }
    }
}

impl Liveness {
    pub fn begin(&self) {
        self.in_flight.fetch_add(1, Ordering::SeqCst);
        *self.last.lock().unwrap() = Instant::now();
    }

    pub fn end(&self) {
        self.in_flight.fetch_sub(1, Ordering::SeqCst);
        *self.last.lock().unwrap() = Instant::now();
    }

    /// A fresh start (after loading the script): it gets STALE to poll.
    fn reset(&self) {
        *self.last.lock().unwrap() = Instant::now();
    }

    fn since(&self) -> (usize, Duration) {
        (self.in_flight.load(Ordering::SeqCst), self.last.lock().unwrap().elapsed())
    }
}

/// Why the bridge needs loading again, if it does.
pub fn bridge_verdict(loaded: bool, in_flight: usize, since_poll: Duration) -> Option<String> {
    if !loaded {
        Some("not loaded in KWin".into())
    } else if in_flight == 0 && since_poll >= STALE {
        Some(format!("loaded but no poll for {} s", since_poll.as_secs()))
    } else {
        None
    }
}

/// Whether loft-keys needs loading again: missing now and at the last check
/// (`misses` counts this one), its rendered file there and settled.
pub fn keys_verdict(file_age: Option<Duration>, loaded: bool, misses: u32) -> bool {
    !loaded && misses >= 2 && file_age.is_some_and(|a| a >= SETTLE)
}

pub fn keys_file() -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    Path::new(&dir).join("loft").join("plasma-keys").join(format!("{KEYS_SCRIPT}.js"))
}

fn age(path: &Path) -> Option<Duration> {
    let m = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(SystemTime::now().duration_since(m).unwrap_or_default())
}

/// At most one go per MIN_GAP.
#[derive(Default)]
struct Gap(Option<Instant>);

impl Gap {
    fn allow(&mut self) -> bool {
        if self.0.is_some_and(|t| t.elapsed() < MIN_GAP) {
            return false;
        }
        self.0 = Some(Instant::now());
        true
    }
}

async fn is_loaded(conn: &Connection, name: &str) -> zbus::Result<bool> {
    let p = zbus::Proxy::new(conn, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting").await?;
    p.call("isScriptLoaded", &(name,)).await
}

async fn start_scripts(conn: &Connection) -> zbus::Result<()> {
    let p = zbus::Proxy::new(conn, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting").await?;
    p.call("start", &()).await
}

/// loft-keys back: the unit's `heal` (LOFT_PLASMA_SHORTCUTS), else the
/// rendered file straight into KWin.
async fn heal_keys(conn: &Connection, file: &Path) -> Result<String, String> {
    if let Some(script) = std::env::var_os("LOFT_PLASMA_SHORTCUTS").filter(|s| !s.is_empty()) {
        let run = tokio::process::Command::new(&script).arg("heal").kill_on_drop(true).output();
        return match tokio::time::timeout(HEAL_TIMEOUT, run).await {
            Err(_) => Err("loft-plasma-shortcuts heal timed out".into()),
            Ok(Err(e)) => Err(format!("loft-plasma-shortcuts heal: {e}")),
            Ok(Ok(o)) if o.status.success() => Ok("loft-plasma-shortcuts heal".into()),
            Ok(Ok(o)) => Err(format!(
                "loft-plasma-shortcuts heal: {} {}",
                o.status,
                String::from_utf8_lossy(&o.stderr).trim()
            )),
        };
    }
    let p = zbus::Proxy::new(conn, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting")
        .await
        .map_err(|e| e.to_string())?;
    let id: i32 = p
        .call("loadScript", &(file.to_string_lossy().to_string(), KEYS_SCRIPT))
        .await
        .map_err(|e| e.to_string())?;
    if id < 0 {
        return Err(format!("KWin refused {} ({id})", file.display()));
    }
    let () = p.call("start", &()).await.map_err(|e| e.to_string())?;
    Ok(format!("loaded {}", file.display()))
}

pub async fn watch(conn: Connection, live: std::sync::Arc<Liveness>, stopping: std::sync::Arc<AtomicBool>) {
    let mut bridge_gap = Gap::default();
    let mut keys_gap = Gap::default();
    let mut keys_misses = 0u32;
    let mut last_start = Instant::now();
    let file = keys_file();
    let mut tick = tokio::time::interval(CHECK);
    tick.tick().await;
    loop {
        tick.tick().await;
        if stopping.load(Ordering::SeqCst) {
            return;
        }
        // KWin away (restarting): nothing to ask, nothing to heal yet.
        let Ok(bridge_loaded) = is_loaded(&conn, crate::SCRIPT_NAME).await else {
            keys_misses = 0;
            continue;
        };
        let (in_flight, since) = live.since();
        if let Some(why) = bridge_verdict(bridge_loaded, in_flight, since)
            && bridge_gap.allow()
        {
            if stopping.load(Ordering::SeqCst) {
                return;
            }
            match crate::load_script(&conn).await {
                Ok(()) => {
                    live.reset();
                    // A new KWin has its effects back on.
                    crate::effects_off(&conn).await;
                    eprintln!("loft-kwin: heal loft-bridge ({why}): reloaded");
                }
                Err(e) => eprintln!("loft-kwin: heal loft-bridge ({why}): failed: {e:#}"),
            }
        }

        let keys_loaded = is_loaded(&conn, KEYS_SCRIPT).await.unwrap_or(true);
        keys_misses = if keys_loaded { 0 } else { keys_misses + 1 };
        let file_age = age(&file);
        if keys_verdict(file_age, keys_loaded, keys_misses) && keys_gap.allow() {
            if stopping.load(Ordering::SeqCst) {
                return;
            }
            match heal_keys(&conn, &file).await {
                Ok(how) => eprintln!("loft-kwin: heal {KEYS_SCRIPT} (not loaded in KWin): {how}"),
                Err(e) => eprintln!("loft-kwin: heal {KEYS_SCRIPT} (not loaded in KWin): failed: {e}"),
            }
            keys_misses = 0;
        } else if keys_loaded && file_age.is_some() && last_start.elapsed() >= START_EVERY {
            // Loaded but maybe never started: start whatever isn't running.
            let _ = start_scripts(&conn).await;
            last_start = Instant::now();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_is_dead_when_unloaded_or_silent() {
        assert_eq!(bridge_verdict(false, 1, Duration::ZERO).as_deref(), Some("not loaded in KWin"));
        assert!(bridge_verdict(true, 1, Duration::from_secs(600)).is_none(), "a poll in flight is alive");
        assert!(bridge_verdict(true, 0, Duration::from_secs(3)).is_none(), "between two polls");
        assert_eq!(
            bridge_verdict(true, 0, Duration::from_secs(40)).as_deref(),
            Some("loaded but no poll for 40 s")
        );
    }

    #[test]
    fn keys_heal_only_when_rendered_settled_and_missing_twice() {
        let old = Some(Duration::from_secs(60));
        assert!(keys_verdict(old, false, 2));
        assert!(!keys_verdict(old, false, 1), "one miss may be a load in progress");
        assert!(!keys_verdict(old, true, 0));
        assert!(!keys_verdict(None, false, 5), "no file: unloaded on purpose");
        assert!(!keys_verdict(Some(Duration::from_secs(2)), false, 5), "a fresh render: a load in progress");
    }

    #[test]
    fn gap_limits_heals() {
        let mut g = Gap::default();
        assert!(g.allow());
        assert!(!g.allow());
        g.0 = Some(Instant::now() - MIN_GAP);
        assert!(g.allow());
    }

    #[test]
    fn liveness_tracks_polls() {
        let l = Liveness::default();
        l.begin();
        assert_eq!(l.since().0, 1);
        l.end();
        let (n, since) = l.since();
        assert_eq!(n, 0);
        assert!(since < Duration::from_secs(1));
    }
}
