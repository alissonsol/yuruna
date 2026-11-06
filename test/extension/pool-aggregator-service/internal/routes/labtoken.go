// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4250acb9-11ea-4d49-ae1c-4a127b277574

package routes

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"yuruna.com/test/extension/extension-sdk/controlproof"
	"yuruna.com/test/extension/pool-aggregator-service/internal/feed"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/httpserve"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// The control-proof lifetimes the host verifier holds this proxy to, and the
// audit line builder; these names keep the handlers readable.
const (
	controlProofTTL    = hostpoll.ControlProofTTL
	controlProofMaxTTL = hostpoll.ControlProofMaxTTL
)

var lokiLinePayload = feed.LinePayload

const (
	labTokenLen = 6
	// The dashboard shows the code through a Prometheus scrape (15s) plus a
	// panel refresh (30s), so the displayed value can trail a rotation by
	// ~45s, and the operator still has to read it and type it on the joining
	// host. Verifying against the current code plus its two predecessors keeps
	// a just-read code redeemable for at least one full rotation period,
	// while a leaked code still dies within ~3 rotations.
	LabKeepCodes    = 3
	maxLabTokenBody = 1 << 10 // bytes read from one exchange POST
	// Per-IP failed-exchange throttle. With 36^6 codes valid for <= 3
	// rotations an online guess is already hopeless; the throttle keeps a
	// misconfigured retry loop from spamming the audit trail and turns the
	// brute-force math from infeasible into absurd.
	LabFailLimit  = 10
	LabFailWindow = 10 * time.Minute
	// Cap on distinct throttle keys held in memory, so an anonymous caller
	// spraying addresses cannot grow the map without bound. At the cap,
	// expired entries are pruned and further unknown keys simply go
	// unrecorded -- codes are still verified and refused, so overflow costs
	// throttling for new addresses, never admission.
	MaxLabFailKeys = 4096
	// The exchange seals the shared token under a key derived from the
	// redeemed code, so only a caller holding the code can open it: an
	// enrolling host has no way to authenticate the aggregator's TLS leaf
	// (it is signed by the proxy's own CA, which that host does not trust
	// yet), and the code is the one secret both ends already share. The
	// iteration count is set for a 6-character secret, which is weak enough
	// that a captured envelope must stay expensive to attack offline.
	LabEnvelopeLabel = "yuruna-lab-token|v1"
	LabEnvelopeIters = 600000
)

// MintControlProof mints a control proof bound to audience and valid for ttl from now,
// or "" when no internal authentication key is configured (the host then only accepts
// loopback control). The operator reaches the host through Grafana -> /go/host, so this
// rides the proof to the browser in the redirect fragment; the host revalidates it
// (audience, expiry window, HMAC). The audience is the host id for /go/host and
// "svc-<area>" for /go/stash: the key is pool-wide, and the binding is what keeps a
// proof lifted from one address bar from unlocking every host and service.
func MintControlProof(token, audience string, ttl time.Duration) string {
	return controlproof.MintFor(token, audience, ttl)
}

// VerifyControlProof is the Go twin of Test.ConfigServiceSync\Test-YurunaControlProof:
// it accepts only a proof bound to a target, "<expiry>.<audience>.<base64 HMAC>", minted
// from token and inside now <= expiry <= now+maxTTL (a far-future expiry is refused, so a
// captured token cannot mint an eternal pass). A bound proof must name audience; an empty
// audience, from a service that names none, accepts one bound to any target. The unbound
// form and any malformed, expired or mismatched input are false -- never an error a
// caller could mistake for a verdict.
func VerifyControlProof(token, wire, audience string, now time.Time, maxTTL time.Duration) bool {
	return controlproof.VerifyFor(token, wire, audience, now, maxTTL)
}

// HandleControlProof tells an extension service whether a proof was minted from
// the pool's internal authentication key and is still live, since the service
// holds no key to check it against. Open, because it verifies and never mints:
// it discloses one bit about a string the caller already holds. Answers 503 when
// no key is configured, because "no token" is not "not valid".
// See https://yuruna.link/42c29d04-001c.
func (s *Server) HandleControlProof(w http.ResponseWriter, r *http.Request) {
	if s.authToken == "" {
		localizedHTTPError(w, r, "aggregator.control_proof_verification_disabled_this_aggregator_holds_no_inte", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxLabTokenBody))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var req struct {
		Proof    string `json:"proof"`
		Audience string `json:"audience"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		localizedHTTPError(w, r, "aggregator.malformed_request", http.StatusBadRequest)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if !VerifyControlProof(s.authToken, strings.TrimSpace(req.Proof), strings.TrimSpace(req.Audience), time.Now(), controlProofMaxTTL) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"ok":false}`+"\n")
		return
	}
	_, _ = io.WriteString(w, `{"ok":true}`+"\n")
}

