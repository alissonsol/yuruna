// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// backfillStateVersion is bumped only when an older file can no longer be read
// as-is. A file of another version is ignored rather than trusted, which costs
// one slower pass for that host and never a wrong answer.
const backfillStateVersion = 1

// backfillHostState is what the backfill keeps about one host between sweeps and
// restarts, one file per host under <state-dir>/hosts/.
//
// Buckets holds the leaves of every history.<date> bucket except the newest the
// host links. A bucket stops changing once rotation has moved on to a newer one,
// so its listing is fetched once; the newest can still receive folders the same
// day and is listed again each sweep.
//
// Failures counts consecutive failed attempts at a cycle, keyed by the cycle
// identity. A cycle that keeps failing is given up on instead of being fetched
// from the host every sweep forever.
//
// Done holds the identities whose lines Loki holds -- because the collector
// wrote them, or this job did -- and Incidents the ids of the incidents this job
// replayed. Both are kept here and not looked up in Loki again, because Loki
// answers for a line stamped days in the past only after it has filed the line
// away, which takes it many minutes; asking sooner would write the line twice.
//
// DerivedAt is when the incidents and the timeline were last rebuilt; they are
// rebuilt after every pass that writes a cycle, and once a day regardless.
// SeenAt is when the host was last in the pool; a host gone for longer than the
// horizon has nothing left to backfill and its files are removed.
//
// ListedAt is when the host's log listing was last requested. A host is listed
// again only hostListingInterval later; the passes between work from the folders
// the cycle index recorded and from the pool share. ListingDeferredUntil is set
// when a listing request was slow or timed out, and until then the host is asked
// for nothing at all: the request that was slow held its status service, and
// every guest livecheck of that host behind it. An older file without these
// fields reads as a host never listed, which is what it is to this job.
type backfillHostState struct {
	Version              int                 `json:"version"`
	HostID               string              `json:"hostId"`
	Buckets              map[string][]string `json:"buckets"`
	Failures             map[string]int      `json:"failures"`
	Done                 map[string]bool     `json:"done"`
	Incidents            map[string]bool     `json:"incidents"`
	DerivedAt            time.Time           `json:"derivedAt"`
	SeenAt               time.Time           `json:"seenAt"`
	ListedAt             time.Time           `json:"listedAt"`
	ListingDeferredUntil time.Time           `json:"listingDeferredUntil"`
}

// listingDue reports whether a pass may request the host's log listing at now. A
// listing time ahead of now -- a file written under a clock since set back --
// does not hold the host back.
func (hs *backfillHostState) listingDue(now time.Time) bool {
	if hs.hostDeferred(now) {
		return false
	}
	return hs.ListedAt.IsZero() || hs.ListedAt.After(now) || !now.Before(hs.ListedAt.Add(hostListingInterval))
}

// hostDeferred reports whether the host is to be left alone at now after a slow
// listing. A deferral reaching further than one listingDeferral from now was set
// under a clock since set back, and is not honored.
func (hs *backfillHostState) hostDeferred(now time.Time) bool {
	return now.Before(hs.ListingDeferredUntil) && hs.ListingDeferredUntil.Sub(now) <= listingDeferral
}

const hostStateDirName = "hosts"

func hostStatePath(stateDir, hostID string) string {
	return filepath.Join(stateDir, hostStateDirName, strings.ToLower(hostID)+".json")
}

// loadHostState reads a host's state, or returns an empty one when the file is
// absent, unreadable, of another version or of another host.
func loadHostState(stateDir, hostID string) *backfillHostState {
	hs := &backfillHostState{}
	data, err := os.ReadFile(hostStatePath(stateDir, hostID))
	if err != nil || json.Unmarshal(data, hs) != nil || hs.Version != backfillStateVersion || !strings.EqualFold(hs.HostID, hostID) {
		hs = &backfillHostState{}
	}
	hs.Version, hs.HostID = backfillStateVersion, hostID
	if hs.Buckets == nil {
		hs.Buckets = map[string][]string{}
	}
	if hs.Failures == nil {
		hs.Failures = map[string]int{}
	}
	if hs.Done == nil {
		hs.Done = map[string]bool{}
	}
	if hs.Incidents == nil {
		hs.Incidents = map[string]bool{}
	}
	return hs
}

func (hs *backfillHostState) save(stateDir string) error {
	return writeJSONAtomic(hostStatePath(stateDir, hs.HostID), hs, 0o644)
}

// fingerprint is the state as it would be saved, to tell whether a pass changed it.
func (hs *backfillHostState) fingerprint() []byte {
	data, _ := json.Marshal(hs)
	return data
}

func (hs *backfillHostState) changedSince(fp []byte) bool {
	return !bytes.Equal(hs.fingerprint(), fp)
}

// prune drops the per-cycle entries that can no longer matter: cycles that
// started before cutoff, buckets named for a day before it, and incidents that
// began before it.
func (hs *backfillHostState) prune(cutoff time.Time) {
	for identity := range hs.Failures {
		if start, ok := cycleStartFromFolder(identity); !ok || start.Before(cutoff) {
			delete(hs.Failures, identity)
		}
	}
	for identity := range hs.Done {
		if start, ok := cycleStartFromFolder(identity); !ok || start.Before(cutoff) {
			delete(hs.Done, identity)
		}
	}
	for name := range hs.Buckets {
		if d, ok := bucketDate(name); !ok || d.Add(bucketDateSlack).Before(cutoff) {
			delete(hs.Buckets, name)
		}
	}
	for id := range hs.Incidents {
		if started, ok := incidentStart(id); !ok || started.Before(cutoff) {
			delete(hs.Incidents, id)
		}
	}
}

// incidentStart reads the start time incidentID encodes as the id's last field.
func incidentStart(id string) (time.Time, bool) {
	i := strings.LastIndex(id, "-")
	if i < 0 {
		return time.Time{}, false
	}
	secs, err := strconv.ParseInt(id[i+1:], 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.Unix(secs, 0).UTC(), true
}

// pruneHostFiles removes the state and cycle index of every host not seen in the
// pool since cutoff.
func pruneHostFiles(stateDir string, cutoff time.Time) {
	entries, err := os.ReadDir(filepath.Join(stateDir, hostStateDirName))
	if err != nil {
		return
	}
	for _, e := range entries {
		id := strings.TrimSuffix(e.Name(), ".json")
		if e.IsDir() || !plainHostIDRE.MatchString(id) {
			continue
		}
		if hs := loadHostState(stateDir, id); hs.SeenAt.IsZero() || hs.SeenAt.Before(cutoff) {
			_ = os.Remove(hostStatePath(stateDir, id))
			_ = os.Remove(cycleIndexPath(stateDir, id))
		}
	}
}

// writeJSONAtomic replaces path with v as indented JSON: written to a temporary
// file in the same directory, synced, then renamed over the target, so a reader
// (the collector reading a cycle index) never sees a half-written file.
func writeJSONAtomic(path string, v any, mode os.FileMode) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(mode); err != nil && runtime.GOOS != "windows" {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	if err := d.Sync(); err != nil && runtime.GOOS != "windows" {
		return err
	}
	return nil
}

// errNoCycleSource marks a cycle that is neither on the host nor in the archive.
var errNoCycleSource = errors.New("no readable copy of the cycle")

// errHostNotAsked marks a cycle whose only readable copy is on a host this pass
// may not ask: the host is deferred, or the folder the index names was renamed
// since. The cycle waits for a later pass and is not charged a failed attempt.
var errHostNotAsked = errors.New("the host is not asked for this cycle now")
