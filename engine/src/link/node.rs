//! A device's whole part in Imp Link (`docs/connecting/link.md`), without any I/O. The node is a state
//! machine. The adapter feeds it what happened (a connection came in, bytes arrived, a connection closed,
//! a dial failed, time passed) and carries out what it asks for (bytes to write, connections to close,
//! devices to dial, the book to save, events for the app). It decides who may talk to whom, keeps the book,
//! the away ledger and the visits, and runs the handshake and the encrypted stream with `noise`.
//!
//! Nothing here reads a clock: every call that depends on time takes `now`, in seconds. Nothing here
//! panics on what a peer sends: every connection that misbehaves is closed.

use crate::link::access::{self, Standing};
use crate::link::book::{BookError, Handed, LinkBook, LinkRecord, MAX_HANDED, Passing};
use crate::link::card::{LinkCard, LinkDevice, LinkKind, LinkRoutes};
use crate::link::crypto::{self, Key};
use crate::link::doors::{self, Band, Door, LinkTravel};
use crate::link::frames::{FrameReader, encode_frame};
use crate::link::hop::{HopAddress, HopCredentials};
use crate::link::identity::Identity;
use crate::link::invite::LinkInvite;
use crate::link::ledger::Claim;
use crate::link::messages::{
    Bytes, Decoded, LinkDecline, LinkEntry, LinkImp, LinkMessage, LinkSecrets, LinkSide,
    LinkStaged, LinkWho, MAX_TEXT,
};
use crate::link::noise::{ChunkReader, Handshake, Secure};
use crate::link::talks::{self, First, Pending};
use crate::link::transfers::{Received, Reply, TransferKind, Transfers};
use crate::link::uploads::{self, MAX_PART, MAX_UPLOAD, Upload, Uploads};
use crate::link::{
    INVITE_LIFE, MAX_CONNECTIONS, MAX_LINKS, PING_INTERVAL, PORT, SILENCE_LIMIT, VISITOR_GRACE,
};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use uuid::Uuid;

/// Seconds, from any steady starting point the adapter picks for the live clock (the book keeps wall
/// clock seconds since 1970, so use that).
pub type Time = f64;

/// What the adapter calls one of its connections.
pub type ConnId = u64;

/// What a `bye` with this reason means: the other side forgot us.
pub const FORGOTTEN: &str = "forgotten";
/// What an Imp hears when its question cannot be answered.
pub const UNREACHABLE: &str = "That Imp can't be reached right now.";
/// What an Imp hears when too many questions are waiting.
pub const BUSY: &str = "Too many questions are waiting. Try again in a moment.";
/// What an Imp hears when it asks across devices and the other device doesn't count its device as the
/// owner's: the fix is on that device.
pub const NOT_MINE: &str = "That Imp's device doesn't count this one as yours: turn on Mine for this device in Devices there.";
/// How many thrown Imps one device may have waiting for the app at once.
const WAITING_PER_SENDER: usize = 8;

#[derive(Debug, Clone)]
pub struct Options {
    /// The port the adapter listens on when it can.
    pub port: u16,
    pub ping_interval: f64,
    pub silence_limit: f64,
    pub visitor_grace: f64,
    /// How long an invite works after its code was last on screen.
    pub invite_life: f64,
    /// How long a connection may take to finish its handshake.
    pub handshake_timeout: f64,
    pub transfer_timeout: f64,
    pub answer_timeout: f64,
    /// How long to wait before redialling a device that cannot be reached, doubling up to the longest.
    pub retry_start: f64,
    pub retry_longest: f64,
    /// How long `join` waits for the host.
    pub join_timeout: f64,
    /// How many frames a connection may send per second, and in one burst. More closes it.
    pub frame_rate: f64,
    pub frame_burst: f64,
}

impl Options {
    /// The wait after `previous` (0 before the first failure): doubled, at least the start and
    /// at most the longest. Used for redialling a device and for the Hop host's reconnects.
    pub fn next_retry(&self, previous: f64) -> f64 {
        (previous * 2.0)
            .max(self.retry_start)
            .min(self.retry_longest)
    }
}

impl Default for Options {
    fn default() -> Self {
        Self {
            port: PORT,
            ping_interval: PING_INTERVAL,
            silence_limit: SILENCE_LIMIT,
            visitor_grace: VISITOR_GRACE,
            invite_life: INVITE_LIFE,
            handshake_timeout: 10.0,
            transfer_timeout: crate::link::transfers::TRANSFER_TIMEOUT,
            answer_timeout: talks::ANSWER_TIMEOUT,
            retry_start: 1.0,
            retry_longest: 60.0,
            join_timeout: 30.0,
            frame_rate: 100.0,
            frame_burst: 400.0,
        }
    }
}

/// An Imp that was thrown, and how it ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Passed {
    pub transfer: Uuid,
    pub imp: Uuid,
    pub to: Uuid,
    pub kind: TransferKind,
    pub outcome: PassOutcome,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PassOutcome {
    Took,
    Declined(LinkDecline),
}

/// Something that went wrong that a person may want to hear about. Never carries secrets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Problem {
    /// The adapter could not listen.
    Listener(String),
    /// The book could not be saved.
    Storage(String),
    /// The device answered but the handshake failed: it forgot everyone, or it runs a different version of
    /// Imp. The app asks the user to update both devices, as it does for the other causes.
    Refused(Uuid),
    /// The device presented another key than the one pinned for it.
    KeyChanged(Uuid),
    /// The Hop turned this device's room away.
    Hop,
    /// A code was refused: it expired, or the host forgot it.
    InviteRefused(Uuid),
    /// A limit (links, visits, connections) was hit.
    Full(&'static str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JoinError {
    NotRunning,
    ItsOwnCode,
    /// The device is already linked with another key.
    KeyChanged,
    Full,
    /// No route to the host worked.
    Unreachable,
    /// The host answered but would not link (the code expired, or was replaced).
    Refused,
    TimedOut,
}

/// What `forget` did to the Imps involved, for the app to show.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Forgotten {
    /// Imps of this device the forgotten device held, taken back home.
    pub called_home: Vec<Uuid>,
    /// Imps visiting this device whose home was forgotten. They go home, so their bodies go.
    pub sent_home: Vec<Uuid>,
}

// Events are short-lived: each one is handed to the adapter at once, so boxing the large ones would
// only add allocations.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// A handshake finished: the device is connected, as a peer or a visitor.
    Connected(LinkDevice, Standing),
    Disconnected(Uuid),
    /// A link was made (a device scanned our code, or we scanned its).
    Linked(LinkDevice),
    /// The other side forgot us: the link is gone on this side too, our Imps it held are called home and
    /// the Imps of its that visited us are sent home (the app removes those bodies).
    Forgotten(Uuid, Forgotten),
    /// A message the node did not deal with itself, from a device allowed to send it. `stage`, `claim` and
    /// `release` arrive after the node updated its books.
    Message(LinkMessage, Uuid),
    /// A thrown Imp was answered or timed out.
    Passed(Passed),
    /// A `join` ended.
    Joined {
        device: Uuid,
        result: Result<LinkDevice, JoinError>,
    },
    Problem(Problem),
}

/// A device to reach. The adapter tries Bonjour first, then `card.routes.hosts` on `card.routes.port`, and
/// the Hop last (`card.routes.hop`), and for each connection that opens calls `Node::dialed`. When no
/// route worked it calls `Node::dial_failed`.
#[derive(Debug, Clone, PartialEq)]
pub struct DialRequest {
    pub device: Uuid,
    pub card: LinkCard,
}

// Outputs are handled at once, not stored.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq)]
pub enum Output {
    /// Write these bytes to the connection.
    Send {
        conn: ConnId,
        bytes: Vec<u8>,
    },
    /// Close the connection.
    Close {
        conn: ConnId,
    },
    Dial(DialRequest),
    /// Store the book (`Node::book_bytes`) where only this user can read it. Only the last one matters.
    Save(Vec<u8>),
    /// The door key changed: listen again, so no old connection stays.
    Relisten,
    /// What the Hop host needs changed (see `Node::hop_host`).
    HopChanged,
    Event(Event),
}

enum Phase {
    Handshake(Box<Handshake>),
    Secure(Box<Secure>),
    Dead,
}

#[derive(Clone)]
struct DialTarget {
    card: LinkCard,
    /// The invite key, if this is a join.
    join: Option<Key>,
}

struct Conn {
    target: Option<DialTarget>,
    via_hop: bool,
    phase: Phase,
    chunks: ChunkReader,
    frames: FrameReader,
    hash: Vec<u8>,
    remote_static: Option<Key>,
    remote: Option<LinkDevice>,
    standing: Option<Standing>,
    established: bool,
    superseded: bool,
    /// Closed by the node for taking too long, not by the other side.
    timed_out: bool,
    established_at: Time,
    handshake_deadline: Option<Time>,
    /// A visitor must claim a ticket before this.
    grace_deadline: Option<Time>,
    /// Claims sent and not answered yet (a second claim with the same ticket would be refused).
    claiming: BTreeSet<Uuid>,
    last_heard: Time,
    last_ping: Time,
    tokens: f64,
    refilled: Time,
}

impl Conn {
    /// Takes a frame's token. False when the other side is sending faster than it may.
    fn admit(&mut self, rate: f64, burst: f64, now: Time) -> bool {
        self.tokens = burst.min(self.tokens + (now - self.refilled).max(0.0) * rate);
        self.refilled = now;
        if self.tokens < 1.0 {
            return false;
        }
        self.tokens -= 1.0;
        true
    }
}

struct Dial {
    wait_until: Time,
    in_flight: bool,
    /// A connection to it answered the handshake wrongly, so no other route will do better.
    refused: bool,
}

struct Join {
    invite: LinkInvite,
    deadline: Time,
}

enum ArrivalKind {
    Pass(Box<PassArrival>),
    Adopt,
}

/// What came with an Imp that was thrown here.
struct PassArrival {
    imp: LinkImp,
    entry: LinkEntry,
    home: Option<LinkCard>,
    ticket: Option<Vec<u8>>,
}

/// An Imp (or one that wants to move in) that was thrown here and waits for the app's answer.
struct Arrival {
    from: Uuid,
    kind: ArrivalKind,
}

