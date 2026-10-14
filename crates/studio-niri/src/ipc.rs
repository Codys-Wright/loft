//! niri IPC (`$NIRI_SOCKET`) through the niri-ipc crate.

use anyhow::{Context, Result, bail};
use niri_ipc::socket::Socket;
use niri_ipc::{Action, OutputAction, OutputConfigChanged, Request, Response};

use crate::outputs::Outputs;

pub fn available() -> bool {
    std::env::var_os(niri_ipc::socket::SOCKET_PATH_ENV).is_some_and(|v| !v.is_empty())
}

pub fn request(req: Request) -> Result<Response> {
    let mut sock = Socket::connect().context("connecting to niri ($NIRI_SOCKET)")?;
    match sock.send(req).context("talking to niri")? {
        Ok(r) => Ok(r),
        Err(e) => bail!("niri: {e}"),
    }
}

pub fn outputs() -> Result<Outputs> {
    match request(Request::Outputs)? {
        Response::Outputs(o) => Ok(o),
        other => bail!("unexpected reply to Outputs: {other:?}"),
    }
}

/// Apply output actions live (transient: niri forgets them when the output
/// config in the files changes — which is why we also record them).
pub fn apply_output(name: &str, actions: Vec<OutputAction>) -> Result<()> {
    for action in actions {
        let reply = request(Request::Output {
            output: name.to_string(),
            action,
        })?;
        if let Response::OutputConfigChanged(OutputConfigChanged::OutputWasMissing) = reply {
            bail!("niri has no output `{name}`");
        }
    }
    Ok(())
}

/// Ask niri to re-read its config now instead of waiting for the watcher.
pub fn reload_config() {
    if available() {
        let _ = request(Request::Action(Action::LoadConfigFile { path: None }));
    }
}
