// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"
)

func TestMessageArgumentsUseCanonicalPortableEncodings(t *testing.T) {
	when := time.Date(2026, 9, 3, 12, 34, 56, 0, time.FixedZone("other", 2*60*60))
	envelope, err := NewMessageEnvelope("pool.assignment_blocked", map[string]Argument{
		"count":   {Type: "integer", Value: 7},
		"huge":    {Type: "integer", Value: "9007199254740992"},
		"ratio":   {Type: "decimal", Value: "001234.500"},
		"size":    {Type: "bytes", Value: uint64(^uint64(0))},
		"elapsed": {Type: "duration", Value: 90500},
		"when":    {Type: "datetime", Value: when},
	}, nil)
	if err != nil {
		t.Fatalf("constructing envelope: %v", err)
	}
	if got := envelope.Args["count"]; got != int64(7) {
		t.Errorf("safe integer = %#v, want int64(7)", got)
	}
	want := map[string]map[string]string{
		"huge":    {"$type": "integer", "value": "9007199254740992"},
		"ratio":   {"$type": "decimal", "value": "1234.5"},
		"size":    {"$type": "bytes", "value": "18446744073709551615"},
		"elapsed": {"$type": "duration", "milliseconds": "90500"},
		"when":    {"$type": "datetime", "value": "2026-09-03T10:34:56.0000000Z"},
	}
	for name, expected := range want {
		got, ok := envelope.Args[name].(map[string]string)
		if !ok {
			t.Errorf("%s = %#v, want typed map", name, envelope.Args[name])
			continue
		}
		for key, value := range expected {
			if got[key] != value {
				t.Errorf("%s.%s = %q, want %q", name, key, got[key], value)
			}
		}
	}

	raw, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var decoded MessageEnvelope
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if err := ValidateMessageEnvelope(decoded); err != nil {
		t.Fatalf("JSON round trip no longer satisfies v1: %v", err)
	}
}

func TestMessageBoundaryPreservesDecomposedUnicode(t *testing.T) {
	var fixture struct {
		UnicodePreservation struct {
			Decomposed    string   `json:"decomposed"`
			ArgumentTypes []string `json:"argumentTypes"`
			DetailSource  string   `json:"detailSource"`
		} `json:"unicodePreservation"`
	}
	readFixture(t, "message-envelope.json", &fixture)
	expected := fixture.UnicodePreservation.Decomposed
	for _, argumentType := range fixture.UnicodePreservation.ArgumentTypes {
		got, err := CanonicalArgument(Argument{Type: argumentType, Value: expected})
		if err != nil {
			t.Fatalf("%s argument: %v", argumentType, err)
		}
		if got != expected {
			t.Errorf("%s argument = %q, want exact source %q", argumentType, got, expected)
		}
	}
	detail, err := ProtectMessageDetail(expected, fixture.UnicodePreservation.DetailSource, nil)
	if err != nil {
		t.Fatal(err)
	}
	if detail.Text != expected {
		t.Errorf("detail = %q, want exact source %q", detail.Text, expected)
	}
}

func TestMessageWireBoundsUseDecimalTextAndUnicodeScalars(t *testing.T) {
	var fixture struct {
		WireBounds struct {
			LongDecimalDigit  string `json:"longDecimalDigit"`
			LongDecimalLength int    `json:"longDecimalLength"`
			Astral            string `json:"astral"`
			MaxScalars        int    `json:"maxScalars"`
		} `json:"wireBounds"`
	}
	readFixture(t, "message-envelope.json", &fixture)
	bounds := fixture.WireBounds
	decimal := strings.Repeat(bounds.LongDecimalDigit, bounds.LongDecimalLength)
	envelope, err := NewMessageEnvelope("pool.assignment_blocked", map[string]Argument{
		"ratio": {Type: "decimal", Value: decimal},
	}, nil)
	if err != nil {
		t.Fatalf("schema-bounded decimal: %v", err)
	}
	got := envelope.Args["ratio"].(map[string]string)["value"]
	if got != decimal {
		t.Errorf("long decimal = %q, want %q", got, decimal)
	}
	if _, err := NewMessageEnvelope("pool.assignment_blocked", map[string]Argument{
		"ratio": {Type: "decimal", Value: decimal + bounds.LongDecimalDigit},
	}, nil); err == nil {
		t.Fatal("decimal over the wire bound was accepted")
	}

	atLimit := strings.Repeat(bounds.Astral, bounds.MaxScalars)
	if _, err := CanonicalArgument(Argument{Type: "text", Value: atLimit}); err != nil {
		t.Fatalf("scalar-bounded astral argument: %v", err)
	}
	if _, err := CanonicalArgument(Argument{Type: "text", Value: atLimit + bounds.Astral}); err == nil {
		t.Fatal("astral argument over the scalar bound was accepted")
	}
	detail, err := ProtectMessageDetail(atLimit+bounds.Astral, "tool.stderr", nil)
	if err != nil {
		t.Fatal(err)
	}
	if detail.Text != atLimit || len([]rune(detail.Text)) != bounds.MaxScalars {
		t.Fatal("astral detail was truncated by bytes/code units rather than Unicode scalars")
	}
}

