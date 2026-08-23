// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// mgrInfoSample is squid's own mgr:info layout, trimmed to the lines this
// daemon reads. It doubles as the record of what that format IS: squid can
// change these labels between releases, and when it does the panel goes quietly
// to zero rather than erroring, so the sample is the early warning.
const mgrInfoSample = `Squid Object Cache: Version 6.10
Build Info:
Service Name: squid
Start Time:	Wed, 20 Aug 2026 09:14:02 GMT
Current Time:	Wed, 20 Aug 2026 12:00:00 GMT
Connection information for squid:
	Number of HTTP requests received:	184213
	Request Hit Ratios:	5min: 71.4%, 60min: 68.2%
Cache information for squid:
	Storage Swap size:	3184920 KB
	Storage Mem size:	65536 KB
	Mean Object Size:	42.10 KB
Internal Data Structures:
	Total accounted:	 191284 KB
File descriptor usage for squid:
	Number of file desc currently in use:	  142
Resource usage for squid:
	UP Time:	9958.123 seconds
`

func TestSquidSummaryReadsTheFieldsThePanelShows(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, mgrPathPrefix) {
			t.Errorf("manager pages are read under %s, got %s", mgrPathPrefix, r.URL.Path)
		}
		_, _ = w.Write([]byte(mgrInfoSample))
	}))
	defer srv.Close()

	c := newSquidClient(strings.TrimPrefix(srv.URL, "http://"), "", 2*time.Second)
	got := c.summary()
	if !got.Reachable {
		t.Fatalf("summary of a live squid: %+v", got)
	}
	for _, tc := range []struct {
		field string
		got   any
		want  any
	}{
		{"version", got.Version, "6.10"},
		{"requestsTotal", got.RequestsTotal, int64(184213)},
		{"hitRatioPct (the 5min column)", got.HitRatioPct, 71.4},
		{"cacheSizeKB", got.CacheSizeKB, int64(3184920)},
		{"memoryUsageKB", got.MemoryUsageKB, int64(191284)},
		// A DIFFERENT quantity from memoryUsageKB above: the in-memory cache,
		// which the dashboard shows as "Cached (Mem)".
		{"memCacheSizeKB", got.MemCacheSizeKB, int64(65536)},
		{"fileDescriptorsInUse", got.FileDescCurrent, int64(142)},
		{"uptimeSeconds", got.UptimeSeconds, int64(9958)},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %v, want %v", tc.field, tc.got, tc.want)
		}
	}
}

func TestSquidManagerRefusalIsNotReportedAsDown(t *testing.T) {
	// 403 from the manager interface means one specific, actionable thing --
	// the manager ACL does not admit this reader -- and an operator who reads
	// it as "squid is down" goes looking at the wrong machine.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()

	c := newSquidClient(strings.TrimPrefix(srv.URL, "http://"), "", 2*time.Second)
	got := c.summary()
	if got.Reachable {
		t.Fatal("a refused manager page is not a reachable summary")
	}
	if !strings.Contains(got.Error, "manager ACL") {
		t.Errorf("the 403 must name the ACL as the cause, got %q", got.Error)
	}
}

func TestSquidManagerPasswordRidesInTheQuery(t *testing.T) {
	// Squid takes the manager password in the URL; there is no header form. If
	// this stops being sent the privileged pages answer 403 and look like an
	// ACL problem on the far end.
	var seen string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.URL.Query().Get("auth")
		_, _ = w.Write([]byte(mgrInfoSample))
	}))
	defer srv.Close()

	c := newSquidClient(strings.TrimPrefix(srv.URL, "http://"), "s3cret", 2*time.Second)
	_ = c.summary()
	if seen != "s3cret" {
		t.Errorf("manager auth = %q, want the configured password", seen)
	}
}

func TestUnconfiguredSquidSaysSoRatherThanDialing(t *testing.T) {
	c := newSquidClient("", "", time.Second)
	got := c.summary()
	if got.Reachable || got.Error == "" {
		t.Fatalf("an unconfigured client must report why: %+v", got)
	}
}

