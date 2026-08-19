// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Pool-wide aggregation. The local host's stashes come from its SQLite index
// (live, including pending/buffered); every OTHER host's come from its
// on-share sidecars. To keep memory bounded as the pool ages (section 3.2), the
// in-memory pool index holds only the last windowDays of remote sidecars,
// refreshed periodically; queries reaching older dates do an on-demand
// date-pruned deep scan instead.
package httpsrv

import (
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"stash-service/internal/config"
	"stash-service/internal/meta"
)

// defaultPoolRefreshInterval is the cadence of the background rescan that
// picks up other hosts' new sidecars (section 3.2). Overridable per instance.
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

	mu                 sync.RWMutex
	cache              []Item
	builtAt            time.Time
	lastScanErr        string // dedupes the stashRoot-unreadable warning
	lastRefreshPartial bool   // the last Refresh could not read every remote dir (cache may miss hosts)
	lastScanPartial    bool   // dedupes the partial-scan warning (any scan path)
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

// RefreshInterval is the cadence the caller drives Refresh on. Exported so the
// server can run the rescan and the index reconcile off one ticker
// (reconcile.go): both read the same mount, and probing it twice a period to
// learn the same thing twice buys nothing.
func (p *PoolIndex) RefreshInterval() time.Duration { return p.refreshInterval }

// windowCutoffUTC is midnight UTC windowDays ago -- the oldest day the cache
// holds.
func (p *PoolIndex) windowCutoffUTC() time.Time {
	y, m, d := time.Now().UTC().Date()
	today := time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
	return today.AddDate(0, 0, -(p.windowDays - 1))
}

