use serde_json::{Value, json};

use super::*;

fn problems_of(doc: Value, kind: Kind) -> Vec<String> {
    match check(doc, kind).expect_err("document should fail") {
        Error::Invalid(found) => found
            .into_iter()
            .map(|v| format!("{} {}", v.pointer, v.detail))
            .collect(),
        other => panic!("not a validation failure: {other:?}"),
    }
}

fn animation(beats: Value) -> Value {
    json!({ "format": 1, "name": "n", "animations": [{ "name": "a", "beats": beats }] })
}

fn tool() -> Value {
    json!({ "format": 1, "name": "n", "mcpServers": { "s": { "url": "https://x.example/mcp" } } })
}

#[test]
fn each_type_takes_its_own_shape() {
    let imp = json!({ "format": 1, "name": "n", "imps": [{ "name": "Pip" }] });
    assert!(check(imp.clone(), Kind::Imp).is_ok());
    assert!(check(imp.clone(), Kind::Kit).is_ok());
    assert!(problems_of(imp, Kind::Tool)[0].contains("/mcpServers"));
    assert!(check(tool(), Kind::Tool).is_ok());
    assert!(problems_of(tool(), Kind::Animation)[0].contains("/animations"));
    let anim = animation(json!([{ "duration": 1.0 }]));
    assert!(check(anim.clone(), Kind::Animation).is_ok());
    assert!(problems_of(anim, Kind::Imp)[0].contains("/imps"));
    let two = json!({ "format": 1, "name": "n", "imps": [{ "name": "Pip" }, { "name": "Pop" }] });
    assert!(problems_of(two.clone(), Kind::Imp)[0].contains("exactly one"));
    assert!(check(two, Kind::Kit).is_ok());
}

#[test]
fn a_trigger_may_carry_the_one_animation_it_plays() {
    let one = json!({ "format": 1, "name": "n", "triggers": [{ "name": "t", "on": "poke", "do": [{ "act": "say", "value": "x" }] }],
        "animations": [{ "name": "a", "beats": [{ "duration": 1 }] }] });
    assert!(check(one, Kind::Trigger).is_ok());
    let two = json!({ "format": 1, "name": "n", "triggers": [{ "name": "t", "on": "poke", "do": [{ "act": "say", "value": "x" }] }],
        "animations": [{ "name": "a", "beats": [{ "duration": 1 }] }, { "name": "b", "beats": [{ "duration": 1 }] }] });
    assert!(problems_of(two, Kind::Trigger)[0].contains("/animations"));
}

#[test]
fn imp_with_its_own_tool_is_an_imp_and_a_loose_tool_is_not() {
    let kit = json!({ "format": 1, "name": "n", "imps": [{ "name": "Pip", "mcpServers": ["s"] }],
        "mcpServers": { "s": { "command": "npx", "args": ["x"] } } });
    let checked = check(kit, Kind::Imp).expect("imp");
    assert!(checked.runs_programs);
    let loose = json!({ "format": 1, "name": "n", "imps": [{ "name": "Pip" }],
        "mcpServers": { "s": { "url": "https://x.example/mcp" } } });
    assert!(problems_of(loose, Kind::Imp)[0].contains("/mcpServers"));
}