/// A question from an Imp of this device to another, for `Node::talk`.
pub struct Ask<'a> {
    pub id: Uuid,
    /// The asking Imp.
    pub from: LinkImp,
    /// The Imp asked, and the device that is its home.
    pub to: Uuid,
    pub to_home: Uuid,
    pub text: &'a str,
    /// Where the asking Imp's body is (this device when at home).
    pub holder: Uuid,
}

pub struct Node {
    options: Options,
    identity: Identity,
    book: LinkBook,
    dirty: bool,
    running: bool,
    invite_on_screen: bool,
    transfers: Transfers,
    talks: Pending,
    uploads: Uploads,
    stages: BTreeMap<Uuid, Vec<LinkStaged>>,
    own_stage: Vec<LinkStaged>,
    arrivals: BTreeMap<Uuid, Arrival>,
    hop: Option<HopAddress>,
    published: BTreeMap<Uuid, LinkRoutes>,
    hosts: Vec<String>,
    port: Option<u16>,
    next_conn: ConnId,
    conns: BTreeMap<ConnId, Conn>,
    connections: BTreeMap<Uuid, ConnId>,
    dials: BTreeMap<Uuid, Dial>,
    delays: BTreeMap<Uuid, f64>,
    /// Devices whose refusal was already reported, so a retry does not repeat it.
    reported: BTreeSet<Uuid>,
    joins: BTreeMap<Uuid, Join>,
    out: VecDeque<Output>,
}

fn key_of(bytes: &Bytes) -> Option<Key> {
    bytes.0.as_slice().try_into().ok()
}

impl Node {
    /// A node for this device. The book is read from `saved`, or made (with a fresh key) on the first run,
    /// when `id` is the device's id. An error means a book exists but cannot be read.
    pub fn new(
        saved: Option<&[u8]>,
        name: &str,
        kind: LinkKind,
        id: Uuid,
        options: Options,
    ) -> Result<Self, BookError> {
        let mut out = VecDeque::new();
        let (identity, book) = match saved {
            Some(bytes) => {
                let book = LinkBook::read(bytes)?;
                let seed = key_of(&book.seed).ok_or(BookError)?;
                (Identity::from_seed(book.device, name, kind, seed), book)
            }
            None => {
                let identity = Identity::new(id, name, kind);
                let book = LinkBook::new(id, *identity.seed(), crypto::random_key());
                out.push_back(Output::Save(book.write()));
                (identity, book)
            }
        };
        Ok(Self {
            options,
            identity,
            book,
            dirty: false,
            running: false,
            invite_on_screen: false,
            transfers: Transfers::default(),
            talks: Pending::default(),
            uploads: Uploads::default(),
            stages: BTreeMap::new(),
            own_stage: Vec::new(),
            arrivals: BTreeMap::new(),
            hop: None,
            published: BTreeMap::new(),
            hosts: Vec::new(),
            port: None,
            next_conn: 1,
            conns: BTreeMap::new(),
            connections: BTreeMap::new(),
            dials: BTreeMap::new(),
            delays: BTreeMap::new(),
            reported: BTreeSet::new(),
            joins: BTreeMap::new(),
            out,
        })
    }

    // MARK: What the adapter takes

    /// Everything the node wants done since the last call, in order.
    pub fn drain(&mut self) -> Vec<Output> {
        if self.dirty {
            self.dirty = false;
            self.out.push_back(Output::Save(self.book.write()));
        }
        self.out.drain(..).collect()
    }

    /// The book as it is now, for the adapter to store.
    pub fn book_bytes(&self) -> Vec<u8> {
        self.book.write()
    }

    fn emit(&mut self, event: Event) {
        self.out.push_back(Output::Event(event));
    }

    fn commit(&mut self) {
        self.dirty = true;
    }

    /// The adapter could not store the book. It stays in memory.
    pub fn save_failed(&mut self, reason: &str) {
        self.emit(Event::Problem(Problem::Storage(reason.to_string())));
    }

    /// The adapter could not listen.
    pub fn listener_failed(&mut self, reason: &str) {
        self.emit(Event::Problem(Problem::Listener(reason.to_string())));
    }

    /// The Hop turned this device's room away.
    pub fn hop_rejected(&mut self) {
        self.emit(Event::Problem(Problem::Hop));
    }

    // MARK: What the app can ask

    /// This device, as others see it.
    pub fn device(&self) -> LinkDevice {
        self.identity.device()
    }

    /// This device as the home of its own Imps.
    pub fn who(&self) -> LinkWho {
        let device = self.identity.device();
        LinkWho {
            id: device.id,
            name: device.name,
            kind: device.kind,
        }
    }

    pub fn identity(&self) -> &Identity {
        &self.identity
    }

    pub fn links(&self) -> &[LinkRecord] {
        &self.book.links
    }

    pub fn visits(&self) -> &crate::link::visits::Visits {
        &self.book.visits
    }

    pub fn away(&self) -> &crate::link::ledger::AwayLedger {
        &self.book.away
    }

    pub fn is_running(&self) -> bool {
        self.running
    }

    /// Every connected device, linked or not.
    pub fn connected(&self) -> Vec<Uuid> {
        self.connections.keys().copied().collect()
    }

    /// The connected devices an Imp can be thrown to.
    pub fn connected_peers(&self) -> Vec<LinkDevice> {
        self.connections
            .values()
            .filter_map(|c| self.conns.get(c))
            .filter(|c| c.standing == Some(Standing::Peer))
            .filter_map(|c| c.remote.clone())
            .collect()
    }

    fn peer_ids(&self) -> Vec<Uuid> {
        self.connected_peers().iter().map(|d| d.id).collect()
    }

    pub fn standing_of(&self, device: Uuid) -> Option<Standing> {
        self.conn_of(device).and_then(|c| c.standing)
    }

    pub fn is_connected(&self, device: Uuid) -> bool {
        self.connections.contains_key(&device)
    }

    pub fn is_through_hop(&self, device: Uuid) -> bool {
        self.conn_of(device).is_some_and(|c| c.via_hop)
    }

    fn conn_of(&self, device: Uuid) -> Option<&Conn> {
        self.connections
            .get(&device)
            .and_then(|c| self.conns.get(c))
    }

    /// The Imps a device said are on its screen.
    pub fn stage_of(&self, device: Uuid) -> &[LinkStaged] {
        self.stages.get(&device).map_or(&[], Vec::as_slice)
    }

    pub fn own_stage(&self) -> &[LinkStaged] {
        &self.own_stage
    }

    /// How an Imp got to this screen.
    pub fn travel_of(&self, imp: Uuid) -> LinkTravel {
        self.book.visits.travel(imp)
    }

    /// Where the Imp goes when thrown off `side` at `height` of this screen.
    pub fn door_of(&self, imp: Uuid, side: LinkSide, height: f64) -> Door {
        doors::door(side, height, self.travel_of(imp), &self.peer_ids())
    }

    /// The bands of a side, for labelling, while an Imp is carried near it.
    pub fn bands_of(&self, imp: Uuid, side: LinkSide) -> Vec<Band> {
        doors::bands(side, self.travel_of(imp), &self.peer_ids())
    }

    /// The device holding one of this device's Imps that is away.
    pub fn holder_of(&self, imp: Uuid) -> Option<Uuid> {
        self.book.away.holder(imp)
    }

    /// This device's own card: what travels with an Imp whose home it is.
    pub fn card(&self) -> LinkCard {
        LinkCard {
            device: self.identity.device(),
            door: self.book.door.clone(),
            routes: self.current_routes(),
        }
    }

    /// Changes the name other devices see (the new name reaches them when they next connect).
    pub fn rename(&mut self, name: &str) {
        self.identity.rename(name);
    }

    /// What the Hop host needs to wait in this device's room: the Hop, the credentials and the local port
    /// the Hop's guests are passed to. None without a Hop or before the adapter listens.
    pub fn hop_host(&self) -> Option<(HopAddress, HopCredentials, u16)> {
        let hop = self.hop.clone()?;
        let door = key_of(&self.book.door)?;
        Some((hop, HopCredentials::host(&self.identity, &door), self.port?))
    }

    /// How long the Hop host waits before reconnecting after a failed try, given the wait before
    /// (0 after a success).
    pub fn hop_retry_delay(&self, previous: f64) -> f64 {
        self.options.next_retry(previous)
    }

    // MARK: Trust

    /// Marks a linked device as one of the owner's own (or not). Visitors and unknown devices cannot be.
    pub fn set_trusted(&mut self, device: Uuid, on: bool) {
        if let Some(link) = self.book.links.iter_mut().find(|l| l.id() == device)
            && link.trusted != on
        {
            link.trusted = on;
            self.commit();
        }
    }

    /// Whether a device is linked and marked as one of the owner's own. Nobody else ever is.
    pub fn is_trusted(&self, device: Uuid) -> bool {
        self.book
            .links
            .iter()
            .any(|l| l.id() == device && l.trusted)
    }

    /// Whether what `message` asks of this device comes from a trusted source, which is when its Imp may
    /// use tools to answer. A request of a holder (`ask`, `file`) is trusted if the holder is. A question
    /// from an Imp is trusted if its home is this device (and `device` holds it) or a trusted one, and
    /// `device` is that home or trusted too. Anything else is not.
    pub fn is_trusted_message(&self, message: &LinkMessage, device: Uuid) -> bool {
        match message {
            LinkMessage::Ask { .. }
            | LinkMessage::Upload { .. }
            | LinkMessage::Stop { .. }
            | LinkMessage::NewChat { .. }
            | LinkMessage::Felt { .. }
            | LinkMessage::File { .. }
            | LinkMessage::Talks { .. } => self.is_trusted(device),
            LinkMessage::Message { from, .. } => {
                let Some(home) = self.asker_home(from.id, device) else {
                    return false;
                };
                if home == self.identity.id() {
                    device == self.identity.id() || self.book.away.holder(from.id) == Some(device)
                } else {
                    self.is_trusted(home) && (device == home || self.is_trusted(device))
                }
            }
            _ => false,
        }
    }

    /// The home of an Imp, as `device` (or this device) says it stages it.
    fn asker_home(&self, imp: Uuid, device: Uuid) -> Option<Uuid> {
        self.own_stage
            .iter()
            .chain(self.stage_of(device))
            .find(|s| s.imp.id == imp)
            .map(|s| s.home.id)
    }

    // MARK: Addresses

    fn current_routes(&self) -> LinkRoutes {
        LinkRoutes::lenient(
            &self.hosts,
            self.port.unwrap_or(self.options.port),
            self.hop.as_ref().map(HopAddress::text).as_deref(),
        )
    }

