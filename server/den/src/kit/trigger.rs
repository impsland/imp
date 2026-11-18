//! Trigger rules of a kit: one event, optional conditions, one to five steps.

use serde_json::Value;

use super::Problems;

const MAX_STEPS: usize = 5;
const MAX_NAME: usize = 60;

const EVENTS: [&str; 28] = [
    "keys", "click", "poke", "hold", "drag", "drop", "shake", "stroke", "tickle", "circle",
    "swish", "rush", "dangle", "near", "away", "start", "at", "every", "idle", "back", "wake",
    "app", "website", "battery", "charger", "busy", "hot", "network",
];
const STATES: [&str; 10] = [
    "battery", "charger", "app", "website", "busy", "hot", "network", "hours", "days", "asleep",
];
const ACTS: [&str; 7] = ["ask", "say", "play", "sleep", "wake", "follow", "open"];

pub(super) fn check_trigger(trigger: &Value, at: &str, problems: &mut Problems) {
    let Some(trigger) = trigger.as_object() else {
        problems.add(at, "must be an object");
        return;
    };
    if let Some(name) = trigger.get("name").filter(|n| !n.is_null()) {
        match name.as_str().map(str::trim) {
            Some(n) if !n.is_empty() && n.chars().count() <= MAX_NAME => {}
            _ => problems.add(
                &format!("{at}/name"),
                format!("a name must be 1 to {MAX_NAME} characters"),
            ),
        }
    }
    match trigger.get("on").and_then(Value::as_str) {
        Some(on) if EVENTS.contains(&on) => {}
        Some(on) => problems.add(&format!("{at}/on"), format!("unknown event `{on}`")),
        None => problems.add(&format!("{at}/on"), "an event name is required"),
    }
    match trigger.get("if") {
        None | Some(Value::Null) => {}
        Some(Value::Array(conds)) => {
            for (n, cond) in conds.iter().enumerate() {
                let at = format!("{at}/if/{n}");
                match cond.as_object() {
                    None => problems.add(&at, "must be an object"),
                    Some(c) => match c.get("state").and_then(Value::as_str) {
                        Some(s) if STATES.contains(&s) => {}
                        Some(s) => {
                            problems.add(&format!("{at}/state"), format!("unknown state `{s}`"))
                        }
                        None => problems.add(&format!("{at}/state"), "a state name is required"),
                    },
                }
            }
        }
        Some(_) => problems.add(&format!("{at}/if"), "must be a list of conditions"),
    }
    match trigger.get("do").and_then(Value::as_array) {
        Some(steps) if (1..=MAX_STEPS).contains(&steps.len()) => {
            for (n, step) in steps.iter().enumerate() {
                let at = format!("{at}/do/{n}");
                match step.as_object() {
                    None => problems.add(&at, "must be an object"),
                    Some(s) => match s.get("act").and_then(Value::as_str) {
                        Some(a) if ACTS.contains(&a) => {}
                        Some(a) => problems.add(&format!("{at}/act"), format!("unknown act `{a}`")),
                        None => problems.add(&format!("{at}/act"), "an act name is required"),
                    },
                }
            }
        }
        _ => problems.add(
            &format!("{at}/do"),
            format!("needs a list of 1 to {MAX_STEPS} steps"),
        ),
    }
}
