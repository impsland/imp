//! This computer as one of the person's devices, doing what the Mac and iPhone apps do on the link
//! (`docs/connecting/link.md`):
//!
//! - **Home.** An Imp of this computer can be sent to a linked Mac or iPhone. Its body shows there, and it
//!   keeps thinking here: what the other device asks it (`ask`) is answered with its own model, and its work
//!   and its chat are sent back as they change. `/call` brings it back, with its conversation.
//! - **Holder.** An Imp a Mac or an iPhone sends here is a visitor. The chat can talk to it: what is said
//!   goes to its home, and its home sends its chat back. It can be sent on, or home.
//! - **Troupe.** Every device tells the others which Imps are on its screen, so Imps message each other
//!   across devices (`imp_message`), as in the apps.
//!
//! The node in `imp-engine` keeps the rules (who may ask what, tickets, timeouts). This file only reacts to
//! what it reports. It runs in the same task as the chat and is not `Send`.

use super::runner::{NodeHandle, Runner, now};
use super::{BookFile, SeedStore, local_hosts, new_device_id};
use crate::chat_state::ChatState;
use crate::session::{Session, SessionOptions, data_dir};
use crate::settings::{self, Settings};
use crate::troupe::{self, Remote, RemoteImp};
use crate::{CliError, Result};
use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use imp_engine::link::card::{LinkKind, LinkRoutes};
use imp_engine::link::hop::HopAddress;
use imp_engine::link::node::{Ask, Event, JoinError, Node, Options, PassOutcome, Passed, Problem};
use imp_engine::link::talks::First;
use imp_engine::link::{
    LinkDecline, LinkEntry, LinkImp, LinkInvite, LinkMessage, LinkSide, LinkStaged, LinkTurn,
    LinkWork, PORT,
};
use imp_engine::{AgentEvent, BoxFuture, ChatMessage, Role, StreamEvent, TalkStore, run_agent};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

/// Only one program at a time is this computer on the link: it holds this lock in the data folder.
const LOCK_FILE: &str = "link.lock";
/// The most turns sent to a holder, as the apps do.
const CHAT_PAGE: usize = 50;
/// Work in progress is sent at most this often while an answer streams.
const WORK_EVERY: Duration = Duration::from_millis(150);

/// How the device is set up.
#[derive(Debug, Clone, Default)]
pub struct DeviceOptions {
    /// The name other devices see. The computer's name if left out.
    pub name: Option<String>,
    /// Host names or addresses to give out. This computer's addresses if left out.
    pub hosts: Vec<String>,
    /// The Hop to wait at, as `host:port`.
    pub hop: Option<String>,
    /// Where the book is kept.
    pub data_dir: PathBuf,
    /// The configuration, for this computer's Imps. Without it there are none.
    pub settings: Option<Settings>,
    /// The folder a home answer works in (an Imp's file tools use it).
    pub workspace: Option<PathBuf>,
}

impl DeviceOptions {
    /// The usual data folder and the given configuration.
    pub fn usual(settings: &Settings) -> Result<Self> {
        Ok(Self {
            data_dir: data_dir()?,
            workspace: Some(settings.workspace.clone()),
            settings: Some(settings.clone()),
            hop: std::env::var("IMP_HOP")
                .ok()
                .filter(|h| !h.trim().is_empty()),
            ..Self::default()
        })
    }

    /// Whether this computer was ever linked, so starting the device is worth it.
    pub fn has_book(&self) -> bool {
        self.data_dir.join("link-book").exists()
    }
}

/// A device this computer is linked with, as the chat shows it.
#[derive(Debug, Clone, PartialEq)]
pub struct Peer {
    pub id: Uuid,
    pub name: String,
    pub kind: LinkKind,
    pub connected: bool,
    pub through_hop: bool,
    /// One of the owner's own devices: Imps use their tools for what it asks.
    pub trusted: bool,
    /// The Imps on its screen.
    pub stage: Vec<LinkStaged>,
}

/// An Imp from another device visiting this computer.
#[derive(Debug, Clone, PartialEq)]
pub struct Visitor {
    pub look: LinkImp,
    pub home: Uuid,
    pub home_name: String,
    /// The device that sent it here.
    pub from: Uuid,
    /// Its home can think for it now.
    pub awake: bool,
    pub turns: Vec<LinkTurn>,
    pub work: Option<LinkWork>,
}

/// What happened that the chat should show.
#[derive(Debug, Clone, PartialEq)]
pub enum Update {
    /// A sentence for the person.
    Note(String),
    /// Something went wrong.
    Problem(String),
    /// A visitor's chat or work changed.
    Visitor(Uuid),
    /// An Imp of this computer is on another device now.
    Away { imp: String, device: String },
    /// An Imp of this computer came back, with what it said while away.
    CameHome {
        imp: String,
        messages: Vec<ChatMessage>,
    },
    /// What another device asked an Imp of this computer, and how it is going.
    Asked { imp: String, line: String },
    /// A visitor left this computer.
    Left(Uuid),
    /// A visitor just came over (after the note that says so). A chat with nothing going on shows it.
    Arrived(Uuid),
}

/// What the views read: kept up to date as events come in.
#[derive(Default)]
struct Shared {
    me: Uuid,
    name: String,
    peers: Vec<Peer>,
    visitors: BTreeMap<Uuid, Visitor>,
    /// This computer's Imps that are away, and the device holding each.
    away: HashMap<Uuid, Uuid>,
    /// Questions to Imps on other devices waiting for their answer.
    talks: HashMap<Uuid, oneshot::Sender<std::result::Result<String, String>>>,
}

/// An Imp of this computer while it is away: its conversation, and its brain once it was needed.
struct HomeImp {
    name: String,
    chat: ChatState,
    turns: Vec<LinkTurn>,
    session: Option<Rc<Session>>,
    /// Stops the answer in progress.
    stop: Option<oneshot::Sender<()>>,
}

/// What a job running here (an answer for another device) reports when it ends.
enum Done {
    /// A home answer for the holder: the new conversation, and the turn to add.
    Home(Box<HomeDone>),
    /// An answer to another device's Imp, sent already.
    Answered,
}

struct HomeDone {
    imp: Uuid,
    chat: ChatState,
    turn: LinkTurn,
    session: Option<Rc<Session>>,
}

type Job = Pin<Box<dyn std::future::Future<Output = Done>>>;

/// A thrown Imp waiting for its answer.
struct Sending {
    name: String,
    to: String,
    messages: Vec<ChatMessage>,
    ours: bool,
}

