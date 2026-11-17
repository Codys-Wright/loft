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
//! - Spaces as Activities (src/activities.rs): stdin `syncSpaces` makes
//!   kactivitymanagerd match the shell's Space list and answers
//!   `{"Spaces": {"map": {space: activity}, …}}`; `loft-kwin spaces list|prune`.
//! - Where windows open (src/placement.rs, docs/KWIN.md §4.13): Loft's
//!   window rules go to the script (`setWindowRules`); `loft-kwin expect
//!   JSON` (`loft open`) places the windows of a started process tree.
//!   The state carries `activity_names` ({id: name}, kactivitymanagerd's).

mod activities;
mod displays;
mod input;
mod placement;
mod record;
mod shot;
mod state;

use std::collections::{BTreeMap, VecDeque};
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

/// A command from another process, and where its answer goes (`Expect`).
type Incoming = (Value, Option<tokio::sync::oneshot::Sender<Result<Value, String>>>);

struct Bridge {
    snapshots: mpsc::UnboundedSender<String>,
    /// Commands from other processes (`loft-kwin send`), handled like stdin's.
    commands: mpsc::UnboundedSender<Incoming>,
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
            .send((cmd, None))
            .map_err(|_| zbus::fdo::Error::Failed("loft-kwin is shutting down".into()))
    }

    /// Place the next windows of a started process (`loft open`):
    /// `{"pid", "activityName"?, "desktop"?, "output"? (connector or role),
    /// "open"?, "size"?, "position"?, "keepAbove"?, "follow"?, "appId"?,
    /// "ttl"?, "count"?}`. Answers `{"id", "output", "pid"}`, or fails with
    /// the reason (no such display, no pid).
    async fn expect(&self, json: String) -> zbus::fdo::Result<String> {
        let mut cmd: Value = serde_json::from_str(&json).map_err(|e| zbus::fdo::Error::InvalidArgs(format!("bad JSON: {e}")))?;
        cmd["cmd"] = json!("expectWindow");
        cmd["tree"] = json!(true);
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.commands
            .send((cmd, Some(tx)))
            .map_err(|_| zbus::fdo::Error::Failed("loft-kwin is shutting down".into()))?;
        match rx.await {
            Ok(Ok(v)) => Ok(v.to_string()),
            Ok(Err(e)) => Err(zbus::fdo::Error::Failed(e)),
            Err(_) => Err(zbus::fdo::Error::Failed("loft-kwin dropped the request".into())),
        }
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
        [verb, json] if verb == "expect" => {
            serde_json::from_str::<Value>(json).context("expect: bad JSON")?;
            let r: zbus::Result<String> = p.call("Expect", &(json.as_str(),)).await;
            match r {
                Ok(s) => println!("{s}"),
                Err(zbus::Error::MethodError(name, Some(msg), _)) if name.as_str() == "org.freedesktop.DBus.Error.Failed" => {
                    anyhow::bail!("{msg}")
                }
                Err(e) => return Err(anyhow::Error::new(e).context(not_running())),
            }
        }
        _ => anyhow::bail!("usage: loft-kwin send JSON | loft-kwin state | loft-kwin expect JSON"),
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
        "syncSpaces" => {
            let spaces: Vec<activities::SpaceInfo> = serde_json::from_value(cmd["spaces"].clone())?;
            emit(&activities::sync(conn, &activities::state_dir(), &spaces).await?);
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

/// A command from stdin or `Command`: KWin's D-Bus API, else the script.
async fn dispatch(conn: &Connection, queue: &Queue, cmd: Value) {
    match direct(conn, &cmd).await {
        Ok(true) => {}
        Ok(false) => queue.push(cmd),
        Err(e) => eprintln!("loft-kwin: {}: {e:#}", cmd["cmd"]),
    }
}

/// Rules and expected windows (src/placement.rs), owned by the main loop.
#[derive(Default)]
struct Places {
    /// placement::layout_key of the last state the rules were sent for.
    layout: String,
    /// Activity id → name (kactivitymanagerd).
    names: BTreeMap<String, String>,
    roles: BTreeMap<String, Vec<String>>,
    sources: Vec<std::path::PathBuf>,
    mtimes: Vec<Option<SystemTime>>,
    expects: Vec<placement::Expect>,
    last_error: String,
}

impl Places {
    /// Ask loft-niri for the rules and send them to the script.
    async fn reload(&mut self, queue: &Queue, state: &Value) {
        match placement::fetch_rules(&placement::displays_arg(state)).await {
            Ok(v) => {
                self.roles = serde_json::from_value(v["roles"].clone()).unwrap_or_default();
                self.sources = v["sources"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|p| p.as_str().map(std::path::PathBuf::from))
                    .collect();
                self.mtimes = placement::mtimes(&self.sources);
                self.last_error.clear();
                queue.push(json!({ "cmd": "setWindowRules", "rules": v["rules"], "activityNames": self.names }));
            }
            Err(e) => {
                if e != self.last_error {
                    eprintln!("loft-kwin: window rules: {e}");
                    self.last_error = e;
                }
            }
        }
    }

    /// New windows of the expected process trees → `placeWindow`.
    fn expected(&mut self, queue: &Queue, state: &Value) {
        if self.expects.is_empty() {
            return;
        }
        let procs = placement::RealProcs("/proc".into());
        let wins = placement::windows_of(state);
        let now = std::time::Instant::now();
        for e in &mut self.expects {
            for w in &wins {
                if !e.expired(now) && e.matches(w, now, &procs) {
                    e.placed.insert(w.uuid.clone());
                    queue.push(e.place_cmd(&w.uuid));
                }
            }
        }
        self.expects.retain(|e| !e.expired(now));
    }

    fn expect(&mut self, queue: &Queue, state: &Value, cmd: &Value) -> Result<Value, String> {
        let procs = placement::RealProcs("/proc".into());
        let mut cmd = cmd.clone();
        if cmd["id"].as_str().is_none_or(str::is_empty) {
            cmd["id"] = json!(format!("open-{}-{}", cmd["pid"], now().as_millis() % 100_000));
        }
        let e = placement::Expect::new(&cmd, &placement::windows_of(state), &self.roles, &procs)?;
        let answer = json!({ "id": e.id, "pid": e.root, "output": e.place.get("output"), "ttl_ms": e.ttl.as_millis() as u64 });
        // `dryRun`: only check it (a display that isn't there) before starting anything.
        if cmd["dryRun"] == true {
            return Ok(answer);
        }
        queue.push(e.script_cmd());
        self.expects.push(e);
        // Windows already there (an app quicker than this).
        self.expected(queue, state);
        Ok(answer)
    }
}

fn current(state: &Mutex<String>) -> Value {
    serde_json::from_str(&state.lock().unwrap()).unwrap_or(Value::Null)
}

/// Activity id → name; empty without kactivitymanagerd.
async fn activity_names(conn: &Connection) -> BTreeMap<String, String> {
    let Ok(p) = activities::proxy(conn).await else { return BTreeMap::new() };
    match activities::list(&p).await {
        Ok((list, _)) => list.into_iter().map(|a| (a.id, a.name)).collect(),
        Err(_) => BTreeMap::new(),
    }
}

/// kactivitymanagerd's signals (an Activity added, removed, renamed): the
/// names (and the rules naming them) need refreshing.
async fn watch_activities(conn: Connection, tx: mpsc::UnboundedSender<()>) {
    let Ok(p) = activities::proxy(&conn).await else { return };
    let Ok(mut all) = p.receive_all_signals().await else { return };
    while all.next().await.is_some() {
        if tx.send(()).is_err() {
            return;
        }
    }
}

/// Stdin's and other processes' commands: placement's here, else dispatch.
async fn handle(
    conn: &Connection,
    queue: &Queue,
    state: &Mutex<String>,
    places: &mut Places,
    cmd: Value,
    reply: Option<tokio::sync::oneshot::Sender<Result<Value, String>>>,
) {
    let answer = match cmd["cmd"].as_str() {
        Some("expectWindow") if cmd["tree"] == true => {
            let s = current(state);
            places.expect(queue, &s, &cmd)
        }
        Some("reloadWindowRules") => {
            let s = current(state);
            places.reload(queue, &s).await;
            Ok(json!({ "ok": true }))
        }
        _ => {
            dispatch(conn, queue, cmd).await;
            Ok(json!({ "ok": true }))
        }
    };
    match reply {
        Some(tx) => drop(tx.send(answer)),
        None => {
            if let Err(e) = answer {
                eprintln!("loft-kwin: {e}");
            }
        }
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
    if args.first().is_some_and(|a| a == "send" || a == "state" || a == "expect") {
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
             loft-kwin expect JSON                           place the next windows of a started pid (loft open)\n\
             loft-kwin shot screen|window|area|workspace …   a screenshot (ScreenShot2)\n\
             loft-kwin thumbs DIR MAX_PX UUID…               window stills for the dock and switcher\n\
             loft-kwin record screen|area|window …           a screen recording (zkde_screencast)\n\
             loft-kwin displays [set JSON]                   outputs through KScreen\n\
             loft-kwin input [set JSON]                      keyboard layouts (kxkbrc), mouse and trackpad (KWin's InputDevice)\n\
             loft-kwin spaces list                           Spaces ↔ Activities map\n\
             loft-kwin spaces prune [--dry-run] [--force]    remove the Activities Loft made"
        );
        return Ok(());
    }

    let (snapshots_tx, mut snapshots) = mpsc::unbounded_channel::<String>();
    let (commands_tx, mut commands) = mpsc::unbounded_channel::<Incoming>();
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
    let mut stdin = BufReader::new(tokio::io::stdin()).lines();
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut places = Places::default();
    let (names_tx, mut names_changed) = mpsc::unbounded_channel::<()>();
    tokio::spawn(watch_activities(conn.clone(), names_tx));
    let mut tick = tokio::time::interval(Duration::from_secs(2));

    loop {
        tokio::select! {
            Some(json) = snapshots.recv() => {
                match serde_json::from_str::<state::Snapshot>(&json) {
                    Ok(snap) => {
                        let mut s = model.update(&snap, now());
                        let key = placement::layout_key(&s);
                        let relayout = key != places.layout;
                        if relayout {
                            places.layout = key;
                            places.names = activity_names(&conn).await;
                        }
                        s["activity_names"] = json!(places.names);
                        *state.lock().unwrap() = s.to_string();
                        emit(&json!({ "State": s }));
                        if relayout {
                            places.reload(&queue, &s).await;
                        }
                        places.expected(&queue, &s);
                    }
                    Err(e) => eprintln!("loft-kwin: bad snapshot: {e}"),
                }
            }
            _ = tick.tick() => {
                if !places.sources.is_empty() && placement::mtimes(&places.sources) != places.mtimes {
                    let s = current(&state);
                    places.reload(&queue, &s).await;
                }
            }
            Some(()) = names_changed.recv() => {
                places.names = activity_names(&conn).await;
                let s = current(&state);
                if !s.is_null() {
                    places.reload(&queue, &s).await;
                }
            }
            line = stdin.next_line() => {
                let Ok(Some(line)) = line else { break };
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(line) {
                    Ok(cmd) => handle(&conn, &queue, &state, &mut places, cmd, None).await,
                    Err(e) => eprintln!("loft-kwin: bad command {line:?}: {e}"),
                }
            }
            Some((cmd, reply)) = commands.recv() => handle(&conn, &queue, &state, &mut places, cmd, reply).await,
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
