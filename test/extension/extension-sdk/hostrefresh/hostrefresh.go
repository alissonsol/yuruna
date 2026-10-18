// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package hostrefresh is the remote authorization boundary for a host refresh:
// the versioned refresh proof a host verifies, the signer that mints it, the
// secret formats both ends read, and the credential gate in front of the one
// route that may mint.
//
// It exists apart from labgate because the legacy control proof cannot carry
// this authority. That proof is lab-wide, binds nothing but an expiry, and is
// minted publicly by the aggregator's host and stash redirects; its session
// cookie cannot tell which door a caller came through. A refresh can stop a
// runner and restart a hypervisor, so its proof is bound to one host, one
// request identity, one tier and ceiling, and a short lifetime, and it is
// signed by a key only an operator-provisioned signing authority can derive.
package hostrefresh

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"yuruna.com/test/extension/extension-sdk/pool"
)

const (
	// ProofHeader carries the refresh proof from pool-control to a host. It is
	// never X-Yuruna-Control: three parsers read the text before the first dot
	// there as a unix expiry, so a versioned proof in that slot would read as
	// malformed or expired rather than as a different credential.
	ProofHeader = "X-Yuruna-Refresh-Proof"

	// CredentialHeader carries the operator's refresh credential to
	// pool-control. It is a header of its own so that neither a lab session
	// cookie nor an Authorization bearer can ever satisfy the refresh gate.
	CredentialHeader = "X-Yuruna-Refresh-Credential"

	// ProofVersion is the first field of every proof this package mints and
	// the only one it accepts.
	ProofVersion = "yhr1"

	// Secret prefixes. Each secret names its own kind, so a secret placed in
	// the wrong slot is a parse refusal rather than a silent acceptance.
	AuthorityPrefix  = "yhra1"
	CredentialPrefix = "yhrc1"
	HostKeyPrefix    = "yhrk1"

	// SecretBytes is the length of every refresh secret.
	SecretBytes = 32

	// ProofTTL is how long a minted proof lives. It covers one round trip to a
	// host plus one same-id resend; a retry after that mints again.
	ProofTTL = 2 * time.Minute

	// MaxLifetime is the longest issue-to-expiry span a verifier accepts, so a
	// leaked signing path cannot mint a long-lived pass.
	MaxLifetime = 5 * time.Minute

	// Skew is the two-sided clock tolerance between the minting service and a
	// host. It is explicit so an expiry test is deterministic, and two-sided so
	// a host clock running ahead is tolerated as much as one running behind.
	Skew = time.Minute

	// MaxWireBytes bounds a proof before it is parsed at all.
	MaxWireBytes = 512

	// Tiers. Only the restart tier is ever accepted remotely.
	TierRestart = "restart"
	TierFull    = "full"
)

// Verification verdicts, spelled as the wire codes every verifier returns.
const (
	ReasonOK                      = "ok"
	ReasonProofMissing            = "refresh_proof_missing"
	ReasonProofMalformed          = "refresh_proof_malformed"
	ReasonProofVersionUnsupported = "refresh_proof_version_unsupported"
	ReasonProofInvalid            = "refresh_proof_invalid"
	ReasonProofHostMismatch       = "refresh_proof_host_mismatch"
	ReasonProofRequestMismatch    = "refresh_proof_request_mismatch"
	ReasonProofPolicyMismatch     = "refresh_proof_policy_mismatch"
	ReasonProofLifetimeInvalid    = "refresh_proof_lifetime_invalid"
	ReasonProofNotYetValid        = "refresh_proof_not_yet_valid"
	ReasonProofExpired            = "refresh_proof_expired"
)

// Host-side authorization verdicts that precede the proof check. The host's
// verifier produces them; they are declared here so every Go reader of a host
// reply spells them once.
const (
	ReasonRemoteUnqualified   = "refresh_remote_unqualified"
	ReasonTierNotRemote       = "refresh_tier_not_remote"
	ReasonRemoteUnprovisioned = "refresh_remote_unprovisioned"
	ReasonRemoteKeyInvalid    = "refresh_remote_key_invalid"
	ReasonVerifierFailed      = "refresh_verifier_failed"
)

