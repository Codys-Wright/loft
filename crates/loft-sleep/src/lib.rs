//! loft-sleep: Bluetooth off during sleep (Settings → Everyday → Sleep).
//!
//! A user service listens for systemd-logind's `PrepareForSleep` signal on
//! the system bus (read-only, no root):
//!
//! - `PrepareForSleep(true)`: if the setting is on, every powered BlueZ
//!   adapter is switched off and remembered in `<state>/bluetooth-sleep.json`,
//!   then our sleep *delay* inhibitor is released so the system goes on.
//! - `PrepareForSleep(false)` (woke up): the remembered adapters are powered
//!   on again, the file is removed, and the delay lock is taken again.
//!
//! Adapters that were already off stay off. The restore also runs at start,
//! for a wake the service missed. The D-Bus side (`main.rs`) sits behind the
//! [`Bluetooth`] and [`SleepLock`] traits, so the logic is tested with fakes.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{Value, json};

/// BlueZ adapters: object path → Powered.
#[allow(async_fn_in_trait)]
pub trait Bluetooth {
    async fn adapters(&mut self) -> Result<Vec<(String, bool)>>;
    async fn set_powered(&mut self, adapter: &str, on: bool) -> Result<()>;
}

/// logind's sleep delay inhibitor.
#[allow(async_fn_in_trait)]
pub trait SleepLock {
    async fn acquire(&mut self) -> Result<()>;
    fn release(&mut self);
}

pub fn state_dir() -> PathBuf {
    if let Some(v) = std::env::var_os("LOFT_STATE_DIR").filter(|v| !v.is_empty()) {
        return PathBuf::from(v);
    }
    std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::home_dir()
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(".local/state")
        })
        .join("loft")
}

pub struct Paths {
    /// The shell's Everyday settings (`sleep.bluetoothOff`).
    pub settings: PathBuf,
    /// Adapters we switched off, to switch on after the wake.
    pub memory: PathBuf,
}

impl Paths {
    pub fn new(state: &Path) -> Self {
        Paths {
            settings: state.join("overrides/everyday.json"),
            memory: state.join("bluetooth-sleep.json"),
        }
    }
}

/// The setting (off unless the file says so).
pub fn enabled(paths: &Paths) -> bool {
    std::fs::read_to_string(&paths.settings)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.pointer("/sleep/bluetoothOff").and_then(Value::as_bool))
        .unwrap_or(false)
}

pub fn remembered(paths: &Paths) -> Vec<String> {
    std::fs::read_to_string(&paths.memory)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| {
            v.get("poweredOff")?.as_array().map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
        })
        .unwrap_or_default()
}

fn remember(paths: &Paths, adapters: &[String]) -> Result<()> {
    let dir = paths.memory.parent().context("memory file has no parent")?;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".bluetooth-sleep.json.tmp-{}", std::process::id()));
    std::fs::write(&tmp, json!({ "poweredOff": adapters }).to_string() + "\n")?;
    std::fs::rename(&tmp, &paths.memory)?;
    Ok(())
}

/// Before sleep: switch the powered adapters off (when the setting is on).
/// Returns the adapters switched off. One failing adapter doesn't stop the
/// others; only the ones that went off are remembered.
pub async fn before_sleep<B: Bluetooth>(bt: &mut B, paths: &Paths) -> Result<Vec<String>> {
    if !enabled(paths) {
        return Ok(Vec::new());
    }
    // Keep what an earlier, unrestored sleep remembered.
    let mut off = remembered(paths);
    let mut errors = Vec::new();
    for (adapter, powered) in bt.adapters().await? {
        if !powered {
            continue;
        }
        match bt.set_powered(&adapter, false).await {
            Ok(()) => {
                if !off.contains(&adapter) {
                    off.push(adapter);
                }
            }
            Err(e) => errors.push(format!("{adapter}: {e:#}")),
        }
    }
    if !off.is_empty() {
        remember(paths, &off)?;
    }
    if !errors.is_empty() {
        eprintln!("loft-sleep: couldn't switch off {}", errors.join("; "));
    }
    Ok(off)
}

