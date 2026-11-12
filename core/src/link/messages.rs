//! The device link messages (`docs/connecting/link.md`) as Rust types: every `LinkMessage` with the JSON
//! its frame carries, and the limits a message must meet to be believed. The vectors are
//! `spec/fixtures/link-messages.json`.

use crate::link::card::{LONGEST_NAME, LinkCard, LinkKind, LinkRoutes};
use crate::link::crypto::KEY_BYTES;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::BTreeMap;
use uuid::Uuid;

/// The longest text in characters.
pub const MAX_TEXT: usize = 20_000;
/// The biggest file in bytes.
pub const MAX_FILE: u64 = 512 * 1024 * 1024;
pub use crate::link::frames::{FrameError, MAX_FRAME};

/// Binary data, written as base64 in JSON.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Bytes(pub Vec<u8>);

impl From<Vec<u8>> for Bytes {
    fn from(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }
}

impl Serialize for Bytes {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&STANDARD.encode(&self.0))
    }
}

impl<'de> Deserialize<'de> for Bytes {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let text = String::deserialize(d)?;
        STANDARD
            .decode(text)
            .map(Bytes)
            .map_err(|_| D::Error::custom("not base64"))
    }
}

impl Bytes {
    pub(crate) fn is_key(&self) -> bool {
        self.0.len() == KEY_BYTES
    }
}

/// A side of a screen an Imp is thrown off, or flies in from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkSide {
    Left,
    Right,
}

