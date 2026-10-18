// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package pool is the client for the pool-aggregator service. See
// ../../../../docs/extensions-api.md#2-the-go-sdk----talking-to-the-pool-and-gating-writes
// for the TLS, sanitization and fallback decisions every call carries. -- pool.go
package pool

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
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Aggregator routes this package speaks.
const (
	pathHealthz        = "/healthz"
	pathPoolStatus     = "/api/v1/pool-status"
	pathExtensionHosts = "/api/v1/extension-hosts"
)

const (
	// DefaultTimeout bounds one aggregator call. A consumer usually sits in
	// front of something a person is waiting for (a page render, a cycle
	// pre-flight), so an aggregator that accepts a connection and then says
	// nothing must not be able to wedge it.
	DefaultTimeout = 10 * time.Second

	// DefaultCacheTTL is how long a pool-status snapshot is reused. Short enough
	// that a UI never shows a stale host list, long enough that a page rendering
	// many rows makes one request rather than one per row.
	DefaultCacheTTL = 15 * time.Second

	// NoCache disables the snapshot cache for a caller that must see the
	// aggregator's answer at the instant it asks.
	NoCache = -1 * time.Nanosecond

	// maxBodyBytes caps a decoded response. The pool view of a large lab is
	// still well under this; the cap only stops an unbounded read.
	maxBodyBytes = 8 << 20
)

// Control states, as the aggregator puts them ON THE WIRE. "remote"/"onsite"
// are dashboard display mappings of these and appear nowhere in the API, so a
// predicate written against those matches zero hosts forever and looks exactly
// like "nothing needed doing".
const (
	ControlReady    = "ready"
	ControlNone     = "none"
	ControlMismatch = "mismatch"
	ControlSkew     = "skew"
	ControlUnknown  = "unknown"
)

// Host refresh capability, as the aggregator carries it ON THE WIRE. Every
// value is lowercase with underscores because it crosses the listener,
// aggregator, pool-control and UI boundaries, where one spelling per code is
// what lets each surface branch on it.
//
// Refresh is a separate typed field rather than another Control state on
// purpose: Control keeps its last-known verdict across a missed probe, and a
// disruptive capability must not. A refresh observation that is stale,
// unreadable or absent reads as unavailable.
const (
	// RefreshProtocolVersion is the only capability protocol this SDK can act
	// on; a host advertising another reads as unavailable.
	RefreshProtocolVersion = 1

	RefreshAvailable   = "available"
	RefreshUnavailable = "unavailable"

	// Whether the host holds a verifier key for remote requests.
	RefreshRemoteProvisioned = "provisioned"
	RefreshRemoteMissing     = "missing"
	RefreshRemoteInvalid     = "invalid"
	RefreshRemoteUnqualified = "unqualified"
	RefreshRemoteUnknown     = "unknown"

	RefreshStateIdle            = "idle"
	RefreshStateActive          = "active"
	RefreshStateRecoveryPending = "recovery_pending"
	RefreshStateUnknown         = "unknown"

	// Why the aggregator reports a host's refresh as unavailable when the host
	// itself did not say so.
	RefreshReasonNotAdvertised           = "not_advertised"
	RefreshReasonProtocolUnsupported     = "protocol_unsupported"
	RefreshReasonCapabilityMalformed     = "capability_malformed"
	RefreshReasonControlStatusUnreadable = "control_status_unreadable"
	RefreshReasonHostUnreachable         = "host_unreachable"
	RefreshReasonObservationExpired      = "observation_expired"
	RefreshReasonNeverObserved           = "never_observed"
)

// Repair rung names. They are parameter vocabulary shared with the host's rung
// declaration, not codes, so they keep their hyphenated spelling everywhere.
const (
	RungProbe           = "probe"
	RungReclaim         = "reclaim"
	RungStartIfStopped  = "start-if-stopped"
	RungRestartIfHung   = "restart-if-hung"
	RungRestartBroker   = "restart-broker"
	RungReapplySettings = "reapply-settings"
	RungReinstall       = "reinstall"
	RungReboot          = "reboot"
)

// refreshRungNames is the whole ladder in Order: the index of a name is its
// Order. The host's rung declaration is the authority for this list, and a
// suite on the host side reads this literal and compares it with that
// declaration, so the two cannot drift silently.
var refreshRungNames = [...]string{"probe", "reclaim", "start-if-stopped", "restart-if-hung", "restart-broker", "reapply-settings", "reinstall", "reboot"}

