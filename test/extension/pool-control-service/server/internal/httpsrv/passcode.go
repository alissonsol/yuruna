// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A shared passcode in front of the operator board.
//
// This service was unauthenticated, which was defensible while it was an expert
// tool on a LAN. A simpler UI on more devices widens who can repoint a lab, so
// the board gets a barrier proportionate to that: one shared secret, entered
// once per device.
//
// Deliberately NOT per-user auth. It stops a stranger on the LAN and an
// accidental visitor; it does not tell you WHO assigned something, which is why
// every mutation is still audited. If that traceability ever matters, this is
// the piece to replace.

const (
	passcodeCookie = "yuruna_board"
	// A session lasts long enough that an operator is not re-prompted during a
	// shift, and short enough that a lost phone stops working within a week.
	passcodeTTL = 7 * 24 * time.Hour
	// Attempt throttling: a short shared code is guessable otherwise.
	passcodeMaxFails  = 8
	passcodeFailWindow = 10 * time.Minute
)

// passcodeGate holds the secret, the signing key and the per-IP failure counts.
type passcodeGate struct {
	mu sync.Mutex
	// code is the shared passcode. Empty disables the gate entirely, which is
	// the posture every existing deployment has today.
	code string
	// signKey signs session cookies. Generated at startup: a restart
	// invalidating sessions is an acceptable cost for never persisting a key,
	// and it means the state dir (a world-readable CIFS mount of the pool NAS)
	// never holds a secret.
	signKey []byte
	// publicRead lets the read-only board render without a passcode, for a wall
	// display. Mutations stay gated regardless.
	publicRead bool
	fails      map[string][]time.Time
}

func newPasscodeGate(code string, publicRead bool) *passcodeGate {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		// Without a usable key we cannot mint verifiable sessions. Fail closed
		// by leaving the gate disabled rather than issuing forgeable cookies.
		return &passcodeGate{fails: map[string][]time.Time{}}
	}
	return &passcodeGate{code: strings.TrimSpace(code), signKey: key, publicRead: publicRead, fails: map[string][]time.Time{}}
}

func (g *passcodeGate) enabled() bool { return g != nil && g.code != "" && len(g.signKey) > 0 }

// mint builds a signed, expiring session value: <expiryUnix>.<hmac>.
func (g *passcodeGate) mint(now time.Time) string {
	exp := strconv.FormatInt(now.Add(passcodeTTL).Unix(), 10)
	mac := hmac.New(sha256.New, g.signKey)
	mac.Write([]byte(exp))
	return exp + "." + hex.EncodeToString(mac.Sum(nil))
}

// valid reports whether a cookie value is well-formed, unexpired and correctly
// signed. Constant-time compare so the signature cannot be probed byte by byte.
func (g *passcodeGate) valid(v string, now time.Time) bool {
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

// authed reports whether the request carries a valid session.
func (g *passcodeGate) authed(r *http.Request) bool {
	if !g.enabled() {
		return true
	}
	c, err := r.Cookie(passcodeCookie)
	if err != nil || c == nil {
		return false
	}
	return g.valid(c.Value, time.Now())
}

// throttled reports whether this source has failed too often recently, and
// prunes expired entries as it goes.
func (g *passcodeGate) throttled(ip string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	cutoff := time.Now().Add(-passcodeFailWindow)
	kept := g.fails[ip][:0]
	for _, t := range g.fails[ip] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	g.fails[ip] = kept
	return len(kept) >= passcodeMaxFails
}

func (g *passcodeGate) recordFail(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.fails[ip] = append(g.fails[ip], time.Now())
}

func clientIP(r *http.Request) string {
	host := r.RemoteAddr
	if i := strings.LastIndex(host, ":"); i > 0 {
		host = host[:i]
	}
	return host
}

// handleLogin exchanges the shared passcode for a session cookie.
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	g := s.gate
	if !g.enabled() {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "gate": false})
		return
	}
	ip := clientIP(r)
	if g.throttled(ip) {
		writeErr(w, http.StatusTooManyRequests, "too many attempts; wait a few minutes")
		return
	}
	var body struct{ Passcode string }
	if !decode(w, r, &body) {
		return
	}
	if subtle.ConstantTimeCompare([]byte(strings.TrimSpace(body.Passcode)), []byte(g.code)) != 1 {
		g.recordFail(ip)
		// Deliberately generic: distinguishing "wrong code" from anything else
		// only helps someone guessing.
		writeErr(w, http.StatusUnauthorized, "incorrect passcode")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     passcodeCookie,
		Value:    g.mint(time.Now()),
		Path:     "/",
		HttpOnly: true,
		// Lax, NOT Strict. The Grafana Extension-hosts table deep-links this
		// service from a different origin, and that is the primary way an
		// operator arrives; Strict would suppress the cookie on that navigation
		// and re-prompt every single time. Lax still withholds it on cross-site
		// POST/fetch, so the CSRF posture for mutations is unchanged.
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(passcodeTTL / time.Second),
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleSession reports whether a gate is configured and whether this device is
// already through it, so the UI knows whether to show the passcode prompt.
func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"gate":    s.gate.enabled(),
		"authed":  s.gate.authed(r),
		"version": s.opts.Version,
	})
}

// requireAuth wraps a handler so it refuses without a valid session.
//
// readOnly handlers may be exempted by --public-read; mutations never are.
func (s *Server) requireAuth(readOnly bool, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.gate.enabled() {
			next(w, r)
			return
		}
		if readOnly && s.gate.publicRead {
			next(w, r)
			return
		}
		if !s.gate.authed(r) {
			writeErr(w, http.StatusUnauthorized, "passcode required")
			return
		}
		next(w, r)
	}
}
