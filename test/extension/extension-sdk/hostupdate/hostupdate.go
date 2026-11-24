// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42ed8835-e46f-46f9-860e-a7df722b2045

// Package hostupdate is the remote authorization boundary for a host update:
// the yup1 proof a host verifies with pool-control's public key, the signer
// that mints it, and the key formats both ends read.
//
// It exists apart from hostrepair because the repair proof is an HMAC under a
// key the host must keep secret, and the checks that such a key is private are
// qualified only on Linux. A yup1 proof is an RSA signature, so a host holds
// only a public key and no host type is barred by where it can keep a secret.
// What a host relies on instead is that only its own account can replace the
// record that holds the key.
package hostupdate

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"yuruna.com/test/extension/extension-sdk/hostrepair"
)

const (
	// ProofHeader carries the update proof from pool-control to a host. It is
	// a header of its own for the reason the repair proof has one: three
	// parsers read X-Yuruna-Control as an expiry first.
	ProofHeader = "X-Yuruna-Update-Proof"

	// ProofVersion is the first field of every proof this package mints and
	// the only one it accepts. The version fixes the algorithm: RSA PKCS#1
	// v1.5 with SHA-256.
	ProofVersion = "yup1"

	// ProofTTL is how long a minted proof lives: one round trip to a host
	// plus one same-id resend.
	ProofTTL = 2 * time.Minute

	// MaxLifetime is the longest issue-to-expiry span a verifier accepts.
	MaxLifetime = 5 * time.Minute

	// Skew is the two-sided clock tolerance between pool-control and a host.
	Skew = time.Minute

	// MaxWireBytes bounds a proof before it is parsed. A 3072-bit signature
	// is 512 characters of base64url; the fields add under 200.
	MaxWireBytes = 1024

	// MinKeyBits is the smallest RSA modulus either end accepts.
	MinKeyBits = 3072

	// Scopes.
	ScopeRestart = "restart"
	ScopeFull    = "full"

	// Drain bounds, in seconds, and the default a request that names none
	// gets on the host.
	MinDrainSeconds     = 60
	MaxDrainSeconds     = 21600
	DefaultDrainSeconds = 7200

	// PublicKeyPrefix names a one-line public key: the prefix, a dot and the
	// unpadded base64url of the SubjectPublicKeyInfo DER.
	PublicKeyPrefix = "yupk1"

	// messageLabel begins every signed message, so a signature over anything
	// else this key may ever sign cannot double as an update proof.
	messageLabel = "yuruna-host-update|v2|"

	// maxKeyFileBytes bounds a key file read; a 4096-bit PKCS#8 PEM is under
	// 3.3 KiB.
	maxKeyFileBytes = 16384
)

// Verification verdicts, spelled as the wire codes every verifier returns.
const (
	ReasonOK                      = "ok"
	ReasonProofMissing            = "update_proof_missing"
	ReasonProofMalformed          = "update_proof_malformed"
	ReasonProofVersionUnsupported = "update_proof_version_unsupported"
	ReasonProofInvalid            = "update_proof_invalid"
	ReasonProofHostMismatch       = "update_proof_host_mismatch"
	ReasonProofRequestMismatch    = "update_proof_request_mismatch"
	ReasonProofPolicyMismatch     = "update_proof_policy_mismatch"
	ReasonProofLifetimeInvalid    = "update_proof_lifetime_invalid"
	ReasonProofNotYetValid        = "update_proof_not_yet_valid"
	ReasonProofExpired            = "update_proof_expired"
)

// Host-side verdicts that precede the proof check, declared here so every Go
// reader of a host reply spells them once.
const (
	ReasonRemoteUnprovisioned = "update_remote_unprovisioned"
	ReasonRemoteInvalid       = "update_remote_invalid"
	ReasonVerifierFailed      = "update_verifier_failed"
)

