//! `imp qr`: a pairing code in the terminal. With no text it makes an invite (`implink://join...`) from the
//! core, shows it as a QR code and stays running as a linked device, so a phone or a Mac that scans the code
//! can join. With text it draws that text instead, for example a kit address to open on a phone.

use crate::link::{BookFile, Runner, SeedStore, local_address, new_device_id};
use crate::{CliError, Result};
use imp_core::link::PORT;
use imp_core::link::card::LinkKind;
use imp_core::link::hop::HopAddress;
use imp_core::link::node::{Event, JoinError, Node, Options, Problem};
use qrcode::{Color, QrCode};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

/// What `imp qr` with no text needs to know.
#[derive(Debug, Clone, Default)]
pub struct PairOptions {
    /// The name other devices see. The computer's name if left out.
    pub name: Option<String>,
    /// Host names or addresses to put in the code. The address on the local network if left out.
    pub hosts: Vec<String>,
    /// The Imp server to wait at, as `host:port`, for devices that are not on the same network.
    pub hop: Option<String>,
    /// Where the device's book is kept.
    pub data_dir: PathBuf,
}

/// Light modules around the code on every side, in modules. The QR standard asks for four.
pub const QUIET_ZONE: usize = 4;

/// The code is always drawn dark on light with its own colours, whatever the terminal's background is,
/// because a scanner needs the contrast. The same escape sets both for every row.
const COLORS: &str = "\x1b[38;2;0;0;0;48;2;255;255;255m";
const RESET: &str = "\x1b[0m";

/// Draws `text` as a QR code in Unicode half blocks: each character holds two modules, one above the
/// other, so the modules come out square. Dark modules are black, the modules and the quiet zone
/// around them are white.
pub fn render(text: &str) -> Result<String> {
    if text.is_empty() {
        return Err(CliError("There is nothing to draw.".into()));
    }
    let code = QrCode::new(text.as_bytes())
        .map_err(|_| CliError("That text is too long for a QR code.".into()))?;
    let side = code.width();
    let colors = code.to_colors();
    let size = side + 2 * QUIET_ZONE;
    let dark = |x: usize, y: usize| {
        let inside = |v: usize| (QUIET_ZONE..QUIET_ZONE + side).contains(&v);
        inside(x) && inside(y) && colors[(y - QUIET_ZONE) * side + (x - QUIET_ZONE)] == Color::Dark
    };
    let mut out = String::new();
    for y in (0..size).step_by(2) {
        out.push_str(COLORS);
        for x in 0..size {
            out.push(match (dark(x, y), dark(x, y + 1)) {
                (true, true) => '\u{2588}',
                (true, false) => '\u{2580}',
                (false, true) => '\u{2584}',
                (false, false) => ' ',
            });
        }
        out.push_str(RESET);
        out.push('\n');
    }
    Ok(out)
}

/// The node for this computer: its book from the data folder (made the first time), its name and where to
/// reach it.
pub fn make_node(options: &PairOptions, seeds: Arc<dyn SeedStore>) -> Result<(Node, BookFile)> {
    let book = BookFile::in_dir(&options.data_dir, seeds);
    let saved = book.load()?;
    let name = options
        .name
        .clone()
        .or_else(computer_name)
        .unwrap_or_else(|| "Imp CLI".into());
    let mut node = Node::new(
        saved.as_deref(),
        &name,
        LinkKind::Mac,
        new_device_id(),
        Options::default(),
    )
    .map_err(|_| {
        CliError(format!(
            "The link book in {} cannot be read. Remove the file to start again.",
            book.path().display()
        ))
    })?;
    let hosts = if options.hosts.is_empty() {
        local_address().into_iter().collect()
    } else {
        options.hosts.clone()
    };
    node.set_hosts(hosts);
    if let Some(hop) = &options.hop {
        let address = HopAddress::parse(hop).ok_or_else(|| {
            CliError("The Hop must be written host:port, such as hop.example.org:4677.".into())
        })?;
        node.set_server(Some(address));
    }
    Ok((node, book))
}

fn computer_name() -> Option<String> {
    ["HOSTNAME", "COMPUTERNAME", "HOST"]
        .iter()
        .find_map(|v| std::env::var(v).ok())
        .map(|n| n.split('.').next().unwrap_or_default().to_string())
        .filter(|n| !n.is_empty())
}

/// What a person should read about something the node reported.
fn describe(event: &Event) -> Option<String> {
    Some(match event {
        Event::Linked(device) => format!("Linked with {}.", device.name),
        Event::Connected(device, _) => format!("{} is connected.", device.name),
        Event::Disconnected(_) => "A device disconnected.".into(),
        Event::Problem(Problem::Hop) => {
            "The Hop turned this device away. Check that it is the same server the apps use and that it runs the same release as the apps.".into()
        }
        Event::Problem(Problem::Refused(_)) => {
            "A device answered but would not talk. It may run a different release of Imp. Update both devices.".into()
        }
        Event::Problem(Problem::InviteRefused(_)) => "A device used a code that has expired.".into(),
        Event::Problem(Problem::Listener(why)) => format!("Cannot listen: {why}"),
        Event::Problem(Problem::Storage(why)) => format!("Could not save the link book: {why}"),
        Event::Joined { result: Err(JoinError::Unreachable), .. } => {
            "That device could not be reached.".into()
        }
        _ => return None,
    })
}