/// This computer on the link. Make it with [`Device::start`], poll [`Device::next`] in the chat's loop.
pub struct Device {
    runner: Option<Runner>,
    handle: NodeHandle,
    events: mpsc::UnboundedReceiver<Event>,
    shared: Rc<RefCell<Shared>>,
    settings: Option<Settings>,
    workspace: Option<PathBuf>,
    /// Where conversations between Imps are kept.
    talks: PathBuf,
    homes: HashMap<Uuid, HomeImp>,
    sending: HashMap<Uuid, Sending>,
    jobs: FuturesUnordered<Job>,
    /// Updates made while handling a command, given out by `next`.
    queued: Vec<Update>,
    /// Work updates from running answers.
    work_tx: mpsc::UnboundedSender<(Uuid, Option<LinkWork>)>,
    work_rx: mpsc::UnboundedReceiver<(Uuid, Option<LinkWork>)>,
    /// What jobs on the node report back.
    inner_tx: mpsc::UnboundedSender<Inner>,
    inner_rx: mpsc::UnboundedReceiver<Inner>,
    _lock: File,
}

/// Why the device did not start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StartError {
    /// Another program is this computer on the link right now.
    Busy,
    Failed(String),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Busy => f.write_str(
                "Another imp program (imp link, imp qr or a chat) is online as this computer, so devices are handled there.",
            ),
            Self::Failed(why) => f.write_str(why),
        }
    }
}

impl From<CliError> for StartError {
    fn from(e: CliError) -> Self {
        Self::Failed(e.0)
    }
}

/// Takes the lock that makes this program the computer's device on the link.
fn lock(dir: &Path) -> std::result::Result<File, StartError> {
    std::fs::create_dir_all(dir).map_err(|e| StartError::Failed(e.to_string()))?;
    let file = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(LOCK_FILE))
        .map_err(|e| StartError::Failed(e.to_string()))?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(std::fs::TryLockError::WouldBlock) => Err(StartError::Busy),
        Err(std::fs::TryLockError::Error(e)) => Err(StartError::Failed(e.to_string())),
    }
}

/// The node for this computer: its book from the data folder (made the first time), its name and where to
/// reach it.
pub fn make_node(options: &DeviceOptions, seeds: Arc<dyn SeedStore>) -> Result<(Node, BookFile)> {
    let book = BookFile::in_dir(&options.data_dir, seeds);
    let saved = book.load()?;
    let name = options
        .name
        .clone()
        .or_else(computer_name)
        .unwrap_or_else(|| "Imp CLI".into());
    let mut node = Node::new(
        saved.as_deref(),
        &name,
        LinkKind::Mac,
        new_device_id(),
        Options::default(),
    )
    .map_err(|_| {
        CliError(format!(
            "The link book in {} cannot be read. Remove the file to start again.",
            book.path().display()
        ))
    })?;
    let hosts = if options.hosts.is_empty() {
        local_hosts()
    } else {
        options.hosts.clone()
    };
    node.set_hosts(hosts);
    if let Some(hop) = &options.hop {
        let address = HopAddress::parse(hop).ok_or_else(|| {
            CliError("The Hop must be written host:port, such as hop.example.org:4677.".into())
        })?;
        node.set_server(Some(address));
    }
    Ok((node, book))
}

fn computer_name() -> Option<String> {
    ["HOSTNAME", "COMPUTERNAME", "HOST"]
        .iter()
        .find_map(|v| std::env::var(v).ok())
        .or_else(|| {
            std::process::Command::new("hostname")
                .output()
                .ok()
                .and_then(|o| String::from_utf8(o.stdout).ok())
        })
        .map(|n| n.trim().split('.').next().unwrap_or_default().to_string())
        .filter(|n| !n.is_empty())
}

/// Says where a device that scans the code will look for this computer.
pub fn reach_note(routes: &LinkRoutes) -> String {
    match (routes.hosts.first(), &routes.hop) {
        (Some(host), _) => format!("On the same Wi-Fi, a device finds this computer at {host}."),
        (None, Some(hop)) => format!(
            "This computer has no network address, so devices come in through the Hop at {hop}."
        ),
        (None, None) => "This computer has no network address. Connect it to the Wi-Fi, or pass --host or --hop.".into(),
    }
}

impl Device {
    /// The configuration of this computer's Imps, read now.
    fn load(&self) -> Result<imp_engine::config::Loaded> {
        self.settings
            .as_ref()
            .map(Settings::load)
            .ok_or_else(|| CliError("This computer has no Imps to send.".into()))
    }

    /// Starts this computer on the link: the lock, the book, the listener and the node.
    pub async fn start(
        options: &DeviceOptions,
        seeds: Arc<dyn SeedStore>,
    ) -> std::result::Result<Self, StartError> {
        let lock = lock(&options.data_dir)?;
        let (node, book) = make_node(options, seeds)?;
        let listener = match TcpListener::bind(("0.0.0.0", PORT)).await {
            Ok(listener) => listener,
            Err(_) => TcpListener::bind(("0.0.0.0", 0))
                .await
                .map_err(|e| StartError::Failed(format!("Cannot listen: {e}")))?,
        };
        let me = node.device();
        let (events_tx, events) = mpsc::unbounded_channel();
        let runner = Runner::start(node, listener, events_tx, move |bytes| {
            book.save(bytes).map_err(|e| e.0)
        })?;
        let (work_tx, work_rx) = mpsc::unbounded_channel();
        let (inner_tx, inner_rx) = mpsc::unbounded_channel();
        let mut device = Self {
            handle: runner.handle(),
            runner: Some(runner),
            events,
            shared: Rc::new(RefCell::new(Shared {
                me: me.id,
                name: me.name,
                ..Shared::default()
            })),
            settings: options.settings.clone(),
            workspace: options.workspace.clone(),
            talks: options.data_dir.join("talks"),
            homes: HashMap::new(),
            sending: HashMap::new(),
            jobs: FuturesUnordered::new(),
            queued: Vec::new(),
            work_tx,
            work_rx,
            inner_tx,
            inner_rx,
            _lock: lock,
        };
        device.refresh_now().await;
        device.publish_stage();
        Ok(device)
    }

    /// This computer's name on the link.
    pub fn name(&self) -> String {
        self.shared.borrow().name.clone()
    }

    /// The linked devices, connected first.
    pub fn peers(&self) -> Vec<Peer> {
        self.shared.borrow().peers.clone()
    }

    /// The Imps visiting this computer.
    pub fn visitors(&self) -> Vec<Visitor> {
        self.shared.borrow().visitors.values().cloned().collect()
    }

    pub fn visitor(&self, imp: Uuid) -> Option<Visitor> {
        self.shared.borrow().visitors.get(&imp).cloned()
    }

    /// The device holding an Imp of this computer, by its name, if it is away.
    pub fn away_on(&self, imp: Uuid) -> Option<String> {
        let shared = self.shared.borrow();
        let holder = shared.away.get(&imp)?;
        Some(
            shared
                .peers
                .iter()
                .find(|p| p.id == *holder)
                .map_or_else(|| "another device".to_string(), |p| p.name.clone()),
        )
    }

    /// The Imps on other devices, for `imp_message`.
    pub fn remote(&self) -> Rc<dyn Remote> {
        Rc::new(DeviceRemote {
            shared: self.shared.clone(),
            handle: self.handle.clone(),
        })
    }

