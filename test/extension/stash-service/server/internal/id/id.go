// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package id implements the 4-character unique-ID allocator defined in
// section 7 of the stash service spec.
//
// Uniqueness scope: an ID must be free in BOTH namespaces it lands in --
// the day folder that stores the artifact, and the metadata index, whose
// id column is a primary key spanning every day the index covers. An ID
// free in today's folder but claimed by an older index row is not free:
// the index insert loses on the primary key and the upload is refused, so
// the existence check is part of allocation rather than a caller's problem.
//
// On first allocation for a day, the allocator scans the corresponding
// files/yyyy/mm/dd/ directory and seeds its "seen" set with the IDs
// already on disk. That makes the allocator restart-safe without
// persisting any state of its own. The index check runs per candidate,
// because there is no per-day slice of the index to seed from.
package id

import (
	"fmt"
	"log"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"stash-service/internal/config"
)

// ExistsFunc reports whether an ID is already claimed outside the day
// folders the allocator scans -- in practice, by a row in the metadata
// index. A lookup failure is returned rather than swallowed: answering
// "free" on a failed check is how an ID gets issued twice.
//
// It is a function, not the metadata store itself, so this package stays
// free of the storage layer (which imports config alongside it) and so a
// caller with no index -- a standalone tool, a test -- can pass nil.
type ExistsFunc func(id string) (bool, error)

// Allocator is the section 5.6 mutex-protected ID generator. Safe for use
// from multiple goroutines.
type Allocator struct {
	mu         sync.Mutex
	rng        *rand.Rand
	seenByDay  map[string]map[string]struct{}
	filesRoots []string
	exists     ExistsFunc
}

// New returns an allocator that scans for existing IDs under each of the
// given files roots and, when exists is non-nil, rejects any candidate it
// reports as claimed. Pass the share's <StashFolder>/files/ AND the
// VM-local buffer's files/ so a daemon restart mid-outage cannot reissue
// an ID a not-yet-flushed buffered artifact already claims (section 7, section 8.4).
// A nil exists narrows the scope back to the day folders, which is enough
// for a caller with no index behind it.
func New(exists ExistsFunc, filesRoots ...string) *Allocator {
	return &Allocator{
		rng:        rand.New(rand.NewSource(time.Now().UnixNano())),
		seenByDay:  make(map[string]map[string]struct{}),
		filesRoots: filesRoots,
		exists:     exists,
	}
}

// Allocate returns a fresh 4-char ID free in the UTC day of t and,
// when an existence check is configured, free of every claim it knows
// about. Returns an error if the existence check fails or the search
// space is exhausted (which would need a day already holding millions
// of IDs, well past what the spec targets).
func (a *Allocator) Allocate(t time.Time) (string, error) {
	dayKey := t.UTC().Format("2006-01-02")
	a.mu.Lock()
	defer a.mu.Unlock()
	seen, ok := a.seenByDay[dayKey]
	if !ok {
		seen = make(map[string]struct{})
		for _, root := range a.filesRoots {
			if err := a.populateFromDisk(root, t.UTC(), seen); err != nil {
				// A real (non-not-exist) read error means the on-disk seed is incomplete. Do NOT
				// cache the partial set or hand out an ID -- we could reissue one an existing
				// artifact already claims. Fail so the caller can retry.
				return "", fmt.Errorf("seed id scan for %s: %w", dayKey, err)
			}
		}
		a.seenByDay[dayKey] = seen
	}
	for tries := 0; tries < 10000; tries++ {
		candidate := a.random()
		if _, drawn := seen[candidate]; drawn {
			continue
		}
		if a.exists != nil {
			claimed, err := a.exists(candidate)
			if err != nil {
				// Same rule as a failed disk scan: an unanswered question about a
				// candidate is not a yes. Fail the allocation instead of issuing an
				// ID that may already be spoken for.
				return "", fmt.Errorf("existence check for %q: %w", candidate, err)
			}
			if claimed {
				// Burn it in the day's set so the loop -- and every later call for
				// this day -- stops paying for the same lookup twice.
				seen[candidate] = struct{}{}
				continue
			}
		}
		seen[candidate] = struct{}{}
		return candidate, nil
	}
	return "", fmt.Errorf("could not allocate a unique ID within %s after 10000 tries", dayKey)
}

func (a *Allocator) random() string {
	b := make([]byte, config.IDLength)
	for i := range b {
		b[i] = config.IDAlphabet[a.rng.Intn(len(config.IDAlphabet))]
	}
	return string(b)
}

// populateFromDisk seeds seen with IDs already stored under
// filesRoot/yyyy/mm/dd/. The ID is always the first IDLength characters
// of the filename: <id>, <id>.ext, <id>.yuruna.archive.zip, or the
// <id>.yuruna.meta.json sidecar.
func (a *Allocator) populateFromDisk(filesRoot string, t time.Time, seen map[string]struct{}) error {
	dayDir := filepath.Join(filesRoot, t.Format("2006/01/02"))
	entries, err := os.ReadDir(dayDir)
	if err != nil {
		if os.IsNotExist(err) {
			// Day folder doesn't exist yet -- fine. First allocation creates it via
			// Store.DayDir; the seen set starts empty.
			return nil
		}
		// A real read error (permission, transient I/O) must be surfaced: proceeding with an
		// empty seen set risks reissuing an ID already stored on disk.
		log.Printf("id: scan %s for existing IDs failed: %v", dayDir, err)
		return err
	}
	for _, e := range entries {
		name := e.Name()
		// Ignore in-progress staging dirs (<id>.staging) but DO count
		// the <id> they reserve so the allocator doesn't hand it out
		// twice.
		if strings.HasSuffix(name, ".staging") {
			name = strings.TrimSuffix(name, ".staging")
		}
		if len(name) >= config.IDLength {
			id := name[:config.IDLength]
			if isValidID(id) {
				seen[id] = struct{}{}
			}
		}
	}
	return nil
}

func isValidID(s string) bool {
	if len(s) != config.IDLength {
		return false
	}
	for _, r := range s {
		if !strings.ContainsRune(config.IDAlphabet, r) {
			return false
		}
	}
	return true
}
