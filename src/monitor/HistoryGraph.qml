import QtQuick
import qs.services

// An area chart of a SystemStats history buffer (newest on the right).
// `values` is required; `values2` draws a second series as a line on top
// (network up vs down, GPU vs CPU temperature). null samples leave gaps.
Canvas {
    id: graph

    property var values: []
    property var values2: []
    property color color: Theme.accent
    property color color2: Theme.accent2
    // Fixed top of the scale; 0 = fit the data (at least `minMax`).
    property real max: 1
    property real minMax: 1
    property int capacity: SystemStats.historyLength
    property bool grid: true

    readonly property real scaleMax: {
        if (max > 0)
            return max;
        let m = minMax;
        for (const v of values)
            if (v !== null && v > m)
                m = v;
        for (const v of values2)
            if (v !== null && v > m)
                m = v;
        return m * 1.15;
    }

    implicitHeight: 80
    antialiasing: true

    onValuesChanged: requestPaint()
    onValues2Changed: requestPaint()
    onColorChanged: requestPaint()
    onColor2Changed: requestPaint()
    onScaleMaxChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    function pointsOf(vals) {
        const step = width / Math.max(1, capacity - 1);
        const offset = capacity - vals.length;
        const pts = [];
        for (let i = 0; i < vals.length; i++) {
            const v = vals[i];
            pts.push(v === null || v === undefined || isNaN(v) ? null : {
                x: (offset + i) * step,
                y: height - 1 - Math.max(0, Math.min(1, v / scaleMax)) * (height - 2)
            });
        }
        return pts;
    }

    // Runs of consecutive non-null points.
    function runs(pts) {
        const out = [];
        let cur = [];
        for (const p of pts) {
            if (p === null) {
                if (cur.length)
                    out.push(cur);
                cur = [];
            } else {
                cur.push(p);
            }
        }
        if (cur.length)
            out.push(cur);
        return out;
    }

    function stroke(ctx, run, color, width) {
        ctx.beginPath();
        ctx.moveTo(run[0].x, run[0].y);
        for (let i = 1; i < run.length; i++)
            ctx.lineTo(run[i].x, run[i].y);
        ctx.lineWidth = width;
        ctx.lineJoin = "round";
        ctx.strokeStyle = color;
        ctx.stroke();
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        if (width <= 0 || height <= 0)
            return;

        if (grid) {
            ctx.strokeStyle = Theme.withAlpha(Theme.text, 0.07);
            ctx.lineWidth = 1;
            for (const f of [0.25, 0.5, 0.75]) {
                const y = Math.round(height * f) + 0.5;
                ctx.beginPath();
                ctx.moveTo(0, y);
                ctx.lineTo(width, y);
                ctx.stroke();
            }
        }

        const fill = ctx.createLinearGradient(0, 0, 0, height);
        fill.addColorStop(0, Theme.withAlpha(color, 0.38));
        fill.addColorStop(1, Theme.withAlpha(color, 0.02));
        for (const run of runs(pointsOf(values))) {
            if (run.length < 2)
                continue;
            ctx.beginPath();
            ctx.moveTo(run[0].x, height);
            for (const p of run)
                ctx.lineTo(p.x, p.y);
            ctx.lineTo(run[run.length - 1].x, height);
            ctx.closePath();
            ctx.fillStyle = fill;
            ctx.fill();
            stroke(ctx, run, color, 1.6);
        }

        for (const run of runs(pointsOf(values2)))
            if (run.length >= 2)
                stroke(ctx, run, color2, 1.4);
    }
}
