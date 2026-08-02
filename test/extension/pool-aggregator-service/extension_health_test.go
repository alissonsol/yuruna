// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The pool advertises an extension address only after it has reached that
// address itself. These cover the refusal of an address the pool cannot use
// (the registration check), the grace that carries a confirmed service through
// a restart, and the removal that follows when the silence outlasts it.

// seedExtensionHealth records a confirmed probe verdict, standing in for the one
// the poll loop takes. Tests that build state by hand need it: an address no
// probe has confirmed is refused by design.
func seedExtensionHealth(s *poolState, hostID, area, target string) {
	s.extHealth[announceKey(hostID, area)] = &extHealthView{
		Target: target, Confirmed: true, LastOkUnixMs: time.Now().UnixMilli(),
	}
}

// The failure this exists to prevent: a host resolves its service VM on a
// hypervisor-private network (the macOS shared vmnet), confirms it locally, and
// registers that address with the pool. Every other member then resolves an
// address it cannot route to. Unconfirmed, it is never handed out.
func TestUnconfirmedRegistrationIsNotResolvable(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "4287d16ff2c346a98ea90fd3a0c307da"
	now := time.Now()
	s.hosts[hid] = &hostView{
		HostId:           hid,
		ActiveExtensions: []string{stashArea},
		ExtensionTargets: map[string]string{stashArea: "http://192.168.64.13"},
		LastSeenUnixMs:   now.UnixMilli(),
	}
	if _, ok := s.resolveExtensionHostsLocked(now)[stashArea]; ok {
		t.Fatalf("an address the pool has never reached was served as the area's answer")
	}
	cand := s.extensionCandidatesLocked(now)[announceKey(hid, stashArea)]
	if !cand.Suppressed || cand.SuppressedTarget != "http://192.168.64.13" {
		t.Errorf("candidate = %+v, want it suppressed carrying the refused address", cand)
	}
	if cand.Target != "" {
		t.Errorf("target = %q, want it blank so nothing can resolve through it", cand.Target)
	}
}

// A reachable service is refused by nothing: confirmed, it resolves.
func TestConfirmedRegistrationResolves(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "4287d16ff2c346a98ea90fd3a0c307da"
	now := time.Now()
	s.hosts[hid] = &hostView{
		HostId:           hid,
		ActiveExtensions: []string{stashArea},
		ExtensionTargets: map[string]string{stashArea: "http://192.168.7.217"},
		LastSeenUnixMs:   now.UnixMilli(),
	}
	seedExtensionHealth(s, hid, stashArea, "http://192.168.7.217")
	if got := s.resolveExtensionHostsLocked(now)[stashArea].Host; got != "192.168.7.217" {
		t.Errorf("host = %q, want the confirmed 192.168.7.217", got)
	}
}

// A working service that goes quiet is carried through the grace: a restart, a
// renewed lease or a dropped packet must not empty the panel and stall every
// cycle that needs the service.
func TestConfirmedTargetSurvivesTheGrace(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "4287d16ff2c346a98ea90fd3a0c307da"
	now := time.Now()
	s.hosts[hid] = &hostView{
		HostId:           hid,
		ExtensionTargets: map[string]string{stashArea: "http://10.0.0.5"},
		LastSeenUnixMs:   now.UnixMilli(),
	}
	s.extHealth[announceKey(hid, stashArea)] = &extHealthView{
		Target: "http://10.0.0.5", Confirmed: true,
		LastOkUnixMs:    now.Add(-2 * time.Minute).UnixMilli(),
		FirstFailUnixMs: now.Add(-time.Minute).UnixMilli(),
		LastError:       "connect timeout",
	}
	entry, ok := s.resolveExtensionHostsLocked(now)[stashArea]
	if !ok {
		t.Fatalf("a confirmed service was dropped one minute into a %s grace", extensionHealthGrace)
	}
	if entry.Healthy {
		t.Errorf("healthy = true, want false while the address is not answering")
	}
	if entry.LastError == "" {
		t.Errorf("lastError is empty; the current failure must be reported even while the address is still served")
	}
}