    /// The host names and addresses this device gives out (the adapter finds them).
    pub fn set_hosts(&mut self, hosts: Vec<String>) {
        if hosts != self.hosts {
            self.hosts = hosts;
            self.publish_routes();
        }
    }

    /// The port the adapter listens on now.
    pub fn set_port(&mut self, port: Option<u16>) {
        if self.port != port {
            self.port = port;
            if self.running {
                self.out.push_back(Output::HopChanged);
            }
            self.publish_routes();
        }
    }

    /// Sets (or clears) the Imp server this device waits at, and tells its peers where else to find it.
    pub fn set_server(&mut self, address: Option<HopAddress>) {
        if self.hop == address {
            return;
        }
        self.hop = address;
        if self.running {
            self.out.push_back(Output::HopChanged);
        }
        self.publish_routes();
    }

    /// Says which Imps are on this device's screen. Peers hear it now and when they connect.
    pub fn set_stage(&mut self, mut imps: Vec<LinkStaged>) {
        imps.truncate(64);
        if imps == self.own_stage {
            return;
        }
        self.own_stage = imps.clone();
        for cid in self.connections.values().copied().collect::<Vec<_>>() {
            self.send_on(cid, &LinkMessage::Stage { imps: imps.clone() });
        }
    }

    /// Tells every peer our routes if they changed since it last heard.
    fn publish_routes(&mut self) {
        let routes = self.current_routes();
        let door = self.book.door.clone();
        let due: Vec<(Uuid, ConnId)> = self
            .connections
            .iter()
            .filter(|(id, cid)| {
                self.conns
                    .get(cid)
                    .is_some_and(|c| c.standing == Some(Standing::Peer))
                    && self.published.get(id) != Some(&routes)
            })
            .map(|(id, cid)| (*id, *cid))
            .collect();
        for (id, cid) in due {
            self.published.insert(id, routes.clone());
            self.send_on(
                cid,
                &LinkMessage::Routes {
                    door: door.clone(),
                    routes: routes.clone(),
                },
            );
        }
    }

    // MARK: Start and stop

    /// Starts: throws of our own Imps that were in the air when this device last stopped, and never got an
    /// answer, are called home (so a receiver that did take one hears `gone` when it claims), and what is
    /// wanted is dialled. An iPhone calls this when the app comes to the front.
    pub fn start(&mut self, now: Time) {
        if self.running {
            return;
        }
        self.running = true;
        let lost: Vec<Passing> = self
            .book
            .passing
            .iter()
            .filter(|p| !self.transfers.outgoing().contains_key(&p.transfer))
            .cloned()
            .collect();
        if !lost.is_empty() {
            self.book.passing.retain(|p| !lost.contains(p));
            for p in &lost {
                if self.book.away.holder(p.imp) == Some(p.to) {
                    self.book.away.call_home(p.imp);
                }
            }
            self.commit();
        }
        self.reconcile(now);
    }

    /// Stops everything and closes every connection. An iPhone calls this when the app leaves the front.
    pub fn stop(&mut self, now: Time) {
        if !self.running {
            return;
        }
        self.running = false;
        self.dials.clear();
        for cid in self.conns.keys().copied().collect::<Vec<_>>() {
            self.retire(cid, now);
        }
        for (device, _) in std::mem::take(&mut self.joins) {
            self.emit(Event::Joined {
                device,
                result: Err(JoinError::NotRunning),
            });
        }
        self.arrivals.clear();
        self.port = None;
    }

    // MARK: Connections

    /// A connection came in (the adapter accepted it, or the Hop passed a guest). None when it must be
    /// closed. Otherwise the id to use from now on.
    pub fn accepted(&mut self, via_hop: bool, now: Time) -> Option<ConnId> {
        if !self.running {
            return None;
        }
        if self.conns.len() >= MAX_CONNECTIONS {
            self.emit(Event::Problem(Problem::Full("connections")));
            return None;
        }
        let secret = self.identity.noise_secret();
        let door = key_of(&self.book.door)?;
        let handshake = Handshake::responder(&secret, &crypto::psk(&door)).ok()?;
        Some(self.open(Phase::Handshake(Box::new(handshake)), None, via_hop, now))
    }

    /// A connection to `device` opened on one of its routes. None when it is no longer wanted. The first
    /// handshake bytes are in `drain`.
    pub fn dialed(&mut self, device: Uuid, via_hop: bool, now: Time) -> Option<ConnId> {
        if !self.running || self.connections.contains_key(&device) {
            return None;
        }
        let target = self.wanted().remove(&device)?;
        let host = key_of(&target.card.device.key)?;
        let door = key_of(&target.card.door)?;
        let (handshake, first) =
            Handshake::initiator(&self.identity.noise_secret(), &host, &crypto::psk(&door)).ok()?;
        let cid = self.open(
            Phase::Handshake(Box::new(handshake)),
            Some(target),
            via_hop,
            now,
        );
        self.out.push_back(Output::Send {
            conn: cid,
            bytes: first,
        });
        Some(cid)
    }

    fn open(
        &mut self,
        phase: Phase,
        target: Option<DialTarget>,
        via_hop: bool,
        now: Time,
    ) -> ConnId {
        let cid = self.next_conn;
        self.next_conn += 1;
        self.conns.insert(
            cid,
            Conn {
                target,
                via_hop,
                phase,
                chunks: ChunkReader::default(),
                frames: FrameReader::new(),
                hash: Vec::new(),
                remote_static: None,
                remote: None,
                standing: None,
                established: false,
                superseded: false,
                timed_out: false,
                established_at: now,
                handshake_deadline: Some(now + self.options.handshake_timeout),
                grace_deadline: None,
                claiming: BTreeSet::new(),
                last_heard: now,
                last_ping: now,
                tokens: self.options.frame_burst,
                refilled: now,
            },
        );
        cid
    }

    /// The connection closed (or failed to open).
    pub fn closed(&mut self, conn: ConnId, now: Time) {
        self.retire(conn, now);
    }

    /// Bytes arrived on a connection.
    pub fn received(&mut self, conn: ConnId, data: &[u8], now: Time) {
        let Some(c) = self.conns.get_mut(&conn) else {
            return;
        };
        c.last_heard = now;
        let chunks = c.chunks.feed(data);
        for chunk in chunks {
            if !self.conns.contains_key(&conn) {
                break;
            }
            self.on_chunk(conn, &chunk, now);
        }
    }

    fn on_chunk(&mut self, cid: ConnId, chunk: &[u8], now: Time) {
        let Some(conn) = self.conns.get_mut(&cid) else {
            return;
        };
        match std::mem::replace(&mut conn.phase, Phase::Dead) {
            Phase::Handshake(mut handshake) => match handshake.read(chunk) {
                Err(_) => {
                    // A device that answers wrongly: it forgot us, or runs another version.
                    if let Some(target) = conn.target.as_ref().map(|t| t.card.id())
                        && let Some(dial) = self.dials.get_mut(&target)
                    {
                        dial.refused = true;
                    }
                    self.retire(cid, now);
                }
                Ok(progress) => {
                    if let Some(bytes) = progress.reply {
                        self.out.push_back(Output::Send { conn: cid, bytes });
                    }
                    match progress.established {
                        None => conn.phase = Phase::Handshake(handshake),
                        Some(done) => {
                            conn.phase = Phase::Secure(Box::new(done.secure));
                            conn.hash = done.hash;
                            conn.remote_static = Some(done.remote_static);
                            if conn.target.is_some() {
                                self.send_hello(cid);
                            }
                        }
                    }
                }
            },
            Phase::Secure(mut secure) => {
                let opened = secure.open(chunk);
                conn.phase = Phase::Secure(secure);
                let frames = opened.ok().and_then(|plain| conn.frames.feed(&plain).ok());
                match frames {
                    None => self.retire(cid, now),
                    Some(bodies) => {
                        for body in bodies {
                            if !self.conns.contains_key(&cid) {
                                break;
                            }
                            self.on_frame(cid, &body, now);
                        }
                    }
                }
            }
            Phase::Dead => {}
        }
    }

    fn on_frame(&mut self, cid: ConnId, body: &[u8], now: Time) {
        let (rate, burst) = (self.options.frame_rate, self.options.frame_burst);
        let Some(conn) = self.conns.get_mut(&cid) else {
            return;
        };
        if !conn.admit(rate, burst, now) {
            return self.retire(cid, now);
        }
        let established = conn.established;
        match LinkMessage::decode(body) {
            Decoded::Message(message) if message.is_sound() => {
                if established {
                    self.dispatch(cid, *message, now);
                } else {
                    self.handshake(cid, *message, now);
                }
            }
            // Whatever cannot be read is ignored, except in the handshake, where it cannot be right.
            _ if !established => self.retire(cid, now),
            _ => {}
        }
    }

    /// Closes a connection and forgets it. What it leaves behind (throws, questions) is settled here.
    fn retire(&mut self, cid: ConnId, now: Time) {
        let Some(conn) = self.conns.remove(&cid) else {
            return;
        };
        self.out.push_back(Output::Close { conn: cid });
        // A device we dialled that closes on us before the handshake is done does not share our door or
        // our version, or it forgot us: no other route will do better.
        if let Some(target) = &conn.target
            && !conn.established
            && !conn.timed_out
            && let Some(dial) = self.dials.get_mut(&target.card.id())
        {
            dial.refused = true;
        }
        if let Some(remote) = &conn.remote
            && self.connections.get(&remote.id) == Some(&cid)
        {
            let id = remote.id;
            self.connections.remove(&id);
            self.stages.remove(&id);
            self.published.remove(&id);
            for t in self.transfers.lost(id, now) {
                self.finish_pass(&t, PassOutcome::Declined(LinkDecline::Timeout), now);
            }
            for q in self.talks.lost(id) {
                self.fail(&q);
            }
            self.arrivals.retain(|_, a| a.from != id);
            self.uploads.lost(id);
            if conn.established && !conn.superseded {
                self.emit(Event::Disconnected(id));
            }
            // A connection that held for a while starts the next dial fresh. One that dropped at once
            // backs off like a failure.
            if now - conn.established_at > 30.0 {
                self.delays.remove(&id);
            } else {
                self.delay_more(id);
            }
        }
        self.reconcile(now);
    }

