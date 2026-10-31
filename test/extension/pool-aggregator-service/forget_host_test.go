// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42c9a568-2467-49a5-83be-789231071394

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func forgetReq(hid, bearer, method string) *http.Request {
	m := method
	if m == "" {
		m = http.MethodPost
	}
	req := httptest.NewRequest(m, "/api/v1/forget-host?hostId="+hid, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	return req
}

// A forget of a present host clears it from EVERY per-host map that feeds a metric,
// returns wasPresent=true, and 200s.
func TestForgetHostRemovesAllState(t *testing.T) {
	s := newPoolState("default", 8080)
	s.authToken = "sekret"
	hid := "42cafe0000000000000000000000dead"
	s.view().Hosts[hid] = &hostView{HostId: hid, LastSeenUnixMs: time.Now().UnixMilli()}
	s.seedCycle(hid, "cyc1", "pass", time.Now(), true)
	s.countCycles(hid, 2, 1)
	s.view().FailWindow[hid] = []failRec{{At: time.Now(), Class: "script_error"}}
	s.view().Incident[hid] = &incidentState{}
	s.view().Announce[announceKey(hid, "stash")] = &announceView{}

	rec := httptest.NewRecorder()
	s.handleForgetHost(rec, forgetReq(hid, "sekret", ""))

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (%s)", rec.Code, rec.Body.String())
	}
	var out struct {
		Forgotten  bool   `json:"forgotten"`
		HostId     string `json:"hostId"`
		WasPresent bool   `json:"wasPresent"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("bad json %q: %v", rec.Body.String(), err)
	}
	if !out.Forgotten || !out.WasPresent || out.HostId != hid {
		t.Fatalf("unexpected result: %+v", out)
	}
	passTotals, failTotals := s.view().CycleTotals()
	cycle, cycleHeld := s.view().Cycle(hid + "|cyc1")
	for name, present := range map[string]bool{
		"hosts":      mapHas(s.view().Hosts, hid),
		"pass":       mapHas(passTotals, hid),
		"fail":       mapHas(failTotals, hid),
		"failWindow": mapHas(s.view().FailWindow, hid),
		"incident":   mapHas(s.view().Incident, hid),
		"seen":       cycleHeld && cycle.Status != "",
		"seenAt":     cycleHeld && !cycle.ObservedAt.IsZero(),
		"counted":    cycle.Counted,
		"announce":   mapHas(s.view().Announce, announceKey(hid, "stash")),
	} {
		if present {
			t.Errorf("%s map still holds the forgotten host", name)
		}
	}
}

// mapHas reports whether a map has a key, for maps of any value type used above.
func mapHas[V any](m map[string]V, k string) bool { _, ok := m[k]; return ok }

// An absent host is a no-op success with wasPresent=false (idempotent).
func TestForgetHostAbsentIsWasPresentFalse(t *testing.T) {
	s := newPoolState("default", 8080)
	s.authToken = "sekret"
	rec := httptest.NewRecorder()
	s.handleForgetHost(rec, forgetReq("42aaaa0000000000000000000000beef", "sekret", ""))
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	var out struct {
		WasPresent bool `json:"wasPresent"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	if out.WasPresent {
		t.Error("wasPresent should be false for an absent host")
	}
}

// Auth + validation: no token -> 503, wrong method -> 405, bad bearer -> 401,
// malformed hostId -> 400.
func TestForgetHostAuthAndValidation(t *testing.T) {
	hid := "42cafe0000000000000000000000dead"

	sNoTok := newPoolState("default", 8080)
	rec := httptest.NewRecorder()
	sNoTok.handleForgetHost(rec, forgetReq(hid, "", ""))
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("no-token want 503, got %d", rec.Code)
	}

	s := newPoolState("default", 8080)
	s.authToken = "sekret"

	rec = httptest.NewRecorder()
	s.handleForgetHost(rec, forgetReq(hid, "sekret", http.MethodGet))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET want 405, got %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	s.handleForgetHost(rec, forgetReq(hid, "wrong", ""))
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("wrong-bearer want 401, got %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	s.handleForgetHost(rec, forgetReq("not-a-uuid", "sekret", ""))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("bad-id want 400, got %d", rec.Code)
	}
}
