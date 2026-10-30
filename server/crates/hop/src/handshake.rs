//! Steps 1 to 3: hello, nonce, proof.

use ed25519_dalek::{Signature, VerifyingKey};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::wire;

pub type Room = [u8; 32];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Mac,
    Phone,
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

pub async fn run(stream: &mut TcpStream) -> Result<(Room, Role), Failure> {
    let mut hello = [0u8; wire::HELLO_LEN];
    stream.read_exact(&mut hello).await?;
    if &hello[..6] != wire::MAGIC || hello[6] != wire::VERSION {
        return Err(Failure::Rejected);
    }
    let role_byte = hello[7];
    let role = match role_byte {
        wire::MAC => Role::Mac,
        wire::PHONE => Role::Phone,
        _ => return Err(Failure::Rejected),
    };
    let mut room = [0u8; 32];
    room.copy_from_slice(&hello[8..]);
    let key = VerifyingKey::from_bytes(&room).map_err(|_| Failure::Rejected)?;

    let nonce: [u8; wire::NONCE_LEN] = rand::random();
    stream.write_all(&nonce).await?;

    let mut proof = [0u8; wire::PROOF_LEN];
    stream.read_exact(&mut proof).await?;
    let mut message = Vec::with_capacity(wire::PROOF_PREFIX.len() + 1 + nonce.len());
    message.extend_from_slice(wire::PROOF_PREFIX);
    message.push(role_byte);
    message.extend_from_slice(&nonce);
    key.verify_strict(&message, &Signature::from_bytes(&proof))
        .map_err(|_| Failure::Rejected)?;
    Ok((room, role))
}
