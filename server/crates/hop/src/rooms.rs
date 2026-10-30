//! Rooms: who is waiting, and how many sessions are live.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::oneshot;

use crate::handshake::{Role, Room};
use crate::limits::ConnGuard;

/// A connection that has passed the handshake.
pub struct Peer {
    pub stream: tokio::net::TcpStream,
    pub conn: ConnGuard,
}

type Slot = (u64, oneshot::Sender<Peer>);

#[derive(Default)]
struct State {
    mac: Option<Slot>,
    phones: VecDeque<Slot>,
    sessions: usize,
}

impl State {
    fn is_empty(&self) -> bool {
        self.mac.is_none() && self.phones.is_empty() && self.sessions == 0
    }
}

pub struct Rooms {
    rooms: Mutex<HashMap<Room, State>>,
    next_id: Mutex<u64>,
    max_sessions: usize,
}

pub enum Arrival {
    /// The other side was waiting and has the connection now.
    Paired,
    /// Nobody there yet: the caller waits on `rx` and keeps its connection.
    Wait {
        id: u64,
        rx: oneshot::Receiver<Peer>,
        me: Peer,
    },
    /// The room is full.
    Busy(Peer),
}

/// One live session in a room. Dropping it frees the place.
pub struct SessionGuard {
    rooms: Arc<Rooms>,
    room: Room,
}

impl Rooms {
    pub fn new(max_sessions: usize) -> Arc<Self> {
        Arc::new(Self {
            rooms: Mutex::default(),
            next_id: Mutex::new(0),
            max_sessions,
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<Room, State>> {
        self.rooms.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn fresh_id(&self) -> u64 {
        let mut id = self.next_id.lock().unwrap_or_else(PoisonError::into_inner);
        *id += 1;
        *id
    }

    /// A Mac or an iPhone shows up. If the other side is waiting it gets `me` and a session starts.
    /// Otherwise the caller waits. A new Mac replaces the Mac that was waiting.
    pub fn arrive(&self, room: Room, role: Role, mut me: Peer) -> Arrival {
        let id = self.fresh_id();
        let mut rooms = self.lock();
        let state = rooms.entry(room).or_default();
        let full = state.sessions >= self.max_sessions;
        if full && role == Role::Phone {
            return Arrival::Busy(me);
        }
        while !(state.sessions >= self.max_sessions) {
            let waiting = match role {
                Role::Phone => state.mac.take(),
                Role::Mac => state.phones.pop_front(),
            };
            let Some((_, tx)) = waiting else { break };
            match tx.send(me) {
                Ok(()) => {
                    state.sessions += 1;
                    return Arrival::Paired;
                }
                Err(back) => me = back,
            }
        }
        let (tx, rx) = oneshot::channel();
        match role {
            Role::Mac => state.mac = Some((id, tx)),
            Role::Phone => state.phones.push_back((id, tx)),
        }
        Arrival::Wait { id, rx, me }
    }

    /// A waiter gives up. Whoever it was waiting for may have just arrived, so the caller
    /// checks its channel once more afterwards.
    pub fn leave(&self, room: &Room, id: u64) {
        let mut rooms = self.lock();
        if let Some(state) = rooms.get_mut(room) {
            if state.mac.as_ref().is_some_and(|(i, _)| *i == id) {
                state.mac = None;
            }
            state.phones.retain(|(i, _)| *i != id);
            if state.is_empty() {
                rooms.remove(room);
            }
        }
    }

    /// Drops every waiter, which tells each of them to say "nobody came".
    pub fn close_waiters(&self) {
        let mut rooms = self.lock();
        for state in rooms.values_mut() {
            state.mac = None;
            state.phones.clear();
        }
        rooms.retain(|_, s| !s.is_empty());
    }
}

/// The side that was waiting takes over a session the arriving side already counted.
pub fn adopt(rooms: &Arc<Rooms>, room: Room) -> SessionGuard {
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
