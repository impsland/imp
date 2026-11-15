//! Imps talking to each other with the `imp_message` tool.
//!
//! The tool has the name, parameters and meaning of the one in the apps. The other Imp runs its own
//! model and answers. Conversations are kept per pair of Imps in the app's data folder, and the
//! rule for continuing or starting new is the one in `imp_engine::talk`.
//!
//! Imps on the person's other devices (a Mac, an iPhone) can be messaged too, through the link: `Remote`
//! lists them and carries the question there and the answer back.

use crate::config::{Config, ImpConfig};
use crate::session::system_prompt;
use imp_engine::link::LinkImp;
use imp_engine::{
    BoxFuture, ChatMessage, HostTool, OpenAiClient, RequestLimits, TalkStore, ToolEntry, ToolHost,
    ToolSelection, ToolSpec, Toolbox, run_agent,
};
use serde_json::{Value, json};
use std::rc::Rc;
use std::time::{SystemTime, UNIX_EPOCH};
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

/// Looks up the API key of an Imp. Keys are never kept by the tool.
pub type KeyLookup = Box<dyn Fn(&str, &ImpConfig) -> Option<String>>;

pub struct ImpMessageHost {
    sender: String,
    config: Config,
    store: TalkStore,
    keys: KeyLookup,
    now: fn() -> u64,
    look: Option<LinkImp>,
    remote: Option<Rc<dyn Remote>>,
}

pub fn clock() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

impl ImpMessageHost {
    pub fn new(sender: &str, config: Config, store: TalkStore, keys: KeyLookup) -> Self {
        Self {
            sender: sender.to_string(),
            config,
            store,
            keys,
            now: clock,
            look: None,
            remote: None,
        }
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
        self.config
            .imps
            .keys()
            .map(String::as_str)
            .filter(|n| *n != self.sender)
            .collect()
    }

    /// Everyone this Imp can message, by the name the tool uses: the other Imps here by name, and the
    /// Imps on other devices by name, or as `name@device` when the name is taken.
    fn targets(&self) -> Vec<(String, Target)> {
        let mut all: Vec<(String, Target)> = self
            .others()
            .into_iter()
            .map(|n| (n.to_string(), Target::Here(n.to_string())))
            .collect();
        let own_ids: Vec<Uuid> = self.config.imps.values().filter_map(|i| i.id).collect();
        let away = self.remote.as_ref().map(|r| r.imps()).unwrap_or_default();
        for imp in away {
            if own_ids.contains(&imp.look.id) {
                continue;
            }
            let plain = imp.look.name.clone();
            let label = if all.iter().any(|(l, _)| *l == plain) {
                format!("{plain}@{}", imp.place)
            } else {
                plain
            };
            if !all.iter().any(|(l, _)| *l == label) {
                all.push((label, Target::Away(imp)));
            }
        }
        all
    }

    /// Sends `text` to the Imp `to` and returns its answer. `asked` is the `conversation` argument.
    pub async fn deliver(
        &self,
        to: &str,
        text: &str,
        asked: Option<&str>,
    ) -> Result<String, String> {
        let mut targets = self.targets();
        let Some(at) = targets.iter().position(|(label, _)| label == to) else {
            let names: Vec<&str> = targets.iter().map(|(l, _)| l.as_str()).collect();
            return Err(format!(
                "There is no Imp called {to} to message. The others are: {}.",
                names.join(", ")
            ));
        };
        match targets.swap_remove(at).1 {
            Target::Here(name) => {
                answer_here(
                    &self.config,
                    &self.store,
                    &self.keys,
                    &self.sender,
                    &name,
                    text,
                    asked,
                    (self.now)(),
                )
                .await
            }
            Target::Away(imp) => {
                let (Some(remote), Some(look)) = (&self.remote, &self.look) else {
                    return Err(format!("{to} can't be reached."));
                };
                remote.ask(look.clone(), imp, text).await
            }
        }
    }

    fn spec(&self) -> ToolSpec {
        let which = "Which conversation with that Imp: `new` starts a fresh one (a different subject), `continue` goes on in your latest one (a follow-up, it remembers what was said). Leave it out and it continues if you talked recently, else starts new.";
        ToolSpec {
            name: TOOL_NAME.into(),
            description:
                "Send a message to another Imp and get its answer. Keep it short and friendly."
                    .into(),
            parameters: json!({
                "type": "object",
                "properties": {
                    "to": { "type": "string", "enum": self.targets().into_iter().map(|(l, _)| l).collect::<Vec<_>>() },
                    "text": { "type": "string" },
                    "conversation": { "type": "string", "enum": ["new", "continue"], "description": which },
                },
                "required": ["to", "text"],
            }),
        }
    }
}

impl ToolHost for ImpMessageHost {
    fn tools(&self) -> Vec<HostTool> {
        if self.targets().is_empty() {
            return Vec::new();
        }
        vec![HostTool {
            entry: Some(ToolEntry::own("troupe", TOOL_NAME)),
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
            Some(
                self.deliver(to, text, field("conversation"))
                    .await
                    .unwrap_or_else(|e| format!("Error: {e}")),
            )
        })
    }
}

/// The Imp `to` of this computer answers `sender` (another Imp, here or on another device) with its own
/// model and personality and without tools, so two Imps can't start a chain of messages. The conversation
/// is kept per pair in `store`.
#[allow(clippy::too_many_arguments)]
pub async fn answer_here(
    config: &Config,
    store: &TalkStore,
    keys: &KeyLookup,
    sender: &str,
    to: &str,
    text: &str,
    asked: Option<&str>,
    now: u64,
) -> Result<String, String> {
    let target = config
        .imps
        .get(to)
        .ok_or_else(|| format!("There is no Imp called {to} here."))?;
    let client = OpenAiClient::new(
        &target.base_url,
        keys(to, target),
        RequestLimits {
            retries: i64::from(config.retries),
            ..RequestLimits::default()
        }
        .policy(),
    )
    .map_err(|e| e.to_string())?;
    let mut log = store.load(sender, to);
    let continues = config.talk_threading.continues(
        asked,
        log.last_activity(),
        config.talk_window_minutes,
        now,
    );
    let conversation = log.open(continues, now);
    let mut messages = vec![ChatMessage::system(format!(
        "{} {sender} is another Imp and is messaging you. Answer them briefly.",
        system_prompt(to, target),
    ))];
    for m in &conversation.messages {
        messages.push(if m.from == sender {
            ChatMessage::user(&m.text)
        } else {
            ChatMessage::assistant(&m.text)
        });
    }
    messages.push(ChatMessage::user(text));
    let answer = run_agent(
        &client,
        &target.model,
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
