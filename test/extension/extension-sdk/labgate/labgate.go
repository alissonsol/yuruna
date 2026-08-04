// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package labgate is the write gate every Yuruna extension service puts in
// front of a route that changes host or pool configuration.
//
// Two ways through one door. An operator reads the rotating 6-character lab
// token off the Yuruna hosts dashboard and exchanges it once per device for a
// signed session cookie; automation sends the shared lab auth token as a
// bearer. Both guard the same routes, because a second credential store buys
// nothing here: neither tells you WHO made a change, which is why every mutation
// is also audited.
//
// The lab token is public on the LAN by construction -- the aggregator publishes
// it on its open /metrics and paints it on a dashboard tile. It is a
// stop-a-stray-click gate, not a secret, and it is worth having precisely
// because it rotates: a code copied out of the lab stops working on its own.
//
// Validation belongs to the aggregator, which owns the codes and their rotation.
// A service holds no copy to go stale and no comparison to get wrong; it asks,
// and it believes only a definite answer. When the check cannot be made at all,
// the gate stays shut and says so -- an operator who cannot tell "wrong code"
// from "validator down" retypes a correct code until they give up.
//
// Reads are deliberately outside all of this. Catalogs, artifacts and status are
// open on the trusted LAN, matching the pool-status posture; gating them would
// make a credential a prerequisite for a host doing its job.
package labgate

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// DefaultCookieName is the session cookie a service sets after an unlock.
	DefaultCookieName = "yuruna_lab_session"

	// DefaultSessionTTL lasts long enough that an operator is not re-prompted
	// during a shift, and short enough that a lost phone stops working within a
	// week.
	DefaultSessionTTL = 7 * 24 * time.Hour

	// Attempt throttling: a short shared code is guessable otherwise. Exported
	// because a service's own route tests assert against the cap, and a UI that
	// explains a 429 needs the window.
	MaxFailedAttempts = 8
	FailWindow        = 10 * time.Minute

	// labTokenPath is the aggregator's exchange route.
	labTokenPath = "/api/v1/lab-token"

	// labTokenTimeout bounds the outbound check. The login route holds a client
	// connection while it waits, so an aggregator that accepts a connection and
	// then says nothing must not be able to wedge unlocking.
	labTokenTimeout = 5 * time.Second

	// maxLoginBody caps the unlock request body: it carries a 6-character code.
	maxLoginBody = 4 << 10

	// ReasonUnavailable is the machine-readable token for "the check itself
	// could not be made", which is never the same answer as "wrong code".
	ReasonUnavailable = "lab-token-unavailable"

	// ReasonUnconfigured is the machine-readable token for a service with
	// neither way in configured. Its mutating routes answer 503, never an
	// ungated write.
	ReasonUnconfigured = "auth-unconfigured"
)

// labTokenRE is the aggregator's own shape for a code. Matching it locally keeps
// a typo from costing a round trip -- and, more importantly, from spending one
// of the lab's shared per-source attempts.
var labTokenRE = regexp.MustCompile(`^[a-z0-9]{6}$`)

// Options configures a Gate.
type Options struct {
	// AggregatorURL validates submitted lab tokens. Empty disables the lab-token
	// route into the gate, leaving the bearer as the only way in.
	AggregatorURL string

	// BearerToken is the shared lab auth token accepted on the Authorization
	// header. Empty disables the bearer route into the gate.
	BearerToken string

	// CookieName overrides DefaultCookieName. Distinct services on distinct
	// origins do not collide, but a service that shares an origin with another
	// should name its own.
	CookieName string

	// SessionTTL overrides DefaultSessionTTL.
	SessionTTL time.Duration

	// Audit records one unlock attempt. Optional; the gate never depends on it.
	// The aggregator's own audit cannot do this job: every operator reaches it
	// THROUGH this service, so from there the whole lab is one source address.
	Audit func(ip, outcome, detail string)

	// HTTPClient replaces the built-in validator client wholesale (tests inject
	// one).
	HTTPClient *http.Client
}

