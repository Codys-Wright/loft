//! Screenshot post-processing for agents: an image plus the global logical
//! rectangle it shows, so every pixel maps back to a click coordinate —
//! crop, scale, a labeled coordinate grid, crosshair marks.

use image::imageops::FilterType;
use image::{Rgba, RgbaImage};

use crate::font;
use crate::niri::Rect;

pub struct Frame {
    pub img: RgbaImage,
    /// The global logical rectangle the image shows.
    pub region: Rect,
    /// Where that rectangle starts in the image: (0, 0), or past the rulers
    /// once a grid is drawn.
    pub origin: (u32, u32),
}

impl Frame {
    pub fn new(img: RgbaImage, region: Rect) -> Frame {
        Frame {
            img,
            region,
            origin: (0, 0),
        }
    }

    /// Image pixels per logical unit.
    pub fn scale(&self) -> f64 {
        (self.img.width() - self.origin.0) as f64 / self.region.w
    }

    /// Global logical → image pixel.
    pub fn to_px(&self, x: f64, y: f64) -> (f64, f64) {
        let s = self.scale();
        (
            (x - self.region.x) * s + self.origin.0 as f64,
            (y - self.region.y) * s + self.origin.1 as f64,
        )
    }

    /// Crop to a logical rectangle (intersected with the frame).
    pub fn crop(&self, r: Rect) -> Option<Frame> {
        let r = r.intersect(self.region)?;
        let (x0, y0) = self.to_px(r.x, r.y);
        let (x1, y1) = self.to_px(r.x + r.w, r.y + r.h);
        let (x0, y0) = (x0.floor().max(0.0) as u32, y0.floor().max(0.0) as u32);
        let x1 = (x1.ceil() as u32).min(self.img.width());
        let y1 = (y1.ceil() as u32).min(self.img.height());
        if x1 <= x0 || y1 <= y0 {
            return None;
        }
        let img = image::imageops::crop_imm(&self.img, x0, y0, x1 - x0, y1 - y0).to_image();
        Some(Frame::new(img, r))
    }

    /// Resize by `factor` (smooth downscale, sharp-ish upscale).
    pub fn resize(self, factor: f64) -> Frame {
        if (factor - 1.0).abs() < 1e-6 {
            return self;
        }
        let w = ((self.img.width() as f64 * factor).round() as u32).max(1);
        let h = ((self.img.height() as f64 * factor).round() as u32).max(1);
        let filter = if factor < 1.0 {
            FilterType::Triangle
        } else {
            FilterType::CatmullRom
        };
        let img = image::imageops::resize(&self.img, w, h, filter);
        Frame::new(img, self.region)
    }

    /// Downscale so the longer side is at most `max` pixels.
    pub fn fit_max(self, max: u32) -> Frame {
        let long = self.img.width().max(self.img.height());
        if long <= max || max == 0 {
            return self;
        }
        let f = max as f64 / long as f64;
        self.resize(f)
    }

    /// Upscale so the longer side is `target` pixels (for --zoom).
    pub fn grow_to(self, target: u32) -> Frame {
        let long = self.img.width().max(self.img.height());
        if long >= target || long == 0 {
            return self;
        }
        let f = target as f64 / long as f64;
        self.resize(f)
    }
}

fn blend(img: &mut RgbaImage, x: i64, y: i64, c: Rgba<u8>) {
    if x < 0 || y < 0 || x >= img.width() as i64 || y >= img.height() as i64 {
        return;
    }
    let p = img.get_pixel_mut(x as u32, y as u32);
    let a = c.0[3] as u32;
    for i in 0..3 {
        p.0[i] = ((c.0[i] as u32 * a + p.0[i] as u32 * (255 - a)) / 255) as u8;
    }
    p.0[3] = 255;
}

fn hline(img: &mut RgbaImage, y: i64, x0: i64, x1: i64, c: Rgba<u8>) {
    for x in x0..=x1 {
        blend(img, x, y, c);
    }
}

fn vline(img: &mut RgbaImage, x: i64, y0: i64, y1: i64, c: Rgba<u8>) {
    for y in y0..=y1 {
        blend(img, x, y, c);
    }
}

fn rect_fill(img: &mut RgbaImage, x: i64, y: i64, w: i64, h: i64, c: Rgba<u8>) {
    for yy in y..y + h {
        hline(img, yy, x, x + w - 1, c);
    }
}

/// A label on a dark plate; (x, y) is its top-left, clamped into the image.
pub fn label(img: &mut RgbaImage, x: i64, y: i64, text: &str, scale: u32, fg: Rgba<u8>) {
    let (tw, th) = font::measure(text, scale);
    let pad = scale as i64;
    let w = tw as i64 + 2 * pad;
    let h = th as i64 + 2 * pad;
    let x = x.clamp(0, (img.width() as i64 - w).max(0));
    let y = y.clamp(0, (img.height() as i64 - h).max(0));
    rect_fill(img, x, y, w, h, Rgba([0, 0, 0, 190]));
    font::raster(text, scale, |gx, gy| {
        blend(img, x + pad + gx as i64, y + pad + gy as i64, fg)
    });
}

