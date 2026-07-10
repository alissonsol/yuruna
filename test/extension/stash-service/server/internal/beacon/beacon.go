// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package beacon self-announces this stash server's presence to the
// pool-aggregator (POST /announce) so the dashboard's Extension hosts row
// exists independently of the owning HOST's status server. The registration
// path (host.registration.json -> aggregator poll) requires a live status
// server on the host; after a host reboot that process is often not running,
// and the row would silently vanish even though the stash VM auto-started and
// serves fine. The beacon closes that gap from the service's own side: hello
// at startup, a re-announce every Interval (so the aggregator's announce TTL
// never expires while the service lives, and an aggregator restart re-learns
// the row within one period), and a best-effort goodbye at shutdown so a
// deliberately stopped service drops off the panel immediately instead of
// aging out.
//
// Identity: the announce carries the OWNING HOST's hostId (the same namespace
// as the pool table) plus this daemon's UI port; the aggregator derives the
// service URL from the connection's source address, so the beacon never has
// to discover its own IP and an announcer can only ever advertise itself.
package beacon

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// announceTimeout bounds one POST /announce attempt; goodbyeTimeout bounds the
// final shutdown announce, which runs on an already-cancelled parent context
// and must not delay process exit.
const (
	announceTimeout = 10 * time.Second
	goodbyeTimeout  = 5 * time.Second
	// maxHelloRetry caps the catch-up cadence while the FIRST announce has not
	// yet landed (e.g. the aggregator's VM is still booting after a whole-lab
	// restart). Once one hello succeeds the loop settles into Interval.
	maxHelloRetry = time.Minute
)

// Beacon periodically announces one extension service to the pool-aggregator.
type Beacon struct {
	AggregatorURL string        // aggregator base, e.g. https://<proxy>:9400
	HostID        string        // OWNING host's hostId (pool-table namespace)
	Area          string        // extension area, e.g. "stash-service"
	TargetPort    int           // this service's UI port (0 = no UI to link)
	Interval      time.Duration // steady-state re-announce period

	client     *http.Client
	helloRetry time.Duration // catch-up cadence before the first success (test-overridable)
}

// New builds a beacon. Enabled() reports whether the inputs are sufficient to
// run it; New never fails so main can construct unconditionally and branch on
// Enabled.
func New(aggregatorURL, hostID, area string, targetPort int, interval time.Duration) *Beacon {
	retry := maxHelloRetry
	if interval > 0 && interval < retry {
		retry = interval
	}
	return &Beacon{
		AggregatorURL: strings.TrimRight(strings.TrimSpace(aggregatorURL), "/"),
		HostID:        strings.TrimSpace(hostID),
		Area:          area,
		TargetPort:    targetPort,
		Interval:      interval,
		helloRetry:    retry,
		// The aggregator serves :9400 over TLS with the pool-CA leaf; on the
		// trusted LAN this non-secret presence write does not pin that CA
		// (encryption-without-pinning, the same posture as the UI's pool-status
		// read in resolve.go).
		client: &http.Client{
			Timeout: announceTimeout,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // trusted-LAN, non-secret presence announce
			},
		},
	}
}

// Enabled reports whether the beacon has everything it needs: an aggregator to
// announce to, a hostId to announce as, and a non-zero period.
func (b *Beacon) Enabled() bool {
	return b.AggregatorURL != "" && b.HostID != "" && b.Interval > 0
}

// Run announces until ctx is cancelled: hello at start (retried on the
// catch-up cadence until it first lands), a re-announce every Interval, and a
// goodbye once ctx is done. Blocks; callers run it in a goroutine and wait for
// it to return so the goodbye gets its bounded window before process exit.
func (b *Beacon) Run(ctx context.Context) {
	if !b.Enabled() {
		return
	}
	delay := time.Duration(0) // first attempt is immediate
	announced := false
	for {
		t := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			t.Stop()
			b.goodbye()
			return
		case <-t.C:
		}
		if err := b.announce(ctx, true); err != nil {
			if ctx.Err() == nil {
				log.Printf("presence beacon: announce to %s failed: %v", b.AggregatorURL, err)
			}
			if !announced {
				delay = b.helloRetry // keep catching up until the first success
				continue
			}
		} else if !announced {
			announced = true
			log.Printf("presence beacon: announced %s/%s to %s (re-announce every %s)", b.HostID, b.Area, b.AggregatorURL, b.Interval)
		}
		delay = b.Interval
	}
}

// goodbye sends the active=false announce on a fresh, bounded context (the
// run context is already cancelled when this fires). Best-effort: the
// aggregator's announce TTL reaps the row anyway if this never arrives.
func (b *Beacon) goodbye() {
	ctx, cancel := context.WithTimeout(context.Background(), goodbyeTimeout)
	defer cancel()
	if err := b.announce(ctx, false); err != nil {
		log.Printf("presence beacon: goodbye to %s failed: %v", b.AggregatorURL, err)
	} else {
		log.Printf("presence beacon: goodbye announced")
	}
}

// announce POSTs one presence record. It tries the configured URL first and,
// when that URL is https and the attempt fails at the transport level, retries
// the plain-http downgrade once: the aggregator serves TLS only when its
// proxy-CA leaf was minted, so an older proxy answers :9400 over plain HTTP
// (the same https-then-http candidate order the host-side pool notifier uses).
func (b *Beacon) announce(ctx context.Context, active bool) error {
	body, err := json.Marshal(map[string]any{
		"schemaVersion": 1,
		"hostId":        b.HostID,
		"area":          b.Area,
		"targetPort":    b.TargetPort,
		"active":        active,
	})
	if err != nil {
		return err
	}
	var lastErr error
	for _, base := range b.candidates() {
		req, rerr := http.NewRequestWithContext(ctx, http.MethodPost, base+"/announce", bytes.NewReader(body))
		if rerr != nil {
			lastErr = rerr
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		resp, derr := b.client.Do(req)
		if derr != nil {
			lastErr = derr
			continue // transport-level failure -> try the next candidate
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode/100 == 2 {
			return nil
		}
		// The aggregator answered: a non-2xx is a protocol answer (validation,
		// announce disabled), not a scheme mismatch -- do not downgrade over it.
		return fmt.Errorf("announce HTTP %d", resp.StatusCode)
	}
	return lastErr
}

// candidates returns the base URLs to try in order: the configured URL, plus
// its plain-http downgrade when the configured scheme is https.
func (b *Beacon) candidates() []string {
	out := []string{b.AggregatorURL}
	if rest, ok := strings.CutPrefix(b.AggregatorURL, "https://"); ok {
		out = append(out, "http://"+rest)
	}
	return out
}
