// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package state persists the pool-control service's operational state under the
// pool NAS (poolStorageNetworkPath/pool-control-service/): an append-only audit log of every
// intent mutation, plus a status.json (last write, last-publish outcome, health,
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
type Store struct {
	dir       string
	mu        sync.Mutex
	startedAt time.Time
	writes    int
	last      Status
	statusErr string
	auditErr  string
}

// AuditEntry is one line of the append-only audit log.
type AuditEntry struct {
	Publish bool   `json:"-"` // true only for an intent mutation
	TimeUTC string `json:"timeUtc"`
	Action  string `json:"action"`
	Target  string `json:"target,omitempty"`
	OK      bool   `json:"ok"`
	Detail  string `json:"detail,omitempty"`
}

// Status is the snapshot written to status.json and served by /healthz.
type Status struct {
	StartedAtUTC   string `json:"startedAtUtc"`
	LastWriteUTC   string `json:"lastWriteUtc,omitempty"`
	LastAction     string `json:"lastAction,omitempty"`
	LastPublishOK  bool   `json:"lastPublishOk"`
	Writes         int    `json:"writes"`
	Healthy        bool   `json:"healthy"`
	StateDir       string `json:"stateDir,omitempty"`
	LastError      string `json:"lastError,omitempty"`
	HeartbeatUTC   string `json:"heartbeatUtc,omitempty"`
	IntentReadable bool   `json:"intentReadable"`
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
// mutation that is a "publish" (any intent write) also stamps LastPublishOK.
func (s *Store) Record(now time.Time, e AuditEntry) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e.Publish {
		s.writes++
		s.last.Writes = s.writes
		s.last.LastWriteUTC = e.TimeUTC
		s.last.LastAction = e.Action
		s.last.LastPublishOK = e.OK
	}
	s.appendAudit(e)
	s.writeStatusLocked(now)
}

// Beat updates the heartbeat + intent-readable flag (called by the monitor loop)
// and persists the status.
func (s *Store) Beat(now time.Time, intentReadable bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.last.HeartbeatUTC = now.UTC().Format(time.RFC3339)
	s.last.IntentReadable = intentReadable
	s.writeStatusLocked(now)
}

// Health returns the current status snapshot for /healthz.
func (s *Store) Health() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.last
}

// updateHealthLocked keeps independent audit and status failures visible until
// that same destination successfully writes again.
func (s *Store) updateHealthLocked() {
	var failures []string
	if s.auditErr != "" {
		failures = append(failures, s.auditErr)
	}
	if s.statusErr != "" {
		failures = append(failures, s.statusErr)
	}
	s.last.LastError = strings.Join(failures, "; ")
	s.last.Healthy = len(failures) == 0
}

func (s *Store) appendAudit(e AuditEntry) {
	if s.dir == "" {
		return
	}
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
	s.updateHealthLocked()
}

func (s *Store) writeStatusLocked(now time.Time) {
	s.statusErr = ""
	s.updateHealthLocked()
	if s.dir == "" {
		return
	}
	tmp := filepath.Join(s.dir, "status.json.tmp")
	dst := filepath.Join(s.dir, "status.json")
	b, _ := json.MarshalIndent(s.last, "", "  ")
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		s.statusErr = "status write: " + err.Error()
		s.updateHealthLocked()
		return
	}
	if err := os.Rename(tmp, dst); err != nil {
		s.statusErr = "status rename: " + err.Error()
		s.updateHealthLocked()
		return
	}
}