// Gate holds the signing key and the per-source failure counts. The codes
// themselves live only at the aggregator.
type Gate struct {
	mu sync.Mutex

	aggregatorURL string
	bearer        string
	cookieName    string
	sessionTTL    time.Duration
	audit         func(ip, outcome, detail string)
	client        *http.Client

	// signKey signs session cookies. Generated at startup: a restart
	// invalidating sessions is an acceptable cost for never persisting a key,
	// and it means a state directory on a shared mount never holds a secret.
	signKey []byte
	fails   map[string][]time.Time
}

// New builds a Gate. It never fails: a gate that could not generate a signing
// key simply has no lab-token route, which is the fail-closed answer -- issuing
// forgeable cookies would not be.
func New(opts Options) *Gate {
	g := &Gate{
		aggregatorURL: strings.TrimRight(strings.TrimSpace(opts.AggregatorURL), "/"),
		bearer:        strings.TrimSpace(opts.BearerToken),
		cookieName:    strings.TrimSpace(opts.CookieName),
		sessionTTL:    opts.SessionTTL,
		audit:         opts.Audit,
		client:        opts.HTTPClient,
		fails:         map[string][]time.Time{},
	}
	if g.cookieName == "" {
		g.cookieName = DefaultCookieName
	}
	if g.sessionTTL <= 0 {
		g.sessionTTL = DefaultSessionTTL
	}
	if g.client == nil {
		g.client = &http.Client{
			Timeout: labTokenTimeout,
			// The same trusted-LAN posture as the beacon and the pool read: the
			// aggregator listener is routinely plain HTTP or carries a leaf no
			// guest trusts, so demanding a verifiable certificate would disable
			// this gate outright. What crosses the wire is a code the aggregator
			// already publishes on its open /metrics, and the reply is discarded
			// unread.
			Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}}, //nolint:gosec // trusted-LAN; the payload is a published rotating code
		}
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return g
	}
	g.signKey = key
	return g
}

// LabTokenEnabled reports whether the dashboard-code route into the gate exists.
func (g *Gate) LabTokenEnabled() bool {
	return g != nil && g.aggregatorURL != "" && len(g.signKey) > 0
}

// BearerEnabled reports whether the automation route into the gate exists.
func (g *Gate) BearerEnabled() bool { return g != nil && g.bearer != "" }

// Configured reports whether ANY way through the gate exists. False means the
// service refuses every mutation rather than running one ungated.
func (g *Gate) Configured() bool { return g.LabTokenEnabled() || g.BearerEnabled() }

// Authed reports whether the request carries a valid session or the bearer.
//
// A session outlives the aggregator being reachable: it was granted on a check
// that DID succeed, and re-prompting every operator because the validator
// blinked would be a worse answer than honouring the cookie until it expires.
func (g *Gate) Authed(r *http.Request) bool {
	return g.bearerAuthed(r) || g.sessionAuthed(r)
}

func (g *Gate) sessionAuthed(r *http.Request) bool {
	if !g.LabTokenEnabled() {
		return false
	}
	c, err := r.Cookie(g.cookieName)
	if err != nil || c == nil {
		return false
	}
	return g.validSession(c.Value, time.Now())
}

// bearerAuthed compares the Authorization bearer in constant time, so a token
// cannot be recovered byte by byte from response timing.
func (g *Gate) bearerAuthed(r *http.Request) bool {
	if !g.BearerEnabled() {
		return false
	}
	h := strings.TrimSpace(r.Header.Get("Authorization"))
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return false
	}
	got := strings.TrimSpace(h[len(prefix):])
	return subtle.ConstantTimeCompare([]byte(got), []byte(g.bearer)) == 1
}

// mint builds a signed, expiring session value: <expiryUnix>.<hmac>.
func (g *Gate) mint(now time.Time) string {
	exp := strconv.FormatInt(now.Add(g.sessionTTL).Unix(), 10)
	mac := hmac.New(sha256.New, g.signKey)
	mac.Write([]byte(exp))
	return exp + "." + hex.EncodeToString(mac.Sum(nil))
}

