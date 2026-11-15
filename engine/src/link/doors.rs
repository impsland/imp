//! Where a thrown Imp goes (`docs/connecting/link.md`, "Doors"). The screen asks with what is connected
//! right now and gets a device, or the reason it bounces.

use crate::link::messages::LinkSide;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// How an Imp's body got to the screen it is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkTravel {
    /// It is at home.
    Home,
    /// It came in through `side` of this screen, from the device `from`.
    Visit { side: LinkSide, from: Uuid },
}

/// Why an Imp bounces back instead of leaving.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bounce {
    /// No device is connected.
    NobodyConnected,
    /// It came in by this side from a device that is not connected any more.
    WayBackIsClosed,
    /// Nothing but the device it came from is connected, and that is not the way on.
    NowhereElse,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Door {
    To(Uuid),
    Bounce(Bounce),
}

/// One device's share of a side: the heights from `top` to `bottom` (0 is the top).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Band {
    pub device: Uuid,
    pub top: f64,
    pub bottom: f64,
}

/// The devices a side of this screen leads to, in a stable order.
pub fn reach(side: LinkSide, travel: LinkTravel, connected: &[Uuid]) -> Vec<Uuid> {
    let mut all = connected.to_vec();
    all.sort();
    all.dedup();
    match travel {
        LinkTravel::Home => all,
        // The side it came in by leads back to where it came from, the other side leads on.
        LinkTravel::Visit { side: entry, from } => all
            .into_iter()
            .filter(|d| (side == entry) == (*d == from))
            .collect(),
    }
}

/// The side split into equal bands from top to bottom, one per device (for labelling).
pub fn bands(side: LinkSide, travel: LinkTravel, connected: &[Uuid]) -> Vec<Band> {
    let devices = reach(side, travel, connected);
    let n = devices.len() as f64;
    devices
        .into_iter()
        .enumerate()
        .map(|(i, device)| Band {
            device,
            top: i as f64 / n,
            bottom: (i + 1) as f64 / n,
        })
        .collect()
}

