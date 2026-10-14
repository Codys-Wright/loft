//! The keyboard side: key names and combos → evdev keycodes + modifier masks,
//! and the xkb keymap the virtual keyboard uploads.
//!
//! The keymap is a US layout on the real evdev keycodes (so apps that look at
//! keycodes — browsers' `KeyboardEvent.code`, Qt shortcut fallbacks — see the
//! keys they expect), plus one spare keycode per character the US layout
//! can't type (`é`, `→`, emoji …), assigned per run. Modifier masks are the
//! fixed xkb real modifiers: Shift 1, Lock 2, Control 4, Mod1 (Alt) 8,
//! Mod4 (Super) 64, Mod5 (ISO_Level3_Shift — studio's window-manager key) 128.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use anyhow::{Result, bail};

/// One key of the US table: evdev code, keysym at level 1 and 2, and the
/// characters they type.
struct UsKey {
    code: u32,
    base: &'static str,
    shifted: &'static str,
    base_ch: char,
    shifted_ch: char,
}

const fn k(
    code: u32,
    base: &'static str,
    shifted: &'static str,
    base_ch: char,
    shifted_ch: char,
) -> UsKey {
    UsKey {
        code,
        base,
        shifted,
        base_ch,
        shifted_ch,
    }
}

#[rustfmt::skip]
const US: &[UsKey] = &[
    k(41, "grave", "asciitilde", '`', '~'),
    k(2, "1", "exclam", '1', '!'), k(3, "2", "at", '2', '@'), k(4, "3", "numbersign", '3', '#'),
    k(5, "4", "dollar", '4', '$'), k(6, "5", "percent", '5', '%'), k(7, "6", "asciicircum", '6', '^'),
    k(8, "7", "ampersand", '7', '&'), k(9, "8", "asterisk", '8', '*'), k(10, "9", "parenleft", '9', '('),
    k(11, "0", "parenright", '0', ')'), k(12, "minus", "underscore", '-', '_'), k(13, "equal", "plus", '=', '+'),
    k(16, "q", "Q", 'q', 'Q'), k(17, "w", "W", 'w', 'W'), k(18, "e", "E", 'e', 'E'), k(19, "r", "R", 'r', 'R'),
    k(20, "t", "T", 't', 'T'), k(21, "y", "Y", 'y', 'Y'), k(22, "u", "U", 'u', 'U'), k(23, "i", "I", 'i', 'I'),
    k(24, "o", "O", 'o', 'O'), k(25, "p", "P", 'p', 'P'),
    k(26, "bracketleft", "braceleft", '[', '{'), k(27, "bracketright", "braceright", ']', '}'),
    k(43, "backslash", "bar", '\\', '|'),
    k(30, "a", "A", 'a', 'A'), k(31, "s", "S", 's', 'S'), k(32, "d", "D", 'd', 'D'), k(33, "f", "F", 'f', 'F'),
    k(34, "g", "G", 'g', 'G'), k(35, "h", "H", 'h', 'H'), k(36, "j", "J", 'j', 'J'), k(37, "k", "K", 'k', 'K'),
    k(38, "l", "L", 'l', 'L'), k(39, "semicolon", "colon", ';', ':'), k(40, "apostrophe", "quotedbl", '\'', '"'),
    k(44, "z", "Z", 'z', 'Z'), k(45, "x", "X", 'x', 'X'), k(46, "c", "C", 'c', 'C'), k(47, "v", "V", 'v', 'V'),
    k(48, "b", "B", 'b', 'B'), k(49, "n", "N", 'n', 'N'), k(50, "m", "M", 'm', 'M'),
    k(51, "comma", "less", ',', '<'), k(52, "period", "greater", '.', '>'), k(53, "slash", "question", '/', '?'),
    k(57, "space", "space", ' ', ' '),
];