// validSession reports whether a cookie value is well-formed, unexpired and
// correctly signed. Constant-time compare so the signature cannot be probed byte
// by byte.
func (g *Gate) validSession(v string, now time.Time) bool {
	parts := strings.SplitN(v, ".", 2)
	if len(parts) != 2 {
		return false
	}
	exp, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || now.Unix() > exp {
		return false
	}
	mac := hmac.New(sha256.New, g.signKey)
	mac.Write([]byte(parts[0]))
	want := hex.EncodeToString(mac.Sum(nil))
	return subtle.ConstantTimeCompare([]byte(want), []byte(parts[1])) == 1
}

// throttled reports whether this source has failed too often recently.
func (g *Gate) throttled(ip string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.keepRecent(ip, time.Now().Add(-FailWindow))) >= MaxFailedAttempts
}

func (g *Gate) recordFail(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	// Sweep every source, not just this one. Login is reachable without any
	// credential, so a caller cycling source addresses would otherwise leave one
	// permanent map entry per address it ever failed from -- unbounded growth
	// driven entirely from outside.
	cutoff := time.Now().Add(-FailWindow)
	for known := range g.fails {
		g.keepRecent(known, cutoff)
	}
	g.fails[ip] = append(g.fails[ip], time.Now())
}

// keepRecent drops this source's expired attempts, and the source itself once it
// has none left. Must be called with the lock held.
func (g *Gate) keepRecent(ip string, cutoff time.Time) []time.Time {
	kept := g.fails[ip][:0]
	for _, t := range g.fails[ip] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) == 0 {
		delete(g.fails, ip)
		return nil
	}
	g.fails[ip] = kept
	return kept
}

// Verdict is what the aggregator said about a submitted code. "Rejected" and
// "could not tell" are separate on purpose: only the first is an answer about
// the code, and neither ever opens the gate.
type Verdict int

const (
	Valid Verdict = iota
	Rejected
	Unavailable
)

