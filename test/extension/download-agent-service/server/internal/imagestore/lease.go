// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"encoding/json"
	"errors"
	"os"
	"sync"
	"time"
)

// defaultConfirmDelay is the write -> pause -> read-back window. CIFS
// atomic-create is unproven here, so acquisition proves itself by reading its
// own write back after giving a competing writer time to land.
const defaultConfirmDelay = 500 * time.Millisecond

// unreadableHolder is the holder reported while the lease file cannot be parsed.
// Naming it in the status is what tells an operator the difference between "held
// by that host" and "nobody can tell who holds this".
const unreadableHolder = "unknown"

// Lease is images/.agent-lease.json.
type Lease struct {
	HostID       string `json:"hostId"`
	VMName       string `json:"vmName"`
	RenewedAtUTC string `json:"renewedAtUtc"`
}

// holder is the identity string compared between agents.
func (l Lease) holder() string {
	if l.HostID != "" {
		return l.HostID
	}
	return l.VMName
}

// LeaseManager keeps one agent the writer for a pool. Correctness never depends
// on it -- generation-addressed storage makes concurrent writers safe -- so a
// lease that cannot be read or written leaves this agent writable rather than
// deadlocking the pool.
type LeaseManager struct {
	Path         string
	HostID       string
	VMName       string
	Expiry       time.Duration
	ConfirmDelay time.Duration

	// onWrote runs between the lease write and the read-back confirmation. It
	// exists so the confirmation window can be exercised deterministically
	// instead of by racing two sleeps against each other.
	onWrote func()

	mu sync.Mutex
	// unreadableSince is when the lease file first failed to parse, so an
	// undecipherable lease is deferred to for one expiry window and then taken
	// over rather than deferred to forever.
	unreadableSince time.Time
	holder          string
	readOnly        bool
	lastErr         string
	renewed         time.Time
}

// NewLeaseManager builds a manager whose lease expires after
// config.LeaseExpiryFactor scan intervals.
func NewLeaseManager(path, hostID, vmName string, expiry time.Duration) *LeaseManager {
	return &LeaseManager{
		Path:         path,
		HostID:       hostID,
		VMName:       vmName,
		Expiry:       expiry,
		ConfirmDelay: defaultConfirmDelay,
	}
}

// identity is what this agent writes into the lease and compares against.
func (m *LeaseManager) identity() string {
	if m.HostID != "" {
		return m.HostID
	}
	if m.VMName != "" {
		return m.VMName
	}
	// Two agents with neither a host id nor a VM name would otherwise both
	// answer "" and each read the other's lease as its own.
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "unidentified-agent"
	}
	return h
}

// Renew acquires or renews the lease. A live lease held by another agent puts
// this one in read-only mode: it keeps serving committed generations and
// answering metadata, and defers downloads to the holder.
func (m *LeaseManager) Renew(now time.Time) (readOnly bool, holder string, err error) {
	if m.Path == "" {
		m.set(false, m.identity(), "")
		return false, m.identity(), nil
	}
	me := m.identity()

	cur, ok, rerr := m.read()
	switch {
	case rerr != nil:
		// An unreadable lease is not an absent one. The likeliest cause is that
		// another agent's write is landing right now, and treating that as "free"
		// makes both agents writers -- the exact duplication the lease exists to
		// avoid. Defer to it as foreign-and-live, but only for one expiry window:
		// past that the file is garbage, not a race, and a pool with no writer at
		// all is worse.
		if !m.deferToUnreadable(now, rerr) {
			break
		}
		return true, unreadableHolder, nil
	case ok:
		m.clearUnreadable()
		if cur.holder() != me && !m.expired(cur, now) {
			m.set(true, cur.holder(), "")
			return true, cur.holder(), nil
		}
	default:
		m.clearUnreadable()
	}

	mine := Lease{HostID: m.HostID, VMName: m.VMName, RenewedAtUTC: now.UTC().Format(time.RFC3339)}
	if mine.holder() == "" {
		// identity() falls back to the hostname when neither id is configured.
		// Writing the raw fields instead publishes a lease with no holder, which
		// every reader -- including this agent's own Release -- takes for absent,
		// so the file is never cleaned up and the next agent waits out a full
		// expiry window for a holder that no longer exists.
		mine.VMName = me
	}
	if werr := m.write(mine); werr != nil {
		// An unwritable lease file must not stop this agent from working; the
		// worst case is duplicate download effort, never corruption.
		m.set(false, me, werr.Error())
		return false, me, werr
	}
	if m.onWrote != nil {
		m.onWrote()
	}
	if m.ConfirmDelay > 0 {
		time.Sleep(m.ConfirmDelay)
	}
	back, ok, rerr := m.read()
	if rerr != nil || !ok {
		m.set(false, me, errString(rerr))
		return false, me, nil
	}
	if back.holder() == me {
		m.mu.Lock()
		m.renewed = now
		m.mu.Unlock()
		m.set(false, me, "")
		return false, me, nil
	}
	if m.expired(back, now) {
		m.set(false, me, "")
		return false, me, nil
	}
	m.set(true, back.holder(), "")
	return true, back.holder(), nil
}

