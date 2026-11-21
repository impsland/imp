//! A web page as one of the person's devices on Imp Link (`docs/connecting/link.md`).
//!
//! The node in `imp-engine` keeps every rule: the Noise handshake, who may send what, tickets, visits and
//! the book. A browser can't open TCP, so the page (web/app/link.js) carries the node's bytes over
//! WebSockets, to the Hop or to a device that takes them, and calls in here for everything else. Values
//! cross as JSON text, and bytes inside it as standard base64.

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use imp_engine::link::card::{LinkCard, LinkDevice, LinkKind};
use imp_engine::link::doors::{Bounce, Door};
use imp_engine::link::hop::{HopAddress, HopClient, HopCredentials, HopStatus};
use imp_engine::link::node::{Event, Node, Options, Output, PassOutcome, Problem};
use imp_engine::link::{LinkDecline, LinkEntry, LinkInvite, LinkMessage, LinkSide, LinkStaged};
use serde_json::{Value, json};
use std::collections::HashMap;
use uuid::Uuid;
use wasm_bindgen::prelude::*;

fn b64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

fn uuid(text: &str) -> Result<Uuid, JsError> {
    Uuid::parse_str(text).map_err(|_| JsError::new("not a device or Imp id"))
}

fn kind_name(kind: LinkKind) -> &'static str {
    match kind {
        LinkKind::Mac => "mac",
        LinkKind::Phone => "phone",
    }
}

/// What the page may know of a device: never its keys.
fn device_json(device: &LinkDevice) -> Value {
    json!({ "id": device.id, "name": device.name, "kind": kind_name(device.kind) })
}

fn status_name(status: HopStatus) -> &'static str {
    match status {
        HopStatus::Go => "go",
        HopStatus::Rejected => "rejected",
        HopStatus::Busy => "busy",
        HopStatus::Nobody => "nobody",
    }
}

fn decline_name(reason: LinkDecline) -> String {
    serde_json::to_value(reason)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_else(|| "other".into())
}

fn problem_text(problem: &Problem) -> String {
    match problem {
        Problem::Listener(why) | Problem::Storage(why) => why.clone(),
        Problem::Refused(_) => {
            "The other device refused the connection: update Imp on both devices.".into()
        }
        Problem::KeyChanged(_) => {
            "The other device showed another key than the one it linked with.".into()
        }
        Problem::Hop => "The Hop turned this device away.".into(),
        Problem::InviteRefused(_) => {
            "The code was refused: it expired, or the device forgot it. Show a new one.".into()
        }
        Problem::Full(what) => format!("Too many {what}."),
    }
}

fn event_json(event: Event) -> Value {
    match event {
        Event::Connected(device, standing) => json!({ "connected": {
            "device": device_json(&device),
            "peer": matches!(standing, imp_engine::link::access::Standing::Peer),
        }}),
        Event::Disconnected(device) => json!({ "disconnected": { "device": device } }),
        Event::Linked(device) => json!({ "linked": { "device": device_json(&device) } }),
        Event::Forgotten(device, forgotten) => json!({ "forgotten": {
            "device": device,
            "calledHome": forgotten.called_home,
            "sentHome": forgotten.sent_home,
        }}),
        Event::Message(message, from) => json!({ "message": { "from": from, "message": message } }),
        Event::Passed(passed) => {
            let (took, reason) = match passed.outcome {
                PassOutcome::Took => (true, None),
                PassOutcome::Declined(reason) => (false, Some(decline_name(reason))),
            };
            json!({ "passed": {
                "transfer": passed.transfer, "imp": passed.imp, "to": passed.to,
                "took": took, "reason": reason,
            }})
        }
        Event::Joined { device, result } => match result {
            Ok(host) => {
                json!({ "joined": { "device": device, "ok": true, "host": device_json(&host) } })
            }
            Err(error) => {
                json!({ "joined": { "device": device, "ok": false, "error": format!("{error:?}") } })
            }
        },
        Event::Problem(problem) => json!({ "problem": problem_text(&problem) }),
    }
}

