// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 429a0e4e-88a5-49d2-a6f1-61d10586ba7a

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
	s.view().Hosts[hid] = &hostView{HostId: hid, BaseURL: host.URL,
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

// attemptRecordPath is the record path the runner gives an attempt generation.
func attemptRecordPath(generation, name string) string {
	digest := sha256.Sum256([]byte(generation))
	return fmt.Sprintf("runner-attempts/%x/%s", digest[:12], name)
}

// passingAttempts is a full 20-attempt window of passes, one an hour from start.
func passingAttempts(start time.Time) string {
	rows := make([]string, 0, 20)
	for i := range 20 {
		started := start.Add(time.Duration(i) * time.Hour)
		rows = append(rows, fmt.Sprintf(`{"attemptGeneration":"pass-%02d","startedAtUtc":%q,"finishedAtUtc":%q,"passed":true}`,
			i, started.Format(time.RFC3339), started.Add(time.Minute).Format(time.RFC3339)))
	}
	return strings.Join(rows, ",")
}

// A host that recovers pushes a failure out of its 20-attempt window within
// hours, and the index then keeps it in olderFailures without the passes that
// followed it. Only a cycle folder can show that one of those passes came before
// the clicked time.
func TestHostEventLinksOlderFailuresOutsideTheWindow(t *testing.T) {
	const hid = "4253419c1f0b45a08260f36a1521a857"
	const faultGeneration = "38eef067f5cd4c54966a2581e5cfca1b:283"
	const gateGeneration = "42a5c91668d041839cdf7299a452ea60:616"
	fault := attemptRecordPath(faultGeneration, "runner-fault.json")
	gate := attemptRecordPath(gateGeneration, "config-gate.json")
	index := `{"schemaVersion":1,"attempts":[` + passingAttempts(time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC)) + `],"olderFailures":[
		{"attemptGeneration":"` + faultGeneration + `","startedAtUtc":"2026-10-18T09:50:26Z","finishedAtUtc":"2026-10-18T09:50:39Z","passed":false,"failureClass":"inner_exited","recordPath":"` + fault + `"},
		{"attemptGeneration":"` + gateGeneration + `","startedAtUtc":"2026-10-17T01:38:00Z","finishedAtUtc":"2026-10-17T01:38:48Z","passed":false,"failureClass":"config_gate_failed","recordPath":"` + gate + `"}
	]}`
	var listing strings.Builder
	for _, leaf := range []string{"000090.2026-10-17.00-30-00", "000091.2026-10-17.03-00-00", "000100.2026-10-18.08-40-00", "000101.2026-10-18.10-52-00"} {
		fmt.Fprintf(&listing, "<a href=\"%s.%s/\">x</a>\n", leaf, hid)
	}
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/runtime/runner-attempts/index.json":
			fmt.Fprint(w, index)
		case "/log/":
			fmt.Fprint(w, listing.String())
		default:
			http.NotFound(w, r)
		}
	}))
	defer host.Close()
	s := newPoolState("default", 8080)
	s.httpClient = host.Client()
	s.view().Hosts[hid] = &hostView{HostId: hid, BaseURL: host.URL,
		Status: &hostStatus{OverallStatus: "pass", StartedAt: "2026-10-20T19:01:00Z", CycleFolderUrl: "log/000140.2026-10-20.19-01-00." + hid + "/"}}
	for _, tc := range []struct{ name, at, status, suffix string }{
		{"red runner-fault block opens its own record", "2026-10-18T10:00:00Z", "3", "/runtime/" + fault},
		{"yellow block opens its own preflight record", "2026-10-17T02:00:00Z", "9", "/runtime/" + gate},
		{"a cycle that began after the fault keeps the cycle link", "2026-10-18T11:30:00Z", "3", "/log/000101.2026-10-18.10-52-00." + hid + "/"},
		{"a yellow block after a later cycle began opens the attempt history", "2026-10-17T03:30:00Z", "9", "/#runner-attempts"},
		{"a yellow block never opens an older runner fault", "2026-10-18T10:00:00Z", "9", "/#runner-attempts"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			at, _ := time.Parse(time.RFC3339, tc.at)
			w := httptest.NewRecorder()
			s.handleGoHostEvent(w, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/go/host-event?host=%s&t=%d&status=%s", hid, at.UnixMilli(), tc.status), nil))
			if w.Code != http.StatusFound || w.Header().Get("Location") != host.URL+tc.suffix {
				t.Fatalf("code=%d location=%q, want %q", w.Code, w.Header().Get("Location"), host.URL+tc.suffix)
			}
		})
	}
}

