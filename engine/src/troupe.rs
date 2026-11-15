//! What Imps say to each other: the `imp_message` tool the model is offered, and the turn an Imp
//! gets when another Imp messages it. No I/O. The apps and the command line both build them here,
//! so an Imp is told the same thing wherever it runs. What only one app has (a speech bubble, files
//! sent as `imp-file://` links) is an option, not a second copy of the words.

use crate::chat::ToolSpec;
use crate::tools::BuiltInTool;
use serde_json::{Map, Value, json};

/// How the `imp_message` tool reads for one Imp.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MessageTool {
    /// The Imps it can message here, by the name the tool takes.
    pub targets: Vec<String>,
    /// The Imps it can message on the person's other devices, by the name the tool takes.
    pub elsewhere: Vec<String>,
    /// Where the Imps here are, said after "another Imp", such as `out on the desktop`. None says nothing.
    pub place: Option<String>,
    /// The answer shows in the other Imp's own speech bubble.
    pub own_bubble: bool,
    /// The sender may choose `own` (a private chat) or `shared` (the other Imp's chat with the person).
    pub chat_choice: bool,
    /// The sender may say whether a message continues the latest conversation (`conversation`).
    pub conversation: bool,
    /// Files in answers come as `imp-file://` links, which this tool opens.
    pub open_file_tool: Option<String>,
}

const CHAT_CHOICE: &str = "Where the two of you talk: `own` (default) is a private chat between you and that Imp, kept apart from the user's; `shared` is the chat that Imp has with the user (use it when the user should see or take part in what's said).";
const CONVERSATION: &str = "Which conversation with that Imp: `new` starts a fresh one (a different subject), `continue` goes on in your latest one (a follow-up, it remembers what was said). Leave it out and it continues if you talked recently, else starts new.";

impl MessageTool {
    /// The tool as offered to the model.
    pub fn spec(&self) -> ToolSpec {
        let everyone: Vec<&String> = self.targets.iter().chain(&self.elsewhere).collect();
        let mut properties = Map::new();
        properties.insert("to".into(), json!({"type": "string", "enum": everyone}));
        properties.insert("text".into(), json!({"type": "string"}));
        if self.chat_choice {
            properties.insert(
                "chat".into(),
                json!({"type": "string", "enum": ["own", "shared"], "description": CHAT_CHOICE}),
            );
        }
        if self.conversation {
            let mut which = CONVERSATION.to_string();
            if self.chat_choice {
                which.push_str(" Only for a private chat between you two.");
            }
            properties.insert(
                "conversation".into(),
                json!({"type": "string", "enum": ["new", "continue"], "description": which}),
            );
        }
        let place = self
            .place
            .as_deref()
            .map_or(String::new(), |p| format!(" {p}"));
        let mut about = format!("Send a message to another Imp{place} and get its answer");
        if self.own_bubble {
            about.push_str(" (it shows its own bubble)");
        }
        about.push_str(". Keep it short and friendly.");
        if let Some(open) = &self.open_file_tool {
            about.push_str(&format!(
                " Files in the answer come as imp-file:// links: show them with those links exactly as they are ({open} opens one to look at or read). To send a file of yours, put it in your folder and link or embed it in the text."
            ));
        }
        if !self.elsewhere.is_empty() {
            about.push_str(&format!(
                " {} are on the user's other devices and answer there.",
                self.elsewhere.join(", ")
            ));
        }
        ToolSpec {
            name: BuiltInTool::ImpMessage.name().to_string(),
            description: about,
            parameters: json!({
                "type": "object",
                "properties": Value::Object(properties),
                "required": ["to", "text"],
            }),
        }
    }
}

/// What an Imp is given when `sender`, another Imp, messages it. `place` is where the sender is,
/// such as `on the desktop`. The reply goes back to the sender.
pub fn message_turn(sender: &str, text: &str, place: Option<&str>) -> String {
    let place = place.map_or(String::new(), |p| format!(" {p}"));
    format!(
        "Message from {sender}, another Imp{place}: “{text}”\n\n(Your reply goes back to {sender}.)"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tool_has_only_what_the_imp_can_use() {
        let plain = MessageTool {
            targets: vec!["pip".into()],
            ..MessageTool::default()
        }
        .spec();
        assert_eq!(plain.name, "imp_message");
        assert_eq!(
            plain.description,
            "Send a message to another Imp and get its answer. Keep it short and friendly."
        );
        assert_eq!(plain.parameters["properties"]["to"]["enum"], json!(["pip"]));
        assert!(plain.parameters["properties"].get("chat").is_none());
        assert!(plain.parameters["properties"].get("conversation").is_none());
        assert_eq!(plain.parameters["required"], json!(["to", "text"]));

        let app = MessageTool {
            targets: vec!["Mo".into()],
            elsewhere: vec!["Pebble".into()],
            place: Some("out on the desktop".into()),
            own_bubble: true,
            chat_choice: true,
            conversation: true,
            open_file_tool: Some("imp_open_file".into()),
        }
        .spec();
        assert!(app.description.starts_with(
            "Send a message to another Imp out on the desktop and get its answer (it shows its own bubble). Keep it short and friendly. Files"
        ));
        assert!(app.description.contains("(imp_open_file opens one"));
        assert!(
            app.description
                .ends_with("Pebble are on the user's other devices and answer there.")
        );
        let props = &app.parameters["properties"];
        assert_eq!(props["to"]["enum"], json!(["Mo", "Pebble"]));
        assert_eq!(props["chat"]["enum"], json!(["own", "shared"]));
        assert!(
            props["conversation"]["description"]
                .as_str()
                .unwrap()
                .ends_with("Only for a private chat between you two.")
        );
    }

    #[test]
    fn a_message_says_who_sent_it_and_where_the_reply_goes() {
        assert_eq!(
            message_turn("Mo", "Hi!", Some("on the desktop")),
            "Message from Mo, another Imp on the desktop: “Hi!”\n\n(Your reply goes back to Mo.)"
        );
        assert!(message_turn("pip", "x", None).starts_with("Message from pip, another Imp: “x”"));
    }
}
