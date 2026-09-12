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
// This package closes that gap from the other direction -- ask the network -- and
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
	"strings"
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
	// Empty when that read failed -- see the type comment.
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
// therefore collapse to one entry.
//
// A machine that re-keys (a reimage, a re-clone: the id lives in the runtime
// directory) lands under a NEW key, so the key alone cannot keep the list to
// one row per machine. What does is the base URL -- see supersedeLocked.
func (h Host) Key() string {
	if h.HostID != "" {
		return h.HostID
	}
	return h.Address
}

// baseKey is the host's status-service base with a trailing slash trimmed, or
// "" when the probe reported none. It is the store's second identity: one
// address:port can hold exactly one status service, so two entries sharing a
// base key are the same machine seen under two names.
func (h Host) baseKey() string {
	return strings.TrimSuffix(strings.TrimSpace(h.BaseURL), "/")
}

// sameMachine reports whether a superseded entry is recognizably the machine
// that replaced it, which decides whether its first-seen stamp is worth
// carrying forward. An entry that never named itself is subsumed by definition
// (its id was unread, not different), and two entries reporting one hostname
// are one machine that re-keyed. Anything else is treated as a new occupant of
// a reused address, whose history does not belong to the newcomer.
func sameMachine(loser, winner Host) bool {
	if loser.HostID == "" {
		return true
	}
	ln, wn := strings.TrimSpace(loser.Hostname), strings.TrimSpace(winner.Hostname)
	return ln != "" && strings.EqualFold(ln, wn)
}

// newerSighting compares two last-seen stamps. Both are written by this package
// as RFC3339 in UTC, one fixed-width form, so a lexical compare is a
// chronological one and no parse can fail on a hand-edited file.
func newerSighting(a, b string) bool { return a > b }

// earlierStamp returns whichever of two stamps is the earlier, ignoring an
// empty one so a record missing its first-seen cannot backdate the survivor.
func earlierStamp(a, b string) string {
	switch {
	case a == "":
		return b
	case b == "":
		return a
	case a < b:
		return a
	default:
		return b
	}
}