    /// A new code for another device to scan. The last one stops working.
    pub async fn invite(&self) -> Result<LinkInvite> {
        self.handle
            .with(|node, now| node.invite(now))
            .await
            .ok_or_else(stopped)
    }

    /// The code is off the screen. It still works for 15 minutes.
    pub async fn invite_hidden(&self) {
        self.handle.with(|node, now| node.invite_hidden(now)).await;
    }

    /// The peer called `name` (or whose name starts with it), connected or not.
    pub fn find_peer(&self, name: &str) -> Result<Peer> {
        let peers = self.peers();
        let wanted = name.trim().to_lowercase();
        let exact = peers.iter().find(|p| p.name.to_lowercase() == wanted);
        let found = exact.cloned().or_else(|| {
            let mut starting = peers
                .iter()
                .filter(|p| p.name.to_lowercase().starts_with(&wanted));
            match (starting.next(), starting.next()) {
                (Some(one), None) => Some(one.clone()),
                _ => None,
            }
        });
        found.ok_or_else(|| {
            let names: Vec<&str> = peers.iter().map(|p| p.name.as_str()).collect();
            if names.is_empty() {
                CliError("No device is linked yet. Use /pair, then scan the code with Imp on a Mac or an iPhone.".into())
            } else {
                CliError(format!(
                    "There is no linked device called {name}. The linked devices are: {}.",
                    names.join(", ")
                ))
            }
        })
    }

    /// Sends an Imp of this computer to a linked device. `messages` is its conversation so far: it
    /// stays here, and the device sees it. The answer comes later as an update.
    pub async fn send_imp(
        &mut self,
        name: &str,
        messages: Vec<ChatMessage>,
        to: &Peer,
    ) -> Result<()> {
        let loaded = self.load()?;
        let agent = &settings::find_imp(&loaded, Some(name))?.value;
        let name = agent.name.as_str();
        let look = settings::look_of(&loaded, agent, &settings::servers_of(&loaded, agent));
        if let Some(on) = self.away_on(look.id) {
            return Err(CliError(format!(
                "{name} is on {on} already. Use /call {name} to bring it back first."
            )));
        }
        self.throw(look, to, name, messages, true).await
    }

    /// Sends a visitor on to a linked device, or back to its home.
    pub async fn send_visitor(&mut self, imp: Uuid, to: &Peer) -> Result<()> {
        let visitor = self
            .visitor(imp)
            .ok_or_else(|| CliError("That Imp is not visiting any more.".into()))?;
        let name = visitor.look.name.clone();
        self.throw(visitor.look, to, &name, Vec::new(), false).await
    }

    async fn throw(
        &mut self,
        look: LinkImp,
        to: &Peer,
        name: &str,
        messages: Vec<ChatMessage>,
        ours: bool,
    ) -> Result<()> {
        if !to.connected {
            return Err(CliError(format!(
                "{} is not connected. Open Imp there, on the same Wi-Fi or with the same Hop.",
                to.name
            )));
        }
        let target = to.id;
        let entry = LinkEntry::after(LinkSide::Right, 0.5, 0.0);
        let transfer = self
            .handle
            .with(move |node, now| node.pass(&look, entry, target, now))
            .await
            .flatten()
            .ok_or_else(|| CliError(format!("{} is not connected.", to.name)))?;
        self.sending.insert(
            transfer,
            Sending {
                name: name.to_string(),
                to: to.name.clone(),
                messages,
                ours,
            },
        );
        Ok(())
    }

    /// Brings an Imp of this computer back from the device that holds it.
    pub async fn call_home(&mut self, name: &str) -> Result<Update> {
        let loaded = self.load()?;
        let name = settings::find_imp(&loaded, Some(name))?.value.name.as_str();
        let id = settings::imp_id(&loaded, name);
        let holder = self
            .handle
            .with(move |node, _| node.call_home(id))
            .await
            .flatten();
        if holder.is_none() && !self.shared.borrow().away.contains_key(&id) {
            return Err(CliError(format!("{name} is here already.")));
        }
        self.shared.borrow_mut().away.remove(&id);
        let messages = self.came_home(id);
        self.publish_stage();
        self.refresh_now().await;
        Ok(Update::CameHome {
            imp: name.to_string(),
            messages,
        })
    }

    /// Sends a visitor home. Its body leaves now and its home hears as soon as it can be reached.
    pub async fn send_home(&mut self, imp: Uuid) -> Result<()> {
        let visitor = self
            .visitor(imp)
            .ok_or_else(|| CliError("That Imp is not visiting any more.".into()))?;
        let home = self.peers().into_iter().find(|p| p.id == visitor.home);
        if let Some(home) = home.filter(|h| h.connected) {
            // Thrown to its home, it lands there.
            return self.send_visitor(imp, &home).await;
        }
        self.handle
            .with(move |node, now| node.send_home(imp, now))
            .await;
        self.shared.borrow_mut().visitors.remove(&imp);
        self.publish_stage();
        Ok(())
    }

    /// Asks a visitor something: it goes to its home, and its chat comes back as updates.
    pub async fn ask_visitor(&self, imp: Uuid, text: &str) -> Result<()> {
        let visitor = self
            .visitor(imp)
            .ok_or_else(|| CliError("That Imp is not visiting any more.".into()))?;
        if !visitor.awake {
            return Err(CliError(format!(
                "{} is asleep: its home, {}, is not connected.",
                visitor.look.name, visitor.home_name
            )));
        }
        let message = LinkMessage::Ask {
            imp,
            text: text.chars().take(imp_engine::link::MAX_TEXT).collect(),
        };
        let home = visitor.home;
        let sent = self
            .handle
            .with(move |node, _| node.send(&message, home))
            .await
            .unwrap_or(false);
        if sent {
            Ok(())
        } else {
            Err(CliError(format!(
                "{} could not be reached.",
                visitor.home_name
            )))
        }
    }

    /// Stops the answer a visitor is giving, or starts its chat over.
    pub async fn tell_visitor(&self, imp: Uuid, new_chat: bool) {
        let Some(visitor) = self.visitor(imp) else {
            return;
        };
        let message = if new_chat {
            LinkMessage::NewChat { imp }
        } else {
            LinkMessage::Stop { imp }
        };
        let home = visitor.home;
        self.handle.post(move |node, _| {
            node.send(&message, home);
        });
    }

    /// Marks a device as one of the owner's own (Imps use their tools for it), or not.
    pub async fn set_trusted(&mut self, device: Uuid, on: bool) {
        self.handle
            .with(move |node, _| node.set_trusted(device, on))
            .await;
        self.refresh_now().await;
        self.resend_brains();
    }

    /// Ends the link with a device. Its Imps here go home, and this computer's Imps there come back.
    pub async fn forget(&mut self, device: Uuid) -> Vec<Update> {
        let result = self
            .handle
            .with(move |node, now| node.forget(device, now))
            .await
            .unwrap_or_default();
        let updates = self.forgotten(result);
        self.refresh_now().await;
        self.publish_stage();
        updates
    }

