package main

import (
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestNormalize(t *testing.T) {
	cases := map[string]string{
		"5 km to mi":        "5 km to -mi",
		"100 usd in eur":    "100 usd to -eur",
		"72f to c":          "72 °F to °C",
		"72 °F in °C":       "72 °F to °C",
		"20 degrees c as f": "20 °C to °F",
		"1 GiB in MB":       "1 GiB to -MB",
		"5 ft 3 in to cm":   "5 ft 3 in to -cm",
		"15% of 80":         "(15/100) * (80)",
		"20% off 59.99":     "(59.99) * (1 - 20/100)",
		"2+2":               "2+2",
		"5 m to ft in":      "5 m to ft in",
	}
	for in, want := range cases {
		if got, _ := normalize(in); got != want {
			t.Errorf("normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRound(t *testing.T) {
	cases := map[[2]string]string{
		{"3.106855961 mi", ""}: "3.1069 mi",
		{"€87.8889", "money"}:  "€87.89",
		{"1073.741824 MB", ""}: "1073.7418 MB",
		{"0.000001 m", ""}:     "0.000001 m",
		{"4", ""}:              "4",
		{"22.22222222 °C", ""}: "22.2222 °C",
	}
	for in, want := range cases {
		if got := round(in[0], in[1] != ""); got != want {
			t.Errorf("round(%q) = %q, want %q", in[0], got, want)
		}
	}
}

func TestParseQalc(t *testing.T) {
	if r := parseQalc("error: \"p\" is not a valid variable/function/unit.\n5 are·picoliters ≈ 1.3 ps", "5 apples", false); r != nil {
		t.Errorf("errors must drop the row, got %+v", r)
	}
	if r := parseQalc("warning: Did you mean \"hecto\"?\nhour ≈ 13 B", "hello 5", false); r != nil {
		t.Errorf("warnings must drop the row, got %+v", r)
	}
	r := parseQalc("5 kilometers ≈ 3.106855961 mi", "5 km to -mi", true)
	if r == nil || r.text != "3.1069 mi" || r.parsed != "5 kilometers" || r.exact {
		t.Errorf("parse: %+v", r)
	}
	r = parseQalc("100 USD ≈ €89.3815", "100 usd to -eur", true)
	if r == nil || r.text != "€89.38" || !r.money {
		t.Errorf("money: %+v", r)
	}
}

func TestInteresting(t *testing.T) {
	for _, q := range []string{"42", "2024", "1.5", "hello"} {
		if interesting(q) {
			t.Errorf("%q should not be evaluated", q)
		}
	}
	for _, q := range []string{"2+2", "5 km to mi", "sqrt 2"} {
		if !interesting(q) {
			t.Errorf("%q should be evaluated", q)
		}
	}
}

func TestTimeQuery(t *testing.T) {
	la, _ := time.LoadLocation("America/Los_Angeles")
	// A Tuesday in October: PDT (UTC-7) and CEST (UTC+2).
	now := time.Date(2026, 10, 13, 10, 0, 0, 0, la)

	r := timeQuery("3pm PT in Berlin", now)
	if r == nil || !strings.HasPrefix(r.text, "12:00 AM CEST in Berlin, next day") {
		t.Fatalf("3pm PT in Berlin: %+v", r)
	}
	if !strings.Contains(r.sub, "Berlin is 9 hours ahead of Los Angeles") {
		t.Errorf("sub: %q", r.sub)
	}

	r = timeQuery("9:30 tokyo to london", now)
	if r == nil || !strings.HasPrefix(r.text, "1:30 AM BST in London") {
		t.Errorf("tokyo → london: %+v", r)
	}

	r = timeQuery("time in sydney", now)
	if r == nil || !strings.Contains(r.text, "in Sydney") {
		t.Errorf("time in sydney: %+v", r)
	}

	r = timeQuery("noon utc+5:30 to nyc", now)
	if r == nil || !strings.HasPrefix(r.text, "2:30 AM EDT in NYC") {
		t.Errorf("offset → alias: %+v", r)
	}

	for _, q := range []string{"5 km to mi", "3pm", "1 GiB in MB", "5 pm to 7 pm", "hello", "time in narnia"} {
		if r := timeQuery(q, now); r != nil {
			t.Errorf("%q is not a time query: %+v", q, r)
		}
	}
}

// With qalc on PATH (the nix build has it), the real thing.
func TestEvaluate(t *testing.T) {
	if _, err := exec.LookPath("qalc"); err != nil {
		t.Skip("no qalc")
	}
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	cases := map[string]string{
		"5 km to mi":      "3.1069 mi",
		"72f to c":        "22.2222 °C",
		"1 GiB in MB":     "1073.7418 MB",
		"5 ft 3 in to cm": "160.02 cm",
		"2^10":            "1024",
		"15% of 80":       "12",
	}
	for q, want := range cases {
		r := evaluate(q)
		if r == nil || r.text != want {
			t.Errorf("evaluate(%q) = %+v, want %q", q, r, want)
		}
	}
	for _, q := range []string{"5 apples", "hello 5", "42", "3pm PT in Berli", "3pm PT in Ber", "9:30 tok"} {
		if r := evaluate(q); r != nil {
			t.Errorf("evaluate(%q) should be dropped, got %+v", q, r)
		}
	}
	if r := evaluate("100 usd in eur"); r == nil || !r.money || !strings.HasPrefix(r.text, "€") {
		t.Errorf("currency: %+v", r)
	}
}
