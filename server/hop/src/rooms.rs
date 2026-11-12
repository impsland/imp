//! Rooms: who is waiting, and how many sessions are live.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use tokio::sync::oneshot;

use crate::handshake::{Arrived, Key, Role};
use crate::limits::ConnGuard;

/// A connection that has passed the handshake.
pub struct Peer {
    pub stream: tokio::net::TcpStream,
    pub conn: ConnGuard,
}

/// What a waiter is woken with.
pub enum Wake {
    /// The other side arrived and this is its connection.
    Peer(Peer),
    /// The host's gate is not this guest's gate.
    Rejected,
}

struct Slot {
    id: u64,
    gate: Key,
    tx: oneshot::Sender<Wake>,
}

/// Hands `me` to a waiter. Gives it back when the waiter has already left.
fn give(tx: oneshot::Sender<Wake>, me: Peer) -> Option<Peer> {
    let Err(Wake::Peer(back)) = tx.send(Wake::Peer(me)) else {
        return None;
    };
    Some(back)
}

#[derive(Default)]
struct State {
    host: Option<Slot>,
    guests: VecDeque<Slot>,
    sessions: usize,
}

impl State {
    fn is_empty(&self) -> bool {
        self.host.is_none() && self.guests.is_empty() && self.sessions == 0
    }
}

pub struct Rooms {
    rooms: Mutex<HashMap<Key, State>>,
    next_id: AtomicU64,
    max_sessions: usize,
}

pub enum Arrival {
    /// The other side was waiting and has the connection now.
    Paired,
    /// Nobody there yet: the caller waits on `rx` and keeps its connection.
    Wait {
        id: u64,
        rx: oneshot::Receiver<Wake>,
        me: Peer,
    },
    /// The room is full.
    Busy(Peer),
    /// A guest whose gate is not the waiting host's gate.
    Rejected(Peer),
}

/// One live session in a room. Dropping it frees the place.
pub struct SessionGuard {
    rooms: Arc<Rooms>,
    room: Key,
}

impl Rooms {
    pub fn new(max_sessions: usize) -> Arc<Self> {
        Arc::new(Self {
            rooms: Mutex::default(),
            next_id: AtomicU64::new(0),
            max_sessions,
        })
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<Key, State>> {
        self.rooms.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A host or a guest shows up. If the other side is waiting it gets `me` and a session starts.
    /// Otherwise the caller waits. A new host replaces the host that was waiting. A host takes at most
    /// one guest per connection, and every waiting guest with another gate is turned away.
    pub fn arrive(&self, who: Arrived, me: Peer) -> Arrival {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut rooms = self.lock();
        let state = rooms.entry(who.room).or_default();
        let (tx, rx) = oneshot::channel();
        let slot = Slot {
            id,
            gate: who.gate,
            tx,
        };
        match who.role {
            Role::Guest => {
                if state.sessions >= self.max_sessions {
                    return Arrival::Busy(me);
                }
                let mut me = me;
                if let Some(host) = state.host.take_if(|h| !h.tx.is_closed()) {
                    if host.gate != who.gate {
                        state.host = Some(host);
                        return Arrival::Rejected(me);
                    }
                    match give(host.tx, me) {
                        None => {
                            state.sessions += 1;
                            return Arrival::Paired;
                        }
                        Some(back) => me = back,
                    }
                }
                state.guests.push_back(slot);
                Arrival::Wait { id, rx, me }
            }
            Role::Host => {
                let mut me = Some(me);
                let mut kept = VecDeque::new();
                for guest in std::mem::take(&mut state.guests) {
                    if guest.gate != who.gate {
                        let _ = guest.tx.send(Wake::Rejected);
                    } else if let Some(peer) = me.take_if(|_| state.sessions < self.max_sessions) {
                        match give(guest.tx, peer) {
                            None => state.sessions += 1,
                            Some(back) => me = Some(back),
                        }
                    } else {
                        kept.push_back(guest);
                    }
                }
                state.guests = kept;
                let Some(me) = me else {
                    return Arrival::Paired;
                };
                state.host = Some(slot);
                Arrival::Wait { id, rx, me }
            }
        }
    }

    /// A waiter gives up. Whoever it was waiting for may have just arrived, so the caller
    /// checks its channel once more afterwards.
    pub fn leave(&self, room: &Key, id: u64) {
        let mut rooms = self.lock();
        if let Some(state) = rooms.get_mut(room) {
            if state.host.as_ref().is_some_and(|h| h.id == id) {
                state.host = None;
            }
            state.guests.retain(|g| g.id != id);
            if state.is_empty() {
                rooms.remove(room);
            }
        }
    }

    /// Drops every waiter, which tells each of them to say "nobody came".
    pub fn close_waiters(&self) {
        let mut rooms = self.lock();
        for state in rooms.values_mut() {
            state.host = None;
            state.guests.clear();
        }
        rooms.retain(|_, s| !s.is_empty());
    }
}

/// The side that was waiting takes over a session the arriving side already counted.
pub fn adopt(rooms: &Arc<Rooms>, room: Key) -> SessionGuard {
    SessionGuard {
        rooms: Arc::clone(rooms),
        room,
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        let mut rooms = self.rooms.lock();
        if let Some(state) = rooms.get_mut(&self.room) {
            state.sessions = state.sessions.saturating_sub(1);
            if state.is_empty() {
                rooms.remove(&self.room);
            }
        }
    }
}
