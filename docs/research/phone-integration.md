# Phone integration for Loft: messages, notifications, calls, files

Research date: 2026-10-13. Cody's phone is an **iPhone**, so this goes deep on iOS. Android
gets a short table at the end. Star counts and "last push" dates come from the GitHub API on
the research date. Nixpkgs status was checked with `nix eval nixpkgs#<attr>.version` against
nixpkgs 26.11 (2026-09-28), the version the fleet pins.

## TL;DR

- **[zackb/tether](https://github.com/zackb/tether)** is the best single backend for Loft.
  It is an MIT-licensed C++ daemon (`tetherd`) that presents the Linux box to the iPhone as a
  Bluetooth hands-free accessory. Over Bluetooth it gets **SMS and iMessage read + send (MAP),
  contacts (PBAP), notifications from every app (ANCS), and call control (HFP)**, with no Mac,
  no Apple ID and no cloud. A companion App Store app adds **clipboard and file transfer over
  Wi-Fi**. It is in nixpkgs (`pkgs.tether` 0.2.34) and ships its own NixOS module. Clients
  talk to it over a **newline-delimited JSON Unix socket** with a `subscribe` broadcast, which
  Quickshell can read directly with `Quickshell.Io.Socket`. No D-Bus shim is needed.
- **[erikwb/blueferry](https://github.com/erikwb/blueferry)** is the closest alternative. It
  uses the same Bluetooth approach, already ships a **Quickshell client**, and adds iPhone
  media control (AMS), battery level and an "away lock". It is Python, GPL-2.0+, not in
  nixpkgs, and only reachable over D-Bus. Use one or the other, never both: the iPhone serves
  a single MAP session.
- The full iMessage experience (attachments, tapbacks, typing, group IDs, history) needs
  either a **Mac relay** (BlueBubbles, or Beeper Desktop on macOS) or **Apple-protocol
  emulation** (OpenBubbles/rustpush, Corten). The emulation route uses Mac hardware
  identifiers, carries Apple ID risk, and requires turning off Contact Key Verification. Treat
  it as an optional phase-4 add-on, not the base.
- **Proposed stack:** tether for messages, notifications, calls, clipboard and files;
  LocalSend or tether's iOS share sheet instead of AirDrop; UxPlay for screen mirroring;
  libimobiledevice for USB/Wi-Fi-sync extras (backup, photos, exact battery). Loft writes its
  own QML front-end (Messages panel, island live activities for calls and incoming messages,
  a Control Center phone tile) on top of tether's socket.
- **Hardware blocker on THEBATTLESHIP:** the only working Bluetooth controller is a **Realtek
  RTL8821C (BT 4.2, USB `0bda:c820`)**. The MediaTek MT7927's Bluetooth half (`0489:e13a`)
  fails to initialise (`hci1: Opcode 0x0c03 failed: -16`). iphonebridge reports that Realtek
  controllers and USB dongles fail the LE bonding that ANCS needs. tether's recorded success
  is on a MediaTek MT7925. MAP, PBAP and HFP should work on any adapter. Notification
  mirroring may need a different controller (see "Cody's hardware").

---

## 1. What tether is, precisely

| | |
|---|---|
| Repo | [github.com/zackb/tether](https://github.com/zackb/tether), "Linux + iPhone Continuity / iMessage / SMS" |
| Language, license | C++ (daemon, CLI, GTK3 app, ncurses TUI), Swift (iOS app), JS (browser/mail extension); **MIT** ([LICENSE](https://github.com/zackb/tether/blob/main/LICENSE)) |
| Maturity | Created 2026-04-12. **1,461 stars**, 42 forks, 12 contributors, **47 releases**, latest **v0.2.38 on 2026-10-14** (pushed the same day). Very active, one main author. |
| Phone OS | iPhone only. Android is an explicit non-goal ([DESIGN.md §5](https://github.com/zackb/tether/blob/main/docs/DESIGN.md)). |
| Packaging | AUR, AppImage, Flatpak, container, **nixpkgs `tether` 0.2.34** (`pkgs/by-name/te/tether`), and an upstream flake with `nixosModules.default` → `programs.tether` ([README "Nix"](https://github.com/zackb/tether#nix), [nix/module.nix](https://github.com/zackb/tether/blob/main/nix/module.nix)) |

### Components ([README "Components"](https://github.com/zackb/tether#components))

1. **`tetherd`**: a per-user daemon (systemd user unit `tetherd.service`). It owns Bluetooth,
   the TCP+mTLS listener for the phone app, and Wayland clipboard access.
2. **`tether`**: the CLI. It is also the browser/mail-extension native-messaging host.
3. **`tether-gtk`** / **`tether-tui`**: front-ends (Devices, Messages, Notifications,
   Contacts, Calls).
4. **iOS app** ([App Store](https://apps.apple.com/us/app/tether-linux-companion/id6762097135)):
   finds the daemon via Bonjour and handles clipboard, files and a share-sheet extension. It is
   *not* needed for messages, notifications or calls.
5. **WebExtension** for Firefox/Chromium/Thunderbird: OTP detection and autofill.

### Two transports

| Feature | Mechanism | Transport | Status per README |
|---|---|---|---|
| SMS + iMessage read/send | **MAP** via BlueZ `obexd` (Linux = OBEX client) | BR/EDR | Stable |
| Contacts, call history | **PBAP** via `obexd` | BR/EDR | Stable |
| Notifications from any app (+ positive/negative actions) | **ANCS** (Linux = GATT central) | BLE | Beta |
| Place/answer/end calls, caller ID, carrier, signal, phone battery | **HFP** through BlueZ `org.bluez.Telephony1` (or PipeWire `org.pipewire.Telephony`) | BR/EDR | Alpha |
| AirPods battery, ANC mode, in-ear | **AAP** over L2CAP | BR/EDR | Alpha, opt-in |
| Clipboard (text + PNG), files, open URL, OTP | tether iOS app ↔ `tetherd` | Wi-Fi, TLS 1.2 mTLS, TOFU fingerprint pinning, port 5134/tcp + mDNS | Stable |

Sources: [docs/BLUETOOTH.md table](https://github.com/zackb/tether/blob/main/docs/BLUETOOTH.md),
[README features](https://github.com/zackb/tether#features),
[PROTOCOL.md §3 pairing](https://github.com/zackb/tether/blob/main/docs/PROTOCOL.md).

### How the Bluetooth trick works

The machine sets its **Class of Device to "A/V Hands-Free" (major 4, minor 8)**. iOS only
offers the **"Show Message Notifications"** and **"Sync Contacts"** toggles to a device with
that class. Once the user enables them in iOS Settings → Bluetooth → (i), the iPhone serves
MAP, PBAP and ANCS to it, the same way it does for a car head unit. This is also how Microsoft
Phone Link for iPhone works.

Requirements ([BLUETOOTH.md "Setup requirements"](https://github.com/zackb/tether/blob/main/docs/BLUETOOTH.md#setup-requirements)):

- **BlueZ ≥ 5.86 started with `--experimental`** (or `Experimental = true`) for the LE bearer
  API `org.bluez.Bearer.LE1`. It must be on *before* pairing, because a bond made without it
  has no LE half and so no ANCS. The fleet runs BlueZ 5.87.
- **Class 0x000408**, re-applied after every `bluetoothd` restart. The NixOS module ships a
  `tether-btclass@hciN` oneshot for this.
- **`obexd`** user service, for MAP and PBAP.
- A controller with BR/EDR + LE + advertising.
- **iOS 26 or later for notification mirroring.** "Notification mirroring does not work on
  iOS 18 and earlier" ([README requirements](https://github.com/zackb/tether#bluetooth-for-messages-and-notifications)).

### Calls

tether does not implement HFP itself. It reads BlueZ's experimental
`org.bluez.Telephony1`/`org.bluez.Call1` (Dial, Answer, Hangup, SendTones) and falls back to
PipeWire's `org.pipewire.Telephony` (PipeWire ≥ 1.4). **By default call audio stays on the
phone**: BlueZ's HF role never opens the SCO voice link.

To get call control, drop `hfp_hf` from WirePlumber's `bluez5.roles`. Otherwise PipeWire
takes the link and BlueZ exports no `Telephony1`.

Desktop call audio is possible through PipeWire's HF role
(`bluez5.telephony-dbus-service = true`, `AudioGatewayTransport1.Activate()`). It costs the
HFP indicators and forces `a2dp_sink`, so the phone's music moves to the desktop too. It also
works only when the phone initiates the link. All of this is in
[BLUETOOTH.md "Calls"](https://github.com/zackb/tether/blob/main/docs/BLUETOOTH.md#calls).

### Hard limits (iOS, not tether)

From [BLUETOOTH.md "Known limits"](https://github.com/zackb/tether/blob/main/docs/BLUETOOTH.md#known-limits):

- MAP labels SMS and iMessage both as `sms-gsm`, so blue and green can't be told apart.
- The MAP sent folder is empty, so tether records its own sends.
- **No attachments, reactions, typing indicators or read receipts.**
- No group-conversation IDs. Groups are guessed by correlating with ANCS.
- ANCS has positive/negative actions only. There is **no free-text reply on a notification**,
  so replies go through MAP, which only works for Messages.
- **Only messages seen while connected.** There is no backfill of history.
- One MAP session per iPhone, across all computers.

### API a shell can consume

- **Unix socket `$XDG_RUNTIME_DIR/tetherd.sock`**, newline-delimited JSON.
  `{"command":"subscribe"}` turns the connection into an event stream
  ([PROTOCOL.md §4, §6](https://github.com/zackb/tether/blob/main/docs/PROTOCOL.md);
  `src/core/src/net.cpp`). Relevant verbs:
  - Messages: `bt_list_threads`, `bt_list_messages {thread}`,
    `bt_send_message {thread, body, operation_id}` → `bt_send_result`, and the `bt_message`
    broadcast on every new message.
  - Status: `bt_mark_read`, `bt_list_contacts {query}`,
    `bt_connection` / `bt_connection_changed`.
  - Notifications: `bt_list_notifications`, `bt_notification_action {uid, positive|negative}`.
  - Calls: `bt_calls`, `bt_call_dial {number}`, `bt_call_action`, `bt_call_tones`,
    `bt_call_history`.
  - Clipboard and files: `clipboard_send`, `send_file {path}`, `discover`, `pair_request`,
    `accept_device`.
  - Other: `bt_airpods*`, `otp_available`, `protocol_info` (capabilities, version 1).
- `tetherd` also raises **freedesktop notifications** with `desktop-entry` hints and a
  **Reply** action, so Loft's existing `NotificationServer` (`src/services/Notifications.qml`)
  shows them with no code.
- The CLI (`tether --bt-calls`, `--bt-call`, `--bt-answer`, …) is good for niri keybinds.
- Privacy: socket commands are local-only. The message journal and contact cache are
  encrypted at rest by default, with the key in libsecret (`bt_set_retention`).

Related: [tether-web](https://github.com/napisani/tether-web) is a headless web UI (MIT,
0 stars, pushed 2026-10-13).

---

## 2. What an iPhone actually exposes to a Linux box

| Channel | What you get | Needs | Notes |
|---|---|---|---|
| **Bluetooth MAP** (iOS = MSE server) | Incoming SMS **and iMessage** text, send SMS/iMessage (routed as iMessage when the recipient supports it), mark read | Pairing as Hands-Free + "Show Message Notifications" toggle | Text only, no history before connect, no group IDs. Confirmed on iOS 26.5 by [iphonebridge](https://github.com/gabrielmeir53/iphonebridge#-the-imessage-surprise), [BlueFerry](https://github.com/erikwb/blueferry#what-works), [tether](https://github.com/zackb/tether/blob/main/docs/BLUETOOTH.md) |
| **Bluetooth PBAP** | Contacts, recents/favourites, call history | "Sync Contacts" toggle | Encrypted cache in tether and BlueFerry |
| **BLE ANCS** | Every app's notifications (title/subtitle/body, app id), positive/negative actions | Dual-mode bond with LE half, BlueZ bearer API, iOS 26+ in tether/BlueFerry | [Apple ANCS spec](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html). No deep links, no inline reply |
| **BLE AMS** (Apple Media Service) | Now playing + remote play/pause/skip/volume of the iPhone's player | Same LE link as ANCS | Implemented by [BlueFerry media control](https://github.com/erikwb/blueferry/blob/main/docs/en/user/media-control.md), not by tether |
| **BLE Battery Service** | Exact phone battery % | LE link | [BlueFerry phone status](https://github.com/erikwb/blueferry/blob/main/docs/en/user/phone-status.md). BlueZ exposes it as `org.bluez.Battery1` (Loft reads that); tether ≥ 0.3.0 reports it too, older tether only HFP's 20 % steps |
| **HFP** (Linux = HF) | Ring, caller ID, answer/decline/dial/DTMF; optional call audio | BlueZ `Telephony1` or oFono or PipeWire telephony | See §1 Calls |
| **A2DP sink** | Phone audio played on the desktop | PipeWire `a2dp_sink` role | Usually *unwanted* here (it steals the phone's audio) |
| **USB / Wi-Fi sync (lockdownd, usbmuxd)** | Device info, **battery**, AFC filesystem (DCIM photos), iTunes-style backups, syslog, screenshots (dev image) | Trust pairing over USB once, then Wi-Fi sync | [libimobiledevice README](https://github.com/libimobiledevice/libimobiledevice#readme) |
| **AirPlay** (iPhone → Linux) | Screen mirroring + audio, video casting | UxPlay on the LAN | Not remote control |
| **AWDL / AirDrop** | AirDrop send/receive | Wi-Fi card with active monitor mode + injection (OWL) | Impractical, see §4.5 |
| **Third-party iOS app** | Clipboard (banner on every read), files, share sheet, URLs | App in foreground, or periodic background wake | [tether DESIGN.md §2](https://github.com/zackb/tether/blob/main/docs/DESIGN.md) on iOS sandbox limits |
| **Apple IDS/APNs emulation** | Full iMessage (attachments, tapbacks, typing, groups, history via CloudKit), FaceTime notices, Find My | Apple ID + Mac hardware identifiers | §4.3, carries account risk |
| **iCloud web APIs** | Find My (locate, play sound), contacts, photos | Apple ID + 2FA | [pyicloud](https://github.com/timlaing/pyicloud) |

---

## 3. iPhone comparison table

Legend: ✅ works · 🟡 partial/experimental · ❌ no · — not in scope.
Msg = SMS/iMessage, Notif = notification mirroring, Clip = clipboard, Files = file transfer.

| Project | Msg read/send | Notif | Calls | Contacts | Clip | Files | Other | Transport / needs | Activity (GH) | License | nixpkgs | Loft integration surface |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **[tether](https://github.com/zackb/tether)** | ✅ MAP | 🟡 ANCS (beta) + actions | 🟡 HFP control (alpha), audio optional | ✅ PBAP | ✅ app | ✅ app | AirPods, OTP, open-URL | BT + Wi-Fi app; no Mac/cloud/Apple ID | 1461★, pushed 2026-10-14, v0.2.38 | MIT | ✅ `tether` 0.2.34 + upstream module | **JSON-lines Unix socket + subscribe**, CLI, fd.o notifications |
| **[BlueFerry](https://github.com/erikwb/blueferry)** | ✅ MAP (SMS/RCS/iMessage), careful groups | 🟡 ANCS + opt-in actions | 🟡 via oFono (opt-in) | ✅ PBAP | ❌ | ❌ | AMS media control, battery, call history, away-lock, OTP autocopy | BT only | 307★, pushed 2026-10-13, v0.8.1 (2026-09-15), created 2026-08 | GPL-2.0+ | ❌ | **Session D-Bus `io.weirdware.BlueFerry`** (content-free signals), **ships a Quickshell client** + JSON-lines bridge process |
| [iphonebridge (gabrielmeir53)](https://github.com/gabrielmeir53/iphonebridge) | ✅ MAP | ✅ ANCS (Intel adapters) | ✅ oFono | ✅ | ❌ | ❌ | OTP copy | BT only | 28★, pushed 2026-05-20 | GPL-2.0 | ❌ | CLI, fd.o notifications, GTK4 app |
| [tincan](https://github.com/quad341/tincan) | 🟡 MAP (no groups) | 🟡 ANCS | ❌ | ✅ | ❌ | ❌ | headless | BT only | 3★, 2026-07-13 | MIT | ❌ | daemon |
| [ancs4linux](https://github.com/pzmarzly/ancs4linux) | ❌ | ✅ ANCS | ❌ | ❌ | ❌ | ❌ | — | BLE | 296★, 2026-08-29; author now points to tether | custom | ❌ | D-Bus signals |
| [ancs-linux (kmod-midori)](https://github.com/kmod-midori/ancs-linux) / [ancs-bridge](https://github.com/mateuszkowalczyk/ancs-bridge) | ❌ | ✅ ANCS (one-way) | ❌ | ❌ | ❌ | ❌ | — | BLE | 21★ / 0★ | MIT | ❌ | fd.o notifications |
| **[BlueBubbles](https://github.com/BlueBubblesApp/bluebubbles-server)** | ✅ full iMessage (attachments, tapbacks, typing w/ Private API) | ❌ | ❌ (FaceTime partial) | via Mac | ❌ | attachments | Find My (Private API) | **Always-on Mac** (or macOS VM) + Apple ID | server 1106★ / app 1385★, active 2026-10 | Apache-2.0 | ✅ client `bluebubbles` 2.1.1 | **REST API + webhooks** ([docs](https://docs.bluebubbles.app/server/developer-guides)), Linux Flutter client |
| [mautrix-imessage](https://github.com/mautrix/imessage) | ✅ via Mac | ❌ | ❌ | — | ❌ | attachments | — | Mac (SIP off for all features) → Matrix | 457★, 2026-05-14 | AGPL-3.0 | ❌ | Matrix (libQuotient / NeoChat) |
| **[OpenBubbles](https://github.com/OpenBubbles/openbubbles-app) / [rustpush](https://github.com/OpenBubbles/rustpush)** | ✅ full iMessage, no Mac at runtime | ❌ | FaceTime | iCloud | ❌ | attachments | Find My, Shared Albums | Apple IDS/APNs emulation; **Mac hardware key** + Apple ID | 490★ / 232★, rustpush 2026-10-12 | Apache-2.0 / custom | ❌ | Flutter app (Android/Windows focus) |
| [Corten-Matrix](https://github.com/lrhodin/corten-matrix) / [rustpush Matrix bridge](https://github.com/jasonlaguidice/imessage) | ✅ full iMessage, CloudKit backfill | ❌ | FaceTime notices | iCloud/CardDAV | ❌ | attachments | Focus status | rustpush; Linux needs a one-time Mac key extraction; prebuilt Linux binaries only (Corten) | 75★ / 6★, 2026-10 | MPL-2.0 / AGPL-3.0 | ❌ | Matrix |
| [pypush](https://github.com/JJTech0130/pypush) | 🟡 mid-rewrite, iMessage removed for now | — | — | — | — | — | APNs client | Apple protocol emulation | 3786★, 2026-03-15 | **SSPL**, bought by Beeper | ❌ | library |
| [Beeper](https://www.beeper.com) | iMessage **only in Beeper Desktop on macOS** ([help](https://beeper.helpjuice.com/en_US/chat-networks/new-imessage-on-macos-getting-started-guide)) | — | — | — | — | — | other networks on Linux | Mac for iMessage | active | proprietary | ✅ `beeper` 4.3.73 | Matrix-ish |
| [AirMessage](https://github.com/airmessage/airmessage-server) | ✅ via Mac | — | — | — | — | — | — | Mac | server last push **2022-10-21** (dormant) | Apache-2.0 | ❌ | — |
| [KDE Connect iOS](https://apps.apple.com/us/app/kde-connect/id1580245991) | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | remote input, run commands, presenter | Wi-Fi app (iOS 15+) | [kdeconnect-ios](https://invent.kde.org/network/kdeconnect-ios) 426★ mirror, active | GPL | ✅ `kdePackages.kdeconnect-kde` | D-Bus (`org.kde.kdeconnect`) |
| [LocalSend](https://github.com/localsend/localsend) | — | — | — | — | text | ✅ | — | Wi-Fi app, open [protocol](https://github.com/localsend/protocol) | 94k★, 2026-10-10 | Apache-2.0 | ✅ `localsend` 1.18.0 + `programs.localsend` | app / reimplementable REST protocol |
| [OpenDrop](https://github.com/seemoo-lab/opendrop) + [OWL](https://github.com/seemoo-lab/owl) | — | — | — | — | — | 🟡 AirDrop | — | AWDL; Wi-Fi card with active monitor + injection | 9.8k★ / 1.5k★ (**OWL archived**) | GPL-3.0 | ❌ | CLI |
| [UxPlay](https://github.com/FDH2/UxPlay) | — | — | — | — | — | — | **AirPlay mirroring + audio, HLS video** | LAN (mDNS or BLE beacon) | 3194★, 2026-10-11, v1.73/1.74 | GPL-3.0 | ✅ `uxplay` 1.73.7 | process + GStreamer window |
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) (+usbmuxd, ifuse) | — | — | — | (sync) | — | ✅ AFC/photos | battery, backups, syslog, screenshots | USB, or Wi-Fi sync | 8254★, 1.4.0 (2025-10-10) | LGPL-2.1 | ✅ `libimobiledevice` 1.4.0, `usbmuxd`, `ifuse` | CLI / C lib |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) / [idevice (Rust)](https://github.com/jkcoxson/idevice) | — | — | — | — | — | ✅ | iOS 17+ RemoteXPC developer services | USB/Wi-Fi | 2871★ / 536★, active | GPL-3.0 / MIT | ✅ `python3Packages.pymobiledevice3` / ❌ | Python / Rust crate |
| [pyicloud](https://github.com/timlaing/pyicloud) | — | — | — | iCloud | — | — | **Find My: locate + play sound** | iCloud web API, Apple ID + 2FA | 173★, 2026-10-13 (maintained fork of [picklepete](https://github.com/picklepete/pyicloud)) | MIT | ✅ `python3Packages.pyicloud` 2.6.5 | Python |
| Microsoft Phone Link (iOS) | 🟡 MAP-style (no groups, no media) | ✅ | ✅ | ✅ | — | — | — | Windows 11 only | — | proprietary | — | reference only ([MacRumors](https://macrumors.com/2023/02/28/microsoft-windows-imessage)) |
| Intel Unison | — | — | — | — | — | — | — | **Discontinued** 2025, end of support 2026-01-01 ([unison.intel.com](https://unison.intel.com), [Dell KB](https://www.dell.com/support/kbdoc/en-us/000337603/intel-unison-end-of-service-announcement?lang=en)) | — | — | — | — |

---

## 4. Per-project notes (iPhone)

### 4.1 Bluetooth "car-kit" bridges (no Mac, no Apple ID)

These all use the same trick (Hands-Free class + MAP/PBAP/ANCS/HFP). They differ in polish,
API and calls stack.

**tether.** See §1. Strengths for Loft:
- MIT license.
- In nixpkgs, with an upstream NixOS module.
- A Unix-socket JSON API that QML can use directly.
- Also covers clipboard and files through its own iOS app.
- The most extensive empirical log of iOS/BlueZ behaviour anywhere
  ([BLUETOOTH.md](https://github.com/zackb/tether/blob/main/docs/BLUETOOTH.md) is about 3,700
  lines of dated findings).

Weaknesses:
- One maintainer.
- ANCS is "beta" and calls "alpha".
- No AMS media control.
- Needs `bluetoothd --experimental`.

**BlueFerry.** Created 2026-08, very active. It covers the same features plus:
- **AMS media control** (now playing + transport).
- **Exact battery** from the LE Battery Service.
- **Away lock**: locks the session when the phone has been gone N seconds, and never unlocks
  ([proximity-lock](https://github.com/erikwb/blueferry/blob/main/docs/en/user/proximity-lock.md)).
- **Click rules** that map an app's notification to a desktop app.
- **Opt-in ANCS action buttons**.
- **Calls through oFono**, with audio via PipeWire
  ([calls.md](https://github.com/erikwb/blueferry/blob/main/docs/en/user/calls.md)).

Its API is the **session D-Bus** service `io.weirdware.BlueFerry` with `Messages1`,
`Events1`, `Presence1`, `CallHistory1`, `Media1` and `Calls1`
([dbus-api.md](https://github.com/erikwb/blueferry/blob/main/docs/en/developer/dbus-api.md)).
Its signals carry no content: clients re-fetch on `HistoryChanged`.

Its Quickshell client (`data/quickshell/*.qml`) runs `blueferry-quickshell-bridge`, a
JSON-lines stdio process, because Quickshell has no generic D-Bus client. That QML is
GPL-2.0+, so Loft (MIT) should learn from it, not copy it.

Python, not in nixpkgs, and developed on an iPhone 16 Pro Max running iOS 26.5. The author
warns: "don't make it your only way to receive an important message yet"
([README](https://github.com/erikwb/blueferry#blueferry)).

**iphonebridge** ([gabrielmeir53](https://github.com/gabrielmeir53/iphonebridge)). Python,
GPL-2.0, GTK4. tether credits it for the original MAP research. Its most useful note is
about hardware: **ANCS needs an Intel adapter. Realtek and every USB dongle they tested
fail**, because their legacy key negotiation blocks the cross-transport key derivation iOS
needs. MAP and PBAP work on any adapter
([README requirements](https://github.com/gabrielmeir53/iphonebridge#-requirements)). Last
push 2026-05. [santisbon/iphonebridge](https://github.com/santisbon/iphonebridge) is an
unrelated project with the same name.

**ANCS-only clients**: [ancs4linux](https://github.com/pzmarzly/ancs4linux) (the original
technique; the author no longer uses it and points to tether),
[kmod-midori/ancs-linux](https://github.com/kmod-midori/ancs-linux) (Rust),
[ancs-bridge](https://github.com/mateuszkowalczyk/ancs-bridge) (Rust, one-way), and the
archived fork [bmh129/ancs4linux](https://github.com/bmh129/ancs4linux). These are superseded
by tether and BlueFerry.

### 4.2 Mac-relay iMessage

**BlueBubbles** ([server](https://github.com/BlueBubblesApp/bluebubbles-server),
[app](https://github.com/BlueBubblesApp/bluebubbles-app)). A macOS server reads
`chat.db` / drives Messages.app and exposes a **REST API + webhooks**
([developer guides](https://docs.bluebubbles.app/server/developer-guides)). The **Private
API** (needs SIP disabled,
[guide](https://docs.bluebubbles.app/server/advanced/disabling-sip-on-unofficial-macs-for-the-private-api))
adds typing, tapbacks, edits and group management. The Linux Flutter client is in nixpkgs
(`bluebubbles` 2.1.1). This is the most complete iMessage you can get on Linux, but it needs
an **always-on Mac**.

A **macOS VM is "by no means an easy process, and it is not guaranteed to work"**, and
BlueBubbles recommends "real Mac hardware to avoid compromising your Apple ID" (suggesting a
$50–75 used Mac mini)
([Running a macOS VM](https://docs.bluebubbles.app/server/advanced/macos-virtualization/running-a-macos-vm),
plus a separate "Enabling iMessage in a VM" guide).

For Cody, the T2 MacBooks `nomad` and `stowaway` dual-boot macOS, but they are laptops and
not always on. A KVM macOS guest on THEBATTLESHIP is possible but fragile: iMessage
activation in VMs needs serial spoofing, and it adds load to a real-time audio box.

**mautrix-imessage** ([repo](https://github.com/mautrix/imessage)). The Matrix bridge runs
*on* a Mac. Full features need SIP disabled. AGPL-3.0, last push 2026-05.
[beeper/imessage](https://github.com/beeper/imessage) is archived (2024).

**AirMessage** ([server](https://github.com/airmessage/airmessage-server)). Mac relay, server
dormant since 2022. Skip it.

**Beeper**. iMessage is offered only in **Beeper Desktop on macOS**, with "no plans to
support these on other platforms"
([Beeper help](https://beeper.helpjuice.com/en_US/chat-networks/new-imessage-on-macos-getting-started-guide)).
Recent release notes mention iMessage fixes only in a macOS context
([release notes](https://releasebot.io/updates/beeper/beeper-desktop)). Beeper Mini, the
2023 Android app that emulated Apple's protocol, was shut down after Apple blocked it
([9to5Mac](https://viptest.9to5mac.com/guides/beeper/)). On Linux, Beeper is useful for
*other* networks (WhatsApp, Signal, Google Messages), not iMessage.

### 4.3 Apple-protocol emulation (no Mac at runtime, Apple ID required)

**rustpush / OpenBubbles** ([rustpush](https://github.com/OpenBubbles/rustpush),
[OpenBubbles](https://github.com/OpenBubbles/openbubbles-app)). A Rust implementation of
Apple IDS/APNs: iMessage with attachments, tapbacks, edits/unsend, typing, groups, FaceTime,
Find My and Shared Albums. "OpenBubbles requires access to a Mac and an Apple ID to
function": registration needs **validation data derived from real Mac hardware
identifiers**.

**Corten-Matrix** ([repo](https://github.com/lrhodin/corten-matrix)) and
**jasonlaguidice/imessage** ([repo](https://github.com/jasonlaguidice/imessage)) wrap
rustpush in mautrix bridgev2:
- On Linux they need a **one-time hardware key extracted from a Mac**.
- With an Intel Mac, that Mac is not needed afterwards. Apple Silicon needs a NAC relay
  running (jasonlaguidice). Corten's new extractor works on either.
- **Contact Key Verification must be disabled** on the Apple ID.
- Corten's Linux build ships only as **prebuilt binaries** ("native pieces … baked into the
  release"), and building from source is supported on macOS only. That is a trust and
  auditability concern.
- Phone-number registration is not possible (an iPhone on the account handles that).

A matrix-docker-ansible-deploy guide notes hardware keys "can be shared by a number of users
(approximately 20) before causing issues with Apple"
([doc](https://git.cqre.net/cqrenet/matrix-docker-ansible-deploy/raw/branch/master/docs/configuring-playbook-bridge-rustpush.md)).
Community opinion treats it as "harm reduction at best"
([Privacy Guides thread](https://discuss.privacyguides.net/t/is-openbubbles-a-safe-app-to-use-it-allows-for-imessages-on-android/32220)).

**Risk.** It is against Apple's terms. Apple has blocked emulation before (Beeper Mini). The
worst case is an Apple ID or device-serial lockout, and the Apple ID is also Cody's iCloud
account.

**Relevance to Cody:** `nomad` and `stowaway` are **Intel** MacBookPro15,1 machines running
macOS, so a one-time key extraction is feasible.

**pypush** ([repo](https://github.com/JJTech0130/pypush)). The original proof of concept.
It is now in a rewrite with iMessage "temporarily removed", licensed **SSPL**, and "purchased
by Beeper". Not usable.

### 4.4 Wi-Fi companion apps (clipboard, files)

- **tether iOS app**: clipboard text and images, files both ways, share-sheet → Linux
  clipboard/URL, OTP. TLS with pinned self-signed certs, no cloud. iOS limits: every
  `UIPasteboard` read shows a banner, and background sync is periodic, not real-time
  ([DESIGN.md](https://github.com/zackb/tether/blob/main/docs/DESIGN.md)).
- **KDE Connect iOS**: clipboard, send files/URLs, remote touchpad/keyboard, presenter, run
  commands. iOS 15+, version 0.5.7. No notifications or SMS on iOS
  ([App Store](https://apps.apple.com/us/app/kde-connect/id1580245991)). Desktop side is
  `kdePackages.kdeconnect-kde` with `programs.kdeconnect`.
- **LocalSend**: the AirDrop-alike that actually works with an iPhone. Open HTTPS-on-LAN
  protocol, in nixpkgs with `programs.localsend` (opens firewall). Its
  [protocol](https://github.com/localsend/protocol) is simple enough to implement a
  receive-only endpoint in a Loft Rust crate, or Loft can just run the app.
- **iOS Shortcuts**: a Shortcut can POST the clipboard or a shared file to a local HTTP
  endpoint. That is a zero-install fallback, but it is what tether's share extension already
  does better.

### 4.5 AirDrop on Linux

**OpenDrop** speaks AirDrop but needs **AWDL**, which on Linux means **OWL**. OWL needs a
Wi-Fi card with **active monitor mode + frame injection** (the authors used an Atheros
AR9280). It takes the interface over exclusively, so there is no concurrent AP connection,
and it does not work in VMs ([OWL README](https://github.com/seemoo-lab/owl#requirements)).
**OWL is archived.** Sending to "contacts only" devices needs AirDrop keys extracted from
macOS. THEBATTLESHIP's MediaTek MT7927 is Wi-Fi 7 with an untested AWDL story, and losing
Wi-Fi while AirDropping is a non-starter.

**Verdict: not feasible for daily use.** Use LocalSend or tether's share extension.

For context, Google added AirDrop interop to Quick Share on Pixel 10 and Pixel 9 (iOS side
"Everyone for 10 minutes")
([ostechnix](https://ostechnix.com/android-quick-share-now-works-with-airdrop/),
[Privacy Guides](https://www.privacyguides.org/news/2026/02/24/google-expands-quick-shares-airdrop-support-to-pixel-9-series/)).
There is no open Linux implementation of that path yet.

### 4.6 AirPlay to Linux (screen mirroring)

**UxPlay**: AirPlay mirror + audio server, HLS video (YouTube) and recording to mp4. Version
1.74 is experimental and adds an internal mDNS (no avahi needed). Discovery can also run over
a BLE beacon ([README](https://github.com/FDH2/UxPlay#readme)). nixpkgs `uxplay` 1.73.7. One
direction only: iPhone → Linux, with no remote control. Loft can start or stop it from the
Control Center ("Mirror iPhone" tile) and treat its window as a niri floating window.

For audio-only AirPlay 2, use [shairport-sync](https://github.com/mikebrady/shairport-sync)
(nixpkgs 5.5.2). [RPiPlay](https://github.com/FD-/RPiPlay) is stale (nixpkgs 2021).

### 4.7 USB / Wi-Fi sync tooling

- **libimobiledevice 1.4.0 + usbmuxd + ifuse**: `ideviceinfo -q com.apple.mobile.battery`
  (exact battery), `idevicebackup2` (full local backups), `ifuse` / `afcclient` (DCIM photo
  import), `idevicesyslog`, `idevicenotificationproxy`, and `idevicescreenshot` (needs the
  developer image). Over Wi-Fi it works for "WiFi sync"-enabled devices once the phone has
  been trusted over USB ([README](https://github.com/libimobiledevice/libimobiledevice#readme)).
  NixOS has `services.usbmuxd`.
- **pymobiledevice3** (Python, GPL-3.0, nixpkgs) and **idevice** (Rust, MIT): newer stacks
  that handle the iOS 17+ RemoteXPC/tunnel developer services. idevice is a natural fit if
  Loft grows a Rust "phone" crate.
- Loft use: a "Back up iPhone" or "Import photos" action when the phone is plugged in
  (`DeviceEvents.qml` already watches devices), and a battery readout as a fallback to
  Bluetooth.

### 4.8 Find My

[pyicloud](https://github.com/timlaing/pyicloud) (maintained fork, MIT, nixpkgs 2.6.5)
covers Find My: device location and **play sound**. It needs the Apple ID password and a 2FA
session cookie stored locally. With Advanced Data Protection on, iCloud web access has to be
allowed for this to work, so treat it as a possible blocker.
[FindMy.py](https://github.com/malmeloo/FindMy.py) targets the Find My *network*
(AirTags/accessories), not "ring my iPhone". A "Find My iPhone → Play sound" button is cheap,
but it means storing iCloud credentials. Make it opt-in.

---

## 5. Android (brief)

| Project | Covers | Transport | Activity | License | nixpkgs | Loft surface |
|---|---|---|---|---|---|---|
| [KDE Connect](https://github.com/KDE/kdeconnect-kde) | Notifications + reply, SMS read/send, clipboard, files, media control, ring phone, battery, remote input, run commands | Wi-Fi/LAN app | 4056★, 2026-10-14 | GPL | ✅ `kdePackages.kdeconnect-kde` 26.08.1, `programs.kdeconnect` | `kdeconnectd` D-Bus `org.kde.kdeconnect` |
| [Valent](https://github.com/andyholmes/valent) | KDE Connect protocol, GTK4 | LAN | 919★, 2026-10-11, 1.0 alpha | GPL | ✅ `valent` 1.0.0.alpha.49 | D-Bus |
| [GSConnect](https://github.com/GSConnect/gnome-shell-extension-gsconnect) | KDE Connect protocol inside GNOME Shell | LAN | 3743★, 2026-10-02 | GPL-2.0 | ✅ `gnomeExtensions.gsconnect` | GNOME-Shell-bound, not usable in niri |
| [Zorin Connect](https://f-droid.org/app/com.zorinos.zorin_connect) | GSConnect/KDE Connect fork for Zorin OS | LAN | — | GPL | ❌ | Zorin-only |
| [scrcpy](https://github.com/Genymobile/scrcpy) | Screen mirror + full remote control, audio, camera | adb USB/TCP | 152k★, v4.1 | Apache-2.0 | ✅ `scrcpy` 4.1 | CLI |
| [mautrix-gmessages](https://github.com/mautrix/gmessages) | Google Messages (SMS/RCS) via web pairing | Google cloud | 182★, 2026-10-13 | AGPL-3.0 | ✅ 26.09 | Matrix |
| [RQuickShare](https://github.com/Martichou/rquickshare) | Quick Share / Nearby Share | LAN/BT | 3636★, 2026-05-01 | GPL-3.0 | ✅ `rquickshare` 0.11.5 | app |
| [LocalSend](https://github.com/localsend/localsend) | Files, text | LAN | 94k★ | Apache-2.0 | ✅ | app / protocol |
| Bluetooth MAP/PBAP/HFP | Android also serves MAP/PBAP/HFP, so tether-style SMS + calls would work; there is no ANCS equivalent | BT | — | — | — | tether is iPhone-scoped by design |

For Android the answer is **KDE Connect (`kdeconnectd`) + its D-Bus API**, with scrcpy for
mirroring. That would be a separate Loft "phone provider" behind the same QML model.

---

## 6. Cody's hardware and fleet: what matters

Checked live on THEBATTLESHIP, 2026-10-13:

- **Bluetooth controller:** `hci0` is Realtek (manufacturer 0x005d, BT 4.2, USB
  `0bda:c820`, `rtl8821c_fw`). The MT7927's BT side (`0489:e13a`) shows as `hci1` and fails
  init (`Opcode 0x0c03 failed: -16`), so it isn't usable.
  - MAP, PBAP and HFP (messages, contacts, calls) should work on the Realtek.
  - **ANCS (notifications) is at risk**: iphonebridge reports Realtek and USB dongles fail
    the LE bond. tether's dual-bond diagnostics (`bt_pair_result.dual_bond`) will say for
    sure.
  - Options if it fails: a known-good controller (Intel AX2xx M.2/PCIe, or a MediaTek
    MT7925 card; tether's recorded success is MT7925 + BlueZ 5.87), or a newer kernel that
    brings up the MT7927 BT half.
- **BlueZ 5.87** (meets ≥ 5.86). It is **not** started with `Experimental`, and the fleet
  aspect `fleet.hardware._.bluetooth` sets only `enable` + `powerOnBoot`. Fix:
  `hardware.bluetooth.settings.General.Experimental = true` plus the class unit, or simply
  import tether's NixOS module (`programs.tether.bluetooth.enable`).
- **PipeWire 1.6.8 / WirePlumber 0.5.x** support `org.pipewire.Telephony`. THEBATTLESHIP's
  audio graph is a Dante/RT setup, so the `bluez5.roles` change (drop `hfp_hf`, consider
  dropping `a2dp_sink` so the phone's audio stays on the phone) must go in the fleet's
  WirePlumber config, not ad hoc. Keep call audio on the phone at first.
- **Conflicts already in the fleet:**
  - `services.blueman.enable = true` runs its own pairing agent, which can race tether's
    agent during pairing.
  - `librepods` (AirPods, AAP) takes the single AAP channel. Leave tether's AirPods feature
    off.
- **Intel Macs on hand** (`nomad`, `stowaway`, MacBookPro15,1) make the rustpush key
  extraction possible, and could host BlueBubbles part-time from macOS. Neither is always on.

---

## 7. Recommendation for Loft

### Architecture

```
iPhone ──BT (MAP/PBAP/ANCS/HFP)──┐
       ──Wi-Fi (tether app)──────┤
                                 tetherd (pkgs.tether, user unit, NixOS module)
                                   │  $XDG_RUNTIME_DIR/tetherd.sock  (JSON lines, "subscribe")
                                   │  fd.o notifications ──► Loft NotificationServer (works today)
                                   ▼
                     src/services/Phone.qml   (Quickshell.Io.Socket + SplitParser)
                       ├─ island: incoming-call live activity, new-message banner w/ inline reply
                       ├─ Messages panel (threads/messages/compose, contacts search)
                       ├─ Control Center: phone tile (link state, carrier/signal/battery, send file, mirror)
                       └─ menu-bar extra: phone glyph + unread badge
```

- **Adopt as-is:** `tetherd`, the tether iOS app and its NixOS module, UxPlay, LocalSend
  (optional), and libimobiledevice/usbmuxd.
- **Build in Loft:** one `Phone.qml` service that holds a single subscribed
  `Quickshell.Io.Socket` to `tetherd.sock` (Socket is a DataStream, so a `SplitParser`
  splits lines; see the
  [Quickshell Socket docs](https://quickshell.org/docs/types/Quickshell.Io/Socket/)), plus a
  second short-lived socket for request/response. Everything else (island pages, panel,
  Control Center tile) binds to that service. No Rust is needed in phase 1–2. Add a small
  `crates/loft-phone` later only if JSON handling in QML gets heavy, or to normalise
  tether, BlueFerry, KDE Connect and a Matrix bridge behind one model.
- **Inline reply:** Loft's `NotificationServer` currently sets `actionsSupported: true`. Turn
  on `inlineReplySupported` and route the reply for `desktop-entry=com.tether.*`
  notifications to `bt_send_message`, so the island can reply in place instead of opening
  tether's dialog.
- **Why tether over BlueFerry:**
  - MIT license (matches Loft's MIT).
  - In nixpkgs, with an upstream module.
  - A socket API QML can use directly, with no Python bridge.
  - Covers clipboard and files too.
  - The largest user base, a very fast release cadence, and BlueZ-native calls without
    oFono.

  Keep BlueFerry as plan B: if tether's ANCS or calls misbehave on this hardware, BlueFerry
  is the drop-in replacement (via its D-Bus API through a tiny bridge). Upstreaming **AMS
  media control** to tether (or doing it in a Loft crate over the same LE link) is the one
  BlueFerry feature worth having.

### Phased plan

1. **Phase 0, hardware + system (fleet repo).**
   - Add the tether flake input and module in a `fleet` aspect: `programs.tether.enable`,
     `wifi.openFirewall`, `bluetooth.enable` + `adapters`.
   - Set BlueZ `Experimental`.
   - Make the WirePlumber `bluez5.roles` change.
   - Disable blueman's agent, or pair via tether.
   - Pair, then confirm `tether bt connection` shows MAP + PBAP + ANCS. If ANCS fails on the
     Realtek, pick a controller.
2. **Phase 1, notifications + clipboard + files.**
   - tether notifications land in the island through the existing server.
   - Add a Control Center phone tile (link state, phone battery, "Send file…" →
     `send_file`).
   - Merge tether clipboard pushes into the cliphist-backed `Clipboard.qml` history (tether
     writes via `wlr-data-control`, which niri supports).
   - LocalSend as an optional extra.
3. **Phase 2, messages.**
   - Messages panel on `bt_list_threads`, `bt_list_messages`, `bt_send_message` and the
     `bt_message` events; contact search via `bt_list_contacts`.
   - Island banner with inline reply; OTP chip from `otp_available` → copy.
   - Be clear in the UI that history starts at pairing, there are no attachments, and
     groups are best-effort.
4. **Phase 3, calls + extras.**
   - Island call live activity (ringing/active, caller from PBAP, Answer/Decline/Hang up via
     `bt_call_action`), a dial pad, recents.
   - Audio on the phone first; offer "audio on Mac-style desktop" as a toggle only after
     testing PipeWire telephony against the Dante graph.
   - Extras: "Mirror iPhone" (UxPlay) toggle, "Back up iPhone" / "Import photos"
     (libimobiledevice) on USB plug, away-lock (lock via logind when
     `bt_connection_changed` reports the phone gone for N seconds).
5. **Phase 4 (optional), full iMessage.** Only if attachments, tapbacks and history matter
   enough to accept Apple ID risk. Two options:
   - **Lower risk:** an always-on cheap Intel Mac mini running BlueBubbles server. Loft
     consumes its REST API + webhooks.
   - **No Mac at runtime:** Corten or the rustpush bridge with a key extracted once from
     `nomad`, behind a self-hosted Matrix homeserver; Loft uses libQuotient
     (`kdePackages.libquotient`) or a Rust Matrix client.

   Either way it **coexists** with tether (different transports) and needs de-duplication.

### Privacy and security trade-offs

| Path | Data leaves the room? | Credentials involved | Main risk |
|---|---|---|---|
| tether / BlueFerry (BT) | No. Phone ↔ PC only. Messages and contacts cached locally, encrypted with a libsecret key | Bluetooth bond keys; tether TLS cert + `known_hosts.json` | Bluetooth attack surface; `bluetoothd --experimental`; the class change makes the PC look like a car kit to every phone |
| tether Wi-Fi app | LAN only, mTLS with TOFU pinning | Self-signed cert | Anyone on the LAN can sit at the pairing prompt ([PROTOCOL.md §3](https://github.com/zackb/tether/blob/main/docs/PROTOCOL.md)) |
| BlueBubbles | Your own Mac; optional Firebase/Cloudflare tunnel for remote access | Apple ID on the Mac | Mac must stay on; Private API needs SIP off |
| rustpush / Corten / OpenBubbles | Apple's servers directly (as with real iMessage) | **Apple ID + Mac hardware identifiers**; CKV off | **Account or serial blocking, against ToS**; Corten's Linux build is closed-ish prebuilt |
| Beeper | Beeper cloud for non-iMessage networks | Network logins | Third-party cloud (iMessage there is Mac-only anyway) |
| pyicloud Find My | Apple iCloud web | **Apple ID password + 2FA session** stored locally | Credential storage; ADP may block it |
| UxPlay / LocalSend | LAN | None or PIN | Open listeners on the LAN (firewall them to trusted interfaces) |

### Open questions for Cody

1. **iOS version.** ANCS mirroring in tether and BlueFerry needs **iOS 26+**.
2. **Bluetooth controller.** Is he willing to swap or add one if notification mirroring fails
   on the Realtek RTL8821C? The MT7927's BT half doesn't initialise today. Same question for
   the laptops (`nomad`/`stowaway` have Apple/Broadcom BT).
3. **Phone on multiple machines.** The iPhone serves **one MAP session**: which machine owns
   it (THEBATTLESHIP vs. the laptops)?
4. **Call audio.** Calls on the desktop speakers/mic or kept on the phone? This decides the
   WirePlumber roles and interacts with the Dante/RT audio graph.
5. **Full iMessage.** Does he need attachments, tapbacks or history? If yes: an always-on Mac
   (BlueBubbles), or accept Apple ID risk for rustpush with a key from `nomad`?
6. **iCloud credentials.** OK to store them for "Find My → play sound"? Is Advanced Data
   Protection on?
7. **Blueman.** OK to drop blueman's agent (Loft's planned Bluetooth extra replaces it)?
8. **AirPods.** Keep `librepods`, or move AirPods handling to tether?

### AMS media control: what tetherd lacks

Checked against tether's source at v0.2.35 (what nixpkgs ships and the fleet runs) and at
v0.3.2 (2026-10-31, `main`): **tetherd has no Apple Media Service client.** It notes the AMS
service in the GATT tree (BLUETOOTH.md, "Apple Media Service `89d3502b-…` is also present") and
does nothing with it. `tether::MediaControl` is something else: MPRIS on *this* machine, used to
pause local players for calls and AirPods. Loft therefore has nothing to drive, and does not
fake a now-playing for the phone. (Away lock and exact battery are done: Settings → Phone,
FEATURES.md.)

AMS itself ([Apple's spec](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleMediaService_Reference/Introduction/Introduction.html))
lives on the same LE link and bond as ANCS, which tetherd already keeps up:

| Characteristic | UUID | Use |
|---|---|---|
| Service | `89D3502B-0F36-433A-8EF4-C502AD55F8DC` | |
| Remote Command | `9B3C81D8-57B1-4A8A-B8DF-0E56F7CA51C2` | write one byte: Play 0, Pause 1, TogglePlayPause 2, NextTrack 3, PreviousTrack 4, VolumeUp 5, VolumeDown 6, AdvanceRepeatMode 7, AdvanceShuffleMode 8, SkipForward 9, SkipBackward 10, Like 11, Dislike 12, Bookmark 13. Notify: the commands the current player supports |
| Entity Update | `2F7CABCE-808D-411F-9A0C-BB92BA96C102` | write `[EntityID, AttributeID…]` to subscribe (Player 0: Name 0, PlaybackInfo 1 = "state,rate,elapsed", Volume 2; Queue 1; Track 2: Artist 0, Album 1, Title 2, Duration 3). Notify: `[EntityID, AttributeID, Flags, UTF-8 value]`, Flags bit 0 = truncated |
| Entity Attribute | `C6B2F38C-23AB-46D8-A6AB-A3A870BBD5D7` | write `[EntityID, AttributeID]`, then read the full value of a truncated one |

What tetherd would need (a change to [zackb/tether](https://github.com/zackb/tether), not
made from here; the shape mirrors its ANCS client in `src/core/src/bluetooth/ancs/`):

1. **An AMS GATT client** next to `ancs::Client`: once `ServicesResolved` on the LE bearer and
   the bond is encrypted, find the service's three characteristics under the device's BlueZ
   object, `StartNotify` on Remote Command and Entity Update, write the Entity Update
   subscriptions above (one write per entity; iOS rejects writes before the bond is
   encrypted, retry like the ANCS `StartNotify` race), and follow truncated values with the
   Entity Attribute write + read. Rebuild it whenever the ANCS link is rebuilt.
2. **State**: player name, state (paused / playing / rewinding / fast-forwarding), rate,
   elapsed + the monotonic time it was reported (iOS only re-sends on changes), volume
   0–1, artist / album / title / duration, queue index / count / shuffle / repeat, and the
   supported command list.
3. **Socket protocol** (docs/PROTOCOL.md): a broadcast event
   `{"command":"bt_media","available":true,"player":"Music","state":"playing","rate":1.0,"elapsed":12.4,"elapsed_at":<unix ms>,"volume":0.6,"title":"…","artist":"…","album":"…","duration":215.0,"commands":["play","pause","toggle","next","previous","volume_up","volume_down","skip_forward","skip_backward"]}`
   on every change (and `available:false` when the LE link goes), `bt_media` in reply to a new
   `bt_get_media`, a command `bt_media_command {"action":"toggle"|"play"|"pause"|"next"|"previous"|"volume_up"|"volume_down"|"skip_forward"|"skip_backward"}` answered by
   `bt_media_result {success, action, message}`, a `media` entry in `protocol_info.capabilities`, and a
   `bt_set_media {enabled}` switch persisted like `bt_set_ancs` (AMS wakes the phone's media
   stack on every track change).
4. **Better still for every desktop, and zero Loft code**: export it as an MPRIS player on the
   session bus (`org.mpris.MediaPlayer2.tether_iphone`: `PlaybackStatus`, `Metadata`
   `xesam:title/artist/album`, `mpris:length`, `Position` from elapsed + rate, `Volume`,
   `CanGoNext/Previous/Play/Pause` from the supported commands; `PlayPause` / `Next` / … write
   Remote Command; `Seeked` is not possible, AMS has no seek). Loft's Now Playing, media keys
   and the island already follow MPRIS, so the phone would just appear as one more player. Its
   own `MediaControl` must then skip that player when pausing local media for calls.

With (3) Loft would add a `phone.js` reducer for `bt_media` and buttons in the phone panel;
with (4) nothing. BlueFerry already implements AMS (its `Media1` D-Bus interface,
[media-control.md](https://github.com/erikwb/blueferry/blob/main/docs/en/user/media-control.md))
and is the reference for the ordering quirks; running it next to tetherd is not an option,
since both would hold the same bond's ANCS link.

---

## Sources (primary)

- tether: [README](https://github.com/zackb/tether), [PROTOCOL.md](https://github.com/zackb/tether/blob/main/docs/PROTOCOL.md), [BLUETOOTH.md](https://github.com/zackb/tether/blob/main/docs/BLUETOOTH.md), [DESIGN.md](https://github.com/zackb/tether/blob/main/docs/DESIGN.md), [HEADLESS.md](https://github.com/zackb/tether/blob/main/docs/HEADLESS.md), [nix/module.nix](https://github.com/zackb/tether/blob/main/nix/module.nix), [releases](https://github.com/zackb/tether/releases)
- BlueFerry: [README](https://github.com/erikwb/blueferry), [D-Bus API](https://github.com/erikwb/blueferry/blob/main/docs/en/developer/dbus-api.md), [calls](https://github.com/erikwb/blueferry/blob/main/docs/en/user/calls.md), [media control](https://github.com/erikwb/blueferry/blob/main/docs/en/user/media-control.md), [phone status](https://github.com/erikwb/blueferry/blob/main/docs/en/user/phone-status.md), [proximity lock](https://github.com/erikwb/blueferry/blob/main/docs/en/user/proximity-lock.md), [ARCHITECTURE.md](https://github.com/erikwb/blueferry/blob/main/ARCHITECTURE.md), [omarchy-blueferry](https://github.com/erikwb/omarchy-blueferry)
- [iphonebridge](https://github.com/gabrielmeir53/iphonebridge), [tincan](https://github.com/quad341/tincan), [ancs4linux](https://github.com/pzmarzly/ancs4linux), [ancs-linux](https://github.com/kmod-midori/ancs-linux), [ancs-bridge](https://github.com/mateuszkowalczyk/ancs-bridge)
- [Apple ANCS specification](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html)
- BlueBubbles: [server](https://github.com/BlueBubblesApp/bluebubbles-server), [app](https://github.com/BlueBubblesApp/bluebubbles-app), [developer guides](https://docs.bluebubbles.app/server/developer-guides), [macOS VM](https://docs.bluebubbles.app/server/advanced/macos-virtualization/running-a-macos-vm), [SIP guide](https://docs.bluebubbles.app/server/advanced/disabling-sip-on-unofficial-macs-for-the-private-api)
- [mautrix-imessage](https://github.com/mautrix/imessage), [beeper/imessage (archived)](https://github.com/beeper/imessage), [AirMessage server](https://github.com/airmessage/airmessage-server)
- [OpenBubbles](https://github.com/OpenBubbles/openbubbles-app), [rustpush](https://github.com/OpenBubbles/rustpush), [Corten-Matrix](https://github.com/lrhodin/corten-matrix), [jasonlaguidice/imessage](https://github.com/jasonlaguidice/imessage), [rustpush bridge deploy doc](https://git.cqre.net/cqrenet/matrix-docker-ansible-deploy/raw/branch/master/docs/configuring-playbook-bridge-rustpush.md), [Privacy Guides discussion](https://discuss.privacyguides.net/t/is-openbubbles-a-safe-app-to-use-it-allows-for-imessages-on-android/32220), [pypush](https://github.com/JJTech0130/pypush)
- Beeper: [iMessage on macOS help](https://beeper.helpjuice.com/en_US/chat-networks/new-imessage-on-macos-getting-started-guide), [release notes](https://releasebot.io/updates/beeper/beeper-desktop), [9to5Mac on Beeper/Apple](https://viptest.9to5mac.com/guides/beeper/)
- [KDE Connect iOS (App Store)](https://apps.apple.com/us/app/kde-connect/id1580245991), [kdeconnect-kde](https://github.com/KDE/kdeconnect-kde), [Valent](https://github.com/andyholmes/valent), [GSConnect](https://github.com/GSConnect/gnome-shell-extension-gsconnect), [Zorin Connect (F-Droid)](https://f-droid.org/app/com.zorinos.zorin_connect)
- [LocalSend](https://github.com/localsend/localsend), [LocalSend protocol](https://github.com/localsend/protocol), [RQuickShare](https://github.com/Martichou/rquickshare), [scrcpy](https://github.com/Genymobile/scrcpy), [mautrix-gmessages](https://github.com/mautrix/gmessages)
- [OpenDrop](https://github.com/seemoo-lab/opendrop), [OWL](https://github.com/seemoo-lab/owl), Quick Share ↔ AirDrop: [ostechnix](https://ostechnix.com/android-quick-share-now-works-with-airdrop/), [Privacy Guides](https://www.privacyguides.org/news/2026/02/24/google-expands-quick-shares-airdrop-support-to-pixel-9-series/)
- [UxPlay](https://github.com/FDH2/UxPlay), [shairport-sync](https://github.com/mikebrady/shairport-sync)
- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice), [usbmuxd](https://github.com/libimobiledevice/usbmuxd), [ifuse](https://github.com/libimobiledevice/ifuse), [pymobiledevice3](https://github.com/doronz88/pymobiledevice3), [idevice](https://github.com/jkcoxson/idevice)
- [pyicloud (maintained fork)](https://github.com/timlaing/pyicloud), [FindMy.py](https://github.com/malmeloo/FindMy.py)
- [Intel Unison end of support](https://unison.intel.com), [Dell KB](https://www.dell.com/support/kbdoc/en-us/000337603/intel-unison-end-of-service-announcement?lang=en); Phone Link iPhone limits: [MacRumors](https://macrumors.com/2023/02/28/microsoft-windows-imessage)
- [Quickshell `Socket`](https://quickshell.org/docs/types/Quickshell.Io/Socket/), [librepods](https://github.com/librepods-org/librepods)
