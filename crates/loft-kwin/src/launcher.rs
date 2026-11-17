//! Spotlight from Loft's shortcuts under KWin (docs/KWIN.md §4.22).
//!
//! The loft-keys script (cli/loft/kwinkeys.py) calls `dev.loft.Launcher`'s
//! `Open(mode)` here instead of starting a systemd unit that runs
//! `loft-launcher MODE` (bash, then `gdbus`): this hands walker's service
//! the same command line, over the session bus loft-kwin already holds.
//! False (walker's service isn't there, or doesn't answer in time) and the
//! script falls back to the unit, whose `loft-launcher` waits for a
//! starting service before it ever starts walker cold.
//!
//! The name is separate from `dev.loft.KWinBridge` so that the script can
//! tell, with one `NameHasOwner`, that this method exists: KWin's `callDBus`
//! never calls back on an error, so a missing method would be a dead key.

use std::collections::HashMap;
use std::time::Duration;

use zbus::zvariant::{ObjectPath, Value};
use zbus::{Connection, interface};

pub const BUS_NAME: &str = "dev.loft.Launcher";
pub const PATH: &str = "/Launcher";
const WALKER: &str = "dev.benz.walker";
const WALKER_PATH: &str = "/dev/benz/walker";
/// The `loft-launcher` client's object path, as its `gdbus call` passes.
const CLIENT_PATH: &str = "/dev/benz/walker/loft";
/// Past this walker is hung (it answers in ~1 ms); the unit's
/// loft-launcher then says so in the journal.
const TIMEOUT: Duration = Duration::from_millis(1500);

/// `loft-launcher MODE`'s walker options (launcher/loft-launcher.sh):
/// (provider, placeholder), None for plain Spotlight.
pub fn mode_options(mode: &str) -> Option<Option<(&'static str, &'static str)>> {
    match mode {
        "" | "open" => Some(None),
        "emoji" => Some(Some(("symbols", "Emoji & Symbols"))),
        "clipboard" => Some(Some(("clipboard", "Clipboard History"))),
        "help" => Some(Some(("commands", "Spotlight Help"))),
        _ => None,
    }
}

/// GApplication's `CommandLine` arguments: the bytestrings of argv (each with
/// its NUL, as `g_variant_new_bytestring_array` makes them) and the platform
/// data with the options the client parsed.
fn command_line(options: Option<(&str, &str)>) -> (Vec<Vec<u8>>, HashMap<&'static str, Value<'static>>) {
    let mut platform = HashMap::new();
    if let Some((provider, placeholder)) = options {
        let mut opts: HashMap<&'static str, Value<'static>> = HashMap::new();
        opts.insert("provider", Value::from(provider.to_string()));
        opts.insert("placeholder", Value::from(placeholder.to_string()));
        platform.insert("options", Value::from(opts));
    }
    (vec![b"walker\0".to_vec()], platform)
}

/// Hand walker's service `loft-launcher MODE`'s command line. True when
/// walker took it.
pub async fn open(conn: &Connection, mode: &str) -> bool {
    let Some(options) = mode_options(mode) else {
        eprintln!("loft-kwin: unknown launcher mode {mode:?}");
        return false;
    };
    let (argv, platform) = command_line(options);
    let body = (ObjectPath::from_static_str_unchecked(CLIENT_PATH), argv, platform);
    let call = conn.call_method(Some(WALKER), WALKER_PATH, Some("org.gtk.Application"), "CommandLine", &body);
    match tokio::time::timeout(TIMEOUT, call).await {
        Ok(Ok(_)) => true,
        Ok(Err(zbus::Error::MethodError(name, _, _))) if name.as_str() == "org.freedesktop.DBus.Error.ServiceUnknown" => false,
        Ok(Err(e)) => {
            eprintln!("loft-kwin: walker didn't take the command line: {e}");
            false
        }
        Err(_) => {
            eprintln!("loft-kwin: walker didn't answer in {} ms", TIMEOUT.as_millis());
            false
        }
    }
}

pub struct Launcher {
    pub conn: Connection,
}

#[interface(name = "dev.loft.Launcher")]
impl Launcher {
    /// Open (or close: walker toggles) Spotlight: `open` (or ""), `emoji`,
    /// `clipboard`, `help`, as `loft-launcher MODE`. False: walker's service
    /// isn't there or didn't take it (the caller runs `loft-launcher MODE`).
    async fn open(&self, mode: String) -> bool {
        open(&self.conn, &mode).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_match_loft_launcher() {
        assert_eq!(mode_options("open"), Some(None));
        assert_eq!(mode_options(""), Some(None));
        assert_eq!(mode_options("emoji"), Some(Some(("symbols", "Emoji & Symbols"))));
        assert_eq!(mode_options("service"), None);
        assert_eq!(mode_options("rm -rf"), None);
        // The same providers and placeholders as launcher/loft-launcher.sh,
        // when the checkout is there to compare.
        let sh = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../launcher/loft-launcher.sh");
        if let Ok(sh) = std::fs::read_to_string(sh) {
            for mode in ["emoji", "clipboard", "help"] {
                let (provider, placeholder) = mode_options(mode).unwrap().unwrap();
                let line = format!("ask_or_start {provider} \"{placeholder}\"");
                let case = sh.split(&format!("\n  {mode})\n")).nth(1).expect(mode);
                assert!(case.trim_start().starts_with(&line), "{mode}: loft-launcher.sh has no `{line}`");
            }
        }
    }

    #[test]
    fn command_line_is_what_gdbus_sends() {
        let (argv, platform) = command_line(None);
        assert_eq!(argv, vec![b"walker\0".to_vec()]);
        assert!(platform.is_empty());
        let (_, platform) = command_line(Some(("symbols", "Emoji & Symbols")));
        // a{sv}: "options" → <a{sv}>, as gdbus's {'options': <{…}>}.
        let Value::Dict(d) = &platform["options"] else { panic!("options is a dict") };
        assert_eq!(d.get::<&str, String>(&"provider").unwrap().as_deref(), Some("symbols"));
    }
}
