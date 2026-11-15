// generated from design/tokens.json, do not edit. Run: node design/generate.mjs
// The terminal draws on its own background, so only the colours that sit on a fill are used as they are.
#![allow(dead_code)]

/// A colour with an alpha channel (0 to 255).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Rgba {
    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }
}

/// The colours of one appearance.
#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub surface: Rgba,
    pub raised: Rgba,
    pub raised_high: Rgba,
    pub deep: Rgba,
    pub doorway: Rgba,
    pub ink: Rgba,
    pub paper: Rgba,
    pub text: Rgba,
    pub muted: Rgba,
    pub faint: Rgba,
    pub card: Rgba,
    pub card_hover: Rgba,
    pub line: Rgba,
    pub well: Rgba,
    pub accent: Rgba,
    pub accent_bright: Rgba,
    pub on_accent: Rgba,
    pub heart: Rgba,
    pub link: Rgba,
    pub warn_background: Rgba,
    pub warn_text: Rgba,
    pub warn_edge: Rgba,
    pub error_background: Rgba,
    pub error_edge: Rgba,
    pub danger: Rgba,
    pub ok_background: Rgba,
    pub ok_edge: Rgba,
    pub focus: Rgba,
    pub good: Rgba,
    pub off: Rgba,
    pub scrim: Rgba,
    pub veil: Rgba,
    pub spark_ember: Rgba,
    pub spark_wisp: Rgba,
    pub spark_hot: Rgba,
    pub spark_smoke_edge: Rgba,
    pub spark_smoke_core: Rgba,
    pub spark_gold: Rgba,
    pub spark_gold_core: Rgba,
    pub spark_chain: Rgba,
    pub spark_chain_core: Rgba,
    pub spark_kindle_core: Rgba,
    pub echo_accent: Rgba,
}

pub const DARK: Palette = Palette {
    surface: Rgba::new(20, 21, 25, 255),
    raised: Rgba::new(30, 32, 38, 255),
    raised_high: Rgba::new(40, 42, 50, 255),
    deep: Rgba::new(13, 14, 17, 255),
    doorway: Rgba::new(7, 8, 9, 255),
    ink: Rgba::new(23, 24, 28, 255),
    paper: Rgba::new(242, 240, 234, 255),
    text: Rgba::new(242, 240, 234, 255),
    muted: Rgba::new(242, 240, 234, 179),
    faint: Rgba::new(242, 240, 234, 115),
    card: Rgba::new(255, 255, 255, 15),
    card_hover: Rgba::new(255, 255, 255, 26),
    line: Rgba::new(255, 255, 255, 31),
    well: Rgba::new(0, 0, 0, 71),
    accent: Rgba::new(242, 240, 234, 255),
    accent_bright: Rgba::new(255, 255, 255, 255),
    on_accent: Rgba::new(23, 24, 28, 255),
    heart: Rgba::new(255, 115, 140, 255),
    link: Rgba::new(158, 197, 255, 255),
    warn_background: Rgba::new(255, 180, 71, 36),
    warn_text: Rgba::new(255, 207, 138, 255),
    warn_edge: Rgba::new(255, 180, 71, 115),
    error_background: Rgba::new(255, 80, 80, 36),
    error_edge: Rgba::new(255, 110, 110, 128),
    danger: Rgba::new(255, 122, 112, 255),
    ok_background: Rgba::new(110, 210, 140, 36),
    ok_edge: Rgba::new(110, 210, 140, 115),
    focus: Rgba::new(242, 240, 234, 255),
    good: Rgba::new(111, 220, 140, 255),
    off: Rgba::new(138, 140, 147, 255),
    scrim: Rgba::new(0, 0, 0, 102),
    veil: Rgba::new(20, 21, 25, 204),
    spark_ember: Rgba::new(255, 158, 66, 255),
    spark_wisp: Rgba::new(140, 207, 255, 255),
    spark_hot: Rgba::new(255, 128, 61, 255),
    spark_smoke_edge: Rgba::new(153, 138, 189, 255),
    spark_smoke_core: Rgba::new(23, 15, 36, 255),
    spark_gold: Rgba::new(255, 214, 77, 255),
    spark_gold_core: Rgba::new(255, 247, 204, 255),
    spark_chain: Rgba::new(255, 115, 158, 255),
    spark_chain_core: Rgba::new(255, 237, 217, 255),
    spark_kindle_core: Rgba::new(204, 255, 209, 255),
    echo_accent: Rgba::new(184, 153, 255, 255),
};

