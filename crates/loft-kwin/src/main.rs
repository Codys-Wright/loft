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
//! - Spaces are the user's KDE Activities (src/activities.rs):
//!   stdin `activities` answers `{"Activities": {"activities": [{id, name,
//!   icon, key, position}], "current"}}` in KDE's "Switch to activity" key
//!   order, sent again on every change; `loft-kwin spaces list|prune`.
//!   stdin `activity` (src/manage.rs) creates, renames, re-icons, reorders
//!   (their keys) or removes one in KDE, answered with `{"ActivityEdit"}`;
//!   `loft-kwin spaces new|rename|icon|move|order|remove` (D-Bus
//!   `Activity`). A rename, from anywhere, relinks Loft's settings and window
//!   rules that named the old name (`{"ActivityLinks"}`).
//!   stdin `openSpace` starts a Space's missing apps in its Activity, on
//!   their roles' displays (src/spinup.rs), answered with `{"SpaceOpened"}`;
//!   `closeSpace` closes the windows of its Activity that are its apps
//!   (`dryRun`: lists them), answered with `{"SpaceClosed"}`.
//! - Self-healing (src/heal.rs, docs/KWIN.md §4.18): the bridge script and
//!   Loft's shortcuts script (`loft-keys`) are loaded again when KWin loses
//!   them (a KWin restart, an unload, a script that never started).
//! - stdout `{"Shortcut": {"name": "loft-…", "state": "pressed"|"repeated"|
//!   "released"}}`: Loft's global shortcuts held and let go (src/keys.rs).
//! - Where windows open (src/placement.rs, docs/KWIN.md §4.17): Loft's
//!   window rules go to the script (`setWindowRules`, with the Activities'
//!   names from the same report as `{"Activities"}`); `loft-kwin expect
//!   JSON` (`loft open`) and `openSpace` place the windows of a started
//!   process tree, through one expectation (placement::Expect).
//! - Serves `org.kde.KWin.ClientWindowMenu` on `/WindowMenu` for Loft's patched
//!   KWin: window menus apps with their own title bars ask for (docs/KWIN.md §4.4).

mod activities;
mod displays;
mod heal;
mod input;
mod keys;
mod manage;
mod placement;
mod record;
mod shot;
mod spinup;
mod state;

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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
    /// The script's polls, for the healer (src/heal.rs).
    live: Arc<heal::Liveness>,
}

/// Marks a NextCommands poll as in flight until dropped (also when zbus
/// drops the call).
struct InFlight<'a>(&'a heal::Liveness);

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.0.end();
    }
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
        self.live.begin();
        let _in_flight = InFlight(&self.live);
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

    /// Create, rename, re-icon, reorder or remove a KDE Activity
    /// (src/manage.rs, `loft-kwin spaces new|rename|…`): the `{"op": …}`
    /// edit; answers the `ActivityEdit` object (`ok`, `error`, `notes`).
    async fn activity(&self, json: String) -> zbus::fdo::Result<String> {
        let mut cmd: Value = serde_json::from_str(&json).map_err(|e| zbus::fdo::Error::InvalidArgs(format!("bad JSON: {e}")))?;
        cmd["cmd"] = json!("activity");
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

/// A window menu an app with its own title bar asked for (GTK / libadwaita
/// header bars, Chromium's, X11's `_GTK_SHOW_WINDOW_MENU`), from Loft's
/// patched KWin (nix/kwin/client-window-menu-service.patch, kwinrc
/// `[Windows] ClientWindowMenuService=dev.loft.KWinBridge`; docs/KWIN.md §4.4).
struct ClientWindowMenu {
    queue: Arc<Queue>,
}

#[interface(name = "org.kde.KWin.ClientWindowMenu")]
impl ClientWindowMenu {
    /// `window`: KWin's internal id; `x`, `y`: the global point the app asked
    /// for. True = Loft's menu opens there; false = KWin shows its own.
    async fn show(&self, window: String, x: f64, y: f64) -> bool {
        match client_menu_command(&window, x, y) {
            Some(cmd) => {
                self.queue.push(cmd);
                true
            }
            None => false,
        }
    }
}

/// A client's window-menu request → the script's `clientMenu` command.
fn client_menu_command(window: &str, x: f64, y: f64) -> Option<Value> {
    let id = window.trim();
    let uuid = id.len() == 38 && id.starts_with('{') && id.ends_with('}');
    (uuid && x.is_finite() && y.is_finite()).then(|| json!({"cmd": "clientMenu", "window": id, "x": x, "y": y}))
}

/// A command line: a JSON object with a string `cmd`.
fn parse_command(json: &str) -> Result<Value, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("bad JSON: {e}"))?;
    if !v["cmd"].is_string() {
        return Err(format!("not a command (no \"cmd\"): {json}"));
    }
    Ok(v)
}

