//! loft-input's command line — also the grammar of `script` lines, which
//! are parsed with the same definitions (one command per line).

use std::path::PathBuf;

use anyhow::{Result, bail};
use clap::{Args, Parser, Subcommand, ValueEnum};

pub const AFTER_HELP: &str = "\
Coordinates are global logical pixels of the target niri (what `loft-input info`
and `loft-shot --grid` show); --output NAME makes them relative to that output.

Target: --session NAME (a `loft-dev --session NAME` test session), else
$LOFT_SESSION, else the session this runs inside. The live desktop only with --live.

niri keybinds do not fire for virtual-keyboard keys (the compositor hands them
straight to the focused app) — use `bind COMBO` to run a bind's action instead.

Examples:
  loft-input --session t1 bind mod+space           # Spotlight
  loft-input --session t1 spawn foot
  loft-input --session t1 type kitty
  loft-input --session t1 key Return
  loft-input --session t1 click 1210 14            # a bar icon
  loft-input --session t1 drag 900 400 1100 400 --duration 400
  loft-input --session t1 scroll down 3 --at 800 500
  printf 'bind mod+space\\nwait 400\\ntype foot\\nkey Return\\n' | loft-input --session t1 script";

#[derive(Debug, Parser)]
#[command(
    name = "loft-input",
    version,
    about = "Drive a niri session with a virtual mouse and keyboard",
    after_help = AFTER_HELP,
    allow_negative_numbers = true
)]
pub struct Cli {
    #[command(flatten)]
    pub global: Global,
    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(Debug, Clone, Args)]
pub struct Global {
    /// A loft-dev test session (`loft-dev --session NAME`).
    #[arg(long, short = 's', global = true)]
    pub session: Option<String>,
    /// Drive the desktop this runs in ($WAYLAND_DISPLAY). Only when asked to.
    #[arg(long, global = true)]
    pub live: bool,
    /// Use kernel uinput devices instead of the Wayland protocols: real
    /// keyboard + pointer for the whole live seat (niri binds fire). Needs
    /// --live --yes-live; never reaches nested sessions.
    #[arg(long, global = true)]
    pub uinput: bool,
    /// Confirm --uinput: you accept that events go to whatever has focus on
    /// the live desktop.
    #[arg(long, global = true)]
    pub yes_live: bool,
    /// Milliseconds between key/button events.
    #[arg(long, global = true, default_value_t = 8, value_name = "MS")]
    pub key_delay: u64,
    /// Print each step.
    #[arg(long, short = 'v', global = true)]
    pub verbose: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Button {
    Left,
    Right,
    Middle,
    Back,
    Forward,
}

impl Button {
    /// Linux BTN_* code.
    pub fn code(self) -> u32 {
        match self {
            Button::Left => 0x110,
            Button::Right => 0x111,
            Button::Middle => 0x112,
            Button::Back => 0x113,
            Button::Forward => 0x114,
        }
    }

