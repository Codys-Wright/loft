use clap::Parser;

fn main() {
    // Exit quietly when piped into `head`.
    // SAFETY: setting a signal disposition at startup, before any threads.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
    let cli = loft_input::cli::Cli::parse();
    if let Err(e) = loft_input::exec::main_with(cli) {
        eprintln!("loft-input: {e:#}");
        std::process::exit(1);
    }
}
