// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"download-agent-service/internal/yex/pool"
)

// poolStatusFixture is the aggregator's real serialization shape: hosts carry a
// nested status whose `host` field is the "host.<hostType>" prefixed form, and a
// host whose status server was unreachable serializes status as null.
const poolStatusFixture = `{
  "pool": "lab",
  "lastPollUtc": "2026-08-03T12:00:00Z",
  "hosts": [
    {"hostId": "aaaa", "currentIp": "10.0.0.1", "reachable": true,
     "status": {"hostId": "aaaa", "host": "host.windows.hyper-v", "overallStatus": "pass"}},
    {"hostId": "bbbb", "currentIp": "10.0.0.2", "reachable": true,
     "status": {"hostId": "bbbb", "host": "host.macos.utm", "overallStatus": "pass"}},
    {"hostId": "cccc", "currentIp": "10.0.0.3", "reachable": false, "status": null},
    {"hostId": "dddd", "currentIp": "10.0.0.4", "reachable": true,
     "status": {"hostId": "dddd", "host": "host.ubuntu.kvm", "overallStatus": "fail"}},
    {"hostId": "eeee", "currentIp": "10.0.0.5", "reachable": true,
     "status": {"hostId": "eeee", "host": "host.ubuntu.kvm", "overallStatus": "pass"}},
    {"hostId": "ffff", "currentIp": "10.0.0.6", "reachable": true,
     "status": {"hostId": "ffff", "host": "host.freebsd.bhyve", "overallStatus": "pass"}}
  ],
  "announcedExtensions": [{"hostId": "aaaa", "area": "stash-service", "active": true}]
}`

func TestDeriveHostTypesStripsThePrefixAndSkipsNullStatus(t *testing.T) {
	var ps pool.Status
	if err := json.Unmarshal([]byte(poolStatusFixture), &ps); err != nil {
		t.Fatalf("unmarshal fixture: %v", err)
	}
	hostTypes, skipped := DeriveHostTypes(ps)
	want := []string{HostTypeUTM, HostTypeKVM, HostTypeHyperV}
	// DeriveHostTypes sorts, so compare against the sorted expectation.
	wantSorted := []string{"macos.utm", "ubuntu.kvm", "windows.hyper-v"}
	if !reflect.DeepEqual(hostTypes, wantSorted) {
		t.Fatalf("hostTypes = %v, want %v (from %v)", hostTypes, wantSorted, want)
	}
	if skipped != 1 {
		t.Fatalf("skipped = %d, want 1 (the host with a null status)", skipped)
	}
}

func TestDeriveHostTypesIgnoresUnknownHostTypes(t *testing.T) {
	ps := pool.Status{Hosts: []pool.Host{
		{HostID: "x", Status: &pool.HostStatus{Host: "host.freebsd.bhyve"}},
	}}
	hostTypes, skipped := DeriveHostTypes(ps)
	if len(hostTypes) != 0 {
		t.Fatalf("hostTypes = %v, want none: an unknown host type must not become a pool directory", hostTypes)
	}
	if skipped != 0 {
		t.Fatalf("skipped = %d, want 0: an unknown host type is not a missing status", skipped)
	}
}

func TestDeriveHostTypesTreatsAnEmptyHostFieldAsMissingStatus(t *testing.T) {
	ps := pool.Status{Hosts: []pool.Host{{HostID: "x", Status: &pool.HostStatus{Host: "  "}}}}
	_, skipped := DeriveHostTypes(ps)
	if skipped != 1 {
		t.Fatalf("skipped = %d, want 1", skipped)
	}
}

func TestArchIsInferredFromTheHostType(t *testing.T) {
	// Pool-status carries no arch field; the mapping is the whole inference.
	for hostType, want := range map[string]string{
		HostTypeHyperV: ArchAMD64,
		HostTypeKVM:    ArchAMD64,
		HostTypeUTM:    ArchARM64,
	} {
		if got := ArchForHostType(hostType); got != want {
			t.Errorf("ArchForHostType(%q) = %q, want %q", hostType, got, want)
		}
	}
	if ArchForHostType("freebsd.bhyve") != "" {
		t.Error("an unknown host type must infer no arch")
	}
}

func TestSeedTargetsCoverTheStableFamiliesOnly(t *testing.T) {
	targets := SeedTargets([]string{HostTypeUTM})
	if len(targets) != len(SeedFamilies) {
		t.Fatalf("got %d targets for one host type, want %d", len(targets), len(SeedFamilies))
	}
	keys := map[string]bool{}
	for _, id := range targets {
		if id.HostType != HostTypeUTM {
			t.Errorf("target %s has the wrong host type", id)
		}
		if id.Arch != ArchARM64 {
			t.Errorf("target %s must inherit the host type's inferred arch", id)
		}
		if id.Variant != VariantStable {
			t.Errorf("target %s must be stable; daily is demand-driven", id)
		}
		keys[id.ImageKey] = true
	}
	for _, want := range []string{KeyUbuntuServer24, KeyUbuntuServer26, KeyUbuntuExtension, KeyAmazonLinux2023} {
		if !keys[want] {
			t.Errorf("seed targets are missing %s", want)
		}
	}
	if keys["guest.windows.11"] || keys["virtio-win"] {
		t.Error("best-effort families must not consume seed bandwidth")
	}
}

func TestSeedTargetsSkipHostTypesWithNoInferredArch(t *testing.T) {
	if got := SeedTargets([]string{"freebsd.bhyve"}); len(got) != 0 {
		t.Fatalf("got %d targets, want none", len(got))
	}
}

func TestThePoolClientReadsTheAggregatorSnapshot(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/pool-status" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(poolStatusFixture))
	}))
	defer srv.Close()

	c := pool.New(pool.Options{BaseURL: srv.URL + "/", CacheTTL: pool.NoCache})
	ps, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if len(ps.Hosts) != 6 {
		t.Fatalf("got %d hosts, want 6", len(ps.Hosts))
	}
	if _, err := pool.New(pool.Options{}).Status(context.Background()); err == nil {
		t.Error("an unset aggregator URL must be an error so the pass is skipped, not silently empty")
	}
}

func TestSeedPassSkipsInLeaseReadOnlyMode(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), AutoSeed: true, AggregatorURL: "http://aggregator.invalid"})
	// Force read-only by planting a live foreign lease.
	writeLease(t, a.lease.Path, Lease{HostID: "someone-else", RenewedAtUTC: fixedNow.UTC().Format(rfc3339)})
	a.lease.ConfirmDelay = 0
	if _, _, err := a.lease.Renew(fixedNow); err != nil {
		t.Fatal(err)
	}

	out := a.seedPass(context.Background(), fixedNow)
	if out.Skipped == "" {
		t.Fatal("a read-only agent must skip the seed pass and say why")
	}
	if out.Started != 0 {
		t.Fatalf("a read-only agent started %d seed downloads", out.Started)
	}
}

func TestSeedPassSkipsWhenAutoSeedIsOff(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), AutoSeed: false})
	out := a.seedPass(context.Background(), fixedNow)
	if out.Skipped != "auto-seed disabled" {
		t.Fatalf("Skipped = %q", out.Skipped)
	}
}
