//! Imps talking to each other with the `imp_message` tool.
//!
//! The tool has the name, parameters and meaning of the one in the apps. The other Imp runs its own
//! model and answers. Conversations are kept per pair of Imps in the app's data folder, and the
//! rule for continuing or starting new is the one in `imp_engine::talk`.
//!
//! Imps on the person's other devices (a Mac, an iPhone) can be messaged too, through the link: `Remote`
//! lists them and carries the question there and the answer back.

use crate::settings;
use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use imp_engine::config::{Loaded, resolve};
use imp_engine::link::LinkImp;
use imp_engine::troupe::{self as words, TalkWaiting, TargetProfile};
use imp_engine::{
    BoxFuture, ChatMessage, HostTool, TalkStore, ToolEntry, ToolHost, ToolSelection, ToolSpec,
    Toolbox, run_agent,
};
use serde_json::Value;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::task::{Poll, Waker};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

/// An Imp on another device that can be messaged.
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteImp {
    pub look: LinkImp,
    /// The device it thinks on.
    pub home: Uuid,
    /// The name of the device its body is on.
    pub place: String,
}

/// The Imps on the person's other devices, and a way to ask them.
pub trait Remote {
    fn imps(&self) -> Vec<RemoteImp>;
    /// Sends `text` from `from` to `to` and waits for the answer (or a plain sentence why there is none).
    fn ask<'a>(
        &'a self,
        from: LinkImp,
        to: RemoteImp,
        text: &'a str,
    ) -> BoxFuture<'a, Result<String, String>>;
}

/// Who a message goes to.
enum Target {
    Here(String),
    Away(RemoteImp),
}

pub const TOOL_NAME: &str = "imp_message";

/// An answer to a message sent without waiting, on its way back to the Imp that sent it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Arrival {
    /// The Imp that was asked, by the name the tool took.
    pub from: String,
    /// The task label the receipt gave.
    pub task: String,
    /// When the message went out, as the event says it.
    pub sent: String,
    /// The answer, or a plain sentence why there is none.
    pub text: String,
    pub failed: bool,
    /// The depth of the message that was sent. An Imp woken by this answer is one deeper.
    pub depth: u32,
}

impl Arrival {
    /// The user-role message that brings the answer back to the Imp. It is added at the end of the chat: no
    /// earlier message is changed.
    pub fn event(&self) -> String {
        words::answer_event(&self.from, &self.task, &self.sent, &self.text, self.failed)
    }

    /// How deep the Imp is that this answer wakes.
    pub fn wakes_at(&self) -> u32 {
        self.depth + 1
    }
}

/// The messages one Imp has sent without waiting, and their answers as they come. The chat polls
/// [`Later::next`] to drive them (nothing here is `Send`, so they are not spawned) and gives each answer to
/// the Imp as a new message.
pub struct Later {
    pending: Rc<Cell<usize>>,
    depth: Cell<u32>,
    timeout: Cell<Duration>,
    tasks: RefCell<FuturesUnordered<BoxFuture<'static, Arrival>>>,
    waker: RefCell<Option<Waker>>,
}

impl Default for Later {
    fn default() -> Self {
        Self {
            pending: Rc::default(),
            depth: Cell::new(0),
            timeout: Cell::new(Duration::from_secs(words::ASYNC_TIMEOUT_SECS)),
            tasks: RefCell::default(),
            waker: RefCell::default(),
        }
    }
}

impl Later {
    pub fn new() -> Self {
        Self::default()
    }

    /// Replaces how long a local Imp has to answer, for tests.
    pub fn set_timeout(&self, timeout: Duration) {
        self.timeout.set(timeout);
    }

    /// The answers still on their way.
    pub fn pending(&self) -> usize {
        self.pending.get()
    }

    /// The depth messages sent now carry: 0 in a turn the person started, one more than the answer's in a
    /// turn an answer started.
    pub fn depth(&self) -> u32 {
        self.depth.get()
    }

    pub fn set_depth(&self, depth: u32) {
        self.depth.set(depth);
    }