// verify asks the aggregator whether a code is one it is currently showing.
//
// The HTTP status is the entire verdict. A 200 carries an envelope sealed under
// the submitted code; opening it would pull the shared lab auth token into this
// process for nothing, so the body is drained and dropped. Draining rather than
// abandoning it is what keeps the connection reusable.
//
// Unlike the beacon there is no plain-http downgrade retry: an unlock that could
// not be checked over the configured URL must fail, not find another route.
func (g *Gate) verify(ctx context.Context, code string) (Verdict, string) {
	if !g.LabTokenEnabled() {
		return Unavailable, "no aggregator URL configured"
	}
	body, err := json.Marshal(map[string]string{"labToken": code})
	if err != nil {
		return Unavailable, "request encoding failed"
	}
	ctx, cancel := context.WithTimeout(ctx, labTokenTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.aggregatorURL+labTokenPath, bytes.NewReader(body))
	if err != nil {
		return Unavailable, "malformed aggregator URL"
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := g.client.Do(req)
	if err != nil {
		return Unavailable, "unreachable"
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		return Valid, ""
	case http.StatusUnauthorized, http.StatusForbidden:
		return Rejected, ""
	default:
		// 503 (exchange disabled), 429 (the aggregator is throttling this
		// service's address), 400 (its shape rule moved out from under the local
		// check) and anything else are all "no answer about the code".
		return Unavailable, "aggregator answered HTTP " + strconv.Itoa(resp.StatusCode)
	}
}

// Session is what a UI needs to decide between prompting for the lab token,
// saying only automation can mutate, and explaining that nothing is configured.
type Session struct {
	OK            bool `json:"ok"`
	LabToken      bool `json:"labToken"`
	Bearer        bool `json:"bearer"`
	Authed        bool `json:"authed"`
	Configured    bool `json:"configured"`
	MutationsOpen bool `json:"mutationsOpen"`
}

// Session reports which ways through the gate exist right now and whether this
// device is already through one.
func (g *Gate) Session(r *http.Request) Session {
	authed := g.Authed(r)
	return Session{
		OK:            true,
		LabToken:      g.LabTokenEnabled(),
		Bearer:        g.BearerEnabled(),
		Authed:        authed,
		Configured:    g.Configured(),
		MutationsOpen: authed,
	}
}

// HandleLogin exchanges the dashboard's lab token for a session cookie.
// Services mount it at POST /api/login; it must stay open, or the prompt could
// never be answered.
func (g *Gate) HandleLogin(w http.ResponseWriter, r *http.Request) {
	ip := ClientIP(r)
	if !g.LabTokenEnabled() {
		writeReason(w, http.StatusServiceUnavailable, ReasonUnavailable,
			"no aggregator URL is configured, so the pool aggregator cannot check a lab token; actions stay locked")
		return
	}
	// Throttling stays here even though the aggregator throttles too. Its bucket
	// is the source address, which for every operator is this service: one
	// guesser would otherwise burn the whole lab's attempts and lock everyone out
	// of enrollment.
	if g.throttled(ip) {
		g.auditLogin(ip, "throttled", "")
		writeErr(w, http.StatusTooManyRequests, "too many attempts; wait a few minutes")
		return
	}
	var body struct {
		LabToken string `json:"labToken"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, maxLoginBody)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body")
		return
	}
	// Case and stray whitespace come from reading a code off a screen, not from
	// guessing one, so normalise before judging.
	code := strings.ToLower(strings.TrimSpace(body.LabToken))
	if !labTokenRE.MatchString(code) {
		// Not a failed guess: it never reached the aggregator, so it neither
		// counts toward the throttle nor spends the lab's shared attempts.
		writeErr(w, http.StatusBadRequest, "the lab token is the 6-character code on the dashboard's Lab token tile")
		return
	}
	switch verdict, detail := g.verify(r.Context(), code); verdict {
	case Unavailable:
		g.auditLogin(ip, "unavailable", detail)
		writeReason(w, http.StatusServiceUnavailable, ReasonUnavailable,
			"the pool aggregator could not check the lab token ("+detail+"); actions stay locked")
		return
	case Rejected:
		g.recordFail(ip)
		g.auditLogin(ip, "refused", "")
		// Deliberately generic: distinguishing "wrong code" from "expired code"
		// only helps someone guessing.
		writeErr(w, http.StatusUnauthorized, "incorrect lab token")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     g.cookieName,
		Value:    g.mint(time.Now()),
		Path:     "/",
		HttpOnly: true,
		// Lax, NOT Strict. The dashboard's Extension hosts table deep-links these
		// services from a different origin, and that is the primary way an
		// operator arrives; Strict would suppress the cookie on that navigation
		// and re-prompt every single time. Lax still withholds it on cross-site
		// POST/fetch, so the CSRF posture for mutations is unchanged.
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(g.sessionTTL / time.Second),
	})
	g.auditLogin(ip, "ok", "")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (g *Gate) auditLogin(ip, outcome, detail string) {
	if g.audit != nil {
		g.audit(ip, outcome, detail)
	}
}

// Require wraps a mutating handler: the request must carry the bearer or a
// session. With neither credential configured the answer is 503 with a
// machine-readable reason -- never an ungated write.
func (g *Gate) Require(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !g.Configured() {
			writeReason(w, http.StatusServiceUnavailable, ReasonUnconfigured,
				"no aggregator URL and no lab auth token configured; changes are disabled")
			return
		}
		if g.Authed(r) {
			next(w, r)
			return
		}
		writeErr(w, http.StatusUnauthorized, "lab token session or lab auth token required")
	}
}

// RequireBearer gates a route on the lab auth token ALONE. It is for routes that
// act pool-wide from one call: a phone session that unlocked one service should
// not be able to start work on every host in the lab at once.
func (g *Gate) RequireBearer(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !g.BearerEnabled() {
			writeReason(w, http.StatusServiceUnavailable, ReasonUnconfigured,
				"no lab auth token configured; this route is disabled")
			return
		}
		if !g.bearerAuthed(r) {
			writeErr(w, http.StatusUnauthorized, "lab auth token required")
			return
		}
		next(w, r)
	}
}

// ClientIP is the throttling and audit key. net.SplitHostPort keeps the brackets
// off an IPv6 literal, so the key is the address; splitting on the last colon by
// hand would chop a port-less IPv6 address at a colon inside the literal.
func ClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		// A RemoteAddr with no port at all is already the host.
		return r.RemoteAddr
	}
	return host
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "error": msg})
}

func writeReason(w http.ResponseWriter, status int, reason, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "reason": reason, "error": msg})
}