var (
	// unixRE and drainRE refuse leading zeros and signs, so one value has one
	// spelling and the signed message cannot be varied.
	unixRE    = regexp.MustCompile(`^(0|[1-9][0-9]{0,18})$`)
	drainRE   = regexp.MustCompile(`^[1-9][0-9]{1,4}$`)
	commitRE  = regexp.MustCompile(`^[0-9a-f]{7,40}$`)
	versionRE = regexp.MustCompile(`^yup[0-9]+$`)
	b64       = base64.RawURLEncoding.Strict()
	// b64AlphabetRE is checked before decoding because the decoder skips CR
	// and LF even in strict mode.
	b64AlphabetRE = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
)

// Key errors. A caller branches on these with errors.Is.
var (
	ErrKeyMissing         = errors.New("update signing key file is missing")
	ErrKeyOpenPermissions = errors.New("update signing key file is readable by other users")
	ErrKeyNotRegular      = errors.New("update signing key path is not a regular file")
	ErrKeyMalformed       = errors.New("update signing key is malformed")
	ErrKeyTooSmall        = errors.New("update signing key is too small")
)

// ErrInvalidClaim is returned when a proof field fails validation before
// signing.
var ErrInvalidClaim = errors.New("invalid update proof field")

// Claims are the fields a yup1 proof binds. ExpectCommit is empty when the
// request names none.
type Claims struct {
	HostID       string
	RequestID    string
	Scope        string
	DrainSeconds int
	ExpectCommit string
	IssuedUnix   int64
	ExpiryUnix   int64
}

// ValidScope reports whether s is a scope a request may name.
func ValidScope(s string) bool { return s == ScopeRestart || s == ScopeFull }

// ValidDrainSeconds reports whether n is inside the drain bounds.
func ValidDrainSeconds(n int) bool { return n >= MinDrainSeconds && n <= MaxDrainSeconds }

// ValidExpectCommit reports whether s is empty or 7 to 40 lowercase hex digits.
func ValidExpectCommit(s string) bool { return s == "" || commitRE.MatchString(s) }

func decodeB64u(s string) ([]byte, bool) {
	if !b64AlphabetRE.MatchString(s) {
		return nil, false
	}
	b, err := b64.DecodeString(s)
	return b, err == nil
}

func parseUnix(s string) (int64, bool) {
	if !unixRE.MatchString(s) {
		return 0, false
	}
	v, err := strconv.ParseInt(s, 10, 64)
	return v, err == nil
}

// Message is the exact text a yup1 signature covers:
//
//	yuruna-host-update|v2|<hostId>|<requestId>|<scope>|<drainSeconds>|<expectCommit or empty>|<issued>|<expiry>
//
// A field is never escaped: every field's syntax excludes the separator.
func Message(c Claims) string {
	return messageLabel + strings.Join([]string{c.HostID, c.RequestID, c.Scope, strconv.Itoa(c.DrainSeconds), c.ExpectCommit,
		strconv.FormatInt(c.IssuedUnix, 10), strconv.FormatInt(c.ExpiryUnix, 10)}, "|")
}

func validateClaims(c Claims) error {
	switch {
	case !hostIDValid(c.HostID):
		return fmt.Errorf("%w: hostId", ErrInvalidClaim)
	case !hostrepair.ValidRequestID(c.RequestID):
		return fmt.Errorf("%w: requestId", ErrInvalidClaim)
	case !ValidScope(c.Scope):
		return fmt.Errorf("%w: scope", ErrInvalidClaim)
	case !ValidDrainSeconds(c.DrainSeconds):
		return fmt.Errorf("%w: drainSeconds", ErrInvalidClaim)
	case !ValidExpectCommit(c.ExpectCommit):
		return fmt.Errorf("%w: expectCommit", ErrInvalidClaim)
	case c.IssuedUnix < 0 || c.ExpiryUnix < 0:
		return fmt.Errorf("%w: instant", ErrInvalidClaim)
	}
	return nil
}

// hostIDValid accepts only the canonical 32-hex form: a proof names one
// spelling of a host.
func hostIDValid(s string) bool {
	c, ok := hostrepair.CanonicalHostID(s)
	return ok && c == s
}