func TestMessageEnvelopeRefusesCredentialArguments(t *testing.T) {
	_, err := NewMessageEnvelope("pool.assignment_blocked", map[string]Argument{
		"apiToken": {Type: "text", Value: "secret"},
	}, nil)
	if err == nil || !strings.Contains(err.Error(), "credential-bearing") {
		t.Fatalf("credential argument was accepted: %v", err)
	}
}

func TestMessageEnvelopeValidationEnforcesJSONAndProvenanceBounds(t *testing.T) {
	base := MessageEnvelope{Schema: MessageSchema, Code: "pool.assignment_blocked", Args: map[string]any{}}
	cases := []struct {
		name  string
		value any
	}{
		{name: "unsafe integer", value: int64(9007199254740992)},
		{name: "not a number", value: math.NaN()},
		{name: "infinite", value: math.Inf(1)},
		{name: "oversized text", value: strings.Repeat("x", 4097)},
		{name: "oversized typed integer", value: map[string]any{"$type": "integer", "value": strings.Repeat("9", 81)}},
	}
	for _, tc := range cases {
		envelope := base
		envelope.Args = map[string]any{"value": tc.value}
		if err := ValidateMessageEnvelope(envelope); err == nil {
			t.Errorf("%s passed validation", tc.name)
		}
	}
	var fixture struct {
		InvalidTypedArguments []struct {
			Name  string         `json:"name"`
			Value map[string]any `json:"value"`
		} `json:"invalidTypedArguments"`
	}
	readFixture(t, "message-envelope.json", &fixture)
	for _, tc := range fixture.InvalidTypedArguments {
		envelope := base
		envelope.Args = map[string]any{"value": tc.Value}
		if err := ValidateMessageEnvelope(envelope); err == nil {
			t.Errorf("shared fixture %q passed semantic validation", tc.Name)
		}
		record := map[string]any{
			"schema": MessageSchema, "code": envelope.Code,
			"args": map[string]any{"value": tc.Value},
		}
		if _, err := EnvelopeFromLegacy(record, nil); err == nil {
			t.Errorf("direct reader accepted shared fixture %q", tc.Name)
		}
	}

	envelope := base
	envelope.Rendered = &RenderedMessage{
		Text: "derived", MessageKey: "not a key", Locale: "en-US",
		CatalogHash: strings.Repeat("a", 64), Authoritative: false,
	}
	if err := ValidateMessageEnvelope(envelope); err == nil {
		t.Fatal("malformed rendered provenance passed validation")
	}
}

