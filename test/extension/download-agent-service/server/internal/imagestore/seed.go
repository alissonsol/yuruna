// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"time"

	"download-agent-service/internal/config"
	"yuruna.com/test/extension/extension-sdk/pool"
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

// ArchesForHostType is the guest architectures a host type can run. Pool-status
// carries no arch field, so the answer is by host type alone: UTM is Apple
// Silicon and runs arm64 only, while Hyper-V and KVM ship on both.
//
// Both are named rather than the commoner one, because an arch left out here is
// left out of everything the scan builds -- no catalog row, no seed, and no drop
// folder -- and is then reachable only by a host request that resolves the
// family first. That escape does not exist for a best-effort family whose
// resolver is down: Ensure answers "unsupported" for an identity with no pointer
// while the resolver is unavailable, so the request that was supposed to create
// the entry never can, and the drop folder that would let an operator supply the
// media by hand was never created either. An ARM64 Hyper-V host asking for
// Windows 11 while Fido is refused is exactly that dead end.
//
// The cost is one extra seeded copy per stable family for the two both-arch host
// types. The best-effort families are not seeded at all, so the arch they gain
// costs a catalog row and a drop folder, not bandwidth.
func ArchesForHostType(hostType string) []string {
	switch hostType {
	case HostTypeUTM:
		return []string{ArchARM64}
	case HostTypeHyperV, HostTypeKVM:
		return []string{ArchAMD64, ArchARM64}
	default:
		return nil
	}
}

// SeedTargets expands host types into the stable-family identities the pass
// ensures exist, one per architecture the host type can run.
func SeedTargets(hostTypes []string) []ImageID {
	var out []ImageID
	for _, ht := range hostTypes {
		for _, arch := range ArchesForHostType(ht) {
			for _, key := range SeedFamilies {
				out = append(out, ImageID{HostType: ht, ImageKey: key, Arch: arch, Variant: VariantStable})
			}
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
		for _, arch := range ArchesForHostType(ht) {
			for _, key := range bestEffortKeysFor(ht) {
				id := ImageID{HostType: ht, ImageKey: key, Arch: arch, Variant: VariantStable}
				// Supported is what keeps virtio-win out of the arm64 pass: the
				// bundle carries x86-64 drivers only, so a row for it would
				// promise media that does not exist.
				if !Supported(id) {
					continue
				}
				out = append(out, id)
			}
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