    /// Stops the node: every connection closes. Imps that are away keep their place for next time.
    pub async fn stop(mut self) {
        if let Some(runner) = self.runner.take() {
            runner.stop().await;
        }
    }

    /// Waits for the next thing to show. Runs answers for other devices meanwhile, so it must be polled
    /// while the chat waits for anything else. It is cancel-safe: handling an event never waits, so a
    /// `select!` that takes another branch loses nothing.
    pub async fn next(&mut self) -> Update {
        loop {
            if !self.queued.is_empty() {
                return self.queued.remove(0);
            }
            tokio::select! {
                event = self.events.recv() => {
                    let Some(event) = event else {
                        return std::future::pending().await;
                    };
                    self.on_event(event);
                }
                Some(inner) = self.inner_rx.recv() => self.on_inner(inner),
                Some((imp, work)) = self.work_rx.recv() => self.send_work(imp, work),
                Some(done) = self.jobs.next(), if !self.jobs.is_empty() => self.finished(done),
            }
        }
    }

    // MARK: Events

    fn on_event(&mut self, event: Event) {
        link_log(&event);
        match event {
            Event::Connected(device, _) => {
                self.refresh();
                self.publish_stage();
                self.resend_all(device.id);
                self.queued
                    .push(Update::Note(format!("{} is connected.", device.name)));
            }
            Event::Disconnected(device) => {
                let name = self.peer_name(device);
                self.refresh();
                if let Some(name) = name {
                    self.queued
                        .push(Update::Note(format!("{name} disconnected.")));
                }
            }
            Event::Linked(device) => {
                self.refresh();
                self.queued.push(Update::Note(format!(
                    "Linked with {}. Send it an Imp with /send {}.",
                    device.name, device.name
                )));
            }
            Event::Forgotten(device, result) => {
                let name = self.peer_name(device);
                let updates = self.forgotten(result);
                self.queued.extend(updates);
                self.refresh();
                self.publish_stage();
                self.queued.push(Update::Note(format!(
                    "{} forgot this computer.",
                    name.unwrap_or_else(|| "A device".into())
                )));
            }
            Event::Passed(passed) => self.passed(passed),
            Event::Joined {
                result: Err(JoinError::Unreachable),
                ..
            } => self
                .queued
                .push(Update::Problem("That device could not be reached.".into())),
            Event::Joined { .. } => {}
            Event::Problem(problem) => {
                if let Some(text) = describe(&problem) {
                    self.queued.push(Update::Problem(text));
                }
            }
            Event::Message(message, from) => self.on_message(message, from),
        }
    }

    fn on_message(&mut self, message: LinkMessage, from: Uuid) {
        match message {
            LinkMessage::Stage { .. } => self.refresh(),
            LinkMessage::Pass {
                transfer,
                imp,
                home,
                ..
            } => self.thrown(transfer, imp, home.is_some(), from),
            LinkMessage::Adopt { transfer, .. } => {
                // Moving in for good needs the review the Mac shows. The terminal says no for now.
                self.handle
                    .post(move |node, _| node.decline(transfer, LinkDecline::Other));
                self.queued.push(Update::Note(
                    "A device offered an Imp to move in for good. The terminal app can host it as a visitor, so send it over instead.".into(),
                ));
            }
            LinkMessage::Claim { imp, .. } => {
                // A new holder: it is told everything afresh.
                self.shared.borrow_mut().away.insert(imp, from);
                self.ensure_home(imp);
                self.send_everything(imp, from);
                self.refresh();
            }
            LinkMessage::Release { imp, .. } => {
                if let Some(name) = self.imp_name(imp) {
                    self.shared.borrow_mut().away.remove(&imp);
                    let messages = self.came_home(imp);
                    self.queued.push(Update::CameHome {
                        imp: name,
                        messages,
                    });
                    self.publish_stage();
                }
            }
            LinkMessage::Ask { imp, text } => self.asked(imp, text, from),
            LinkMessage::Stop { imp } => {
                if let Some(stop) = self.homes.get_mut(&imp).and_then(|h| h.stop.take()) {
                    let _ = stop.send(());
                }
            }
            LinkMessage::NewChat { imp } => {
                if let Some(home) = self.homes.get_mut(&imp) {
                    home.chat.clear();
                    home.turns.clear();
                    let message = LinkMessage::Chat {
                        imp,
                        turns: Vec::new(),
                    };
                    self.handle.post(move |node, _| {
                        node.send(&message, from);
                    });
                }
            }
            LinkMessage::Felt { imp, feeling } => {
                if let Some(name) = self.imp_name(imp) {
                    let felt = match feeling {
                        imp_engine::link::LinkFeeling::Poke => "poked",
                        imp_engine::link::LinkFeeling::Cuddle => "cuddled",
                        imp_engine::link::LinkFeeling::Shake => "shook",
                        imp_engine::link::LinkFeeling::Drop => "dropped",
                    };
                    let device = self.peer_name(from).unwrap_or_default();
                    self.queued.push(Update::Asked {
                        imp: name.clone(),
                        line: format!("{device} {felt} {name}."),
                    });
                }
            }
            LinkMessage::File { id, .. } => {
                let message = LinkMessage::FileFailed {
                    id,
                    reason: "The terminal app doesn't share files yet.".into(),
                };
                self.handle.post(move |node, _| {
                    node.send(&message, from);
                });
            }
            LinkMessage::Talks { imp } => {
                let message = LinkMessage::TalkLines {
                    imp,
                    lines: Vec::new(),
                };
                self.handle.post(move |node, _| {
                    node.send(&message, from);
                });
            }
            LinkMessage::Message {
                id,
                from: asker,
                to,
                text,
                ..
            } => self.message(id, asker, to, text, from),
            LinkMessage::Answer { id, text, failed } => {
                if let Some(waiting) = self.shared.borrow_mut().talks.remove(&id) {
                    let _ = waiting.send(if failed { Err(text) } else { Ok(text) });
                }
            }
            // What a visitor's home says about it.
            LinkMessage::Look { imp } => {
                let id = imp.id;
                if let Some(v) = self.shared.borrow_mut().visitors.get_mut(&id) {
                    v.look = imp;
                }
                self.queued.push(Update::Visitor(id));
            }
            LinkMessage::Chat { imp, turns } => {
                if let Some(v) = self.shared.borrow_mut().visitors.get_mut(&imp) {
                    v.turns = turns;
                }
                self.queued.push(Update::Visitor(imp));
            }
            LinkMessage::Work { imp, work } => {
                if let Some(v) = self.shared.borrow_mut().visitors.get_mut(&imp) {
                    v.work = work;
                }
                self.queued.push(Update::Visitor(imp));
            }
            LinkMessage::Brain { imp, ready, .. } => {
                if let Some(v) = self.shared.borrow_mut().visitors.get_mut(&imp) {
                    v.awake = ready;
                }
                self.queued.push(Update::Visitor(imp));
            }
            LinkMessage::Gone { imp } => {
                let left = self.shared.borrow_mut().visitors.remove(&imp);
                if let Some(v) = left {
                    self.publish_stage();
                    self.queued.push(Update::Left(imp));
                    self.queued.push(Update::Note(format!(
                        "{} went back to {}.",
                        v.look.name, v.home_name
                    )));
                }
            }
            _ => {}
        }
    }

