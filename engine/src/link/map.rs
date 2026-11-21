//! The Devices screen's picture of the system, built from what the link knows: the devices as nodes, the
//! channels between them (on the local network or through a server) with their state, and each Imp with
//! the tools it has and the Imps it can talk to. A plain value, so the view only draws it.

use crate::link::card::LinkKind;
use crate::link::hop::is_host;
use crate::link::messages::LinkStaged;
use crate::link::talks;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

/// The id of the node for this device.
pub const THIS_DEVICE: &str = "this-mac";
/// The id of the server node.
pub const SERVER: &str = "server";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NodeKind {
    ThisDevice,
    Mac,
    Phone,
    Server,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Path {
    Local,
    Relay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Connected,
    Connecting,
    Offline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reach {
    Direct,
    ViaServer,
    Connecting,
    Away,
}

/// What the link says about a linked device.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MapPeer {
    pub id: Uuid,
    pub name: String,
    pub kind: LinkKind,
    pub reach: Reach,
    pub is_trusted: bool,
    /// The Imps on its screen right now, as it last said: its own and its visitors. Empty while it is
    /// not connected.
    pub stage: Vec<LinkStaged>,
    /// Where the link book last knew it on the local network.
    #[serde(default)]
    pub routes: Option<MapRoutes>,
}

/// The local network routes of a device: the host names or addresses it answers on, and its port.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MapRoutes {
    pub hosts: Vec<String>,
    pub port: u16,
}

impl MapRoutes {
    /// Every route as `host:port` (an IPv6 address in brackets), in the order the link tries them.
    fn addresses(&self) -> Vec<String> {
        self.hosts
            .iter()
            .map(|host| {
                if host.contains(':') {
                    format!("[{host}]:{}", self.port)
                } else {
                    format!("{host}:{}", self.port)
                }
            })
            .collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToolSource {
    Own,
    Mcp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MapTool {
    pub id: String,
    pub title: String,
    pub symbol: String,
    pub source: ToolSource,
}

/// One of this device's Imps, with the tools its settings give it (the app lists them from the tool
/// registry).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MapImp {
    pub id: Uuid,
    pub name: String,
    pub hue: f64,
    /// The device holding it, when it is away.
    pub away_on: Option<Uuid>,
    /// Whether it has the tools to message other Imps.
    pub can_talk: bool,
    pub tools: Vec<MapTool>,
}

/// A device this one is not linked with but knows of through a third party: the home of a visiting Imp
/// (its card came along) or the device a holder passed an Imp on to. `via` is the linked device that
/// relays it, when there is one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MapKnown {
    pub id: Uuid,
    /// Empty when only its id is known.
    pub name: String,
    pub kind: LinkKind,
    #[serde(default)]
    pub via: Option<Uuid>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub id: String,
    pub kind: NodeKind,
    /// Empty for a device only known by its id.
    pub name: String,
    /// False for a device known only through a third party: not linked with this one.
    pub linked: bool,
    /// For a device that is not linked: the node of the linked device that relays it.
    pub via: Option<String>,
    pub is_trusted: bool,
    /// For a server: connected when a channel runs through it right now.
    pub state: State,
    /// The Imps of this device that are on this node right now.
    pub imps: Vec<Uuid>,
    /// How the node is reached, as `host:port`: this device's own routes, a linked device's last known
    /// local routes, or the server's address as the person set it.
    pub addresses: Vec<String>,
}

/// An Imp an Imp can message: one of this device's, or another device's Imp on the same screen.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Contact {
    pub id: Uuid,
    pub name: String,
    pub hue: f64,
    /// The node its body is on.
    pub location: String,
    /// The node of the device it thinks on: `this-mac` for this device's own Imps, a linked device's
    /// node for the Imps hatched there, and the node of a device only known through a third party.
    pub home: Option<String>,
}

