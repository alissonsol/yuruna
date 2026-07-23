// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package beacon announces this service's presence to the pool aggregator so it
// appears in the Extension hosts table even without a host status-server probe.
// Mirrors the stash-service beacon: a hello on boot (retried until first
// success), a keep-alive every Interval, and an active:false goodbye on
// shutdown. Trusted-LAN posture: TLS verification is skipped and the payload
// carries no secret.
package beacon

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

const (
	postTimeout   = 10 * time.Second
	maxHelloRetry = time.Minute
)

// Beacon posts presence announcements for one (hostId, area).
type Beacon struct {
	AggregatorURL string
	HostID        string
	Area          string
	TargetPort    int
	Interval      time.Duration
	client        *http.Client
	helloRetry    time.Duration
}

// New builds a Beacon; Enabled() is false unless the aggregator URL, host id, and
// a positive interval are all set.
func New(aggregatorURL, hostID, area string, targetPort int, interval time.Duration) *Beacon {
	return &Beacon{
		AggregatorURL: strings.TrimRight(strings.TrimSpace(aggregatorURL), "/"),
		HostID:        strings.TrimSpace(hostID),
		Area:          area,
		TargetPort:    targetPort,
		Interval:      interval,
		client:        &http.Client{Timeout: postTimeout, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}},
		helloRetry:    10 * time.Second,
	}
}

// Enabled reports whether the beacon has enough config to run.
func (b *Beacon) Enabled() bool {
	return b.AggregatorURL != "" && b.HostID != "" && b.Interval > 0
}

// Run announces immediately (retrying until the first success), then re-announces
// every Interval, and posts an active:false goodbye when ctx is cancelled.
func (b *Beacon) Run(ctx context.Context) {
	if !b.Enabled() {
		return
	}
	for {
		if b.announce(ctx, true) {
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(b.helloRetry):
		}
	}
	ticker := time.NewTicker(b.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			b.goodbye()
			return
		case <-ticker.C:
			_ = b.announce(ctx, true)
		}
	}
}

func (b *Beacon) goodbye() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = b.announce(ctx, false)
}

// announce POSTs the presence payload to <aggregator>/announce, trying the
// configured URL first and, only on a transport failure, an http:// downgrade of
// an https:// URL. Returns true on any 2xx.
func (b *Beacon) announce(ctx context.Context, active bool) bool {
	body, _ := json.Marshal(map[string]any{
		"schemaVersion": 1,
		"hostId":        b.HostID,
		"area":          b.Area,
		"targetPort":    b.TargetPort,
		"active":        active,
	})
	candidates := []string{b.AggregatorURL}
	if strings.HasPrefix(b.AggregatorURL, "https://") {
		candidates = append(candidates, "http://"+strings.TrimPrefix(b.AggregatorURL, "https://"))
	}
	for _, base := range candidates {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/announce", bytes.NewReader(body))
		if err != nil {
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := b.client.Do(req)
		if err != nil {
			continue // transport failure -> try the next candidate
		}
		ok := resp.StatusCode >= 200 && resp.StatusCode < 300
		resp.Body.Close()
		return ok // a protocol answer (even non-2xx) is authoritative; do not downgrade
	}
	return false
}