func TestCanonicalMessageReaderComparesJSONNumberBoundsExactly(t *testing.T) {
	for _, value := range []string{
		"9007199254740991.1",
		"-9007199254740991.1",
		"9.0071992547409911e15",
	} {
		raw := []byte(`{"schema":"yuruna.message/v1","code":"pool.assignment_blocked","args":{"value":` + value + `}}`)
		envelope, err := decodeMessageEnvelope(raw)
		if err != nil {
			t.Fatalf("decode %s: %v", value, err)
		}
		if err := ValidateMessageEnvelope(envelope); err == nil {
			t.Errorf("JSON number just outside the schema bound was accepted: %s", value)
		}
	}

	for _, value := range []string{
		"9007199254740991",
		"-9007199254740991",
		"9007199254740990.999",
		"9.007199254740990999e15",
	} {
		raw := []byte(`{"schema":"yuruna.message/v1","code":"pool.assignment_blocked","args":{"value":` + value + `}}`)
		envelope, err := decodeMessageEnvelope(raw)
		if err != nil {
			t.Fatalf("decode %s: %v", value, err)
		}
		if err := ValidateMessageEnvelope(envelope); err != nil {
			t.Errorf("JSON number within the schema bound was rejected (%s): %v", value, err)
		}
	}

	base := MessageEnvelope{Schema: MessageSchema, Code: "pool.assignment_blocked", Args: map[string]any{}}
	for _, value := range []json.Number{
		"1/2", "0x10", "0b10", "+1", "01", ".5", "1.", "NaN", "1e100000000",
	} {
		envelope := base
		envelope.Args = map[string]any{"value": value}
		if err := ValidateMessageEnvelope(envelope); err == nil {
			t.Errorf("invalid or out-of-bound numeric token was accepted by the direct validator: %q", value)
		}
	}
	for _, value := range []json.Number{"1e-100000000", "0e100000000"} {
		envelope := base
		envelope.Args = map[string]any{"value": value}
		if err := ValidateMessageEnvelope(envelope); err != nil {
			t.Errorf("bounded tiny/zero JSON number was rejected (%q): %v", value, err)
		}
	}
}

func TestMessageDetailIsBoundedRedactedAndCannotChangeIdentity(t *testing.T) {
	secret := "ghp_123456"
	detail, err := ProtectMessageDetail(
		"\x1b[31m Authorization: Bearer "+secret+" token=other password=hunter2 "+strings.Repeat("x", 5000),
		"git.stderr", []string{secret})
	if err != nil {
		t.Fatal(err)
	}
	for _, leaked := range []string{secret, "other", "hunter2", "\x1b"} {
		if strings.Contains(detail.Text, leaked) {
			t.Errorf("detail leaked %q", leaked)
		}
	}
	if len([]rune(detail.Text)) > maxMessageDetailRunes {
		t.Errorf("detail has %d runes, max %d", len([]rune(detail.Text)), maxMessageDetailRunes)
	}
	envelope, err := NewMessageEnvelope("repository.access_denied", nil, &detail)
	if err != nil {
		t.Fatal(err)
	}
	if envelope.Code != "repository.access_denied" {
		t.Errorf("detail changed code to %q", envelope.Code)
	}
}

func TestMessageDetailRedactionAndWireSafetyMatchSharedFixture(t *testing.T) {
	var fixture struct {
		Redaction struct {
			ExplicitSecret     string `json:"explicitSecret"`
			MixedCaseText      string `json:"mixedCaseText"`
			UnsafeDirectDetail []struct {
				Name    string   `json:"name"`
				Text    string   `json:"text"`
				Secrets []string `json:"secrets"`
			} `json:"unsafeDirectDetails"`
		} `json:"redaction"`
	}
	readFixture(t, "message-envelope.json", &fixture)

	detail, err := ProtectMessageDetail(fixture.Redaction.MixedCaseText, "tool.stderr", []string{fixture.Redaction.ExplicitSecret})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(detail.Text, "[REDACTED]") || strings.Contains(strings.ToLower(detail.Text), strings.ToLower(fixture.Redaction.ExplicitSecret)) {
		t.Fatalf("mixed-case explicit secret was not redacted: %q", detail.Text)
	}

	for _, tc := range fixture.Redaction.UnsafeDirectDetail {
		message := map[string]any{
			"schema": MessageSchema, "code": "repository.access_denied", "args": map[string]any{},
			"detail": map[string]any{"text": tc.Text, "source": "tool.stderr"},
		}
		for _, record := range []map[string]any{message, {"message": message}} {
			if _, err := EnvelopeFromLegacy(record, tc.Secrets); err == nil {
				t.Errorf("direct/nested reader accepted unsafe detail %q", tc.Name)
			}
		}
		if len(tc.Secrets) == 0 {
			raw, err := json.Marshal(message)
			if err != nil {
				t.Fatal(err)
			}
			envelope, err := decodeMessageEnvelope(raw)
			if err != nil {
				t.Fatal(err)
			}
			if err := ValidateMessageEnvelope(envelope); err == nil {
				t.Errorf("validator accepted unsafe detail %q", tc.Name)
			}
		}
	}
}

