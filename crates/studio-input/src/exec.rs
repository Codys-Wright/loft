//! Runs commands against a target: one connection, one keymap, in order.

use std::path::PathBuf;
use std::process::Command;
use std::thread::sleep;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::json;
use studio_niri::binds::{self, Bind};
use studio_niri::config::ConfigTree;

use crate::backend::{Axis, Backend, Uinput, Wayland};
use crate::cli::{Button, Cmd, Global, ScrollDir, button_args};
use crate::keymap::{Combo, Keymap, Modifier, keysym_name, parse_combo, text_strokes};
use crate::niri::{Niri, OutputRect, bounding, find_output, window_rect};
use crate::session::Target;
use crate::{bind, session};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// Time for the compositor/app to see a hover before a press.
const SETTLE_MS: u64 = 30;

pub struct Exec {
    pub target: Target,
    global: Global,
    backend: Option<Box<dyn Backend>>,
    keymap: Keymap,
    outputs: Option<Vec<OutputRect>>,
    tree: Option<Option<ConfigTree>>,
    mask: u32,
    held_mods: Vec<Modifier>,
    held_keys: Vec<(u32, Combo)>,
    held_buttons: Vec<Button>,
    script: bool,
}

fn needs_pointer(c: &Cmd) -> bool {
    matches!(
        c,
        Cmd::Move { .. }
            | Cmd::Click { .. }
            | Cmd::Down { .. }
            | Cmd::Up { .. }
            | Cmd::Drag { .. }
            | Cmd::Scroll { .. }
    )
}

fn needs_keyboard(c: &Cmd) -> bool {
    matches!(
        c,
        Cmd::Type { .. } | Cmd::Key { .. } | Cmd::Keydown { .. } | Cmd::Keyup { .. }
    )
}

impl Exec {
    pub fn new(target: Target, global: Global, script: bool) -> Exec {
        Exec {
            target,
            global,
            backend: None,
            keymap: Keymap::new(),
            outputs: None,
            tree: None,
            mask: 0,
            held_mods: Vec::new(),
            held_keys: Vec::new(),
            held_buttons: Vec::new(),
            script,
        }
    }

    fn niri(&self) -> Result<Niri> {
        let s = self.target.niri_socket.as_ref().with_context(|| {
            format!("{} has no niri socket ($NIRI_SOCKET)", self.target.label())
        })?;
        Ok(Niri::new(s))
    }

    fn outputs(&mut self) -> Result<&[OutputRect]> {
        if self.outputs.is_none() {
            self.outputs = Some(self.niri()?.outputs()?);
        }
        Ok(self.outputs.as_deref().unwrap_or_default())
    }

    fn tree(&mut self) -> Option<&ConfigTree> {
        if self.tree.is_none() {
            let t = self
                .target
                .niri_config
                .as_deref()
                .and_then(|p| ConfigTree::load(p, &|_| false).ok());
            self.tree = Some(t);
        }
        self.tree.as_ref().and_then(|t| t.as_ref())
    }

    /// Open the devices the commands need, with a keymap covering all of
    /// their text and keys.
    pub fn prepare(&mut self, cmds: &[Cmd]) -> Result<()> {
        let pointer = cmds.iter().any(needs_pointer);
        let keyboard = cmds.iter().any(needs_keyboard);
        for c in cmds {
            match c {
                Cmd::Type { text } => {
                    text_strokes(&mut self.keymap, &text.join(" "))?;
                }
                Cmd::Key { combos } => {
                    for c in combos {
                        if let Some(k) = parse_combo(c)?.key {
                            self.keymap.ensure(&k)?;
                        }
                    }
                }
                Cmd::Keydown { combo } | Cmd::Keyup { combo } => {
                    if let Some(k) = parse_combo(combo)?.key {
                        self.keymap.ensure(&k)?;
                    }
                }
                _ => {}
            }
        }
        if !pointer && !keyboard {
            return Ok(());
        }
        if self.global.uinput {
            if !self.target.is_live() || !self.global.yes_live {
                bail!(
                    "--uinput drives the whole live seat; it needs --live --yes-live (nested sessions can't receive it)"
                );
            }
            let b = bounding(self.outputs()?);
            eprintln!("studio-input: uinput devices on the LIVE seat ({b})");
            self.backend = Some(Box::new(Uinput::new(b)?));
        } else {
            let keymap = keyboard.then(|| self.keymap.to_xkb());
            let w = Wayland::connect(&self.target.socket_path(), pointer, keymap.as_deref())?;
            self.backend = Some(Box::new(w));
        }
        if self.target.is_live() && self.global.verbose {
            eprintln!("studio-input: driving {}", self.target.label());
        }
        Ok(())
    }