// Release drops a lease this agent holds, so a restart does not have to wait out
// the expiry window. Best effort: an unreachable pool just leaves it to expire.
func (m *LeaseManager) Release() {
	if m.Path == "" || m.ReadOnly() {
		return
	}
	cur, ok, err := m.read()
	if err != nil || !ok || cur.holder() != m.identity() {
		return
	}
	_ = os.Remove(m.Path)
}

// ReadOnly reports whether another agent currently holds the lease.
func (m *LeaseManager) ReadOnly() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.readOnly
}

// Holder is the identity that currently holds the lease.
func (m *LeaseManager) Holder() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.holder
}

// LastError is the most recent lease read/write failure, for the status page.
func (m *LeaseManager) LastError() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastErr
}

func (m *LeaseManager) set(readOnly bool, holder, lastErr string) {
	m.mu.Lock()
	m.readOnly = readOnly
	m.holder = holder
	m.lastErr = lastErr
	m.mu.Unlock()
}

// deferToUnreadable records the first sighting of an unparseable lease and
// reports whether this agent should still stand down for it.
func (m *LeaseManager) deferToUnreadable(now time.Time, rerr error) bool {
	m.mu.Lock()
	if m.unreadableSince.IsZero() {
		m.unreadableSince = now
	}
	since := m.unreadableSince
	m.mu.Unlock()
	if now.Sub(since) > m.Expiry {
		return false
	}
	m.set(true, unreadableHolder, errString(rerr))
	return true
}

func (m *LeaseManager) clearUnreadable() {
	m.mu.Lock()
	m.unreadableSince = time.Time{}
	m.mu.Unlock()
}

func (m *LeaseManager) expired(l Lease, now time.Time) bool {
	t, err := time.Parse(time.RFC3339, l.RenewedAtUTC)
	if err != nil {
		return true
	}
	return now.Sub(t) > m.Expiry
}

func (m *LeaseManager) read() (Lease, bool, error) {
	b, err := os.ReadFile(m.Path)
	if errors.Is(err, os.ErrNotExist) {
		return Lease{}, false, nil
	}
	if err != nil {
		return Lease{}, false, err
	}
	var l Lease
	if err := json.Unmarshal(b, &l); err != nil {
		return Lease{}, false, err
	}
	if l.holder() == "" {
		return Lease{}, false, nil
	}
	return l, true, nil
}

// write publishes the lease through the same unique-temp-plus-rename helper the
// pointers use: a direct write is not atomic, so a competing agent's read could
// otherwise land on a half-written document and read it as free.
func (m *LeaseManager) write(l Lease) error {
	return writeJSONAtomic(m.Path, l)
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
