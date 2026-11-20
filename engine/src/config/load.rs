//! Finding the files, reading them and merging them: `imp.json` and `auth.json` of the config folder,
//! `~/.agents`, and the `.agents` folders from a project's root down to where the terminal app started.
//! A file that cannot be used is a diagnostic; the rest loads.

use crate::agents::{self, Instructions, LeftOut, MOST_INSTRUCTIONS, SkillSpec};
use crate::config::doc::{Agent, Command, Skill, valid_agent_name};
use crate::config::trust::TrustStore;
use crate::config::types::{Auth, ImpConfig, parse_config};
use crate::config::{Diagnostic, Env};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// `~/.agents` and the config folder: the person's own.
    Global,
    /// A `.agents` folder of the project.
    Project,
}

/// A thing read from a file, and where from.
#[derive(Debug, Clone, PartialEq)]
pub struct Sourced<T> {
    pub value: T,
    pub path: PathBuf,
    pub scope: Scope,
}

/// What a project asks the person to trust.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Project {
    /// The farthest folder of the chain: the git root, or the folder the app started in.
    pub root: PathBuf,
    /// The project's `.agents/imp.json` files, farthest first.
    pub config_files: Vec<PathBuf>,
    /// The digest of them as they are, `None` when there are none.
    pub digest: Option<String>,
    /// The person allowed them as they are: they are merged into the configuration.
    pub trusted: bool,
}

#[derive(Debug, Clone, Default)]
pub struct Loaded {
    pub config: ImpConfig,
    pub auth: Auth,
    pub agents: BTreeMap<String, Sourced<Agent>>,
    pub skills: BTreeMap<String, Sourced<Skill>>,
    pub commands: BTreeMap<String, Sourced<Command>>,
    /// The `AGENTS.md` files that fit, farthest first, labelled with their paths.
    pub instructions: Vec<Instructions>,
    pub project: Option<Project>,
    pub diagnostics: Vec<Diagnostic>,
}

impl Loaded {
    /// The agents that are Imps (`primary` or `all`), by name.
    pub fn imps(&self) -> impl Iterator<Item = &Sourced<Agent>> {
        self.agents.values().filter(|a| a.value.is_imp())
    }

    /// What goes after who the Imp is in the system text: the `AGENTS.md` notes, then the skills.
    pub fn system_suffix(&self) -> String {
        let skills: Vec<SkillSpec> = self
            .skills
            .values()
            .map(|s| SkillSpec::from(&s.value))
            .collect();
        agents::prompt(&self.instructions, &skills)
    }
}

/// The folders whose `.agents` apply, farthest first: from `start` up to the folder with a `.git`
/// (included), or up to the home folder (not included). With neither, only `start`.
pub fn project_dirs(start: &Path, home: Option<&Path>) -> Vec<PathBuf> {
    let mut chain = Vec::new();
    let mut stopped = false;
    for dir in start.ancestors() {
        if home == Some(dir) {
            stopped = true;
            break;
        }
        chain.push(dir.to_path_buf());
        if dir.join(".git").exists() {
            stopped = true;
            break;
        }
    }
    if !stopped {
        chain = vec![start.to_path_buf()];
    }
    chain.reverse();
    chain
}

/// Loads everything for the terminal app (`start` is its current folder) or the Mac app (`None`).
pub fn load(env: &Env, start: Option<&Path>, trust: &TrustStore) -> Loaded {
    let mut out = Loaded::default();
    if let Some(dir) = env.config_dir() {
        read_settings(env, &dir, &mut out);
    }
    let global = env.agents_dir();
    let dirs = start.map_or_else(Vec::new, |s| project_dirs(s, env.home_dir()));

    // The folders in the order they are read: the person's own, then the project's, nearer last.
    let mut agent_dirs: Vec<(PathBuf, Scope)> = Vec::new();
    if let Some(g) = &global {
        agent_dirs.push((g.clone(), Scope::Global));
    }
    for d in &dirs {
        let a = d.join(".agents");
        if global.as_ref() != Some(&a) {
            agent_dirs.push((a, Scope::Project));
        }
    }
    for (dir, scope) in &agent_dirs {
        read_agents(env, dir, *scope, &mut out);
        read_skills(dir, *scope, &mut out);
        read_commands(dir, *scope, &mut out);
    }
    out.agents.retain(|_, a| !a.value.disabled);

    let mut notes: Vec<PathBuf> = Vec::new();
    if let Some(g) = &global {
        notes.push(g.join("AGENTS.md"));
    }
    for d in &dirs {
        notes.push(d.join("AGENTS.md"));
        notes.push(d.join(".agents").join("AGENTS.md"));
    }
    read_instructions(env, &notes, &mut out);

    if let Some(root) = dirs.first() {
        read_project_settings(env, root, &dirs, global.as_deref(), trust, &mut out);
    }
    out
}