// With no cycle placed at the clicked time the older failure is the only evidence
// that names the block. A listing that holds only later cycles answers with the
// oldest one it has, which began after the click and so places nothing.
func TestHostEventOpensOlderFailureWhenNoSourcePlacesTheCycle(t *testing.T) {
	const hid = "4253419c1f0b45a08260f36a1521a857"
	const faultGeneration = "38eef067f5cd4c54966a2581e5cfca1b:283"
	fault := attemptRecordPath(faultGeneration, "runner-fault.json")
	index := `{"schemaVersion":1,"attempts":[` + passingAttempts(time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC)) + `],"olderFailures":[
		{"attemptGeneration":"` + faultGeneration + `","startedAtUtc":"2026-10-18T09:50:26Z","finishedAtUtc":"2026-10-18T09:50:39Z","passed":false,"failureClass":"inner_exited","recordPath":"` + fault + `"}
	]}`
	for _, tc := range []struct{ name, listing string }{
		{"no source answers", ""},
		{"the listing holds only later cycles", `<a href="000101.2026-10-18.10-52-00.` + hid + `/">x</a>`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.URL.Path == "/runtime/runner-attempts/index.json":
					fmt.Fprint(w, index)
				case r.URL.Path == "/log/" && tc.listing != "":
					fmt.Fprint(w, tc.listing)
				default:
					http.NotFound(w, r)
				}
			}))
			defer host.Close()
			s := newPoolState("default", 8080)
			s.httpClient = host.Client()
			s.view().Hosts[hid] = &hostView{HostId: hid, BaseURL: host.URL,
				Status: &hostStatus{OverallStatus: "pass", StartedAt: "2026-10-20T19:01:00Z", CycleFolderUrl: "log/000140.2026-10-20.19-01-00." + hid + "/"}}
			at := time.Date(2026, 10, 18, 10, 0, 0, 0, time.UTC)
			w := httptest.NewRecorder()
			s.handleGoHostEvent(w, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/go/host-event?host=%s&t=%d&status=3", hid, at.UnixMilli()), nil))
			if w.Code != http.StatusFound || w.Header().Get("Location") != host.URL+"/runtime/"+fault {
				t.Fatalf("code=%d location=%q, want the older failure's record", w.Code, w.Header().Get("Location"))
			}
		})
	}
}

// The host page lists at most 30 older failures, so a link never opens one the
// page does not show.
func TestHostEventReadsAtMostThirtyOlderFailures(t *testing.T) {
	const hid = "4253419c1f0b45a08260f36a1521a857"
	older := make([]string, 0, 31)
	for i := range 31 {
		generation := fmt.Sprintf("42a5c91668d041839cdf7299a452ea60:%d", 700-i)
		finished := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC).Add(-time.Duration(i) * time.Hour)
		if i == 30 {
			finished = time.Date(2026, 10, 16, 1, 38, 48, 0, time.UTC)
		}
		older = append(older, fmt.Sprintf(`{"attemptGeneration":%q,"startedAtUtc":%q,"finishedAtUtc":%q,"passed":false,"failureClass":"config_gate_failed","recordPath":%q}`,
			generation, finished.Add(-time.Minute).Format(time.RFC3339), finished.Format(time.RFC3339), attemptRecordPath(generation, "config-gate.json")))
	}
	index := `{"schemaVersion":1,"attempts":[` + passingAttempts(time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC)) + `],"olderFailures":[` + strings.Join(older, ",") + `]}`
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/runtime/runner-attempts/index.json" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, index)
	}))
	defer host.Close()
	s := newPoolState("default", 8080)
	s.httpClient = host.Client()
	s.view().Hosts[hid] = &hostView{HostId: hid, BaseURL: host.URL, Status: &hostStatus{CycleFolderUrl: "log/previous-pass/"}}
	at := time.Date(2026, 10, 16, 2, 0, 0, 0, time.UTC)
	w := httptest.NewRecorder()
	s.handleGoHostEvent(w, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/go/host-event?host=%s&t=%d&status=9", hid, at.UnixMilli()), nil))
	if w.Code != http.StatusFound || w.Header().Get("Location") != host.URL+"/#runner-attempts" {
		t.Fatalf("the 31st older failure must not be linked: code=%d location=%q", w.Code, w.Header().Get("Location"))
	}
}

// The host page ignores an olderFailures value it cannot list, so a malformed
// one must not cost a click on a failure in the 20-attempt window its record.
func TestHostEventKeepsWindowLinksWhenOlderFailuresIsMalformed(t *testing.T) {
	const hid = "4253419c1f0b45a08260f36a1521a857"
	const generation = "42a5c91668d041839cdf7299a452ea60:616"
	gate := attemptRecordPath(generation, "config-gate.json")
	for _, tc := range []struct{ name, older string }{
		{"a string", `"not-a-list"`},
		{"an object", `{"attemptGeneration":"` + generation + `"}`},
		{"a list holding a non-object", `[1]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			index := `{"schemaVersion":1,"attempts":[
				{"attemptGeneration":"` + generation + `","startedAtUtc":"2026-10-18T01:38:00Z","finishedAtUtc":"2026-10-18T01:38:48Z","passed":false,"failureClass":"config_gate_failed","recordPath":"` + gate + `"}
			],"olderFailures":` + tc.older + `}`
			host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/runtime/runner-attempts/index.json" {
					http.NotFound(w, r)
					return
				}
				fmt.Fprint(w, index)
			}))
			defer host.Close()
			s := newPoolState("default", 8080)
			s.httpClient = host.Client()
			s.view().Hosts[hid] = &hostView{HostId: hid, BaseURL: host.URL, Status: &hostStatus{CycleFolderUrl: "log/previous-pass/"}}
			at := time.Date(2026, 10, 18, 1, 40, 0, 0, time.UTC)
			w := httptest.NewRecorder()
			s.handleGoHostEvent(w, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/go/host-event?host=%s&t=%d&status=9", hid, at.UnixMilli()), nil))
			if w.Code != http.StatusFound || w.Header().Get("Location") != host.URL+"/runtime/"+gate {
				t.Fatalf("code=%d location=%q, want the window failure's record", w.Code, w.Header().Get("Location"))
			}
		})
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
		{"older failure path escape", `{"schemaVersion":1,"attempts":[],"olderFailures":[{"attemptGeneration":"../../private","startedAtUtc":"2026-10-18T01:38:00Z","finishedAtUtc":"2026-10-18T01:38:48Z","failureClass":"config_gate_failed","recordPath":"https://example.invalid/"}]}`},
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
			s.view().Hosts[hid] = &hostView{BaseURL: host.URL, Status: &hostStatus{CycleFolderUrl: "log/previous-pass/"}}
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
