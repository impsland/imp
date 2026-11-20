//! The command line grammar. What the person sees first is `imp --help`, so the text matters.

use clap::{Parser, Subcommand};
use std::path::PathBuf;

const ABOUT: &str = "Talk to your Imps from a terminal";

const LONG_ABOUT: &str = "Talk to your Imps from a terminal\n\nImp is a little character that lives on your computer and talks to an AI model you choose.\n\
This is its terminal version. Make an Imp, then chat with it.";

const AFTER_HELP: &str = "Getting started:\n  \
imp provider add ollama --url http://localhost:11434/v1     Tell Imp where a model lives\n  \
imp agent new Pip --model ollama/qwen3                      Make an Imp called Pip\n  \
imp chat                                                    Chat with it (type /help inside)\n  \
imp qr                                                      Link a Mac or an iPhone, then /send it there\n\n\
Everything is kept in the files the Mac app reads too: imp.json and auth.json in the config folder\n\
(see `imp config path`) and agents in ~/.agents. Add --json to a list or show command for machine-readable output.\n\
Keys are never written to imp.json: `imp auth set PROVIDER` saves one in auth.json, or point a provider at an\n\
environment variable with `imp provider add ID --url URL --key-env VAR`.";

const MCP_ADD_LONG_ABOUT: &str = "Add an MCP server: a program this computer starts (--command, then the program and its arguments, \
last) or a service at an address (--url). Every Imp can use it; `imp mcp disable NAME --agent IMP` turns it off for one. \
In the arguments, ${workspaceFolder} is the folder the chat is started in.\n\n\
Examples:\n  \
imp mcp add files --command npx -y @modelcontextprotocol/server-filesystem ${workspaceFolder}\n  \
imp mcp add search --url https://mcp.example.org/mcp --header Authorization=Bearer\\ {env:SEARCH_KEY}";

const LINK_LONG_ABOUT: &str = "Stay online as one of your devices, without a chat. Imps of this computer that are on a Mac or \
an iPhone think here while it runs, Imps sent here visit, and Imps message each other across devices. Link a device \
first with `imp qr`. A full-screen chat does the same while it is open. Press Ctrl+C to stop.";

const SERVE_LONG_ABOUT: &str = "Run The Hop on this computer, so your devices can use it as their relay. Press Ctrl+C to stop.\n\n\
The Hop relays links between devices and keeps nothing. The Den (the gallery) is a separate service, `den`, \
see server/README.md.\n\n\
Examples:\n  \
imp serve                  Run the Hop on this computer only\n  \
imp serve --host 0.0.0.0   Let devices on your network use it";

#[derive(Debug, Parser, PartialEq)]
#[command(name = "imp", version, about = ABOUT, long_about = LONG_ABOUT, after_help = AFTER_HELP)]
pub struct Cli {
    /// Print lists and details as JSON
    #[arg(long, global = true)]
    pub json: bool,

