package main

// Time zones: "3pm PT in Berlin", "9:30 tokyo to london", "time in Sydney",
// "now in utc+5:30", "noon cet". Cities come from the tz database (its last
// path component: "Los_Angeles" → "los angeles") plus the aliases below.

import (
	"fmt"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	_ "time/tzdata" // LoadLocation works without a system zoneinfo
	"unicode"
)

// Common abbreviations and names. Daylight/standard variants map to the same
// zone: "PST" in July means the time in Los Angeles, as people use it.
var tzAbbr = map[string]string{
	"pt": "America/Los_Angeles", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pacific": "America/Los_Angeles",
	"mt": "America/Denver", "mst": "America/Denver", "mdt": "America/Denver", "mountain": "America/Denver",
	"ct": "America/Chicago", "cst": "America/Chicago", "cdt": "America/Chicago", "central": "America/Chicago",
	"et": "America/New_York", "est": "America/New_York", "edt": "America/New_York", "eastern": "America/New_York",
	"akst": "America/Anchorage", "akdt": "America/Anchorage", "hst": "Pacific/Honolulu",
	"utc": "UTC", "gmt": "UTC", "z": "UTC", "zulu": "UTC",
	"bst": "Europe/London", "wet": "Europe/Lisbon", "west": "Europe/Lisbon",
	"cet": "Europe/Berlin", "cest": "Europe/Berlin", "eet": "Europe/Athens", "eest": "Europe/Athens",
	"msk": "Europe/Moscow", "ist": "Asia/Kolkata", "pkt": "Asia/Karachi", "sgt": "Asia/Singapore",
	"hkt": "Asia/Hong_Kong", "jst": "Asia/Tokyo", "kst": "Asia/Seoul", "aest": "Australia/Sydney",
	"aedt": "Australia/Sydney", "acst": "Australia/Adelaide", "awst": "Australia/Perth",
	"nzst": "Pacific/Auckland", "nzdt": "Pacific/Auckland", "brt": "America/Sao_Paulo",
}

// Places the tz database doesn't name (or names differently).
var tzAlias = map[string]string{
	"nyc": "America/New_York", "ny": "America/New_York", "new york city": "America/New_York",
	"la": "America/Los_Angeles", "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
	"seattle": "America/Los_Angeles", "portland": "America/Los_Angeles", "san diego": "America/Los_Angeles",
	"las vegas": "America/Los_Angeles", "california": "America/Los_Angeles", "silicon valley": "America/Los_Angeles",
	"boston": "America/New_York", "washington": "America/New_York", "dc": "America/New_York",
	"miami": "America/New_York", "atlanta": "America/New_York", "philadelphia": "America/New_York",
	"austin": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago", "texas": "America/Chicago",
	"salt lake city": "America/Denver", "hawaii": "Pacific/Honolulu", "alaska": "America/Anchorage",
	"montreal": "America/Toronto", "ottawa": "America/Toronto", "calgary": "America/Edmonton",
	"uk": "Europe/London", "england": "Europe/London", "britain": "Europe/London", "scotland": "Europe/London",
	"edinburgh": "Europe/London", "manchester": "Europe/London", "ireland": "Europe/Dublin",
	"germany": "Europe/Berlin", "munich": "Europe/Berlin", "hamburg": "Europe/Berlin", "frankfurt": "Europe/Berlin",
	"cologne": "Europe/Berlin", "france": "Europe/Paris", "spain": "Europe/Madrid", "barcelona": "Europe/Madrid",
	"italy": "Europe/Rome", "milan": "Europe/Rome", "netherlands": "Europe/Amsterdam", "switzerland": "Europe/Zurich",
	"geneva": "Europe/Zurich", "sweden": "Europe/Stockholm", "norway": "Europe/Oslo", "denmark": "Europe/Copenhagen",
	"finland": "Europe/Helsinki", "poland": "Europe/Warsaw", "austria": "Europe/Vienna", "portugal": "Europe/Lisbon",
	"greece": "Europe/Athens", "ukraine": "Europe/Kyiv", "kiev": "Europe/Kyiv", "russia": "Europe/Moscow",
	"st petersburg": "Europe/Moscow", "turkey": "Europe/Istanbul", "israel": "Asia/Jerusalem", "tel aviv": "Asia/Jerusalem",
	"egypt": "Africa/Cairo", "uae": "Asia/Dubai", "abu dhabi": "Asia/Dubai", "india": "Asia/Kolkata",
	"mumbai": "Asia/Kolkata", "bombay": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
	"bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "chennai": "Asia/Kolkata", "hyderabad": "Asia/Kolkata",
	"pakistan": "Asia/Karachi", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "shenzhen": "Asia/Shanghai",
	"guangzhou": "Asia/Shanghai", "japan": "Asia/Tokyo", "osaka": "Asia/Tokyo", "kyoto": "Asia/Tokyo",
	"korea": "Asia/Seoul", "south korea": "Asia/Seoul", "vietnam": "Asia/Ho_Chi_Minh", "saigon": "Asia/Ho_Chi_Minh",
	"hanoi": "Asia/Bangkok", "thailand": "Asia/Bangkok", "philippines": "Asia/Manila", "indonesia": "Asia/Jakarta",
	"bali": "Asia/Makassar", "taiwan": "Asia/Taipei", "australia": "Australia/Sydney", "canberra": "Australia/Sydney",
	"new zealand": "Pacific/Auckland", "nz": "Pacific/Auckland", "wellington": "Pacific/Auckland",
	"brazil": "America/Sao_Paulo", "rio": "America/Sao_Paulo", "rio de janeiro": "America/Sao_Paulo",
	"argentina": "America/Argentina/Buenos_Aires", "mexico": "America/Mexico_City", "peru": "America/Lima",
	"colombia": "America/Bogota", "chile": "America/Santiago", "kenya": "Africa/Nairobi", "nigeria": "Africa/Lagos",
	"south africa": "Africa/Johannesburg", "cape town": "Africa/Johannesburg",
}

