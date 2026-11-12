//! Checks the link messages against the shared vectors in `spec/fixtures/link-messages.json`.

use imp_core::link::{Decoded, LinkMessage};
use serde_json::Value;

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../spec/fixtures/link-messages.json"
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
        let wire = message.encode().expect("encodes");
        let again: Value = serde_json::from_slice(&wire).unwrap();
        let expected = entry.get("reencodes").unwrap_or(&entry["json"]);
        assert!(
            same(&again, expected),
            "{}: {again} != {expected}",
            name(entry)
        );
        // Reading what we wrote gives the same message.
        assert_eq!(
            LinkMessage::decode(&wire),
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

#[test]
fn every_link_message_has_a_vector() {
    let all = vectors();
    let names: std::collections::BTreeSet<&str> = all["valid"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            entry["json"]
                .as_object()
                .unwrap()
                .keys()
                .next()
                .unwrap()
                .as_str()
        })
        .collect();
    let cases = [
        "hello",
        "welcome",
        "ping",
        "pong",
        "bye",
        "routes",
        "stage",
        "pass",
        "took",
        "declined",
        "claim",
        "claimed",
        "gone",
        "release",
        "ask",
        "stop",
        "newChat",
        "felt",
        "file",
        "talks",
        "look",
        "chat",
        "work",
        "mood",
        "brain",
        "animate",
        "speech",
        "filePart",
        "fileFailed",
        "talkLines",
        "message",
        "answer",
        "adopt",
        "adopted",
    ];
    assert_eq!(names, cases.into_iter().collect());
    assert!(all.get("version").is_none(), "the vectors carry no version");
}

fn invite_vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../spec/fixtures/link-invites.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("json")
}

fn base64url(bytes: &imp_core::link::messages::Bytes) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&bytes.0)
}

#[test]
fn every_valid_invite_is_read_and_written_the_same_way() {
    use imp_core::link::{LinkInvite, LinkKind};
    let all = invite_vectors();
    let valid = all["valid"].as_array().unwrap();
    assert!(valid.len() >= 3);
    for entry in valid {
        let url = entry["url"].as_str().unwrap();
        let invite =
            LinkInvite::parse(url).unwrap_or_else(|| panic!("{} did not parse", name(entry)));
        let expect = &entry["expect"];
        assert_eq!(
            invite.device.id.to_string(),
            expect["device"].as_str().unwrap()
        );
        assert_eq!(invite.device.name, expect["name"].as_str().unwrap());
        let kind = match invite.device.kind {
            LinkKind::Mac => "mac",
            LinkKind::Phone => "phone",
        };
        assert_eq!(kind, expect["kind"].as_str().unwrap(), "{}", name(entry));
        assert_eq!(
            base64url(&invite.device.key),
            expect["key"].as_str().unwrap()
        );
        assert_eq!(
            base64url(&invite.device.room),
            expect["room"].as_str().unwrap()
        );
        assert_eq!(base64url(&invite.door), expect["door"].as_str().unwrap());
        assert_eq!(
            base64url(&invite.invite),
            expect["invite"].as_str().unwrap()
        );
        let hosts: Vec<&str> = expect["hosts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|h| h.as_str().unwrap())
            .collect();
        assert_eq!(invite.routes.hosts, hosts, "{}", name(entry));
        assert_eq!(
            u64::from(invite.routes.port),
            expect["port"].as_u64().unwrap()
        );
        assert_eq!(invite.routes.hop.as_deref(), expect["hop"].as_str());
        assert_eq!(
            invite.url(),
            entry["canonical"].as_str().unwrap(),
            "{}",
            name(entry)
        );
    }
}

#[test]
fn every_invalid_invite_is_refused() {
    use imp_core::link::LinkInvite;
    let all = invite_vectors();
    let invalid = all["invalid"].as_array().unwrap();
    assert!(invalid.len() >= 10);
    for entry in invalid {
        assert!(
            LinkInvite::parse(entry["url"].as_str().unwrap()).is_none(),
            "{} was accepted",
            name(entry)
        );
    }
}
