//! The document format, written out for whoever writes a document without Imp's own export: a model
//! behind any MCP host, or a person. It is built from the constants the checks use, so it can't say
//! anything the checks don't, and every example in it passes the checks (see `tests`).

use serde_json::{Value, json};

use super::animation::{GLYPHS, MAX_BEAT, MAX_BEATS, MAX_TOTAL, MIN_BEAT, MOODS, MOVES, TRAITS};
use super::skills::MAX_SKILLS;
use super::trigger::{ACTS, EVENTS, MAX_NAME as MAX_TRIGGER_NAME, MAX_STEPS, STATES};
use super::{
    Kind, MAX_ANIMATIONS, MAX_FORMAT, MAX_IMPS, MAX_ITEM_BYTES, MAX_KIT_BYTES, MAX_SERVERS,
    MAX_TRIGGERS,
};

/// What a document of `kind` holds at the top level.
fn holds(kind: Kind) -> &'static str {
    match kind {
        Kind::Imp => {
            "Exactly one entry in `imps` (its own `animations` and `triggers` go inside it), plus the `mcpServers` that Imp names, and nothing else."
        }
        Kind::Animation => "Exactly one entry in `animations`, and nothing else.",
        Kind::Trigger => {
            "Exactly one entry in `triggers`, plus at most the one animation it plays in `animations`."
        }
        Kind::Tool => "Exactly one entry in `mcpServers`, and nothing else.",
        Kind::Kit => {
            "Any of `imps`, `animations`, `triggers`, `mcpServers` and `skills`, at least one entry in all."
        }
    }
}

/// A document of `kind` that the Den accepts.
fn example(kind: Kind) -> Value {
    match kind {
        Kind::Animation => json!({
            "format": 1, "name": "Happy Wave",
            "animations": [wave()],
        }),
        Kind::Trigger => json!({
            "format": 1, "name": "Ouch",
            "triggers": [{
                "name": "Ouch", "on": "poke",
                "do": [{ "act": "play", "value": "Wiggle" }, { "act": "say", "value": "Ouch!" }],
            }],
            "animations": [{
                "name": "Wiggle",
                "beats": [{ "duration": 0.6, "mood": "surprised", "move": "wobble", "times": 2 }],
            }],
        }),
        Kind::Tool => json!({
            "format": 1, "name": "Weather",
            "mcpServers": { "weather": { "url": "https://weather.example/mcp", "headers": { "Authorization": "" } } },
        }),
        Kind::Imp => json!({
            "format": 1, "name": "Pip",
            "imps": [{
                "name": "Pip",
                "personality": "You are Pip, a calm and cheerful Imp. You answer briefly and kindly.",
                "traits": { "lids": 0.2, "blush": 0.6, "tempo": 1.2 },
                "animations": [wave()],
                "triggers": [{ "on": "click", "do": [{ "act": "play", "value": "Happy Wave" }] }],
                "mcpServers": ["weather"],
            }],
            "mcpServers": { "weather": { "url": "https://weather.example/mcp" } },
        }),
        Kind::Kit => json!({
            "format": 1, "name": "Morning pack", "about": "A wave, a greeting and a weather tool.",
            "animations": [wave()],
            "triggers": [{
                "name": "Good morning", "on": "wake",
                "if": [{ "state": "hours", "value": "06:00-11:00" }],
                "do": [{ "act": "play", "value": "Happy Wave" }, { "act": "ask", "value": "Greet the person and give a one-line plan for the day." }],
            }],
            "mcpServers": { "weather": { "url": "https://weather.example/mcp" } },
            "skills": [{ "name": "pdf", "source": "anthropics/skills/skills/pdf" }],
        }),
    }
}

fn wave() -> Value {
    json!({
        "name": "Happy Wave",
        "beats": [
            { "duration": 0.4, "mood": "happy", "glyph": "sparkles", "look": [0, -0.3] },
            { "duration": 0.8, "mood": "excited", "move": "sway", "times": 2 },
            { "duration": 0.4, "mood": "content", "hop": true },
        ],
    })
}

fn animation_rules() -> Value {
    let traits: serde_json::Map<String, Value> = TRAITS
        .iter()
        .map(|(name, lo, hi)| ((*name).to_owned(), json!([lo, hi])))
        .collect();
    json!({
        "animation": {
            "name": "Required, 1 to 40 characters. A trigger plays it by this name.",
            "beats": format!("Required, 1 to {MAX_BEATS} beats, at most {MAX_TOTAL} s in all."),
            "starts": "Refused: nothing starts an animation but a trigger's `play` step.",
        },
        "beat": {
            "duration": format!("Required, seconds, {MIN_BEAT} to {MAX_BEAT}."),
            "mood": "The face during the beat, one of `moods`.",
            "glyph": "A sign above the head, one of `glyphs`.",
            "move": "A whole-body move across the beat, one of `moves`, with `times` (1 to 8) and `reverse` (true or false).",
            "look": "Where the eyes look, [x, y], each -1 to 1.",
            "tilt": "Lean, -30 to 30 degrees.",
            "hop": "true for a little hop.",
            "stretch": "Squash or stretch, -0.3 to 0.3.",
            "note": "Other fields are ignored, so a beat with none of these only waits.",
        },
        "moods": MOODS,
        "glyphs": GLYPHS,
        "moves": MOVES,
        "traits": traits,
    })
}