    fn be(&mut self) -> Result<&mut Box<dyn Backend>> {
        self.backend.as_mut().context("no input devices open")
    }

    fn point(&mut self, x: f64, y: f64, output: Option<&str>) -> Result<(f64, f64)> {
        Ok(match output {
            Some(o) => {
                let r = find_output(self.outputs()?, o)?.rect;
                (r.x + x, r.y + y)
            }
            None => (x, y),
        })
    }

    fn move_to(&mut self, x: f64, y: f64, output: Option<&str>) -> Result<()> {
        let (x, y) = self.point(x, y, output)?;
        let outs = self.outputs()?;
        let b = bounding(outs);
        if !outs.iter().any(|o| o.rect.contains(x, y)) {
            eprintln!("studio-input: warning: {x},{y} is outside every output (clamped)");
        }
        if self.global.verbose {
            eprintln!("  move {x},{y}");
        }
        self.be()?.motion_abs(x, y, b)
    }

    fn key_delay(&self) {
        sleep(ms(self.global.key_delay));
    }

    fn set_mask(&mut self, mask: u32) -> Result<()> {
        if mask != self.mask {
            self.mask = mask;
            self.be()?.modifiers(mask)?;
        }
        Ok(())
    }

    fn uinput(&self) -> bool {
        self.global.uinput
    }

    fn press_mods(&mut self, mods: &[Modifier]) -> Result<()> {
        for &m in mods {
            if self.held_mods.contains(&m) {
                continue;
            }
            self.be()?.key(m.code(), true)?;
            self.held_mods.push(m);
            let mask = self.mask | m.mask();
            self.set_mask(mask)?;
            self.key_delay();
        }
        Ok(())
    }

    fn release_mods(&mut self, mods: &[Modifier]) -> Result<()> {
        for &m in mods.iter().rev() {
            // Still needed by another held key?
            if self.held_keys.iter().any(|(_, c)| c.mods.contains(&m)) {
                continue;
            }
            if let Some(i) = self.held_mods.iter().position(|h| *h == m) {
                self.held_mods.remove(i);
                self.be()?.key(m.code(), false)?;
                let mask = self.mask & !m.mask();
                self.set_mask(mask)?;
                self.key_delay();
            }
        }
        Ok(())
    }

    /// Press (and maybe release) the key of a combo, with Shift added when
    /// its keysym sits on the shifted level (`question`, `A`).
    fn combo(&mut self, combo: &Combo, press: bool, release: bool) -> Result<()> {
        let mut mods = combo.mods.clone();
        let stroke = match &combo.key {
            Some(k) => {
                let s = self
                    .keymap
                    .stroke(k)
                    .with_context(|| format!("`{k}` is not in the keymap"))?;
                if self.uinput() && self.keymap.is_spare(k) {
                    bail!("--uinput can only press keys of a US keyboard, not `{k}`");
                }
                if s.shift && !mods.contains(&Modifier::Shift) {
                    mods.push(Modifier::Shift);
                }
                Some(s)
            }
            None => None,
        };
        if press {
            self.press_mods(&mods)?;
            if let Some(s) = stroke {
                self.be()?.key(s.evdev(), true)?;
                self.key_delay();
                if !release {
                    self.held_keys.push((
                        s.evdev(),
                        Combo {
                            mods: mods.clone(),
                            key: combo.key.clone(),
                        },
                    ));
                }
            }
        }
        if release {
            if let Some(s) = stroke {
                self.held_keys.retain(|(c, _)| *c != s.evdev());
                self.be()?.key(s.evdev(), false)?;
                self.key_delay();
            }
            self.release_mods(&mods)?;
        }
        Ok(())
    }

