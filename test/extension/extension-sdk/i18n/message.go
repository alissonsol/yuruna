// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package i18n

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	MessageSchema          = "yuruna.message/v1"
	LegacyReadUntilRelease = "2027.02"
	LegacyReadUntilDate    = "2027-02-28"
	maxMessageArguments    = 32
	maxMessageDetailRunes  = 4096
)

var (
	messageCodeRE       = regexp.MustCompile("^[a-z][a-z0-9_]*(?:\\.[a-z][a-z0-9_]*)+$")
	argumentNameRE      = regexp.MustCompile("^[a-z][A-Za-z0-9]{0,63}$")
	sensitiveArgumentRE = regexp.MustCompile("(?i)(password|passwd|secret|token|api[_-]?key|apikey|credential)")
	detailSourceRE      = regexp.MustCompile("^[a-z][a-z0-9_.-]{0,127}$")
	messageKeyRE        = regexp.MustCompile("^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*)+$")
	localeTagRE         = regexp.MustCompile("^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
	catalogHashRE       = regexp.MustCompile("^[0-9a-f]{64}$")
	decimalRE           = regexp.MustCompile("^-?[0-9]+(?:\\.[0-9]+)?$")
	jsonNumberRE        = regexp.MustCompile("^-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$")
	integerRE           = regexp.MustCompile("^(?:0|[1-9][0-9]*|-[1-9][0-9]*)$")
	unsignedRE          = regexp.MustCompile("^(?:0|[1-9][0-9]*)$")
	bearerRE            = regexp.MustCompile("(?i)(authorization\\s*:\\s*bearer\\s+)[^\\s,;]+")
	secretAssignmentRE  = regexp.MustCompile("(?i)\\b(password|passwd|secret|token|credential|api[_-]?key)\\s*[:=]\\s*[^\\s,;]+")
	jsSafeInteger       = mustBigInt("9007199254740991")
)

// MessageDetail is external prose. Source says which boundary produced it;
// neither field can select the code or a catalog key.
type MessageDetail struct {
	Text   string `json:"text"`
	Source string `json:"source"`
}

// RenderedMessage is a compatibility convenience, never identity. The exact
// catalog set is retained so a report can be reproduced after wording moves.
type RenderedMessage struct {
	Text          string `json:"text"`
	MessageKey    string `json:"messageKey"`
	Locale        string `json:"locale"`
	CatalogHash   string `json:"catalogHash"`
	Authoritative bool   `json:"authoritative"`
}

// MessageEnvelope is the only new message identity written across a process,
// persistence or network boundary.
type MessageEnvelope struct {
	Schema   string           `json:"schema"`
	Code     string           `json:"code"`
	Args     map[string]any   `json:"args"`
	Detail   *MessageDetail   `json:"detail,omitempty"`
	Rendered *RenderedMessage `json:"rendered,omitempty"`
}

// Argument gives CanonicalArgument the source catalog type explicitly. A
// string is never guessed to be an integer, decimal or timestamp.
type Argument struct {
	Type  string
	Value any
}

func mustBigInt(value string) *big.Int {
	n, ok := new(big.Int).SetString(value, 10)
	if !ok {
		panic("invalid integer constant")
	}
	return n
}

func integerText(value any) (string, error) {
	switch v := value.(type) {
	case json.Number:
		return v.String(), nil
	case string:
		return v, nil
	case int:
		return strconv.FormatInt(int64(v), 10), nil
	case int8:
		return strconv.FormatInt(int64(v), 10), nil
	case int16:
		return strconv.FormatInt(int64(v), 10), nil
	case int32:
		return strconv.FormatInt(int64(v), 10), nil
	case int64:
		return strconv.FormatInt(v, 10), nil
	case uint:
		return strconv.FormatUint(uint64(v), 10), nil
	case uint8:
		return strconv.FormatUint(uint64(v), 10), nil
	case uint16:
		return strconv.FormatUint(uint64(v), 10), nil
	case uint32:
		return strconv.FormatUint(uint64(v), 10), nil
	case uint64:
		return strconv.FormatUint(v, 10), nil
	default:
		return "", fmt.Errorf("%T is not an integer value", value)
	}
}

func canonicalDecimal(value any) (string, error) {
	text := fmt.Sprint(value)
	if !decimalRE.MatchString(text) {
		return "", fmt.Errorf("%q is not an invariant decimal", text)
	}
	negative := strings.HasPrefix(text, "-")
	text = strings.TrimPrefix(text, "-")
	parts := strings.SplitN(text, ".", 2)
	whole := strings.TrimLeft(parts[0], "0")
	if whole == "" {
		whole = "0"
	}
	fraction := ""
	if len(parts) == 2 {
		fraction = strings.TrimRight(parts[1], "0")
	}
	result := whole
	if fraction != "" {
		result += "." + fraction
	}
	if negative && result != "0" {
		result = "-" + result
	}
	return result, nil
}

// CanonicalArgument converts a catalog-declared type to the encoding shared
// with PowerShell and JavaScript. It introduces no locale/CLDR dependency.
func CanonicalArgument(arg Argument) (any, error) {
	if arg.Value == nil {
		return nil, nil
	}
	switch arg.Type {
	case "text", "identifier", "detail", "token":
		value, ok := arg.Value.(string)
		if !ok {
			return nil, fmt.Errorf("%s argument is %T, not string", arg.Type, arg.Value)
		}
		if utf8.RuneCountInString(value) > 4096 {
			return nil, fmt.Errorf("%s argument exceeds 4096 characters", arg.Type)
		}
		return value, nil
	case "integer":
		text, err := integerText(arg.Value)
		if err != nil || !integerRE.MatchString(text) {
			return nil, fmt.Errorf("invalid integer argument %q", text)
		}
		n, _ := new(big.Int).SetString(text, 10)
		if new(big.Int).Abs(new(big.Int).Set(n)).Cmp(jsSafeInteger) <= 0 {
			return n.Int64(), nil
		}
		return map[string]string{"$type": "integer", "value": n.String()}, nil
	case "decimal":
		text, err := canonicalDecimal(arg.Value)
		if err != nil {
			return nil, err
		}
		return map[string]string{"$type": "decimal", "value": text}, nil
	case "bytes":
		text, err := integerText(arg.Value)
		if err != nil || !unsignedRE.MatchString(text) {
			return nil, fmt.Errorf("invalid byte count %q", text)
		}
		return map[string]string{"$type": "bytes", "value": text}, nil
	case "duration":
		var text string
		if duration, ok := arg.Value.(time.Duration); ok {
			if duration < 0 {
				return nil, errors.New("duration cannot be negative")
			}
			text = strconv.FormatInt(duration.Milliseconds(), 10)
		} else {
			var err error
			text, err = integerText(arg.Value)
			if err != nil || !unsignedRE.MatchString(text) {
				return nil, fmt.Errorf("invalid duration %q", text)
			}
		}
		return map[string]string{"$type": "duration", "milliseconds": text}, nil
	case "datetime":
		var when time.Time
		switch value := arg.Value.(type) {
		case time.Time:
			when = value
		case string:
			parsed, err := time.Parse(time.RFC3339Nano, value)
			if err != nil {
				return nil, fmt.Errorf("invalid datetime %q: %w", value, err)
			}
			when = parsed
		default:
			return nil, fmt.Errorf("datetime argument is %T", arg.Value)
		}
		return map[string]string{"$type": "datetime", "value": when.UTC().Format("2006-01-02T15:04:05.0000000Z")}, nil
	default:
		return nil, fmt.Errorf("unknown message argument type %q", arg.Type)
	}
}

func truncateRunes(value string, limit int) string {
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return string(runes[:limit])
}

// ProtectMessageDetail strips terminal controls, redacts known credential
// shapes and bounds untrusted prose before it is persisted.
func ProtectMessageDetail(text, source string, secrets []string) (MessageDetail, error) {
	source = strings.ToLower(strings.TrimSpace(source))
	if !detailSourceRE.MatchString(source) {
		return MessageDetail{}, fmt.Errorf("detail source %q is not a stable source token", source)
	}
	var b strings.Builder
	for _, r := range text {
		if (r < 0x20 && r != '\n' && r != '\r' && r != '\t') || r == 0x7f {
			continue
		}
		b.WriteRune(r)
	}
	safe := b.String()
	for _, secret := range secrets {
		if secret != "" {
			// Secrets are token-like material and their case is not a safe
			// distinction. Match PowerShell's documented case-insensitive
			// redaction so one runtime cannot leak a differently cased copy.
			secretRE := regexp.MustCompile("(?i:" + regexp.QuoteMeta(secret) + ")")
			safe = secretRE.ReplaceAllString(safe, "[REDACTED]")
		}
	}
	safe = bearerRE.ReplaceAllString(safe, "$1[REDACTED]")
	safe = secretAssignmentRE.ReplaceAllString(safe, "$1=[REDACTED]")
	return MessageDetail{Text: truncateRunes(safe, maxMessageDetailRunes), Source: source}, nil
}

// NewMessageEnvelope validates and canonicalizes a new producer's record.
func NewMessageEnvelope(code string, arguments map[string]Argument, detail *MessageDetail) (MessageEnvelope, error) {
	if len(code) > 128 || !messageCodeRE.MatchString(code) {
		return MessageEnvelope{}, fmt.Errorf("message code %q is not a bounded namespaced code", code)
	}
	if len(arguments) > maxMessageArguments {
		return MessageEnvelope{}, fmt.Errorf("message envelope has %d arguments, maximum is %d", len(arguments), maxMessageArguments)
	}
	names := make([]string, 0, len(arguments))
	for name := range arguments {
		names = append(names, name)
	}
	sort.Strings(names)
	args := make(map[string]any, len(arguments))
	for _, name := range names {
		if !argumentNameRE.MatchString(name) {
			return MessageEnvelope{}, fmt.Errorf("message argument name %q is invalid", name)
		}
		if sensitiveArgumentRE.MatchString(name) {
			return MessageEnvelope{}, fmt.Errorf("message argument %q looks credential-bearing", name)
		}
		value, err := CanonicalArgument(arguments[name])
		if err != nil {
			return MessageEnvelope{}, fmt.Errorf("%s: %w", name, err)
		}
		args[name] = value
	}
	envelope := MessageEnvelope{Schema: MessageSchema, Code: code, Args: args}
	if detail != nil {
		protected, err := ProtectMessageDetail(detail.Text, detail.Source, nil)
		if err != nil {
			return MessageEnvelope{}, err
		}
		envelope.Detail = &protected
	}
	return envelope, ValidateMessageEnvelope(envelope)
}

func validTypedArgument(value map[string]any) bool {
	kind, ok := value["$type"].(string)
	if !ok {
		return false
	}
	switch kind {
	case "integer":
		text, ok := value["value"].(string)
		return ok && len(value) == 2 && len(text) <= 80 && integerRE.MatchString(text)
	case "decimal":
		text, ok := value["value"].(string)
		if !ok || len(value) != 2 || len(text) > 128 {
			return false
		}
		canonical, err := canonicalDecimal(text)
		return err == nil && canonical == text
	case "bytes":
		text, ok := value["value"].(string)
		return ok && len(value) == 2 && len(text) <= 80 && unsignedRE.MatchString(text)
	case "duration":
		text, ok := value["milliseconds"].(string)
		return ok && len(value) == 2 && len(text) <= 80 && unsignedRE.MatchString(text)
	case "datetime":
		text, ok := value["value"].(string)
		if !ok || len(value) != 2 {
			return false
		}
		_, err := time.Parse("2006-01-02T15:04:05.0000000Z", text)
		return err == nil
	}
	return false
}

func validJSONNumber(value any) bool {
	switch number := value.(type) {
	case float32:
		parsed := float64(number)
		return !math.IsNaN(parsed) && !math.IsInf(parsed, 0) && math.Abs(parsed) <= 9007199254740991
	case float64:
		return !math.IsNaN(number) && !math.IsInf(number, 0) && math.Abs(number) <= 9007199254740991
	case int:
		return int64(number) >= -9007199254740991 && int64(number) <= 9007199254740991
	case int8, int16, int32:
		return true
	case int64:
		return number >= -9007199254740991 && number <= 9007199254740991
	case uint:
		return uint64(number) <= 9007199254740991
	case uint8, uint16, uint32:
		return true
	case uint64:
		return number <= 9007199254740991
	case json.Number:
		return jsonNumberWithinSafeRange(number.String())
	default:
		return false
	}
}

// jsonNumberWithinSafeRange compares the original JSON token without first
// rounding it to float64 and without expanding a hostile exponent into a big
// integer. The only boundary is an integer, so decimal-point position and a
// bounded lexical comparison are sufficient regardless of exponent size.
func jsonNumberWithinSafeRange(text string) bool {
	if !jsonNumberRE.MatchString(text) {
		return false
	}
	unsigned := strings.TrimPrefix(text, "-")
	mantissa := unsigned
	exponentText := ""
	if index := strings.IndexAny(unsigned, "eE"); index >= 0 {
		mantissa = unsigned[:index]
		exponentText = unsigned[index+1:]
	}

	decimal := strings.IndexByte(mantissa, '.')
	fractionDigits := 0
	if decimal >= 0 {
		fractionDigits = len(mantissa) - decimal - 1
		mantissa = mantissa[:decimal] + mantissa[decimal+1:]
	}
	digits := strings.TrimLeft(mantissa, "0")
	if digits == "" {
		return true
	}

	exponent := 0
	if exponentText != "" {
		negative := strings.HasPrefix(exponentText, "-")
		exponentDigits := strings.TrimLeft(exponentText, "+-")
		// More magnitude than the token length plus this boundary needs can
		// only put a nonzero value far above the limit or far below one. Stop
		// accumulating there so exponent work and memory stay linear in input.
		bound := len(text) + len("9007199254740991") + 1
		for i := 0; i < len(exponentDigits); i++ {
			digit := int(exponentDigits[i] - '0')
			if exponent > (bound-digit)/10 {
				exponent = bound + 1
				break
			}
			exponent = exponent*10 + digit
		}
		if negative {
			exponent = -exponent
		}
	}

	integerDigits := len(digits) + exponent - fractionDigits
	const limit = "9007199254740991"
	if integerDigits < len(limit) {
		return true
	}
	if integerDigits > len(limit) {
		return false
	}

	prefix := digits
	if len(prefix) > len(limit) {
		prefix = prefix[:len(limit)]
	} else if len(prefix) < len(limit) {
		prefix += strings.Repeat("0", len(limit)-len(prefix))
	}
	if prefix < limit {
		return true
	}
	if prefix > limit {
		return false
	}
	// The integer prefix is exactly the maximum. Any nonzero fractional
	// significant digit would put the mathematical value over it.
	if len(digits) > len(limit) {
		return strings.Trim(digits[len(limit):], "0") == ""
	}
	return true
}

// ValidateMessageEnvelope is the dependency-free runtime side of the checked
// JSON Schema. Build/test validates the schema file itself; a hot request does
// not load or interpret JSON Schema.
func validateMessageEnvelope(envelope MessageEnvelope, secrets []string) error {
	if envelope.Schema != MessageSchema {
		return fmt.Errorf("message schema %q is unsupported", envelope.Schema)
	}
	if len(envelope.Code) > 128 || !messageCodeRE.MatchString(envelope.Code) {
		return fmt.Errorf("message code %q is invalid", envelope.Code)
	}
	if envelope.Args == nil || len(envelope.Args) > maxMessageArguments {
		return errors.New("message args are absent or over the bound")
	}
	for name, value := range envelope.Args {
		if !argumentNameRE.MatchString(name) || sensitiveArgumentRE.MatchString(name) {
			return fmt.Errorf("message argument %q is not allowed", name)
		}
		switch typed := value.(type) {
		case nil, bool:
			// JSON-safe primitives. The catalog owns their semantic type.
		case string:
			if utf8.RuneCountInString(typed) > 4096 {
				return fmt.Errorf("message argument %q exceeds the string bound", name)
			}
		case map[string]any:
			if !validTypedArgument(typed) {
				return fmt.Errorf("message argument %q has a noncanonical typed value", name)
			}
		case map[string]string:
			converted := make(map[string]any, len(typed))
			for k, v := range typed {
				converted[k] = v
			}
			if !validTypedArgument(converted) {
				return fmt.Errorf("message argument %q has a noncanonical typed value", name)
			}
		default:
			if !validJSONNumber(typed) {
				return fmt.Errorf("message argument %q is not a bounded JSON-safe number", name)
			}
		}
	}
	if envelope.Detail != nil {
		if !detailSourceRE.MatchString(envelope.Detail.Source) || utf8.RuneCountInString(envelope.Detail.Text) > maxMessageDetailRunes {
			return errors.New("message detail is not bounded or sourced")
		}
		protected, err := ProtectMessageDetail(envelope.Detail.Text, envelope.Detail.Source, secrets)
		if err != nil || protected != *envelope.Detail {
			return errors.New("message detail is not canonical redacted text")
		}
	}
	if envelope.Rendered != nil {
		if envelope.Rendered.Authoritative || utf8.RuneCountInString(envelope.Rendered.Text) < 1 ||
			utf8.RuneCountInString(envelope.Rendered.Text) > 16384 || len(envelope.Rendered.MessageKey) > 128 ||
			!messageKeyRE.MatchString(envelope.Rendered.MessageKey) || len(envelope.Rendered.Locale) > 35 ||
			!localeTagRE.MatchString(envelope.Rendered.Locale) || !catalogHashRE.MatchString(envelope.Rendered.CatalogHash) {
			return errors.New("rendered message does not carry derived provenance")
		}
	}
	return nil
}

// ValidateMessageEnvelope checks a canonical wire envelope. Explicit secrets
// are supplied by EnvelopeFromLegacy at its untrusted read boundary; the
// public shape still rejects terminal controls and recognizable credentials.
func ValidateMessageEnvelope(envelope MessageEnvelope) error {
	return validateMessageEnvelope(envelope, nil)
}

func decodeMessageEnvelope(raw []byte) (MessageEnvelope, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	decoder.DisallowUnknownFields()
	var envelope MessageEnvelope
	if err := decoder.Decode(&envelope); err != nil {
		return MessageEnvelope{}, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return MessageEnvelope{}, errors.New("message envelope contains more than one JSON value")
		}
		return MessageEnvelope{}, err
	}
	return envelope, nil
}

