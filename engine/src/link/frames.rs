//! The frames messages travel in: 4 bytes of length, big endian, then that many bytes of JSON. The frame
//! stream itself is carried by the encrypted chunks of `noise`.

/// The biggest frame body in bytes.
pub const MAX_FRAME: usize = 4 << 20;

/// A frame cannot be sent or read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum FrameError {
    #[error("a frame of {0} bytes is bigger than any frame may be")]
    TooBig(usize),
    #[error("the message has no JSON form")]
    Unencodable,
}

/// Wraps a body in a frame: 4 bytes of length, big endian, then the body.
pub fn encode_frame(body: &[u8]) -> Result<Vec<u8>, FrameError> {
    if body.len() > MAX_FRAME {
        return Err(FrameError::TooBig(body.len()));
    }
    let length = u32::try_from(body.len()).map_err(|_| FrameError::TooBig(body.len()))?;
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(body);
    Ok(frame)
}

/// Collects bytes as they arrive and hands back whole frame bodies.
#[derive(Debug, Default)]
pub struct FrameReader {
    buffer: Vec<u8>,
}

impl FrameReader {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds bytes and returns every complete frame body. An error means a broken or hostile peer
    /// and the connection should be dropped.
    pub fn feed(&mut self, data: &[u8]) -> Result<Vec<Vec<u8>>, FrameError> {
        self.buffer.extend_from_slice(data);
        let mut frames = Vec::new();
        let mut start = 0;
        while self.buffer.len() - start >= 4 {
            let head = &self.buffer[start..start + 4];
            let length = u32::from_be_bytes([head[0], head[1], head[2], head[3]]) as usize;
            if length > MAX_FRAME {
                return Err(FrameError::TooBig(length));
            }
            if self.buffer.len() - start < 4 + length {
                break;
            }
            frames.push(self.buffer[start + 4..start + 4 + length].to_vec());
            start += 4 + length;
        }
        self.buffer.drain(..start);
        Ok(frames)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_split_and_join() {
        let one = encode_frame(b"{\"ping\":{}}").unwrap();
        let two = encode_frame(b"{\"pong\":{}}").unwrap();
        let all = [one.clone(), two.clone()].concat();
        let mut reader = FrameReader::new();
        let mut got = Vec::new();
        for byte in &all {
            got.extend(reader.feed(&[*byte]).unwrap());
        }
        assert_eq!(
            got,
            vec![b"{\"ping\":{}}".to_vec(), b"{\"pong\":{}}".to_vec()]
        );
        assert_eq!(FrameReader::new().feed(&all).unwrap().len(), 2);
        assert_eq!(one[..4], [0, 0, 0, 11]);
    }

    #[test]
    fn frames_have_a_ceiling() {
        let mut reader = FrameReader::new();
        let too_big = u32::try_from(MAX_FRAME + 1).unwrap().to_be_bytes();
        assert_eq!(
            reader.feed(&too_big),
            Err(FrameError::TooBig(MAX_FRAME + 1))
        );
        assert!(encode_frame(&vec![0; MAX_FRAME + 1]).is_err());
        assert!(encode_frame(&vec![0; MAX_FRAME]).is_ok());
    }
}
