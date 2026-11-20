//! Permission rules: an action, a resource pattern and an effect. The rules are read in order, the
//! built-in defaults first, and the last one that matches decides.

use crate::config::doc::Agent;
use crate::config::types::ImpConfig;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Effect {
    Allow,
    Ask,
    Deny,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rule {
    pub action: String,
    #[serde(default = "any")]
    pub resource: String,
    pub effect: Effect,
}

fn any() -> String {
    "*".into()
}

impl Rule {
    pub fn new(action: &str, resource: &str, effect: Effect) -> Self {
        Self {
            action: action.into(),
            resource: resource.into(),
            effect,
        }
    }
}

/// Whether `text` matches `pattern`, where `*` is any run of characters (also none, also `/`) and
/// `?` is one character. Everything else must be the same.
pub fn glob_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti) = (0, 0);
    // Where the last `*` was, and how much text it has taken so far.
    let mut star: Option<(usize, usize)> = None;
    while ti < t.len() {
        match p.get(pi) {
            Some('*') => {
                star = Some((pi, ti));
                pi += 1;
            }
            Some(c) if *c == '?' || *c == t[ti] => {
                pi += 1;
                ti += 1;
            }
            _ => match star {
                Some((sp, st)) => {
                    pi = sp + 1;
                    ti = st + 1;
                    star = Some((sp, st + 1));
                }
                None => return false,
            },
        }
    }
    p[pi..].iter().all(|c| *c == '*')
}

/// The effect when no rule matches: a thing nobody forbade is allowed.
pub const UNMATCHED: Effect = Effect::Allow;

/// The effect of the last rule that matches, or [`UNMATCHED`].
pub fn decide(rules: &[Rule], action: &str, resource: &str) -> Effect {
    decide_in(rules, action, resource, None)
}

/// Like [`decide`], and a pattern that starts with `~` means the home folder.
pub fn decide_in(rules: &[Rule], action: &str, resource: &str, home: Option<&str>) -> Effect {
    rules
        .iter()
        .rev()
        .find(|r| {
            glob_match(&r.action, action) && {
                match (home, r.resource.strip_prefix('~')) {
                    (Some(h), Some(rest)) => {
                        glob_match(&format!("{}{rest}", h.trim_end_matches('/')), resource)
                    }
                    _ => glob_match(&r.resource, resource),
                }
            }
        })
        .map_or(UNMATCHED, |r| r.effect)
}

/// What every Imp starts with: the groups of its own tools that are off until someone switches them on
/// (`tools::GROUPS`: computer control) are denied.
pub fn default_rules() -> Vec<Rule> {
    crate::tools::GROUPS
        .iter()
        .filter(|(_, on)| !on)
        .map(|(group, _)| Rule::new(group, "*", Effect::Deny))
        .collect()
}

/// The rules that apply to an agent, in the order they are read: the defaults, `imp.json`'s, its own.
pub fn effective_rules(config: &ImpConfig, agent: &Agent) -> Vec<Rule> {
    let mut rules = default_rules();
    rules.extend(config.permissions.iter().cloned());
    rules.extend(agent.permissions.iter().cloned());
    rules
}

/// Whether the agent may use a group of its own tools (the switch in its settings): it is not denied.
pub fn group_enabled(config: &ImpConfig, agent: &Agent, group: &str) -> bool {
    decide(&effective_rules(config, agent), group, "*") != Effect::Deny
}

/// Makes `action` on `resource` allowed (`on`) or denied for the agent, with as few rules as it takes:
/// the agent's own rules for exactly that pair are dropped, and one is added only when the defaults and
/// `imp.json` do not already give the wanted answer. A group switched off is
/// `{action: group, resource: "*", effect: deny}` and switching it on removes that rule.
pub fn set_rule(config: &ImpConfig, agent: &mut Agent, action: &str, resource: &str, on: bool) {
    agent
        .permissions
        .retain(|r| !(r.action == action && r.resource == resource));
    let enabled = decide(&effective_rules(config, agent), action, resource) != Effect::Deny;
    if enabled != on {
        let effect = if on { Effect::Allow } else { Effect::Deny };
        agent.permissions.push(Rule::new(action, resource, effect));
    }
}

/// [`set_rule`] for a group of the Imp's own tools.
pub fn set_group(config: &ImpConfig, agent: &mut Agent, group: &str, on: bool) {
    set_rule(config, agent, group, "*", on);
}

