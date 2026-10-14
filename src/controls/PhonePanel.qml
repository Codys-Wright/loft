import QtQuick
import QtQuick.Layouts
import qs.services

// iPhone (feature "phone"): the phone tetherd is linked to, its battery,
// signal and carrier (from Hands-Free), the call on the line, the latest
// conversations, and Messages… — the Control Center tile and the optional
// menu bar extra.
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    PanelHeader {
        title: Phone.link === "offline" || Phone.link === "unpaired" ? "iPhone" : Phone.deviceName
        trailing: Phone.battery >= 0 ? `${Phone.battery}%` : ""
        subtitle: {
            switch (Phone.link) {
            case "offline":
                return "Not connected — tetherd isn't running";
            case "unpaired":
                return "No iPhone paired";
            case "away":
                return "Not nearby";
            case "linking":
                return "Connecting…";
            }
            return Phone.carrier !== "" ? `Connected · ${Phone.carrier}` : "Connected";
        }
    }

    // The call on the line.
    PanelRow {
        visible: Phone.activeCall !== null
        glyph: "󰏶"
        glyphActive: true
        text: Phone.callerName(Phone.activeCall)
        detail: Phone.activeCall?.connected ? `On a call · ${Phone.callTime}` : Phone.callStateLabel(Phone.activeCall)
        trailing: "Hang Up"
        onClicked: Phone.hangup()
    }

    PanelRow {
        visible: Phone.connected && (Phone.battery >= 0 || Phone.signal >= 0)
        interactive: false
        text: "Battery"
        trailing: Phone.battery >= 0 ? `${Phone.battery}%` : "—"
        trailingGlyph: Phone.batteryGlyph()
    }
    PanelRow {
        visible: Phone.connected && Phone.signal >= 0
        interactive: false
        text: "Signal"
        trailing: Phone.carrier
        trailingGlyph: Phone.signalGlyph()
    }

    PanelSection {
        visible: Phone.threads.length > 0
        text: "Messages"
        trailing: Phone.unread > 0 ? `${Phone.unread} unread` : ""
    }
    Repeater {
        model: Phone.threads.slice(0, root.details ? 6 : 3)
        delegate: PanelRow {
            required property var modelData
            glyph: "󰍩"
            glyphActive: (modelData.unread ?? 0) > 0
            text: Phone.threadTitle(modelData)
            detail: modelData.preview ?? ""
            trailing: Phone.shortTime(modelData.timestamp)
            bold: (modelData.unread ?? 0) > 0
            onClicked: {
                root.dismiss();
                Phone.openMessages(modelData.thread);
            }
        }
    }

    PanelSeparator {}
    PanelRow {
        visible: Phone.up
        text: "Messages…"
        onClicked: {
            root.dismiss();
            Phone.openMessages("");
        }
    }
    PanelRow {
        text: "Phone Settings…"
        onClicked: root.openSettings("phone")
    }
}
