//! A 5×7 bitmap font for coordinate labels (digits and `,-.x:`), so grid
//! and mark labels need no font files.

/// Rows of 5 bits, top to bottom, MSB = leftmost column.
fn glyph(c: char) -> Option<[u8; 7]> {
    Some(match c {
        '0' => [0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e],
        '1' => [0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e],
        '2' => [0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f],
        '3' => [0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e],
        '4' => [0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02],
        '5' => [0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e],
        '6' => [0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e],
        '7' => [0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        '8' => [0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e],
        '9' => [0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c],
        ',' => [0x00, 0x00, 0x00, 0x00, 0x06, 0x04, 0x08],
        '-' => [0x00, 0x00, 0x00, 0x1f, 0x00, 0x00, 0x00],
        '.' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x0c],
        'x' => [0x00, 0x00, 0x11, 0x0a, 0x04, 0x0a, 0x11],
        ':' => [0x00, 0x0c, 0x0c, 0x00, 0x0c, 0x0c, 0x00],
        ' ' => [0; 7],
        _ => return None,
    })
}

pub const W: u32 = 5;
pub const H: u32 = 7;

/// Size in pixels of `text` at integer `scale` (1 px gap between glyphs).
pub fn measure(text: &str, scale: u32) -> (u32, u32) {
    let n = text.chars().count() as u32;
    if n == 0 {
        return (0, 0);
    }
    ((n * (W + 1) - 1) * scale, H * scale)
}

/// Call `put(x, y)` for every lit pixel of `text` drawn at (0, 0).
pub fn raster(text: &str, scale: u32, mut put: impl FnMut(u32, u32)) {
    for (i, c) in text.chars().enumerate() {
        let Some(g) = glyph(c).or_else(|| glyph('-')) else {
            continue;
        };
        let ox = i as u32 * (W + 1) * scale;
        for (row, bits) in g.iter().enumerate() {
            for col in 0..W {
                if bits & (1 << (W - 1 - col)) != 0 {
                    for dy in 0..scale {
                        for dx in 0..scale {
                            put(ox + col * scale + dx, row as u32 * scale + dy);
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn measures_and_rasters() {
        assert_eq!(measure("120", 1), (17, 7));
        assert_eq!(measure("120", 2), (34, 14));
        let mut n = 0;
        raster("1", 1, |x, y| {
            assert!(x < W && y < H);
            n += 1;
        });
        assert_eq!(n, 10);
        // Unknown characters draw as a dash rather than vanishing.
        let mut m = 0;
        raster("?", 1, |_, _| m += 1);
        assert_eq!(m, 5);
    }
}