fn note(out: &mut Loaded, file: &Path, message: impl Into<String>) {
    out.diagnostics
        .push(Diagnostic::new(Some(file.to_path_buf()), message));
}

/// The text of a file, or nothing when it is not there. Any other failure is a diagnostic.
fn read_text(path: &Path, out: &mut Loaded) -> Option<String> {
    match std::fs::read_to_string(path) {
        Ok(t) => Some(t),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            note(out, path, format!("could not be read: {e}"));
            None
        }
    }
}

/// The entries of a folder by name. A folder that is not there has none.
fn entries(dir: &Path) -> Vec<PathBuf> {
    let mut all: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    all.sort();
    all
}

fn read_settings(env: &Env, dir: &Path, out: &mut Loaded) {
    let file = dir.join("imp.json");
    if let Some(text) = read_text(&file, out) {
        let (config, diags) = parse_config(&text, Some(&file), Some(env));
        out.config = config;
        out.diagnostics.extend(diags);
    }
    let file = dir.join("auth.json");
    if let Some(text) = read_text(&file, out) {
        match serde_json::from_str::<Auth>(&text) {
            Ok(auth) => out.auth = auth,
            // The text of the error can hold a piece of a key, so it is not repeated.
            Err(_) => note(
                out,
                &file,
                "is not valid: it must be JSON with `providers` and `mcp`.",
            ),
        }
    }
}

fn read_agents(env: &Env, dir: &Path, scope: Scope, out: &mut Loaded) {
    for path in entries(&dir.join("agents")) {
        if path.extension().and_then(|e| e.to_str()) != Some("md") || !path.is_file() {
            continue;
        }
        let name = path
            .file_stem()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let Some(text) = read_text(&path, out) else {
            continue;
        };
        let mut problems = Vec::new();
        let base = path.parent().unwrap_or(Path::new("."));
        match Agent::parse_filled(&name, &text, base, env, &mut problems) {
            Ok(agent) => {
                let wrong = agent.problems();
                if !valid_agent_name(&name) {
                    note(out, &path, wrong[0].clone());
                    continue;
                }
                for p in problems.into_iter().chain(wrong) {
                    note(out, &path, p);
                }
                out.agents.insert(
                    name,
                    Sourced {
                        value: agent,
                        path,
                        scope,
                    },
                );
            }
            Err(why) => note(out, &path, why),
        }
    }
}

fn read_skills(dir: &Path, scope: Scope, out: &mut Loaded) {
    for folder in entries(&dir.join("skills"))
        .into_iter()
        .filter(|p| p.is_dir())
    {
        let path = folder.join("SKILL.md");
        let Some(text) = read_text(&path, out) else {
            continue;
        };
        let name = folder
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        match Skill::parse(&name, &text) {
            Ok(skill) => {
                out.skills.insert(
                    name,
                    Sourced {
                        value: skill,
                        path,
                        scope,
                    },
                );
            }
            Err(why) => note(out, &path, format!("the skill: {why}")),
        }
    }
}

fn read_commands(dir: &Path, scope: Scope, out: &mut Loaded) {
    for path in entries(&dir.join("commands")) {
        if path.extension().and_then(|e| e.to_str()) != Some("md") || !path.is_file() {
            continue;
        }
        let name = path
            .file_stem()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let Some(text) = read_text(&path, out) else {
            continue;
        };
        match Command::parse(&name, &text) {
            Ok(command) => {
                out.commands.insert(
                    name,
                    Sourced {
                        value: command,
                        path,
                        scope,
                    },
                );
            }
            Err(why) => note(out, &path, why),
        }
    }
}

fn read_instructions(env: &Env, paths: &[PathBuf], out: &mut Loaded) {
    let mut seen: Vec<PathBuf> = Vec::new();
    let mut found = Vec::new();
    for path in paths {
        let Ok(real) = path.canonicalize() else {
            continue;
        };
        if seen.contains(&real) {
            continue;
        }
        seen.push(real);
        if let Some(text) = read_text(path, out) {
            found.push(Instructions {
                label: shown(env, path),
                text,
            });
        }
    }
    let (kept, left) = agents::fit_instructions(found);
    let most = MOST_INSTRUCTIONS / 1024;
    for l in left {
        out.diagnostics.push(Diagnostic::new(
            None,
            match l {
                LeftOut::Cut(label) => format!(
                    "{label} was cut short: the AGENTS.md files are longer than {most} KB together."
                ),
                LeftOut::Dropped(label) => format!(
                    "{label} was left out: the AGENTS.md files are longer than {most} KB together."
                ),
            },
        ));
    }
    out.instructions = kept;
}

