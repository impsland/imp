//! `imp serve`: The Hop on this computer.

use super::Io;
use crate::Result;
use crate::serve::ServeOptions;

pub async fn run(options: &ServeOptions, io: &mut Io<'_>) -> Result<()> {
    let bound = crate::serve::bind(options).await?;
    writeln!(io.err, "The Hop is listening on {}", bound.hop_addr)?;
    writeln!(io.err, "  It keeps no data.")?;
    writeln!(
        io.err,
        "\nTo use it, open the Imp settings on a Mac or the Imp app on an iPhone and set the Hop address:"
    )?;
    writeln!(
        io.err,
        "  Hop     {}",
        hop_name(options, bound.hop_addr.port())
    )?;
    if options.host.is_loopback() {
        writeln!(
            io.err,
            "Only this computer can reach it. Use --host 0.0.0.0 to let devices on your network in."
        )?;
    }
    writeln!(io.err, "Press Ctrl-C to stop.")?;
    bound
        .run(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    writeln!(io.err, "Stopped.")?;
    Ok(())
}

fn hop_name(options: &ServeOptions, port: u16) -> String {
    let name = match options.host {
        std::net::IpAddr::V4(a) if a.is_loopback() || a.is_unspecified() => "localhost".to_owned(),
        std::net::IpAddr::V4(a) => a.to_string(),
        std::net::IpAddr::V6(a) => format!("[{a}]"),
    };
    format!("{name}:{port}")
}
