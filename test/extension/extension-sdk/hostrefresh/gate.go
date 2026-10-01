// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package hostrefresh

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"sync"
	"time"
	"yuruna.com/test/extension/extension-sdk/internal/gatethrottle"

	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/internal/catalog"
)

// Gate refusal reasons, spelled as wire codes.
const (
	ReasonGateUnconfigured   = "refresh_auth_unconfigured"
	ReasonCredentialRequired = "refresh_credential_required"
	ReasonGateThrottled      = "refresh_auth_throttled"
)

// Audit outcomes a Gate reports. Hyphenated, so no audit token can be read as
// one of the underscored wire codes a reply carries.
const (
	AuditOK           = "credential-ok"
	AuditRefused      = "credential-refused"
	AuditThrottled    = "credential-throttled"
	AuditUnconfigured = "credential-unprovisioned"
)

// Throttling matches the legacy gate's allowance so a guesser gains nothing by
// switching doors, and is kept separately so a legacy unlock storm cannot lock
// the refresh credential out, or the reverse.
const (
	MaxFailedAttempts = 8
	FailWindow        = 10 * time.Minute
)

// GateOptions configures a refresh credential gate.
type GateOptions struct {
	// Credential is the operator refresh credential, one "yhrc1.<b64u>" line.
	// Anything else leaves the gate unconfigured, which refuses everything.
	Credential string
	// Language and AllowPseudoLocale follow the service's own locale policy.
	Language          string
	AllowPseudoLocale bool
	// Audit receives the source address and one Audit* outcome. It never
	// receives the presented value.
	Audit func(ip, outcome string)
	// Now replaces the clock for throttle tests.
	Now func() time.Time
}

// Gate admits a request only when it carries the refresh credential in its
// own header. It never reads Authorization, never reads or sets a cookie, and
// grants nothing that outlives the request, so neither a legacy session nor a
// legacy bearer can satisfy it and the credential never becomes a session.
//
// It satisfies the mcp package's Gate interface structurally, so a tool can be
// gated on it without this package importing mcp.
type Gate struct {
	credential []byte
	audit      func(ip, outcome string)
	now        func() time.Time
	locale     *i18n.Negotiator

	mu        sync.Mutex
	fails     map[string][]time.Time
	lastSweep time.Time
}

// NewGate builds a gate. A credential that does not parse leaves it
// unconfigured rather than accepting a weak or misplaced secret.
func NewGate(o GateOptions) *Gate {
	g := &Gate{audit: o.Audit, now: o.Now, fails: map[string][]time.Time{},
		locale: &i18n.Negotiator{Manifest: i18n.DefaultManifest(), Available: gateCatalog().Locales(),
			ConfigLanguage: o.Language, AllowPseudo: o.AllowPseudoLocale}}
	if g.now == nil {
		g.now = time.Now
	}
	if b, err := ParseSecret(o.Credential, CredentialPrefix); err == nil {
		g.credential = []byte(FormatSecret(CredentialPrefix, b))
	}
	return g
}

// Configured reports whether a credential is provisioned.
func (g *Gate) Configured() bool { return g != nil && len(g.credential) > 0 }

// Authorized compares the credential header in constant time. Only the
// dedicated header is read.
func (g *Gate) Authorized(r *http.Request) bool {
	if !g.Configured() {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(r.Header.Get(CredentialHeader)), g.credential) == 1
}

// check is the one decision both entry points share. It records a failure
// only for a presented, wrong credential: a request without the header is not
// a guess and spends nothing.
func (g *Gate) check(r *http.Request) (ok bool, status int, reason, key string, args map[string]any) {
	ip := clientIP(r)
	if !g.Configured() {
		g.report(ip, AuditUnconfigured)
		return false, http.StatusServiceUnavailable, ReasonGateUnconfigured, "auth.refresh_unconfigured", nil
	}
	if g.throttled(ip) {
		g.report(ip, AuditThrottled)
		return false, http.StatusTooManyRequests, ReasonGateThrottled, "auth.refresh_throttled",
			map[string]any{"minutes": int(FailWindow / time.Minute)}
	}
	if !g.Authorized(r) {
		if r.Header.Get(CredentialHeader) != "" {
			g.recordFail(ip)
		}
		g.report(ip, AuditRefused)
		return false, http.StatusUnauthorized, ReasonCredentialRequired, "auth.refresh_credential_required", nil
	}
	g.report(ip, AuditOK)
	return true, http.StatusOK, "", "", nil
}

// Require wraps a handler: 503 when no credential is provisioned, 429 while
// this source is throttled, 401 without the credential.
func (g *Gate) Require(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ok, status, reason, key, args := g.check(r)
		if ok {
			next(w, r)
			return
		}
		locale := g.resolveLocale(r)
		i18n.Apply(w.Header(), locale)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": false, "code": key, "reason": reason,
			"error": gateCatalog().Render(key, args, locale.ResolvedTag),
		})
	}
}

// Allow answers the mcp Gate question on the incoming request: ok, the reason
// code and the localized message.
func (g *Gate) Allow(r *http.Request) (bool, string, string) {
	ok, _, reason, key, args := g.check(r)
	if ok {
		return true, "", ""
	}
	return false, reason, gateCatalog().Render(key, args, g.resolveLocale(r).ResolvedTag)
}

// resolveLocale is the request's negotiated locale. A nil gate -- never built
// by NewGate -- still refuses, in the default locale, rather than panicking in
// front of a route it was meant to protect.
func (g *Gate) resolveLocale(r *http.Request) i18n.Context {
	if g == nil || g.locale == nil {
		return (&i18n.Negotiator{Manifest: i18n.DefaultManifest(), Available: gateCatalog().Locales()}).Resolve(r)
	}
	return g.locale.Resolve(r)
}

func (g *Gate) report(ip, outcome string) {
	if g != nil && g.audit != nil {
		g.audit(ip, outcome)
	}
}

func (g *Gate) throttled(ip string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.keepRecent(ip, g.now().Add(-FailWindow))) >= MaxFailedAttempts
}

// recordFail prunes this source on every call and asks gatethrottle to sweep
// other sources at most once per window, bounding growth from rotated addresses.
func (g *Gate) recordFail(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	gatethrottle.Record(g.fails, ip, g.now(), FailWindow, &g.lastSweep)
}

// keepRecent drops this source's expired attempts, and the source once none
// remain. Must be called with the lock held.
func (g *Gate) keepRecent(ip string, cutoff time.Time) []time.Time {
	return gatethrottle.KeepRecent(g.fails, ip, cutoff)
}

// clientIP keys the throttle and the audit on the address, with the brackets
// of an IPv6 literal removed.
func clientIP(r *http.Request) string { return gatethrottle.ClientIP(r) }

var (
	gateOnce     sync.Once
	gateMessages *i18n.Catalog
)

// gateCatalog decodes the SDK's embedded auth catalogs once.
func gateCatalog() *i18n.Catalog {
	gateOnce.Do(func() {
		gateMessages = i18n.NewCatalog(nil)
		for tag, domains := range catalog.Catalogs {
			for domain, data := range domains {
				if err := gateMessages.Register(tag, domain, data); err != nil {
					panic(err)
				}
			}
		}
	})
	return gateMessages
}