    fn type_text(&mut self, text: &str) -> Result<()> {
        let strokes = text_strokes(&mut self.keymap, text)?;
        for (c, s) in strokes {
            let sym = if c == '\n' {
                "Return".into()
            } else {
                keysym_name(&c.to_string()).unwrap_or_default()
            };
            if self.uinput() && self.keymap.is_spare(&sym) {
                bail!("--uinput can only type characters of a US keyboard, not `{c}`");
            }
            let shift = s.shift && !self.held_mods.contains(&Modifier::Shift);
            if shift {
                self.press_mods(&[Modifier::Shift])?;
            }
            self.be()?.key(s.evdev(), true)?;
            self.key_delay();
            self.be()?.key(s.evdev(), false)?;
            self.key_delay();
            if shift {
                self.release_mods(&[Modifier::Shift])?;
            }
        }
        Ok(())
    }

    /// Hint when a `key` combo is really a niri bind (which won't fire).
    fn bind_hint(&mut self, combo_text: &str) {
        let nested = self.target.nested;
        if let Some(t) = self.tree() {
            let all = binds::collect(t);
            let mk = bind::mod_key(t, nested);
            if bind::find(&all, combo_text, &mk).is_ok() && !self.global.uinput {
                eprintln!(
                    "studio-input: note: `{combo_text}` is a niri keybind; niri ignores virtual-keyboard keys (the focused app gets them). Use `bind {combo_text}` to run the bind."
                );
            }
        }
    }

    fn binds(&mut self) -> Result<(Vec<Bind>, String)> {
        let nested = self.target.nested;
        let path = self.target.niri_config.clone();
        let t = self.tree().with_context(|| match &path {
            Some(p) => format!("can't read the niri config {}", p.display()),
            None => format!("no niri config known for {}", "the target"),
        })?;
        Ok((binds::collect(t), bind::mod_key(t, nested)))
    }

    pub fn run(&mut self, cmd: &Cmd) -> Result<()> {
        if self.global.verbose {
            eprintln!("> {cmd:?}");
        }
        match cmd {
            Cmd::Move { x, y, output, rel } => {
                if *rel {
                    self.be()?.motion_rel(*x, *y)?;
                } else {
                    self.move_to(*x, *y, output.as_deref())?;
                }
            }
            Cmd::Click {
                args,
                double,
                output,
                hold,
            } => {
                let (b, at) = button_args(args)?;
                if let Some((x, y)) = at {
                    self.move_to(x, y, output.as_deref())?;
                    sleep(ms(SETTLE_MS));
                }
                for i in 0..if *double { 2 } else { 1 } {
                    if i > 0 {
                        sleep(ms(60));
                    }
                    self.be()?.button(b.code(), true)?;
                    sleep(ms(*hold));
                    self.be()?.button(b.code(), false)?;
                }
            }
            Cmd::Down { args, output } | Cmd::Up { args, output } => {
                let down = matches!(cmd, Cmd::Down { .. });
                let (b, at) = button_args(args)?;
                if let Some((x, y)) = at {
                    self.move_to(x, y, output.as_deref())?;
                    sleep(ms(SETTLE_MS));
                }
                self.be()?.button(b.code(), down)?;
                if down {
                    self.held_buttons.push(b);
                } else {
                    self.held_buttons.retain(|h| *h != b);
                }
            }
            Cmd::Drag {
                x1,
                y1,
                x2,
                y2,
                steps,
                duration,
                button,
                hold,
                output,
            } => {
                let (ax, ay) = self.point(*x1, *y1, output.as_deref())?;
                let (bx, by) = self.point(*x2, *y2, output.as_deref())?;
                self.move_to(ax, ay, None)?;
                sleep(ms(SETTLE_MS));
                self.be()?.button(button.code(), true)?;
                sleep(ms(*hold));
                let steps = (*steps).max(1);
                let dt = Duration::from_micros(duration * 1000 / steps as u64);
                for i in 1..=steps {
                    let t = i as f64 / steps as f64;
                    // Ease in-out, like a hand.
                    let e = t * t * (3.0 - 2.0 * t);
                    self.move_to(ax + (bx - ax) * e, ay + (by - ay) * e, None)?;
                    sleep(dt);
                }
                sleep(ms(*hold));
                self.be()?.button(button.code(), false)?;
            }
            Cmd::Scroll {
                dir,
                amount,
                smooth,
                at,
                output,
            } => {
                if let Some(at) = at {
                    self.move_to(at[0], at[1], output.as_deref())?;
                    sleep(ms(SETTLE_MS));
                }
                let (axis, sign) = match dir {
                    ScrollDir::Up => (Axis::Vertical, -1.0),
                    ScrollDir::Down => (Axis::Vertical, 1.0),
                    ScrollDir::Left => (Axis::Horizontal, -1.0),
                    ScrollDir::Right => (Axis::Horizontal, 1.0),
                };
                if *smooth {
                    let total = amount.abs();
                    let n = (total / 10.0).ceil().max(1.0) as u32;
                    for i in 0..n {
                        let step = (total / n as f64) * sign;
                        self.be()?.smooth_scroll(axis, step, i + 1 == n)?;
                        sleep(ms(10));
                    }
                } else {
                    for _ in 0..(amount.abs().round() as u32).max(1) {
                        self.be()?.wheel(axis, sign as i32)?;
                        sleep(ms(20));
                    }
                }
            }
            Cmd::Type { text } => self.type_text(&text.join(" "))?,
            Cmd::Key { combos } => {
                for c in combos {
                    let combo = parse_combo(c)?;
                    if combo
                        .mods
                        .iter()
                        .any(|m| matches!(m, Modifier::Super | Modifier::Level3 | Modifier::Alt))
                    {
                        self.bind_hint(c);
                    }
                    self.combo(&combo, true, true)?;
                }
            }
            Cmd::Keydown { combo } => {
                let c = parse_combo(combo)?;
                self.combo(&c, true, false)?;
            }
            Cmd::Keyup { combo } => {
                let c = parse_combo(combo)?;
                self.combo(&c, false, true)?;
            }
            Cmd::Wait { ms: n } => {
                if let Some(b) = self.backend.as_mut() {
                    b.sync()?;
                }
                sleep(ms(*n));
            }
            Cmd::Bind {
                combo,
                list,
                dry_run,
            } => self.bind(combo.as_deref(), *list, *dry_run)?,
            Cmd::Info { json } => self.info(*json)?,
            Cmd::Spawn { command } => {
                if self.target.is_live() && !self.global.live {
                    bail!("refusing to spawn on the live desktop without --live");
                }
                self.niri()?.action(niri_ipc::Action::Spawn {
                    command: command.clone(),
                })?;
            }
            Cmd::Shot { args } => {
                if let Some(b) = self.backend.as_mut() {
                    b.sync()?;
                }
                self.shot(args)?;
            }
            Cmd::Script { .. } => bail!("scripts can't nest"),
        }
        Ok(())
    }