// less orders the list: by address, then newest sighting, then key. The address
// is first because that is how an operator reads the page; the rest of the
// comparator exists so the order is TOTAL. Two entries on one address are the
// duplicate case, and consumers that keep the first one they see for an address
// -- the Hosts table and the facts fan-out both do -- would otherwise pick a
// different row on every request, because Go's sort is not stable.
func less(a, b Host) bool {
	if a.Address != b.Address {
		return a.Address < b.Address
	}
	if a.LastSeenUTC != b.LastSeenUTC {
		return newerSighting(a.LastSeenUTC, b.LastSeenUTC)
	}
	return a.Key() < b.Key()
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
	// A file written before the store collapsed by base URL can hold several
	// entries for one machine, and the machine may never be probed again (it
	// can be off, or retired) -- so the list would keep showing every id it has
	// ever had. Collapsing at load fixes the file in place instead of waiting
	// for a sighting that may not come. No lock: nothing else can hold this
	// store until NewStore has returned it.
	if s.collapseLocked() > 0 {
		s.persistLocked()
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
	s.supersedeLocked(key)
	s.persistLocked()
	return !existed
}

// supersedeLocked drops every OTHER entry answering at the winner's base URL
// whose last sighting is older, folding the earliest first-seen of the ones it
// recognizes as the same machine into the survivor. Caller holds the mutex.
//
// One address:port holds one status service, so an older entry still claiming
// this base URL is not a second machine -- it is this one under an id it has
// since stopped reporting (a reimage or a re-clone re-keys a host, because the
// id lives in the runtime directory), or a sighting that could not read an id
// at all. Keeping both is what made one machine occupy several rows for as long
// as the list survived, and pool membership follow the id that went quiet.
//
// Only strictly-older entries go. A host that legitimately MOVED off this
// address keeps its entry until something else answers there, and the sweep
// that finds it at its new address re-stamps it first when it probes in
// ascending order -- so the common case costs it nothing. The case this does
// give up on is a machine whose address was handed to another host between two
// sweeps: its entry goes, and the next sweep rediscovers it where it now lives.
func (s *Store) supersedeLocked(winnerKey string) int {
	winner, ok := s.hosts[winnerKey]
	if !ok {
		return 0
	}
	base := winner.baseKey()
	if base == "" {
		return 0
	}
	removed := 0
	for key, h := range s.hosts {
		if key == winnerKey || h.baseKey() != base {
			continue
		}
		if !newerSighting(winner.LastSeenUTC, h.LastSeenUTC) {
			continue
		}
		if sameMachine(h, winner) {
			winner.FirstSeenUTC = earlierStamp(winner.FirstSeenUTC, h.FirstSeenUTC)
		}
		delete(s.hosts, key)
		removed++
	}
	if removed > 0 {
		s.hosts[winnerKey] = winner
	}
	return removed
}

// collapseLocked reduces every base URL to its newest entry, whether or not a
// probe just confirmed one. Caller holds the mutex.
//
// supersedeLocked runs off a sighting, so it can only clean up a machine that
// is still answering. This closes the other half: a machine that re-keyed and
// then went off the network leaves both ids behind, and neither will ever be
// stamped again. Ordering is the list's own total order, so the survivor per
// base URL is the newest sighting and the outcome does not depend on map
// iteration.
func (s *Store) collapseLocked() int {
	byBase := map[string][]Host{}
	for _, h := range s.hosts {
		if base := h.baseKey(); base != "" {
			byBase[base] = append(byBase[base], h)
		}
	}
	removed := 0
	for _, group := range byBase {
		if len(group) < 2 {
			continue
		}
		sort.Slice(group, func(i, j int) bool { return less(group[i], group[j]) })
		winner := group[0]
		for _, h := range group[1:] {
			if sameMachine(h, winner) {
				winner.FirstSeenUTC = earlierStamp(winner.FirstSeenUTC, h.FirstSeenUTC)
			}
			delete(s.hosts, h.Key())
			removed++
		}
		s.hosts[winner.Key()] = winner
	}
	return removed
}

// Prune collapses duplicate base URLs and drops whatever has not been seen for
// maxAge, reporting how many entries left. A maxAge of zero or less expires
// nothing and only collapses.
//
// The list is a monitored set, not a liveness view: a host that has gone quiet
// is exactly what an operator wants to keep seeing, which is why this is days
// rather than the aggregator's hours. But "keep forever" is not the same
// promise -- a machine retired months ago is noise that hides the one that went
// quiet this morning, and every stale row is a row somebody has to recognize as
// stale before they can read past it.
func (s *Store) Prune(now time.Time, maxAge time.Duration) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	removed := s.collapseLocked()
	if maxAge > 0 {
		cutoff := now.Add(-maxAge).UTC().Format(time.RFC3339)
		for key, h := range s.hosts {
			// An entry with no stamp has no age to judge, so it is kept: this
			// store's own writes always stamp, and refusing to guess is better
			// than expiring a record somebody hand-repaired.
			if h.LastSeenUTC == "" {
				continue
			}
			if h.LastSeenUTC < cutoff {
				delete(s.hosts, key)
				removed++
			}
		}
	}
	if removed > 0 {
		s.persistLocked()
	}
	return removed
}

// Has reports whether a key is already stored.
func (s *Store) Has(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.hosts[key]
	return ok
}

// List returns every stored host in the package's total order -- by address,
// newest sighting first within one address -- so a page renders the same way
// twice running and a consumer that keeps one entry per address keeps the same
// one every time.
func (s *Store) List() []Host {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Host, 0, len(s.hosts))
	for _, h := range s.hosts {
		out = append(out, h)
	}
	sort.Slice(out, func(i, j int) bool { return less(out[i], out[j]) })
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
	sort.Slice(out, func(i, j int) bool { return less(out[i], out[j]) })
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
