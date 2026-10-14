//! Where events go: the Wayland virtual-input protocols (the default; one
//! session, no root, nested or live), or uinput (the whole seat of the live
//! desktop — gated behind `--uinput --yes-live`).

use std::io::Write as _;
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::time::Instant;

use anyhow::{Context, Result, bail};
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{wl_keyboard, wl_pointer, wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle, delegate_noop};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
    zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1,
};

use crate::niri::Rect;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    Vertical,
    Horizontal,
}

pub trait Backend {
    /// Absolute motion to global logical (x, y); `bounds` is the bounding box
    /// of all outputs.
    fn motion_abs(&mut self, x: f64, y: f64, bounds: Rect) -> Result<()>;
    fn motion_rel(&mut self, dx: f64, dy: f64) -> Result<()>;
    /// Linux BTN_* code.
    fn button(&mut self, code: u32, pressed: bool) -> Result<()>;
    /// One wheel notch (discrete) or `amount` pixels of smooth scrolling;
    /// positive is down / right.
    fn wheel(&mut self, axis: Axis, notches: i32) -> Result<()>;
    fn smooth_scroll(&mut self, axis: Axis, pixels: f64, last: bool) -> Result<()>;
    /// evdev key code.
    fn key(&mut self, code: u32, pressed: bool) -> Result<()>;
    /// Real-modifier mask (Shift 1, Control 4, Mod1 8, Mod4 64, Mod5 128).
    fn modifiers(&mut self, mask: u32) -> Result<()>;
    /// Send everything queued; wait until the compositor has processed it.
    fn sync(&mut self) -> Result<()>;
}

// --- Wayland -----------------------------------------------------------------

struct State;

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

delegate_noop!(State: ignore wl_seat::WlSeat);
delegate_noop!(State: ZwlrVirtualPointerManagerV1);
delegate_noop!(State: ZwlrVirtualPointerV1);
delegate_noop!(State: ZwpVirtualKeyboardManagerV1);
delegate_noop!(State: ZwpVirtualKeyboardV1);

pub struct Wayland {
    conn: Connection,
    queue: EventQueue<State>,
    pointer: Option<ZwlrVirtualPointerV1>,
    keyboard: Option<ZwpVirtualKeyboardV1>,
    start: Instant,
}

impl Wayland {
    /// Connect to the Wayland socket at `path`; create a virtual pointer
    /// and/or keyboard (the keyboard with `keymap`).
    pub fn connect(
        path: &std::path::Path,
        want_pointer: bool,
        keymap: Option<&str>,
    ) -> Result<Wayland> {
        let stream = UnixStream::connect(path)
            .with_context(|| format!("connecting to Wayland socket {}", path.display()))?;
        let conn = Connection::from_socket(stream).context("Wayland handshake")?;
        let (globals, mut queue) =
            registry_queue_init::<State>(&conn).context("reading Wayland globals")?;
        let qh = queue.handle();
        let seat: wl_seat::WlSeat = globals
            .bind(&qh, 1..=7, ())
            .context("the compositor has no wl_seat")?;
        let pointer = if want_pointer {
            let mgr: ZwlrVirtualPointerManagerV1 = globals.bind(&qh, 1..=2, ()).context(
                "the compositor does not offer zwlr_virtual_pointer_manager_v1 (virtual pointer)",
            )?;
            Some(mgr.create_virtual_pointer(Some(&seat), &qh, ()))
        } else {
            None
        };
        let keyboard = match keymap {
            Some(km) => {
                let mgr: ZwpVirtualKeyboardManagerV1 = globals.bind(&qh, 1..=1, ()).context(
                    "the compositor does not offer zwp_virtual_keyboard_manager_v1 (virtual keyboard)",
                )?;
                let kb = mgr.create_virtual_keyboard(&seat, &qh, ());
                let fd = keymap_fd(km)?;
                kb.keymap(
                    wl_keyboard::KeymapFormat::XkbV1 as u32,
                    fd.as_fd(),
                    km.len() as u32 + 1,
                );
                Some(kb)
            }
            None => None,
        };
        let mut s = State;
        queue
            .roundtrip(&mut s)
            .context("the compositor rejected the virtual devices")?;
        Ok(Wayland {
            conn,
            queue,
            pointer,
            keyboard,
            start: Instant::now(),
        })
    }