/// A way two devices talk. A relay channel passes through the server node `via`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Channel {
    pub id: String,
    pub from: String,
    pub to: String,
    pub path: Path,
    pub state: State,
    pub via: Option<String>,
    /// The server's name when the channel goes through one.
    pub server: Option<String>,
    /// The address it goes through: the server's `host:port` for a relay channel, the linked device's
    /// first known local route otherwise (none when the book has none).
    pub address: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImpEntry {
    pub id: Uuid,
    pub name: String,
    pub hue: f64,
    /// The node it is on.
    pub location: String,
    // Its home is always this device (`THIS_DEVICE`), so the entry doesn't repeat it.
    pub tools: Vec<MapTool>,
    /// The other Imps it can message: this device's own, wherever they are, and every Imp on the screen
    /// its body is on.
    pub talks_to: Vec<Contact>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceMap {
    pub nodes: Vec<Node>,
    pub channels: Vec<Channel>,
    pub imps: Vec<ImpEntry>,
    /// Other devices' Imps on the screens this device knows: on a connected device, or visiting here.
    pub others: Vec<Contact>,
}

/// The host of a server address the person set (`host` or `host:port`), or none if it is empty or wrong.
pub fn server_host(server: &str) -> Option<String> {
    let text = server.trim().to_lowercase();
    let host = match text.rsplit_once(':') {
        Some((host, port)) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => host,
        _ => &text,
    };
    is_host(host).then(|| host.to_string())
}

/// Orders names the way people read them: ignoring case, with runs of digits by value.
fn natural(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(p), Some(q)) if p.is_ascii_digit() && q.is_ascii_digit() => {
                let number = |it: &mut std::iter::Peekable<std::str::Chars<'_>>| {
                    let mut digits = String::new();
                    while let Some(d) = it.next_if(char::is_ascii_digit) {
                        digits.push(d);
                    }
                    digits.trim_start_matches('0').to_string()
                };
                let (m, n) = (number(&mut x), number(&mut y));
                let order = m.len().cmp(&n.len()).then_with(|| m.cmp(&n));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(p), Some(q)) => {
                let order = p.to_lowercase().cmp(q.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                x.next();
                y.next();
            }
        }
    }
}

impl DeviceMap {
    pub fn node(&self, id: &str) -> Option<&Node> {
        self.nodes.iter().find(|n| n.id == id)
    }

    pub fn imp(&self, id: Uuid) -> Option<&ImpEntry> {
        self.imps.iter().find(|i| i.id == id)
    }

    /// Every Imp whose body is on node `id`: this device's and other devices'.
    pub fn residents(&self, id: &str) -> Vec<Contact> {
        self.imps
            .iter()
            .filter(|i| i.location == id)
            .map(|i| Contact {
                id: i.id,
                name: i.name.clone(),
                hue: i.hue,
                location: id.to_string(),
                home: Some(THIS_DEVICE.into()),
            })
            .chain(self.others.iter().filter(|c| c.location == id).cloned())
            .collect()
    }

