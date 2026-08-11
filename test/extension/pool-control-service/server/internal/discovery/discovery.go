// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package discovery finds Yuruna hosts by sweeping a network and keeps the ones
// it finds in a list this daemon monitors on its own.
//
// The pool's own view of "which hosts exist" is second-hand: the aggregator
// learns a host when that host registers or beacons, and pool membership is a
// separate fact again, held in git-backed intent. A machine that is running a
// Yuruna status service but has never enrolled is therefore invisible to every
// pool UI, even though it is sitting on the same subnet answering probes.
//
// This package closes that gap from the other direction — ask the network — and
// deliberately keeps its answers local: the store is this daemon's, so the list
// survives an aggregator outage and needs no write path into anyone else's
// registry. Membership of a pool is untouched; a discovered host is monitored,
// not enrolled.
package discovery

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Host is one machine the sweep confirmed is running a Yuruna status service.
//
// Address is the only field a probe always yields, so it is the fallback
// identity: a host whose registration record could not be read is still a host
// worth monitoring, and dropping it because it would not name itself would hide
// exactly the half-configured machine an operator most wants to see.
type Host struct {
	// Address is the IP the status service answered on.
	Address string `json:"address"`
	// BaseURL is the status-service base ("http://ip:port"), the same shape the
	// aggregator reports for a registered host, so a consumer that already
	// reads one can read the other without a second code path.
	BaseURL string `json:"baseUrl"`
	// HostID is the host's own stable id, read from its registration record.
	// Empty when that read failed — see the type comment.
	HostID       string `json:"hostId,omitempty"`
	Hostname     string `json:"hostname,omitempty"`
	HostType     string `json:"hostType,omitempty"`
	FirstSeenUTC string `json:"firstSeenUtc"`
	LastSeenUTC  string `json:"lastSeenUtc"`
	// FoundBy is "scan" for an operator's own run and "sweep" for the timer,
	// which is the difference between "I went looking" and "it turned up".
	FoundBy string `json:"foundBy,omitempty"`
}

// Key is the identity a host is stored under: its own id when it reported one,
// otherwise the address it answered on. Two probes of the same machine
// therefore collapse to one entry, and a machine that starts reporting an id
// after a rebuild lands as a new entry rather than silently overwriting the
// address-keyed one — which is the honest outcome, because from here they are
// not provably the same machine.
func (h Host) Key() string {
	if h.HostID != "" {
		return h.HostID
	}
	return h.Address
}

// Store holds the discovered hosts. Safe for concurrent use.
//
// The file is a convenience, not a dependency: with no path (no --state-dir)
// the store is memory-only and a restart simply re-discovers on the next sweep,
// which is at most one interval away. That keeps the host-side launcher and the
// unit tests running with no NAS, the same bargain the audit-log store makes.
type Store struct {
	mu    sync.Mutex
	path  string
	hosts map[string]Host
	// lastErr keeps a persistence failure visible without ever failing the
	// scan that produced the data: a NAS that went read-only must not cost the
	// operator the list they are looking at.
	lastErr string
}

// NewStore opens (and loads) the store at path. An empty path is memory-only.
// A load failure is not fatal: it leaves an empty list and a recorded error,
// because refusing to start over an unreadable cache would take the whole
// service down for a file it can rebuild by scanning.
func NewStore(path string) *Store {
	s := &Store{path: path, hosts: map[string]Host{}}
	if path == "" {
		return s
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			s.lastErr = "read: " + err.Error()
		}
		return s
	}
	var loaded []Host
	if err := json.Unmarshal(data, &loaded); err != nil {
		s.lastErr = "parse: " + err.Error()
		return s
	}
	for _, h := range loaded {
		if h.Address == "" {
			continue
		}
		s.hosts[h.Key()] = h
	}
	return s
}

// Add records a host and reports whether it was new to this store. An existing
// entry keeps its first-seen stamp and takes the fresh sighting's other fields:
// a host that has since reported an id, a name, or a new address is describing
// itself more completely than the last probe could.
func (s *Store) Add(h Host, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	stamp := now.UTC().Format(time.RFC3339)
	h.LastSeenUTC = stamp
	key := h.Key()
	prev, existed := s.hosts[key]
	if existed {
		h.FirstSeenUTC = prev.FirstSeenUTC
		if h.Hostname == "" {
			h.Hostname = prev.Hostname
		}
		if h.HostType == "" {
			h.HostType = prev.HostType
		}
		if h.FoundBy == "" {
			h.FoundBy = prev.FoundBy
		}
	} else {
		h.FirstSeenUTC = stamp
	}
	s.hosts[key] = h
	s.persistLocked()
	return !existed
}

// Has reports whether a key is already stored.
func (s *Store) Has(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.hosts[key]
	return ok
}

// List returns every stored host, address-ordered so a page renders the same
// way twice running.
func (s *Store) List() []Host {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Host, 0, len(s.hosts))
	for _, h := range s.hosts {
		out = append(out, h)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Address < out[j].Address })
	return out
}

// Forget drops one host by key and reports whether it was there. An operator
// needs a way out for a machine that has been retired: without it a decommissioned
// address stays on the page until someone edits a file on the NAS by hand.
func (s *Store) Forget(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.hosts[key]; !ok {
		return false
	}
	delete(s.hosts, key)
	s.persistLocked()
	return true
}

// LastError reports the most recent persistence failure ("" when healthy).
func (s *Store) LastError() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastErr
}

// persistLocked writes the whole list through a temp file and a rename, so a
// crash mid-write leaves the previous list intact rather than a truncated one.
// Caller holds the mutex.
func (s *Store) persistLocked() {
	if s.path == "" {
		return
	}
	out := make([]Host, 0, len(s.hosts))
	for _, h := range s.hosts {
		out = append(out, h)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Address < out[j].Address })
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		s.lastErr = "encode: " + err.Error()
		return
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		s.lastErr = "state dir: " + err.Error()
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		s.lastErr = "write: " + err.Error()
		return
	}
	if err := os.Rename(tmp, s.path); err != nil {
		s.lastErr = "rename: " + err.Error()
		_ = os.Remove(tmp)
		return
	}
	s.lastErr = ""
}