    fn time(&self) -> u32 {
        self.start.elapsed().as_millis() as u32
    }

    fn ptr(&self) -> Result<&ZwlrVirtualPointerV1> {
        self.pointer.as_ref().context("no virtual pointer")
    }

    fn kb(&self) -> Result<&ZwpVirtualKeyboardV1> {
        self.keyboard.as_ref().context("no virtual keyboard")
    }

    fn flush(&self) -> Result<()> {
        self.conn
            .flush()
            .context("Wayland connection lost (did the compositor reject the keymap?)")
    }
}

fn keymap_fd(km: &str) -> Result<OwnedFd> {
    // SAFETY: plain syscall; the fd is owned right after.
    let raw = unsafe { libc::memfd_create(c"loft-input-keymap".as_ptr(), libc::MFD_CLOEXEC) };
    if raw < 0 {
        bail!("memfd_create: {}", std::io::Error::last_os_error());
    }
    // SAFETY: raw is a fresh, valid fd we own.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let mut f = std::fs::File::from(fd.try_clone()?);
    f.write_all(km.as_bytes())?;
    f.write_all(&[0])?;
    Ok(fd)
}

fn wl_axis(a: Axis) -> wl_pointer::Axis {
    match a {
        Axis::Vertical => wl_pointer::Axis::VerticalScroll,
        Axis::Horizontal => wl_pointer::Axis::HorizontalScroll,
    }
}

impl Backend for Wayland {
    fn motion_abs(&mut self, x: f64, y: f64, b: Rect) -> Result<()> {
        // niri maps (x / x_extent) onto the bounding box of all outputs when
        // the virtual pointer has no output. Extents in 1/4 logical pixels.
        const SUB: f64 = 4.0;
        let ext_w = (b.w * SUB).round().max(1.0);
        let ext_h = (b.h * SUB).round().max(1.0);
        let px = ((x - b.x) * SUB).round().clamp(0.0, ext_w - 1.0);
        let py = ((y - b.y) * SUB).round().clamp(0.0, ext_h - 1.0);
        let t = self.time();
        let p = self.ptr()?;
        p.motion_absolute(t, px as u32, py as u32, ext_w as u32, ext_h as u32);
        p.frame();
        self.flush()
    }

    fn motion_rel(&mut self, dx: f64, dy: f64) -> Result<()> {
        let t = self.time();
        let p = self.ptr()?;
        p.motion(t, dx, dy);
        p.frame();
        self.flush()
    }

    fn button(&mut self, code: u32, pressed: bool) -> Result<()> {
        let t = self.time();
        let p = self.ptr()?;
        p.button(
            t,
            code,
            if pressed {
                wl_pointer::ButtonState::Pressed
            } else {
                wl_pointer::ButtonState::Released
            },
        );
        p.frame();
        self.flush()
    }

    fn wheel(&mut self, axis: Axis, notches: i32) -> Result<()> {
        let t = self.time();
        let p = self.ptr()?;
        p.axis_source(wl_pointer::AxisSource::Wheel);
        p.axis_discrete(t, wl_axis(axis), 15.0 * notches as f64, notches);
        p.frame();
        self.flush()
    }

    fn smooth_scroll(&mut self, axis: Axis, pixels: f64, last: bool) -> Result<()> {
        let t = self.time();
        let p = self.ptr()?;
        p.axis_source(wl_pointer::AxisSource::Finger);
        p.axis(t, wl_axis(axis), pixels);
        p.frame();
        if last {
            p.axis_source(wl_pointer::AxisSource::Finger);
            p.axis_stop(t, wl_axis(axis));
            p.frame();
        }
        self.flush()
    }

    fn key(&mut self, code: u32, pressed: bool) -> Result<()> {
        let t = self.time();
        self.kb()?.key(t, code, u32::from(pressed));
        self.flush()
    }

