//! The Imps visiting this device (`docs/connecting/link.md`, "Visit"): for each one, how it came in, its
//! home's card and the ticket that lets this device act for it at its home. Plus the releases that could
//! not be delivered yet. The book keeps it.

use crate::link::card::{LinkCard, LinkDevice};
use crate::link::crypto;
use crate::link::doors::LinkTravel;
use crate::link::messages::{Bytes, LinkEntry, LinkImp, LinkSide};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// The most Imps that may visit at once.
pub const MAX_VISITS: usize = 24;
/// A release not delivered in this long (seconds) is dropped: its home is gone for good.
pub const RELEASE_LIFE: f64 = 14.0 * 24.0 * 3600.0;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Visit {
    pub imp: LinkImp,
    pub home: LinkCard,
    pub ticket: Bytes,
    /// The side of this screen it came in by, and the device that threw it.
    pub side: LinkSide,
    pub from: Uuid,
}

impl Visit {
    pub fn id(&self) -> Uuid {
        self.imp.id
    }

    pub fn travel(&self) -> LinkTravel {
        LinkTravel::Visit {
            side: self.side,
            from: self.from,
        }
    }
}

/// A visiting Imp that was sent home, whose home has not heard yet.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Release {
    pub imp: Uuid,
    pub home: LinkCard,
    pub ticket: Bytes,
    /// Seconds since 1970.
    pub date: f64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Visits {
    visits: Vec<Visit>,
    releases: Vec<Release>,
}

impl Visits {
    pub fn visits(&self) -> &[Visit] {
        &self.visits
    }

    pub fn releases(&self) -> &[Release] {
        &self.releases
    }

    pub fn visit(&self, imp: Uuid) -> Option<&Visit> {
        self.visits.iter().find(|v| v.imp.id == imp)
    }

    pub fn is_full(&self) -> bool {
        self.visits.len() >= MAX_VISITS
    }

    /// How the Imp got to this screen: a visitor's way in, or nothing special at home.
    pub fn travel(&self, imp: Uuid) -> LinkTravel {
        self.visit(imp).map_or(LinkTravel::Home, Visit::travel)
    }

    /// An Imp arrives. False if there is no room (a returning visitor always has).
    pub fn arrive(
        &mut self,
        imp: &LinkImp,
        entry: &LinkEntry,
        from: Uuid,
        home: &LinkCard,
        ticket: &[u8],
    ) -> bool {
        if self.visit(imp.id).is_none() && self.is_full() {
            return false;
        }
        self.visits.retain(|v| v.imp.id != imp.id);
        self.releases.retain(|r| r.imp != imp.id);
        self.visits.push(Visit {
            imp: imp.clone(),
            home: home.clone(),
            ticket: ticket.to_vec().into(),
            side: entry.side,
            from,
        });
        true
    }

    /// The home rotated the ticket after a claim.
    pub fn rotate(&mut self, imp: Uuid, ticket: &[u8]) {
        if let Some(v) = self.visits.iter_mut().find(|v| v.imp.id == imp) {
            v.ticket = ticket.to_vec().into();
        }
    }

    /// The home rotated the ticket of an Imp already sent home, so its release can go on. False unless a
    /// release for it is waiting at that home.
    pub fn rotate_release(&mut self, imp: Uuid, ticket: &[u8], home: Uuid) -> bool {
        match self
            .releases
            .iter_mut()
            .find(|r| r.imp == imp && r.home.id() == home)
        {
            Some(r) => {
                r.ticket = ticket.to_vec().into();
                true
            }
            None => false,
        }
    }

    /// Looks changed at the home.
    pub fn update(&mut self, imp: &LinkImp) {
        if let Some(v) = self.visits.iter_mut().find(|v| v.imp.id == imp.id) {
            v.imp = imp.clone();
        }
    }

    /// The Imp leaves this device (passed on, or the home said `gone`). Returns the visit.
    pub fn leave(&mut self, imp: Uuid) -> Option<Visit> {
        let i = self.visits.iter().position(|v| v.imp.id == imp)?;
        Some(self.visits.remove(i))
    }

    /// Sends a visiting Imp home from here (deleted, or its home forgotten): it leaves now and the
    /// release waits until the home has heard.
    pub fn send_home(&mut self, imp: Uuid, now: f64) -> Option<Visit> {
        let visit = self.leave(imp)?;
        self.releases.retain(|r| r.imp != imp);
        self.releases.push(Release {
            imp,
            home: visit.home.clone(),
            ticket: visit.ticket.clone(),
            date: now,
        });
        Some(visit)
    }

