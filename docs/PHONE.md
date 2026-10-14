# iPhone: messages, calls and notifications

Loft shows your iPhone's messages, calls and app notifications through
[tether](https://github.com/zackb/tether). Its daemon, `tetherd`, presents the computer to the
phone as a Bluetooth hands-free accessory (like a car kit), so the iPhone shares:

- **messages**, SMS and iMessage, read and send (MAP);
- **contacts** (PBAP);
- **every app's notifications** (ANCS);
- **calls**: ring, caller ID, answer, decline, hang up and dial (HFP).

No Mac, Apple ID or cloud is involved. Loft is a client of tetherd's socket. The research behind
this choice is in [research/phone-integration.md](research/phone-integration.md), and the feature
rows are in [FEATURES.md](FEATURES.md#iphone--wave-3-phone).

## What you get

| Where | What |
|---|---|
| Island | A banner for each new message, with **Reply**. An incoming call turns the island into **Decline / Answer**. A call in progress is a live activity (caller and timer); hover it for **Hang Up**. |
| Messages panel | Conversations, the thread and a reply box. Open it from Spotlight ("Messages"), the Control Center tile, a banner, or `phone messages`. ⌃N starts a new message and Esc closes the panel. |
| Notifications | The phone's app notifications appear like any other notification, tagged "Instagram · iPhone", with tether's actions. |
| Control Center / menu bar | An **iPhone** tile showing battery, unread count or the call. Expanding it shows signal, carrier and the latest conversations. The menu bar extra is off by default (Settings → Menu Bar). |
| Settings → Phone | Status, which links are up, what Loft shows, tetherd's call control, and the pairing guide. |

These limits come from iOS, not tether:

- Only messages that arrive while the phone is connected show up. There is no history from
  before pairing.
- There are no photos, reactions or read receipts.
- SMS and iMessage look the same.
- Only one computer at a time can hold the phone's messages.
- Notifications need iOS 26.

## Setup

### 1. The system (NixOS)

tetherd is in nixpkgs (`pkgs.tether`). The system has to:

- start BlueZ with `Experimental = true`, which gives the LE bearer API ANCS needs. Do this
  **before pairing**: a bond made without it has no LE half;
- set the adapter's class to *A/V Hands-Free* after every `bluetoothd` start. iOS only offers the
  Messages and Contacts toggles to a hands-free device.

This snippet is a port of upstream's `nix/module.nix`:

```nix
{ pkgs, ... }:
{
  hardware.bluetooth.settings.General.Experimental = true;
  environment.systemPackages = [ pkgs.tether ];
  systemd.services."tether-btclass@hci0" = {
    description = "Set Bluetooth Class of Device to A/V Hands-Free for Tether";
    after = [ "bluetooth.service" ];
    partOf = [ "bluetooth.service" ];
    wantedBy = [ "bluetooth.service" ];
    path = [ pkgs.bluez pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 60; };
    script = ''
      for attempt in $(seq 30); do
        hci=hci0
        [ -e /sys/class/bluetooth/$hci ] || hci=$(ls /sys/class/bluetooth 2>/dev/null | head -n1)
        if [ -n "$hci" ]; then
          echo | btmgmt --index $hci class 4 8 >/dev/null 2>&1
          echo | btmgmt --index $hci info 2>/dev/null | grep -q "class 0x..0408" && exit 0
        fi
        sleep 1
      done
      exit 1
    '';
  };
}
```

### 2. The daemon (home-manager)

```nix
programs.loft.phone.enable = true;   # tether + tetherd.service (user unit)
```

tetherd is a **per-user** daemon. It owns the Bluetooth session, its socket
(`$XDG_RUNTIME_DIR/tetherd.sock`) and the clipboard. It runs without a Wayland session too.

### 3. Pair (once, by hand)

Settings → Phone shows these steps:

1. `tether bt setup` lists the system steps that are still missing. Run it until it lists none.
2. Close other pairing agents, such as blueman's applet. If there are several controllers, pick
   the working one with `tether bt adapter hci0`.
3. On the iPhone, open Settings → Bluetooth and keep the page open. Then run
   `tether bt devices` to find the iPhone's address, and `tether bt pair <address>`. Confirm the
   code on both the phone and the computer.
4. On the iPhone, go to Settings → Bluetooth → (i) next to the computer. Turn on **Show Message
   Notifications** and **Sync Contacts**. If the toggles don't appear, run `tether bt solicit`.
5. Optional, for calls: run `tether bt calls-enable on`, or use the switch in Settings → Phone.
   WirePlumber must not take the phone's Hands-Free link: drop `hfp_hf` from `bluez5.roles`.
6. Turn on Settings → Features → **iPhone**. Settings → Phone should then say Messages,
   Contacts and Notifications are "on". For diagnostics, run `tether bt connection` or
   `tether status`.

### Hardware

ANCS needs a bond that covers LE as well as classic Bluetooth. Realtek controllers and USB dongles
are reported to fail that LE bond. THEBATTLESHIP's only working controller is a Realtek RTL8821C,
so messages, contacts and calls should work there, but notifications may not. tetherd's pair
result says for certain (`dual_bond`). Intel AX2xx and MediaTek MT7925 controllers are known to
work.

## Call audio

By default the audio stays on the iPhone, and Loft only controls the call. tetherd uses BlueZ's
experimental `org.bluez.Telephony1`. BlueZ only exports it when PipeWire doesn't claim the HF role,
so call control needs `hfp_hf` removed from WirePlumber's `bluez5.roles`.

Desktop call audio is possible through PipeWire's telephony (`org.pipewire.Telephony`), but it has
costs:

- the HFP indicators are lost;
- the phone's music moves to the computer too;
- it works only when the phone opens the link.

On a studio machine this needs testing against the audio graph first. Loft changes no audio
configuration.

## IPC

```sh
qs ipc call phone status                 # JSON: link, device, battery, unread, call…
qs ipc call phone send "+1 503 555 0101" "on my way"   # number, Apple ID or thread key
qs ipc call phone answer|decline|hangup
qs ipc call phone dial "+15035550101"
qs ipc call phone messages               # toggle the panel
qs ipc call phone thread tel:+15035550101
```

## How it works

`src/services/Phone.qml` holds **one** `Quickshell.Io.Socket` to tetherd. It sends
`{"command":"subscribe"}` and then the list commands. tetherd answers the list commands on the same
connection and broadcasts the rest. Fire-and-forget commands get a bare `OK` line, which is
ignored. The protocol facts come from upstream `docs/PROTOCOL.md` and the 0.2.35 sources
(`src/core/src/net.cpp`, `src/daemon/main.cpp`). All parsing and state live in
`src/services/phone.js`, a pure reducer:

- it is unit-tested against a recorded session (`tests/phone.test.js`,
  `tests/fixtures/tether/session.jsonl`);
- it runs in `nix flake check` as `phone-protocol`.

Before connecting, the service checks that the socket exists (`test -S`). A missing tetherd only
shows "Not connected" and never fills the log.

### Testing without a phone

`tests/fake_tetherd.py` speaks the same protocol with canned data. With `--notify` it also raises
tetherd's freedesktop notifications through `gdbus`. `tests/test_phone_fake.py` keeps it honest
against the fixture. In a test session (never on the live desktop):

```sh
loft-dev --session phone "$PWD" &          # then source its session.env
python3 tests/fake_tetherd.py serve --notify &      # binds the session's $XDG_RUNTIME_DIR/tetherd.sock
python3 tests/fake_tetherd.py inject message        # | notification | call | outgoing | answer | hangup | away | back
```

Turn on Features → iPhone in that session. The fake never touches Bluetooth.
