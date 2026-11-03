use clap::Parser;
use imp_cli::cli::Cli;
use imp_cli::commands::{Io, run};
use std::io::{stderr, stdin, stdout};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
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
