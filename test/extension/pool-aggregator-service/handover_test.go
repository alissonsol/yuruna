// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	oldHandoverID = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	newHandoverID = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	thirdID       = "42cccccccccccccccccccccccccccccc"
)

func handoverState(t *testing.T) *poolState {
	t.Helper()
	s := newPoolState("default", 8080)
	s.handoverFile = filepath.Join(t.TempDir(), "handovers.json")
	s.authToken = "test-secret"
	s.hosts[oldHandoverID] = &hostView{HostId: oldHandoverID, BaseURL: "http://192.0.2.10:8080", CurrentIP: "192.0.2.10", Reachable: false}
	s.hosts[newHandoverID] = &hostView{HostId: newHandoverID, BaseURL: "http://192.0.2.10:8080", CurrentIP: "192.0.2.10", Reachable: true}
	return s
}

func TestHandoverPersistsRetirementAndCombinesCounts(t *testing.T) {
	s := handoverState(t)
	s.pass[oldHandoverID], s.pass[newHandoverID] = 3, 2
	s.fail[oldHandoverID], s.fail[newHandoverID] = 1, 4
	if err := s.handoverHost(oldHandoverID, newHandoverID); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.hosts[oldHandoverID]; ok {
		t.Fatal("retired host still appears in live state")
	}
	if base, _ := s.resolveHostBase(oldHandoverID, ""); base != "http://192.0.2.10:8080" {
		t.Fatalf("old host link does not resolve through the current identity: %q", base)
	}
	if err := os.Remove(s.handoverFile); err != nil {
		t.Fatal(err)
	}
	if err := s.handoverHost(oldHandoverID, newHandoverID); err != nil {
		t.Fatalf("handover retry: %v", err)
	}
	if _, err := os.Stat(s.handoverFile); err != nil {
		t.Fatalf("retry did not restore the durable ledger: %v", err)
	}
	if err := s.handoverHost(oldHandoverID, thirdID); err == nil {
		t.Fatal("conflicting handover accepted")
	}
	status := httptest.NewRecorder()
	s.handlePoolStatus(status, httptest.NewRequest(http.MethodGet, "/api/v1/pool-status", nil))
	if strings.Contains(status.Body.String(), oldHandoverID+`","currentIp`) {
		t.Fatalf("retired host appears as a live row: %s", status.Body.String())
	}
	if !strings.Contains(status.Body.String(), `"previousHostIds":["`+oldHandoverID+`"]`) {
		t.Fatalf("current host does not expose its previous ID: %s", status.Body.String())
	}
	metrics := httptest.NewRecorder()
	s.handleMetricsBody(metrics)
	if !strings.Contains(metrics.Body.String(), `yuruna_pool_cycles_pass_total{pool="default",hostId="`+newHandoverID+`"} 5`) ||
		!strings.Contains(metrics.Body.String(), `yuruna_pool_cycles_fail_total{pool="default",hostId="`+newHandoverID+`"} 5`) {
		t.Fatalf("counts were not combined under the current ID: %s", metrics.Body.String())
	}
	if strings.Contains(metrics.Body.String(), `yuruna_pool_cycles_pass_total{pool="default",hostId="`+oldHandoverID+`"}`) {
		t.Fatal("retired ID still has an exported counter")
	}
	restarted := newPoolState("default", 8080)
	restarted.handoverFile = s.handoverFile
	if err := restarted.loadHandovers(); err != nil {
		t.Fatal(err)
	}
	if restarted.seedHostStubLocked(oldHandoverID, "http://192.0.2.10:8080", time.Now()) {
		t.Fatal("Loki presence restored a retired host")
	}
	if got := canonicalHostID(restarted.handovers, oldHandoverID); got != newHandoverID {
		t.Fatalf("canonical ID after restart = %s", got)
	}
}

func TestHandoverRejectsUnsafePairsAndFailedPersistence(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*poolState)
	}{
		{"old still reachable", func(s *poolState) { s.hosts[oldHandoverID].Reachable = true }},
		{"new unreachable", func(s *poolState) { s.hosts[newHandoverID].Reachable = false }},
		{"different address", func(s *poolState) { s.hosts[newHandoverID].BaseURL = "http://192.0.2.11:8080" }},
		{"state directory missing", func(s *poolState) { s.handoverFile = filepath.Join(t.TempDir(), "missing", "handovers.json") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := handoverState(t)
			tc.edit(s)
			if err := s.handoverHost(oldHandoverID, newHandoverID); err == nil {
				t.Fatal("unsafe or non-durable handover accepted")
			}
			if s.handovers[oldHandoverID] != "" || s.hosts[oldHandoverID] == nil {
				t.Fatal("state changed before durable acceptance")
			}
		})
	}
}