    /// Builds the map. `server` is the address the person set (empty or wrong: none). `visitors` are the
    /// Imps of other devices visiting this device's desktop. `this_routes` are the ones this device
    /// answers on.
    pub fn build(
        this_device: &str,
        this_routes: Option<&MapRoutes>,
        peers: &[MapPeer],
        server: &str,
        imps: &[MapImp],
        visitors: &[LinkStaged],
        known: &[MapKnown],
    ) -> Self {
        let server_name = server_host(server);
        let server_address = server_name.as_ref().map(|_| server.trim().to_lowercase());
        let mut sorted: Vec<&MapPeer> = peers.iter().collect();
        sorted.sort_by(|a, b| natural(&a.name, &b.name));
        // Devices known only through a third party: told so by the link (the homes of visitors, the
        // devices holders passed Imps on to), by the homes a screen names, and by id for a holder nothing
        // else describes. Never a linked device, and never this one.
        let is_peer = |id: Uuid| peers.iter().any(|p| p.id == id);
        let mut strangers: BTreeMap<Uuid, MapKnown> = BTreeMap::new();
        for k in known.iter().filter(|k| !is_peer(k.id)) {
            strangers
                .entry(k.id)
                .and_modify(|old| {
                    if old.name.is_empty() {
                        *old = k.clone();
                    }
                })
                .or_insert_with(|| k.clone());
        }
        let on_screens = visitors.iter().map(|s| (s, None)).chain(
            sorted
                .iter()
                .flat_map(|p| p.stage.iter().map(move |s| (s, Some(p.id)))),
        );
        for (staged, via) in on_screens {
            if !is_peer(staged.home.id) && !imps.iter().any(|i| i.id == staged.imp.id) {
                strangers.entry(staged.home.id).or_insert_with(|| MapKnown {
                    id: staged.home.id,
                    name: staged.home.name.clone(),
                    kind: staged.home.kind,
                    via,
                });
            }
        }
        for holder in imps.iter().filter_map(|i| i.away_on) {
            if !is_peer(holder) {
                strangers.entry(holder).or_insert_with(|| MapKnown {
                    id: holder,
                    name: String::new(),
                    kind: LinkKind::Phone,
                    via: None,
                });
            }
        }
        // Where an Imp is: on its holder when it is away (a linked device, or one only known through
        // another), here otherwise. An away Imp is never shown on this device.
        let here = |imp: &MapImp| -> String {
            imp.away_on.map_or_else(
                || THIS_DEVICE.to_string(),
                |holder| holder.to_string().to_uppercase(),
            )
        };
        let held = |id: &str| -> Vec<Uuid> {
            imps.iter()
                .filter(|i| here(i) == id)
                .map(|i| i.id)
                .collect()
        };

        let mut nodes = vec![Node {
            id: THIS_DEVICE.into(),
            kind: NodeKind::ThisDevice,
            name: this_device.into(),
            linked: true,
            via: None,
            is_trusted: false,
            state: State::Connected,
            imps: held(THIS_DEVICE),
            addresses: this_routes.map(MapRoutes::addresses).unwrap_or_default(),
        }];
        let mut channels = Vec::new();
        let mut relay_up = false;
        for peer in &sorted {
            let id = peer.id.to_string().to_uppercase();
            let state = match peer.reach {
                Reach::Direct | Reach::ViaServer => State::Connected,
                Reach::Connecting => State::Connecting,
                Reach::Away => State::Offline,
            };
            // A device that is away is shown on the path it would come back on.
            let relay = peer.reach == Reach::ViaServer
                || (peer.reach != Reach::Direct && server_name.is_some());
            relay_up |= peer.reach == Reach::ViaServer;
            let addresses = peer
                .routes
                .as_ref()
                .map(MapRoutes::addresses)
                .unwrap_or_default();
            let address = if relay {
                server_address.clone()
            } else {
                addresses.first().cloned()
            };
            nodes.push(Node {
                imps: held(&id),
                addresses,
                id: id.clone(),
                kind: if peer.kind == LinkKind::Mac {
                    NodeKind::Mac
                } else {
                    NodeKind::Phone
                },
                name: peer.name.clone(),
                linked: true,
                via: None,
                is_trusted: peer.is_trusted,
                state,
            });
            channels.push(Channel {
                id: id.clone(),
                from: THIS_DEVICE.into(),
                to: id,
                path: if relay { Path::Relay } else { Path::Local },
                state,
                via: relay.then(|| SERVER.to_string()),
                server: if relay { server_name.clone() } else { None },
                address,
            });
        }
        if let Some(name) = &server_name {
            nodes.insert(
                1,
                Node {
                    id: SERVER.into(),
                    kind: NodeKind::Server,
                    name: name.clone(),
                    linked: true,
                    via: None,
                    is_trusted: false,
                    state: if relay_up {
                        State::Connected
                    } else {
                        State::Offline
                    },
                    imps: Vec::new(),
                    addresses: server_address.into_iter().collect(),
                },
            );
        }

        let mut others_known: Vec<&MapKnown> = strangers.values().collect();
        others_known.sort_by(|a, b| natural(&a.name, &b.name).then(a.id.cmp(&b.id)));
        for k in others_known {
            let id = k.id.to_string().to_uppercase();
            nodes.push(Node {
                imps: held(&id),
                id,
                kind: if k.kind == LinkKind::Mac {
                    NodeKind::Mac
                } else {
                    NodeKind::Phone
                },
                name: k.name.clone(),
                linked: false,
                via: k
                    .via
                    .filter(|v| is_peer(*v))
                    .map(|v| v.to_string().to_uppercase()),
                is_trusted: false,
                state: State::Offline,
                addresses: Vec::new(),
            });
        }

        // Other devices' Imps on each screen: on a connected device (its own and its visitors), and the
        // visitors on this device's desktop. This device's own Imps are listed once, where they are.
        let mine: BTreeSet<Uuid> = imps.iter().map(|i| i.id).collect();
        let mut screens: BTreeMap<String, Vec<LinkStaged>> = BTreeMap::new();
        screens.insert(
            THIS_DEVICE.into(),
            visitors
                .iter()
                .filter(|v| !mine.contains(&v.imp.id))
                .cloned()
                .collect(),
        );
        for peer in sorted.iter().filter(|p| p.reach != Reach::Away) {
            screens.insert(
                peer.id.to_string().to_uppercase(),
                peer.stage
                    .iter()
                    .filter(|s| !mine.contains(&s.imp.id))
                    .cloned()
                    .collect(),
            );
        }
        // The node of each linked device by its id: where an Imp's home is, when it is one of those.
        let node_of = |device: Uuid| -> Option<String> {
            (is_peer(device) || strangers.contains_key(&device))
                .then(|| device.to_string().to_uppercase())
        };
        let mut others = Vec::new();
        let mut homes: BTreeMap<Uuid, Option<String>> = BTreeMap::new();
        let mut location: BTreeMap<Uuid, String> = BTreeMap::new();
        for node in &nodes {
            for staged in screens.get(&node.id).into_iter().flatten() {
                if let std::collections::btree_map::Entry::Vacant(slot) =
                    location.entry(staged.imp.id)
                {
                    slot.insert(node.id.clone());
                    homes.insert(staged.imp.id, node_of(staged.home.id));
                    others.push(Contact {
                        id: staged.imp.id,
                        name: staged.imp.name.clone(),
                        hue: staged.imp.hue,
                        location: node.id.clone(),
                        home: node_of(staged.home.id),
                    });
                }
            }
        }
        for imp in imps {
            location.insert(imp.id, here(imp));
            homes.insert(imp.id, Some(THIS_DEVICE.into()));
        }

        // Who each can message, by the link's own rule: the Imps of its home, and the Imps on the screen
        // its body is on.
        let entries = imps
            .iter()
            .map(|imp| {
                let screen = screens.get(&here(imp)).map_or(&[][..], Vec::as_slice);
                let reachable = if imp.can_talk {
                    talks::reachable(
                        imp.id,
                        imps.iter().map(|i| i.id),
                        screen.iter().map(|s| s.imp.id),
                    )
                } else {
                    Vec::new()
                };
                ImpEntry {
                    id: imp.id,
                    name: imp.name.clone(),
                    hue: imp.hue,
                    location: here(imp),
                    tools: imp.tools.clone(),
                    talks_to: reachable
                        .iter()
                        .filter_map(|id| {
                            let (name, hue) = imps
                                .iter()
                                .find(|i| i.id == *id)
                                .map(|i| (&i.name, i.hue))
                                .or_else(|| {
                                    screen
                                        .iter()
                                        .find(|s| s.imp.id == *id)
                                        .map(|s| (&s.imp.name, s.imp.hue))
                                })?;
                            Some(Contact {
                                id: *id,
                                name: name.clone(),
                                hue,
                                location: location
                                    .get(id)
                                    .cloned()
                                    .unwrap_or_else(|| THIS_DEVICE.into()),
                                home: homes.get(id).cloned().flatten(),
                            })
                        })
                        .collect(),
                }
            })
            .collect();
        Self {
            nodes,
            channels,
            imps: entries,
            others,
        }
    }
}

