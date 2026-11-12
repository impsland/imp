//! Imp Link for the apps: the sans-IO node of `imp-core` behind one object. The adapter feeds it what
//! happened (connections, bytes, time) and carries out the steps each call returns. Messages, devices
//! and cards travel as the same JSON the protocol uses, so the apps hold no second copy of any rule.

use imp_core::link::access::Standing;
use imp_core::link::card::{LinkCard, LinkDevice, LinkKind, LinkRoutes};
use imp_core::link::doors::{Bounce, Door};
use imp_core::link::hop::{HopAddress, HopClient, HopCredentials, HopStatus};
use imp_core::link::invite::LinkInvite;
use imp_core::link::messages::{
    Bytes, LinkEntry, LinkImp, LinkMessage, LinkSecrets, LinkSide, LinkStaged,
};
use imp_core::link::node::{Ask, Event, JoinError, Node, Options, Output, PassOutcome, Problem};
use imp_core::link::talks::First;
use imp_core::link::transfers::TransferKind;
use std::sync::{Arc, Mutex, MutexGuard};
use uuid::Uuid;

/// A readable reason a link call failed.
#[derive(Debug, uniffi::Error)]
pub enum LinkError {
    Failed { message: String },
}

impl std::fmt::Display for LinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for LinkError {}

fn failed(message: &str) -> LinkError {
    LinkError::Failed {
        message: message.to_string(),
    }
}

pub(crate) fn uuid(text: &str) -> Result<Uuid, LinkError> {
    Uuid::parse_str(text).map_err(|_| failed("That is not a device id."))
}

pub(crate) fn json<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

pub(crate) fn from_json<T: serde::de::DeserializeOwned>(text: &str) -> Result<T, LinkError> {
    serde_json::from_str(text).map_err(|_| failed("That is not a valid link message."))
}