/// Named (non-character) keys: keysym and evdev code.
#[rustfmt::skip]
const NAMED: &[(&str, u32)] = &[
    ("Escape", 1), ("BackSpace", 14), ("Tab", 15), ("Return", 28), ("Caps_Lock", 58),
    ("F1", 59), ("F2", 60), ("F3", 61), ("F4", 62), ("F5", 63), ("F6", 64), ("F7", 65),
    ("F8", 66), ("F9", 67), ("F10", 68), ("F11", 87), ("F12", 88),
    ("F13", 183), ("F14", 184), ("F15", 185), ("F16", 186), ("F17", 187), ("F18", 188),
    ("F19", 189), ("F20", 190), ("F21", 191), ("F22", 192), ("F23", 193), ("F24", 194),
    ("Num_Lock", 69), ("Scroll_Lock", 70), ("Print", 99), ("Pause", 119), ("Menu", 127),
    ("Home", 102), ("Up", 103), ("Prior", 104), ("Left", 105), ("Right", 106), ("End", 107),
    ("Down", 108), ("Next", 109), ("Insert", 110), ("Delete", 111),
    ("KP_Enter", 96), ("KP_Divide", 98), ("KP_Multiply", 55), ("KP_Subtract", 74), ("KP_Add", 78),
    ("XF86AudioMute", 113), ("XF86AudioLowerVolume", 114), ("XF86AudioRaiseVolume", 115),
    ("XF86AudioNext", 163), ("XF86AudioPlay", 164), ("XF86AudioPrev", 165), ("XF86AudioStop", 166),
    ("XF86MonBrightnessDown", 224), ("XF86MonBrightnessUp", 225),
];

/// Modifier keys, with their keysym, evdev code and real-modifier mask.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Modifier {
    Shift,
    Ctrl,
    Alt,
    Super,
    /// ISO_Level3_Shift (Mod5): studio's window-manager key, "Mod".
    Level3,
}

impl Modifier {
    pub const ALL: [Modifier; 5] = [
        Modifier::Ctrl,
        Modifier::Alt,
        Modifier::Super,
        Modifier::Level3,
        Modifier::Shift,
    ];

    pub fn keysym(self) -> &'static str {
        match self {
            Modifier::Shift => "Shift_L",
            Modifier::Ctrl => "Control_L",
            Modifier::Alt => "Alt_L",
            Modifier::Super => "Super_L",
            Modifier::Level3 => "ISO_Level3_Shift",
        }
    }

    /// evdev code (KEY_LEFTSHIFT, KEY_LEFTCTRL, KEY_LEFTALT, KEY_LEFTMETA, KEY_RIGHTALT).
    pub fn code(self) -> u32 {
        match self {
            Modifier::Shift => 42,
            Modifier::Ctrl => 29,
            Modifier::Alt => 56,
            Modifier::Super => 125,
            Modifier::Level3 => 100,
        }
    }

    pub fn mask(self) -> u32 {
        match self {
            Modifier::Shift => 1,
            Modifier::Ctrl => 4,
            Modifier::Alt => 8,
            Modifier::Super => 64,
            Modifier::Level3 => 128,
        }
    }

    pub fn parse(s: &str) -> Option<Modifier> {
        Some(match s.to_ascii_lowercase().as_str() {
            "shift" => Modifier::Shift,
            "ctrl" | "control" | "ctl" => Modifier::Ctrl,
            "alt" | "opt" | "option" => Modifier::Alt,
            "super" | "win" | "logo" | "meta" | "cmd" | "command" => Modifier::Super,
            "mod" | "mod5" | "altgr" | "level3" | "iso_level3_shift" => Modifier::Level3,
            _ => return None,
        })
    }
}

/// What to press for one key: its xkb keycode (evdev + 8) and whether Shift
/// selects its keysym.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stroke {
    pub code: u32,
    pub shift: bool,
}

impl Stroke {
    pub fn evdev(self) -> u32 {
        self.code - 8
    }
}

/// A parsed combo like `ctrl+shift+t`: modifiers held around one key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Combo {
    pub mods: Vec<Modifier>,
    /// The key's keysym name; None for a bare modifier (`super`).
    pub key: Option<String>,
}