// RefreshRungNames returns the eight rung names in Order. A copy, so no
// importer can reorder the ladder another importer compares against.
func RefreshRungNames() []string {
	out := make([]string, len(refreshRungNames))
	copy(out, refreshRungNames[:])
	return out
}

// RefreshRungOrder is a rung's Order, and whether the name is a rung at all.
// Callers compare Order, never the name.
func RefreshRungOrder(name string) (int, bool) {
	for i, n := range refreshRungNames {
		if n == name {
			return i, true
		}
	}
	return 0, false
}

// refreshReasonRE bounds a host-supplied reason code: a label-safe token short
// enough that no host can grow a metric or a table cell with it.
var refreshReasonRE = regexp.MustCompile(`^[a-z][a-z0-9_]{0,47}$`)

// HostRefresh is one host's refresh capability as the aggregator last judged
// it. It carries no key, tag, proof or request id: the capability says whether
// a remote request could be accepted, never how to make one.
type HostRefresh struct {
	Protocol     int    `json:"protocol,omitempty"`
	Availability string `json:"availability"`
	// Ceiling is the highest rung the host can execute in the restart tier,
	// empty when nothing is available.
	Ceiling string `json:"ceiling,omitempty"`
	Reason  string `json:"reason,omitempty"`
	Remote  string `json:"remote,omitempty"`
	State   string `json:"state,omitempty"`
	// ObservedUnixMs is when the aggregator last read this capability from the
	// host itself; AgeSeconds is how old that reading was when served.
	ObservedUnixMs int64 `json:"observedUnixMs,omitempty"`
	AgeSeconds     int64 `json:"ageSeconds,omitempty"`
}

// UnobservedRefresh is the capability of a host nobody has read one from:
// unavailable, with every enumerated field at its unknown value.
func UnobservedRefresh() HostRefresh {
	return HostRefresh{
		Availability: RefreshUnavailable,
		Reason:       RefreshReasonNeverObserved,
		Remote:       RefreshRemoteUnknown,
		State:        RefreshStateUnknown,
	}
}

// RemoteUsable reports whether a remote refresh request may be sent to the
// host at all: a compatible protocol, an available capability, and a verifier
// key on the host. An aggregator that predates the field decodes to the zero
// value, which is never usable.
func (r HostRefresh) RemoteUsable() bool {
	return r.Protocol == RefreshProtocolVersion && r.Availability == RefreshAvailable && r.Remote == RefreshRemoteProvisioned
}

// Normalized clamps every field to its bounded vocabulary. The value arrives
// over unauthenticated reads, so an unknown availability, an out-of-shape
// reason or an available capability with no rung to climb reads as
// unavailable rather than being passed through to a UI or a decision. An
// absent capability (an aggregator that predates it) reads as never observed.
func (r HostRefresh) Normalized() HostRefresh {
	if r.Availability == "" {
		return UnobservedRefresh()
	}
	out := r
	if out.ObservedUnixMs < 0 {
		out.ObservedUnixMs = 0
	}
	if out.AgeSeconds < 0 {
		out.AgeSeconds = 0
	}
	if _, ok := RefreshRungOrder(out.Ceiling); !ok {
		out.Ceiling = ""
	}
	switch out.Remote {
	case RefreshRemoteProvisioned, RefreshRemoteMissing, RefreshRemoteInvalid, RefreshRemoteUnqualified, RefreshRemoteUnknown:
	default:
		out.Remote = RefreshRemoteUnknown
	}
	switch out.State {
	case RefreshStateIdle, RefreshStateActive, RefreshStateRecoveryPending, RefreshStateUnknown:
	default:
		out.State = RefreshStateUnknown
	}
	demote := func(reason string) HostRefresh {
		out.Availability, out.Reason = RefreshUnavailable, reason
		return out
	}
	if out.Protocol != RefreshProtocolVersion {
		return demote(RefreshReasonProtocolUnsupported)
	}
	if out.Reason != "" && !refreshReasonRE.MatchString(out.Reason) {
		return demote(RefreshReasonCapabilityMalformed)
	}
	switch out.Availability {
	case RefreshAvailable:
		if out.Ceiling == "" {
			return demote(RefreshReasonCapabilityMalformed)
		}
		out.Reason = ""
	case RefreshUnavailable:
	default:
		return demote(RefreshReasonCapabilityMalformed)
	}
	return out
}

