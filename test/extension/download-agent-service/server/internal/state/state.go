// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package state persists the download-agent service's operational state under
// the pool share (poolStorageNetworkPath/download-agent-service/): an
// append-only audit log of every pool mutation, plus a status.json (last
// action, counters, health, heartbeat) that survives a service restart. When no
// state dir is configured it is an inert no-op, so unit tests and a
// pool-less bring-up run without a NAS.
//
// A write failure is recorded in Health and never blocks the mutation itself:
// losing the audit trail is strictly better than refusing to serve images
// because the share went read-only.
package state

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Store owns the state directory. All methods are safe for concurrent use and
// tolerate a temporarily-unwritable NAS (they record the failure in Health).
//
// The two locks are not interchangeable. mu guards only the in-memory snapshot
// and is never held across a file operation: /healthz reads that snapshot, and
// the launcher polls /healthz to decide the daemon is up, so a mutex held across
// a CIFS write to a hung NAS would hang exactly the endpoint whose whole purpose
// is to answer while the share is sick. ioMu serializes the writes themselves.
type Store struct {
	dir       string
	mu        sync.Mutex
	startedAt time.Time
	actions   int
	last      Status
	lastErr   string

	ioMu sync.Mutex
	// auditErr is sticky and lives under ioMu: the status write that follows an
	// audit append must not clear the very failure it is meant to report. It
	// stays set until an audit append succeeds, so a gap in the log keeps
	// showing as degraded health.
	auditErr string
}

// AuditEntry is one line of the append-only audit log: which image the operator
// (or the scanner) acted on, and how it turned out.
type AuditEntry struct {
	AtUTC    string `json:"atUtc"`
	Action   string `json:"action"`
	HostType string `json:"hostType,omitempty"`
	ImageKey string `json:"imageKey,omitempty"`
	Arch     string `json:"arch,omitempty"`
	Variant  string `json:"variant,omitempty"`
	Outcome  string `json:"outcome"`
	Detail   string `json:"detail,omitempty"`
}

// Status is the snapshot written to status.json and served by /healthz.
type Status struct {
	StartedAtUTC  string `json:"startedAtUtc"`
	LastActionUTC string `json:"lastActionUtc,omitempty"`
	LastAction    string `json:"lastAction,omitempty"`
	LastTarget    string `json:"lastTarget,omitempty"`
	LastOutcome   string `json:"lastOutcome,omitempty"`
	Actions       int    `json:"actions"`
	Healthy       bool   `json:"healthy"`
	StateDir      string `json:"stateDir,omitempty"`
	LastError     string `json:"lastError,omitempty"`
	HeartbeatUTC  string `json:"heartbeatUtc,omitempty"`
	PoolAvailable bool   `json:"poolAvailable"`
}

// New returns a Store rooted at dir (empty = disabled). It creates the dir when
// possible; a create failure is surfaced later via Health rather than fatal.
func New(dir string, now time.Time) *Store {
	s := &Store{dir: dir, startedAt: now}
	if dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			s.lastErr = "state dir: " + err.Error()
		}
	}
	s.last = Status{StartedAtUTC: now.UTC().Format(time.RFC3339), Healthy: dir == "" || s.lastErr == "", StateDir: dir, LastError: s.lastErr}
	return s
}

// Enabled reports whether a state dir is configured.
func (s *Store) Enabled() bool { return s.dir != "" }

// Record appends an audit entry and updates the in-memory + on-disk status.
func (s *Store) Record(now time.Time, e AuditEntry) {
	if e.AtUTC == "" {
		e.AtUTC = now.UTC().Format(time.RFC3339)
	}
	s.mu.Lock()
	s.actions++
	s.last.Actions = s.actions
	s.last.LastActionUTC = e.AtUTC
	s.last.LastAction = e.Action
	s.last.LastTarget = auditTarget(e)
	s.last.LastOutcome = e.Outcome
	s.mu.Unlock()
	s.persist(&e)
}

// Beat updates the heartbeat + pool-available flag (called by the scanner) and
// persists the status.
func (s *Store) Beat(now time.Time, poolAvailable bool) {
	s.mu.Lock()
	s.last.HeartbeatUTC = now.UTC().Format(time.RFC3339)
	s.last.PoolAvailable = poolAvailable
	s.mu.Unlock()
	s.persist(nil)
}

// Health returns the current status snapshot for /healthz.
func (s *Store) Health() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.last
}

// auditTarget renders the image identity as one display string for status.json.
func auditTarget(e AuditEntry) string {
	if e.HostType == "" && e.ImageKey == "" {
		return ""
	}
	t := e.HostType + "/" + e.ImageKey
	if e.Arch != "" {
		t += "/" + e.Arch
	}
	if e.Variant != "" {
		t += "/" + e.Variant
	}
	return t
}

// persist appends an audit line (when e is non-nil) and rewrites status.json,
// then folds the outcome back into the in-memory snapshot. Every file operation
// happens under ioMu and OUTSIDE mu, so a share that has stopped answering can
// stall this and nothing else.
func (s *Store) persist(e *AuditEntry) {
	if s.dir == "" {
		s.mu.Lock()
		s.last.LastError = ""
		s.last.Healthy = true
		s.mu.Unlock()
		return
	}

	s.ioMu.Lock()
	defer s.ioMu.Unlock()
	if e != nil {
		s.appendAudit(*e)
	}

	s.mu.Lock()
	snap := s.last
	s.mu.Unlock()

	// A successful status write clears a prior transient status error, but never
	// the audit failure recorded moments earlier in the same call.
	snap.LastError, snap.Healthy = s.auditErr, s.auditErr == ""
	if err := s.writeStatus(snap); err != nil {
		snap.LastError, snap.Healthy = err.Error(), false
	}

	s.mu.Lock()
	s.last.LastError, s.last.Healthy = snap.LastError, snap.Healthy
	s.mu.Unlock()
}

// appendAudit runs under ioMu; it records its own failure in auditErr rather
// than returning it, because the mutation it describes has already happened.
func (s *Store) appendAudit(e AuditEntry) {
	f, err := os.OpenFile(filepath.Join(s.dir, "audit.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		s.auditErr = "audit write: " + err.Error()
		return
	}
	defer f.Close()
	b, _ := json.Marshal(e)
	if _, err := f.Write(append(b, '\n')); err != nil {
		s.auditErr = "audit write: " + err.Error()
		return
	}
	s.auditErr = ""
}

// writeStatus persists one snapshot; it runs under ioMu and never touches mu.
func (s *Store) writeStatus(snap Status) error {
	tmp := filepath.Join(s.dir, "status.json.tmp")
	dst := filepath.Join(s.dir, "status.json")
	b, _ := json.MarshalIndent(snap, "", "  ")
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return errors.New("status write: " + err.Error())
	}
	if err := os.Rename(tmp, dst); err != nil {
		return errors.New("status rename: " + err.Error())
	}
	return nil
}