    fn add(&self, task: BoxFuture<'static, Arrival>) {
        self.pending.set(self.pending.get() + 1);
        self.tasks.borrow_mut().push(task);
        if let Some(waker) = self.waker.borrow_mut().take() {
            waker.wake();
        }
    }

    /// Runs the messages on their way until the next answer is in, and returns it. It waits forever when
    /// none is on its way.
    pub async fn next(&self) -> Arrival {
        std::future::poll_fn(|cx| {
            *self.waker.borrow_mut() = Some(cx.waker().clone());
            match self.tasks.borrow_mut().poll_next_unpin(cx) {
                Poll::Ready(Some(arrival)) => Poll::Ready(arrival),
                _ => Poll::Pending,
            }
        })
        .await
    }
}

pub struct ImpMessageHost {
    sender: String,
    loaded: Loaded,
    store: TalkStore,
    now: fn() -> u64,
    look: Option<LinkImp>,
    remote: Option<Rc<dyn Remote>>,
    waiting: TalkWaiting,
    later: Option<Rc<Later>>,
}

/// What an Imp here says about itself to the others: its description, and its MCP servers as what it can do.
pub fn profile_of(loaded: &Loaded, name: &str, label: &str) -> Option<TargetProfile> {
    let agent = &loaded.agents.get(name)?.value;
    Some(TargetProfile {
        name: label.to_string(),
        about: agent.description.as_deref().and_then(words::about_line),
        abilities: words::ability_tags(&settings::servers_of(loaded, agent)),
    })
}

pub fn clock() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

impl ImpMessageHost {
    pub fn new(sender: &str, loaded: Loaded, store: TalkStore) -> Self {
        Self {
            sender: sender.to_string(),
            loaded,
            store,
            now: clock,
            look: None,
            remote: None,
            waiting: TalkWaiting::Wait,
            later: None,
        }
    }

    /// Lets the Imp send a message without waiting, if `waiting` allows it. The answers go to `later`, which
    /// the chat polls. Without it every message waits, whatever `waiting` says.
    #[must_use]
    pub fn with_later(mut self, waiting: TalkWaiting, later: Option<Rc<Later>>) -> Self {
        self.waiting = waiting;
        self.later = later;
        self
    }

    /// Lets the Imp (which looks like `look` to other devices) message the Imps of `remote` too.
    #[must_use]
    pub fn with_remote(mut self, look: LinkImp, remote: Option<Rc<dyn Remote>>) -> Self {
        self.look = Some(look);
        self.remote = remote;
        self
    }

    /// Replaces the clock, for tests.
    #[must_use]
    pub fn with_clock(mut self, now: fn() -> u64) -> Self {
        self.now = now;
        self
    }

    fn others(&self) -> Vec<&str> {
        self.loaded
            .imps()
            .map(|a| a.value.name.as_str())
            .filter(|n| *n != self.sender)
            .collect()
    }

    /// Everyone this Imp can message, by the name the tool uses (`imp_engine::troupe::tool_names`, the
    /// apps' rule): the other Imps here by name, and the Imps on other devices by name, or as `name@device`
    /// when the name is taken (by this Imp too).
    fn targets(&self) -> Vec<(String, Target)> {
        let here: Vec<String> = self.others().into_iter().map(str::to_string).collect();
        let own_ids: Vec<Uuid> = self.loaded.config.imps.values().map(|i| i.id).collect();
        let away: Vec<RemoteImp> = self
            .remote
            .as_ref()
            .map(|r| r.imps())
            .unwrap_or_default()
            .into_iter()
            .filter(|imp| !own_ids.contains(&imp.look.id))
            .collect();
        let places: Vec<(String, String)> = away
            .iter()
            .map(|imp| (imp.look.name.clone(), imp.place.clone()))
            .collect();
        let (here_names, away_names) = imp_engine::troupe::tool_names(&self.sender, &here, &places);
        here_names
            .into_iter()
            .zip(here)
            .map(|(label, name)| (label, Target::Here(name)))
            .chain(
                away_names
                    .into_iter()
                    .zip(away)
                    .map(|(label, imp)| (label, Target::Away(imp))),
            )
            .collect()
    }

