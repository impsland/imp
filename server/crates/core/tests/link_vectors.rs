//! Checks the link messages against the shared vectors in `Tests/Fixtures/link-messages.json`.

use imp_core::link::{Decoded, LinkMessage};
use serde_json::Value;

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../Tests/Fixtures/link-messages.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("json")
}

/// Equal as parsed JSON, with numbers compared by value (1 and 1.0 are the same).
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

fn body(entry: &Value) -> Vec<u8> {
    serde_json::to_vec(&entry["json"]).unwrap()
}

fn name(entry: &Value) -> &str {
    entry["name"].as_str().unwrap()
}

#[test]
fn every_valid_vector_decodes_and_encodes_back() {
    let all = vectors();
    let valid = all["valid"].as_array().unwrap();
    assert!(valid.len() >= 30);
    for entry in valid {
        let Decoded::Message(message) = LinkMessage::decode(&body(entry)) else {
            panic!("{} did not decode", name(entry));
        };
        assert!(message.is_sound(), "{} is not sound", name(entry));
        let again: Value = serde_json::from_slice(&message.encode()).unwrap();
        let expected = entry.get("reencodes").unwrap_or(&entry["json"]);
        assert!(
            same(&again, expected),
            "{}: {again} != {expected}",
            name(entry)
        );
        // Reading what we wrote gives the same message.
        assert_eq!(
            LinkMessage::decode(&message.encode()),
            Decoded::Message(message),
            "{}",
            name(entry)
        );
    }
}

#[test]
fn unknown_vectors_are_ignored() {
    for entry in vectors()["unknown"].as_array().unwrap() {
        assert_eq!(
            LinkMessage::decode(&body(entry)),
            Decoded::Unknown,
            "{}",
            name(entry)
        );
    }
}

#[test]
fn malformed_vectors_are_rejected() {
    for entry in vectors()["malformed"].as_array().unwrap() {
        assert_eq!(
            LinkMessage::decode(&body(entry)),
            Decoded::Malformed,
            "{}",
            name(entry)
        );
    }
}

#[test]
fn unsound_vectors_decode_but_break_a_limit() {
    for entry in vectors()["unsound"].as_array().unwrap() {
        let Decoded::Message(message) = LinkMessage::decode(&body(entry)) else {
            panic!("{} should decode", name(entry));
        };
        assert!(!message.is_sound(), "{} should be unsound", name(entry));
    }
}