fn kind_of(text: &str) -> Result<LinkKind, LinkError> {
    match text {
        "mac" => Ok(LinkKind::Mac),
        "phone" => Ok(LinkKind::Phone),
        _ => Err(failed("A device is a mac or a phone.")),
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkOptions {
    pub port: u16,
    pub ping_interval: f64,
    pub silence_limit: f64,
    pub visitor_grace: f64,
    pub invite_life: f64,
    pub handshake_timeout: f64,
    pub transfer_timeout: f64,
    pub answer_timeout: f64,
    pub retry_start: f64,
    pub retry_longest: f64,
    pub join_timeout: f64,
    pub frame_rate: f64,
    pub frame_burst: f64,
}

impl From<LinkOptions> for Options {
    fn from(o: LinkOptions) -> Self {
        Self {
            port: o.port,
            ping_interval: o.ping_interval,
            silence_limit: o.silence_limit,
            visitor_grace: o.visitor_grace,
            invite_life: o.invite_life,
            handshake_timeout: o.handshake_timeout,
            transfer_timeout: o.transfer_timeout,
            answer_timeout: o.answer_timeout,
            retry_start: o.retry_start,
            retry_longest: o.retry_longest,
            join_timeout: o.join_timeout,
            frame_rate: o.frame_rate,
            frame_burst: o.frame_burst,
        }
    }
}

impl From<Options> for LinkOptions {
    fn from(o: Options) -> Self {
        Self {
            port: o.port,
            ping_interval: o.ping_interval,
            silence_limit: o.silence_limit,
            visitor_grace: o.visitor_grace,
            invite_life: o.invite_life,
            handshake_timeout: o.handshake_timeout,
            transfer_timeout: o.transfer_timeout,
            answer_timeout: o.answer_timeout,
            retry_start: o.retry_start,
            retry_longest: o.retry_longest,
            join_timeout: o.join_timeout,
            frame_rate: o.frame_rate,
            frame_burst: o.frame_burst,
        }
    }
}

/// The protocol's own timings and port.
#[uniffi::export]
pub fn link_default_options() -> LinkOptions {
    Options::default().into()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkStanding {
    Peer,
    Visitor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkJoinFailure {
    NotRunning,
    ItsOwnCode,
    KeyChanged,
    Full,
    Unreachable,
    Refused,
    TimedOut,
}

impl From<JoinError> for LinkJoinFailure {
    fn from(e: JoinError) -> Self {
        match e {
            JoinError::NotRunning => Self::NotRunning,
            JoinError::ItsOwnCode => Self::ItsOwnCode,
            JoinError::KeyChanged => Self::KeyChanged,
            JoinError::Full => Self::Full,
            JoinError::Unreachable => Self::Unreachable,
            JoinError::Refused => Self::Refused,
            JoinError::TimedOut => Self::TimedOut,
        }
    }
}

/// Something that went wrong that a person may want to hear about.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LinkTrouble {
    Listener { reason: String },
    Storage { reason: String },
    Refused { device: String },
    KeyChanged { device: String },
    Hop,
    InviteRefused { device: String },
    Full { what: String },
}

/// What the adapter is asked to do, or told happened, after a call.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LinkStep {
    /// Write these bytes to the connection.
    Send {
        conn: u64,
        bytes: Vec<u8>,
    },
    Close {
        conn: u64,
    },
    /// Reach a device: Bonjour, then its hosts, then its Hop. `card` is JSON.
    Dial {
        device: String,
        card: String,
    },
    /// Store the book where only this user can read it.
    Save {
        bytes: Vec<u8>,
    },
    /// The door key changed: listen again.
    Relisten,
    /// The Hop host needs its room or port changed (see `hop_host`).
    HopChanged,
    Connected {
        device: String,
        standing: LinkStanding,
    },
    Disconnected {
        device: String,
    },
    Linked {
        device: String,
    },
    Forgotten {
        device: String,
        called_home: Vec<String>,
        sent_home: Vec<String>,
    },
    /// A message for the app. `message` is JSON.
    Message {
        message: String,
        from: String,
    },
    Passed {
        transfer: String,
        imp: String,
        to: String,
        adopt: bool,
        took: bool,
        /// The reason, when it was declined.
        decline: Option<String>,
    },
    Joined {
        device: String,
        linked: bool,
        failure: Option<LinkJoinFailure>,
    },
    Problem {
        problem: LinkTrouble,
    },
}

fn ids(list: &[Uuid]) -> Vec<String> {
    list.iter().map(Uuid::to_string).collect()
}

fn step_of(output: Output) -> LinkStep {
    match output {
        Output::Send { conn, bytes } => LinkStep::Send { conn, bytes },
        Output::Close { conn } => LinkStep::Close { conn },
        Output::Dial(d) => LinkStep::Dial {
            device: d.device.to_string(),
            card: json(&d.card),
        },
        Output::Save(bytes) => LinkStep::Save { bytes },
        Output::Relisten => LinkStep::Relisten,
        Output::HopChanged => LinkStep::HopChanged,
        Output::Event(event) => match event {
            Event::Connected(device, standing) => LinkStep::Connected {
                device: json(&device),
                standing: match standing {
                    Standing::Peer => LinkStanding::Peer,
                    Standing::Visitor => LinkStanding::Visitor,
                },
            },
            Event::Disconnected(id) => LinkStep::Disconnected {
                device: id.to_string(),
            },
            Event::Linked(device) => LinkStep::Linked {
                device: json(&device),
            },
            Event::Forgotten(id, f) => LinkStep::Forgotten {
                device: id.to_string(),
                called_home: ids(&f.called_home),
                sent_home: ids(&f.sent_home),
            },
            Event::Message(message, from) => LinkStep::Message {
                message: json(&message),
                from: from.to_string(),
            },
            Event::Passed(p) => LinkStep::Passed {
                transfer: p.transfer.to_string(),
                imp: p.imp.to_string(),
                to: p.to.to_string(),
                adopt: p.kind == TransferKind::Adopt,
                took: p.outcome == PassOutcome::Took,
                decline: match p.outcome {
                    PassOutcome::Took => None,
                    PassOutcome::Declined(d) => Some(json(&d).trim_matches('"').to_string()),
                },
            },
            Event::Joined { device, result } => LinkStep::Joined {
                device: device.to_string(),
                linked: result.is_ok(),
                failure: result.err().map(Into::into),
            },
            Event::Problem(p) => LinkStep::Problem {
                problem: match p {
                    Problem::Listener(reason) => LinkTrouble::Listener { reason },
                    Problem::Storage(reason) => LinkTrouble::Storage { reason },
                    Problem::Refused(id) => LinkTrouble::Refused {
                        device: id.to_string(),
                    },
                    Problem::KeyChanged(id) => LinkTrouble::KeyChanged {
                        device: id.to_string(),
                    },
                    Problem::Hop => LinkTrouble::Hop,
                    Problem::InviteRefused(id) => LinkTrouble::InviteRefused {
                        device: id.to_string(),
                    },
                    Problem::Full(what) => LinkTrouble::Full {
                        what: what.to_string(),
                    },
                },
            },
        },
    }
}

/// What a call answered, with the steps it asked for.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkOutcome {
    pub ok: bool,
    /// An id the call made (a transfer, for example).
    pub id: Option<String>,
    /// A connection the call opened.
    pub conn: Option<u64>,
    pub steps: Vec<LinkStep>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkBounce {
    NobodyConnected,
    WayBackIsClosed,
    NowhereElse,
}

/// Where a thrown Imp goes: to a device, or back (`bounce`).
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkDoor {
    pub device: Option<String>,
    pub bounce: Option<LinkBounce>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkBand {
    pub device: String,
    pub top: f64,
    pub bottom: f64,
}

/// Where a question from an Imp goes first.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum LinkFirst {
    Here,
    Via { device: String },
    Unreachable,
}

#[derive(Clone, uniffi::Record)]
pub struct LinkHopHost {
    pub address: String,
    pub client: Arc<LinkHopClient>,
}

fn side_of(text: &str) -> Result<LinkSide, LinkError> {
    from_json(&format!("\"{text}\""))
}

/// A device's whole part in Imp Link.
#[derive(uniffi::Object)]
pub struct LinkCore {
    node: Mutex<Node>,
}

impl LinkCore {
    fn lock(&self) -> MutexGuard<'_, Node> {
        self.node
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn done(mut node: MutexGuard<'_, Node>) -> Vec<LinkStep> {
        node.drain().into_iter().map(step_of).collect()
    }

    fn outcome(
        mut node: MutexGuard<'_, Node>,
        ok: bool,
        id: Option<Uuid>,
        conn: Option<u64>,
    ) -> LinkOutcome {
        let steps = node.drain().into_iter().map(step_of).collect();
        LinkOutcome {
            ok,
            id: id.map(|i| i.to_string()),
            conn,
            steps,
        }
    }
}

#[uniffi::export]
impl LinkCore {
    /// A node for this device. `saved` is the stored book, nil on the first run. The first steps (the
    /// book to store) come from `steps`.
    #[uniffi::constructor]
    pub fn new(
        saved: Option<Vec<u8>>,
        name: String,
        kind: String,
        id: String,
        options: LinkOptions,
    ) -> Result<Arc<Self>, LinkError> {
        let node = Node::new(
            saved.as_deref(),
            &name,
            kind_of(&kind)?,
            uuid(&id)?,
            options.into(),
        )
        .map_err(|_| failed("The saved links could not be read."))?;
        Ok(Arc::new(Self {
            node: Mutex::new(node),
        }))
    }

    /// Everything the node wants done since the last call.
    pub fn steps(&self) -> Vec<LinkStep> {
        Self::done(self.lock())
    }

    pub fn book_bytes(&self) -> Vec<u8> {
        self.lock().book_bytes()
    }

    pub fn device(&self) -> String {
        json(&self.lock().device())
    }

    pub fn card(&self) -> String {
        json(&self.lock().card())
    }

    pub fn links(&self) -> String {
        json(&self.lock().links())
    }

    pub fn visits(&self) -> String {
        json(&self.lock().visits().visits())
    }

    /// The Imps of this device that are away, with the device holding each.
    pub fn away(&self) -> String {
        json(&self.lock().away().entries())
    }

    /// The Imps of this device that `device` holds.
    pub fn held_by(&self, device: String) -> Result<Vec<String>, LinkError> {
        Ok(ids(&self.lock().away().held_by(uuid(&device)?)))
    }

    pub fn is_running(&self) -> bool {
        self.lock().is_running()
    }

    pub fn connected(&self) -> Vec<String> {
        ids(&self.lock().connected())
    }

    pub fn connected_peers(&self) -> String {
        json(&self.lock().connected_peers())
    }

    pub fn standing_of(&self, device: String) -> Result<Option<LinkStanding>, LinkError> {
        Ok(self.lock().standing_of(uuid(&device)?).map(|s| match s {
            Standing::Peer => LinkStanding::Peer,
            Standing::Visitor => LinkStanding::Visitor,
        }))
    }

    pub fn is_connected(&self, device: String) -> Result<bool, LinkError> {
        Ok(self.lock().is_connected(uuid(&device)?))
    }

    pub fn is_through_hop(&self, device: String) -> Result<bool, LinkError> {
        Ok(self.lock().is_through_hop(uuid(&device)?))
    }

    pub fn stage_of(&self, device: String) -> Result<String, LinkError> {
        Ok(json(&self.lock().stage_of(uuid(&device)?)))
    }

    pub fn travel_of(&self, imp: String) -> Result<String, LinkError> {
        Ok(json(&self.lock().travel_of(uuid(&imp)?)))
    }

    pub fn door_of(&self, imp: String, side: String, height: f64) -> Result<LinkDoor, LinkError> {
        Ok(
            match self.lock().door_of(uuid(&imp)?, side_of(&side)?, height) {
                Door::To(id) => LinkDoor {
                    device: Some(id.to_string()),
                    bounce: None,
                },
                Door::Bounce(b) => LinkDoor {
                    device: None,
                    bounce: Some(match b {
                        Bounce::NobodyConnected => LinkBounce::NobodyConnected,
                        Bounce::WayBackIsClosed => LinkBounce::WayBackIsClosed,
                        Bounce::NowhereElse => LinkBounce::NowhereElse,
                    }),
                },
            },
        )
    }

    pub fn bands_of(&self, imp: String, side: String) -> Result<Vec<LinkBand>, LinkError> {
        Ok(self
            .lock()
            .bands_of(uuid(&imp)?, side_of(&side)?)
            .into_iter()
            .map(|b| LinkBand {
                device: b.device.to_string(),
                top: b.top,
                bottom: b.bottom,
            })
            .collect())
    }

    pub fn holder_of(&self, imp: String) -> Result<Option<String>, LinkError> {
        Ok(self.lock().holder_of(uuid(&imp)?).map(|i| i.to_string()))
    }

    pub fn rename(&self, name: String) {
        self.lock().rename(&name);
    }

    pub fn set_trusted(&self, device: String, on: bool) -> Result<Vec<LinkStep>, LinkError> {
        let mut node = self.lock();
        node.set_trusted(uuid(&device)?, on);
        Ok(Self::done(node))
    }

    pub fn is_trusted(&self, device: String) -> Result<bool, LinkError> {
        Ok(self.lock().is_trusted(uuid(&device)?))
    }

    /// Whether the app may act on this message from this device.
    pub fn is_trusted_message(&self, message: String, device: String) -> Result<bool, LinkError> {
        let message: LinkMessage = from_json(&message)?;
        Ok(self.lock().is_trusted_message(&message, uuid(&device)?))
    }

    pub fn set_hosts(&self, hosts: Vec<String>) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.set_hosts(hosts);
        Self::done(node)
    }

    pub fn set_port(&self, port: Option<u16>) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.set_port(port);
        Self::done(node)
    }

    /// Sets the Hop (`host:port`) or clears it. False when the text is not a Hop address.
    pub fn set_server(&self, address: Option<String>) -> LinkOutcome {
        let mut node = self.lock();
        let parsed = address.as_deref().map(HopAddress::parse);
        let ok = !matches!(parsed, Some(None));
        if ok {
            node.set_server(parsed.flatten());
        }
        Self::outcome(node, ok, None, None)
    }

    /// The Imps on this device's screen (JSON list of staged Imps).
    pub fn set_stage(&self, imps: String) -> Result<Vec<LinkStep>, LinkError> {
        let imps: Vec<LinkStaged> = from_json(&imps)?;
        let mut node = self.lock();
        node.set_stage(imps);
        Ok(Self::done(node))
    }

    pub fn start(&self, now: f64) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.start(now);
        Self::done(node)
    }

    pub fn stop(&self, now: f64) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.stop(now);
        Self::done(node)
    }

    pub fn tick(&self, now: f64) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.tick(now);
        Self::done(node)
    }

    pub fn listener_failed(&self, reason: String) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.listener_failed(&reason);
        Self::done(node)
    }

    pub fn save_failed(&self, reason: String) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.save_failed(&reason);
        Self::done(node)
    }

    pub fn hop_rejected(&self) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.hop_rejected();
        Self::done(node)
    }

    /// Where this device waits at its Hop, and the client to speak to the relay with. Nil without a Hop.
    pub fn hop_host(&self) -> Option<LinkHopHost> {
        let (address, credentials, _) = self.lock().hop_host()?;
        Some(LinkHopHost {
            address: address.text(),
            client: Arc::new(LinkHopClient::new(credentials)),
        })
    }

    /// How many seconds the Hop host waits before reconnecting after a failed try, given the wait
    /// before it (0 after a success).
    pub fn hop_retry_delay(&self, previous: f64) -> f64 {
        self.lock().hop_retry_delay(previous)
    }

    /// A connection came in. `conn` is nil when it must be closed.
    pub fn accepted(&self, via_hop: bool, now: f64) -> LinkOutcome {
        let mut node = self.lock();
        let conn = node.accepted(via_hop, now);
        Self::outcome(node, conn.is_some(), None, conn)
    }

    /// A connection to `device` opened. `conn` is nil when it is no longer wanted.
    pub fn dialed(
        &self,
        device: String,
        via_hop: bool,
        now: f64,
    ) -> Result<LinkOutcome, LinkError> {
        let mut node = self.lock();
        let conn = node.dialed(uuid(&device)?, via_hop, now);
        Ok(Self::outcome(node, conn.is_some(), None, conn))
    }

    pub fn closed(&self, conn: u64, now: f64) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.closed(conn, now);
        Self::done(node)
    }

    pub fn received(&self, conn: u64, data: Vec<u8>, now: f64) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.received(conn, &data, now);
        Self::done(node)
    }

    pub fn dial_failed(&self, device: String, now: f64) -> Result<Vec<LinkStep>, LinkError> {
        let mut node = self.lock();
        node.dial_failed(uuid(&device)?, now);
        Ok(Self::done(node))
    }

    /// Dial again now: `devices` were found on the local network, or nil when the network changed.
    pub fn kick(&self, devices: Option<Vec<String>>, now: f64) -> Result<Vec<LinkStep>, LinkError> {
        let found = devices
            .map(|d| d.iter().map(|i| uuid(i)).collect::<Result<Vec<_>, _>>())
            .transpose()?;
        let mut node = self.lock();
        node.kick(found.as_deref(), now);
        Ok(Self::done(node))
    }

    /// Sends a message (JSON) to a connected device. `ok` is false when it could not be sent.
    pub fn send(&self, message: String, to: String) -> Result<LinkOutcome, LinkError> {
        let message: LinkMessage = from_json(&message)?;
        let mut node = self.lock();
        let ok = node.send(&message, uuid(&to)?);
        Ok(Self::outcome(node, ok, None, None))
    }

    /// An Imp asks another.
    pub fn talk(&self, question: LinkQuestion, now: f64) -> Result<LinkTalk, LinkError> {
        let from: LinkImp = from_json(&question.from)?;
        let ask = Ask {
            id: uuid(&question.id)?,
            from,
            to: uuid(&question.to)?,
            to_home: uuid(&question.to_home)?,
            text: &question.text,
            holder: uuid(&question.holder)?,
        };
        let mut node = self.lock();
        let first = match node.talk(ask, now) {
            First::Here => LinkFirst::Here,
            First::Via(d) => LinkFirst::Via {
                device: d.to_string(),
            },
            First::Unreachable => LinkFirst::Unreachable,
        };
        let steps = Self::done(node);
        Ok(LinkTalk { first, steps })
    }

    /// A new invite to show. Earlier ones stop working.
    pub fn invite(&self, now: f64) -> LinkInviteInfo {
        let mut node = self.lock();
        let invite = node.invite(now);
        LinkInviteInfo::of(&invite)
    }

    /// The code was taken off the screen.
    pub fn invite_hidden(&self, now: f64) {
        self.lock().invite_hidden(now);
    }

    /// Joins the host an invite names (its URL). The result comes as a `Joined` step.
    pub fn join(&self, invite: String, now: f64) -> Result<Vec<LinkStep>, LinkError> {
        let invite =
            LinkInvite::parse(&invite).ok_or_else(|| failed("That code is not an Imp invite."))?;
        let mut node = self.lock();
        node.join(&invite, now);
        Ok(Self::done(node))
    }

    pub fn forget(&self, device: String, now: f64) -> Result<Vec<LinkStep>, LinkError> {
        let mut node = self.lock();
        node.forget(uuid(&device)?, now);
        Ok(Self::done(node))
    }

    pub fn forget_everyone(&self, now: f64) -> Vec<LinkStep> {
        let mut node = self.lock();
        node.forget_everyone(now);
        Self::done(node)
    }

    /// Throws an Imp (JSON) to a connected peer. `id` is the transfer.
    pub fn pass(
        &self,
        imp: String,
        entry: String,
        to: String,
        now: f64,
    ) -> Result<LinkOutcome, LinkError> {
        let imp: LinkImp = from_json(&imp)?;
        let entry: LinkEntry = from_json(&entry)?;
        let mut node = self.lock();
        let transfer = node.pass(&imp, entry, uuid(&to)?, now);
        Ok(Self::outcome(node, transfer.is_some(), transfer, None))
    }

    /// Moves an Imp hatched here to a peer for good.
    pub fn adopt(
        &self,
        imp: String,
        kit: String,
        secrets: String,
        entry: String,
        to: String,
        now: f64,
    ) -> Result<LinkOutcome, LinkError> {
        let secrets: LinkSecrets = from_json(&secrets)?;
        let entry: LinkEntry = from_json(&entry)?;
        let mut node = self.lock();
        let transfer = node.adopt(uuid(&imp)?, &kit, secrets, entry, uuid(&to)?, now);
        Ok(Self::outcome(node, transfer.is_some(), transfer, None))
    }

    pub fn can_accept(&self, transfer: String) -> Result<bool, LinkError> {
        Ok(self.lock().can_accept(uuid(&transfer)?))
    }

    pub fn accept(&self, transfer: String, now: f64) -> Result<LinkOutcome, LinkError> {
        let mut node = self.lock();
        let ok = node.accept(uuid(&transfer)?, now);
        Ok(Self::outcome(node, ok, None, None))
    }

    pub fn decline(&self, transfer: String, reason: String) -> Result<Vec<LinkStep>, LinkError> {
        let reason = from_json(&format!("\"{reason}\""))?;
        let mut node = self.lock();
        node.decline(uuid(&transfer)?, reason);
        Ok(Self::done(node))
    }

    /// Takes an Imp back from its holder. `id` is the holder, if it was away.
    pub fn call_home(&self, imp: String) -> Result<LinkOutcome, LinkError> {
        let mut node = self.lock();
        let holder = node.call_home(uuid(&imp)?);
        Ok(Self::outcome(node, holder.is_some(), holder, None))
    }

    /// Sends a visiting Imp home from here.
    pub fn send_home(&self, imp: String, now: f64) -> Result<LinkOutcome, LinkError> {
        let mut node = self.lock();
        let ok = node.send_home(uuid(&imp)?, now);
        Ok(Self::outcome(node, ok, None, None))
    }
}