/// Shows an invite as a QR code, stays linked and tells what happens, until `stop` completes.
pub async fn pair(
    options: &PairOptions,
    seeds: Arc<dyn SeedStore>,
    out: &mut dyn Write,
    err: &mut dyn Write,
    stop: impl std::future::Future<Output = ()>,
) -> Result<()> {
    let (node, book) = make_node(options, seeds)?;
    let listener = match TcpListener::bind(("0.0.0.0", PORT)).await {
        Ok(listener) => listener,
        Err(_) => TcpListener::bind(("0.0.0.0", 0)).await?,
    };
    let (events, mut heard) = mpsc::unbounded_channel();
    let runner = Runner::start(node, listener, events, move |bytes| {
        book.save(bytes).map_err(|e| e.0)
    })?;
    let invite = runner
        .with(|node, now| node.invite(now))
        .await
        .ok_or_else(|| CliError("The link stopped before it started.".into()))?;
    write!(out, "{}", render(&invite.url())?)?;
    writeln!(out)?;
    writeln!(
        err,
        "Scan this code with Imp on a Mac or an iPhone. It works for 15 minutes after it was last on screen.\nPress Ctrl-C to stop."
    )?;
    tokio::pin!(stop);
    loop {
        tokio::select! {
            () = &mut stop => break,
            event = heard.recv() => {
                let Some(event) = event else { break };
                if let Some(text) = describe(&event) {
                    writeln!(err, "{text}")?;
                }
            }
        }
    }
    runner.with(|node, now| node.invite_hidden(now)).await;
    runner.stop().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAYLOAD: &str = "https://example.org/kit.json";

    /// Reads the module matrix back from the drawn text: one string of `#` and `.` per module row.
    fn read_back(drawn: &str) -> Vec<Vec<bool>> {
        let mut rows = Vec::new();
        for line in drawn.lines() {
            let text = line
                .strip_prefix(COLORS)
                .and_then(|l| l.strip_suffix(RESET))
                .expect("explicit colours on every row");
            let (mut top, mut bottom) = (Vec::new(), Vec::new());
            for c in text.chars() {
                let (t, b) = match c {
                    '\u{2588}' => (true, true),
                    '\u{2580}' => (true, false),
                    '\u{2584}' => (false, true),
                    ' ' => (false, false),
                    other => panic!("unexpected {other:?}"),
                };
                top.push(t);
                bottom.push(b);
            }
            rows.push(top);
            rows.push(bottom);
        }
        rows
    }

    #[test]
    fn the_drawn_modules_are_the_codes_modules_inside_a_quiet_zone() {
        let code = QrCode::new(PAYLOAD.as_bytes()).unwrap();
        let side = code.width();
        let colors = code.to_colors();
        let rows = read_back(&render(PAYLOAD).unwrap());
        let size = side + 2 * QUIET_ZONE;
        const { assert!(QUIET_ZONE >= 4) };
        assert_eq!(rows.len(), size + size % 2, "two modules per character row");
        for (y, row) in rows.iter().enumerate() {
            assert_eq!(
                row.len(),
                size,
                "a square aspect: as many columns as module columns"
            );
            for (x, drawn) in row.iter().enumerate() {
                let inside = |v: usize| (QUIET_ZONE..QUIET_ZONE + side).contains(&v);
                let expected = inside(x)
                    && inside(y)
                    && colors[(y - QUIET_ZONE) * side + x - QUIET_ZONE] == Color::Dark;
                assert_eq!(*drawn, expected, "module {x},{y}");
            }
        }
        for y in 0..QUIET_ZONE {
            assert!(rows[y].iter().all(|d| !d) && rows[rows.len() - 1 - y].iter().all(|d| !d));
        }
        assert!(rows.iter().all(|r| {
            r[..QUIET_ZONE]
                .iter()
                .chain(&r[size - QUIET_ZONE..])
                .all(|d| !d)
        }));
    }

    #[test]
    fn the_colours_are_explicit_and_not_the_terminals() {
        let drawn = render(PAYLOAD).unwrap();
        assert!(
            drawn
                .lines()
                .all(|l| l.starts_with("\x1b[38;2;0;0;0;48;2;255;255;255m")
                    && l.ends_with("\x1b[0m"))
        );
        assert!(drawn.contains('\u{2580}') && drawn.contains('\u{2584}'));
    }

    #[test]
    fn refuses_empty_and_huge_text() {
        assert!(render("").is_err());
        assert!(render(&"x".repeat(5000)).is_err());
    }
}
