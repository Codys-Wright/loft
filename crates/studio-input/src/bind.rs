//! "Press" a niri keybind: niri never sees virtual-keyboard keys (smithay
//! hands them straight to the focused client), so `studio-input bind COMBO`
//! looks the combo up in the session's niri config — the same tree niri
//! loads, includes and all — and runs the bound action through niri IPC
//! (`niri msg action …`), so it runs inside that niri, with its environment.

use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::Value;
use studio_niri::binds::{self, Bind};
use studio_niri::config::ConfigTree;

/// niri's `Mod` for this session: `input { mod-key-nested … }` when nested,
/// `mod-key` otherwise (niri's defaults: Alt nested, Super on a TTY).
pub fn mod_key(tree: &ConfigTree, nested: bool) -> String {
    let get = |name: &str| {
        tree.find_last(&["input", name])
            .and_then(|n| n.node.entries().first().cloned())
            .and_then(|e| e.value().as_string().map(str::to_string))
    };
    let k = if nested {
        get("mod-key-nested").or_else(|| Some("Alt".into()))
    } else {
        get("mod-key")
    };
    k.unwrap_or_else(|| "Super".into())
}

/// The canonical modifier name niri's normalize() gives the Mod key.
fn mod_canon(mod_key: &str) -> String {
    binds::normalize(&format!("{mod_key}+x"))
        .0
        .into_iter()
        .next()
        .unwrap_or_default()
}

/// Find the bind that wins for `combo` (last definition). `Mod` matches
/// niri's Mod; so does the session's actual mod key (`super+space` finds
/// `Mod+Space` when Mod is Super).
pub fn find<'a>(all: &'a [Bind], combo: &str, mod_key: &str) -> Result<&'a Bind> {
    let (mods, trigger) = binds::normalize(combo);
    if mods.iter().any(|m| m == "?") {
        bail!("`{combo}`: unknown modifier (Mod, Super, Ctrl, Alt, Shift, ISO_Level3_Shift)");
    }
    let canon = |mods: &[String], trigger: &str| {
        let mut m: Vec<String> = mods.to_vec();
        m.sort();
        m.push(trigger.to_string());
        m.join("+").to_lowercase()
    };
    let want = canon(&mods, &trigger);
    let mk = mod_canon(mod_key);
    // `super+space` → `Mod+Space` when Super is the mod key.
    let alt = mods.contains(&mk).then(|| {
        let m: Vec<String> = mods
            .iter()
            .map(|m| {
                if *m == mk {
                    "Mod".to_string()
                } else {
                    m.clone()
                }
            })
            .collect();
        canon(&m, &trigger)
    });
    let key_of = |b: &Bind| canon(&b.modifiers, &b.trigger);
    let live: Vec<&Bind> = all.iter().filter(|b| !b.shadowed).collect();
    live.iter()
        .find(|b| key_of(b) == want)
        .or_else(|| {
            alt.as_ref()
                .and_then(|a| live.iter().find(|b| &key_of(b) == a))
        })
        .copied()
        .with_context(|| format!("no niri bind for `{combo}` (see `studio-input bind --list`)"))
}

fn arg_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// The bound action as `niri msg action` arguments.
pub fn action_args(b: &Bind) -> Result<Vec<String>> {
    if b.action.is_empty() {
        bail!("bind {} has no action", b.combo);
    }
    let mut args = vec![b.action.clone()];
    match b.action.as_str() {
        "spawn" | "spawn-sh" => {
            args.push("--".into());
            args.extend(b.args.iter().map(arg_text));
            return Ok(args);
        }
        "quit" => {
            if b.action_props.get("skip-confirmation") == Some(&Value::Bool(true)) {
                args.push("--skip-confirmation".into());
            }
            return Ok(args);
        }
        _ => {}
    }
    for (k, v) in &b.action_props {
        args.push(format!("--{k}"));
        args.push(arg_text(v));
    }
    if !b.args.is_empty() {
        // Values like "-10%" must not read as flags.
        args.push("--".into());
        args.extend(b.args.iter().map(arg_text));
    }
    Ok(args)
}

/// Run the bind's action in the niri at `socket`.
pub fn run(b: &Bind, socket: &Path) -> Result<()> {
    let args = action_args(b)?;
    let out = Command::new("niri")
        .arg("msg")
        .arg("action")
        .args(&args)
        .env("NIRI_SOCKET", socket)
        .output()
        .context("running `niri msg action` (is niri on PATH?)")?;
    if !out.status.success() {
        bail!(
            "niri msg action {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree(text: &str) -> ConfigTree {
        let d = std::env::temp_dir().join(format!("studio-input-bind-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join(format!("c{}.kdl", text.len()));
        std::fs::write(&p, text).unwrap();
        ConfigTree::load(&p, &|_| false).unwrap()
    }

    const CONFIG: &str = r#"
input {
    mod-key "ISO_Level3_Shift"
    mod-key-nested "ISO_Level3_Shift"
}
binds {
    Mod+Space { spawn "studio-launcher" "open"; }
    Mod+Return { spawn "foot"; }
    Mod+Shift+1 { move-column-to-workspace 1 focus=false; }
    Mod+Minus { set-column-width "-10%"; }
    Mod+O { toggle-overview; }
    Mod+Shift+E { quit skip-confirmation=true; }
}
binds {
    Mod+Return { spawn-sh "kitty --single-instance"; }
}
"#;

    #[test]
    fn finds_and_translates_binds() {
        let t = tree(CONFIG);
        let all = binds::collect(&t);
        let mk = mod_key(&t, true);
        assert_eq!(mk, "ISO_Level3_Shift");

        let b = find(&all, "mod+space", &mk).unwrap();
        assert_eq!(
            action_args(b).unwrap(),
            ["spawn", "--", "studio-launcher", "open"]
        );
        // The real mod key spelled out finds the Mod bind.
        assert_eq!(
            find(&all, "ISO_Level3_Shift+o", &mk).unwrap().action,
            "toggle-overview"
        );
        // The later definition wins.
        let r = find(&all, "Mod+Return", &mk).unwrap();
        assert_eq!(
            action_args(r).unwrap(),
            ["spawn-sh", "--", "kitty --single-instance"]
        );
        assert_eq!(
            action_args(find(&all, "mod+shift+1", &mk).unwrap()).unwrap(),
            ["move-column-to-workspace", "--focus", "false", "--", "1"]
        );
        assert_eq!(
            action_args(find(&all, "mod+minus", &mk).unwrap()).unwrap(),
            ["set-column-width", "--", "-10%"]
        );
        assert_eq!(
            action_args(find(&all, "mod+shift+e", &mk).unwrap()).unwrap(),
            ["quit", "--skip-confirmation"]
        );
        assert!(find(&all, "super+space", &mk).is_err());
        assert!(find(&all, "hyper+space", &mk).is_err());
    }

    #[test]
    fn default_mod_keys() {
        let t = tree("binds {\n}\n");
        assert_eq!(mod_key(&t, true), "Alt");
        assert_eq!(mod_key(&t, false), "Super");
    }
}
