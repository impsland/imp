//! Animation and trait rules of a kit: moods, glyphs, moves, beat timing and Imp trait ranges.

use serde_json::Value;

use super::{Problems, is_number, whole_number};

pub(super) const MAX_BEATS: usize = 24;
pub(super) const MIN_BEAT: f64 = 0.05;
pub(super) const MAX_BEAT: f64 = 6.0;
pub(super) const MAX_TOTAL: f64 = 20.0;

pub(super) const MOODS: [&str; 20] = [
    "idle",
    "listening",
    "thinking",
    "happy",
    "love",
    "sad",
    "error",
    "sleepy",
    "annoyed",
    "surprised",
    "dizzy",
    "mean",
    "working",
    "content",
    "giggly",
    "scared",
    "curious",
    "shy",
    "excited",
    "bored",
];
pub(super) const GLYPHS: [&str; 7] = [
    "notes", "question", "exclaim", "idea", "sweat", "heart", "sparkles",
];
pub(super) const MOVES: [&str; 10] = [
    "spin",
    "flip",
    "roll",
    "bounce",
    "shake",
    "sway",
    "wobble",
    "float",
    "nod",
    "headshake",
];
pub(super) const TRAITS: [(&str, f64, f64); 8] = [
    ("lids", 0.0, 0.6),
    ("slant", -1.0, 1.0),
    ("eyes", -0.4, 0.4),
    ("squint", -1.0, 1.0),
    ("horns", -30.0, 30.0),
    ("blush", 0.0, 1.0),
    ("tilt", -12.0, 12.0),
    ("tempo", 0.6, 1.6),
];

pub(super) fn check_traits(traits: &Value, at: &str, problems: &mut Problems) {
    let Some(traits) = traits.as_object() else {
        problems.add(at, "must be an object");
        return;
    };
    for (key, lo, hi) in TRAITS {
        if let Some(v) = traits.get(key)
            && !is_number(v).is_some_and(|n| (lo..=hi).contains(&n))
        {
            problems.add(
                &format!("{at}/{key}"),
                format!("must be a number from {lo} to {hi}"),
            );
        }
    }
}

pub(super) fn check_animation(anim: &Value, at: &str, problems: &mut Problems) {
    let Some(anim) = anim.as_object() else {
        problems.add(at, "must be an object");
        return;
    };
    if anim.contains_key("starts") {
        problems.add(
            &format!("{at}/starts"),
            "animations no longer start by themselves; use a trigger with a `play` step",
        );
    }
    match anim.get("name").and_then(Value::as_str).map(str::trim) {
        Some(n) if !n.is_empty() && n.chars().count() <= 40 => {}
        _ => problems.add(
            &format!("{at}/name"),
            "a name of 1 to 40 characters is required",
        ),
    }
    let Some(beats) = anim
        .get("beats")
        .and_then(Value::as_array)
        .filter(|b| (1..=MAX_BEATS).contains(&b.len()))
    else {
        problems.add(
            &format!("{at}/beats"),
            format!("needs 1 to {MAX_BEATS} beats"),
        );
        return;
    };
    let mut total = 0.0;
    for (n, beat) in beats.iter().enumerate() {
        let at = format!("{at}/beats/{n}");
        let Some(beat) = beat.as_object() else {
            problems.add(&at, "must be an object");
            continue;
        };
        match beat
            .get("duration")
            .and_then(is_number)
            .filter(|d| (MIN_BEAT..=MAX_BEAT).contains(d))
        {
            Some(d) => total += d,
            None => problems.add(
                &format!("{at}/duration"),
                format!("must be a number from {MIN_BEAT} to {MAX_BEAT} seconds"),
            ),
        }
        for (key, allowed) in [
            ("mood", &MOODS[..]),
            ("glyph", &GLYPHS[..]),
            ("move", &MOVES[..]),
        ] {
            if let Some(v) = beat.get(key)
                && !v.as_str().is_some_and(|s| allowed.contains(&s))
            {
                problems.add(&format!("{at}/{key}"), format!("unknown {key}"));
            }
        }
        if let Some(look) = beat.get("look").filter(|l| !l.is_null()) {
            let ok = look.as_array().is_some_and(|l| {
                l.len() == 2
                    && l.iter()
                        .all(|x| is_number(x).is_some_and(|n| (-1.0..=1.0).contains(&n)))
            });
            if !ok {
                problems.add(
                    &format!("{at}/look"),
                    "must be [x, y] with each from -1 to 1",
                );
            }
        }
        for (key, lo, hi) in [("tilt", -30.0, 30.0), ("stretch", -0.3, 0.3)] {
            if let Some(v) = beat.get(key)
                && !is_number(v).is_some_and(|n| (lo..=hi).contains(&n))
            {
                problems.add(
                    &format!("{at}/{key}"),
                    format!("must be a number from {lo} to {hi}"),
                );
            }
        }
        for key in ["hop", "reverse"] {
            if beat.get(key).is_some_and(|v| !v.is_boolean()) {
                problems.add(&format!("{at}/{key}"), "must be true or false");
            }
        }
        if let Some(v) = beat.get("times")
            && !whole_number(v).is_some_and(|t| (1..=8).contains(&t))
        {
            problems.add(&format!("{at}/times"), "must be a whole number from 1 to 8");
        }
    }
    if total > MAX_TOTAL + 1e-9 {
        problems.add(
            &format!("{at}/beats"),
            format!("{total:.1} s long, at most {MAX_TOTAL} s"),
        );
    }
}