/// A path with the home folder as `~`.
fn shown(env: &Env, path: &Path) -> String {
    match env.home_dir().and_then(|h| path.strip_prefix(h).ok()) {
        Some(rest) => format!("~/{}", rest.display()),
        None => path.display().to_string(),
    }
}

fn read_project_settings(
    env: &Env,
    root: &Path,
    dirs: &[PathBuf],
    global: Option<&Path>,
    trust: &TrustStore,
    out: &mut Loaded,
) {
    let mut files = Vec::new();
    let mut texts = Vec::new();
    for d in dirs {
        let file = d.join(".agents").join("imp.json");
        if global == Some(d.join(".agents").as_path()) {
            continue;
        }
        if let Some(text) = read_text(&file, out) {
            files.push(file);
            texts.push(text);
        }
    }
    if files.is_empty() {
        return;
    }
    let mut asked = String::new();
    for (f, t) in files.iter().zip(&texts) {
        asked.push_str(&format!("{}\n{t}\n", f.display()));
    }
    let digest = crate::workspace::checksum(asked.as_bytes());
    let trusted = trust.allows(root, &digest);
    if trusted {
        for (file, text) in files.iter().zip(&texts) {
            let (project, diags) = parse_config(text, Some(file), Some(env));
            out.diagnostics.extend(diags);
            merge_project(&mut out.config, project, file, &mut out.diagnostics);
        }
    }
    out.project = Some(Project {
        root: root.to_path_buf(),
        config_files: files,
        digest: Some(digest),
        trusted,
    });
}

/// Puts a trusted project's `imp.json` over the configuration: its default model replaces the one
/// there, its providers and servers replace the ones of the same name, and its rules come after the
/// rules already there (so they win). Nothing else is read from a project: the rest is the person's.
pub fn merge_project(
    base: &mut ImpConfig,
    project: ImpConfig,
    file: &Path,
    diags: &mut Vec<Diagnostic>,
) {
    if project.model.is_some() {
        base.model = project.model;
    }
    base.providers.extend(project.providers);
    base.mcp.extend(project.mcp);
    base.permissions.extend(project.permissions);
    let mut ignored = Vec::new();
    for (key, used) in [
        ("imps", !project.imps.is_empty()),
        ("triggers", !project.triggers.is_empty()),
        ("animations", !project.animations.is_empty()),
        ("requests", project.requests.is_some()),
        ("talk", project.talk.is_some()),
        ("link", project.link.is_some()),
    ] {
        if used {
            ignored.push(key);
        }
    }
    if !ignored.is_empty() {
        diags.push(Diagnostic::new(
            Some(file.to_path_buf()),
            format!(
                "{} {} ignored: a project's imp.json sets the model, providers, mcp and permissions.",
                ignored.join(", "),
                if ignored.len() == 1 { "is" } else { "are" }
            ),
        ));
    }
}