    fn bind(&mut self, combo: Option<&str>, list: bool, dry_run: bool) -> Result<()> {
        let (all, mk) = self.binds()?;
        if list || combo.is_none() {
            println!("Mod = {mk}");
            for b in all.iter().filter(|b| !b.shadowed) {
                println!("{:<28} {}", b.combo, b.action_text);
            }
            return Ok(());
        }
        let combo = combo.unwrap_or_default();
        let b = bind::find(&all, combo, &mk)?;
        let args = bind::action_args(b)?;
        if dry_run || self.global.verbose {
            println!("{} → niri msg action {}", b.combo, args.join(" "));
        }
        if !dry_run {
            if self.target.is_live() && !self.global.live {
                bail!("refusing to run a bind on the live desktop without --live");
            }
            let sock = self
                .target
                .niri_socket
                .clone()
                .context("no niri socket for the target")?;
            if let Some(be) = self.backend.as_mut() {
                be.sync()?;
            }
            bind::run(b, &sock)?;
        }
        Ok(())
    }

    fn info(&mut self, as_json: bool) -> Result<()> {
        let niri = self.niri()?;
        let outputs = niri.outputs()?;
        let ws = niri.workspaces()?;
        let wins = niri.windows()?;
        let layers = niri.layers().unwrap_or_default();
        let b = bounding(&outputs);
        let win_rows: Vec<serde_json::Value> = wins
            .iter()
            .map(|w| {
                let r = window_rect(w, &ws, &outputs);
                json!({
                    "id": w.id, "app_id": w.app_id, "title": w.title, "pid": w.pid,
                    "workspace_id": w.workspace_id, "focused": w.is_focused,
                    "floating": w.is_floating, "rect": r,
                })
            })
            .collect();
        if as_json {
            let v = json!({
                "target": self.target.name.clone().unwrap_or_else(|| "live".into()),
                "wayland_display": self.target.wayland_display,
                "niri_socket": self.target.niri_socket,
                "bounds": b,
                "outputs": outputs,
                "windows": win_rows,
                "layers": layers.iter().map(|l| json!({
                    "namespace": l.namespace, "output": l.output,
                    "layer": format!("{:?}", l.layer),
                    "keyboard": format!("{:?}", l.keyboard_interactivity),
                })).collect::<Vec<_>>(),
                "workspaces": ws.iter().map(|w| json!({
                    "id": w.id, "idx": w.idx, "name": w.name, "output": w.output,
                    "active": w.is_active, "focused": w.is_focused,
                })).collect::<Vec<_>>(),
            });
            println!("{}", serde_json::to_string_pretty(&v)?);
            return Ok(());
        }
        println!(
            "{}  (all coordinates: global logical px; bounds {})",
            self.target.label(),
            b
        );
        println!("outputs:");
        for o in &outputs {
            println!(
                "  {:<8} {}  scale {}  {}",
                o.name, o.rect, o.scale, o.transform
            );
        }
        println!("windows:");
        for (w, row) in wins.iter().zip(&win_rows) {
            let _ = row;
            let (ww, wh) = w.layout.window_size;
            let r = match window_rect(w, &ws, &outputs) {
                Some(r) => format!("{r}  center {:.0},{:.0}", r.center().0, r.center().1),
                None if !w.is_floating => format!(
                    "tiled {ww}x{wh}, column {:?} (niri reports no position for tiled windows)",
                    w.layout.pos_in_scrolling_layout.map(|p| p.0).unwrap_or(0)
                ),
                None => format!("{ww}x{wh} (not on a visible workspace)"),
            };
            println!(
                "  #{:<4} {:<22} {:<30} {}{}{}",
                w.id,
                w.app_id.as_deref().unwrap_or("?"),
                format!("\"{}\"", w.title.as_deref().unwrap_or("")),
                r,
                if w.is_focused { "  focused" } else { "" },
                if w.is_floating { "  floating" } else { "" },
            );
        }
        println!("layer surfaces (niri reports no geometry for these):");
        for l in &layers {
            println!(
                "  {:<28} {:<10} on {}  keyboard {:?}",
                l.namespace,
                format!("{:?}", l.layer),
                l.output,
                l.keyboard_interactivity
            );
        }
        Ok(())
    }