/// [`set_rule`] for every tool of an MCP server.
pub fn set_mcp_server(config: &ImpConfig, agent: &mut Agent, server: &str, on: bool) {
    set_rule(config, agent, "mcp", &format!("{server}/*"), on);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn globs() {
        for (p, t, want) in [
            ("*", "", true),
            ("*", "anything/at all", true),
            ("a*c", "abc", true),
            ("a*c", "ac", true),
            ("a*c", "abd", false),
            ("a?c", "abc", true),
            ("a?c", "ac", false),
            ("files/*", "files/read", true),
            ("files/*", "other/read", false),
            ("rm -rf *", "rm -rf /", true),
            ("rm -rf *", "rm -r /", false),
            ("*.md", "a/b.md", true),
            ("*a*b*", "xaxxbx", true),
            ("*a*b*", "xbxa", false),
            ("", "", true),
            ("", "a", false),
            ("é?", "éx", true),
        ] {
            assert_eq!(glob_match(p, t), want, "{p:?} {t:?}");
        }
    }

    #[test]
    fn the_last_match_decides() {
        let rules = [
            Rule::new("shell", "*", Effect::Ask),
            Rule::new("shell", "git *", Effect::Allow),
            Rule::new("shell", "git push*", Effect::Deny),
        ];
        assert_eq!(decide(&rules, "shell", "ls"), Effect::Ask);
        assert_eq!(decide(&rules, "shell", "git status"), Effect::Allow);
        assert_eq!(decide(&rules, "shell", "git push -f"), Effect::Deny);
        assert_eq!(decide(&rules, "read", "x"), UNMATCHED);
        assert_eq!(decide(&[], "shell", "x"), Effect::Allow);
        let again = [rules[2].clone(), Rule::new("shell", "*", Effect::Allow)];
        assert_eq!(decide(&again, "shell", "git push"), Effect::Allow);
    }

    #[test]
    fn home_in_a_pattern() {
        let rules = [
            Rule::new("read", "*", Effect::Deny),
            Rule::new("read", "~/src/*", Effect::Allow),
        ];
        assert_eq!(
            decide_in(&rules, "read", "/h/src/a.rs", Some("/h")),
            Effect::Allow
        );
        assert_eq!(
            decide_in(&rules, "read", "/h/other", Some("/h/")),
            Effect::Deny
        );
        assert_eq!(decide(&rules, "read", "/h/src/a.rs"), Effect::Deny);
    }

    #[test]
    fn defaults_deny_computer_only() {
        assert_eq!(default_rules(), [Rule::new("computer", "*", Effect::Deny)]);
        let config = ImpConfig::default();
        let agent = Agent::default();
        for (group, on) in crate::tools::GROUPS {
            assert_eq!(group_enabled(&config, &agent, group), on, "{group}");
        }
    }

    #[test]
    fn groups_are_switched_with_the_canonical_rule() {
        let config = ImpConfig::default();
        let mut agent = Agent::default();
        set_group(&config, &mut agent, "triggers", false);
        assert_eq!(
            agent.permissions,
            [Rule::new("triggers", "*", Effect::Deny)]
        );
        set_group(&config, &mut agent, "triggers", false);
        assert_eq!(agent.permissions.len(), 1);
        set_group(&config, &mut agent, "triggers", true);
        assert!(agent.permissions.is_empty());
        // Computer control is opt-in: on is an allow rule, off removes it again.
        set_group(&config, &mut agent, "computer", true);
        assert_eq!(
            agent.permissions,
            [Rule::new("computer", "*", Effect::Allow)]
        );
        assert!(group_enabled(&config, &agent, "computer"));
        set_group(&config, &mut agent, "computer", false);
        assert!(agent.permissions.is_empty());
    }

    #[test]
    fn imp_json_rules_come_between_the_defaults_and_the_agent() {
        let mut config = ImpConfig::default();
        config
            .permissions
            .push(Rule::new("look", "*", Effect::Deny));
        let mut agent = Agent::default();
        assert!(!group_enabled(&config, &agent, "look"));
        set_group(&config, &mut agent, "look", true);
        assert_eq!(agent.permissions, [Rule::new("look", "*", Effect::Allow)]);
        set_group(&config, &mut agent, "look", false);
        assert!(agent.permissions.is_empty());
        set_mcp_server(&config, &mut agent, "files", false);
        let rules = effective_rules(&config, &agent);
        assert_eq!(decide(&rules, "mcp", "files/read"), Effect::Deny);
        assert_eq!(decide(&rules, "mcp", "web/get"), Effect::Allow);
        set_mcp_server(&config, &mut agent, "files", true);
        assert!(agent.permissions.is_empty());
    }

    #[test]
    fn rules_read_and_write_as_json() {
        let rule: Rule = serde_json::from_str(r#"{"action":"shell","effect":"ask"}"#).unwrap();
        assert_eq!(rule, Rule::new("shell", "*", Effect::Ask));
        assert_eq!(
            serde_json::to_value(&rule).unwrap()["effect"],
            Value::from("ask")
        );
        assert!(serde_json::from_str::<Rule>(r#"{"action":"a","effect":"maybe"}"#).is_err());
    }
}
