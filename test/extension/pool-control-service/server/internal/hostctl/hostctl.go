// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package hostctl drives another host's operator-control routes: the two pause
// switches behind the status page's "Pause after cycle" and "Pause after step"
// buttons. See
// ../../../../../../docs/pool-admin.md#pool-status--pausing-and-continuing-every-member-at-once
// for the three-state model and the control-proof HMAC it shares with the
// other two implementations. -- hostctl.go
package hostctl

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"yuruna.com/test/extension/extension-sdk/controlproof"
	"yuruna.com/test/extension/extension-sdk/hostrefresh"
)

// The states an operator picks between. They double as the per-host states a
// read reports, so the selector can show what it would set.
const (
	ActionContinue        = "continue"
	ActionPauseAfterCycle = "pause-after-cycle"
	ActionPauseAfterStep  = "pause-after-step"
)

// States that are observed but never commanded.
const (
	// StateBoth is a host with BOTH switches armed. Nothing here produces it;
	// an operator at the host's own status page, which has one button per
	// switch, can.
	StateBoth = "both"

	// StateUnknown is a host that did not answer.
	StateUnknown = "unknown"

	// StateMixed is never one host's state: it is what a POOL reports when its
	// members disagree. It lives here so every layer reads one vocabulary.
	StateMixed = "mixed"
)

const (
	// ProofTTL matches what the aggregator mints for a browser. The expiry is
	// judged by the HOST's clock, not ours, and a host accepts one no more than
	// 20 minutes out -- so the window is held well above the instant this proof
	// is actually used, and ordinary clock drift between two lab machines does
	// not turn into a refused control call.
	ProofTTL = 15 * time.Minute

	// DefaultTimeout bounds one call to one host. An operator is waiting on a
	// fan-out over every member, so a host that accepts a connection and then
	// says nothing must not be able to hold up the hosts that would answer.
	DefaultTimeout = 10 * time.Second

	// maxBodyBytes caps a response read. Both bodies are a short JSON document.
	maxBodyBytes = 1 << 20

	// proofFragment is how the aggregator's /go/host redirect carries a proof.
	proofFragment = "#yctl="
)

// ErrNoProof means no control proof was supplied, so nothing was sent: a host
// would refuse the call, and sending it anyway would spend a round trip to be
// told so.
var ErrNoProof = errors.New("no control proof")

// Proof is the deterministic core of the control proof: the exact wire string
// "<expiry>.<base64 HMAC>" a host accepts on its mutating /control/* routes,
// where HMAC = HMAC-SHA256(internal authentication key, "yuruna-control|proof|<expiry>").
func Proof(token string, expiry int64) string {
	return controlproof.Proof(token, expiry)
}

// Mint returns a proof valid for ttl from now, or "" when no token is held --
// the caller then has no local way to prove control and must obtain one from
// the aggregator.
func Mint(token string, ttl time.Duration) string {
	return controlproof.Mint(token, ttl)
}

// KnownAction reports whether action is one this package can apply.
func KnownAction(action string) bool {
	_, ok := routesFor(action)
	return ok
}

// routesFor returns the control routes that put a host in the requested state,
// in the order they must be called: the switch being ARMED goes first, so a
// call that fails between the two leaves the host more paused than asked for,
// never less.
func routesFor(action string) ([]string, bool) {
	switch action {
	case ActionContinue:
		return []string{"cycle-resume", "step-resume"}, true
	case ActionPauseAfterCycle:
		return []string{"cycle-pause", "step-resume"}, true
	case ActionPauseAfterStep:
		return []string{"step-pause", "cycle-resume"}, true
	}
	return nil, false
}

// Options configures a Client.
type Options struct {
	// Timeout bounds one call to one host; 0 selects DefaultTimeout.
	Timeout time.Duration

	// HTTPClient replaces the built-in client wholesale (tests inject one).
	HTTPClient *http.Client
}

// Client talks to host status services.
type Client struct{ http *http.Client }

