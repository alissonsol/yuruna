// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Squid's manager interface is reached as an ordinary proxy request for a
// cache_object-style URL. Both spellings work on a modern squid; the internal
// path is the one the exporter and the seed's meta-exporter already use, so it
// is the one this daemon speaks.
const mgrPathPrefix = "/squid-internal-mgr/"

// SquidSummary is the part of squid's state an operator asks about, which is a
// much smaller set than mgr:info returns. Everything here is a number or a
// string a dashboard cell can hold; the raw page stays available to anyone who
// wants it via squidclient.
type SquidSummary struct {
	Reachable       bool    `json:"reachable"`
	Version         string  `json:"version,omitempty"`
	UptimeSeconds   int64   `json:"uptimeSeconds,omitempty"`
	RequestsTotal   int64   `json:"requestsTotal,omitempty"`
	HitRatioPct     float64 `json:"hitRatioPct,omitempty"`
	CacheSizeKB     int64   `json:"cacheSizeKB,omitempty"`
	MemoryUsageKB   int64   `json:"memoryUsageKB,omitempty"`
	FileDescCurrent int64   `json:"fileDescriptorsInUse,omitempty"`
	Error           string  `json:"error,omitempty"`
}

// squidClient reads squid's manager pages. The address it talks to is the
// whole of what "local mode" and "remote mode" differ by for reads: on the box
// it is 127.0.0.1:3128, off the box it is the proxy VM's address, and the
// manager ACL plus cachemgr_passwd on that VM is what decides whether the
// second one is allowed to answer at all.
type squidClient struct {
	addr     string // host:port of the squid HTTP port
	password string // cachemgr_passwd for the privileged pages; empty for none
	http     *http.Client
}

func newSquidClient(addr, password string, timeout time.Duration) *squidClient {
	return &squidClient{
		addr:     addr,
		password: password,
		// No proxy from the environment: this daemon frequently runs INSIDE the
		// proxy VM, where inheriting http_proxy would send a request for squid's
		// own manager page back through squid.
		http: &http.Client{Timeout: timeout, Transport: &http.Transport{Proxy: nil}},
	}
}

// page fetches one manager page as text. A non-200 is returned as an error
// carrying the status, because 403 here means one specific, actionable thing
// -- the manager ACL does not admit this reader -- and it must not be
// flattened into "squid is down".
func (c *squidClient) page(name string) (string, error) {
	if c == nil || c.addr == "" {
		return "", fmt.Errorf("no squid address configured")
	}
	u := &url.URL{Scheme: "http", Host: c.addr, Path: mgrPathPrefix + name}
	if c.password != "" {
		// Squid takes the manager password in the URL for these pages; there is
		// no header form. It is a shared secret for read-only pages on a
		// trusted LAN, not a credential for anything that changes state.
		q := u.Query()
		q.Set("auth", c.password)
		u.RawQuery = q.Encode()
	}
	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return "", err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _, _ = io.Copy(io.Discard, resp.Body); _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode == http.StatusForbidden {
		return "", fmt.Errorf("squid refused the manager page %q (HTTP 403): the manager ACL does not admit this reader", name)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("squid manager page %q: HTTP %d", name, resp.StatusCode)
	}
	return string(body), nil
}

// summary reads mgr:info and reduces it. A failure is reported in the struct
// rather than returned, because "the proxy did not answer" is a status this
// endpoint exists to report, not an error that should blank the whole response
// -- the switches and the registry beside it may still be readable.
func (c *squidClient) summary() SquidSummary {
	body, err := c.page("info")
	if err != nil {
		return SquidSummary{Reachable: false, Error: err.Error()}
	}
	s := SquidSummary{Reachable: true}
	for _, line := range strings.Split(body, "\n") {
		label, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		label = strings.TrimSpace(label)
		value = strings.TrimSpace(value)
		switch {
		case strings.HasPrefix(label, "Squid Object Cache") || label == "Squid Cache":
			// The value reads "Version 6.10": the word is part of the line, not
			// part of the number.
			s.Version = firstToken(strings.TrimSpace(strings.TrimPrefix(value, "Version")))
		case label == "Start Time" || label == "Current Time":
			// Not carried: absolute times say nothing a reader cannot get from
			// uptime, and they drift between the two clocks involved.
		case strings.Contains(label, "Number of HTTP requests received"):
			s.RequestsTotal = parseInt(value)
		case strings.Contains(label, "Request Hit Ratios"):
			s.HitRatioPct = parsePercent(value)
		case strings.Contains(label, "Storage Swap size"):
			s.CacheSizeKB = parseInt(value)
		case strings.Contains(label, "Total accounted"):
			s.MemoryUsageKB = parseInt(value)
		case strings.Contains(label, "Number of file desc currently in use"):
			s.FileDescCurrent = parseInt(value)
		case label == "UP Time":
			s.UptimeSeconds = int64(parseFloat(value))
		}
	}
	return s
}

func firstToken(s string) string {
	if f := strings.Fields(s); len(f) > 0 {
		return f[0]
	}
	return ""
}

// parseInt takes the first numeric token of a squid stat line, which routinely
// carries a unit after it ("1234 KB") or a qualifier before the next field.
func parseInt(s string) int64 {
	for _, f := range strings.Fields(s) {
		if n, err := strconv.ParseInt(strings.TrimSuffix(f, ","), 10, 64); err == nil {
			return n
		}
	}
	return 0
}

func parseFloat(s string) float64 {
	for _, f := range strings.Fields(s) {
		if n, err := strconv.ParseFloat(strings.TrimSuffix(f, ","), 64); err == nil {
			return n
		}
	}
	return 0
}

// parsePercent reads the 5-minute column of a "Request Hit Ratios" line, which
// squid formats as "5min: 12.3%, 60min: 4.5%". The 5-minute figure is the one
// that answers "is the cache working right now".
func parsePercent(s string) float64 {
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if !strings.HasPrefix(part, "5min") {
			continue
		}
		_, value, ok := strings.Cut(part, ":")
		if !ok {
			continue
		}
		return parseFloat(strings.TrimSuffix(strings.TrimSpace(value), "%"))
	}
	return 0
}