    /// An Imp was thrown here: one of ours coming home, or a visitor.
    fn thrown(&mut self, transfer: Uuid, imp: LinkImp, has_home: bool, from: Uuid) {
        let ours = self.imp_name(imp.id);
        let device = self.peer_name(from).unwrap_or_else(|| "A device".into());
        if has_home == ours.is_some() {
            // An Imp of this computer is never somebody's visitor here, and an Imp that isn't ours needs a
            // home to think at.
            self.handle
                .post(move |node, _| node.decline(transfer, LinkDecline::Other));
            return;
        }
        let back = self.inner_tx.clone();
        self.handle.post(move |node, now| {
            let took = node.accept(transfer, now);
            let home = node
                .visits()
                .visit(imp.id)
                .map(|v| (v.home.id(), v.home.device.name.clone()));
            let _ = back.send(Inner::Accepted {
                look: Box::new(imp),
                ours,
                took,
                from: device,
                home,
            });
        });
    }

    /// What became of an Imp thrown here.
    fn on_inner(&mut self, inner: Inner) {
        match inner {
            Inner::Snapshot(snapshot) => self.apply(*snapshot),
            Inner::Accepted { took: false, .. } => {}
            Inner::Accepted {
                look,
                ours: Some(name),
                ..
            } => {
                self.shared.borrow_mut().away.remove(&look.id);
                let messages = self.came_home(look.id);
                self.queued.push(Update::CameHome {
                    imp: name,
                    messages,
                });
                self.publish_stage();
            }
            Inner::Accepted {
                look,
                ours: None,
                from,
                home,
                ..
            } => {
                let id = look.id;
                let name = look.name.clone();
                if let Some((home, home_name)) = home {
                    let awake = self
                        .shared
                        .borrow()
                        .peers
                        .iter()
                        .any(|p| p.id == home && p.connected);
                    let from_id = self
                        .shared
                        .borrow()
                        .peers
                        .iter()
                        .find(|p| p.name == from)
                        .map_or(home, |p| p.id);
                    self.shared.borrow_mut().visitors.insert(
                        id,
                        Visitor {
                            look: *look,
                            home,
                            home_name,
                            from: from_id,
                            awake,
                            turns: Vec::new(),
                            work: None,
                        },
                    );
                }
                self.refresh();
                self.publish_stage();
                self.queued.push(Update::Note(format!(
                    "{name} came over from {from}. Talk to it with /imp {name}, send it back with /return {name}."
                )));
                self.queued.push(Update::Arrived(id));
                self.queued.push(Update::Visitor(id));
            }
        }
    }

    /// A throw of ours was answered.
    fn passed(&mut self, passed: Passed) {
        let Some(sending) = self.sending.remove(&passed.transfer) else {
            self.refresh();
            return;
        };
        match passed.outcome {
            PassOutcome::Took if sending.ours => {
                self.shared.borrow_mut().away.insert(passed.imp, passed.to);
                let system = self
                    .load()
                    .ok()
                    .and_then(|l| {
                        l.agents.get(&sending.name).map(|a| {
                            settings::system_prompt(&a.value, l.config.imps.get(&sending.name))
                        })
                    })
                    .unwrap_or_default();
                let chat = ChatState::from_messages(system, sending.messages);
                let turns = turns_of(chat.messages());
                self.homes.insert(
                    passed.imp,
                    HomeImp {
                        name: sending.name.clone(),
                        chat,
                        turns,
                        session: None,
                        stop: None,
                    },
                );
                self.send_everything(passed.imp, passed.to);
                self.publish_stage();
                self.queued.push(Update::Away {
                    imp: sending.name,
                    device: sending.to,
                });
            }
            PassOutcome::Took => {
                self.shared.borrow_mut().visitors.remove(&passed.imp);
                self.publish_stage();
                self.queued.push(Update::Left(passed.imp));
                self.queued.push(Update::Note(format!(
                    "{} is on {} now.",
                    sending.name, sending.to
                )));
            }
            PassOutcome::Declined(reason) => {
                let why = match reason {
                    LinkDecline::Full => "it has no room for another Imp",
                    LinkDecline::Playing => "it is in the middle of a game",
                    LinkDecline::NotLinked => "it is not linked with this computer any more",
                    LinkDecline::Timeout => "it did not answer in time",
                    LinkDecline::Other => "it said no",
                };
                self.queued.push(Update::Problem(format!(
                    "{} did not take {}: {why}.",
                    sending.to, sending.name
                )));
            }
        }
        self.refresh();
    }

