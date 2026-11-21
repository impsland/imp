//! What the screens of Imp Link decide with the core's rules: throws, shakes, the Devices map and a
//! device's waiting lane. Plain values in, plain values out, so the apps keep no second copy.

use crate::link::{LinkError, from_json, json};
use imp_engine::link::lanes::{self, Admission};
use imp_engine::link::map::{self, DeviceMap, MapImp, MapKnown, MapPeer, MapRoutes};
use imp_engine::link::messages::{LinkEntry, LinkSide, LinkStaged};
use imp_engine::link::shake::{
    self, Decision, Direction, Sensitivity, ShakeImp, ShakePeer, ShakeSettings,
};
use imp_engine::link::toss::{self, Jolt, JoltDetector, Point, Rect};
use std::sync::{Mutex, MutexGuard};
use uuid::Uuid;

fn side_text(side: LinkSide) -> String {
    match side {
        LinkSide::Left => "left",
        LinkSide::Right => "right",
    }
    .to_string()
}

fn side_of(text: &str) -> Option<LinkSide> {
    match text {
        "left" => Some(LinkSide::Left),
        "right" => Some(LinkSide::Right),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct LinkPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct LinkRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl From<LinkPoint> for Point {
    fn from(p: LinkPoint) -> Self {
        Point { x: p.x, y: p.y }
    }
}

impl From<Point> for LinkPoint {
    fn from(p: Point) -> Self {
        LinkPoint { x: p.x, y: p.y }
    }
}

impl From<LinkRect> for Rect {
    fn from(r: LinkRect) -> Self {
        Rect {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}

impl From<Rect> for LinkRect {
    fn from(r: Rect) -> Self {
        LinkRect {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}

fn rects(screens: Vec<LinkRect>) -> Vec<Rect> {
    screens.into_iter().map(Rect::from).collect()
}

/// Where a throw leaves a screen: the side ("left" or "right") and how far down it (0 top, 1 bottom).
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkExit {
    pub side: String,
    pub height: f64,
}

fn exit_of(e: Option<toss::Exit>) -> Option<LinkExit> {
    e.map(|e| LinkExit {
        side: side_text(e.side),
        height: e.height,
    })
}

/// The outer side of the desktop a carried Imp is heading for.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkApproach {
    pub side: String,
    pub screen: LinkRect,
    pub height: f64,
    pub gap: f64,
}

/// Where an Imp tossed onto the desktop comes in.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkLanding {
    pub screen: LinkRect,
    pub point: LinkPoint,
}

/// The speeds and zones that tell a throw from a carry.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkTossLimits {
    pub desktop_speed: f64,
    pub desktop_zone: f64,
    pub phone_speed: f64,
    pub phone_zone: f64,
}

#[uniffi::export]
pub fn link_toss_limits() -> LinkTossLimits {
    LinkTossLimits {
        desktop_speed: toss::DESKTOP_SPEED,
        desktop_zone: toss::DESKTOP_ZONE,
        phone_speed: toss::PHONE_SPEED,
        phone_zone: toss::PHONE_ZONE,
    }
}

#[uniffi::export]
pub fn link_desktop_exit(
    cursor: LinkPoint,
    dx: f64,
    dy: f64,
    screens: Vec<LinkRect>,
) -> Option<LinkExit> {
    exit_of(toss::desktop_exit(cursor.into(), (dx, dy), &rects(screens)))
}

#[uniffi::export]
pub fn link_desktop_approach(
    cursor: LinkPoint,
    distance: f64,
    screens: Vec<LinkRect>,
) -> Option<LinkApproach> {
    toss::desktop_approach(cursor.into(), distance, &rects(screens)).map(|a| LinkApproach {
        side: side_text(a.side),
        screen: a.screen.into(),
        height: a.height,
        gap: a.gap,
    })
}

/// Where an Imp thrown in from `side` at `height` lands on these screens.
#[uniffi::export]
pub fn link_desktop_entry(
    side: String,
    height: f64,
    screens: Vec<LinkRect>,
) -> Option<LinkLanding> {
    let entry = LinkEntry {
        side: side_of(&side)?,
        height,
        speed: 0.0,
    };
    toss::desktop_entry(&entry, &rects(screens)).map(|(screen, point)| LinkLanding {
        screen: screen.into(),
        point: point.into(),
    })
}

#[uniffi::export]
pub fn link_phone_exit(
    point: LinkPoint,
    dx: f64,
    dy: f64,
    width: f64,
    height: f64,
) -> Option<LinkExit> {
    exit_of(toss::phone_exit(point.into(), (dx, dy), width, height))
}

#[uniffi::export]
pub fn link_phone_release(
    point: LinkPoint,
    predicted: LinkPoint,
    dx: f64,
    dy: f64,
    width: f64,
    height: f64,
) -> Option<LinkExit> {
    exit_of(toss::phone_release(
        point.into(),
        predicted.into(),
        (dx, dy),
        width,
        height,
    ))
}

/// What a jolt of the whole phone was.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum LinkJolt {
    Thrown { side: String },
    Shaken,
}

/// Spots a throw or a shake from the phone's sideways acceleration and its turn.
#[derive(uniffi::Object)]
pub struct LinkJoltDetector {
    inner: Mutex<JoltDetector>,
}

#[uniffi::export]
impl LinkJoltDetector {
    #[uniffi::constructor]
    pub fn new(
        threshold: f64,
        window: f64,
        shake_count: u32,
        cooldown: f64,
    ) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            inner: Mutex::new(JoltDetector::new(
                threshold,
                window,
                shake_count as usize,
                cooldown,
            )),
        })
    }

    pub fn feed(&self, x: f64, at: f64) -> Option<LinkJolt> {
        self.feed_motion(x, 0.0, at)
    }

    /// A sample with the turn in the screen's plane too (rad/s, + counterclockwise as you look at the screen),
    /// which tells a flick's direction best.
    pub fn feed_motion(&self, x: f64, spin: f64, at: f64) -> Option<LinkJolt> {
        let mut inner = lock(&self.inner);
        inner.feed_motion(x, spin, at).map(|j| match j {
            Jolt::Thrown(side) => LinkJolt::Thrown {
                side: side_text(side),
            },
            Jolt::Shaken => LinkJolt::Shaken,
        })
    }

    pub fn shake_start(&self) -> Option<String> {
        lock(&self.inner).shake_start().map(side_text)
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// How hard a shake has to be: the push each needs (g) and how many make a shake.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkShakeStrength {
    pub threshold: f64,
    pub pushes: u32,
}

