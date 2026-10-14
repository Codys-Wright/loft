package main

// Math, units and currencies through qalc. normalize() turns Spotlight-style
// queries into what qalc parses the way people mean them; evaluate() drops
// anything qalc only half understood (warnings, errors, "5 apples").

import (
	"context"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

var (
	// The last "to"-like word splits value and target: "5 ft 3 in to cm".
	reTo = regexp.MustCompile(`(?i)^(.*\S)\s+(?:to|in|into|as|->|→|=>)\s+([^\s\d].*)$`)
	// Temperatures: "72f", "72 °F", "20 deg c", "300 kelvin"; targets "c", "°f".
	reTempValue  = regexp.MustCompile(`(?i)^(-?\d+(?:\.\d+)?)\s*(?:°\s*|deg(?:rees?)?\s*)?(f|c|k|fahrenheit|celsius|kelvin)$`)
	reTempTarget = regexp.MustCompile(`(?i)^(?:°\s*|deg(?:rees?)?\s*)?(f|c|k|fahrenheit|celsius|kelvin)$`)
	rePercentOf  = regexp.MustCompile(`(?i)^(-?\d+(?:\.\d+)?)\s*%\s+of\s+(.+)$`)
	rePercentOff = regexp.MustCompile(`(?i)^(-?\d+(?:\.\d+)?)\s*%\s+off\s+(.+)$`)
	reNumber     = regexp.MustCompile(`-?\d+(?:\.\d+)?(?:E[-+]?\d+)?`)
	reDays       = regexp.MustCompile(`(\d+) days?`)
	reCurrency   = regexp.MustCompile(`[$€£¥₹₽₩฿₿]|\b[A-Z]{3}\b`)
)

var tempUnit = map[string]string{
	"f": "°F", "fahrenheit": "°F", "c": "°C", "celsius": "°C", "k": "K", "kelvin": "K",
}

// normalize rewrites q for qalc; conv reports a unit/currency conversion.
func normalize(q string) (expr string, conv bool) {
	q = normSpace(q)

	if m := rePercentOf.FindStringSubmatch(q); m != nil {
		return fmt.Sprintf("(%s/100) * (%s)", m[1], m[2]), false
	}
	if m := rePercentOff.FindStringSubmatch(q); m != nil {
		return fmt.Sprintf("(%s) * (1 - %s/100)", m[2], m[1]), false
	}

	m := reTo.FindStringSubmatch(q)
	if m == nil {
		return q, false
	}
	value, target := strings.TrimSpace(m[1]), strings.TrimSpace(m[2])

	if v := reTempValue.FindStringSubmatch(value); v != nil {
		if t := reTempTarget.FindStringSubmatch(target); t != nil {
			return fmt.Sprintf("%s %s to %s", v[1], tempUnit[strings.ToLower(v[2])], tempUnit[strings.ToLower(t[1])]), true
		}
	}

	// One target unit: no mixed units ("3.11 mi", not "3 mi + 188 yd").
	if !strings.ContainsAny(target, " +*/^()") {
		target = "-" + target
	}
	return value + " to " + target, true
}

// interesting: worth a row (a plain "42" or "2024" isn't).
func interesting(q string) bool {
	if !strings.ContainsFunc(q, unicode.IsDigit) {
		return false
	}
	if _, err := strconv.ParseFloat(strings.TrimSpace(q), 64); err == nil {
		return false
	}
	return true
}

type calcResult struct {
	text   string // "3.1069 mi"
	full   string // qalc's own result, full precision
	parsed string // how qalc read it: "5 kilometers"
	exact  bool   // "=" rather than "≈"
	money  bool
	stale  string // "16 days old": qalc's note on the currency rates
}

func qalcEnv() []string {
	return append(os.Environ(), "XDG_CONFIG_HOME="+qalcConfigDir())
}

// qalc keeps its settings in its own config dir (it saves them on exit), so
// the person's qalc setup is neither used nor changed.
func qalcConfigDir() string {
	if config != nil && config.QalcConfig != "" {
		return config.QalcConfig
	}
	d, err := os.UserCacheDir()
	if err != nil {
		d = os.TempDir()
	}
	return filepath.Join(d, "loft", "qalc")
}

var qalcArgs = []string{"-s", "color 0", "-s", "upxrates 0", "-s", "unicode on", "-s", "digit grouping 0", "-m", "700"}

func evaluate(q string) *calcResult {
	if !interesting(q) || looksLikeTime(q) {
		return nil
	}
	expr, conv := normalize(q)

	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	cmd := exec.CommandContext(ctx, "qalc", append(append([]string{}, qalcArgs...), expr)...)
	cmd.Env = qalcEnv()
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	return parseQalc(string(out), expr, conv)
}

// parseQalc reads "5 kilometers ≈ 3.106855961 mi" (non-terse output).
func parseQalc(out, expr string, conv bool) *calcResult {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	stale := ""
	for _, l := range lines {
		l = strings.TrimSpace(strings.ToLower(l))
		if strings.Contains(l, "exchange rates") {
			// "warning: It has been 16 days since the exchange rates last were updated."
			if m := reDays.FindStringSubmatch(l); m != nil {
				stale = m[1] + " days old"
			}
			continue
		}
		if strings.HasPrefix(l, "error:") || strings.HasPrefix(l, "warning:") {
			return nil
		}
	}
	last := strings.TrimSpace(lines[len(lines)-1])

	sep, exact := " ≈ ", false
	i := strings.LastIndex(last, sep)
	if j := strings.LastIndex(last, " = "); j > i {
		i, sep, exact = j, " = ", true
	}
	if i < 0 {
		return nil
	}
	parsed, full := strings.TrimSpace(last[:i]), strings.TrimSpace(last[i+len(sep):])
	if full == "" || strings.Contains(full, "undefined") {
		return nil
	}
	// qalc answering with the question: "x" → "x", "1/2" fine but "a = a" not.
	if strings.EqualFold(normSpace(full), normSpace(expr)) {
		return nil
	}

	// Unit soup ("3pm PT in Berli" → "1.2E49 rli·T·B·e/(C·bit)"): qalc read
	// words as unit products. Only keep products the query asked for.
	if strings.Contains(full, "·") && !strings.ContainsAny(expr, "*·") {
		return nil
	}

	r := &calcResult{full: full, parsed: parsed, exact: exact, stale: stale}
	r.money = reCurrency.MatchString(full)
	r.text = round(full, r.money)
	_ = conv
	return r
}

// round shortens long decimals: money to cents, others to 4 places (tiny
// numbers keep qalc's precision, so 1e-9 doesn't become 0).
func round(s string, money bool) string {
	return reNumber.ReplaceAllStringFunc(s, func(n string) string {
		if strings.ContainsAny(n, "Ee") || !strings.Contains(n, ".") {
			return n
		}
		f, err := strconv.ParseFloat(n, 64)
		if err != nil {
			return n
		}
		places := 4
		if money {
			places = 2
		} else if a := math.Abs(f); a != 0 && a < 0.01 {
			return n
		}
		out := strconv.FormatFloat(f, 'f', places, 64)
		if !money {
			out = strings.TrimRight(strings.TrimRight(out, "0"), ".")
		}
		return out
	})
}

// number: the first number of a result ("3.1069 mi" → "3.1069").
func number(s string) string {
	if n := reNumber.FindString(s); n != "" {
		return n
	}
	return s
}

// ── Currency rates (opt-in download, at most daily) ──────────────────────

func ratesFiles() []string {
	d := os.Getenv("XDG_DATA_HOME")
	if d == "" {
		h, _ := os.UserHomeDir()
		d = filepath.Join(h, ".local", "share")
	}
	q := filepath.Join(d, "qalculate")
	return []string{filepath.Join(q, "eurofxref-daily.xml"), filepath.Join(q, "rates.json")}
}

// ratesAge: when qalc's rates were last downloaded (zero: never, built-in).
func ratesAge() time.Time {
	var t time.Time
	for _, f := range ratesFiles() {
		if st, err := os.Stat(f); err == nil && st.ModTime().After(t) {
			t = st.ModTime()
		}
	}
	return t
}

func ratesNote(stale string) string {
	t := ratesAge()
	if t.IsZero() {
		if stale != "" {
			return "built-in rates, " + stale
		}
		return "built-in rates"
	}
	if time.Since(t) < 36*time.Hour {
		return "rates from " + t.Format("Jan 2, 15:04")
	}
	return "rates from " + t.Format("Jan 2")
}

// looksLikeTime: "3pm PT in Berl" while typing a time-zone query, or "9:30
// tokyo" — leave those to timeQuery instead of letting qalc guess units.
func looksLikeTime(q string) bool {
	c := reClockPre.FindStringSubmatch(normSpace(strings.ToLower(q)))
	if c == nil || strings.TrimSpace(c[2]) == "" {
		return false
	}
	clock := c[1]
	return strings.ContainsAny(clock, ":") || strings.HasSuffix(clock, "m") || strings.HasSuffix(clock, "a") || strings.HasSuffix(clock, "p")
}