var (
	cityOnce sync.Once
	cities   map[string]string // "los angeles" → "America/Los_Angeles"
)

func zoneinfoDir() string {
	for _, d := range []string{os.Getenv("ZONEINFO"), "/etc/zoneinfo", "/usr/share/zoneinfo", "/usr/share/lib/zoneinfo"} {
		if d == "" {
			continue
		}
		if st, err := os.Stat(filepath.Join(d, "Europe")); err == nil && st.IsDir() {
			return d
		}
	}
	return ""
}

// zoneNames (zones.go) is the tz database's list, so cities resolve without a
// zoneinfo directory too (build sandboxes, minimal systems). Regenerate with
// /etc/zoneinfo/{zone1970.tab,tzdata.zi}: the third column of the first, the
// link names ("L target name") of the second, under the regions below.
func loadCities() {
	cities = map[string]string{}
	add := func(name string) {
		key := strings.ToLower(strings.ReplaceAll(filepath.Base(name), "_", " "))
		if _, taken := cities[key]; !taken {
			cities[key] = name
		}
	}
	for _, n := range zoneNames {
		add(n)
	}
	root := zoneinfoDir()
	if root == "" {
		return
	}
	for _, region := range []string{"Africa", "America", "Antarctica", "Asia", "Atlantic", "Australia", "Europe", "Indian", "Pacific"} {
		_ = filepath.WalkDir(filepath.Join(root, region), func(p string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			rel, _ := filepath.Rel(root, p)
			add(rel)
			return nil
		})
	}
}

var reOffset = regexp.MustCompile(`^(?:utc|gmt)?\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?$`)

