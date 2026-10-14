.pragma library

// Clean URL: strip tracking parameters from a copied link.
// Pure JS (QML's engine has no URL class), unit-tested by tests/urlclean.test.js.

// Removed on every site.
const GLOBAL = [/^utm_/i, /^fbclid$/i, /^gclid$/i, /^gclsrc$/i, /^dclid$/i, /^gbraid$/i, /^wbraid$/i, /^msclkid$/i, /^yclid$/i, /^twclid$/i, /^ttclid$/i, /^li_fat_id$/i, /^mc_cid$/i, /^mc_eid$/i, /^_hsenc$/i, /^_hsmi$/i, /^__hstc$/i, /^__hssc$/i, /^__hsfp$/i, /^hsctatracking$/i, /^mkt_tok$/i, /^igshid$/i, /^igsh$/i, /^vero_id$/i, /^vero_conv$/i, /^oly_anon_id$/i, /^oly_enc_id$/i, /^rb_clickid$/i, /^s_cid$/i, /^srsltid$/i, /^_openstat$/i, /^wickedid$/i, /^ref_src$/i, /^ref_url$/i, /^trk$/i, /^trkCampaign$/i, /^sc_cid$/i, /^ncid$/i, /^cmpid$/i, /^campaign_id$/i, /^ad_id$/i, /^spm$/i, /^scm$/i];

// Removed only on these hosts (the same names mean something elsewhere).
const PER_HOST = [
    { host: /(^|\.)(youtube\.com|youtu\.be)$/i, params: [/^si$/i, /^feature$/i, /^pp$/i] },
    { host: /(^|\.)spotify\.com$/i, params: [/^si$/i, /^context$/i, /^nd$/i] },
    { host: /(^|\.)(twitter\.com|x\.com)$/i, params: [/^s$/i, /^t$/i] },
    { host: /(^|\.)instagram\.com$/i, params: [/^img_index$/i] },
    { host: /(^|\.)amazon\.[a-z.]+$/i, params: [/^ref$/i, /^ref_$/i, /^pd_rd_/i, /^pf_rd_/i, /^psc$/i, /^content-id$/i, /^crid$/i, /^sprefix$/i, /^qid$/i, /^sr$/i] },
    { host: /(^|\.)linkedin\.com$/i, params: [/^trackingId$/i, /^refId$/i, /^lipi$/i, /^trk/i] },
    { host: /(^|\.)reddit\.com$/i, params: [/^share_id$/i, /^utm_/i, /^rdt$/i] },
    { host: /(^|\.)tiktok\.com$/i, params: [/^_r$/i, /^_t$/i, /^is_from_webapp$/i, /^sender_device$/i] }
];

// A single http(s) URL, nothing else on the line.
function isUrl(text) {
    return /^https?:\/\/[^\s]+$/i.test(String(text).trim());
}

function hostOf(url) {
    const m = /^https?:\/\/(?:[^@/?#]*@)?([^:/?#]+)/i.exec(url);
    return m ? m[1] : "";
}

function tracked(name, host) {
    if (GLOBAL.some(r => r.test(name)))
        return true;
    return PER_HOST.some(h => h.host.test(host) && h.params.some(r => r.test(name)));
}

// The URL without tracking parameters; unchanged (same string) when it
// isn't a URL or carries none.
function clean(text) {
    const url = String(text).trim();
    if (!isUrl(url))
        return text;
    const hashAt = url.indexOf("#");
    const hash = hashAt >= 0 ? url.slice(hashAt) : "";
    const beforeHash = hashAt >= 0 ? url.slice(0, hashAt) : url;
    const qAt = beforeHash.indexOf("?");
    if (qAt < 0)
        return text;
    const base = beforeHash.slice(0, qAt);
    const host = hostOf(url);
    const params = beforeHash.slice(qAt + 1).split("&").filter(p => p !== "");
    const kept = params.filter(p => {
        let name = p.split("=")[0];
        try {
            name = decodeURIComponent(name);
        } catch (e) {}
        return !tracked(name, host);
    });
    if (kept.length === params.length)
        return text;
    return base + (kept.length ? "?" + kept.join("&") : "") + hash;
}

// Whether clean() would change it.
function isTracked(text) {
    return clean(text) !== text;
}