var LabTokenRE = regexp.MustCompile(`^[a-z0-9]{6}$`)

// NewLabCode mints one 6-character lab connection token from a 31-character
// alphabet without i, l, o, 0 and 1, the characters most often misread off a
// dashboard tile. Unbiased: a byte at or above the largest multiple of the
// alphabet length is discarded rather than folded.
// See https://yuruna.link/42c29d04-001d.
func NewLabCode() (string, error) {
	const charset = "abcdefghjkmnpqrstuvwxyz23456789"
	// Largest multiple of len(charset) that fits in a byte; candidates at or
	// above it are discarded rather than folded, so no code is likelier than
	// another.
	limit := byte(256 - (256 % len(charset)))
	out := make([]byte, 0, labTokenLen)
	buf := make([]byte, 1)
	for len(out) < labTokenLen {
		if _, err := rand.Read(buf); err != nil {
			return "", err
		}
		if buf[0] >= limit {
			continue
		}
		out = append(out, charset[buf[0]%byte(len(charset))])
	}
	return string(out), nil
}

// RotateLabToken mints the next lab connection token (retaining LabKeepCodes of
// history for the exchange's grace window) and prunes expired throttle records.
// A crypto/rand failure keeps the previous codes live and logs -- enrollment
// degrades to "retry after the next rotation", never to a predictable code.
func RotateLabToken(st *poolstate.State, now time.Time) {
	code, err := NewLabCode()
	if err != nil {
		log.Print(operatorMessage("aggregator.log_lab_token_rotation_failed_value1_keeping_previous_code_e2670350", map[string]any{"value1": fmt.Sprintf("%v", err)}))
		return
	}
	cut := now.Add(-LabFailWindow)
	st.Do(func(view *poolstate.View) { view.RotateLabCode(code, LabKeepCodes, cut) })
}

