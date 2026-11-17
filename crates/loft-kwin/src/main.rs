//! `loft-kwin`: Loft's KWin backend daemon, run by the shell
//! (src/services/KWin.qml). docs/KWIN.md §3.
//!
//! - Owns `dev.loft.KWinBridge` on the session bus and loads the KWin script
//!   `loft-bridge` (src/bridge.js), which pushes KWin's state to `Push` and
//!   long-polls `NextCommands` for actions. The script is unloaded on exit.
//! - stdout: one JSON object per line: `{"State": {...}}` (niri-shaped
//!   windows/workspaces, crate::state), `{"KeyboardLayouts": {"names": [...],
//!   "current_idx": n}}`, `{"Error": "..."}`.
//! - stdin: one command per line, e.g. `{"cmd":"focusWindow","window":"{uuid}"}`
//!   (applied by the script) or `setDesktopName` / `switchLayout` /
//!   `toggleOverview` (done here over KWin's D-Bus API). EOF ends the daemon.
//! - `loft-kwin shot …`: a screenshot through KWin's ScreenShot2 (src/shot.rs).
//! - `loft-kwin thumbs DIR MAX UUID…`: small window stills for the dock
//!   preview and the switcher (src/shot.rs, docs/KWIN.md §4.8).

mod shot;
mod state;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{Notify, mpsc};
use zbus::zvariant::ObjectPath;
use zbus::{Connection, Proxy, interface};

const BUS_NAME: &str = "dev.loft.KWinBridge";
const SCRIPT_NAME: &str = "loft-bridge";
const SCRIPT: &str = include_str!("bridge.js");
/// How long a NextCommands poll waits before answering "nothing" (well
/// under D-Bus's 25 s default timeout).
const POLL: Duration = Duration::from_secs(15);

#[derive(Default)]
struct Queue {
    items: Mutex<VecDeque<Value>>,
    ready: Notify,
}

impl Queue {
    fn push(&self, cmd: Value) {
        self.items.lock().unwrap().push_back(cmd);
        self.ready.notify_waiters();
    }

    async fn take(&self, timeout: Duration) -> String {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let notified = self.ready.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let mut items = self.items.lock().unwrap();
                if !items.is_empty() {
                    let batch: Vec<Value> = items.drain(..).collect();
                    return Value::Array(batch).to_string();
                }
            }
            tokio::select! {
                _ = &mut notified => {}
                _ = tokio::time::sleep_until(deadline) => return "[]".to_string(),
            }
        }
    }
}

struct Bridge {
    snapshots: mpsc::UnboundedSender<String>,
    queue: Arc<Queue>,
}

#[interface(name = "dev.loft.KWinBridge")]
impl Bridge {
    /// The script's state snapshot (bridge.js `snapshot()`), as JSON.
    async fn push(&self, json: String) {
        let _ = self.snapshots.send(json);
    }

    /// The commands queued since the last poll, as a JSON array; waits up to
    /// POLL for one to arrive.
    async fn next_commands(&self) -> String {
        self.queue.take(POLL).await
    }
}

fn emit(v: &Value) {
    // One line per message; the shell's SplitParser reads them.
    println!("{v}");
}

fn now() -> Duration {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default()
}

async fn kwin_proxy<'a>(conn: &Connection, path: &'a str, iface: &'a str) -> Result<Proxy<'a>> {
    Ok(Proxy::new(conn, "org.kde.KWin", ObjectPath::try_from(path)?, iface).await?)
}

async fn unload_script(conn: &Connection) {
    if let Ok(p) = kwin_proxy(conn, "/Scripting", "org.kde.kwin.Scripting").await {
        let _: zbus::Result<bool> = p.call("unloadScript", &(SCRIPT_NAME,)).await;
    }
}

async fn load_script(conn: &Connection) -> Result<()> {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    let dir = std::path::Path::new(&dir).join("loft");
    std::fs::create_dir_all(&dir)?;
    let file = dir.join("kwin-bridge.js");
    std::fs::write(&file, SCRIPT)?;

    // A previous loft-kwin that died without unloading leaves its script
    // polling a name we now own: replace it.
    unload_script(conn).await;
    let scripting = kwin_proxy(conn, "/Scripting", "org.kde.kwin.Scripting")
        .await
        .context("KWin's scripting interface (is this a KWin session?)")?;
    let id: i32 = scripting
        .call("loadScript", &(file.to_string_lossy().to_string(), SCRIPT_NAME))
        .await
        .context("loading the loft-bridge KWin script")?;
    if id < 0 {
        anyhow::bail!("KWin refused the loft-bridge script ({id})");
    }
    let path = format!("/Scripting/Script{id}");
    let script = kwin_proxy(conn, &path, "org.kde.kwin.Script").await?;
    let () = script.call("run", &()).await.context("starting the loft-bridge KWin script")?;
    Ok(())
}