    fn delay_more(&mut self, id: Uuid) {
        let next = self
            .options
            .next_retry(self.delays.get(&id).copied().unwrap_or(0.0));
        self.delays.insert(id, next);
    }

    // MARK: Sending

    fn send_on(&mut self, cid: ConnId, message: &LinkMessage) -> bool {
        let Ok(body) = message.encode() else {
            return false;
        };
        let Ok(frame) = encode_frame(&body) else {
            return false;
        };
        let Some(Conn {
            phase: Phase::Secure(secure),
            ..
        }) = self.conns.get_mut(&cid)
        else {
            return false;
        };
        match secure.seal(&frame) {
            Ok(bytes) => {
                self.out.push_back(Output::Send { conn: cid, bytes });
                true
            }
            Err(_) => false,
        }
    }

    /// Sends a message to a connected device. False if it is not connected or the message cannot be sent.
    pub fn send(&mut self, message: &LinkMessage, to: Uuid) -> bool {
        match self.connections.get(&to).copied() {
            Some(cid) => self.send_on(cid, message),
            None => false,
        }
    }

    /// Sends a file to the home of an Imp this device holds, to name in the next `ask`: the `upload`
    /// and all its parts are queued. Returns the id to put in `attachments`. None if `to` is not
    /// connected or the file is empty or too big.
    pub fn upload(
        &mut self,
        imp: Uuid,
        to: Uuid,
        name: &str,
        mime: &str,
        data: Vec<u8>,
        _now: Time,
    ) -> Option<Uuid> {
        if data.is_empty() || data.len() as u64 > MAX_UPLOAD || !self.connections.contains_key(&to)
        {
            return None;
        }
        let id = crypto::new_id();
        let start = LinkMessage::Upload {
            id,
            imp,
            name: uploads::clean_name(name),
            mime: mime.trim().chars().take(200).collect(),
            size: data.len() as u64,
            sha256: crate::workspace::checksum(&data),
        };
        if !self.send(&start, to) {
            return None;
        }
        for (i, part) in data.chunks(MAX_PART).enumerate() {
            let part = LinkMessage::UploadPart {
                id,
                offset: (i * MAX_PART) as u64,
                data: part.to_vec().into(),
            };
            if !self.send(&part, to) {
                return None;
            }
        }
        Some(id)
    }

    /// A file that arrived whole from `from`, for an `ask` that names it. It is forgotten once taken.
    pub fn take_upload(&mut self, id: Uuid, from: Uuid) -> Option<Upload> {
        self.uploads.take(id, from)
    }

    // MARK: Handshake

    fn send_hello(&mut self, cid: ConnId) {
        let Some(conn) = self.conns.get(&cid) else {
            return;
        };
        let join = conn
            .target
            .as_ref()
            .and_then(|t| t.join)
            .map(|invite| crypto::join_proof(&invite, &conn.hash).to_vec().into());
        let hello = LinkMessage::Hello {
            device: self.identity.id(),
            name: self.identity.name().to_string(),
            kind: self.identity.kind(),
            room: self.identity.room_key().to_vec().into(),
            join,
        };
        self.send_on(cid, &hello);
    }

    fn handshake(&mut self, cid: ConnId, message: LinkMessage, now: Time) {
        let guest = self.conns.get(&cid).is_some_and(|c| c.target.is_some());
        match message {
            LinkMessage::Hello {
                device,
                name,
                kind,
                room,
                join,
            } if !guest => self.on_hello(cid, device, &name, kind, room, join, now),
            LinkMessage::Welcome {
                device,
                name,
                linked,
                ..
            } if guest => self.on_welcome(cid, device, &name, linked, now),
            _ => self.retire(cid, now),
        }
    }

    /// We are the host: check who is calling, decide how far to trust them, and answer.
    #[allow(clippy::too_many_arguments)]
    fn on_hello(
        &mut self,
        cid: ConnId,
        device: Uuid,
        name: &str,
        kind: LinkKind,
        room: Bytes,
        join: Option<Bytes>,
        now: Time,
    ) {
        let Some((hash, Some(key))) = self
            .conns
            .get(&cid)
            .map(|c| (c.hash.clone(), c.remote_static))
        else {
            return self.retire(cid, now);
        };
        if device == self.identity.id() {
            return self.retire(cid, now);
        }
        let remote = LinkDevice {
            id: device,
            name: LinkDevice::cleaned(name, kind),
            kind,
            key: key.to_vec().into(),
            room,
        };
        let mut standing = Standing::Visitor;
        let mut newly_linked = false;
        let known = self.book.links.iter().position(|l| l.id() == device);
        let home_clash = self
            .book
            .visits
            .home_key(device)
            .is_some_and(|k| !crypto::equal(k, &key));
        if let Some(i) = known {
            // A device we have a link with must be the one whose key we pinned.
            if !crypto::equal(&self.book.links[i].device.key.0, &key) {
                self.emit(Event::Problem(Problem::KeyChanged(device)));
                return self.retire(cid, now);
            }
            standing = Standing::Peer;
            if self.book.links[i].device.name != remote.name
                || self.book.links[i].device.room != remote.room
            {
                self.book.links[i].device.name = remote.name.clone();
                self.book.links[i].device.room = remote.room.clone();
                self.commit();
            }
        } else if home_clash {
            // Someone using the id of a home an Imp of ours visits from, with another key.
            self.emit(Event::Problem(Problem::KeyChanged(device)));
            return self.retire(cid, now);
        } else if let Some(join) = join
            && let Some(invite) = self.book.invite.as_ref().and_then(key_of)
            && self.invite_is_fresh(now)
            && crypto::is_valid_join(&join.0, &invite, &hash)
        {
            if self.book.links.len() < MAX_LINKS {
                self.book.links.push(LinkRecord {
                    device: remote.clone(),
                    door: None,
                    routes: LinkRoutes::none(),
                    since: now,
                    trusted: false,
                });
                self.commit();
                standing = Standing::Peer;
                newly_linked = true;
            } else {
                self.emit(Event::Problem(Problem::Full("links")));
            }
        }
        let welcome = LinkMessage::Welcome {
            device: self.identity.id(),
            name: self.identity.name().to_string(),
            kind: self.identity.kind(),
            linked: standing == Standing::Peer,
        };
        self.send_on(cid, &welcome);
        self.establish(cid, remote, standing, newly_linked, now);
    }

    /// We are the guest: the Noise handshake already proved the host is the device we meant. It tells us how
    /// it sees us.
    fn on_welcome(&mut self, cid: ConnId, device: Uuid, name: &str, linked: bool, now: Time) {
        let Some(target) = self.conns.get(&cid).and_then(|c| c.target.clone()) else {
            return self.retire(cid, now);
        };
        let id = target.card.id();
        if device != id {
            return self.retire(cid, now);
        }
        let refuse = |node: &mut Self| {
            if let Some(dial) = node.dials.get_mut(&id) {
                dial.refused = true;
            }
            node.retire(cid, now);
        };
        let mut remote = target.card.device.clone();
        remote.name = LinkDevice::cleaned(name, remote.kind);
        let mut standing = Standing::Visitor;
        let mut newly_linked = false;
        let index = self.book.links.iter().position(|l| l.id() == id);
        if target.join.is_some() {
            if !linked {
                self.emit(Event::Problem(Problem::InviteRefused(id)));
                return refuse(self);
            }
            if let Some(i) = index {
                self.book.links[i].device = remote.clone();
                self.book.links[i].door = Some(target.card.door.clone());
                self.book.links[i].routes = target.card.routes.clone();
            } else if self.book.links.len() < MAX_LINKS {
                self.book.links.push(LinkRecord {
                    device: remote.clone(),
                    door: Some(target.card.door.clone()),
                    routes: target.card.routes.clone(),
                    since: now,
                    trusted: false,
                });
                newly_linked = true;
            } else {
                self.emit(Event::Problem(Problem::Full("links")));
                return refuse(self);
            }
            self.commit();
            standing = Standing::Peer;
        } else if let Some(i) = index {
            if linked {
                standing = Standing::Peer;
                if self.book.links[i].device.name != remote.name {
                    self.book.links[i].device.name = remote.name.clone();
                    self.commit();
                }
            } else {
                // It forgot us: so do we, but a visitor may still have business with it.
                let dropped = self.dropped(id, now);
                self.emit(Event::Forgotten(id, dropped));
            }
        } else if linked {
            // It thinks we are linked and we do not: say so, and it forgets us too.
            self.send_on(
                cid,
                &LinkMessage::Bye {
                    reason: FORGOTTEN.into(),
                },
            );
            return self.retire(cid, now);
        }
        self.establish(cid, remote, standing, newly_linked, now);
    }

    /// Whether the connection to the same device that wins is `new`: the one dialled by the device with the
    /// smaller id stays. Two dialled by the same device: the newer (the older is likely dead).
    fn prefers(&self, new: ConnId, old: ConnId, remote: Uuid) -> bool {
        let dialler = |cid: ConnId| {
            if self.conns.get(&cid).is_some_and(|c| c.target.is_some()) {
                self.identity.id()
            } else {
                remote
            }
        };
        let (n, o) = (dialler(new), dialler(old));
        n <= o
    }

    fn establish(
        &mut self,
        cid: ConnId,
        remote: LinkDevice,
        standing: Standing,
        newly_linked: bool,
        now: Time,
    ) {
        if let Some(old) = self.connections.get(&remote.id).copied() {
            if self.prefers(cid, old, remote.id) {
                if let Some(c) = self.conns.get_mut(&old) {
                    c.superseded = true;
                }
                self.connections.remove(&remote.id);
                self.retire(old, now);
            } else {
                if let Some(c) = self.conns.get_mut(&cid) {
                    c.superseded = true;
                }
                self.dials.remove(&remote.id);
                return self.retire(cid, now);
            }
        }
        let grace = self.options.visitor_grace;
        let Some(conn) = self.conns.get_mut(&cid) else {
            return;
        };
        conn.remote = Some(remote.clone());
        conn.standing = Some(standing);
        conn.established = true;
        conn.established_at = now;
        conn.last_ping = now;
        conn.handshake_deadline = None;
        if standing == Standing::Visitor && conn.target.is_none() {
            conn.grace_deadline = Some(now + grace);
        }
        self.connections.insert(remote.id, cid);
        self.reported.remove(&remote.id);
        self.dials.remove(&remote.id);
        if newly_linked {
            self.emit(Event::Linked(remote.clone()));
        }
        if standing == Standing::Peer && self.joins.remove(&remote.id).is_some() {
            self.emit(Event::Joined {
                device: remote.id,
                result: Ok(remote.clone()),
            });
        }
        self.emit(Event::Connected(remote, standing));
        self.greet(cid);
    }