    /// A holder asked an Imp of this computer something: it thinks here and the holder sees it happen.
    fn asked(&mut self, imp: Uuid, text: String, from: Uuid) {
        let words: String = text
            .trim()
            .chars()
            .take(imp_engine::link::MAX_TEXT)
            .collect();
        if words.is_empty() || self.imp_name(imp).is_none() {
            return;
        }
        self.ensure_home(imp);
        let handle = self.handle.clone();
        let device = self.peer_name(from).unwrap_or_else(|| "a device".into());
        let settings = self.settings.clone().map(|s| match &self.workspace {
            Some(w) => Settings {
                workspace: w.clone(),
                ..s
            },
            None => s,
        });
        let Some(home) = self.homes.get_mut(&imp) else {
            return;
        };
        if home.stop.is_some() {
            return; // one answer at a time, as in the apps
        }
        let (stop, stopped) = oneshot::channel();
        home.stop = Some(stop);
        let name = home.name.clone();
        let session = home.session.clone();
        let mut chat = std::mem::take(&mut home.chat);
        chat.push_user(&words);
        self.queued.push(Update::Asked {
            imp: name.clone(),
            line: format!("{device} asks {name}: {words}"),
        });
        let work = self.work_tx.clone();
        let request = words.clone();
        self.jobs.push(Box::pin(async move {
            // Only the owner's own devices make an Imp use its tools.
            let trusted = handle
                .with(move |node, _| node.is_trusted(from))
                .await
                .unwrap_or(false);
            let session = match (session, settings) {
                (Some(s), _) => Some(s),
                (None, Some(settings)) => Session::open(
                    &settings,
                    Some(&name),
                    SessionOptions {
                        remote: None,
                        answers_later: false,
                        asker: None,
                    },
                )
                .await
                .ok()
                .map(Rc::new),
                (None, None) => None,
            };
            let started = now();
            let mut turn = LinkTurn {
                id: new_device_id(),
                date: started,
                request: request.clone(),
                from: None,
                reply: String::new(),
                failed: false,
                steps: Vec::new(),
            };
            let Some(s) = session.clone() else {
                turn.failed = true;
                turn.reply = "Its settings could not be read on its home computer.".into();
                return Done::Home(Box::new(HomeDone {
                    imp,
                    chat,
                    turn,
                    session,
                }));
            };
            let _ = work.send((
                imp,
                Some(LinkWork {
                    request: request.clone(),
                    status: None,
                    partial: String::new(),
                    from: None,
                }),
            ));
            let mut messages = chat.request_messages_with(&s.system);
            let selection = imp_engine::ToolSelection::all();
            let no_tools = imp_engine::Toolbox::new();
            let toolbox: &dyn imp_engine::ToolHost = if trusted { &*s.toolbox } else { &no_tools };
            let partial = RefCell::new(String::new());
            let status = RefCell::new(None::<String>);
            let steps = RefCell::new(Vec::<String>::new());
            // When the model began thinking. Only that it thought goes to the other device, as a step.
            let thinking = RefCell::new(None::<Instant>);
            let last = RefCell::new(Instant::now());
            let run = run_agent(
                &s.client,
                &s.model,
                &mut messages,
                toolbox,
                &selection,
                s.max_steps,
                |event| {
                    if let AgentEvent::Stream(StreamEvent::Reasoning(_)) = &event {
                        thinking.borrow_mut().get_or_insert_with(Instant::now);
                    } else if let Some(since) = thinking.borrow_mut().take() {
                        let seconds = since.elapsed().as_secs_f64().ceil().max(1.0);
                        steps.borrow_mut().push(format!("Thought for {seconds}s"));
                    }
                    match &event {
                        AgentEvent::Stream(StreamEvent::Text(t)) => {
                            partial.borrow_mut().push_str(t)
                        }
                        AgentEvent::ToolStart(call) => {
                            let title = format!("Using {}", call.name);
                            steps.borrow_mut().push(format!("Used {}", call.name));
                            *status.borrow_mut() = Some(title);
                        }
                        AgentEvent::ToolResult { .. } => *status.borrow_mut() = None,
                        AgentEvent::StepStart => partial.borrow_mut().clear(),
                        _ => {}
                    }
                    chat.apply_agent(&event);
                    if last.borrow().elapsed() >= WORK_EVERY
                        || matches!(event, AgentEvent::ToolStart(_))
                    {
                        *last.borrow_mut() = Instant::now();
                        let _ = work.send((
                            imp,
                            Some(LinkWork {
                                request: request.clone(),
                                status: status.borrow().clone(),
                                partial: partial.borrow().clone(),
                                from: None,
                            }),
                        ));
                    }
                },
            );
            let result = tokio::select! {
                result = run => Some(result),
                _ = stopped => None,
            };
            let finished = result.is_some();
            match result {
                Some(Ok(text)) => turn.reply = text,
                Some(Err(e)) => {
                    turn.failed = true;
                    turn.reply = e.to_string();
                }
                None => {
                    turn.reply = partial.borrow().clone();
                }
            }
            if chat.is_streaming() {
                chat.abort_reply();
            }
            chat.finish_exchange(!turn.failed && finished);
            turn.steps = steps.into_inner();
            Done::Home(Box::new(HomeDone {
                imp,
                chat,
                turn,
                session,
            }))
        }));
    }

    /// An Imp of another device messages an Imp of this computer, which answers without tools.
    fn message(&mut self, id: Uuid, asker: LinkImp, to: Uuid, text: String, from: Uuid) {
        let handle = self.handle.clone();
        let Some(target) = self.imp_name(to) else {
            let failure = LinkMessage::Answer {
                id,
                text: "That Imp isn't on this computer.".into(),
                failed: true,
            };
            handle.post(move |node, _| {
                node.send(&failure, from);
            });
            return;
        };
        let device = self.peer_name(from).unwrap_or_else(|| "a device".into());
        self.queued.push(Update::Asked {
            imp: target.clone(),
            line: format!("{} (on {device}) messages {target}: {text}", asker.name),
        });
        let settings = self.settings.clone();
        let talks = self.talks.clone();
        self.jobs.push(Box::pin(async move {
            let answer = async {
                let loaded = settings.ok_or("This computer has no Imps.")?.load();
                let store = TalkStore::new(talks);
                troupe::answer_here(
                    &loaded,
                    &store,
                    &asker.name,
                    &target,
                    &text,
                    None,
                    troupe::clock(),
                )
                .await
            }
            .await;
            let (text, failed) = match answer {
                Ok(text) => (text, false),
                Err(why) => (why, true),
            };
            let message = LinkMessage::Answer { id, text, failed };
            handle.post(move |node, _| {
                node.send(&message, from);
            });
            Done::Answered
        }));
    }

    fn finished(&mut self, done: Done) {
        let Done::Home(home) = done else {
            return;
        };
        let HomeDone {
            imp,
            chat,
            turn,
            session,
        } = *home;
        let holder = self.shared.borrow().away.get(&imp).copied();
        let Some(home) = self.homes.get_mut(&imp) else {
            return;
        };
        home.stop = None;
        home.session = session;
        home.chat = chat;
        let line = if turn.failed {
            format!("{} could not answer: {}", home.name, turn.reply)
        } else {
            format!("{} answered: {}", home.name, first_line(&turn.reply))
        };
        home.turns.push(turn);
        let name = home.name.clone();
        let turns = tail(&home.turns);
        self.queued.push(Update::Asked { imp: name, line });
        if let Some(holder) = holder {
            // The chat with the answer comes first: a holder shows the newest turn when the work ends
            // (`docs/connecting/link.md`, "chat" and "work").
            let messages = [
                LinkMessage::Chat { imp, turns },
                LinkMessage::Work { imp, work: None },
                LinkMessage::Mood {
                    imp,
                    mood: "idle".into(),
                },
            ];
            self.handle.post(move |node, _| {
                for m in &messages {
                    node.send(m, holder);
                }
            });
        }
    }

    fn send_work(&mut self, imp: Uuid, work: Option<LinkWork>) {
        let Some(holder) = self.shared.borrow().away.get(&imp).copied() else {
            return;
        };
        let mood = if work.as_ref().is_some_and(|w| w.status.is_some()) {
            "working"
        } else {
            "thinking"
        };
        let messages = [
            LinkMessage::Work { imp, work },
            LinkMessage::Mood {
                imp,
                mood: mood.into(),
            },
        ];
        self.handle.post(move |node, _| {
            for m in &messages {
                node.send(m, holder);
            }
        });
    }

    // MARK: Helpers

    /// The conversation of an Imp that came back, and its MCP servers stopped.
    fn came_home(&mut self, imp: Uuid) -> Vec<ChatMessage> {
        let Some(mut home) = self.homes.remove(&imp) else {
            return Vec::new();
        };
        if let Some(stop) = home.stop.take() {
            let _ = stop.send(());
        }
        // Dropping the session stops its MCP servers.
        drop(home.session.take());
        home.chat.messages().to_vec()
    }

