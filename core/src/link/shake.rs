//! Which Imp a shake sends and where, decided from what the phone knows (`docs/concepts/transfer.md`).
//! Pure: no clock, no network, everything is passed in. Times are seconds.

use crate::link::messages::LinkSide;
use uuid::Uuid;

/// How hard a shake has to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Sensitivity {
    Gentle,
    #[default]
    Normal,
    Firm,
}

impl Sensitivity {
    /// Acceleration (g) each push of the shake needs.
    pub fn threshold(self) -> f64 {
        match self {
            Self::Gentle => 1.5,
            Self::Normal => 2.0,
            Self::Firm => 2.8,
        }
    }

    /// Pushes back and forth that make a shake.
    pub fn pushes(self) -> usize {
        if self == Self::Firm { 5 } else { 4 }
    }
}

/// What the side the shake starts toward means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Direction {
    /// It does not mean anything. The device that is nearby goes.
    #[default]
    Either,
    /// With two devices nearby, a shake to the right sends to the first and to the left to the second.
    LeftRight,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShakeSettings {
    pub enabled: bool,
    pub sensitivity: Sensitivity,
    pub direction: Direction,
    /// A device that is linked but not marked as one of yours is asked about first.
    pub asks_for_friends: bool,
    /// How long (seconds) a device counts as nearby after it was last seen on the same network.
    pub nearby_window: f64,
}

impl Default for ShakeSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            sensitivity: Sensitivity::Normal,
            direction: Direction::Either,
            asks_for_friends: true,
            nearby_window: 10.0 * 60.0,
        }
    }
}

/// An Imp that is on the phone's screen and free to go.
#[derive(Debug, Clone, PartialEq)]
pub struct ShakeImp {
    pub id: Uuid,
    pub name: String,
    /// When it was last carried, thrown or flew in.
    pub last_moved: Option<f64>,
    /// When a finger last touched it.
    pub last_touched: Option<f64>,
}