    /// First things after a handshake: tell a peer where we are, deliver news that was waiting, claim what
    /// we hold from this device, then say what is on our screen (after the claims, so a home we only visit
    /// already knows we hold its Imp and listens).
    fn greet(&mut self, cid: ConnId) {
        let Some((remote, standing)) = self
            .conns
            .get(&cid)
            .and_then(|c| Some((c.remote.clone()?, c.standing?)))
        else {
            return;
        };
        if standing == Standing::Peer {
            let routes = self.current_routes();
            self.published.insert(remote.id, routes.clone());
            self.send_on(
                cid,
                &LinkMessage::Routes {
                    door: self.book.door.clone(),
                    routes,
                },
            );
        }
        self.deliver_notices();
        self.deliver_handed();
        self.claim_everything(cid);
        self.send_on(
            cid,
            &LinkMessage::Stage {
                imps: self.own_stage.clone(),
            },
        );
    }

    fn invite_is_fresh(&self, now: Time) -> bool {
        self.book.invite.is_some()
            && (self.invite_on_screen
                || now - self.book.invite_shown.unwrap_or(f64::NEG_INFINITY)
                    <= self.options.invite_life)
    }

    // MARK: Claims

    /// Claims every Imp held from this device, and delivers the releases waiting for it. Tickets only go to
    /// the device whose key the Imp's card has.
    fn claim_everything(&mut self, cid: ConnId) {
        let Some(remote) = self.conns.get(&cid).and_then(|c| c.remote.clone()) else {
            return;
        };
        for (imp, ticket) in self.book.visits.claims(&remote) {
            self.claim(cid, imp, ticket);
        }
        let releases: Vec<(Uuid, Bytes)> = self
            .book
            .visits
            .pending_releases(&remote)
            .iter()
            .map(|r| (r.imp, r.ticket.clone()))
            .collect();
        for (imp, ticket) in releases {
            self.send_on(cid, &LinkMessage::Release { imp, ticket });
        }
    }

    fn claim(&mut self, cid: ConnId, imp: Uuid, ticket: Vec<u8>) {
        if self
            .conns
            .get_mut(&cid)
            .is_some_and(|c| c.claiming.insert(imp))
        {
            self.send_on(
                cid,
                &LinkMessage::Claim {
                    imp,
                    ticket: ticket.into(),
                },
            );
        }
    }

    /// Tells the homes of Imps this device passed on where they went, as far as they are connected.
    fn deliver_handed(&mut self) {
        let waiting = std::mem::take(&mut self.book.handed);
        let before = waiting.len();
        for h in waiting {
            let message = LinkMessage::Moved {
                imp: h.imp,
                to: h.to.clone(),
            };
            if !self.send(&message, h.home) {
                self.book.handed.push(h);
            }
        }
        if self.book.handed.len() != before {
            self.commit();
        }
    }

    /// Tells every connected device the news it was owed (an Imp of ours it no longer holds).
    fn deliver_notices(&mut self) {
        if self.book.away.notices().is_empty() {
            return;
        }
        for (id, cid) in self.connections.clone() {
            for imp in self.book.away.take_notices(id) {
                self.send_on(cid, &LinkMessage::Gone { imp });
            }
        }
        self.commit();
    }

    // MARK: Messages

    fn dispatch(&mut self, cid: ConnId, message: LinkMessage, now: Time) {
        let Some((remote, standing)) = self
            .conns
            .get(&cid)
            .and_then(|c| Some((c.remote.clone()?, c.standing?)))
        else {
            return;
        };
        let from = remote.id;
        if !access::allows(&message, from, standing, &self.book.away, &self.book.visits) {
            match &message {
                LinkMessage::Message { id, .. } => {
                    self.send_on(
                        cid,
                        &LinkMessage::Answer {
                            id: *id,
                            text: UNREACHABLE.into(),
                            failed: true,
                        },
                    );
                }
                // It is not theirs any more: say so rather than leave them asking.
                LinkMessage::Ask { imp, .. }
                | LinkMessage::Stop { imp }
                | LinkMessage::NewChat { imp }
                | LinkMessage::Felt { imp, .. }
                | LinkMessage::Talks { imp } => {
                    self.send_on(cid, &LinkMessage::Gone { imp: *imp });
                }
                LinkMessage::Upload { id, imp, .. } => {
                    self.send_on(
                        cid,
                        &LinkMessage::UploadFailed {
                            id: *id,
                            reason: "That Imp isn't here any more.".into(),
                        },
                    );
                    self.send_on(cid, &LinkMessage::Gone { imp: *imp });
                }
                LinkMessage::File { id, imp, .. } => {
                    self.send_on(
                        cid,
                        &LinkMessage::FileFailed {
                            id: *id,
                            reason: "That file isn't available.".into(),
                        },
                    );
                    self.send_on(cid, &LinkMessage::Gone { imp: *imp });
                }
                _ => {}
            }
            return;
        }
        match message.clone() {
            LinkMessage::Ping {} => {
                self.send_on(cid, &LinkMessage::Pong {});
            }
            LinkMessage::Pong {} | LinkMessage::Hello { .. } | LinkMessage::Welcome { .. } => {}
            LinkMessage::Bye { reason } => {
                if reason == FORGOTTEN && self.book.links.iter().any(|l| l.id() == from) {
                    let result = self.dropped(from, now);
                    self.retire(cid, now);
                    self.emit(Event::Forgotten(from, result));
                } else {
                    self.retire(cid, now);
                }
            }
            LinkMessage::Routes { door, routes } => {
                if let Some(link) = self.book.links.iter_mut().find(|l| l.id() == from)
                    && (link.door.as_ref() != Some(&door) || link.routes != routes)
                {
                    link.door = Some(door);
                    link.routes = routes;
                    self.commit();
                    self.reconcile(now);
                }
            }
            LinkMessage::Stage { imps } => {
                self.stages.insert(from, imps);
                self.emit(Event::Message(message, from));
            }
            LinkMessage::Claim { imp, ticket } => self.on_claim(cid, imp, &ticket.0, message),
            LinkMessage::Release { imp, ticket } => self.on_release(cid, imp, &ticket.0, message),
            LinkMessage::Claimed { imp, ticket } => self.on_claimed(cid, imp, &ticket.0),
            LinkMessage::Gone { imp } => self.on_gone(cid, imp, message),
            LinkMessage::Moved { imp, to } => {
                if to.id != self.identity.id()
                    && self.book.away.moved(imp, from, to.id, &to.name, to.kind)
                {
                    self.commit();
                    self.emit(Event::Message(LinkMessage::Moved { imp, to }, from));
                }
            }
            LinkMessage::Pass {
                transfer,
                imp,
                entry,
                home,
                ticket,
            } => {
                self.on_pass(
                    cid,
                    transfer,
                    imp,
                    entry,
                    home,
                    ticket.map(|t| t.0),
                    message,
                    now,
                );
            }
            LinkMessage::Adopt { transfer, imp, .. } => {
                self.on_adopt(cid, transfer, imp, message, now)
            }
            LinkMessage::Took { transfer } | LinkMessage::Adopted { transfer } => {
                self.answered(transfer, from, PassOutcome::Took, now);
            }
            LinkMessage::Declined { transfer, reason } => {
                self.answered(transfer, from, PassOutcome::Declined(reason), now)
            }
            LinkMessage::Message {
                id,
                from: imp,
                to,
                to_home,
                text,
                forwarded,
            } => {
                self.on_talk(cid, id, imp, to, to_home, text, forwarded, message, now);
            }
            LinkMessage::Answer { id, text, failed } => {
                self.on_answer(id, text, failed, from, message)
            }
            LinkMessage::Upload {
                id,
                name,
                mime,
                size,
                sha256,
                ..
            } => {
                if let Err(why) = self
                    .uploads
                    .begin(id, from, &name, &mime, size, &sha256, now)
                {
                    self.send_on(
                        cid,
                        &LinkMessage::UploadFailed {
                            id,
                            reason: why.reason().into(),
                        },
                    );
                }
            }
            LinkMessage::UploadPart { id, offset, data } => {
                if let Some(Err(why)) = self.uploads.part(id, from, offset, &data.0, now) {
                    self.send_on(
                        cid,
                        &LinkMessage::UploadFailed {
                            id,
                            reason: why.reason().into(),
                        },
                    );
                }
            }
            LinkMessage::Look { imp } => {
                self.book.visits.update(&imp);
                self.commit();
                self.emit(Event::Message(message, from));
            }
            _ => self.emit(Event::Message(message, from)),
        }
    }

    fn remote_id(&self, cid: ConnId) -> Option<Uuid> {
        self.conns.get(&cid)?.remote.as_ref().map(|r| r.id)
    }

    fn on_claim(&mut self, cid: ConnId, imp: Uuid, ticket: &[u8], message: LinkMessage) {
        let Some(from) = self.remote_id(cid) else {
            return;
        };
        match self.book.away.claim(imp, ticket, from) {
            Claim::Granted { ticket: fresh, .. } => {
                if let Some(c) = self.conns.get_mut(&cid) {
                    c.grace_deadline = None;
                }
                self.commit();
                self.send_on(
                    cid,
                    &LinkMessage::Claimed {
                        imp,
                        ticket: fresh.to_vec().into(),
                    },
                );
                self.deliver_notices();
                self.emit(Event::Message(message, from));
            }
            Claim::Refused => {
                self.send_on(cid, &LinkMessage::Gone { imp });
            }
        }
    }

    fn on_release(&mut self, cid: ConnId, imp: Uuid, ticket: &[u8], message: LinkMessage) {
        let Some(from) = self.remote_id(cid) else {
            return;
        };
        if self.book.away.release(imp, ticket) {
            if let Some(c) = self.conns.get_mut(&cid) {
                c.grace_deadline = None;
            }
            self.commit();
            self.emit(Event::Message(message, from));
        }
        // Either way the sender can stop trying.
        self.send_on(cid, &LinkMessage::Gone { imp });
    }

