//! The device link messages and frames (`docs/LINK.md`), as Rust types.
//!
//! This is the base a program needs to take part in a link: every `LinkMessage` case with the same
//! JSON the Swift `LinkMessage` writes, the length-prefixed frame codec, and the soundness limits.
//! It has no network or crypto in it. The vectors are `Tests/Fixtures/link-messages.json`.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::BTreeMap;
use uuid::Uuid;

/// The protocol version this code speaks.
pub const VERSION: u32 = 2;
/// The biggest frame body in bytes.
pub const MAX_FRAME: usize = 4 << 20;
/// The longest text in characters.
pub const MAX_TEXT: usize = 20_000;
/// The longest device name in characters.
pub const LONGEST_NAME: usize = 80;
/// The size of keys, doors and tickets in bytes.
pub const KEY_BYTES: usize = 32;
/// The size of a proof in bytes.
pub const PROOF_BYTES: usize = 64;
/// The most hosts in a set of routes.
pub const MOST_HOSTS: usize = 8;
/// The biggest file in bytes.
pub const MAX_FILE: u64 = 512 * 1024 * 1024;

/// Binary data, written as base64 in JSON.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bytes(pub Vec<u8>);

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
    fn is_key(&self) -> bool {
        self.0.len() == KEY_BYTES
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Mac,
    Phone,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Side {
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Feeling {
    Poke,
    Cuddle,
    Shake,
    Drop,
}

/// Why a thrown Imp bounces back. A reason from a newer version reads as `Other`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Decline {
    Full,
    Playing,
    NotLinked,
    Timeout,
    Other,
}

impl<'de> Deserialize<'de> for Decline {
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
pub enum SpeechRole {
    Asked,
    Reply,
    Asking,
}

/// Where an Imp enters a screen. Height and speed are limited as the Swift decoder does.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(from = "RawEntry")]
pub struct Entry {
    pub side: Side,
    pub height: f64,
    pub speed: f64,
}

#[derive(Deserialize)]
struct RawEntry {
    side: Side,
    height: f64,
    speed: f64,
}

impl From<RawEntry> for Entry {
    fn from(raw: RawEntry) -> Self {
        Self::new(raw.side, raw.height, raw.speed)
    }
}

impl Entry {
    pub fn new(side: Side, height: f64, speed: f64) -> Self {
        let height = if height.is_finite() { height } else { 0.5 };
        let speed = if speed.is_finite() { speed } else { 0.0 };
        Self {
            side,
            height: height.clamp(0.0, 1.0),
            speed: speed.max(0.0),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Traits {
    pub lids: f64,
    pub slant: f64,
    pub eyes: f64,
    pub squint: f64,
    pub horns: f64,
    pub blush: f64,
    pub tilt: f64,
    pub tempo: f64,
}

/// An Imp's looks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Imp {
    pub id: Uuid,
    pub name: String,
    pub hue: f64,
    pub scale: f64,
    pub traits: Traits,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Staged {
    pub imp: Imp,
    pub home: Uuid,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub id: Uuid,
    pub name: String,
    pub kind: Kind,
    pub key: Bytes,
}

/// Where a device can be reached. Checked when it is read, as the Swift decoder does.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "RawRoutes")]
pub struct Routes {
    pub hosts: Vec<String>,
    pub port: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hop: Option<String>,
}

#[derive(Deserialize)]
struct RawRoutes {
    hosts: Vec<String>,
    port: u16,
    #[serde(default)]
    hop: Option<String>,
}

fn is_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ':'))
}

/// `host:port`, as the Hop address in routes.
pub fn is_hop_address(text: &str) -> bool {
    text.rsplit_once(':')
        .is_some_and(|(host, port)| is_host(host) && port.parse::<u16>().is_ok_and(|p| p > 0))
}

impl TryFrom<RawRoutes> for Routes {
    type Error = String;

    fn try_from(raw: RawRoutes) -> Result<Self, String> {
        let good = raw.port > 0
            && raw.hosts.len() <= MOST_HOSTS
            && raw.hosts.iter().all(|h| is_host(h))
            && raw.hop.as_deref().is_none_or(is_hop_address);
        if good {
            Ok(Self {
                hosts: raw.hosts,
                port: raw.port,
                hop: raw.hop,
            })
        } else {
            Err("bad routes".into())
        }
    }
}

/// A device's visiting card. It holds the door key, so it is a secret and must not be logged.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "RawCard")]
pub struct Card {
    pub device: Device,
    pub door: Bytes,
    pub routes: Routes,
}

#[derive(Deserialize)]
struct RawCard {
    device: Device,
    door: Bytes,
    routes: Routes,
}

impl TryFrom<RawCard> for Card {
    type Error = String;

    fn try_from(raw: RawCard) -> Result<Self, String> {
        if raw.door.is_key() && raw.device.key.is_key() {
            Ok(Self {
                device: raw.device,
                door: raw.door,
                routes: raw.routes,
            })
        } else {
            Err("bad card".into())
        }
    }
}

impl std::fmt::Debug for Card {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Card")
            .field("device", &self.device.id)
            .field("door", &"<hidden>")
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Turn {
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
pub struct Work {
    pub request: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    pub partial: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Speech {
    pub id: Uuid,
    pub role: SpeechRole,
    pub peer: String,
    pub hue: f64,
    pub question: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilePart {
    pub name: String,
    pub size: u64,
    pub offset: u64,
    pub data: Bytes,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Secrets {
    #[serde(default, rename = "apiKey", skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    pub headers: BTreeMap<String, BTreeMap<String, String>>,
}

/// One step of an animation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Beat {
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
pub struct Sender {
    pub id: Uuid,
    pub name: String,
    pub hue: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TalkLine {
    pub id: Uuid,
    pub date: f64,
    pub asker: Sender,
    pub answerer: Sender,
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
        kind: Kind,
        key: Bytes,
        version: u32,
        proof: Bytes,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        join: Option<Bytes>,
    },
    Welcome {
        device: Uuid,
        name: String,
        kind: Kind,
        version: u32,
        linked: bool,
        proof: Bytes,
    },
    Ping {},
    Pong {},
    Bye {
        reason: String,
    },
    Routes {
        door: Bytes,
        routes: Routes,
    },
    Stage {
        imps: Vec<Staged>,
    },
    Pass {
        transfer: Uuid,
        imp: Imp,
        entry: Entry,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        home: Option<Card>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ticket: Option<Bytes>,
    },
    Took {
        transfer: Uuid,
    },
    Declined {
        transfer: Uuid,
        reason: Decline,
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
        feeling: Feeling,
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
        imp: Imp,
    },
    Chat {
        imp: Uuid,
        turns: Vec<Turn>,
    },
    Work {
        imp: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        work: Option<Work>,
    },
    Mood {
        imp: Uuid,
        mood: String,
    },
    Animate {
        imp: Uuid,
        beats: Vec<Beat>,
    },
    Speech {
        imp: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        speech: Option<Speech>,
    },
    FilePart {
        id: Uuid,
        part: FilePart,
    },
    FileFailed {
        id: Uuid,
        reason: String,
    },
    TalkLines {
        imp: Uuid,
        lines: Vec<TalkLine>,
    },
    Message {
        id: Uuid,
        from: Imp,
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
        secrets: Secrets,
        entry: Entry,
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

    /// The frame body as JSON bytes.
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("a link message always serializes")
    }

    /// Whether sizes and counts are sane. A node drops a message that is not.
    pub fn is_sound(&self) -> bool {
        let name = |s: &str| s.chars().count() <= LONGEST_NAME * 2;
        let text = |s: &str| s.chars().count() <= MAX_TEXT;
        let imp = |i: &Imp| name(&i.name);
        match self {
            Self::Hello {
                name: n,
                key,
                proof,
                join,
                ..
            } => {
                name(n)
                    && key.is_key()
                    && proof.0.len() == PROOF_BYTES
                    && join.as_ref().is_none_or(Bytes::is_key)
            }
            Self::Welcome { name: n, proof, .. } => name(n) && proof.0.len() == PROOF_BYTES,
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
            | Self::Speech { .. }
            | Self::Took { .. }
            | Self::Declined { .. }
            | Self::Adopted { .. } => true,
        }
    }
}

/// A frame cannot be sent or read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum FrameError {
    #[error("a frame of {0} bytes is bigger than any frame may be")]
    TooBig(usize),
}

/// Wraps a body in a frame: 4 bytes of length, big endian, then the body.
pub fn encode_frame(body: &[u8]) -> Result<Vec<u8>, FrameError> {
    if body.len() > MAX_FRAME {
        return Err(FrameError::TooBig(body.len()));
    }
    let length = u32::try_from(body.len()).map_err(|_| FrameError::TooBig(body.len()))?;
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(body);
    Ok(frame)
}

/// Collects bytes as they arrive and hands back whole frame bodies.
#[derive(Debug, Default)]
pub struct FrameReader {
    buffer: Vec<u8>,
}

impl FrameReader {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds bytes and returns every complete frame body. An error means a broken or hostile peer
    /// and the connection should be dropped.
    pub fn feed(&mut self, data: &[u8]) -> Result<Vec<Vec<u8>>, FrameError> {
        self.buffer.extend_from_slice(data);
        let mut frames = Vec::new();
        let mut start = 0;
        while self.buffer.len() - start >= 4 {
            let head = &self.buffer[start..start + 4];
            let length = u32::from_be_bytes([head[0], head[1], head[2], head[3]]) as usize;
            if length > MAX_FRAME {
                return Err(FrameError::TooBig(length));
            }
            if self.buffer.len() - start < 4 + length {
                break;
            }
            frames.push(self.buffer[start + 4..start + 4 + length].to_vec());
            start += 4 + length;
        }
        self.buffer.drain(..start);
        Ok(frames)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_split_and_join() {
        let one = encode_frame(b"{\"ping\":{}}").unwrap();
        let two = encode_frame(b"{\"pong\":{}}").unwrap();
        let all = [one.clone(), two.clone()].concat();
        let mut reader = FrameReader::new();
        let mut got = Vec::new();
        for byte in &all {
            got.extend(reader.feed(&[*byte]).unwrap());
        }
        assert_eq!(
            got,
            vec![b"{\"ping\":{}}".to_vec(), b"{\"pong\":{}}".to_vec()]
        );
        assert_eq!(FrameReader::new().feed(&all).unwrap().len(), 2);
        assert_eq!(one[..4], [0, 0, 0, 11]);
    }

    #[test]
    fn frames_have_a_ceiling() {
        let mut reader = FrameReader::new();
        let too_big = u32::try_from(MAX_FRAME + 1).unwrap().to_be_bytes();
        assert_eq!(
            reader.feed(&too_big),
            Err(FrameError::TooBig(MAX_FRAME + 1))
        );
        assert!(encode_frame(&vec![0; MAX_FRAME + 1]).is_err());
        assert!(encode_frame(&vec![0; MAX_FRAME]).is_ok());
    }

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