// Refresh rebuilds the in-memory cache from remote sidecars within the
// window. Scan errors are logged (deduped) inside scan; a partial scan still
// updates the cache, and its partial flag is retained so the Recent() path
// can tell callers the cached view may be missing hosts.
func (p *PoolIndex) Refresh() {
	cutoff := p.windowCutoffUTC()
	items, partial, errReads := p.scan(func(day time.Time) bool { return !day.Before(cutoff) })
	p.mu.Lock()
	p.cache = items
	p.builtAt = time.Now().UTC()
	p.lastRefreshPartial = partial
	p.mu.Unlock()
	// Drive the deduped partial-scan warning from the steady refresh only (not
	// the sporadic on-demand DeepScan), called outside the lock notePartialScan
	// takes itself.
	p.notePartialScan(partial, errReads)
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
// (section 3.2). from/to are inclusive day bounds; a zero from means "no lower
// bound" and a zero to means "up to today". The bool return is true when the
// walk could not read every directory it should have, so the caller can flag
// a partial result instead of trusting a short/empty list.
func (p *PoolIndex) DeepScan(from, to time.Time) ([]Item, bool) {
	items, partial, _ := p.scan(func(day time.Time) bool {
		if !from.IsZero() && day.Before(dayFloor(from)) {
			return false
		}
		if !to.IsZero() && day.After(dayFloor(to)) {
			return false
		}
		return true
	})
	return items, partial
}

// scan walks <stashRoot>/<hostId>/files/yyyy/mm/dd and reads every sidecar
// in an accepted day folder. Directory descent is pruned by the day filter
// so an out-of-window scan never opens those day folders. The local host's
// folder is skipped (its records come from the live index).
// The int return is the count of non-ErrNotExist directory-read failures, for
// the caller's deduped partial-scan logging; partial (the bool) is true when
// that count is non-zero OR the stashRoot itself was unreadable for a real
// reason.
func (p *PoolIndex) scan(accept func(day time.Time) bool) ([]Item, bool, int) {
	hosts, err := os.ReadDir(p.stashRoot)
	if err != nil {
		// stashRoot unavailable (share offline/unmounted, or not yet created)
		// just means there are no remote stashes to show right now -- graceful
		// degradation (section 8.4), not a hard error. The common offline case is
		// ErrNotExist (silent); a genuinely broken mount (EIO/EACCES/ESTALE)
		// is logged ONCE per state change so it stays diagnosable without
		// spamming every rescan.
		p.noteScanError(err)
		return nil, !os.IsNotExist(err), 0
	}
	p.noteScanError(nil)

	// errReads counts directories the walk should have been able to read but
	// could not for a reason OTHER than absence (EACCES/EIO/ESTALE). An absent
	// path (ErrNotExist) is ordinary -- a host with no files/ yet, or a folder
	// that vanished between listing and descent -- and is not counted. A
	// non-zero count means the resulting item set is short, so the caller must
	// treat it as a partial pool view rather than an authoritative one.
	var items []Item
	errReads := 0
	tryReadDir := func(path string) ([]os.DirEntry, bool) {
		entries, e := os.ReadDir(path)
		if e != nil {
			if !os.IsNotExist(e) {
				errReads++
			}
			return nil, false
		}
		return entries, true
	}

	for _, h := range hosts {
		if !h.IsDir() {
			continue
		}
		hostID := h.Name()
		if hostID == p.localHostID || !looksLikeHostID(hostID) {
			continue
		}
		filesRoot := filepath.Join(p.stashRoot, hostID, config.FilesDirName)
		years, ok := tryReadDir(filesRoot)
		if !ok {
			continue
		}
		for _, yE := range years {
			if !yE.IsDir() {
				continue
			}
			yN, ok := atoiOK(yE.Name())
			if !ok {
				continue
			}
			months, ok := tryReadDir(filepath.Join(filesRoot, yE.Name()))
			if !ok {
				continue
			}
			for _, mE := range months {
				if !mE.IsDir() {
					continue
				}
				mN, ok := atoiOK(mE.Name())
				if !ok || !validMonth(mN) {
					continue
				}
				dayDirs, ok := tryReadDir(filepath.Join(filesRoot, yE.Name(), mE.Name()))
				if !ok {
					continue
				}
				for _, dE := range dayDirs {
					if !dE.IsDir() {
						continue
					}
					dN, ok := atoiOK(dE.Name())
					if !ok || !validDay(dN) {
						continue
					}
					day := time.Date(yN, time.Month(mN), dN, 0, 0, 0, 0, time.UTC)
					if !accept(day) {
						continue
					}
					dir := filepath.Join(filesRoot, yE.Name(), mE.Name(), dE.Name())
					var bad bool
					items, bad = appendDaySidecars(items, dir, hostID)
					if bad {
						errReads++
					}
				}
			}
		}
	}
	return items, errReads > 0, errReads
}

// noteScanError logs a stashRoot-unreadable warning at most once per distinct
// error (and clears on recovery). ErrNotExist -- the ordinary share-offline
// case -- is treated as "no error" so it never logs.
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

// notePartialScan logs, at most once per transition into a partial state,
// that the walk skipped one or more directories it should have been able to
// read (a real read error, not an absent path). Only the steady periodic
// refresh drives this dedup -- a sporadic on-demand DeepScan surfaces its own
// partiality to its caller instead -- so the warning stays quiet while the
// condition persists and re-arms once a refresh reads everything, keeping a
// broken mount diagnosable without spamming every rescan.
func (p *PoolIndex) notePartialScan(partial bool, errReads int) {
	p.mu.Lock()
	changed := partial != p.lastScanPartial
	p.lastScanPartial = partial
	p.mu.Unlock()
	if changed && partial {
		log.Printf("poolindex: scan skipped %d unreadable dir(s) under %s; pool view is partial", errReads, p.stashRoot)
	}
}

// LastRefreshPartial reports whether the most recent background Refresh could
// not read every remote directory, so the cached Recent() view may be missing
// hosts. The list handler surfaces this so a short/empty result is not
// mistaken for an authoritative one.
func (p *PoolIndex) LastRefreshPartial() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.lastRefreshPartial
}

// appendDaySidecars appends the sidecars in a single day folder. The bool is
// true when the day folder itself could not be read for a reason other than
// absence, so the caller can account it toward a partial scan; a corrupt
// individual sidecar is skipped without flagging the whole folder.
func appendDaySidecars(items []Item, dir, hostID string) ([]Item, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return items, !os.IsNotExist(err)
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
	return items, false
}

// looksLikeHostID accepts only hostId-shaped directory names (hex, length
// >= 16 -- the runtime/host.uuid format). This keeps the dev/local-fallback
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

