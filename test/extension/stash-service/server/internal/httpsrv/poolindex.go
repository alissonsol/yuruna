// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Pool-wide aggregation (stash-service-ui.md §3). The local host's stashes
// come from its SQLite index (live, including pending/buffered); every OTHER
// host's come from its on-share sidecars. To keep memory bounded as the pool
// ages (§3.2), the in-memory pool index holds only the last windowDays of
// remote sidecars, refreshed periodically; queries reaching older dates do
// an on-demand date-pruned deep scan instead.
package httpsrv

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"stash-server/internal/config"
	"stash-server/internal/meta"
)

// defaultPoolRefreshInterval is the cadence of the background rescan that
// picks up other hosts' new sidecars (§3.2). Overridable per instance.
const defaultPoolRefreshInterval = 60 * time.Second

// Item is one remote-host stash discovered from a sidecar.
type Item struct {
	HostID string
	Rec    *meta.Record
}

// PoolIndex caches recent remote-host sidecars and serves date-pruned scans.
type PoolIndex struct {
	stashRoot       string
	localHostID     string
	windowDays      int
	refreshInterval time.Duration

	mu          sync.RWMutex
	cache       []Item
	builtAt     time.Time
	lastScanErr string // dedupes the stashRoot-unreadable warning
}

// NewPoolIndex constructs the index. windowDays <= 0 / refresh <= 0 fall back
// to the spec defaults so a misconfiguration can't disable the window or spin
// the refresher.
func NewPoolIndex(stashRoot, localHostID string, windowDays int, refresh time.Duration) *PoolIndex {
	if windowDays <= 0 {
		windowDays = config.DefaultPoolWindowDays
	}
	if refresh <= 0 {
		refresh = defaultPoolRefreshInterval
	}
	return &PoolIndex{stashRoot: stashRoot, localHostID: localHostID, windowDays: windowDays, refreshInterval: refresh}
}

// RunRefresher does an initial scan then refreshes on every tick until ctx
// is cancelled. Run it in its own goroutine.
func (p *PoolIndex) RunRefresher(ctx context.Context) {
	p.Refresh()
	t := time.NewTicker(p.refreshInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.Refresh()
		}
	}
}

// windowCutoffUTC is midnight UTC windowDays ago — the oldest day the cache
// holds.
func (p *PoolIndex) windowCutoffUTC() time.Time {
	y, m, d := time.Now().UTC().Date()
	today := time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
	return today.AddDate(0, 0, -(p.windowDays - 1))
}

// Refresh rebuilds the in-memory cache from remote sidecars within the
// window. Errors are logged; a partial scan still updates the cache.
func (p *PoolIndex) Refresh() {
	cutoff := p.windowCutoffUTC()
	items, err := p.scan(func(day time.Time) bool { return !day.Before(cutoff) })
	if err != nil {
		log.Printf("poolindex: refresh: %v", err)
	}
	p.mu.Lock()
	p.cache = items
	p.builtAt = time.Now().UTC()
	p.mu.Unlock()
}

// Recent returns a snapshot of the cached in-window remote items.
func (p *PoolIndex) Recent() []Item {
	p.mu.RLock()
	defer p.mu.RUnlock()
	out := make([]Item, len(p.cache))
	copy(out, p.cache)
	return out
}

// Evict removes a remote item from the cache (after a delete elsewhere is
// observed, or to keep the local view tidy). Safe no-op if absent.
func (p *PoolIndex) Evict(hostID, id string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for i := range p.cache {
		if p.cache[i].HostID == hostID && p.cache[i].Rec.ID == id {
			p.cache = append(p.cache[:i], p.cache[i+1:]...)
			return
		}
	}
}