    pub fn parse(s: &str) -> Option<Button> {
        <Button as ValueEnum>::from_str(s, true).ok()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ScrollDir {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Debug, Clone, Subcommand)]
pub enum Cmd {
    /// Move the pointer to X Y.
    #[command(allow_negative_numbers = true)]
    Move {
        x: f64,
        y: f64,
        /// X Y are relative to this output's top-left.
        #[arg(long)]
        output: Option<String>,
        /// Move by X Y (relative motion) instead.
        #[arg(long)]
        rel: bool,
    },
    /// Click: `click [BUTTON] [X Y]` (default left, at the current position).
    #[command(allow_negative_numbers = true)]
    Click {
        #[arg(value_name = "[BUTTON] [X Y]", num_args = 0..=3)]
        args: Vec<String>,
        #[arg(long)]
        double: bool,
        #[arg(long)]
        output: Option<String>,
        /// Milliseconds between press and release.
        #[arg(long, default_value_t = 40, value_name = "MS")]
        hold: u64,
    },
    /// Press a button and keep it pressed: `down [BUTTON] [X Y]`.
    #[command(allow_negative_numbers = true)]
    Down {
        #[arg(value_name = "[BUTTON] [X Y]", num_args = 0..=3)]
        args: Vec<String>,
        #[arg(long)]
        output: Option<String>,
    },
    /// Release a button: `up [BUTTON] [X Y]`.
    #[command(allow_negative_numbers = true)]
    Up {
        #[arg(value_name = "[BUTTON] [X Y]", num_args = 0..=3)]
        args: Vec<String>,
        #[arg(long)]
        output: Option<String>,
    },
    /// Press at X1 Y1, move to X2 Y2 in steps, release.
    #[command(allow_negative_numbers = true)]
    Drag {
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        #[arg(long, default_value_t = 24)]
        steps: u32,
        /// Total time of the movement.
        #[arg(long, default_value_t = 300, value_name = "MS")]
        duration: u64,
        #[arg(long, value_enum, default_value_t = Button::Left)]
        button: Button,
        /// Pause after pressing and before releasing.
        #[arg(long, default_value_t = 80, value_name = "MS")]
        hold: u64,
        #[arg(long)]
        output: Option<String>,
    },
    /// Scroll: wheel notches (default), or smooth pixels with --smooth.
    #[command(allow_negative_numbers = true)]
    Scroll {
        #[arg(value_enum)]
        dir: ScrollDir,
        /// Notches (or pixels with --smooth).
        #[arg(default_value_t = 1.0)]
        amount: f64,
        /// Touchpad-style continuous scrolling, AMOUNT in pixels.
        #[arg(long)]
        smooth: bool,
        /// Move here first.
        #[arg(long, num_args = 2, value_names = ["X", "Y"])]
        at: Option<Vec<f64>>,
        #[arg(long)]
        output: Option<String>,
    },
    /// Type text (unicode is fine; \n is Return, \t is Tab).
    Type {
        #[arg(required = true, num_args = 1.., allow_hyphen_values = true)]
        text: Vec<String>,
    },
    /// Press key combos in order: `key ctrl+shift+t`, `key Escape Return`.
    Key {
        #[arg(required = true, num_args = 1..)]
        combos: Vec<String>,
    },
    /// Press a key (with its modifiers) and keep it held (until `keyup` or
    /// the end of the run — virtual keys can't stay held across runs).
    Keydown { combo: String },
    /// Release a key held with `keydown`.
    Keyup { combo: String },
    /// Pause.
    Wait {
        #[arg(value_name = "MS")]
        ms: u64,
    },
    /// Run the niri keybind for COMBO (niri ignores virtual-keyboard keys).
    Bind {
        combo: Option<String>,
        /// List the session's binds instead.
        #[arg(long)]
        list: bool,
        /// Print the action without running it.
        #[arg(long)]
        dry_run: bool,
    },
    /// Start a program inside the session (niri spawns it, with the
    /// session's environment).
    Spawn {
        #[arg(required = true, num_args = 1.., allow_hyphen_values = true, trailing_var_arg = true)]
        command: Vec<String>,
    },
    /// Outputs, windows (global geometry), layer surfaces of the target.
    Info {
        #[arg(long)]
        json: bool,
    },
    /// Run commands from FILE (or stdin), one per line, on one connection.
    Script { file: Option<PathBuf> },
    /// Take a screenshot of the same target (arguments go to loft-shot).
    Shot {
        #[arg(num_args = 0.., allow_hyphen_values = true, trailing_var_arg = true)]
        args: Vec<String>,
    },
}

/// `[BUTTON] [X Y]`.
pub fn button_args(args: &[String]) -> Result<(Button, Option<(f64, f64)>)> {
    let (button, rest) = match args.first().and_then(|a| Button::parse(a)) {
        Some(b) => (b, &args[1..]),
        None => (Button::Left, args),
    };
    let nums: Vec<f64> = rest
        .iter()
        .map(|a| a.parse::<f64>())
        .collect::<std::result::Result<_, _>>()
        .map_err(|_| anyhow::anyhow!("expected [BUTTON] [X Y], got `{}`", args.join(" ")))?;
    match nums[..] {
        [] => Ok((button, None)),
        [x, y] => Ok((button, Some((x, y)))),
        _ => bail!("expected [BUTTON] [X Y], got `{}`", args.join(" ")),
    }
}

/// Split a script line like a shell would: quotes, backslash escapes, `#`
/// comments.
pub fn split_line(line: &str) -> Result<Vec<String>> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut has = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '#' if !has => break,
            c if c.is_whitespace() => {
                if has {
                    out.push(std::mem::take(&mut cur));
                    has = false;
                }
            }
            '\'' => {
                has = true;
                loop {
                    match chars.next() {
                        Some('\'') => break,
                        Some(c) => cur.push(c),
                        None => bail!("unclosed ' in `{line}`"),
                    }
                }
            }
            '"' => {
                has = true;
                loop {
                    match chars.next() {
                        Some('"') => break,
                        Some('\\') => match chars.next() {
                            Some('n') => cur.push('\n'),
                            Some('t') => cur.push('\t'),
                            Some(c) => cur.push(c),
                            None => bail!("dangling \\ in `{line}`"),
                        },
                        Some(c) => cur.push(c),
                        None => bail!("unclosed \" in `{line}`"),
                    }
                }
            }
            '\\' => {
                has = true;
                if let Some(c) = chars.next() {
                    cur.push(c);
                }
            }
            c => {
                has = true;
                cur.push(c);
            }
        }
    }
    if has {
        out.push(cur);
    }
    Ok(out)
}

