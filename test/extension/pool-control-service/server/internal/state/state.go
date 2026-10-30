// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42e8242e-91d0-470a-a801-e83dbf3c96ab

// Package state persists the pool-control service's operational state under the
// pool NAS (poolStorageNetworkPath/pool-control-service/): an append-only audit log of every
// configuration mutation, plus a status.json (last write, last-publish outcome, health,
// heartbeat) that survives a service restart. When no state dir is configured it
// is an inert no-op, so the host-side launcher and unit tests run without a NAS.
package state

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Store owns the state directory. All methods are safe for concurrent use and
// tolerate a temporarily-unwritable NAS (they record the failure in Health).
//
// The two locks are not interchangeable. mu guards only the in-memory snapshot
// and is never held across a file operation: /healthz reads that snapshot, so a
// mutex held across a CIFS write to a hung NAS would hang the endpoint whose
// whole purpose is to answer while the share is sick. ioMu serializes the
// writes themselves, and the failures they record.
type Store struct {
	dir       string
	mu        sync.Mutex
	startedAt time.Time
	writes    int
	last      Status

	ioMu      sync.Mutex
	statusErr string
	auditErr  string
}

// AuditEntry is one line of the append-only audit log.
type AuditEntry struct {
	Publish bool   `json:"-"` // true only for a configuration mutation
	TimeUTC string `json:"timeUtc"`
	Action  string `json:"action"`
	Target  string `json:"target,omitempty"`
	OK      bool   `json:"ok"`
	Detail  string `json:"detail,omitempty"`
}

// Status is the snapshot written to status.json and served by /healthz.
type Status struct {
	StartedAtUTC          string `json:"startedAtUtc"`
	LastWriteUTC          string `json:"lastWriteUtc,omitempty"`
	LastAction            string `json:"lastAction,omitempty"`
	LastPublishOK         bool   `json:"lastPublishOk"`
	Writes                int    `json:"writes"`
	Healthy               bool   `json:"healthy"`
	StateDir              string `json:"stateDir,omitempty"`
	LastError             string `json:"lastError,omitempty"`
	HeartbeatUTC          string `json:"heartbeatUtc,omitempty"`
	ConfigurationReadable bool   `json:"configurationReadable"`
}

// New returns a Store rooted at dir (empty = disabled). It creates the dir when
// possible; a create failure is surfaced later via Health rather than fatal.
func New(dir string, now time.Time) *Store {
	s := &Store{dir: dir, startedAt: now}
	if dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			s.statusErr = "state dir: " + err.Error()
		}
	}
	s.last = Status{StartedAtUTC: now.UTC().Format(time.RFC3339), Healthy: dir == "" || s.statusErr == "", StateDir: dir, LastError: s.statusErr}
	return s
}

// Enabled reports whether a state dir is configured.
func (s *Store) Enabled() bool { return s.dir != "" }

// Record appends an audit entry and updates the in-memory + on-disk status. A
// mutation that is a "publish" (any configuration write) also stamps LastPublishOK.
func (s *Store) Record(now time.Time, e AuditEntry) {
	s.mu.Lock()
	if e.Publish {
		s.writes++
		s.last.Writes = s.writes
		s.last.LastWriteUTC = e.TimeUTC
		s.last.LastAction = e.Action
		s.last.LastPublishOK = e.OK
	}
	s.mu.Unlock()
	s.persist(&e)
}

// Beat updates the heartbeat + configuration-readable flag (called by the monitor loop)
// and persists the status.
func (s *Store) Beat(now time.Time, configurationReadable bool) {
	s.mu.Lock()
	s.last.HeartbeatUTC = now.UTC().Format(time.RFC3339)
	s.last.ConfigurationReadable = configurationReadable
	s.mu.Unlock()
	s.persist(nil)
}

// Health returns the current status snapshot for /healthz.
func (s *Store) Health() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.last
}

// persist appends an audit line (when e is non-nil) and rewrites status.json,
// then folds the outcome back into the in-memory snapshot. Every file operation
// happens under ioMu and outside mu.
func (s *Store) persist(e *AuditEntry) {
	s.ioMu.Lock()
	defer s.ioMu.Unlock()
	if s.dir != "" && e != nil {
		s.appendAudit(*e)
	}
	s.statusErr = ""
	s.mu.Lock()
	snap := s.last
	s.mu.Unlock()
	snap.LastError, snap.Healthy = s.failures()
	if s.dir != "" {
		if err := writeStatus(s.dir, snap); err != nil {
			s.statusErr = err.Error()
			snap.LastError, snap.Healthy = s.failures()
		}
	}
	s.mu.Lock()
	s.last.LastError, s.last.Healthy = snap.LastError, snap.Healthy
	s.mu.Unlock()
}

// failures joins the audit and status failures; each stays visible until that
// same destination writes successfully again. Runs under ioMu.
func (s *Store) failures() (string, bool) {
	var failures []string
	if s.auditErr != "" {
		failures = append(failures, s.auditErr)
	}
	if s.statusErr != "" {
		failures = append(failures, s.statusErr)
	}
	return strings.Join(failures, "; "), len(failures) == 0
}

// appendAudit runs under ioMu.
func (s *Store) appendAudit(e AuditEntry) {
	f, err := os.OpenFile(filepath.Join(s.dir, "audit.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err == nil {
		var b []byte
		b, err = json.Marshal(e)
		if err == nil {
			_, err = f.Write(append(b, '\n'))
		}
		err = errors.Join(err, f.Close())
	}
	previous := s.auditErr
	s.auditErr = ""
	if err != nil {
		s.auditErr = "audit write: " + err.Error()
	}
	if s.auditErr != "" && s.auditErr != previous {
		log.Printf("pool-control-service: %s", s.auditErr)
	}
}

// writeStatus publishes one snapshot through a temp file of its own and a
// rename. A fixed temp name would let two writers -- a second daemon on the same
// share, or a write still landing after a restart -- write into one file and
// rename each other's half.
func writeStatus(dir string, snap Status) error {
	b, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return errors.New("status encode: " + err.Error())
	}
	f, err := os.CreateTemp(dir, ".status.json.tmp-*")
	if err != nil {
		return errors.New("status write: " + err.Error())
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err := f.Write(b); err != nil {
		f.Close()
		return errors.New("status write: " + err.Error())
	}
	if err := f.Chmod(0o644); err != nil {
		f.Close()
		return errors.New("status write: " + err.Error())
	}
	if err := f.Close(); err != nil {
		return errors.New("status write: " + err.Error())
	}
	if err := os.Rename(tmp, filepath.Join(dir, "status.json")); err != nil {
		return errors.New("status rename: " + err.Error())
	}
	return nil
}