func TestHandoverHTTPAuthAndHistory(t *testing.T) {
	s := handoverState(t)
	request := func(token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/api/v1/handover-host", strings.NewReader(`{"oldHostId":"`+oldHandoverID+`","newHostId":"`+newHandoverID+`"}`))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		s.handleHandoverHost(w, r)
		return w
	}
	if got := request("").Code; got != http.StatusUnauthorized {
		t.Fatalf("anonymous handover = %d", got)
	}
	malformed := httptest.NewRequest(http.MethodPost, "/api/v1/handover-host", strings.NewReader(`{"oldHostId":"`+oldHandoverID+`","newHostId":"`+newHandoverID+`"}{}`))
	malformed.Header.Set("Authorization", "Bearer test-secret")
	bad := httptest.NewRecorder()
	s.handleHandoverHost(bad, malformed)
	if bad.Code != http.StatusBadRequest || s.handovers[oldHandoverID] != "" {
		t.Fatalf("multiple JSON documents were accepted: %d", bad.Code)
	}
	if got := request("test-secret").Code; got != http.StatusOK {
		t.Fatalf("authorized handover = %d", got)
	}
	if got := request("test-secret").Code; got != http.StatusOK {
		t.Fatalf("idempotent replay = %d", got)
	}
	aliases := httptest.NewRecorder()
	s.handleHostAliases(aliases, httptest.NewRequest(http.MethodGet, "/api/v1/host-aliases?hostId="+newHandoverID, nil))
	var body struct {
		CanonicalHostID string   `json:"canonicalHostId"`
		HostIDs         []string `json:"hostIds"`
	}
	if err := json.Unmarshal(aliases.Body.Bytes(), &body); err != nil || body.CanonicalHostID != newHandoverID || len(body.HostIDs) != 2 {
		t.Fatalf("aliases: %s (%v)", aliases.Body.String(), err)
	}
	unauthorized := httptest.NewRecorder()
	s.handleHostHistory(unauthorized, httptest.NewRequest(http.MethodGet, "/api/v1/host-history?hostId="+newHandoverID, nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous raw history = %d", unauthorized.Code)
	}
}

func TestHandoverRejectsCorruptLedgerOnStartup(t *testing.T) {
	s := handoverState(t)
	if err := os.WriteFile(s.handoverFile, []byte(`{"version":1,"aliases":{"`+oldHandoverID+`":"`+newHandoverID+`","`+newHandoverID+`":"`+oldHandoverID+`"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := s.loadHandovers(); err == nil {
		t.Fatal("cyclic identity ledger accepted")
	}
}

func TestHandoverChainReplacesLedgerAndPreservesAllHistoricalIDs(t *testing.T) {
	s := handoverState(t)
	if err := s.handoverHost(oldHandoverID, newHandoverID); err != nil {
		t.Fatal(err)
	}
	s.hosts[newHandoverID].Reachable = false
	s.hosts[thirdID] = &hostView{HostId: thirdID, BaseURL: "http://192.0.2.10:8080", CurrentIP: "192.0.2.10", Reachable: true}
	if err := s.handoverHost(newHandoverID, thirdID); err != nil {
		t.Fatalf("second handover must replace the existing ledger: %v", err)
	}
	restarted := newPoolState("default", 8080)
	restarted.handoverFile = s.handoverFile
	if err := restarted.loadHandovers(); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{oldHandoverID, newHandoverID} {
		if got := canonicalHostID(restarted.handovers, id); got != thirdID {
			t.Fatalf("%s resolves to %s, want %s", id, got, thirdID)
		}
	}
}

func TestHostHistoryQueriesBothIdentitiesAndKeepsSourceIDs(t *testing.T) {
	s := handoverState(t)
	if err := s.handoverHost(oldHandoverID, newHandoverID); err != nil {
		t.Fatal(err)
	}
	var durationMu sync.Mutex
	var queriedDuration time.Duration
	loki := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query().Get("query")
		if !strings.Contains(query, oldHandoverID) || !strings.Contains(query, newHandoverID) || r.URL.Query().Get("limit") != "1000" {
			t.Errorf("history query did not cover both IDs: %s", query)
		}
		start, startErr := strconv.ParseInt(r.URL.Query().Get("start"), 10, 64)
		end, endErr := strconv.ParseInt(r.URL.Query().Get("end"), 10, 64)
		if startErr != nil || endErr != nil {
			t.Errorf("invalid history time bounds: start=%q end=%q", r.URL.Query().Get("start"), r.URL.Query().Get("end"))
		} else {
			durationMu.Lock()
			queriedDuration = time.Duration(end - start)
			durationMu.Unlock()
		}
		_, _ = fmt.Fprintf(w, `{"data":{"result":[{"stream":{"hostId":%q,"src":"cycle"},"values":[["10","old cycle"]]},{"stream":{"hostId":%q,"src":"event"},"values":[["20","new event"]]}]}}`, oldHandoverID, newHandoverID)
	}))
	defer loki.Close()
	s.lokiURL = loki.URL + "/loki/api/v1/push"
	s.httpClient = loki.Client()
	for _, tc := range []struct {
		window string
		want   time.Duration
	}{{"1h", time.Hour}, {"24h", 24 * time.Hour}, {"7d", 7 * 24 * time.Hour}, {"30d", 30 * 24 * time.Hour}} {
		t.Run(tc.window, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/api/v1/host-history?hostId="+newHandoverID+"&range="+tc.window, nil)
			req.Header.Set("Authorization", "Bearer test-secret")
			w := httptest.NewRecorder()
			s.handleHostHistory(w, req)
			if w.Code != http.StatusOK {
				t.Fatalf("history = %d: %s", w.Code, w.Body.String())
			}
			durationMu.Lock()
			gotDuration := queriedDuration
			durationMu.Unlock()
			if gotDuration != tc.want {
				t.Fatalf("queried %s for %s, want %s", gotDuration, tc.window, tc.want)
			}
			var result struct {
				CanonicalHostID string   `json:"canonicalHostId"`
				HostIDs         []string `json:"hostIds"`
				Entries         []struct {
					HostID string `json:"hostId"`
					Line   string `json:"line"`
				} `json:"entries"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if result.CanonicalHostID != newHandoverID || len(result.HostIDs) != 2 || len(result.Entries) != 2 || result.Entries[0].HostID != newHandoverID || result.Entries[1].HostID != oldHandoverID {
				t.Fatalf("merged history lost its source identities: %+v", result)
			}
		})
	}
}