    fn shot(&self, args: &[String]) -> Result<()> {
        let exe = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("studio-shot")))
            .filter(|p| p.exists())
            .unwrap_or_else(|| PathBuf::from("studio-shot"));
        let mut cmd = Command::new(exe);
        match &self.target.name {
            Some(n) => cmd.args(["--session", n]),
            None => cmd.arg("--live"),
        };
        let st = cmd.args(args).status().context("running studio-shot")?;
        if !st.success() {
            bail!("studio-shot failed");
        }
        Ok(())
    }

    /// Release keys still held (virtual keys can't outlive the connection
    /// cleanly), and flush.
    pub fn finish(&mut self) -> Result<()> {
        if self.backend.is_none() {
            return Ok(());
        }
        let held: Vec<(u32, Combo)> = std::mem::take(&mut self.held_keys);
        if !held.is_empty() {
            eprintln!("studio-input: releasing keys still held at the end of the run");
        }
        for (code, c) in held {
            self.be()?.key(code, false)?;
            self.release_mods(&c.mods)?;
        }
        let mods = self.held_mods.clone();
        self.release_mods(&mods)?;
        if self.script && !self.held_buttons.is_empty() {
            eprintln!(
                "studio-input: note: {:?} still pressed (send `up`)",
                self.held_buttons
            );
        }
        self.be()?.sync()
    }
}

/// Run one CLI invocation (a single command or a script).
pub fn main_with(cli: crate::cli::Cli) -> Result<()> {
    let g = cli.global.clone();
    let (cmds, script): (Vec<Cmd>, bool) = match &cli.cmd {
        Cmd::Script { file } => {
            let text = match file {
                Some(p) if p.as_os_str() != "-" => std::fs::read_to_string(p)
                    .with_context(|| format!("reading {}", p.display()))?,
                _ => std::io::read_to_string(std::io::stdin())?,
            };
            (
                crate::cli::parse_script(&text)?
                    .into_iter()
                    .map(|(_, c)| c)
                    .collect(),
                true,
            )
        }
        c => (vec![c.clone()], false),
    };
    let target = session::resolve(g.session.as_deref(), g.live, session::Fallback::RefuseLive)?;
    let mut ex = Exec::new(target, g, script);
    ex.prepare(&cmds)?;
    for c in &cmds {
        ex.run(c)?;
    }
    ex.finish()
}