fn sensitivity(text: &str) -> Sensitivity {
    match text {
        "gentle" => Sensitivity::Gentle,
        "firm" => Sensitivity::Firm,
        _ => Sensitivity::Normal,
    }
}

#[uniffi::export]
pub fn link_shake_strength(sensitivity_name: String) -> LinkShakeStrength {
    let s = sensitivity(&sensitivity_name);
    LinkShakeStrength {
        threshold: s.threshold(),
        pushes: s.pushes() as u32,
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkShakeSettings {
    pub enabled: bool,
    /// "gentle", "normal" or "firm".
    pub sensitivity: String,
    /// "either" or "leftRight".
    pub direction: String,
    pub asks_for_friends: bool,
    pub nearby_window: f64,
}

/// The seconds a device counts as nearby by default.
#[uniffi::export]
pub fn link_shake_nearby_window() -> f64 {
    ShakeSettings::default().nearby_window
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkShakeImp {
    pub id: String,
    pub name: String,
    pub last_moved: Option<f64>,
    pub last_touched: Option<f64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkShakePeer {
    pub id: String,
    pub name: String,
    pub linked: bool,
    pub connected: bool,
    pub via_hop: bool,
    pub last_nearby: Option<f64>,
    pub mine: bool,
}

/// What a shake does: send, ask, or nothing.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum LinkShakeDecision {
    Send {
        imp: String,
        to: String,
    },
    /// `why` is "severalNearby", "friend" or "farAway".
    Ask {
        imp: String,
        choices: Vec<String>,
        why: String,
    },
    /// `why` is "off", "noImps" or "nobodyAround".
    Nothing {
        why: String,
    },
}

/// `closeness` of a device: "near", "recent" or "far".
#[uniffi::export]
pub fn link_shake_closeness(
    peer: LinkShakePeer,
    now: f64,
    window: f64,
) -> Result<String, LinkError> {
    let peer = shake_peer(peer)?;
    Ok(match shake::closeness(&peer, now, window) {
        shake::Closeness::Near => "near",
        shake::Closeness::Recent => "recent",
        shake::Closeness::Far => "far",
    }
    .to_string())
}

fn shake_peer(p: LinkShakePeer) -> Result<ShakePeer, LinkError> {
    Ok(ShakePeer {
        id: crate::link::uuid(&p.id)?,
        name: p.name,
        linked: p.linked,
        connected: p.connected,
        via_hop: p.via_hop,
        last_nearby: p.last_nearby,
        mine: p.mine,
    })
}

/// Which Imp a shake sends and where (`side`: the way the shake started, if it can tell).
#[uniffi::export]
pub fn link_shake_decide(
    imps: Vec<LinkShakeImp>,
    peers: Vec<LinkShakePeer>,
    side: Option<String>,
    settings: LinkShakeSettings,
    now: f64,
) -> Result<LinkShakeDecision, LinkError> {
    let imps = imps
        .into_iter()
        .map(|i| {
            Ok(ShakeImp {
                id: crate::link::uuid(&i.id)?,
                name: i.name,
                last_moved: i.last_moved,
                last_touched: i.last_touched,
            })
        })
        .collect::<Result<Vec<_>, LinkError>>()?;
    let peers = peers
        .into_iter()
        .map(shake_peer)
        .collect::<Result<Vec<_>, LinkError>>()?;
    let settings = ShakeSettings {
        enabled: settings.enabled,
        sensitivity: sensitivity(&settings.sensitivity),
        direction: if settings.direction == "leftRight" {
            Direction::LeftRight
        } else {
            Direction::Either
        },
        asks_for_friends: settings.asks_for_friends,
        nearby_window: settings.nearby_window,
    };
    let side = side.as_deref().and_then(side_of);
    let text = |id: Uuid| id.to_string().to_uppercase();
    Ok(match shake::decide(&imps, &peers, side, &settings, now) {
        Decision::Send { imp, to } => LinkShakeDecision::Send {
            imp: text(imp),
            to: text(to),
        },
        Decision::Ask { imp, choices, why } => LinkShakeDecision::Ask {
            imp: text(imp),
            choices: choices.into_iter().map(text).collect(),
            why: match why {
                shake::Why::SeveralNearby => "severalNearby",
                shake::Why::Friend => "friend",
                shake::Why::FarAway => "farAway",
            }
            .to_string(),
        },
        Decision::Nothing(why) => LinkShakeDecision::Nothing {
            why: match why {
                shake::Nothing::Off => "off",
                shake::Nothing::NoImps => "noImps",
                shake::Nothing::NobodyAround => "nobodyAround",
            }
            .to_string(),
        },
    })
}

/// The Devices map. Routes, peers, Imps and visitors come as JSON, and so does the map that comes back.
/// `this_routes` is empty before the node is open.
#[uniffi::export]
pub fn link_device_map(
    this_device: String,
    this_routes: String,
    peers: String,
    server: String,
    imps: String,
    visitors: String,
    known: String,
) -> Result<String, LinkError> {
    let this_routes: Option<MapRoutes> = if this_routes.trim().is_empty() {
        None
    } else {
        Some(from_json(&this_routes)?)
    };
    let peers: Vec<MapPeer> = from_json(&peers)?;
    let imps: Vec<MapImp> = from_json(&imps)?;
    let visitors: Vec<LinkStaged> = from_json(&visitors)?;
    let known: Vec<MapKnown> = from_json(&known)?;
    Ok(json(&DeviceMap::build(
        &this_device,
        this_routes.as_ref(),
        &peers,
        &server,
        &imps,
        &visitors,
        &known,
    )))
}

/// The ids of this device's node and of the server's node in the map.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkMapIds {
    pub this_device: String,
    pub server: String,
}

#[uniffi::export]
pub fn link_map_ids() -> LinkMapIds {
    LinkMapIds {
        this_device: map::THIS_DEVICE.to_string(),
        server: map::SERVER.to_string(),
    }
}

/// The parts of the line from `a` to `b` that lie outside every box.
#[uniffi::export]
pub fn link_line_pieces(a: LinkPoint, b: LinkPoint, boxes: Vec<LinkRect>) -> Vec<LinkLine> {
    let boxes: Vec<(f64, f64, f64, f64)> = boxes
        .iter()
        .map(|r| (r.x, r.y, r.width, r.height))
        .collect();
    map::pieces((a.x, a.y), (b.x, b.y), &boxes)
        .into_iter()
        .map(|(from, to)| LinkLine {
            from: LinkPoint {
                x: from.0,
                y: from.1,
            },
            to: LinkPoint { x: to.0, y: to.1 },
        })
        .collect()
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkLine {
    pub from: LinkPoint,
    pub to: LinkPoint,
}

/// What happens to a job offered to a device's lane: "run", "wait" or "busy".
#[uniffi::export]
pub fn link_lane_admit(running: bool, queued: u32) -> String {
    match lanes::admit(running, queued as usize) {
        Admission::Run => "run",
        Admission::Wait => "wait",
        Admission::Busy => "busy",
    }
    .to_string()
}

/// How many jobs may wait behind the one that runs, and how many files one device may fetch at once.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkLaneLimits {
    pub waiting: u32,
    pub files: u32,
}

#[uniffi::export]
pub fn link_lane_limits() -> LinkLaneLimits {
    LinkLaneLimits {
        waiting: lanes::WAITING as u32,
        files: lanes::FILES as u32,
    }
}