// New builds a Client.
func New(opts Options) *Client {
	if opts.HTTPClient != nil {
		return &Client{http: opts.HTTPClient}
	}
	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	return &Client{http: &http.Client{
		Timeout: timeout,
		// The aggregator's /go/host answer IS the redirect, so following it
		// would discard the proof and fetch a host's home page instead. A
		// control POST has no redirect to follow either.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		// The same trusted-LAN posture the pool read and the beacon take: a
		// host status service answers plain http, and the aggregator's TLS leaf
		// is signed by the pool CA that no service VM has a trust-store entry
		// for, so demanding a verifiable certificate would disable this
		// outright.
		Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}}, //nolint:gosec // trusted-LAN; the proof authenticates the CALLER, not the host
	}}
}

// Error is a host's own refusal, kept structured because the fix differs per
// reason: an unenrolled host, a host holding a different lab token and a host
// with a skewed clock all answer 403.
type Error struct {
	Status int
	Reason string
	Detail string
}

func (e *Error) Error() string {
	if text := reasonText[e.Reason]; text != "" {
		return text
	}
	if e.Detail != "" {
		return fmt.Sprintf("HTTP %d: %s", e.Status, e.Detail)
	}
	return fmt.Sprintf("HTTP %d", e.Status)
}

// reasonText turns a host's machine-readable refusal into the fix for it, so a
// pool operator reading a list of failed members is not left holding a bare
// 403 per host.
var reasonText = map[string]string{
	"host-token-missing":   "the host holds no lab token (enroll it: pwsh test/lab/Set-LabToken.ps1)",
	"proof-invalid":        "the host holds a different lab token (re-enroll it against this lab)",
	"proof-expired":        "the host's clock is behind this service's (fix time sync on the host)",
	"proof-missing":        "the host received no control proof",
	"verifier-unavailable": "the host's status service could not load its proof verifier",
}

// Apply puts one host into the requested state, presenting proof on each call.
func (c *Client) Apply(ctx context.Context, baseURL, action, proof string) error {
	routes, ok := routesFor(action)
	if !ok {
		return fmt.Errorf("unknown action %q", action)
	}
	if strings.TrimSpace(proof) == "" {
		return ErrNoProof
	}
	base, err := hostBase(baseURL)
	if err != nil {
		return err
	}
	for _, route := range routes {
		if err := c.post(ctx, base+"/control/"+route, proof); err != nil {
			return err
		}
	}
	return nil
}

