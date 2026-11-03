//! Imps of the terminal app talking to each other with the `imp_message` tool.
//!
//! The tool has the name, parameters and meaning of the one in the apps. The other Imp runs its own
//! model and answers. Conversations are kept per pair of Imps in the app's data folder, and the
//! rule for continuing or starting new is the one in `imp_core::talk`.

use crate::commands::system_prompt;
use crate::config::{Config, ImpConfig};
use imp_core::{
    BoxFuture, ChatMessage, HostTool, OpenAiClient, RetryPolicy, TalkStore, ToolEntry, ToolHost,
    ToolSelection, ToolSpec, Toolbox, run_agent,
};
use serde_json::{Value, json};
use std::time::{SystemTime, UNIX_EPOCH};

pub const TOOL_NAME: &str = "imp_message";

/// Looks up the API key of an Imp. Keys are never kept by the tool.
pub type KeyLookup = Box<dyn Fn(&str, &ImpConfig) -> Option<String>>;

pub struct ImpMessageHost {
    sender: String,
    config: Config,
    store: TalkStore,
    keys: KeyLookup,
    now: fn() -> u64,
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
        }
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

    /// Sends `text` to the Imp `to` and returns its answer. `asked` is the `conversation` argument.
    pub async fn deliver(
        &self,
        to: &str,
        text: &str,
        asked: Option<&str>,
    ) -> Result<String, String> {
        if !self.others().contains(&to) {
            return Err(format!(
                "There is no Imp called {to} to message. The others are: {}.",
                self.others().join(", ")
            ));
        }
        let target = &self.config.imps[to];
        let client = OpenAiClient::new(
            &target.base_url,
            (self.keys)(to, target),
            RetryPolicy::new(self.config.retries, 1.0, 2.0, 20.0),
        )
        .map_err(|e| e.to_string())?;
        let now = (self.now)();
        let mut log = self.store.load(&self.sender, to);
        let continues = self.config.talk_threading.continues(
            asked,
            log.last_activity(),
            self.config.talk_window_minutes,
            now,
        );
        let conversation = log.open(continues, now);
        let mut messages = vec![ChatMessage::system(format!(
            "{} {} is another Imp and is messaging you. Answer them briefly.",
            system_prompt(to, target),
            self.sender
        ))];
        for m in &conversation.messages {
            messages.push(if m.from == self.sender {
                ChatMessage::user(&m.text)
            } else {
                ChatMessage::assistant(&m.text)
            });
        }
        messages.push(ChatMessage::user(text));
        // The other Imp answers without tools, so two Imps can't start a chain of messages.
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
        conversation.push(&self.sender, text, now);
        conversation.push(to, &answer, now);
        // A conversation that can't be saved still answers, it just isn't remembered.
        let _ = self.store.save(&self.sender, to, &log);
        Ok(answer)
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
                    "to": { "type": "string", "enum": self.others() },
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
        if self.others().is_empty() {
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
