# The keyboard layer (xremap): the Mac's modifier roles on Linux.
#
#   Esc / Caps Lock   tap → Escape, hold → the window-manager key
#                     (emits Right Alt, which XKB lv3:ralt_switch turns into
#                     ISO_Level3_Shift = niri's mod-key — no app binds it)
#   Right Alt         the window-manager key natively (XKB), no xremap needed
#   Super             Cmd: app shortcuts (⌘C → Ctrl+C, ⌘⇧C/V in terminals, …)
#   Ctrl              untouched — terminals, vim, readline
#   Alt               Option: word navigation
#
# `appKeys = false` builds the dual-role keys only (no app-aware Cmd remaps);
# the dev session uses that, since inside another desktop xremap can't tell
# which app is focused.
{ lib }:
{
  appKeys ? true,
}:
let
  dualRole = {
    name = "Esc / Caps Lock: tap = Escape, hold = window-manager key";
    remap =
      lib.genAttrs
        [
          "Esc"
          "CapsLock"
        ]
        (_: {
          tap = "Esc";
          hold = "Alt_R";
          # Held past 100 ms (or with another key) = the modifier; a press
          # released within 1 s with nothing else = Escape.
          held_threshold_millis = 100;
          tap_timeout_millis = 1000;
        });
  };

  mac = import ./mac-keybindings.nix { inherit lib; } { cmdKey = "super"; };
in
if appKeys then
  mac // { modmap = [ dualRole ] ++ mac.modmap; }
else
  {
    modmap = [ dualRole ];
  }
