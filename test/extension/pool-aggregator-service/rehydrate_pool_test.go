// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 426d1075-c8e6-4345-a993-b438804330bc

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

type rehydratePoolTransport func(*http.Request) (*http.Response, error)

func (f rehydratePoolTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestRehydrateRegisteredPoolsPreservesCountsIncidentsAndDeduplication(t *testing.T) {
	const passHost = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const failHost = "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	now := time.Now().UTC().Truncate(time.Second)
	started := now.Add(-10 * time.Minute)
	stamp := fmt.Sprint(now.Add(-time.Minute).UnixNano())
	type stream struct {
		Labels map[string]string `json:"stream"`
		Values [][2]string       `json:"values"`
	}
	streams := []stream{
		{map[string]string{"pool": "red-lab", "src": "cycle"}, [][2]string{{stamp, `{"hostId":"` + passHost + `","cycleStartUtc":"pass-cycle","overallStatus":"pass","baseUrl":"http://192.0.2.10:8080"}`}}},
		{map[string]string{"pool": "blue-lab", "src": "cycle"}, [][2]string{{stamp, `{"hostId":"` + failHost + `","cycleStartUtc":"fail-cycle","overallStatus":"fail","failureClass":"network_timeout","baseUrl":"http://192.0.2.11:8080"}`}}},
		{map[string]string{"pool": "blue-lab", "src": "incident"}, [][2]string{{stamp, fmt.Sprintf(`{"hostId":%q,"event":"incident_open","incidentId":"original-incident","startedAt":%q,"failCount":3,"dominantClass":"network_timeout"}`, failHost, started.Format(time.RFC3339))}}},
		{map[string]string{"pool": "default", "src": "incident"}, [][2]string{{stamp, fmt.Sprintf(`{"event":"pool_incident_open","incidentId":"original-pool-incident","startedAt":%q,"affectedHostCount":3,"class":"network_timeout"}`, started.Format(time.RFC3339))}}},
	}
	selector := regexp.MustCompile(`pool(=~|=)"([^"]*)"`)
	loki := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query().Get("query")
		match := selector.FindStringSubmatch(query)
		if len(match) != 3 {
			http.Error(w, "missing pool selector", http.StatusBadRequest)
			return
		}
		var selected []stream
		for _, row := range streams {
			matchesPool := row.Labels["pool"] == match[2]
			if match[1] == "=~" {
				matchesPool, _ = regexp.MatchString("^(?:"+match[2]+")$", row.Labels["pool"])
			}
			wantIncidents := strings.Contains(query, `src="incident"`)
			if matchesPool && ((row.Labels["src"] == "incident") == wantIncidents) {
				selected = append(selected, row)
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"result": selected}})
	}))
	defer loki.Close()

	state := newPoolState("default", 8080)
	lokiURL := loki.URL + "/loki/api/v1/push"
	state.rehydrateFromLoki(lokiURL, "default", time.Hour, now)
	state.rehydrateIncidentsFromLoki(lokiURL, "default", time.Hour, now)
	passTotals, failTotals := state.view().CycleTotals()
	if passTotals[passHost] != 1 || failTotals[failHost] != 1 {
		t.Fatalf("registered-pool counters were lost: pass=%v fail=%v", passTotals, failTotals)
	}
	passCycle, _ := state.view().Cycle(passHost + "|pass-cycle")
	failCycle, _ := state.view().Cycle(failHost + "|fail-cycle")
	if passCycle.Status != "pass" || !passCycle.Counted ||
		failCycle.Status != "fail" || !failCycle.Counted {
		t.Fatal("terminal transitions must retain both deduplication records")
	}
	if len(state.view().FailWindow[failHost]) != 1 || state.view().FailWindow[failHost][0].Class != "network_timeout" {
		t.Fatalf("failure window was not restored: %+v", state.view().FailWindow[failHost])
	}
	incident := state.view().Incident[failHost]
	if incident == nil || incident.ID != "original-incident" || !incident.StartedAt.Equal(started) {
		t.Fatalf("original incident identity was lost: %+v", incident)
	}
	if state.view().PoolIncident == nil || state.view().PoolIncident.ID != "original-pool-incident" {
		t.Fatalf("collector-scoped incident was lost: %+v", state.view().PoolIncident)
	}

	cyclePushes := 0
	client := &http.Client{Transport: rehydratePoolTransport(func(r *http.Request) (*http.Response, error) {
		code, body := http.StatusOK, "{}"
		if r.Method == http.MethodPost {
			var payload struct {
				Streams []stream `json:"streams"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				return nil, err
			}
			for _, row := range payload.Streams {
				if row.Labels["src"] == "cycle" {
					cyclePushes++
				}
			}
			code = http.StatusNoContent
		} else {
			hid, cycle, status, pool := passHost, "pass-cycle", "pass", "red-lab"
			if r.URL.Hostname() == "192.0.2.11" {
				hid, cycle, status, pool = failHost, "fail-cycle", "fail", "blue-lab"
			}
			switch r.URL.Path {
			case "/runtime/status.json":
				body = fmt.Sprintf(`{"hostId":%q,"cycleStartUtc":%q,"overallStatus":%q,"lastFailure":{"failureClass":"network_timeout"}}`, hid, cycle, status)
			case "/runtime/host.registration.json":
				body = fmt.Sprintf(`{"poolId":%q}`, pool)
			default:
				code = http.StatusNotFound
			}
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	state.pollOnce(client, filepath.Join(t.TempDir(), "absent-squid.log"), "http://fixture.invalid/push", now.Add(time.Second))
	passTotals, failTotals = state.view().CycleTotals()
	if cyclePushes != 0 || passTotals[passHost] != 1 || failTotals[failHost] != 1 {
		t.Fatalf("first poll duplicated restored cycles: pushes=%d pass=%v fail=%v", cyclePushes, passTotals, failTotals)
	}
	if state.view().Incident[failHost] == nil || state.view().Incident[failHost].ID != "original-incident" {
		t.Fatal("first poll replaced the restored per-host incident")
	}
}