    /// Sends every Imp whose home is `home` back to it. Returns them.
    pub fn send_home_of(&mut self, home: Uuid, now: f64) -> Vec<Visit> {
        let ids: Vec<Uuid> = self
            .visits
            .iter()
            .filter(|v| v.home.id() == home)
            .map(Visit::id)
            .collect();
        ids.into_iter()
            .filter_map(|id| self.send_home(id, now))
            .collect()
    }

    /// The home heard the release (or no longer knows the Imp).
    pub fn delivered(&mut self, imp: Uuid, home: Uuid) {
        self.releases
            .retain(|r| !(r.imp == imp && r.home.id() == home));
    }

    /// Drops releases that waited too long.
    pub fn expire(&mut self, now: f64) {
        self.releases.retain(|r| now - r.date <= RELEASE_LIFE);
    }

    /// What to claim when connected to `home`: every Imp held from it, with the ticket held. Only a
    /// device with the key the Imp's card has is the home: tickets go to nobody else.
    pub fn claims(&self, home: &LinkDevice) -> Vec<(Uuid, Vec<u8>)> {
        self.visits
            .iter()
            .filter(|v| is_home(home, &v.home))
            .map(|v| (v.imp.id, v.ticket.0.clone()))
            .collect()
    }

    pub fn pending_releases(&self, home: &LinkDevice) -> Vec<&Release> {
        self.releases
            .iter()
            .filter(|r| is_home(home, &r.home))
            .collect()
    }

    /// The key of a home this device has business with, by its id.
    pub fn home_key(&self, id: Uuid) -> Option<&[u8]> {
        self.visits
            .iter()
            .map(|v| &v.home)
            .chain(self.releases.iter().map(|r| &r.home))
            .find(|h| h.id() == id)
            .map(|h| h.device.key.0.as_slice())
    }

    /// The homes this device has business with: where visiting Imps think, and where releases wait.
    pub fn homes(&self) -> Vec<LinkCard> {
        let mut seen = Vec::<Uuid>::new();
        let mut homes = Vec::new();
        for card in self
            .visits
            .iter()
            .map(|v| &v.home)
            .chain(self.releases.iter().map(|r| &r.home))
        {
            if !seen.contains(&card.id()) {
                seen.push(card.id());
                homes.push(card.clone());
            }
        }
        homes
    }
}

