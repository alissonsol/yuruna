// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestHostEventLinksRetainedPreflightAfterRecovery(t *testing.T) {
	const hid = "4253419c1f0b45a08260f36a1521a857"
	const generation = "42a5c91668d041839cdf7299a452ea60:616"
	digest := sha256.Sum256([]byte(generation))
	artifact := fmt.Sprintf("runner-attempts/%x/config-gate.json", digest[:12])
	const folder = "log/000001.2026-10-18.01-22-23." + hid + "/"
	index := `{"schemaVersion":1,"attempts":[
		{"attemptGeneration":"aaaaaaaaaaaaaaaaaaaaaaaa","startedAtUtc":"2026-10-18T01:43:00Z","finishedAtUtc":"2026-10-18T01:44:10Z","passed":true},
		{"attemptGeneration":"` + generation + `","startedAtUtc":"2026-10-18T01:38:00Z","finishedAtUtc":"2026-10-18T01:38:48Z","passed":false,"failureClass":"config_gate_failed","recordPath":"` + artifact + `"}
	]}`
	var reads atomic.Int32
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/runtime/runner-attempts/index.json" {
			t.Errorf("unexpected host request %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		reads.Add(1)
		fmt.Fprint(w, index)
	}))
	defer host.Close()
	s := newPoolState("default", 8080)
	s.httpClient = host.Client()
	s.hosts[hid] = &hostView{HostId: hid, BaseURL: host.URL,
		Status: &hostStatus{OverallStatus: "pass", StartedAt: "2026-10-18T01:22:23Z", CycleFolderUrl: folder}}
	for _, tc := range []struct {
		name, at, status, suffix string
		share                    bool
	}{
		{"failure after recovery", "01:40:00", "9", "/runtime/" + artifact, false},
		{"retry still in preflight", "01:43:30", "9", "/runtime/" + artifact, false},
		{"legacy red preflight", "01:40:00", "3", "/runtime/" + artifact, false},
		{"successful retry clears fault", "01:44:10", "", "/" + folder, false},
		{"cycle before fault", "01:37:24", "2", "/" + folder, false},
		{"cycle failure remains a cycle", "01:50:00", "3", "/" + folder, false},
		{"share cannot select a previous pass", "01:40:00", "9", "/runtime/" + artifact, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			at, _ := time.Parse(time.RFC3339, "2026-10-18T"+tc.at+"Z")
			request := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/go/host-event?host=%s&t=%d&status=%s", hid, at.UnixMilli(), tc.status), nil)
			w := httptest.NewRecorder()
			before := reads.Load()
			if tc.share {
				s.handleGoCycleShare(w, request)
			} else {
				s.handleGoHostEvent(w, request)
			}
			if w.Code != http.StatusFound || w.Header().Get("Location") != host.URL+tc.suffix {
				t.Fatalf("code=%d location=%q, want %q", w.Code, w.Header().Get("Location"), host.URL+tc.suffix)
			}
			if tc.status == "2" && reads.Load() != before {
				t.Fatal("passing cycle needlessly queried runner attempts")
			}
		})
	}
	// Existing cycle URLs keep their explicit cycle meaning at the same timestamp.
	w := httptest.NewRecorder()
	s.handleGoCycle(w, httptest.NewRequest(http.MethodGet, "/go/cycle?host="+hid+"&t=1792287600000", nil))
	if w.Header().Get("Location") != host.URL+"/"+folder {
		t.Fatalf("explicit cycle link changed: %q", w.Header().Get("Location"))
	}
}

func TestPreflightLinkFallbackAndPathContainment(t *testing.T) {
	const hid = "4253419c1f0b45a08260f36a1521a857"
	for _, tc := range []struct{ name, body string }{
		{"missing index", ""},
		{"invalid json", "not json"},
		{"unsupported version", `{"schemaVersion":2,"attempts":[]}`},
		{"expired evidence", `{"schemaVersion":1,"attempts":[]}`},
		{"malformed timestamp", `{"schemaVersion":1,"attempts":[{"attemptGeneration":"aaaaaaaaaaaaaaaaaaaaaaaa","startedAtUtc":"invalid","finishedAtUtc":"2026-10-18T01:38:48Z","failureClass":"config_gate_failed"}]}`},
		{"path escape", `{"schemaVersion":1,"attempts":[{"attemptGeneration":"../../private","startedAtUtc":"2026-10-18T01:38:00Z","finishedAtUtc":"2026-10-18T01:38:48Z","failureClass":"config_gate_failed","recordPath":"https://example.invalid/"}]}`},
		{"different fault", `{"schemaVersion":1,"attempts":[{"attemptGeneration":"aaaaaaaaaaaaaaaaaaaaaaaa","startedAtUtc":"2026-10-18T01:38:00Z","finishedAtUtc":"2026-10-18T01:38:48Z","failureClass":"runner_crash"}]}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if tc.body == "" {
					http.NotFound(w, r)
					return
				}
				fmt.Fprint(w, tc.body)
			}))
			defer host.Close()
			s := newPoolState("default", 8080)
			s.httpClient = host.Client()
			s.hosts[hid] = &hostView{BaseURL: host.URL, Status: &hostStatus{CycleFolderUrl: "log/previous-pass/"}}
			at, _ := time.Parse(time.RFC3339, "2026-10-18T01:40:00Z")
			w := httptest.NewRecorder()
			s.handleGoHostEvent(w, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/go/host-event?host=%s&t=%d&status=9", hid, at.UnixMilli()), nil))
			if w.Code != http.StatusFound || w.Header().Get("Location") != host.URL+"/#runner-attempts" {
				t.Fatalf("preflight click must fall back to retained attempts: code=%d location=%q", w.Code, w.Header().Get("Location"))
			}
		})
	}
}

func TestDashboardPreflightStateAndDiagnosticLink(t *testing.T) {
	data, err := os.ReadFile("grafana-pool-dashboard.json")
	if err != nil {
		t.Fatal(err)
	}
	var dashboard struct {
		Panels []struct {
			ID          int    `json:"id"`
			Title       string `json:"title"`
			FieldConfig struct {
				Defaults struct {
					Mappings []struct {
						Options map[string]struct{ Text, Color string } `json:"options"`
					} `json:"mappings"`
					Links []struct{ URL string } `json:"links"`
				} `json:"defaults"`
			} `json:"fieldConfig"`
		} `json:"panels"`
	}
	if err := json.Unmarshal(data, &dashboard); err != nil {
		t.Fatal(err)
	}
	for _, panel := range dashboard.Panels {
		if panel.ID != 7 {
			continue
		}
		if !strings.HasPrefix(panel.Title, "Host state") {
			t.Fatalf("timeline conflates host state with cycle outcome: %q", panel.Title)
		}
		mappings := panel.FieldConfig.Defaults.Mappings[0].Options
		if mappings["9"].Color != "#eab308" || mappings["9"].Text != "preflight failed" || mappings["3"].Color != "#ef4444" {
			t.Fatalf("preflight and cycle failures need distinct yellow/red mappings: %+v", mappings)
		}
		for _, link := range panel.FieldConfig.Defaults.Links {
			if strings.Contains(link.URL, "/go/host-event?") && strings.Contains(link.URL, "&status=${__value.raw}") {
				return
			}
		}
		t.Fatal("timeline lacks a diagnostic link carrying its observed state")
	}
	t.Fatal("host timeline is absent")
}