/// Label size that stays readable: 2× on images over ~900 px.
pub fn label_scale(img: &RgbaImage) -> u32 {
    if img.width().max(img.height()) >= 900 {
        2
    } else {
        1
    }
}

/// A "nice" grid step (logical units) giving lines at least ~70 image px
/// apart and about 8–16 lines across the longer side.
pub fn auto_step(region: Rect, px_per_unit: f64) -> f64 {
    const NICE: [f64; 12] = [
        5.0, 10.0, 20.0, 25.0, 50.0, 100.0, 200.0, 250.0, 500.0, 1000.0, 2000.0, 5000.0,
    ];
    let long = region.w.max(region.h);
    NICE.iter()
        .copied()
        .find(|s| long / s <= 16.0 && s * px_per_unit >= 70.0)
        .unwrap_or(5000.0)
}

/// Lines every `step` logical units, with rulers added along the top and
/// left edges carrying the global coordinates — outside the picture, so no
/// label hides what's under it. Every other line is stronger.
pub fn draw_grid(f: &mut Frame, step: f64) {
    let s = f.scale();
    let r = f.region;
    let ls = label_scale(&f.img);
    let first = |lo: f64| (lo / step).ceil() as i64;
    let last = |hi: f64| (hi / step).floor() as i64;
    let xs: Vec<f64> = (first(r.x)..=last(r.x + r.w))
        .map(|i| i as f64 * step)
        .collect();
    let ys: Vec<f64> = (first(r.y)..=last(r.y + r.h))
        .map(|i| i as f64 * step)
        .collect();
    let (_, lh) = font::measure("0", ls);
    let widest = ys
        .iter()
        .map(|y| font::measure(&fmt_num(*y), ls).0)
        .max()
        .unwrap_or(0);
    let top = lh + 4 * ls;
    let left = widest + 4 * ls;

    // The canvas: rulers + the picture.
    let (cw, ch) = (f.img.width(), f.img.height());
    let mut img = RgbaImage::from_pixel(cw + left, ch + top, Rgba([24, 24, 28, 255]));
    image::imageops::replace(&mut img, &f.img, left as i64, top as i64);
    f.img = img;
    f.origin = (left, top);
    let (w, h) = (f.img.width() as i64, f.img.height() as i64);

    let major = Rgba([255, 40, 200, 170]);
    let minor = Rgba([255, 40, 200, 90]);
    let shadow = Rgba([0, 0, 0, 70]);
    let fg = Rgba([255, 230, 90, 255]);
    let tick = Rgba([255, 230, 90, 200]);
    for gx in &xs {
        let px = left as i64 + ((gx - r.x) * s).round() as i64;
        if px >= w {
            continue;
        }
        let c = if (gx / step).round() as i64 % 2 == 0 {
            major
        } else {
            minor
        };
        vline(&mut f.img, px + 1, top as i64, h - 1, shadow);
        vline(&mut f.img, px, top as i64, h - 1, c);
        vline(
            &mut f.img,
            px,
            top as i64 - 2 * ls as i64,
            top as i64 - 1,
            tick,
        );
        let t = fmt_num(*gx);
        let (tw, _) = font::measure(&t, ls);
        let lx = (px - tw as i64 / 2).clamp(left as i64, (w - tw as i64).max(0));
        font::raster(&t, ls, |x, y| {
            blend(&mut f.img, lx + x as i64, ls as i64 + y as i64, fg)
        });
    }
    for gy in &ys {
        let py = top as i64 + ((gy - r.y) * s).round() as i64;
        if py >= h {
            continue;
        }
        let c = if (gy / step).round() as i64 % 2 == 0 {
            major
        } else {
            minor
        };
        hline(&mut f.img, py + 1, left as i64, w - 1, shadow);
        hline(&mut f.img, py, left as i64, w - 1, c);
        hline(
            &mut f.img,
            py,
            left as i64 - 2 * ls as i64,
            left as i64 - 1,
            tick,
        );
        let t = fmt_num(*gy);
        let (tw, _) = font::measure(&t, ls);
        let ly = (py - lh as i64 / 2).clamp(top as i64, (h - lh as i64).max(0));
        font::raster(&t, ls, |x, y| {
            blend(
                &mut f.img,
                left as i64 - 3 * ls as i64 - tw as i64 + x as i64,
                ly + y as i64,
                fg,
            )
        });
    }
}

pub fn fmt_num(v: f64) -> String {
    if (v - v.round()).abs() < 1e-6 {
        format!("{}", v.round() as i64)
    } else {
        format!("{v:.1}")
    }
}

