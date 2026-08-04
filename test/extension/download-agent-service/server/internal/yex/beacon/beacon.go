// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package beacon self-announces an extension service's presence to the
// pool-aggregator service (POST /announce), keeping the dashboard's Extension
// hosts row alive independently of the owning HOST's status service: a hello at
// startup (retried until it first lands), a re-announce every Interval, and a
// best-effort goodbye at shutdown.
//
// The owning host's registration record is the other source of that row, and it
// is read THROUGH that host's status service -- so the moment that process is
// down, which a host reboot routinely leaves behind, the row vanishes even
// though the service itself is up and serving. The beacon is what covers that
// window, which is why it must keep working when nothing else on the host does.
//
// Trusted-LAN posture: the aggregator serves :9400 with a leaf signed by the
// pool CA, which no guest has a trust-store entry for, so this non-secret
// presence write encrypts without pinning. Pinning the pool CA is the documented
// upgrade path, not a silent assumption.
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

const (
	// announceTimeout bounds one POST /announce attempt.
	announceTimeout = 10 * time.Second

	// goodbyeTimeout bounds the shutdown announce, which runs on an already-
	// canceled parent context and must not delay process exit.
	goodbyeTimeout = 5 * time.Second

	// firstHelloRetry is the wait after the first failed hello. An aggregator
	// that is not up yet is the normal case at boot (a whole-lab restart brings
	// the service VMs up alongside it), so the first retries stay quick.
	firstHelloRetry = 10 * time.Second

	// maxHelloRetry caps the catch-up cadence. An aggregator that is down for an
	// hour must not be polled every ten seconds for that hour, so the wait
	// doubles up to this ceiling. Once one hello succeeds the loop settles into
	// Interval.
	maxHelloRetry = time.Minute

	// announceBodyCap bounds the reply read. The body is discarded, but it must
	// be DRAINED rather than abandoned or the transport discards the connection
	// and every announce opens a fresh one, for the life of the lab.
	announceBodyCap = 1 << 16
)

// Beacon posts presence announcements for one (hostId, area).
type Beacon struct {
	AggregatorURL string        // aggregator base, e.g. https://<proxy>:9400
	HostID        string        // OWNING host's hostId (pool-table namespace)
	Area          string        // extension area, e.g. "stash-service"
	TargetPort    int           // this service's UI port (0 = no UI to link)
	Interval      time.Duration // steady-state re-announce period

	client     *http.Client
	helloRetry time.Duration // catch-up cadence before the first success (test-overridable)
}

// New builds a beacon. Enabled reports whether the inputs suffice to run it;
// New never fails, so a caller can construct unconditionally and branch on
// Enabled.
func New(aggregatorURL, hostID, area string, targetPort int, interval time.Duration) *Beacon {
	return &Beacon{
		AggregatorURL: strings.TrimRight(strings.TrimSpace(aggregatorURL), "/"),
		HostID:        strings.TrimSpace(hostID),
		Area:          area,
		TargetPort:    targetPort,
		Interval:      interval,
		helloRetry:    initialHelloRetry(interval),
		client: &http.Client{
			Timeout: announceTimeout,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}, //nolint:gosec // trusted-LAN, non-secret presence announce
			},
		},
	}
}

// initialHelloRetry is the first catch-up wait: the standard one, unless the
// steady-state period is shorter still (which only happens in tests and in a
// deliberately aggressive configuration, where retrying slower than the normal
// cadence would be absurd).
func initialHelloRetry(interval time.Duration) time.Duration {
	if interval > 0 && interval < firstHelloRetry {
		return interval
	}
	return firstHelloRetry
}

// nextHelloRetry doubles the wait between hello attempts up to maxHelloRetry.
func nextHelloRetry(d time.Duration) time.Duration {
	if d *= 2; d > maxHelloRetry {
		return maxHelloRetry
	}
	return d
}

// Enabled reports whether the beacon has everything it needs: an aggregator to
// announce to, a hostId to announce as, and a non-zero period.
func (b *Beacon) Enabled() bool {
	return b.AggregatorURL != "" && b.HostID != "" && b.Interval > 0
}

// Run announces until ctx is canceled: hello at start (retried on the doubling
// catch-up cadence until it first lands), a re-announce every Interval, and a
// goodbye once ctx is done. Blocks; callers run it in a goroutine and wait for
// it to return so the goodbye gets its bounded window before process exit.
func (b *Beacon) Run(ctx context.Context) {
	if !b.Enabled() {
		return
	}
	delay := time.Duration(0) // the first attempt is immediate
	retry := b.helloRetry
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
				log.Printf("presence beacon (%s): announce to %s failed: %v", b.Area, b.AggregatorURL, err)
			}
			if !announced {
				delay = retry
				retry = nextHelloRetry(retry)
				continue // keep catching up until the first success
			}
		} else if !announced {
			announced = true
			log.Printf("presence beacon (%s): announced %s to %s (re-announce every %s)", b.Area, b.HostID, b.AggregatorURL, b.Interval)
		}
		delay = b.Interval
	}
}

// goodbye sends the active=false announce on a fresh, bounded context (the run
// context is already canceled when this fires). Best-effort: the aggregator's
// announce TTL reaps the row anyway if it never arrives.
func (b *Beacon) goodbye() {
	ctx, cancel := context.WithTimeout(context.Background(), goodbyeTimeout)
	defer cancel()
	if err := b.announce(ctx, false); err != nil {
		log.Printf("presence beacon (%s): goodbye to %s failed: %v", b.Area, b.AggregatorURL, err)
	} else {
		log.Printf("presence beacon (%s): goodbye announced", b.Area)
	}
}

// announce POSTs one presence record. It tries the configured URL first and,
// when that URL is https and the attempt fails at the transport level, retries
// the plain-http downgrade once: the aggregator serves TLS only when its
// proxy-CA leaf was minted, so an older proxy answers :9400 over plain HTTP (the
// same https-then-http candidate order the host-side pool notifier uses).
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
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, announceBodyCap))
		resp.Body.Close()
		if resp.StatusCode/100 == 2 {
			return nil
		}
		// The aggregator answered: a non-2xx is a protocol answer (validation,
		// announce disabled), not a scheme mismatch -- do not downgrade over it,
		// or a rejected announce would be delivered twice.
		return fmt.Errorf("announce HTTP %d", resp.StatusCode)
	}
	return lastErr
}

// candidates returns the base URLs to try in order: the configured URL, plus its
// plain-http downgrade when the configured scheme is https.
func (b *Beacon) candidates() []string {
	out := []string{b.AggregatorURL}
	if rest, ok := strings.CutPrefix(b.AggregatorURL, "https://"); ok {
		out = append(out, "http://"+rest)
	}
	return out
}
