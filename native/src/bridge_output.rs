use anyhow::{bail, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use super::transport::Event;

/// Incremental stdout framing persists across Eternal reconnect/replay boundaries.
#[derive(Default)]
pub(crate) struct BridgeOutput { buffer: Vec<u8> }
impl BridgeOutput {
    pub(crate) fn push(&mut self, bytes: &[u8]) -> Result<Vec<Event>> {
        if self.buffer.len() + bytes.len() > 2 * 1024 * 1024 + 65541 {
            bail!("Bridge output exceeds limit");
        }
        self.buffer.extend_from_slice(bytes);
        let mut consumed = 0;
        let mut events = Vec::new();
        while self.buffer.len() - consumed >= 5 {
            let header = &self.buffer[consumed..consumed + 5];
            let kind = header[0];
            let len = u32::from_be_bytes(header[1..5].try_into()?) as usize;
            if !matches!(kind, 1 | 2) || len > if kind == 1 { 65536 } else { 2 * 1024 * 1024 } {
                bail!("Invalid bridge output frame");
            }
            if self.buffer.len() - consumed < 5 + len { break; }
            let body = &self.buffer[consumed + 5..consumed + 5 + len];
            events.push(if kind == 1 { Event::Output { data: STANDARD.encode(body) } }
                else { Event::Directory { data: std::str::from_utf8(body)?.to_owned() } });
            consumed += 5 + len;
        }
        self.buffer.drain(..consumed);
        Ok(events)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame(kind: u8, data: &[u8]) -> Vec<u8> {
        let mut out = vec![kind];
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(data); out
    }
    #[test] fn fragmentation_coalescing_and_vt_are_separate() {
        let vt = b"\x1b]fake-directory\x07";
        let wire = [frame(1, vt), frame(2, b"{\"id\":\"test\"}"), frame(1, b"end")].concat();
        let mut decoder = BridgeOutput::default();
        let mut events = Vec::new();
        for byte in &wire { events.extend(decoder.push(&[*byte]).unwrap()); }
        assert_eq!(events.len(), 3);
        assert!(matches!(&events[0], Event::Output { data } if STANDARD.decode(data).unwrap() == vt));
        assert!(matches!(&events[1], Event::Directory { data } if data == "{\"id\":\"test\"}"));
        assert_eq!(BridgeOutput::default().push(&wire).unwrap().len(), 3);
    }
    #[test] fn rejects_invalid_kind_length_and_utf8() {
        for bytes in [vec![9, 0, 0, 0, 0], vec![1, 0, 1, 0, 1], vec![2, 0, 32, 0, 1], frame(2, &[255])] {
            assert!(BridgeOutput::default().push(&bytes).is_err());
        }
    }
}
