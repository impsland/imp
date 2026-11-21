//! The page's node, driven the way web/app/link.js drives it, with an in-memory wire instead of WebSockets.

use imp_web::{WebNode, qr_path};
use serde_json::Value;

const HOME: &str = "00000000-0000-0000-0000-00000000000a";
const PAGE: &str = "00000000-0000-0000-0000-00000000000b";

/// One side of the wire: its node, and the connection id the node gave the wire.
struct Side {
    node: WebNode,
    conn: Option<f64>,
    events: Vec<Value>,
    dials: Vec<Value>,
}

impl Side {
    fn new(name: &str, id: &str) -> Self {
        let mut node = WebNode::new(None, name, id).expect("node");
        node.start(1.0);
        Self {
            node,
            conn: None,
            events: Vec::new(),
            dials: Vec::new(),
        }
    }

    /// What the node asked for: bytes for the wire are returned, the rest is kept.
    fn drain(&mut self) -> Vec<Vec<u8>> {
        use base64::Engine;
        let outputs: Vec<Value> = serde_json::from_str(&self.node.drain()).expect("JSON");
        let mut wire = Vec::new();
        for output in outputs {
            if let Some(send) = output.get("send") {
                assert_eq!(
                    send["conn"].as_f64(),
                    self.conn,
                    "bytes for the wire's connection"
                );
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(send["bytes"].as_str().expect("base64"))
                    .expect("bytes");
                wire.push(bytes);
            } else if let Some(event) = output.get("event") {
                self.events.push(event.clone());
            } else if let Some(dial) = output.get("dial") {
                self.dials.push(dial.clone());
            }
        }
        wire
    }

    fn event(&self, name: &str) -> Option<&Value> {
        self.events.iter().find_map(|e| e.get(name))
    }
}

/// Moves bytes both ways until neither side has anything to say.
fn pump(a: &mut Side, b: &mut Side, now: f64) {
    for _ in 0..50 {
        let to_b = a.drain();
        let to_a = b.drain();
        if to_a.is_empty() && to_b.is_empty() {
            return;
        }
        for bytes in to_b {
            b.node.received(b.conn.expect("b conn"), &bytes, now);
        }
        for bytes in to_a {
            a.node.received(a.conn.expect("a conn"), &bytes, now);
        }
    }
    panic!("the two nodes never went quiet");
}

/// The page joins the home with its code over one connection, as it would through the Hop.
fn linked() -> (Side, Side) {
    let mut home = Side::new("Terminal", HOME);
    let mut page = Side::new("Web", PAGE);
    home.node
        .set_hop(Some("hop.example.com:4677".into()))
        .expect("hop");
    let code = home.node.invite(1.0);
    assert!(code.starts_with("implink://join?"), "{code}");
    assert!(code.contains("hop=hop.example.com:4677"), "{code}");
    let host = page.node.join(&code, 1.0).expect("a code");
    assert_eq!(host, HOME);
    page.drain();
    let dial = page.dials.first().expect("the page dials the home").clone();
    assert_eq!(dial["device"], HOME);
    assert_eq!(dial["hop"], "hop.example.com:4677");
    let hop = page.node.hop_guest(HOME).expect("id").expect("a Hop guest");
    assert_eq!(hop.address(), "hop.example.com:4677");
    assert_eq!(hop.hello().len(), 71, "the Hop's hello");
    home.drain();
    home.conn = home.node.accepted(true, 2.0);
    page.conn = page.node.dialed(HOME, true, 2.0).expect("id");
    pump(&mut page, &mut home, 2.0);
    (home, page)
}

#[test]
fn a_page_joins_with_a_code_and_both_sides_see_the_link() {
    let (home, page) = linked();
    let joined = page.event("joined").expect("joined");
    assert_eq!(joined["ok"], true, "{joined}");
    assert_eq!(joined["host"]["name"], "Terminal");
    assert!(home.event("linked").is_some(), "{:?}", home.events);

    let state: Value = serde_json::from_str(&page.node.state()).expect("state");
    assert_eq!(state["device"]["name"], "Web");
    assert_eq!(state["links"][0]["id"], HOME);
    assert_eq!(state["links"][0]["connected"], true);
    assert_eq!(state["links"][0]["viaHop"], true);
    let text = page.node.state();
    assert!(
        !text.contains("door") && !text.contains("key") && !text.contains("ticket"),
        "no secrets: {text}"
    );
}