#[test]
fn format_is_required_and_a_newer_one_is_refused() {
    let none = json!({ "name": "n", "mcpServers": { "s": { "url": "https://x.example/mcp" } } });
    assert!(problems_of(none, Kind::Tool)[0].contains("/format"));
    for bad in [json!("1"), json!(1.5), json!(0), json!(-1), json!(true)] {
        let mut doc = tool();
        doc["format"] = bad;
        assert!(problems_of(doc, Kind::Tool)[0].contains("/format"));
    }
    let mut newer = tool();
    newer["format"] = json!(2);
    match check(newer, Kind::Tool).unwrap_err() {
        Error::UnsupportedFormat(detail) => {
            assert_eq!(detail, "This Den reads kit format 1 at most.")
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn skills_belong_in_a_kit_and_mark_it_as_running_programs() {
    let kit = json!({ "format": 1, "name": "n", "skills": [{ "name": "pdf", "source": "anthropics/skills/skills/pdf" }] });
    let checked = check(kit.clone(), Kind::Kit).expect("kit");
    assert!(checked.runs_programs);
    assert_eq!(checked.counts.skills, 1);
    assert!(
        problems_of(kit, Kind::Tool)
            .iter()
            .any(|p| p.contains("/skills"))
    );
    let bad = json!({ "format": 1, "name": "n", "skills": [{ "name": "PDF", "source": "a b" }] });
    let found = problems_of(bad, Kind::Kit);
    assert!(found.iter().any(|p| p.contains("/skills/0/name")));
    assert!(found.iter().any(|p| p.contains("/skills/0/source")));
    let many: Vec<Value> = (0..21)
        .map(|i| json!({ "name": format!("s{i}"), "source": "a/b" }))
        .collect();
    let too_many = json!({ "format": 1, "name": "n", "skills": many });
    assert!(problems_of(too_many, Kind::Kit)[0].contains("at most 20"));
}

#[test]
fn secrets_are_refused() {
    let env = json!({ "format": 1, "name": "n", "mcpServers": { "s": { "command": "x", "env": { "API_KEY": "sk-1" } } } });
    assert!(problems_of(env, Kind::Tool)[0].contains("/mcpServers/s/env/API_KEY"));
    let query = json!({ "format": 1, "name": "n", "mcpServers": { "s": { "url": "https://x.example/mcp?api_key=1" } } });
    assert!(problems_of(query, Kind::Tool)[0].contains("looks like a secret"));
    let user = json!({ "format": 1, "name": "n", "mcpServers": { "s": { "url": "https://u:p@x.example/" } } });
    assert!(problems_of(user, Kind::Tool)[0].contains("user name"));
    let empty = json!({ "format": 1, "name": "n", "mcpServers": { "s": { "command": "x", "env": { "API_KEY": "" } } } });
    assert!(check(empty, Kind::Tool).is_ok());
}

#[test]
fn animations_are_checked() {
    let found = |beats: Value| problems_of(animation(beats), Kind::Animation);
    assert!(found(json!([])).iter().any(|p| p.contains("1 to 24 beats")));
    assert!(
        found(json!([{ "duration": 0.01 }]))
            .iter()
            .any(|p| p.contains("duration"))
    );
    assert!(
        found(json!([{ "duration": 1, "mood": "grumpy" }]))
            .iter()
            .any(|p| p.contains("mood"))
    );
    assert!(
        found(json!([{ "duration": 1, "times": 9 }]))
            .iter()
            .any(|p| p.contains("times"))
    );
    let long = json!(
        (0..5)
            .map(|_| json!({ "duration": 5.0 }))
            .collect::<Vec<_>>()
    );
    assert!(found(long).iter().any(|p| p.contains("at most 20")));
}

#[test]
fn limits_and_basics() {
    assert!(problems_of(json!([]), Kind::Kit).len() == 1);
    assert!(
        problems_of(json!({ "format": 1, "triggers": [{}] }), Kind::Trigger)[0].contains("/name")
    );
    assert!(
        problems_of(json!({ "format": 1, "name": "n" }), Kind::Kit)[0].contains("at least one")
    );
    let imps: Vec<Value> = (0..21)
        .map(|i| json!({ "name": format!("i{i}") }))
        .collect();
    assert!(
        problems_of(json!({ "format": 1, "name": "n", "imps": imps }), Kind::Kit)[0]
            .contains("at most 20")
    );
    let chats =
        json!({ "format": 1, "name": "n", "imps": [{ "name": "p", "chats": [{ "title": "x" }] }] });
    assert!(problems_of(chats, Kind::Imp)[0].contains("private"));
    let traits =
        json!({ "format": 1, "name": "n", "imps": [{ "name": "p", "traits": { "lids": 0.9 } }] });
    assert!(problems_of(traits, Kind::Imp)[0].contains("lids"));
}

#[test]
fn size_limits_follow_the_type() {
    let big = "x".repeat(70 * 1024);
    let doc = json!({ "format": 1, "name": "n", "about": "a", "mcpServers": { "s": { "url": format!("https://x.example/{big}") } } });
    assert!(problems_of(doc.clone(), Kind::Tool)[0].contains("at most 64 KB"));
    assert!(check(doc, Kind::Kit).is_ok());
}

#[test]
fn the_stored_text_is_compact_with_sorted_keys() {
    let doc = json!({ "name": "n", "format": 1, "mcpServers": { "s": { "url": "https://x.example/mcp" } } });
    let text = check(doc, Kind::Tool).unwrap().text;
    assert_eq!(
        text,
        r#"{"format":1,"mcpServers":{"s":{"url":"https://x.example/mcp"}},"name":"n"}"#
    );
}

fn trigger_kit(trigger: Value) -> Value {
    json!({ "format": 1, "name": "n", "triggers": [trigger] })
}

#[test]
fn a_valid_trigger_passes_at_top_level_and_inside_an_imp() {
    let t = json!({ "name": "Ouch", "on": "poke",
        "if": [{ "state": "hours", "value": "09:00-18:00" }],
        "do": [{ "act": "play", "value": "Wiggle" }, { "act": "say", "value": "Ouch!" }] });
    assert!(check(trigger_kit(t.clone()), Kind::Trigger).is_ok());
    let imp = json!({ "format": 1, "name": "n", "imps": [{ "name": "Pip", "triggers": [t] }] });
    assert!(check(imp, Kind::Imp).is_ok());
}

#[test]
fn a_trigger_with_an_unknown_event_state_or_act_is_refused() {
    let found = problems_of(
        trigger_kit(json!({ "on": "sneeze", "do": [{ "act": "say" }] })),
        Kind::Trigger,
    );
    assert!(found[0].starts_with("/triggers/0/on "), "{found:?}");
    let found = problems_of(
        trigger_kit(json!({ "on": "poke", "if": [{ "state": "mood" }], "do": [{ "act": "say" }] })),
        Kind::Trigger,
    );
    assert!(found[0].starts_with("/triggers/0/if/0/state "), "{found:?}");
    let found = problems_of(
        trigger_kit(json!({ "on": "poke", "do": [{ "act": "dance" }] })),
        Kind::Trigger,
    );
    assert!(found[0].starts_with("/triggers/0/do/0/act "), "{found:?}");
    let imp = json!({ "format": 1, "name": "n",
        "imps": [{ "name": "Pip", "triggers": [{ "on": "sneeze", "do": [{ "act": "say" }] }] }] });
    assert!(problems_of(imp, Kind::Imp)[0].starts_with("/imps/0/triggers/0/on "));
}

#[test]
fn a_trigger_needs_one_to_five_steps_and_a_short_name() {
    for steps in [0, 6] {
        let list: Vec<Value> = (0..steps).map(|_| json!({ "act": "say" })).collect();
        let found = problems_of(
            trigger_kit(json!({ "on": "poke", "do": list })),
            Kind::Trigger,
        );
        assert!(found[0].starts_with("/triggers/0/do "), "{found:?}");
    }
    let five: Vec<Value> = (0..5).map(|_| json!({ "act": "say" })).collect();
    assert!(
        check(
            trigger_kit(json!({ "on": "poke", "do": five })),
            Kind::Trigger
        )
        .is_ok()
    );
    let long = "x".repeat(61);
    let found = problems_of(
        trigger_kit(json!({ "name": long, "on": "poke", "do": [{ "act": "say" }] })),
        Kind::Trigger,
    );
    assert!(found[0].starts_with("/triggers/0/name "), "{found:?}");
}

#[test]
fn an_animation_with_starts_is_refused() {
    let doc = json!({ "format": 1, "name": "n",
        "animations": [{ "name": "a", "starts": ["idle"], "beats": [{ "duration": 1 }] }] });
    assert!(problems_of(doc, Kind::Animation)[0].starts_with("/animations/0/starts "));
}