// Domain-separation labels. Each HMAC input starts with a label no other input
// can produce, so a tag or a derived key can never double as a proof.
const (
	hostKeyLabel      = "yuruna-host-refresh|host-key|v1|"
	proofLabel        = "yuruna-host-refresh|v1|host-refresh|"
	keyTagLabel       = "yuruna-host-refresh|tag|v1"
	authorityTagLabel = "yuruna-host-refresh|authority-tag|v1"
)

// maxSecretFileBytes bounds a secret file read; every secret is one short line.
const maxSecretFileBytes = 4096

// remoteRungCeiling is the highest rung Order a remote request may name: the
// restart tier. Rungs above it change host settings or packages and are
// local-only.
const remoteRungCeiling = 4

var (
	hostIDRE    = regexp.MustCompile(`^[0-9a-f]{32}$`)
	requestIDRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	// unixRE refuses leading zeros, signs and anything past 19 digits, so one
	// instant has exactly one spelling and the MAC input cannot be varied.
	unixRE    = regexp.MustCompile(`^(0|[1-9][0-9]{0,18})$`)
	versionRE = regexp.MustCompile(`^yhr[0-9]+$`)
	// b64 is unpadded base64url that also refuses non-zero trailing bits, so
	// one byte string has exactly one textual form.
	b64 = base64.RawURLEncoding.Strict()
	// b64AlphabetRE is checked before decoding because the decoder skips CR
	// and LF even in strict mode, which would let a line break inside a
	// secret or a proof pass as the same value.
	b64AlphabetRE = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
)

// decodeB64u decodes exactly one canonical unpadded base64url string.
func decodeB64u(s string) ([]byte, bool) {
	if !b64AlphabetRE.MatchString(s) {
		return nil, false
	}
	b, err := b64.DecodeString(s)
	return b, err == nil
}

// Secret errors. A caller branches on these with errors.Is.
var (
	ErrSecretMissing         = errors.New("refresh secret file is missing")
	ErrSecretOpenPermissions = errors.New("refresh secret file is readable by other users")
	ErrSecretNotRegular      = errors.New("refresh secret path is not a regular file")
	ErrSecretMalformed       = errors.New("refresh secret is malformed")
)

// ErrInvalidClaim is returned when a proof field fails validation before
// minting.
var ErrInvalidClaim = errors.New("invalid refresh proof field")

// Claims are the fields a refresh proof binds.
type Claims struct {
	HostID     string
	RequestID  string
	Tier       string
	MaxRung    string
	IssuedUnix int64
	ExpiryUnix int64
}

// CanonicalHostID lowercases a host id and removes dashes, and reports whether
// the result is the canonical 32-hex form. The dashed rendering dashboards show
// and the bare form hosts write therefore name the same host.
func CanonicalHostID(s string) (string, bool) {
	c := strings.ToLower(strings.ReplaceAll(s, "-", ""))
	return c, hostIDRE.MatchString(c)
}

// ValidRequestID reports whether s is a canonical lowercase UUID in the
// 8-4-4-4-12 form. One spelling per request is what keeps a retry from ever
// becoming a second request.
func ValidRequestID(s string) bool { return requestIDRE.MatchString(s) }

// NewRequestID returns a random version-4 UUID in canonical form.
func NewRequestID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := fmt.Sprintf("%x", b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32], nil
}

func ValidTier(s string) bool { return s == TierRestart || s == TierFull }

func ValidRung(s string) bool {
	_, ok := pool.RefreshRungOrder(s)
	return ok
}

// ValidRemoteRung reports whether s names a rung a remote request may use as
// its ceiling: Order 0 through 4, the restart tier.
func ValidRemoteRung(s string) bool {
	order, ok := pool.RefreshRungOrder(s)
	return ok && order <= remoteRungCeiling
}

