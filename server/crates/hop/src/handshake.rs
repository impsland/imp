//! Steps 1 to 3: hello, nonce, proof.

use ed25519_dalek::{Signature, VerifyingKey};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::wire;

pub type Key = [u8; 32];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Host,
    Guest,
}

/// Who is at the door: a proven host of `room`, or a proven holder of `gate`'s key.
#[derive(Clone, Copy, Debug)]
pub struct Arrived {
    pub role: Role,
    pub room: Key,
    pub gate: Key,
}

pub enum Failure {
    /// A bad hello or proof: the client gets `0x01`.
    Rejected,
    /// The connection broke: nobody to tell.
    Closed,
}

impl From<std::io::Error> for Failure {
    fn from(_: std::io::Error) -> Self {
        Failure::Closed
    }
}

pub async fn run(stream: &mut TcpStream) -> Result<Arrived, Failure> {
    let mut hello = [0u8; wire::HELLO_LEN];
    stream.read_exact(&mut hello).await?;
    if &hello[..6] != wire::MAGIC || hello[6] != wire::VERSION {
        return Err(Failure::Rejected);
    }
    let role_byte = hello[7];
    let role = match role_byte {
        wire::HOST => Role::Host,
        wire::GUEST => Role::Guest,
        _ => return Err(Failure::Rejected),
    };
    let room: Key = hello[8..40].try_into().map_err(|_| Failure::Rejected)?;
    let gate: Key = hello[40..].try_into().map_err(|_| Failure::Rejected)?;
    // The host signs with the room key and names the gate. A guest signs with the gate key and names the room.
    let (signer, named) = match role {
        Role::Host => (&room, &gate),
        Role::Guest => (&gate, &room),
    };
    let key = VerifyingKey::from_bytes(signer).map_err(|_| Failure::Rejected)?;

    let nonce: [u8; wire::NONCE_LEN] = rand::random();
    stream.write_all(&nonce).await?;

    let mut proof = [0u8; wire::PROOF_LEN];
    stream.read_exact(&mut proof).await?;
    let mut message = Vec::with_capacity(wire::PROOF_PREFIX.len() + 1 + 32 + 32);
    message.extend_from_slice(wire::PROOF_PREFIX);
    message.push(role_byte);
    message.extend_from_slice(&nonce);
    message.extend_from_slice(named);
    key.verify_strict(&message, &Signature::from_bytes(&proof))
        .map_err(|_| Failure::Rejected)?;
    Ok(Arrived { role, room, gate })
}
