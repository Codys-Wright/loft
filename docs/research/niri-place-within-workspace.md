# Per-workspace layer surfaces in niri (`place-within-workspace`)

Loft's patch: `nix/niri/workspace-layers.patch` (package `niri-loft`, niri 26.04).
This note is the proposal for upstream.

## The problem

Stock niri renders background and bottom layer surfaces once behind every workspace of
their output (`Niri::render`, the per-workspace loop over
`Monitor::workspaces_with_render_geo`). They move and zoom with the workspaces, but every
workspace shows the same surface. `place-within-backdrop` (PR #1440) moves a background
surface into the overview backdrop instead. Neither one lets a workspace have its own
wallpaper.

So the per-workspace wallpaper tools (multibg-niri, niri-scripts, Loft before this) swap one
surface's image when a workspace is activated. During the vertical switch animation both the
outgoing and the incoming workspace show the same, new image: it pops instead of sliding. The
overview shows that one image behind every workspace.

## The proposal: a layer rule

```kdl
layer-rule {
    match namespace="^wallpaper@(.+)$"
    place-within-workspace "$1"
}
```

`place-within-workspace` binds a background or bottom layer surface to one workspace of its
output. The value is a workspace reference, read like `niri msg action focus-workspace`
reads one: a number is a 1-based index on the surface's output, anything else is a workspace
name (case-insensitive). `$1`, `${1}`, `${name}` expand to the captures of the matching
`namespace` regex (`regex::Captures::expand`), so one rule binds a whole family of surfaces.

A bound surface:

- renders only within its workspace: in the normal view, during switch animations (where it
  slides with the workspace, cropped to it like everything else in the per-workspace loop) and
  in the overview (zoomed with it);
- is not rendered at all while its workspace is off screen (the existing culling of
  `workspaces_with_render_geo` applies: the filter sits in `layers_in_render_order`);
- gets pointer input, and exclusive keyboard focus, only while its workspace is the one under
  the pointer / the active one;
- feeds the xray background (blur behind glass surfaces) while its workspace is active;
- never goes into the overview backdrop (`place-within-backdrop` is ignored for it).

Unbound surfaces keep the stock behaviour, so with no rule using the property niri behaves
exactly as before: every new code path is a filter that passes everything when no binding is
set.

## Why a layer rule (and not a protocol or IPC)

- **No new protocol.** Layer rules already resolve per surface from its namespace and
  re-resolve on commit; adding a property follows `place-within-backdrop` and `opacity`. The
  client only picks a namespace.
- **Works for dynamic workspaces.** A client names surfaces after a workspace name or its
  index, both visible in IPC (`niri msg workspaces`), and creates / destroys them as
  workspaces come and go. Ids would need a protocol or a config reload per workspace.
- **Small.** About 150 changed lines outside tests and docs: `niri-config` (one field),
  `layer/` (the resolved binding + capture expansion), `Monitor::workspace_idx`, and the
  render / input / focus call sites in `niri.rs`.
- **A protocol remains possible later** (e.g. on top of `ext-workspace-v1`, binding a layer
  surface to an `ext_workspace_handle_v1`). The rendering half of this patch is what such a
  protocol would need anyway.

## Clients: keep only what is on screen

niri never draws a bound surface whose workspace is off screen, but a mapped surface still
costs its buffers. A client should map only the workspaces that can come on screen: Loft
(`src/services/WorkspaceWallpapers.qml`, `wswallpapers.js`) keeps the active workspace and one
neighbour each way at full size (a switch or swipe slides a neighbour in, and niri announces a
switch only as it starts); with the overview open, the workspaces its zoom shows plus one more
each way, the extra ones decoded at the overview's zoom; and destroys a surface 1.5 s after it
stopped being wanted.

## Tests in the patch

- `niri-config`: `parse_place_within_workspace` (the property parses, needs an argument).
- `layer::tests`: capture expansion (`$1`, `${1}`, named groups, no match context) and
  matching (index vs name, case-insensitive).
- `tests::layer_shell::place_within_workspace`: two named workspaces + the empty one; a
  surface bound by name and one bound by index; each takes input only on its own workspace,
  none on the third; an unbound surface still covers every workspace.
- The wiki section parses (`wiki-parses`).

## Open questions for upstream

- Index binding follows the index, not the workspace: when workspaces are reordered the
  surface stays with the slot. That suits wallpapers keyed by position; a client that wants
  the workspace itself can name it.
- Whether a bound *bottom* layer surface should also follow its workspace to another output
  (it doesn't: layer surfaces belong to an output).
- A capability signal for clients. Loft reads `niri msg version` (its package tags the
  version string) and only includes the rule when it runs the patched niri, since a stock niri
  rejects an unknown layer-rule property.

## Measured (Loft, 2026-10-14)

`loft-dev --session wsw --outputs 2560x1440,1920x1080,1440x2560`, 10 named workspaces per
output (+ niri's empty one), a distinct 3840x2160 JPEG per workspace, every output on its 5th
workspace. Software rendering (llvmpipe), so window buffers and textures are process memory:
PSS of the shell (quickshell) and niri. Decoded MB = image data the shell holds.

| | wallpaper surfaces | decoded images | quickshell PSS | niri PSS |
|---|---|---|---|---|
| swap on activate (stock niri path) | 3 | 66 MB | 1057 MB | 75 MB |
| every workspace mapped (naive, `LOFT_WS_WALLPAPERS_ALL=1`) | 33 | 751 MB | 4561 MB | 75 MB |
| Loft: active ± 1 | 9 | 199 MB | 1825 MB | 75 MB |
| Loft: overview open (±1 full, ±2 at zoom 0.5) | 15 | 233 MB | 2358 MB | 75 MB |
| Loft: 4 s after the overview closed | 9 | 199 MB | 1788 MB | 75 MB |

A surface costs far more than its image (≈ 128 MB each under llvmpipe for these sizes: Qt's
swapchain buffers plus the scene graph texture); on a GPU that is VRAM, roughly 3 × W × H × 4
bytes per surface plus the texture. The portrait output's images decode at 3840x2160 (cover
crop of a landscape image), which is most of the decoded MB.
