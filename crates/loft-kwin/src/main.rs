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
//! - `loft-kwin send JSON`: one command to the running daemon, over its
//!   `Command` D-Bus method (as if the shell wrote it on stdin). Without a
//!   `window` the script acts on the active window (Spotlight's commands).
//! - `loft-kwin state`: the daemon's last `State` (the same JSON the shell
//!   gets), over its `State` method (`loft mcp` reads windows from it).
//! - `loft-kwin thumbs DIR MAX UUID…`: small window stills for the dock
//!   preview and the switcher (src/shot.rs, docs/KWIN.md §4.8).
//! - `loft-kwin record …`: a screen recording through KWin's zkde_screencast
//!   and PipeWire (src/record.rs).
//! - `loft-kwin displays [set JSON]`: outputs through KScreen (src/displays.rs).
//! - Spaces are the user's KDE Activities (src/activities.rs), read-only:
//!   stdin `activities` answers `{"Activities": {"activities": [{id, name,
//!   icon, key, position}], "current"}}` in KDE's "Switch to activity" key
//!   order, sent again on every change; `loft-kwin spaces list|prune`.
//!   stdin `openSpace` starts a Space's missing apps in its Activity, on
//!   their roles' displays (src/spinup.rs), answered with `{"SpaceOpened"}`.

mod activities;
mod displays;
mod input;
mod record;
mod shot;
mod spinup;
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

pub(crate) const BUS_NAME: &str = "dev.loft.KWinBridge";
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
    /// Commands from other processes (`loft-kwin send`), handled like stdin's.
    commands: mpsc::UnboundedSender<Value>,
    /// The last state emitted, as JSON ("" until the first snapshot).
    state: Arc<Mutex<String>>,
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

    /// One command, as on stdin (`{"cmd": …}`); `loft-kwin send`.
    async fn command(&self, json: String) -> zbus::fdo::Result<()> {
        let cmd = parse_command(&json).map_err(zbus::fdo::Error::InvalidArgs)?;
        self.commands
            .send(cmd)
            .map_err(|_| zbus::fdo::Error::Failed("loft-kwin is shutting down".into()))
    }

    /// The shell's current state (niri-shaped windows, workspaces, outputs,
    /// overview_open), as JSON; `loft-kwin state`.
    async fn state(&self) -> zbus::fdo::Result<String> {
        let s = self.state.lock().unwrap().clone();
        if s.is_empty() {
            return Err(zbus::fdo::Error::Failed("no state from KWin yet".into()));
        }
        Ok(s)
    }

    /// From Loft's decoration (kdecoration/shell.cpp), in KWin: a title-bar
    /// action, `{"action": "menu"|"tileMenu"|"fullscreen", "x", "y" (decoration-
    /// local anchor), "width", "height" (the frame)}`. The script finds the
    /// window under the pointer and does it. True = taken; false tells the
    /// decoration to fall back to KWin's own behaviour.
    async fn title_bar(&self, json: String) -> bool {
        match title_bar_command(&json) {
            Some(cmd) => {
                self.queue.push(cmd);
                true
            }
            None => {
                eprintln!("loft-kwin: bad title-bar request {json:?}");
                false
            }
        }
    }

    /// From the script: an event for the shell (one stdout line as is), e.g.
    /// `{"WindowActionsMenuRequested": {"window", "output", "x", "y", "kind"}}`.
    async fn event(&self, json: String) {
        match serde_json::from_str::<Value>(&json) {
            Ok(v) if v.is_object() => emit(&v),
            _ => eprintln!("loft-kwin: bad event from the script {json:?}"),
        }
    }
}

/// A command line: a JSON object with a string `cmd`.
fn parse_command(json: &str) -> Result<Value, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("bad JSON: {e}"))?;
    if !v["cmd"].is_string() {
        return Err(format!("not a command (no \"cmd\"): {json}"));
    }
    Ok(v)
}

/// Talk to the running daemon (`send` / `state`): its bus name, not KWin's.
async fn client(args: &[String]) -> Result<()> {
    let conn = Connection::session().await.context("the session bus")?;
    let p = Proxy::new(&conn, BUS_NAME, "/Bridge", BUS_NAME).await?;
    let not_running = || format!("{BUS_NAME} isn't on the session bus (is Loft's shell running under KWin?)");
    match args {
        [verb, json] if verb == "send" => {
            parse_command(json).map_err(anyhow::Error::msg)?;
            let () = p.call("Command", &(json.as_str(),)).await.with_context(not_running)?;
        }
        [verb] if verb == "state" => {
            let s: String = p.call("State", &()).await.with_context(not_running)?;
            println!("{s}");
        }
        _ => anyhow::bail!("usage: loft-kwin send JSON | loft-kwin state"),
    }
    Ok(())
}

