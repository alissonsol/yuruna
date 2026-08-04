// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func newTestLease(t *testing.T, hostID string) *LeaseManager {
	t.Helper()
	m := NewLeaseManager(filepath.Join(t.TempDir(), ".agent-lease.json"), hostID, "yuruna-download-agent-service", 45*time.Minute)
	m.ConfirmDelay = 0
	return m
}

func writeLease(t *testing.T, path string, l Lease) {
	t.Helper()
	b, err := json.Marshal(l)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLeaseAcquiresWhenTheFileIsAbsent(t *testing.T) {
	m := newTestLease(t, "host-a")
	readOnly, holder, err := m.Renew(time.Now())
	if err != nil {
		t.Fatalf("Renew: %v", err)
	}
	if readOnly {
		t.Fatal("an absent lease must be acquirable")
	}
	if holder != "host-a" {
		t.Fatalf("holder = %q, want host-a", holder)
	}
	if m.ReadOnly() {
		t.Fatal("ReadOnly must agree with the Renew verdict")
	}
}

func TestLeaseDefersToALiveForeignHolder(t *testing.T) {
	m := newTestLease(t, "host-a")
	now := time.Now()
	writeLease(t, m.Path, Lease{HostID: "host-b", VMName: "other", RenewedAtUTC: now.Add(-time.Minute).UTC().Format(time.RFC3339)})

	readOnly, holder, err := m.Renew(now)
	if err != nil {
		t.Fatalf("Renew: %v", err)
	}
	if !readOnly {
		t.Fatal("a live foreign lease must put this agent in read-only mode")
	}
	if holder != "host-b" {
		t.Fatalf("holder = %q, want host-b", holder)
	}
	// The foreign lease must be left exactly as it was: stamping over it would
	// make both agents believe they hold it.
	b, err := os.ReadFile(m.Path)
	if err != nil {
		t.Fatal(err)
	}
	var back Lease
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if back.HostID != "host-b" {
		t.Fatalf("a deferring agent overwrote the holder's lease: %+v", back)
	}
}

func TestLeaseTakesOverAnExpiredForeignHolder(t *testing.T) {
	m := newTestLease(t, "host-a")
	now := time.Now()
	// Expiry is 3 x the scan interval; anything past that is abandoned.
	writeLease(t, m.Path, Lease{HostID: "host-b", RenewedAtUTC: now.Add(-2 * time.Hour).UTC().Format(time.RFC3339)})

	readOnly, holder, err := m.Renew(now)
	if err != nil {
		t.Fatalf("Renew: %v", err)
	}
	if readOnly {
		t.Fatal("an expired foreign lease must be takeable")
	}
	if holder != "host-a" {
		t.Fatalf("holder = %q, want host-a", holder)
	}
}

func TestLeaseReadBackConfirmationLosesToACompetingWriter(t *testing.T) {
	m := newTestLease(t, "host-a")
	now := time.Now()
	// The competing writer lands inside the confirmation window, so the read-back
	// finds someone else's identity and acquisition must not be claimed. The
	// window is entered through the manager's own hook rather than by racing two
	// sleeps, and the writer reports its outcome over a channel: a t.Fatal from
	// a non-test goroutine only ends that goroutine, and can panic outright if
	// the test has already finished.
	writeErr := make(chan error, 1)
	m.onWrote = func() {
		b, err := json.Marshal(Lease{HostID: "host-b", RenewedAtUTC: now.UTC().Format(time.RFC3339)})
		if err != nil {
			writeErr <- err
			return
		}
		writeErr <- os.WriteFile(m.Path, b, 0o644)
	}

	readOnly, holder, err := m.Renew(now)
	if err != nil {
		t.Fatalf("Renew: %v", err)
	}
	if werr := <-writeErr; werr != nil {
		t.Fatalf("planting the competing lease: %v", werr)
	}
	if !readOnly || holder != "host-b" {
		t.Fatalf("read-back confirmation did not detect the competing writer: readOnly=%v holder=%q", readOnly, holder)
	}
}

func TestAnUnreadableLeaseIsDeferredToThenTakenOver(t *testing.T) {
	m := newTestLease(t, "host-a")
	now := time.Now()
	// A half-written or corrupt lease is most likely another agent's write
	// landing right now. Reading it as "absent" would make both agents writers,
	// which is the exact duplication the lease exists to prevent.
	if err := os.WriteFile(m.Path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	readOnly, holder, err := m.Renew(now)
	if err != nil {
		t.Fatalf("Renew: %v", err)
	}
	if !readOnly {
		t.Fatal("an unreadable lease must be deferred to, not treated as free")
	}
	if holder == "host-a" {
		t.Fatalf("holder = %q; an agent that cannot read the lease has not acquired it", holder)
	}
	if m.LastError() == "" {
		t.Fatal("the parse failure must reach the status page; it is the only sign the lease is garbage")
	}

	// It is deferred to for one expiry window only. Past that the file is not a
	// racing write but debris, and a pool with no writer at all is worse.
	readOnly, holder, err = m.Renew(now.Add(m.Expiry + time.Minute))
	if err != nil {
		t.Fatalf("Renew: %v", err)
	}
	if readOnly || holder != "host-a" {
		t.Fatalf("a lease unreadable for a full expiry window must be taken over: readOnly=%v holder=%q", readOnly, holder)
	}
}

func TestLeaseIsPublishedAtomically(t *testing.T) {
	m := newTestLease(t, "host-a")
	if _, _, err := m.Renew(time.Now()); err != nil {
		t.Fatal(err)
	}
	// Two agents share one NAS by design. A shared temp name means one truncates
	// the file while the other's rename is pending, so the temp must be unique
	// per write -- and dot-prefixed, so an abandoned one is skipped by every
	// pool walker rather than mistaken for an artifact.
	ents, err := os.ReadDir(filepath.Dir(m.Path))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if e.Name() == filepath.Base(m.Path) {
			continue
		}
		t.Fatalf("the lease write left %q behind", e.Name())
	}
}

func TestLeaseRenewalKeepsTheSameHolder(t *testing.T) {
	m := newTestLease(t, "host-a")
	base := time.Now()
	if _, _, err := m.Renew(base); err != nil {
		t.Fatal(err)
	}
	readOnly, holder, err := m.Renew(base.Add(15 * time.Minute))
	if err != nil {
		t.Fatalf("Renew: %v", err)
	}
	if readOnly || holder != "host-a" {
		t.Fatalf("renewal changed the verdict: readOnly=%v holder=%q", readOnly, holder)
	}
}

func TestAnAgentWithNoConfiguredIdentityStillPublishesAHolder(t *testing.T) {
	m := NewLeaseManager(filepath.Join(t.TempDir(), ".agent-lease.json"), "", "", time.Hour)
	m.ConfirmDelay = 0
	now := time.Now()
	if _, holder, err := m.Renew(now); err != nil || holder == "" {
		t.Fatalf("Renew: holder=%q err=%v", holder, err)
	}
	l, ok, err := m.read()
	if err != nil || !ok {
		t.Fatalf("the lease this agent just wrote reads as absent: %v ok=%v", err, ok)
	}
	if l.holder() != m.identity() {
		t.Fatalf("lease holder = %q, want %q", l.holder(), m.identity())
	}
	// A lease nobody can attribute is a lease nobody removes, so the next agent
	// waits out a full expiry window for a holder that no longer exists.
	m.Release()
	if _, err := os.Stat(m.Path); !os.IsNotExist(err) {
		t.Fatalf("Release left the lease behind: %v", err)
	}
}

func TestLeaseWithoutAPathLeavesTheAgentWritable(t *testing.T) {
	// No pool configured: correctness never depends on the lease, so the agent
	// must not lock itself out.
	m := NewLeaseManager("", "host-a", "vm", time.Hour)
	readOnly, _, err := m.Renew(time.Now())
	if err != nil || readOnly {
		t.Fatalf("Renew with no lease path: readOnly=%v err=%v", readOnly, err)
	}
}

func TestLeaseReleaseOnlyDropsItsOwn(t *testing.T) {
	m := newTestLease(t, "host-a")
	now := time.Now()
	writeLease(t, m.Path, Lease{HostID: "host-b", RenewedAtUTC: now.UTC().Format(time.RFC3339)})
	if _, _, err := m.Renew(now); err != nil {
		t.Fatal(err)
	}
	m.Release()
	if _, err := os.Stat(m.Path); err != nil {
		t.Fatal("a read-only agent must not remove the holder's lease")
	}

	m2 := newTestLease(t, "host-a")
	if _, _, err := m2.Renew(now); err != nil {
		t.Fatal(err)
	}
	m2.Release()
	if _, err := os.Stat(m2.Path); !os.IsNotExist(err) {
		t.Fatal("releasing a lease this agent holds must remove it")
	}
}
