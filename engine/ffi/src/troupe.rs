//! What Imps say to each other, for the apps. The words are in `imp_engine::troupe`.

use imp_engine::troupe;

/// How the `imp_message` tool reads for one Imp. See `imp_engine::troupe::MessageTool`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TroupeMessageTool {
    pub targets: Vec<String>,
    pub elsewhere: Vec<String>,
    pub place: Option<String>,
    pub own_bubble: bool,
    pub chat_choice: bool,
    pub conversation: bool,
    pub open_file_tool: Option<String>,
    /// What each Imp it can message says about itself, by the name the tool takes.
    pub profiles: Vec<TroupeTargetProfile>,
    /// `wait`, `dont_wait` or `decides`. Anything else is `decides`.
    pub waiting: String,
}

/// What one Imp says about itself: its description and what it can do. See `imp_engine::troupe::TargetProfile`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TroupeTargetProfile {
    pub name: String,
    pub about: Option<String>,
    pub abilities: Vec<String>,
}

/// A tool as offered to the model. `parameters_json` is its JSON schema.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TroupeToolSpec {
    pub name: String,
    pub description: String,
    pub parameters_json: String,
}

/// The `imp_message` tool for these options.
#[uniffi::export]
pub fn troupe_message_tool(options: TroupeMessageTool) -> TroupeToolSpec {
    let spec = troupe::MessageTool {
        targets: options.targets,
        elsewhere: options.elsewhere,
        place: options.place,
        own_bubble: options.own_bubble,
        chat_choice: options.chat_choice,
        conversation: options.conversation,
        open_file_tool: options.open_file_tool,
        profiles: options
            .profiles
            .into_iter()
            .map(|p| troupe::TargetProfile {
                name: p.name,
                about: p.about,
                abilities: p.abilities,
            })
            .collect(),
        waiting: troupe::TalkWaiting::from_name(&options.waiting),
    }
    .spec();
    TroupeToolSpec {
        name: spec.name,
        description: spec.description,
        parameters_json: spec.parameters.to_string(),
    }
}

/// What an Imp is given when `sender`, another Imp, messages it. `place`: where the sender is.
#[uniffi::export]
pub fn troupe_message_turn(sender: String, text: String, place: Option<String>) -> String {
    troupe::message_turn(&sender, &text, place.as_deref())
}

/// An Imp on another device, before it has the name `imp_message` takes: its own name and the device it is on.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TroupeAway {
    pub name: String,
    pub place: String,
}

/// The names `imp_message` takes for `here` and `away`, in their order. See `imp_engine::troupe::tool_names`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TroupeNames {
    pub here: Vec<String>,
    pub away: Vec<String>,
}

/// The names `imp_message` takes for the Imps `sender` can message: each different, none the sender's own.
#[uniffi::export]
pub fn troupe_tool_names(sender: String, here: Vec<String>, away: Vec<TroupeAway>) -> TroupeNames {
    let away: Vec<(String, String)> = away.into_iter().map(|a| (a.name, a.place)).collect();
    let (here, away) = troupe::tool_names(&sender, &here, &away);
    TroupeNames { here, away }
}

/// What an Imp says about itself, made safe for other Imps to read: one line of at most 200 characters.
#[uniffi::export]
pub fn troupe_about_line(text: String) -> Option<String> {
    troupe::about_line(&text)
}

/// Abilities made safe for other Imps to read: short, different, at most 8.
#[uniffi::export]
pub fn troupe_ability_tags(tags: Vec<String>) -> Vec<String> {
    troupe::ability_tags(&tags)
}

/// Whether a message waits for its answer, from the setting (`wait`, `dont_wait`, `decides`) and the `wait` argument.
#[uniffi::export]
pub fn troupe_wants_wait(waiting: String, asked: Option<bool>) -> bool {
    troupe::wants_wait(troupe::TalkWaiting::from_name(&waiting), asked)
}

/// None when an Imp with `pending` answers outstanding, at `depth`, may send one more without waiting. Otherwise
/// the sentence to give the model.
#[uniffi::export]
pub fn troupe_may_leave(pending: u32, depth: u32) -> Option<String> {
    troupe::may_leave(pending as usize, depth).err()
}

/// The short name of a message sent without waiting, from its id (a UUID).
#[uniffi::export]
pub fn troupe_task_label(id: String) -> String {
    match uuid::Uuid::parse_str(id.trim()) {
        Ok(id) => troupe::task_label(id),
        Err(_) => troupe::task_label(uuid::Uuid::nil()),
    }
}

/// What the tool returns at once for a message sent without waiting.
#[uniffi::export]
pub fn troupe_receipt(to: String, task: String) -> String {
    troupe::receipt(&to, &task)
}

/// The user-role message that brings an answer back to the Imp that asked.
#[uniffi::export]
pub fn troupe_answer_event(
    from: String,
    task: String,
    sent: String,
    text: String,
    failed: bool,
) -> String {
    troupe::answer_event(&from, &task, &sent, &text, failed)
}

/// Whether calls to this tool in one reply may run at the same time.
#[uniffi::export]
pub fn troupe_runs_concurrently(tool: String) -> bool {
    imp_engine::tools::runs_concurrently(&tool)
}

/// The limits on messages sent without waiting.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TroupeLimits {
    /// The answers one Imp may have outstanding.
    pub max_pending: u32,
    /// How deep a chain of Imps waking each other may go.
    pub max_depth: u32,
    /// How long a local Imp has to answer, in seconds.
    pub async_timeout_secs: u64,
}

#[uniffi::export]
pub fn troupe_limits() -> TroupeLimits {
    TroupeLimits {
        max_pending: troupe::MAX_PENDING as u32,
        max_depth: troupe::MAX_DEPTH,
        async_timeout_secs: troupe::ASYNC_TIMEOUT_SECS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_calls_reach_the_core() {
        assert_eq!(
            troupe_about_line(" hi \n there ".into()).as_deref(),
            Some("hi there")
        );
        assert!(troupe_wants_wait("decides".into(), None));
        assert!(!troupe_wants_wait("dont_wait".into(), None));
        assert!(!troupe_wants_wait("decides".into(), Some(false)));
        assert!(troupe_may_leave(0, 0).is_none());
        assert!(troupe_may_leave(4, 0).is_some());
        assert_eq!(
            troupe_task_label("1a2b3c4d-0000-0000-0000-000000000000".into()),
            "t-1a2b3c"
        );
        assert!(
            troupe_runs_concurrently("imp_message".into())
                && !troupe_runs_concurrently("shell".into())
        );
        let limits = troupe_limits();
        assert_eq!(
            (
                limits.max_pending,
                limits.max_depth,
                limits.async_timeout_secs
            ),
            (4, 3, 600)
        );
        let spec = troupe_message_tool(TroupeMessageTool {
            targets: vec!["Bo".into()],
            elsewhere: vec![],
            place: None,
            own_bubble: false,
            chat_choice: false,
            conversation: false,
            open_file_tool: None,
            profiles: vec![TroupeTargetProfile {
                name: "Bo".into(),
                about: Some("cooks".into()),
                abilities: vec!["oven".into()],
            }],
            waiting: "unknown".into(),
        });
        assert!(spec.description.contains("- Bo: cooks. Can: oven."));
        assert!(spec.parameters_json.contains("\"wait\""));
    }
}