fn trigger_rules() -> Value {
    json!({
        "trigger": {
            "name": format!("Optional, 1 to {MAX_TRIGGER_NAME} characters."),
            "on": "Required, one of `events`.",
            "value": "The event's argument where it takes one: keys such as \"ctrl+cmd+T\" for keys, clicks (1 to 3) for click, \"HH:MM\" for at, minutes (1 to 1440) for every, seconds (5 to 86400) for idle, an app name for app, part of an address for website, a percent for battery and busy, \"plugged\" or \"unplugged\" for charger, \"offline\" or \"online\" for network.",
            "if": "Optional list of conditions that must all hold: { \"state\": one of `states`, \"value\" }. hours takes \"22:00-07:00\", days takes \"mon-fri\" or \"sat,sun\", asleep takes true or false; the others read value as the event of the same name.",
            "do": format!("Required, 1 to {MAX_STEPS} steps run in order: {{ \"act\": one of `acts`, \"value\" }}."),
            "enabled": "Optional, true by default.",
        },
        "acts": {
            "ask": "value: what the Imp should do, in plain words to itself. Its model answers with its tools.",
            "say": "value: text shown in the bubble.",
            "play": "value: the name of an animation.",
            "sleep": "value: optional animation to play while falling asleep.",
            "wake": "value: optional animation to play while waking.",
            "follow": "value: off, eyes, hop or glide; optional speed 0.5 to 2.",
            "open": "value: text_box, listen, chat or settings.",
        },
        "events": EVENTS,
        "states": STATES,
        "act_names": ACTS,
    })
}

fn tool_rules() -> Value {
    json!({
        "mcpServers": format!("An object of at most {MAX_SERVERS} tools, keyed by a name of 1 to 64 characters, in the shape Claude Desktop uses."),
        "server": "Either { \"url\" } (https:// or http://, no user name or password, no query parameter named like a key, token, secret, password, auth, sig or credential) or { \"command\", \"args\" } (a program that runs on the person's computer), never both.",
        "secrets": "Every value in `env` and `headers` must be the empty string \"\": the person fills it in after installing.",
    })
}

fn imp_rules() -> Value {
    json!({
        "imp": {
            "name": "Required.",
            "personality": "Optional: who the Imp is and how it talks, written to the Imp.",
            "traits": "Optional face settings, each in its range in `traits`.",
            "animations": "Optional: the Imp's own animations.",
            "triggers": format!("Optional: the Imp's own triggers, at most {MAX_TRIGGERS}."),
            "mcpServers": "Optional: names of tools, each also defined in the document's top-level `mcpServers`.",
            "chats": "Refused: chats are private.",
        },
    })
}

fn skill_rules() -> Value {
    json!({
        "skills": format!("Only in a kit, at most {MAX_SKILLS}: {{ \"name\": 1 to 64 of a-z, 0-9 and inner dashes, \"source\": owner/repo, owner/repo/path or an https:// address }}, as `npx skills add <source>` takes it."),
    })
}

fn merge(into: &mut Value, part: Value) {
    if let (Some(into), Value::Object(part)) = (into.as_object_mut(), part) {
        into.extend(part);
    }
}

/// The rules and an example for `kind`, or for every type.
pub fn reference(kind: Option<Kind>) -> Value {
    let kinds: Vec<Kind> = kind.map_or_else(|| Kind::ALL.to_vec(), |k| vec![k]);
    let mut types = serde_json::Map::new();
    for k in &kinds {
        types.insert(
            k.as_str().to_owned(),
            json!({
                "holds": holds(*k),
                "max_bytes": if *k == Kind::Kit { MAX_KIT_BYTES } else { MAX_ITEM_BYTES },
                "example": example(*k),
            }),
        );
    }
    let mut out = json!({
        "document": {
            "format": format!("Required, the integer {MAX_FORMAT}."),
            "name": "Required, 1 to 80 characters: the item's name in the gallery.",
            "about": "Optional, at most 4000 characters.",
            "limits": format!("At most {MAX_IMPS} Imps, {MAX_TRIGGERS} triggers and {MAX_ANIMATIONS} animations (counting those inside Imps)."),
            "unknown_fields": "Ignored by Imp, so they do nothing.",
        },
        "types": types,
    });
    let needs = |wanted: &[Kind]| kinds.iter().any(|k| wanted.contains(k));
    if needs(&[Kind::Animation, Kind::Trigger, Kind::Imp, Kind::Kit]) {
        merge(&mut out, animation_rules());
    }
    if needs(&[Kind::Trigger, Kind::Imp, Kind::Kit]) {
        merge(&mut out, trigger_rules());
    }
    if needs(&[Kind::Tool, Kind::Imp, Kind::Kit]) {
        merge(&mut out, tool_rules());
    }
    if needs(&[Kind::Imp, Kind::Kit]) {
        merge(&mut out, imp_rules());
    }
    if needs(&[Kind::Kit]) {
        merge(&mut out, skill_rules());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kit::check;

    #[test]
    fn every_example_passes_the_checks_as_its_type() {
        for kind in Kind::ALL {
            let doc = example(kind);
            if let Err(e) = check(doc.clone(), kind) {
                panic!("the {} example fails: {e:?}", kind.as_str());
            }
            let shown = &reference(Some(kind))["types"][kind.as_str()]["example"];
            assert_eq!(shown, &doc);
        }
    }

    #[test]
    fn one_type_gets_only_the_rules_it_needs() {
        let tool = reference(Some(Kind::Tool));
        assert!(tool.get("server").is_some());
        assert!(tool.get("moods").is_none());
        assert!(tool["types"].get("animation").is_none());
        let animation = reference(Some(Kind::Animation));
        assert_eq!(
            animation["moods"].as_array().map(Vec::len),
            Some(MOODS.len())
        );
        assert!(animation.get("events").is_none());
        let all = reference(None);
        assert_eq!(all["types"].as_object().map(|t| t.len()), Some(5));
        assert!(all.get("skills").is_some() && all.get("events").is_some());
    }
}
