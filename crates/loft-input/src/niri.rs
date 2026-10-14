//! The target session's niri, over its IPC socket: output layout (for
//! absolute pointer coordinates), windows and layer surfaces with their
//! geometry in global logical coordinates.

use std::path::Path;

use anyhow::{Context, Result, bail};
use niri_ipc::socket::Socket;
use niri_ipc::{Action, LayerSurface, Request, Response, Window, Workspace};
use serde::Serialize;

/// A rectangle in global logical coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }

    /// `X,Y,W,H` (also `X,Y WxH`, grim/slurp style).
    pub fn parse(s: &str) -> Result<Rect> {
        let nums: Vec<f64> = s
            .split([',', ' ', 'x'])
            .filter(|p| !p.is_empty())
            .map(|p| p.trim().parse::<f64>())
            .collect::<std::result::Result<_, _>>()
            .with_context(|| format!("bad rectangle `{s}` (want X,Y,W,H)"))?;
        match nums[..] {
            [x, y, w, h] if w > 0.0 && h > 0.0 => Ok(Rect { x, y, w, h }),
            _ => bail!("bad rectangle `{s}` (want X,Y,W,H with positive W,H)"),
        }
    }

    pub fn union(self, o: Rect) -> Rect {
        let x = self.x.min(o.x);
        let y = self.y.min(o.y);
        let r = (self.x + self.w).max(o.x + o.w);
        let b = (self.y + self.h).max(o.y + o.h);
        Rect::new(x, y, r - x, b - y)
    }

    pub fn intersect(self, o: Rect) -> Option<Rect> {
        let x = self.x.max(o.x);
        let y = self.y.max(o.y);
        let r = (self.x + self.w).min(o.x + o.w);
        let b = (self.y + self.h).min(o.y + o.h);
        (r > x && b > y).then(|| Rect::new(x, y, r - x, b - y))
    }

    pub fn contains(self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }

    pub fn center(self) -> (f64, f64) {
        (self.x + self.w / 2.0, self.y + self.h / 2.0)
    }

    /// grim's `-g` syntax.
    pub fn grim(self) -> String {
        format!(
            "{},{} {}x{}",
            self.x.round() as i64,
            self.y.round() as i64,
            self.w.round().max(1.0) as i64,
            self.h.round().max(1.0) as i64
        )
    }
}

impl std::fmt::Display for Rect {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{},{} {}x{}", self.x, self.y, self.w, self.h)
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct OutputRect {
    pub name: String,
    pub rect: Rect,
    pub scale: f64,
    pub transform: String,
}

pub struct Niri {
    socket: std::path::PathBuf,
}

impl Niri {
    pub fn new(socket: &Path) -> Niri {
        Niri {
            socket: socket.to_path_buf(),
        }
    }

    pub fn request(&self, req: Request) -> Result<Response> {
        let mut sock = Socket::connect_to(&self.socket)
            .with_context(|| format!("connecting to niri at {}", self.socket.display()))?;
        match sock.send(req).context("talking to niri")? {
            Ok(r) => Ok(r),
            Err(e) => bail!("niri: {e}"),
        }
    }

    pub fn action(&self, action: Action) -> Result<()> {
        self.request(Request::Action(action)).map(|_| ())
    }