// Past the grace it is refused. Same rule for a registration, which is merely
// suppressed (its host keeps re-asserting it), and for an announce, which is
// deleted outright by the poll.
func TestTargetRefusedPastTheGrace(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "4287d16ff2c346a98ea90fd3a0c307da"
	now := time.Now()
	s.hosts[hid] = &hostView{
		HostId:           hid,
		ExtensionTargets: map[string]string{stashArea: "http://10.0.0.5"},
		LastSeenUnixMs:   now.UnixMilli(),
	}
	s.extHealth[announceKey(hid, stashArea)] = &extHealthView{
		Target: "http://10.0.0.5", Confirmed: true,
		LastOkUnixMs:    now.Add(-30 * time.Minute).UnixMilli(),
		FirstFailUnixMs: now.Add(-extensionHealthGrace - time.Minute).UnixMilli(),
		LastError:       "connect timeout",
	}
	if _, ok := s.resolveExtensionHostsLocked(now)[stashArea]; ok {
		t.Errorf("an address unanswered for longer than %s was still served", extensionHealthGrace)
	}
}

// The removal an operator asked for: a service that stops answering leaves the
// pool. The registration side cannot be deleted (the owning host re-asserts it
// every poll), so only the announce entry goes.
func TestRefreshExtensionHealthDropsSilentAnnounce(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "422dd0cac87e4cc6831c3228f12ae689"
	now := time.Now()
	// An address nothing listens on: the probe fails without waiting out a
	// timeout, because a closed port refuses immediately.
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	target := dead.URL
	dead.Close()
	s.announce[announceKey(hid, stashArea)] = &announceView{
		HostId: hid, Area: stashArea, Target: target,
		LastSeenUnixMs: now.UnixMilli(), sourceIP: "127.0.0.1",
	}
	s.extHealth[announceKey(hid, stashArea)] = &extHealthView{
		Target: target, Confirmed: true,
		FirstFailUnixMs: now.Add(-extensionHealthGrace - time.Minute).UnixMilli(),
		LastError:       "connect refused",
	}
	s.refreshExtensionHealth(newInternalHTTPClient(probeTimeout), now)
	if _, ok := s.announce[announceKey(hid, stashArea)]; ok {
		t.Errorf("a service silent for longer than %s was kept in the announce view", extensionHealthGrace)
	}
}

// The probe itself: 200 from /healthz and nothing else counts as an answer.
func TestProbeExtensionTarget(t *testing.T) {
	client := newInternalHTTPClient(probeTimeout)
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == extensionHealthPath {
			_, _ = w.Write([]byte("ok"))
			return
		}
		http.NotFound(w, r)
	}))
	defer ok.Close()
	if err := probeExtensionTarget(client, ok.URL); err != nil {
		t.Errorf("live service: %v, want no error", err)
	}
	// A server that answers, but not as a service: an address hosting something
	// else entirely must not pass as the pool's stash.
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer other.Close()
	if err := probeExtensionTarget(client, other.URL); err == nil {
		t.Errorf("a server with no %s answered as a service", extensionHealthPath)
	}
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	deadURL := dead.URL
	dead.Close()
	if err := probeExtensionTarget(client, deadURL); err == nil {
		t.Errorf("a closed port answered as a service")
	}
}

// A live service is confirmed by the poll's own pass, and becomes resolvable.
// Needs a non-loopback listener: a loopback address is refused before any probe
// (it would send every consumer to its own machine), so a httptest server cannot
// stand in here.
func TestRefreshExtensionHealthConfirmsLiveTarget(t *testing.T) {
	lanIP := ""
	addrs, err := net.InterfaceAddrs()
	if err == nil {
		for _, a := range addrs {
			n, okAddr := a.(*net.IPNet)
			if !okAddr || n.IP.To4() == nil || n.IP.IsLoopback() || n.IP.IsLinkLocalUnicast() {
				continue
			}
			lanIP = n.IP.String()
			break
		}
	}
	if lanIP == "" {
		t.Skip("no non-loopback IPv4 on this machine to serve a probe from")
	}
	ln, err := net.Listen("tcp", net.JoinHostPort(lanIP, "0"))
	if err != nil {
		t.Skipf("cannot listen on %s: %v", lanIP, err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == extensionHealthPath {
			_, _ = w.Write([]byte("ok"))
			return
		}
		http.NotFound(w, r)
	})}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()
	target := "http://" + ln.Addr().String()

	s := newPoolState("default", 8080)
	hid := "422dd0cac87e4cc6831c3228f12ae689"
	now := time.Now()
	s.announce[announceKey(hid, stashArea)] = &announceView{
		HostId: hid, Area: stashArea, Target: target,
		LastSeenUnixMs: now.UnixMilli(), sourceIP: lanIP,
	}
	s.refreshExtensionHealth(newInternalHTTPClient(probeTimeout), now)
	h := s.extHealth[announceKey(hid, stashArea)]
	if h == nil || !h.Confirmed {
		t.Fatalf("health = %+v, want a confirmed verdict for a service answering %s", h, extensionHealthPath)
	}
	if got := s.resolveExtensionHostsLocked(now)[stashArea].Target; got != target {
		t.Errorf("target = %q, want the confirmed %s", got, target)
	}
}