/// After the wake (and at start): switch the remembered adapters back on.
/// Returns the adapters switched on. Runs whatever the setting says now —
/// what we switched off is always restored.
pub async fn after_wake<B: Bluetooth>(bt: &mut B, paths: &Paths) -> Result<Vec<String>> {
    let off = remembered(paths);
    if off.is_empty() {
        let _ = std::fs::remove_file(&paths.memory);
        return Ok(Vec::new());
    }
    let present: Vec<String> = bt
        .adapters()
        .await
        .unwrap_or_default()
        .into_iter()
        .map(|(a, _)| a)
        .collect();
    let mut on = Vec::new();
    for adapter in &off {
        if !present.contains(adapter) {
            eprintln!("loft-sleep: {adapter} is gone; not restoring it");
            continue;
        }
        match bt.set_powered(adapter, true).await {
            Ok(()) => on.push(adapter.clone()),
            Err(e) => eprintln!("loft-sleep: couldn't switch {adapter} back on: {e:#}"),
        }
    }
    let _ = std::fs::remove_file(&paths.memory);
    Ok(on)
}

/// One `PrepareForSleep(start)` signal: the work, then the lock dance.
pub async fn on_prepare_for_sleep<B: Bluetooth, L: SleepLock>(
    start: bool,
    bt: &mut B,
    lock: &mut L,
    paths: &Paths,
) -> Vec<String> {
    if start {
        let r = before_sleep(bt, paths).await;
        // Always let the system sleep, whatever happened.
        lock.release();
        r.unwrap_or_else(|e| {
            eprintln!("loft-sleep: before sleep: {e:#}");
            Vec::new()
        })
    } else {
        let r = after_wake(bt, paths).await;
        if let Err(e) = lock.acquire().await {
            eprintln!("loft-sleep: couldn't take the sleep delay lock again: {e:#}");
        }
        r.unwrap_or_else(|e| {
            eprintln!("loft-sleep: after wake: {e:#}");
            Vec::new()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeBt {
        adapters: Vec<(String, bool)>,
        broken: Vec<String>,
        calls: Vec<String>,
    }

    impl FakeBt {
        fn new(adapters: &[(&str, bool)]) -> Self {
            FakeBt {
                adapters: adapters.iter().map(|(a, p)| (a.to_string(), *p)).collect(),
                ..Default::default()
            }
        }
        fn powered(&self, a: &str) -> bool {
            self.adapters.iter().find(|(x, _)| x == a).unwrap().1
        }
    }

    impl Bluetooth for FakeBt {
        async fn adapters(&mut self) -> Result<Vec<(String, bool)>> {
            Ok(self.adapters.clone())
        }
        async fn set_powered(&mut self, adapter: &str, on: bool) -> Result<()> {
            self.calls.push(format!("{adapter}={on}"));
            if self.broken.iter().any(|b| b == adapter) {
                anyhow::bail!("org.bluez.Error.Failed");
            }
            for (a, p) in &mut self.adapters {
                if a == adapter {
                    *p = on;
                }
            }
            Ok(())
        }
    }

    #[derive(Default)]
    struct FakeLock {
        held: bool,
        log: Vec<&'static str>,
    }

    impl SleepLock for FakeLock {
        async fn acquire(&mut self) -> Result<()> {
            self.held = true;
            self.log.push("acquire");
            Ok(())
        }
        fn release(&mut self) {
            self.held = false;
            self.log.push("release");
        }
    }

    fn scratch(name: &str, enabled: Option<bool>) -> Paths {
        let d = std::env::temp_dir().join(format!("loft-sleep-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("overrides")).unwrap();
        let p = Paths::new(&d);
        if let Some(on) = enabled {
            std::fs::write(
                &p.settings,
                json!({ "keepAwake": {}, "sleep": { "bluetoothOff": on } }).to_string(),
            )
            .unwrap();
        }
        p
    }

    fn block<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(f)
    }

    #[test]
    fn off_before_sleep_and_back_after_wake() {
        let p = scratch("cycle", Some(true));
        let mut bt = FakeBt::new(&[("/org/bluez/hci0", true), ("/org/bluez/hci1", false)]);
        let mut lock = FakeLock {
            held: true,
            ..Default::default()
        };
        let off = block(on_prepare_for_sleep(true, &mut bt, &mut lock, &p));
        assert_eq!(off, vec!["/org/bluez/hci0"]);
        assert!(!bt.powered("/org/bluez/hci0"));
        assert!(!lock.held, "the delay lock is released before sleep");
        assert_eq!(remembered(&p), vec!["/org/bluez/hci0"]);

        let on = block(on_prepare_for_sleep(false, &mut bt, &mut lock, &p));
        assert_eq!(on, vec!["/org/bluez/hci0"]);
        assert!(bt.powered("/org/bluez/hci0"));
        assert!(
            !bt.powered("/org/bluez/hci1"),
            "an adapter that was off stays off"
        );
        assert!(!p.memory.exists());
        assert!(lock.held, "the lock is taken again after the wake");
        assert_eq!(lock.log, vec!["release", "acquire"]);
        assert_eq!(
            bt.calls,
            vec!["/org/bluez/hci0=false", "/org/bluez/hci0=true"]
        );
    }

    #[test]
    fn setting_off_or_missing_does_nothing_but_still_releases() {
        for (name, setting) in [("off", Some(false)), ("missing", None)] {
            let p = scratch(name, setting);
            let mut bt = FakeBt::new(&[("/org/bluez/hci0", true)]);
            let mut lock = FakeLock::default();
            let off = block(on_prepare_for_sleep(true, &mut bt, &mut lock, &p));
            assert!(off.is_empty());
            assert!(bt.calls.is_empty());
            assert_eq!(lock.log, vec!["release"]);
            assert!(!p.memory.exists());
        }
    }

    #[test]
    fn restores_even_if_the_setting_was_turned_off_meanwhile() {
        let p = scratch("turned-off", Some(true));
        let mut bt = FakeBt::new(&[("/org/bluez/hci0", true)]);
        block(before_sleep(&mut bt, &p)).unwrap();
        std::fs::write(&p.settings, r#"{"sleep":{"bluetoothOff":false}}"#).unwrap();
        assert_eq!(
            block(after_wake(&mut bt, &p)).unwrap(),
            vec!["/org/bluez/hci0"]
        );
        assert!(bt.powered("/org/bluez/hci0"));
    }

    #[test]
    fn a_failing_adapter_is_not_remembered() {
        let p = scratch("broken", Some(true));
        let mut bt = FakeBt::new(&[("/org/bluez/hci0", true), ("/org/bluez/hci1", true)]);
        bt.broken.push("/org/bluez/hci1".into());
        let off = block(before_sleep(&mut bt, &p)).unwrap();
        assert_eq!(off, vec!["/org/bluez/hci0"]);
        assert_eq!(remembered(&p), vec!["/org/bluez/hci0"]);
    }

    #[test]
    fn a_vanished_adapter_is_skipped_and_nothing_remembered_is_a_no_op() {
        let p = scratch("gone", Some(true));
        let mut bt = FakeBt::new(&[("/org/bluez/hci0", true)]);
        assert!(block(after_wake(&mut bt, &p)).unwrap().is_empty());
        assert!(bt.calls.is_empty());
        block(before_sleep(&mut bt, &p)).unwrap();
        bt.adapters.clear(); // e.g. a USB dongle unplugged during sleep
        assert!(block(after_wake(&mut bt, &p)).unwrap().is_empty());
        assert!(!p.memory.exists());
    }
}
