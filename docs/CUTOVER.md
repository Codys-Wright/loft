# Cutover: Loft as the fleet's only shell (issue #4, Phase 6)

What still stands between Loft and daily use on every desktop host in
[nix-config](https://github.com/Codys-Wright/nix-config), what Loft fixes itself, and
the nix-config changes to make later. Audited 2026-10-31 against nix-config `main`
792c9e5a (which pins Loft a5d410a) and the live THEBATTLESHIP system. Nothing in
nix-config was changed.

## Where things stand

**Noctalia is already gone from nix-config `main`.** nix-config #61 (6bab37d9,
2026-10-30, the nixpkgs bump that removed `noctalia-shell`) deleted
`settings.desktop.shell`, the Noctalia KDL, its wallpaper script and colours, and the
`loft/greeter` aspect. `fleet.desktop._.loft` (`modules/desktop/loft/loft.nix`) now
gives every user on every `fleet.desktop` host Loft (`programs.loft.enable = mkDefault
true`), the keyboard layer, and the Loft SDDM greeter.

**#61 isn't deployed yet.** THEBATTLESHIP's running system (generation 1064,
2026-10-29) still has `noctalia-shell` and `wlr-which-key`. joshua, bri, guest and carter
there, and cody on nomad / stowaway, switch from Noctalia to Loft at the next switch. So
the THEBATTLESHIP blocker below must land before that deploy, or in the same one.

Desktop hosts (everything that includes `<fleet/desktop>`):

| Host | Hardware | Users | niri | Shell today |
|---|---|---|---|---|
| THEBATTLESHIP | Ryzen 9 9950X3D, RTX 4080 (NVIDIA 615) + Raphael iGPU, 4 monitors | cody, joshua, bri, guest, carter | niri-loft-live | cody: Loft. Others: Noctalia until #61 deploys |
| electric | Ryzen + RX 7800 XT (amdgpu), Windows dual-boot | carter | stock 26.04 | Loft (since nix-config #36) |
| nomad | MacBookPro15,1 (T2): Intel UHD 630 + Radeon Pro 560X, 15" Retina 2880x1800, battery, Broadcom Wi-Fi/BT, Touch Bar | cody | stock 26.04 | Noctalia until #61 deploys |
| stowaway | same as nomad (`<fleet.roles/t2-laptop>`) | cody | stock 26.04 | Noctalia until #61 deploys |

Not desktops: airlock and voyager (macOS), outrider (WSL), dave (XFCE test VM, no
`fleet.desktop`), beacon (installer ISO). `THEBATTLESHIP-vm` includes niri only, without
Loft.

System services the shell relies on, evaluated per host: UPower, power-profiles-daemon,
NetworkManager and BlueZ are on everywhere (the GNOME/KDE sessions in `fleet.desktop`
bring the first two; `fleet.hardware` the rest). `hardware.i2c` is off everywhere, so
DDC/CI brightness for external monitors doesn't work on any host.

## Per host

### THEBATTLESHIP

**Status:** cody runs Loft every day. The other four accounts haven't run it yet.

Blocking:
- **Monitor power-off wedges the NVIDIA driver, and only cody has it turned off.**
  `hosts/THEBATTLESHIP/cody-desktop.nix` sets `idle.lockAfter = null` and
  `idle.screenOffAfter = null` because DPMS left `nvidia-modeset` hung in D state.
  joshua, bri, guest and carter get Loft's defaults (lock after 300 s, monitors off
  after 600 s), so the first idle session in any of those accounts can freeze the
  desktop for everyone. Fix in nix-config: set `screenOffAfter = null` for every user
  on the host. Keep the lock.

Nice to have:
- joshua, bri and guest don't have `kitty`, which the fleet's `Mod+Return` spawns. Mod+E
  (ghostty) and Spotlight work.
- The other users ran stock `niri` in `programs.loft.niriPackage` while the compositor
  is niri-loft-live, so they got no per-workspace wallpapers or traffic lights. **Fixed
  on the Loft side** (below). After the Loft bump, cody's explicit `niriPackage` in
  cody-desktop.nix is redundant.
- Only cody has phone, Spotify, Qt/Dolphin theming and the agent skills. That's
  intentional, per user.

### electric

**Status:** working. Carter has used Loft as his shell since nix-config #36.

Blocking: none found.

