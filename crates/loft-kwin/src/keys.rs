//! Press, repeat and release of Loft's global shortcuts (docs/KWIN.md §4.13).
//!
//! Loft's shortcuts are kglobalaccel actions `loft-<id>` in KWin's `kwin`
//! component (cli/loft/kwinkeys.py). A KWin script's shortcut callback fires
//! on the press and again on every key repeat, and never on the release, so
//! it can't tell a tap from a hold. kglobalaccel itself can: its component
//! object emits `globalShortcutPressed`, `globalShortcutRepeated` (KWin
//! repeats a held shortcut: after the keyboard's repeat delay, at its repeat
//! rate) and `globalShortcutReleased` (when the first key of the chord is let
//! go, the modifier or the key). This relays them to the shell as
//! `{"Shortcut": {"name": "loft-quit", "state": "pressed"|"repeated"|"released"}}`
//! lines; the quit guard (⌘Q held) uses them.

use futures_util::StreamExt;
use serde_json::{Value, json};
use zbus::{Connection, Proxy};

const COMPONENT: &str = "kwin";
const PREFIX: &str = "loft-";

/// The shell's line for a kglobalaccel signal, if it's about a Loft shortcut.
pub(crate) fn event(signal: &str, component: &str, action: &str) -> Option<Value> {
    let state = match signal {
        "globalShortcutPressed" => "pressed",
        "globalShortcutRepeated" => "repeated",
        "globalShortcutReleased" => "released",
        _ => return None,
    };
    if component != COMPONENT || !action.starts_with(PREFIX) {
        return None;
    }
    Some(json!({ "Shortcut": { "name": action, "state": state } }))
}

/// Relay until the bus goes away. Without kglobalaccel (or a KF too old for
/// these signals) nothing arrives, and the shell keeps using the shortcuts'
/// own commands.
pub(crate) async fn watch(conn: Connection, emit: fn(&Value)) {
    let Ok(p) = Proxy::new(&conn, "org.kde.kglobalaccel", "/component/kwin", "org.kde.kglobalaccel.Component").await
    else {
        return;
    };
    let (Ok(pressed), Ok(repeated), Ok(released)) = (
        p.receive_signal("globalShortcutPressed").await,
        p.receive_signal("globalShortcutRepeated").await,
        p.receive_signal("globalShortcutReleased").await,
    ) else {
        eprintln!("loft-kwin: can't watch kglobalaccel's shortcut signals; hold keys fall back to repeats");
        return;
    };
    let mut all = futures_util::stream::select_all([pressed, repeated, released]);
    while let Some(msg) = all.next().await {
        let header = msg.header();
        let Some(member) = header.member() else { continue };
        let Ok((component, action, _ts)) = msg.body().deserialize::<(String, String, i64)>() else { continue };
        if let Some(v) = event(member.as_str(), &component, &action) {
            emit(&v);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loft_shortcuts_only() {
        assert_eq!(
            event("globalShortcutPressed", "kwin", "loft-quit").unwrap(),
            json!({"Shortcut": {"name": "loft-quit", "state": "pressed"}})
        );
        assert_eq!(event("globalShortcutRepeated", "kwin", "loft-quit").unwrap()["Shortcut"]["state"], "repeated");
        assert_eq!(event("globalShortcutReleased", "kwin", "loft-quit-2").unwrap()["Shortcut"]["state"], "released");
        assert!(event("globalShortcutPressed", "kwin", "Window Close").is_none());
        assert!(event("globalShortcutPressed", "plasmashell", "loft-quit").is_none());
        assert!(event("somethingElse", "kwin", "loft-quit").is_none());
    }
}
