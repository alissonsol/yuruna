// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package hostctl drives another host's operator-control routes: the two pause
// switches behind the status page's "Pause after cycle" and "Pause after step"
// buttons, plus the read of where a host currently stands.
//
// A host accepts a mutating /control/* call only from its own loopback
// interface or from a caller presenting a control proof -- an HMAC over the
// pool-wide lab-auth-token, carried in X-Yuruna-Control. That format is shared
// with the pool aggregator (Go) and the host's own verifier (PowerShell), so
// all three must derive it byte for byte identically; the golden vector in this
// package's tests is what pins it.
//
// The two switches are independent flag files on the host, and its status page
// drives them from two independent buttons. This package instead speaks in the
// three states an operator chooses between, and every Apply leaves exactly one
// switch armed -- which is what lets a pool report a single state for its
// members rather than a matrix of them.
package hostctl

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
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
// where HMAC = HMAC-SHA256(lab-auth-token, "yuruna-control|proof|<expiry>").
func Proof(token string, expiry int64) string {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|" + strconv.FormatInt(expiry, 10)))
	return strconv.FormatInt(expiry, 10) + "." + base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// Mint returns a proof valid for ttl from now, or "" when no token is held --
// the caller then has no local way to prove control and must obtain one from
// the aggregator.
func Mint(token string, ttl time.Duration) string {
	if strings.TrimSpace(token) == "" {
		return ""
	}
	return Proof(token, time.Now().Add(ttl).Unix())
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
	"host-token-missing":   "the host holds no lab token (enrol it: pwsh test/Set-LabToken.ps1)",
	"proof-invalid":        "the host holds a different lab token (re-enrol it against this lab)",
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
// This is the fallback for a service that holds no lab-auth-token of its own:
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
		return "", fmt.Errorf("the pool aggregator answered HTTP %d for this host", resp.StatusCode)
	}
	// No fragment means the aggregator holds no lab-auth-token of its own, so
	// the whole lab is loopback-only control. Say that, rather than sending a
	// proofless call to every member to collect identical 403s.
	_, proof, found := strings.Cut(resp.Header.Get("Location"), proofFragment)
	if !found || proof == "" {
		return "", errors.New("the pool aggregator minted no control proof (it holds no lab auth token)")
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

// hostBase normalizes a host base URL, refusing anything that is not an
// absolute http(s) address. The addresses come from the aggregator, which this
// service reads unauthenticated.
func hostBase(baseURL string) (string, error) {
	raw := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if raw == "" {
		return "", errors.New("the pool knows no address for this host")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return "", fmt.Errorf("unusable host address %q", baseURL)
	}
	return raw, nil
}

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