Nice to have:
- The shared `outputs.kdl` (THEBATTLESHIP's monitors) has an `output "HDMI-A-2"` block
  keyed by connector, not identity. If one of electric's monitors comes up on HDMI-A-2,
  it gets the AOC's mode and position (`x=-2560`).
- No DDC/CI brightness (`hardware.i2c` off).
- AMD GPU stats (VRAM, temperature, power, fan) are covered since Loft a5d410a (#14).

### nomad and stowaway (T2 MacBook Pro)

**Status:** expected to work on first login. Not run on the hardware yet: neither host
was reachable from this audit, and #61 isn't deployed there.

Blocking (fixed on the Loft side):
- **Nothing handled the brightness keys.** Neither the fleet's binds nor Loft's bound
  `XF86MonBrightnessUp/Down`. Noctalia didn't either, but the control matters on a
  laptop. Loft now binds them (below).

Covered already, no work needed: battery extra and low-battery alerts (UPower), Wi-Fi
(NetworkManager), Bluetooth, power mode (power-profiles-daemon), backlight slider
(brightnessctl through logind), Keep Awake with an optional lid-closed inhibitor,
lock-before-sleep (swayidle `before-sleep`), trackpad settings (Settings → Input: tap,
natural scroll, disable-while-typing), and niri's own touchpad gestures (3-finger
workspace/column swipe, 4-finger overview). The fleet's `input.kdl` already sets
`touchpad { natural-scroll; tap; }`.

HiDPI and a single output: niri picks scale 2 for the 2880x1800 panel. A headless
session at 2880x1800, scale 2 (1440x900 logical) on the AMD iGPU lays out cleanly
(bar, island, dock, Settings all fit).

GPU: VA-API video wallpapers use Mesa (iHD on Intel, radeonsi on the 560X). Loft's
NVIDIA additions are harmless there: `LIBVA_DRIVERS_PATH` puts nvidia-vaapi-driver-loft
first, but libva looks drivers up by name, so Mesa's still load (checked with `vainfo`
on the Raphael iGPU: `radeonsi_drv_video.so` from `/run/opengl-driver`).
`NVD_MAX_DETACHED_BACKING_IMAGES` is read only by the NVIDIA driver, and the zero-copy
path tries Mesa's composed layers first. The NVIDIA-only UI (sleep warning, nvidia-smi
stats, wallvideo checks) is gated on `/proc/driver/nvidia`.

Nice to have:
- Keyboard backlight (`/sys/class/leds/*kbd_backlight`, keys `XF86KbdBrightnessUp/Down`)
  has neither a control nor binds.
- Media keys (`XF86AudioPlay/Next/Prev`) aren't bound. The shell has MPRIS
  (`Controls.player`) but no IPC for it yet.
- No Intel iGPU stats (the island reads NVIDIA and amdgpu only).
- Touch Bar (tiny-dfr) isn't themed or driven by Loft.
- Risks outside Loft: T2 suspend/resume (apple-bce) is often unreliable on t2linux;
  lid close → suspend → lock depends on it. Both hosts have the same
  `deployment.ip` (192.168.0.139) in nix-config.

## wlr-which-key

**Loft covers it; remove it from the fleet.** The fleet's `Mod+D` menu
(`_config/which-key.yaml`) holds a browser, ten `focus-workspace` jumps, three
column-width actions and Logout. In Loft those are:

- Workspaces: `Mod+1…9`, the Spaces switcher (`Mod+Ctrl+S`), workspace icons in the bar,
  and `Mod+Ctrl+←/→`.
- Apps, Logout and the rest: Spotlight (`Mod+Space`; system commands, every Settings
  page and every Control Center module), the Quick Panel (`Mod+Ctrl+V`) and the Radial
  Menu (`Mod+Ctrl+Space`) for favourite actions, and the System menu.
- Column widths: niri's own binds in the fleet's `binds.kdl` (`Mod+R` presets, `Mod+F`
  maximize, `Mod+C` center). "Fill available" (`expand-column-to-available-width`) has no
  bind. If it's missed, give it one when removing the menu.
- Discoverability: Settings → Keyboard Shortcuts lists every effective bind, and niri's
  hotkey overlay (`Mod+Shift+/`) shows Loft's binds with titles.

Loft doesn't bind `Mod+D`, so removing the menu frees the key.

## nix-config checklist (for later; this audit changed none of it)

Done in #61:
- [x] `settings.desktop.shell` removed; Loft is every niri user's shell
  (`modules/desktop/desktop.nix`, `modules/desktop/loft/loft.nix`).
- [x] `noctalia-shell`, its KDL, wallpaper script and colours removed
  (`modules/desktop/environment/niri/niri.nix`, `_config/`).