// hostTypePrefix is how the aggregator serializes a host type in pool-status.
const hostTypePrefix = "host."

var (
	// ErrNotConfigured means no aggregator URL was supplied. A host with no
	// caching-proxy service has no aggregator to ask and no pool: that is a
	// normal state, not a fault, and it is reported rather than guessed around.
	ErrNotConfigured = errors.New("pool aggregator address unset")

	// ErrAreaNotServed is the aggregator's documented 404 for an area no live
	// host serves -- the answer that lets a caller tell "not there" from "here
	// it is".
	ErrAreaNotServed = errors.New("no live host serves this extension area")
)

// Options configures a Client.
type Options struct {
	// BaseURL is the aggregator base, e.g. https://<proxy>:9400. Empty leaves
	// every call answering ErrNotConfigured.
	BaseURL string

	// Timeout bounds one call; 0 selects DefaultTimeout.
	Timeout time.Duration

	// CacheTTL is how long a pool-status snapshot is reused; 0 selects
	// DefaultCacheTTL and NoCache disables reuse.
	CacheTTL time.Duration

	// HTTPClient replaces the built-in client wholesale. Tests inject one; a
	// deployment that pins the pool CA supplies one here rather than editing
	// this package.
	HTTPClient *http.Client
}

// Client reads the pool-aggregator service.
type Client struct {
	base     string
	client   *http.Client
	cacheTTL time.Duration

	mu       sync.Mutex
	cached   *Status
	cachedAt time.Time
}

// New builds a Client. It never fails: an empty or malformed base URL leaves a
// client whose calls report ErrNotConfigured, so a caller can construct
// unconditionally and let each call site decide what a pool-less host means.
func New(opts Options) *Client {
	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	ttl := opts.CacheTTL
	if ttl == 0 {
		ttl = DefaultCacheTTL
	}
	client := opts.HTTPClient
	if client == nil {
		client = &http.Client{
			Timeout: timeout,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}, //nolint:gosec // trusted-LAN, unauthenticated pool read
			},
		}
	}
	return &Client{
		base:     strings.TrimRight(strings.TrimSpace(opts.BaseURL), "/"),
		client:   client,
		cacheTTL: ttl,
	}
}

// Configured reports whether an aggregator URL was supplied.
func (c *Client) Configured() bool { return c != nil && c.base != "" }

// BaseURL is the configured aggregator base, trimmed of its trailing slash.
func (c *Client) BaseURL() string {
	if c == nil {
		return ""
	}
	return c.base
}

// Healthz reports whether the aggregator answers its liveness route.
func (c *Client) Healthz(ctx context.Context) error {
	if !c.Configured() {
		return ErrNotConfigured
	}
	_, err := c.get(ctx, c.base+pathHealthz)
	return err
}

// HostStatus is the host's own status.json as the aggregator last read it;
// absent (nil on the Host) when that host was unreachable at poll time.
type HostStatus struct {
	HostID string `json:"hostId"`
	// Host is the host type in its prefixed form, e.g. "host.windows.hyper-v".
	Host          string `json:"host"`
	OverallStatus string `json:"overallStatus"`
	CycleStartUTC string `json:"cycleStartUtc"`
}

// Host is one discovered pool member, keyed by the stable hostId. The pool view
// is hostname-free by design, so nothing identifying is carried here.
type Host struct {
	HostID         string `json:"hostId"`
	CurrentIP      string `json:"currentIp"`
	BaseURL        string `json:"baseUrl"`
	Reachable      bool   `json:"reachable"`
	LastSeenUnixMs int64  `json:"lastSeenUnixMs"`
	Version        string `json:"version"`
	PoolID         string `json:"poolId"`
	PoolGUID       string `json:"poolGuid"`
	// Control is the remote-control verdict: one of the Control* constants.
	Control string `json:"control"`
	// Refresh is the host's refresh capability. Status normalizes it, so an
	// aggregator that predates the field yields UnobservedRefresh.
	Refresh HostRefresh `json:"refresh"`
	// ActiveExtensions are the areas this host is ACTIVELY running, and
	// ExtensionTargets the deep-link it advertises for each.
	ActiveExtensions []string          `json:"activeExtensions"`
	ExtensionTargets map[string]string `json:"extensionTargets"`
	// StashBaseURL is the stash-service address the pool resolves for this host,
	// through the same source merge the dashboard and /go/stash use.
	StashBaseURL    string      `json:"stashBaseUrl"`
	PreviousHostIDs []string    `json:"previousHostIds,omitempty"`
	Status          *HostStatus `json:"status"`
}