    fn modifiers(&mut self, mask: u32) -> Result<()> {
        self.kb()?.modifiers(mask, 0, 0, 0);
        self.flush()
    }

    fn sync(&mut self) -> Result<()> {
        let mut s = State;
        self.queue
            .roundtrip(&mut s)
            .context("Wayland connection lost (did the compositor reject the keymap?)")?;
        Ok(())
    }
}

impl Drop for Wayland {
    fn drop(&mut self) {
        if let Some(p) = self.pointer.take() {
            p.destroy();
        }
        if let Some(k) = self.keyboard.take() {
            k.destroy();
        }
        let _ = self.conn.flush();
    }
}

// --- uinput ------------------------------------------------------------------

/// Kernel-level virtual devices: the live seat's libinput sees a real
/// keyboard and an absolute pointer, so niri keybinds fire too. Affects the
/// whole seat (whatever has focus on the live desktop); never reaches nested
/// sessions (they get input from their host window, not libinput).
pub struct Uinput {
    kbd: std::fs::File,
    ptr: std::fs::File,
    bounds: Rect,
}

const EV_SYN: u16 = 0;
const EV_KEY: u16 = 1;
const EV_REL: u16 = 2;
const EV_ABS: u16 = 3;
const REL_HWHEEL: u16 = 6;
const REL_WHEEL: u16 = 8;
const ABS_X: u16 = 0;
const ABS_Y: u16 = 1;
const UI_SET_EVBIT: libc::c_ulong = 0x4004_5564;
const UI_SET_KEYBIT: libc::c_ulong = 0x4004_5565;
const UI_SET_RELBIT: libc::c_ulong = 0x4004_5566;
const UI_SET_ABSBIT: libc::c_ulong = 0x4004_5567;
const UI_DEV_CREATE: libc::c_ulong = 0x5501;
const UI_DEV_DESTROY: libc::c_ulong = 0x5502;
const UI_DEV_SETUP: libc::c_ulong = 0x405c_5503;
const UI_ABS_SETUP: libc::c_ulong = 0x401c_5504;

#[repr(C)]
struct UinputSetup {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [u8; 80],
    ff_effects_max: u32,
}

#[repr(C)]
struct UinputAbsSetup {
    code: u16,
    _pad: u16,
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
}

fn ioctl(f: &std::fs::File, req: libc::c_ulong, arg: libc::c_ulong) -> Result<()> {
    use std::os::fd::AsRawFd;
    // SAFETY: uinput ioctls with an int or a pointer to a live repr(C) struct.
    let r = unsafe { libc::ioctl(f.as_raw_fd(), req as _, arg) };
    if r < 0 {
        bail!("uinput ioctl {req:#x}: {}", std::io::Error::last_os_error());
    }
    Ok(())
}

fn uinput_device(
    name: &str,
    setup: impl Fn(&std::fs::File) -> Result<()>,
) -> Result<std::fs::File> {
    let f = std::fs::OpenOptions::new()
        .write(true)
        .open("/dev/uinput")
        .context("opening /dev/uinput (needs the uinput group)")?;
    setup(&f)?;
    let mut s = UinputSetup {
        bustype: 0x06, // BUS_VIRTUAL
        vendor: 0x5354,
        product: 0x4950,
        version: 1,
        name: [0; 80],
        ff_effects_max: 0,
    };
    s.name[..name.len()].copy_from_slice(name.as_bytes());
    ioctl(&f, UI_DEV_SETUP, &s as *const _ as libc::c_ulong)?;
    ioctl(&f, UI_DEV_CREATE, 0)?;
    Ok(f)
}