fn is_home(device: &LinkDevice, card: &LinkCard) -> bool {
    card.id() == device.id && crypto::equal(&card.device.key.0, &device.key.0)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::link::card::{LinkKind, LinkRoutes};

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    pub(crate) fn device(n: u128, key: u8) -> LinkDevice {
        LinkDevice {
            id: id(n),
            name: format!("Device {n}"),
            kind: LinkKind::Mac,
            key: vec![key; 32].into(),
            room: vec![key.wrapping_add(1); 32].into(),
        }
    }

    pub(crate) fn card(n: u128, key: u8) -> LinkCard {
        LinkCard {
            device: device(n, key),
            door: vec![7; 32].into(),
            routes: LinkRoutes::none(),
        }
    }

    pub(crate) fn imp(n: u128) -> LinkImp {
        LinkImp {
            id: id(n),
            name: format!("Imp {n}"),
            hue: 0.5,
            scale: 1.0,
            traits: Default::default(),
            about: None,
            abilities: Vec::new(),
        }
    }

    fn entry() -> LinkEntry {
        LinkEntry::new(LinkSide::Left, 0.5, 600.0)
    }

    #[test]
    fn an_arrival_records_how_it_came_in_and_travel_follows() {
        let mut visits = Visits::default();
        assert_eq!(visits.travel(id(1)), LinkTravel::Home);
        assert!(visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]));
        assert_eq!(
            visits.travel(id(1)),
            LinkTravel::Visit {
                side: LinkSide::Left,
                from: id(20)
            }
        );
        assert_eq!(visits.homes().len(), 1);
    }

    #[test]
    fn the_house_has_room_for_so_many_but_a_returning_visitor_always_fits() {
        let mut visits = Visits::default();
        for n in 0..MAX_VISITS as u128 {
            assert!(visits.arrive(&imp(100 + n), &entry(), id(20), &card(10, 1), &[5; 32]));
        }
        assert!(visits.is_full());
        assert!(!visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]));
        assert!(visits.arrive(&imp(100), &entry(), id(21), &card(10, 1), &[6; 32]));
        assert_eq!(visits.visits().len(), MAX_VISITS);
    }

    #[test]
    fn sending_home_keeps_a_release_until_the_home_hears() {
        let mut visits = Visits::default();
        visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]);
        assert!(visits.send_home(id(1), 100.0).is_some());
        assert!(visits.send_home(id(1), 100.0).is_none());
        assert!(visits.visit(id(1)).is_none());
        assert_eq!(visits.releases().len(), 1);
        assert!(visits.rotate_release(id(1), &[9; 32], id(10)));
        assert!(!visits.rotate_release(id(1), &[9; 32], id(11)));
        assert_eq!(visits.releases()[0].ticket.0, vec![9; 32]);
        visits.delivered(id(1), id(11));
        assert_eq!(visits.releases().len(), 1);
        visits.delivered(id(1), id(10));
        assert!(visits.releases().is_empty());
    }

    #[test]
    fn arriving_again_cancels_a_release_and_old_releases_expire() {
        let mut visits = Visits::default();
        visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]);
        visits.send_home(id(1), 0.0);
        visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]);
        assert!(visits.releases().is_empty());
        visits.send_home(id(1), 0.0);
        visits.expire(RELEASE_LIFE - 1.0);
        assert_eq!(visits.releases().len(), 1);
        visits.expire(RELEASE_LIFE + 1.0);
        assert!(visits.releases().is_empty());
    }

    #[test]
    fn tickets_go_only_to_a_device_with_the_homes_key() {
        let mut visits = Visits::default();
        visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]);
        visits.arrive(&imp(2), &entry(), id(20), &card(11, 2), &[6; 32]);
        assert_eq!(visits.claims(&device(10, 1)), vec![(id(1), vec![5; 32])]);
        assert!(visits.claims(&device(10, 99)).is_empty());
        assert!(visits.claims(&device(12, 1)).is_empty());
        visits.send_home(id(2), 0.0);
        assert_eq!(visits.pending_releases(&device(11, 2)).len(), 1);
        assert!(visits.pending_releases(&device(11, 3)).is_empty());
        assert_eq!(visits.home_key(id(11)), Some(&[2u8; 32][..]));
        assert_eq!(visits.home_key(id(99)), None);
    }

    #[test]
    fn rotate_update_and_leave_touch_only_their_imp() {
        let mut visits = Visits::default();
        visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]);
        visits.rotate(id(1), &[8; 32]);
        visits.rotate(id(2), &[8; 32]);
        assert_eq!(visits.visit(id(1)).unwrap().ticket.0, vec![8; 32]);
        let mut changed = imp(1);
        changed.name = "New".into();
        visits.update(&changed);
        assert_eq!(visits.visit(id(1)).unwrap().imp.name, "New");
        assert_eq!(visits.send_home_of(id(10), 0.0).len(), 1);
        assert!(visits.leave(id(1)).is_none());
    }

    #[test]
    fn sending_home_every_imp_of_a_home() {
        let mut visits = Visits::default();
        for n in 1..=3u128 {
            let home = if n == 3 { card(11, 2) } else { card(10, 1) };
            visits.arrive(&imp(n), &entry(), id(20), &home, &[5; 32]);
        }
        let mut sent: Vec<Uuid> = visits
            .send_home_of(id(10), 0.0)
            .iter()
            .map(Visit::id)
            .collect();
        sent.sort();
        assert_eq!(sent, vec![id(1), id(2)]);
        assert_eq!(visits.visits().len(), 1);
        assert_eq!(visits.visit(id(3)).map(Visit::id), Some(id(3)));
        assert_eq!(visits.releases().len(), 2);
    }

    #[test]
    fn a_release_waiting_keeps_its_home_known_until_delivered() {
        let mut visits = Visits::default();
        visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]);
        visits.send_home(id(1), 0.0);
        assert_eq!(
            visits.homes().iter().map(LinkCard::id).collect::<Vec<_>>(),
            vec![id(10)]
        );
        assert_eq!(
            visits.pending_releases(&device(10, 1))[0].ticket.0,
            vec![5; 32]
        );
        visits.delivered(id(1), id(10));
        assert!(visits.homes().is_empty());
    }

    #[test]
    fn looks_update_in_place_and_unknown_imps_are_ignored() {
        let mut visits = Visits::default();
        visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]);
        let mut look = imp(1);
        look.hue = 0.9;
        visits.update(&look);
        visits.update(&imp(7));
        assert_eq!(visits.visit(id(1)).unwrap().imp.hue, 0.9);
        assert_eq!(visits.visits().len(), 1);
    }

    #[test]
    fn a_returning_visitor_keeps_its_new_sender_and_the_old_home_card() {
        let mut visits = Visits::default();
        visits.arrive(&imp(1), &entry(), id(20), &card(10, 1), &[5; 32]);
        visits.arrive(&imp(1), &entry(), id(21), &card(10, 1), &[6; 32]);
        let v = visits.visit(id(1)).unwrap();
        assert_eq!(
            (v.from, v.ticket.0.clone(), v.home.clone()),
            (id(21), vec![6; 32], card(10, 1))
        );
    }
}