/// A question from an Imp of this device to another.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkQuestion {
    pub id: String,
    /// The asking Imp (JSON).
    pub from: String,
    /// The Imp asked, and the device that is its home.
    pub to: String,
    pub to_home: String,
    pub text: String,
    /// Where the asking Imp's body is (this device when at home).
    pub holder: String,
}

/// The first leg of a question, with the steps it asked for.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkTalk {
    pub first: LinkFirst,
    pub steps: Vec<LinkStep>,
}

/// An invite as the person sees it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkInviteInfo {
    /// The link the QR code holds.
    pub url: String,
    /// The host (JSON).
    pub device: String,
}

impl LinkInviteInfo {
    fn of(invite: &LinkInvite) -> Self {
        Self {
            url: invite.url(),
            device: json(&invite.device),
        }
    }
}

/// Reads an invite pasted or scanned. Nil unless it is whole and valid.
#[uniffi::export]
pub fn link_parse_invite(text: String) -> Option<LinkInviteInfo> {
    LinkInvite::parse(&text).map(|i| LinkInviteInfo::of(&i))
}

/// Makes an invite from a host's device (JSON), its door and invite keys and its routes (JSON).
#[uniffi::export]
pub fn link_make_invite(
    device: String,
    door: Vec<u8>,
    invite: Vec<u8>,
    routes: String,
) -> Result<LinkInviteInfo, LinkError> {
    let device: LinkDevice = from_json(&device)?;
    let routes: LinkRoutes = from_json(&routes)?;
    let made = LinkInvite {
        device,
        door: Bytes(door),
        invite: Bytes(invite),
        routes,
    };
    let info = LinkInviteInfo::of(&made);
    LinkInvite::parse(&info.url).ok_or_else(|| failed("Those values do not make an invite."))?;
    Ok(info)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkHopStatus {
    /// The other side is spliced in: the link's bytes follow.
    Go,
    /// Bad hello or proof: give up on the Hop for now.
    Rejected,
    /// A limit was hit: back off.
    Busy,
    /// Nobody came before the wait ran out, or nobody is waiting.
    Nobody,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkHopProgress {
    pub reply: Vec<u8>,
    pub status: Option<LinkHopStatus>,
    pub rest: Vec<u8>,
}

/// The Hop handshake: hello, nonce, proof, status.
#[derive(uniffi::Object)]
pub struct LinkHopClient {
    client: Mutex<HopClient>,
}

impl LinkHopClient {
    fn new(credentials: HopCredentials) -> Self {
        Self {
            client: Mutex::new(HopClient::new(credentials)),
        }
    }
}

#[uniffi::export]
impl LinkHopClient {
    /// The bytes to send as soon as the connection is up.
    pub fn hello(&self) -> Vec<u8> {
        self.client
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .hello()
    }

    /// What the relay sent. Send `reply` back. Once `status` is set the handshake is over.
    pub fn feed(&self, data: Vec<u8>) -> Result<LinkHopProgress, LinkError> {
        let progress = self
            .client
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .feed(&data)
            .map_err(|_| failed("The server did not answer the way an Imp server does."))?;
        Ok(LinkHopProgress {
            reply: progress.reply,
            status: progress.status.map(|s| match s {
                HopStatus::Go => LinkHopStatus::Go,
                HopStatus::Rejected => LinkHopStatus::Rejected,
                HopStatus::Busy => LinkHopStatus::Busy,
                HopStatus::Nobody => LinkHopStatus::Nobody,
            }),
            rest: progress.rest,
        })
    }
}

/// A guest's client for the Hop room of the host this card names.
#[uniffi::export]
pub fn link_hop_guest(card: String) -> Result<Arc<LinkHopClient>, LinkError> {
    let card: LinkCard = from_json(&card)?;
    let room: [u8; 32] = card
        .device
        .room
        .0
        .as_slice()
        .try_into()
        .map_err(|_| failed("That device has no room."))?;
    let door: [u8; 32] = card
        .door
        .0
        .as_slice()
        .try_into()
        .map_err(|_| failed("That device has no door."))?;
    Ok(Arc::new(LinkHopClient::new(HopCredentials::guest(
        room, &door,
    ))))
}

/// Whether text is a Hop address (`host:port`), written the way the Hop wants it.
#[uniffi::export]
pub fn link_hop_address(text: String) -> Option<String> {
    HopAddress::parse(&text).map(|a| a.text())
}

/// The protocol's constants the adapters need.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkLimits {
    pub service_type: String,
    pub port: u16,
    pub max_frame: u64,
    pub max_text: u64,
}

#[uniffi::export]
pub fn link_limits() -> LinkLimits {
    LinkLimits {
        service_type: imp_core::link::SERVICE_TYPE.to_string(),
        port: imp_core::link::PORT,
        max_frame: imp_core::link::MAX_FRAME as u64,
        max_text: imp_core::link::messages::MAX_TEXT as u64,
    }
}

/// Where a piece of text sits (bytes).
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkRange {
    pub start: u64,
    pub end: u64,
}

/// Where each file reference sits in a reply (byte offsets).
#[uniffi::export]
pub fn link_reference_ranges(text: String) -> Vec<LinkRange> {
    imp_core::link::files::reference_ranges(&text)
        .into_iter()
        .map(|r| LinkRange {
            start: r.start as u64,
            end: r.end as u64,
        })
        .collect()
}

/// Whether a file reference points at the web.
#[uniffi::export]
pub fn link_is_web(reference: String) -> bool {
    imp_core::link::files::is_web(&reference)
}

/// The Imps an Imp may talk to: its home's and the screen's, never itself. Lists are JSON.
#[uniffi::export]
pub fn link_talk_targets(asker: String, mine: String, stage: String) -> Result<String, LinkError> {
    let mine: Vec<LinkStaged> = from_json(&mine)?;
    let stage: Vec<LinkStaged> = from_json(&stage)?;
    Ok(json(&imp_core::link::talks::targets(
        uuid(&asker)?,
        &mine,
        &stage,
    )))
}