impl Uinput {
    pub fn new(bounds: Rect) -> Result<Uinput> {
        let kbd = uinput_device("loft-input keyboard", |f| {
            ioctl(f, UI_SET_EVBIT, EV_KEY as _)?;
            for k in 1..=255 {
                ioctl(f, UI_SET_KEYBIT, k)?;
            }
            Ok(())
        })?;
        let ptr = uinput_device("loft-input pointer", |f| {
            ioctl(f, UI_SET_EVBIT, EV_KEY as _)?;
            for b in 0x110..=0x114 {
                ioctl(f, UI_SET_KEYBIT, b)?;
            }
            ioctl(f, UI_SET_EVBIT, EV_REL as _)?;
            ioctl(f, UI_SET_RELBIT, REL_WHEEL as _)?;
            ioctl(f, UI_SET_RELBIT, REL_HWHEEL as _)?;
            ioctl(f, UI_SET_EVBIT, EV_ABS as _)?;
            for (code, max) in [(ABS_X, bounds.w), (ABS_Y, bounds.h)] {
                ioctl(f, UI_SET_ABSBIT, code as _)?;
                let a = UinputAbsSetup {
                    code,
                    _pad: 0,
                    value: 0,
                    minimum: 0,
                    maximum: max as i32 - 1,
                    fuzz: 0,
                    flat: 0,
                    resolution: 0,
                };
                ioctl(f, UI_ABS_SETUP, &a as *const _ as libc::c_ulong)?;
            }
            Ok(())
        })?;
        // libinput picks new devices up through udev.
        std::thread::sleep(std::time::Duration::from_millis(600));
        Ok(Uinput { kbd, ptr, bounds })
    }

    fn emit(f: &mut std::fs::File, events: &[(u16, u16, i32)]) -> Result<()> {
        let mut buf = Vec::with_capacity((events.len() + 1) * 24);
        for &(ty, code, value) in events.iter().chain([(EV_SYN, 0, 0)].iter()) {
            buf.extend_from_slice(&[0u8; 16]); // timeval: the kernel stamps it
            buf.extend_from_slice(&ty.to_ne_bytes());
            buf.extend_from_slice(&code.to_ne_bytes());
            buf.extend_from_slice(&value.to_ne_bytes());
        }
        f.write_all(&buf).context("writing to uinput")
    }
}

impl Backend for Uinput {
    fn motion_abs(&mut self, x: f64, y: f64, _: Rect) -> Result<()> {
        let b = self.bounds;
        let px = (x - b.x).round().clamp(0.0, b.w - 1.0) as i32;
        let py = (y - b.y).round().clamp(0.0, b.h - 1.0) as i32;
        Self::emit(&mut self.ptr, &[(EV_ABS, ABS_X, px), (EV_ABS, ABS_Y, py)])
    }

    fn motion_rel(&mut self, _: f64, _: f64) -> Result<()> {
        bail!("relative motion is not supported with --uinput (use absolute `move`)")
    }

    fn button(&mut self, code: u32, pressed: bool) -> Result<()> {
        Self::emit(&mut self.ptr, &[(EV_KEY, code as u16, i32::from(pressed))])
    }

    fn wheel(&mut self, axis: Axis, notches: i32) -> Result<()> {
        // REL_WHEEL is positive *up*.
        let (code, v) = match axis {
            Axis::Vertical => (REL_WHEEL, -notches),
            Axis::Horizontal => (REL_HWHEEL, notches),
        };
        Self::emit(&mut self.ptr, &[(EV_REL, code, v)])
    }

    fn smooth_scroll(&mut self, axis: Axis, pixels: f64, _last: bool) -> Result<()> {
        let n = (pixels / 15.0).round() as i32;
        if n != 0 {
            self.wheel(axis, n)?;
        }
        Ok(())
    }

    fn key(&mut self, code: u32, pressed: bool) -> Result<()> {
        Self::emit(&mut self.kbd, &[(EV_KEY, code as u16, i32::from(pressed))])
    }

    fn modifiers(&mut self, _mask: u32) -> Result<()> {
        // The real modifier keys are pressed instead (see exec).
        Ok(())
    }

    fn sync(&mut self) -> Result<()> {
        Ok(())
    }
}

impl Drop for Uinput {
    fn drop(&mut self) {
        std::thread::sleep(std::time::Duration::from_millis(50));
        let _ = ioctl(&self.kbd, UI_DEV_DESTROY, 0);
        let _ = ioctl(&self.ptr, UI_DEV_DESTROY, 0);
    }
}