// State reports which of the three states a host is in, from the same
// status.json its own page renders. Reads are open on a host, so this needs no
// proof -- and a host that refuses control still reports where it stands.
func (c *Client) State(ctx context.Context, baseURL string) (string, error) {
	base, err := hostBase(baseURL)
	if err != nil {
		return StateUnknown, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/runtime/status.json", nil)
	if err != nil {
		return StateUnknown, err
	}
	req.Header.Set("Cache-Control", "no-store")
	resp, err := c.http.Do(req)
	if err != nil {
		return StateUnknown, fmt.Errorf("the host did not answer: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if resp.StatusCode/100 != 2 {
		return StateUnknown, &Error{Status: resp.StatusCode, Detail: firstLine(body)}
	}
	if err != nil {
		return StateUnknown, err
	}
	var doc struct {
		StepPaused  bool `json:"stepPaused"`
		CyclePaused bool `json:"cyclePaused"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return StateUnknown, fmt.Errorf("the host's status document did not parse: %w", err)
	}
	switch {
	case doc.StepPaused && doc.CyclePaused:
		return StateBoth, nil
	case doc.StepPaused:
		return ActionPauseAfterStep, nil
	case doc.CyclePaused:
		return ActionPauseAfterCycle, nil
	}
	return ActionContinue, nil
}

// ProofFromAggregator asks the pool aggregator for a control proof through
// /go/host -- the identical proof a browser receives when an operator follows a
// dashboard host link, carried in the redirect's URL fragment.
//
// This is the fallback for a service that holds no internal authentication key of its own:
// nothing bakes that file into a service VM's seed, so requiring it would leave
// the pool-wide control unusable on a lab that never placed one by hand. The
// fragment never reaches a server or an access log -- here it never leaves this
// process either, because the redirect is read rather than followed.
func (c *Client) ProofFromAggregator(ctx context.Context, aggregatorBase, hostID string) (string, error) {
	base := strings.TrimRight(strings.TrimSpace(aggregatorBase), "/")
	if base == "" || strings.TrimSpace(hostID) == "" {
		return "", ErrNoProof
	}
	resp, err := c.getFirstAnswer(ctx, base+"/go/host?host="+url.QueryEscape(hostID))
	if err != nil {
		return "", fmt.Errorf("the pool aggregator did not answer: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxBodyBytes))
	if resp.StatusCode/100 != 3 {
		return "", fmt.Errorf("the pool aggregator answered HTTP %d for the host lookup", resp.StatusCode)
	}
	// No fragment means the aggregator holds no internal authentication key of its own, so
	// the whole lab is loopback-only control. Say that, rather than sending a
	// proofless call to every member to collect identical 403s.
	_, proof, found := strings.Cut(resp.Header.Get("Location"), proofFragment)
	if !found || proof == "" {
		return "", errors.New("the pool aggregator minted no control proof (it holds no internal authentication key)")
	}
	return proof, nil
}

// getFirstAnswer performs a GET, falling back from https to plain http on a
// TRANSPORT failure only. The aggregator serves TLS only once its proxy-CA leaf
// is minted, so an older proxy answers :9400 in the clear; a protocol answer of
// any status is authoritative and is never retried against the other scheme.
// The same order the pool read takes, for the same reason.
func (c *Client) getFirstAnswer(ctx context.Context, rawURL string) (*http.Response, error) {
	candidates := []string{rawURL}
	if rest, ok := strings.CutPrefix(rawURL, "https://"); ok {
		candidates = append(candidates, "http://"+rest)
	}
	var lastErr error
	for _, candidate := range candidates {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, candidate, nil)
		if err != nil {
			lastErr = err
			continue
		}
		resp, err := c.http.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		return resp, nil
	}
	return nil, lastErr
}

// post sends one control call. A host requires X-Yuruna on every mutating
// control route (its cross-site request guard) in addition to the proof.
func (c *Client) post(ctx context.Context, endpoint, proof string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-Yuruna", "1")
	req.Header.Set("X-Yuruna-Control", proof)
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("the host did not answer: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if resp.StatusCode/100 == 2 {
		return nil
	}
	var doc struct {
		Reason string `json:"reason"`
		Error  string `json:"error"`
	}
	_ = json.Unmarshal(body, &doc)
	detail := doc.Error
	if detail == "" {
		detail = firstLine(body)
	}
	return &Error{Status: resp.StatusCode, Reason: doc.Reason, Detail: detail}
}

// --- REGION: Per-host refresh
// Refresh reply vocabulary, spelled as the host's listener puts it on the
// wire.
const (
	RefreshActionSpawned        = "spawned"
	RefreshActionAlreadyClaimed = "already_claimed"
	RefreshActionCompleted      = "completed"

	RefreshReasonBusy            = "busy"
	RefreshReasonRequestConflict = "request_conflict"
	RefreshReasonRequestClosed   = "request_closed"
	// RefreshReasonReplyInvalid is this client's own verdict on an answer it
	// cannot use: an unexpected success or redirect, a mismatched request id,
	// or an undecodable body.
	RefreshReasonReplyInvalid = "host_reply_invalid"
)

const (
	refreshPath = "/control/host-refresh"
	// maxRefreshReplyBytes caps a refresh reply read; every reply is a short
	// JSON document.
	maxRefreshReplyBytes = 64 << 10
	// refreshResendFloor is the least time that must remain on the caller's
	// context for the one same-id resend after a transport failure; less than
	// that and the resend could only be cut off mid-flight.
	refreshResendFloor = 3 * time.Second
)

// ErrNoRefreshProof means no refresh proof was supplied, so nothing was sent.
var ErrNoRefreshProof = errors.New("no refresh proof")

// RefreshRequest is what one refresh asks of one host. RequestID is generated
// once by the caller and reused on every retry, so a retry is always the same
// request.
type RefreshRequest struct {
	RequestID, Tier, MaxRung string
}

// RefreshReply is a host's acceptance: 202 with spawned or already_claimed, or
// 200 with a stored completed replay (Replay true, Verdict and State set).
// StateURL is absolute and on the host's own origin, or empty.
type RefreshReply struct {
	Status                                               int
	RequestID, Action, StateURL, Verdict, State, Ceiling string
	Replay                                               bool
}

// RefreshError is every answer that is not an acceptance. Reason is the
// host's machine-readable reason (or RefreshReasonReplyInvalid); Code and
// Detail are its catalog key and text, kept apart from Reason because the
// listener's refusals and the legacy transport gate's use the fields
// differently. Status 0 means the host never answered.
type RefreshError struct {
	Status                                                                 int
	Reason, Code, Detail, RequestID, ActiveRequestID, ActiveKind, StateURL string
	State, Verdict                                                         string
	Retryable                                                              bool
}

// Error is the machine form; the route renders the operator text.
func (e *RefreshError) Error() string {
	return fmt.Sprintf("host refresh: HTTP %d reason=%s", e.Status, e.Reason)
}

type refreshReplyDoc struct {
	OK              bool   `json:"ok"`
	RequestID       string `json:"requestId"`
	Action          string `json:"action"`
	StateURL        string `json:"stateUrl"`
	Verdict         string `json:"verdict"`
	State           string `json:"state"`
	Ceiling         string `json:"ceiling"`
	Reason          string `json:"reason"`
	Error           string `json:"error"`
	Code            string `json:"code"`
	ActiveRequestID string `json:"activeRequestId"`
	ActiveKind      string `json:"activeKind"`
}

// Refresh asks one host to admit one refresh request. It is a method of its
// own, not an action of Apply: it carries a JSON body, both the legacy
// transport proof and the refresh proof, and a typed reply.
//
// Nothing is sent unless every field is valid and both proofs are present. A
// transport failure is resent once -- the identical body and proofs, so the
// host sees the same request id and answers already_claimed if the first copy
// arrived -- when at least refreshResendFloor remains on ctx. A new request id
// is never generated here.
func (c *Client) Refresh(ctx context.Context, baseURL string, req RefreshRequest, controlProof, refreshProof string) (RefreshReply, error) {
	switch {
	case !hostrefresh.ValidRequestID(req.RequestID):
		return RefreshReply{}, fmt.Errorf("%w: requestId", hostrefresh.ErrInvalidClaim)
	case !hostrefresh.ValidTier(req.Tier):
		return RefreshReply{}, fmt.Errorf("%w: tier", hostrefresh.ErrInvalidClaim)
	case !hostrefresh.ValidRung(req.MaxRung):
		return RefreshReply{}, fmt.Errorf("%w: maxRung", hostrefresh.ErrInvalidClaim)
	case strings.TrimSpace(controlProof) == "":
		return RefreshReply{}, ErrNoProof
	case strings.TrimSpace(refreshProof) == "":
		return RefreshReply{}, ErrNoRefreshProof
	}
	base, err := hostBase(baseURL)
	if err != nil {
		return RefreshReply{}, err
	}
	body, err := json.Marshal(struct {
		RequestID string `json:"requestId"`
		Tier      string `json:"tier"`
		MaxRung   string `json:"maxRung"`
	}{req.RequestID, req.Tier, req.MaxRung})
	if err != nil {
		return RefreshReply{}, err
	}
	resp, err := c.sendRefresh(ctx, base, body, controlProof, refreshProof)
	if err != nil && ctx.Err() == nil && remainingAtLeast(ctx, refreshResendFloor) {
		resp, err = c.sendRefresh(ctx, base, body, controlProof, refreshProof)
	}
	if err != nil {
		return RefreshReply{}, &RefreshError{Status: 0, RequestID: req.RequestID, Retryable: true, Detail: err.Error()}
	}
	defer resp.Body.Close()
	raw, readErr := io.ReadAll(io.LimitReader(resp.Body, maxRefreshReplyBytes+1))
	var doc refreshReplyDoc
	parsed := readErr == nil && len(raw) <= maxRefreshReplyBytes && json.Unmarshal(raw, &doc) == nil
	invalid := func(detail string) (RefreshReply, error) {
		return RefreshReply{}, &RefreshError{Status: resp.StatusCode, Reason: RefreshReasonReplyInvalid, Detail: detail, RequestID: req.RequestID}
	}
	if parsed && doc.RequestID != "" && doc.RequestID != req.RequestID {
		return invalid("the host answered for another request id")
	}
	stateURL := ""
	if parsed {
		stateURL = sameOriginURL(base, doc.StateURL)
	}
	switch {
	case resp.StatusCode == http.StatusAccepted:
		if !parsed || !doc.OK || doc.RequestID != req.RequestID ||
			(doc.Action != RefreshActionSpawned && doc.Action != RefreshActionAlreadyClaimed) {
			return invalid("an acceptance without a matching request id and action")
		}
		return RefreshReply{Status: resp.StatusCode, RequestID: doc.RequestID, Action: doc.Action, StateURL: stateURL, Ceiling: doc.Ceiling}, nil
	case resp.StatusCode == http.StatusOK:
		if !parsed || !doc.OK || doc.RequestID != req.RequestID || doc.Action != RefreshActionCompleted {
			return invalid("a success that is not a completed replay of this request")
		}
		return RefreshReply{Status: resp.StatusCode, RequestID: doc.RequestID, Action: doc.Action, StateURL: stateURL,
			Verdict: doc.Verdict, State: doc.State, Ceiling: doc.Ceiling, Replay: true}, nil
	case resp.StatusCode/100 == 2 || resp.StatusCode/100 == 3 || resp.StatusCode < 200:
		return invalid(fmt.Sprintf("unexpected HTTP %d", resp.StatusCode))
	}
	e := &RefreshError{Status: resp.StatusCode, RequestID: req.RequestID, StateURL: stateURL}
	if parsed {
		e.Reason, e.Code, e.Detail = doc.Reason, doc.Code, doc.Error
		e.ActiveRequestID, e.ActiveKind, e.State, e.Verdict = doc.ActiveRequestID, doc.ActiveKind, doc.State, doc.Verdict
	} else {
		e.Detail = firstLine(raw)
	}
	// A 409 is an answer about this request (busy with another, or already
	// used differently): retrying it unchanged cannot succeed. A timeout or a
	// server-side failure can.
	e.Retryable = resp.StatusCode == http.StatusRequestTimeout || resp.StatusCode/100 == 5
	return RefreshReply{}, e
}

// sendRefresh performs one POST of the refresh body.
func (c *Client) sendRefresh(ctx context.Context, base string, body []byte, controlProof, refreshProof string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+refreshPath, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Yuruna", "1")
	req.Header.Set("X-Yuruna-Control", controlProof)
	req.Header.Set(hostrefresh.ProofHeader, refreshProof)
	return c.http.Do(req)
}

// remainingAtLeast reports whether ctx allows at least d more; a context with
// no deadline always does.
func remainingAtLeast(ctx context.Context, d time.Duration) bool {
	deadline, ok := ctx.Deadline()
	return !ok || time.Until(deadline) >= d
}

// sameOriginURL resolves a state URL the host returned against the host's own
// base and keeps it only when it stays on that origin, so a host reply cannot
// point a caller at another server.
func sameOriginURL(base, ref string) string {
	if strings.TrimSpace(ref) == "" {
		return ""
	}
	b, err := url.Parse(base)
	if err != nil {
		return ""
	}
	r, err := url.Parse(ref)
	if err != nil {
		return ""
	}
	abs := b.ResolveReference(r)
	if abs.Scheme != b.Scheme || abs.Host != b.Host || abs.User != nil {
		return ""
	}
	return abs.String()
}

// hostBase normalizes a host base URL, refusing anything that is not an
// absolute http(s) address. The addresses come from the aggregator, which this
// service reads unauthenticated.
func hostBase(baseURL string) (string, error) {
	raw := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if raw == "" {
		return "", &hostAddressError{text: "the pool holds no address for the host"}
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return "", &hostAddressError{text: fmt.Sprintf("unusable host address %q", baseURL)}
	}
	return raw, nil
}

// ErrHostAddress means the host's address was missing or not an absolute
// http(s) URL, so nothing was sent. The error's own text quotes that address,
// which comes from the aggregator unauthenticated; a caller that relays the
// failure to someone else matches this instead of forwarding the text.
var ErrHostAddress = errors.New("unusable host address")

// hostAddressError keeps hostBase's operator text while matching
// ErrHostAddress.
type hostAddressError struct{ text string }

func (e *hostAddressError) Error() string        { return e.text }
func (e *hostAddressError) Is(target error) bool { return target == ErrHostAddress }

// firstLine keeps an unstructured error body to one short line, so a host
// answering an HTML error page does not push a page of markup into a UI notice.
func firstLine(body []byte) string {
	s := strings.TrimSpace(string(body))
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200] + "..."
	}
	return s
}
