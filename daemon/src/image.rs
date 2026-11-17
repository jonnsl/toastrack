//! Raw image-data hints, encoded as PNG for storage.

pub struct Raw {
    pub width: i32,
    pub height: i32,
    pub rowstride: i32,
    pub has_alpha: bool,
    pub bits_per_sample: i32,
    pub channels: i32,
    pub data: Vec<u8>,
}

/// Larger images are dropped rather than stored
const MAX_SIDE: i32 = 2048;

pub fn to_png(raw: &Raw) -> Option<Vec<u8>> {
    if raw.bits_per_sample != 8 || raw.width <= 0 || raw.height <= 0 || raw.width > MAX_SIDE || raw.height > MAX_SIDE {
        return None;
    }
    let color = match (raw.channels, raw.has_alpha) {
        (4, true) => png::ColorType::Rgba,
        (3, false) => png::ColorType::Rgb,
        _ => return None,
    };
    let (width, height, channels) = (raw.width as usize, raw.height as usize, raw.channels as usize);
    let row_len = width * channels;
    let rowstride = raw.rowstride as usize;
    // The last row may be unpadded
    if rowstride < row_len || raw.data.len() < rowstride * (height - 1) + row_len {
        return None;
    }
    let mut pixels = Vec::with_capacity(row_len * height);
    for row in 0..height {
        pixels.extend_from_slice(&raw.data[row * rowstride..row * rowstride + row_len]);
    }

    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, raw.width as u32, raw.height as u32);
    encoder.set_color(color);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().ok()?;
    writer.write_image_data(&pixels).ok()?;
    writer.finish().ok()?;
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn padded_rows() {
        // 1x2 RGB with rows padded to 4 bytes, last row unpadded
        let raw = Raw {
            width: 1,
            height: 2,
            rowstride: 4,
            has_alpha: false,
            bits_per_sample: 8,
            channels: 3,
            data: vec![1, 2, 3, 0, 4, 5, 6],
        };
        let png = to_png(&raw).unwrap();
        let decoder = png::Decoder::new(std::io::Cursor::new(png));
        let mut reader = decoder.read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size().unwrap()];
        reader.next_frame(&mut buf).unwrap();
        assert_eq!(buf, vec![1, 2, 3, 4, 5, 6]);
    }

    #[test]
    fn rejects_short_data() {
        let raw = Raw {
            width: 2,
            height: 2,
            rowstride: 8,
            has_alpha: true,
            bits_per_sample: 8,
            channels: 4,
            data: vec![0; 10],
        };
        assert!(to_png(&raw).is_none());
    }
}
