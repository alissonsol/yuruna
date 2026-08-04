// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"download-agent-service/internal/config"
	"download-agent-service/internal/yex/pool"
)

// Entry states surfaced to the UI and to ensure clients.
const (
	StateFresh       = "fresh"
	StateStale       = "stale"
	StateDownloading = "downloading"
	StateFailed      = "failed"
	StateAbsent      = "absent"
	StateDeleting    = "deleting"
	StateReady       = "ready"
	StateUnsupported = "unsupported"
	StateUnavailable = "unavailable"
)

// Machine-readable refusal reasons, per the control-route convention.
const (
	ReasonPoolUnavailable = "pool-unavailable"
	ReasonLeaseReadOnly   = "lease-read-only"
	ReasonUnsupported     = "unsupported-image"
	// ReasonPoolWalkFailed stands in for any share-level failure while reading
	// the pool. The wire contract is a fixed token, so the underlying error goes
	// to the log and the audit record instead of into the response -- where it
	// would both break that contract and echo the pool path on an open route.
	ReasonPoolWalkFailed = "pool-walk-failed"
)

// Network budgets. Connect and header timeouts are short so an unreachable
// origin fails in seconds -- a stale lab must degrade fast, not after a long
// poll budget -- while the body stream itself is unbounded because a cold ISO
// legitimately takes hours.
const (
	dialTimeout           = 10 * time.Second
	responseHeaderTimeout = 30 * time.Second
	probeTimeout          = 60 * time.Second
	downloadDeadline      = 6 * time.Hour
)

// firstDownloadBackoff is how long a failed first-ever download is reported as
// failed before another attempt is made. Without it every poll from every host
// finds no flight, starts a fresh download and re-hammers a dead origin, while
// the client never sees anything but 202 for its whole poll budget.
const firstDownloadBackoff = 5 * time.Minute

// AuditEvent is one recorded pool mutation.
type AuditEvent struct {
	AtUTC    string
	Action   string
	HostType string
	ImageKey string
	Arch     string
	Variant  string
	Outcome  string
	Detail   string
}

// AuditFunc receives every mutation the agent performs. Best effort by
// contract: the mutation proceeds whether or not the sink succeeds.
type AuditFunc func(AuditEvent)

// Options configures an Agent.
type Options struct {
	PoolDir       string
	ScanInterval  time.Duration
	Freshness     time.Duration
	PrefetchLead  time.Duration
	AutoSeed      bool
	AggregatorURL string
	HostID        string
	VMName        string
	AgentVersion  string
	ProxyHTTP     string
	ProxyHTTPS    string
	ProxyCA       string
	// Fido locates the interpreter and the vendored script the best-effort
	// Windows 11 family needs. Its zero value searches the standard install
	// locations, so an agent VM that never installed them simply reports the
	// family unavailable.
	Fido  FidoConfig
	Audit AuditFunc
	// Transport replaces the direct transport for resolver fetches, probes,
	// checksums and byte downloads. It is what lets the suite drive the whole
	// pipeline against an in-process fixture instead of the real internet, so it
	// passes on an offline build VM.
	Transport http.RoundTripper
	// Now is injectable so scanner-window tests do not depend on wall clock.
	Now func() time.Time
	// Logf receives operational lines; nil discards them.
	Logf func(format string, args ...any)
}

// Fingerprint is what a host already holds locally, sent with ensure.
type Fingerprint struct {
	Filename  string `json:"filename"`
	ByteCount int64  `json:"byteCount"`
	SHA256    string `json:"sha256"`
}

// CatalogEntry is one row of the catalog: the on-disk facts plus the live view.
type CatalogEntry struct {
	HostType  string `json:"hostType"`
	ImageKey  string `json:"imageKey"`
	Arch      string `json:"arch"`
	Variant   string `json:"variant"`
	State     string `json:"state"`
	Supported bool   `json:"supported"`
	// BestEffort marks a family the agent may not be able to serve at all, and
	// UnavailableReason says why this agent cannot. Together they are what keeps
	// a row from reading as a plain "not fetched yet": a Windows 11 row on an
	// agent with no Fido is not waiting for a download, it is never going to get
	// one until an operator installs the tooling.
	BestEffort        bool   `json:"bestEffort,omitempty"`
	UnavailableReason string `json:"unavailableReason,omitempty"`
	UpstreamFilename  string `json:"upstreamFilename,omitempty"`
	Generation        string `json:"generation,omitempty"`
	FileURL           string `json:"fileUrl,omitempty"`
	SourceURL         string `json:"sourceUrl,omitempty"`
	SHA256            string `json:"sha256,omitempty"`
	ChecksumVerdict   string `json:"checksumVerdict,omitempty"`
	ByteCount         int64  `json:"byteCount,omitempty"`
	LastModified      string `json:"lastModified,omitempty"`
	// ResolvedVariant names the preference the bytes actually came from, which
	// differs from Variant whenever preference-with-fallback fired.
	ResolvedVariant string `json:"resolvedVariant,omitempty"`
	CurrentBytes    int64  `json:"currentBytes"`
	PreviousBytes   int64  `json:"previousBytes"`
	GenerationCount int    `json:"generationCount"`
	DownloadedAt    string `json:"downloadedAt,omitempty"`
	LastVerifiedAt  string `json:"lastVerifiedAt,omitempty"`
	ExpiresAt       string `json:"expiresAt,omitempty"`
	SecondsToExpiry int64  `json:"secondsToExpiry"`
	RefreshInFlight bool   `json:"refreshInFlight"`
	Phase           string `json:"phase,omitempty"`
	BytesDone       int64  `json:"bytesDone,omitempty"`
	BytesTotal      int64  `json:"bytesTotal,omitempty"`
	LastError       string `json:"lastError,omitempty"`
}

// Totals is the pool footprint, with the per-hostType subtotals that answer
// "what is eating the share".
type Totals struct {
	Images        int              `json:"images"`
	Bytes         int64            `json:"bytes"`
	CurrentBytes  int64            `json:"currentBytes"`
	PreviousBytes int64            `json:"previousBytes"`
	ByHostType    map[string]int64 `json:"byHostType"`
}

