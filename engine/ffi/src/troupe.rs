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