// HostType is the host type with the "host." prefix stripped
// ("windows.hyper-v"), or "" when the host's status was not readable.
func (h Host) HostType() string {
	if h.Status == nil {
		return ""
	}
	return strings.TrimPrefix(strings.TrimSpace(h.Status.Host), hostTypePrefix)
}

// Status is the aggregator's snapshot of every discovered host's last poll.
type Status struct {
	Pool        string `json:"pool"`
	LastPollUTC string `json:"lastPollUtc"`
	Hosts       []Host `json:"hosts"`
}

// Host returns the entry for hostID, and whether it was present.
func (s Status) Host(hostID string) (Host, bool) {
	for _, h := range s.Hosts {
		if h.HostID == hostID {
			return h, true
		}
	}
	return Host{}, false
}

// HostTypes is every distinct host type in the pool, sorted, plus the number of
// hosts whose status was unreadable. Unknown-status hosts are counted rather
// than guessed at: their type is simply not known this poll.
func (s Status) HostTypes() (types []string, unknown int) {
	seen := map[string]bool{}
	for _, h := range s.Hosts {
		ht := h.HostType()
		if ht == "" {
			unknown++
			continue
		}
		seen[ht] = true
	}
	for ht := range seen {
		types = append(types, ht)
	}
	sort.Strings(types)
	return types, unknown
}

// Status fetches the pool-status snapshot, reusing one no older than the
// configured cache TTL.
func (c *Client) Status(ctx context.Context) (Status, error) {
	if !c.Configured() {
		return Status{}, ErrNotConfigured
	}
	if s, ok := c.cachedStatus(); ok {
		return s, nil
	}
	var s Status
	if err := c.getJSON(ctx, c.base+pathPoolStatus, &s); err != nil {
		return Status{}, err
	}
	// Sanitize before anything can read it: these values reach UIs as links and
	// scripts as fetch targets, and a value that is not an absolute http(s) URL
	// is not one either consumer can use.
	for i := range s.Hosts {
		s.Hosts[i].Refresh = s.Hosts[i].Refresh.Normalized()
		s.Hosts[i].BaseURL = SanitizeBaseURL(s.Hosts[i].BaseURL)
		s.Hosts[i].StashBaseURL = SanitizeBaseURL(s.Hosts[i].StashBaseURL)
		for area, target := range s.Hosts[i].ExtensionTargets {
			if clean := SanitizeBaseURL(target); clean != "" {
				s.Hosts[i].ExtensionTargets[area] = clean
			} else {
				delete(s.Hosts[i].ExtensionTargets, area)
			}
		}
	}
	c.cacheStatus(s)
	return s, nil
}

// HandoverHost retires an old identity after re-keying. Mutation requests use
// only the configured URL: a TLS failure must never downgrade a bearer token.
func (c *Client) HandoverHost(ctx context.Context, oldID, newID, token string) error {
	if !c.Configured() {
		return ErrNotConfigured
	}
	if token == "" {
		return errors.New("internal authentication token missing")
	}
	body, err := json.Marshal(struct {
		OldHostID string `json:"oldHostId"`
		NewHostID string `json:"newHostId"`
	}{oldID, newID})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/api/v1/handover-host", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := c.authenticatedDo(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("host handover: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(message)))
	}
	c.mu.Lock()
	c.cached = nil
	c.mu.Unlock()
	return nil
}