// EnvelopeFromLegacy is the one N/N-1 dual-read boundary.
func EnvelopeFromLegacy(record map[string]any, secrets []string) (MessageEnvelope, error) {
	if nested, ok := record["message"]; ok {
		raw, err := json.Marshal(nested)
		if err == nil {
			var marker struct {
				Schema string `json:"schema"`
			}
			if json.Unmarshal(raw, &marker) == nil && marker.Schema == MessageSchema {
				envelope, decodeErr := decodeMessageEnvelope(raw)
				if decodeErr != nil {
					return MessageEnvelope{}, decodeErr
				}
				return envelope, validateMessageEnvelope(envelope, secrets)
			}
		}
	}
	if schema, _ := record["schema"].(string); schema == MessageSchema {
		raw, _ := json.Marshal(record)
		envelope, err := decodeMessageEnvelope(raw)
		if err != nil {
			return MessageEnvelope{}, err
		}
		return envelope, validateMessageEnvelope(envelope, secrets)
	}

	code := "legacy.condition"
	source := "legacy.record"
	if value := fmt.Sprint(record["failureClass"]); value != "" && value != "<nil>" {
		code, source = "failure."+strings.ToLower(value), "legacy.failure"
	} else if value := fmt.Sprint(record["event"]); value != "" && value != "<nil>" {
		value = strings.ReplaceAll(strings.ToLower(value), "_", ".")
		if strings.Contains(value, ".") {
			code = value
		} else {
			code = "event." + value
		}
		source = "legacy.event"
	} else if value := fmt.Sprint(record["diagnosticClass"]); value != "" && value != "<nil>" {
		code, source = "diagnostic."+strings.ToLower(value), "legacy.diagnostic"
	}
	invalidCode := regexp.MustCompile("[^a-z0-9_.]")
	code = invalidCode.ReplaceAllString(code, "_")

	detailText := ""
	if value := fmt.Sprint(record["errorMessage"]); value != "" && value != "<nil>" {
		detailText = value
	} else if value := fmt.Sprint(record["reason"]); value != "" && value != "<nil>" {
		detailText = value
	}
	var detail *MessageDetail
	if detailText != "" {
		protected, err := ProtectMessageDetail(detailText, source, secrets)
		if err != nil {
			return MessageEnvelope{}, err
		}
		detail = &protected
	}
	return NewMessageEnvelope(code, nil, detail)
}

// MessageCompatibilityRecord is the N/N-1 dual-write wrapper. New consumers
// read Message; old consumers retain their named field until the dated window
// closes.
func MessageCompatibilityRecord(envelope MessageEnvelope) (map[string]any, error) {
	if err := ValidateMessageEnvelope(envelope); err != nil {
		return nil, err
	}
	record := map[string]any{"message": envelope}
	parts := strings.SplitN(envelope.Code, ".", 2)
	if len(parts) == 2 {
		switch parts[0] {
		case "failure":
			record["failureClass"] = parts[1]
		case "diagnostic":
			record["diagnosticClass"] = parts[1]
		case "event":
			record["event"] = parts[1]
		case "step":
			record["event"] = envelope.Code
		}
	}
	if envelope.Detail != nil {
		record["reason"] = envelope.Detail.Text
		record["errorMessage"] = envelope.Detail.Text
	}
	return record, nil
}