// Status is the agent's own snapshot for /api/v1/status and the UI header.
type Status struct {
	PoolDir             string      `json:"poolDir"`
	ImagesDir           string      `json:"imagesDir"`
	PoolAvailable       bool        `json:"poolAvailable"`
	ReadOnly            bool        `json:"readOnly"`
	LeaseHolder         string      `json:"leaseHolder,omitempty"`
	LeaseError          string      `json:"leaseError,omitempty"`
	ScanIntervalSeconds int         `json:"scanIntervalSeconds"`
	FreshnessSeconds    int         `json:"freshnessSeconds"`
	PrefetchLeadSeconds int         `json:"prefetchLeadSeconds"`
	LastScanUTC         string      `json:"lastScanUtc,omitempty"`
	NextScanUTC         string      `json:"nextScanUtc,omitempty"`
	Scans               int         `json:"scans"`
	StagingSwept        int         `json:"stagingSwept"`
	AutoSeed            bool        `json:"autoSeed"`
	LastSeed            SeedOutcome `json:"lastSeed"`
	InFlight            int         `json:"inFlight"`
	ProxyConfigured     bool        `json:"proxyConfigured"`
	// BestEffort answers, once for the whole agent, "can this agent serve the
	// families that depend on optional tooling". Without it an operator reading
	// the table can only guess whether a Windows row is idle or impossible.
	BestEffort []FamilyStatus `json:"bestEffort"`
	Totals     Totals         `json:"totals"`
}

// FamilyStatus is one best-effort family's usability on this agent.
type FamilyStatus struct {
	ImageKey  string `json:"imageKey"`
	Available bool   `json:"available"`
	Reason    string `json:"reason,omitempty"`
}

// EnsureResult is the ensure protocol's answer.
type EnsureResult struct {
	HTTPStatus      int          `json:"-"`
	State           string       `json:"state"`
	Reason          string       `json:"reason,omitempty"`
	LocalCurrent    bool         `json:"localCurrent,omitempty"`
	Stale           bool         `json:"stale,omitempty"`
	RefreshInFlight bool         `json:"refreshInFlight,omitempty"`
	BytesDone       int64        `json:"bytesDone,omitempty"`
	BytesTotal      int64        `json:"bytesTotal,omitempty"`
	Error           string       `json:"error,omitempty"`
	Image           CatalogEntry `json:"image"`
}

// Agent ties the pool store, the resolvers, the download pipeline, the lease and
// the auto-seed pass together.
type Agent struct {
	opts     Options
	store    *Store
	resolver *Resolver
	lease    *LeaseManager
	flights  *Group

	// direct answers resolver fetches, HEAD probes and checksum fetches. It is
	// NEVER proxied: the caching proxy pins .iso/.zip with
	// override-expire/override-lastmod and runs offline_mode after prewarm, so a
	// proxied probe would hand back frozen prewarm-era headers and certify
	// staleness as freshness forever.
	direct      *http.Client
	directBytes *http.Client
	proxyBytes  *http.Client

	// pool answers "which host types does this lab run", which is what the
	// auto-seed pass downloads for. It is a separate client from direct because
	// it talks to the aggregator rather than to an origin: the aggregator's leaf
	// is signed by the pool CA, which this guest has no trust-store entry for, so
	// a client built for public origins cannot complete that handshake at all.
	pool *pool.Client

	mu           sync.Mutex
	lastScan     time.Time
	nextScan     time.Time
	scans        int
	stagingSwept int
	lastSeed     SeedOutcome
	lastErr      map[string]string
	// lastErrAt stamps lastErr so a first-ever download that failed can be
	// reported as failed for a back-off window instead of being restarted by
	// every poll.
	lastErrAt map[string]time.Time
	deleting  map[string]bool
	// fidoErr remembers the last Fido resolve failure so the Windows family
	// reads as unavailable instead of as a failed image: hosts step over the
	// former silently and warn about the latter, and a resolver that cannot run
	// is not the host's problem to report. It expires so a transient failure
	// does not disable the family until the daemon is restarted.
	fidoErr        string
	fidoErrAt      time.Time
	knownHostTypes []string
}

// fidoFailureTTL is how long one failed Fido run keeps the Windows family marked
// unavailable.
const fidoFailureTTL = time.Hour

