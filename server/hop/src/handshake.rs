//! Steps 1 to 3: hello, nonce, proof. The bytes and the proof rules are the core's (`imp_engine::link::hop`).

use imp_engine::link::hop::{HELLO_LEN, HopHello, NONCE_LEN, PROOF_LEN};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub type Key = [u8; 32];
pub use imp_engine::link::hop::HopRole as Role;

/// Who is at the door: a proven host of `room`, or a proven holder of `gate`'s key.
#[derive(Clone, Copy, Debug)]
pub struct Arrived {
    pub role: Role,
    pub room: Key,
    pub gate: Key,
}

/// Why the handshake ended without a proven client.
pub enum Failure {
    /// A bad hello or proof: the client gets `Rejected`.
    Rejected,
    /// The connection broke: nobody to tell.
    Closed,
}

impl From<std::io::Error> for Failure {
    fn from(_: std::io::Error) -> Self {
        Failure::Closed
    }
}

pub async fn run<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Result<Arrived, Failure> {
    let mut bytes = [0u8; HELLO_LEN];
    stream.read_exact(&mut bytes).await?;
    let hello = HopHello::parse(&bytes).ok_or(Failure::Rejected)?;

    let nonce: [u8; NONCE_LEN] = rand::random();
    stream.write_all(&nonce).await?;

    let mut proof = [0u8; PROOF_LEN];
    stream.read_exact(&mut proof).await?;
    if !hello.accepts(&nonce, &proof) {
        return Err(Failure::Rejected);
    }
    Ok(Arrived {
        role: hello.role,
        room: hello.room,
        gate: hello.gate,
    })
}