    /// The Imp the tool's `to` names, with the name it has in the tool.
    fn resolve(&self, to: &str) -> Result<(String, Target), String> {
        let mut targets = self.targets();
        let Some(at) = targets
            .iter()
            .position(|(label, _)| label.to_lowercase() == to.trim().to_lowercase())
        else {
            let names: Vec<&str> = targets.iter().map(|(l, _)| l.as_str()).collect();
            return Err(format!(
                "There is no Imp called {to} to message. The others are: {}.",
                names.join(", ")
            ));
        };
        let (label, target) = targets.swap_remove(at);
        Ok((label, target))
    }

    /// The message on its way, owning all it needs, so it can go on after the tool has returned.
    fn delivery(
        &self,
        to: &str,
        target: Target,
        text: &str,
        asked: Option<&str>,
    ) -> BoxFuture<'static, Result<String, String>> {
        let (text, asked) = (text.to_string(), asked.map(str::to_string));
        match target {
            Target::Here(name) => {
                let (loaded, store) = (self.loaded.clone(), self.store.clone());
                let (sender, now) = (self.sender.clone(), (self.now)());
                Box::pin(async move {
                    answer_here(
                        &loaded,
                        &store,
                        &sender,
                        &name,
                        &text,
                        asked.as_deref(),
                        now,
                    )
                    .await
                })
            }
            Target::Away(imp) => {
                let (Some(remote), Some(look)) = (self.remote.clone(), self.look.clone()) else {
                    let why = format!("{to} can't be reached.");
                    return Box::pin(async move { Err(why) });
                };
                Box::pin(async move { remote.ask(look, imp, &text).await })
            }
        }
    }

    /// Sends `text` to the Imp `to` and returns its answer. `asked` is the `conversation` argument.
    pub async fn deliver(
        &self,
        to: &str,
        text: &str,
        asked: Option<&str>,
    ) -> Result<String, String> {
        let (_, target) = self.resolve(to)?;
        self.delivery(to, target, text, asked).await
    }

    /// Sends `text` to the Imp `to` and returns at once with a receipt. The answer comes later, from
    /// [`Later::next`], to be added to the chat as a new message. Fails with a sentence for the model when
    /// the Imp has too many answers on their way, or this is too deep a chain of Imps waking each other.
    pub fn deliver_later(
        &self,
        to: &str,
        text: &str,
        asked: Option<&str>,
    ) -> Result<String, String> {
        let Some(later) = &self.later else {
            return Err("Messages here wait for the answer.".into());
        };
        let depth = later.depth();
        words::may_leave(later.pending(), depth)?;
        let (label, target) = self.resolve(to)?;
        let task = words::task_label(Uuid::new_v4());
        let sent = words::clock_label((self.now)());
        // Another device answers within the link's own time. An Imp here has the time the chat allows.
        let limit = match &target {
            Target::Here(_) => Some(later.timeout.get()),
            Target::Away(_) => None,
        };
        let delivery = self.delivery(to, target, text, asked);
        let (from, receipt) = (label.clone(), words::receipt(&label, &task));
        let pending = later.pending.clone();
        later.add(Box::pin(async move {
            let answer = match limit {
                Some(limit) => match tokio::time::timeout(limit, delivery).await {
                    Ok(answer) => answer,
                    Err(_) => Err(format!(
                        "{from} didn't answer within {} minutes.",
                        limit.as_secs().div_ceil(60)
                    )),
                },
                None => delivery.await,
            };
            pending.set(pending.get().saturating_sub(1));
            let (text, failed) = match answer {
                Ok(text) => (text, false),
                Err(why) => (why, true),
            };
            Arrival {
                from,
                task,
                sent,
                text,
                failed,
                depth,
            }
        }));
        Ok(receipt)
    }

    /// The tool as the core words it, with the Imps here and those on other devices apart.
    fn spec(&self) -> ToolSpec {
        let (mut targets, mut elsewhere, mut profiles) = (Vec::new(), Vec::new(), Vec::new());
        for (label, target) in self.targets() {
            // What each says about itself: the Imps here from the settings, the others from their look.
            let profile = match &target {
                Target::Here(name) => profile_of(&self.loaded, name, &label),
                Target::Away(imp) => Some(TargetProfile {
                    name: label.clone(),
                    about: imp.look.about.clone(),
                    abilities: imp.look.abilities.clone(),
                }),
            };
            profiles.extend(profile);
            match target {
                Target::Here(_) => targets.push(label),
                Target::Away(_) => elsewhere.push(label),
            }
        }
        words::MessageTool {
            targets,
            elsewhere,
            conversation: true,
            profiles,
            waiting: if self.later.is_some() {
                self.waiting
            } else {
                TalkWaiting::Wait
            },
            ..words::MessageTool::default()
        }
        .spec()
    }
}