    fn on_claimed(&mut self, cid: ConnId, imp: Uuid, ticket: &[u8]) {
        let Some(from) = self.remote_id(cid) else {
            return;
        };
        if let Some(c) = self.conns.get_mut(&cid) {
            c.claiming.remove(&imp);
        }
        let release = |node: &mut Self| {
            node.send_on(
                cid,
                &LinkMessage::Release {
                    imp,
                    ticket: ticket.to_vec().into(),
                },
            );
        };
        if let Some(visit) = self.book.visits.visit(imp) {
            if visit.home.id() == from {
                self.book.visits.rotate(imp, ticket);
                self.commit();
            }
        } else if self.book.visits.rotate_release(imp, ticket, from) {
            self.commit();
            release(self);
        } else {
            // We hold no body for it (a claim that crossed a throw): do not leave it away.
            release(self);
        }
    }

    fn on_gone(&mut self, cid: ConnId, imp: Uuid, message: LinkMessage) {
        let Some(from) = self.remote_id(cid) else {
            return;
        };
        if let Some(c) = self.conns.get_mut(&cid) {
            c.claiming.remove(&imp);
        }
        self.book.visits.delivered(imp, from);
        if self
            .book
            .visits
            .visit(imp)
            .is_some_and(|v| v.home.id() == from)
        {
            self.book.visits.leave(imp);
            self.commit();
            self.emit(Event::Message(message, from));
        } else {
            self.commit();
        }
    }

    // MARK: Imp talk

    #[allow(clippy::too_many_arguments)]
    fn on_talk(
        &mut self,
        cid: ConnId,
        id: Uuid,
        imp: LinkImp,
        to: Uuid,
        to_home: Uuid,
        text: String,
        forwarded: bool,
        message: LinkMessage,
        now: Time,
    ) {
        let Some(from) = self.remote_id(cid) else {
            return;
        };
        let fail = |node: &mut Self, text: &str| {
            node.send_on(
                cid,
                &LinkMessage::Answer {
                    id,
                    text: text.into(),
                    failed: true,
                },
            );
        };
        let connected = self.connected();
        match talks::received(self.identity.id(), to_home, forwarded, from, &connected) {
            talks::Received::Answer => {
                // Only what is on the screen the target's body is on may ask it something, or an Imp
                // on the screen of another of the owner's devices (marked Mine here).
                let screen = match self.book.away.holder(to) {
                    Some(holder) => self.stage_of(holder),
                    None => self.own_stage.as_slice(),
                };
                let known: Vec<LinkStaged> = self
                    .own_stage
                    .iter()
                    .chain(self.stages.values().flatten())
                    .cloned()
                    .collect();
                let mine = self.is_trusted(from);
                let holder = self.book.away.holder(to);
                if talks::holder_may_ask(imp.id, forwarded, from, holder, &known)
                    || talks::may_ask(
                        imp.id,
                        screen,
                        forwarded,
                        from,
                        self.stage_of(from),
                        &known,
                        mine,
                    )
                {
                    self.emit(Event::Message(message, from));
                } else if !mine
                    && !forwarded
                    && self.stage_of(from).iter().any(|s| s.imp.id == imp.id)
                {
                    // It would have been let in from one of the owner's devices.
                    fail(self, NOT_MINE);
                } else {
                    fail(self, UNREACHABLE);
                }
            }
            talks::Received::Forward(target) => {
                if self.talks.count_from(from) >= talks::PER_SENDER {
                    return fail(self, BUSY);
                }
                if !self
                    .talks
                    .sent(id, Some(from), target, now, self.options.answer_timeout)
                {
                    return fail(self, UNREACHABLE);
                }
                let forward = LinkMessage::Message {
                    id,
                    from: imp,
                    to,
                    to_home,
                    text,
                    forwarded: true,
                };
                if !self.send(&forward, target) {
                    self.talks.answered(id, target);
                    fail(self, UNREACHABLE);
                }
            }
            talks::Received::Refuse => fail(self, UNREACHABLE),
        }
    }

    fn on_answer(
        &mut self,
        id: Uuid,
        text: String,
        failed: bool,
        from: Uuid,
        message: LinkMessage,
    ) {
        let Some(question) = self.talks.answered(id, from) else {
            return;
        };
        match question.from {
            Some(back) => {
                self.send(&LinkMessage::Answer { id, text, failed }, back);
            }
            None => self.emit(Event::Message(message, from)),
        }
    }

    /// A question that will never be answered: fail it the way an answer would arrive.
    fn fail(&mut self, question: &talks::Question) {
        let failure = LinkMessage::Answer {
            id: question.id,
            text: UNREACHABLE.into(),
            failed: true,
        };
        match question.from {
            Some(back) => {
                self.send(&failure, back);
            }
            None => self.emit(Event::Message(failure, question.to)),
        }
    }

    /// Starts a question from an Imp of this device to another (`to`, whose home is `to_home`). `holder` is
    /// where the asking Imp's body is (this device when at home). On `Here` the app answers it itself. On
    /// `Via` the answer comes back as `Event::Message(Answer)`, or a failed one after the timeout. On
    /// `Unreachable` nothing was sent.
    pub fn talk(&mut self, ask: Ask<'_>, now: Time) -> First {
        let Ask {
            id,
            from,
            to,
            to_home,
            text,
            holder,
        } = ask;
        let first = talks::first(self.identity.id(), to_home, holder, &self.connected());
        let First::Via(device) = first else {
            return first;
        };
        if !self
            .talks
            .sent(id, None, device, now, self.options.answer_timeout)
        {
            return First::Unreachable;
        }
        let question = LinkMessage::Message {
            id,
            from,
            to,
            to_home,
            text: text.chars().take(MAX_TEXT).collect(),
            forwarded: false,
        };
        if !self.send(&question, device) {
            self.talks.answered(id, device);
            return First::Unreachable;
        }
        first
    }

    // MARK: Invites and links

    /// The invite to show as a QR code: the one already out while it still works, so a code that was copied
    /// or shown before stays good when it is shown again (the screen reopened, the app came back from the
    /// background). A new one once it has expired. Its routes are always the current ones.
    pub fn invite(&mut self, now: Time) -> LinkInvite {
        let Some(key) = self
            .book
            .invite
            .clone()
            .filter(|_| self.invite_is_fresh(now))
        else {
            return self.new_invite(now);
        };
        self.book.invite_shown = Some(now);
        self.invite_on_screen = true;
        self.commit();
        self.invite_of(key)
    }

    /// A new invite to show as a QR code. The previous one stops working.
    pub fn new_invite(&mut self, now: Time) -> LinkInvite {
        let key: Bytes = crypto::random_key().to_vec().into();
        self.book.invite = Some(key.clone());
        self.book.invite_shown = Some(now);
        self.invite_on_screen = true;
        self.commit();
        self.invite_of(key)
    }

    fn invite_of(&self, key: Bytes) -> LinkInvite {
        LinkInvite {
            device: self.identity.device(),
            door: self.book.door.clone(),
            invite: key,
            routes: self.current_routes(),
        }
    }

    /// The code is off the screen: it still works for a while.
    pub fn invite_hidden(&mut self, now: Time) {
        self.invite_on_screen = false;
        self.book.invite_shown = Some(now);
        self.commit();
    }

    /// Scans an invite: links with the device that showed it. The result comes as `Event::Joined`.
    pub fn join(&mut self, invite: &LinkInvite, now: Time) {
        let id = invite.device.id;
        let finish = |node: &mut Self, result| node.emit(Event::Joined { device: id, result });
        if !self.running {
            return finish(self, Err(JoinError::NotRunning));
        }
        if id == self.identity.id() {
            return finish(self, Err(JoinError::ItsOwnCode));
        }
        if self.joins.contains_key(&id) {
            return;
        }
        // Somebody asked for this now: no waiting.
        self.delays.remove(&id);
        if let Some(i) = self.book.links.iter().position(|l| l.id() == id) {
            if !crypto::equal(&self.book.links[i].device.key.0, &invite.device.key.0) {
                return finish(self, Err(JoinError::KeyChanged));
            }
            // Scanned again: take the newest addresses and door, and carry on.
            self.book.links[i].door = Some(invite.door.clone());
            self.book.links[i].routes = invite.routes.clone();
            self.commit();
            self.reconcile(now);
            let device = self.book.links[i].device.clone();
            return finish(self, Ok(device));
        }
        if self.book.links.len() >= MAX_LINKS {
            return finish(self, Err(JoinError::Full));
        }
        self.joins.insert(
            id,
            Join {
                invite: invite.clone(),
                deadline: now + self.options.join_timeout,
            },
        );
        self.reconcile(now);
    }

    /// Ends the link with a device: it hears `bye` if it is connected, our Imps it holds are called home,
    /// and the Imps visiting us whose home it is are sent home.
    pub fn forget(&mut self, device: Uuid, now: Time) -> Forgotten {
        let mut result = Forgotten::default();
        if self.book.links.iter().any(|l| l.id() == device) {
            result.called_home = self.book.away.call_home_from(device);
            result.sent_home = self
                .book
                .visits
                .send_home_of(device, now)
                .iter()
                .map(|v| v.id())
                .collect();
            if let Some(cid) = self.connections.get(&device).copied() {
                self.deliver_notices();
                self.send_on(
                    cid,
                    &LinkMessage::Bye {
                        reason: FORGOTTEN.into(),
                    },
                );
                self.retire(cid, now);
            }
            self.book.away.drop_notices(device);
            self.book.handed.retain(|h| h.home != device);
            self.drop_link(device);
        }
        self.reconcile(now);
        result
    }

    /// Forgets every device and makes a new door key, so every old code and link stops working.
    pub fn forget_everyone(&mut self, now: Time) -> Forgotten {
        let mut result = Forgotten::default();
        for id in self.book.links.iter().map(|l| l.id()).collect::<Vec<_>>() {
            let one = self.forget(id, now);
            result.called_home.extend(one.called_home);
            result.sent_home.extend(one.sent_home);
        }
        // Imps still held by devices that are no longer linked cannot reach us with the old door key either.
        for imp in self
            .book
            .away
            .entries()
            .iter()
            .map(|e| e.imp)
            .collect::<Vec<_>>()
        {
            if self.book.away.call_home(imp).is_some() {
                result.called_home.push(imp);
            }
        }
        self.deliver_notices();
        self.book.door = crypto::random_key().to_vec().into();
        self.book.invite = None;
        self.book.invite_shown = None;
        self.invite_on_screen = false;
        self.commit();
        // Visitors that came in with the old door key have no business here any more.
        for cid in self
            .conns
            .iter()
            .filter(|(_, c)| c.target.is_none())
            .map(|(cid, _)| *cid)
            .collect::<Vec<_>>()
        {
            self.retire(cid, now);
        }
        if self.running {
            self.out.push_back(Output::Relisten);
            self.out.push_back(Output::HopChanged);
        }
        result
    }

