use std::io::Read as _;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use serde_json::{Value, json};

use loft_niri::outputs::{self, OutputChange};
use loft_niri::render::{RenderOpts, RenderResult};
use loft_niri::state::{self, Overrides, Paths};
use loft_niri::{ApplyOpts, binds, config, ipc, keys, render};

/// loft's niri settings backend: live outputs, runtime overrides
/// (overrides/niri.json → overrides/niri.kdl) and keybind listing.
#[derive(Parser)]
#[command(name = "loft-niri", version)]
struct Cli {
    /// State dir (default: $LOFT_STATE_DIR, else $XDG_STATE_HOME/loft).
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    /// niri entry config (default: $LOFT_NIRI_CONFIG, $NIRI_CONFIG, ~/.config/niri/config.kdl).
    #[arg(long, global = true)]
    config: Option<PathBuf>,
    /// Machine-readable output.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Args, Clone, Copy)]
struct RenderFlags {
    /// Write without running `niri validate` first.
    #[arg(long)]
    no_validate: bool,
    /// Don't ask niri to reload its config.
    #[arg(long)]
    no_reload: bool,
}

#[derive(Subcommand)]
enum Cmd {
    /// Live outputs from niri (modes, scale, transform, position, VRR, identity).
    Outputs {
        /// Read `niri msg --json outputs` output from a file instead of IPC
        /// (also $LOFT_NIRI_OUTPUTS_FILE).
        #[arg(long, hide = true)]
        from_file: Option<PathBuf>,
    },
    /// Change one output: live through IPC, and recorded by its stable identity.
    Output {
        #[command(subcommand)]
        cmd: OutputCmd,
    },
    /// Set a setting (see `keys`), e.g. `set layout.gaps 8`.
    Set {
        key: String,
        #[arg(allow_hyphen_values = true)]
        value: String,
        /// Render (validate, swap, reload) right away.
        #[arg(long)]
        render: bool,
        #[command(flatten)]
        flags: RenderFlags,
    },
    /// Drop one setting's override (or a section: `unset input.mouse`).
    Unset {
        key: String,
        #[arg(long)]
        render: bool,
        #[command(flatten)]
        flags: RenderFlags,
    },
    /// `input set <key> <value>` = `set input.<key> <value>`.
    Input {
        #[command(subcommand)]
        cmd: SectionCmd,
    },
    /// `layout set <key> <value>` = `set layout.<key> <value>`.
    Layout {
        #[command(subcommand)]
        cmd: SectionCmd,
    },
    /// `animations set <key> <value>` = `set animations.<key> <value>`.
    Animations {
        #[command(subcommand)]
        cmd: SectionCmd,
    },
    /// The settings this tool manages.
    Keys,
    /// Every managed setting: effective value, and whether it comes from an
    /// override, the config (file:line) or niri's default.
    Show,
    /// overrides/niri.json → overrides/niri.kdl (validated, swapped atomically, reloaded).
    Render {
        /// Print the fragment instead of writing it.
        #[arg(long)]
        dry_run: bool,
        #[command(flatten)]
        flags: RenderFlags,
    },
    /// Every keybind in the active config tree, with source and shadowing.
    Binds {
        /// Only keys bound more than once.
        #[arg(long)]
        conflicts: bool,
    },
    /// Drop overrides: all, a section/key (`input`, `layout.gaps`), or `outputs`.
    Reset {
        target: Option<String>,
        /// Drop one output's overrides (identity or connector).
        #[arg(long)]
        output: Option<String>,
        #[command(flatten)]
        flags: RenderFlags,
    },
    /// Apply a JSON batch (the shell's interface); DATA or stdin.
    Apply {
        data: Option<String>,
        #[command(flatten)]
        flags: RenderFlags,
    },
    /// Settings → Window Rules: translucent windows, apps kept opaque, per-app rules.
    Windows {
        #[command(subcommand)]
        cmd: WindowsCmd,
    },
    /// Spaces (docs/SPACES.md): list, activate, render spaces.kdl.
    Space {
        #[command(flatten)]
        opts: SpaceOpts,
        #[command(subcommand)]
        cmd: SpaceCmd,
    },
}

#[derive(clap::Args)]
struct SpaceOpts {
    /// Space documents (default: $LOFT_SPACES_DIR, else $LOFT_LIBRARY/Spaces, ~/Documents/Loft/Spaces;
    /// LOFT_LIBRARY=none: built-ins only).
    #[arg(long, global = true)]
    spaces_dir: Option<PathBuf>,
    /// The main display, connector or identity (default: Settings → Displays,
    /// else the largest).
    #[arg(long, global = true)]
    main: Option<String>,
}

#[derive(Subcommand)]
enum SpaceCmd {
    /// The spaces in order (Mod+1…9), with their workspaces per role.
    List {
        /// Include archived instances.
        #[arg(long)]
        archived: bool,
    },
    /// Activate a space (id, or its position 1…9): every display it binds.
    /// Activating the active space again brings back `keep` displays that
    /// were switched by hand; the first activation in a session spins the
    /// space's apps up (`startup: "first-activate"`).
    Focus {
        space: String,
        /// Don't spin up apps, even on the first activation.
        #[arg(long)]
        no_open: bool,
    },
    /// Restore a space: gather its open windows, start the missing apps
    /// (in systemd scopes), place them, order the columns once, activate.
    Open {
        space: String,
        /// Don't activate the space (apps still go to its workspaces).
        #[arg(long)]
        no_focus: bool,
        /// Seconds to wait for spawned apps' windows.
        #[arg(long, default_value_t = 10)]
        timeout: u64,
    },
    /// Close the space's windows (claimed or in its scopes); an instance's
    /// workspaces lose their names. The instance file stays.
    Close { space: String },
    /// Pull matching windows back into the space; nothing is started.
    Gather { space: String },
    /// Which window is which app of the space (changes nothing).
    Apps { space: String },
    /// Open the spaces whose `startup` is `login` (session autostart).
    Startup,
    /// Create / move the space's workspaces where they belong; no switching.
    Ensure { space: String },
    /// Print the actions `focus` would send, without sending them.
    Plan {
        space: String,
        /// Plan `move-window` instead of `focus`.
        #[arg(long)]
        move_window: bool,
        /// Plan against a recorded state ({"outputs", "workspaces",
        /// "focused_window"}) instead of the live niri.
        #[arg(long)]
        from_file: Option<PathBuf>,
    },
    /// Activate the next space (Mod+Ctrl+Right).
    Next,
    /// Activate the previous space (Mod+Ctrl+Left).
    Prev,
    /// Put each display's space workspaces in space order.
    Order,
    /// Move the focused window to the space's workspace on the same role
    /// as its display (else main's), without following it.
    MoveWindow { space: String },
    /// spaces → <state>/overrides/spaces.kdl (validated, swapped, reloaded).
    Render {
        /// Print instead of writing.
        #[arg(long)]
        dry_run: bool,
        /// Leave the space binds out.
        #[arg(long)]
        no_binds: bool,
        /// The command the binds run (default: loft-niri).
        #[arg(long)]
        bin: Option<String>,
        #[command(flatten)]
        flags: RenderFlags,
    },
}

#[derive(Subcommand)]
enum WindowsCmd {
    /// Everything the Window Rules page shows: the glass values (theme,
    /// yours, effective), the built-in opaque list, your per-app rules and
    /// every window-rule in the niri config (file:line).
    List,
    /// Translucent windows: `on`, `off`, `status` (default), or `reset` (back
    /// to the theme's values). --focused / --unfocused / --blur set values.
    Glass {
        #[arg(value_parser = ["on", "off", "status", "reset"], default_value = "status")]
        state: String,
        /// Opacity of the focused window, 0.05–1.
        #[arg(long)]
        focused: Option<f64>,
        /// Opacity of the other windows, 0.05–1.
        #[arg(long)]
        unfocused: Option<f64>,
        /// Blur what is behind translucent windows: on or off.
        #[arg(long, value_parser = ["on", "off"])]
        blur: Option<String>,
        #[command(flatten)]
        flags: RenderFlags,
    },
    /// Apps kept opaque: `list` (default), `add APP-ID`, `remove APP-ID`.
    Opaque {
        #[arg(value_parser = ["list", "add", "remove"], default_value = "list")]
        action: String,
        /// niri app id (`niri msg windows`), e.g. org.gnome.Nautilus.
        app_id: Option<String>,
        #[command(flatten)]
        flags: RenderFlags,
    },
    /// Show or change one app's rule: `rule APP [FIELD=VALUE…]`, e.g.
    /// `rule code glass=custom opacity=0.97 blur=off open-floating=true`;
    /// `FIELD=` drops a field. Fields: glass (opaque|custom|native),
    /// opacity, opacity-unfocused, blur, open-floating, open-maximized,
    /// open-fullscreen, default-column-width (0–1), square-corners,
    /// block-out-from (screencast|screen-capture), open-on-workspace,
    /// open-on-output.
    Rule {
        app_id: String,
        fields: Vec<String>,
        #[command(flatten)]
        flags: RenderFlags,
    },
    /// Drop one app's rule, or (no app) every window rule and glass value.
    Reset {
        app_id: Option<String>,
        #[command(flatten)]
        flags: RenderFlags,
    },
}

/// `FIELD=VALUE` from the command line: bools (on/off/true/false), numbers,
/// else a string; empty = null (drop).
fn rule_value(field: &str, v: &str) -> Value {
    let v = v.trim();
    if v.is_empty() || v == "null" {
        return Value::Null;
    }
    match v {
        "on" | "true" | "yes" => return Value::Bool(true),
        "off" | "false" | "no" => return Value::Bool(false),
        _ => {}
    }
    if !matches!(field, "open-on-workspace" | "open-on-output")
        && let Ok(f) = v.parse::<f64>()
    {
        return json!(f);
    }
    Value::String(v.to_string())
}

fn describe_glass(l: &Value) -> String {
    let e = &l["glass"]["effective"];
    let user = l["glass"]["user"].as_object().map(|m| m.len()).unwrap_or(0);
    let mut s = format!(
        "translucent windows: {}\n  focused {}  unfocused {}  blur {}\n  {}",
        if e["enabled"] == true { "on" } else { "off" },
        e["focused"],
        e["unfocused"],
        if e["blur"] == true { "on" } else { "off" },
        if user > 0 { "(your values over the theme's)" } else { "(the theme's values)" },
    );
    let opaque = describe_opaque(l);
    if !opaque.is_empty() {
        s.push_str("\nkept opaque:\n");
        s.push_str(&opaque);
    }
    s
}

fn describe_opaque(l: &Value) -> String {
    let mut lines = Vec::new();
    for d in l["defaults"].as_array().into_iter().flatten() {
        let ids: Vec<_> = d["app_ids"].as_array().into_iter().flatten().chain(d["titles"].as_array().into_iter().flatten()).filter_map(Value::as_str).collect();
        lines.push(format!(
            "  [{}] {:28} built-in  {}",
            if d["on"] == true { "x" } else { " " },
            d["label"].as_str().unwrap_or(""),
            ids.join(" ")
        ));
    }
    if let Some(r) = l["rules"].as_object() {
        for (app, rec) in r {
            if rec["glass"] == "opaque" {
                lines.push(format!("  [x] {app:28} yours"));
            }
        }
    }
    lines.join("\n")
}

#[derive(Subcommand)]
enum SectionCmd {
    Set {
        key: String,
        #[arg(allow_hyphen_values = true)]
        value: String,
        #[arg(long)]
        render: bool,
        #[command(flatten)]
        flags: RenderFlags,
    },
}

#[derive(Subcommand)]
enum OutputCmd {
    /// e.g. `output set "Dell Inc. DELL U2720Q ABC" --mode 3840x2160@60 --scale 1.5`
    Set {
        /// "Make Model Serial" (preferred) or connector name.
        target: String,
        /// WxH or WxH@R, or `auto`.
        #[arg(long)]
        mode: Option<String>,
        /// e.g. 1.25, or `auto`.
        #[arg(long)]
        scale: Option<String>,
        /// X,Y in logical pixels, or `auto`.
        #[arg(long, allow_hyphen_values = true)]
        position: Option<String>,
        /// normal, 90, 180, 270, flipped, flipped-90, flipped-180, flipped-270.
        #[arg(long)]
        transform: Option<String>,
        /// on, off or on-demand.
        #[arg(long)]
        vrr: Option<String>,
        #[arg(long, conflicts_with = "on")]
        off: bool,
        #[arg(long)]
        on: bool,
        /// Apply live only; don't record (e.g. while a change awaits confirmation).
        #[arg(long, conflicts_with = "record_only")]
        live_only: bool,
        /// Record only; don't touch the running output.
        #[arg(long)]
        record_only: bool,
        /// Render (validate, swap, reload) after recording.
        #[arg(long)]
        render: bool,
        #[command(flatten)]
        flags: RenderFlags,
    },
}

fn main() {
    let cli = Cli::parse();
    let json_out = cli.json;
    if let Err(e) = run(cli) {
        if json_out {
            println!("{}", json!({ "ok": false, "error": format!("{e:#}") }));
        } else {
            eprintln!("loft-niri: {e:#}");
        }
        std::process::exit(1);
    }
}

fn print(json_out: bool, v: &Value, text: impl FnOnce() -> String) {
    if json_out {
        println!("{v}");
    } else {
        let t = text();
        if !t.is_empty() {
            println!("{t}");
        }
    }
}

fn run(cli: Cli) -> Result<()> {
    let paths = Paths::new(state::state_dir(cli.state_dir.as_deref()));
    let entry = config::entry_config(cli.config.as_deref());
    let entry = entry.as_deref();
    let j = cli.json;
    let opts = |f: RenderFlags| ApplyOpts {
        entry,
        validate: !f.no_validate,
        reload: !f.no_reload,
    };

    let set_one = |key: &str, value: &str, render: bool, flags: RenderFlags| -> Result<()> {
        let def = keys::find(key)?;
        let v = def.parse(&Value::String(value.to_string()))?;
        let prev = Overrides::load(&paths.json)?;
        let mut ov = prev.clone();
        ov.set(def.key, v.clone());
        let rendered = loft_niri::commit(&paths, &prev, &ov, render, opts(flags))?;
        print(
            j,
            &json!({ "ok": true, "key": def.key, "value": v, "rendered": rendered }),
            || format!("{} = {v}", def.key),
        );
        Ok(())
    };

    match cli.cmd {
        Cmd::Outputs { from_file } => {
            // $LOFT_NIRI_OUTPUTS_FILE: pretend these are the live outputs
            // (UI work on multi-monitor layouts from a single-output session).
            let from_file = from_file.or_else(|| {
                std::env::var_os("LOFT_NIRI_OUTPUTS_FILE")
                    .filter(|v| !v.is_empty())
                    .map(PathBuf::from)
            });
            let outs: outputs::Outputs = match from_file {
                Some(f) => serde_json::from_str(&std::fs::read_to_string(&f)?)
                    .with_context(|| format!("parsing {}", f.display()))?,
                None => ipc::outputs()?,
            };
            let ov = Overrides::load(&paths.json)?;
            let list = outputs::list(&outs, ov.outputs());
            print(j, &list, || {
                list.as_array()
                    .unwrap()
                    .iter()
                    .map(describe_output)
                    .collect::<Vec<_>>()
                    .join("\n")
            });
        }
        Cmd::Output {
            cmd:
                OutputCmd::Set {
                    target,
                    mode,
                    scale,
                    position,
                    transform,
                    vrr,
                    off,
                    on,
                    live_only,
                    record_only,
                    render,
                    flags,
                },
        } => {
            let change = OutputChange {
                mode,
                scale,
                position,
                transform,
                vrr,
                off: if off {
                    Some(true)
                } else if on {
                    Some(false)
                } else {
                    None
                },
            };
            if change == OutputChange::default() {
                bail!(
                    "nothing to change (pass --mode, --scale, --position, --transform, --vrr, --on or --off)"
                );
            }
            let mut data = json!({
                "outputs": {}, "live": !record_only, "record": !live_only, "render": render,
            });
            data["outputs"][&target] = change_json(&change);
            let r = loft_niri::apply(&paths, &data, opts(flags))?;
            print(j, &r, || {
                let mut s = Vec::new();
                if let Some(a) = r["applied_live"].as_array().filter(|a| !a.is_empty()) {
                    let names: Vec<_> = a.iter().filter_map(Value::as_str).collect();
                    s.push(format!("applied live to {}", names.join(", ")));
                }
                if !live_only {
                    s.push(format!("recorded in {}", paths.json.display()));
                }
                s.join("; ")
            });
        }
        Cmd::Set {
            key,
            value,
            render,
            flags,
        } => set_one(&key, &value, render, flags)?,
        Cmd::Input {
            cmd:
                SectionCmd::Set {
                    key,
                    value,
                    render,
                    flags,
                },
        } => set_one(&format!("input.{key}"), &value, render, flags)?,
        Cmd::Layout {
            cmd:
                SectionCmd::Set {
                    key,
                    value,
                    render,
                    flags,
                },
        } => set_one(&format!("layout.{key}"), &value, render, flags)?,
        Cmd::Animations {
            cmd:
                SectionCmd::Set {
                    key,
                    value,
                    render,
                    flags,
                },
        } => set_one(&format!("animations.{key}"), &value, render, flags)?,
        Cmd::Unset { key, render, flags } => {
            let prev = Overrides::load(&paths.json)?;
            let mut ov = prev.clone();
            let removed = ov.remove(&key);
            let rendered = loft_niri::commit(&paths, &prev, &ov, render, opts(flags))?;
            print(
                j,
                &json!({ "ok": true, "removed": removed, "rendered": rendered }),
                || {
                    if removed {
                        format!("{key}: override removed")
                    } else {
                        format!("{key}: no override")
                    }
                },
            );
        }
        Cmd::Keys => {
            let v = Value::Array(keys::KEYS.iter().map(|k| k.describe()).collect());
            print(j, &v, || {
                keys::KEYS
                    .iter()
                    .map(|k| format!("{:32} {:7} {}", k.key, k.kind_name(), k.label))
                    .collect::<Vec<_>>()
                    .join("\n")
            });
        }
        Cmd::Show => {
            let v = loft_niri::show(&paths, entry)?;
            print(j, &v, || describe_show(&v, &paths));
        }
        Cmd::Render { dry_run, flags } => {
            let live = loft_niri::live_outputs();
            if dry_run {
                let ov = Overrides::load(&paths.json)?;
                let base = render::base_tree(entry, &paths);
                let glass = loft_niri::window_rules::GlassTheme::load(&paths.state);
                print!("{}", render::render_with(&ov, base.as_ref(), live.as_ref(), Some(&glass)));
                return Ok(());
            }
            let r = render::render_to_disk(
                &paths,
                &RenderOpts {
                    entry,
                    validate: !flags.no_validate,
                    reload: !flags.no_reload,
                    live: live.as_ref(),
                },
            )?;
            let written = matches!(r, RenderResult::Written);
            print(
                j,
                &json!({ "ok": true, "written": written, "path": paths.kdl }),
                || {
                    if written {
                        format!("wrote {}", paths.kdl.display())
                    } else {
                        format!("{} is up to date", paths.kdl.display())
                    }
                },
            );
        }
        Cmd::Windows { cmd } => {
            use loft_niri::window_rules as wr;
            let listing = || -> Result<Value> {
                let ov = Overrides::load(&paths.json)?;
                let base = render::base_tree(entry, &paths);
                Ok(wr::list(&ov, base.as_ref(), &wr::GlassTheme::load(&paths.state)))
            };
            let apply = |batch: Value, flags: RenderFlags| -> Result<Value> {
                loft_niri::apply(&paths, &batch, opts(flags))
            };
            match cmd {
                WindowsCmd::List => {
                    let l = listing()?;
                    print(j, &l, || describe_glass(&l));
                }
                WindowsCmd::Glass { state, focused, unfocused, blur, flags } => {
                    let mut g = serde_json::Map::new();
                    match state.as_str() {
                        "on" => drop(g.insert("enabled".into(), json!(true))),
                        "off" => drop(g.insert("enabled".into(), json!(false))),
                        "reset" => {
                            for k in ["enabled", "focused", "unfocused", "blur"] {
                                g.insert(k.into(), Value::Null);
                            }
                        }
                        _ => {}
                    }
                    if let Some(f) = focused {
                        g.insert("focused".into(), json!(f));
                    }
                    if let Some(f) = unfocused {
                        g.insert("unfocused".into(), json!(f));
                    }
                    if let Some(b) = blur {
                        g.insert("blur".into(), json!(b == "on"));
                    }
                    if !g.is_empty() {
                        apply(json!({ "window_glass": g }), flags)?;
                    }
                    let l = listing()?;
                    print(j, &l["glass"], || describe_glass(&l));
                }
                WindowsCmd::Opaque { action, app_id, flags } => {
                    if action != "list" {
                        let app = app_id.context("which app? (`opaque add APP-ID`; `niri msg windows` shows app ids)")?;
                        let ov = Overrides::load(&paths.json)?;
                        let batch = wr::opaque_batch(&ov, &app, action == "add");
                        apply(batch, flags)?;
                        let ov = Overrides::load(&paths.json)?;
                        let (on, via) = wr::opaque_state(&ov, &app);
                        let v = json!({ "ok": true, "app_id": app, "opaque": on, "builtin": via });
                        print(j, &v, || format!("{app}: {}", if on { "kept opaque" } else { "translucent (follows the global look)" }));
                    } else {
                        let l = listing()?;
                        print(j, &json!({ "defaults": l["defaults"], "rules": l["rules"] }), || describe_opaque(&l));
                    }
                }
                WindowsCmd::Rule { app_id, fields, flags } => {
                    if !fields.is_empty() {
                        let mut rec = serde_json::Map::new();
                        for f in &fields {
                            let (k, v) = f.split_once('=').with_context(|| format!("`{f}`: expected FIELD=VALUE"))?;
                            rec.insert(k.trim().to_string(), rule_value(k.trim(), v));
                        }
                        apply(json!({ "window_rules": { &app_id: rec } }), flags)?;
                    }
                    let ov = Overrides::load(&paths.json)?;
                    let rec = ov.0.get(wr::RULES).and_then(|r| r.get(&app_id)).cloned().unwrap_or(json!({}));
                    let (opaque, via) = wr::opaque_state(&ov, &app_id);
                    let v = json!({ "app_id": app_id, "rule": rec, "opaque": opaque, "builtin": via });
                    print(j, &v, || {
                        let mut s = format!("{app_id}: {}", serde_json::to_string(&rec).unwrap_or_default());
                        if let Some(b) = via {
                            s.push_str(&format!("\n  built-in opaque entry `{b}`: {}", if opaque { "on" } else { "off" }));
                        }
                        s
                    });
                }
                WindowsCmd::Reset { app_id, flags } => {
                    let batch = match &app_id {
                        Some(a) => json!({ "window_rules": { a: null } }),
                        None => json!({ "reset_window_rules": true }),
                    };
                    let r = apply(batch, flags)?;
                    print(j, &r, || match &app_id {
                        Some(a) => format!("{a}: rule dropped"),
                        None => "window rules and glass values back to the defaults".into(),
                    });
                }
            }
        }
        Cmd::Binds { conflicts } => {
            let tree = loft_niri::load_tree(entry)?;
            let all = binds::collect(&tree);
            let conf = binds::conflicts(&all);
            // A file included twice (the overrides fragment) counts once.
            let mut files: Vec<String> = Vec::new();
            for f in &tree.files {
                let p = f.path.display().to_string();
                if !files.contains(&p) {
                    files.push(p);
                }
            }
            if j {
                let v = if conflicts {
                    json!({
                        "config": tree.entry,
                        "conflicts": conf.iter().map(|(k, ix)| json!({
                            "combo": k,
                            "definitions": ix.iter().map(|&i| &all[i]).collect::<Vec<_>>(),
                        })).collect::<Vec<_>>(),
                        "errors": tree.errors,
                    })
                } else {
                    // Settings → Keyboard Shortcuts: the config's binds
                    // (without our fragment) with the user's changes.
                    let base = render::base_tree(entry, &paths);
                    let base_binds = base.as_ref().map(binds::collect).unwrap_or_default();
                    let ov = Overrides::load(&paths.json)?;
                    json!({
                        "config": tree.entry,
                        "files": files,
                        "binds": all,
                        "conflicts": conf.keys().collect::<Vec<_>>(),
                        "errors": tree.errors,
                        "shortcuts": loft_niri::shortcuts::rows(&base_binds, &ov),
                        "overrides_kdl": paths.kdl,
                    })
                };
                println!("{v}");
            } else if conflicts {
                for (k, ix) in &conf {
                    println!("{k}");
                    for &i in ix {
                        let b = &all[i];
                        let mark = if b.shadowed { "overridden" } else { "wins" };
                        println!("  {mark:10} {:40} {}:{}", b.action_text, b.file, b.line);
                    }
                }
            } else {
                for b in &all {
                    let mark = if b.shadowed { "~" } else { " " };
                    println!(
                        "{mark} {:28} {:44} {}:{}",
                        b.combo, b.action_text, b.file, b.line
                    );
                }
                for e in &tree.errors {
                    eprintln!("warning: {e}");
                }
            }
        }
        Cmd::Reset {
            target,
            output,
            flags,
        } => {
            let prev = Overrides::load(&paths.json)?;
            let mut ov = prev.clone();
            match (&target, &output) {
                (_, Some(id)) => {
                    // A connector name resolves to the identity it's recorded under.
                    let id = loft_niri::live_outputs()
                        .as_ref()
                        .and_then(|l| outputs::find(l, id).map(outputs::identity))
                        .unwrap_or_else(|| id.clone());
                    ov.remove_output(&id);
                }
                (None, None) => ov = Overrides::default(),
                (Some(t), None) => {
                    ov.remove(t);
                }
            }
            let rendered = loft_niri::commit(&paths, &prev, &ov, true, opts(flags))?;
            print(j, &json!({ "ok": true, "rendered": rendered }), || {
                "overrides reset".into()
            });
        }
        Cmd::Space { opts, cmd } => space_cmd(&paths, entry, j, opts, cmd)?,
        Cmd::Apply { data, flags } => {
            let text = match data {
                Some(d) => d,
                None => {
                    let mut s = String::new();
                    std::io::stdin().read_to_string(&mut s)?;
                    s
                }
            };
            let data: Value = serde_json::from_str(&text).context("parsing the apply batch")?;
            let r = loft_niri::apply(&paths, &data, opts(flags))?;
            print(j, &r, || r.to_string());
        }
    }
    Ok(())
}

fn describe_output(o: &Value) -> String {
    let l = &o["logical"];
    let mut s = format!(
        "{}  \"{}\"\n  {}  scale {}  transform {}  at {},{}  vrr {}{}",
        o["name"].as_str().unwrap_or(""),
        o["identity"].as_str().unwrap_or(""),
        o["mode"].as_str().unwrap_or("off"),
        o["scale"],
        o["transform"].as_str().unwrap_or(""),
        l["x"],
        l["y"],
        if o["vrr_enabled"] == true {
            "on"
        } else {
            "off"
        },
        if o["vrr_supported"] == true {
            ""
        } else {
            " (unsupported)"
        },
    );
    if !o["override"].is_null() {
        s.push_str(&format!("\n  override {}", o["override"]));
    }
    s
}

fn describe_show(v: &Value, paths: &Paths) -> String {
    let mut s = format!(
        "config: {}\noverrides: {}\n",
        v["config"].as_str().unwrap_or("(none found)"),
        paths.json.display()
    );
    for (k, d) in v["keys"].as_object().unwrap() {
        let src = match d["source"].as_str().unwrap_or("") {
            "config" => format!("{}:{}", d["file"].as_str().unwrap_or(""), d["line"]),
            other => other.to_string(),
        };
        s.push_str(&format!("{k:32} {:20} {src}\n", d["value"].to_string()));
    }
    for (id, o) in v["outputs"].as_object().unwrap() {
        s.push_str(&format!("output \"{id}\" {o}\n"));
    }
    s.trim_end().to_string()
}

fn change_json(c: &OutputChange) -> Value {
    let mut m = serde_json::Map::new();
    for (k, v) in [
        ("mode", &c.mode),
        ("scale", &c.scale),
        ("position", &c.position),
        ("transform", &c.transform),
        ("vrr", &c.vrr),
    ] {
        if let Some(v) = v {
            m.insert(k.into(), json!(v));
        }
    }
    if let Some(off) = c.off {
        m.insert("off".into(), json!(off));
    }
    Value::Object(m)
}

fn space_cmd(
    paths: &Paths,
    entry: Option<&std::path::Path>,
    j: bool,
    opts: SpaceOpts,
    cmd: SpaceCmd,
) -> Result<()> {
    use loft_niri::spaces::model::{Binding, Catalog, Env, library_dir};
    use loft_niri::spaces::{launch, live, plan, render as srender, roles};

    let dir = opts.spaces_dir.or_else(library_dir);
    let cat = Catalog::load(dir.as_deref(), &Env::from_process(&paths.state));
    for p in &cat.problems {
        eprintln!("loft-niri: spaces: {p}");
    }
    let main = opts.main.or_else(|| live::main_from_settings(&paths.state));
    let lopts = |main: Option<String>| launch::Opts::from_env(&paths.state, main);
    let find = |key: &str| {
        cat.find(key).with_context(|| {
            let ids: Vec<_> = cat.active().iter().map(|s| s.id.clone()).collect();
            format!("no space `{key}` (spaces: {})", ids.join(", "))
        })
    };
    let report = |plans: &[plan::Plan]| {
        let v = json!({ "ok": true, "rounds": plans });
        print(j, &v, || {
            plans
                .iter()
                .flat_map(|p| p.notes.iter().cloned())
                .collect::<Vec<_>>()
                .join("\n")
        });
    };
    match cmd {
        SpaceCmd::List { archived } => {
            let spaces: Vec<_> = cat
                .spaces
                .iter()
                .filter(|s| archived || !s.archived)
                .collect();
            let active = cat.active();
            let rows: Vec<Value> = spaces
                .iter()
                .map(|s| {
                    let pos = active.iter().position(|a| a.id == s.id).map(|i| i + 1);
                    let displays: serde_json::Map<String, Value> = s
                        .displays
                        .iter()
                        .map(|(r, b)| {
                            let v = match b {
                                Binding::Keep => json!("keep"),
                                Binding::Bound(b) => json!(b.workspace),
                            };
                            (r.clone(), v)
                        })
                        .collect();
                    json!({
                        "id": s.id, "name": s.name, "icon": s.icon, "order": s.order,
                        "position": pos, "template": s.template, "archived": s.archived,
                        "displays": displays, "doc": s.doc,
                    })
                })
                .collect();
            print(
                j,
                &json!({ "spaces": rows, "problems": cat.problems }),
                || {
                    rows.iter()
                        .map(|r| {
                            let pos = r["position"].as_u64().map_or(" ".into(), |p| p.to_string());
                            let ws: Vec<String> = r["displays"]
                                .as_object()
                                .unwrap()
                                .iter()
                                .map(|(k, v)| format!("{k}={}", v.as_str().unwrap_or("")))
                                .collect();
                            format!(
                                "{pos} {} {:24} {:16} {}",
                                r["icon"].as_str().unwrap_or(" "),
                                r["name"].as_str().unwrap_or(""),
                                r["id"].as_str().unwrap_or(""),
                                ws.join("  ")
                            )
                        })
                        .collect::<Vec<_>>()
                        .join("\n")
                },
            );
        }
        SpaceCmd::Focus { space, no_open } => {
            let s = find(&space)?;
            let r = launch::focus(&cat, s, &lopts(main), !no_open)?;
            print(j, &serde_json::to_value(&r)?, || r.text());
        }
        SpaceCmd::Open {
            space,
            no_focus,
            timeout,
        } => {
            let s = find(&space)?;
            let mut o = lopts(main);
            o.timeout = std::time::Duration::from_secs(timeout);
            let r = launch::open(&cat, s, &o, !no_focus)?;
            print(j, &serde_json::to_value(&r)?, || r.text());
        }
        SpaceCmd::Close { space } => {
            let r = launch::close(find(&space)?, &lopts(main))?;
            print(j, &serde_json::to_value(&r)?, || {
                format!("{} actions sent", r.actions.len())
            });
        }
        SpaceCmd::Gather { space } => {
            let r = launch::gather(&cat, find(&space)?, &lopts(main))?;
            print(j, &serde_json::to_value(&r)?, || r.text());
        }
        SpaceCmd::Apps { space } => {
            let r = launch::inspect(find(&space)?, &lopts(main))?;
            print(j, &serde_json::to_value(&r)?, || r.text());
        }
        SpaceCmd::Startup => {
            let rs = launch::startup(&cat, &lopts(main))?;
            print(j, &serde_json::to_value(&rs)?, || {
                rs.iter()
                    .map(|r| format!("{}:\n{}", r.space, r.text()))
                    .collect::<Vec<_>>()
                    .join("\n")
            });
        }
        SpaceCmd::Ensure { space } => {
            let s = find(&space)?;
            let order = cat.active();
            report(&live::run(main, |st| plan::ensure_only(st, s, &order))?)
        }
        SpaceCmd::MoveWindow { space } => {
            let s = find(&space)?;
            let order = cat.active();
            report(&live::run(main, |st| plan::move_window(st, s, &order))?)
        }
        SpaceCmd::Order => {
            let order = cat.active();
            report(&live::run(main, |st| plan::order_all(st, &order))?)
        }
        SpaceCmd::Next | SpaceCmd::Prev => {
            let forward = matches!(cmd, SpaceCmd::Next);
            let st = live::read_state(main.clone())?;
            let s = plan::step(&st, &cat, forward).context("no spaces")?;
            let r = launch::focus(&cat, s, &lopts(main), true)?;
            print(j, &serde_json::to_value(&r)?, || r.text());
        }
        SpaceCmd::Plan {
            space,
            move_window,
            from_file,
        } => {
            let s = find(&space)?;
            let st = match from_file {
                Some(f) => live::state_from_file(&f, main)?,
                None => live::read_state(main)?,
            };
            let order = cat.active();
            let p = if move_window {
                plan::move_window(&st, s, &order)
            } else {
                plan::activate(&st, s, &order)
            };
            // The plan is JSON either way: the actions as niri's IPC takes them.
            println!("{}", serde_json::to_string_pretty(&p)?);
        }
        SpaceCmd::Render {
            dry_run,
            no_binds,
            bin,
            flags,
        } => {
            let displays = match loft_niri::live_outputs() {
                Some(o) => roles::displays_from_niri(&o),
                None => {
                    eprintln!(
                        "loft-niri: niri isn't reachable; workspaces are declared without displays"
                    );
                    Vec::new()
                }
            };
            let opts = srender::RenderOpts {
                bin: bin.as_deref().unwrap_or("loft-niri"),
                binds: !no_binds,
            };
            let text = srender::render(&cat.active(), &displays, main.as_deref(), &opts);
            if dry_run {
                print!("{text}");
                return Ok(());
            }
            let written = live::render_to_disk(
                &paths.state,
                &text,
                entry,
                !flags.no_validate,
                !flags.no_reload,
            )?;
            let path = live::spaces_kdl(&paths.state);
            // Workspaces a reload declares land in reverse order; fix it.
            if written && !flags.no_reload && loft_niri::ipc::available() {
                let order = cat.active();
                live::run(main.clone(), |st| plan::order_all(st, &order))?;
            }
            print(
                j,
                &json!({ "ok": true, "written": written, "path": path }),
                || {
                    if written {
                        format!("wrote {}", path.display())
                    } else {
                        format!("{} is up to date", path.display())
                    }
                },
            );
        }
    }
    Ok(())
}
