// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// A host's status service builds every listing in PowerShell and serves one
	// request at a time, so a large history bucket can take seconds and a reply
	// is waited for far longer than a live probe would be.
	backfillRequestTimeout = 60 * time.Second
	maxListingBytes        = 8 << 20
	// The host refuses files over 50 MB; an event file anywhere near that size is
	// not one this job can replay usefully, so the read stops well before it.
	maxEventsFileBytes = 16 << 20
)

// activeHost is one host the collector reaches right now, as its pool-status
// document reports it.
type activeHost struct {
	HostID   string
	BaseURL  string
	Pool     string
	HostType string
	// CurrentStart is the start of the cycle the host is running, or last ran.
	// That cycle belongs to the collector, which is following it live.
	CurrentStart time.Time
	// CurrentStatus is that cycle's overallStatus right now.
	CurrentStatus string
}

// poolStatusDoc is the subset of /api/v1/pool-status the backfill reads.
type poolStatusDoc struct {
	Pool  string `json:"pool"`
	Hosts []struct {
		HostID    string      `json:"hostId"`
		BaseURL   string      `json:"baseUrl"`
		Reachable bool        `json:"reachable"`
		PoolID    string      `json:"poolId"`
		Status    *hostStatus `json:"status"`
	} `json:"hosts"`
}

// parseUTC reads an RFC 3339 time and returns it in UTC. A value without a zone
// designator is refused rather than guessed at: every time the backfill writes is
// UTC, and a local time read as UTC would move a cycle by the host's offset.
func parseUTC(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(s))
	if err != nil {
		return time.Time{}, false
	}
	return t.UTC(), true
}

// formatUTC renders a time the way hosts write cycleStartUtc, startedAt and
// finishedAt: whole seconds, UTC, with a literal Z.
func formatUTC(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

// parsePoolStatus returns the hosts worth backfilling: reachable, carrying a
// status document, and named by a lowercase 32-hex id. The pool label is the one
// the collector stamps on the host's live data -- its registered pool, else the
// collector's own default -- so backfilled and live lines land in the same pool.
func parsePoolStatus(body []byte) ([]activeHost, error) {
	var doc poolStatusDoc
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, err
	}
	fallbackPool := doc.Pool
	if fallbackPool == "" {
		fallbackPool = defaultPool
	}
	var out []activeHost
	for _, h := range doc.Hosts {
		id := strings.TrimSpace(h.HostID)
		if !plainHostIDRE.MatchString(id) || id != strings.ToLower(id) || !h.Reachable || h.Status == nil {
			continue
		}
		base := strings.TrimRight(strings.TrimSpace(h.BaseURL), "/")
		if base == "" {
			continue
		}
		pool := h.PoolID
		if pool == "" {
			pool = fallbackPool
		}
		ah := activeHost{HostID: id, BaseURL: base, Pool: pool, HostType: h.Status.Host, CurrentStatus: h.Status.OverallStatus}
		if t, ok := parseUTC(h.Status.CycleStartUtc); ok {
			ah.CurrentStart = t
		}
		out = append(out, ah)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].HostID < out[j].HostID })
	return out, nil
}

var (
	listingHrefRE = regexp.MustCompile(`href="([^"]+)"`)
	// A cycle folder as it sits on a host: the identity, then ".incomplete" while
	// the cycle runs, or ".aborted.<UTC>" once boot recovery has closed a killed one.
	cycleLeafRE     = regexp.MustCompile(`^(\d{6})\.(\d{4}-\d{2}-\d{2})\.(\d{2}-\d{2}-\d{2})\.([0-9a-f]{32})(\.incomplete|\.aborted\.\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z)?$`)
	historyBucketRE = regexp.MustCompile(`^history\.\d{4}-\d{2}-\d{2}$`)
)

// bucketDate is the date a history bucket is named for: the host's local date on
// the day rotation moved cycles into it, so every cycle inside started on or
// before that date.
func bucketDate(name string) (time.Time, bool) {
	if !historyBucketRE.MatchString(name) {
		return time.Time{}, false
	}
	d, err := time.Parse("2006-01-02", strings.TrimPrefix(name, "history."))
	return d, err == nil
}

// parseListing splits a host's HTML directory index into the child folder names
// it links: cycle leaves and history buckets alike, unescaped and without the
// trailing slash. The visible text is never read -- hosts wrap it in Unicode
// isolates -- only the href, which is the folder name URL-escaped.
func parseListing(body string) (leaves, buckets []string) {
	for _, m := range listingHrefRE.FindAllStringSubmatch(body, -1) {
		name, err := url.PathUnescape(m[1])
		if err != nil {
			continue
		}
		name = strings.TrimSuffix(name, "/")
		if name == "" || strings.ContainsAny(name, `/\?#`) {
			continue
		}
		switch {
		case historyBucketRE.MatchString(name):
			buckets = append(buckets, name)
		case cycleLeafRE.MatchString(name):
			leaves = append(leaves, name)
		}
	}
	return leaves, buckets
}

