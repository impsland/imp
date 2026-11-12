//! The Devices screen's picture of the system, built from what the link knows: the devices as nodes, the
//! channels between them (on the local network or through a server) with their state, and each Imp with
//! the tools it has and the Imps it can talk to. A plain value, so the view only draws it.

use crate::link::card::LinkKind;
use crate::link::hop::is_host;
use crate::link::messages::{LinkImp, LinkStaged};
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

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub id: String,
    pub kind: NodeKind,
    pub name: String,
    pub is_trusted: bool,
    /// For a server: connected when a channel runs through it right now.
    pub state: State,
    /// The Imps of this device that are on this node right now.
    pub imps: Vec<Uuid>,
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
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImpEntry {
    pub id: Uuid,
    pub name: String,
    pub hue: f64,
    /// The node it is on.
    pub location: String,
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
            })
            .chain(self.others.iter().filter(|c| c.location == id).cloned())
            .collect()
    }

    /// Builds the map. `server` is the address the person set (empty or wrong: none). `visitors` are the
    /// Imps of other devices visiting this device's desktop.
    pub fn build(
        this_device: &str,
        peers: &[MapPeer],
        server: &str,
        imps: &[MapImp],
        visitors: &[LinkStaged],
    ) -> Self {
        let server_name = server_host(server);
        let mut sorted: Vec<&MapPeer> = peers.iter().collect();
        sorted.sort_by(|a, b| natural(&a.name, &b.name));
        let here = |imp: &MapImp| -> String {
            imp.away_on
                .filter(|holder| peers.iter().any(|p| p.id == *holder))
                .map_or_else(
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
            is_trusted: false,
            state: State::Connected,
            imps: held(THIS_DEVICE),
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
            nodes.push(Node {
                imps: held(&id),
                id: id.clone(),
                kind: if peer.kind == LinkKind::Mac {
                    NodeKind::Mac
                } else {
                    NodeKind::Phone
                },
                name: peer.name.clone(),
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
            });
        }
        if let Some(name) = &server_name {
            nodes.insert(
                1,
                Node {
                    id: SERVER.into(),
                    kind: NodeKind::Server,
                    name: name.clone(),
                    is_trusted: false,
                    state: if relay_up {
                        State::Connected
                    } else {
                        State::Offline
                    },
                    imps: Vec::new(),
                },
            );
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
        let mut others = Vec::new();
        let mut location: BTreeMap<Uuid, String> = BTreeMap::new();
        for node in &nodes {
            for staged in screens.get(&node.id).into_iter().flatten() {
                if let std::collections::btree_map::Entry::Vacant(slot) =
                    location.entry(staged.imp.id)
                {
                    slot.insert(node.id.clone());
                    others.push(Contact {
                        id: staged.imp.id,
                        name: staged.imp.name.clone(),
                        hue: staged.imp.hue,
                        location: node.id.clone(),
                    });
                }
            }
        }
        for imp in imps {
            location.insert(imp.id, here(imp));
        }

        // Who each can message, by the link's own rule: the Imps of its home, and the Imps on the screen
        // its body is on.
        let home: Vec<LinkStaged> = imps
            .iter()
            .map(|i| LinkStaged {
                imp: LinkImp {
                    id: i.id,
                    name: i.name.clone(),
                    hue: i.hue,
                    scale: 1.0,
                    traits: Default::default(),
                },
                home: Uuid::nil(),
            })
            .collect();
        let entries = imps
            .iter()
            .map(|imp| {
                let reachable = if imp.can_talk {
                    talks::targets(
                        imp.id,
                        &home,
                        screens.get(&here(imp)).map_or(&[], Vec::as_slice),
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
                        .map(|t| Contact {
                            id: t.imp.id,
                            name: t.imp.name.clone(),
                            hue: t.imp.hue,
                            location: location
                                .get(&t.imp.id)
                                .cloned()
                                .unwrap_or_else(|| THIS_DEVICE.into()),
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
        let map = DeviceMap::build("Mac", &[], "", &[imp(1, "Pip")], &[]);
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
            &[phone(), mac()],
            "imp.example.org",
            &[imp(1, "Pip")],
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
        let without = DeviceMap::build("Mac", std::slice::from_ref(&gone), "", &[], &[]);
        assert_eq!(
            (without.channels[0].path, without.channels[0].state),
            (Path::Local, State::Offline)
        );
        let with = DeviceMap::build("Mac", &[gone], "imp.example.org", &[], &[]);
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
            &[MapPeer {
                reach: Reach::Connecting,
                ..phone()
            }],
            "",
            &[],
            &[],
        );
        assert_eq!(map.channels[0].state, State::Connecting);
    }

    #[test]
    fn a_bad_server_is_no_server() {
        for bad in ["not a host!", "", "  ", "UPPER:notaport", "-bad.example"] {
            assert!(
                DeviceMap::build("Mac", &[mac()], bad, &[], &[])
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
        let map = DeviceMap::build("Mac", &[phone()], "", &[imp(1, "Home"), away, stale], &[]);
        assert_eq!(map.node(&key(100)).unwrap().imps, vec![id(2)]);
        assert_eq!(map.node(THIS_DEVICE).unwrap().imps.len(), 2);
    }

    #[test]
    fn peers_are_listed_in_natural_name_order() {
        let peers = [
            peer(1, "iPhone 10", LinkKind::Phone, Reach::Direct),
            peer(2, "iPhone 9", LinkKind::Phone, Reach::Direct),
            peer(3, "airplane", LinkKind::Phone, Reach::Direct),
        ];
        let map = DeviceMap::build("Mac", &peers, "", &[], &[]);
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
        LinkStaged { imp, home }
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
        let map = DeviceMap::build("Mac", &[on_phone], "", &[dot, bumble], &[]);
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
        let map = DeviceMap::build("Mac", &[phone()], "", &[imp(2, "Bumble")], &visitors);
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
            id: "own.body".into(),
            title: "Body".into(),
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
        let map = DeviceMap::build("Mac", &[], "", &[a, b], &[]);
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
        let map = DeviceMap::build("Mac", &[], "", &[imp(1, "Dot")], &visitors);
        assert!(map.others.is_empty());
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