    /// Without a command, `imp` starts `imp chat`
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum Command {
    /// Settings, Imps, services, tool servers and permissions. The same commands work in a chat with a /
    #[command(flatten)]
    Manage(Manage),
    /// Chat with an Imp in a full-screen chat. Type /help inside. Esc or Ctrl+C leaves.
    Chat {
        /// Which Imp to talk to (the only one, if there is one)
        #[arg(long, value_name = "NAME")]
        imp: Option<String>,
        /// Use the simple line chat even in a terminal
        #[arg(long)]
        plain: bool,
        /// Don't go online for your linked devices while chatting
        #[arg(long)]
        offline: bool,
    },
    /// Stay online for your linked devices without a chat. Press Ctrl+C to stop
    #[command(long_about = LINK_LONG_ABOUT)]
    Link {
        /// The name other devices see (the computer's name if left out)
        #[arg(long, value_name = "NAME")]
        name: Option<String>,
        /// The Imp server to wait at, as host:port, for devices on another network
        #[arg(long, env = "IMP_HOP", value_name = "HOST:PORT")]
        hop: Option<String>,
        /// Keep the link book here instead of in the usual data folder
        #[arg(long, env = "IMP_DATA_DIR", value_name = "DIR")]
        data_dir: Option<PathBuf>,
    },
    /// Run The Hop on this computer, so your devices can use it as their relay. Press Ctrl+C to stop
    #[command(long_about = SERVE_LONG_ABOUT)]
    Serve {
        /// The address to listen on (127.0.0.1 keeps it on this computer, 0.0.0.0 opens it to your network)
        #[arg(long, default_value = "127.0.0.1", value_name = "ADDRESS")]
        host: std::net::IpAddr,
        /// The port of The Hop
        #[arg(long, default_value_t = crate::serve::DEFAULT_HOP_PORT, value_name = "PORT")]
        hop_port: u16,
    },
    /// Show a pairing code for the Imp apps and stay linked. With text, draw that text instead
    Qr {
        /// The text to draw, instead of a pairing code
        text: Option<String>,
        /// The name other devices see (the computer's name if left out)
        #[arg(long, value_name = "NAME", conflicts_with = "text")]
        name: Option<String>,
        /// A host name or address to put in the code. Repeat for several. This computer's addresses if left out, Wi-Fi and Ethernet first
        #[arg(long = "host", value_name = "HOST", conflicts_with = "text")]
        hosts: Vec<String>,
        /// The Imp server to wait at, as host:port, for devices on another network
        #[arg(
            long,
            env = "IMP_HOP",
            value_name = "HOST:PORT",
            conflicts_with = "text"
        )]
        hop: Option<String>,
        /// Keep the link book here instead of in the usual data folder
        #[arg(
            long,
            env = "IMP_DATA_DIR",
            value_name = "DIR",
            conflicts_with = "text"
        )]
        data_dir: Option<PathBuf>,
    },
}