To do:
- [ ] **THEBATTLESHIP idle (blocker, before deploying #61):** turn monitor power-off
  off for every user on the host, e.g. in `hosts/THEBATTLESHIP/THEBATTLESHIP.nix` (or a
  new `hosts/THEBATTLESHIP/loft-idle.nix` aspect):
  `provides.to-users.homeManager.programs.loft.idle.screenOffAfter = lib.mkDefault null;`.
  Then drop the per-cody line in `cody-desktop.nix`, or keep it because cody also turns
  off the lock.
- [ ] **Deploy #61** to THEBATTLESHIP, nomad and stowaway. Then check one non-cody account
  on THEBATTLESHIP and one laptop by hand.
- [ ] **Bump loft** once this branch is on Loft `main` (brightness keys; `niriPackage`
  follows the system niri). Optional afterwards: drop `programs.loft.niriPackage` from
  `hosts/THEBATTLESHIP/cody-desktop.nix`.
- [ ] **Remove wlr-which-key:**
  - `modules/desktop/environment/niri/niri.nix:69` (systemPackages)
  - `modules/desktop/environment/niri/_config/binds.kdl:5` (`Mod+D`)
  - `modules/desktop/environment/niri/_config/which-key.yaml` (delete)
  - `modules/flake/niri-package.nix:35` (runtimeInputs of the standalone `.#niri`)
  - `modules/desktop/environment/niri/_niri-settings.nix` (`mkWhichKeyExe`, the
    `Mod+D` bind near line 248) via `niri-wrapper.nix`
  - docs: `docs/niri.md` "Which-Key Menu", `docs/desktop-design.md` (which-key sections)
- [ ] **Terminal for every user:** `_config/binds.kdl:2` spawns `kitty`, which only some
  users have. Spawn `ghostty` (in systemPackages), or add `kitty` to `niri.nix`.
- [ ] **Leftover Noctalia-era tools** in `niri.nix` systemPackages: `swaybg` (Loft draws
  wallpapers), `swaylock` plus the `Mod+Shift+Escape` swaylock bind in `binds.kdl:90`
  (a second locker that bypasses Loft's lock screen; Loft locks with `Mod+Ctrl+Q`), and
  `swayidle` (home-manager's `services.swayidle` from Loft runs it). Optional:
  `Mod+Shift+S/E` grim/swappy, which Loft's capture (`⌘⇧3/4/5`) replaces.
- [ ] **Per-host outputs:** move THEBATTLESHIP's `_config/outputs.kdl` and the
  `open-on-output` lines in `_config/workspaces.kdl` into `hosts/THEBATTLESHIP/`, or key
  the `HDMI-A-2` block by monitor identity like the others.
- [ ] Optional: `hardware.i2c.enable = true` plus the `i2c` group (or a uaccess udev rule
  for `i2c-dev`) on THEBATTLESHIP and electric, so Control Center → Display can set
  external monitor brightness over DDC/CI.
- [ ] Unrelated, found on the way: nomad and stowaway share `deployment.ip =
  "192.168.0.139"`.

## Loft-side fixes (this branch)

- **Brightness keys:** `XF86MonBrightnessUp/Down` (also on the lock screen) step the
  built-in panel 5 %, or every display when there's no backlight, and show it in the
  island HUD. The new IPC is `brightness up|down|set V|get`
  (`src/services/Brightness.qml`, `niri/shell-binds.kdl.in`). Tested in a headless
  session with `LOFT_FAKE_BRIGHTNESS=1`: two key presses through niri took the displays
  from 0.7/0.45 to 0.6/0.35, and the HUD showed it.
- **`programs.loft.niriPackage` follows the system's niri:** Loft's NixOS module adds a
  `home-manager.sharedModules` default (`mkDefault config.programs.niri.package`) when
  home-manager and niri are on the host. On THEBATTLESHIP every user now gets
  niri-loft-live's per-workspace wallpapers and traffic lights. A user's niri.kdl can no
  longer include KDL the running niri rejects, or leave out what it supports. Check:
  `niri-follows-system`. Verified against nix-config with `--override-input loft`:
  THEBATTLESHIP joshua now gets `niri-loft-live-26.04` (was `niri-26.04`), nomad cody
  gets `niri-26.04`.

Checked and left alone (not host-specific in practice): the NVIDIA VA-API environment
(see the T2 section above), output names (only in tests), `/run/media/Development` and
user names (only in docs and examples).

## Larger gaps (not done here)

- Keyboard backlight control and keys (T2 laptops).
- Media-key binds through an MPRIS IPC.
- Intel iGPU stats.
- Run the T2 laptops on real hardware after #61 deploys: suspend/resume, lid, Touch Bar,
  Broadcom Wi-Fi in the Wi-Fi extra, and the battery extra's time estimates.
- The keyboard decision (voyager / macOS parity) that issue #4 mentions. It doesn't block
  the Linux hosts.