// sealLabToken wraps the shared token for one redeemer: AES-256-GCM under a key
// PBKDF2-derived from the redeemed code plus a fresh salt, in the wire shape of
// Protect-ConfigSyncCredential (v/salt/nonce/ciphertext/tag, all base64), which
// Test.ConfigServiceSync\Unprotect-LabTokenEnvelope opens. The seal authenticates
// the answer: only a party that knows the displayed code can produce a payload
// the enrolling host accepts.
// See https://yuruna.link/42c29d04-001d.
func sealLabToken(code, token string) (map[string]string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	key, err := pbkdf2.Key(sha256.New, code, salt, LabEnvelopeIters, 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	// Seal appends the tag to the ciphertext; split it out so the envelope
	// carries the same named fields the PowerShell side already speaks.
	sealed := gcm.Seal(nil, nonce, []byte(token), []byte(LabEnvelopeLabel))
	cut := len(sealed) - gcm.Overhead()
	return map[string]string{
		"salt":       base64.StdEncoding.EncodeToString(salt),
		"nonce":      base64.StdEncoding.EncodeToString(nonce),
		"ciphertext": base64.StdEncoding.EncodeToString(sealed[:cut]),
		"tag":        base64.StdEncoding.EncodeToString(sealed[cut:]),
	}, nil
}

// HandleLabToken (POST /api/v1/lab-token) exchanges the 6-character code the
// dashboard displays for the internal authentication key, for
// test/lab/Set-LabToken.ps1. Open, because the code is the credential: it is
// checked in constant time against the retained codes, throttled per address
// and audited with the caller's address, and the answer is sealed under the
// code. Answers 503 when rotation is off or no key is configured, like /ingest.
// See https://yuruna.link/42c29d04-001d.
func (s *Server) HandleLabToken(w http.ResponseWriter, r *http.Request) {
	if s.labRotate <= 0 || s.authToken == "" {
		localizedHTTPError(w, r, "aggregator.lab_token_exchange_disabled", http.StatusServiceUnavailable)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	srcIP := httpserve.SourceIP(r)
	if srcIP == "" {
		localizedHTTPError(w, r, "aggregator.no_source_address", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxLabTokenBody))
	if err != nil {
		localizedHTTPError(w, r, "aggregator.payload_too_large_or_unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	var req struct {
		LabToken string `json:"labToken"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		localizedHTTPError(w, r, "aggregator.malformed_request", http.StatusBadRequest)
		return
	}
	code := strings.ToLower(strings.TrimSpace(req.LabToken))
	if !LabTokenRE.MatchString(code) {
		localizedHTTPError(w, r, "aggregator.labtoken_must_be_6_lowercase_letters_digits", http.StatusBadRequest)
		return
	}
	now := time.Now().UTC()
	cut := now.Add(-LabFailWindow)
	// Throttle by the /64 for IPv6: a single delegated prefix hands one
	// attacker more addresses than the map could ever hold, so per-address
	// buckets there would throttle nothing while growing without bound.
	throttleKey := LabThrottleKey(srcIP)
	poolLabel := s.pool
	token := s.authToken
	var attempt poolstate.LabAttempt
	s.st.Do(func(view *poolstate.View) {
		attempt = view.RedeemLabCode(throttleKey, code, now, cut, LabFailLimit, MaxLabFailKeys)
	})
	recent, throttled, match, outcome := attempt.Recent, attempt.Throttled, attempt.Matched, attempt.Outcome
	// audit is false for a repeat throttled attempt: once an address is
	// locked out, auditing every retry would let an anonymous caller amplify
	// one request into one log line and one Loki write apiece. The crossing
	// into throttled IS recorded, so the operator still sees the burst.
	audit := !throttled
	// Audit after the unlock (a slow Loki must not stall the handler);
	// refusals are audited too -- a burst of them is the operator's signal
	// that someone is poking the enrollment surface. The code itself is
	// never logged: a refused one is a guess worth nothing, and an accepted
	// one would put a live credential in the log.
	if audit {
		auditOutcome := outcome
		if !match && recent+1 == LabFailLimit {
			auditOutcome = "refused (now throttled)"
		}
		log.Print(operatorMessage("aggregator.log_lab_token_exchange_value1_from_value2_3d2e9e4a", map[string]any{"value1": fmt.Sprintf("%s", auditOutcome), "value2": fmt.Sprintf("%s", srcIP)}))
		line, _ := json.Marshal(map[string]string{"sourceIp": srcIP, "outcome": auditOutcome})
		_ = s.Queue(s.httpClient, s.lokiURL, lokiLinePayload(map[string]string{"pool": poolLabel, "src": "lab-token"}, line, now), "lab-token exchange push")
	}
	switch {
	case throttled:
		w.Header().Set("Retry-After", strconv.Itoa(int(LabFailWindow/time.Second)))
		localizedHTTPError(w, r, "aggregator.too_many_failed_attempts_retry_later", http.StatusTooManyRequests)
	case !match:
		localizedHTTPError(w, r, "aggregator.unknown_or_expired_lab_token", http.StatusForbidden)
	default:
		envelope, err := sealLabToken(code, token)
		if err != nil {
			log.Print(operatorMessage("aggregator.log_lab_token_exchange_sealing_failed_value1_8aceabc2", map[string]any{"value1": fmt.Sprintf("%v", err)}))
			localizedHTTPError(w, r, "aggregator.failed_to_seal_the_token", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		resp, _ := json.Marshal(struct {
			Ok bool `json:"ok"`
			V  int  `json:"v"`
			// Inline so the envelope fields sit at the top level, matching
			// the config-sync credential envelope the client already parses.
			Salt       string `json:"salt"`
			Nonce      string `json:"nonce"`
			Ciphertext string `json:"ciphertext"`
			Tag        string `json:"tag"`
		}{Ok: true, V: 1, Salt: envelope["salt"], Nonce: envelope["nonce"],
			Ciphertext: envelope["ciphertext"], Tag: envelope["tag"]})
		_, _ = w.Write(resp)
	}
}

// LabThrottleKey collapses an address to its throttle bucket: the /64 for IPv6
// (the smallest routinely-delegated prefix), the address itself for IPv4 and
// for anything unparseable.
func LabThrottleKey(ip string) string {
	addr := net.ParseIP(ip)
	if addr == nil || addr.To4() != nil {
		return ip
	}
	return addr.Mask(net.CIDRMask(64, 128)).String() + "/64"
}