impl ToolHost for ImpMessageHost {
    fn tools(&self) -> Vec<HostTool> {
        if self.targets().is_empty() {
            return Vec::new();
        }
        vec![HostTool {
            entry: Some(ToolEntry::own("personality", TOOL_NAME)),
            spec: self.spec(),
        }]
    }

    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            if name != TOOL_NAME {
                return None;
            }
            let args: Value = serde_json::from_str(arguments).unwrap_or(Value::Null);
            let field = |k: &str| args.get(k).and_then(Value::as_str);
            let (Some(to), Some(text)) = (field("to"), field("text")) else {
                return Some("Error: imp_message needs `to` and `text`.".into());
            };
            let asked_to_wait = args.get("wait").and_then(Value::as_bool);
            let wait = self.later.is_none() || words::wants_wait(self.waiting, asked_to_wait);
            let sent = if wait {
                self.deliver(to, text, field("conversation")).await
            } else {
                self.deliver_later(to, text, field("conversation"))
            };
            Some(sent.unwrap_or_else(|e| format!("Error: {e}")))
        })
    }
}

/// The Imp `to` of this computer answers `sender` (another Imp, here or on another device) with its own
/// model and personality and without tools, so two Imps can't start a chain of messages. The conversation
/// is kept per pair in `store`.
#[allow(clippy::too_many_arguments)]
pub async fn answer_here(
    loaded: &Loaded,
    store: &TalkStore,
    sender: &str,
    to: &str,
    text: &str,
    asked: Option<&str>,
    now: u64,
) -> Result<String, String> {
    let target = &loaded
        .imps()
        .find(|a| a.value.name == to)
        .ok_or_else(|| format!("There is no Imp called {to} here."))?
        .value;
    let resolved = resolve(&loaded.config, &loaded.auth, target, None)?;
    let client = crate::session::client_of(loaded, &resolved).map_err(|e| e.0)?;
    let talk = settings::talk_of(loaded);
    let mut log = store.load(sender, to);
    let continues = talk
        .threading
        .continues(asked, log.last_activity(), talk.window_minutes, now);
    let conversation = log.open(continues, now);
    let mut messages = vec![ChatMessage::system(settings::system_prompt(
        target,
        loaded.config.imps.get(to),
    ))];
    for m in &conversation.messages {
        messages.push(if m.from == sender {
            ChatMessage::user(&m.text)
        } else {
            ChatMessage::assistant(&m.text)
        });
    }
    // The new message says who sent it, in the core's words, as in the apps.
    messages.push(ChatMessage::user(imp_engine::troupe::message_turn(
        sender, text, None,
    )));
    let answer = run_agent(
        &client,
        &resolved.model,
        &mut messages,
        &Toolbox::new(),
        &ToolSelection::all(),
        1,
        |_| {},
    )
    .await
    .map_err(|e| format!("{to} could not answer: {e}"))?;
    conversation.push(sender, text, now);
    conversation.push(to, &answer, now);
    // A conversation that can't be saved still answers, it just isn't remembered.
    let _ = store.save(sender, to, &log);
    Ok(answer)
}