// NewAgent builds an Agent. base is the long-lived context every flight inherits
// from, so an ensure that answers 202 and returns leaves the download running.
func NewAgent(base context.Context, opts Options) (*Agent, error) {
	if opts.ScanInterval <= 0 {
		opts.ScanInterval = config.DefaultScanInterval
	}
	if opts.Freshness <= 0 {
		opts.Freshness = config.DefaultFreshness
	}
	if opts.PrefetchLead < 0 {
		opts.PrefetchLead = config.DefaultPrefetchLead
	}
	if opts.PrefetchLead >= opts.Freshness {
		// A lead at or beyond the freshness window makes DueForRefresh true for
		// every entry at every moment, so the scanner would re-verify the whole
		// pool on every pass forever.
		clamped := opts.Freshness / 2
		if opts.Logf != nil {
			opts.Logf("prefetch lead %s is not shorter than freshness %s, which would make every entry permanently due; clamped to %s",
				opts.PrefetchLead, opts.Freshness, clamped)
		}
		opts.PrefetchLead = clamped
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	var direct http.RoundTripper = newDirectTransport()
	if opts.Transport != nil {
		direct = opts.Transport
	}
	a := &Agent{
		opts:           opts,
		store:          NewStore(opts.PoolDir),
		direct:         &http.Client{Transport: direct, Timeout: probeTimeout},
		directBytes:    &http.Client{Transport: direct},
		flights:        NewGroup(base),
		lastErr:        map[string]string{},
		lastErrAt:      map[string]time.Time{},
		deleting:       map[string]bool{},
		knownHostTypes: append([]string(nil), HostTypes...),
	}
	poolOpts := pool.Options{BaseURL: opts.AggregatorURL, Timeout: probeTimeout, CacheTTL: pool.NoCache}
	if opts.Transport != nil {
		poolOpts.HTTPClient = &http.Client{Transport: opts.Transport, Timeout: probeTimeout}
	}
	a.pool = pool.New(poolOpts)
	a.resolver = NewResolver(a.direct)
	a.resolver.Fido = opts.Fido
	a.lease = NewLeaseManager(config.LeaseFileFor(opts.PoolDir), opts.HostID, opts.VMName,
		time.Duration(config.LeaseExpiryFactor)*opts.ScanInterval)

	if strings.TrimSpace(opts.ProxyHTTPS) != "" && strings.TrimSpace(opts.ProxyCA) == "" {
		// squid impersonates the origin on the ssl-bump port, so without its CA
		// in the root pool every HTTPS byte fetch fails TLS and falls back to
		// direct. The cache is then bypassed for every artifact with no other
		// symptom, which is why this is said out loud once at startup.
		a.logf("proxy-https %s is set with no --proxy-ca: HTTPS byte fetches cannot trust the ssl-bump port and will fall back to direct, bypassing the cache", opts.ProxyHTTPS)
	}

	pc, err := newProxyTransport(opts.ProxyHTTP, opts.ProxyHTTPS, opts.ProxyCA)
	if err != nil {
		// A broken proxy breadcrumb must not stop the agent: every byte fetch
		// falls back to direct anyway.
		a.logf("proxy transport unusable, downloads go direct: %v", err)
	} else if pc != nil {
		a.proxyBytes = &http.Client{Transport: pc}
	}
	return a, nil
}

// Store exposes the pool layout (byte serving, tests).
func (a *Agent) Store() *Store { return a.store }

// Lease exposes the single-writer lease state.
func (a *Agent) Lease() *LeaseManager { return a.lease }

// PoolAvailable reports whether the pool share is usable right now.
func (a *Agent) PoolAvailable() bool { return a.store.Available() }

func (a *Agent) now() time.Time { return a.opts.Now() }

func (a *Agent) logf(format string, args ...any) {
	if a.opts.Logf != nil {
		a.opts.Logf(format, args...)
	}
}

func (a *Agent) audit(action string, id ImageID, outcome, detail string) {
	if a.opts.Audit == nil {
		return
	}
	a.opts.Audit(AuditEvent{
		AtUTC:    a.now().UTC().Format(time.RFC3339),
		Action:   action,
		HostType: id.HostType, ImageKey: id.ImageKey, Arch: id.Arch, Variant: id.Variant,
		Outcome: outcome, Detail: detail,
	})
}

// --- HTTP clients -----------------------------------------------------------

func newDirectTransport() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	// Proxy: nil, explicitly. Inheriting the environment's proxy variables would
	// silently route the freshness probes through the caching proxy.
	t.Proxy = nil
	t.ResponseHeaderTimeout = responseHeaderTimeout
	t.DialContext = (&net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}).DialContext
	return t
}

// newProxyTransport builds the squid-first byte transport: plain HTTP through
// the :3128 port, HTTPS through the ssl-bump port with RootCAs pinned to the
// squid CA (squid impersonates the origin there, so the system roots alone
// cannot verify it). Returns nil when no proxy is configured.
func newProxyTransport(proxyHTTP, proxyHTTPS, caPath string) (*http.Transport, error) {
	proxyHTTP, proxyHTTPS = strings.TrimSpace(proxyHTTP), strings.TrimSpace(proxyHTTPS)
	if proxyHTTP == "" && proxyHTTPS == "" {
		return nil, nil
	}
	var httpURL, httpsURL *url.URL
	var err error
	if proxyHTTP != "" {
		if httpURL, err = url.Parse(proxyHTTP); err != nil {
			return nil, fmt.Errorf("proxy-http %q: %w", proxyHTTP, err)
		}
	}
	if proxyHTTPS != "" {
		if httpsURL, err = url.Parse(proxyHTTPS); err != nil {
			return nil, fmt.Errorf("proxy-https %q: %w", proxyHTTPS, err)
		}
	}
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.ResponseHeaderTimeout = responseHeaderTimeout
	t.DialContext = (&net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}).DialContext
	t.Proxy = func(r *http.Request) (*url.URL, error) {
		if r.URL.Scheme == "https" {
			return httpsURL, nil
		}
		return httpURL, nil
	}
	if caPath != "" {
		pem, err := os.ReadFile(caPath)
		if err != nil {
			return nil, fmt.Errorf("proxy CA %s: %w", caPath, err)
		}
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("proxy CA %s: no certificate found", caPath)
		}
		t.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	return t, nil
}

// --- scanning ---------------------------------------------------------------

// Run sweeps staging, renews the lease, seeds and refreshes on the scan cadence
// until ctx is canceled.
// The lease is released on EVERY exit path, not just the ticker's: a scan that
// is still running when the process is asked to stop would otherwise leave a
// stale lease behind, forcing every other agent read-only for a full expiry
// window. Whoever starts Run must also wait for it before exiting.
func (a *Agent) Run(ctx context.Context) {
	defer a.lease.Release()
	a.ScanOnce(ctx)
	ticker := time.NewTicker(a.opts.ScanInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.ScanOnce(ctx)
		}
	}
}

// ScanOnce is one full pass: staging hygiene, lease, auto-seed, then a refresh
// for every entry inside the prefetch window.
func (a *Agent) ScanOnce(ctx context.Context) {
	now := a.now()
	if a.store.Available() {
		if swept, err := a.store.SweepStaging(now, nil); err == nil && swept > 0 {
			a.mu.Lock()
			a.stagingSwept += swept
			a.mu.Unlock()
			a.logf("swept %d abandoned staging entries", swept)
		}
	}
	readOnly, holder, _ := a.lease.Renew(now)
	if readOnly {
		a.logf("lease held by %s: read-only mode, deferring downloads", holder)
	}

	seed := a.seedPass(ctx, now)

	due := 0
	if !readOnly && a.store.Available() {
		entries, err := a.store.List()
		if err != nil {
			a.logf("pool walk failed: %v", err)
		}
		for _, e := range entries {
			if ctx.Err() != nil {
				break
			}
			if !a.DueForRefresh(e.Sidecar, now) {
				continue
			}
			if _, started := a.startRefresh(e.ID, false); started {
				due++
			}
		}
	}

	a.mu.Lock()
	a.lastScan = now
	a.nextScan = now.Add(a.opts.ScanInterval)
	a.scans++
	a.lastSeed = seed
	a.mu.Unlock()
	if due > 0 {
		a.logf("scan started %d refresh(es)", due)
	}
}

