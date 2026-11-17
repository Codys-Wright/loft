//! Keep Awake under KWin (docs/KWIN.md §4.20): a PowerDevil inhibition held
//! on loft-kwin's own bus connection.
//!
//! stdin `{"cmd": "keepAwake", "why": "Keep Awake (manual)"}` adds one
//! (`org.kde.Solid.PowerManagement.PolicyAgent.AddInhibition`, policy
//! ChangeScreenSettings), `"why": ""` releases it; answered with
//! `{"KeepAwake": {"held", "why", "cookie"?, "error"?}}`.
//!
//! ChangeScreenSettings is what a video player asks for: PowerDevil neither
//! dims nor turns the displays off, implies InterruptSession (no idle sleep),
//! and kscreenlocker skips its idle lock while PowerDevil reports it
//! (`HasInhibition(4)`). PowerDevil watches the caller's bus name, so the
//! inhibition ends with loft-kwin however it exits. When PowerDevil
//! (re)starts its cookies are gone, so `watch` asks for the inhibition again.

use futures_util::StreamExt;
use serde_json::{Value, json};
use zbus::{Connection, MatchRule, MessageStream, Proxy};

pub const SERVICE: &str = "org.kde.Solid.PowerManagement.PolicyAgent";
const PATH: &str = "/org/kde/Solid/PowerManagement/PolicyAgent";
/// PowerDevil::PolicyAgent::ChangeScreenSettings.
pub const CHANGE_SCREEN_SETTINGS: u32 = 4;
const APP: &str = "Loft";

/// What to do to get from what's held to what's wanted.
#[derive(Debug, PartialEq, Eq)]
pub struct Plan {
    pub release: Option<u32>,
    pub add: bool,
}

/// `held`: the cookie and the reason it was added for; `why`: what's wanted
/// now ("" = nothing); `again`: PowerDevil restarted, so the cookie is gone.
pub fn plan(held: Option<(u32, &str)>, why: &str, again: bool) -> Plan {
    match held {
        Some((_, w)) if w == why && !again => Plan { release: None, add: false },
        Some((cookie, _)) => Plan { release: (!again).then_some(cookie), add: !why.is_empty() },
        None => Plan { release: None, add: !why.is_empty() },
    }
}

#[derive(Default)]
pub struct KeepAwake {
    why: String,
    held: Option<(u32, String)>,
    error: String,
}

impl KeepAwake {
    /// Want `why` ("" = nothing). Returns the `{"KeepAwake"}` report.
    pub async fn set(&mut self, conn: &Connection, why: &str) -> Value {
        self.why = why.to_string();
        self.sync(conn, false).await
    }

    /// PowerDevil came or went: its cookies are gone, add again if wanted.
    pub async fn refresh(&mut self, conn: &Connection) -> Value {
        self.sync(conn, true).await
    }

    async fn sync(&mut self, conn: &Connection, again: bool) -> Value {
        let p = plan(self.held.as_ref().map(|(c, w)| (*c, w.as_str())), &self.why, again);
        if again || p.release.is_some() {
            self.held = None;
        }
        self.error.clear();
        if let Some(cookie) = p.release
            && let Err(e) = call::<()>(conn, "ReleaseInhibition", &(cookie,)).await
        {
            eprintln!("loft-kwin: releasing PowerDevil inhibition {cookie}: {e:#}");
        }
        if p.add {
            match call::<u32>(conn, "AddInhibition", &(CHANGE_SCREEN_SETTINGS, APP, self.why.as_str())).await {
                Ok(cookie) => self.held = Some((cookie, self.why.clone())),
                Err(e) => self.error = format!("PowerDevil: {e:#}"),
            }
        }
        self.report()
    }

    pub fn wanted(&self) -> bool {
        !self.why.is_empty()
    }

    fn report(&self) -> Value {
        let mut r = json!({ "held": self.held.is_some(), "why": self.why });
        if let Some((cookie, _)) = &self.held {
            r["cookie"] = json!(cookie);
        }
        if !self.error.is_empty() {
            r["error"] = json!(self.error);
        }
        json!({ "KeepAwake": r })
    }
}

async fn call<R>(conn: &Connection, method: &str, args: &(impl serde::Serialize + zbus::zvariant::DynamicType)) -> zbus::Result<R>
where
    R: for<'d> zbus::zvariant::DynamicDeserialize<'d>,
{
    let p = Proxy::new(conn, SERVICE, PATH, SERVICE).await?;
    p.call(method, args).await
}

/// Calls `changed` whenever PowerDevil's PolicyAgent gets a new owner (or
/// loses it).
pub async fn watch(conn: Connection, changed: impl Fn()) {
    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.add_arg(SERVICE))
        .map(|b| b.build());
    let Ok(rule) = rule else { return };
    let mut stream = match MessageStream::for_match_rule(rule, &conn, Some(8)).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("loft-kwin: can't watch PowerDevil: {e}");
            return;
        }
    };
    while stream.next().await.is_some() {
        changed();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans() {
        // Nothing held: add when wanted.
        assert_eq!(plan(None, "", false), Plan { release: None, add: false });
        assert_eq!(plan(None, "Keep Awake (manual)", false), Plan { release: None, add: true });
        // Held for the same reason: leave it.
        assert_eq!(plan(Some((7, "Keep Awake (manual)")), "Keep Awake (manual)", false), Plan { release: None, add: false });
        // Another reason: swap it; nothing wanted: release only.
        assert_eq!(plan(Some((7, "Keep Awake (manual)")), "Keep Awake (timer)", false), Plan { release: Some(7), add: true });
        assert_eq!(plan(Some((7, "Keep Awake (manual)")), "", false), Plan { release: Some(7), add: false });
        // PowerDevil restarted: the old cookie is gone, add again.
        assert_eq!(plan(Some((7, "Keep Awake (manual)")), "Keep Awake (manual)", true), Plan { release: None, add: true });
        assert_eq!(plan(Some((7, "x")), "", true), Plan { release: None, add: false });
    }
}