// Proof is the deterministic core of the update proof:
//
//	yup1.<hostId>.<requestId>.<scope>.<drainSeconds>.<expectCommit or empty>.<iat>.<exp>.<b64u signature>
//
// with the signature over Message of the same fields. PKCS#1 v1.5 padding is
// deterministic, so one key and one set of claims give one wire, which is what
// the shared golden vectors pin. The lifetime is not checked here, so the
// verifier's lifetime refusals can be exercised with real signatures;
// Signer.Mint is the policy-bearing mint.
func Proof(key *rsa.PrivateKey, c Claims) (string, error) {
	if key == nil {
		return "", fmt.Errorf("%w: no signing key", ErrInvalidClaim)
	}
	if err := validateClaims(c); err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(Message(c)))
	sig, err := rsa.SignPKCS1v15(nil, key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return strings.Join([]string{ProofVersion, c.HostID, c.RequestID, c.Scope, strconv.Itoa(c.DrainSeconds), c.ExpectCommit,
		strconv.FormatInt(c.IssuedUnix, 10), strconv.FormatInt(c.ExpiryUnix, 10), b64.EncodeToString(sig)}, "."), nil
}

// Verify judges an update proof against what the host itself knows: its own
// id and the effective values of the request it was asked to admit, defaults
// applied. The order is fixed and shared with the PowerShell verifier:
// missing, then shape, then the signature over the fields as received, then
// host, request, policy, lifetime, and finally the clock. Checking the
// signature before any claim means a forged proof learns nothing about which
// claim would have been wrong.
//
// now is explicit and the skew is two-sided: nothing here reads a clock.
func Verify(pub *rsa.PublicKey, wire string, want Claims, now time.Time, maxLifetime, skew time.Duration) (Claims, string) {
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
	if len(f) != 9 || f[0] != ProofVersion {
		return Claims{}, ReasonProofMalformed
	}
	iat, okIat := parseUnix(f[6])
	exp, okExp := parseUnix(f[7])
	sig, okSig := decodeB64u(f[8])
	drain := 0
	okDrain := drainRE.MatchString(f[4])
	if okDrain {
		drain, _ = strconv.Atoi(f[4])
		okDrain = ValidDrainSeconds(drain)
	}
	if !hostIDValid(f[1]) || !hostrepair.ValidRequestID(f[2]) || !ValidScope(f[3]) || !okDrain || !ValidExpectCommit(f[5]) ||
		!okIat || !okExp || !okSig || len(sig) == 0 {
		return Claims{}, ReasonProofMalformed
	}
	got := Claims{HostID: f[1], RequestID: f[2], Scope: f[3], DrainSeconds: drain, ExpectCommit: f[5], IssuedUnix: iat, ExpiryUnix: exp}
	sum := sha256.Sum256([]byte(Message(got)))
	if pub == nil || rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig) != nil {
		return got, ReasonProofInvalid
	}
	wantHost, _ := hostrepair.CanonicalHostID(want.HostID)
	if got.HostID != wantHost {
		return got, ReasonProofHostMismatch
	}
	if got.RequestID != want.RequestID {
		return got, ReasonProofRequestMismatch
	}
	if got.Scope != want.Scope || got.DrainSeconds != want.DrainSeconds || got.ExpectCommit != want.ExpectCommit {
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

// ParsePrivateKeyPEM reads exactly one PKCS#8 "PRIVATE KEY" block holding an
// RSA key of at least MinKeyBits, with nothing but whitespace around it.
func ParsePrivateKeyPEM(raw []byte) (*rsa.PrivateKey, error) {
	block, rest := pem.Decode(raw)
	if block == nil || block.Type != "PRIVATE KEY" || len(block.Headers) != 0 || strings.TrimSpace(string(rest)) != "" {
		return nil, fmt.Errorf("%w: expected one PKCS#8 PRIVATE KEY block", ErrKeyMalformed)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrKeyMalformed, err)
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%w: not an RSA key", ErrKeyMalformed)
	}
	if key.N.BitLen() < MinKeyBits {
		return nil, fmt.Errorf("%w: %d bits, at least %d required", ErrKeyTooSmall, key.N.BitLen(), MinKeyBits)
	}
	return key, nil
}