    /// An Imp of this computer that is away without a conversation here (it went away before this program
    /// started) gets an empty one.
    fn ensure_home(&mut self, imp: Uuid) {
        if self.homes.contains_key(&imp) {
            return;
        }
        if let Some(name) = self.imp_name(imp) {
            self.homes.insert(
                imp,
                HomeImp {
                    name,
                    chat: ChatState::default(),
                    turns: Vec::new(),
                    session: None,
                    stop: None,
                },
            );
        }
    }

    /// Tells a holder everything about an Imp of this computer: how it looks, its brain, its chat.
    fn send_everything(&mut self, imp: Uuid, holder: Uuid) {
        let Ok(loaded) = self.load() else {
            return;
        };
        let Some(found) = settings::imp_by_id(&loaded, imp) else {
            return;
        };
        let look = settings::look_of(
            &loaded,
            &found.value,
            &settings::servers_of(&loaded, &found.value),
        );
        let turns = self
            .homes
            .get(&imp)
            .map(|h| tail(&h.turns))
            .unwrap_or_default();
        let ready =
            imp_engine::config::resolve(&loaded.config, &loaded.auth, &found.value, None).is_ok();
        self.handle.post(move |node, _| {
            let tools = node.is_trusted(holder);
            for m in [
                LinkMessage::Look { imp: look },
                LinkMessage::Mood {
                    imp,
                    mood: "idle".into(),
                },
                LinkMessage::Brain { imp, ready, tools },
                LinkMessage::Chat { imp, turns },
                LinkMessage::Work { imp, work: None },
                LinkMessage::Speech { imp, speech: None },
            ] {
                node.send(&m, holder);
            }
        });
    }

    /// After a device connects: everything about the Imps of ours it holds.
    fn resend_all(&mut self, device: Uuid) {
        let held: Vec<Uuid> = self
            .shared
            .borrow()
            .away
            .iter()
            .filter(|(_, h)| **h == device)
            .map(|(i, _)| *i)
            .collect();
        for imp in held {
            self.ensure_home(imp);
            self.send_everything(imp, device);
        }
    }

    /// After trust changed: whether each away Imp uses its tools.
    fn resend_brains(&mut self) {
        let away: Vec<(Uuid, Uuid)> = self
            .shared
            .borrow()
            .away
            .iter()
            .map(|(i, h)| (*i, *h))
            .collect();
        for (imp, holder) in away {
            self.handle.post(move |node, _| {
                let tools = node.is_trusted(holder);
                node.send(
                    &LinkMessage::Brain {
                        imp,
                        ready: true,
                        tools,
                    },
                    holder,
                );
            });
        }
    }

    fn forgotten(&mut self, result: imp_engine::link::node::Forgotten) -> Vec<Update> {
        let mut updates = Vec::new();
        for imp in result.called_home {
            if let Some(name) = self.imp_name(imp) {
                self.shared.borrow_mut().away.remove(&imp);
                let messages = self.came_home(imp);
                updates.push(Update::CameHome {
                    imp: name,
                    messages,
                });
            }
        }
        for imp in result.sent_home {
            if self.shared.borrow_mut().visitors.remove(&imp).is_some() {
                updates.push(Update::Left(imp));
            }
        }
        updates
    }

    fn imp_name(&self, imp: Uuid) -> Option<String> {
        let loaded = self.load().ok()?;
        settings::imp_by_id(&loaded, imp).map(|a| a.value.name.clone())
    }

    fn peer_name(&self, device: Uuid) -> Option<String> {
        self.shared
            .borrow()
            .peers
            .iter()
            .find(|p| p.id == device)
            .map(|p| p.name.clone())
    }

    /// Reads the node's books again (the peers, the visitors and where this computer's Imps are) and waits
    /// for them. For the commands, which show the result at once.
    async fn refresh_now(&mut self) {
        if let Some(snapshot) = self.handle.with(|node, _| snapshot(node)).await {
            self.apply(snapshot);
        }
    }

    /// Asks the node for its books. They come back through `next`, so handling an event never waits.
    fn refresh(&self) {
        let back = self.inner_tx.clone();
        self.handle.post(move |node, _| {
            let _ = back.send(Inner::Snapshot(Box::new(snapshot(node))));
        });
    }

    fn apply(&mut self, snapshot: Snapshot) {
        let Snapshot {
            mut peers,
            visits,
            away,
        } = snapshot;
        peers.sort_by_key(|p| (!p.connected, p.name.to_lowercase()));
        let mut shared = self.shared.borrow_mut();
        let connected: Vec<Uuid> = peers.iter().filter(|p| p.connected).map(|p| p.id).collect();
        shared.peers = peers;
        shared.away = away.into_iter().collect();
        let mut visitors = BTreeMap::new();
        for (look, home, home_name, from) in visits {
            let old = shared.visitors.remove(&look.id);
            // Awake while its home is connected, unless the home said it has no brain.
            let awake = connected.contains(&home)
                && old
                    .as_ref()
                    .is_none_or(|o| o.awake || !connected.contains(&o.home));
            visitors.insert(
                look.id,
                Visitor {
                    turns: old.as_ref().map(|o| o.turns.clone()).unwrap_or_default(),
                    work: old.as_ref().and_then(|o| o.work.clone()),
                    look,
                    home,
                    home_name,
                    from,
                    awake,
                },
            );
        }
        shared.visitors = visitors;
    }

    /// Tells every device which Imps are on this computer's screen: its own at home, and its visitors.
    fn publish_stage(&mut self) {
        let Ok(loaded) = self.load() else {
            return;
        };
        let (me, away, visitors) = {
            let shared = self.shared.borrow();
            (
                shared.me,
                shared.away.keys().copied().collect::<Vec<_>>(),
                shared
                    .visitors
                    .values()
                    .map(|v| LinkStaged {
                        imp: v.look.clone(),
                        home: v.home,
                    })
                    .collect::<Vec<_>>(),
            )
        };
        let mut stage: Vec<LinkStaged> = loaded
            .imps()
            .map(|a| settings::look_of(&loaded, &a.value, &settings::servers_of(&loaded, &a.value)))
            .filter(|look| !away.contains(&look.id))
            .map(|imp| LinkStaged { imp, home: me })
            .collect();
        stage.extend(visitors);
        self.handle.post(move |node, _| node.set_stage(stage));
    }
}

/// What the node's books say, read in one go.
struct Snapshot {
    peers: Vec<Peer>,
    visits: Vec<(LinkImp, Uuid, String, Uuid)>,
    away: Vec<(Uuid, Uuid)>,
}

fn snapshot(node: &Node) -> Snapshot {
    let peers = node
        .links()
        .iter()
        .map(|link| {
            let id = link.id();
            Peer {
                id,
                name: link.device.name.clone(),
                kind: link.device.kind,
                connected: node.is_connected(id),
                through_hop: node.is_through_hop(id),
                trusted: node.is_trusted(id),
                stage: node.stage_of(id).to_vec(),
            }
        })
        .collect();
    let visits = node
        .visits()
        .visits()
        .iter()
        .map(|v| {
            (
                v.imp.clone(),
                v.home.id(),
                v.home.device.name.clone(),
                v.from,
            )
        })
        .collect();
    let away = node
        .away()
        .entries()
        .iter()
        .map(|e| (e.imp, e.holder))
        .collect();
    Snapshot {
        peers,
        visits,
        away,
    }
}

