//! The command line grammar. What the person sees first is `imp --help`, so the text matters.

use clap::{Parser, Subcommand};
use std::path::PathBuf;

const ABOUT: &str = "Talk to your Imps from a terminal";

const LONG_ABOUT: &str = "Talk to your Imps from a terminal\n\nImp is a little character that lives on your computer and talks to an AI model you choose.\n\
This is its terminal version. Make an Imp, then chat with it.";

const AFTER_HELP: &str = "Getting started:\n  \
imp imp new pip --model gpt-5       Make an Imp called pip\n  \
imp chat                            Chat with it\n\n\
Your API key is never stored in the settings file. Put it in an environment variable\n\
(IMP_API_KEY by default) or save it in the system keychain with `imp config set-key`.";

const SERVE_LONG_ABOUT: &str = "Run The Den, The Hop or both on this computer, so your devices can use it as their server. Press Ctrl-C to stop.\n\n\
By default both run. The Den holds accounts, shared kits and the web gallery, and keeps its data in a folder on this computer. \
The Hop relays links between devices and keeps nothing. The Hop does not need The Den, so each can run alone. \
Options for a service you did not choose are not allowed.\n\n\
Examples:\n  \
imp serve                  Run both\n  \
imp serve --den-only       Run only The Den\n  \
imp serve --hop-only       Run only The Hop";

#[derive(Debug, Parser, PartialEq)]
#[command(name = "imp", version, about = ABOUT, long_about = LONG_ABOUT, after_help = AFTER_HELP, arg_required_else_help = true)]
pub struct Cli {
    /// Use this settings file instead of the usual one
    #[arg(long, global = true, env = "IMP_CONFIG", value_name = "FILE")]
    pub config: Option<PathBuf>,

    #[command(subcommand)]
    pub command: Command,
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
    /// Chat with an Imp in a full-screen chat. Press Esc to leave
    Chat {
        /// Which Imp to talk to (the default Imp if left out)
        #[arg(long, value_name = "NAME")]
        imp: Option<String>,
        /// Use the simple line chat even in a terminal
        #[arg(long)]
        plain: bool,
    },
    /// Run The Den, The Hop or both on this computer, so your devices can use it as their server. Press Ctrl-C to stop
    #[command(long_about = SERVE_LONG_ABOUT)]
    Serve {
        /// Run only The Den (accounts, shared kits and the web gallery)
        #[arg(long, conflicts_with = "hop_only")]
        den_only: bool,
        /// Run only The Hop (the relay between devices). It does not need The Den
        #[arg(long, conflicts_with_all = ["den_only", "den_port", "public_url"])]
        hop_only: bool,
        /// The address to listen on (127.0.0.1 keeps it on this computer, 0.0.0.0 opens it to your network)
        #[arg(long, default_value = "127.0.0.1", value_name = "ADDRESS")]
        host: std::net::IpAddr,
        /// The port of The Den
        #[arg(long, default_value_t = crate::serve::DEFAULT_DEN_PORT, value_name = "PORT", conflicts_with = "hop_only")]
        den_port: u16,
        /// The port of The Hop
        #[arg(long, default_value_t = crate::serve::DEFAULT_HOP_PORT, value_name = "PORT", conflicts_with = "den_only")]
        hop_port: u16,
        /// The address people use to reach The Den, if it is not http://localhost:PORT
        #[arg(long, value_name = "URL", conflicts_with = "hop_only")]
        public_url: Option<String>,
        /// Keep The Den's data here instead of in the usual data folder
        #[arg(
            long,
            env = "IMP_DATA_DIR",
            value_name = "DIR",
            conflicts_with = "hop_only"
        )]
        data_dir: Option<PathBuf>,
    },
    /// Draw a QR code in the terminal. With no text it explains what the apps can scan today
    Qr {
        /// The text to draw
        text: Option<String>,
        /// Draw dark on light, for a terminal with a light background
        #[arg(long)]
        light_terminal: bool,
    },
}

#[derive(Debug, Subcommand, PartialEq)]
pub enum ConfigAction {
    /// Show the settings and where the API key comes from. The key itself is never shown
    Show,
    /// Print the path of the settings file
    Path,
    /// Change a setting: default_imp, api_key_env or retries
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
            parse(&["config"]).unwrap().command,
            Command::Config { action: None }
        );
        assert_eq!(
            parse(&["config", "show"]).unwrap().command,
            Command::Config {
                action: Some(ConfigAction::Show)
            }
        );
        assert_eq!(
            parse(&["config", "set", "retries", "5"]).unwrap().command,
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
                .command,
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
            parse(&["imp", "list"]).unwrap().command,
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
            new.command,
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
            "gpt-6-luna",
            "--api-key-env",
            "OPENAI_API_KEY",
        ])
        .unwrap();
        assert_eq!(
            unnamed.command,
            Command::Imp {
                action: ImpAction::New {
                    name: None,
                    personality: None,
                    url: Some("https://openrouter.ai/api/v1".into()),
                    model: Some("gpt-6-luna".into()),
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
            cli.command,
            Command::Chat {
                imp: Some("pip".into()),
                plain: false
            }
        );
        assert_eq!(cli.config, Some(PathBuf::from("/tmp/x.toml")));
        assert_eq!(
            parse(&["chat"]).unwrap().command,
            Command::Chat {
                imp: None,
                plain: false
            }
        );
    }

    fn serve_flags(args: &[&str]) -> (bool, bool) {
        let mut full = vec!["serve"];
        full.extend_from_slice(args);
        match parse(&full).unwrap().command {
            Command::Serve {
                den_only, hop_only, ..
            } => (den_only, hop_only),
            other => panic!("not serve: {other:?}"),
        }
    }

    #[test]
    fn serve_runs_both_by_default_or_one_on_request() {
        assert_eq!(serve_flags(&[]), (false, false));
        assert_eq!(serve_flags(&["--den-only"]), (true, false));
        assert_eq!(serve_flags(&["--hop-only"]), (false, true));
        assert_eq!(
            serve_flags(&[
                "--den-only",
                "--den-port",
                "9000",
                "--public-url",
                "https://a.b"
            ]),
            (true, false)
        );
        assert_eq!(
            serve_flags(&["--hop-only", "--hop-port", "9001"]),
            (false, true)
        );
        assert_eq!(
            serve_flags(&["--den-port", "1", "--hop-port", "2", "--host", "0.0.0.0"]),
            (false, false)
        );
    }

    #[test]
    fn serve_refuses_options_of_a_service_that_is_not_running() {
        for args in [
            &["serve", "--den-only", "--hop-only"][..],
            &["serve", "--hop-only", "--den-port", "9000"],
            &["serve", "--hop-only", "--public-url", "https://a.b"],
            &["serve", "--den-only", "--hop-port", "9001"],
        ] {
            assert_eq!(
                parse(args).unwrap_err().kind(),
                ErrorKind::ArgumentConflict,
                "{args:?}"
            );
        }
    }

    #[test]
    fn help_and_mistakes() {
        assert_eq!(
            parse(&[]).unwrap_err().kind(),
            ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand
        );
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