/// Commands KWin's D-Bus API does directly; everything else goes to the script.
async fn direct(conn: &Connection, cmd: &Value) -> Result<bool> {
    match cmd["cmd"].as_str().unwrap_or("") {
        "setDesktopName" => {
            let p = kwin_proxy(conn, "/VirtualDesktopManager", "org.kde.KWin.VirtualDesktopManager").await?;
            let desktop = cmd["desktop"].as_str().unwrap_or("").to_string();
            let name = cmd["name"].as_str().unwrap_or("").to_string();
            let () = p.call("setDesktopName", &(desktop, name)).await?;
            Ok(true)
        }
        "toggleOverview" => {
            let p = Proxy::new(
                conn,
                "org.kde.kglobalaccel",
                ObjectPath::try_from("/component/kwin")?,
                "org.kde.kglobalaccel.Component",
            )
            .await?;
            let () = p.call("invokeShortcut", &("Overview",)).await?;
            Ok(true)
        }
        "switchLayout" => {
            let p = keyboard(conn).await?;
            let index = cmd["index"].as_u64().unwrap_or(0) as u32;
            let _: bool = p.call("setLayout", &(index,)).await?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

async fn keyboard(conn: &Connection) -> Result<Proxy<'static>> {
    Ok(Proxy::new(conn, "org.kde.keyboard", "/Layouts", "org.kde.KeyboardLayouts").await?)
}

async fn emit_layouts(kb: &Proxy<'_>) -> Result<()> {
    let list: Vec<(String, String, String)> = kb.call("getLayoutsList", &()).await?;
    let current: u32 = kb.call("getLayout", &()).await?;
    // niri's names are the long ones ("English (US)").
    let names: Vec<String> = list
        .into_iter()
        .map(|(short, display, long)| if !long.is_empty() { long } else if !display.is_empty() { display } else { short })
        .collect();
    emit(&json!({ "KeyboardLayouts": { "names": names, "current_idx": current } }));
    Ok(())
}

/// Keyboard layouts from Plasma's keyboard daemon (kded), kept current.
async fn watch_layouts(conn: Connection) {
    let Ok(kb) = keyboard(&conn).await else { return };
    let _ = emit_layouts(&kb).await;
    let Ok(mut changed) = kb.receive_signal("layoutChanged").await else { return };
    let Ok(mut list_changed) = kb.receive_signal("layoutListChanged").await else { return };
    loop {
        tokio::select! {
            Some(_) = changed.next() => {}
            Some(_) = list_changed.next() => {}
            else => return,
        }
        let _ = emit_layouts(&kb).await;
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "shot") {
        return shot::run(&shot::parse(&args[1..])?).await;
    }
    if args.first().is_some_and(|a| a == "thumbs") {
        return shot::thumbs(&shot::parse_thumbs(&args[1..])?).await;
    }
    if args.first().is_some_and(|a| a == "--help" || a == "-h") {
        println!(
            "loft-kwin — Loft's KWin backend daemon\n\n\
             Loads the loft-bridge KWin script and relays: stdout {{\"State\"}} /\n\
             {{\"KeyboardLayouts\"}} / {{\"Error\"}} lines, stdin one command per line\n\
             ({{\"cmd\":\"focusWindow\",\"window\":\"{{uuid}}\"}}, …). docs/KWIN.md."
        );
        return Ok(());
    }

    let (snapshots_tx, mut snapshots) = mpsc::unbounded_channel::<String>();
    let queue = Arc::new(Queue::default());

    let conn = match zbus::connection::Builder::session()?
        .name(BUS_NAME)?
        .serve_at("/Bridge", Bridge { snapshots: snapshots_tx, queue: queue.clone() })?
        .build()
        .await
    {
        Ok(c) => c,
        Err(e) => {
            emit(&json!({ "Error": format!("can't own {BUS_NAME}: {e}") }));
            return Err(e.into());
        }
    };

    if let Err(e) = load_script(&conn).await {
        emit(&json!({ "Error": format!("{e:#}") }));
        return Err(e);
    }

    tokio::spawn(watch_layouts(conn.clone()));

    let mut model = state::Model::new();
    // Display identities spell the vendor out like niri (LOFT_PNP_IDS: set
    // by the Nix package to hwdata's pnp.ids).
    let pnp_path = std::env::var("LOFT_PNP_IDS").unwrap_or_else(|_| "/run/current-system/sw/share/hwdata/pnp.ids".into());
    match std::fs::read_to_string(&pnp_path) {
        Ok(text) => model.pnp = state::parse_pnp_ids(&text),
        Err(e) => eprintln!("loft-kwin: no PNP ids ({pnp_path}: {e}); display vendors stay as ids"),
    }
    let mut stdin = BufReader::new(tokio::io::stdin()).lines();
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;

    loop {
        tokio::select! {
            Some(json) = snapshots.recv() => {
                match serde_json::from_str::<state::Snapshot>(&json) {
                    Ok(snap) => emit(&json!({ "State": model.update(&snap, now()) })),
                    Err(e) => eprintln!("loft-kwin: bad snapshot: {e}"),
                }
            }
            line = stdin.next_line() => {
                let Ok(Some(line)) = line else { break };
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(line) {
                    Ok(cmd) => match direct(&conn, &cmd).await {
                        Ok(true) => {}
                        Ok(false) => queue.push(cmd),
                        Err(e) => eprintln!("loft-kwin: {}: {e:#}", cmd["cmd"]),
                    },
                    Err(e) => eprintln!("loft-kwin: bad command {line:?}: {e}"),
                }
            }
            _ = term.recv() => break,
            _ = tokio::signal::ctrl_c() => break,
        }
    }

    unload_script(&conn).await;
    Ok(())
}
