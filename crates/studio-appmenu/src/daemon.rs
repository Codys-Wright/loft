//! The daemon: registrar + menu reader, driven by the shell over stdin.

use std::collections::HashMap;
use std::io::Write as _;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::StreamExt;
use futures_util::stream::select_all;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio::task::JoinHandle;
use zbus::fdo::{DBusProxy, RequestNameFlags, RequestNameReply};
use zbus::message::Type as MsgType;
use zbus::{Connection, MatchRule, MessageStream};

use crate::discovery::{self, PidCache};
use crate::matching::{ProcTable, candidates, pick};
use crate::protocol::{Command, Event, Menu, RegistrarMode, Source, Status, parse_command};
use crate::registrar::{self, Entry, Registrar};
use crate::{dbusmenu, gtkmenu};

/// Messages into the main loop.
#[derive(Debug)]
pub enum Internal {
    Cmd(Command),
    BadLine(String),
    StdinClosed,
    Registered {
        pid: Option<u32>,
    },
    Unregistered {
        candidates: Vec<Entry>,
    },
    Gone(Vec<(String, String)>),
    NameVanished(String),
    RegistrarOwner(Option<String>),
    /// The bound menu emitted a change signal (generation).
    Changed(u64),
    Refresh(u64),
    /// Look again for a menu that wasn't there yet (focus generation, attempt).
    Retry(u64, usize),
}

/// Apps export their menubar a moment after mapping the window.
const RETRY_AFTER_MS: [u64; 4] = [300, 1000, 2500, 6000];
const CALL_TIMEOUT: Duration = Duration::from_secs(2);
const DEBOUNCE: Duration = Duration::from_millis(40);

#[derive(Debug, Clone, PartialEq, Eq)]
struct Focus {
    pid: u32,
    index: Option<usize>,
    count: Option<usize>,
    exclude: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Target {
    DBus {
        service: String,
        path: String,
        pid: u32,
    },
    Gtk {
        service: String,
        app_path: String,
        win_path: Option<String>,
        pid: u32,
    },
}

impl Target {
    fn service(&self) -> &str {
        match self {
            Target::DBus { service, .. } | Target::Gtk { service, .. } => service,
        }
    }
}

async fn within<T>(fut: impl Future<Output = T>) -> Option<T> {
    tokio::time::timeout(CALL_TIMEOUT, fut).await.ok()
}

struct App {
    conn: Connection,
    tx: UnboundedSender<Internal>,
    state: Arc<Mutex<registrar::State>>,
    mode: RegistrarMode,
    pids: PidCache,
    /// Unique name → GtkApplication paths with a menubar (introspection is
    /// the expensive part; dropped when the name goes away).
    gtk_apps: HashMap<String, Vec<String>>,
    protected: Vec<u32>,

    focus: Option<Focus>,
    focus_gen: u64,
    target: Option<Target>,
    generation: u64,
    watcher: Option<JoinHandle<()>>,
    refresh_pending: bool,
    gtk_groups: Vec<u32>,
    activations: HashMap<i32, gtkmenu::Activation>,
    raw: serde_json::Value,
    last_menu: String,
}

pub async fn run() -> Result<()> {
    let conn = Connection::session()
        .await
        .context("connecting to the session bus")?;
    let (tx, rx) = mpsc::unbounded_channel();
    let state = Arc::new(Mutex::new(registrar::State::default()));

    let mode = if matches!(
        std::env::var("STUDIO_APPMENU_REGISTRAR").as_deref(),
        Ok("0" | "off" | "false")
    ) {
        RegistrarMode::Off
    } else {
        conn.object_server()
            .at(
                registrar::PATH,
                Registrar {
                    state: state.clone(),
                    tx: tx.clone(),
                },
            )
            .await
            .context("serving the registrar object")?;
        request_registrar(&conn).await
    };

    let me = std::process::id();
    let mut protected = ProcTable::read().ancestors_of(me);
    protected.push(me);

    let mut app = App {
        conn: conn.clone(),
        tx: tx.clone(),
        state,
        mode,
        pids: PidCache::default(),
        gtk_apps: HashMap::new(),
        protected,
        focus: None,
        focus_gen: 0,
        target: None,
        generation: 0,
        watcher: None,
        refresh_pending: false,
        gtk_groups: Vec::new(),
        activations: HashMap::new(),
        raw: serde_json::Value::Null,
        last_menu: String::new(),
    };
    app.emit_status();

    tokio::spawn(read_stdin(tx.clone()));
    tokio::spawn(watch_names(conn, tx));
    app.run(rx).await;
    Ok(())
}

/// Takes the name unless someone (Plasma) has it; lets them replace us.
async fn request_registrar(conn: &Connection) -> RegistrarMode {
    let flags = RequestNameFlags::DoNotQueue | RequestNameFlags::AllowReplacement;
    match conn.request_name_with_flags(registrar::NAME, flags).await {
        Ok(RequestNameReply::PrimaryOwner | RequestNameReply::AlreadyOwner) => RegistrarMode::Owned,
        _ => RegistrarMode::External,
    }
}

async fn read_stdin(tx: UnboundedSender<Internal>) {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let msg = match parse_command(&line) {
            Ok(c) => Internal::Cmd(c),
            Err(e) => Internal::BadLine(e),
        };
        if tx.send(msg).is_err() {
            return;
        }
    }
    let _ = tx.send(Internal::StdinClosed);
}