/// What changes the configuration or shows it. One grammar for the terminal and for the `/` commands of a chat.
#[derive(Debug, Subcommand, PartialEq)]
pub enum Manage {
    /// Imps and other agents: the files in ~/.agents/agents
    Agent {
        #[command(subcommand)]
        action: AgentAction,
    },
    /// Model services: where models live
    Provider {
        #[command(subcommand)]
        action: ProviderAction,
    },
    /// Keys for services, and the MCP sign-ins. Keys are never shown
    Auth {
        #[command(subcommand)]
        action: AuthAction,
    },
    /// Show or choose a model: provider/model#variant
    Model {
        /// The model to use, such as ollama/qwen3#high (`-` with --agent: the default again)
        model: Option<String>,
        /// Change this agent's model instead of the default one
        #[arg(long, value_name = "NAME")]
        agent: Option<String>,
    },
    /// MCP servers: tools from programs and services
    Mcp {
        #[command(subcommand)]
        action: McpAction,
    },
    /// Rules for what Imps may do: allow, ask or deny
    Permission {
        #[command(subcommand)]
        action: PermissionAction,
    },
    /// Skills the Imps can read
    Skill {
        #[command(subcommand)]
        action: ReadAction,
    },
    /// Custom commands: commands/NAME.md, run as /NAME in a chat
    #[command(name = "command")]
    Cmd {
        #[command(subcommand)]
        action: ReadAction,
    },
    /// What the folder adds, and whether its settings are trusted
    Project {
        #[command(subcommand)]
        action: Option<ProjectAction>,
    },
    /// The settings file imp.json
    Config {
        #[command(subcommand)]
        action: Option<ConfigAction>,
    },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum AgentAction {
    /// List agents. The Imps are the ones that are primary or all
    List {
        /// Also the hidden ones
        #[arg(long)]
        all: bool,
    },
    /// Show an agent: its settings and prompt
    Show { name: String },
    /// Make an agent
    New {
        /// Letters, digits, - and _, up to 32
        name: String,
        /// What it is good at
        #[arg(long)]
        description: Option<String>,
        /// provider/model#variant
        #[arg(long)]
        model: Option<String>,
        /// primary (an Imp you talk to), subagent or all
        #[arg(long, default_value = "primary")]
        mode: String,
        /// #rrggbb
        #[arg(long)]
        color: Option<String>,
    },
    /// Open the agent's file in $EDITOR
    Edit { name: String },
    /// Change one setting: description, mode, model, variant, color, steps, hidden, disabled or prompt (`-` clears)
    Set {
        name: String,
        key: String,
        value: String,
    },
    /// Remove an agent and its settings
    Remove { name: String },
    /// Give an agent another name
    Rename { old: String, new: String },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum ProviderAction {
    /// List the services
    List,
    /// Add a service. It must speak the OpenAI chat API
    Add {
        /// A short name, used in model names: ollama/qwen3
        id: String,
        /// The address of the API, such as http://localhost:11434/v1
        #[arg(long, value_name = "URL")]
        url: String,
        /// A name for people
        #[arg(long)]
        name: Option<String>,
        /// A header to send with every request, as NAME=VALUE. Repeat for several
        #[arg(long = "header", value_name = "NAME=VALUE")]
        headers: Vec<String>,
        /// Read the key from this environment variable
        #[arg(long, value_name = "VAR")]
        key_env: Option<String>,
    },
    /// Change one setting: name, url, key-env or header.NAME (`-` clears)
    Set {
        id: String,
        key: String,
        value: String,
    },
    /// Remove a service and its saved key
    Remove { id: String },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum AuthAction {
    /// Save a key for a service. It is read from standard input, and not shown when typed
    Set { provider: String },
    /// Forget the saved key of a service
    Clear { provider: String },
    /// Which services have a key, and from where
    List,
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum McpAction {
    /// List the MCP servers
    List {
        /// Show which are on for this agent
        #[arg(long, value_name = "NAME")]
        agent: Option<String>,
    },
    /// Add an MCP server: --command, last, or --url
    #[command(long_about = MCP_ADD_LONG_ABOUT)]
    Add {
        name: String,
        /// The program and its arguments
        #[arg(long, num_args = 1.., allow_hyphen_values = true, value_name = "PROGRAM ARGS", conflicts_with = "url")]
        command: Vec<String>,
        /// The address of a server
        #[arg(long, value_name = "URL")]
        url: Option<String>,
        /// An environment variable for the program, as NAME=VALUE. Repeat for several
        #[arg(long = "env", value_name = "NAME=VALUE")]
        env: Vec<String>,
        /// A header for the address, as NAME=VALUE. Repeat for several
        #[arg(long = "header", value_name = "NAME=VALUE")]
        headers: Vec<String>,
    },
    /// Change one setting: command, url, cwd, timeout, env.NAME or header.NAME (`-` clears)
    Set {
        name: String,
        key: String,
        value: String,
    },
    /// Remove an MCP server
    Remove { name: String },
    /// Turn a server on, for everyone or for one agent
    Enable {
        name: String,
        #[arg(long, value_name = "NAME")]
        agent: Option<String>,
    },
    /// Turn a server off, for everyone or for one agent
    Disable {
        name: String,
        #[arg(long, value_name = "NAME")]
        agent: Option<String>,
    },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum PermissionAction {
    /// List the rules, in the order they are read. The last one that matches decides
    List {
        #[arg(long, value_name = "NAME")]
        agent: Option<String>,
    },
    /// Add a rule at the end. ACTION is personality, look, animations, triggers, tools, senses, computer, shell, mcp, skill, read, edit or message
    Add {
        action: String,
        /// What it covers: a tool, a command line, server/tool, a path... `*` is any run of characters
        resource: String,
        /// allow, ask or deny
        effect: String,
        #[arg(long, value_name = "NAME")]
        agent: Option<String>,
    },
    /// Remove a rule by its number in the list
    Remove {
        index: usize,
        #[arg(long, value_name = "NAME")]
        agent: Option<String>,
    },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum ReadAction {
    List,
    Show { name: String },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum ProjectAction {
    /// What the folder adds
    Show,
    /// Allow the folder's .agents/imp.json as it is now
    Trust,
    /// Stop using it
    Untrust,
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum ConfigAction {
    /// Print where imp.json is
    Path,
    /// Print a setting, by dotted key such as requests.retries (everything without a key)
    Get { key: Option<String> },
    /// Change a setting. The value is JSON when it parses as such, else text. Escape a dot in a name as \\.
    Set { key: String, value: String },
    /// Remove a setting
    Unset { key: String },
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;
    use clap::error::ErrorKind;

    fn parse(args: &[&str]) -> Result<Cli, clap::Error> {
        let mut full = vec!["imp"];
        full.extend_from_slice(args);
        Cli::try_parse_from(full)
    }

    fn manage(args: &[&str]) -> Manage {
        match parse(args).unwrap().command.unwrap() {
            Command::Manage(m) => m,
            other => panic!("not a manage command: {other:?}"),
        }
    }

    #[test]
    fn the_grammar_is_consistent() {
        Cli::command().debug_assert();
    }

    #[test]
    fn nouns_and_verbs() {
        assert_eq!(
            manage(&["agent", "new", "Pip", "--model", "ollama/qwen3#high"]),
            Manage::Agent {
                action: AgentAction::New {
                    name: "Pip".into(),
                    description: None,
                    model: Some("ollama/qwen3#high".into()),
                    mode: "primary".into(),
                    color: None,
                }
            }
        );
        assert_eq!(
            manage(&["model", "x/y", "--agent", "Pip"]),
            Manage::Model {
                model: Some("x/y".into()),
                agent: Some("Pip".into())
            }
        );
        assert_eq!(
            manage(&[
                "permission",
                "add",
                "shell",
                "rm *",
                "deny",
                "--agent",
                "Pip"
            ]),
            Manage::Permission {
                action: PermissionAction::Add {
                    action: "shell".into(),
                    resource: "rm *".into(),
                    effect: "deny".into(),
                    agent: Some("Pip".into())
                }
            }
        );
        assert_eq!(manage(&["project"]), Manage::Project { action: None });
        assert!(
            parse(&["provider", "add", "x"]).is_err(),
            "a provider needs --url"
        );
    }

    #[test]
    fn json_is_global_and_a_command_takes_the_rest_of_the_line() {
        assert!(parse(&["agent", "list", "--json"]).unwrap().json);
        match manage(&[
            "mcp",
            "add",
            "files",
            "--command",
            "npx",
            "-y",
            "@modelcontextprotocol/server-filesystem",
            "/tmp",
        ]) {
            Manage::Mcp {
                action: McpAction::Add { command, .. },
            } => assert_eq!(command.len(), 4),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn chat_link_serve_and_qr_stay() {
        assert_eq!(
            parse(&["chat", "--imp", "pip"]).unwrap().command.unwrap(),
            Command::Chat {
                imp: Some("pip".into()),
                plain: false,
                offline: false
            }
        );
        assert!(matches!(
            parse(&["link"]).unwrap().command.unwrap(),
            Command::Link { .. }
        ));
        assert!(parse(&["--config", "x.json", "chat"]).is_err());
    }

    #[test]
    fn serve_takes_a_host_and_a_hop_port() {
        match parse(&["serve"]).unwrap().command.unwrap() {
            Command::Serve { host, hop_port } => {
                assert!(host.is_loopback());
                assert_eq!(hop_port, crate::serve::DEFAULT_HOP_PORT);
            }
            other => panic!("not serve: {other:?}"),
        }
        match parse(&["serve", "--hop-port", "2", "--host", "0.0.0.0"])
            .unwrap()
            .command
            .unwrap()
        {
            Command::Serve { host, hop_port } => {
                assert!(host.is_unspecified());
                assert_eq!(hop_port, 2);
            }
            other => panic!("not serve: {other:?}"),
        }
    }

    #[test]
    fn serve_no_longer_runs_the_den() {
        for args in [
            &["serve", "--den-only"][..],
            &["serve", "--den-port", "9000"],
            &["serve", "--public-url", "https://a.b"],
        ] {
            assert_eq!(
                parse(args).unwrap_err().kind(),
                ErrorKind::UnknownArgument,
                "{args:?}"
            );
        }
    }

    #[test]
    fn help_and_mistakes() {
        assert_eq!(parse(&[]).unwrap().command, None);
        assert_eq!(
            parse(&["--help"]).unwrap_err().kind(),
            ErrorKind::DisplayHelp
        );
        assert_eq!(
            parse(&["dance"]).unwrap_err().kind(),
            ErrorKind::InvalidSubcommand
        );
    }
}
