//! Spaces: functional desktops across every display (docs/SPACES.md).
//!
//! - `model`: space documents → resolved spaces (templates, instances)
//! - `expr`: `${…}` interpolation in templates
//! - `roles`: display roles (ported from wallsets) and a space on a layout
//! - `render`: spaces → `overrides/spaces.kdl`
//! - `plan`: niri state + a space → the IPC actions that activate it

pub mod expr;
pub mod model;
pub mod render;
pub mod roles;