/// A device the phone knows.
#[derive(Debug, Clone, PartialEq)]
pub struct ShakePeer {
    pub id: Uuid,
    pub name: String,
    /// Linked: it is in the phone's book of devices. Nothing else is ever a target.
    pub linked: bool,
    /// Connected right now (an Imp can only be thrown to a connected device).
    pub connected: bool,
    /// Connected through the Hop server (the internet) and not the local network.
    pub via_hop: bool,
    /// The last time it was connected over the local network.
    pub last_nearby: Option<f64>,
    /// Marked as one of the owner's own devices.
    pub mine: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Closeness {
    Near,
    Recent,
    Far,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Why {
    /// Several devices are nearby and the shake does not say which.
    SeveralNearby,
    /// Linked, but not one of the owner's own devices.
    Friend,
    /// No device was seen nearby lately: it may be far away.
    FarAway,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Nothing {
    Off,
    NoImps,
    NobodyAround,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Send it now. The person sees where it went and can undo it for a few seconds.
    Send {
        imp: Uuid,
        to: Uuid,
    },
    /// Ask first: `choices` are the devices to pick from, in the order to show them.
    Ask {
        imp: Uuid,
        choices: Vec<Uuid>,
        why: Why,
    },
    Nothing(Nothing),
}

/// How close a device is: on the local network now, seen there lately, or neither.
pub fn closeness(peer: &ShakePeer, now: f64, window: f64) -> Closeness {
    if peer.connected && !peer.via_hop {
        Closeness::Near
    } else if peer.last_nearby.is_some_and(|seen| now - seen <= window) {
        Closeness::Recent
    } else {
        Closeness::Far
    }
}

/// The Imp a shake moves: the one carried or thrown last, then the one touched last, then by name so the
/// same Imp is picked every time.
pub fn pick(imps: &[ShakeImp]) -> Option<&ShakeImp> {
    let when = |t: Option<f64>| t.unwrap_or(f64::NEG_INFINITY);
    imps.iter().min_by(|a, b| {
        when(b.last_moved)
            .total_cmp(&when(a.last_moved))
            .then(when(b.last_touched).total_cmp(&when(a.last_touched)))
            .then_with(|| (&a.name, a.id).cmp(&(&b.name, b.id)))
    })
}

/// `side`: the way the shake started, if it can tell.
pub fn decide(
    imps: &[ShakeImp],
    peers: &[ShakePeer],
    side: Option<LinkSide>,
    settings: &ShakeSettings,
    now: f64,
) -> Decision {
    if !settings.enabled {
        return Decision::Nothing(Nothing::Off);
    }
    let Some(imp) = pick(imps) else {
        return Decision::Nothing(Nothing::NoImps);
    };
    // Only a linked device that is connected is ever a target.
    let mut eligible: Vec<&ShakePeer> = peers.iter().filter(|p| p.linked && p.connected).collect();
    eligible.sort_by(|a, b| (&a.name, a.id).cmp(&(&b.name, b.id)));
    if eligible.is_empty() {
        return Decision::Nothing(Nothing::NobodyAround);
    }
    let tier = |c: Closeness| -> Vec<&ShakePeer> {
        eligible
            .iter()
            .copied()
            .filter(|p| closeness(p, now, settings.nearby_window) == c)
            .collect()
    };
    let near = tier(Closeness::Near);
    let pool = if near.is_empty() {
        tier(Closeness::Recent)
    } else {
        near
    };
    if pool.is_empty() {
        return Decision::Ask {
            imp: imp.id,
            choices: eligible.iter().map(|p| p.id).collect(),
            why: Why::FarAway,
        };
    }
    let target = if pool.len() == 1 {
        Some(pool[0])
    } else if settings.direction == Direction::LeftRight && pool.len() == 2 {
        side.map(|s| {
            if s == LinkSide::Right {
                pool[0]
            } else {
                pool[1]
            }
        })
    } else {
        None
    };
    let Some(target) = target else {
        return Decision::Ask {
            imp: imp.id,
            choices: pool.iter().map(|p| p.id).collect(),
            why: Why::SeveralNearby,
        };
    };
    if !target.mine && settings.asks_for_friends {
        return Decision::Ask {
            imp: imp.id,
            choices: vec![target.id],
            why: Why::Friend,
        };
    }
    Decision::Send {
        imp: imp.id,
        to: target.id,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn imp(n: u128, name: &str, moved: Option<f64>, touched: Option<f64>) -> ShakeImp {
        ShakeImp {
            id: id(n),
            name: name.into(),
            last_moved: moved,
            last_touched: touched,
        }
    }

    fn peer(n: u128, name: &str) -> ShakePeer {
        ShakePeer {
            id: id(n),
            name: name.into(),
            linked: true,
            connected: true,
            via_hop: false,
            last_nearby: None,
            mine: true,
        }
    }

    const NOW: f64 = 10_000.0;

    fn decide_with(
        imps: &[ShakeImp],
        peers: &[ShakePeer],
        side: Option<LinkSide>,
        settings: &ShakeSettings,
    ) -> Decision {
        decide(imps, peers, side, settings, NOW)
    }

    #[test]
    fn the_imp_moved_last_goes_then_the_one_touched_last_then_by_name() {
        let imps = [
            imp(1, "B", Some(5.0), None),
            imp(2, "A", Some(9.0), None),
            imp(3, "C", None, Some(99.0)),
        ];
        assert_eq!(pick(&imps).unwrap().id, id(2));
        let imps = [imp(1, "B", None, Some(5.0)), imp(2, "A", None, Some(9.0))];
        assert_eq!(pick(&imps).unwrap().id, id(2));
        let imps = [imp(2, "B", None, None), imp(1, "A", None, None)];
        assert_eq!(pick(&imps).unwrap().id, id(1));
        assert!(pick(&[]).is_none());
    }

    #[test]
    fn off_no_imps_and_nobody_around_send_nothing() {
        let imps = [imp(1, "Pip", None, None)];
        let off = ShakeSettings {
            enabled: false,
            ..Default::default()
        };
        assert_eq!(
            decide_with(&imps, &[peer(10, "Mac")], None, &off),
            Decision::Nothing(Nothing::Off)
        );
        assert_eq!(
            decide_with(&[], &[peer(10, "Mac")], None, &ShakeSettings::default()),
            Decision::Nothing(Nothing::NoImps)
        );
        let mut unlinked = peer(10, "Mac");
        unlinked.linked = false;
        let mut gone = peer(11, "Gone");
        gone.connected = false;
        assert_eq!(
            decide_with(&imps, &[unlinked, gone], None, &ShakeSettings::default()),
            Decision::Nothing(Nothing::NobodyAround)
        );
    }

    #[test]
    fn one_device_nearby_that_is_mine_gets_the_imp() {
        let imps = [imp(1, "Pip", None, None)];
        assert_eq!(
            decide_with(&imps, &[peer(10, "Mac")], None, &ShakeSettings::default()),
            Decision::Send {
                imp: id(1),
                to: id(10)
            }
        );
    }

    #[test]
    fn a_friends_device_is_asked_about_first_unless_that_is_turned_off() {
        let imps = [imp(1, "Pip", None, None)];
        let mut friend = peer(10, "Friend");
        friend.mine = false;
        assert_eq!(
            decide_with(&imps, &[friend.clone()], None, &ShakeSettings::default()),
            Decision::Ask {
                imp: id(1),
                choices: vec![id(10)],
                why: Why::Friend
            }
        );
        let relaxed = ShakeSettings {
            asks_for_friends: false,
            ..Default::default()
        };
        assert_eq!(
            decide_with(&imps, &[friend], None, &relaxed),
            Decision::Send {
                imp: id(1),
                to: id(10)
            }
        );
    }

    #[test]
    fn several_nearby_ask_unless_left_right_picks_by_the_side() {
        let imps = [imp(1, "Pip", None, None)];
        let peers = [peer(11, "B Mac"), peer(10, "A Mac")];
        assert_eq!(
            decide_with(
                &imps,
                &peers,
                Some(LinkSide::Right),
                &ShakeSettings::default()
            ),
            Decision::Ask {
                imp: id(1),
                choices: vec![id(10), id(11)],
                why: Why::SeveralNearby
            }
        );
        let by_side = ShakeSettings {
            direction: Direction::LeftRight,
            ..Default::default()
        };
        assert_eq!(
            decide_with(&imps, &peers, Some(LinkSide::Right), &by_side),
            Decision::Send {
                imp: id(1),
                to: id(10)
            }
        );
        assert_eq!(
            decide_with(&imps, &peers, Some(LinkSide::Left), &by_side),
            Decision::Send {
                imp: id(1),
                to: id(11)
            }
        );
        assert!(matches!(
            decide_with(&imps, &peers, None, &by_side),
            Decision::Ask {
                why: Why::SeveralNearby,
                ..
            }
        ));
        let three = [peer(10, "A"), peer(11, "B"), peer(12, "C")];
        assert!(matches!(
            decide_with(&imps, &three, Some(LinkSide::Left), &by_side),
            Decision::Ask { .. }
        ));
    }

    #[test]
    fn a_device_that_is_not_linked_is_passed_over_for_one_that_is() {
        let imps = [imp(1, "Pip", None, None)];
        let mut unlinked = peer(10, "Stranger");
        unlinked.linked = false;
        let mut gone = peer(11, "Gone");
        gone.connected = false;
        gone.last_nearby = Some(NOW - 1.0);
        assert_eq!(
            decide_with(
                &imps,
                &[unlinked, gone, peer(12, "Mine")],
                None,
                &ShakeSettings::default()
            ),
            Decision::Send {
                imp: id(1),
                to: id(12)
            }
        );
    }

    #[test]
    fn nearness_uses_the_local_network_then_recent_sightings() {
        let imps = [imp(1, "Pip", None, None)];
        let mut hop = peer(10, "Far");
        hop.via_hop = true;
        let mut recent = peer(11, "Recent");
        recent.via_hop = true;
        recent.last_nearby = Some(NOW - 60.0);
        let settings = ShakeSettings::default();
        assert_eq!(closeness(&hop, NOW, settings.nearby_window), Closeness::Far);
        assert_eq!(
            closeness(&recent, NOW, settings.nearby_window),
            Closeness::Recent
        );
        assert_eq!(
            closeness(&peer(12, "Near"), NOW, settings.nearby_window),
            Closeness::Near
        );
        // Only far ones: ask among all of them.
        assert_eq!(
            decide_with(&imps, &[hop.clone()], None, &settings),
            Decision::Ask {
                imp: id(1),
                choices: vec![id(10)],
                why: Why::FarAway
            }
        );
        // A recent one beats a far one.
        assert_eq!(
            decide_with(&imps, &[hop.clone(), recent.clone()], None, &settings),
            Decision::Send {
                imp: id(1),
                to: id(11)
            }
        );
        // A near one beats a recent one.
        assert_eq!(
            decide_with(&imps, &[recent, peer(12, "Near")], None, &settings),
            Decision::Send {
                imp: id(1),
                to: id(12)
            }
        );
        // Old sightings do not count.
        let mut old = peer(13, "Old");
        old.via_hop = true;
        old.last_nearby = Some(NOW - 3600.0);
        assert_eq!(closeness(&old, NOW, settings.nearby_window), Closeness::Far);
    }

    #[test]
    fn sensitivity_sets_the_push_strength_and_count() {
        assert_eq!(
            (
                Sensitivity::Gentle.threshold(),
                Sensitivity::Gentle.pushes()
            ),
            (1.5, 4)
        );
        assert_eq!(
            (
                Sensitivity::Normal.threshold(),
                Sensitivity::Normal.pushes()
            ),
            (2.0, 4)
        );
        assert_eq!(
            (Sensitivity::Firm.threshold(), Sensitivity::Firm.pushes()),
            (2.8, 5)
        );
    }
}