/// How an Imp thrown off `side` of the page comes in on the other device: by the opposite side (thrown
/// off the right, it comes in from the left), as the Mac and the iPhone send it. The entry names the side it
/// comes in by.
pub fn throw_entry(side: LinkSide, height: f64, speed: f64) -> LinkEntry {
    LinkEntry::after(side, height.clamp(0.0, 1.0), speed)
}

fn side_named(side: &str) -> Result<LinkSide, JsError> {
    match side {
        "left" => Ok(LinkSide::Left),
        "right" => Ok(LinkSide::Right),
        _ => Err(JsError::new("A side is left or right.")),
    }
}

/// A QR code of `text` as one SVG path in a `size` by `size` box, without the quiet zone: JSON
/// `{ "size", "path" }`. The CLI draws its codes with the same crate.
#[wasm_bindgen]
pub fn qr_path(text: &str) -> Result<String, JsError> {
    let code = qrcode::QrCode::new(text.as_bytes())
        .map_err(|_| JsError::new("That text is too long for a QR code."))?;
    let size = code.width();
    let mut path = String::new();
    for (i, color) in code.to_colors().iter().enumerate() {
        if *color == qrcode::Color::Dark {
            path.push_str(&format!("M{} {}h1v1h-1z", i % size, i / size));
        }
    }
    Ok(json!({ "size": size, "path": path }).to_string())
}

/// Reads a QR code from a camera frame: `rgba` is width*height*4 bytes (canvas ImageData). The first code's text, or nothing.
#[wasm_bindgen]
pub fn scan_qr(rgba: &[u8], width: u32, height: u32) -> Option<String> {
    let (w, h) = (width as usize, height as usize);
    if w == 0 || h == 0 || w.checked_mul(h)?.checked_mul(4)? != rgba.len() {
        return None;
    }
    let mut image = rqrr::PreparedImage::prepare_from_greyscale(w, h, |x, y| {
        let p = &rgba[(y * w + x) * 4..][..3];
        // Integer Rec. 601 luma.
        ((u32::from(p[0]) * 77 + u32::from(p[1]) * 150 + u32::from(p[2]) * 29) >> 8) as u8
    });
    image
        .detect_grids()
        .into_iter()
        .find_map(|grid| grid.decode().ok().map(|(_, text)| text))
}

/// The Hop's handshake for one connection (`spec/PROTOCOL.md`), done by the core for the page.
#[wasm_bindgen]
pub struct WebHop {
    client: HopClient,
    address: String,
}

#[wasm_bindgen]
impl WebHop {
    /// The Hop as `host:port`, as the code gives it.
    #[wasm_bindgen(getter)]
    pub fn address(&self) -> String {
        self.address.clone()
    }

    /// The first bytes to send.
    pub fn hello(&self) -> Vec<u8> {
        self.client.hello()
    }

    /// Feeds what the Hop sent. JSON: `reply` (base64, send it now), `status` (`go`, `rejected`, `busy`,
    /// `nobody` or null while it goes on) and `rest` (base64: after `go`, the first bytes of the link).
    pub fn feed(&mut self, data: &[u8]) -> Result<String, JsError> {
        let progress = self
            .client
            .feed(data)
            .map_err(|_| JsError::new("The Hop did not speak the Hop protocol."))?;
        Ok(json!({
            "reply": b64(&progress.reply),
            "status": progress.status.map(status_name),
            "rest": b64(&progress.rest),
        })
        .to_string())
    }

    /// What the Hop answered before it closed, if anything.
    pub fn closed(&self) -> Option<String> {
        self.client.closed().map(|s| status_name(s).to_owned())
    }
}

/// This page's link node.
#[wasm_bindgen]
pub struct WebNode {
    node: Node,
    /// Who each dial is for, so a Hop guest can be made for it.
    dials: HashMap<Uuid, LinkCard>,
}

#[wasm_bindgen]
impl WebNode {
    /// A node from its saved book, or a new device named `name` with id `id` when there is none.
    #[wasm_bindgen(constructor)]
    pub fn new(saved: Option<Vec<u8>>, name: &str, id: &str) -> Result<WebNode, JsError> {
        let node = Node::new(
            saved.as_deref(),
            name,
            LinkKind::Mac,
            uuid(id)?,
            Options::default(),
        )
        .map_err(|_| JsError::new("The saved link book could not be read."))?;
        Ok(Self {
            node,
            dials: HashMap::new(),
        })
    }