// LoadSigningKeyFile reads the signing key. It refuses a missing file,
// anything that is not a regular file, a file other users can read on Unix,
// an oversize file and any content ParsePrivateKeyPEM refuses. The returned
// error never carries file content.
func LoadSigningKeyFile(path string) (*rsa.PrivateKey, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("%w: %s", ErrKeyMissing, path)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%w: %s", ErrKeyNotRegular, path)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("%w: %s has mode %#o", ErrKeyOpenPermissions, path, info.Mode().Perm())
	}
	fh, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("%w: %s", ErrKeyMissing, path)
	}
	defer fh.Close()
	raw, err := io.ReadAll(io.LimitReader(fh, maxKeyFileBytes+1))
	if err != nil || len(raw) > maxKeyFileBytes {
		return nil, fmt.Errorf("%w: %s", ErrKeyMalformed, path)
	}
	key, err := ParsePrivateKeyPEM(raw)
	if err != nil {
		if errors.Is(err, ErrKeyTooSmall) {
			return nil, fmt.Errorf("%w: %s", ErrKeyTooSmall, path)
		}
		return nil, fmt.Errorf("%w: %s", ErrKeyMalformed, path)
	}
	return key, nil
}

// FormatPublicKey renders a public key as one "yupk1.<b64u SPKI DER>" line,
// the form a host's pool-control record carries.
func FormatPublicKey(pub *rsa.PublicKey) (string, error) {
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return "", err
	}
	return PublicKeyPrefix + "." + b64.EncodeToString(der), nil
}

// ParsePublicKey reads one "yupk1." line holding an RSA key of at least
// MinKeyBits.
func ParsePublicKey(text string) (*rsa.PublicKey, error) {
	head, body, found := strings.Cut(text, ".")
	if !found || head != PublicKeyPrefix {
		return nil, fmt.Errorf("%w: expected one %s line", ErrKeyMalformed, PublicKeyPrefix)
	}
	der, ok := decodeB64u(body)
	if !ok {
		return nil, fmt.Errorf("%w: expected base64url after %s", ErrKeyMalformed, PublicKeyPrefix)
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrKeyMalformed, err)
	}
	pub, ok := parsed.(*rsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("%w: not an RSA key", ErrKeyMalformed)
	}
	if pub.N.BitLen() < MinKeyBits {
		return nil, fmt.Errorf("%w: %d bits", ErrKeyTooSmall, pub.N.BitLen())
	}
	return pub, nil
}

// KeyTag is a non-secret name for a public key: the unpadded base64url of the
// SHA-256 of its SubjectPublicKeyInfo DER. An operator compares the tag
// pool-control logs with the one a host reports.
func KeyTag(pub *rsa.PublicKey) string {
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(der)
	return b64.EncodeToString(sum[:])
}

// Signer mints update proofs. It lives only where an operator provisioned the
// signing key explicitly.
type Signer struct {
	key *rsa.PrivateKey
	tag string
}

// NewSigner refuses a key smaller than MinKeyBits.
func NewSigner(key *rsa.PrivateKey) (*Signer, error) {
	if key == nil || key.N.BitLen() < MinKeyBits {
		return nil, ErrKeyTooSmall
	}
	return &Signer{key: key, tag: KeyTag(&key.PublicKey)}, nil
}

// KeyTag is the signer's non-secret name.
func (s *Signer) KeyTag() string { return s.tag }

// Mint issues a proof valid from now for ProofTTL. Every field is validated
// here.
func (s *Signer) Mint(hostID, requestID, scope string, drainSeconds int, expectCommit string, now time.Time) (string, Claims, error) {
	iat := now.Unix()
	if iat < 0 {
		return "", Claims{}, fmt.Errorf("%w: instant", ErrInvalidClaim)
	}
	c := Claims{HostID: hostID, RequestID: requestID, Scope: scope, DrainSeconds: drainSeconds, ExpectCommit: expectCommit,
		IssuedUnix: iat, ExpiryUnix: iat + int64(ProofTTL/time.Second)}
	wire, err := Proof(s.key, c)
	if err != nil {
		return "", Claims{}, err
	}
	return wire, c, nil
}