    /// The other side forgot us: ends the link on this side as `forget` does, without a goodbye. Our Imps
    /// it held are called home and the Imps of its that visit us are sent home.
    fn dropped(&mut self, device: Uuid, now: Time) -> Forgotten {
        let result = Forgotten {
            called_home: self.book.away.call_home_from(device),
            sent_home: self
                .book
                .visits
                .send_home_of(device, now)
                .iter()
                .map(|v| v.id())
                .collect(),
        };
        self.book.away.drop_notices(device);
        self.drop_link(device);
        result
    }

    /// Removes a link from the book (no goodbye, no Imps moved: the callers do that).
    fn drop_link(&mut self, device: Uuid) {
        self.book.links.retain(|l| l.id() != device);
        self.stages.remove(&device);
        self.commit();
    }

    // MARK: Throwing

    /// Throws an Imp to a connected peer. Returns the transfer, or None if the device is not a connected
    /// peer. The answer comes as `Event::Passed`. The app keeps the body until then. An Imp of this device
    /// gets a ticket for its holder. A visiting Imp is handed on with the ticket it has.
    pub fn pass(&mut self, imp: &LinkImp, entry: LinkEntry, to: Uuid, now: Time) -> Option<Uuid> {
        let cid = self.connections.get(&to).copied()?;
        if self.standing_of(to) != Some(Standing::Peer) {
            return None;
        }
        let (home, ticket) = match self.book.visits.visit(imp.id) {
            Some(visit) if visit.home.id() != to => {
                (Some(visit.home.clone()), Some(visit.ticket.clone()))
            }
            Some(_) => (None, None),
            None => {
                let ticket = self.book.away.mint(imp.id, to);
                (Some(self.card()), Some(ticket.to_vec().into()))
            }
        };
        let transfer = crypto::new_id();
        if home.as_ref().is_some_and(|h| h.id() == self.identity.id()) {
            self.book.passing.push(Passing {
                transfer,
                imp: imp.id,
                to,
            });
            self.commit();
            self.deliver_notices();
        }
        self.transfers.sent(
            transfer,
            imp.id,
            to,
            TransferKind::Pass,
            now,
            self.options.transfer_timeout,
        );
        self.send_on(
            cid,
            &LinkMessage::Pass {
                transfer,
                imp: imp.clone(),
                entry,
                home,
                ticket,
            },
        );
        Some(transfer)
    }

    /// Moves an Imp hatched here to a connected peer for good. The answer comes as `Event::Passed` (`Took`
    /// once the other user agreed).
    pub fn adopt(
        &mut self,
        imp: Uuid,
        kit: &str,
        secrets: LinkSecrets,
        entry: LinkEntry,
        to: Uuid,
        now: Time,
    ) -> Option<Uuid> {
        let cid = self.connections.get(&to).copied()?;
        if self.standing_of(to) != Some(Standing::Peer) {
            return None;
        }
        let transfer = crypto::new_id();
        self.transfers.sent(
            transfer,
            imp,
            to,
            TransferKind::Adopt,
            now,
            self.options.transfer_timeout,
        );
        self.send_on(
            cid,
            &LinkMessage::Adopt {
                transfer,
                imp,
                kit: kit.to_string(),
                secrets,
                entry,
            },
        );
        Some(transfer)
    }

    /// Whether a thrown Imp (or adoption) still waits for the app's answer and can be taken. The app checks
    /// before it does anything it cannot undo (adopting an Imp's kit, say).
    pub fn can_accept(&self, transfer: Uuid) -> bool {
        self.arrivals.get(&transfer).is_some_and(|a| {
            self.connections.contains_key(&a.from) && self.transfers.is_waiting(transfer)
        })
    }

    /// The app takes an Imp (or an adoption) that was thrown here. False if it cannot any more: it timed
    /// out, the thrower left, or there is no room.
    pub fn accept(&mut self, transfer: Uuid, now: Time) -> bool {
        let Some(from) = self.arrivals.get(&transfer).map(|a| a.from) else {
            return false;
        };
        let Some(cid) = self
            .connections
            .get(&from)
            .copied()
            .filter(|_| self.transfers.is_waiting(transfer))
        else {
            self.arrivals.remove(&transfer);
            return false;
        };
        let Some(arrival) = self.arrivals.remove(&transfer) else {
            return false;
        };
        match arrival.kind {
            ArrivalKind::Pass(pass) => {
                let PassArrival {
                    imp,
                    entry,
                    home,
                    ticket,
                } = &*pass;
                match (home, ticket) {
                    (Some(home), Some(ticket)) => {
                        if !self.book.visits.arrive(imp, entry, from, home, ticket) {
                            self.arrivals.insert(
                                transfer,
                                Arrival {
                                    from,
                                    kind: ArrivalKind::Pass(pass),
                                },
                            );
                            self.decline(transfer, LinkDecline::Full);
                            return false;
                        }
                    }
                    _ => self.book.away.came_home(imp.id),
                }
                self.commit();
                self.transfers.answer(transfer, Reply::Took);
                self.send_on(cid, &LinkMessage::Took { transfer });
                if let Some(home) = home {
                    match self.connections.get(&home.id()).copied() {
                        Some(home_cid) => {
                            let ticket = self.book.visits.visit(imp.id).map(|v| v.ticket.0.clone());
                            let same_key = self
                                .conn_of(home.id())
                                .and_then(|c| c.remote.as_ref())
                                .is_some_and(|r| crypto::equal(&r.key.0, &home.device.key.0));
                            if let (Some(ticket), true) = (ticket, same_key) {
                                self.claim(home_cid, imp.id, ticket);
                            }
                        }
                        None => self.reconcile(now),
                    }
                }
            }
            ArrivalKind::Adopt => {
                self.transfers.answer(transfer, Reply::Took);
                self.send_on(cid, &LinkMessage::Adopted { transfer });
            }
        }
        true
    }

    /// The app turns down an Imp (or an adoption) that was thrown here. It bounces back.
    pub fn decline(&mut self, transfer: Uuid, reason: LinkDecline) {
        let Some(arrival) = self.arrivals.remove(&transfer) else {
            return;
        };
        if self.transfers.answer(transfer, Reply::Declined(reason)) {
            self.send(&LinkMessage::Declined { transfer, reason }, arrival.from);
        }
    }

    /// An answer to a throw of ours came in (or the throw ran out of time).
    fn answered(&mut self, transfer: Uuid, device: Uuid, outcome: PassOutcome, now: Time) {
        let Some(throwing) = self.transfers.answered(transfer, device) else {
            // A `took` after we gave up: the receiver has the body. A visit of ours leaves now. An Imp of
            // ours that is not theirs any more is told so.
            if outcome == PassOutcome::Took
                && let Some(late) = self.transfers.late(transfer, device, now)
                && late.kind == TransferKind::Pass
            {
                if self.book.visits.visit(late.imp).is_some() {
                    self.finish_pass(&late, PassOutcome::Took, now);
                } else if self.book.away.holder(late.imp) != Some(late.to) {
                    self.send(&LinkMessage::Gone { imp: late.imp }, late.to);
                }
            }
            return;
        };
        self.finish_pass(&throwing, outcome, now);
    }

    fn finish_pass(
        &mut self,
        t: &crate::link::transfers::Outgoing,
        outcome: PassOutcome,
        _now: Time,
    ) {
        let mut outcome = outcome;
        if t.kind == TransferKind::Pass {
            if self.book.passing.iter().any(|p| p.transfer == t.id) {
                self.book.passing.retain(|p| p.transfer != t.id);
                self.commit();
            }
            match outcome {
                PassOutcome::Took => {
                    if let Some(visit) = self.book.visits.leave(t.imp) {
                        // It is gone from here, and a visit's ticket went with it. Its home hears where it
                        // went (if it is not the home itself), even when it is not linked with that device.
                        if visit.home.id() != t.to
                            && let Some(link) = self.book.links.iter().find(|l| l.id() == t.to)
                        {
                            let to = LinkWho {
                                id: t.to,
                                name: link.device.name.clone(),
                                kind: link.device.kind,
                            };
                            self.book.handed.retain(|h| h.imp != t.imp);
                            self.book.handed.push(Handed {
                                imp: t.imp,
                                home: visit.home.id(),
                                to,
                            });
                            let extra = self.book.handed.len().saturating_sub(MAX_HANDED);
                            self.book.handed.drain(..extra);
                            self.deliver_handed();
                        }
                        self.commit();
                    } else if self.book.away.holder(t.imp) != Some(t.to) {
                        // We called it home meanwhile: the receiver must let go.
                        self.send(&LinkMessage::Gone { imp: t.imp }, t.to);
                        outcome = PassOutcome::Declined(LinkDecline::Other);
                    }
                }
                PassOutcome::Declined(reason) => {
                    // An Imp of ours that was not taken is not away. If we cannot tell whether it was (no
                    // answer), the receiver is told to let go in case it took it after all.
                    if self.book.visits.visit(t.imp).is_none() {
                        if reason == LinkDecline::Timeout {
                            self.book.away.call_home(t.imp);
                            self.deliver_notices();
                        } else {
                            self.book.away.came_home(t.imp);
                        }
                        self.commit();
                    }
                }
            }
        }
        self.emit(Event::Passed(Passed {
            transfer: t.id,
            imp: t.imp,
            to: t.to,
            kind: t.kind,
            outcome,
        }));
    }