// DeepScan reads remote sidecars whose day is within [from,to], bypassing
// the cache. Used when a query's date range predates the in-memory window
// (§3.2). from/to are inclusive day bounds; a zero from means "no lower
// bound" and a zero to means "up to today".
func (p *PoolIndex) DeepScan(from, to time.Time) []Item {
	items, err := p.scan(func(day time.Time) bool {
		if !from.IsZero() && day.Before(dayFloor(from)) {
			return false
		}
		if !to.IsZero() && day.After(dayFloor(to)) {
			return false
		}
		return true
	})
	if err != nil {
		log.Printf("poolindex: deep scan: %v", err)
	}
	return items
}

// scan walks <stashRoot>/<hostId>/files/yyyy/mm/dd and reads every sidecar
// in an accepted day folder. Directory descent is pruned by the day filter
// so an out-of-window scan never opens those day folders. The local host's
// folder is skipped (its records come from the live index).
func (p *PoolIndex) scan(accept func(day time.Time) bool) ([]Item, error) {
	hosts, err := os.ReadDir(p.stashRoot)
	if err != nil {
		// stashRoot unavailable (share offline/unmounted, or not yet created)
		// just means there are no remote stashes to show right now — graceful
		// degradation (§8.4), not a hard error. The common offline case is
		// ErrNotExist (silent); a genuinely broken mount (EIO/EACCES/ESTALE)
		// is logged ONCE per state change so it stays diagnosable without
		// spamming every rescan.
		p.noteScanError(err)
		return nil, nil
	}
	p.noteScanError(nil)
	var items []Item
	for _, h := range hosts {
		if !h.IsDir() {
			continue
		}
		hostID := h.Name()
		if hostID == p.localHostID || !looksLikeHostID(hostID) {
			continue
		}
		filesRoot := filepath.Join(p.stashRoot, hostID, config.FilesDirName)
		years, err := os.ReadDir(filesRoot)
		if err != nil {
			continue // host with no files/ yet
		}
		for _, yE := range years {
			if !yE.IsDir() {
				continue
			}
			yN, ok := atoiOK(yE.Name())
			if !ok {
				continue
			}
			months, err := os.ReadDir(filepath.Join(filesRoot, yE.Name()))
			if err != nil {
				continue
			}
			for _, mE := range months {
				if !mE.IsDir() {
					continue
				}
				mN, ok := atoiOK(mE.Name())
				if !ok || mN < 1 || mN > 12 {
					continue
				}
				dayDirs, err := os.ReadDir(filepath.Join(filesRoot, yE.Name(), mE.Name()))
				if err != nil {
					continue
				}
				for _, dE := range dayDirs {
					if !dE.IsDir() {
						continue
					}
					dN, ok := atoiOK(dE.Name())
					if !ok || dN < 1 || dN > 31 {
						continue
					}
					day := time.Date(yN, time.Month(mN), dN, 0, 0, 0, 0, time.UTC)
					if !accept(day) {
						continue
					}
					dir := filepath.Join(filesRoot, yE.Name(), mE.Name(), dE.Name())
					items = appendDaySidecars(items, dir, hostID)
				}
			}
		}
	}
	return items, nil
}

// noteScanError logs a stashRoot-unreadable warning at most once per distinct
// error (and clears on recovery). ErrNotExist — the ordinary share-offline
// case — is treated as "no error" so it never logs.
func (p *PoolIndex) noteScanError(err error) {
	var s string
	if err != nil && !os.IsNotExist(err) {
		s = err.Error()
	}
	p.mu.Lock()
	changed := s != p.lastScanErr
	p.lastScanErr = s
	p.mu.Unlock()
	if changed && s != "" {
		log.Printf("poolindex: stashRoot %s unreadable (treating as no remote stashes): %s", p.stashRoot, s)
	}
}

func appendDaySidecars(items []Item, dir, hostID string) []Item {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return items
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), config.SidecarExtension) {
			continue
		}
		rec, err := meta.ReadSidecar(filepath.Join(dir, e.Name()))
		if err != nil {
			continue // skip a corrupt/partial sidecar, don't abort
		}
		items = append(items, Item{HostID: hostID, Rec: rec})
	}
	return items
}

