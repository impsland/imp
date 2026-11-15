//! `imp qr`: a pairing code in the terminal. With no text it makes an invite (`implink://join...`) from the
//! core, shows it as a QR code and stays running as a linked device, so a phone or a Mac that scans the code
//! can join. With text it draws that text instead, for example a kit address to open on a phone.
//!
//! `imp link` is the same device without a code: it stays online for the devices linked already.

use crate::link::SeedStore;
use crate::link::device::{Device, DeviceOptions, Update, reach_note};
use crate::{CliError, Result};
use qrcode::{Color, QrCode};
use std::io::Write;
use std::sync::Arc;

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

/// The rows of the code in half blocks, without colours, for a screen that sets them itself (black on white).
pub fn rows(text: &str) -> Result<Vec<String>> {
    let drawn = render(text)?;
    Ok(drawn
        .lines()
        .map(|l| {
            l.trim_start_matches(COLORS)
                .trim_end_matches(RESET)
                .to_string()
        })
        .collect())
}

/// Shows an invite as a QR code, then stays online as this computer until `stop` completes: devices that
/// scan it link, Imps sent here visit, and Imps of this computer that are away think here.
pub async fn pair(
    options: &DeviceOptions,
    seeds: Arc<dyn SeedStore>,
    out: &mut dyn Write,
    err: &mut dyn Write,
    stop: impl std::future::Future<Output = ()>,
) -> Result<()> {
    let device = Device::start(options, seeds)
        .await
        .map_err(|e| CliError(e.to_string()))?;
    let invite = device.invite().await?;
    write!(out, "{}", render(&invite.url())?)?;
    writeln!(out)?;
    writeln!(
        err,
        "Scan this code with Imp on a Mac or an iPhone. It works for 15 minutes after it was last on screen."
    )?;
    writeln!(err, "{}", reach_note(&invite.routes))?;
    stay_online(device, err, stop, true).await
}

/// Keeps this computer online as a device and tells what happens, until `stop` completes.
pub async fn stay_online(
    mut device: Device,
    err: &mut dyn Write,
    stop: impl std::future::Future<Output = ()>,
    code_shown: bool,
) -> Result<()> {
    writeln!(err, "Press Ctrl-C to stop.")?;
    tokio::pin!(stop);
    loop {
        tokio::select! {
            () = &mut stop => break,
            update = device.next() => {
                if let Some(text) = describe(&update) {
                    writeln!(err, "{text}")?;
                }
            }
        }
    }
    if code_shown {
        device.invite_hidden().await;
    }
    device.stop().await;
    Ok(())
}

/// A line about something that happened on the link, for a terminal with no chat.
fn describe(update: &Update) -> Option<String> {
    Some(match update {
        Update::Note(text) | Update::Problem(text) => text.clone(),
        Update::Away { imp, device } => {
            format!("{imp} is on {device} now. It thinks here while this keeps running.")
        }
        Update::CameHome { imp, .. } => format!("{imp} is back on this computer."),
        Update::Asked { line, .. } => line.clone(),
        Update::Visitor(_) | Update::Left(_) | Update::Arrived(_) => return None,
    })
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