    /// Enabled outputs, left to right.
    pub fn outputs(&self) -> Result<Vec<OutputRect>> {
        let Response::Outputs(map) = self.request(Request::Outputs)? else {
            bail!("unexpected reply to Outputs");
        };
        let mut out: Vec<OutputRect> = map
            .into_values()
            .filter_map(|o| {
                let l = o.logical?;
                Some(OutputRect {
                    name: o.name,
                    rect: Rect::new(l.x as f64, l.y as f64, l.width as f64, l.height as f64),
                    scale: l.scale,
                    transform: format!("{:?}", l.transform),
                })
            })
            .collect();
        out.sort_by(|a, b| {
            (a.rect.x, a.rect.y)
                .partial_cmp(&(b.rect.x, b.rect.y))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        if out.is_empty() {
            bail!("niri reports no enabled outputs");
        }
        Ok(out)
    }

    pub fn windows(&self) -> Result<Vec<Window>> {
        match self.request(Request::Windows)? {
            Response::Windows(w) => Ok(w),
            _ => bail!("unexpected reply to Windows"),
        }
    }

    pub fn workspaces(&self) -> Result<Vec<Workspace>> {
        match self.request(Request::Workspaces)? {
            Response::Workspaces(w) => Ok(w),
            _ => bail!("unexpected reply to Workspaces"),
        }
    }

    pub fn layers(&self) -> Result<Vec<LayerSurface>> {
        match self.request(Request::Layers)? {
            Response::Layers(l) => Ok(l),
            _ => bail!("unexpected reply to Layers"),
        }
    }
}

/// The bounding box of all outputs: what an absolute virtual-pointer motion
/// without an output maps onto.
pub fn bounding(outputs: &[OutputRect]) -> Rect {
    outputs
        .iter()
        .map(|o| o.rect)
        .reduce(Rect::union)
        .unwrap_or(Rect::new(0.0, 0.0, 1.0, 1.0))
}

pub fn find_output<'a>(outputs: &'a [OutputRect], name: &str) -> Result<&'a OutputRect> {
    outputs
        .iter()
        .find(|o| o.name.eq_ignore_ascii_case(name))
        .with_context(|| {
            format!(
                "no output `{name}` (have: {})",
                outputs
                    .iter()
                    .map(|o| o.name.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })
}

/// A window's visual geometry in global logical coordinates. niri 26.04
/// reports positions only for floating windows on a visible workspace —
/// None otherwise (tiled windows: use loft-shot --window-render, or read
/// the position off a gridded screenshot).
pub fn window_rect(w: &Window, workspaces: &[Workspace], outputs: &[OutputRect]) -> Option<Rect> {
    let (tx, ty) = w.layout.tile_pos_in_workspace_view?;
    let ws = workspaces.iter().find(|ws| Some(ws.id) == w.workspace_id)?;
    let out = outputs
        .iter()
        .find(|o| Some(&o.name) == ws.output.as_ref())?;
    let (ox, oy) = w.layout.window_offset_in_tile;
    let (ww, wh) = w.layout.window_size;
    Some(Rect::new(
        out.rect.x + tx + ox,
        out.rect.y + ty + oy,
        ww as f64,
        wh as f64,
    ))
}

/// Find a window by id, exact app id, exact title, then app-id/title
/// substring (case-insensitive). Prefers the focused one on ties.
pub fn find_window<'a>(windows: &'a [Window], query: &str) -> Result<&'a Window> {
    if let Ok(id) = query.trim_start_matches('#').parse::<u64>()
        && let Some(w) = windows.iter().find(|w| w.id == id)
    {
        return Ok(w);
    }
    let q = query.to_lowercase();
    let pick = |pred: &dyn Fn(&Window) -> bool| -> Option<&'a Window> {
        let mut m: Vec<&Window> = windows.iter().filter(|w| pred(w)).collect();
        m.sort_by_key(|w| !w.is_focused);
        m.first().copied()
    };
    let app = |w: &Window| w.app_id.clone().unwrap_or_default().to_lowercase();
    let title = |w: &Window| w.title.clone().unwrap_or_default().to_lowercase();
    pick(&|w| app(w) == q)
        .or_else(|| pick(&|w| title(w) == q))
        .or_else(|| pick(&|w| app(w).contains(&q) || title(w).contains(&q)))
        .with_context(|| {
            format!(
                "no window matches `{query}` (have: {})",
                windows
                    .iter()
                    .map(|w| format!("#{} {}", w.id, w.app_id.as_deref().unwrap_or("?")))
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rects() {
        let r = Rect::parse("10,20,300,400").unwrap();
        assert_eq!(r, Rect::new(10.0, 20.0, 300.0, 400.0));
        assert_eq!(Rect::parse("10,20 300x400").unwrap(), r);
        assert!(Rect::parse("1,2,3").is_err());
        assert!(Rect::parse("1,2,0,4").is_err());
        assert_eq!(r.grim(), "10,20 300x400");
        let u = r.union(Rect::new(0.0, 0.0, 20.0, 20.0));
        assert_eq!(u, Rect::new(0.0, 0.0, 310.0, 420.0));
        assert_eq!(
            r.intersect(Rect::new(0.0, 0.0, 50.0, 50.0)),
            Some(Rect::new(10.0, 20.0, 40.0, 30.0))
        );
        assert_eq!(r.intersect(Rect::new(0.0, 0.0, 5.0, 5.0)), None);
    }

    #[test]
    fn bounding_box_spans_outputs() {
        let o = |name: &str, x, y, w, h| OutputRect {
            name: name.into(),
            rect: Rect::new(x, y, w, h),
            scale: 1.0,
            transform: "Normal".into(),
        };
        let outs = vec![
            o("DP-5", 0.0, 0.0, 1440.0, 2560.0),
            o("DP-4", 1440.0, 0.0, 5120.0, 1440.0),
            o("DP-3", 6560.0, 0.0, 2560.0, 1440.0),
        ];
        assert_eq!(bounding(&outs), Rect::new(0.0, 0.0, 9120.0, 2560.0));
        assert_eq!(find_output(&outs, "dp-3").unwrap().rect.x, 6560.0);
        assert!(find_output(&outs, "HDMI-1").is_err());
    }
}