// The addresses that are wrong on their face are refused without a probe. A host
// advertising 127.0.0.1 is telling every consumer to look on its own machine.
func TestExtensionTargetProblem(t *testing.T) {
	cases := []struct {
		target  string
		refused bool
	}{
		{"", false},
		{"http://192.168.7.217", false},
		{"https://stash.lab.local:8443", false},
		{"http://127.0.0.1", true},
		{"http://[::1]:8080", true},
		{"http://169.254.10.1", true},
		{"http://0.0.0.0", true},
		{"http://224.0.0.1", true},
		{"ftp://192.168.7.217", true},
		{"192.168.7.217", true},
	}
	for _, c := range cases {
		why := extensionTargetProblem(c.target)
		if (why != "") != c.refused {
			t.Errorf("extensionTargetProblem(%q) = %q, want refused=%v", c.target, why, c.refused)
		}
	}
}

// The listing reports the refused entry rather than hiding it: this is what
// Test-Config reads to say "two stash services registered, one unreachable"
// before a cycle starts instead of after it fails.
func TestExtensionHostsListingReportsSuppressed(t *testing.T) {
	s := newPoolState("default", 8080)
	good := "422dd0cac87e4cc6831c3228f12ae689"
	bad := "4287d16ff2c346a98ea90fd3a0c307da"
	now := time.Now()
	s.announce[announceKey(good, stashArea)] = &announceView{
		HostId: good, Area: stashArea, Target: "http://192.168.7.217",
		LastSeenUnixMs: now.UnixMilli(), sourceIP: "192.168.7.217",
	}
	seedExtensionHealth(s, good, stashArea, "http://192.168.7.217")
	s.hosts[bad] = &hostView{
		HostId:           bad,
		ActiveExtensions: []string{stashArea},
		ExtensionTargets: map[string]string{stashArea: "http://192.168.64.13"},
		LastSeenUnixMs:   now.UnixMilli(),
	}

	rec := httptest.NewRecorder()
	s.handleExtensionHosts(rec, httptest.NewRequest("GET", "/api/v1/extension-hosts", nil))
	var out struct {
		Areas    map[string]extensionHostEntry `json:"areas"`
		Services []extensionHostEntry          `json:"services"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got := out.Areas[stashArea].Host; got != "192.168.7.217" {
		t.Errorf("resolved host = %q, want the reachable 192.168.7.217", got)
	}
	if len(out.Services) != 2 {
		t.Fatalf("services = %d entries, want both stash registrations listed", len(out.Services))
	}
	var refused *extensionHostEntry
	for i := range out.Services {
		if out.Services[i].HostId == bad {
			refused = &out.Services[i]
		}
	}
	if refused == nil || !refused.Suppressed {
		t.Fatalf("the unreachable registration is missing or not marked suppressed: %+v", out.Services)
	}
	if refused.SuppressedTarget != "http://192.168.64.13" || refused.SuppressReason == "" {
		t.Errorf("refused entry = %+v, want the refused address and a reason", refused)
	}
}

// A suppressed row is kept out of the Extension hosts panel -- a service the
// pool refuses to resolve is not one a member can use -- and exported as an
// unreachable row instead, so the misconfiguration is visible rather than merely
// absent.
func TestMetricsSeparatesUnreachableExtension(t *testing.T) {
	s := newPoolState("default", 8080)
	hid := "4287d16ff2c346a98ea90fd3a0c307da"
	now := time.Now()
	s.hosts[hid] = &hostView{
		HostId:           hid,
		BaseURL:          "http://192.168.7.101:8080",
		ActiveExtensions: []string{stashArea},
		ExtensionTargets: map[string]string{stashArea: "http://192.168.64.13"},
		LastSeenUnixMs:   now.UnixMilli(),
	}
	rec := httptest.NewRecorder()
	s.handleMetrics(rec, httptest.NewRequest("GET", "/metrics", nil))
	body := rec.Body.String()
	if strings.Contains(body, "yuruna_pool_host_extension{") {
		t.Errorf("an unreachable service was listed as a usable extension host:\n%s", body)
	}
	if !strings.Contains(body, `yuruna_pool_extension_unreachable{pool="default",hostId="`+hid+`",area="stash-service",target="http://192.168.64.13"`) {
		t.Errorf("/metrics missing the unreachable row:\n%s", body)
	}
}
