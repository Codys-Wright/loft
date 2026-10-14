//! The line-JSON protocol between the shell and the daemon.
//!
//! stdin, one command per line:
//!
//! ```text
//! {"cmd":"focus","pid":123,"index":0,"count":1,"exclude":[456]}   focused window changed
//! {"cmd":"focus"}                                                   nothing focused
//! {"cmd":"open","id":7}       a menu is about to show (AboutToShow + "opened"; lazy submenus fill in)
//! {"cmd":"close","id":7}      it closed ("closed")
//! {"cmd":"activate","id":12}  click an item
//! {"cmd":"refresh"}           re-read the current menu
//! {"cmd":"list"}              → {"menus":[…]} the registrar's table (debugging)
//! {"cmd":"dump"}              → {"dump":…} the raw layout of the current menu (fixtures)
//! {"cmd":"quit"}
//! ```
//!
//! stdout, one event per line: `{"status":{…}}` once at start, `{"menu":{…}}` /
//! `{"menu":null}` whenever the focused app's menu changes, `{"error":"…"}`.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    /// The focused window changed. `pid` absent = nothing focused.
    Focus {
        #[serde(default)]
        pid: Option<u32>,
        /// Position of the focused window among the windows of this pid,
        /// ordered by niri window id, and how many there are. Picks between
        /// several menubars of one process (one per main window).
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        count: Option<usize>,
        /// Pids that own other windows: never take their menus when walking
        /// the process tree (a Qt app started from a terminal isn't the
        /// terminal's menu).
        #[serde(default)]
        exclude: Vec<u32>,
    },
    Open {
        id: i32,
    },
    Close {
        id: i32,
    },
    Activate {
        id: i32,
    },
    Refresh,
    List,
    Dump,
    Quit,
}

