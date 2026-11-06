// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 424b9922-45d2-47db-bfb5-a57c1b4da9c9

package routes

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"yuruna.com/test/extension/extension-sdk/controlproof"
	"yuruna.com/test/extension/pool-aggregator-service/internal/extensions"
	"yuruna.com/test/extension/pool-aggregator-service/internal/hostpoll"
	"yuruna.com/test/extension/pool-aggregator-service/internal/httpserve"
	"yuruna.com/test/extension/pool-aggregator-service/internal/loki"
	"yuruna.com/test/extension/pool-aggregator-service/internal/poolstate"
)

// The Loki range query and its answer, and the bound on one host request;
// these names keep the resolvers readable.
type lokiStreamsResult = loki.Streams

var queryRangeURL = loki.QueryRangeURL

const (
	pushTimeout  = loki.RequestTimeout
	probeTimeout = hostpoll.ProbeTimeout
)

// cycleCand is one Loki transition line parsed for /go/cycle's time->cycle match.
type cycleCand struct {
	started, finished, ingest   time.Time
	folderURL, baseURL, cycleID string
}

// pickCycleForTime chooses the cycle whose [started,finished] window contains t;
// failing that (a still-running cycle with no finishedAt, or a gap between cycles)
// it returns the candidate whose timestamp is nearest t. Pure + table-testable;
// ok=false only for empty input. MUST stay free of I/O so the resolver's matching
// is unit-tested without a live Loki.
func pickCycleForTime(cands []cycleCand, t time.Time) (cycleCand, bool) {
	for _, c := range cands {
		if !c.started.IsZero() && !c.finished.IsZero() && !t.Before(c.started) && !t.After(c.finished) {
			return c, true
		}
	}
	best, found := cycleCand{}, false
	var bestDelta time.Duration
	for _, c := range cands {
		ref := c.ingest
		if ref.IsZero() {
			ref = c.started
		}
		if ref.IsZero() {
			continue
		}
		d := ref.Sub(t)
		if d < 0 {
			d = -d
		}
		if !found || d < bestDelta {
			best, bestDelta, found = c, d, true
		}
	}
	return best, found
}

