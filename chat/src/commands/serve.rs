//! `imp serve`: The Den and The Hop on this computer.

use super::Io;
use crate::Result;
use crate::serve::{Bound, ServeOptions};

pub async fn run(options: &ServeOptions, io: &mut Io<'_>) -> Result<()> {
    let bound = crate::serve::bind(options).await?;
    if let (Some(addr), Some(url)) = (bound.den_addr, &bound.public_url) {
        writeln!(io.err, "The Den is listening on {addr}")?;
        writeln!(
            io.err,
            "  Its data is kept in {}. The secret stays in the file den-secret there.",
            options.data_dir.display()
        )?;
        writeln!(io.err, "  Its public address is {url}")?;
    }
    if let Some(addr) = bound.hop_addr {
        writeln!(io.err, "The Hop is listening on {addr}")?;
        writeln!(io.err, "  It keeps no data and does not need The Den.")?;
    }
    writeln!(
        io.err,
        "\nTo use it, open the Imp settings on a Mac or the Imp app on an iPhone and set:"
    )?;
    if let Some(url) = &bound.public_url {
        writeln!(io.err, "  Server  {url}")?;
    }
    if bound.hop_addr.is_some() {
        writeln!(io.err, "  Hop     {}", hop_name(options, &bound))?;
    }
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

fn hop_name(options: &ServeOptions, bound: &Bound) -> String {
    let name = match options.host {
        std::net::IpAddr::V4(a) if a.is_loopback() || a.is_unspecified() => "localhost".to_owned(),
        std::net::IpAddr::V4(a) => a.to_string(),
        std::net::IpAddr::V6(a) => format!("[{a}]"),
    };
    let port = bound.hop_addr.map_or(0, |a| a.port());
    format!("{name}:{port}")
}