/// Where an Imp thrown off `side` at `height` (0 the top, 1 the bottom) goes.
pub fn door(side: LinkSide, height: f64, travel: LinkTravel, connected: &[Uuid]) -> Door {
    let devices = reach(side, travel, connected);
    if devices.is_empty() {
        if connected.is_empty() {
            return Door::Bounce(Bounce::NobodyConnected);
        }
        if matches!(travel, LinkTravel::Visit { side: entry, .. } if entry == side) {
            return Door::Bounce(Bounce::WayBackIsClosed);
        }
        return Door::Bounce(Bounce::NowhereElse);
    }
    let h = if height.is_finite() {
        height.clamp(0.0, 1.0)
    } else {
        0.5
    };
    let index = ((h * devices.len() as f64) as usize).min(devices.len() - 1);
    Door::To(devices[index])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    #[test]
    fn at_home_every_connected_device_is_reachable_on_both_sides() {
        let connected = [id(3), id(1), id(2), id(1)];
        assert_eq!(
            reach(LinkSide::Left, LinkTravel::Home, &connected),
            vec![id(1), id(2), id(3)]
        );
        assert_eq!(
            reach(LinkSide::Right, LinkTravel::Home, &connected),
            vec![id(1), id(2), id(3)]
        );
    }

    #[test]
    fn a_visitor_goes_back_by_the_side_it_came_in_and_on_by_the_other() {
        let travel = LinkTravel::Visit {
            side: LinkSide::Left,
            from: id(1),
        };
        let connected = [id(1), id(2)];
        assert_eq!(reach(LinkSide::Left, travel, &connected), vec![id(1)]);
        assert_eq!(reach(LinkSide::Right, travel, &connected), vec![id(2)]);
    }

    #[test]
    fn heights_pick_a_band_and_bad_heights_are_safe() {
        let connected = [id(1), id(2)];
        let pick = |h: f64| door(LinkSide::Right, h, LinkTravel::Home, &connected);
        assert_eq!(pick(0.0), Door::To(id(1)));
        assert_eq!(pick(0.49), Door::To(id(1)));
        assert_eq!(pick(0.5), Door::To(id(2)));
        assert_eq!(pick(1.0), Door::To(id(2)));
        assert_eq!(pick(-3.0), Door::To(id(1)));
        assert_eq!(pick(f64::NAN), Door::To(id(2)));
        let b = bands(LinkSide::Right, LinkTravel::Home, &connected);
        assert_eq!(
            (b[0].top, b[0].bottom, b[1].top, b[1].bottom),
            (0.0, 0.5, 0.5, 1.0)
        );
    }

    #[test]
    fn the_reasons_an_imp_bounces() {
        let visit = LinkTravel::Visit {
            side: LinkSide::Left,
            from: id(1),
        };
        assert_eq!(
            door(LinkSide::Left, 0.5, LinkTravel::Home, &[]),
            Door::Bounce(Bounce::NobodyConnected)
        );
        assert_eq!(
            door(LinkSide::Left, 0.5, visit, &[id(2)]),
            Door::Bounce(Bounce::WayBackIsClosed)
        );
        assert_eq!(
            door(LinkSide::Right, 0.5, visit, &[id(1)]),
            Door::Bounce(Bounce::NowhereElse)
        );
    }

    #[test]
    fn the_order_is_stable_whatever_the_connection_order() {
        let a = reach(LinkSide::Left, LinkTravel::Home, &[id(4), id(2), id(3)]);
        assert_eq!(
            a,
            reach(LinkSide::Left, LinkTravel::Home, &[id(3), id(4), id(2)])
        );
        assert_eq!(
            a,
            reach(
                LinkSide::Left,
                LinkTravel::Home,
                &[id(2), id(2), id(3), id(4), id(4)]
            )
        );
        let mut sorted = a.clone();
        sorted.sort_by_key(|u| u.to_string());
        assert_eq!(a, sorted);
    }

    #[test]
    fn a_visit_goes_back_the_way_it_came_with_doors_by_height() {
        let travel = LinkTravel::Visit {
            side: LinkSide::Right,
            from: id(1),
        };
        let connected = [id(1), id(2), id(3)];
        assert_eq!(reach(LinkSide::Right, travel, &connected), vec![id(1)]);
        assert_eq!(
            reach(LinkSide::Left, travel, &connected),
            vec![id(2), id(3)]
        );
        assert_eq!(
            door(LinkSide::Right, 0.9, travel, &connected),
            Door::To(id(1))
        );
        assert_eq!(
            door(LinkSide::Left, 0.1, travel, &connected),
            Door::To(id(2))
        );
        assert_eq!(
            door(LinkSide::Left, 0.9, travel, &connected),
            Door::To(id(3))
        );
    }

    #[test]
    fn the_forward_side_never_leads_back() {
        for entry in [LinkSide::Left, LinkSide::Right] {
            let travel = LinkTravel::Visit {
                side: entry,
                from: id(1),
            };
            let forward = reach(entry.opposite(), travel, &[id(1), id(2), id(3)]);
            assert!(!forward.contains(&id(1)));
            assert_eq!(forward, vec![id(2), id(3)]);
        }
    }

    #[test]
    fn four_devices_split_the_height_into_quarters() {
        let connected = [id(1), id(2), id(3), id(4)];
        let pick = |h: f64| door(LinkSide::Left, h, LinkTravel::Home, &connected);
        assert_eq!(
            (pick(0.0), pick(0.24), pick(0.25)),
            (Door::To(id(1)), Door::To(id(1)), Door::To(id(2)))
        );
        assert_eq!(
            (pick(0.5), pick(0.74), pick(0.75)),
            (Door::To(id(3)), Door::To(id(3)), Door::To(id(4)))
        );
        assert_eq!(
            (pick(1.0), pick(-4.0), pick(9.0)),
            (Door::To(id(4)), Door::To(id(1)), Door::To(id(4)))
        );
        assert_eq!(
            (pick(f64::NAN), pick(f64::INFINITY)),
            (Door::To(id(3)), Door::To(id(3)))
        );
    }

    #[test]
    fn bands_are_equal_from_top_to_bottom() {
        let b = bands(LinkSide::Right, LinkTravel::Home, &[id(1), id(2), id(3)]);
        assert_eq!(
            b.iter().map(|b| b.device).collect::<Vec<_>>(),
            vec![id(1), id(2), id(3)]
        );
        assert_eq!((b[0].top, b[2].bottom), (0.0, 1.0));
        for pair in b.windows(2) {
            assert_eq!(pair[0].bottom, pair[1].top);
        }
        assert!(((b[0].bottom - b[0].top) - 1.0 / 3.0).abs() < 1e-9);
        assert!(bands(LinkSide::Right, LinkTravel::Home, &[]).is_empty());
    }

    #[test]
    fn nobody_connected_bounces_for_a_visitor_too() {
        let back = LinkTravel::Visit {
            side: LinkSide::Left,
            from: id(1),
        };
        assert_eq!(
            door(LinkSide::Right, 0.5, back, &[]),
            Door::Bounce(Bounce::NobodyConnected)
        );
    }
}