func TestLegacyMessageMigrationCoversEveryNamedProducer(t *testing.T) {
	cases := []struct {
		legacy map[string]any
		code   string
	}{
		{map[string]any{"failureClass": "ssh_timeout", "errorMessage": "timed out"}, "failure.ssh_timeout"},
		{map[string]any{"event": "step_start", "reason": "begin"}, "step.start"},
		{map[string]any{"diagnosticClass": "network_timeout", "errorMessage": "down"}, "diagnostic.network_timeout"},
		{map[string]any{"reason": "old free text"}, "legacy.condition"},
	}
	for _, tc := range cases {
		envelope, err := EnvelopeFromLegacy(tc.legacy, nil)
		if err != nil {
			t.Errorf("%s: %v", tc.code, err)
			continue
		}
		if envelope.Code != tc.code {
			t.Errorf("legacy code = %q, want %q", envelope.Code, tc.code)
		}
	}
}

func TestCompatibilityRecordLetsOldAndNewConsumersCoexist(t *testing.T) {
	detail := &MessageDetail{Text: "timed out", Source: "ssh.stderr"}
	envelope, err := NewMessageEnvelope("failure.ssh_timeout", nil, detail)
	if err != nil {
		t.Fatal(err)
	}
	record, err := MessageCompatibilityRecord(envelope)
	if err != nil {
		t.Fatal(err)
	}
	if record["failureClass"] != "ssh_timeout" || record["errorMessage"] != "timed out" {
		t.Fatalf("old fields missing: %#v", record)
	}
	got, err := EnvelopeFromLegacy(record, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got.Code != envelope.Code {
		t.Errorf("new consumer read %q, want %q", got.Code, envelope.Code)
	}
}

func TestCanonicalMessageReaderRejectsUnknownFields(t *testing.T) {
	cases := []struct {
		name   string
		record map[string]any
	}{
		{
			name: "top level",
			record: map[string]any{
				"schema": MessageSchema, "code": "pool.assignment_blocked",
				"args": map[string]any{}, "unexpected": true,
			},
		},
		{
			name: "detail",
			record: map[string]any{
				"schema": MessageSchema, "code": "pool.assignment_blocked", "args": map[string]any{},
				"detail": map[string]any{"text": "failed", "source": "git.stderr", "unexpected": true},
			},
		},
		{
			name: "rendered",
			record: map[string]any{
				"schema": MessageSchema, "code": "pool.assignment_blocked", "args": map[string]any{},
				"rendered": map[string]any{
					"text": "blocked", "messageKey": "pool.assignment_blocked", "locale": "en-US",
					"catalogHash": strings.Repeat("a", 64), "authoritative": false, "unexpected": true,
				},
			},
		},
		{
			name: "nested canonical envelope",
			record: map[string]any{"message": map[string]any{
				"schema": MessageSchema, "code": "pool.assignment_blocked",
				"args": map[string]any{}, "unexpected": true,
			}},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := EnvelopeFromLegacy(tc.record, nil); err == nil || !strings.Contains(err.Error(), "unknown field") {
				t.Fatalf("unknown %s field was accepted: %v", tc.name, err)
			}
		})
	}
}

func TestMessageMigrationDatesMatchTheSharedFixture(t *testing.T) {
	var fixture struct {
		LegacyReadUntilRelease string   `json:"legacyReadUntilRelease"`
		LegacyReadUntilDate    string   `json:"legacyReadUntilDate"`
		LegacyFields           []string `json:"legacyFields"`
	}
	readFixture(t, "message-envelope.json", &fixture)
	if fixture.LegacyReadUntilRelease != LegacyReadUntilRelease || fixture.LegacyReadUntilDate != LegacyReadUntilDate {
		t.Fatalf("Go window %s/%s, fixture %s/%s", LegacyReadUntilRelease, LegacyReadUntilDate,
			fixture.LegacyReadUntilRelease, fixture.LegacyReadUntilDate)
	}
	want := map[string]bool{"failureClass": true, "reason": true, "errorMessage": true, "event": true, "diagnosticClass": true}
	for _, field := range fixture.LegacyFields {
		delete(want, field)
	}
	if len(want) != 0 {
		t.Errorf("fixture does not date every legacy field: %#v", want)
	}
}