// findZone resolves a place, abbreviation or UTC offset; label names it.
func findZone(s string) (loc *time.Location, label string, ok bool) {
	s = normSpace(strings.ToLower(strings.Trim(s, " ?.,")))
	s = strings.TrimPrefix(s, "the ")
	if s == "" {
		return nil, "", false
	}
	switch s {
	case "local", "here", "local time", "my time", "home":
		return time.Local, "local time", true
	}
	if m := reOffset.FindStringSubmatch(s); m != nil {
		h, _ := strconv.Atoi(m[2])
		mins := 0
		if m[3] != "" {
			mins, _ = strconv.Atoi(m[3])
		}
		if h > 14 || mins > 59 {
			return nil, "", false
		}
		off := h*3600 + mins*60
		if m[1] == "-" {
			off = -off
		}
		label = "UTC" + m[1] + strconv.Itoa(h)
		if mins != 0 {
			label += fmt.Sprintf(":%02d", mins)
		}
		return time.FixedZone(label, off), label, true
	}

	name, viaAbbr := tzAbbr[s], true
	if name == "" {
		viaAbbr = false
		name = tzAlias[s]
	}
	if name == "" {
		cityOnce.Do(loadCities)
		name = cities[s]
	}
	if name == "" {
		return nil, "", false
	}
	l, err := time.LoadLocation(name)
	if err != nil {
		return nil, "", false
	}
	if name == "UTC" {
		return l, "UTC", true
	}
	label = strings.ReplaceAll(name[strings.LastIndex(name, "/")+1:], "_", " ")
	if !viaAbbr && tzAlias[s] != "" {
		label = titleCase(s)
		if len(s) <= 3 {
			label = strings.ToUpper(s)
		}
	}
	return l, label, true
}

var reClock = regexp.MustCompile(`^(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.|a|p)?$`)

// parseClock: "3pm", "3:30 pm", "15:00", "noon", "midnight", "now".
// A bare number is not a time ("5 to 3").
func parseClock(s string) (h, m int, now, ok bool) {
	switch s {
	case "now", "right now":
		return 0, 0, true, true
	case "noon", "midday":
		return 12, 0, false, true
	case "midnight":
		return 0, 0, false, true
	}
	c := reClock.FindStringSubmatch(s)
	if c == nil || (c[2] == "" && c[3] == "") {
		return 0, 0, false, false
	}
	h, _ = strconv.Atoi(c[1])
	if c[2] != "" {
		m, _ = strconv.Atoi(c[2])
	}
	if m > 59 {
		return 0, 0, false, false
	}
	switch strings.TrimSuffix(strings.ReplaceAll(c[3], ".", ""), "m") {
	case "a":
		if h < 1 || h > 12 {
			return 0, 0, false, false
		}
		if h == 12 {
			h = 0
		}
	case "p":
		if h < 1 || h > 12 {
			return 0, 0, false, false
		}
		if h != 12 {
			h += 12
		}
	default:
		if h > 23 {
			return 0, 0, false, false
		}
	}
	return h, m, false, true
}

var (
	reTimeIn   = regexp.MustCompile(`^(?:what(?:'s| is) )?(?:the )?(?:current )?time (?:in|at|for) (.+)$`)
	reTimeOf   = regexp.MustCompile(`^(?:time|now) (?:in |at )?(.+)$`)
	rePlaceNow = regexp.MustCompile(`^(.+) (?:time|now)$`)
	reConvert  = regexp.MustCompile(`^(.+?)\s+(?:in|to|at|as|into|->|→|=>)\s+(.+)$`)
	reClockPre = regexp.MustCompile(`^(now|noon|midday|midnight|\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.|a|p)?)(?:\s+(.*))?$`)
)

type tzResult struct {
	text, sub, copy string
}