// cycleFolder is one cycle of one host, wherever a readable copy of it is.
type cycleFolder struct {
	Identity string    // NNNNNN.YYYY-MM-DD.HH-MM-SS.<hostId>, with no suffix
	Start    time.Time // UTC, from the folder name
	// RelDir is the folder under the host's status root, e.g.
	// "log/history.2026-08-05/<leaf>/". Empty when only the archive has it.
	RelDir string
	// ArchiveDir is the folder on the pool share as this machine mounts it. Empty
	// when the archive does not hold a committed copy.
	ArchiveDir string
}

// cycleFolderFromLeaf reads one leaf. A leaf of another host is refused: a
// one-shot run on the same machine can leave a folder under a different id.
func cycleFolderFromLeaf(leaf, hostID, parent string) (cycleFolder, bool) {
	m := cycleLeafRE.FindStringSubmatch(leaf)
	if m == nil || m[4] != hostID {
		return cycleFolder{}, false
	}
	start, err := time.Parse("2006-01-02 15-04-05", m[2]+" "+m[3])
	if err != nil {
		return cycleFolder{}, false
	}
	identity := m[1] + "." + m[2] + "." + m[3] + "." + m[4]
	return cycleFolder{Identity: identity, Start: start.UTC(), RelDir: parent + leaf + "/"}, true
}

// mergeFolder records a host copy of a cycle. A bucket copy wins over a top-level
// one: on a host that copies to the pool share, the top-level index also lists
// archived names that the host only serves by reaching through to the share.
func mergeFolder(into map[string]cycleFolder, cf cycleFolder) {
	prev, ok := into[cf.Identity]
	if !ok {
		into[cf.Identity] = cf
		return
	}
	if strings.Contains(cf.RelDir, "/history.") && !strings.Contains(prev.RelDir, "/history.") {
		prev.RelDir = cf.RelDir
		into[cf.Identity] = prev
	}
}

// archiveFolders lists the committed copies of a host's cycles on the pool share:
// <root>/<hostId>/test-cycles/<identity>/ with the .yuruna-complete sentinel the
// archiver writes last. A folder without it may still be copying.
func archiveFolders(root, hostID string) map[string]string {
	out := map[string]string{}
	if root == "" || !hostIDRe.MatchString(hostID) {
		return out
	}
	dir := filepath.Join(root, hostID, "test-cycles")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return out
	}
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() || !archiveCycleRe.MatchString(name) || !strings.HasSuffix(name, "."+hostID) {
			continue
		}
		full := filepath.Join(dir, name)
		if st, err := os.Stat(filepath.Join(full, ".yuruna-complete")); err == nil && !st.IsDir() {
			out[name] = full
		}
	}
	return out
}

// pacer spaces the requests one host receives. Its status service is a single
// PowerShell listener that also answers the collector's poll and the operator's
// browser, so the backfill never sends it a second request before the interval
// has passed.
type pacer struct {
	mu       sync.Mutex
	next     time.Time
	interval time.Duration
	now      func() time.Time
	sleep    func(ctx context.Context, d time.Duration) bool
}

// wait blocks until this caller may send, and reports false when ctx ended first.
func (p *pacer) wait(ctx context.Context) bool {
	return p.reserve(ctx, p.interval)
}

// reserve is wait with a slot of length d in place of the fixed interval: the
// next caller is held until d after this one was let through. A slot sized to
// the request is how a byte budget is kept with the same pacer.
func (p *pacer) reserve(ctx context.Context, d time.Duration) bool {
	p.mu.Lock()
	now := p.now()
	at := p.next
	if at.Before(now) {
		at = now
	}
	p.next = at.Add(d)
	p.mu.Unlock()
	if wait := at.Sub(now); wait > 0 {
		return p.sleep(ctx, wait)
	}
	return ctx.Err() == nil
}

// atLeast holds the next caller until at least d from now. A host that took long
// to answer is given that much longer before the next request.
func (p *pacer) atLeast(d time.Duration) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if at := p.now().Add(d); at.After(p.next) {
		p.next = at
	}
}

// sleepCtx sleeps for d and reports false when ctx ended first.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

// getBounded GETs a URL and returns the body of a 200 answer, refusing one larger
// than limit instead of truncating it into something that parses.
func getBounded(ctx context.Context, client *http.Client, u string, limit int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, backfillRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// Loki and Prometheus say why they refused a query in the body; the first
		// line of it is what makes the log entry actionable.
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("GET %s: HTTP %d: %s", u, resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("GET %s: answer larger than %d bytes", u, limit)
	}
	return body, nil
}

// readFileBounded reads a local file of at most limit bytes.
func readFileBounded(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New(path + ": larger than " + strconv.FormatInt(limit, 10) + " bytes")
	}
	return data, nil
}
