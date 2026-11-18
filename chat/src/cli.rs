//! The command line grammar. What the person sees first is `imp --help`, so the text matters.

use clap::{Parser, Subcommand};
use std::path::PathBuf;

const ABOUT: &str = "Talk to your Imps from a terminal";

const LONG_ABOUT: &str = "Talk to your Imps from a terminal\n\nImp is a little character that lives on your computer and talks to an AI model you choose.\n\
This is its terminal version. Make an Imp, then chat with it.";

const AFTER_HELP: &str = "Getting started:\n  \
imp imp new Pip --model openai/gpt-6-luna      Make an Imp called Pip\n  \
imp mcp add files -- npx -y @modelcontextprotocol/server-filesystem .\n                                               \
Let it work with the files of the folder you chat in\n  \
imp chat                                       Chat with it (type /help inside)\n  \
imp qr                                         Link a Mac or an iPhone, then /send it there\n\n\
Your API key is never stored in the settings file. Put it in an environment variable\n\
(IMP_API_KEY by default) or save it in the system keychain with `imp config set-key`.";

const MCP_ADD_LONG_ABOUT: &str = "Give an Imp the tools of an MCP server. A server is a program this computer starts (a command and \
its arguments, after --) or a service at an address. In the arguments, ${workspaceFolder} (or a plain .) is the folder \
the chat is started in.\n\n\
Examples:\n  \
imp mcp add files -- npx -y @modelcontextprotocol/server-filesystem .\n  \
imp mcp add search --header Authorization https://mcp.example.org/mcp";

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
    /// Use this settings file instead of the usual one
    #[arg(long, global = true, env = "IMP_CONFIG", value_name = "FILE")]
    pub config: Option<PathBuf>,

    /// Without a command, `imp` starts `imp chat`
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum Command {
    /// Show or change settings
    Config {
        #[command(subcommand)]
        action: Option<ConfigAction>,
    },
    /// Make, list and remove Imps
    Imp {
        #[command(subcommand)]
        action: ImpAction,
    },
    /// Chat with an Imp in a full-screen chat. Type /help inside. Esc or Ctrl+C leaves.
    Chat {
        /// Which Imp to talk to (the default Imp if left out)
        #[arg(long, value_name = "NAME")]
        imp: Option<String>,
        /// Use the simple line chat even in a terminal
        #[arg(long)]
        plain: bool,
        /// Don't go online for your linked devices while chatting
        #[arg(long)]
        offline: bool,
    },
    /// Give an Imp tools from MCP servers, list them or take them away
    Mcp {
        #[command(subcommand)]
        action: McpAction,
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

#[derive(Debug, Subcommand, PartialEq)]
pub enum ConfigAction {
    /// Show the settings and where the API key comes from. The key itself is never shown
    Show,
    /// Print the path of the settings file
    Path,
    /// Change a setting: default_imp, api_key_env, retries, max_steps, memory_exchanges or long_chat_tokens
    Set {
        /// The setting
        key: String,
        /// Its new value
        value: String,
    },
    /// Save an API key in the system keychain, read from the first line of standard input
    SetKey {
        /// The Imp the key is for (the default Imp if left out)
        #[arg(long, value_name = "NAME")]
        imp: Option<String>,
    },
    /// Save the value of an MCP server header in the system keychain, read from the first line of standard input
    SetHeader {
        /// The MCP server, as named in the settings file
        server: String,
        /// The header, as listed under headers for that server
        header: String,
    },
    /// Remove an API key from the system keychain
    ClearKey {
        /// The Imp the key was for (the default Imp if left out)
        #[arg(long, value_name = "NAME")]
        imp: Option<String>,
    },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum ImpAction {
    /// List your Imps
    List,
    /// Make a new Imp. Anything you leave out is asked for
    New {
        /// Its name: letters, digits, dash and underscore (asked for if left out)
        name: Option<String>,
        /// How it behaves, in a sentence or two
        #[arg(long)]
        personality: Option<String>,
        /// Where its brain lives: the base address of an OpenAI-compatible service
        #[arg(long, value_name = "URL")]
        url: Option<String>,
        /// The model to ask for
        #[arg(long)]
        model: Option<String>,
        /// The environment variable that holds the API key (IMP_API_KEY if left out)
        #[arg(long, value_name = "VAR")]
        api_key_env: Option<String>,
        /// Make it the default Imp
        #[arg(long)]
        default: bool,
    },
    /// Remove an Imp
    Remove {
        /// Its name
        name: String,
    },
    /// Change one of an Imp's settings: model, base_url, personality, api_key_env or hue
    Set {
        /// The Imp
        name: String,
        /// The setting
        key: String,
        /// Its new value
        value: String,
    },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum McpAction {
    /// List an Imp's MCP servers
    List {
        /// The Imp (the default Imp if left out)
        #[arg(long, value_name = "NAME")]
        imp: Option<String>,
    },
    /// Add an MCP server: a command after --, or an address
    #[command(long_about = MCP_ADD_LONG_ABOUT)]
    Add {
        /// A name for the server: letters, digits, dash and underscore
        name: String,
        /// The Imp that gets it (the default Imp if left out)
        #[arg(long, value_name = "NAME")]
        imp: Option<String>,
        /// An environment variable to pass on to the command, by NAME. Repeat for several
        #[arg(long = "env", value_name = "VAR")]
        env: Vec<String>,
        /// A header to send to the address, by NAME (its value is read from IMP_MCP_<SERVER>_<HEADER> or the keychain)
        #[arg(long = "header", value_name = "NAME")]
        headers: Vec<String>,
        /// The address (https://...), or the command and its arguments after --
        #[arg(required = true, num_args = 1.., allow_hyphen_values = true, value_name = "COMMAND_OR_URL")]
        target: Vec<String>,
    },
    /// Remove an MCP server from an Imp
    Remove {
        /// The server's name
        name: String,
        /// The Imp (the default Imp if left out)
        #[arg(long, value_name = "NAME")]
        imp: Option<String>,
    },
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

    #[test]
    fn the_grammar_is_consistent() {
        Cli::command().debug_assert();
    }

    #[test]
    fn config_commands() {
        assert_eq!(
            parse(&["config"]).unwrap().command.unwrap(),
            Command::Config { action: None }
        );
        assert_eq!(
            parse(&["config", "show"]).unwrap().command.unwrap(),
            Command::Config {
                action: Some(ConfigAction::Show)
            }
        );
        assert_eq!(
            parse(&["config", "set", "retries", "5"])
                .unwrap()
                .command
                .unwrap(),
            Command::Config {
                action: Some(ConfigAction::Set {
                    key: "retries".into(),
                    value: "5".into()
                })
            }
        );
        assert_eq!(
            parse(&["config", "set-key", "--imp", "pip"])
                .unwrap()
                .command
                .unwrap(),
            Command::Config {
                action: Some(ConfigAction::SetKey {
                    imp: Some("pip".into())
                })
            }
        );
    }

    #[test]
    fn imp_commands() {
        assert_eq!(
            parse(&["imp", "list"]).unwrap().command.unwrap(),
            Command::Imp {
                action: ImpAction::List
            }
        );
        let new = parse(&[
            "imp",
            "new",
            "pip",
            "--model",
            "m",
            "--url",
            "http://localhost:11434/v1",
            "--default",
        ])
        .unwrap();
        assert_eq!(
            new.command.unwrap(),
            Command::Imp {
                action: ImpAction::New {
                    name: Some("pip".into()),
                    personality: None,
                    url: Some("http://localhost:11434/v1".into()),
                    model: Some("m".into()),
                    api_key_env: None,
                    default: true,
                }
            }
        );
        // The name may be left out: it is asked for, like the other values.
        let unnamed = parse(&[
            "imp",
            "new",
            "--url",
            "https://openrouter.ai/api/v1",
            "--model",
            "openai/gpt-6-luna",
            "--api-key-env",
            "OPENAI_API_KEY",
        ])
        .unwrap();
        assert_eq!(
            unnamed.command.unwrap(),
            Command::Imp {
                action: ImpAction::New {
                    name: None,
                    personality: None,
                    url: Some("https://openrouter.ai/api/v1".into()),
                    model: Some("openai/gpt-6-luna".into()),
                    api_key_env: Some("OPENAI_API_KEY".into()),
                    default: false,
                }
            }
        );
    }

    #[test]
    fn chat_and_global_config_flag() {
        let cli = parse(&["chat", "--imp", "pip", "--config", "/tmp/x.toml"]).unwrap();
        assert_eq!(
            cli.command.unwrap(),
            Command::Chat {
                imp: Some("pip".into()),
                plain: false,
                offline: false
            }
        );
        assert_eq!(cli.config, Some(PathBuf::from("/tmp/x.toml")));
        assert_eq!(
            parse(&["chat"]).unwrap().command.unwrap(),
            Command::Chat {
                imp: None,
                plain: false,
                offline: false
            }
        );
    }

    #[test]
    fn mcp_and_link_commands() {
        let add = parse(&[
            "mcp",
            "add",
            "files",
            "--imp",
            "pip",
            "--",
            "npx",
            "-y",
            "@modelcontextprotocol/server-filesystem",
            ".",
        ])
        .unwrap();
        assert_eq!(
            add.command.unwrap(),
            Command::Mcp {
                action: McpAction::Add {
                    name: "files".into(),
                    imp: Some("pip".into()),
                    env: vec![],
                    headers: vec![],
                    target: vec![
                        "npx".into(),
                        "-y".into(),
                        "@modelcontextprotocol/server-filesystem".into(),
                        ".".into()
                    ],
                }
            }
        );
        assert!(parse(&["mcp", "add", "files"]).is_err());
        assert!(matches!(
            parse(&["link"]).unwrap().command.unwrap(),
            Command::Link { .. }
        ));
        assert_eq!(
            parse(&["imp", "set", "pip", "model", "x/y"])
                .unwrap()
                .command
                .unwrap(),
            Command::Imp {
                action: ImpAction::Set {
                    name: "pip".into(),
                    key: "model".into(),
                    value: "x/y".into()
                }
            }
        );
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
