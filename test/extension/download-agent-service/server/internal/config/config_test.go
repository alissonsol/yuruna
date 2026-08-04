// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package config

import (
	"path/filepath"
	"testing"
	"time"
)

// The values below are a cross-component contract: the bring-up script, the
// systemd unit, the host-side client and the pool layout all encode them
// independently. A silent change here would desynchronize them, so they are
// asserted rather than merely defaulted.
func TestFrozenDefaults(t *testing.T) {
	if PresenceArea != "download-agent-service" {
		t.Errorf("PresenceArea = %q", PresenceArea)
	}
	if DefaultHTTPAddress != "0.0.0.0:80" {
		t.Errorf("DefaultHTTPAddress = %q", DefaultHTTPAddress)
	}
	if DefaultPresenceInterval != 15*time.Minute {
		t.Errorf("DefaultPresenceInterval = %s", DefaultPresenceInterval)
	}
	if DefaultScanInterval != 15*time.Minute {
		t.Errorf("DefaultScanInterval = %s", DefaultScanInterval)
	}
	if DefaultFreshness != 24*time.Hour {
		t.Errorf("DefaultFreshness = %s", DefaultFreshness)
	}
	if DefaultPrefetchLead != 2*time.Hour {
		t.Errorf("DefaultPrefetchLead = %s", DefaultPrefetchLead)
	}
	if DefaultPoolDir != "/mnt/yuruna-pool" {
		t.Errorf("DefaultPoolDir = %q", DefaultPoolDir)
	}
	if DefaultAuthTokenFile != "/etc/yuruna/lab-auth.token" {
		t.Errorf("DefaultAuthTokenFile = %q", DefaultAuthTokenFile)
	}
	if MaxRequestBytes != 1<<20 {
		t.Errorf("MaxRequestBytes = %d", MaxRequestBytes)
	}
	if StagingMaxAge != 24*time.Hour {
		t.Errorf("StagingMaxAge = %s", StagingMaxAge)
	}
	if LeaseExpiryFactor != 3 {
		t.Errorf("LeaseExpiryFactor = %d", LeaseExpiryFactor)
	}
	if MaxSeedConcurrency != 2 {
		t.Errorf("MaxSeedConcurrency = %d", MaxSeedConcurrency)
	}
}

func TestPoolLayoutNames(t *testing.T) {
	if ImagesDirName != "images" || StagingDirName != ".staging" || LeaseFileName != ".agent-lease.json" {
		t.Errorf("layout names = %q %q %q", ImagesDirName, StagingDirName, LeaseFileName)
	}
	if SidecarSuffix != ".meta.json" {
		t.Errorf("SidecarSuffix = %q", SidecarSuffix)
	}
	if ServiceStateDirName != "download-agent-service" {
		t.Errorf("ServiceStateDirName = %q", ServiceStateDirName)
	}
	if got := PointerName("amd64", "stable"); got != "current.amd64.stable.json" {
		t.Errorf("PointerName = %q", got)
	}
	if got := PointerName("arm64", "daily"); got != "current.arm64.daily.json" {
		t.Errorf("PointerName = %q", got)
	}
}

func TestPathHelpersDeriveFromThePoolMount(t *testing.T) {
	pool := filepath.Join("mnt", "yuruna-pool")
	if got, want := ImagesDirFor(pool), filepath.Join(pool, "images"); got != want {
		t.Errorf("ImagesDirFor = %q, want %q", got, want)
	}
	if got, want := StateDirFor(pool), filepath.Join(pool, "download-agent-service"); got != want {
		t.Errorf("StateDirFor = %q, want %q", got, want)
	}
	if got, want := LeaseFileFor(pool), filepath.Join(pool, "images", ".agent-lease.json"); got != want {
		t.Errorf("LeaseFileFor = %q, want %q", got, want)
	}
	// No pool configured must not synthesize a path under the process's CWD.
	for name, got := range map[string]string{
		"ImagesDirFor": ImagesDirFor(""),
		"StateDirFor":  StateDirFor(""),
		"LeaseFileFor": LeaseFileFor(""),
	} {
		if got != "" {
			t.Errorf("%s(\"\") = %q, want empty", name, got)
		}
	}
}
