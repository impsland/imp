//! Putting text on the system clipboard: with the system's own program (`pbcopy`, `wl-copy`, `xclip`,
//! `xsel`, `clip`), or else by asking the terminal with the OSC 52 sequence, which also works over SSH
//! in most terminals (iTerm2, kitty, WezTerm, Ghostty, Alacritty, Windows Terminal, tmux).

use std::io::Write;
use std::process::{Command, Stdio};

/// Copies `text`. Over SSH the terminal is asked, since the programs here would fill the clipboard of
/// the far computer.
pub fn copy(text: &str) {
    let remote =
        std::env::var_os("SSH_CONNECTION").is_some() || std::env::var_os("SSH_TTY").is_some();
    if remote || !with_program(text) {
        let _ = with_terminal(text);
    }
}

fn with_program(text: &str) -> bool {
    let programs: &[(&str, &[&str])] = if cfg!(target_os = "macos") {
        &[("pbcopy", &[])]
    } else if cfg!(windows) {
        &[("clip", &[])]
    } else {
        &[
            ("wl-copy", &[]),
            ("xclip", &["-selection", "clipboard"]),
            ("xsel", &["--clipboard", "--input"]),
        ]
    };
    programs.iter().any(|(program, args)| {
        let Ok(mut child) = Command::new(program)
            .args(*args)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        else {
            return false;
        };
        let written = child
            .stdin
            .take()
            .is_some_and(|mut stdin| stdin.write_all(text.as_bytes()).is_ok());
        written && child.wait().is_ok_and(|s| s.success())
    })
}

fn with_terminal(text: &str) -> std::io::Result<()> {
    let mut out = std::io::stdout();
    out.write_all(osc52(text, std::env::var_os("TMUX").is_some()).as_bytes())?;
    out.flush()
}

/// The OSC 52 sequence that sets the clipboard to `text`, wrapped for tmux to pass on.
pub fn osc52(text: &str, tmux: bool) -> String {
    let set = format!("\x1b]52;c;{}\x07", base64(text.as_bytes()));
    if tmux {
        format!("\x1bPtmux;{}\x1b\\", set.replace('\x1b', "\x1b\x1b"))
    } else {
        set
    }
}

/// Standard base64 with padding.
fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(TABLE[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_and_the_terminal_sequence() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64("héllo".as_bytes()), "aMOpbGxv");
        assert_eq!(osc52("hi", false), "\x1b]52;c;aGk=\x07");
        assert_eq!(osc52("hi", true), "\x1bPtmux;\x1b\x1b]52;c;aGk=\x07\x1b\\");
    }
}