    /// This device: `{ id, name, kind }`.
    pub fn device(&self) -> String {
        device_json(&self.node.device()).to_string()
    }

    pub fn start(&mut self, now: f64) {
        // A page has no listener and no host names, so nobody dials it directly. The node only waits at
        // its Hop once the adapter "listens", so it is given the usual port, which no code ever names a
        // host for.
        self.node.set_hosts(Vec::new());
        self.node.set_port(Some(imp_engine::link::PORT));
        self.node.start(now);
    }

    pub fn stop(&mut self, now: f64) {
        self.node.stop(now);
    }

    pub fn tick(&mut self, now: f64) {
        self.node.tick(now);
    }

    pub fn rename(&mut self, name: &str) {
        self.node.rename(name);
    }

    /// The Hop to wait at, as `host:port`, or nothing.
    pub fn set_hop(&mut self, hop: Option<String>) -> Result<(), JsError> {
        let address = match hop.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            Some(text) => {
                Some(HopAddress::parse(text).ok_or_else(|| JsError::new("The Hop is host:port."))?)
            }
            None => None,
        };
        self.node.set_server(address);
        Ok(())
    }

    /// A connection came in (from the Hop, as its host). Its id, or nothing when the node won't take it.
    pub fn accepted(&mut self, via_hop: bool, now: f64) -> Option<f64> {
        self.node.accepted(via_hop, now).map(|c| c as f64)
    }

    /// A dial the node asked for opened.
    pub fn dialed(
        &mut self,
        device: &str,
        via_hop: bool,
        now: f64,
    ) -> Result<Option<f64>, JsError> {
        let device = uuid(device)?;
        self.dials.remove(&device);
        Ok(self.node.dialed(device, via_hop, now).map(|c| c as f64))
    }

    pub fn dial_failed(&mut self, device: &str, now: f64) -> Result<(), JsError> {
        let device = uuid(device)?;
        self.dials.remove(&device);
        self.node.dial_failed(device, now);
        Ok(())
    }

    pub fn received(&mut self, conn: f64, data: &[u8], now: f64) {
        self.node.received(conn as u64, data, now);
    }

    pub fn closed(&mut self, conn: f64, now: f64) {
        self.node.closed(conn as u64, now);
    }

    /// The book could not be stored. The node reports it as a problem.
    pub fn save_failed(&mut self, reason: &str) {
        self.node.save_failed(reason);
    }

    pub fn hop_rejected(&mut self) {
        self.node.hop_rejected();
    }

    /// Everything the node asks for, oldest first, as a JSON list of one-key objects:
    /// `send` `{ conn, bytes }`, `close` `{ conn }`, `dial` `{ device, name, hosts, port, hop }`, `save`
    /// (the book), `hopChanged`, `event` (see `event_json`). Bytes are base64.
    pub fn drain(&mut self) -> String {
        let mut out = Vec::new();
        loop {
            let outputs = self.node.drain();
            if outputs.is_empty() {
                break;
            }
            for output in outputs {
                out.push(match output {
                    Output::Send { conn, bytes } => {
                        json!({ "send": { "conn": conn, "bytes": b64(&bytes) } })
                    }
                    Output::Close { conn } => json!({ "close": { "conn": conn } }),
                    Output::Dial(request) => {
                        let routes = &request.card.routes;
                        let value = json!({ "dial": {
                            "device": request.device,
                            "name": request.card.device.name,
                            "hosts": routes.hosts,
                            "port": routes.port,
                            "hop": routes.hop,
                        }});
                        self.dials.insert(request.device, request.card);
                        value
                    }
                    Output::Save(bytes) => json!({ "save": b64(&bytes) }),
                    Output::Relisten => continue,
                    Output::HopChanged => json!({ "hopChanged": {} }),
                    Output::Event(event) => json!({ "event": event_json(event) }),
                });
            }
        }
        Value::Array(out).to_string()
    }

    /// The Hop handshake of a guest for a dial the node asked for, when that device has a Hop.
    pub fn hop_guest(&self, device: &str) -> Result<Option<WebHop>, JsError> {
        let Some(card) = self.dials.get(&uuid(device)?) else {
            return Ok(None);
        };
        let Some(address) = card.routes.hop.as_deref().and_then(HopAddress::parse) else {
            return Ok(None);
        };
        let (Ok(room), Ok(door)) = (
            <[u8; 32]>::try_from(card.device.room.0.as_slice()),
            <[u8; 32]>::try_from(card.door.0.as_slice()),
        ) else {
            return Ok(None);
        };
        Ok(Some(WebHop {
            client: HopClient::new(HopCredentials::guest(room, &door)),
            address: address.text(),
        }))
    }

    /// The Hop handshake for waiting at this device's own Hop as its host, when one is set.
    pub fn hop_host(&self) -> Option<WebHop> {
        let (address, credentials, _) = self.node.hop_host()?;
        Some(WebHop {
            client: HopClient::new(credentials),
            address: address.text(),
        })
    }

    /// Joins with a code (`implink://join?...`). The answer comes as a `joined` event.
    pub fn join(&mut self, code: &str, now: f64) -> Result<String, JsError> {
        let invite = LinkInvite::parse(code.trim())
            .ok_or_else(|| JsError::new("That is not an Imp linking code."))?;
        let id = invite.device.id;
        self.node.join(&invite, now);
        Ok(id.to_string())
    }

    /// A code for another device to scan. Call `invite_hidden` once it is off screen.
    pub fn invite(&mut self, now: f64) -> String {
        self.node.invite(now).url()
    }

    pub fn invite_hidden(&mut self, now: f64) {
        self.node.invite_hidden(now);
    }

    /// Sends a message (its wire JSON, such as `{"ask":{"imp":"…","text":"Hi"}}`, which may add `"attachments":[ids]`) to a device.
    pub fn send(&mut self, message: &str, to: &str) -> Result<bool, JsError> {
        let message: LinkMessage = serde_json::from_str(message)
            .map_err(|e| JsError::new(&format!("Not a link message: {e}")))?;
        Ok(self.node.send(&message, uuid(to)?))
    }

    /// Sends a file to `to`, the home of an Imp this page holds, and returns its id for the `attachments` of
    /// the `ask` that follows (`send({ask:{imp,text,attachments:[id]}}, to)`). The bytes go out with the
    /// next `drain`. Nothing (null) when `to` is not connected or the file is empty or over 25 MiB.
    pub fn upload(
        &mut self,
        imp: &str,
        to: &str,
        name: &str,
        mime: &str,
        data: &[u8],
        now: f64,
    ) -> Result<Option<String>, JsError> {
        let (imp, to) = (uuid(imp)?, uuid(to)?);
        Ok(self
            .node
            .upload(imp, to, name, mime, data.to_vec(), now)
            .map(|id| id.to_string()))
    }

    /// Takes an Imp that was thrown here. False when it can't be taken any more.
    pub fn accept(&mut self, transfer: &str, now: f64) -> Result<bool, JsError> {
        Ok(self.node.accept(uuid(transfer)?, now))
    }

    pub fn decline(&mut self, transfer: &str, reason: &str) -> Result<(), JsError> {
        let reason: LinkDecline =
            serde_json::from_value(Value::String(reason.into())).unwrap_or(LinkDecline::Other);
        self.node.decline(uuid(transfer)?, reason);
        Ok(())
    }

    /// Throws a visiting Imp off a side of the page. JSON: `{ "transfer", "to" }`, or `{ "bounce" }` with
    /// why it can't go (`nobodyConnected`, `wayBackIsClosed`, `nowhereElse`).
    pub fn throw(
        &mut self,
        imp: &str,
        side: &str,
        height: f64,
        speed: f64,
        now: f64,
    ) -> Result<String, JsError> {
        let imp = uuid(imp)?;
        let side = side_named(side)?;
        let look = self
            .node
            .visits()
            .visit(imp)
            .map(|v| v.imp.clone())
            .ok_or_else(|| JsError::new("That Imp is not visiting this page."))?;
        let to = match self.node.door_of(imp, side, height) {
            Door::To(device) => device,
            Door::Bounce(why) => {
                let why = match why {
                    Bounce::NobodyConnected => "nobodyConnected",
                    Bounce::WayBackIsClosed => "wayBackIsClosed",
                    Bounce::NowhereElse => "nowhereElse",
                };
                return Ok(json!({ "bounce": why }).to_string());
            }
        };
        let entry = throw_entry(side, height, speed);
        let transfer = self.node.pass(&look, entry, to, now);
        Ok(match transfer {
            Some(transfer) => json!({ "transfer": transfer, "to": to }),
            None => json!({ "bounce": "nobodyConnected" }),
        }
        .to_string())
    }

    /// The doors on a side of the page, while a visiting Imp is carried near it (the Mac's door signs):
    /// JSON `{ "bands": [{ "id", "name", "kind", "top", "bottom", "back" }], "lit" }`. Each band is a device
    /// and the heights (0 top, 1 bottom) that lead to it, `back` the way the Imp came in, and `lit` the device
    /// a throw at `height` goes to (or null). No bands: that side leads nowhere.
    pub fn doors(&self, imp: &str, side: &str, height: f64) -> Result<String, JsError> {
        let imp = uuid(imp)?;
        let side = side_named(side)?;
        let visit = self.node.visits().visit(imp);
        let bands: Vec<Value> = self
            .node
            .bands_of(imp, side)
            .into_iter()
            .filter_map(|band| {
                let record = self.node.links().iter().find(|r| r.id() == band.device)?;
                let mut device = device_json(&record.device);
                device["top"] = json!(band.top);
                device["bottom"] = json!(band.bottom);
                device["back"] =
                    json!(visit.is_some_and(|v| v.side == side && v.from == band.device));
                Some(device)
            })
            .collect();
        let lit = match self.node.door_of(imp, side, height.clamp(0.0, 1.0)) {
            Door::To(device) => Some(device),
            Door::Bounce(_) => None,
        };
        Ok(json!({ "bands": bands, "lit": lit }).to_string())
    }

    /// Sends a visiting Imp home from here. False when it isn't visiting.
    pub fn send_home(&mut self, imp: &str, now: f64) -> Result<bool, JsError> {
        Ok(self.node.send_home(uuid(imp)?, now))
    }

    /// Which Imps are on this page: a JSON list of `{ imp, home: { id, name, kind } }` (the wire's `stage` entries).
    pub fn set_stage(&mut self, stage: &str) -> Result<(), JsError> {
        let stage: Vec<LinkStaged> =
            serde_json::from_str(stage).map_err(|e| JsError::new(&format!("Not a stage: {e}")))?;
        self.node.set_stage(stage);
        Ok(())
    }

    pub fn forget(&mut self, device: &str, now: f64) -> Result<(), JsError> {
        self.node.forget(uuid(device)?, now);
        Ok(())
    }

    /// What the page shows: `{ device, links: [{ id, name, kind, connected, viaHop, trusted }],
    /// visits: [{ imp, from, side, home: { id, name, kind } }] }`. No keys, doors or tickets.
    pub fn state(&self) -> String {
        let links: Vec<Value> = self
            .node
            .links()
            .iter()
            .map(|record| {
                let id = record.id();
                let mut device = device_json(&record.device);
                device["connected"] = json!(self.node.is_connected(id));
                device["viaHop"] = json!(self.node.is_through_hop(id));
                device["trusted"] = json!(record.trusted);
                device
            })
            .collect();
        let visits: Vec<Value> = self
            .node
            .visits()
            .visits()
            .iter()
            .map(|visit| {
                json!({
                    "imp": visit.imp,
                    "from": visit.from,
                    "side": visit.side,
                    "home": device_json(&visit.home.device),
                })
            })
            .collect();
        json!({ "device": device_json(&self.node.device()), "links": links, "visits": visits })
            .to_string()
    }
}
