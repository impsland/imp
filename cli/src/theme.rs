//! The terminal's look. The terminal's own background is the one surface, so the palette's colours are
//! used only where they sit on a fill (a soft fill for the message field, a raised card for help) and
//! for the Imp's colour and the status colours. Everything else is the default foreground, or dim.
//! With `NO_COLOR` set there are no colours at all, only bold and dim.

#[path = "theme.generated.rs"]
mod palette;

use palette::{DARK, LIGHT, Palette, Rgba};
use ratatui::style::{Color, Modifier, Style};

#[derive(Debug, Clone, Copy)]
pub struct Theme {
    colors: Option<Palette>,
}

impl Theme {
    /// The theme for this terminal: no colours with `NO_COLOR`, the light palette when `COLORFGBG` says
    /// the background is light.
    pub fn detect() -> Self {
        let no_color = std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty());
        let light = std::env::var("COLORFGBG").is_ok_and(|v| light_background(&v));
        Self::new(no_color, light)
    }

    pub fn new(no_color: bool, light: bool) -> Self {
        let colors = (!no_color).then_some(if light { LIGHT } else { DARK });
        Self { colors }
    }

    pub fn has_color(&self) -> bool {
        self.colors.is_some()
    }

    /// Plain text: the terminal's own foreground.
    pub fn text(&self) -> Style {
        Style::default()
    }

    /// Hints, the status line, tool results.
    pub fn muted(&self) -> Style {
        Style::default().add_modifier(Modifier::DIM)
    }

    /// The Imp's own colour: its mark and nothing else.
    pub fn imp(&self) -> Style {
        match &self.colors {
            Some(p) => Style::default().fg(color(p.echo_accent)),
            None => Style::default().add_modifier(Modifier::BOLD),
        }
    }

    /// The mark of another Imp, in its own colour (a hue from 0 to 1, as the apps keep it).
    pub fn hue(&self, hue: f64) -> Style {
        match &self.colors {
            Some(_) => {
                let (r, g, b) = hsv(hue, 0.55, 0.95);
                Style::default().fg(Color::Rgb(r, g, b))
            }
            None => Style::default().add_modifier(Modifier::BOLD),
        }
    }

    /// A QR code: black on white whatever the terminal's colours are, so a camera can read it.
    pub fn code(&self) -> Style {
        Style::default()
            .fg(Color::Rgb(0, 0, 0))
            .bg(Color::Rgb(255, 255, 255))
    }

    /// Problems.
    pub fn danger(&self) -> Style {
        match &self.colors {
            Some(p) => Style::default().fg(color(p.danger)),
            None => Style::default().add_modifier(Modifier::BOLD),
        }
    }

    /// A soft fill that sets a group apart from the surface, such as the message field.
    pub fn card(&self) -> Style {
        match &self.colors {
            Some(p) => Style::default().bg(color(over(p.card, p.surface))),
            None => Style::default(),
        }
    }

    /// The fill of something that floats for a moment, such as the help card.
    pub fn raised(&self) -> Style {
        match &self.colors {
            Some(p) => Style::default().bg(color(p.raised)),
            None => Style::default(),
        }
    }
}

/// A colour from hue, saturation and value, each from 0 to 1.
fn hsv(h: f64, s: f64, v: f64) -> (u8, u8, u8) {
    let h = h.rem_euclid(1.0) * 6.0;
    let sector = h.floor();
    let f = h - sector;
    let (p, q, t) = (v * (1.0 - s), v * (1.0 - s * f), v * (1.0 - s * (1.0 - f)));
    let (r, g, b) = match sector as u8 {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    };
    let byte = |x: f64| (x * 255.0).round().clamp(0.0, 255.0) as u8;
    (byte(r), byte(g), byte(b))
}

fn color(c: Rgba) -> Color {
    Color::Rgb(c.r, c.g, c.b)
}

/// `top` laid over `under`.
fn over(top: Rgba, under: Rgba) -> Rgba {
    let mix = |t: u8, u: u8| {
        let a = u32::from(top.a);
        ((u32::from(t) * a + u32::from(u) * (255 - a)) / 255) as u8
    };
    Rgba::new(
        mix(top.r, under.r),
        mix(top.g, under.g),
        mix(top.b, under.b),
        255,
    )
}

/// `COLORFGBG` is `foreground;background` in ANSI colour numbers. The numbers 7 and 15 are the light ones.
fn light_background(value: &str) -> bool {
    value
        .rsplit(';')
        .next()
        .and_then(|bg| bg.parse::<u8>().ok())
        .is_some_and(|bg| bg == 7 || bg == 15)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_color_means_no_colors_at_all() {
        let t = Theme::new(true, false);
        assert!(!t.has_color());
        for style in [
            t.text(),
            t.muted(),
            t.imp(),
            t.danger(),
            t.card(),
            t.raised(),
        ] {
            assert_eq!((style.fg, style.bg), (None, None));
        }
    }

    #[test]
    fn colours_come_from_the_generated_palette() {
        let t = Theme::new(false, false);
        let e = DARK.echo_accent;
        assert_eq!(t.imp().fg, Some(Color::Rgb(e.r, e.g, e.b)));
        assert!(t.card().bg.is_some());
        assert_ne!(Theme::new(false, true).raised().bg, t.raised().bg);
    }

    #[test]
    fn the_background_hint_is_read() {
        assert!(light_background("0;15"));
        assert!(light_background("0;default;7"));
        assert!(!light_background("15;0"));
        assert!(!light_background("nonsense"));
    }
}
