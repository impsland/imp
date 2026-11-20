//! Permissions at work: every tool call and every shell command goes through the rules of the Imp
//! (`imp_engine::config::decide`). `deny` refuses with a sentence for the model, `allow` goes on, and `ask`
//! asks the person: in the full-screen chat in the chat itself (Allow once, Always, Deny), and where nobody
//! can be asked (the line chat, a pipe, a visit from another device) it counts as `deny` and says so.
//! Always writes an `allow` rule into the Imp's agent file.

use imp_engine::config::{Effect, Permission, Rule, Store, classify, decide_in};
use imp_engine::{BoxFuture, HostTool, ToolHost, Toolbox};
use std::cell::RefCell;
use std::rc::Rc;

/// What is asked of the person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Question {
    pub imp: String,
    pub action: String,
    pub resource: String,
}

impl Question {
    /// `shell ls -la`, `mcp files/read_file`.
    pub fn what(&self) -> String {
        format!("{} {}", self.action, self.resource)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Answer {
    Once,
    Always,
    Deny,
}

/// Whoever can be asked. `None` from [`Asker::ask`] means nobody can: `ask` is a `deny`.
pub trait Asker {
    fn ask<'a>(&'a self, question: &'a Question) -> BoxFuture<'a, Option<Answer>>;
}

/// Nobody to ask: the line chat, a pipe, a visit.
pub struct NoOne;

impl Asker for NoOne {
    fn ask<'a>(&'a self, _: &'a Question) -> BoxFuture<'a, Option<Answer>> {
        Box::pin(async { None })
    }
}

/// A question on its way to whoever is at the screen, with the way back for the answer.
pub struct Pending {
    pub question: Question,
    pub reply: tokio::sync::oneshot::Sender<Answer>,
}

/// Asks through a channel: the full-screen chat receives the questions, shows them and sends the answers.
/// An answer that never comes (the question was dropped, the chat ended) is a `Deny`.
pub struct Channel {
    tx: tokio::sync::mpsc::UnboundedSender<Pending>,
}

impl Channel {
    pub fn new() -> (Rc<Self>, tokio::sync::mpsc::UnboundedReceiver<Pending>) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (Rc::new(Self { tx }), rx)
    }
}

impl Asker for Channel {
    fn ask<'a>(&'a self, question: &'a Question) -> BoxFuture<'a, Option<Answer>> {
        Box::pin(async move {
            let (reply, answer) = tokio::sync::oneshot::channel();
            let pending = Pending {
                question: question.clone(),
                reply,
            };
            if self.tx.send(pending).is_err() {
                return None;
            }
            Some(answer.await.unwrap_or(Answer::Deny))
        })
    }
}

/// The rules of one Imp and the way to ask.
pub struct Gate {
    imp: String,
    rules: RefCell<Vec<Rule>>,
    home: Option<String>,
    asker: Rc<dyn Asker>,
    store: Store,
    servers: RefCell<Vec<String>>,
}

impl Gate {
    pub fn new(
        imp: &str,
        rules: Vec<Rule>,
        home: Option<String>,
        asker: Rc<dyn Asker>,
        store: Store,
    ) -> Self {
        Self {
            imp: imp.to_string(),
            rules: RefCell::new(rules),
            home,
            asker,
            store,
            servers: RefCell::new(Vec::new()),
        }
    }

    /// The rules and the MCP servers after the configuration changed.
    pub fn update(&self, rules: Vec<Rule>, servers: Vec<String>) {
        *self.rules.borrow_mut() = rules;
        *self.servers.borrow_mut() = servers;
    }

    pub fn decide(&self, action: &str, resource: &str) -> Effect {
        decide_in(&self.rules.borrow(), action, resource, self.home.as_deref())
    }

    /// Whether the action may go on. `Err` is the sentence the model (and the person) read.
    pub async fn check(&self, action: &str, resource: &str) -> Result<(), String> {
        match self.decide(action, resource) {
            Effect::Allow => Ok(()),
            Effect::Deny => Err(format!(
                "Not allowed: {action} {resource}. A permission rule of {} denies it.",
                self.imp
            )),
            Effect::Ask => {
                let question = Question {
                    imp: self.imp.clone(),
                    action: action.into(),
                    resource: resource.into(),
                };
                match self.asker.ask(&question).await {
                    Some(Answer::Once) => Ok(()),
                    Some(Answer::Always) => {
                        self.remember(&question);
                        Ok(())
                    }
                    Some(Answer::Deny) => {
                        Err(format!("The person did not allow {}.", question.what()))
                    }
                    None => Err(format!(
                        "{} needs the person's permission and there is nobody to ask here. Allow it with `imp permission add {action} '{resource}' allow --agent {}`.",
                        question.what(),
                        self.imp
                    )),
                }
            }
        }
    }

    /// Writes `allow` for this action to the agent's file, and uses it from now on. A file that can't be
    /// written only means the person is asked again next time.
    fn remember(&self, q: &Question) {
        let rule = Rule::new(&q.action, &q.resource, Effect::Allow);
        self.rules.borrow_mut().push(rule.clone());
        if let Ok(mut agent) = self.store.read_agent(&q.imp) {
            agent.permissions.push(rule);
            let _ = self.store.write_agent(&agent);
        }
    }

    /// The action and resource a tool call is (`imp_engine::config::classify`, the same on the Mac).
    fn permission_of(&self, tool: &HostTool, arguments: Option<&str>) -> Permission {
        classify(
            tool.entry.as_ref().map(|e| e.id.as_str()),
            &tool.spec.name,
            arguments.unwrap_or(""),
            &self.servers.borrow(),
        )
    }
}

/// The tools of an Imp as the rules leave them: the ones a `deny` rule takes away are not offered, and each
/// call is checked when it is made.
pub struct Gated {
    pub gate: Rc<Gate>,
    pub inner: Rc<Toolbox>,
}

impl ToolHost for Gated {
    fn tools(&self) -> Vec<HostTool> {
        self.inner
            .tools()
            .into_iter()
            .filter(|t| {
                // Without arguments a skill and a message are `*`: they are checked by what they name, when called.
                let p = self.gate.permission_of(t, None);
                self.gate.decide(&p.action, &p.resource) != Effect::Deny
            })
            .collect()
    }

    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            let tools = self.inner.tools();
            let tool = tools.iter().find(|t| t.spec.name == name)?;
            let p = self.gate.permission_of(tool, Some(arguments));
            if let Err(why) = self.gate.check(&p.action, &p.resource).await {
                return Some(format!("Error: {why}"));
            }
            self.inner.call(name, arguments).await
        })
    }
}
