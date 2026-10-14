import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Settings → Phone: the iPhone through tetherd (Phone.qml, PhoneConfig):
// its status, a pairing guide, what Loft shows, and tetherd's call control.
// Pairing itself is tetherd's (`tether bt pair`); Loft never pairs.
ColumnLayout {
    id: page
    spacing: 12

    component Hint: Text {
        Layout.fillWidth: true
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }

    // One step of the guide: a number, what to do, the command to run.
    component Step: RowLayout {
        id: step
        property int n
        property string text
        property string command: ""
        Layout.fillWidth: true
        spacing: 10

        Rectangle {
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 1
            implicitWidth: 20
            implicitHeight: 20
            radius: 10
            color: Theme.withAlpha(Theme.accent, 0.18)
            Text {
                anchors.centerIn: parent
                text: step.n
                color: Theme.accent
                font.family: Theme.fontUi
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            Text {
                Layout.fillWidth: true
                text: step.text
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
            Rectangle {
                visible: step.command !== ""
                Layout.fillWidth: true
                implicitHeight: cmd.implicitHeight + 12
                radius: 7
                color: Theme.withAlpha(Theme.text, 0.07)
                Text {
                    id: cmd
                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 9
                        rightMargin: 9
                    }
                    text: step.command
                    color: Theme.text
                    font.family: "monospace"
                    font.pixelSize: 11
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                }
            }
        }
    }

    // ── Status ──────────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "iPhone"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14

            Rectangle {
                implicitWidth: 52
                implicitHeight: 52
                radius: 14
                color: Phone.connected ? Theme.withAlpha("#34c759", 0.18) : Theme.withAlpha(Theme.text, 0.08)
                Icon {
                    anchors.centerIn: parent
                    text: Phone.glyph
                    size: 28
                    color: Phone.connected ? "#34c759" : Theme.subtext
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: Phone.link === "offline" || Phone.link === "unpaired" ? "No iPhone" : Phone.deviceName
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    text: {
                        const parts = [Phone.statusLine];
                        if (Phone.connected && Phone.carrier !== "")
                            parts.push(Phone.carrier);
                        if (Phone.connected && Phone.signal >= 0)
                            parts.push(`signal ${Phone.signal}/5`);
                        return parts.join("  ·  ");
                    }
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: Phone.detail
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
            }
            SettingsButton {
                visible: Phone.up
                text: "Messages"
                icon: "󰍩"
                onClicked: Phone.openMessages("")
            }
        }

        SettingsRow {
            label: "tetherd"
            hint: Phone.up ? `Running${Phone.version ? " · " + Phone.version : ""} · ${Phone.socketPath}` : `Not running — no socket at ${Phone.socketPath}`
        }
        SettingsRow {
            visible: Phone.up && Phone.link !== "unpaired"
            label: "Links"
            hint: {
                const l = Phone.state.link ?? {};
                const yes = b => b ? "on" : "off";
                return `Messages (MAP) ${yes(l.map_open)} · Contacts (PBAP) ${yes(l.pbap_open)} · Notifications (ANCS) ${yes(l.ancs_ready)} · Calls (HFP) ${yes(l.calls?.available)}`;
            }
        }
    }

    // ── What Loft shows ─────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Show"
        }
        SettingsRow {
            label: "Notifications"
            hint: "Every app's notifications from the iPhone, in the island and the Notification Center (tagged “· iPhone”)"
            SettingsSwitch {
                checked: PhoneConfig.notifications
                onToggled: on => PhoneConfig.notifications = on
            }
        }
        SettingsRow {
            label: "Messages"
            hint: "A banner for each new SMS / iMessage, with Reply"
            SettingsSwitch {
                checked: PhoneConfig.messages
                onToggled: on => PhoneConfig.messages = on
            }
        }
        SettingsRow {
            label: "Message previews"
            hint: "The text in the banner; off shows “New message”"
            SettingsSwitch {
                checked: PhoneConfig.previews
                onToggled: on => PhoneConfig.previews = on
            }
        }
        SettingsRow {
            label: "Calls"
            hint: "Incoming calls in the island with Answer and Decline, and the call timer"
            SettingsSwitch {
                checked: PhoneConfig.calls
                onToggled: on => PhoneConfig.calls = on
            }
        }
        SettingsRow {
            visible: Phone.up
            label: "Call control in tetherd"
            hint: Phone.callControl ? "On: answer, decline, hang up and dial from here. The audio stays on the iPhone." : "Off (tetherd's default): calls aren't seen at all, and there's no battery or signal. Needs BlueZ's Telephony (see the pairing guide)."
            SettingsSwitch {
                checked: Phone.callControl
                onToggled: on => Phone.setCallControl(on)
            }
        }
    }

    // ── Pairing guide ───────────────────────────────────────────────────
    SettingsCard {
        spacing: 10
        PageHeader {
            title: "Pairing your iPhone"
        }
        Hint {
            text: "tetherd makes this computer look like a car's hands-free kit, so the iPhone shares messages, contacts, notifications and calls with it over Bluetooth — no Mac, no Apple ID. Loft only shows what tetherd gets; pairing happens in tetherd. Do it once, by hand, with the iPhone next to the computer and unlocked."
        }
        Step {
            n: 1
            text: "The system side (Nix): tether installed, the tetherd user service running, BlueZ started with Experimental = true, and the Bluetooth class set to Hands-Free (tether-btclass@hci0). Then reboot or restart bluetooth. Check what's still missing:"
            command: "tether bt setup"
        }
        Step {
            n: 2
            text: "Close other pairing agents first (blueman's applet would race tetherd's). If the computer has several Bluetooth controllers, pick the working one:"
            command: "tether bt adapter hci0"
        }
        Step {
            n: 3
            text: "On the iPhone open Settings → Bluetooth (leave it open, so it's discoverable). Find its address and pair; confirm the same code on both:"
            command: "tether bt devices\ntether bt pair AA:BB:CC:DD:EE:FF"
        }
        Step {
            n: 4
            text: "On the iPhone: Settings → Bluetooth → (i) next to this computer → turn on “Show Message Notifications” and “Sync Contacts”. They can take a minute to appear; to make the phone offer them again:"
            command: "tether bt solicit"
        }
        RowLayout {
            Layout.leftMargin: 30
            spacing: 8
            SettingsButton {
                visible: Phone.up && Phone.link !== "unpaired"
                text: "Ask the iPhone again"
                onClicked: Phone.solicit()
            }
            SettingsButton {
                visible: Phone.up && !Phone.callControl
                text: "Turn on call control"
                onClicked: Phone.setCallControl(true)
            }
        }
        Step {
            n: 5
            text: "Calls (optional): turn on call control here or with `tether bt calls-enable on`. WirePlumber must not take the phone's Hands-Free link (drop hfp_hf from bluez5.roles), or BlueZ exposes no Telephony. Call audio stays on the iPhone."
        }
        Step {
            n: 6
            text: "Turn on Features → iPhone (done, if you're reading this) and check this page: Messages, Contacts and Notifications should say “on”. tetherd's own diagnostics:"
            command: "tether bt connection\ntether status"
        }
        Hint {
            text: "Limits (iOS, not tether): messages arrive only while connected (no history before pairing), no photos or reactions, SMS and iMessage look the same, and only one computer at a time can hold the iPhone's messages. Notifications need iOS 26 or later."
        }
    }

    // ── Hardware note ───────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Bluetooth controller"
        }
        Hint {
            text: "Notifications (ANCS) need a bond that covers Bluetooth LE as well as classic. On THEBATTLESHIP the working controller is a Realtek RTL8821C (USB 0bda:c820); Realtek controllers and USB dongles are reported to fail that LE bond, so messages, contacts and calls should work but notifications may not. tetherd's pair result says for sure (dual_bond). If it fails: an Intel AX2xx or MediaTek MT7925 card is known to work."
        }
    }
}