/// The parts of the line from `a` to `b` that lie outside every box (`(x, y, width, height)`).
pub fn pieces(
    a: (f64, f64),
    b: (f64, f64),
    boxes: &[(f64, f64, f64, f64)],
) -> Vec<((f64, f64), (f64, f64))> {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    // Where along the line (0 at a, 1 at b) it is inside each box (Liang-Barsky).
    let mut covered: Vec<(f64, f64)> = Vec::new();
    for &(x, y, w, h) in boxes {
        let (mut low, mut high) = (0.0f64, 1.0f64);
        let mut inside = true;
        for (p, q) in [
            (-dx, a.0 - x),
            (dx, x + w - a.0),
            (-dy, a.1 - y),
            (dy, y + h - a.1),
        ] {
            if p == 0.0 {
                if q < 0.0 {
                    inside = false;
                    break;
                }
            } else {
                let t = q / p;
                if p < 0.0 {
                    low = low.max(t);
                } else {
                    high = high.min(t);
                }
            }
        }
        if inside && low < high {
            covered.push((low, high));
        }
    }
    covered.sort_by(|p, q| p.0.total_cmp(&q.0));
    let point = |t: f64| (a.0 + dx * t, a.1 + dy * t);
    let mut result = Vec::new();
    let mut from = 0.0f64;
    for (low, high) in covered {
        if low > from {
            result.push((point(from), point(low)));
        }
        from = from.max(high);
    }
    if from < 1.0 {
        result.push((point(from), point(1.0)));
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::link::messages::LinkWho;
    use crate::link::visits::tests::imp as link_imp;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn peer(n: u128, name: &str, kind: LinkKind, reach: Reach) -> MapPeer {
        MapPeer {
            id: id(n),
            name: name.into(),
            kind,
            reach,
            is_trusted: false,
            stage: Vec::new(),
            routes: None,
        }
    }

    fn imp(n: u128, name: &str) -> MapImp {
        MapImp {
            id: id(n),
            name: name.into(),
            hue: 0.2,
            away_on: None,
            can_talk: true,
            tools: Vec::new(),
        }
    }

    fn phone() -> MapPeer {
        peer(100, "Anna's iPhone", LinkKind::Phone, Reach::Direct)
    }

    fn mac() -> MapPeer {
        MapPeer {
            is_trusted: true,
            ..peer(101, "Studio", LinkKind::Mac, Reach::ViaServer)
        }
    }

    fn key(n: u128) -> String {
        id(n).to_string().to_uppercase()
    }

    #[test]
    fn alone_is_one_node() {
        let map = DeviceMap::build("Mac", None, &[], "", &[imp(1, "Pip")], &[], &[]);
        assert_eq!(
            map.nodes.iter().map(|n| n.kind).collect::<Vec<_>>(),
            vec![NodeKind::ThisDevice]
        );
        assert!(map.channels.is_empty());
        assert_eq!(map.nodes[0].imps.len(), 1);
    }

    #[test]
    fn channels_keep_path_state_and_server() {
        let map = DeviceMap::build(
            "Mac",
            None,
            &[phone(), mac()],
            "imp.example.org",
            &[imp(1, "Pip")],
            &[],
            &[],
        );
        assert_eq!(
            map.nodes.iter().map(|n| n.kind).collect::<Vec<_>>(),
            vec![
                NodeKind::ThisDevice,
                NodeKind::Server,
                NodeKind::Phone,
                NodeKind::Mac
            ]
        );
        let local = map.channels.iter().find(|c| c.to == key(100)).unwrap();
        assert_eq!(
            (
                local.path,
                local.state,
                local.via.clone(),
                local.server.clone()
            ),
            (Path::Local, State::Connected, None, None)
        );
        let relay = map.channels.iter().find(|c| c.to == key(101)).unwrap();
        assert_eq!((relay.path, relay.state), (Path::Relay, State::Connected));
        assert_eq!(
            (relay.via.as_deref(), relay.server.as_deref()),
            (Some(SERVER), Some("imp.example.org"))
        );
        assert_eq!(map.node(SERVER).unwrap().state, State::Connected);
        assert!(map.node(&key(101)).unwrap().is_trusted);
    }

    #[test]
    fn away_devices_show_their_path_offline() {
        let gone = MapPeer {
            reach: Reach::Away,
            ..phone()
        };
        let without = DeviceMap::build("Mac", None, std::slice::from_ref(&gone), "", &[], &[], &[]);
        assert_eq!(
            (without.channels[0].path, without.channels[0].state),
            (Path::Local, State::Offline)
        );
        let with = DeviceMap::build("Mac", None, &[gone], "imp.example.org", &[], &[], &[]);
        assert_eq!(
            (with.channels[0].path, with.channels[0].state),
            (Path::Relay, State::Offline)
        );
        assert_eq!(with.node(SERVER).unwrap().state, State::Offline);
    }

    #[test]
    fn connecting_is_its_own_state() {
        let map = DeviceMap::build(
            "Mac",
            None,
            &[MapPeer {
                reach: Reach::Connecting,
                ..phone()
            }],
            "",
            &[],
            &[],
            &[],
        );
        assert_eq!(map.channels[0].state, State::Connecting);
    }

    #[test]
    fn a_bad_server_is_no_server() {
        for bad in ["not a host!", "", "  ", "UPPER:notaport", "-bad.example"] {
            assert!(
                DeviceMap::build("Mac", None, &[mac()], bad, &[], &[], &[])
                    .node(SERVER)
                    .is_none(),
                "{bad}"
            );
        }
        assert_eq!(
            server_host(" Imp.Example.org:8443 ").as_deref(),
            Some("imp.example.org")
        );
    }

    #[test]
    fn imps_are_where_they_are() {
        let away = MapImp {
            away_on: Some(id(100)),
            ..imp(2, "Away")
        };
        let stale = MapImp {
            away_on: Some(id(999)),
            ..imp(3, "Stale")
        };
        let map = DeviceMap::build(
            "Mac",
            None,
            &[phone()],
            "",
            &[imp(1, "Home"), away, stale],
            &[],
            &[],
        );
        assert_eq!(map.node(&key(100)).unwrap().imps, vec![id(2)]);
        // An Imp held by a device nothing describes is on that device, known only by its id: never here.
        assert_eq!(map.node(THIS_DEVICE).unwrap().imps, vec![id(1)]);
        let unknown = map.node(&key(999)).unwrap();
        assert_eq!(
            (unknown.imps.clone(), unknown.linked, unknown.name.as_str()),
            (vec![id(3)], false, "")
        );
    }

    #[test]
    fn peers_are_listed_in_natural_name_order() {
        let peers = [
            peer(1, "iPhone 10", LinkKind::Phone, Reach::Direct),
            peer(2, "iPhone 9", LinkKind::Phone, Reach::Direct),
            peer(3, "airplane", LinkKind::Phone, Reach::Direct),
        ];
        let map = DeviceMap::build("Mac", None, &peers, "", &[], &[], &[]);
        assert_eq!(
            map.nodes
                .iter()
                .skip(1)
                .map(|n| n.name.as_str())
                .collect::<Vec<_>>(),
            vec!["airplane", "iPhone 9", "iPhone 10"]
        );
    }

    fn staged(n: u128, name: &str, home: Uuid) -> LinkStaged {
        let mut imp = link_imp(n);
        imp.name = name.into();
        LinkStaged {
            imp,
            home: LinkWho {
                id: home,
                name: format!("Home {}", home.as_u128()),
                kind: LinkKind::Mac,
            },
        }
    }

    #[test]
    fn an_imp_away_talks_to_the_imps_on_the_screen_it_is_on() {
        let dot = MapImp {
            away_on: Some(id(100)),
            ..imp(1, "Dot")
        };
        let bumble = imp(2, "Bumble");
        let mut on_phone = phone();
        on_phone.stage = vec![
            staged(10, "Cinder", id(100)),
            staged(11, "Noodle", id(100)),
            staged(1, "Dot", id(777)),
        ];
        let map = DeviceMap::build("Mac", None, &[on_phone], "", &[dot, bumble], &[], &[]);
        let names = |i: Uuid| {
            map.imp(i)
                .unwrap()
                .talks_to
                .iter()
                .map(|c| c.name.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(names(id(1)), vec!["Bumble", "Cinder", "Noodle"]);
        assert_eq!(
            map.imp(id(1)).unwrap().talks_to.last().unwrap().location,
            key(100)
        );
        assert_eq!(names(id(2)), vec!["Dot"]);
        let residents: Vec<String> = map
            .residents(&key(100))
            .into_iter()
            .map(|c| c.name)
            .collect();
        assert_eq!(residents, vec!["Dot", "Cinder", "Noodle"]);
    }

    #[test]
    fn an_imp_at_home_talks_to_the_visitors_here() {
        let visitors = [staged(10, "Cinder", id(100))];
        let map = DeviceMap::build(
            "Mac",
            None,
            &[phone()],
            "",
            &[imp(2, "Bumble")],
            &visitors,
            &[],
        );
        assert_eq!(map.imp(id(2)).unwrap().talks_to[0].name, "Cinder");
        let residents: Vec<String> = map
            .residents(THIS_DEVICE)
            .into_iter()
            .map(|c| c.name)
            .collect();
        assert_eq!(residents, vec!["Bumble", "Cinder"]);
    }

    #[test]
    fn an_imp_without_the_talk_tool_talks_to_nobody_and_tools_pass_through() {
        let tool = MapTool {
            id: "own.personality".into(),
            title: "Personality".into(),
            symbol: "figure".into(),
            source: ToolSource::Own,
        };
        let a = MapImp {
            tools: vec![tool.clone()],
            ..imp(1, "A")
        };
        let b = MapImp {
            can_talk: false,
            ..imp(2, "B")
        };
        let map = DeviceMap::build("Mac", None, &[], "", &[a, b], &[], &[]);
        assert_eq!(map.imp(id(1)).unwrap().tools, vec![tool]);
        assert_eq!(
            map.imp(id(1))
                .unwrap()
                .talks_to
                .iter()
                .map(|c| c.id)
                .collect::<Vec<_>>(),
            vec![id(2)]
        );
        assert!(map.imp(id(2)).unwrap().talks_to.is_empty());
    }

    #[test]
    fn a_visitor_that_is_also_ours_is_listed_once_where_it_is() {
        let visitors = [staged(1, "Dot", id(100))];
        let map = DeviceMap::build("Mac", None, &[], "", &[imp(1, "Dot")], &visitors, &[]);
        assert!(map.others.is_empty());
    }

    fn routes(hosts: &[&str], port: u16) -> MapRoutes {
        MapRoutes {
            hosts: hosts.iter().map(|h| h.to_string()).collect(),
            port,
        }
    }

    #[test]
    fn channels_say_the_address_they_go_through() {
        let local = MapPeer {
            routes: Some(routes(&["studio.local", "fe80::1"], 47824)),
            ..phone()
        };
        let map = DeviceMap::build(
            "Mac",
            Some(&routes(&["10.0.0.2"], 47825)),
            &[local, mac()],
            " IMP.example.org:4000 ",
            &[],
            &[],
            &[],
        );
        let to = |n: u128| map.channels.iter().find(|c| c.to == key(n)).unwrap();
        assert_eq!(to(100).address.as_deref(), Some("studio.local:47824"));
        assert_eq!(to(101).address.as_deref(), Some("imp.example.org:4000"));
        assert_eq!(map.node(THIS_DEVICE).unwrap().addresses, ["10.0.0.2:47825"]);
        assert_eq!(
            map.node(&key(100)).unwrap().addresses,
            ["studio.local:47824", "[fe80::1]:47824"]
        );
        assert_eq!(
            map.node(SERVER).unwrap().addresses,
            ["imp.example.org:4000"]
        );
        // A linked device with no known route has no address, and a bare Hop host is shown as set.
        let none = DeviceMap::build("Mac", None, &[phone()], "", &[], &[], &[]);
        assert_eq!(none.channels[0].address, None);
        assert!(none.node(THIS_DEVICE).unwrap().addresses.is_empty());
    }

    #[test]
    fn imps_know_their_home_node() {
        let visitors = [
            staged(10, "Cinder", id(100)),
            staged(12, "Stranger", id(999)),
        ];
        let mut on_mac = mac();
        on_mac.stage = vec![staged(11, "Noodle", id(100))];
        let map = DeviceMap::build(
            "Mac",
            None,
            &[phone(), on_mac],
            "",
            &[imp(1, "Pip")],
            &visitors,
            &[],
        );
        let home = |n: u128| {
            map.others
                .iter()
                .find(|c| c.id == id(n))
                .unwrap()
                .home
                .clone()
        };
        assert_eq!(home(10), Some(key(100)));
        assert_eq!(home(11), Some(key(100)));
        // A home this device is not linked with is a node of its own, named by the stage.
        assert_eq!(home(12), Some(key(999)));
        let residents = map.residents(THIS_DEVICE);
        assert_eq!(residents[0].home.as_deref(), Some(THIS_DEVICE));
        // Contacts an Imp can message carry the home too.
        let talks = &map.imp(id(1)).unwrap().talks_to;
        let cinder = talks.iter().find(|c| c.id == id(10)).unwrap();
        assert_eq!(cinder.home, Some(key(100)));
        let stranger = talks.iter().find(|c| c.id == id(12)).unwrap();
        assert_eq!(stranger.home, Some(key(999)));
    }

    #[test]
    fn a_home_known_only_from_a_visitor_keeps_its_name_and_kind() {
        let mut visitor = staged(10, "Cinder", id(555));
        visitor.home.name = "Anna's iPhone".into();
        visitor.home.kind = LinkKind::Phone;
        let relayed = MapKnown {
            id: id(555),
            name: "Anna's iPhone".into(),
            kind: LinkKind::Phone,
            via: Some(id(101)),
        };
        let map = DeviceMap::build(
            "Mac",
            None,
            &[mac()],
            "",
            &[],
            &[visitor.clone()],
            &[relayed],
        );
        let home = map.node(&key(555)).unwrap();
        assert_eq!(
            (home.name.as_str(), home.kind, home.linked, home.via.clone()),
            ("Anna's iPhone", NodeKind::Phone, false, Some(key(101)))
        );
        assert_eq!(map.others[0].home, Some(key(555)));
        // Without a `known` entry the stage's own words are enough.
        let named = DeviceMap::build("Mac", None, &[], "", &[], &[visitor.clone()], &[]);
        assert_eq!(named.node(&key(555)).unwrap().name, "Anna's iPhone");
    }

    #[test]
    fn an_imp_passed_on_is_drawn_on_the_device_that_holds_it() {
        let away = MapImp {
            away_on: Some(id(555)),
            ..imp(1, "Dot")
        };
        let held = MapKnown {
            id: id(555),
            name: "Anna's iPhone".into(),
            kind: LinkKind::Phone,
            via: Some(id(101)),
        };
        let map = DeviceMap::build("Mac", None, &[mac()], "", &[away], &[], &[held]);
        assert_eq!(map.imp(id(1)).unwrap().location, key(555));
        assert!(map.node(THIS_DEVICE).unwrap().imps.is_empty());
        assert_eq!(map.node(&key(555)).unwrap().imps, vec![id(1)]);
        assert_eq!(map.node(&key(555)).unwrap().via, Some(key(101)));
    }

    #[test]
    fn lines_stop_at_tiles_and_labels() {
        let boxes = [
            (0.0, 0.0, 10.0, 10.0),
            (45.0, 0.0, 10.0, 10.0),
            (90.0, 0.0, 10.0, 10.0),
        ];
        let found = pieces((5.0, 5.0), (95.0, 5.0), &boxes);
        let xs: Vec<[f64; 2]> = found.iter().map(|p| [p.0.0, p.1.0]).collect();
        assert_eq!(xs, vec![[10.0, 45.0], [55.0, 90.0]]);
        assert_eq!(
            pieces((0.0, 0.0), (100.0, 0.0), &[(40.0, 50.0, 10.0, 10.0)]).len(),
            1
        );
        let overlapping = [(20.0, -5.0, 20.0, 10.0), (30.0, -5.0, 20.0, 10.0)];
        let xs: Vec<[f64; 2]> = pieces((0.0, 0.0), (100.0, 0.0), &overlapping)
            .iter()
            .map(|p| [p.0.0, p.1.0])
            .collect();
        assert_eq!(xs, vec![[0.0, 20.0], [50.0, 100.0]]);
    }
}