/// User spellings of named keys → keysym names.
fn alias(name: &str) -> Option<&'static str> {
    Some(match name.to_ascii_lowercase().as_str() {
        "enter" | "return" | "ret" => "Return",
        "esc" | "escape" => "Escape",
        "backspace" | "bs" => "BackSpace",
        "del" | "delete" => "Delete",
        "ins" | "insert" => "Insert",
        "tab" => "Tab",
        "space" | "spc" => "space",
        "pgup" | "pageup" | "page_up" | "prior" => "Prior",
        "pgdn" | "pagedown" | "page_down" | "next" => "Next",
        "home" => "Home",
        "end" => "End",
        "up" => "Up",
        "down" => "Down",
        "left" => "Left",
        "right" => "Right",
        "menu" => "Menu",
        "print" | "printscreen" => "Print",
        "capslock" | "caps_lock" | "caps" => "Caps_Lock",
        "pause" => "Pause",
        "plus" => "plus",
        "minus" => "minus",
        "comma" => "comma",
        "period" | "dot" => "period",
        "slash" => "slash",
        _ => return None,
    })
}

/// Canonical keysym name for a user key name, or an error for unknown names.
pub fn keysym_name(name: &str) -> Result<String> {
    if let Some(a) = alias(name) {
        return Ok(a.to_string());
    }
    let mut chars = name.chars();
    if let (Some(c), None) = (chars.next(), chars.clone().next()) {
        return Ok(char_keysym(c));
    }
    if let Some(n) = NAMED.iter().find(|(n, _)| n.eq_ignore_ascii_case(name)) {
        return Ok(n.0.to_string());
    }
    if let Some(u) = US
        .iter()
        .find(|u| u.base.len() > 1 && u.base.eq_ignore_ascii_case(name))
    {
        return Ok(u.base.to_string());
    }
    if let Some(u) = US
        .iter()
        .find(|u| u.shifted.len() > 1 && u.shifted.eq_ignore_ascii_case(name))
    {
        return Ok(u.shifted.to_string());
    }
    // U+00E9 / U00E9
    if let Some(hex) = name
        .strip_prefix("U+")
        .or_else(|| name.strip_prefix("u+"))
        .or_else(|| name.strip_prefix('U').filter(|h| h.len() >= 4))
        && let Ok(v) = u32::from_str_radix(hex, 16)
        && let Some(c) = char::from_u32(v)
    {
        return Ok(char_keysym(c));
    }
    if let Some(n) = known_keysym(name) {
        return Ok(n.to_string());
    }
    bail!(
        "unknown key `{name}` (an xkb keysym name like Return, F5, XF86AudioPlay, or one character)"
    )
}

/// The real xkb name of a keysym name, matched case-insensitively against
/// xkbcommon's table (via xkeysym).
fn known_keysym(name: &str) -> Option<&'static str> {
    let ranges = [
        0x20u32..0x1_0000,
        0x1008_fe00..0x1009_0000,
        0x1008_1000..0x1008_1200,
    ];
    let mut ci = None;
    for r in ranges {
        for v in r {
            if let Some(n) = xkeysym::Keysym::new(v).name() {
                let n = n.strip_prefix("XK_").unwrap_or(n);
                if n == name {
                    return Some(n);
                }
                if ci.is_none() && n.eq_ignore_ascii_case(name) {
                    ci = Some(n);
                }
            }
        }
    }
    ci
}

/// The keysym name that types `c`: the US table's, else `U<hex>`.
pub fn char_keysym(c: char) -> String {
    if let Some(u) = US.iter().find(|u| u.base_ch == c) {
        return u.base.to_string();
    }
    if let Some(u) = US.iter().find(|u| u.shifted_ch == c) {
        return u.shifted.to_string();
    }
    format!("U{:04X}", c as u32)
}

/// `ctrl+shift+t`, `super+space`, `Escape`, `mod+shift+slash`, `ctrl++`.
pub fn parse_combo(s: &str) -> Result<Combo> {
    let s = s.trim();
    if s.is_empty() {
        bail!("empty key combo");
    }
    // A trailing `++` is the plus key (`ctrl++`).
    let mut parts: Vec<&str> = match s.strip_suffix("++") {
        Some(body) => body.split('+').chain(std::iter::once("plus")).collect(),
        None => s.split('+').collect(),
    };
    let mut mods = Vec::new();
    let last = parts.pop().unwrap_or_default().trim();
    for p in parts {
        match Modifier::parse(p.trim()) {
            Some(m) if !mods.contains(&m) => mods.push(m),
            Some(_) => {}
            None => bail!("`{p}` in `{s}` is not a modifier (ctrl, shift, alt, super, mod)"),
        }
    }
    let key = match Modifier::parse(last) {
        Some(m) => {
            if !mods.contains(&m) {
                mods.push(m);
            }
            None
        }
        None => Some(keysym_name(last)?),
    };
    mods.sort();
    Ok(Combo { mods, key })
}

