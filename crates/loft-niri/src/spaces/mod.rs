//! Spaces: functional desktops across every display (docs/SPACES.md).
//!
//! - `model`: space documents → resolved spaces (templates, instances)
//! - `expr`: `${…}` interpolation in templates
//! - `roles`: display roles (ported from wallsets) and a space on a layout
//! - `render`: spaces → `overrides/spaces.kdl`
//! - `plan`: niri state + a space → the IPC actions that activate it
//! - `live`: reading niri, sending plans pipelined, writing spaces.kdl
//! - `apps`: spin-up / restore as pure functions (matching, placement, order)
//! - `runtime`: `<state>/spaces/runtime.json` (claims, opened, per-space memory)
//! - `launch`: the live side of spin-up (`/proc`, `systemd-run`, waiting)
//! - `edit`: writing space documents (create, patch, delete, reorder, capture)

pub mod apps;
pub mod edit;
pub mod expr;
pub mod launch;
pub mod live;
pub mod model;
pub mod plan;
pub mod render;
pub mod roles;
pub mod runtime;