async fn watch_names(conn: Connection, tx: UnboundedSender<Internal>) {
    let Ok(proxy) = DBusProxy::new(&conn).await else {
        return;
    };
    let Ok(mut changes) = proxy.receive_name_owner_changed().await else {
        return;
    };
    while let Some(sig) = changes.next().await {
        let Ok(args) = sig.args() else { continue };
        let name = args.name().to_string();
        let new_owner = args.new_owner().as_ref().map(|o| o.to_string());
        let msg = if name == registrar::NAME {
            Internal::RegistrarOwner(new_owner)
        } else if name.starts_with(':') && new_owner.is_none() {
            Internal::NameVanished(name)
        } else {
            continue;
        };
        if tx.send(msg).is_err() {
            return;
        }
    }
}

fn rule(service: &str, path: Option<&str>, interface: &str) -> Option<MatchRule<'static>> {
    let mut b = MatchRule::builder()
        .msg_type(MsgType::Signal)
        .sender(service)
        .ok()?
        .interface(interface)
        .ok()?;
    if let Some(p) = path {
        b = b.path(p).ok()?;
    }
    Some(b.build().to_owned().into_owned())
}

/// Forwards any signal matching `rules` as Changed(generation).
async fn watch_menu(
    conn: Connection,
    rules: Vec<MatchRule<'static>>,
    generation: u64,
    tx: UnboundedSender<Internal>,
) {
    let mut streams = Vec::new();
    for r in rules {
        if let Ok(s) = MessageStream::for_match_rule(r, &conn, Some(64)).await {
            streams.push(s);
        }
    }
    let mut all = select_all(streams);
    while all.next().await.is_some() {
        if tx.send(Internal::Changed(generation)).is_err() {
            return;
        }
    }
}

