// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42a42558-6b05-478d-8842-dcb7037a297c

// Package controlproof verifies the shared host-control credential wire format.
package controlproof

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func proofMAC(token string, expiry int64) []byte {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|" + strconv.FormatInt(expiry, 10)))
	return mac.Sum(nil)
}

// Proof returns the retired unbound form "<expiry>.<base64 HMAC>", or an empty
// string without a usable key. No verifier accepts it: it names no target, so it
// would open every host and service that shares the key. It is still minted for
// the shared golden vector, and Mint's answer tells a caller whether it holds a
// usable key.
func Proof(token string, expiry int64) string {
	if strings.TrimSpace(token) == "" {
		return ""
	}
	return strconv.FormatInt(expiry, 10) + "." + base64.StdEncoding.EncodeToString(proofMAC(token, expiry))
}

// Mint creates the unbound form expiring ttl from now, or an empty string
// without a usable key.
func Mint(token string, ttl time.Duration) string {
	return Proof(token, time.Now().Add(ttl).Unix())
}

// A bound proof names the one target it unlocks, its audience: a host id for a
// host's /control/* routes, or "svc-<service>" for an extension service's UI.
// The key is pool-wide, so a proof that named no target, copied from one host's
// address bar (a screenshot, a pasted link), would work on every host for its
// lifetime; a bound one works only where it was meant to. The audience sits
// between the expiry and the MAC, so a page reads the deadline off the first
// field of every form.
var audiencePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,80}$`)

// ValidAudience reports whether a is a well-formed audience.
func ValidAudience(a string) bool { return audiencePattern.MatchString(a) }

func boundMAC(token, audience string, expiry int64) []byte {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|v2|" + audience + "|" + strconv.FormatInt(expiry, 10)))
	return mac.Sum(nil)
}

// ProofFor returns the bound proof "<expiry>.<audience>.<base64 HMAC>", or an
// empty string without a usable key or with a malformed audience.
func ProofFor(token, audience string, expiry int64) string {
	if strings.TrimSpace(token) == "" || !ValidAudience(audience) {
		return ""
	}
	return strconv.FormatInt(expiry, 10) + "." + audience + "." + base64.StdEncoding.EncodeToString(boundMAC(token, audience, expiry))
}

// MintFor creates a bound proof expiring ttl from now.
func MintFor(token, audience string, ttl time.Duration) string {
	return ProofFor(token, audience, time.Now().Add(ttl).Unix())
}

// VerifyFor accepts a bound proof whose audience equals audience, ignoring
// case, only inside the inclusive window now <= expiry <= now+maxTTL. The MAC
// covers the audience and the canonical decimal expiry, using the token's exact
// bytes, and is compared in constant time. An empty audience accepts a bound
// proof for any target; only a verifier answering for a caller that names no
// audience uses that. The unbound form, which names no target, is refused like
// any other malformed, expired or mismatched input.
func VerifyFor(token, wire, audience string, now time.Time, maxTTL time.Duration) bool {
	parts := strings.Split(wire, ".")
	if len(parts) != 3 || strings.TrimSpace(token) == "" || !ValidAudience(parts[1]) {
		return false
	}
	if audience != "" && !strings.EqualFold(parts[1], audience) {
		return false
	}
	expiry, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return false
	}
	unix := now.Unix()
	if expiry < unix || expiry > unix+int64(maxTTL/time.Second) {
		return false
	}
	given, err := base64.StdEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	return hmac.Equal(boundMAC(token, parts[1], expiry), given)
}

// A scoped proof narrows a bound one to one class of routes on its target:
// "<expiry>.<audience>.<scope>.<base64 HMAC>". The pool-wide pause and continue
// needs a host's four pause and resume routes and nothing else, so the proof
// that carries it should not also save that host's configuration or start a
// cycle. ScopePause is that class. A verifier that predates scopes refuses the
// four-field form, and VerifyFor never accepts it.
const ScopePause = "pause"

var scopePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// ValidScope reports whether s is a well-formed scope.
func ValidScope(s string) bool { return scopePattern.MatchString(s) }

func scopedMAC(token, audience, scope string, expiry int64) []byte {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte("yuruna-control|proof|v3|" + audience + "|" + scope + "|" + strconv.FormatInt(expiry, 10)))
	return mac.Sum(nil)
}

// ProofForScope returns the scoped proof, or an empty string without a usable
// key, with a malformed audience or with a malformed scope.
func ProofForScope(token, audience, scope string, expiry int64) string {
	if strings.TrimSpace(token) == "" || !ValidAudience(audience) || !ValidScope(scope) {
		return ""
	}
	return strconv.FormatInt(expiry, 10) + "." + audience + "." + scope + "." + base64.StdEncoding.EncodeToString(scopedMAC(token, audience, scope, expiry))
}

// MintForScope creates a scoped proof expiring ttl from now.
func MintForScope(token, audience, scope string, ttl time.Duration) string {
	return ProofForScope(token, audience, scope, time.Now().Add(ttl).Unix())
}

// VerifyScoped accepts a scoped proof whose audience equals audience, ignoring
// case, and whose scope is one of scopes, inside the window VerifyFor enforces.
// It accepts nothing else: a caller that also takes the bound form asks
// VerifyFor for it.
func VerifyScoped(token, wire, audience string, scopes []string, now time.Time, maxTTL time.Duration) bool {
	parts := strings.Split(wire, ".")
	if len(parts) != 4 || strings.TrimSpace(token) == "" || !ValidAudience(parts[1]) || !ValidScope(parts[2]) {
		return false
	}
	if !strings.EqualFold(parts[1], audience) {
		return false
	}
	allowed := false
	for _, s := range scopes {
		if parts[2] == s {
			allowed = true
			break
		}
	}
	if !allowed {
		return false
	}
	expiry, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return false
	}
	unix := now.Unix()
	if expiry < unix || expiry > unix+int64(maxTTL/time.Second) {
		return false
	}
	given, err := base64.StdEncoding.DecodeString(parts[3])
	if err != nil {
		return false
	}
	return hmac.Equal(scopedMAC(token, parts[1], parts[2], expiry), given)
}
