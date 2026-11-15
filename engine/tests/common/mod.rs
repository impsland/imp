//! A small network for the link tests: nodes joined by in-memory connections. It does what an adapter does.
#![allow(dead_code)]

use imp_engine::link::card::LinkKind;
use imp_engine::link::node::{ConnId, Event, Node, Options, Output};
use imp_engine::link::{LinkImp, LinkMessage, LinkStaged};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

pub fn id(n: u128) -> Uuid {
    Uuid::from_u128(n)
}

pub struct Net {
    pub nodes: Vec<Node>,
    pub now: f64,
    pub events: Vec<Vec<Event>>,
    /// (node, conn) -> (node, conn)
    pub wires: BTreeMap<(usize, ConnId), (usize, ConnId)>,
    /// Devices that cannot be dialled.
    pub unreachable: BTreeSet<Uuid>,
    /// Bytes that crossed, for checking nothing is in the clear.
    pub traffic: Vec<u8>,
    pub saved: Vec<Option<Vec<u8>>>,
    /// Dialled connections that have not become a link yet: (node, conn) -> the device dialled.
    trying: BTreeMap<(usize, ConnId), Uuid>,
}

pub fn imp(n: u128, name: &str) -> LinkImp {
    LinkImp {
        id: id(n),
        name: name.into(),
        hue: 0.3,
        scale: 1.0,
        traits: Default::default(),
    }
}

pub fn staged(n: u128, name: &str, home: Uuid) -> LinkStaged {
    LinkStaged {
        imp: imp(n, name),
        home,
    }
}

impl Net {
    /// Devices 1, 2, ... named after their number, all running.
    pub fn new(count: u128) -> Self {
        Self::with(count, Options::default())
    }

    pub fn with(count: u128, options: Options) -> Self {
        let mut net = Self {
            nodes: Vec::new(),
            now: 1_000.0,
            events: Vec::new(),
            wires: BTreeMap::new(),
            unreachable: BTreeSet::new(),
            traffic: Vec::new(),
            saved: Vec::new(),
            trying: BTreeMap::new(),
        };
        for n in 1..=count {
            let kind = if n % 2 == 1 {
                LinkKind::Mac
            } else {
                LinkKind::Phone
            };
            let node =
                Node::new(None, &format!("Device {n}"), kind, id(n), options.clone()).unwrap();
            net.nodes.push(node);
            net.events.push(Vec::new());
            net.saved.push(None);
        }
        for i in 0..net.nodes.len() {
            net.nodes[i].set_port(Some(imp_engine::link::PORT));
            net.nodes[i].start(net.now);
        }
        net.pump();
        net
    }

    pub fn index(&self, device: Uuid) -> Option<usize> {
        self.nodes.iter().position(|n| n.device().id == device)
    }

    /// Carries every output out until nothing is left to do.
    pub fn pump(&mut self) {
        for _ in 0..10_000 {
            let mut worked = false;
            for i in 0..self.nodes.len() {
                for output in self.nodes[i].drain() {
                    worked = true;
                    self.carry(i, output);
                }
            }
            if !worked {
                return;
            }
        }
        panic!("the nodes never settle");
    }

    fn carry(&mut self, i: usize, output: Output) {
        match output {
            Output::Send { conn, bytes } => {
                self.traffic.extend_from_slice(&bytes);
                if let Some(&(j, other)) = self.wires.get(&(i, conn)) {
                    let now = self.now;
                    self.nodes[j].received(other, &bytes, now);
                }
            }
            Output::Close { conn } => {
                let now = self.now;
                let failed = self
                    .trying
                    .remove(&(i, conn))
                    .filter(|d| !self.nodes[i].is_connected(*d));
                if let Some((j, other)) = self.wires.remove(&(i, conn)) {
                    self.wires.remove(&(j, other));
                    self.nodes[j].closed(other, now);
                }
                if let Some(device) = failed {
                    self.nodes[i].dial_failed(device, now);
                }
            }
            Output::Dial(request) => {
                let now = self.now;
                let target = self
                    .index(request.device)
                    .filter(|_| !self.unreachable.contains(&request.device));
                let Some(j) = target else {
                    return self.nodes[i].dial_failed(request.device, now);
                };
                let Some(there) = self.nodes[j].accepted(false, now) else {
                    return self.nodes[i].dial_failed(request.device, now);
                };
                match self.nodes[i].dialed(request.device, false, now) {
                    Some(here) => {
                        self.trying.insert((i, here), request.device);
                        self.wires.insert((i, here), (j, there));
                        self.wires.insert((j, there), (i, here));
                    }
                    None => self.nodes[j].closed(there, now),
                }
            }
            Output::Save(bytes) => self.saved[i] = Some(bytes),
            Output::Relisten | Output::HopChanged => {}
            Output::Event(event) => {
                if let Event::Connected(device, _) = &event {
                    self.trying
                        .retain(|(n, _), d| !(*n == i && *d == device.id));
                }
                self.events[i].push(event)
            }
        }
    }

    /// Moves time on and lets the nodes tick.
    pub fn advance(&mut self, seconds: f64) {
        let end = self.now + seconds;
        while self.now < end {
            self.now = (self.now + 0.5).min(end);
            let now = self.now;
            for node in &mut self.nodes {
                node.tick(now);
            }
            self.pump();
        }
    }

    /// Takes every event a node has had so far.
    pub fn take(&mut self, i: usize) -> Vec<Event> {
        std::mem::take(&mut self.events[i])
    }

    /// Links node `guest` to node `host` the way a scanned code does. Both end up connected peers.
    pub fn link(&mut self, host: usize, guest: usize) {
        let invite = self.nodes[host].invite(self.now);
        self.nodes[guest].join(&invite, self.now);
        self.pump();
        assert!(
            self.nodes[host].is_connected(self.nodes[guest].device().id),
            "linked and connected"
        );
        self.nodes[host].invite_hidden(self.now);
        self.pump();
    }

    /// Whether the node has an event matching.
    pub fn saw(&self, i: usize, wanted: impl Fn(&Event) -> bool) -> bool {
        self.events[i].iter().any(wanted)
    }

    pub fn messages(&self, i: usize) -> Vec<(LinkMessage, Uuid)> {
        self.events[i]
            .iter()
            .filter_map(|e| match e {
                Event::Message(m, from) => Some((m.clone(), *from)),
                _ => None,
            })
            .collect()
    }

    /// Cuts the connection between two nodes, as a dropped network would.
    pub fn cut(&mut self, a: usize, b: usize) {
        let now = self.now;
        let key = self
            .wires
            .iter()
            .find(|((i, _), (j, _))| *i == a && *j == b)
            .map(|(k, v)| (*k, *v));
        if let Some(((_, ca), (_, cb))) = key {
            self.wires.remove(&(a, ca));
            self.wires.remove(&(b, cb));
            self.nodes[a].closed(ca, now);
            self.nodes[b].closed(cb, now);
            self.pump();
        }
    }
}
