//! What a folder adds to a chat, beyond the configuration (`crate::settings`): the skills the Imp can read
//! with the `use_skill` tool, and the custom commands the folder (or `~/.agents`) offers. The files are found
//! and read by `imp_engine::config::load`.

use imp_engine::config::{Command, Loaded};
use std::path::Path;

pub use imp_engine::agents::SkillHost;

/// The custom commands of `~/.agents` and the folder, as `commands/NAME.md` files define them.
pub fn custom_commands(loaded: &Loaded) -> Vec<Command> {
    loaded.commands.values().map(|c| c.value.clone()).collect()
}

/// A path for people: `~/...` inside the home folder.
pub fn shown_path(path: &Path) -> String {
    if let Some(home) = directories::BaseDirs::new()
        && let Ok(rest) = path.strip_prefix(home.home_dir())
    {
        return if rest.as_os_str().is_empty() {
            "~".into()
        } else {
            format!("~/{}", rest.display())
        };
    }
    path.display().to_string()
}
