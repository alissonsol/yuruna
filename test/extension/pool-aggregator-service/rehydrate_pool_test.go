// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

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
	if state.pass[passHost] != 1 || state.fail[failHost] != 1 {
		t.Fatalf("registered-pool counters were lost: pass=%v fail=%v", state.pass, state.fail)
	}
	if state.seen[passHost+"|pass-cycle"] != "pass" || !state.counted[passHost+"|pass-cycle"] ||
		state.seen[failHost+"|fail-cycle"] != "fail" || !state.counted[failHost+"|fail-cycle"] {
		t.Fatal("terminal transitions must retain both deduplication records")
	}
	if len(state.failWindow[failHost]) != 1 || state.failWindow[failHost][0].class != "network_timeout" {
		t.Fatalf("failure window was not restored: %+v", state.failWindow[failHost])
	}
	incident := state.incident[failHost]
	if incident == nil || incident.id != "original-incident" || !incident.startedAt.Equal(started) {
		t.Fatalf("original incident identity was lost: %+v", incident)
	}
	if state.poolIncident == nil || state.poolIncident.id != "original-pool-incident" {
		t.Fatalf("collector-scoped incident was lost: %+v", state.poolIncident)
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
	if cyclePushes != 0 || state.pass[passHost] != 1 || state.fail[failHost] != 1 {
		t.Fatalf("first poll duplicated restored cycles: pushes=%d pass=%v fail=%v", cyclePushes, state.pass, state.fail)
	}
	if state.incident[failHost] == nil || state.incident[failHost].id != "original-incident" {
		t.Fatal("first poll replaced the restored per-host incident")
	}
}