// validMonth / validDay range-check a parsed month (1..12) / day (1..31), shared
// by parsePathKey (the request path) and the pool day-folder scan so the two
// paths cannot drift on the accepted range. The year bound is intentionally NOT
// shared: parsePathKey bounds 1970..9999 while the scan accepts any parseable year.
func validMonth(n int) bool { return n >= 1 && n <= 12 }
func validDay(n int) bool   { return n >= 1 && n <= 31 }

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
// in-memory remote match.
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
// cached window, requiring a deep scan (section 3.2).
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

// The columns the list can be ordered by, named as the UI's `sort` query value.
// Sorting happens HERE, over the merged local+remote set, and not in the
// browser: the list is paged, so a browser could only order the rows it has
// been given, and "smallest first" over one page of a larger corpus is an
// answer to a question nobody asked.
const (
	sortCreated = "created"
	sortID      = "id"
	sortName    = "name"
	sortHost    = "host"
	sortUser    = "user"
	sortSize    = "size"
	sortStatus  = "status"
	sortType    = "type"
)

// sortColumn normalizes a requested column, falling back to the newest-first
// default for anything unrecognized. A stale bookmark or a hand-typed parameter
// renders a list rather than an error -- ordering is a view preference, and
// there is no wrong answer worth a 400.
func sortColumn(col string) string {
	switch col {
	case sortID, sortName, sortHost, sortUser, sortSize, sortStatus, sortType:
		return col
	default:
		return sortCreated
	}
}

// sortViews orders views by one column. Ascending when asc; the default view
// (newest first) is sortCreated descending (section 4.1).
//
// Every ordering is TOTAL, not merely sorted: ties break on created-then-id, in
// a fixed direction, so two stashes of the same size (or the same status, which
// most of them share) hold one order across requests. Paging is offset-based
// over a freshly sorted set each time, so an order that could shuffle equal
// rows between two requests would let "Load more" skip a stash or serve one
// twice -- the tiebreak is what makes the window mean anything.
func sortViews(v []StashView, col string, asc bool) {
	cmp := viewComparator(col)
	sort.SliceStable(v, func(i, j int) bool {
		if c := cmp(&v[i], &v[j]); c != 0 {
			if asc {
				return c < 0
			}
			return c > 0
		}
		return tiebreakViews(&v[i], &v[j]) < 0
	})
}

// viewComparator returns the three-way comparison for one column.
func viewComparator(col string) func(a, b *StashView) int {
	switch col {
	case sortID:
		return func(a, b *StashView) int { return cmpText(a.ID, b.ID) }
	case sortName:
		return func(a, b *StashView) int { return cmpText(a.OriginalFilename, b.OriginalFilename) }
	case sortHost:
		return func(a, b *StashView) int { return cmpText(a.HostID, b.HostID) }
	case sortUser:
		return func(a, b *StashView) int { return cmpText(a.Username, b.Username) }
	case sortSize:
		return func(a, b *StashView) int { return cmpInt64(a.SizeBytes, b.SizeBytes) }
	case sortStatus:
		return func(a, b *StashView) int { return cmpText(a.Status, b.Status) }
	case sortType:
		// The cell shows an icon, so ordering by the class behind it is what
		// makes same-looking rows gather -- which is the whole point of sorting
		// a column whose values cannot be read as words.
		return func(a, b *StashView) int { return cmpText(a.ContentClass, b.ContentClass) }
	default:
		return func(a, b *StashView) int { return cmpTime(a.CreatedAt, b.CreatedAt) }
	}
}

// tiebreakViews is the fixed order equal rows fall back to: newest first, then
// id. Never reversed with the column -- reversing the tiebreak too would make a
// direction flip reshuffle rows the operator did not sort on.
func tiebreakViews(a, b *StashView) int {
	if c := cmpTime(a.CreatedAt, b.CreatedAt); c != 0 {
		return -c // newest first
	}
	return cmpText(a.ID, b.ID)
}

// cmpText compares case-insensitively, so a capitalized filename sorts where a
// reader expects rather than ahead of every lowercase one. Equal-ignoring-case
// values fall through to the tiebreak, keeping the order total.
func cmpText(a, b string) int {
	return strings.Compare(strings.ToLower(a), strings.ToLower(b))
}

func cmpInt64(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

func cmpTime(a, b time.Time) int {
	switch {
	case a.Before(b):
		return -1
	case a.After(b):
		return 1
	}
	return 0
}
