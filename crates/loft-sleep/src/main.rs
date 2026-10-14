//! `loft-sleep watch`: the user service (programs.loft, see lib.rs).
//! `loft-sleep status`: the setting, what's remembered and the adapters.

use std::collections::HashMap;

use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use loft_sleep::{Bluetooth, Paths, SleepLock};
use serde_json::json;
use zbus::message::Type as MsgType;
use zbus::zvariant::{OwnedFd, OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, MatchRule, MessageStream};

const LOGIN1: &str = "org.freedesktop.login1";
const LOGIN1_PATH: &str = "/org/freedesktop/login1";
const LOGIN1_MANAGER: &str = "org.freedesktop.login1.Manager";

type Managed = HashMap<OwnedObjectPath, HashMap<String, HashMap<String, OwnedValue>>>;

struct BlueZ<'a>(&'a Connection);

impl Bluetooth for BlueZ<'_> {
    async fn adapters(&mut self) -> Result<Vec<(String, bool)>> {
        let reply = match self
            .0
            .call_method(
                Some("org.bluez"),
                "/",
                Some("org.freedesktop.DBus.ObjectManager"),
                "GetManagedObjects",
                &(),
            )
            .await
        {
            Ok(r) => r,
            // No bluetoothd (no adapter, or Bluetooth not enabled): nothing to do.
            Err(zbus::Error::MethodError(name, _, _))
                if name.as_str() == "org.freedesktop.DBus.Error.ServiceUnknown" =>
            {
                return Ok(Vec::new());
            }
            Err(e) => return Err(e).context("asking BlueZ for its adapters"),
        };
        let objects: Managed = reply.body().deserialize()?;
        let mut out: Vec<(String, bool)> = objects
            .into_iter()
            .filter_map(|(path, ifaces)| {
                let a = ifaces.get("org.bluez.Adapter1")?;
                let powered = a
                    .get("Powered")
                    .and_then(|v| bool::try_from(v).ok())
                    .unwrap_or(false);
                Some((path.to_string(), powered))
            })
            .collect();
        out.sort();
        Ok(out)
    }

    async fn set_powered(&mut self, adapter: &str, on: bool) -> Result<()> {
        self.0
            .call_method(
                Some("org.bluez"),
                adapter,
                Some("org.freedesktop.DBus.Properties"),
                "Set",
                &("org.bluez.Adapter1", "Powered", Value::from(on)),
            )
            .await
            .with_context(|| format!("setting {adapter} Powered={on}"))?;
        Ok(())
    }
}

/// logind's `Inhibit("sleep", …, "delay")`: sleep waits (up to
/// InhibitDelayMaxSec) until the fd is closed.
struct DelayLock<'a> {
    conn: &'a Connection,
    fd: Option<OwnedFd>,
}

impl SleepLock for DelayLock<'_> {
    async fn acquire(&mut self) -> Result<()> {
        if self.fd.is_some() {
            return Ok(());
        }
        let reply = self
            .conn
            .call_method(
                Some(LOGIN1),
                LOGIN1_PATH,
                Some(LOGIN1_MANAGER),
                "Inhibit",
                &("sleep", "Loft", "Turn Bluetooth off before sleep", "delay"),
            )
            .await
            .context("taking a sleep delay lock from logind")?;
        self.fd = Some(reply.body().deserialize::<OwnedFd>()?);
        Ok(())
    }

    fn release(&mut self) {
        self.fd = None;
    }
}

async fn watch() -> Result<()> {
    let conn = Connection::system()
        .await
        .context("connecting to the system bus")?;
    let paths = Paths::new(&loft_sleep::state_dir());
    let rule = MatchRule::builder()
        .msg_type(MsgType::Signal)
        .sender(LOGIN1)?
        .interface(LOGIN1_MANAGER)?
        .member("PrepareForSleep")?
        .path(LOGIN1_PATH)?
        .build();
    let mut signals = MessageStream::for_match_rule(rule, &conn, Some(16)).await?;
    let mut bt = BlueZ(&conn);
    let mut lock = DelayLock {
        conn: &conn,
        fd: None,
    };
    // A wake we missed (the service was down): restore first.
    let restored = loft_sleep::after_wake(&mut bt, &paths).await?;
    if !restored.is_empty() {
        eprintln!("loft-sleep: switched {} back on", restored.join(", "));
    }
    if let Err(e) = lock.acquire().await {
        // Without the lock sleep may start before the adapters are off;
        // keep going (they're still switched off, just maybe late).
        eprintln!("loft-sleep: {e:#}");
    }
    eprintln!(
        "loft-sleep: watching for sleep (Bluetooth off: {})",
        if loft_sleep::enabled(&paths) {
            "on"
        } else {
            "off — Settings → Everyday"
        }
    );
    while let Some(msg) = signals.next().await {
        let msg = msg?;
        let Ok(start) = msg.body().deserialize::<bool>() else {
            continue;
        };
        let changed = loft_sleep::on_prepare_for_sleep(start, &mut bt, &mut lock, &paths).await;
        if !changed.is_empty() {
            eprintln!(
                "loft-sleep: {} {}",
                if start {
                    "before sleep, switched off"
                } else {
                    "after wake, switched on"
                },
                changed.join(", ")
            );
        }
    }
    bail!("the system bus closed")
}

async fn status() -> Result<()> {
    let paths = Paths::new(&loft_sleep::state_dir());
    let adapters = match Connection::system().await {
        Ok(conn) => BlueZ(&conn).adapters().await.unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    println!(
        "{}",
        json!({
            "enabled": loft_sleep::enabled(&paths),
            "remembered": loft_sleep::remembered(&paths),
            "adapters": adapters.iter().map(|(a, p)| json!({ "path": a, "powered": p })).collect::<Vec<_>>(),
            "settings": paths.settings,
        })
    );
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    match std::env::args().nth(1).as_deref() {
        Some("watch") => watch().await,
        Some("status") => status().await,
        _ => {
            println!(
                "loft-sleep — Bluetooth off during sleep (Loft)\n\n\
                 loft-sleep watch    listen for logind's PrepareForSleep: before sleep switch\n\
                 \x20                   the powered Bluetooth adapters off (when Settings → Everyday\n\
                 \x20                   → \"Turn Bluetooth off during sleep\" is on), after the wake\n\
                 \x20                   switch them back on\n\
                 loft-sleep status   the setting, remembered adapters and the adapters (JSON)\n\n\
                 Reads $LOFT_STATE_DIR (default $XDG_STATE_HOME/loft)/overrides/everyday.json."
            );
            Ok(())
        }
    }
}
