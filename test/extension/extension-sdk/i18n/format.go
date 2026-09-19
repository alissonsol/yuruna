// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// DefaultManifest is the world the shipped binaries resolve in, built from the
// generated locale table. Callers that need a different world -- the shared
// fixture, which declares its own supported set -- construct a Manifest instead.
func DefaultManifest() *Manifest {
	data := make(map[string]LocaleData, len(generatedLocaleData))
	for k, v := range generatedLocaleData {
		data[k] = v
	}
	aliases := make(map[string]string, len(generatedAliases))
	for k, v := range generatedAliases {
		aliases[k] = v
	}
	supported := append([]string(nil), generatedSupported...)
	return &Manifest{
		Default:         generatedDefault,
		Supported:       supported,
		Aliases:         aliases,
		Data:            data,
		MaxTagLength:    generatedMaxTagLength,
		MaxHeaderLength: generatedMaxHeaderLength,
	}
}

func (m *Manifest) dataFor(tag string) LocaleData {
	if m != nil {
		if d, ok := m.Data[tag]; ok {
			return d
		}
		if d, ok := m.Data[m.Default]; ok {
			return d
		}
	}
	return LocaleData{Group: ",", Decimal: ".", GroupSize: 3, PluralRule: "one-if-1", Direction: "ltr"}
}

// ErrNoPluralRule reports a locale whose plural rule the manifest has not
// pinned. It is an error rather than a silent fallback because English and
// Portuguese disagree about zero: borrowing one language's rule for another
// produces grammar that reads fine to everyone who does not speak it, and no
// test written in English would catch it.
type ErrNoPluralRule struct{ Locale string }

func (e *ErrNoPluralRule) Error() string {
	return "no pinned plural rule for " + e.Locale + "; refusing to guess one"
}

// PluralCategory is the CLDR category a count takes in a locale.
func PluralCategory(count float64, tag string, m *Manifest) (string, error) {
	rule := m.dataFor(tag).PluralRule
	if rule == "" {
		return "", &ErrNoPluralRule{Locale: tag}
	}
	switch rule {
	case "one-if-1":
		if count == 1 {
			return "one", nil
		}
		return "other", nil
	case "pt-cardinal-cldr46":
		absolute := math.Abs(count)
		if math.Floor(absolute) <= 1 {
			return "one", nil
		}
		if absolute > 0 && math.Mod(absolute, 1000000) == 0 {
			return "many", nil
		}
		return "other", nil
	default:
		return "", fmt.Errorf("plural rule %q for %s has no implementation here", rule, tag)
	}
}

// groupDigits punctuates a digit string from the right.
func groupDigits(digits, sep string, size int) string {
	if sep == "" || size <= 0 || len(digits) <= size {
		return digits
	}
	var b strings.Builder
	lead := len(digits) % size
	if lead > 0 {
		b.WriteString(digits[:lead])
	}
	for i := lead; i < len(digits); i += size {
		if b.Len() > 0 {
			b.WriteString(sep)
		}
		b.WriteString(digits[i : i+size])
	}
	return b.String()
}

// FormatNumber writes a number the way the locale manifest says this locale
// writes it.
//
// The separators come from the manifest, not from Go's own locale handling.
// The same number is written by a PowerShell command into a transcript, by
// this service into a page, and by a browser with no Intl at all; a reader
// comparing them cannot tell a formatting difference from a real one, so all
// three read one table.
func FormatNumber(value float64, decimals int, tag string, m *Manifest) string {
	d := m.dataFor(tag)
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return ""
	}
	negative := value < 0
	text := strconv.FormatFloat(math.Abs(value), 'f', decimals, 64)
	whole, frac, hasFrac := strings.Cut(text, ".")
	out := groupDigits(whole, d.Group, d.GroupSize)
	if hasFrac {
		out += d.Decimal + frac
	}
	if negative {
		return "-" + out
	}
	return out
}

// FormatDuration writes a number of seconds as a coarse human duration.
//
// It floors and never rounds. 5400 seconds is an hour and a half, and a rule
// that rounded would report it as "2h 30m" -- longer than the time that
// actually passed, in the part of the string a reader is least likely to
// question.
func FormatDuration(seconds float64) string {
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds < 0 {
		return ""
	}
	total := int64(math.Floor(seconds))
	h := total / 3600
	mn := (total % 3600) / 60
	s := total % 60
	switch {
	case h >= 1:
		return fmt.Sprintf("%dh %dm", h, mn)
	case mn >= 1:
		return fmt.Sprintf("%dm %ds", mn, s)
	default:
		return fmt.Sprintf("%ds", s)
	}
}

// FormatArgument renders one typed argument for a reader.
//
// The declared type chooses the formatting, so a caller passes a value rather
// than a pre-formatted string: a caller that formatted its own number would
// bake one locale's separators into every locale's output.
func FormatArgument(value any, argType, tag string, m *Manifest) string {
	if value == nil {
		return ""
	}
	switch argType {
	case "integer":
		n, ok := toFloat(value)
		if !ok {
			return fmt.Sprint(value)
		}
		return FormatNumber(n, 0, tag, m)
	case "decimal":
		n, ok := toFloat(value)
		if !ok {
			return fmt.Sprint(value)
		}
		return FormatNumber(n, 2, tag, m)
	case "duration":
		n, ok := toFloat(value)
		if !ok {
			return ""
		}
		return FormatDuration(n)
	case "datetime":
		// A fixed, locale-independent shape in UTC, and the same one the other
		// runtimes write. A timestamp read off a page and pasted into a
		// transcript search has to be the string the transcript holds.
		when, ok := toTime(value)
		if !ok {
			return ""
		}
		return when.UTC().Format("2006-01-02 15:04:05") + " UTC"
	default:
		// An external value is placed as given and never parsed back into
		// state. Escaping belongs to the surface that renders it, which knows
		// whether it is writing HTML, a header or a log line.
		return fmt.Sprint(value)
	}
}

func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int32:
		return float64(n), true
	case int64:
		return float64(n), true
	case uint:
		return float64(n), true
	case uint32:
		return float64(n), true
	case uint64:
		return float64(n), true
	case string:
		parsed, err := strconv.ParseFloat(n, 64)
		return parsed, err == nil
	}
	return 0, false
}

func toTime(v any) (time.Time, bool) {
	switch t := v.(type) {
	case time.Time:
		return t, true
	case string:
		for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05Z", "2006-01-02 15:04:05"} {
			if parsed, err := time.Parse(layout, t); err == nil {
				return parsed, true
			}
		}
	}
	return time.Time{}, false
}