// RemoteRungNames returns the rungs a remote request may name, in Order.
func RemoteRungNames() []string {
	return pool.RefreshRungNames()[:remoteRungCeiling+1]
}

func mac(key []byte, message string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(message))
	return h.Sum(nil)
}

// DeriveHostKey is HMAC-SHA256(authority, label + hostID). Each host holds only
// its own derived key, so a compromised host can verify proofs for itself but
// can mint nothing for any other host. Derivation accepts any non-empty
// authority; the 32-byte floor is enforced where an authority is loaded.
func DeriveHostKey(authority []byte, hostID string) ([]byte, error) {
	if len(authority) == 0 {
		return nil, fmt.Errorf("%w: empty signing authority", ErrInvalidClaim)
	}
	if !hostIDRE.MatchString(hostID) {
		return nil, fmt.Errorf("%w: hostId", ErrInvalidClaim)
	}
	return mac(authority, hostKeyLabel+hostID), nil
}

// KeyTag is a non-secret name for a host key, for provisioning output and
// status only. It is an HMAC under the key over a fixed label, so it cannot be
// used to forge a proof or recover the key.
func KeyTag(key []byte) string { return b64.EncodeToString(mac(key, keyTagLabel)) }

// AuthorityTag is the non-secret name for a signing authority.
func AuthorityTag(authority []byte) string {
	return b64.EncodeToString(mac(authority, authorityTagLabel))
}

func proofMessage(hostID, requestID, tier, maxRung, iat, exp string) string {
	return proofLabel + hostID + "|" + requestID + "|" + tier + "|" + maxRung + "|" + iat + "|" + exp
}

// Proof is the deterministic core of the refresh proof:
//
//	yhr1.<hostId>.<requestId>.<tier>.<maxRung>.<iat>.<exp>.<b64u HMAC>
//
// with the HMAC under the host key over the same fields. It validates each
// field's syntax but not the lifetime, so the verifier's lifetime refusals can
// be exercised with real signatures; Signer.Mint is the policy-bearing mint.
func Proof(hostKey []byte, c Claims) (string, error) {
	if len(hostKey) == 0 {
		return "", fmt.Errorf("%w: empty host key", ErrInvalidClaim)
	}
	switch {
	case !hostIDRE.MatchString(c.HostID):
		return "", fmt.Errorf("%w: hostId", ErrInvalidClaim)
	case !ValidRequestID(c.RequestID):
		return "", fmt.Errorf("%w: requestId", ErrInvalidClaim)
	case !ValidTier(c.Tier):
		return "", fmt.Errorf("%w: tier", ErrInvalidClaim)
	case !ValidRung(c.MaxRung):
		return "", fmt.Errorf("%w: maxRung", ErrInvalidClaim)
	case c.IssuedUnix < 0 || c.ExpiryUnix < 0:
		return "", fmt.Errorf("%w: instant", ErrInvalidClaim)
	}
	iat := strconv.FormatInt(c.IssuedUnix, 10)
	exp := strconv.FormatInt(c.ExpiryUnix, 10)
	sum := mac(hostKey, proofMessage(c.HostID, c.RequestID, c.Tier, c.MaxRung, iat, exp))
	return strings.Join([]string{ProofVersion, c.HostID, c.RequestID, c.Tier, c.MaxRung, iat, exp, b64.EncodeToString(sum)}, "."), nil
}

// parseUnix reads one instant field in its single canonical spelling.
func parseUnix(s string) (int64, bool) {
	if !unixRE.MatchString(s) {
		return 0, false
	}
	v, err := strconv.ParseInt(s, 10, 64)
	return v, err == nil
}