impl App {
    async fn run(&mut self, mut rx: UnboundedReceiver<Internal>) {
        while let Some(msg) = rx.recv().await {
            match msg {
                Internal::StdinClosed | Internal::Cmd(Command::Quit) => break,
                Internal::Cmd(c) => self.command(c).await,
                Internal::BadLine(e) => self.emit(&Event::Error(e)),
                Internal::Registered { .. } => {
                    if self.focus.is_some() {
                        self.resolve_and_bind().await;
                    }
                }
                Internal::Unregistered { candidates } => {
                    // The app drops the object right after; see which went.
                    let conn = self.conn.clone();
                    let tx = self.tx.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(250)).await;
                        let mut gone = Vec::new();
                        for e in candidates {
                            let alive = within(discovery::introspect(&conn, &e.service, &e.path))
                                .await
                                .and_then(|r| r.ok())
                                .is_some_and(|n| n.interfaces.iter().any(|i| i == dbusmenu::IFACE));
                            if !alive {
                                gone.push((e.service, e.path));
                            }
                        }
                        let _ = tx.send(Internal::Gone(gone));
                    });
                }
                Internal::Gone(paths) => {
                    let mut changed = false;
                    {
                        let mut st = self.state.lock().expect("registrar state");
                        for (s, p) in &paths {
                            changed |= st.remove(s, p);
                        }
                    }
                    if changed {
                        self.resolve_and_bind().await;
                    }
                }
                Internal::NameVanished(name) => {
                    self.pids.forget(&name);
                    self.gtk_apps.remove(&name);
                    let removed = self
                        .state
                        .lock()
                        .expect("registrar state")
                        .remove_service(&name);
                    if removed || self.target.as_ref().is_some_and(|t| t.service() == name) {
                        self.resolve_and_bind().await;
                    }
                }
                Internal::RegistrarOwner(owner) => self.registrar_owner(owner).await,
                Internal::Changed(generation) => {
                    if generation == self.generation && !self.refresh_pending {
                        self.refresh_pending = true;
                        let tx = self.tx.clone();
                        tokio::spawn(async move {
                            tokio::time::sleep(DEBOUNCE).await;
                            let _ = tx.send(Internal::Refresh(generation));
                        });
                    }
                }
                Internal::Refresh(generation) => {
                    if generation == self.generation {
                        self.refresh_pending = false;
                        self.fetch_emit().await;
                    }
                }
                Internal::Retry(fgen, attempt) => {
                    if fgen == self.focus_gen && self.target.is_none() && self.focus.is_some() {
                        self.resolve_and_bind().await;
                        if self.target.is_none() {
                            self.schedule_retry(attempt + 1);
                        }
                    }
                }
            }
        }
        self.unbind().await;
    }

    async fn registrar_owner(&mut self, owner: Option<String>) {
        let me = self.conn.unique_name().map(|n| n.to_string());
        let mode = match (self.mode, owner) {
            (RegistrarMode::Off, _) => RegistrarMode::Off,
            (_, Some(o)) if Some(&o) == me.as_ref() => RegistrarMode::Owned,
            (_, Some(_)) => RegistrarMode::External,
            // The other registrar left: take over.
            (_, None) => request_registrar(&self.conn).await,
        };
        if mode != self.mode {
            self.mode = mode;
            self.emit_status();
        }
    }

    fn schedule_retry(&self, attempt: usize) {
        let Some(&ms) = RETRY_AFTER_MS.get(attempt) else {
            return;
        };
        let tx = self.tx.clone();
        let fgen = self.focus_gen;
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(ms)).await;
            let _ = tx.send(Internal::Retry(fgen, attempt));
        });
    }

    async fn command(&mut self, cmd: Command) {
        match cmd {
            Command::Focus {
                pid,
                index,
                count,
                exclude,
            } => {
                let focus = pid.filter(|&p| p > 0).map(|pid| Focus {
                    pid,
                    index,
                    count,
                    exclude,
                });
                if focus == self.focus {
                    return;
                }
                self.focus = focus;
                self.focus_gen += 1;
                self.resolve_and_bind().await;
                if self.target.is_none() && self.focus.is_some() {
                    self.schedule_retry(0);
                }
            }
            Command::Activate { id } => self.activate(id).await,
            Command::Open { id } => {
                if let Some(Target::DBus { service, path, .. }) = self.target.clone() {
                    let _ = within(dbusmenu::about_to_show(&self.conn, &service, &path, id)).await;
                    let _ =
                        within(dbusmenu::event(&self.conn, &service, &path, id, "opened")).await;
                    // Lazy submenus fill in now; LayoutUpdated may or may not follow.
                    let _ = self.tx.send(Internal::Changed(self.generation));
                }
            }
            Command::Close { id } => {
                if let Some(Target::DBus { service, path, .. }) = self.target.clone() {
                    let _ =
                        within(dbusmenu::event(&self.conn, &service, &path, id, "closed")).await;
                }
            }
            Command::Refresh => {
                self.last_menu.clear();
                self.fetch_emit().await;
            }
            Command::List => {
                let list = self.state.lock().expect("registrar state").list();
                self.emit(&Event::Menus(list));
            }
            Command::Dump => self.emit(&Event::Dump(self.raw.clone())),
            Command::Quit => {}
        }
    }

    async fn activate(&mut self, id: i32) {
        let result = match self.target.clone() {
            None => return,
            Some(Target::DBus { service, path, .. }) => {
                within(dbusmenu::event(&self.conn, &service, &path, id, "clicked")).await
            }
            Some(Target::Gtk {
                service,
                app_path,
                win_path,
                ..
            }) => {
                let Some(act) = self.activations.get(&id).cloned() else {
                    self.emit(&Event::Error(format!("no action for item {id}")));
                    return;
                };
                let path = match act.group.as_str() {
                    "app" => Some(app_path),
                    _ => win_path,
                };
                let Some(path) = path else {
                    self.emit(&Event::Error(format!(
                        "no window action group for {}",
                        act.name
                    )));
                    return;
                };
                within(gtkmenu::activate(
                    &self.conn,
                    &service,
                    &path,
                    &act.name,
                    act.target.as_ref(),
                ))
                .await
            }
        };
        match result {
            Some(Ok(())) => {}
            Some(Err(e)) => self.emit(&Event::Error(format!("activate {id}: {e}"))),
            None => self.emit(&Event::Error(format!("activate {id}: timed out"))),
        }
    }

    /// The menu for the focused window, if any.
    async fn resolve(&mut self) -> Option<Target> {
        let mut f = self.focus.clone()?;

        // X11 window: niri gave us xwayland-satellite's pid; ask X instead.
        if crate::x11::is_xwayland_bridge(f.pid) {
            let active = within(tokio::task::spawn_blocking(crate::x11::active_window))
                .await
                .and_then(|r| r.ok().flatten());
            if let Some(a) = active {
                if let Some(e) = self
                    .state
                    .lock()
                    .expect("registrar state")
                    .for_window(a.xid)
                {
                    return Some(Target::DBus {
                        service: e.service.clone(),
                        path: e.path.clone(),
                        pid: e.pid.unwrap_or(f.pid),
                    });
                }
                if let Some(pid) = a.pid {
                    // Registered before we started: Chromium/Electron export at
                    // /com/canonical/menu/<XID in hex>.
                    let path = format!("/com/canonical/menu/{:X}", a.xid);
                    for (name, p) in self.pids.connections_of(&self.conn, &[pid]).await {
                        if let Some(Ok(_)) =
                            within(dbusmenu::get_layout(&self.conn, &name, &path)).await
                        {
                            return Some(Target::DBus {
                                service: name,
                                path,
                                pid: p,
                            });
                        }
                    }
                    f = Focus {
                        pid,
                        index: None,
                        count: None,
                        exclude: f.exclude,
                    };
                }
            }
        }

        let table = ProcTable::read();
        let pids = candidates(&table, f.pid, &f.exclude, &self.protected);

        // Registered menubars (Qt registers as soon as the window shows).
        {
            let st = self.state.lock().expect("registrar state");
            for &pid in &pids {
                let entries = st.for_pid(pid);
                if let Some(e) = pick(&entries, f.index, f.count) {
                    return Some(Target::DBus {
                        service: e.service.clone(),
                        path: e.path.clone(),
                        pid,
                    });
                }
            }
        }

        // Introspection: Qt apps registered elsewhere, GTK menubars.
        let conns = self.pids.connections_of(&self.conn, &pids).await;
        for (name, pid) in &conns {
            let bars = within(discovery::qt_menubars(&self.conn, name))
                .await
                .unwrap_or_default();
            if let Some(path) = pick(&bars, f.index, f.count) {
                return Some(Target::DBus {
                    service: name.clone(),
                    path: path.to_string(),
                    pid: *pid,
                });
            }
        }
        for (name, pid) in &conns {
            let apps = match self.gtk_apps.get(name) {
                Some(a) => a.clone(),
                None => {
                    let a = within(discovery::gtk_apps(&self.conn, name))
                        .await
                        .unwrap_or_default();
                    self.gtk_apps.insert(name.clone(), a.clone());
                    a
                }
            };
            if let Some(app_path) = apps.first() {
                let windows = within(discovery::gtk_windows(&self.conn, name, app_path))
                    .await
                    .unwrap_or_default();
                return Some(Target::Gtk {
                    service: name.clone(),
                    app_path: app_path.to_string(),
                    win_path: pick(&windows, f.index, f.count).cloned(),
                    pid: *pid,
                });
            }
        }
        None
    }

    async fn resolve_and_bind(&mut self) {
        let target = self.resolve().await;
        if target == self.target {
            if target.is_none() {
                self.emit_menu(None);
            }
            return;
        }
        self.unbind().await;
        self.target = target;
        self.generation += 1;
        if let Some(t) = &self.target {
            let rules: Vec<MatchRule<'static>> = match t {
                Target::DBus { service, path, .. } => {
                    rule(service, Some(path.as_str()), dbusmenu::IFACE)
                        .into_iter()
                        .collect()
                }
                Target::Gtk {
                    service, app_path, ..
                } => [
                    rule(
                        service,
                        Some(&format!("{app_path}/menus/menubar")),
                        gtkmenu::MENUS,
                    ),
                    rule(service, None, gtkmenu::ACTIONS),
                ]
                .into_iter()
                .flatten()
                .collect(),
            };
            self.watcher = Some(tokio::spawn(watch_menu(
                self.conn.clone(),
                rules,
                self.generation,
                self.tx.clone(),
            )));
        }
        self.fetch_emit().await;
    }

    async fn unbind(&mut self) {
        if let Some(w) = self.watcher.take() {
            w.abort();
        }
        self.end_gtk().await;
        self.activations.clear();
        self.refresh_pending = false;
    }

    async fn end_gtk(&mut self) {
        if let Some(Target::Gtk {
            service, app_path, ..
        }) = &self.target
            && !self.gtk_groups.is_empty()
        {
            let groups = std::mem::take(&mut self.gtk_groups);
            let _ = within(gtkmenu::end(
                &self.conn,
                service,
                &format!("{app_path}/menus/menubar"),
                groups,
            ))
            .await;
        }
    }

    async fn fetch_emit(&mut self) {
        let menu = match self.target.clone() {
            None => None,
            Some(Target::DBus { service, path, pid }) => {
                match within(dbusmenu::get_layout(&self.conn, &service, &path)).await {
                    Some(Ok(root)) => {
                        self.raw = serde_json::to_value(&root).unwrap_or_default();
                        Some(Menu {
                            source: Source::Dbusmenu,
                            pid,
                            service,
                            path,
                            items: dbusmenu::to_items(&root),
                        })
                    }
                    other => {
                        self.report("GetLayout", other);
                        None
                    }
                }
            }
            Some(Target::Gtk {
                service,
                app_path,
                win_path,
                pid,
            }) => {
                self.end_gtk().await;
                let menubar = format!("{app_path}/menus/menubar");
                match within(gtkmenu::load_menus(&self.conn, &service, &menubar)).await {
                    Some(Ok((menus, groups))) => {
                        self.gtk_groups = groups;
                        let mut raw = gtkmenu::RawGtk {
                            menus,
                            actions: Default::default(),
                        };
                        if let Some(Ok(a)) = within(gtkmenu::describe_all(
                            &self.conn, &service, &app_path, "app",
                        ))
                        .await
                        {
                            raw.actions.extend(a);
                        }
                        if let Some(w) = &win_path
                            && let Some(Ok(a)) =
                                within(gtkmenu::describe_all(&self.conn, &service, w, "win")).await
                        {
                            raw.actions.extend(a);
                        }
                        let built = gtkmenu::build(&raw);
                        self.raw = serde_json::to_value(&raw).unwrap_or_default();
                        self.activations = built.activations;
                        Some(Menu {
                            source: Source::Gtk,
                            pid,
                            service,
                            path: menubar,
                            items: built.items,
                        })
                    }
                    other => {
                        self.report("org.gtk.Menus.Start", other);
                        None
                    }
                }
            }
        };
        self.emit_menu(menu);
    }

    fn report<T>(&self, what: &str, r: Option<zbus::Result<T>>) {
        let msg = match r {
            Some(Err(e)) => format!("{what}: {e}"),
            None => format!("{what}: timed out"),
            Some(Ok(_)) => return,
        };
        self.emit(&Event::Error(msg));
    }

    fn emit_menu(&mut self, menu: Option<Menu>) {
        // Top-level titles only matter if there are any.
        let menu = menu.filter(|m| !m.items.is_empty());
        let line = Event::Menu(menu).to_line();
        if line != self.last_menu {
            write_line(&line);
            self.last_menu = line;
        }
    }

    fn emit_status(&self) {
        self.emit(&Event::Status(Status {
            registrar: self.mode,
            version: env!("CARGO_PKG_VERSION"),
        }));
    }

    fn emit(&self, event: &Event) {
        write_line(&event.to_line());
    }
}

fn write_line(line: &str) {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(line.as_bytes());
    let _ = out.flush();
}