// DueForRefresh is the scanner window: an entry is acted on once it is within
// prefetchLead of expiring, so a host asking at the expiry moment still finds a
// verified artifact rather than a refresh that has not started.
func (a *Agent) DueForRefresh(sc *Sidecar, now time.Time) bool {
	if sc == nil || sc.LastVerifiedAt == "" {
		return true
	}
	verified, err := time.Parse(time.RFC3339, sc.LastVerifiedAt)
	if err != nil {
		return true
	}
	return !now.Before(verified.Add(a.opts.Freshness - a.opts.PrefetchLead))
}

// IsFresh reports whether an entry is still inside its freshness window.
func (a *Agent) IsFresh(sc *Sidecar, now time.Time) bool {
	if sc == nil || sc.LastVerifiedAt == "" {
		return false
	}
	verified, err := time.Parse(time.RFC3339, sc.LastVerifiedAt)
	if err != nil {
		return false
	}
	return now.Before(verified.Add(a.opts.Freshness))
}

// familyUnavailable reports why this agent cannot resolve an identity's family
// right now, or "" when it can. Only the Windows family can answer non-empty:
// it needs an interpreter and a vendored script the agent VM may never have
// installed, and it needs Fido to still work against Microsoft's pages.
//
// The lookup half never starts a child, so the catalog can ask on every render;
// the remembered-failure half is what turns a Fido run that exits badly, prints
// nothing, prints something that is not a URL, or hangs into the same answer as
// a missing interpreter -- one state, so hosts have one behavior.
func (a *Agent) familyUnavailable(id ImageID) string {
	if FamilyOf(id.ImageKey) != FamilyWindows11 {
		return ""
	}
	if err := a.resolver.Fido.Check(); err != nil {
		return err.Error()
	}
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.fidoErr != "" && now.Sub(a.fidoErrAt) < fidoFailureTTL {
		return a.fidoErr
	}
	return ""
}

// noteFidoOutcome records or clears the remembered Fido failure.
func (a *Agent) noteFidoOutcome(err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err == nil {
		a.fidoErr, a.fidoErrAt = "", time.Time{}
		return
	}
	a.fidoErr, a.fidoErrAt = err.Error(), a.opts.Now()
}

// BestEffortStatus reports, per best-effort family, whether this agent can
// resolve it at all. It is the header's answer to "is this feature installed
// here", which is a different question from any single row's state.
func (a *Agent) BestEffortStatus() []FamilyStatus {
	out := make([]FamilyStatus, 0, len(BestEffortKeys))
	for _, key := range BestEffortKeys {
		fs := FamilyStatus{ImageKey: key, Available: true}
		if reason := a.familyUnavailable(ImageID{ImageKey: key}); reason != "" {
			fs.Available, fs.Reason = false, reason
		}
		out = append(out, fs)
	}
	return out
}

func (a *Agent) setKnownHostTypes(hostTypes []string) {
	if len(hostTypes) == 0 {
		return
	}
	a.mu.Lock()
	a.knownHostTypes = append([]string(nil), hostTypes...)
	a.mu.Unlock()
}

// --- the refresh pipeline ---------------------------------------------------

// startRefresh joins or starts the single-flight refresh for one identity.
func (a *Agent) startRefresh(id ImageID, seed bool) (*Flight, bool) {
	return a.flights.Start(id.Key(), seed, func(ctx context.Context, p *Progress) error {
		dctx, cancel := context.WithTimeout(ctx, downloadDeadline)
		defer cancel()
		err := a.refreshNow(dctx, id, p)
		a.mu.Lock()
		if err != nil {
			a.lastErr[id.Key()] = err.Error()
			a.lastErrAt[id.Key()] = a.opts.Now()
		} else {
			delete(a.lastErr, id.Key())
			delete(a.lastErrAt, id.Key())
		}
		a.mu.Unlock()
		outcome := "ok"
		detail := ""
		if err != nil {
			outcome, detail = "failed", err.Error()
			a.logf("refresh %s failed: %v", id, err)
		}
		a.audit("refresh", id, outcome, detail)
		return err
	})
}

