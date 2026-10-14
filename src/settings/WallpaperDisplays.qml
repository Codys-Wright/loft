import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Settings → Wallpaper → Displays & Workspaces: a wallpaper per display and
// per workspace, auto-matched images, and wallpaper sets (Vibes.qml,
// cli/loft/wallsets.py).
//
// The diagram draws the displays at their real relative positions, sizes and
// orientation with what each shows now; click one to pick for it. The strip
// below lists its workspaces (named ones by name) with what each shows; click
// one to pick for just that workspace. The picker lists the theme's matching
// images, the same tone and colors as the selection first.
SettingsCard {
    id: card

    // The selected display (connector) and workspace (null = the display itself).
    property string sel: ""
    property var selWs: null
    property bool pickAll: false
    readonly property int pickShown: 12
    property string setName: ""
    property string notice: ""

    readonly property var outputs: Vibes.layout.outputs
    readonly property string selName: outputs.some(o => o.name === sel) ? sel : (outputs.find(o => (Vibes.roles[o.name] ?? [])[0] === "main")?.name ?? outputs[0]?.name ?? "")
    readonly property var selOutput: outputs.find(o => o.name === selName) ?? null
    readonly property var selWorkspaces: Vibes.workspacesOn(selName)
    readonly property bool sameAll: Vibes.isSameAll(selName)
    // The workspace being picked for (only while it can have its own image).
    readonly property var targetWs: sameAll ? null : selWs
    readonly property string current: targetWs ? Vibes.wallpaperAt(selName, targetWs) : Vibes.baseFor(selName)
    readonly property string explicitChoice: targetWs ? (Vibes.workspaceChoices[Vibes.workspaceKey(selName, targetWs)] ?? "") : (Vibes.displayChoices[Vibes.identityOf(selName)] ?? "")

    function thumbOf(path) {
        return Vibes.pool.find(c => c.path === path)?.thumb || Library.byPath[path]?.thumb || "";
    }

    function caption(path) {
        if (!path)
            return "Theme default";
        const short = Library.byPath[path]?.short;
        if (short)
            return short;
        return path.split("/").pop().replace(/\.[^.]+$/, "");
    }

    function sourceLabel(src) {
        return ({
                workspace: "Chosen",
                display: "Display",
                theme: "Theme choice",
                packset: "Pack set",
                auto: "Auto",
                "default": "Default"
            })[src] ?? src;
    }

    function shortModel(identity) {
        // "Acer Technologies XV271U M3 1321…" → "XV271U M3"
        const parts = (identity ?? "").split(" ");
        return parts.length >= 3 ? parts.slice(-3, -1).join(" ").replace(/^Technologies /, "") : identity;
    }

    // The pool ordered for the selection: its tone first, then a color
    // family in common with what it shows, the same folder (a series), how
    // well the image fits the display's shape, then closeness to the theme.
    readonly property var picks: {
        const ref = Vibes.pool.find(c => c.path === current);
        const fam = ref ? ref.colors : [];
        const tone = ref?.tone ?? Vibes.targetTone;
        const id = selOutput?.identity ?? "";
        const dir = current.replace(/\/[^/]*$/, "/");
        const rank = c => (c.tone === tone ? 0 : c.tone === "Medium" || tone === "Medium" ? 1 : 3) + (fam.length && !c.colors.some(f => fam.indexOf(f) >= 0) ? 1 : 0) + (current && c.path.startsWith(dir) && c.path.indexOf("/", dir.length) < 0 ? -0.5 : 0) + (1 - (c.kept?.[id] ?? 1)) * 2 - c.score;
        return Vibes.pool.slice().sort((a, b) => rank(a) - rank(b));
    }

    function choose(path) {
        if (targetWs)
            Vibes.chooseWallpaperForWorkspace(selName, targetWs, path);
        else
            Vibes.chooseWallpaperFor(selName, path);
    }

    PageHeader {
        title: "Displays & Workspaces"
        SettingsButton {
            text: "Auto-fill matching"
            icon: "󰁨"
            enabled: Vibes.pool.length > 0
            onClicked: Vibes.autoFill()
        }
        SettingsButton {
            text: "Shuffle"
            icon: "󰒝"
            enabled: Vibes.autoOn && Vibes.pool.length > 1
            onClicked: Vibes.shuffle()
        }
    }

    Text {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: (Vibes.planning && !Vibes.plan ? "Matching images…" : `${Vibes.pool.length} images match ${Vibes.theme}` + (Vibes.targetTone ? ` · ${Vibes.targetTone.toLowerCase()} tone` : "")) + (Vibes.activeSet ? ` · set “${Vibes.activeSet}”` : Vibes.packSet ? ` · the pack's set “${Vibes.packSet.name}”` : "")
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
    }

    // ── the layout diagram ──────────────────────────────────────────────
    Item {
        id: diagram
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(190, box.h * fit + 26)

        readonly property var box: {
            const os = card.outputs;
            if (os.length === 0)
                return { x: 0, y: 0, w: 1, h: 1 };
            const x0 = Math.min(...os.map(o => o.x)), y0 = Math.min(...os.map(o => o.y));
            const x1 = Math.max(...os.map(o => o.x + o.width)), y1 = Math.max(...os.map(o => o.y + o.height));
            return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
        }
        readonly property real gap: 6
        readonly property real fit: Math.min((width - gap * Math.max(0, card.outputs.length - 1)) / box.w, 164 / box.h)
        readonly property real offsetX: (width - box.w * fit - gap * Math.max(0, card.outputs.length - 1)) / 2

        Repeater {
            model: card.outputs
            delegate: Item {
                id: disp
                required property var modelData
                required property int index
                readonly property bool selected: modelData.name === card.selName
                readonly property string shows: Vibes.wallpaperFor(modelData.name)
                // Displays to the left of this one, for the gaps between them.
                readonly property int leftOf: card.outputs.filter(o => o.x + o.width <= modelData.x).length

                x: diagram.offsetX + (modelData.x - diagram.box.x) * diagram.fit + leftOf * diagram.gap
                y: (modelData.y - diagram.box.y) * diagram.fit
                width: modelData.width * diagram.fit
                height: modelData.height * diagram.fit + 22

                Rectangle {
                    id: screenRect
                    width: parent.width
                    height: disp.modelData.height * diagram.fit
                    radius: Theme.controlRadius
                    color: Theme.withAlpha(Theme.text, 0.08)
                    border.width: disp.selected ? 3 : hoverArea.containsMouse ? 1 : 0
                    border.color: disp.selected ? Theme.accent : Theme.withAlpha(Theme.text, 0.45)

                    CroppedThumb {
                        anchors.fill: parent
                        anchors.margins: disp.selected ? 3 : 1
                        path: disp.shows
                        thumb: card.thumbOf(disp.shows)
                    }

                    Rectangle {
                        anchors {
                            left: parent.left
                            bottom: parent.bottom
                            margins: 6
                        }
                        visible: Vibes.isSameAll(disp.modelData.name)
                        width: sameLabel.implicitWidth + 10
                        height: 16
                        radius: 8
                        color: Theme.withAlpha("#000000", 0.55)
                        Text {
                            id: sameLabel
                            anchors.centerIn: parent
                            text: "all workspaces"
                            color: "white"
                            font.family: Theme.fontUi
                            font.pixelSize: 9
                            font.weight: Font.DemiBold
                        }
                    }
                }

                Text {
                    anchors {
                        top: screenRect.bottom
                        topMargin: 4
                        horizontalCenter: parent.horizontalCenter
                    }
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: `${disp.modelData.name} · ${(Vibes.roles[disp.modelData.name] ?? [])[0] ?? ""}`
                    color: disp.selected ? Theme.text : Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 10
                    font.weight: disp.selected ? Font.DemiBold : Font.Normal
                }

                MouseArea {
                    id: hoverArea
                    anchors.fill: screenRect
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        card.sel = disp.modelData.name;
                        card.selWs = null;
                        card.pickAll = false;
                    }
                }
            }
        }
    }

    // ── the selected display's workspaces ──────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: card.selOutput ? `${card.shortModel(card.selOutput.identity)} — ${(Vibes.roles[card.selName] ?? []).slice(0, 3).join(", ")}` : ""
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
        Text {
            text: "Use for all workspaces"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
        }
        SettingsSwitch {
            checked: card.sameAll
            onToggled: on => Vibes.setSameAll(card.selName, on)
        }
        Text {
            text: "Auto"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
        }
        SettingsSwitch {
            checked: Vibes.autoOn
            onToggled: on => Vibes.setAuto(on)
        }
    }

    Flickable {
        Layout.fillWidth: true
        Layout.preferredHeight: 74
        contentWidth: strip.implicitWidth
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Row {
            id: strip
            spacing: 8

            // The display itself: its base image.
            WsTile {
                label: "Display"
                sub: card.sourceLabel(Vibes.displayChoices[Vibes.identityOf(card.selName)] ? "display" : Vibes.sourceAt(card.selName, null))
                path: Vibes.baseFor(card.selName)
                selected: card.targetWs === null
                onClicked: card.selWs = null
            }

            Repeater {
                model: card.selWorkspaces
                delegate: WsTile {
                    required property var modelData
                    label: modelData.name || `${modelData.idx}`
                    sub: card.sameAll ? "Display" : card.sourceLabel(Vibes.sourceAt(card.selName, modelData))
                    path: Vibes.wallpaperAt(card.selName, modelData)
                    active: !!modelData.active
                    dim: card.sameAll
                    selected: card.targetWs !== null && card.targetWs.idx === modelData.idx
                    onClicked: if (!card.sameAll)
                        card.selWs = modelData
                }
            }
        }
    }

    // ── the picker ─────────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: (card.targetWs ? `Workspace ${card.targetWs.name || card.targetWs.idx}` : `${card.selName}`) + ` · ${card.caption(card.current)}`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
        SettingsButton {
            text: card.targetWs ? "Follow display" : "Clear"
            enabled: card.explicitChoice !== ""
            onClicked: card.choose("")
        }
    }

    Flow {
        Layout.fillWidth: true
        spacing: 10

        Repeater {
            model: card.pickAll ? card.picks : card.picks.slice(0, card.pickShown)
            delegate: VibeThumb {
                required property var modelData
                implicitWidth: 132
                image: modelData.path
                thumbnail: modelData.thumb ?? ""
                title: card.caption(modelData.path)
                subtitle: `${modelData.tone} · ${modelData.colors.join(" + ")}` + (modelData.source ? ` · ${modelData.source}` : "")
                score: modelData.origin === "match" ? modelData.score : -1
                badge: modelData.tone !== Vibes.targetTone ? modelData.tone.toLowerCase() : (modelData.kept?.[card.selOutput?.identity ?? ""] ?? 1) < 0.5 ? "crops badly" : ""
                selected: modelData.path === card.current
                onClicked: card.choose(modelData.path)
            }
        }
    }

    SettingsButton {
        visible: card.picks.length > card.pickShown
        text: card.pickAll ? "Show fewer" : `Show all ${card.picks.length}`
        onClicked: card.pickAll = !card.pickAll
    }

    // ── sets ───────────────────────────────────────────────────────────
    PageHeader {
        title: "Sets"
        SettingsTextField {
            implicitWidth: 180
            placeholder: "Name"
            text: card.setName
            onEdited: t => card.setName = t
            onCommitted: t => card.setName = t
        }
        SettingsButton {
            text: "Save as Set…"
            primary: true
            enabled: card.setName.trim() !== ""
            onClicked: {
                const n = card.setName.trim();
                card.notice = Vibes.saveSet(n) ? `Saved “${n}”` : "Nothing to save";
                card.forceActiveFocus(); // the field lets go, then empties
                card.setName = "";
            }
        }
    }

    Text {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        visible: Vibes.sets.length === 0 || card.notice !== ""
        text: card.notice !== "" ? card.notice : "A set keeps what every display and workspace shows, by role (main, left, right, portrait …), so it also fits another desk. Theme packs can ship sets too."
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
    }

    Repeater {
        model: Vibes.sets
        delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: 8

            // The set's images, side by side in role order.
            Row {
                spacing: 3
                Repeater {
                    model: Object.values(modelData.displays).slice(0, 4)
                    delegate: Rectangle {
                        required property var modelData
                        width: 44
                        height: 26
                        radius: 5
                        clip: true
                        color: Theme.withAlpha(Theme.text, 0.08)
                        CroppedThumb {
                            anchors.fill: parent
                            path: parent.modelData
                            thumb: card.thumbOf(parent.modelData)
                        }
                    }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: modelData.name + (modelData.name === Vibes.activeSet ? "  ✓" : "")
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.weight: modelData.name === Vibes.activeSet ? Font.DemiBold : Font.Normal
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: (modelData.origin === "pack" ? "From the theme pack · " : "") + Object.keys(modelData.displays).join(", ") + (Object.keys(modelData.workspaces ?? {}).length ? ` · ${Object.keys(modelData.workspaces).length} workspaces` : "")
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 10
                }
            }
            SettingsButton {
                text: "Apply"
                onClicked: card.notice = Vibes.applySet(modelData.name) ? `Applied “${modelData.name}”` : ""
            }
            SettingsButton {
                visible: modelData.origin === "user"
                text: "Delete"
                onClicked: {
                    Vibes.deleteSet(modelData.name);
                    card.notice = `Deleted “${modelData.name}”`;
                }
            }
        }
    }

    // An image cropped like the wallpaper layer (around its focus).
    component CroppedThumb: Item {
        id: ct
        property string path
        property string thumb
        clip: true
        readonly property var focus2: Vibes.focusFor(path)
        Image {
            id: ctImg
            source: Vibes.url(ct.thumb || ct.path)
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(Math.max(1, ct.width * 2), Math.max(1, ct.height * 2))
            width: Math.max(implicitWidth / 2, ct.width)
            height: Math.max(implicitHeight / 2, ct.height)
            x: Math.min(0, Math.max(ct.width - width, ct.width / 2 - ct.focus2[0] * width))
            y: Math.min(0, Math.max(ct.height - height, ct.height / 2 - ct.focus2[1] * height))
        }
        Rectangle {
            anchors.fill: parent
            visible: ct.path === "" || ctImg.status !== Image.Ready
            gradient: Gradient {
                GradientStop { position: 0; color: Theme.wallpaperGradient[0] ?? Theme.bg }
                GradientStop { position: 1; color: Theme.wallpaperGradient[2] ?? Theme.surface }
            }
        }
    }

    // A workspace in the strip: what it shows, its name, where the image comes from.
    component WsTile: Item {
        id: tile
        property string label
        property string sub
        property string path
        property bool selected: false
        property bool active: false
        property bool dim: false
        signal clicked
        width: 96
        height: 72
        opacity: dim ? 0.55 : 1

        Rectangle {
            id: tileFrame
            width: parent.width
            height: 46
            radius: Theme.controlRadius
            color: Theme.withAlpha(Theme.text, 0.08)
            border.width: tile.selected ? 2 : tileHover.containsMouse ? 1 : 0
            border.color: tile.selected ? Theme.accent : Theme.withAlpha(Theme.text, 0.45)
            CroppedThumb {
                anchors.fill: parent
                anchors.margins: tile.selected ? 2 : 1
                path: tile.path
                thumb: card.thumbOf(tile.path)
            }
            Rectangle {
                visible: tile.active
                anchors {
                    right: parent.right
                    top: parent.top
                    margins: 5
                }
                width: 7
                height: 7
                radius: 3.5
                color: Theme.accent
                border.width: 1
                border.color: Theme.withAlpha("#000000", 0.4)
            }
        }
        Text {
            anchors.top: tileFrame.bottom
            anchors.topMargin: 3
            width: parent.width
            elide: Text.ElideRight
            text: tile.label
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 11
            font.weight: tile.selected ? Font.DemiBold : Font.Normal
        }
        Text {
            anchors.bottom: parent.bottom
            width: parent.width
            elide: Text.ElideRight
            text: tile.sub
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 9
        }
        MouseArea {
            id: tileHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: tile.dim ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: tile.clicked()
        }
    }
}
