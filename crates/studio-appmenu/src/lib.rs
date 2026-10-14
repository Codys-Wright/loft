//! studio-appmenu: the global menu backend of studio-linux's menu bar.
//!
//! niri has no appmenu protocol, so menus are matched to windows by pid:
//! Qt registers its DBusMenu menubars with our `com.canonical.AppMenu.Registrar`
//! (recording the sender's pid), and anything else is found by introspecting
//! the connections a process owns (`discovery`). The shell talks to the
//! daemon in line-JSON (`protocol`).

pub mod daemon;
pub mod dbusmenu;
pub mod discovery;
pub mod gtkmenu;
pub mod matching;
pub mod protocol;
pub mod raw;
pub mod registrar;
pub mod x11;