// looksLikeHostID accepts only hostId-shaped directory names (hex, length
// >= 16 — the runtime/host.uuid format). This keeps the dev/local-fallback
// case (siblings like buffer/, metadata/) from being mis-scanned as hosts.
func looksLikeHostID(name string) bool {
	if len(name) < 16 {
		return false
	}
	for _, r := range name {
		switch {
		case r >= '0' && r <= '9':
		case r >= 'a' && r <= 'f':
		case r >= 'A' && r <= 'F':
		default:
			return false
		}
	}
	return true
}

func atoiOK(s string) (int, bool) {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, false
	}
	return n, true
}

func dayFloor(t time.Time) time.Time {
	y, m, d := t.UTC().Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// listFilter is the parsed query shared by the local SQL search and the
// in-memory remote match (stash-service-ui.md §4.2).
type listFilter struct {
	ID           string
	Username     string // substring (also matches exact)
	Filename     string // substring
	PathMeta     string // substring
	ContentClass string
	Status       string
	Host         string // facet: "" = all; localHostID or a remote hostId
	From         time.Time
	To           time.Time
}

// toMetaFilter maps onto the SQLite SearchFilter for the local index.
func (f listFilter) toMetaFilter(limit int) *meta.SearchFilter {
	mf := &meta.SearchFilter{
		ID:                f.ID,
		UsernameSubstring: f.Username,
		OriginalSubstring: f.Filename,
		PathMetaSubstring: f.PathMeta,
		ContentClass:      f.ContentClass,
		StatusExact:       f.Status,
		Limit:             limit,
	}
	if !f.From.IsZero() {
		t := f.From
		mf.CreatedAtFrom = &t
	}
	if !f.To.IsZero() {
		t := f.To
		mf.CreatedAtTo = &t
	}
	return mf
}

// match reports whether a remote record satisfies the filter (mirrors the
// SQL predicates for the in-memory remote path).
func (f listFilter) match(r *meta.Record) bool {
	if f.ID != "" && r.ID != f.ID {
		return false
	}
	if f.Username != "" && !containsFold(r.Username, f.Username) {
		return false
	}
	if f.Filename != "" && !containsFold(r.OriginalFilename, f.Filename) {
		return false
	}
	if f.PathMeta != "" && !containsFold(r.PathMetadata, f.PathMeta) {
		return false
	}
	if f.ContentClass != "" && r.ContentClass != f.ContentClass {
		return false
	}
	if f.Status != "" && r.Status != f.Status {
		return false
	}
	if !f.From.IsZero() && r.CreatedAt.Before(f.From) {
		return false
	}
	if !f.To.IsZero() && r.CreatedAt.After(f.To) {
		return false
	}
	return true
}

func containsFold(haystack, needle string) bool {
	return strings.Contains(strings.ToLower(haystack), strings.ToLower(needle))
}

// fromBeforeWindow reports whether the query's lower bound reaches before the
// cached window, requiring a deep scan (§3.2).
func (p *PoolIndex) fromBeforeWindow(from time.Time) bool {
	return !from.IsZero() && from.Before(p.windowCutoffUTC())
}

// toBeforeWindow reports whether the query's UPPER bound predates the cached
// window. An upper-bound-only query (e.g. to=2020-01-01, no from) would
// otherwise read only the in-window cache and then filter everything out;
// this routes it to a deep scan so out-of-window remote stashes are found.
func (p *PoolIndex) toBeforeWindow(to time.Time) bool {
	return !to.IsZero() && to.Before(p.windowCutoffUTC())
}

// sortViewsDesc orders views newest-first (the list/recent ordering, §4.1).
func sortViewsDesc(v []StashView) {
	sort.SliceStable(v, func(i, j int) bool { return v[i].CreatedAt.After(v[j].CreatedAt) })
}