#[test]
fn a_page_waits_at_its_own_hop_once_it_has_one() {
    let mut page = Side::new("Web", PAGE);
    assert!(page.node.hop_host().is_none(), "no Hop yet");
    page.node
        .set_hop(Some("hop.example.com:4677".into()))
        .expect("hop");
    page.drain();
    let hop = page.node.hop_host().expect("waits as the host");
    assert_eq!(hop.address(), "hop.example.com:4677");
    assert_eq!(hop.hello()[6], 1, "the host's role");
}

#[test]
fn messages_cross_as_wire_json() {
    let (mut home, mut page) = linked();
    let sent = page
        .node
        .send(r#"{"stage":{"imps":[]}}"#, HOME)
        .expect("a link message");
    assert!(sent);
    pump(&mut page, &mut home, 3.0);
    // A linked peer may send its stage, and the home's app hears it.
    assert!(
        home.events.iter().any(|e| e
            .get("message")
            .is_some_and(|m| m["message"].get("stage").is_some())),
        "{:?}",
        home.events
    );
}

#[test]
fn a_qr_path_draws_every_dark_module() {
    let qr: Value =
        serde_json::from_str(&qr_path("implink://join?d=x").expect("qr")).expect("JSON");
    let size = qr["size"].as_u64().expect("size");
    assert!(size >= 21);
    assert!(qr["path"].as_str().expect("path").starts_with('M'));
}

#[test]
fn the_doors_of_a_side_name_the_devices_it_leads_to() {
    let (_home, page) = linked();
    let imp = "33333333-3333-4333-8333-333333333333";
    let doors: Value =
        serde_json::from_str(&page.node.doors(imp, "left", 0.5).expect("doors")).expect("JSON");
    // One linked device: the whole side leads to it, and a throw anywhere on it goes there.
    assert_eq!(doors["bands"][0]["id"], HOME, "{doors}");
    assert_eq!(doors["bands"][0]["name"], "Terminal");
    assert_eq!(doors["bands"][0]["top"], 0.0);
    assert_eq!(doors["bands"][0]["bottom"], 1.0);
    assert_eq!(doors["bands"][0]["back"], false);
    assert_eq!(doors["lit"], HOME);
}

#[test]
fn an_upload_for_an_imp_the_page_does_not_hold_goes_nowhere_and_an_ask_may_name_attachments() {
    let (mut home, mut page) = linked();
    let imp = "33333333-3333-4333-8333-333333333333";
    // An empty or too big file is nothing, and so is a home that is not connected.
    assert_eq!(
        page.node
            .upload(imp, HOME, "a.png", "image/png", b"", 3.0)
            .unwrap(),
        None
    );
    let huge = vec![0u8; 25 * 1024 * 1024 + 1];
    assert_eq!(
        page.node
            .upload(imp, HOME, "a.png", "image/png", &huge, 3.0)
            .unwrap(),
        None
    );
    let elsewhere = "00000000-0000-0000-0000-0000000000cc";
    assert_eq!(
        page.node
            .upload(imp, elsewhere, "a.png", "image/png", b"x", 3.0)
            .unwrap(),
        None
    );
    // The page isn't the holder, so the home drops the upload and the ask that names it.
    let id = page
        .node
        .upload(imp, HOME, "a.png", "image/png", b"pixels", 3.0)
        .unwrap()
        .expect("queued for the home");
    let ask = format!(r#"{{"ask":{{"imp":"{imp}","text":"look","attachments":["{id}"]}}}}"#);
    assert!(page.node.send(&ask, HOME).expect("a link message"));
    pump(&mut page, &mut home, 3.0);
    assert!(
        !home.events.iter().any(|e| e
            .get("message")
            .is_some_and(|m| m["message"].get("ask").is_some())),
        "{:?}",
        home.events
    );
    // An ask without attachments still reads as before.
    let plain = format!(r#"{{"ask":{{"imp":"{imp}","text":"hi"}}}}"#);
    assert!(page.node.send(&plain, HOME).expect("a link message"));
}

#[test]
fn an_imp_thrown_off_one_side_comes_in_by_the_other() {
    use imp_engine::link::LinkSide;
    use imp_web::throw_entry;
    // Off the page's right side: into the next screen from its left, and the other way round.
    assert_eq!(
        throw_entry(LinkSide::Right, 0.4, 1500.0).side,
        LinkSide::Left
    );
    assert_eq!(
        throw_entry(LinkSide::Left, 0.4, 1500.0).side,
        LinkSide::Right
    );
    assert_eq!(throw_entry(LinkSide::Right, 2.0, 0.0).height, 1.0);
}