// lookupCycleAt queries the Loki transition feed ({pool,hostId,src=cycle}) for the
// cycle a host was running at time t and returns its results-folder URL + the
// baseURL recorded then. Best-effort + bounded (a 6h window each side, line cap):
// any Loki error or no usable match returns ok=false, and the caller degrades to
// the host's current status root.
func (s *Server) lookupCycleAt(pool, hostID string, t time.Time) (folderURL, baseURL string, ok bool) {
	if t.IsZero() || s.lokiURL == "" || s.httpClient == nil {
		return "", "", false
	}
	queryURL := queryRangeURL(s.lokiURL)
	const win = 6 * time.Hour
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=%q, hostId=%q, src="cycle"} | json`, pool, hostID))
	params.Set("start", strconv.FormatInt(t.Add(-win).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(t.Add(win).UnixNano(), 10))
	params.Set("limit", "200")
	params.Set("direction", "backward")

	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		return "", "", false
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return "", "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", false
	}
	var lr lokiStreamsResult
	if json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&lr) != nil {
		return "", "", false
	}
	var cands []cycleCand
	for _, st := range lr.Data.Result {
		for _, v := range st.Values {
			var e struct {
				StartedAt      string `json:"startedAt"`
				FinishedAt     string `json:"finishedAt"`
				CycleFolderUrl string `json:"cycleFolderUrl"`
				BaseUrl        string `json:"baseUrl"`
				CycleStartUtc  string `json:"cycleStartUtc"`
			}
			if json.Unmarshal([]byte(v[1]), &e) != nil {
				continue
			}
			c := cycleCand{folderURL: e.CycleFolderUrl, baseURL: e.BaseUrl, cycleID: e.CycleStartUtc}
			if ns, perr := strconv.ParseInt(v[0], 10, 64); perr == nil {
				c.ingest = time.Unix(0, ns)
			}
			if tt, perr := time.Parse(time.RFC3339, e.StartedAt); perr == nil {
				c.started = tt
			}
			if tt, perr := time.Parse(time.RFC3339, e.FinishedAt); perr == nil {
				c.finished = tt
			}
			cands = append(cands, c)
		}
	}
	c, found := pickCycleForTime(cands, t)
	if !found || c.folderURL == "" {
		return "", "", false
	}
	return c.folderURL, c.baseURL, true
}

// LastKnownBaseURL returns the most recent baseUrl (host IP) the transition feed
// recorded for a host -- the fallback for resolving a host's address when it is not
// in the live in-memory view (just after a collector restart, or an idle host that
// hasn't been re-discovered yet). Best-effort + bounded -> "".
func (s *Server) LastKnownBaseURL(pool, hostID string) string {
	if s.lokiURL == "" || s.httpClient == nil {
		return ""
	}
	now := time.Now().UTC()
	queryURL := queryRangeURL(s.lokiURL)
	params := url.Values{}
	params.Set("query", fmt.Sprintf(`{pool=%q, hostId=%q, src="cycle"} | json`, pool, hostID))
	params.Set("start", strconv.FormatInt(now.Add(-s.deepLinkLookback).UnixNano(), 10))
	params.Set("end", strconv.FormatInt(now.UnixNano(), 10))
	params.Set("limit", "1")
	params.Set("direction", "backward")

	ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, queryURL+"?"+params.Encode(), nil)
	if err != nil {
		return ""
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var lr lokiStreamsResult
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&lr) != nil {
		return ""
	}
	for _, st := range lr.Data.Result {
		for _, v := range st.Values {
			var e struct {
				BaseUrl string `json:"baseUrl"`
			}
			if json.Unmarshal([]byte(v[1]), &e) == nil && e.BaseUrl != "" {
				return e.BaseUrl
			}
		}
	}
	return ""
}

// ResolveHostBase resolves a hostId to the host's CURRENT status-page base URL -- the
// uuid->IP step shared by the dashboard deep-links (/go/cycle and /go/host). Prefers
// the live in-memory IP (freshest -- survives an IP change), else the last IP the Loki
// transition feed recorded (host not in the live view, e.g. just after a collector
// restart, before re-discovery). Returns "" when the host is unknown to the pool. An
// empty pool is normalized to the host's pool so the Loki fallback can scope its query;
// the normalized pool is returned for callers that need it downstream.
func (s *Server) ResolveHostBase(hostID, pool string) (base, resolvedPool string) {
	var currentID string
	s.st.Do(func(view *poolstate.View) {
		currentID = view.CanonicalHostID(hostID)
		if hv := view.Hosts[currentID]; hv != nil {
			base = hv.BaseURL
		}
		if pool == "" {
			pool = s.poolFor(view, currentID)
		}
	})
	if base == "" {
		base = s.LastKnownBaseURL(pool, currentID)
		if base == "" && currentID != hostID {
			base = s.LastKnownBaseURL(pool, hostID)
		}
	}
	return base, pool
}

// The two spellings of one hostId (dashed for display, plain as the view's key)
// are rendered and folded back in internal/poolstate. plainHostIDRE there
// deliberately does NOT reuse HostIDRe, which spells the same shape: that one is
// the /archive/ route's authorization gate, and tightening a gate must not
// silently change how an id is printed.
var (
	normalizeHostID = poolstate.NormalizeHostID
	dashedHostID    = poolstate.DashedHostID
)

// HandleGoHost bridges a dashboard click -> the host's OWN status-page root, resolving
// the host's CURRENT IP server-side (the same uuid->IP resolution as /go/cycle, so the
// link survives a host IP change). Distinct from /go/cycle, which targets a specific
// cycle-results folder; this always lands on the status root. The state-timeline series
// is intentionally IP-free (keyed on hostId so a host's row doesn't split on an IP
// change), so the link can't carry the IP and must resolve it here. Host unknown -> 404.
func (s *Server) HandleGoHost(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.missing_host", http.StatusBadRequest)
		return
	}
	// pool-control asks with scope=pause for the pool-wide pause and continue: that
	// proof opens the host's pause and resume routes and nothing else on it.
	scope := strings.TrimSpace(q.Get("scope"))
	if scope != "" && !controlproof.ValidScope(scope) {
		localizedHTTPError(w, r, "aggregator.invalid_control_scope", http.StatusBadRequest)
		return
	}
	base, _ := s.ResolveHostBase(hostID, strings.TrimSpace(q.Get("pool")))
	if base == "" {
		localizedHTTPError(w, r, "aggregator.host_not_known_to_the_pool", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	// Carry a short-lived control proof to the host UI in the URL FRAGMENT (never sent to
	// a server or written to an access log; the status page JS reads location.hash). This
	// lets the operator drive the host's mutating /control/* routes after arriving through
	// the (to-be-authenticated) Grafana dashboard, without the host trusting the whole LAN.
	// No token configured -> no fragment -> the host accepts only loopback control.
	dest := strings.TrimRight(base, "/")
	proof := MintControlProof(s.authToken, hostID, controlProofTTL)
	if scope != "" {
		proof = controlproof.MintForScope(s.authToken, hostID, scope, controlProofTTL)
	}
	if proof != "" {
		dest += "#yctl=" + proof
	}
	http.Redirect(w, r, dest, http.StatusFound)
}

// HandleGoStash bridges a dashboard Extension-cell click -> an extension's
// service UI, 302ing to the address the pool resolves for that host's area
// (default "stash-service"); host or target unknown -> 404. Like /go/host it
// carries a short-lived control proof in the fragment, bound to the service's
// audience.
// See https://yuruna.link/42c29d04-001c.
func (s *Server) HandleGoStash(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.missing_host", http.StatusBadRequest)
		return
	}
	area := strings.TrimSpace(q.Get("area"))
	if area == "" {
		area = StashArea
	}
	// One merged view for both sources: a live announce (first-hand -- the
	// service reached us from that address) outranks the owning host's
	// registration, which lags a cycle behind its own service; the registration
	// answers whenever nothing is announcing, including when the service's
	// status service is down and the announce is all there is.
	var target string
	s.st.Do(func(view *poolstate.View) {
		target = extensions.TargetFor(view, s.announceTtl, hostID, area, time.Now())
	})
	if target == "" {
		localizedHTTPError(w, r, "aggregator.stash_target_not_known_to_the_pool", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	// Carry a short-lived control proof in the URL FRAGMENT, the same handoff /go/host
	// makes to a host's status page: a fragment never reaches a server and never lands
	// in an access log, and the service UI reads it off location.hash. It is what lets
	// an operator who arrived through the (to-be-authenticated) dashboard act on the
	// service's gated routes without retyping the rotating lab code -- the service
	// revalidates it, here if it holds no token of its own. No token configured -> no
	// fragment -> the UI prompts for the lab token exactly as before.
	dest := strings.TrimRight(target, "/")
	if proof := MintControlProof(s.authToken, "svc-"+area, controlProofTTL); proof != "" {
		dest += "#yctl=" + proof
	}
	http.Redirect(w, r, dest, http.StatusFound)
}

// resolveClickedCycle answers "which host, and which cycle folder, is under that
// point on the timeline?" for every cycle deep link. The host's current address
// comes from ResolveHostBase, so a link survives an IP change; the folder is the
// current cycle when t falls in it, else cycleFolderAt's answer. Returns ok=false
// having written the response (no host id 400, unknown host 404); a resolved host
// with no folder is ok=true with folder "".
// See https://yuruna.link/42c29d04-0008.
func (s *Server) resolveClickedCycle(w http.ResponseWriter, r *http.Request) (base, folder string, ok bool) {
	q := r.URL.Query()
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.missing_host", http.StatusBadRequest)
		return "", "", false
	}
	var clickT time.Time
	if ms, err := strconv.ParseInt(strings.TrimSpace(q.Get("t")), 10, 64); err == nil && ms > 0 {
		clickT = time.Unix(0, ms*int64(time.Millisecond)).UTC()
	}
	pool := strings.TrimSpace(q.Get("pool"))

	var curFolder string
	var curStart time.Time
	s.st.Do(func(view *poolstate.View) {
		if hv := view.Hosts[hostID]; hv != nil && hv.Status != nil {
			curFolder = hv.Status.CycleFolderUrl
			if tt, perr := time.Parse(time.RFC3339, hv.Status.StartedAt); perr == nil {
				curStart = tt
			}
		}
	})

	// Resolve the host's current base URL (live IP, else the last IP Loki recorded);
	// also normalizes an empty pool so the per-cycle folder lookups below can scope.
	base, pool = s.ResolveHostBase(hostID, pool)
	if base == "" {
		localizedHTTPError(w, r, "aggregator.host_not_known_to_the_pool", http.StatusNotFound)
		return "", "", false
	}

	switch {
	case curFolder != "" && (clickT.IsZero() || (!curStart.IsZero() && !clickT.Before(curStart))):
		folder = curFolder // current cycle (in-memory, no fetch)
	case !clickT.IsZero():
		folder = s.cycleFolderAt(hostID, pool, base, clickT)
	}
	return base, folder, true
}

// cycleFolderAt resolves the cycle folder active at time t: the backfill's cycle
// index, then the archive, then the host's /log/ listing, then Loki's recorded
// folder; "" when none answers. See https://yuruna.link/42c29d04-0008.
func (s *Server) cycleFolderAt(hostID, pool, base string, t time.Time) string {
	if folder := s.resolveFolderByIndex(hostID, t); folder != "" {
		return folder
	}
	if folder := s.ResolveFolderByArchive(hostID, t); folder != "" {
		return folder
	}
	if folder := s.ResolveFolderByListing(base, hostID, t); folder != "" {
		return folder
	}
	if folder, _, found := s.lookupCycleAt(pool, hostID, t); found {
		return folder
	}
	return ""
}

// cycleBeganBetween reports whether the cycle active at click began after the
// given time. A cycle opens only once its attempt has passed the configuration
// gate, so such a cycle shows that a later attempt passed.
func (s *Server) cycleBeganBetween(hostID, pool, base string, after, click time.Time) bool {
	start, ok := CycleStartFromFolder(path.Base(strings.Trim(s.cycleFolderAt(hostID, pool, base, click), "/")))
	return ok && start.After(after) && !start.After(click)
}

// HostIDRe and ArchiveCycleRe validate an /archive/ request before any
// filesystem call: the shape check is the authorization, as it is for the host's
// own /archive/<cycle>.zip route. A cycle leaf must be the stable stripped
// identity, so an .incomplete or .aborted suffix names nothing here.
// See https://yuruna.link/42c29d04-001e.
var (
	HostIDRe       = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)
	ArchiveCycleRe = regexp.MustCompile(`^\d{6}\.\d{4}-\d{2}-\d{2}\.\d{2}-\d{2}-\d{2}\.[0-9a-fA-F]{32}$`)
)

// ArchiveCommitted reports whether an archived cycle folder carries the
// .yuruna-complete sentinel. A destination exists sentinel-less for the whole
// duration of its copy (up to ten minutes for a large cycle) and after a failed
// verification until its cleanup lands, and a reader cannot tell a half-copied tree
// from a finished one by looking at it. Every resolution path checks this, so a
// dashboard click can never land inside a copy that is still running.
func (s *Server) ArchiveCommitted(hostID, cycle string) bool {
	if s.archiveRoot == "" || !HostIDRe.MatchString(hostID) || !ArchiveCycleRe.MatchString(cycle) {
		return false
	}
	root, err := os.OpenRoot(s.archiveRoot)
	if err != nil {
		return false
	}
	defer root.Close()
	st, err := root.Stat(path.Join(hostID, "test-cycles", cycle, ".yuruna-complete"))
	return err == nil && !st.IsDir()
}

// ResolveFolderByArchive returns the archived cycle folder covering time t for a
// host, as "<cycle>/" -- or "" when the archive cannot answer. The folder name
// carries the cycle's UTC start, so the same "latest start at or before t" rule the
// host-listing resolver uses applies unchanged; this one reads local disk on the
// proxy instead of fetching over HTTP from a host that may be switched off, which
// is the entire point of a durable tier.
func (s *Server) ResolveFolderByArchive(hostID string, t time.Time) string {
	if s.archiveRoot == "" || !HostIDRe.MatchString(hostID) || t.IsZero() {
		return ""
	}
	root, err := os.OpenRoot(s.archiveRoot)
	if err != nil {
		return ""
	}
	defer root.Close()
	dir, err := root.Open(path.Join(hostID, "test-cycles"))
	if err != nil {
		return ""
	}
	defer dir.Close()
	names, err := dir.Readdirnames(-1)
	if err != nil {
		return ""
	}
	best := ""
	var bestStart time.Time
	for _, name := range names {
		if !ArchiveCycleRe.MatchString(name) {
			continue
		}
		start, ok := CycleStartFromFolder(name)
		if !ok || start.After(t) {
			continue
		}
		if best == "" || start.After(bestStart) {
			best, bestStart = name, start
		}
	}
	if best == "" || !s.ArchiveCommitted(hostID, best) {
		return ""
	}
	return best + "/"
}

// HandleArchive serves archived cycle results straight off the pool share:
// GET /archive/<hostId>/test-cycles/<cycle>/... . Read-only, GET/HEAD only, and
// contained by os.Root, so no "..", symlink or case trick escapes the archive
// root. The root is opened per request, because the share is mounted after the
// service starts.
// See https://yuruna.link/42c29d04-001e.
func (s *Server) HandleArchive(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		localizedHTTPError(w, r, "aggregator.method_not_allowed", http.StatusMethodNotAllowed)
		return
	}
	rel := strings.TrimPrefix(r.URL.Path, "/archive/")
	segs := strings.Split(strings.Trim(rel, "/"), "/")
	if len(segs) < 2 || !HostIDRe.MatchString(segs[0]) || segs[1] != "test-cycles" {
		http.NotFound(w, r)
		return
	}
	if len(segs) >= 3 && segs[2] != "" && !ArchiveCycleRe.MatchString(segs[2]) {
		http.NotFound(w, r)
		return
	}
	root, err := os.OpenRoot(s.archiveRoot)
	if err != nil {
		// The mount is away (or was never there). Say so plainly rather than
		// serving a 500 that reads like a bug in the service.
		localizedHTTPError(w, r, "aggregator.the_pool_share_is_not_mounted_on_this_machine", http.StatusNotFound)
		return
	}
	defer root.Close()
	w.Header().Set("Cache-Control", "no-store")
	// FileServerFS, not ServeContent: this route has to answer folder URLs with a
	// listing (that is what a dashboard click lands on) as well as files with Range
	// support for large screenshots and transcripts. ServeContent does the second
	// and none of the first.
	http.StripPrefix("/archive/", http.FileServerFS(root.FS())).ServeHTTP(w, r)
}

// HandleGoCycle bridges a dashboard timeline click -> that cycle's results.
// Archive-first: once a cycle is committed on the share, the redirect goes to this
// service's own /archive/ copy, which answers from local disk and keeps working when
// the host is switched off or reimaged -- the durable tier's whole promise. Only a
// cycle that is not (yet) archived sends the operator to the host. Degrades
// gracefully: missing/zero time -> current cycle; folder unresolved -> the host's
// status root (still the right host at its current IP); host unknown -> 404.
func (s *Server) HandleGoCycle(w http.ResponseWriter, r *http.Request) {
	base, folder, ok := s.resolveClickedCycle(w, r)
	if !ok {
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	hostID := normalizeHostID(strings.TrimSpace(r.URL.Query().Get("host")))
	http.Redirect(w, r, s.cycleResultsTarget(hostID, base, folder), http.StatusFound)
}

// A runner attempt can fail before creating a cycle. Resolve those host-state
// intervals separately so opening a yellow block cannot show the previous pass.
// Completed attempts remain available after recovery, until host retention removes
// them. The dashboard sends the observed state to distinguish expired preflight
// evidence from a cycle result without changing the existing cycle-link contract.
func (s *Server) HandleGoHostEvent(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	status := q.Get("status")
	if status != "" && status != "3" && status != "9" {
		s.HandleGoCycle(w, r)
		return
	}
	hostID := normalizeHostID(strings.TrimSpace(q.Get("host")))
	if hostID == "" {
		localizedHTTPError(w, r, "aggregator.missing_host", http.StatusBadRequest)
		return
	}
	base, pool := s.ResolveHostBase(hostID, strings.TrimSpace(q.Get("pool")))
	if base == "" {
		localizedHTTPError(w, r, "aggregator.host_not_known_to_the_pool", http.StatusNotFound)
		return
	}
	var target string
	if ms, err := strconv.ParseInt(strings.TrimSpace(q.Get("t")), 10, 64); err == nil && ms > 0 {
		target = s.runnerAttemptTarget(hostID, pool, base, time.UnixMilli(ms), status == "9")
	}
	if target == "" && status == "9" {
		target = strings.TrimRight(base, "/") + "/#runner-attempts"
	}
	if target == "" {
		s.HandleGoCycle(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, target, http.StatusFound)
}

// The index includes successful attempts so a failure's interval ends when the
// next preflight completes, rather than following the host into a recovered cycle.
// Diagnostic text is deliberately not parsed or exported by the pool service.
// olderFailures keeps failures past the window without the passes between them,
// so one answers only a click the window cannot place, and only while no cycle
// has begun since it ended.
func (s *Server) runnerAttemptTarget(hostID, pool, base string, click time.Time, preflightOnly bool) string {
	if s.httpClient == nil {
		return ""
	}
	type attempt struct {
		Generation   string `json:"attemptGeneration"`
		StartedAt    string `json:"startedAtUtc"`
		FinishedAt   string `json:"finishedAtUtc"`
		Passed       bool   `json:"passed"`
		Skipped      bool   `json:"skipped"`
		FailureClass string `json:"failureClass"`
		RecordPath   string `json:"recordPath"`
	}
	var index struct {
		SchemaVersion int             `json:"schemaVersion"`
		Attempts      []attempt       `json:"attempts"`
		OlderFailures json.RawMessage `json:"olderFailures"`
	}
	body := s.fetchListing(strings.TrimRight(base, "/") + "/runtime/runner-attempts/index.json")
	if json.Unmarshal([]byte(body), &index) != nil || index.SchemaVersion != 1 || len(index.Attempts) > 20 {
		return ""
	}
	// olderFailures decodes on its own, so a malformed value reads as no older
	// failures instead of failing the whole index, which would also cost the
	// window its links; the host page likewise ignores a value it cannot list.
	var olderFailures []attempt
	if json.Unmarshal(index.OlderFailures, &olderFailures) != nil {
		olderFailures = nil
	}
	latestBy := func(rows []attempt) (*attempt, time.Time) {
		var latest *attempt
		var latestTime time.Time
		for i := range rows {
			row := &rows[i]
			finished, err := time.Parse(time.RFC3339Nano, row.FinishedAt)
			started, startErr := time.Parse(time.RFC3339Nano, row.StartedAt)
			if err != nil || startErr != nil || finished.Before(started) || finished.After(click) {
				continue
			}
			if latest == nil || finished.After(latestTime) {
				latest, latestTime = row, finished
			}
		}
		return latest, latestTime
	}
	latest, latestTime := latestBy(index.Attempts)
	older := latest == nil
	if older {
		// The host page lists at most 30 older failures; no more are read here.
		latest, latestTime = latestBy(olderFailures[:min(len(olderFailures), 30)])
	}
	if latest == nil || latest.Passed || latest.Skipped || latest.FailureClass == "" ||
		(preflightOnly && latest.FailureClass != "config_gate_failed") || latest.Generation == "" {
		return ""
	}
	// The directory identity is the same SHA256 prefix the runner uses; its
	// original generation may include a process ID or other non-path characters.
	digest := sha256.Sum256([]byte(latest.Generation))
	directory := fmt.Sprintf("runner-attempts/%x/", digest[:12])
	if latest.RecordPath != directory+"config-gate.json" && latest.RecordPath != directory+"runner-fault.json" {
		return ""
	}
	if older && s.cycleBeganBetween(hostID, pool, base, latestTime, click) {
		return ""
	}
	return strings.TrimRight(base, "/") + "/runtime/" + latest.RecordPath
}

// cycleResultsTarget is where a timeline click on this host at this cycle lands.
// Factored out because the JSON route hands the same URL to a caller that cannot
// see the timeline at all; sharing the body is what stops the link a tool
// returns and the link a click follows from ever being different places.
//
// A leading "/" is deliberate and means the archive on this service.
func (s *Server) cycleResultsTarget(hostID, base, folder string) string {
	if leaf := strings.Trim(folder, "/"); leaf != "" {
		leaf = path.Base(leaf)
		if s.ArchiveCommitted(hostID, leaf) {
			return "/archive/" + hostID + "/test-cycles/" + leaf + "/"
		}
	}
	target := strings.TrimRight(base, "/")
	if folder != "" {
		target += "/" + strings.TrimLeft(folder, "/")
	}
	return target
}

// cycleShareTarget is the host's share page for one cycle, or "" when the folder
// cannot name one -- the caller decides whether that is a 404 or an omitted field.
func cycleShareTarget(base, folder string) string {
	leaf := path.Base(strings.Trim(folder, "/"))
	if leaf == "" || leaf == "." || leaf == "/" {
		return ""
	}
	return strings.TrimRight(base, "/") + "/share-cycle.html?cycle=" + url.QueryEscape(leaf)
}

// HandleGoCycleShare bridges a dashboard timeline click -> the host's own share
// page for that cycle, through the same resolver as /go/cycle, so "share this"
// cannot archive a different cycle than "open this" would show. An unresolved
// folder is a 404 here, not the status root.
// See https://yuruna.link/42c29d04-0008.
func (s *Server) HandleGoCycleShare(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("status") == "9" {
		s.HandleGoHostEvent(w, r)
		return
	}
	base, folder, ok := s.resolveClickedCycle(w, r)
	if !ok {
		return
	}
	if folder == "" {
		localizedHTTPError(w, r, "aggregator.no_cycle_results_folder_for_that_host_at_that_time", http.StatusNotFound)
		return
	}
	// The share page and the host's archive route both name a results folder by
	// its LEAF -- the folder sits directly under the host's log dir, and the leaf
	// is what carries the cycle number, the UTC start and the host id that the
	// archive is named from. Every producer here spells it "log/<leaf>/"
	// (Set-CycleFolderUrl, the listing parser, and the Loki copy of the same
	// value), so hand on the last segment rather than the path.
	target := cycleShareTarget(base, folder)
	if target == "" {
		localizedHTTPError(w, r, "aggregator.unusable_cycle_results_folder_for_that_host_at_that_time", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, target, http.StatusFound)
}

// ResolveFolderByListing fetches the host's /log/ index and returns the results
// folder ("log/<n>.<date>.<time>.<hostId>/") of the cycle that was active at time
// t. Works for any cycle still on disk regardless of what Loki recorded -- the
// folder name itself encodes the start time. Best-effort: unreachable / non-200 /
// unparseable -> "".
func (s *Server) ResolveFolderByListing(baseURL, hostID string, t time.Time) string {
	if s.httpClient == nil {
		return ""
	}
	body := s.fetchListing(strings.TrimRight(baseURL, "/") + "/log/")
	if body == "" {
		return ""
	}
	// An exact hit in the live index is the common case and costs one request.
	if best, _ := ScanListingForHost(body, hostID, t); best != "" {
		return "log/" + strings.TrimSuffix(best, "/") + "/"
	}
	// A cycle past the retention window moves into a history.<YYYY-MM-DD>/ bucket the
	// index links but does not inline. Read newest first, the first bucket holding a
	// cycle that started at or before t holds the cycle active at t.
	// See https://yuruna.link/42c29d04-0008.
	for _, bucket := range HistoryBucketsNewestFirst(s.parseListing, body, maxHistoryBucketsScanned) {
		hb := s.fetchListing(strings.TrimRight(baseURL, "/") + "/log/" + bucket + "/")
		if hb == "" {
			continue
		}
		if best, _ := ScanListingForHost(hb, hostID, t); best != "" {
			return "log/" + bucket + "/" + strings.TrimSuffix(best, "/") + "/"
		}
	}
	return PickFolderFromListing(body, hostID, t)
}

// maxHistoryBucketsScanned bounds the bucket reads one click can cost. Rotation
// moves about ninety cycles at a time, so this reaches weeks back; older clicks
// are answered from the history backfill's cycle index, which has every bucket
// already read.
const maxHistoryBucketsScanned = 16

// HistoryBucketsNewestFirst returns the history buckets a /log/ index links,
// newest first, at most limit of them.
func HistoryBucketsNewestFirst(parseListing func(body string) (leaves, buckets []string), body string, limit int) []string {
	_, buckets := parseListing(body)
	sort.Sort(sort.Reverse(sort.StringSlice(buckets)))
	if len(buckets) > limit {
		buckets = buckets[:limit]
	}
	return buckets
}

// fetchListing GETs one directory index and returns its body, "" on any failure.
func (s *Server) fetchListing(u string) string {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return ""
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return ""
	}
	return string(body)
}

// ScanListingForHost finds this host's cycle folders in one directory index and
// returns two answers: the leaf whose encoded start is the latest at/before t (the
// cycle active at that moment, "" when the listing holds none that old) and the
// earliest leaf present. Separating them lets a caller tell a real hit from the
// oldest-retained consolation prize, which reads identically once returned.
func ScanListingForHost(body, hostID string, t time.Time) (best, earliest string) {
	re := regexp.MustCompile(`\d{6}\.(\d{4}-\d{2}-\d{2})\.(\d{2}-\d{2}-\d{2})\.` + regexp.QuoteMeta(hostID) + `(?:\.incomplete)?/`)
	var bestStart, earliestStart time.Time
	for _, m := range re.FindAllStringSubmatch(body, -1) {
		st, perr := time.Parse("2006-01-02 15-04-05", m[1]+" "+m[2])
		if perr != nil {
			continue
		}
		st = st.UTC()
		if earliest == "" || st.Before(earliestStart) {
			earliest, earliestStart = m[0], st
		}
		if st.After(t) {
			continue
		}
		if best == "" || st.After(bestStart) {
			best, bestStart = m[0], st
		}
	}
	return best, earliest
}

// CycleStartFromFolder parses the UTC start encoded in a cycle folder leaf
// ("NNNNNN.YYYY-MM-DD.HH-MM-SS.<hostId>"). One parser for both resolvers, so the
// archive and the host listing can never disagree about which cycle covers a click.
func CycleStartFromFolder(name string) (time.Time, bool) {
	m := cycleStartRe.FindStringSubmatch(name)
	if m == nil {
		return time.Time{}, false
	}
	st, err := time.Parse("2006-01-02 15-04-05", m[1]+" "+m[2])
	if err != nil {
		return time.Time{}, false
	}
	return st.UTC(), true
}

var cycleStartRe = regexp.MustCompile(`^\d{6}\.(\d{4}-\d{2}-\d{2})\.(\d{2}-\d{2}-\d{2})\.`)

// PickFolderFromListing scans a /log/ index page for this host's cycle folders
// (`<6-digit cycle number>.<YYYY-MM-DD>.<HH-mm-ss>.<hostId>[.incomplete]/`, the
// Format-CycleFolderBaseName shape) and returns the one whose encoded start is the
// latest at or before t, else the earliest; "" when nothing matches. Pure: no I/O.
// See https://yuruna.link/42c29d04-0008.
func PickFolderFromListing(body, hostID string, t time.Time) string {
	best, earliest := ScanListingForHost(body, hostID, t)
	if best == "" {
		best = earliest
	}
	if best == "" {
		return ""
	}
	return "log/" + strings.TrimSuffix(best, "/") + "/"
}

// HandleCycleLinks answers the three navigating destinations the state-timeline
// panel offers on a click, for a caller that cannot click, through
// resolveClickedCycle so a link handed out here goes where a click would. Its
// hostStatusUrl carries no control proof, unlike /go/host: a credential does not
// belong on a JSON read surface.
// See https://yuruna.link/42c29d04-0020.
func (s *Server) HandleCycleLinks(w http.ResponseWriter, r *http.Request) {
	base, folder, ok := s.resolveClickedCycle(w, r)
	if !ok {
		return
	}
	hostID := normalizeHostID(strings.TrimSpace(r.URL.Query().Get("host")))

	// resolveClickedCycle answers the folder; the cycle's own start time comes
	// from the in-memory view when the caller asked for the current cycle.
	cycleStart := ""
	s.st.Do(func(view *poolstate.View) {
		if hv := view.Hosts[hostID]; hv != nil && hv.Status != nil {
			if path.Base(strings.Trim(hv.Status.CycleFolderUrl, "/")) == path.Base(strings.Trim(folder, "/")) {
				cycleStart = hv.Status.StartedAt
			}
		}
	})

	results := s.cycleResultsTarget(hostID, base, folder)
	// The archive target is a path on this service. A caller that cannot see the
	// address bar has nothing to resolve it against, so make it whole here.
	if strings.HasPrefix(results, "/") {
		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}
		results = scheme + "://" + r.Host + results
	}

	payload := map[string]any{
		"ok":            true,
		"hostId":        hostID,
		"resultsUrl":    results,
		"hostStatusUrl": strings.TrimRight(base, "/"),
	}
	if cycleStart != "" {
		payload["cycleStartUtc"] = cycleStart
	}
	if share := cycleShareTarget(base, folder); share != "" {
		payload["shareUrl"] = share
	}
	httpserve.WriteJSON(w, payload)
}
