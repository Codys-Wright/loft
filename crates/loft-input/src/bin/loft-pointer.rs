use clap::Parser;

fn main() {
    // Exit (and so stop scrolling) when whoever reads our events is gone.
    // SAFETY: setting a signal disposition at startup, before any threads.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
    let cli = loft_input::autoscroll::Cli::parse();
    if let Err(e) = loft_input::autoscroll::main_with(cli) {
        eprintln!("loft-pointer: {e:#}");
        std::process::exit(1);
    }
}