impl LinkSide {
    /// Thrown off one side of a screen, it flies in from the other side of the next one.
    pub fn opposite(self) -> Self {
        match self {
            Self::Left => Self::Right,
            Self::Right => Self::Left,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkFeeling {
    Poke,
    Cuddle,
    Shake,
    Drop,
}

/// Why a thrown Imp bounces back. A reason from a newer app reads as `Other`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkDecline {
    Full,
    Playing,
    NotLinked,
    Timeout,
    Other,
}

impl<'de> Deserialize<'de> for LinkDecline {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(match String::deserialize(d)?.as_str() {
            "full" => Self::Full,
            "playing" => Self::Playing,
            "notLinked" => Self::NotLinked,
            "timeout" => Self::Timeout,
            _ => Self::Other,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkSpeechRole {
    Asked,
    Reply,
    Asking,
}

/// How an Imp flies onto a screen. Height and speed are limited as they are read.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(from = "RawEntry")]
pub struct LinkEntry {
    /// The side it comes in from.
    pub side: LinkSide,
    /// How far down that side: 0 the top, 1 the bottom.
    pub height: f64,
    /// How hard it was thrown, points a second (0: gently, from a menu).
    pub speed: f64,
}

#[derive(Deserialize)]
struct RawEntry {
    side: LinkSide,
    height: f64,
    speed: f64,
}

impl From<RawEntry> for LinkEntry {
    fn from(raw: RawEntry) -> Self {
        Self::new(raw.side, raw.height, raw.speed)
    }
}

impl LinkEntry {
    pub fn new(side: LinkSide, height: f64, speed: f64) -> Self {
        let height = if height.is_finite() { height } else { 0.5 };
        let speed = if speed.is_finite() { speed } else { 0.0 };
        Self {
            side,
            height: height.clamp(0.0, 1.0),
            speed: speed.max(0.0),
        }
    }

    /// Where it enters after being thrown off `exit` at `height` (it carries on the way it went).
    pub fn after(exit: LinkSide, height: f64, speed: f64) -> Self {
        Self::new(exit.opposite(), height, speed)
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct LinkTraits {
    pub lids: f64,
    pub slant: f64,
    pub eyes: f64,
    pub squint: f64,
    pub horns: f64,
    pub blush: f64,
    pub tilt: f64,
    pub tempo: f64,
}

/// What a device needs to draw an Imp exactly as its home does.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkImp {
    pub id: Uuid,
    pub name: String,
    pub hue: f64,
    pub scale: f64,
    pub traits: LinkTraits,
}

/// An Imp on someone's screen, and the device it thinks on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkStaged {
    pub imp: LinkImp,
    pub home: Uuid,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkTurn {
    pub id: Uuid,
    pub date: f64,
    pub request: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    pub reply: String,
    pub failed: bool,
    pub steps: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkWork {
    pub request: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    pub partial: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkSpeech {
    pub id: Uuid,
    pub role: LinkSpeechRole,
    pub peer: String,
    pub hue: f64,
    pub question: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkFilePart {
    pub name: String,
    pub size: u64,
    pub offset: u64,
    pub data: Bytes,
}

#[derive(Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct LinkSecrets {
    #[serde(default, rename = "apiKey", skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    pub headers: BTreeMap<String, BTreeMap<String, String>>,
}

impl std::fmt::Debug for LinkSecrets {
    /// Keys and header values are never shown.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinkSecrets")
            .field("api_key", &self.api_key.as_ref().map(|_| "<hidden>"))
            .field("headers", &self.headers.keys().collect::<Vec<_>>())
            .finish()
    }
}

/// One step of an animation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkBeat {
    pub duration: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub look_x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub look_y: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mood: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub glyph: Option<String>,
    #[serde(default)]
    pub tilt: f64,
    #[serde(default)]
    pub hop: bool,
    #[serde(default)]
    pub stretch: f64,
    #[serde(default, rename = "move", skip_serializing_if = "Option::is_none")]
    pub movement: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub times: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reverse: Option<bool>,
}

/// Who spoke in a talk line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkSender {
    pub id: Uuid,
    pub name: String,
    pub hue: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkTalkLine {
    pub id: Uuid,
    pub date: f64,
    pub asker: LinkSender,
    pub answerer: LinkSender,
    pub question: String,
    pub reply: String,
    pub failed: bool,
}

/// One frame body: a JSON object with one key, the message name.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkMessage {
    Hello {
        device: Uuid,
        name: String,
        kind: LinkKind,
        /// The Ed25519 key that names this device's room at the Hop.
        room: Bytes,
        /// The proof that the guest holds a fresh invite (`crypto::join_proof`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        join: Option<Bytes>,
    },
    Welcome {
        device: Uuid,
        name: String,
        kind: LinkKind,
        linked: bool,
    },
    Ping {},
    Pong {},
    Bye {
        reason: String,
    },
    Routes {
        door: Bytes,
        routes: LinkRoutes,
    },
    Stage {
        imps: Vec<LinkStaged>,
    },
    Pass {
        transfer: Uuid,
        imp: LinkImp,
        entry: LinkEntry,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        home: Option<LinkCard>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ticket: Option<Bytes>,
    },
    Took {
        transfer: Uuid,
    },
    Declined {
        transfer: Uuid,
        reason: LinkDecline,
    },
    Claim {
        imp: Uuid,
        ticket: Bytes,
    },
    Claimed {
        imp: Uuid,
        ticket: Bytes,
    },
    Gone {
        imp: Uuid,
    },
    Release {
        imp: Uuid,
        ticket: Bytes,
    },
    Ask {
        imp: Uuid,
        text: String,
    },
    Stop {
        imp: Uuid,
    },
    NewChat {
        imp: Uuid,
    },
    Felt {
        imp: Uuid,
        feeling: LinkFeeling,
    },
    File {
        id: Uuid,
        imp: Uuid,
        #[serde(rename = "ref")]
        reference: String,
    },
    Talks {
        imp: Uuid,
    },
    Look {
        imp: LinkImp,
    },
    Chat {
        imp: Uuid,
        turns: Vec<LinkTurn>,
    },
    Work {
        imp: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        work: Option<LinkWork>,
    },
    Mood {
        imp: Uuid,
        mood: String,
    },
    /// Whether it has a brain it can think with at its home. False: it sleeps on the holder too.
    Brain {
        imp: Uuid,
        ready: bool,
    },
    Animate {
        imp: Uuid,
        beats: Vec<LinkBeat>,
    },
    Speech {
        imp: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        speech: Option<LinkSpeech>,
    },
    FilePart {
        id: Uuid,
        part: LinkFilePart,
    },
    FileFailed {
        id: Uuid,
        reason: String,
    },
    TalkLines {
        imp: Uuid,
        lines: Vec<LinkTalkLine>,
    },
    Message {
        id: Uuid,
        from: LinkImp,
        to: Uuid,
        #[serde(rename = "toHome")]
        to_home: Uuid,
        text: String,
        forwarded: bool,
    },
    Answer {
        id: Uuid,
        text: String,
        failed: bool,
    },
    Adopt {
        transfer: Uuid,
        imp: Uuid,
        kit: String,
        secrets: LinkSecrets,
        entry: LinkEntry,
    },
    Adopted {
        transfer: Uuid,
    },
}

/// The message names this version knows.
const KNOWN: &[&str] = &[
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

/// What a frame body turned out to be.
#[derive(Debug, Clone, PartialEq)]
pub enum Decoded {
    Message(Box<LinkMessage>),
    /// Well formed JSON this version does not understand. A receiver ignores it.
    Unknown,
    /// Not a valid message. A receiver ignores it too (before the handshake it closes instead).
    Malformed,
}

impl LinkMessage {
    /// Reads one frame body.
    pub fn decode(body: &[u8]) -> Decoded {
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(body) else {
            return Decoded::Malformed;
        };
        let Some(object) = value.as_object() else {
            return Decoded::Unknown;
        };
        if object.len() == 1 && object.keys().all(|k| !KNOWN.contains(&k.as_str())) {
            return Decoded::Unknown;
        }
        match serde_json::from_value(value) {
            Ok(message) => Decoded::Message(Box::new(message)),
            Err(_) => Decoded::Malformed,
        }
    }

    /// The frame body as JSON bytes. Fails for a message that has no JSON (a number that is not finite).
    pub fn encode(&self) -> Result<Vec<u8>, FrameError> {
        serde_json::to_vec(self).map_err(|_| FrameError::Unencodable)
    }

    /// Whether sizes and counts are sane. A node drops a message that is not.
    pub fn is_sound(&self) -> bool {
        let name = |s: &str| s.chars().count() <= LONGEST_NAME * 2;
        let text = |s: &str| s.chars().count() <= MAX_TEXT;
        let imp = |i: &LinkImp| name(&i.name);
        match self {
            Self::Hello {
                name: n,
                room,
                join,
                ..
            } => name(n) && room.is_key() && join.as_ref().is_none_or(Bytes::is_key),
            Self::Welcome { name: n, .. } => name(n),
            Self::Bye { reason } => reason.chars().count() <= 200,
            Self::Routes { door, .. } => door.is_key(),
            Self::Stage { imps } => imps.len() <= 64 && imps.iter().all(|s| imp(&s.imp)),
            Self::Pass {
                imp: i,
                home,
                ticket,
                ..
            } => {
                imp(i)
                    && ticket.as_ref().is_none_or(Bytes::is_key)
                    && home.is_some() == ticket.is_some()
                    && home.as_ref().is_none_or(|h| name(&h.device.name))
            }
            Self::Claim { ticket, .. }
            | Self::Claimed { ticket, .. }
            | Self::Release { ticket, .. } => ticket.is_key(),
            Self::Ask { text: t, .. } => text(t),
            Self::File { reference, .. } => reference.chars().count() <= 4096,
            Self::Look { imp: i } => imp(i),
            Self::Chat { turns, .. } => {
                turns.len() <= 500 && turns.iter().all(|t| t.steps.len() <= 200)
            }
            Self::Mood { mood, .. } => mood.chars().count() <= 40,
            Self::Animate { beats, .. } => beats.len() <= 256,
            Self::FilePart { part, .. } => {
                part.data.0.len() <= 1 << 20
                    && part.size <= MAX_FILE
                    && part.offset <= part.size
                    && name(&part.name)
            }
            Self::FileFailed { reason, .. } => reason.chars().count() <= 500,
            Self::TalkLines { lines, .. } => lines.len() <= 300,
            Self::Message { from, text: t, .. } => imp(from) && text(t),
            Self::Answer { text: t, .. } => text(t),
            Self::Adopt { kit, .. } => kit.len() <= MAX_FRAME,
            Self::Ping {}
            | Self::Pong {}
            | Self::Gone { .. }
            | Self::Stop { .. }
            | Self::NewChat { .. }
            | Self::Felt { .. }
            | Self::Talks { .. }
            | Self::Work { .. }
            | Self::Brain { .. }
            | Self::Speech { .. }
            | Self::Took { .. }
            | Self::Declined { .. }
            | Self::Adopted { .. } => true,
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn secrets_debug_hides_keys_and_header_values() {
        let secrets = LinkSecrets {
            api_key: Some("sk-secret-value".into()),
            headers: BTreeMap::from([(
                "files".into(),
                BTreeMap::from([("Authorization".into(), "token-value".into())]),
            )]),
        };
        let shown = format!("{secrets:?}");
        assert!(
            !shown.contains("sk-secret-value") && !shown.contains("token-value"),
            "{shown}"
        );
    }

    use super::*;

    #[test]
    fn unknown_and_malformed() {
        assert_eq!(LinkMessage::decode(br#"{"warp":{}}"#), Decoded::Unknown);
        assert_eq!(LinkMessage::decode(b"[1]"), Decoded::Unknown);
        assert_eq!(LinkMessage::decode(b"nope"), Decoded::Malformed);
        assert_eq!(
            LinkMessage::decode(br#"{"ping":{},"pong":{}}"#),
            Decoded::Malformed
        );
    }
}