// refreshNow re-resolves, probes the origin DIRECTLY, and downloads only when
// the comparison shows the origin changed.
func (a *Agent) refreshNow(ctx context.Context, id ImageID, p *Progress) error {
	if !a.store.Available() {
		return errors.New(ReasonPoolUnavailable)
	}
	if !Supported(id) {
		return fmt.Errorf("%s: %s", ReasonUnsupported, id.ImageKey)
	}

	p.SetPhase(PhaseResolving)
	res, err := a.resolver.Resolve(ctx, id)
	if FamilyOf(id.ImageKey) == FamilyWindows11 && ctx.Err() == nil {
		// A canceled resolve says nothing about Fido -- it says the operator
		// deleted the entry or the daemon is stopping -- so only a real outcome
		// is remembered.
		a.noteFidoOutcome(err)
	}
	if err != nil {
		return err
	}

	p.SetPhase(PhaseProbing)
	size, lastMod, err := a.probe(ctx, res.SourceURL)
	if err != nil {
		// Stamp nothing: laundering an unreachable origin into lastVerifiedAt
		// would certify staleness as freshness.
		return fmt.Errorf("origin probe %s: %w", res.SourceURL, err)
	}

	cur, hasPointer, err := a.store.ReadPointer(id)
	if err != nil {
		return err
	}
	if hasPointer {
		if sc, err := a.store.ReadSidecar(id, cur.GenerationFile); err == nil && sameOrigin(sc, res, size, lastMod) {
			sc.LastVerifiedAt = a.now().UTC().Format(time.RFC3339)
			sc.SchemaVersion = SchemaVersion
			return a.store.WriteSidecar(id, cur.GenerationFile, *sc)
		}
	}

	p.SetPhase(PhaseDownloading)
	p.SetTotal(size)
	staged, err := a.store.NewStagingPath(id, res.UpstreamFilename)
	if err != nil {
		return err
	}
	sha, written, err := a.downloadTo(ctx, res.SourceURL, staged, p)
	if err != nil {
		_ = os.Remove(staged)
		return err
	}
	// The probe's Content-Length is what sameOrigin compares the sidecar against
	// on every later scan, so a byteCount that recorded anything else would make
	// the entry look changed forever and re-download it on every pass. Proving
	// the two agree here is also the only truncation check the pipeline has
	// before the checksum.
	if size > 0 && written != size {
		_ = os.Remove(staged)
		return fmt.Errorf("origin %s: HEAD reported %d byte(s), the download produced %d", res.SourceURL, size, written)
	}
	byteCount := size
	if byteCount <= 0 {
		byteCount = written
	}

	p.SetPhase(PhaseVerifying)
	verdict, err := a.verifyChecksum(ctx, res, sha)
	if err != nil {
		// A generation the agent cannot vouch for is discarded and the current
		// pointer is left untouched, so the previous verified artifact stays
		// servable.
		_ = os.Remove(staged)
		return err
	}

	p.SetPhase(PhasePromoting)
	generation := GenerationName(res.UpstreamFilename, sha)
	if err := a.store.PromoteStaging(id, staged, generation); err != nil {
		_ = os.Remove(staged)
		return err
	}
	nowStr := a.now().UTC().Format(time.RFC3339)
	sc := Sidecar{
		ImageKey: id.ImageKey, HostType: id.HostType, Arch: id.Arch, Variant: id.Variant,
		ResolvedVariant:  res.Variant,
		SourceURL:        res.SourceURL,
		UpstreamFilename: res.UpstreamFilename,
		ByteCount:        byteCount,
		LastModified:     lastMod,
		SHA256:           sha,
		ChecksumVerdict:  verdict,
		DownloadedAt:     nowStr,
		LastVerifiedAt:   nowStr,
		AgentVersion:     a.opts.AgentVersion,
	}
	if err := a.store.Commit(id, generation, sc); err != nil {
		return err
	}
	if _, err := a.store.Retain(id); err != nil {
		a.logf("retention for %s: %v", id, err)
	}
	return nil
}

// sameOrigin is the four-field comparison the host-side skip guard uses:
// URL-derived filename, URL, Content-Length and Last-Modified. Last-Modified is
// lenient when either side lacks it, exactly as the host guard is.
//
// A signed-URL family compares filename and Content-Length only. Its resolver
// mints a fresh URL -- and a fresh expiry, and whatever Last-Modified the
// edge node that answers happens to carry -- for the same artifact on every
// resolve, so including either field would report "changed" on every scan and
// re-download a multi-gigabyte ISO forever. ComparesSourceURL names the one
// family that behaves this way; everything else keeps the full comparison,
// because for them a changed URL is exactly how a new artifact announces itself.
func sameOrigin(sc *Sidecar, res Resolved, size int64, lastMod string) bool {
	if sc == nil {
		return false
	}
	if sc.UpstreamFilename != res.UpstreamFilename {
		return false
	}
	if size <= 0 || sc.ByteCount != size {
		return false
	}
	if !ComparesSourceURL(res.Family) {
		return true
	}
	if sc.SourceURL != res.SourceURL {
		return false
	}
	if sc.LastModified != "" && lastMod != "" && sc.LastModified != lastMod {
		return false
	}
	return true
}

// probe HEADs the resolved URL directly and returns the comparison fields.
func (a *Agent) probe(ctx context.Context, rawURL string) (int64, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, rawURL, nil)
	if err != nil {
		return 0, "", err
	}
	resp, err := a.direct.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return resp.ContentLength, resp.Header.Get("Last-Modified"), nil
}

// downloadTo streams the artifact into staging, hashing as it goes. Bytes try
// the caching proxy first and fall back to a direct fetch on ANY proxy failure --
// including the offline-mode 504 a cache miss produces, and including one that
// only surfaces mid-body, long after the headers looked fine. squid can drop a
// long stream (a peer that stops relaying, an offline-mode switch mid-transfer),
// and a multi-hour ISO transfer is exactly where that happens; failing the whole
// refresh for it would leave the pool stale when a direct fetch would have
// worked. The retry restarts the artifact and the progress counter from zero,
// because a partially proxied file cannot be resumed against a different peer.
func (a *Agent) downloadTo(ctx context.Context, rawURL, dstPath string, p *Progress) (string, int64, error) {
	resp, viaProxy, err := a.openStream(ctx, rawURL)
	if err != nil {
		return "", 0, err
	}
	if viaProxy {
		a.logf("fetching %s via the caching proxy", rawURL)
	}
	sha, n, err := copyStream(resp, dstPath, p)
	if err == nil || !viaProxy || ctx.Err() != nil {
		return sha, n, err
	}

	a.logf("proxy stream of %s broke after %d byte(s) (%v); restarting the fetch direct", rawURL, n, err)
	p.Reset()
	direct, derr := a.openDirectStream(ctx, rawURL)
	if derr != nil {
		return "", n, fmt.Errorf("proxy stream failed (%v); direct retry: %w", err, derr)
	}
	return copyStream(direct, dstPath, p)
}

// copyStream writes one response body into dstPath, hashing and counting as it
// goes, and always closes the body. dstPath is truncated, so a retry starts a
// clean artifact rather than appending to a partial one.
func copyStream(resp *http.Response, dstPath string, p *Progress) (string, int64, error) {
	defer resp.Body.Close()
	f, err := os.Create(dstPath)
	if err != nil {
		return "", 0, err
	}
	hasher := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(f, hasher, p), resp.Body)
	closeErr := f.Close()
	if copyErr != nil {
		return "", n, copyErr
	}
	if closeErr != nil {
		return "", n, closeErr
	}
	return hex.EncodeToString(hasher.Sum(nil)), n, nil
}