/// What jobs on the node report back to the device.
enum Inner {
    Snapshot(Box<Snapshot>),
    /// A thrown Imp was taken (or could not be): `ours` is its name when it is one of this computer's.
    Accepted {
        look: Box<LinkImp>,
        ours: Option<String>,
        took: bool,
        from: String,
        home: Option<(Uuid, String)>,
    },
}

/// The Imps on other devices' screens, and questions to them through the link.
struct DeviceRemote {
    shared: Rc<RefCell<Shared>>,
    handle: NodeHandle,
}

impl Remote for DeviceRemote {
    fn imps(&self) -> Vec<RemoteImp> {
        let shared = self.shared.borrow();
        let mut all = Vec::new();
        for peer in shared.peers.iter().filter(|p| p.connected) {
            for staged in &peer.stage {
                if !all.iter().any(|r: &RemoteImp| r.look.id == staged.imp.id) {
                    all.push(RemoteImp {
                        look: staged.imp.clone(),
                        home: staged.home,
                        place: peer.name.clone(),
                    });
                }
            }
        }
        for visitor in shared.visitors.values() {
            if !all.iter().any(|r| r.look.id == visitor.look.id) {
                all.push(RemoteImp {
                    look: visitor.look.clone(),
                    home: visitor.home,
                    place: shared.name.clone(),
                });
            }
        }
        all
    }

    fn ask<'a>(
        &'a self,
        from: LinkImp,
        to: RemoteImp,
        text: &'a str,
    ) -> BoxFuture<'a, std::result::Result<String, String>> {
        Box::pin(async move {
            let id = new_device_id();
            let (answer, reply) = oneshot::channel();
            let me = self.shared.borrow().me;
            self.shared.borrow_mut().talks.insert(id, answer);
            let words = text.to_string();
            let target = to.look.id;
            let first = self
                .handle
                .with(move |node, now| {
                    node.talk(
                        Ask {
                            id,
                            from,
                            to: target,
                            to_home: to.home,
                            text: &words,
                            holder: me,
                        },
                        now,
                    )
                })
                .await;
            match first {
                Some(First::Via(_)) => reply
                    .await
                    .unwrap_or_else(|_| Err("The link stopped before the answer came.".into())),
                _ => {
                    self.shared.borrow_mut().talks.remove(&id);
                    Err(format!(
                        "{} can't be reached: its device is not connected.",
                        to.look.name
                    ))
                }
            }
        })
    }
}

/// What a person should read about something the node reported.
fn describe(problem: &Problem) -> Option<String> {
    Some(match problem {
        Problem::Hop => "The Hop turned this computer away. Check that it is the same server the apps use and that it runs the same release as the apps.".into(),
        Problem::Refused(_) => "A device answered but would not talk. It may run a different release of Imp. Update both devices.".into(),
        Problem::KeyChanged(_) => "A device is not the one it was when it was linked, so it was turned away.".into(),
        Problem::InviteRefused(_) => "A device used a code that has expired. Show a fresh one with /pair.".into(),
        Problem::Listener(why) => format!("Cannot listen: {why}"),
        Problem::Storage(why) => format!("Could not save the link book: {why}"),
        Problem::Full(what) => format!("Imp has reached its limit of {what}."),
    })
}

fn stopped() -> CliError {
    CliError("The link stopped.".into())
}

fn first_line(text: &str) -> String {
    let line = text.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
    let mut cut: String = line.chars().take(120).collect();
    if cut.len() < line.len() {
        cut.push('…');
    }
    cut
}

/// The last page of turns, as the apps send them.
fn tail(turns: &[LinkTurn]) -> Vec<LinkTurn> {
    turns[turns.len().saturating_sub(CHAT_PAGE)..].to_vec()
}

/// A conversation as turns for another device's screen: each thing the person said, and the answer.
pub fn turns_of(messages: &[ChatMessage]) -> Vec<LinkTurn> {
    let mut turns: Vec<LinkTurn> = Vec::new();
    for m in messages {
        match m.role {
            Role::User => turns.push(LinkTurn {
                id: new_device_id(),
                date: now(),
                request: m.content.clone(),
                from: None,
                reply: String::new(),
                failed: false,
                steps: Vec::new(),
            }),
            Role::Assistant => {
                if let Some(turn) = turns.last_mut() {
                    if !m.content.is_empty() {
                        if !turn.reply.is_empty() {
                            turn.reply.push_str("\n\n");
                        }
                        turn.reply.push_str(&m.content);
                    }
                    turn.steps
                        .extend(m.tool_calls.iter().map(|c| format!("Used {}", c.name)));
                }
            }
            Role::Tool | Role::System => {}
        }
    }
    turns
}

/// A visitor's turns as messages for the chat screen.
pub fn messages_of(turns: &[LinkTurn]) -> Vec<ChatMessage> {
    let mut out = Vec::new();
    for turn in turns {
        let request = match &turn.from {
            Some(from) => format!("({from}) {}", turn.request),
            None => turn.request.clone(),
        };
        out.push(ChatMessage::user(request));
        if !turn.reply.is_empty() {
            out.push(ChatMessage::assistant(turn.reply.clone()));
        }
    }
    out
}

/// With `IMP_LINK_LOG` set to a file, one line per event of the link is added to it: when, what kind, which
/// device, and how big a message was. Never what was said, nor a key or a ticket. For finding out why
/// a connection dropped or an Imp went astray.
fn link_log(event: &Event) {
    use std::io::Write;
    let Some(path) = std::env::var_os("IMP_LINK_LOG").filter(|p| !p.is_empty()) else {
        return;
    };
    let line = match event {
        Event::Connected(device, standing) => {
            format!("connected {} {} {standing:?}", device.id, device.name)
        }
        Event::Disconnected(id) => format!("disconnected {id}"),
        Event::Linked(device) => format!("linked {} {}", device.id, device.name),
        Event::Forgotten(id, _) => format!("forgotten {id}"),
        Event::Message(message, from) => {
            let body = message.encode().unwrap_or_default();
            let kind = serde_json::from_slice::<serde_json::Value>(&body)
                .ok()
                .and_then(|v| v.as_object().and_then(|o| o.keys().next().cloned()))
                .unwrap_or_else(|| "?".into());
            format!("message {kind} from {from} {} bytes", body.len())
        }
        Event::Passed(passed) => format!(
            "passed {} to {} {:?}",
            passed.imp, passed.to, passed.outcome
        ),
        Event::Joined { device, result } => format!("joined {device} ok={}", result.is_ok()),
        Event::Problem(problem) => format!("problem {problem:?}"),
    };
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(file, "{secs:.3} {line}");
    }
}
