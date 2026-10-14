import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services
import qs.settings

// Utilities → Updates: what `nix flake update` would change in the system
// flake (services/Updates.qml → `loft updates check`, run on a scratch copy;
// the real flake and lock are only read). Inputs with new revisions (old →
// new, dates, commit counts linking to the GitHub compare), the nixpkgs
// version and the installed packages it would bump. "Update…" (toolbar)
// shows the commands to run yourself — Loft never switches the system.
ColumnLayout {
    id: page
    spacing: 12

    property bool showCommands: false
    property bool showAllPackages: false
    property bool showUnchanged: false
    readonly property var s: Updates.summary

    // Ticks the "checking … 0:42" line.
    property real now: Date.now()
    Timer {
        interval: 1000
        repeat: true
        running: Updates.running && page.visible
        onTriggered: page.now = Date.now()
    }

    function date(t) {
        return t ? Qt.formatDate(new Date(t * 1000), "MMM d") : "";
    }

    component Label: Text {
        color: Theme.text
        font.family: Theme.fontUi
        font.pixelSize: 12
    }
    component Sub: Text {
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
    }

    // ── Status ───────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Rectangle {
                Layout.preferredWidth: 44
                Layout.preferredHeight: 44
                radius: 12
                color: Theme.badgeColor(page.s && !page.s.error && Updates.changed.length === 0 ? "green" : "blue")
                Icon {
                    anchors.centerIn: parent
                    text: Updates.running ? "󰑐" : "󰚰"
                    size: 22
                    color: "white"
                    RotationAnimator on rotation {
                        running: Updates.running
                        from: 0
                        to: 360
                        duration: 1400
                        loops: Animation.Infinite
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: Updates.running ? "Checking for updates…" : !page.s ? "Not checked yet" : page.s.error ? "Couldn't check" : Updates.changed.length === 0 ? "Everything is up to date" : `${Updates.changed.length} input${Updates.changed.length === 1 ? "" : "s"} can be updated` + (page.s.indirectChanged ? ` (+${page.s.indirectChanged} indirect)` : "")
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Sub {
                    Layout.fillWidth: true
                    text: Updates.running ? `${Updates.stage} · ${Math.floor((page.now - Updates.startedAt) / 1000)} s` : !page.s ? "Updates a scratch copy of your system flake's lock and compares. Your flake isn't changed; nothing is built." : `${page.s.flake.replace(Quickshell.env("HOME"), "~")} · checked ${Updates.ago(page.s.checkedAt)}` + (page.s.seconds ? ` (${Math.round(page.s.seconds)} s)` : "")
                    wrapMode: Text.Wrap
                }
                Sub {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: Updates.error !== "" ? Updates.error : (page.s?.error ?? "")
                    color: Theme.urgent
                    wrapMode: Text.Wrap
                }
            }

            SettingsButton {
                visible: !page.s && !Updates.running
                primary: true
                text: "Check Now"
                onClicked: Updates.refresh()
            }
        }

        // nixpkgs at a glance.
        RowLayout {
            Layout.fillWidth: true
            visible: !!page.s?.nixpkgs
            spacing: 8
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 34
                radius: 10
                color: Theme.withAlpha(Theme.text, 0.05)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 8
                    Icon {
                        text: "󱄅"
                        size: 14
                        color: Theme.badgeColor("blue")
                    }
                    Label {
                        text: "nixpkgs"
                        font.weight: Font.DemiBold
                    }
                    Label {
                        Layout.fillWidth: true
                        readonly property var np: page.s?.nixpkgs ?? {}
                        readonly property var row: Updates.changed.find(i => i.name === "nixpkgs")
                        text: np.changed ? `${np.old ?? "?"}  →  ${np.new ?? "?"}` + (row?.commits ? `  ·  ${row.commits.toLocaleString(Qt.locale(), "f", 0)} commits` : "") : `${np.old ?? ""} — current`
                        color: np.changed ? Theme.text : Theme.subtext
                        elide: Text.ElideRight
                        font.features: {
                            "tnum": 1
                        }
                    }
                }
            }
        }
    }

    // ── Changed inputs ───────────────────────────────────────────────────
    SettingsCard {
        visible: Updates.changed.length > 0
        spacing: 2

        PageHeader {
            title: "Inputs with updates"
        }

        Repeater {
            model: Updates.changed
            delegate: Rectangle {
                id: irow
                required property var modelData
                required property int index
                readonly property var o: modelData.old ?? {}
                readonly property var n: modelData.new ?? {}
                Layout.fillWidth: true
                implicitHeight: 40
                radius: 8
                color: ih.hovered ? Theme.withAlpha(Theme.text, 0.07) : index % 2 === 1 ? Theme.withAlpha(Theme.text, 0.03) : "transparent"
                HoverHandler {
                    id: ih
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 10
                    ColumnLayout {
                        Layout.preferredWidth: 190
                        Layout.maximumWidth: 190
                        spacing: 0
                        Label {
                            Layout.fillWidth: true
                            text: irow.modelData.name
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Sub {
                            Layout.fillWidth: true
                            text: (irow.n.source ?? "").replace(/^github:/, "").replace(/^https:\/\/releases\.nixos\.org\/.*/, "channel tarball") + (irow.n.ref ? ` · ${irow.n.ref}` : "")
                            font.pixelSize: 10
                            elide: Text.ElideMiddle
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        text: `${irow.o.version ?? Updates.shortRev(irow.o.rev)}  ${page.date(irow.o.date)}   →   ${irow.n.version ?? Updates.shortRev(irow.n.rev)}  ${page.date(irow.n.date)}`
                        font.family: Theme.fontUi
                        font.features: {
                            "tnum": 1
                        }
                        elide: Text.ElideRight
                    }
                    Rectangle {
                        visible: irow.modelData.commits !== undefined && irow.modelData.commits !== null
                        implicitWidth: ctext.implicitWidth + 16
                        implicitHeight: 22
                        radius: 11
                        color: cm.containsMouse ? Theme.accent : Theme.withAlpha(Theme.accent, 0.16)
                        Text {
                            id: ctext
                            anchors.centerIn: parent
                            text: `${irow.modelData.commits} commit${irow.modelData.commits === 1 ? "" : "s"}  ↗`
                            color: cm.containsMouse ? Theme.bg : Theme.accent
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            font.weight: Font.Medium
                        }
                        MouseArea {
                            id: cm
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Updates.openUrl(irow.modelData.url)
                        }
                    }
                }
            }
        }
    }

    // ── Packages ─────────────────────────────────────────────────────────
    SettingsCard {
        visible: (page.s?.packages ?? []).length > 0
        spacing: 4

        PageHeader {
            title: `Package updates from nixpkgs · ${(page.s?.packages ?? []).length}`
            SettingsButton {
                visible: (page.s?.packages ?? []).length > 24
                text: page.showAllPackages ? "Show Fewer" : "Show All"
                onClicked: page.showAllPackages = !page.showAllPackages
            }
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 18
            rowSpacing: 2
            Repeater {
                model: (page.s?.packages ?? []).slice(0, page.showAllPackages ? 1000 : 24)
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    spacing: 8
                    Label {
                        Layout.preferredWidth: 150
                        text: modelData.name
                        elide: Text.ElideRight
                    }
                    Sub {
                        Layout.fillWidth: true
                        text: `${modelData.from}  →  ${modelData.to}`
                        elide: Text.ElideRight
                        font.features: {
                            "tnum": 1
                        }
                    }
                }
            }
        }
        Sub {
            Layout.fillWidth: true
            Layout.topMargin: 4
            text: page.s?.packagesNote ?? ""
            font.pixelSize: 10
            wrapMode: Text.Wrap
        }
    }

    Sub {
        Layout.fillWidth: true
        visible: !!page.s && (page.s.packages ?? []).length === 0 && (page.s.packagesNote ?? "") !== ""
        text: page.s?.packagesNote ?? ""
        wrapMode: Text.Wrap
    }

    // ── Up to date ───────────────────────────────────────────────────────
    SettingsCard {
        visible: Updates.unchanged.length > 0
        spacing: 4
        PageHeader {
            title: `Up to date · ${Updates.unchanged.length}`
            SettingsButton {
                text: page.showUnchanged ? "Hide" : "Show"
                onClicked: page.showUnchanged = !page.showUnchanged
            }
        }
        Flow {
            Layout.fillWidth: true
            visible: page.showUnchanged
            spacing: 6
            Repeater {
                model: Updates.unchanged
                delegate: Rectangle {
                    required property var modelData
                    implicitWidth: ut.implicitWidth + 14
                    implicitHeight: 22
                    radius: 11
                    color: Theme.withAlpha(Theme.text, 0.07)
                    Text {
                        id: ut
                        anchors.centerIn: parent
                        text: modelData.name + (modelData.new?.date ? ` · ${page.date(modelData.new.date)}` : "")
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                    }
                }
            }
        }
    }
}
