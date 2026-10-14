//! com.canonical.AppMenu.Registrar at /com/canonical/AppMenu/Registrar.
//!
//! Qt (QGenericUnixTheme / plasma-integration) exports a window's QMenuBar
//! over DBusMenu — and hides the in-window menubar — only when this name is
//! on the session bus at startup; it then calls RegisterWindow(winId,
//! "/MenuBar/<n>"). Window ids are X11 ids, meaningless on Wayland (Qt may
//! send the same id for every window), so entries are keyed by the
//! sender's connection + path and matched to windows by the sender's pid.

use std::sync::{Arc, Mutex};

use tokio::sync::mpsc::UnboundedSender;
use zbus::fdo;
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{ObjectPath, OwnedObjectPath};
use zbus::{Connection, interface};

use crate::daemon::Internal;
use crate::protocol::Registered;

pub const NAME: &str = "com.canonical.AppMenu.Registrar";
pub const PATH: &str = "/com/canonical/AppMenu/Registrar";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub window_id: u32,
    pub service: String,
    pub path: String,
    pub pid: Option<u32>,
    pub seq: u64,
}

#[derive(Debug, Default)]
pub struct State {
    entries: Vec<Entry>,
    seq: u64,
}

impl State {
    pub fn register(&mut self, window_id: u32, service: &str, path: &str, pid: Option<u32>) {
        self.entries
            .retain(|e| !(e.service == service && e.path == path));
        self.seq += 1;
        self.entries.push(Entry {
            window_id,
            service: service.to_string(),
            path: path.to_string(),
            pid,
            seq: self.seq,
        });
    }

    /// Entries the sender may mean by this window id. They are not dropped
    /// yet: with ambiguous ids the caller checks which paths are gone.
    pub fn unregister_candidates(&self, service: &str, window_id: u32) -> Vec<Entry> {
        self.entries
            .iter()
            .filter(|e| e.service == service && e.window_id == window_id)
            .cloned()
            .collect()
    }

    pub fn remove(&mut self, service: &str, path: &str) -> bool {
        let before = self.entries.len();
        self.entries
            .retain(|e| !(e.service == service && e.path == path));
        before != self.entries.len()
    }

    pub fn remove_service(&mut self, service: &str) -> bool {
        let before = self.entries.len();
        self.entries.retain(|e| e.service != service);
        before != self.entries.len()
    }

    /// A pid's menubars, oldest first.
    pub fn for_pid(&self, pid: u32) -> Vec<Entry> {
        let mut v: Vec<Entry> = self
            .entries
            .iter()
            .filter(|e| e.pid == Some(pid))
            .cloned()
            .collect();
        v.sort_by_key(|e| e.seq);
        v
    }

    pub fn for_window(&self, window_id: u32) -> Option<&Entry> {
        self.entries.iter().rev().find(|e| e.window_id == window_id)
    }

    pub fn list(&self) -> Vec<Registered> {
        self.entries
            .iter()
            .map(|e| Registered {
                window_id: e.window_id,
                service: e.service.clone(),
                path: e.path.clone(),
                pid: e.pid,
            })
            .collect()
    }
}

pub struct Registrar {
    pub state: Arc<Mutex<State>>,
    pub tx: UnboundedSender<Internal>,
}

fn sender(hdr: &Header<'_>) -> fdo::Result<String> {
    hdr.sender()
        .map(|s| s.to_string())
        .ok_or_else(|| fdo::Error::Failed("no sender".into()))
}

#[interface(name = "com.canonical.AppMenu.Registrar")]
impl Registrar {
    async fn register_window(
        &self,
        window_id: u32,
        menu_object_path: OwnedObjectPath,
        #[zbus(header)] hdr: Header<'_>,
        #[zbus(connection)] conn: &Connection,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> fdo::Result<()> {
        let service = sender(&hdr)?;
        let pid = crate::discovery::pid_of(conn, &service).await;
        let path = menu_object_path.as_str().to_string();
        self.state
            .lock()
            .expect("registrar state")
            .register(window_id, &service, &path, pid);
        let _ =
            Registrar::window_registered(&emitter, window_id, &service, menu_object_path.as_ref())
                .await;
        let _ = self.tx.send(Internal::Registered { pid });
        Ok(())
    }

    async fn unregister_window(
        &self,
        window_id: u32,
        #[zbus(header)] hdr: Header<'_>,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> fdo::Result<()> {
        let service = sender(&hdr)?;
        let candidates = self
            .state
            .lock()
            .expect("registrar state")
            .unregister_candidates(&service, window_id);
        let _ = Registrar::window_unregistered(&emitter, window_id).await;
        let _ = self.tx.send(Internal::Unregistered { candidates });
        Ok(())
    }

    #[zbus(out_args("service", "menuObjectPath"))]
    async fn get_menu_for_window(&self, window_id: u32) -> fdo::Result<(String, OwnedObjectPath)> {
        let state = self.state.lock().expect("registrar state");
        let e = state
            .for_window(window_id)
            .ok_or_else(|| fdo::Error::InvalidArgs(format!("no menu for window {window_id}")))?;
        let path = OwnedObjectPath::try_from(e.path.clone())
            .map_err(|e| fdo::Error::Failed(e.to_string()))?;
        Ok((e.service.clone(), path))
    }

    async fn get_menus(&self) -> Vec<(u32, String, OwnedObjectPath)> {
        let state = self.state.lock().expect("registrar state");
        state
            .entries
            .iter()
            .filter_map(|e| {
                Some((
                    e.window_id,
                    e.service.clone(),
                    OwnedObjectPath::try_from(e.path.clone()).ok()?,
                ))
            })
            .collect()
    }

    #[zbus(signal)]
    async fn window_registered(
        emitter: &SignalEmitter<'_>,
        window_id: u32,
        service: &str,
        menu_object_path: ObjectPath<'_>,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn window_unregistered(emitter: &SignalEmitter<'_>, window_id: u32) -> zbus::Result<()>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_by_service_and_path() {
        let mut s = State::default();
        // Qt on Wayland: every window may report the same id.
        s.register(1, ":1.5", "/MenuBar/1", Some(50));
        s.register(1, ":1.5", "/MenuBar/2", Some(50));
        s.register(1, ":1.9", "/MenuBar/1", Some(90));
        assert_eq!(
            s.for_pid(50)
                .iter()
                .map(|e| e.path.as_str())
                .collect::<Vec<_>>(),
            ["/MenuBar/1", "/MenuBar/2"]
        );
        // Re-registering a path moves it to the end, without duplicating.
        s.register(1, ":1.5", "/MenuBar/1", Some(50));
        assert_eq!(
            s.for_pid(50)
                .iter()
                .map(|e| e.path.as_str())
                .collect::<Vec<_>>(),
            ["/MenuBar/2", "/MenuBar/1"]
        );
        assert_eq!(s.unregister_candidates(":1.5", 1).len(), 2);
        assert!(s.remove(":1.5", "/MenuBar/2"));
        assert_eq!(s.for_pid(50).len(), 1);
        assert!(s.remove_service(":1.5"));
        assert!(s.for_pid(50).is_empty());
        assert_eq!(s.for_window(1).map(|e| e.service.as_str()), Some(":1.9"));
        assert_eq!(s.list().len(), 1);
    }
}