func (a *Agent) openStream(ctx context.Context, rawURL string) (*http.Response, bool, error) {
	if a.proxyBytes != nil {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err == nil {
			resp, err := a.proxyBytes.Do(req)
			if err == nil && resp.StatusCode >= 200 && resp.StatusCode < 300 {
				return resp, true, nil
			}
			if resp != nil {
				a.logf("proxy fetch of %s returned HTTP %d; falling back to direct", rawURL, resp.StatusCode)
				resp.Body.Close()
			} else if err != nil {
				a.logf("proxy fetch of %s failed (%v); falling back to direct", rawURL, err)
			}
		}
	}
	resp, err := a.openDirectStream(ctx, rawURL)
	return resp, false, err
}

func (a *Agent) openDirectStream(ctx context.Context, rawURL string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := a.directBytes.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		status := resp.StatusCode
		resp.Body.Close()
		return nil, fmt.Errorf("GET %s: HTTP %d", rawURL, status)
	}
	return resp, nil
}

// verifyChecksum compares the downloaded hash against the publisher's, fetched
// DIRECTLY. A publisher that offers no checksum for this artifact is a soft pass
// ("unpublished"); a checksum that cannot be fetched at all is a hard failure,
// because unverifiable is not the same as unpublished.
func (a *Agent) verifyChecksum(ctx context.Context, res Resolved, sha string) (string, error) {
	if res.ChecksumURL == "" {
		return VerdictNone, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, res.ChecksumURL, nil)
	if err != nil {
		return "", err
	}
	resp, err := a.direct.Do(req)
	if err != nil {
		return "", fmt.Errorf("checksum fetch %s: %w", res.ChecksumURL, err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusForbidden, resp.StatusCode == http.StatusNotFound, resp.StatusCode == http.StatusGone:
		return VerdictUnpublished, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return "", fmt.Errorf("checksum fetch %s: HTTP %d", res.ChecksumURL, resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return "", fmt.Errorf("checksum fetch %s: %w", res.ChecksumURL, err)
	}
	var want string
	if res.ChecksumFormat == ChecksumSidecar {
		want = ParseSHA256Sidecar(string(b))
	} else {
		want = ParseSHA256SUMS(string(b), res.ChecksumTarget)
	}
	if want == "" {
		return VerdictUnpublished, nil
	}
	if !strings.EqualFold(want, sha) {
		return "", fmt.Errorf("checksum mismatch for %s: published %s, downloaded %s", res.UpstreamFilename, want, sha)
	}
	return VerdictVerified, nil
}

// --- catalog ----------------------------------------------------------------

// Catalog is every entry on disk plus a row for each family the pool could hold
// -- the seeded ones and the best-effort ones alike -- so an operator always has
// a row to act on and never has to infer a family's absence from a table that
// simply does not mention it.
func (a *Agent) Catalog(now time.Time) ([]CatalogEntry, Totals) {
	entries, _ := a.store.List()
	seen := map[string]bool{}
	out := make([]CatalogEntry, 0, len(entries))
	totals := Totals{ByHostType: map[string]int64{}}
	for _, e := range entries {
		ce := a.decorate(e, now)
		seen[e.ID.Key()] = true
		out = append(out, ce)
		totals.Images++
		totals.CurrentBytes += ce.CurrentBytes
		totals.PreviousBytes += ce.PreviousBytes
		totals.Bytes += ce.CurrentBytes + ce.PreviousBytes
		totals.ByHostType[e.ID.HostType] += ce.CurrentBytes + ce.PreviousBytes
	}
	a.mu.Lock()
	known := append([]string(nil), a.knownHostTypes...)
	a.mu.Unlock()
	for _, id := range CatalogTargets(known) {
		if seen[id.Key()] {
			continue
		}
		seen[id.Key()] = true
		e, err := a.store.Entry(id)
		if err != nil {
			e = Entry{ID: id}
		}
		out = append(out, a.decorate(e, now))
		if _, ok := totals.ByHostType[id.HostType]; !ok {
			totals.ByHostType[id.HostType] = 0
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].HostType != out[j].HostType {
			return out[i].HostType < out[j].HostType
		}
		if out[i].ImageKey != out[j].ImageKey {
			return out[i].ImageKey < out[j].ImageKey
		}
		if out[i].Arch != out[j].Arch {
			return out[i].Arch < out[j].Arch
		}
		return out[i].Variant < out[j].Variant
	})
	return out, totals
}

// Entry is one catalog row; found is false when nothing is on disk for it.
func (a *Agent) Entry(now time.Time, id ImageID) (CatalogEntry, bool) {
	e, err := a.store.Entry(id)
	if err != nil {
		e = Entry{ID: id}
	}
	ce := a.decorate(e, now)
	return ce, e.Pointer != nil
}

// decorate folds the live view (flight progress, last error, deleting) onto an
// on-disk entry and computes its state badge.
func (a *Agent) decorate(e Entry, now time.Time) CatalogEntry {
	ce := CatalogEntry{
		HostType: e.ID.HostType, ImageKey: e.ID.ImageKey, Arch: e.ID.Arch, Variant: e.ID.Variant,
		Supported:       Supported(e.ID),
		BestEffort:      IsBestEffort(e.ID.ImageKey),
		CurrentBytes:    e.CurrentBytes,
		PreviousBytes:   e.PreviousBytes,
		GenerationCount: len(e.Generations),
	}
	if ce.BestEffort {
		ce.UnavailableReason = a.familyUnavailable(e.ID)
	}
	if e.Pointer != nil {
		ce.Generation = e.Pointer.GenerationFile
		ce.UpstreamFilename = e.Pointer.UpstreamFilename
		ce.SHA256 = e.Pointer.SHA256
		ce.FileURL = FileURL(e.ID, e.Pointer.GenerationFile)
	}
	if e.Sidecar != nil {
		ce.SourceURL = e.Sidecar.SourceURL
		ce.ByteCount = e.Sidecar.ByteCount
		ce.LastModified = e.Sidecar.LastModified
		ce.ResolvedVariant = e.Sidecar.ResolvedVariant
		ce.ChecksumVerdict = e.Sidecar.ChecksumVerdict
		ce.DownloadedAt = e.Sidecar.DownloadedAt
		ce.LastVerifiedAt = e.Sidecar.LastVerifiedAt
		if verified, err := time.Parse(time.RFC3339, e.Sidecar.LastVerifiedAt); err == nil {
			exp := verified.Add(a.opts.Freshness)
			ce.ExpiresAt = exp.UTC().Format(time.RFC3339)
			ce.SecondsToExpiry = int64(exp.Sub(now).Seconds())
		}
	}

	a.mu.Lock()
	lastErr := a.lastErr[e.ID.Key()]
	deleting := a.deleting[e.ID.Key()]
	a.mu.Unlock()
	ce.LastError = lastErr

	if f, live := a.flights.Lookup(e.ID.Key()); live {
		snap := f.Progress.Snapshot()
		ce.RefreshInFlight = true
		ce.Phase = snap.Phase
		ce.BytesDone = snap.Done
		ce.BytesTotal = snap.Total
	}

	switch {
	case deleting:
		ce.State = StateDeleting
	case e.Pointer == nil && ce.RefreshInFlight:
		ce.State = StateDownloading
	case e.Pointer == nil && ce.UnavailableReason != "":
		// Ahead of "failed" on purpose: a Force refresh of a family whose
		// resolver cannot run leaves a recorded error, and reporting that as a
		// failed image would send the operator looking for a broken download
		// instead of missing tooling. The error itself still renders beside the
		// badge.
		ce.State = StateUnavailable
	case e.Pointer == nil && lastErr != "":
		ce.State = StateFailed
	case e.Pointer == nil:
		ce.State = StateAbsent
	case a.IsFresh(e.Sidecar, now):
		ce.State = StateFresh
	default:
		ce.State = StateStale
	}
	return ce
}

// FileURL is the byte-serving route for one generation.
func FileURL(id ImageID, generation string) string {
	return "/api/v1/images/" + url.PathEscape(id.HostType) + "/" + url.PathEscape(id.ImageKey) +
		"/file/" + url.PathEscape(generation)
}

// Status snapshots the agent for the status route and the UI header.
func (a *Agent) Status(now time.Time) Status {
	_, totals := a.Catalog(now)
	a.mu.Lock()
	st := Status{
		PoolDir:             a.opts.PoolDir,
		ImagesDir:           a.store.ImagesDir(),
		ScanIntervalSeconds: int(a.opts.ScanInterval.Seconds()),
		FreshnessSeconds:    int(a.opts.Freshness.Seconds()),
		PrefetchLeadSeconds: int(a.opts.PrefetchLead.Seconds()),
		Scans:               a.scans,
		StagingSwept:        a.stagingSwept,
		AutoSeed:            a.opts.AutoSeed,
		LastSeed:            a.lastSeed,
		Totals:              totals,
	}
	if !a.lastScan.IsZero() {
		st.LastScanUTC = a.lastScan.UTC().Format(time.RFC3339)
	}
	if !a.nextScan.IsZero() {
		st.NextScanUTC = a.nextScan.UTC().Format(time.RFC3339)
	}
	a.mu.Unlock()
	st.PoolAvailable = a.store.Available()
	st.ReadOnly = a.lease.ReadOnly()
	st.LeaseHolder = a.lease.Holder()
	st.LeaseError = a.lease.LastError()
	st.InFlight = a.flights.Len()
	st.ProxyConfigured = a.proxyBytes != nil
	st.BestEffort = a.BestEffortStatus()
	return st
}

// --- request-facing operations ----------------------------------------------

// Ensure is the host-facing join/trigger protocol.
func (a *Agent) Ensure(now time.Time, id ImageID, fp Fingerprint) EnsureResult {
	if !a.store.Available() {
		return EnsureResult{HTTPStatus: http.StatusServiceUnavailable, State: StateUnavailable, Reason: ReasonPoolUnavailable}
	}
	if !Supported(id) {
		return EnsureResult{HTTPStatus: http.StatusNotFound, State: StateUnsupported, Reason: ReasonUnsupported}
	}
	ce, hasPointer := a.Entry(now, id)
	res := EnsureResult{Image: ce}

	// A best-effort family this agent cannot resolve, holding nothing, answers
	// byte-for-byte the way an unsupported one does. That is the whole point of
	// "best effort": the host cannot tell an agent that lacks Fido from a lab
	// that runs no agent, so it takes its own path without a warning nobody can
	// act on. Bytes already on disk from an earlier successful resolve stay
	// servable below; what a missing resolver removes is the ability to refresh
	// them, not the ability to hand them out.
	unavailable := a.familyUnavailable(id)
	if unavailable != "" && !hasPointer {
		return EnsureResult{HTTPStatus: http.StatusNotFound, State: StateUnsupported, Reason: ReasonUnsupported}
	}

	if hasPointer && fingerprintMatches(fp, ce) {
		// The host already holds these bytes. Answer immediately even if the
		// entry is stale: it must never wait on -- or re-download after -- a
		// refresh of bytes it already has.
		res.HTTPStatus = http.StatusOK
		res.State = StateReady
		res.LocalCurrent = true
		res.RefreshInFlight = ce.RefreshInFlight
		return res
	}

	fresh := a.IsFresh(sidecarOf(ce), now)
	if hasPointer && fresh {
		res.HTTPStatus = http.StatusOK
		res.State = StateReady
		res.RefreshInFlight = ce.RefreshInFlight
		return res
	}

	if hasPointer {
		// Stale: start or join a refresh, but keep serving the previous verified
		// artifact meanwhile.
		res.HTTPStatus = http.StatusOK
		res.State = StateReady
		res.Stale = true
		switch {
		case a.lease.ReadOnly():
			// A follower defers refreshes to the lease holder. Reporting a
			// refresh in flight here would have hosts poll for work this agent
			// is never going to do.
			res.Reason = ReasonLeaseReadOnly
		case unavailable != "":
			// Same reasoning, different cause: the resolver cannot run here, so
			// there is no refresh to start and nothing to poll for. The previous
			// verified artifact stays servable.
		default:
			if f, _ := a.startRefresh(id, false); f != nil {
				res.RefreshInFlight = true
			}
		}
		res.Image, _ = a.Entry(now, id)
		return res
	}

	if a.lease.ReadOnly() {
		return EnsureResult{HTTPStatus: http.StatusServiceUnavailable, State: StateUnavailable, Reason: ReasonLeaseReadOnly, Image: ce}
	}

	// A first-ever download with no live flight is either "not started yet" or
	// "just failed". The flight map cannot tell them apart -- a finished flight
	// is removed from it -- so the recorded failure is what distinguishes them.
	// Without this, every poll of every host starts a brand new download against
	// a dead origin and the client only ever sees 202 until its budget runs out.
	if f, live := a.flights.Lookup(id.Key()); live {
		snap := f.Progress.Snapshot()
		res.HTTPStatus = http.StatusAccepted
		res.State = StateDownloading
		res.RefreshInFlight = true
		res.BytesDone = snap.Done
		res.BytesTotal = snap.Total
		return res
	}
	if msg, failedAt, ok := a.lastFailure(id.Key()); ok && now.Sub(failedAt) < firstDownloadBackoff {
		res.HTTPStatus = http.StatusOK
		res.State = StateFailed
		res.Error = msg
		return res
	}

	f, _ := a.startRefresh(id, false)
	snap := f.Progress.Snapshot()
	select {
	case <-f.Done():
		if err := f.Err(); err != nil {
			ce, ok := a.Entry(now, id)
			if ok {
				return EnsureResult{HTTPStatus: http.StatusOK, State: StateReady, Stale: true, Image: ce}
			}
			return EnsureResult{HTTPStatus: http.StatusOK, State: StateFailed, Error: err.Error(), Image: ce}
		}
		ce, _ = a.Entry(now, id)
		return EnsureResult{HTTPStatus: http.StatusOK, State: StateReady, Image: ce}
	default:
	}
	res.HTTPStatus = http.StatusAccepted
	res.State = StateDownloading
	res.RefreshInFlight = true
	res.BytesDone = snap.Done
	res.BytesTotal = snap.Total
	return res
}

// lastFailure reports the most recent recorded refresh failure for a key.
func (a *Agent) lastFailure(key string) (string, time.Time, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	msg, ok := a.lastErr[key]
	if !ok || msg == "" {
		return "", time.Time{}, false
	}
	return msg, a.lastErrAt[key], true
}

// sidecarOf rebuilds the freshness-relevant sidecar fields from a catalog row so
// Ensure and the UI agree on what "fresh" means.
func sidecarOf(ce CatalogEntry) *Sidecar {
	if ce.LastVerifiedAt == "" {
		return nil
	}
	return &Sidecar{LastVerifiedAt: ce.LastVerifiedAt}
}

// fingerprintMatches compares what the host holds with the current pointer. A
// matching SHA-256 is conclusive; filename + byte count is the fallback for a
// host whose sentinel predates content addressing.
func fingerprintMatches(fp Fingerprint, ce CatalogEntry) bool {
	if fp.SHA256 != "" && ce.SHA256 != "" {
		return strings.EqualFold(fp.SHA256, ce.SHA256)
	}
	if fp.Filename == "" || fp.ByteCount <= 0 {
		return false
	}
	return fp.Filename == ce.UpstreamFilename && fp.ByteCount == ce.ByteCount
}

// ForceRefresh re-verifies one identity now, downloading only if the origin
// changed. Also the manual first-download path for an absent row.
func (a *Agent) ForceRefresh(id ImageID) (bool, error) {
	if !a.store.Available() {
		return false, errors.New(ReasonPoolUnavailable)
	}
	if !Supported(id) {
		return false, errors.New(ReasonUnsupported)
	}
	if a.lease.ReadOnly() {
		return false, errors.New(ReasonLeaseReadOnly)
	}
	_, started := a.startRefresh(id, false)
	return started, nil
}

// RefreshAll re-verifies every entry in the pool and reports how many flights it
// started (entries already in flight are joined, not restarted).
func (a *Agent) RefreshAll() (int, error) {
	if !a.store.Available() {
		return 0, errors.New(ReasonPoolUnavailable)
	}
	if a.lease.ReadOnly() {
		return 0, errors.New(ReasonLeaseReadOnly)
	}
	entries, err := a.store.List()
	if err != nil {
		return 0, err
	}
	started := 0
	for _, e := range entries {
		if _, ok := a.startRefresh(e.ID, false); ok {
			started++
		}
	}
	return started, nil
}

// Delete cancels any in-flight download for the identity, clears its staging,
// removes the pointer FIRST and then every generation it owns. The next host
// request or seed pass re-downloads from origin.
func (a *Agent) Delete(id ImageID) error {
	if !a.store.Available() {
		return errors.New(ReasonPoolUnavailable)
	}
	a.mu.Lock()
	a.deleting[id.Key()] = true
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		delete(a.deleting, id.Key())
		delete(a.lastErr, id.Key())
		delete(a.lastErrAt, id.Key())
		a.mu.Unlock()
	}()

	a.flights.Cancel(id.Key())
	removed, err := a.store.Delete(id)
	outcome, detail := "ok", fmt.Sprintf("removed %d file(s)", len(removed))
	if err != nil {
		outcome, detail = "failed", err.Error()
	}
	a.audit("delete", id, outcome, detail)
	return err
}

// PrunePrevious reclaims the retained previous generation; current stays servable.
func (a *Agent) PrunePrevious(id ImageID) (int, error) {
	if !a.store.Available() {
		return 0, errors.New(ReasonPoolUnavailable)
	}
	n, err := a.store.PrunePrevious(id)
	outcome, detail := "ok", fmt.Sprintf("pruned %d generation(s)", n)
	if err != nil {
		outcome, detail = "failed", err.Error()
	}
	a.audit("prune", id, outcome, detail)
	return n, err
}

// OpenGeneration hands a generation's bytes to the byte-serving route.
func (a *Agent) OpenGeneration(id ImageID, generation string) (*os.File, os.FileInfo, error) {
	return a.store.Open(id, generation)
}
