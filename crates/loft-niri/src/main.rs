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
                print!("{}", render::render(&ov, base.as_ref(), live.as_ref()));
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
                    json!({
                        "config": tree.entry,
                        "files": files,
                        "binds": all,
                        "conflicts": conf.keys().collect::<Vec<_>>(),
                        "errors": tree.errors,
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