pub fn parse_command(line: &str) -> Result<Command, String> {
    serde_json::from_str(line).map_err(|e| format!("bad command {line:?}: {e}"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Toggle {
    Check,
    Radio,
}

/// One menu entry as the shell draws it. Invisible items are dropped.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MenuItem {
    pub id: i32,
    #[serde(skip_serializing_if = "is_false")]
    pub separator: bool,
    /// Mnemonic markers removed ("_Open" → "Open").
    pub label: String,
    /// The mnemonic character, if the label had one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mnemonic: Option<String>,
    pub enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub toggle: Option<Toggle>,
    #[serde(skip_serializing_if = "is_false")]
    pub checked: bool,
    /// Key chords, each a list of modifiers then the key:
    /// `[["Control","Shift","S"]]`. Modifier names: Control, Shift, Alt, Super.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub shortcut: Vec<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// Opens a submenu (its children may arrive only after `open`).
    #[serde(skip_serializing_if = "is_false")]
    pub submenu: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<MenuItem>,
}

impl MenuItem {
    pub fn separator(id: i32) -> Self {
        MenuItem {
            id,
            separator: true,
            label: String::new(),
            mnemonic: None,
            enabled: true,
            toggle: None,
            checked: false,
            shortcut: Vec::new(),
            icon: None,
            submenu: false,
            children: Vec::new(),
        }
    }

    pub fn labelled(id: i32, raw_label: &str) -> Self {
        let (label, mnemonic) = strip_mnemonic(raw_label);
        MenuItem {
            separator: false,
            label,
            mnemonic: mnemonic.map(String::from),
            ..MenuItem::separator(id)
        }
    }
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// com.canonical.dbusmenu (Qt/KDE, appmenu-gtk-module, Electron on X11).
    Dbusmenu,
    /// org.gtk.Menus + org.gtk.Actions (GtkApplication menubars).
    Gtk,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Menu {
    pub source: Source,
    /// The process the menu belongs to (may differ from the window's pid).
    pub pid: u32,
    pub service: String,
    pub path: String,
    /// Top-level titles (File, Edit, …), each with `submenu: true`.
    pub items: Vec<MenuItem>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RegistrarMode {
    /// We own com.canonical.AppMenu.Registrar: Qt apps register with us.
    Owned,
    /// Another registrar (e.g. Plasma's) owns the name; menus are still
    /// found by pid through bus introspection.
    External,
    /// Disabled ($LOFT_APPMENU_REGISTRAR=0); introspection only.
    Off,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub registrar: RegistrarMode,
    pub version: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Registered {
    pub window_id: u32,
    pub service: String,
    pub path: String,
    pub pid: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Event {
    Status(Status),
    Menu(Option<Menu>),
    Menus(Vec<Registered>),
    Dump(serde_json::Value),
    Error(String),
}

impl Event {
    pub fn to_line(&self) -> String {
        // Our types always serialize.
        let mut s = serde_json::to_string(self)
            .unwrap_or_else(|e| format!("{{\"error\":{:?}}}", e.to_string()));
        s.push('\n');
        s
    }
}

/// "_File" → ("File", Some('F')); "Save __As" → ("Save _As", None).
/// DBusMenu and GMenu both mark mnemonics with `_` and escape it as `__`.
pub fn strip_mnemonic(raw: &str) -> (String, Option<char>) {
    let mut out = String::with_capacity(raw.len());
    let mut mnemonic = None;
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '_' {
            out.push(c);
            continue;
        }
        match chars.peek() {
            Some('_') => {
                out.push('_');
                chars.next();
            }
            // Only the first marker counts; the marked char is pushed next round.
            Some(&next) if mnemonic.is_none() => mnemonic = Some(next),
            _ => {}
        }
    }
    (out, mnemonic)
}

/// A GTK accelerator ("<Primary><Shift>s") as a key chord.
pub fn gtk_accel(accel: &str) -> Vec<String> {
    let mut keys = Vec::new();
    let mut rest = accel.trim();
    while let Some(stripped) = rest.strip_prefix('<') {
        let Some(end) = stripped.find('>') else { break };
        let modifier = match stripped[..end].to_ascii_lowercase().as_str() {
            "primary" | "control" | "ctrl" | "ctl" => "Control",
            "shift" => "Shift",
            "alt" | "mod1" => "Alt",
            "super" | "meta" | "hyper" | "mod4" => "Super",
            _ => "",
        };
        if !modifier.is_empty() && !keys.iter().any(|k| k == modifier) {
            keys.push(modifier.to_string());
        }
        rest = &stripped[end + 1..];
    }
    if rest.is_empty() {
        return Vec::new();
    }
    keys.push(key_name(rest));
    keys
}

/// Keysym names → what's printed on the key.
fn key_name(sym: &str) -> String {
    let named = match sym {
        "plus" | "KP_Add" => "+",
        "minus" | "KP_Subtract" => "-",
        "equal" => "=",
        "comma" => ",",
        "period" => ".",
        "slash" => "/",
        "backslash" => "\\",
        "question" => "?",
        "semicolon" => ";",
        "apostrophe" => "'",
        "bracketleft" => "[",
        "bracketright" => "]",
        "grave" => "`",
        "space" => "Space",
        "Delete" | "KP_Delete" => "Del",
        "Return" | "KP_Enter" => "Return",
        "BackSpace" => "Backspace",
        "Escape" => "Esc",
        "Page_Up" => "PgUp",
        "Page_Down" => "PgDown",
        _ => "",
    };
    if !named.is_empty() {
        return named.to_string();
    }
    let mut chars = sym.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => c.to_uppercase().collect(),
        _ => sym.to_string(),
    }
}

/// DBusMenu shortcuts already use our names, except some apps send
/// "Ctrl"/"Meta"; normalize.
pub fn normalize_chord(chord: &[String]) -> Vec<String> {
    chord
        .iter()
        .map(|k| match k.as_str() {
            "Ctrl" | "Control" => "Control".to_string(),
            "Meta" | "Super" => "Super".to_string(),
            // Chromium sends the key as typed ("h").
            k if k.chars().count() == 1 => k.to_uppercase(),
            other => other.to_string(),
        })
        .collect()
}

/// Drop leading, trailing and doubled separators.
pub fn tidy_separators(items: Vec<MenuItem>) -> Vec<MenuItem> {
    let mut out: Vec<MenuItem> = Vec::with_capacity(items.len());
    for item in items {
        if item.separator && out.last().is_none_or(|l| l.separator) {
            continue;
        }
        out.push(item);
    }
    while out.last().is_some_and(|l| l.separator) {
        out.pop();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_commands() {
        assert_eq!(
            parse_command(r#"{"cmd":"focus","pid":42,"index":1,"count":2,"exclude":[7]}"#).unwrap(),
            Command::Focus {
                pid: Some(42),
                index: Some(1),
                count: Some(2),
                exclude: vec![7]
            }
        );
        assert_eq!(
            parse_command(r#"{"cmd":"focus"}"#).unwrap(),
            Command::Focus {
                pid: None,
                index: None,
                count: None,
                exclude: vec![]
            }
        );
        assert_eq!(
            parse_command(r#"{"cmd":"activate","id":12}"#).unwrap(),
            Command::Activate { id: 12 }
        );
        assert_eq!(
            parse_command(r#"{"cmd":"open","id":-3}"#).unwrap(),
            Command::Open { id: -3 }
        );
        assert_eq!(
            parse_command(r#"{"cmd":"refresh"}"#).unwrap(),
            Command::Refresh
        );
        assert!(parse_command(r#"{"cmd":"nope"}"#).is_err());
        assert!(parse_command("not json").is_err());
    }

    #[test]
    fn encodes_events() {
        assert_eq!(Event::Menu(None).to_line(), "{\"menu\":null}\n");
        let mut open = MenuItem::labelled(3, "_Open…");
        open.shortcut = vec![vec!["Control".into(), "O".into()]];
        let mut file = MenuItem::labelled(1, "_File");
        file.submenu = true;
        file.children = vec![open, MenuItem::separator(4)];
        let menu = Menu {
            source: Source::Dbusmenu,
            pid: 9,
            service: ":1.5".into(),
            path: "/MenuBar/1".into(),
            items: vec![file],
        };
        let line = Event::Menu(Some(menu)).to_line();
        assert_eq!(
            line,
            concat!(
                r#"{"menu":{"source":"dbusmenu","pid":9,"service":":1.5","path":"/MenuBar/1","items":["#,
                r#"{"id":1,"label":"File","mnemonic":"F","enabled":true,"submenu":true,"children":["#,
                r#"{"id":3,"label":"Open…","mnemonic":"O","enabled":true,"shortcut":[["Control","O"]]},"#,
                r#"{"id":4,"separator":true,"label":"","enabled":true}]}]}}"#,
                "\n"
            )
        );
        assert_eq!(
            Event::Status(Status {
                registrar: RegistrarMode::External,
                version: "0.1.0"
            })
            .to_line(),
            "{\"status\":{\"registrar\":\"external\",\"version\":\"0.1.0\"}}\n"
        );
    }

    #[test]
    fn strips_mnemonics() {
        assert_eq!(strip_mnemonic("_File"), ("File".into(), Some('F')));
        assert_eq!(strip_mnemonic("Save _As…"), ("Save As…".into(), Some('A')));
        assert_eq!(strip_mnemonic("snake__case"), ("snake_case".into(), None));
        assert_eq!(strip_mnemonic("a__b _c _d"), ("a_b c d".into(), Some('c')));
        assert_eq!(strip_mnemonic("trailing_"), ("trailing".into(), None));
        assert_eq!(strip_mnemonic("Plain"), ("Plain".into(), None));
    }

    #[test]
    fn converts_gtk_accels() {
        assert_eq!(gtk_accel("<Primary>s"), vec!["Control", "S"]);
        assert_eq!(
            gtk_accel("<Control><Shift>z"),
            vec!["Control", "Shift", "Z"]
        );
        assert_eq!(gtk_accel("<Primary>plus"), vec!["Control", "+"]);
        assert_eq!(gtk_accel("F11"), vec!["F11"]);
        assert_eq!(gtk_accel("<Alt>Delete"), vec!["Alt", "Del"]);
        assert!(gtk_accel("").is_empty());
    }

    #[test]
    fn normalizes_chords() {
        let c = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(normalize_chord(&c(&["Ctrl", "h"])), c(&["Control", "H"]));
        assert_eq!(
            normalize_chord(&c(&["Meta", "Shift", "F5"])),
            c(&["Super", "Shift", "F5"])
        );
    }

    #[test]
    fn tidies_separators() {
        let s = MenuItem::separator;
        let i = |id| MenuItem::labelled(id, "x");
        let ids = |v: Vec<MenuItem>| v.iter().map(|m| m.id).collect::<Vec<_>>();
        assert_eq!(
            ids(tidy_separators(vec![s(1), i(2), s(3), s(4), i(5), s(6)])),
            vec![2, 3, 5]
        );
        assert!(tidy_separators(vec![s(1), s(2)]).is_empty());
    }
}