// Verify judges a refresh proof against what the host itself knows: its own id
// and the request it was asked to admit. The order is fixed and shared with the
// PowerShell verifier: missing, then shape, then the MAC over the fields as
// received, then host, request, policy, lifetime, and finally the clock.
// Checking the MAC before any claim means a forged proof learns nothing about
// which claim would have been wrong.
//
// now is explicit and the skew is two-sided: nothing here reads a clock, so
// every expiry and skew boundary is testable. The reason is always one of the
// Reason constants; the claims are returned once the proof has parsed.
func Verify(hostKey []byte, wire string, want Claims, now time.Time, maxLifetime, skew time.Duration) (Claims, string) {
	if wire == "" {
		return Claims{}, ReasonProofMissing
	}
	if len(wire) > MaxWireBytes {
		return Claims{}, ReasonProofMalformed
	}
	f := strings.Split(wire, ".")
	if versionRE.MatchString(f[0]) && f[0] != ProofVersion {
		return Claims{}, ReasonProofVersionUnsupported
	}
	if len(f) != 8 || f[0] != ProofVersion {
		return Claims{}, ReasonProofMalformed
	}
	iat, okIat := parseUnix(f[5])
	exp, okExp := parseUnix(f[6])
	given, okMac := decodeB64u(f[7])
	if !hostIDRE.MatchString(f[1]) || !ValidRequestID(f[2]) || !ValidTier(f[3]) || !ValidRung(f[4]) ||
		!okIat || !okExp || !okMac || len(given) != sha256.Size {
		return Claims{}, ReasonProofMalformed
	}
	got := Claims{HostID: f[1], RequestID: f[2], Tier: f[3], MaxRung: f[4], IssuedUnix: iat, ExpiryUnix: exp}
	if len(hostKey) == 0 || !hmac.Equal(mac(hostKey, proofMessage(f[1], f[2], f[3], f[4], f[5], f[6])), given) {
		return got, ReasonProofInvalid
	}
	wantHost, _ := CanonicalHostID(want.HostID)
	if got.HostID != wantHost {
		return got, ReasonProofHostMismatch
	}
	if got.RequestID != want.RequestID {
		return got, ReasonProofRequestMismatch
	}
	if got.Tier != want.Tier || got.MaxRung != want.MaxRung {
		return got, ReasonProofPolicyMismatch
	}
	life := int64(maxLifetime / time.Second)
	if exp <= iat || exp-iat > life {
		return got, ReasonProofLifetimeInvalid
	}
	sk := int64(skew / time.Second)
	if sk < 0 {
		sk = 0
	}
	// Clamped so the differences below cannot overflow: both instants are
	// non-negative, so neither subtraction can leave the int64 range.
	nowUnix := now.Unix()
	if nowUnix < 0 {
		nowUnix = 0
	}
	if iat > nowUnix && iat-nowUnix > sk {
		return got, ReasonProofNotYetValid
	}
	if nowUnix > exp && nowUnix-exp > sk {
		return got, ReasonProofExpired
	}
	return got, ReasonOK
}

// ParseSecret reads one "<prefix>.<b64u>" secret: the exact prefix, strict
// unpadded base64url, and exactly SecretBytes of key material. No whitespace
// is accepted anywhere; LoadSecretFile strips the one line terminator a file
// carries.
func ParseSecret(text, prefix string) ([]byte, error) {
	head, body, found := strings.Cut(text, ".")
	if !found || head != prefix {
		return nil, fmt.Errorf("%w: expected one %s secret", ErrSecretMalformed, prefix)
	}
	b, ok := decodeB64u(body)
	if !ok || len(b) != SecretBytes {
		return nil, fmt.Errorf("%w: expected %d bytes of base64url after %s", ErrSecretMalformed, SecretBytes, prefix)
	}
	return b, nil
}

// FormatSecret renders key material as one "<prefix>.<b64u>" line.
func FormatSecret(prefix string, b []byte) string { return prefix + "." + b64.EncodeToString(b) }

// ParseHostKey reads one "yhrk1.<hostId>.<b64u>" verifier key and returns the
// host it was derived for, which a verifier must compare with its own id.
func ParseHostKey(text string) (string, []byte, error) {
	f := strings.Split(text, ".")
	if len(f) != 3 || f[0] != HostKeyPrefix || !hostIDRE.MatchString(f[1]) {
		return "", nil, fmt.Errorf("%w: expected one %s.<hostId>.<key> line", ErrSecretMalformed, HostKeyPrefix)
	}
	b, ok := decodeB64u(f[2])
	if !ok || len(b) != SecretBytes {
		return "", nil, fmt.Errorf("%w: expected %d bytes of base64url after the host id", ErrSecretMalformed, SecretBytes)
	}
	return f[1], b, nil
}

