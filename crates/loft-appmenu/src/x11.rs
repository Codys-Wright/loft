//! X11 windows under niri's xwayland-satellite.
//!
//! niri reports xwayland-satellite's pid for every X11 window, so the pid
//! can't identify the app. The X server can: `_NET_ACTIVE_WINDOW` on the
//! root is the focused X11 window — the very id X11 apps (Electron, GTK with
//! appmenu-gtk-module) pass to RegisterWindow — and its `_NET_WM_PID` is the
//! app's process.

use x11rb::connection::Connection as _;
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt as _};

/// The pid niri reports for X11 windows.
pub fn is_xwayland_bridge(pid: u32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/comm"))
        .map(|c| is_bridge_comm(c.trim()))
        .unwrap_or(false)
}

fn is_bridge_comm(comm: &str) -> bool {
    // comm is cut to 15 chars; nix wrappers prefix a dot.
    let c = comm.trim_start_matches('.');
    c.starts_with("xwayland-satel") || c == "Xwayland"
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Active {
    pub xid: u32,
    pub pid: Option<u32>,
}

/// The focused X11 window on $DISPLAY (blocking; call off the event loop).
pub fn active_window() -> Option<Active> {
    let (conn, screen) = x11rb::connect(None).ok()?;
    let root = conn.setup().roots.get(screen)?.root;
    let atom = |name: &[u8]| Some(conn.intern_atom(false, name).ok()?.reply().ok()?.atom);
    let net_active = atom(b"_NET_ACTIVE_WINDOW")?;
    let net_pid = atom(b"_NET_WM_PID")?;
    let reply = conn
        .get_property(false, root, net_active, AtomEnum::WINDOW, 0, 1)
        .ok()?
        .reply()
        .ok()?;
    let xid = reply.value32()?.next().filter(|&x| x != 0)?;
    let pid = conn
        .get_property(false, xid, net_pid, AtomEnum::CARDINAL, 0, 1)
        .ok()
        .and_then(|c| c.reply().ok())
        .and_then(|r| r.value32()?.next());
    Some(Active { xid, pid })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_the_bridge() {
        assert!(is_bridge_comm(".xwayland-satel"));
        assert!(is_bridge_comm("xwayland-satell"));
        assert!(is_bridge_comm("Xwayland"));
        assert!(!is_bridge_comm("kate"));
    }
}
