// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Host resolution (stash-service-ui.md §3.4). A stash's hostId is an opaque
// UUID; to build the remote-host deep-link (§8.3) the UI turns it into a
// reachable stash-UI base URL by reusing the pool-aggregator's existing
// hostId→address mapping rather than storing addresses in stash metadata.
//
// This is BEST-EFFORT and never a hard dependency: an unset/unreachable
// aggregator, or one that hasn't discovered the host (its discovery is
// proxy-traffic-driven), yields no URL and the UI shows the hostId alone.
//
// The resolver reads the aggregator's read-only /api/v1/pool-status snapshot
// and looks for the host's stashBaseUrl. That field is the §13 amendment the
// aggregator must carry; until it ships, resolution simply returns "" and
// the UI degrades gracefully (the wiring is in place, the link just doesn't
// appear yet).
package httpsrv

import (
	"crypto/tls"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// hostResolution caches a hostId→stashBaseUrl lookup briefly so repeated
// detail views don't hammer the aggregator.
type hostResolution struct {
	url string
	at  time.Time
}

type hostResolver struct {
	mu    sync.Mutex
	cache map[string]hostResolution
}

func newHostResolver() *hostResolver {
	return &hostResolver{cache: map[string]hostResolution{}}
}

const hostResolutionTTL = 30 * time.Second

// poolStatusHost is one entry in the aggregator's /api/v1/pool-status
// snapshot. Only the fields the stash UI needs are decoded; the snapshot is
// hostname-free by design, so nothing identifying is read.
type poolStatusHost struct {
	HostID       string `json:"hostId"`
	StashBaseURL string `json:"stashBaseUrl"`
}

// resolveStashBaseURL returns the reachable stash-UI base for hostID, or ""
// when it cannot be resolved. Cached for hostResolutionTTL.
func (s *Server) resolveStashBaseURL(hostID string) string {
	if s.aggregatorURL == "" || hostID == "" {
		return ""
	}
	now := time.Now()
	s.resolver.mu.Lock()
	if r, ok := s.resolver.cache[hostID]; ok && now.Sub(r.at) < hostResolutionTTL {
		s.resolver.mu.Unlock()
		return r.url
	}
	s.resolver.mu.Unlock()

	url := s.fetchStashBaseURL(hostID)
	s.resolver.mu.Lock()
	s.resolver.cache[hostID] = hostResolution{url: url, at: now}
	s.resolver.mu.Unlock()
	return url
}

// fetchStashBaseURL queries the aggregator and extracts the host's
// stashBaseUrl. Tolerant of two snapshot shapes: a bare array of hosts, or
// an object with a "hosts" array. Any error → "".
func (s *Server) fetchStashBaseURL(hostID string) string {
	req, err := http.NewRequest(http.MethodGet, s.aggregatorURL+"/api/v1/pool-status", nil)
	if err != nil {
		return ""
	}
	resp, err := s.aggregatorClient().Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024))
	if err != nil {
		return ""
	}
	for _, h := range parsePoolStatus(body) {
		if h.HostID == hostID {
			return sanitizeBaseURL(h.StashBaseURL)
		}
	}
	return ""
}

// sanitizeBaseURL accepts a base URL only if it is an absolute http/https
// URL with a host. The aggregator read uses InsecureSkipVerify on the
// trusted LAN, so a spoofed/poisoned response could otherwise supply a
// `javascript:`/`data:` value that the UI would render as an <a href> sink.
// This hard backstop (plus the front-end scheme guard + the page CSP) keeps
// a forged value from ever becoming an executable link. Returns "" on any
// non-http(s) or malformed value.
func sanitizeBaseURL(raw string) string {
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

func parsePoolStatus(body []byte) []poolStatusHost {
	// Shape 1: {"hosts":[...]}
	var wrapped struct {
		Hosts []poolStatusHost `json:"hosts"`
	}
	if err := json.Unmarshal(body, &wrapped); err == nil && len(wrapped.Hosts) > 0 {
		return wrapped.Hosts
	}
	// Shape 2: bare array [...]
	var arr []poolStatusHost
	if err := json.Unmarshal(body, &arr); err == nil && len(arr) > 0 {
		return arr
	}
	return nil
}

// aggregatorClient is the HTTP client for aggregator calls. The aggregator
// serves :9400 over TLS with the pool-CA leaf; on the trusted LAN the stash
// UI does not pin that CA (encryption-without-pinning, the same posture the
// runner's /metrics read uses), so verification is skipped for this
// best-effort, non-secret resolution call only.
func (s *Server) aggregatorClient() *http.Client {
	if s.httpClient != nil && strings.HasPrefix(s.aggregatorURL, "http://") {
		return s.httpClient
	}
	return &http.Client{
		Timeout: 4 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // trusted-LAN, non-secret pool-status read (§3.4)
		},
	}
}