impl From<&Skill> for SkillSpec {
    fn from(skill: &Skill) -> Self {
        let description = skill
            .description
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        Self {
            name: skill.name.clone(),
            description: description.chars().take(agents::MOST_DESCRIPTION).collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::McpServer;

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    struct World {
        _dir: tempfile::TempDir,
        home: PathBuf,
        project: PathBuf,
        sub: PathBuf,
        env: Env,
        trust: TrustStore,
    }

    fn world() -> World {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let home = root.join("home");
        let project = home.join("src/app");
        let sub = project.join("crates/x");
        std::fs::create_dir_all(&sub).unwrap();
        std::fs::create_dir_all(project.join(".git")).unwrap();
        let env = Env::new(
            &[
                ("IMP_CONFIG_HOME", root.join("cfg").to_str().unwrap()),
                ("K", "key-1"),
            ],
            Some(&home),
        );
        let trust = TrustStore::at(root.join("trusted.json"));
        World {
            _dir: dir,
            home,
            project,
            sub,
            env,
            trust,
        }
    }

    #[test]
    fn the_chain_stops_at_git_or_home() {
        let w = world();
        assert_eq!(
            project_dirs(&w.sub, Some(&w.home)),
            [w.project.clone(), w.project.join("crates"), w.sub.clone()]
        );
        std::fs::remove_dir(w.project.join(".git")).unwrap();
        // No git root: up to, and not including, home.
        assert_eq!(
            project_dirs(&w.sub, Some(&w.home)).first().unwrap(),
            &w.home.join("src")
        );
        assert!(project_dirs(&w.home, Some(&w.home)).is_empty());
        // Neither: just the folder.
        assert_eq!(project_dirs(&w.sub, None), std::slice::from_ref(&w.sub));
    }

    #[test]
    fn nearer_wins_by_name_and_disabled_hides() {
        let w = world();
        let g = w.home.join(".agents");
        write(
            &g.join("agents/review.md"),
            "---\ndescription: mine\nmodel: p/m\n---\nGlobal review.",
        );
        write(
            &g.join("agents/pip.md"),
            "---\nmodel: '{env:K}/x'\n---\nPip.",
        );
        write(&g.join("agents/old.md"), "Old.");
        write(
            &w.project.join(".agents/agents/review.md"),
            "---\ndescription: project\n---\nProject review.",
        );
        write(
            &w.sub.join(".agents/agents/review.md"),
            "---\ndescription: nearest\n---\nNearest review.",
        );
        write(
            &w.project.join(".agents/agents/old.md"),
            "---\ndisabled: true\n---\n",
        );
        write(
            &g.join("skills/notes/SKILL.md"),
            "---\nname: notes\ndescription: global notes\n---\nG",
        );
        write(
            &w.project.join(".agents/skills/notes/SKILL.md"),
            "---\ndescription: project notes\n---\nP",
        );
        write(&g.join("commands/fix.md"), "Fix it");
        write(
            &w.sub.join(".agents/commands/fix.md"),
            "---\ndescription: nearer\n---\nFix it here",
        );
        let l = load(&w.env, Some(&w.sub), &w.trust);
        assert!(l.diagnostics.is_empty(), "{:?}", l.diagnostics);
        assert_eq!(
            l.agents["review"].value.description.as_deref(),
            Some("nearest")
        );
        assert_eq!(l.agents["review"].scope, Scope::Project);
        assert_eq!(l.agents["pip"].scope, Scope::Global);
        assert_eq!(l.agents["pip"].value.model.as_deref(), Some("key-1/x"));
        assert!(!l.agents.contains_key("old"));
        assert_eq!(l.skills["notes"].value.description, "project notes");
        assert_eq!(l.commands["fix"].value.template, "Fix it here");
        // The Mac app has no folder: only ~/.agents.
        let mac = load(&w.env, None, &w.trust);
        assert_eq!(
            mac.agents["review"].value.description.as_deref(),
            Some("mine")
        );
        assert!(mac.agents.contains_key("old"));
        assert_eq!(mac.imps().count(), 3);
    }

    #[test]
    fn agents_md_is_read_farthest_first_and_capped() {
        let w = world();
        write(&w.home.join(".agents/AGENTS.md"), "own notes");
        write(&w.project.join("AGENTS.md"), "root notes");
        write(&w.project.join(".agents/AGENTS.md"), "root agents notes");
        write(&w.sub.join("AGENTS.md"), "sub notes");
        let l = load(&w.env, Some(&w.sub), &w.trust);
        let texts: Vec<&str> = l.instructions.iter().map(|i| i.text.as_str()).collect();
        assert_eq!(
            texts,
            ["own notes", "root notes", "root agents notes", "sub notes"]
        );
        assert_eq!(l.instructions[0].label, "~/.agents/AGENTS.md");
        let suffix = l.system_suffix();
        assert!(suffix.find("own notes").unwrap() < suffix.find("sub notes").unwrap());
        write(&w.sub.join("AGENTS.md"), &"x".repeat(MOST_INSTRUCTIONS));
        let l = load(&w.env, Some(&w.sub), &w.trust);
        assert!(
            l.diagnostics
                .iter()
                .any(|d| d.message.contains("cut short"))
        );
        assert!(l.instructions.iter().map(|i| i.text.len()).sum::<usize>() <= MOST_INSTRUCTIONS);
    }

    #[test]
    fn a_projects_imp_json_waits_for_trust() {
        let w = world();
        write(
            &w.env.config_dir().unwrap().join("imp.json"),
            r#"{"model":"a/b","mcp":{"own":{"type":"remote","url":"u"}},"permissions":[{"action":"shell","effect":"ask"}],"requests":{"retries":1}}"#,
        );
        write(
            &w.project.join(".agents/imp.json"),
            r#"{"model":"c/d","mcp":{"evil":{"type":"local","command":["rm"]}},"permissions":[{"action":"shell","resource":"rm *","effect":"deny"}],"providers":{"p":{"options":{"apiKey":"{env:K}"}}},"triggers":[{}]}"#,
        );
        let l = load(&w.env, Some(&w.sub), &w.trust);
        let project = l.project.clone().unwrap();
        assert!(!project.trusted);
        assert_eq!(project.root, w.project);
        assert_eq!(l.config.model.as_deref(), Some("a/b"));
        assert!(!l.config.mcp.contains_key("evil") && l.config.providers.is_empty());
        // Trust it, and it merges: nearer model, servers by name, rules after.
        w.trust
            .set(&project.root, project.digest.as_deref())
            .unwrap();
        let l = load(&w.env, Some(&w.sub), &w.trust);
        assert!(l.project.as_ref().unwrap().trusted);
        assert_eq!(l.config.model.as_deref(), Some("c/d"));
        assert!(
            matches!(l.config.mcp["evil"], McpServer::Local { .. })
                && l.config.mcp.contains_key("own")
        );
        assert_eq!(
            l.config.providers["p"].options.api_key.as_deref(),
            Some("key-1")
        );
        assert_eq!(l.config.permissions.len(), 2);
        assert_eq!(l.config.permissions[1].resource, "rm *");
        assert_eq!(l.config.requests.as_ref().unwrap().retries, Some(1));
        assert!(
            l.diagnostics
                .iter()
                .any(|d| d.message.starts_with("triggers is ignored"))
        );
        // A change waits again.
        write(&w.project.join(".agents/imp.json"), r#"{"model":"e/f"}"#);
        let l = load(&w.env, Some(&w.sub), &w.trust);
        assert!(!l.project.unwrap().trusted);
        assert_eq!(l.config.model.as_deref(), Some("a/b"));
        // The Mac app never reads a project's file.
        assert!(load(&w.env, None, &w.trust).project.is_none());
    }

    #[test]
    fn broken_files_are_diagnostics_not_failures() {
        let w = world();
        let cfg = w.env.config_dir().unwrap();
        write(
            &cfg.join("imp.json"),
            r#"{"model":"a/b","providers":{"bad":3}}"#,
        );
        write(
            &cfg.join("auth.json"),
            r#"{"providers":{"p":{"key":"sk-secret-1"}}, nope"#,
        );
        let g = w.home.join(".agents");
        write(&g.join("agents/good.md"), "---\nmodel: a/b\n---\nGood.");
        write(&g.join("agents/broken.md"), "---\nmode: [\n---\n");
        write(&g.join("agents/bad name.md"), "Hi");
        write(
            &g.join("agents/shy.md"),
            "---\nmodel: nope\ncolor: red\nrequest:\n  headers:\n    X: '{env:MISSING}'\n---\n",
        );
        write(
            &g.join("skills/nodesc/SKILL.md"),
            "---\nname: nodesc\n---\n",
        );
        write(
            &g.join("skills/wrong/SKILL.md"),
            "---\nname: other\ndescription: d\n---\n",
        );
        write(&g.join("commands/bad name.md"), "x");
        let l = load(&w.env, None, &w.trust);
        assert_eq!(l.config.model.as_deref(), Some("a/b"));
        assert_eq!(l.agents.keys().collect::<Vec<_>>(), ["good", "shy"]);
        let said: Vec<String> = l.diagnostics.iter().map(ToString::to_string).collect();
        for part in [
            "providers.bad",
            "auth.json",
            "broken.md: the front matter is not valid",
            "bad name.md",
            "is not a model",
            "is not #rrggbb",
            "MISSING",
            "no description",
            "name of its folder",
            "command name",
        ] {
            assert!(said.iter().any(|m| m.contains(part)), "{part} in {said:#?}");
        }
        assert!(!said.iter().any(|m| m.contains("sk-secret")));
        assert!(l.auth.providers.is_empty());
    }

    #[test]
    fn auth_and_missing_everything() {
        let w = world();
        let l = load(&w.env, Some(&w.sub), &w.trust);
        assert!(l.diagnostics.is_empty() && l.agents.is_empty() && l.project.is_none());
        write(
            &w.env.config_dir().unwrap().join("auth.json"),
            r#"{"providers":{"p":{"key":"k"}}}"#,
        );
        let l = load(&w.env, None, &w.trust);
        assert_eq!(l.auth.key_for("p", None).as_deref(), Some("k"));
    }
}