/// A keymap for one run: the US table, the modifiers, the named keys, and
/// spare keycodes for every other keysym the run needs.
#[derive(Debug, Clone)]
pub struct Keymap {
    /// keysym name → stroke
    strokes: BTreeMap<String, Stroke>,
    /// xkb keycode → its keysyms (levels)
    keys: BTreeMap<u32, Vec<String>>,
}

impl Default for Keymap {
    fn default() -> Self {
        Self::new()
    }
}

fn is_builtin_code(code: u32) -> bool {
    US.iter().any(|u| u.code + 8 == code)
        || NAMED.iter().any(|(_, c)| c + 8 == code)
        || Modifier::ALL.iter().any(|m| m.code() + 8 == code)
}

impl Keymap {
    pub fn new() -> Self {
        let mut km = Keymap {
            strokes: BTreeMap::new(),
            keys: BTreeMap::new(),
        };
        for u in US {
            let code = u.code + 8;
            km.keys
                .insert(code, vec![u.base.to_string(), u.shifted.to_string()]);
            km.strokes
                .entry(u.base.to_string())
                .or_insert(Stroke { code, shift: false });
            km.strokes
                .entry(u.shifted.to_string())
                .or_insert(Stroke { code, shift: true });
        }
        for (name, code) in NAMED {
            let code = code + 8;
            let levels = if *name == "Tab" {
                vec!["Tab".to_string(), "ISO_Left_Tab".to_string()]
            } else {
                vec![name.to_string()]
            };
            km.keys.insert(code, levels);
            km.strokes
                .insert(name.to_string(), Stroke { code, shift: false });
        }
        for m in Modifier::ALL {
            let code = m.code() + 8;
            km.keys.insert(code, vec![m.keysym().to_string()]);
            km.strokes
                .insert(m.keysym().to_string(), Stroke { code, shift: false });
        }
        km
    }

    /// Make sure `keysym` can be typed, giving it a spare keycode if needed.
    pub fn ensure(&mut self, keysym: &str) -> Result<Stroke> {
        if let Some(s) = self.strokes.get(keysym) {
            return Ok(*s);
        }
        // Spare keycodes from the top down (Xwayland only sees 8..=255).
        let code = (9..=255u32)
            .rev()
            .find(|c| !self.keys.contains_key(c))
            .ok_or_else(|| anyhow::anyhow!("too many distinct characters in one run"))?;
        self.keys.insert(code, vec![keysym.to_string()]);
        let s = Stroke { code, shift: false };
        self.strokes.insert(keysym.to_string(), s);
        Ok(s)
    }

    pub fn stroke(&self, keysym: &str) -> Option<Stroke> {
        self.strokes.get(keysym).copied()
    }

    /// Whether this keysym only exists on a spare keycode (not a real key of
    /// a US keyboard) — uinput can't type those.
    pub fn is_spare(&self, keysym: &str) -> bool {
        self.stroke(keysym)
            .is_some_and(|s| !is_builtin_code(s.code))
    }

    /// xkb_keymap text (format XKB_KEYMAP_FORMAT_TEXT_V1).
    pub fn to_xkb(&self) -> String {
        let mut s = String::new();
        s.push_str(
            "xkb_keymap {\nxkb_keycodes \"studio-input\" {\n    minimum = 8;\n    maximum = 255;\n",
        );
        for code in self.keys.keys() {
            let _ = writeln!(s, "    <I{code}> = {code};");
        }
        s.push_str("};\nxkb_types \"studio-input\" { include \"complete\" };\n");
        s.push_str("xkb_compatibility \"studio-input\" { include \"complete\" };\n");
        s.push_str("xkb_symbols \"studio-input\" {\n");
        for (code, syms) in &self.keys {
            let _ = writeln!(s, "    key <I{code}> {{ [ {} ] }};", syms.join(", "));
        }
        for m in Modifier::ALL {
            let name = match m {
                Modifier::Shift => "Shift",
                Modifier::Ctrl => "Control",
                Modifier::Alt => "Mod1",
                Modifier::Super => "Mod4",
                Modifier::Level3 => "Mod5",
            };
            let _ = writeln!(s, "    modifier_map {name} {{ <I{}> }};", m.code() + 8);
        }
        s.push_str("};\n};\n");
        s
    }
}