// FormatHostKey renders a host verifier key line.
func FormatHostKey(hostID string, key []byte) (string, error) {
	if !hostIDRE.MatchString(hostID) {
		return "", fmt.Errorf("%w: hostId", ErrInvalidClaim)
	}
	if len(key) != SecretBytes {
		return "", fmt.Errorf("%w: host key length", ErrInvalidClaim)
	}
	return HostKeyPrefix + "." + hostID + "." + b64.EncodeToString(key), nil
}

// LoadSecretFile reads one secret file. It refuses a missing file, anything
// that is not a regular file (a link could point the secret slot at another
// file), a file other users can read on Unix, and any content other than one
// secret line with an optional line terminator. The returned error never
// carries file content.
func LoadSecretFile(path, prefix string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w: %s", ErrSecretMissing, path)
		}
		return nil, fmt.Errorf("%w: %s: %v", ErrSecretMissing, path, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%w: %s", ErrSecretNotRegular, path)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("%w: %s has mode %#o", ErrSecretOpenPermissions, path, info.Mode().Perm())
	}
	fh, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("%w: %s: %v", ErrSecretMissing, path, err)
	}
	defer fh.Close()
	raw, err := io.ReadAll(io.LimitReader(fh, maxSecretFileBytes+1))
	if err != nil || len(raw) > maxSecretFileBytes {
		return nil, fmt.Errorf("%w: %s", ErrSecretMalformed, path)
	}
	text := string(raw)
	if t, ok := strings.CutSuffix(text, "\r\n"); ok {
		text = t
	} else if t, ok := strings.CutSuffix(text, "\n"); ok {
		text = t
	}
	b, perr := ParseSecret(text, prefix)
	if perr != nil {
		return nil, fmt.Errorf("%w: %s", ErrSecretMalformed, path)
	}
	return b, nil
}

// Signer mints refresh proofs from the signing authority. It is the only
// component that can, and it lives only where an operator provisioned the
// authority explicitly.
type Signer struct {
	authority []byte
	tag       string
}

// NewSigner refuses an authority shorter than SecretBytes: a weak authority
// would make every derived host key guessable at once.
func NewSigner(authority []byte) (*Signer, error) {
	if len(authority) < SecretBytes {
		return nil, fmt.Errorf("%w: a signing authority needs at least %d bytes", ErrSecretMalformed, SecretBytes)
	}
	a := append([]byte(nil), authority...)
	return &Signer{authority: a, tag: AuthorityTag(a)}, nil
}

func (s *Signer) HostKey(hostID string) ([]byte, error) { return DeriveHostKey(s.authority, hostID) }

// AuthorityTag is the signer's non-secret name.
func (s *Signer) AuthorityTag() string { return s.tag }

// Mint issues a proof valid from now for ProofTTL. Every field is validated
// here; the remote tier and rung allowlist is not, because the route that
// calls Mint applies it and reports its own refusal.
func (s *Signer) Mint(hostID, requestID, tier, maxRung string, now time.Time) (string, Claims, error) {
	key, err := s.HostKey(hostID)
	if err != nil {
		return "", Claims{}, err
	}
	iat := now.Unix()
	if iat < 0 {
		return "", Claims{}, fmt.Errorf("%w: instant", ErrInvalidClaim)
	}
	c := Claims{HostID: hostID, RequestID: requestID, Tier: tier, MaxRung: maxRung,
		IssuedUnix: iat, ExpiryUnix: iat + int64(ProofTTL/time.Second)}
	wire, err := Proof(key, c)
	if err != nil {
		return "", Claims{}, err
	}
	return wire, c, nil
}
