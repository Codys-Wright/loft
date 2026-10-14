import QtQuick
import QtQuick.Layouts
import qs.components
import qs.palette
import qs.services

// Settings → Radial Menu: profiles (one per set of apps, the first is the
// default), each a list of slices — actions or submenus — dragged into
// order, with a live preview of the wheel. Data: palette/Radial.qml.
ColumnLayout {
    id: page
    spacing: 12

    property int profileIndex: 0
    // Slice whose submenu is being edited (-1 none).
    property int openSub: -1
    // "" | "slice" | "child": which list the picker adds to.
    property string adding: ""
    property int hoveredSlice: -1
    property int hoveredChild: -1

    readonly property var profiles: Radial.profiles
    readonly property var profile: profiles[Math.min(profileIndex, profiles.length - 1)] ?? null
    readonly property var slices: profile?.slices ?? []
    readonly property var sub: openSub >= 0 && openSub < slices.length && slices[openSub].children ? slices[openSub] : null

    onProfileIndexChanged: {
        openSub = -1;
        adding = "";
    }

    // Edit a copy of the profiles and save it.
    function edit(fn) {
        const l = JSON.parse(JSON.stringify(profiles));
        fn(l, l[Math.min(profileIndex, l.length - 1)]);
        Radial.saveProfiles(l);
    }

    function moveIn(arr, from, to) {
        const [x] = arr.splice(from, 1);
        arr.splice(to, 0, x);
    }

    function rowFor(s) {
        const isSub = !!s.children;
        const e = isSub ? null : Actions.entry(s.action);
        const ok = isSub ? true : Actions.available(s.action);
        return {
            icon: Radial.sliceIcon(s),
            label: Radial.sliceLabel(s) + (isSub ? "  ▸" : ""),
            sub: isSub ? `Submenu · ${(s.children ?? []).length} items — click to edit` : ok ? (e?.group ?? "Unknown action") : "Not shown: its module is off (Features)",
            warn: !ok,
            badge: isSub ? "indigo" : Actions.badge(e?.group),
            appId: e?.kind === "app" ? e.appId : ""
        };
    }

    SettingsCard {
        SettingsRow {
            label: "Radial menu"
            hint: "Hold ⌃⌘Space (Mod+Ctrl+Space) or the middle button on the desktop, point, let go"
            SettingsSwitch {
                checked: Features.on("radialMenu")
                onToggled: on => Features.set("radialMenu", on)
            }
        }

        SettingsRow {
            label: "Size"
            SettingsSegmented {
                options: [
                    { value: "small", label: "Small" },
                    { value: "medium", label: "Medium" },
                    { value: "large", label: "Large" }
                ]
                current: Radial.size
                onActivated: v => Radial.save({ size: v })
            }
        }

        SettingsRow {
            label: "Preview"
            hint: "Opens the wheel to click (Esc closes)"
            SettingsButton {
                text: "Show Radial Menu"
                enabled: Features.on("radialMenu")
                onClicked: {
                    Radial.hold();
                    Radial.sticky = true;
                }
            }
        }
    }

    // ── Profiles ─────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 8

        PageHeader {
            title: "Profiles"
            SettingsButton {
                text: "Reset All"
                onClicked: {
                    Radial.reset();
                    page.profileIndex = 0;
                }
            }
            SettingsButton {
                text: "New Profile"
                onClicked: {
                    const n = page.profiles.length;
                    page.edit(l => l.push({ id: "p" + Date.now().toString(36), name: `Profile ${n + 1}`, apps: [], slices: [{ action: "niri:close" }, { action: "niri:maximize" }, { action: "capture:window" }, { action: "clipboard:history" }] }));
                    page.profileIndex = n;
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: page.profiles
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    required property int index
                    readonly property bool current: index === page.profileIndex
                    implicitWidth: chipText.implicitWidth + 24
                    implicitHeight: 28
                    radius: 14
                    color: current ? Theme.accent : chipHit.containsMouse ? Theme.withAlpha(Theme.text, 0.14) : Theme.withAlpha(Theme.text, 0.08)
                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: chip.modelData.name || "Untitled"
                        color: chip.current ? Theme.bg : Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: chip.current ? Font.DemiBold : Font.Normal
                    }
                    MouseArea {
                        id: chipHit
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.profileIndex = chip.index
                    }
                }
            }
        }

        SettingsRow {
            label: "Name"
            SettingsTextField {
                Layout.preferredWidth: 220
                text: page.profile?.name ?? ""
                onCommitted: t => page.edit((l, p) => p.name = t.trim() || p.name)
            }
        }

        SettingsRow {
            label: "Apps"
            hint: page.profileIndex === 0 ? "The first profile is used for every other app" : "Used while one is focused: app ids or /regex/"
            SettingsTextField {
                Layout.preferredWidth: 260
                enabled: page.profileIndex > 0
                text: (page.profile?.apps ?? []).join(", ")
                placeholder: page.profileIndex === 0 ? "Every app" : "firefox, /chrom/"
                onCommitted: t => page.edit((l, p) => p.apps = t.split(",").map(x => x.trim()).filter(x => x !== ""))
            }
        }

        SettingsRow {
            visible: page.profileIndex > 0
            label: "Order"
            hint: "The first profile whose apps match wins"
            SettingsButton {
                text: "Move Up"
                enabled: page.profileIndex > 1
                onClicked: {
                    const i = page.profileIndex;
                    page.edit(l => page.moveIn(l, i, i - 1));
                    page.profileIndex = i - 1;
                }
            }
            SettingsButton {
                text: "Delete Profile"
                onClicked: {
                    const i = page.profileIndex;
                    page.edit(l => l.splice(i, 1));
                    page.profileIndex = Math.max(0, i - 1);
                }
            }
        }
    }

    // ── Slices ───────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 6

        PageHeader {
            title: `Slices · ${page.slices.length}`
            SettingsButton {
                text: "Add Submenu"
                enabled: page.slices.length < 12
                onClicked: page.edit((l, p) => {
                    p.slices.push({ label: "Submenu", icon: "󰍜", children: [] });
                    page.openSub = p.slices.length - 1;
                })
            }
            SettingsButton {
                text: page.adding === "slice" ? "Close" : "Add…"
                primary: page.adding !== "slice"
                enabled: page.slices.length < 12 || page.adding === "slice"
                onClicked: {
                    page.adding = page.adding === "slice" ? "" : "slice";
                    if (page.adding)
                        picker.focusSearch();
                }
            }
        }

        // Live preview: the hovered row lights its slice.
        Item {
            Layout.fillWidth: true
            // Room for the submenu ring only while one is open.
            Layout.preferredHeight: (page.sub ? preview.height : preview.radius * 2 + 30) * preview.scale
            Behavior on Layout.preferredHeight {
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutQuart
                }
            }
            RadialWheel {
                id: preview
                anchors.centerIn: parent
                scale: 0.78
                slices: page.slices
                radius: 104
                hub: 36
                ringRadius: 150
                selMain: page.hoveredChild >= 0 ? page.openSub : page.hoveredSlice
                selChild: page.hoveredChild
                ring: page.sub ? page.openSub : -1
                caption: page.hoveredChild >= 0 && page.sub ? Radial.sliceLabel(page.sub.children[page.hoveredChild]) : page.hoveredSlice >= 0 && page.hoveredSlice < page.slices.length ? Radial.sliceLabel(page.slices[page.hoveredSlice]) : (page.profile?.name ?? "")
            }
        }

        ActionPicker {
            id: picker
            Layout.fillWidth: true
            Layout.bottomMargin: 8
            visible: page.adding !== ""
            exclude: page.adding === "child" && page.sub ? page.sub.children.map(c => c.action) : page.slices.filter(s => s.action).map(s => s.action)
            onPicked: id => {
                const into = page.adding, at = page.openSub;
                page.edit((l, p) => {
                    if (into === "child")
                        p.slices[at].children.push({ action: id });
                    else if (p.slices.length < 12)
                        p.slices.push({ action: id });
                });
            }
            onCanceled: page.adding = ""
        }

        ActionList {
            Layout.fillWidth: true
            items: page.slices.map(s => page.rowFor(s))
            selected: page.openSub
            onHoveredChanged: page.hoveredSlice = hovered
            onClicked: i => {
                page.openSub = page.slices[i].children && page.openSub !== i ? i : -1;
                if (page.adding === "child")
                    page.adding = "";
            }
            onMoved: (from, to) => {
                const sel = page.openSub;
                page.edit((l, p) => page.moveIn(p.slices, from, to));
                if (sel === from)
                    page.openSub = to;
                else
                    page.openSub = -1;
            }
            onRemoved: i => {
                page.openSub = -1;
                page.edit((l, p) => p.slices.splice(i, 1));
            }
        }
    }

    // ── The open submenu ─────────────────────────────────────────────────
    SettingsCard {
        visible: page.sub !== null
        spacing: 6

        PageHeader {
            title: `Submenu: ${page.sub?.label ?? ""}`
            SettingsButton {
                text: page.adding === "child" ? "Close" : "Add…"
                primary: page.adding !== "child"
                onClicked: {
                    page.adding = page.adding === "child" ? "" : "child";
                    if (page.adding)
                        picker.focusSearch();
                }
            }
        }

        SettingsRow {
            label: "Name"
            SettingsTextField {
                Layout.preferredWidth: 200
                text: page.sub?.label ?? ""
                onCommitted: t => {
                    const at = page.openSub;
                    page.edit((l, p) => p.slices[at].label = t.trim() || "Submenu");
                }
            }
        }

        SettingsRow {
            label: "Icon"
            hint: "A Nerd Font glyph"
            SettingsTextField {
                Layout.preferredWidth: 80
                text: page.sub?.icon ?? ""
                onCommitted: t => {
                    const at = page.openSub;
                    page.edit((l, p) => p.slices[at].icon = t.trim() || "󰍜");
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: (page.sub?.children ?? []).length === 0
            text: "Empty — Add… puts items on the submenu's ring."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
        }

        ActionList {
            Layout.fillWidth: true
            items: (page.sub?.children ?? []).map(s => page.rowFor(s))
            onHoveredChanged: page.hoveredChild = hovered
            onMoved: (from, to) => {
                const at = page.openSub;
                page.edit((l, p) => page.moveIn(p.slices[at].children, from, to));
            }
            onRemoved: i => {
                const at = page.openSub;
                page.edit((l, p) => p.slices[at].children.splice(i, 1));
            }
        }
    }
}
