//! What several test files share: a local stand-in for an OpenAI-compatible service, and a world of
//! temporary folders to run the configuration in.

#![allow(dead_code)]

use imp_chat::settings::Settings;
use imp_engine::config::Env;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Answers every request with "Answer N" and records the request bodies.
pub async fn mock() -> (String, Arc<Mutex<Vec<String>>>) {
    let (url, bodies, _) = mock_with(|n| text_reply(&format!("Answer {n}"))).await;
    (url, bodies)
}

/// One streamed answer that is only text.
pub fn text_reply(text: &str) -> String {
    format!(
        "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{text}\"}}}}]}}\n\ndata: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n"
    )
}

/// One streamed answer that calls one tool.
pub fn tool_reply(id: &str, name: &str, arguments: &str) -> String {
    let arguments = serde_json::to_string(arguments).unwrap();
    format!(
        "data: {{\"choices\":[{{\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"{id}\",\"type\":\"function\",\"function\":{{\"name\":\"{name}\",\"arguments\":{arguments}}}}}]}}}}]}}\n\ndata: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\ndata: [DONE]\n\n"
    )
}

/// A service that answers request number N (from 1) with `respond(N)` (the streamed body), and records the
/// request bodies and the heads (request line and headers, lower-cased).
pub async fn mock_with(
    respond: impl Fn(usize) -> String + Send + Sync + 'static,
) -> (String, Arc<Mutex<Vec<String>>>, Arc<Mutex<Vec<String>>>) {
    let respond = Arc::new(respond);
    let heads = Arc::new(Mutex::new(Vec::<String>::new()));
    let heads_log = heads.clone();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let log = log.clone();
            let heads_log = heads_log.clone();
            let respond = respond.clone();
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buf = [0u8; 8192];
                let mut head_seen = String::new();
                let body = loop {
                    let read = socket.read(&mut buf).await.unwrap_or(0);
                    data.extend_from_slice(&buf[..read]);
                    let text = String::from_utf8_lossy(&data).to_string();
                    if let Some((head, rest)) = text.split_once("\r\n\r\n") {
                        head_seen = head.to_ascii_lowercase();
                        let length = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if rest.len() >= length {
                            break rest.to_string();
                        }
                    }
                    if read == 0 {
                        break String::new();
                    }
                };
                let n = {
                    let mut log = log.lock().unwrap();
                    log.push(body);
                    log.len()
                };
                heads_log.lock().unwrap().push(head_seen);
                let sse = respond(n);
                let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n";
                let _ = socket.write_all(format!("{head}{sse}").as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    (url, seen, heads)
}

static COUNTER: AtomicUsize = AtomicUsize::new(0);

/// Folders of their own for one test: a config folder, a home with `~/.agents`, a data folder and the
/// folder a chat starts in (`work`, with a `.git` so the project is that folder). Removed when dropped.
/// The developer's own settings are never read.
pub struct World {
    pub root: PathBuf,
    pub config: PathBuf,
    pub home: PathBuf,
    pub data: PathBuf,
    pub work: PathBuf,
}

impl World {
    pub fn new(tag: &str) -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!("imp-chat-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let world = Self {
            config: root.join("cfg"),
            home: root.join("home"),
            data: root.join("data"),
            work: root.join("work"),
            root,
        };
        for dir in [&world.config, &world.home, &world.data] {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::create_dir_all(world.work.join(".git")).unwrap();
        world
    }

    /// The environment of a program run in this world: `IMP_CONFIG_HOME` and `HOME` are the world's.
    pub fn env(&self, vars: &[(&str, &str)]) -> Env {
        let config = self.config.display().to_string();
        let mut all = vec![("IMP_CONFIG_HOME", config.as_str())];
        all.extend_from_slice(vars);
        Env::new(&all, Some(&self.home))
    }

    pub fn settings(&self) -> Settings {
        self.settings_with(&[])
    }

    pub fn settings_with(&self, vars: &[(&str, &str)]) -> Settings {
        Settings::new(self.env(vars), self.work.clone(), Some(self.data.clone())).unwrap()
    }

    pub fn imp_json(&self) -> PathBuf {
        self.config.join("imp.json")
    }

    pub fn auth_json(&self) -> PathBuf {
        self.config.join("auth.json")
    }

    /// `imp.json` as JSON text.
    pub fn write_config(&self, json: &str) {
        std::fs::write(self.imp_json(), json).unwrap();
    }

    /// `imp.json` with one service called `mock` at `url`, and `mock/m` as the model.
    pub fn with_mock(&self, url: &str) {
        self.write_config(&format!(
            r#"{{"model":"mock/m","providers":{{"mock":{{"options":{{"baseURL":"{url}"}}}}}}}}"#
        ));
    }

    /// A file under `~/.agents`.
    pub fn home_agents(&self, rel: &str, text: &str) {
        write(&self.home.join(".agents"), rel, text);
    }

    /// An agent file in `~/.agents/agents`.
    pub fn agent(&self, name: &str, front: &str, body: &str) {
        self.home_agents(
            &format!("agents/{name}.md"),
            &format!("---\n{front}\n---\n{body}\n"),
        );
    }

    /// A file in the folder the chat starts in.
    pub fn in_work(&self, rel: &str, text: &str) {
        write(&self.work, rel, text);
    }

    pub fn read_config(&self) -> serde_json::Value {
        serde_json::from_str(&std::fs::read_to_string(self.imp_json()).unwrap()).unwrap()
    }

    pub fn agent_file(&self, name: &str) -> PathBuf {
        self.home.join(".agents/agents").join(format!("{name}.md"))
    }
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

pub fn write(dir: &Path, rel: &str, text: &str) {
    let path = dir.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// What one run of the `imp` program did.
pub struct Run {
    pub ok: bool,
    pub out: String,
    pub err: String,
}

impl Run {
    pub fn json(&self) -> serde_json::Value {
        serde_json::from_str(&self.out).unwrap_or_else(|e| panic!("not JSON ({e}): {}", self.out))
    }
}

impl World {
    /// Runs the real `imp` in `work`, with this world's folders and nothing of the developer's.
    pub fn imp_in(&self, args: &[&str], stdin: &str) -> Run {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let mut child = Command::new(env!("CARGO_BIN_EXE_imp"))
            .args(args)
            .current_dir(&self.work)
            .env("HOME", &self.home)
            .env("IMP_CONFIG_HOME", &self.config)
            .env("IMP_DATA_DIR", &self.data)
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("IMP_HOP")
            .env_remove("VISUAL")
            .env_remove("EDITOR")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(stdin.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        Run {
            ok: out.status.success(),
            out: String::from_utf8_lossy(&out.stdout).to_string(),
            err: String::from_utf8_lossy(&out.stderr).to_string(),
        }
    }

    /// Runs `imp ARGS` and expects it to work.
    pub fn imp(&self, args: &[&str]) -> Run {
        let run = self.imp_in(args, "");
        assert!(run.ok, "imp {args:?} failed: {}", run.err);
        run
    }

    /// Runs `imp ARGS` and expects it to fail. Returns the sentence it says.
    pub fn imp_fails(&self, args: &[&str]) -> String {
        let run = self.imp_in(args, "");
        assert!(!run.ok, "imp {args:?} should fail, it said: {}", run.out);
        assert!(run.out.is_empty(), "nothing on stdout: {}", run.out);
        run.err
    }
}