// GetAuthenticated reads a bearer-gated aggregator route without ever
// downgrading an HTTPS URL after a transport error.
func (c *Client) GetAuthenticated(ctx context.Context, path, token string, out any) error {
	if !c.Configured() {
		return ErrNotConfigured
	}
	if token == "" {
		return errors.New("internal authentication token missing")
	}
	if !strings.HasPrefix(path, "/") {
		return errors.New("aggregator path must be absolute")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := c.authenticatedDo(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("aggregator history: HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(out)
}

func (c *Client) authenticatedDo(req *http.Request) (*http.Response, error) {
	client := *c.client
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	return client.Do(req)
}

// ExtensionTarget is the address hostID advertises for area, or "" when the
// pool cannot resolve one. Best-effort by construction: an unreachable
// aggregator, or a host the pool has not discovered, yields "".
func (c *Client) ExtensionTarget(ctx context.Context, hostID, area string) string {
	s, err := c.Status(ctx)
	if err != nil {
		return ""
	}
	h, ok := s.Host(hostID)
	if !ok {
		return ""
	}
	if area == stashArea && h.StashBaseURL != "" {
		return h.StashBaseURL
	}
	return h.ExtensionTargets[area]
}

// stashArea is the one area pool-status answers on its own top-level field, for
// consumers that predate the extensionTargets map.
const stashArea = "stash-service"

// ExtensionHost is where the pool currently sees one area served.
type ExtensionHost struct {
	Area string `json:"area"`
	// Host is the bare address callers compose probes and scp targets from;
	// Target is the advertised base URL. Both are blank on a suppressed entry.
	Host           string `json:"host"`
	Target         string `json:"target"`
	HostID         string `json:"hostId"`
	Source         string `json:"source"` // "registration" | "announce"
	LastSeenUnixMs int64  `json:"lastSeenUnixMs"`
	// SupersededTarget is what the OTHER source claimed when the two disagreed:
	// normally absent, and present means a host's registration has fallen behind
	// its own service.
	SupersededTarget string `json:"supersededTarget"`
	// Suppressed marks an entry the pool knows about but refuses to hand out --
	// an address it has never reached, or has stopped reaching. Nothing may
	// resolve through it, which is why Host and Target are blank; the refused
	// address and the reason travel together so a diagnosis needs one place.
	Suppressed       bool   `json:"suppressed"`
	SuppressedTarget string `json:"suppressedTarget"`
	SuppressReason   string `json:"suppressReason"`
	Healthy          bool   `json:"healthy"`
	LastOkUnixMs     int64  `json:"lastOkUnixMs"`
	LastError        string `json:"lastError"`
}

// ExtensionHosts is the full extension registry: one answer per area, plus
// every (hostId, area) the pool knows -- including the ones it refuses, so a
// second host advertising an area at an address nobody can reach is visible
// before a cycle needs it rather than after one fails.
type ExtensionHosts struct {
	Pool     string                   `json:"pool"`
	Areas    map[string]ExtensionHost `json:"areas"`
	Services []ExtensionHost          `json:"services"`
}

// ExtensionHost answers where one area is served, or ErrAreaNotServed when the
// pool knows no live host for it.
func (c *Client) ExtensionHost(ctx context.Context, area string) (ExtensionHost, error) {
	if !c.Configured() {
		return ExtensionHost{}, ErrNotConfigured
	}
	var e ExtensionHost
	err := c.getJSON(ctx, c.base+pathExtensionHosts+"?area="+url.QueryEscape(area), &e)
	if errors.Is(err, errNotFound) {
		// Two 404s land here and both mean "cannot answer": the handler's "no
		// live host for this area", and the Go mux's own 404 from an aggregator
		// built before the route existed. The caller's fallback is identical.
		return ExtensionHost{}, ErrAreaNotServed
	}
	if err != nil {
		return ExtensionHost{}, err
	}
	e.sanitize()
	return e, nil
}

// ExtensionHosts answers every area the pool can locate.
func (c *Client) ExtensionHosts(ctx context.Context) (ExtensionHosts, error) {
	if !c.Configured() {
		return ExtensionHosts{}, ErrNotConfigured
	}
	var out ExtensionHosts
	if err := c.getJSON(ctx, c.base+pathExtensionHosts, &out); err != nil {
		return ExtensionHosts{}, err
	}
	for area, e := range out.Areas {
		e.sanitize()
		out.Areas[area] = e
	}
	for i := range out.Services {
		out.Services[i].sanitize()
	}
	return out, nil
}

func (e *ExtensionHost) sanitize() {
	e.Target = SanitizeBaseURL(e.Target)
	e.SupersededTarget = SanitizeBaseURL(e.SupersededTarget)
	e.SuppressedTarget = SanitizeBaseURL(e.SuppressedTarget)
}

// Get decodes one JSON document from a path on THIS aggregator (e.g.
// "/api/v1/pool-stats?range=24h"), for the routes this package does not type.
func (c *Client) Get(ctx context.Context, path string, out any) error {
	if !c.Configured() {
		return ErrNotConfigured
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return c.getJSON(ctx, c.base+path, out)
}

// GetURL decodes one JSON document from an absolute URL, using the same
// transport posture. The pool is not the only thing an extension reads over
// this stance -- a host's own registration record is served by that host, over
// plain HTTP, and is fetched the same way.
func (c *Client) GetURL(ctx context.Context, rawURL string, out any) error {
	if strings.TrimSpace(rawURL) == "" {
		return ErrNotConfigured
	}
	return c.getJSON(ctx, rawURL, out)
}

// errNotFound distinguishes the aggregator's 404 from every other non-2xx, so
// ExtensionHost can map it onto ErrAreaNotServed without inspecting strings.
var errNotFound = errors.New("HTTP 404")

// get performs one request with the https-then-http candidate order, returning
// the body. A transport failure on an https base falls back to plain http; a
// protocol answer never does.
func (c *Client) get(ctx context.Context, rawURL string) ([]byte, error) {
	var lastErr error
	for _, candidate := range candidates(rawURL) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, candidate, nil)
		if err != nil {
			lastErr = err
			continue
		}
		resp, err := c.client.Do(req)
		if err != nil {
			lastErr = err
			continue // transport-level failure -> try the next candidate
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
		resp.Body.Close()
		if resp.StatusCode == http.StatusNotFound {
			return nil, errNotFound
		}
		if resp.StatusCode/100 != 2 {
			return nil, fmt.Errorf("GET %s: HTTP %d", candidate, resp.StatusCode)
		}
		if readErr != nil {
			return nil, readErr
		}
		return body, nil
	}
	return nil, lastErr
}

func (c *Client) getJSON(ctx context.Context, rawURL string, out any) error {
	body, err := c.get(ctx, rawURL)
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(body, out)
}

// candidates returns the URLs to try in order: the one given, plus its
// plain-http downgrade when it is https.
func candidates(rawURL string) []string {
	out := []string{rawURL}
	if rest, ok := strings.CutPrefix(rawURL, "https://"); ok {
		out = append(out, "http://"+rest)
	}
	return out
}

func (c *Client) cachedStatus() (Status, bool) {
	if c.cacheTTL <= 0 {
		return Status{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cached == nil || time.Since(c.cachedAt) >= c.cacheTTL {
		return Status{}, false
	}
	return cloneStatus(*c.cached), true
}

func (c *Client) cacheStatus(s Status) {
	if c.cacheTTL <= 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	snapshot := cloneStatus(s)
	c.cached = &snapshot
	c.cachedAt = time.Now()
}

// SanitizeBaseURL accepts a base URL only when it is an absolute http or https
// URL with a host, and returns "" otherwise. Every URL that reaches a caller
// from a pool response goes through this: the reads are unauthenticated, so a
// spoofed or poisoned response could otherwise supply a javascript: or data:
// value that a UI renders as an <a href> sink, and "" is the value every
// consumer already handles as "not resolvable".
func SanitizeBaseURL(raw string) string {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return ""
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "https":
		return raw
	}
	return ""
}

// cloneStatus gives each consumer ownership of all mutable snapshot fields.
func cloneStatus(s Status) Status {
	if s.Hosts == nil {
		return s
	}
	s.Hosts = append([]Host{}, s.Hosts...)
	for i := range s.Hosts {
		h := &s.Hosts[i]
		if h.ActiveExtensions != nil {
			h.ActiveExtensions = append([]string{}, h.ActiveExtensions...)
		}
		if h.PreviousHostIDs != nil {
			h.PreviousHostIDs = append([]string{}, h.PreviousHostIDs...)
		}
		if h.ExtensionTargets != nil {
			targets := make(map[string]string, len(h.ExtensionTargets))
			for k, v := range h.ExtensionTargets {
				targets[k] = v
			}
			h.ExtensionTargets = targets
		}
		if h.Status != nil {
			status := *h.Status
			h.Status = &status
		}
	}
	return s
}
