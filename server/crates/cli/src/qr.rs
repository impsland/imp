//! `imp qr`: QR codes in the terminal.
//!
//! What a code can do today is narrow on purpose. The apps' scanners accept only a device link
//! invite (`implink://join…`) and the `imp://` commands do not include a server setting. A device
//! link invite is no use until this program can answer as a linked device, which needs the TLS
//! identity and session layer. So `imp qr` with no text explains that, and `imp qr TEXT` draws
//! any text you give it, for example a kit address to open on a phone.

use crate::{CliError, Result};
use qrcode::QrCode;
use qrcode::render::unicode::Dense1x2;

/// Why there is no pairing code yet. Shown when `imp qr` gets no text.
pub const NOT_YET: &str = "There is no code to show yet. The Imp apps scan only a device link invite, and this program cannot answer as a linked device until it has the secure link layer the apps use. Nothing can be pointed at `imp serve` by a code today. Type the addresses that `imp serve` prints into the apps instead. You can still draw any text with `imp qr TEXT`.";

/// Draws `text` as a QR code in Unicode half blocks. Light on dark unless `light_terminal` is set.
pub fn render(text: &str, light_terminal: bool) -> Result<String> {
    if text.is_empty() {
        return Err(CliError("There is nothing to draw.".into()));
    }
    let code = QrCode::new(text.as_bytes())
        .map_err(|_| CliError("That text is too long for a QR code.".into()))?;
    let (dark, light) = if light_terminal {
        (Dense1x2::Dark, Dense1x2::Light)
    } else {
        (Dense1x2::Light, Dense1x2::Dark)
    };
    Ok(code
        .render::<Dense1x2>()
        .dark_color(dark)
        .light_color(light)
        .quiet_zone(true)
        .build())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_blocks_and_flips_for_light_terminals() {
        let dark = render("https://example.org/kit.json", false).unwrap();
        let light = render("https://example.org/kit.json", true).unwrap();
        assert!(dark.lines().count() > 10);
        assert!(dark.contains('█') || dark.contains('▀') || dark.contains('▄'));
        assert_ne!(dark, light);
        assert_eq!(dark.lines().count(), light.lines().count());
    }

    #[test]
    fn refuses_empty_and_huge_text() {
        assert!(render("", false).is_err());
        assert!(render(&"x".repeat(5000), false).is_err());
    }
}