/// A decoration's title-bar request → the script's `titleBar` command.
fn title_bar_command(json: &str) -> Option<Value> {
    let req: Value = serde_json::from_str(json).ok()?;
    let action = req["action"].as_str()?;
    if !matches!(action, "menu" | "tileMenu" | "fullscreen") {
        return None;
    }
    let num = |k: &str| req[k].as_f64().filter(|v| v.is_finite());
    Some(json!({
        "cmd": "titleBar",
        "action": action,
        "x": num("x")?,
        "y": num("y")?,
        "width": num("width")?,
        "height": num("height")?,
    }))
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

/// KWin effects that animate Loft's own surfaces on top of Loft's motion:
/// `fadingpopups` fades every popup in (150 ms) and out (600 ms), which shows
/// a Loft menu's first frame before it's placed, so menus seem to grow out
/// of a corner. niri animates none of them. Off while loft-kwin runs.
const EFFECTS_OFF: &[&str] = &["fadingpopups"];

/// Where we note the effects we unloaded, so a loft-kwin that restarts after
/// a crash still gives them back on exit.
fn effects_note() -> std::path::PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    std::path::Path::new(&dir).join("loft").join("kwin-effects-off")
}

async fn effects_off(conn: &Connection) {
    let Ok(fx) = kwin_proxy(conn, "/Effects", "org.kde.kwin.Effects").await else { return };
    let note = effects_note();
    let mut off: Vec<String> = std::fs::read_to_string(&note)
        .unwrap_or_default()
        .lines()
        .map(String::from)
        .collect();
    for name in EFFECTS_OFF {
        let loaded: bool = fx.call("isEffectLoaded", &(*name,)).await.unwrap_or(false);
        if loaded {
            let _: zbus::Result<()> = fx.call("unloadEffect", &(*name,)).await;
            if !off.iter().any(|n| n == name) {
                off.push(name.to_string());
            }
        }
    }
    if !off.is_empty() {
        let _ = std::fs::create_dir_all(note.parent().unwrap());
        let _ = std::fs::write(&note, off.join("\n"));
    }
}

