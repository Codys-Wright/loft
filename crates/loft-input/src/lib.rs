//! loft-input / loft-shot: let agents (and people) see and drive a
//! Loft desktop — a nested `loft-dev --session NAME` test session,
//! or, when asked, the live one.
//!
//! - `backend`: Wayland virtual pointer + keyboard (zwlr_virtual_pointer_v1,
//!   zwp_virtual_keyboard_v1), or uinput for the live seat
//! - `keymap`: combos / text → keycodes, and the uploaded xkb keymap
//! - `bind`: niri keybinds run through IPC (niri never sees virtual keys)
//! - `niri`: outputs, windows, layers in global logical coordinates
//! - `session`: which desktop (`session.env` of loft-dev sessions)
//! - `shot` + `font`: screenshot post-processing (crop, scale, grid, marks)
//! - `autoscroll`: `loft-pointer scroll`, the Auto Scroll helper of
//!   scrolling capture (pointer motion + wheel notches only)

pub mod autoscroll;
pub mod backend;
pub mod bind;
pub mod cli;
pub mod exec;
pub mod font;
pub mod keymap;
pub mod niri;
pub mod session;
pub mod shot;