func TestHandoverInvalidatesCachedPoolStatsAndCombinesLokiCounts(t *testing.T) {
	var seen []string
	loki := newLokiStub(t, map[string]int64{oldHandoverID: 3, newHandoverID: 2}, map[string]int64{oldHandoverID: 1, newHandoverID: 4}, &seen)
	defer loki.Close()
	s := handoverState(t)
	s.lokiURL = loki.URL + "/loki/api/v1/push"
	s.httpClient = loki.Client()
	first := httptest.NewRecorder()
	s.handlePoolStats(first, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=24h", nil))
	if !strings.Contains(first.Body.String(), oldHandoverID) {
		t.Fatal("pre-handover stats did not include the old identity")
	}
	if err := s.handoverHost(oldHandoverID, newHandoverID); err != nil {
		t.Fatal(err)
	}
	second := httptest.NewRecorder()
	s.handlePoolStats(second, httptest.NewRequest(http.MethodGet, "/api/v1/pool-stats?range=24h", nil))
	var result struct {
		Hosts []struct {
			HostID string `json:"hostId"`
			Passed int64  `json:"passed"`
			Failed int64  `json:"failed"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(second.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Hosts) != 1 || result.Hosts[0].HostID != newHandoverID || result.Hosts[0].Passed != 5 || result.Hosts[0].Failed != 5 || len(seen) != 4 {
		t.Fatalf("post-handover stats were stale or split: %+v, Loki queries %d", result, len(seen))
	}
}

func TestHandoverMetricsMapRetiredHistoryToTheLiveHost(t *testing.T) {
	s := handoverState(t)
	if err := s.handoverHost(oldHandoverID, newHandoverID); err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	s.handleMetricsBody(w)
	body := w.Body.String()
	for _, want := range []string{
		`yuruna_pool_host_canonical_info{hostId="` + oldHandoverID + `",canonicalHostId="` + newHandoverID + `"}`,
		`yuruna_pool_host_canonical_info{hostId="` + newHandoverID + `",canonicalHostId="` + newHandoverID + `"}`,
		`yuruna_pool_host_retired{hostId="` + oldHandoverID + `"} 1`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing dashboard identity metric %s", want)
		}
	}
	if strings.Contains(body, `yuruna_pool_host_info{pool="default",poolGuid="",hostId="`+oldHandoverID+`"`) {
		t.Fatal("retired host still exported as a live host")
	}
}

func TestHandoverDashboardGroupsRetiredCycleCounts(t *testing.T) {
	raw, err := os.ReadFile("grafana-pool-dashboard.json")
	if err != nil {
		t.Fatal(err)
	}
	var dashboard struct {
		Panels []struct {
			ID      int `json:"id"`
			Targets []struct {
				RefID string `json:"refId"`
				Expr  string `json:"expr"`
			} `json:"targets"`
			Transformations []struct {
				ID string `json:"id"`
			} `json:"transformations"`
		} `json:"panels"`
	}
	if err := json.Unmarshal(raw, &dashboard); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, panel := range dashboard.Panels {
		if panel.ID != 6 {
			continue
		}
		found = true
		expressions := map[string]string{}
		for _, target := range panel.Targets {
			expressions[target.RefID] = target.Expr
		}
		if !strings.Contains(expressions["A"], "unless on(hostId) yuruna_pool_host_retired") ||
			!strings.Contains(expressions["C"], "sum by (hostId)") ||
			!strings.Contains(expressions["D"], "sum by (hostId)") ||
			!strings.Contains(expressions["E"], "yuruna_pool_host_canonical_info") {
			t.Fatalf("host table no longer joins historical counts through the identity mapping: %+v", expressions)
		}
		// Grafana merges on every shared field, including __name__. Arithmetic
		// removes the mapping metric name so it can join host-info rows without
		// collapsing their missing canonicalHostId values into one blank row.
		const mappingQuery = "(topk(1, yuruna_pool_host_canonical_info) by (hostId)) * 1"
		if expressions["E"] != mappingQuery {
			t.Fatalf("identity mapping must drop its metric name before merging with host info: got %q, want %q", expressions["E"], mappingQuery)
		}
		var steps []string
		for _, step := range panel.Transformations {
			steps = append(steps, step.ID)
		}
		if !reflect.DeepEqual(steps, []string{"merge", "groupBy", "filterByValue", "organize"}) {
			t.Fatalf("host table transformations changed: %v", steps)
		}
	}
	if !found {
		t.Fatal("Pool hosts panel is absent")
	}

	// The proxy provisions a copy of this dashboard from cloud-init. A drifted
	// copy would leave a fresh proxy displaying the old split host rows.
	boot, err := os.ReadFile("../../../host/vmconfig/caching-proxy-service.base.user-data")
	if os.IsNotExist(err) {
		t.Skip("cloud-init source is absent from this staged module")
	}
	if err != nil {
		t.Fatal(err)
	}
	provisioned := string(boot)
	start := strings.Index(provisioned, "  - path: /var/lib/grafana/dashboards/pool.json")
	if start < 0 {
		t.Fatal("provisioned pool dashboard is absent")
	}
	provisioned = provisioned[start:]
	start = strings.Index(provisioned, "    content: |\n")
	end := strings.Index(provisioned, "\n  # See https://yuruna.link/429f3d06-0056")
	if start < 0 || end < 0 {
		t.Fatal("provisioned pool dashboard boundaries changed")
	}
	provisioned = provisioned[start+len("    content: |\n") : end]
	lines := strings.Split(provisioned, "\n")
	for i, line := range lines {
		if !strings.HasPrefix(line, "      ") {
			t.Fatalf("dashboard line %d has unexpected indentation", i+1)
		}
		lines[i] = strings.TrimPrefix(line, "      ")
	}
	var canonicalJSON, provisionedJSON any
	if err := json.Unmarshal(raw, &canonicalJSON); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(strings.Join(lines, "\n")), &provisionedJSON); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(canonicalJSON, provisionedJSON) {
		t.Fatal("cloud-init dashboard differs from its canonical source")
	}
}

func TestHandoverDeploymentIncludesStateAndSource(t *testing.T) {
	unit, err := os.ReadFile("pool-aggregator-service.service")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(unit), "StateDirectory=pool-aggregator-service") || !strings.Contains(string(unit), "-handover-state-file /var/lib/pool-aggregator-service/handovers.json") {
		t.Fatal("the service cannot persist the identity ledger")
	}
	boot, err := os.ReadFile("../../../host/vmconfig/caching-proxy-service.base.user-data")
	if os.IsNotExist(err) {
		t.Skip("cloud-init source is absent from this staged module")
	}
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(boot), "for f in main.go handover.go mcp.go") {
		t.Fatal("the proxy boot build omits handover.go")
	}
}
