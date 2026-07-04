// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package id implements the per-day 4-character unique-ID allocator
// defined in §7 of the Stash Service spec.
//
// Uniqueness scope: per UTC day, i.e. unique within one yyyy/mm/dd
// folder. Cross-day collisions are intentional (§12) and require no
// special handling.
//
// On first allocation for a day, the allocator scans the corresponding
// files/yyyy/mm/dd/ directory and seeds its "seen" set with the IDs
// already on disk. That makes the allocator restart-safe without
// persisting any state of its own.
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

	"stash-server/internal/config"
)

// Allocator is the §5.6 mutex-protected ID generator. Safe for use
// from multiple goroutines.
type Allocator struct {
	mu         sync.Mutex
	rng        *rand.Rand
	seenByDay  map[string]map[string]struct{}
	filesRoots []string
}

// New returns an allocator that scans for existing IDs under each of the
// given files roots. Pass the share's <StashFolder>/files/ AND the
// VM-local buffer's files/ so a daemon restart mid-outage cannot reissue
// an ID a not-yet-flushed buffered artifact already claims (§7, §8.4).
func New(filesRoots ...string) *Allocator {
	return &Allocator{
		rng:        rand.New(rand.NewSource(time.Now().UnixNano())),
		seenByDay:  make(map[string]map[string]struct{}),
		filesRoots: filesRoots,
	}
}

// Allocate returns a fresh 4-char ID unique within the UTC day of t.
// Returns an error only if the search space is exhausted (would only
// happen if a day already holds millions of IDs, which the spec does
// not target).
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
		if _, exists := seen[candidate]; !exists {
			seen[candidate] = struct{}{}
			return candidate, nil
		}
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
			// Day folder doesn't exist yet — fine. First allocation creates it via
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