// timeQuery answers time-zone questions; nil when q isn't one.
func timeQuery(q string, now time.Time) *tzResult {
	lq := normSpace(strings.ToLower(strings.Trim(q, " ?")))
	if lq == "" || !strings.ContainsFunc(lq, unicode.IsLetter) {
		return nil
	}

	// "time in tokyo", "tokyo time", "now in utc+2"
	for _, re := range []*regexp.Regexp{reTimeIn, reTimeOf, rePlaceNow} {
		if m := re.FindStringSubmatch(lq); m != nil {
			if loc, label, ok := findZone(m[1]); ok {
				return nowIn(now, loc, label)
			}
		}
	}

	// "<clock> [zone] in <zone>" or "<clock> <zone>" (→ local time)
	left, right := lq, ""
	if m := reConvert.FindStringSubmatch(lq); m != nil {
		left, right = m[1], m[2]
	}
	c := reClockPre.FindStringSubmatch(left)
	if c == nil {
		return nil
	}
	h, mi, isNow, ok := parseClock(strings.TrimSpace(c[1]))
	if !ok {
		return nil
	}

	srcLoc, srcLabel := time.Local, "local time"
	if strings.TrimSpace(c[2]) != "" {
		l, lab, ok := findZone(c[2])
		if !ok {
			return nil
		}
		srcLoc, srcLabel = l, lab
	}
	dstLoc, dstLabel := time.Local, "local time"
	if right != "" {
		l, lab, ok := findZone(right)
		if !ok {
			return nil
		}
		dstLoc, dstLabel = l, lab
	} else if strings.TrimSpace(c[2]) == "" {
		return nil // just "3pm"
	}
	if isNow {
		return nowIn(now, dstLoc, dstLabel)
	}

	sn := now.In(srcLoc)
	src := time.Date(sn.Year(), sn.Month(), sn.Day(), h, mi, 0, 0, srcLoc)
	dst := src.In(dstLoc)

	day := ""
	switch dayDiff(src, dst) {
	case 1:
		day = ", next day"
	case -1:
		day = ", previous day"
	}
	return &tzResult{
		text: fmt.Sprintf("%s %s%s", clock(dst), where(dst, dstLabel), day),
		sub:  fmt.Sprintf("%s %s  ·  %s", clock(src), where(src, srcLabel), ahead(src, dst, dstLabel, srcLabel)),
		copy: clock(dst) + " " + dst.Format("MST"),
	}
}

func nowIn(now time.Time, loc *time.Location, label string) *tzResult {
	t := now.In(loc)
	here := now.In(time.Local)
	return &tzResult{
		text: fmt.Sprintf("%s %s", clock(t), where(t, label)),
		sub:  fmt.Sprintf("%s  ·  %s", t.Format("Monday, January 2"), ahead(here, t, label, "local time")),
		copy: clock(t) + " " + t.Format("MST"),
	}
}

func clock(t time.Time) string { return t.Format("3:04 PM") }

// where: "CEST in Berlin", "UTC+5:30", "PDT (local time)".
func where(t time.Time, label string) string {
	abbr := t.Format("MST")
	switch {
	case label == "local time":
		return abbr + " (local time)"
	case strings.EqualFold(abbr, label):
		return abbr
	case abbr[0] == '+' || abbr[0] == '-':
		return "in " + label + " (UTC" + abbr + ")"
	}
	return abbr + " in " + label
}

func ahead(from, to time.Time, toLabel, fromLabel string) string {
	_, a := from.Zone()
	_, b := to.Zone()
	d := float64(b-a) / 3600
	if d == 0 {
		return "same time as " + fromLabel
	}
	hours := strconv.FormatFloat(math.Abs(d), 'f', -1, 64)
	unit := "hours"
	if math.Abs(d) == 1 {
		unit = "hour"
	}
	dir := "ahead of"
	if d < 0 {
		dir = "behind"
	}
	name := toLabel
	if name == "local time" {
		name = "local time"
	}
	return fmt.Sprintf("%s is %s %s %s %s", capitalize(name), hours, unit, dir, fromLabel)
}

func dayDiff(a, b time.Time) int {
	ad := time.Date(a.Year(), a.Month(), a.Day(), 0, 0, 0, 0, time.UTC)
	bd := time.Date(b.Year(), b.Month(), b.Day(), 0, 0, 0, 0, time.UTC)
	return int(bd.Sub(ad).Hours() / 24)
}

func normSpace(s string) string { return strings.Join(strings.Fields(s), " ") }

func titleCase(s string) string {
	w := strings.Fields(s)
	for i, x := range w {
		w[i] = capitalize(x)
	}
	return strings.Join(w, " ")
}

func capitalize(s string) string {
	if s == "" {
		return s
	}
	r := []rune(s)
	r[0] = unicode.ToUpper(r[0])
	return string(r)
}
