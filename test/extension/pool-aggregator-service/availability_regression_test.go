// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestPoolStatsRejectsEitherFailedLegWithoutCaching(t *testing.T) {
	for _, failedOutcome := range []string{"pass", "fail"} {
		t.Run(failedOutcome, func(t *testing.T) {
			var requests atomic.Int32
			stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				if strings.Contains(r.URL.Query().Get("query"), `overallStatus="`+failedOutcome+`"`) {
					http.Error(w, "rate limited", http.StatusTooManyRequests)
					return
				}
				fmt.Fprint(w, `{"data":{"result":[{"metric":{"hostId":"h1"},"value":[1,"7"]}]}}`)
			}))
			defer stub.Close()
			s := newStatsState(stub.URL)
			for i := 0; i < 2; i++ {
				w := httptest.NewRecorder()
				s.handlePoolStats(w, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=24h", nil))
				if w.Code != http.StatusBadGateway {
					t.Fatalf("response=%d %s", w.Code, w.Body.String())
				}
			}
			if len(s.statsCache) != 0 || requests.Load() != 4 {
				t.Fatalf("failed result cached: cache=%d requests=%d", len(s.statsCache), requests.Load())
			}
		})
	}
}

func TestThrottledLabRetriesDoNotAmplifyLokiWrites(t *testing.T) {
	var pushes atomic.Int32
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { pushes.Add(1); w.WriteHeader(http.StatusNoContent) }))
	defer stub.Close()
	s := newLabState("aaaaaa")
	s.httpClient = stub.Client()
	s.lokiURL = stub.URL
	for i := 0; i < labFailLimit; i++ {
		postLabToken(s, "192.168.7.5:1234", `{"labToken":"bbbbbb"}`)
	}
	before := pushes.Load()
	if before == 0 {
		t.Fatal("initial refusal burst was not audited")
	}
	for i := 0; i < 5; i++ {
		w := postLabToken(s, "192.168.7.5:1234", `{"labToken":"bbbbbb"}`)
		if w.Code != http.StatusTooManyRequests {
			t.Fatalf("retry response=%d", w.Code)
		}
	}
	if pushes.Load() != before {
		t.Fatalf("throttled retries added %d Loki writes", pushes.Load()-before)
	}
}

func TestReapedAndForgottenHostsLoseFootprint(t *testing.T) {
	s := newPoolState("default", 8080)
	now := time.Now()
	s.hostTtl = time.Hour
	s.hosts["old"] = &hostView{HostId: "old", LastSeenUnixMs: now.Add(-2 * time.Hour).UnixMilli()}
	s.footprint["old"] = &addressFootprintView{distinct: 4}
	s.pass["old"] = 3
	s.pollOnce(nil, "missing-squid-log", "", now)
	if s.footprint["old"] != nil {
		t.Fatal("reaped footprint retained")
	}
	// Even a stale footprint loaded separately cannot restore a departed host.
	s.footprint["old"] = &addressFootprintView{distinct: 4}
	w := httptest.NewRecorder()
	s.handleMetricsBody(w)
	body := w.Body.String()
	if !strings.Contains(body, "yuruna_pool_address_hosts_measured 0\n") || !strings.Contains(body, "yuruna_pool_address_distinct_total 0\n") {
		t.Fatal(body)
	}
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "yuruna_pool_host_address_") && strings.Contains(line, `hostId="old"`) {
			t.Fatalf("reaped metric: %s", line)
		}
	}
	s.forgetHost("old")
	if s.footprint["old"] != nil {
		t.Fatal("forgotten footprint retained")
	}
}

func TestBlockedArchiveProbeLeavesStateAvailable(t *testing.T) {
	s := newPoolState("default", 8080)
	s.archiveRoot = "fixture-share"
	entered, release, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	defer func() { close(release); <-finished }()
	go func() {
		defer close(finished)
		s.handleMetricsWithArchiveProbe(httptest.NewRecorder(), func(string) bool { close(entered); <-release; return false })
	}()
	<-entered
	unlocked := make(chan struct{})
	go func() { s.mu.Lock(); s.mu.Unlock(); close(unlocked) }()
	select {
	case <-unlocked:
	case <-time.After(time.Second):
		t.Fatal("archive probe held the global state lock")
	}
}

func TestServiceUnitForwardsGlobalizationEnvironment(t *testing.T) {
	data, err := os.ReadFile("pool-aggregator-service.service")
	if err != nil {
		t.Fatal(err)
	}
	start := ""
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "ExecStart=") {
			start = line
		}
	}
	for _, argument := range []string{"--language=${YURUNA_LANGUAGE}", "--allow-pseudo-locale=${YURUNA_ALLOW_PSEUDO_LOCALE}"} {
		if !strings.Contains(start, argument) {
			t.Fatalf("service unit drops %s", argument)
		}
	}
}