/// Give back what effects_off took (only what it took: an effect the user
/// had turned off stays off).
async fn effects_restore(conn: &Connection) {
    let note = effects_note();
    let Ok(list) = std::fs::read_to_string(&note) else { return };
    if let Ok(fx) = kwin_proxy(conn, "/Effects", "org.kde.kwin.Effects").await {
        for name in list.lines().filter(|n| !n.is_empty()) {
            let _: zbus::Result<bool> = fx.call("loadEffect", &(name,)).await;
        }
    }
    let _ = std::fs::remove_file(&note);
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
        // Spaces are the user's Activities: read them, never write them
        // (src/activities.rs). `syncSpaces` is what older shells sent; it
        // gets the same read-only answer.
        "activities" | "syncSpaces" => {
            emit(&activities::report(conn).await);
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

/// What `openSpace` keeps between calls: the last state, and the apps
/// started recently whose window hasn't shown up ((space, app) → when).
struct Spin {
    state: Arc<Mutex<String>>,
    starting: Mutex<std::collections::HashMap<(String, String), std::time::Instant>>,
}

/// `openSpace` (src/spinup.rs): find, place, start; queue the script's
/// commands; report.
fn open_space(queue: &Queue, spin: &Spin, cmd: &Value) -> Value {
    let space = cmd["space"].as_str().unwrap_or("").to_string();
    let activity = cmd["activity"].as_str().unwrap_or("").to_string();
    let mut notes: Vec<String> = cmd["notes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|n| n.as_str().map(String::from))
        .collect();
    let apps: Vec<spinup::AppReq> = match serde_json::from_value(cmd["apps"].clone()) {
        Ok(a) => a,
        Err(e) => return json!({ "SpaceOpened": { "space": space, "apps": [], "notes": [format!("bad apps: {e}")] } }),
    };
    if cmd["focus"].as_bool() == Some(true) && !activity.is_empty() {
        queue.push(json!({ "cmd": "setActivity", "activity": activity }));
    }
    let matchers: Vec<Option<spinup::Matcher>> = apps
        .iter()
        .map(|a| match spinup::Matcher::new(a) {
            Ok(m) => Some(m),
            Err(e) => {
                notes.push(format!("{}: {e}", a.app));
                None
            }
        })
        .collect();
    let state: Value = serde_json::from_str(&spin.state.lock().unwrap()).unwrap_or(Value::Null);
    let wins = spinup::windows_from_state(&state, Some(std::path::Path::new("/proc")));
    let mut starting = spin.starting.lock().unwrap();
    let ttl = Duration::from_millis(spinup::EXPECT_MS);
    starting.retain(|_, t| t.elapsed() < ttl);
    let recent: std::collections::BTreeSet<String> =
        starting.keys().filter(|(s, _)| *s == space).map(|(_, a)| a.clone()).collect();
    let mut rows = Vec::new();
    for step in spinup::plan(&apps, &matchers, &wins, &activity, &recent) {
        use spinup::Step;
        let (i, window, spawn) = match step {
            Step::Found { app, uuid, move_to } => {
                starting.remove(&(space.clone(), apps[app].app.clone()));
                if let Some(output) = move_to {
                    queue.push(json!({ "cmd": "moveToOutput", "window": uuid, "output": output }));
                }
                (app, Some(uuid), None)
            }
            Step::Starting { app } => (app, None, Some("starting")),
            Step::Missing { app } => {
                notes.push(format!("{} isn't open, and has no command to start it", apps[app].app));
                (app, None, None)
            }
            Step::Spawn { app } => {
                let a = &apps[app];
                match spinup::spawn(a) {
                    Ok(pid) => {
                        if let Some(m) = &matchers[app] {
                            queue.push(spinup::expect_cmd(a, m, &activity, Some(pid)));
                        }
                        starting.insert((space.clone(), a.app.clone()), std::time::Instant::now());
                        (app, None, Some("started"))
                    }
                    Err(e) => {
                        notes.push(format!("{}: starting `{}`: {e}", a.app, a.exec.join(" ")));
                        (app, None, None)
                    }
                }
            }
        };
        rows.push(json!({ "app": apps[i].app, "display": apps[i].display, "window": window, "spawn": spawn }));
    }
    json!({ "SpaceOpened": { "space": space, "activity": activity, "apps": rows, "notes": notes } })
}

/// A command from stdin or `Command`: KWin's D-Bus API, else the script.
async fn dispatch(conn: &Connection, queue: &Queue, spin: &Spin, cmd: Value) {
    if cmd["cmd"] == "openSpace" {
        emit(&open_space(queue, spin, &cmd));
        return;
    }
    match direct(conn, &cmd).await {
        Ok(true) => {}
        Ok(false) => queue.push(cmd),
        Err(e) => eprintln!("loft-kwin: {}: {e:#}", cmd["cmd"]),
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
    if args.first().is_some_and(|a| a == "send" || a == "state") {
        return client(&args).await;
    }
    if args.first().is_some_and(|a| a == "thumbs") {
        return shot::thumbs(&shot::parse_thumbs(&args[1..])?).await;
    }
    if args.first().is_some_and(|a| a == "record") {
        return record::run(&record::parse(&args[1..])?).await;
    }
    if args.first().is_some_and(|a| a == "displays") {
        return displays::run(&args[1..]);
    }
    if args.first().is_some_and(|a| a == "input") {
        return input::cli(&args[1..]).await;
    }
    if args.first().is_some_and(|a| a == "spaces") {
        return activities::cli(&args[1..]).await;
    }
    if args.first().is_some_and(|a| a == "--help" || a == "-h") {
        println!(
            "loft-kwin — Loft's KWin backend daemon\n\n\
             Loads the loft-bridge KWin script and relays: stdout {{\"State\"}} /\n\
             {{\"KeyboardLayouts\"}} / {{\"Error\"}} lines, stdin one command per line\n\
             ({{\"cmd\":\"focusWindow\",\"window\":\"{{uuid}}\"}}, …). docs/KWIN.md.\n\n\
             loft-kwin send JSON                             one command to the running daemon (no window: the active one)\n\
             loft-kwin state                                 the running daemon's state, as JSON\n\
             loft-kwin shot screen|window|area|workspace …   a screenshot (ScreenShot2)\n\
             loft-kwin thumbs DIR MAX_PX UUID…               window stills for the dock and switcher\n\
             loft-kwin record screen|area|window …           a screen recording (zkde_screencast)\n\
             loft-kwin displays [set JSON]                   outputs through KScreen\n\
             loft-kwin input [set JSON]                      keyboard layouts (kxkbrc), mouse and trackpad (KWin's InputDevice)\n\
             loft-kwin spaces list                           the Activities (= Spaces), in Loft's order\n\
             loft-kwin spaces prune [--dry-run]              undo what older Loft builds did to Activities"
        );
        return Ok(());
    }

    let (snapshots_tx, mut snapshots) = mpsc::unbounded_channel::<String>();
    let (commands_tx, mut commands) = mpsc::unbounded_channel::<Value>();
    let state = Arc::new(Mutex::new(String::new()));
    let queue = Arc::new(Queue::default());

    let conn = match zbus::connection::Builder::session()?
        .name(BUS_NAME)?
        .serve_at(
            "/Bridge",
            Bridge { snapshots: snapshots_tx, commands: commands_tx, state: state.clone(), queue: queue.clone() },
        )?
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
    effects_off(&conn).await;

    tokio::spawn(watch_layouts(conn.clone()));
    tokio::spawn(activities::watch(conn.clone(), emit));
    // GStreamer's first run after an update scans every plugin (~10 s), and
    // auto's encoder probe takes a moment: do both now, so the first
    // recording starts at once (record.rs).
    tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(20)).await;
        record::warm_up().await;
    });

    let mut model = state::Model::new();
    // Display identities spell the vendor out like niri (LOFT_PNP_IDS: set
    // by the Nix package to hwdata's pnp.ids).
    let pnp_path = std::env::var("LOFT_PNP_IDS").unwrap_or_else(|_| "/run/current-system/sw/share/hwdata/pnp.ids".into());
    match std::fs::read_to_string(&pnp_path) {
        Ok(text) => model.pnp = state::parse_pnp_ids(&text),
        Err(e) => eprintln!("loft-kwin: no PNP ids ({pnp_path}: {e}); display vendors stay as ids"),
    }
    let spin = Spin { state: state.clone(), starting: Mutex::default() };
    let mut stdin = BufReader::new(tokio::io::stdin()).lines();
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;

    loop {
        tokio::select! {
            Some(json) = snapshots.recv() => {
                match serde_json::from_str::<state::Snapshot>(&json) {
                    Ok(snap) => {
                        let s = model.update(&snap, now());
                        *state.lock().unwrap() = s.to_string();
                        emit(&json!({ "State": s }));
                    }
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
                    Ok(cmd) => dispatch(&conn, &queue, &spin, cmd).await,
                    Err(e) => eprintln!("loft-kwin: bad command {line:?}: {e}"),
                }
            }
            Some(cmd) = commands.recv() => dispatch(&conn, &queue, &spin, cmd).await,
            _ = term.recv() => break,
            _ = tokio::signal::ctrl_c() => break,
        }
    }

    unload_script(&conn).await;
    effects_restore(&conn).await;
    // Exit now: tokio's stdin reader is a blocking thread that the runtime
    // would wait for on shutdown, so after SIGTERM the process would linger
    // without its bus name and the shell (which restarts loft-kwin when it
    // exits) would never notice.
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_bar_requests() {
        let cmd = title_bar_command(r#"{"action":"tileMenu","x":34,"y":27,"width":802,"height":641}"#).unwrap();
        assert_eq!(cmd, json!({"cmd": "titleBar", "action": "tileMenu", "x": 34.0, "y": 27.0, "width": 802.0, "height": 641.0}));
        assert!(title_bar_command(r#"{"action":"close","x":0,"y":0,"width":1,"height":1}"#).is_none());
        assert!(title_bar_command(r#"{"action":"menu","x":0,"y":0}"#).is_none());
        assert!(title_bar_command("not json").is_none());
    }

    #[test]
    fn commands_need_a_cmd() {
        assert_eq!(parse_command(r#"{"cmd":"toggleMaximize"}"#).unwrap()["cmd"], "toggleMaximize");
        assert!(parse_command(r#"{"window":"x"}"#).unwrap_err().contains("no \"cmd\""));
        assert!(parse_command(r#"{"cmd":1}"#).is_err());
        assert!(parse_command("nope").unwrap_err().starts_with("bad JSON"));
    }
}