/// Parse a script into commands (target flags belong on the `script` call).
pub fn parse_script(text: &str) -> Result<Vec<(usize, Cmd)>> {
    let mut cmds = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let words = split_line(line)?;
        if words.is_empty() {
            continue;
        }
        let cli = Cli::try_parse_from(std::iter::once("loft-input".to_string()).chain(words))
            .map_err(|e| anyhow::anyhow!("line {}: {}", i + 1, e.render().to_string().trim()))?;
        if cli.global.live
            || cli.global.uinput
            || cli.global.yes_live
            || cli.global.session.is_some()
        {
            bail!(
                "line {}: put --live/--uinput/--session on the `script` command, not on lines",
                i + 1
            );
        }
        if matches!(cli.cmd, Cmd::Script { .. }) {
            bail!("line {}: scripts can't nest", i + 1);
        }
        cmds.push((i + 1, cli.cmd));
    }
    Ok(cmds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_lines() {
        assert_eq!(
            split_line(r#"type "hello world" 'a b' c\ d # comment"#).unwrap(),
            ["type", "hello world", "a b", "c d"]
        );
        assert_eq!(split_line(r#"type "a\nb""#).unwrap(), ["type", "a\nb"]);
        assert!(split_line("  # just a comment").unwrap().is_empty());
        assert_eq!(split_line("key 'ctrl+#'").unwrap(), ["key", "ctrl+#"]);
        assert!(split_line("type \"open").is_err());
    }

    #[test]
    fn parses_scripts() {
        let s = "\
# open Spotlight and launch kitty
bind mod+space
wait 400
type kitty
key Return
click right 100 -20
drag 10 10 300 40 --steps 5
scroll down 3 --at 800 500
shot --grid --out /tmp/x.png
";
        let cmds = parse_script(s).unwrap();
        assert_eq!(cmds.len(), 8);
        assert!(matches!(&cmds[0].1, Cmd::Bind { combo: Some(c), .. } if c == "mod+space"));
        assert!(matches!(cmds[1].1, Cmd::Wait { ms: 400 }));
        match &cmds[4].1 {
            Cmd::Click { args, .. } => {
                assert_eq!(
                    button_args(args).unwrap(),
                    (Button::Right, Some((100.0, -20.0)))
                )
            }
            c => panic!("{c:?}"),
        }
        assert!(matches!(&cmds[5].1, Cmd::Drag { steps: 5, .. }));
        assert!(
            matches!(&cmds[6].1, Cmd::Scroll { dir: ScrollDir::Down, amount, at: Some(at), .. } if *amount == 3.0 && at == &[800.0, 500.0])
        );
        assert!(matches!(&cmds[7].1, Cmd::Shot { args } if args[0] == "--grid"));
        assert!(parse_script("frobnicate").is_err());
        assert!(parse_script("click --live").is_err());
        assert!(parse_script("script x").is_err());
    }

    #[test]
    fn button_arguments() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(button_args(&s(&[])).unwrap(), (Button::Left, None));
        assert_eq!(
            button_args(&s(&["middle"])).unwrap(),
            (Button::Middle, None)
        );
        assert_eq!(
            button_args(&s(&["5", "6"])).unwrap(),
            (Button::Left, Some((5.0, 6.0)))
        );
        assert!(button_args(&s(&["left", "5"])).is_err());
        assert!(button_args(&s(&["nope", "5", "6"])).is_err());
    }
}