    #[allow(clippy::too_many_arguments)]
    fn on_pass(
        &mut self,
        cid: ConnId,
        transfer: Uuid,
        imp: LinkImp,
        entry: LinkEntry,
        home: Option<LinkCard>,
        ticket: Option<Vec<u8>>,
        message: LinkMessage,
        now: Time,
    ) {
        let Some(remote) = self.conns.get(&cid).and_then(|c| c.remote.clone()) else {
            return;
        };
        let from = remote.id;
        if !self.is_new(cid, transfer, from, self.options.transfer_timeout, now) {
            return;
        }
        if let Some(reason) = self
            .refusal(&imp, home.as_ref(), &remote)
            .or_else(|| self.crowded(from))
        {
            self.transfers.answer(transfer, Reply::Declined(reason));
            self.send_on(cid, &LinkMessage::Declined { transfer, reason });
            return;
        }
        self.arrivals.insert(
            transfer,
            Arrival {
                from,
                kind: ArrivalKind::Pass(Box::new(PassArrival {
                    imp,
                    entry,
                    home,
                    ticket,
                })),
            },
        );
        self.emit(Event::Message(message, from));
    }

    fn on_adopt(
        &mut self,
        cid: ConnId,
        transfer: Uuid,
        _imp: Uuid,
        message: LinkMessage,
        now: Time,
    ) {
        let Some(from) = self.remote_id(cid) else {
            return;
        };
        if !self.is_new(
            cid,
            transfer,
            from,
            crate::link::transfers::ADOPT_TIMEOUT,
            now,
        ) {
            return;
        }
        if let Some(reason) = self.crowded(from) {
            self.transfers.answer(transfer, Reply::Declined(reason));
            self.send_on(cid, &LinkMessage::Declined { transfer, reason });
            return;
        }
        self.arrivals.insert(
            transfer,
            Arrival {
                from,
                kind: ArrivalKind::Adopt,
            },
        );
        self.emit(Event::Message(message, from));
    }

    /// `Full` if `sender` already has as many throws waiting as it may (the one just noted counts).
    fn crowded(&self, sender: Uuid) -> Option<LinkDecline> {
        (self.transfers.waiting(sender) > WAITING_PER_SENDER).then_some(LinkDecline::Full)
    }

    /// Notes a throw that arrived. False if it was a repeat (answered again, or still waiting).
    fn is_new(&mut self, cid: ConnId, transfer: Uuid, from: Uuid, timeout: f64, now: Time) -> bool {
        match self.transfers.received(transfer, from, now, timeout) {
            Received::New => true,
            Received::Pending => false,
            Received::Repeated(reply) => {
                match reply {
                    Reply::Took => {
                        self.send_on(cid, &LinkMessage::Took { transfer });
                    }
                    Reply::Declined(reason) => {
                        self.send_on(cid, &LinkMessage::Declined { transfer, reason });
                    }
                    Reply::Waiting => {}
                }
                false
            }
        }
    }

    /// Why a thrown Imp cannot come in, if it cannot.
    fn refusal(
        &self,
        imp: &LinkImp,
        home: Option<&LinkCard>,
        sender: &LinkDevice,
    ) -> Option<LinkDecline> {
        let Some(home) = home else {
            // Coming home: only its holder can bring it.
            return (!self.book.away.authorises(sender.id, imp.id))
                .then_some(LinkDecline::NotLinked);
        };
        if home.id() == self.identity.id() || self.book.away.is_away(imp.id) {
            return Some(LinkDecline::NotLinked);
        }
        // An Imp of ours that is here, or one we already hold a visit of from somebody else, cannot be
        // thrown in again.
        if self
            .own_stage
            .iter()
            .any(|s| s.imp.id == imp.id && s.home.id == self.identity.id())
        {
            return Some(LinkDecline::Other);
        }
        let visit = self.book.visits.visit(imp.id);
        if visit.is_some_and(|v| v.from != sender.id) {
            return Some(LinkDecline::Other);
        }
        if self
            .book
            .links
            .iter()
            .find(|l| l.id() == home.id())
            .is_some_and(|l| !crypto::equal(&l.device.key.0, &home.device.key.0))
        {
            return Some(LinkDecline::NotLinked);
        }
        if home.id() == sender.id && !crypto::equal(&home.device.key.0, &sender.key.0) {
            return Some(LinkDecline::NotLinked);
        }
        if visit.is_none() && self.book.visits.is_full() {
            return Some(LinkDecline::Full);
        }
        None
    }

    // MARK: Away and visiting Imps

    /// Takes one of this device's Imps back from its holder at any time: its ticket dies and the holder is
    /// told as soon as it can be. Returns the holder, if it was away.
    pub fn call_home(&mut self, imp: Uuid) -> Option<Uuid> {
        let holder = self.book.away.call_home(imp);
        self.commit();
        self.deliver_notices();
        holder
    }

    /// Sends a visiting Imp home from here (deleted, or its home forgotten): the body leaves now and the
    /// home hears as soon as it can be reached. False if it is not a visitor.
    pub fn send_home(&mut self, imp: Uuid, now: Time) -> bool {
        let Some(visit) = self.book.visits.send_home(imp, now) else {
            return false;
        };
        self.commit();
        match self.connections.get(&visit.home.id()).copied() {
            Some(cid) => self.claim_everything(cid),
            None => self.reconcile(now),
        }
        true
    }

    // MARK: Time

    /// Call this every half second or so, and whenever a timer the node asked for is due.
    pub fn tick(&mut self, now: Time) {
        if !self.running {
            return;
        }
        for t in self.transfers.expired(now) {
            self.finish_pass(&t, PassOutcome::Declined(LinkDecline::Timeout), now);
        }
        for (id, _) in self.transfers.lapsed(now) {
            self.arrivals.remove(&id);
        }
        // Nothing stays that no longer waits for the app.
        let stale: Vec<Uuid> = self
            .arrivals
            .keys()
            .filter(|id| !self.transfers.is_waiting(**id))
            .copied()
            .collect();
        for id in stale {
            self.arrivals.remove(&id);
        }
        self.uploads.expire(now);
        for q in self.talks.expired(now) {
            self.fail(&q);
        }
        let (silence, ping) = (self.options.silence_limit, self.options.ping_interval);
        let mut dead = Vec::new();
        let mut pings = Vec::new();
        for (cid, c) in &mut self.conns {
            let late = |d: Option<Time>| d.is_some_and(|d| now > d);
            if late(c.handshake_deadline)
                || late(c.grace_deadline)
                || (c.established && now - c.last_heard > silence)
            {
                c.timed_out = true;
                dead.push(*cid);
            } else if c.established && now - c.last_ping >= ping {
                c.last_ping = now;
                pings.push(*cid);
            }
        }
        for cid in dead {
            self.retire(cid, now);
        }
        for cid in pings {
            self.send_on(cid, &LinkMessage::Ping {});
        }
        self.book.visits.expire(now);
        let timed_out: Vec<Uuid> = self
            .joins
            .iter()
            .filter(|(_, j)| now >= j.deadline)
            .map(|(id, _)| *id)
            .collect();
        for device in timed_out {
            self.joins.remove(&device);
            self.dials.remove(&device);
            self.emit(Event::Joined {
                device,
                result: Err(JoinError::TimedOut),
            });
        }
        self.reconcile(now);
    }

    // MARK: Dialling

    /// Every device this one wants a connection to: its links (whose door key it knows), the homes of the
    /// Imps it holds or sent home, and the host of a code being scanned.
    fn wanted(&self) -> BTreeMap<Uuid, DialTarget> {
        let mut targets = BTreeMap::new();
        for home in self.book.visits.homes() {
            targets.insert(
                home.id(),
                DialTarget {
                    card: home,
                    join: None,
                },
            );
        }
        for card in self.book.links.iter().filter_map(LinkRecord::card) {
            targets.insert(card.id(), DialTarget { card, join: None });
        }
        for (id, join) in &self.joins {
            if let Some(invite) = key_of(&join.invite.invite) {
                targets.insert(
                    *id,
                    DialTarget {
                        card: join.invite.card(),
                        join: Some(invite),
                    },
                );
            }
        }
        targets.remove(&self.identity.id());
        targets
    }

    /// Asks for a dial to whatever is wanted and is not connected or being dialled, and stops dialling what
    /// is not wanted.
    fn reconcile(&mut self, now: Time) {
        if !self.running {
            return;
        }
        let targets = self.wanted();
        self.dials.retain(|id, _| targets.contains_key(id));
        for (id, target) in &targets {
            if self.connections.contains_key(id) {
                continue;
            }
            let dial = self.dials.entry(*id).or_insert_with(|| Dial {
                wait_until: now + self.delays.get(id).copied().unwrap_or(0.0),
                in_flight: false,
                refused: false,
            });
            if !dial.in_flight && dial.wait_until <= now {
                dial.in_flight = true;
                self.out.push_back(Output::Dial(DialRequest {
                    device: *id,
                    card: target.card.clone(),
                }));
            }
        }
    }

    /// Every route to `device` failed. The node waits (longer each time, up to the longest) and asks again.
    pub fn dial_failed(&mut self, device: Uuid, now: Time) {
        let Some(dial) = self.dials.get_mut(&device) else {
            return;
        };
        let refused = dial.refused;
        dial.refused = false;
        dial.in_flight = false;
        if refused && self.reported.insert(device) {
            self.emit(Event::Problem(Problem::Refused(device)));
        }
        if self.joins.remove(&device).is_some() {
            self.dials.remove(&device);
            let error = if refused {
                JoinError::Refused
            } else {
                JoinError::Unreachable
            };
            self.emit(Event::Joined {
                device,
                result: Err(error),
            });
            return self.reconcile(now);
        }
        self.delay_more(device);
        let wait = self.delays.get(&device).copied().unwrap_or(0.0);
        if let Some(dial) = self.dials.get_mut(&device) {
            dial.wait_until = now + wait;
        }
    }

    /// Dial again now: devices were found on the local network (`Some`), or the network changed (`None`).
    pub fn kick(&mut self, devices: Option<&[Uuid]>, now: Time) {
        let ids: Vec<Uuid> = match devices {
            Some(list) => list.to_vec(),
            None => self.dials.keys().copied().collect(),
        };
        for id in ids {
            self.delays.remove(&id);
            if let Some(dial) = self.dials.get_mut(&id)
                && !dial.in_flight
            {
                dial.wait_until = now;
            }
        }
        self.reconcile(now);
    }
}

#[cfg(test)]
mod retry_tests {
    use super::Options;

    #[test]
    fn waits_double_from_the_start_up_to_the_longest() {
        let o = Options::default();
        let mut waits = Vec::new();
        let mut previous = 0.0;
        for _ in 0..9 {
            previous = o.next_retry(previous);
            waits.push(previous);
        }
        assert_eq!(waits, [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 60.0, 60.0, 60.0]);
    }
}
