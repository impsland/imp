//! Reading QR codes from camera frames.

use imp_web::scan_qr;

/// A QR code of `text` as RGBA pixels, `scale` pixels per module, with a quiet zone.
fn frame(text: &str, scale: usize) -> (Vec<u8>, u32, u32) {
    let code = qrcode::QrCode::new(text.as_bytes()).unwrap();
    let n = code.width();
    let side = (n + 8) * scale;
    let mut rgba = vec![255u8; side * side * 4];
    for (i, color) in code.to_colors().iter().enumerate() {
        if *color != qrcode::Color::Dark {
            continue;
        }
        for dy in 0..scale {
            for dx in 0..scale {
                let x = (i % n + 4) * scale + dx;
                let y = (i / n + 4) * scale + dy;
                rgba[(y * side + x) * 4..][..3].fill(0);
            }
        }
    }
    (rgba, side as u32, side as u32)
}

#[test]
fn reads_a_linking_code() {
    let text = "implink://join?d=abc";
    let (rgba, w, h) = frame(text, 6);
    assert_eq!(scan_qr(&rgba, w, h).as_deref(), Some(text));
}

#[test]
fn noise_and_bad_sizes_give_nothing() {
    let mut seed = 12345u32;
    let noise: Vec<u8> = (0..200 * 200 * 4)
        .map(|_| {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            (seed >> 24) as u8
        })
        .collect();
    assert_eq!(scan_qr(&noise, 200, 200), None);
    let (rgba, w, h) = frame("implink://join?d=abc", 6);
    assert_eq!(scan_qr(&rgba[1..], w, h), None);
    assert_eq!(scan_qr(&rgba, w + 1, h), None);
    assert_eq!(scan_qr(&[], 0, 0), None);
    assert_eq!(scan_qr(&rgba, 0, h), None);
    assert_eq!(scan_qr(&rgba, u32::MAX, u32::MAX), None);
}
