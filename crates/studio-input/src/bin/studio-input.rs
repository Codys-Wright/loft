use clap::Parser;

fn main() {
    // Exit quietly when piped into `head`.
    // SAFETY: setting a signal disposition at startup, before any threads.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
    let cli = studio_input::cli::Cli::parse();
    if let Err(e) = studio_input::exec::main_with(cli) {
        eprintln!("studio-input: {e:#}");
        std::process::exit(1);
    }
}
