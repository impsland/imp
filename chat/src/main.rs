use clap::Parser;
use imp_chat::cli::Cli;
use imp_chat::commands::{Io, run};
use std::io::{stderr, stdin, stdout};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    // On a Mac, out of the folder it shared with the Mac app (see `imp_chat::folders`).
    imp_chat::folders::settle_here();
    let (stdin, mut out, mut err) = (stdin(), stdout().lock(), stderr().lock());
    let mut input = stdin.lock();
    let mut io = Io {
        input: &mut input,
        out: &mut out,
        err: &mut err,
    };
    match run(cli, &mut io).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            let _ = writeln!(io.err, "imp: {e}");
            ExitCode::FAILURE
        }
    }
}