/// `loft-kwin spaces new|rename|…`: through the running daemon (which moves a
/// removed Activity's windows and relinks on a rename), else straight to KDE.
async fn edit_cli(cmd: Value) -> Result<()> {
    let conn = Connection::session().await.context("the session bus")?;
    let dbus = zbus::fdo::DBusProxy::new(&conn).await?;
    let running = match zbus::names::BusName::try_from(BUS_NAME) {
        Ok(n) => dbus.name_has_owner(n).await.unwrap_or(false),
        Err(_) => false,
    };
    let r: Value = if running {
        let p = Proxy::new(&conn, BUS_NAME, "/Bridge", BUS_NAME).await?;
        let s: String = p.call("Activity", &(cmd.to_string(),)).await.context("loft-kwin's Activity method")?;
        serde_json::from_str(&s)?
    } else {
        manage::edit_line(&conn, &cmd, None).await["ActivityEdit"].clone()
    };
    for n in r["notes"].as_array().into_iter().flatten().filter_map(Value::as_str) {
        eprintln!("{n}");
    }
    if r["ok"] != true {
        anyhow::bail!("{}", r["error"].as_str().unwrap_or("that didn't work"));
    }
    println!("{}", serde_json::to_string(&r)?);
    Ok(())
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
    // Start it through Scripting.start (runs every loaded script that isn't
    // running yet; running ones are left alone), not `run` on
    // /Scripting/Script<id>: KWin reuses script ids, and with another
    // script (loft-keys, xremap) loaded and unloaded around us that path
    // could name the wrong script, leaving ours loaded but never started.
    let () = scripting.call("start", &()).await.context("starting the loft-bridge KWin script")?;
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

/// What the command loop keeps between commands: the last state (shared
/// with the D-Bus interface), where windows open (rules, expectations),
/// the Activities, and the apps `openSpace` started recently whose window
/// hasn't shown up ((space, app) → when).
struct Daemon {
    state: Arc<Mutex<String>>,
    places: Places,
    starting: HashMap<(String, String), Instant>,
}

impl Daemon {
    fn current(&self) -> Value {
        serde_json::from_str(&self.state.lock().unwrap()).unwrap_or(Value::Null)
    }
}

/// `openSpace` (src/spinup.rs): find, place, start; the started apps'
/// windows are expected like `loft open`'s (Places::expect); report.
fn open_space(queue: &Queue, d: &mut Daemon, cmd: &Value) -> Value {
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
    let state = d.current();
    let wins = spinup::windows_from_state(&state, Some(std::path::Path::new("/proc")));
    let ttl = Duration::from_millis(spinup::EXPECT_MS);
    d.starting.retain(|_, t| t.elapsed() < ttl);
    let recent: std::collections::BTreeSet<String> =
        d.starting.keys().filter(|(s, _)| *s == space).map(|(_, a)| a.clone()).collect();
    let mut rows = Vec::new();
    for step in spinup::plan(&apps, &matchers, &wins, &activity, &recent) {
        use spinup::Step;
        let (i, window, spawn) = match step {
            Step::Found { app, uuid, move_to } => {
                d.starting.remove(&(space.clone(), apps[app].app.clone()));
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
                            let e = spinup::expect_cmd(a, m, &activity, Some(pid));
                            if let Err(err) = d.places.expect(queue, &state, &e) {
                                notes.push(format!("{}: {err}", a.app));
                            }
                        }
                        d.starting.insert((space.clone(), a.app.clone()), Instant::now());
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

/// `closeSpace` (src/spinup.rs `close_targets`): close the windows of the
/// Space's Activity that are its apps (`dryRun`: only say which). KWin's
/// close is a polite request: an app with unsaved changes asks first, as
/// on ⌘W. The Activity itself stays. Answers `{"SpaceClosed": {space,
/// activity, dryRun, windows: [{app, window, app_id, title}], notes}}`.
fn close_space(queue: &Queue, d: &mut Daemon, cmd: &Value) -> Value {
    let space = cmd["space"].as_str().unwrap_or("").to_string();
    let activity = cmd["activity"].as_str().unwrap_or("").to_string();
    let dry = cmd["dryRun"].as_bool() == Some(true);
    let mut notes: Vec<String> = Vec::new();
    let apps: Vec<spinup::AppReq> = match serde_json::from_value(cmd["apps"].clone()) {
        Ok(a) => a,
        Err(e) => {
            return json!({ "SpaceClosed": { "space": space, "activity": activity, "dryRun": dry, "windows": [], "notes": [format!("bad apps: {e}")] } });
        }
    };
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
    let state = d.current();
    let wins = spinup::windows_from_state(&state, Some(std::path::Path::new("/proc")));
    let rows: Vec<Value> = spinup::close_targets(&apps, &matchers, &wins, &activity)
        .into_iter()
        .map(|(i, uuid)| {
            let w = wins.iter().find(|w| w.uuid == uuid);
            if !dry {
                queue.push(json!({ "cmd": "closeWindow", "window": uuid }));
            }
            json!({ "app": apps[i].app, "window": uuid,
                    "app_id": w.map(|w| w.app_id.clone()), "title": w.map(|w| w.title.clone()) })
        })
        .collect();
    if !dry {
        // Closed on purpose: the next Open starts them again at once.
        d.starting.retain(|(s, _), _| *s != space);
    }
    json!({ "SpaceClosed": { "space": space, "activity": activity, "dryRun": dry, "windows": rows, "notes": notes } })
}

/// Rules and expected windows (src/placement.rs).
#[derive(Default)]
struct Places {
    /// placement::layout_key of the last state the rules were sent for.
    layout: String,
    /// The Activities as last reported (activities.rs: id, name, …).
    activities: Vec<placement::ActivityName>,
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
                let names = placement::names_by_id(&self.activities);
                queue.push(json!({ "cmd": "setWindowRules", "rules": v["rules"], "activityNames": names }));
            }
            Err(e) => {
                if e != self.last_error {
                    eprintln!("loft-kwin: window rules: {e}");
                    self.last_error = e;
                }
            }
        }
    }

    /// An `{"Activities"}` report: true if the names changed (the rules
    /// naming them go to the script again).
    fn set_activities(&mut self, report: &Value) -> bool {
        let list = placement::activities_of(report);
        if report["Activities"]["error"].is_string() && list.is_empty() {
            return false;
        }
        let changed = list != self.activities;
        self.activities = list;
        changed
    }

    /// New windows of the expected process trees → `placeWindow`.
    fn expected(&mut self, queue: &Queue, state: &Value) {
        if self.expects.is_empty() {
            return;
        }
        let procs = placement::RealProcs("/proc".into());
        let wins = placement::windows_of(state);
        let now = Instant::now();
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

    /// `expectWindow` with a process tree (`loft open`, `openSpace`).
    fn expect(&mut self, queue: &Queue, state: &Value, cmd: &Value) -> Result<Value, String> {
        let procs = placement::RealProcs("/proc".into());
        let mut cmd = cmd.clone();
        if cmd["id"].as_str().is_none_or(str::is_empty) {
            cmd["id"] = json!(format!("open-{}-{}", cmd["pid"], now().as_millis() % 100_000));
        }
        let roles = placement::with_outputs(&self.roles, state);
        let e = placement::Expect::new(&cmd, &placement::windows_of(state), &roles, &self.activities, &procs)?;
        let answer = json!({ "id": e.id, "pid": e.root, "output": e.place.get("output"), "ttl_ms": e.ttl.as_millis() as u64 });
        // `dryRun`: only check it (a display or Activity that isn't there)
        // before starting anything.
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

/// Stdin's and other processes' commands: the ones with state here, KWin's
/// D-Bus API next, else the script. `reply` (`loft-kwin expect`) gets the
/// answer; without one an error is logged.
async fn handle(
    conn: &Connection,
    queue: &Queue,
    d: &mut Daemon,
    cmd: Value,
    reply: Option<tokio::sync::oneshot::Sender<Result<Value, String>>>,
) {
    let ok = || Ok(json!({ "ok": true }));
    let answer = match cmd["cmd"].as_str().unwrap_or("") {
        "expectWindow" if cmd["tree"] == true => {
            let s = d.current();
            d.places.expect(queue, &s, &cmd)
        }
        "reloadWindowRules" => {
            let s = d.current();
            d.places.reload(queue, &s).await;
            ok()
        }
        "openSpace" => {
            let r = open_space(queue, d, &cmd);
            emit(&r);
            Ok(r)
        }
        "closeSpace" => {
            let r = close_space(queue, d, &cmd);
            emit(&r);
            Ok(r)
        }
        // Spaces are the user's Activities (src/activities.rs). `syncSpaces`
        // is what older shells sent; it gets the same answer.
        "activities" | "syncSpaces" => {
            let r = activities::report(conn).await;
            activities_changed(queue, d, &r).await;
            emit(&r);
            Ok(r)
        }
        // Create, rename, re-icon, reorder or remove one, in KDE
        // (src/manage.rs). A removed Activity's own windows move to its
        // neighbour through the script.
        "activity" => {
            let windows = manage::windows_of(&d.current());
            let move_window = |w: &str, to: &str| queue.push(json!({ "cmd": "setWindowActivities", "window": w, "activities": [to] }));
            let line = manage::edit_line(conn, &cmd, Some(manage::Ctx { windows, move_window: &move_window })).await;
            emit(&line);
            Ok(line["ActivityEdit"].clone())
        }
        _ => match direct(conn, &cmd).await {
            Ok(true) => ok(),
            Ok(false) => {
                queue.push(cmd);
                ok()
            }
            Err(e) => Err(format!("{}: {e:#}", cmd["cmd"])),
        },
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

/// A new `{"Activities"}` report: rules naming an Activity follow a rename,
/// and so do Loft's settings and rules that named the old name (whoever
/// renamed it: Loft, `loft-kwin spaces rename` or Plasma).
async fn activities_changed(queue: &Queue, d: &mut Daemon, report: &Value) {
    let before: Vec<(String, String)> = d.places.activities.iter().map(|a| (a.id.clone(), a.name.clone())).collect();
    let now: Vec<(String, String)> = placement::activities_of(report).into_iter().map(|a| (a.id, a.name)).collect();
    for (id, old, new) in manage::renames(&before, &now) {
        tokio::spawn(async move {
            let r = manage::fix_links(&id, &old, &new).await;
            emit(&json!({ "ActivityLinks": r }));
        });
    }
    if d.places.set_activities(report) {
        let s = d.current();
        if !s.is_null() {
            d.places.reload(queue, &s).await;
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
        if let Some(cmd) = manage::parse_cli(&args[1..]) {
            return edit_cli(cmd.map_err(anyhow::Error::msg)?).await;
        }
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
             loft-kwin spaces list                           the Activities (= Spaces), in Loft's order\n\
             loft-kwin spaces prune [--dry-run]              undo what older Loft builds did to Activities"
        );
        return Ok(());
    }

    let (snapshots_tx, mut snapshots) = mpsc::unbounded_channel::<String>();
    let (commands_tx, mut commands) = mpsc::unbounded_channel::<Incoming>();
    let state = Arc::new(Mutex::new(String::new()));
    let queue = Arc::new(Queue::default());
    let live = Arc::new(heal::Liveness::default());
    let stopping = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let conn = match zbus::connection::Builder::session()?
        .name(BUS_NAME)?
        .serve_at(
            "/Bridge",
            Bridge {
                snapshots: snapshots_tx,
                commands: commands_tx,
                state: state.clone(),
                queue: queue.clone(),
                live: live.clone(),
            },
        )?
        .serve_at("/WindowMenu", ClientWindowMenu { queue: queue.clone() })?
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
    tokio::spawn(keys::watch(conn.clone(), emit));
    // The Activities reports come through the loop: it passes them on and
    // keeps the names for the window rules.
    let (reports_tx, mut reports) = mpsc::unbounded_channel::<Value>();
    tokio::spawn(activities::watch(conn.clone(), move |r: &Value| drop(reports_tx.send(r.clone()))));
    tokio::spawn(heal::watch(conn.clone(), live, stopping.clone()));
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
    let mut d = Daemon { state: state.clone(), places: Places::default(), starting: HashMap::new() };
    // The rules' files are polled (a change reloads them).
    let mut tick = tokio::time::interval(Duration::from_secs(2));

    loop {
        tokio::select! {
            Some(json) = snapshots.recv() => {
                match serde_json::from_str::<state::Snapshot>(&json) {
                    Ok(snap) => {
                        let s = model.update(&snap, now());
                        *state.lock().unwrap() = s.to_string();
                        emit(&json!({ "State": s }));
                        let key = placement::layout_key(&s);
                        if key != d.places.layout {
                            d.places.layout = key;
                            d.places.reload(&queue, &s).await;
                        }
                        d.places.expected(&queue, &s);
                    }
                    Err(e) => eprintln!("loft-kwin: bad snapshot: {e}"),
                }
            }
            _ = tick.tick() => {
                if !d.places.sources.is_empty() && placement::mtimes(&d.places.sources) != d.places.mtimes {
                    let s = d.current();
                    d.places.reload(&queue, &s).await;
                }
            }
            Some(r) = reports.recv() => {
                activities_changed(&queue, &mut d, &r).await;
                emit(&r);
            }
            line = stdin.next_line() => {
                let Ok(Some(line)) = line else { break };
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(line) {
                    Ok(cmd) => handle(&conn, &queue, &mut d, cmd, None).await,
                    Err(e) => eprintln!("loft-kwin: bad command {line:?}: {e}"),
                }
            }
            Some((cmd, reply)) = commands.recv() => handle(&conn, &queue, &mut d, cmd, reply).await,
            _ = term.recv() => break,
            _ = tokio::signal::ctrl_c() => break,
        }
    }

    // Before unloading: the healer must not put the bridge back.
    stopping.store(true, std::sync::atomic::Ordering::SeqCst);
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
    fn client_menu_requests() {
        let id = "{0b5c6a2e-8d6f-4c1e-9a3b-2f1d7e4c5a60}";
        assert_eq!(
            client_menu_command(id, 412.5, 88.0).unwrap(),
            json!({"cmd": "clientMenu", "window": id, "x": 412.5, "y": 88.0})
        );
        assert!(client_menu_command("", 1.0, 1.0).is_none());
        assert!(client_menu_command("not-a-uuid", 1.0, 1.0).is_none());
        assert!(client_menu_command(id, f64::NAN, 1.0).is_none());
    }

    #[test]
    fn commands_need_a_cmd() {
        assert_eq!(parse_command(r#"{"cmd":"toggleMaximize"}"#).unwrap()["cmd"], "toggleMaximize");
        assert!(parse_command(r#"{"window":"x"}"#).unwrap_err().contains("no \"cmd\""));
        assert!(parse_command(r#"{"cmd":1}"#).is_err());
        assert!(parse_command("nope").unwrap_err().starts_with("bad JSON"));
    }
}