/// What typing `text` presses: per character, a stroke (`\n` is Return,
/// `\t` is Tab).
pub fn text_strokes(km: &mut Keymap, text: &str) -> Result<Vec<(char, Stroke)>> {
    let mut out = Vec::new();
    for c in text.chars() {
        let sym = match c {
            '\n' | '\r' => "Return".to_string(),
            '\t' => "Tab".to_string(),
            c if c.is_control() => bail!("can't type control character U+{:04X}", c as u32),
            c => char_keysym(c),
        };
        out.push((c, km.ensure(&sym)?));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_combos() {
        let c = parse_combo("ctrl+shift+t").unwrap();
        assert_eq!(c.mods, vec![Modifier::Shift, Modifier::Ctrl]);
        assert_eq!(c.key.as_deref(), Some("t"));
        assert_eq!(
            parse_combo("Escape").unwrap(),
            Combo {
                mods: vec![],
                key: Some("Escape".into())
            }
        );
        assert_eq!(
            parse_combo("super+space").unwrap().key.as_deref(),
            Some("space")
        );
        assert_eq!(
            parse_combo("mod+Return").unwrap().mods,
            vec![Modifier::Level3]
        );
        assert_eq!(parse_combo("ctrl++").unwrap().key.as_deref(), Some("plus"));
        assert_eq!(parse_combo("super").unwrap().key, None);
        assert_eq!(parse_combo("enter").unwrap().key.as_deref(), Some("Return"));
        assert_eq!(parse_combo("pgdn").unwrap().key.as_deref(), Some("Next"));
        assert_eq!(parse_combo("f5").unwrap().key.as_deref(), Some("F5"));
        assert!(parse_combo("hyper+x").is_err());
        assert!(parse_combo("ctrl+NotAKeyAtAll").is_err());
    }

    #[test]
    fn resolves_keysym_names() {
        assert_eq!(keysym_name("xf86audioplay").unwrap(), "XF86AudioPlay");
        assert_eq!(
            keysym_name("XF86AudioRaiseVolume").unwrap(),
            "XF86AudioRaiseVolume"
        );
        assert_eq!(keysym_name("aacute").unwrap(), "aacute");
        assert_eq!(keysym_name("U+00E9").unwrap(), "U00E9");
        assert_eq!(keysym_name("?").unwrap(), "question");
        assert_eq!(keysym_name("A").unwrap(), "A");
        assert_eq!(keysym_name("Question").unwrap(), "question");
    }

    #[test]
    fn types_shifted_and_unicode() {
        let mut km = Keymap::new();
        let s = text_strokes(&mut km, "Hi!é\n").unwrap();
        assert_eq!(
            s[0].1,
            Stroke {
                code: 35 + 8,
                shift: true
            }
        );
        assert_eq!(
            s[1].1,
            Stroke {
                code: 23 + 8,
                shift: false
            }
        );
        assert_eq!(
            s[2].1,
            Stroke {
                code: 2 + 8,
                shift: true
            }
        );
        assert!(km.is_spare("U00E9"));
        assert!(!km.is_spare("a"));
        assert_eq!(s[3].1.code, 255);
        assert_eq!(
            s[4].1,
            Stroke {
                code: 28 + 8,
                shift: false
            }
        );
        // The same character reuses its spare key.
        let again = text_strokes(&mut km, "é").unwrap();
        assert_eq!(again[0].1.code, 255);
        assert!(text_strokes(&mut km, "\u{7}").is_err());
    }

    #[test]
    fn renders_a_complete_keymap() {
        let mut km = Keymap::new();
        km.ensure("U2192").unwrap();
        let x = km.to_xkb();
        assert!(x.contains("<I38> = 38;"));
        assert!(x.contains("key <I38> { [ a, A ] };"));
        assert!(x.contains("key <I255> { [ U2192 ] };"));
        assert!(x.contains("modifier_map Mod5 { <I108> };"));
        assert!(x.contains("key <I23> { [ Tab, ISO_Left_Tab ] };"));
        // Every keycode is declared once.
        assert_eq!(x.matches("<I36> =").count(), 1);
    }
}