pub const LIGHT: Palette = Palette {
    surface: Rgba::new(243, 241, 236, 255),
    raised: Rgba::new(255, 255, 255, 255),
    raised_high: Rgba::new(243, 241, 236, 255),
    deep: Rgba::new(230, 227, 220, 255),
    doorway: Rgba::new(42, 44, 51, 255),
    ink: Rgba::new(23, 24, 28, 255),
    paper: Rgba::new(242, 240, 234, 255),
    text: Rgba::new(23, 24, 28, 255),
    muted: Rgba::new(23, 24, 28, 179),
    faint: Rgba::new(23, 24, 28, 128),
    card: Rgba::new(23, 24, 28, 10),
    card_hover: Rgba::new(23, 24, 28, 20),
    line: Rgba::new(23, 24, 28, 31),
    well: Rgba::new(23, 24, 28, 15),
    accent: Rgba::new(23, 24, 28, 255),
    accent_bright: Rgba::new(0, 0, 0, 255),
    on_accent: Rgba::new(242, 240, 234, 255),
    heart: Rgba::new(255, 115, 140, 255),
    link: Rgba::new(31, 95, 191, 255),
    warn_background: Rgba::new(255, 240, 220, 255),
    warn_text: Rgba::new(122, 67, 0, 255),
    warn_edge: Rgba::new(239, 197, 143, 255),
    error_background: Rgba::new(255, 232, 230, 255),
    error_edge: Rgba::new(232, 163, 157, 255),
    danger: Rgba::new(198, 40, 40, 255),
    ok_background: Rgba::new(230, 246, 234, 255),
    ok_edge: Rgba::new(156, 207, 169, 255),
    focus: Rgba::new(23, 24, 28, 255),
    good: Rgba::new(44, 122, 69, 255),
    off: Rgba::new(138, 140, 147, 255),
    scrim: Rgba::new(0, 0, 0, 97),
    veil: Rgba::new(243, 241, 236, 204),
    spark_ember: Rgba::new(255, 158, 66, 255),
    spark_wisp: Rgba::new(140, 207, 255, 255),
    spark_hot: Rgba::new(255, 128, 61, 255),
    spark_smoke_edge: Rgba::new(153, 138, 189, 255),
    spark_smoke_core: Rgba::new(23, 15, 36, 255),
    spark_gold: Rgba::new(255, 214, 77, 255),
    spark_gold_core: Rgba::new(255, 247, 204, 255),
    spark_chain: Rgba::new(255, 115, 158, 255),
    spark_chain_core: Rgba::new(255, 237, 217, 255),
    spark_kindle_core: Rgba::new(204, 255, 209, 255),
    echo_accent: Rgba::new(184, 153, 255, 255),
};

/// Spacing in pixels. A terminal rounds it to cells in chat/src/theme.rs.
pub mod spacing {
    pub const HAIRLINE: u16 = 2;
    pub const TIGHT: u16 = 4;
    pub const SNUG: u16 = 6;
    pub const SMALL: u16 = 8;
    pub const COZY: u16 = 10;
    pub const MEDIUM: u16 = 12;
    pub const ROOMY: u16 = 14;
    pub const LARGE: u16 = 16;
    pub const PAGE: u16 = 20;
    pub const WIDE: u16 = 24;
    pub const HUGE: u16 = 28;
    pub const VAST: u16 = 40;
}

/// Animation lengths in milliseconds, and what each does under reduced motion (0 means it just happens).
pub mod motion {
    pub const REDUCED_FADE_MS: u64 = 150;
    pub const QUICK_MS: u64 = 120;
    pub const HOVER_MS: u64 = 150;
    pub const PRESS_MS: u64 = 150;
    pub const EXPAND_MS: u64 = 200;
    pub const SMOOTH_MS: u64 = 250;
    pub const SCENE_MS: u64 = 350;
    pub const SETTLE_MS: u64 = 350;
    pub const SPRING_MS: u64 = 400;
    pub const POP_MS: u64 = 400;
    pub const FADE_MS: u64 = 400;
    pub const PEEK_MS: u64 = 500;
}
