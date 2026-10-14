import QtQuick
import qs.services

// A circular progress ring (0..1), drawn with Canvas.
Canvas {
    id: root

    property real value: 0
    property real lineWidth: 6
    property color color: Theme.accent
    property color trackColor: Theme.withAlpha(Theme.text, 0.15)

    onValueChanged: requestPaint()
    onColorChanged: requestPaint()
    onTrackColorChanged: requestPaint()
    onWidthChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        ctx.lineWidth = lineWidth;
        ctx.lineCap = "round";
        const r = Math.min(width, height) / 2 - lineWidth / 2 - 1;
        ctx.strokeStyle = trackColor;
        ctx.beginPath();
        ctx.arc(width / 2, height / 2, r, 0, 2 * Math.PI);
        ctx.stroke();
        ctx.strokeStyle = color;
        ctx.beginPath();
        ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.max(0.01, Math.min(1, value)));
        ctx.stroke();
    }
}