/// A crosshair + ring at global (x, y), labeled `x,y`. False if outside.
pub fn draw_mark(f: &mut Frame, x: f64, y: f64) -> bool {
    if !f.region.contains(x, y) {
        return false;
    }
    let (px, py) = f.to_px(x, y);
    let (px, py) = (px.round() as i64, py.round() as i64);
    let ls = label_scale(&f.img) as i64;
    let red = Rgba([255, 30, 30, 255]);
    let dark = Rgba([0, 0, 0, 200]);
    let arm = 14 * ls;
    let gap = 4 * ls;
    for (c, off) in [(dark, 1i64), (dark, -1), (red, 0)] {
        hline(&mut f.img, py + off, px - arm, px - gap, c);
        hline(&mut f.img, py + off, px + gap, px + arm, c);
        vline(&mut f.img, px + off, py - arm, py - gap, c);
        vline(&mut f.img, px + off, py + gap, py + arm, c);
    }
    // Ring.
    let rad = (9 * ls) as f64;
    let steps = 96;
    for i in 0..steps {
        let a = i as f64 / steps as f64 * std::f64::consts::TAU;
        let (cx, cy) = (px as f64 + rad * a.cos(), py as f64 + rad * a.sin());
        blend(&mut f.img, cx.round() as i64, cy.round() as i64, red);
    }
    blend(&mut f.img, px, py, red);
    let text = format!("{},{}", fmt_num(x), fmt_num(y));
    label(
        &mut f.img,
        px + arm + 3,
        py - arm - 2,
        &text,
        ls as u32,
        Rgba([255, 255, 255, 255]),
    );
    true
}

/// `X,Y`.
pub fn parse_point(s: &str) -> anyhow::Result<(f64, f64)> {
    let p: Vec<&str> = s.split([',', ' ']).filter(|p| !p.is_empty()).collect();
    match p[..] {
        [x, y] => Ok((x.trim().parse()?, y.trim().parse()?)),
        _ => anyhow::bail!("bad point `{s}` (want X,Y)"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(w: u32, h: u32, region: Rect) -> Frame {
        Frame::new(RgbaImage::from_pixel(w, h, Rgba([10, 20, 30, 255])), region)
    }

    #[test]
    fn maps_and_crops() {
        // A 2× (HiDPI) capture of 100,50 400x200.
        let f = frame(800, 400, Rect::new(100.0, 50.0, 400.0, 200.0));
        assert_eq!(f.scale(), 2.0);
        assert_eq!(f.to_px(150.0, 60.0), (100.0, 20.0));
        let c = f.crop(Rect::new(0.0, 0.0, 200.0, 100.0)).unwrap();
        assert_eq!(c.region, Rect::new(100.0, 50.0, 100.0, 50.0));
        assert_eq!(c.img.dimensions(), (200, 100));
        assert!(f.crop(Rect::new(0.0, 0.0, 50.0, 50.0)).is_none());
        let small = c.fit_max(50);
        assert_eq!(small.img.dimensions(), (50, 25));
        assert_eq!(small.scale(), 0.5);
        let big = small.grow_to(400);
        assert_eq!(big.img.dimensions(), (400, 200));
        assert_eq!(big.region, Rect::new(100.0, 50.0, 100.0, 50.0));
    }

    #[test]
    fn picks_grid_steps() {
        assert_eq!(auto_step(Rect::new(0.0, 0.0, 1600.0, 1000.0), 1.0), 100.0);
        assert_eq!(auto_step(Rect::new(0.0, 0.0, 9120.0, 2560.0), 0.17), 1000.0);
        assert_eq!(auto_step(Rect::new(0.0, 0.0, 200.0, 100.0), 8.0), 20.0);
    }

    #[test]
    fn draws_grid_and_marks_in_bounds() {
        let mut f = frame(1000, 600, Rect::new(-100.0, 0.0, 1000.0, 600.0));
        draw_grid(&mut f, 100.0);
        // Rulers on top and left; the picture keeps its scale.
        let (ox, oy) = f.origin;
        assert!(ox > 0 && oy > 0);
        assert_eq!(f.img.dimensions(), (1000 + ox, 600 + oy));
        assert_eq!(f.scale(), 1.0);
        assert_eq!(f.to_px(0.0, 0.0), (100.0 + ox as f64, oy as f64));
        // The x=0 line is 100 px into the picture.
        let p = f.img.get_pixel(100 + ox, 300);
        assert!(p.0[0] > 100, "{p:?}");
        assert!(draw_mark(&mut f, -95.0, 3.0));
        assert!(draw_mark(&mut f, 899.0, 599.0));
        assert!(!draw_mark(&mut f, 900.0, 10.0));
        assert_eq!(parse_point("12,34").unwrap(), (12.0, 34.0));
        assert!(parse_point("12").is_err());
        assert_eq!(fmt_num(1200.0), "1200");
        assert_eq!(fmt_num(-0.5), "-0.5");
    }
}
