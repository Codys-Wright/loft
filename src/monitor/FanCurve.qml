import QtQuick
import qs.services

// A fan curve (°C → %) with draggable points: each stays between its
// neighbours' temperatures; under `floor` the band is shaded (the machine's
// minimum — the fan never runs slower), the critical line is where every fan
// goes to 100 %. committed(points) fires once on release.
Item {
    id: fc

    property var points: [] // [[°C, %], …] as stored
    property real floor: 25
    property real critical: 90
    property real temp: -1 // the source's reading now, -1 = unknown
    property real applied: -1 // the % the service last wrote, -1 = none
    signal committed(var points)

    readonly property real tMin: 20
    readonly property real tMax: 100
    readonly property real pad: 8

    // A working copy while dragging; follows `points` otherwise.
    property var pts: []
    property int dragging: -1
    onPointsChanged: if (dragging < 0)
        pts = points.map(p => [p[0], p[1]])

    implicitHeight: 160

    function xOf(t) {
        return pad + (t - tMin) / (tMax - tMin) * (width - 2 * pad);
    }
    function yOf(p) {
        return pad + (1 - p / 100) * (height - 2 * pad);
    }
    function tOf(x) {
        return tMin + (x - pad) / (width - 2 * pad) * (tMax - tMin);
    }
    function pOf(y) {
        return (1 - (y - pad) / (height - 2 * pad)) * 100;
    }

    onPtsChanged: plot.requestPaint()
    onFloorChanged: plot.requestPaint()
    onTempChanged: plot.requestPaint()
    onAppliedChanged: plot.requestPaint()
    onWidthChanged: plot.requestPaint()

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: Theme.withAlpha(Theme.text, 0.05)
    }

    Canvas {
        id: plot
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            if (width <= 0 || fc.pts.length < 2)
                return;
            // Grid: every 20 °C and 25 %.
            ctx.strokeStyle = Theme.withAlpha(Theme.text, 0.07);
            ctx.lineWidth = 1;
            for (let t = 40; t < fc.tMax; t += 20) {
                const x = Math.round(fc.xOf(t)) + 0.5;
                ctx.beginPath();
                ctx.moveTo(x, fc.pad);
                ctx.lineTo(x, height - fc.pad);
                ctx.stroke();
            }
            for (const p of [25, 50, 75]) {
                const y = Math.round(fc.yOf(p)) + 0.5;
                ctx.beginPath();
                ctx.moveTo(fc.pad, y);
                ctx.lineTo(width - fc.pad, y);
                ctx.stroke();
            }
            // Under the floor.
            ctx.fillStyle = Theme.withAlpha(Theme.text, 0.06);
            ctx.fillRect(fc.pad, fc.yOf(fc.floor), width - 2 * fc.pad, fc.yOf(0) - fc.yOf(fc.floor));
            // Critical: 100 % from here.
            if (fc.critical < fc.tMax) {
                ctx.fillStyle = Theme.withAlpha(Theme.urgent, 0.1);
                ctx.fillRect(fc.xOf(fc.critical), fc.pad, width - fc.pad - fc.xOf(fc.critical), height - 2 * fc.pad);
            }
            // The curve, flat before the first point and after the last.
            const xy = fc.pts.map(p => [fc.xOf(p[0]), fc.yOf(Math.max(p[1], fc.floor))]);
            ctx.beginPath();
            ctx.moveTo(fc.pad, xy[0][1]);
            for (const [x, y] of xy)
                ctx.lineTo(x, y);
            ctx.lineTo(width - fc.pad, xy[xy.length - 1][1]);
            ctx.lineTo(width - fc.pad, height - fc.pad);
            ctx.lineTo(fc.pad, height - fc.pad);
            ctx.closePath();
            const fill = ctx.createLinearGradient(0, 0, 0, height);
            fill.addColorStop(0, Theme.withAlpha(Theme.accent, 0.3));
            fill.addColorStop(1, Theme.withAlpha(Theme.accent, 0.03));
            ctx.fillStyle = fill;
            ctx.fill();
            ctx.beginPath();
            ctx.moveTo(fc.pad, xy[0][1]);
            for (const [x, y] of xy)
                ctx.lineTo(x, y);
            ctx.lineTo(width - fc.pad, xy[xy.length - 1][1]);
            ctx.strokeStyle = Theme.accent;
            ctx.lineWidth = 2;
            ctx.lineJoin = "round";
            ctx.stroke();
            // Now: the source's temperature and what the fan got.
            if (fc.temp >= 0) {
                const x = Math.round(fc.xOf(Math.max(fc.tMin, Math.min(fc.tMax, fc.temp)))) + 0.5;
                ctx.strokeStyle = Theme.withAlpha(Theme.text, 0.35);
                ctx.setLineDash([3, 3]);
                ctx.beginPath();
                ctx.moveTo(x, fc.pad);
                ctx.lineTo(x, height - fc.pad);
                ctx.stroke();
                ctx.setLineDash([]);
                if (fc.applied >= 0) {
                    ctx.fillStyle = Theme.text;
                    ctx.beginPath();
                    ctx.arc(x, fc.yOf(fc.applied), 3.5, 0, 2 * Math.PI);
                    ctx.fill();
                }
            }
        }
    }

    // Axis labels.
    Repeater {
        model: [40, 60, 80]
        delegate: Text {
            required property int modelData
            x: fc.xOf(modelData) - width / 2
            y: fc.height - fc.pad - height - 2
            text: `${modelData}°`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 9
        }
    }
    Repeater {
        model: [50, 100]
        delegate: Text {
            required property int modelData
            x: fc.pad + 4
            y: fc.yOf(modelData) + 2
            text: `${modelData}%`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 9
        }
    }

    Repeater {
        model: fc.pts.length
        delegate: Rectangle {
            id: handle
            required property int index
            readonly property var pt: fc.pts[index] ?? [0, 0]
            x: fc.xOf(pt[0]) - width / 2
            y: fc.yOf(pt[1]) - height / 2
            width: 14
            height: 14
            radius: 7
            color: drag.pressed || drag.containsMouse ? Theme.accent : "white"
            border.width: 2
            border.color: Theme.accent

            Text {
                visible: drag.pressed
                anchors.bottom: parent.top
                anchors.bottomMargin: 4
                anchors.horizontalCenter: parent.horizontalCenter
                text: `${Math.round(handle.pt[0])} °C · ${Math.round(handle.pt[1])}%`
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 10
                font.weight: Font.DemiBold
            }

            MouseArea {
                id: drag
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.SizeAllCursor
                onPressed: fc.dragging = handle.index
                onPositionChanged: mouse => {
                    if (!pressed)
                        return;
                    const i = handle.index;
                    const p = mapToItem(fc, mouse.x, mouse.y);
                    const lo = i > 0 ? fc.pts[i - 1][0] + 1 : fc.tMin;
                    const hi = i < fc.pts.length - 1 ? fc.pts[i + 1][0] - 1 : fc.tMax;
                    const next = fc.pts.map(q => [q[0], q[1]]);
                    next[i] = [Math.round(Math.max(lo, Math.min(hi, fc.tOf(p.x)))), Math.round(Math.max(fc.floor, Math.min(100, fc.pOf(p.y))))];
                    fc.pts = next;
                }
                onReleased: {
                    fc.dragging = -1;
                    fc.committed(fc.pts);
                }
            }
        }
    }
}
