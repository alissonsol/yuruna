// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// promTargetsFor runs the scrape-document handler over a prepared host view and
// returns the decoded answer.
func promTargetsFor(t *testing.T, s *poolState) []promTargetGroup {
	t.Helper()
	rec := httptest.NewRecorder()
	s.handlePrometheusTargets(rec, httptest.NewRequest(http.MethodGet, routePromTargets, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", rec.Code)
	}
	var got []promTargetGroup
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	return got
}

// TestPrometheusTargetsListsOnlyScrapableHosts: this document decides
// what the collector tries to reach, so what it must NOT contain is the part
// worth asserting -- a host of a type that runs no supported exporter, and a host
// that is currently off. Either one, listed, is a target that is down for as
// long as it stays listed.
func TestPrometheusTargetsListsOnlyScrapableHosts(t *testing.T) {
	s := newPoolState("default", defaultStatusPort)
	s.hosts["42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] = &hostView{
		HostId: "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", CurrentIP: "10.0.0.5", Reachable: true,
		Status: &hostStatus{Host: "host.windows.hyper-v"},
	}
	s.hosts["42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] = &hostView{
		HostId: "42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", CurrentIP: "10.0.0.6", Reachable: true,
		Status: &hostStatus{Host: "host.unsupported.vm"},
	}
	s.hosts["42cccccccccccccccccccccccccccccc"] = &hostView{
		HostId: "42cccccccccccccccccccccccccccccc", CurrentIP: "10.0.0.7", Reachable: false,
		Status: &hostStatus{Host: "host.windows.hyper-v"},
	}

	got := promTargetsFor(t, s)
	if len(got) != 1 {
		t.Fatalf("got %d target groups, want only the reachable Windows host: %+v", len(got), got)
	}
	if len(got[0].Targets) != 1 || got[0].Targets[0] != "10.0.0.5:9182" {
		t.Errorf("targets %v, want the host address at the exporter port", got[0].Targets)
	}
	want := map[string]string{
		"pool":         "default",
		"hostId":       "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"hostIdDashed": "42aaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
		"hostType":     "host.windows.hyper-v",
	}
	for k, v := range want {
		if got[0].Labels[k] != v {
			t.Errorf("label %s = %q, want %q", k, got[0].Labels[k], v)
		}
	}
	// A hostname here would put machine names into the pool's metrics, which
	// every other per-host series is deliberately free of.
	if _, bad := got[0].Labels["hostname"]; bad {
		t.Errorf("scrape document carries a hostname label: %v", got[0].Labels)
	}
}

// Unix memory metrics share the status listener, including a port learned
// through announce, rather than the Windows exporter port.
func TestPrometheusTargetsUnixUsesConfirmedStatusEndpoint(t *testing.T) {
	s := newPoolState("default", 18080)
	s.hostMetricsPort = 19182
	for _, hostType := range []string{"host.ubuntu.kvm", "host.macos.utm"} {
		t.Run(hostType, func(t *testing.T) {
			hv := &hostView{
				HostId: "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", CurrentIP: "10.0.0.6", Reachable: true,
				BaseURL: "http://10.0.0.6:28080", Status: &hostStatus{Host: hostType},
			}
			s.hosts[hv.HostId] = hv
			got := promTargetsFor(t, s)
			if len(got) != 1 || len(got[0].Targets) != 1 || got[0].Targets[0] != "10.0.0.6:28080" {
				t.Fatalf("target groups %+v, want the confirmed Unix status endpoint", got)
			}
			if got[0].Labels["hostId"] != hv.HostId || got[0].Labels["hostType"] != hostType {
				t.Fatalf("labels %v do not preserve the host identity and platform", got[0].Labels)
			}
			hv.CurrentIP, hv.BaseURL = "10.0.0.9", "http://10.0.0.9:38080"
			got = promTargetsFor(t, s)
			if got[0].Targets[0] != "10.0.0.9:38080" || got[0].Labels["hostId"] != hv.HostId {
				t.Fatalf("target groups %+v do not follow the Unix endpoint with stable identity", got)
			}
			hv.Reachable = false
			if got := promTargetsFor(t, s); len(got) != 0 {
				t.Fatalf("unreachable Unix host was published: %+v", got)
			}
		})
	}
}

// TestPrometheusTargetsFollowsTheAddressAndThePort: a host that renumbers must
// be scraped at its new address with nothing rewritten by hand, keeping the
// same identity, and the port must be the pool-wide setting rather than a
// constant frozen into the document.
func TestPrometheusTargetsFollowsTheAddressAndThePort(t *testing.T) {
	s := newPoolState("default", defaultStatusPort)
	s.hostMetricsPort = 19182
	hv := &hostView{
		HostId: "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", CurrentIP: "10.0.0.5", Reachable: true,
		Status: &hostStatus{Host: "host.windows.hyper-v"},
	}
	s.hosts[hv.HostId] = hv
	if got := promTargetsFor(t, s); got[0].Targets[0] != "10.0.0.5:19182" {
		t.Fatalf("target %q, want the configured exporter port", got[0].Targets[0])
	}
	hv.CurrentIP = "10.0.0.9"
	if got := promTargetsFor(t, s); got[0].Targets[0] != "10.0.0.9:19182" {
		t.Fatalf("target %q, want the host's new address", got[0].Targets[0])
	}
	if got := promTargetsFor(t, s); got[0].Labels["hostId"] != hv.HostId {
		t.Fatalf("hostId label changed with the address: %v", got[0].Labels)
	}
}

// TestPrometheusTargetsEmptyPoolIsAnEmptyDocument: Prometheus rejects a
// malformed body whole, so "no hosts yet" has to decode as a list, not as
// nothing at all.
func TestPrometheusTargetsEmptyPoolIsAnEmptyDocument(t *testing.T) {
	s := newPoolState("default", defaultStatusPort)
	rec := httptest.NewRecorder()
	s.handlePrometheusTargets(rec, httptest.NewRequest(http.MethodGet, routePromTargets, nil))
	if body := rec.Body.String(); body != "[]" {
		t.Fatalf("body %q, want an empty JSON list", body)
	}
}
