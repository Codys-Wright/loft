import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services
import qs.settings

// Utilities: Port manager, Flake updates, Cleaner and Media Tools — the
// "App management" and "Media tools" rows of docs/VORSSAINT-COMPARISON.md —
// in one Golden Gate window (WindowChrome: flush sidebar, toolbar, traffic
// lights). Each page is its own feature; the state lives in the services
// (Ports, Updates, Cleaner, MediaTools), so closing loses nothing.
// IPC: utilities toggle|open|close|ports|updates|cleaner|media;
// media open OP PATHS (services/MediaTools.qml).
Scope {
    id: root

    readonly property string section: Utilities.section

    IpcHandler {
        target: "utilities"

        function toggle(): void {
            Utilities.toggle();
        }
        function open(): void {
            Utilities.show(Utilities.section);
        }
        function close(): void {
            Utilities.open = false;
        }
        function ports(): void {
            Utilities.show("ports");
        }
        function updates(): void {
            Utilities.show("updates");
        }
        function cleaner(): void {
            Utilities.show("cleaner");
        }
        function media(): void {
            Utilities.show("media");
        }
    }

    FloatingWindow {
        id: window
        visible: Utilities.open
        title: "Loft Utilities"
        implicitWidth: 960
        implicitHeight: 680
        color: "transparent"
        onVisibleChanged: if (!visible)
            Utilities.open = false

        BackgroundEffect.blurRegion: Theme.blur ? blur : null
        Region {
            id: blur
            item: chrome.surface
            radius: chrome.radius
        }

        WindowChrome {
            id: chrome
            hostWindow: window
            title: Utilities.sections.find(s => s.id === root.section)?.label ?? ""
            sidebarWidth: 200
            onCloseRequested: Utilities.open = false
            onHideRequested: Utilities.open = false

            focus: Utilities.open
            Keys.onEscapePressed: {
                if (Ports.pending !== null)
                    Ports.cancel();
                else if (Cleaner.confirming !== null)
                    Cleaner.confirming = null;
                else if (updatesPage.showCommands)
                    updatesPage.showCommands = false;
                else
                    Utilities.open = false;
            }

            toolbar: [
                SettingsButton {
                    visible: root.section === "ports"
                    icon: "󰑐"
                    text: "Refresh"
                    onClicked: Ports.refresh()
                },
                SettingsButton {
                    visible: root.section === "updates" && Updates.summary !== null
                    icon: "󰑐"
                    text: Updates.running ? "Checking…" : "Check Now"
                    enabled: !Updates.running
                    onClicked: Updates.refresh()
                },
                SettingsButton {
                    visible: root.section === "updates" && (Updates.summary?.commands ?? []).length > 0
                    primary: Updates.changed.length > 0
                    text: "Update…"
                    onClicked: updatesPage.showCommands = true
                },
                SettingsButton {
                    visible: root.section === "cleaner"
                    icon: "󰑐"
                    text: Cleaner.scanning ? "Scanning…" : "Rescan"
                    enabled: !Cleaner.scanning
                    onClicked: Cleaner.rescan()
                },
                SettingsButton {
                    visible: root.section === "media" && MediaTools.files.length > 0
                    text: "Clear"
                    enabled: !MediaTools.running
                    onClicked: MediaTools.clearFiles()
                }
            ]

            sidebar: [
                Repeater {
                    model: Utilities.shown
                    delegate: SidebarItem {
                        required property var modelData
                        icon: modelData.icon
                        badge: modelData.badge
                        label: modelData.label
                        current: root.section === modelData.id
                        windowActive: chrome.active
                        onClicked: Utilities.section = modelData.id
                    }
                },
                // At a glance.
                ColumnLayout {
                    Layout.leftMargin: 10
                    Layout.topMargin: 14
                    spacing: 3

                    Repeater {
                        model: [Features.on("portManager") ? ["Dev servers", `${Ports.devCount}`] : null, Features.on("flakeUpdates") && Updates.summary ? ["Updates", Updates.summary.error ? "—" : `${Updates.changed.length} inputs`] : null, Features.on("cleaner") && Cleaner.scan ? ["Caches", Cleaner.formatBytes(Cleaner.scan.cacheBytes)] : null, Features.on("cleaner") && Cleaner.scan?.store ? ["Nix garbage", Cleaner.formatBytes(Cleaner.scan.store.deadBytes)] : null].filter(x => x !== null)
                        delegate: RowLayout {
                            required property var modelData
                            spacing: 6
                            Text {
                                Layout.preferredWidth: 78
                                text: modelData[0]
                                color: Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                            }
                            Text {
                                text: modelData[1]
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                                font.features: {
                                    "tnum": 1
                                }
                            }
                        }
                    }
                }
            ]

            Flickable {
                id: content
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                contentHeight: pages.implicitHeight + 16
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: pages
                    width: content.width
                    spacing: 12

                    PortsPage {
                        Layout.fillWidth: true
                        visible: root.section === "ports" && Features.on("portManager")
                    }
                    UpdatesPage {
                        id: updatesPage
                        Layout.fillWidth: true
                        visible: root.section === "updates" && Features.on("flakeUpdates")
                    }
                    CleanerPage {
                        Layout.fillWidth: true
                        visible: root.section === "cleaner" && Features.on("cleaner")
                    }
                    MediaPage {
                        Layout.fillWidth: true
                        visible: root.section === "media" && Features.on("mediaTools")
                    }
                }
            }
        }

        // Dropping files anywhere on the window sends them to Media Tools.
        DropArea {
            anchors.fill: parent
            enabled: Features.on("mediaTools")
            keys: ["text/uri-list"]
            onEntered: drag => {
                drag.accept(Qt.CopyAction);
                dropHint.visible = true;
            }
            onExited: dropHint.visible = false
            onDropped: drop => {
                dropHint.visible = false;
                const urls = drop.hasUrls ? drop.urls.map(u => String(u)) : String(drop.text).split(/\r?\n/);
                MediaTools.openWith(urls.filter(u => u !== ""), "");
                drop.accept(Qt.CopyAction);
            }
        }

        Rectangle {
            id: dropHint
            visible: false
            anchors.fill: parent
            anchors.margins: 6
            radius: chrome.radius
            color: Theme.withAlpha(Theme.accent, 0.12)
            border.width: 2
            border.color: Theme.withAlpha(Theme.accent, 0.8)
            Text {
                anchors.centerIn: parent
                text: "Drop to add to Media Tools"
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }
        }

        // ── Sheets ─────────────────────────────────────────────────────
        ConfirmSheet {
            readonly property var p: Ports.pending
            readonly property var r: p?.row ?? null
            readonly property string who: r ? `${r.process?.name ?? "process"}${r.process?.project ? " (" + r.process.project.name + ")" : ""}` : ""
            shown: p !== null
            icon: p?.phase === "stuck" ? "󰀦" : "󰓛"
            title: p?.phase === "stuck" ? `“${who}” is still running` : `Stop ${who}?`
            text: !r ? "" : p.phase === "stuck" ? `It didn't exit within 3 seconds of SIGTERM. Force Quit (SIGKILL) ends it without letting it clean up.` : p.phase === "stopping" ? "Stopping…" : `PID ${r.pid} · ${r.proto.toUpperCase()} ${r.port}\n${r.process?.command ?? ""}\nSIGTERM asks it to exit; unsaved work in it may be lost.`
            buttons: !p ? [] : p.phase === "stuck" ? [
                {
                    label: "Cancel",
                    run: () => Ports.cancel()
                },
                {
                    label: "Force Quit",
                    primary: true,
                    run: () => {
                        Ports.pending = {
                            row: r,
                            phase: "confirm"
                        };
                        Ports.stop(true);
                    }
                }
            ] : [
                {
                    label: "Cancel",
                    run: () => Ports.cancel()
                },
                {
                    label: "Force Quit",
                    enabled: p.phase === "confirm",
                    run: () => Ports.stop(true)
                },
                {
                    label: "Stop",
                    primary: true,
                    enabled: p.phase === "confirm",
                    run: () => Ports.stop(false)
                }
            ]
            onDismissed: Ports.cancel()
        }

        ConfirmSheet {
            readonly property var c: Cleaner.confirming
            shown: c !== null
            icon: "󰃢"
            iconColor: Theme.warn
            title: !c ? "" : c.toTrash ? `Move ${c.label} to the Trash?` : `Clear ${c.label}?`
            text: !c ? "" : c.toTrash ? `${Cleaner.formatBytes(c.bytes)}${Cleaner.scan?.testHome ? " (TEST home " + Cleaner.scan.home + ")" : ""}. You can put them back from the Trash.` : `About ${Cleaner.formatBytes(c.bytes)} will be deleted from ${Cleaner.scan?.testHome ? "the TEST home " + Cleaner.scan.home : "your home folder"}. Apps rebuild their caches as needed (the next start may be slower). You can't undo this.`
            buttons: [
                {
                    label: "Cancel",
                    run: () => Cleaner.confirming = null
                },
                {
                    label: Cleaner.clearing ? "Working…" : c?.toTrash ? "Move to Trash" : "Clear",
                    primary: true,
                    enabled: !Cleaner.clearing,
                    run: () => Cleaner.clear()
                }
            ]
            onDismissed: if (!Cleaner.clearing)
                Cleaner.confirming = null
        }

        ConfirmSheet {
            shown: updatesPage.showCommands
            icon: "󰚰"
            iconColor: Theme.accent
            title: "Update the system"
            text: `Loft doesn't switch the system for you. Run these in a terminal${Updates.summary?.flake ? " (flake: " + Updates.summary.flake + ")" : ""}:`
            buttons: [
                {
                    label: "Close",
                    run: () => updatesPage.showCommands = false
                },
                {
                    label: "Copy Commands",
                    primary: true,
                    run: () => {
                        Updates.copyCommands();
                        updatesPage.showCommands = false;
                    }
                }
            ]
            onDismissed: updatesPage.showCommands = false

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: cmds.implicitHeight + 16
                radius: 8
                color: Theme.withAlpha(Theme.text, 0.07)
                Text {
                    id: cmds
                    anchors {
                        fill: parent
                        margins: 8
                    }
                    text: (Updates.summary?.commands ?? []).join("\n")
                    color: Theme.text
                    font.family: "monospace"
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }
        }
    }
}
