.pragma library

// The Dynamic Island's wheel / swipe paging (Island.qml); tested by
// tests/island-paging.test.js.
//
// One wheel notch, or one touchpad swipe, is one page: deltas add up to a
// threshold, then the rest of that gesture is swallowed until the wheel
// rests (`idle()`, ~200 ms without events) or `LOCK_MS` pass — a swipe's
// tail of small events and kinetic scrolling don't page again.
//
// QtWayland hands every wheel event over with pixel deltas too, and calls
// a mouse wheel and a touchpad both "touchpad", so they're told apart by
// the ratio: a (hi-res) wheel's angle is 8 × its pixels, a touchpad's 12 ×.
// The dominant axis wins: down / right = next. A swipe pages after ~24 px
// of travel, so a resting finger's jitter doesn't.

var THRESHOLD = 120; // one notch
var PX_UNITS = 5; // 24 px of swipe = one notch
var LOCK_MS = 450;

function fresh() {
    return { acc: 0, locked: false, lockedAt: 0 };
}

// ev: { ax, ay, px, py } (angleDelta / pixelDelta). Returns { d, st } with
// d = +1 next, -1 previous, 0 nothing (yet).
function step(st, ev, now) {
    st = { acc: st.acc, locked: st.locked, lockedAt: st.lockedAt };
    var horizontal = Math.abs(ev.ax) > Math.abs(ev.ay);
    var angle = horizontal ? ev.ax : ev.ay;
    var pixels = horizontal ? ev.px : ev.py;
    if (st.locked && now - st.lockedAt < LOCK_MS)
        return { d: 0, st: st };
    st.locked = false;
    var continuous = pixels !== 0 && Math.abs(angle) > Math.abs(pixels) * 10;
    st.acc += continuous ? pixels * PX_UNITS : angle;
    if (Math.abs(st.acc) < THRESHOLD)
        return { d: 0, st: st };
    var d = st.acc < 0 ? 1 : -1;
    st.acc = 0;
    st.locked = true;
    st.lockedAt = now;
    return { d: d, st: st };
}

// The wheel came to rest: the next event starts a new gesture.
function idle() {
    return fresh();
}
