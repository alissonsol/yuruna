// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

// TestHostTTLReapHonoursConfiguredWindow pins the configurable host-disappearance
// window: a host silent for longer than the configured TTL leaves the view, one
// inside it stays.
//
// The stale host is seeded WITHOUT CurrentIP on purpose. Probe candidates are the
// squid-log IPs unioned with every hv.CurrentIP, and each candidate is fetched
// with the *http.Client passed to pollOnce -- so a seeded IP plus the nil client
// this test uses would panic in the fetch rather than exercise the reap.
func TestHostTTLReapHonoursConfiguredWindow(t *testing.T) {
	s := newPoolState("default", 8080)
	s.hostTtl = 2 * time.Hour
	now := time.Now().UTC()

	s.hosts["stalehost1"] = &hostView{
		HostId:         "stalehost1",
		LastSeenUnixMs: now.Add(-3 * time.Hour).UnixMilli(),
	}
	s.hosts["freshhost1"] = &hostView{
		HostId:         "freshhost1",
		LastSeenUnixMs: now.Add(-1 * time.Hour).UnixMilli(),
	}

	// Dedup keys exercise the OTHER sweep in the same locked section, which is
	// gated on the derived seenTtl. Seeding them here is what pins the ordering
	// to behaviour: one key inside hostTtl+1h must survive the reap that removed
	// its own host row (else a returning host re-counts that cycle), and one past
	// it must go.
	s.seenAt["stalehost1|cycle-recent"] = now.Add(-150 * time.Minute) // < 3h, survives
	s.seen["stalehost1|cycle-recent"] = "pass"
	s.counted["stalehost1|cycle-recent"] = true
	s.seenAt["stalehost1|cycle-ancient"] = now.Add(-4 * time.Hour) // > 3h, swept
	s.seen["stalehost1|cycle-ancient"] = "pass"
	s.counted["stalehost1|cycle-ancient"] = true

	s.pollOnce(nil, "no-such-squid.log", "", now)

	s.mu.Lock()
	_, stale := s.hosts["stalehost1"]
	_, fresh := s.hosts["freshhost1"]
	_, dedupKept := s.seenAt["stalehost1|cycle-recent"]
	_, dedupSwept := s.seenAt["stalehost1|cycle-ancient"]
	s.mu.Unlock()

	if stale {
		t.Error("host silent past the configured host-ttl survived the reap")
	}
	if !fresh {
		t.Error("host inside the configured host-ttl was reaped")
	}
	if !dedupKept {
		t.Error("dedup key inside hostTtl+1h was swept with the host row; a returning host could re-count that cycle")
	}
	if dedupSwept {
		t.Error("dedup key older than hostTtl+1h was not swept, so the dedup set grows without bound")
	}
}

// TestSeenTTLDerivesFromHostTTL: the per-cycle dedup set must outlive the host
// row, or a host that is reaped and then re-appears re-counts a terminal cycle it
// was already counted for. Deriving rather than configuring is what makes that
// ordering impossible to invert. (It does not bound the cumulative pass/fail
// counters -- those are cleared only by forgetHost.)
func TestSeenTTLDerivesFromHostTTL(t *testing.T) {
	s := newPoolState("default", 8080)
	s.hostTtl = 2 * time.Hour
	if got, want := s.seenTtl(), 3*time.Hour; got != want {
		t.Fatalf("seenTtl = %v, want %v (hostTtl + 1h)", got, want)
	}
	if s.seenTtl() <= s.hostTtl {
		t.Fatalf("seenTtl %v must exceed hostTtl %v, or dedup state expires before the row and a returning host double-counts", s.seenTtl(), s.hostTtl)
	}
}

// TestDeepLinkLookbackFloor: the host TTL doubles as the Loki window that
// resolves a departed host's ADDRESS, the step /go/host and /go/cycle share. A
// short TTL must not shorten that below the dashboard's own default range, or a
// link the operator can still see returns 404 -- including the redirect that
// mints a control proof. (/go/cycle's cycle-folder match keeps its own fixed 6h
// window and is unaffected by this setting.)
func TestDeepLinkLookbackFloor(t *testing.T) {
	s := newPoolState("default", 8080)

	s.hostTtl = 2 * time.Hour
	if got := s.deepLinkLookback(); got != minDeepLinkLookback {
		t.Errorf("short host-ttl: deepLinkLookback = %v, want the %v floor", got, minDeepLinkLookback)
	}
	// Boundary: the comparison is strict, so a TTL exactly equal to the floor
	// falls through to the floor branch. Same answer, different code path.
	s.hostTtl = minDeepLinkLookback
	if got := s.deepLinkLookback(); got != minDeepLinkLookback {
		t.Errorf("host-ttl equal to the floor: deepLinkLookback = %v, want %v", got, minDeepLinkLookback)
	}

	s.hostTtl = 72 * time.Hour
	if got := s.deepLinkLookback(); got != 72*time.Hour {
		t.Errorf("long host-ttl: deepLinkLookback = %v, want it to follow the TTL up to %v", got, 72*time.Hour)
	}
}

// TestLastKnownBaseURLUsesTheFlooredLookback covers the one PRODUCTION call site.
// Without this the helper could be correct while nothing used it -- reverting the
// query back to the raw host TTL would leave deepLinkLookback an unused method,
// which Go accepts, and the pure-helper test above would still pass. Asserts on
// the `start` parameter the aggregator actually sends to Loki.
func TestLastKnownBaseURLUsesTheFlooredLookback(t *testing.T) {
	var gotStart string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotStart = r.URL.Query().Get("start")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"success","data":{"result":[]}}`))
	}))
	defer srv.Close()

	s := newPoolState("default", 8080)
	// lokiURL is the PUSH endpoint; the query URL is derived by swapping the
	// trailing "push", so a bare host:port here would build a malformed address
	// and silently issue no request at all.
	s.lokiURL = srv.URL + "/loki/api/v1/push"
	s.httpClient = srv.Client()
	s.hostTtl = 2 * time.Hour // below the floor

	before := time.Now().UTC()
	_ = s.lastKnownBaseURL("default", "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	if gotStart == "" {
		t.Fatal("no Loki query was issued, so the lookback wiring is untested")
	}
	startNs, err := strconv.ParseInt(gotStart, 10, 64)
	if err != nil {
		t.Fatalf("start param %q is not a nanosecond timestamp: %v", gotStart, err)
	}
	span := before.Sub(time.Unix(0, startNs).UTC())
	// A 2h TTL must still query the 24h floor, not 2h back.
	if span < minDeepLinkLookback-time.Minute {
		t.Errorf("query looked back %v; the floor is %v, so a deep link older than the TTL would 404", span, minDeepLinkLookback)
	}
}
