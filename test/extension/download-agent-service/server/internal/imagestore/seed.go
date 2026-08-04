// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"time"

	"download-agent-service/internal/config"
	"download-agent-service/internal/yex/pool"
)

// SeedFamilies are the stable families the auto-seed pass pre-downloads for
// every host type the aggregator reports. Daily variants stay demand-driven:
// daily is a per-host workaround choice, not a pool-wide default worth the
// bandwidth.
var SeedFamilies = []string{KeyUbuntuServer24, KeyUbuntuServer26, KeyUbuntuExtension, KeyAmazonLinux2023}

// SeedOutcome is the last auto-seed pass, surfaced in /api/v1/status and the UI.
type SeedOutcome struct {
	AtUTC        string   `json:"atUtc,omitempty"`
	HostTypes    []string `json:"hostTypes,omitempty"`
	SkippedHosts int      `json:"skippedHosts"`
	Started      int      `json:"started"`
	Deferred     int      `json:"deferred"`
	Error        string   `json:"error,omitempty"`
	Skipped      string   `json:"skipped,omitempty"`
}

// DeriveHostTypes turns a pool-status snapshot into the host types present in
// the pool. Hosts whose status is absent are counted and skipped -- their images
// arrive demand-driven on the host's first request -- and host types outside the
// known set are ignored rather than turned into stray pool directories.
func DeriveHostTypes(ps pool.Status) (hostTypes []string, skipped int) {
	present, skipped := ps.HostTypes()
	for _, ht := range present {
		if !knownHostType(ht) {
			continue
		}
		hostTypes = append(hostTypes, ht)
	}
	return hostTypes, skipped
}

func knownHostType(ht string) bool {
	for _, k := range HostTypes {
		if k == ht {
			return true
		}
	}
	return false
}

// ArchForHostType infers the guest architecture a host type runs. Pool-status
// carries no arch field, so the mapping is by host type: Hyper-V and KVM hosts
// are x86-64 in practice, UTM runs on Apple Silicon. An arm64 KVM host is
// covered demand-driven -- its first request creates the arm64 entry, which the
// scanner then maintains.
func ArchForHostType(hostType string) string {
	switch hostType {
	case HostTypeUTM:
		return ArchARM64
	case HostTypeHyperV, HostTypeKVM:
		return ArchAMD64
	default:
		return ""
	}
}

// SeedTargets expands host types into the stable-family identities the pass
// ensures exist.
func SeedTargets(hostTypes []string) []ImageID {
	var out []ImageID
	for _, ht := range hostTypes {
		arch := ArchForHostType(ht)
		if arch == "" {
			continue
		}
		for _, key := range SeedFamilies {
			out = append(out, ImageID{HostType: ht, ImageKey: key, Arch: arch, Variant: VariantStable})
		}
	}
	return out
}

// BestEffortKeys are the families whose availability is a property of the agent
// rather than of the identity, in display order.
var BestEffortKeys = []string{KeyWindows11, KeyVirtioWin}

// bestEffortKeysFor is which best-effort families a host type can use.
// virtio-win is KVM/QEMU only: a Hyper-V guest gets Microsoft's own drivers for
// its synthetic devices, and the UTM/ARM64 path installs the UTM guest-tools ISO
// instead, which that script fetches for itself.
func bestEffortKeysFor(hostType string) []string {
	switch hostType {
	case HostTypeKVM:
		return []string{KeyWindows11, KeyVirtioWin}
	case HostTypeHyperV, HostTypeUTM:
		return []string{KeyWindows11}
	default:
		return nil
	}
}

// BestEffortTargets expands host types into the best-effort identities the
// catalog always shows a row for. They are deliberately absent from SeedTargets:
// seeding a multi-gigabyte Windows ISO nobody has asked for would spend the
// pool's bandwidth on a family that may never be used. The row exists anyway,
// because a family missing from the table reads as a feature that does not
// exist, rather than one this agent cannot serve.
func BestEffortTargets(hostTypes []string) []ImageID {
	var out []ImageID
	for _, ht := range hostTypes {
		arch := ArchForHostType(ht)
		if arch == "" {
			continue
		}
		for _, key := range bestEffortKeysFor(ht) {
			id := ImageID{HostType: ht, ImageKey: key, Arch: arch, Variant: VariantStable}
			if !Supported(id) {
				continue
			}
			out = append(out, id)
		}
	}
	return out
}

// CatalogTargets is every identity the catalog shows a row for even with nothing
// on disk: the seeded families plus the best-effort ones.
func CatalogTargets(hostTypes []string) []ImageID {
	return append(SeedTargets(hostTypes), BestEffortTargets(hostTypes)...)
}

// seedPass pre-downloads the stable families for every host type the aggregator
// reports. It skips entirely in lease read-only mode (the holder is doing this),
// and never starts more than config.MaxSeedConcurrency downloads at once so
// seeding cannot starve an interactive host request.
func (a *Agent) seedPass(ctx context.Context, now time.Time) SeedOutcome {
	out := SeedOutcome{AtUTC: now.UTC().Format(time.RFC3339)}
	if !a.opts.AutoSeed {
		out.Skipped = "auto-seed disabled"
		return out
	}
	if a.lease.ReadOnly() {
		out.Skipped = "lease held by " + a.lease.Holder()
		return out
	}
	if !a.store.Available() {
		out.Skipped = "pool unavailable"
		return out
	}
	ps, err := a.pool.Status(ctx)
	if err != nil {
		out.Error = err.Error()
		return out
	}
	hostTypes, skipped := DeriveHostTypes(ps)
	out.HostTypes = hostTypes
	out.SkippedHosts = skipped
	a.setKnownHostTypes(hostTypes)

	for _, id := range SeedTargets(hostTypes) {
		if ctx.Err() != nil {
			break
		}
		if _, ok, err := a.store.ReadPointer(id); err == nil && ok {
			continue
		}
		if a.flights.SeedLen() >= config.MaxSeedConcurrency {
			out.Deferred++
			continue
		}
		if _, started := a.startRefresh(id, true); started {
			out.Started++
		}
	}
	return out
}