func TestRemoteSwitchStateIsInferredFromTheRunningConfig(t *testing.T) {
	// Off the box there is no drop-in to look at, so both switches are read out
	// of what squid says it is running. The commented lines are the trap: a
	// config dump carries the defaults as comments, and counting those would
	// report every proxy as offline.
	cfg := `# Configuration for squid
offline_mode on
#offline_mode off
acl yuruna_local src 10.0.0.0/8
miss_access deny all
http_access allow yuruna_local
`
	got := readSwitchesRemote(cfg)
	if !got.Offline {
		t.Error("offline_mode on must read as offline")
	}
	if !got.NoUpstream {
		t.Error("miss_access deny all is the no-upstream switch")
	}
	if got.Source != "mgr:config" {
		t.Errorf("source = %q, want mgr:config so a reader knows which view this is", got.Source)
	}
	if got.Detail == "" {
		t.Error("the weaker remote answer must say that it is inferred")
	}

	off := readSwitchesRemote("#offline_mode on\nhttp_access allow all\n")
	if off.Offline || off.NoUpstream {
		t.Errorf("commented directives must not count: %+v", off)
	}
}

func TestRegistryStateReadsCatalogCanaryAndPrewarm(t *testing.T) {
	dir := t.TempDir()
	// The real formats the VM writes: a shell-env meta file and a 5-column TSV.
	// Getting these wrong is invisible -- the fields simply stay zero.
	if err := os.WriteFile(filepath.Join(dir, "prewarm-meta.env"),
		[]byte("YURUNA_PREWARM_LAST_RUN=2026-08-20T10:00:00Z\nYURUNA_PREWARM_K8S_MINOR=31\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	rows := strings.Join([]string{
		"k8s\tregistry.k8s.io/pause:3.9\t200\t0.4\tresident",
		"k8s\tregistry.k8s.io/etcd:3.5\t200\t9.1\tcold",
		"cni\tghcr.io/flannel:v0.25\t000\t30.0\ttimeout",
	}, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(dir, "prewarm-rows.tsv"), []byte(rows), 0o644); err != nil {
		t.Fatal(err)
	}

	meta := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/zot-meta" {
			t.Errorf("canary read hit %s, want /zot-meta", r.URL.Path)
		}
		_, _ = w.Write([]byte("# HELP yuruna_zot_manifest_ok canary\n" +
			"yuruna_zot_manifest_ok 1\n" +
			"yuruna_zot_manifest_latency_seconds{repo=\"dotnet/sdk\",tag=\"10.0\"} 0.82\n"))
	}))
	defer meta.Close()

	zot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v2/_catalog" {
			t.Errorf("registry read hit %s, want the OCI catalog", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"repositories":["ubuntu","alpine","golang"]}`))
	}))
	defer zot.Close()

	got := newRegistryReader(zot.URL, meta.URL, dir, 2*time.Second).state()
	if !got.Reachable || got.Repositories != 3 {
		t.Fatalf("registry state: %+v", got)
	}
	if !got.CanaryOk || got.CanaryLatency != 0.82 {
		t.Errorf("canary not read from the exporter text: %+v", got)
	}
	if got.PrewarmLastRun != "2026-08-20T10:00:00Z" {
		t.Errorf("prewarmLastRun = %q", got.PrewarmLastRun)
	}
	// resident and cold both mean the mirror holds it; only the timeout does not.
	if got.PrewarmHeld != 2 || got.PrewarmTotal != 3 {
		t.Errorf("prewarm held/total = %d/%d, want 2/3", got.PrewarmHeld, got.PrewarmTotal)
	}
}

func TestAbsentPrewarmAndCanaryAreNotAnError(t *testing.T) {
	// A proxy that has never prewarmed is new, not broken; a REMOTE reader has
	// no state dir at all and must simply say less.
	zot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"repositories":[]}`))
	}))
	defer zot.Close()

	got := newRegistryReader(zot.URL, "", "", 2*time.Second).state()
	if !got.Reachable {
		t.Fatalf("registry state: %+v", got)
	}
	if got.Error != "" {
		t.Errorf("absent canary and prewarm must not be an error, got %q", got.Error)
	}
	if got.CanaryOk || got.PrewarmLastRun != "" || got.PrewarmTotal != 0 {
		t.Errorf("absent state must stay zero: %+v", got)
	}
}

func TestWriteFileAtomicLeavesNoPartialDropIn(t *testing.T) {
	// A squid reconfigure racing a half-written drop-in is a parse error that
	// takes the proxy down for every guest on the lab.
	dir := t.TempDir()
	path := filepath.Join(dir, "yuruna-offline.conf")
	if err := writeFileAtomic(path, "offline_mode on\n"); err != nil {
		t.Fatalf("writeFileAtomic: %v", err)
	}
	body, err := os.ReadFile(path)
	if err != nil || string(body) != "offline_mode on\n" {
		t.Fatalf("read back %q, %v", body, err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("the temp file must not survive: %v", entries)
	}
}
