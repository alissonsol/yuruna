// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// --- REGION: Loki query fixture
type fakeLokiEntry struct {
	ns     int64
	line   string
	hidden bool // pushed with an old timestamp and not yet filed away
}

type fakeLokiStream struct {
	labels  map[string]string
	entries []fakeLokiEntry // ascending
}

type fakeLoki struct {
	mu      sync.Mutex
	streams map[string]*fakeLokiStream
	pushes  int
	queries []string
	// cyclePushes records every accepted src=cycle push as "hostId|cycleStartUtc",
	// in arrival order: the order the dashboard's history grows in.
	cyclePushes []string
	now         func() time.Time
	// lag makes the fake behave as Loki does with a line stamped long before it
	// arrives: accepted at once, answered for only once it has been filed away,
	// which reveal stands in for.
	lag bool
}

// reveal makes every line pushed so far visible to queries.
func (f *fakeLoki) reveal() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, st := range f.streams {
		for i := range st.entries {
			st.entries[i].hidden = false
		}
	}
}

func newFakeLoki(now func() time.Time) *fakeLoki {
	return &fakeLoki{streams: map[string]*fakeLokiStream{}, now: now}
}

func labelKey(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "%s=%q,", k, m[k])
	}
	return b.String()
}

// check applies the two ingestion rules a backfill can trip: the age limit, and
// the hour an entry may trail the newest entry of an existing stream.
func (f *fakeLoki) check(labels map[string]string, ns int64) error {
	if ns < f.now().Add(-2208*time.Hour).UnixNano() {
		return fmt.Errorf("entry for stream %s has timestamp too old", labelKey(labels))
	}
	if st := f.streams[labelKey(labels)]; st != nil && len(st.entries) > 0 && ns < st.entries[len(st.entries)-1].ns-int64(time.Hour) {
		return fmt.Errorf("entry too far behind for stream %s", labelKey(labels))
	}
	return nil
}

func (f *fakeLoki) insert(labels map[string]string, ns int64, line string, hidden bool) {
	key := labelKey(labels)
	st := f.streams[key]
	if st == nil {
		cp := map[string]string{}
		for k, v := range labels {
			cp[k] = v
		}
		st = &fakeLokiStream{labels: cp}
		f.streams[key] = st
	}
	for _, e := range st.entries {
		if e.ns == ns && e.line == line {
			return // Loki drops an exact duplicate
		}
	}
	st.entries = append(st.entries, fakeLokiEntry{ns: ns, line: line, hidden: hidden})
	sort.SliceStable(st.entries, func(i, j int) bool { return st.entries[i].ns < st.entries[j].ns })
}

func (f *fakeLoki) seed(payload map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, st := range payload["streams"].([]map[string]any) {
		labels := st["stream"].(map[string]string)
		for _, v := range st["values"].([][]string) {
			ns, _ := strconv.ParseInt(v[0], 10, 64)
			f.insert(labels, ns, v[1], false)
		}
	}
}

var (
	fakeSumByRE   = regexp.MustCompile(`^sum by \((\w+)\) \(count_over_time\((.*) \[(\d+)s\]\)\)$`)
	fakeMatcherRE = regexp.MustCompile(`(\w+)\s*(=~|=)\s*"([^"]*)"`)
	fakeExtractRE = regexp.MustCompile(`^\| json (\w+)="(\w+)"$`)
	fakeStatusRE  = regexp.MustCompile(`^\| json \| overallStatus(=~|=)"([^"]*)"$`)
)

type fakeLogQuery struct {
	matchers [][3]string
	status   *regexp.Regexp
	extract  [2]string
	json     bool
}

func parseFakeLogQuery(q string) (fakeLogQuery, error) {
	var out fakeLogQuery
	end := strings.Index(q, "}")
	if !strings.HasPrefix(q, "{") || end < 0 {
		return out, fmt.Errorf("no selector in %q", q)
	}
	for _, m := range fakeMatcherRE.FindAllStringSubmatch(q[:end+1], -1) {
		out.matchers = append(out.matchers, [3]string{m[1], m[2], m[3]})
	}
	rest := strings.TrimSpace(q[end+1:])
	switch {
	case rest == "":
	case fakeStatusRE.MatchString(rest):
		m := fakeStatusRE.FindStringSubmatch(rest)
		out.json = true
		if m[1] == "=" {
			out.status = regexp.MustCompile("^" + regexp.QuoteMeta(m[2]) + "$")
		} else {
			out.status = regexp.MustCompile("^(?:" + m[2] + ")$")
		}
	case fakeExtractRE.MatchString(rest):
		m := fakeExtractRE.FindStringSubmatch(rest)
		out.extract = [2]string{m[1], m[2]}
	default:
		return out, fmt.Errorf("unsupported pipeline %q", rest)
	}
	return out, nil
}

func (q fakeLogQuery) matches(labels map[string]string) bool {
	for _, m := range q.matchers {
		v := labels[m[0]]
		if m[1] == "=" && v != m[2] {
			return false
		}
		if m[1] == "=~" && !regexp.MustCompile("^(?:"+m[2]+")$").MatchString(v) {
			return false
		}
	}
	return true
}

func (q fakeLogQuery) keep(line string) bool {
	if q.status == nil {
		return true
	}
	var m map[string]any
	if json.Unmarshal([]byte(line), &m) != nil {
		return false
	}
	s, _ := m["overallStatus"].(string)
	return q.status.MatchString(s)
}

// value is what `sum by (name)` groups an entry under: the stream label when the
// stream has one -- Loki renames a clashing extracted label -- else the field.
func (q fakeLogQuery) value(labels map[string]string, line, name string) string {
	if v, ok := labels[name]; ok {
		return v
	}
	field := name
	if q.extract[0] != "" {
		if q.extract[0] != name {
			return ""
		}
		field = q.extract[1]
	} else if !q.json {
		return ""
	}
	var m map[string]any
	if json.Unmarshal([]byte(line), &m) != nil {
		return ""
	}
	s, _ := m[field].(string)
	return s
}

func (f *fakeLoki) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if q := r.URL.Query().Get("query"); q != "" {
		f.mu.Lock()
		f.queries = append(f.queries, q)
		f.mu.Unlock()
	}
	switch r.URL.Path {
	case "/loki/api/v1/push":
		f.handlePush(w, r)
	case "/loki/api/v1/query":
		f.handleInstant(w, r)
	case "/loki/api/v1/query_range":
		f.handleRange(w, r)
	default:
		http.NotFound(w, r)
	}
}

func (f *fakeLoki) handlePush(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Streams []struct {
			Stream map[string]string `json:"stream"`
			Values [][2]string       `json:"values"`
		} `json:"streams"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, st := range body.Streams {
		for _, v := range st.Values {
			ns, err := strconv.ParseInt(v[0], 10, 64)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			if err := f.check(st.Stream, ns); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
		}
	}
	old := f.now().Add(-3 * time.Hour).UnixNano()
	for _, st := range body.Streams {
		for _, v := range st.Values {
			ns, _ := strconv.ParseInt(v[0], 10, 64)
			f.insert(st.Stream, ns, v[1], f.lag && ns < old)
		}
		if st.Stream["src"] == "cycle" {
			f.cyclePushes = append(f.cyclePushes, st.Stream["hostId"]+"|"+st.Stream["cycleStartUtc"])
		}
	}
	f.pushes++
	w.WriteHeader(http.StatusNoContent)
}

func (f *fakeLoki) handleInstant(w http.ResponseWriter, r *http.Request) {
	m := fakeSumByRE.FindStringSubmatch(r.URL.Query().Get("query"))
	if m == nil {
		http.Error(w, "unsupported query", http.StatusBadRequest)
		return
	}
	q, err := parseFakeLogQuery(m[2])
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	secs, _ := strconv.ParseInt(m[3], 10, 64)
	at, _ := strconv.ParseInt(r.URL.Query().Get("time"), 10, 64)
	lo := at - secs*int64(time.Second)
	f.mu.Lock()
	counts := map[string]int{}
	for _, st := range f.streams {
		if !q.matches(st.labels) {
			continue
		}
		for _, e := range st.entries {
			if !e.hidden && e.ns > lo && e.ns <= at && q.keep(e.line) {
				counts[q.value(st.labels, e.line, m[1])]++
			}
		}
	}
	f.mu.Unlock()
	var result []map[string]any
	for v, n := range counts {
		metric := map[string]string{}
		if v != "" {
			metric[m[1]] = v
		}
		result = append(result, map[string]any{"metric": metric, "value": []any{float64(at) / 1e9, strconv.Itoa(n)}})
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"status": "success", "data": map[string]any{"resultType": "vector", "result": result}})
}

func (f *fakeLoki) handleRange(w http.ResponseWriter, r *http.Request) {
	q, err := parseFakeLogQuery(r.URL.Query().Get("query"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	start, _ := strconv.ParseInt(r.URL.Query().Get("start"), 10, 64)
	end, _ := strconv.ParseInt(r.URL.Query().Get("end"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if r.URL.Query().Get("direction") != "forward" {
		http.Error(w, "the backfill reads forward", http.StatusBadRequest)
		return
	}
	type hit struct {
		labels map[string]string
		e      fakeLokiEntry
	}
	var hits []hit
	f.mu.Lock()
	for _, st := range f.streams {
		if !q.matches(st.labels) {
			continue
		}
		for _, e := range st.entries {
			if !e.hidden && e.ns >= start && e.ns < end && q.keep(e.line) {
				hits = append(hits, hit{st.labels, e})
			}
		}
	}
	f.mu.Unlock()
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].e.ns < hits[j].e.ns })
	if limit > 0 && len(hits) > limit {
		hits = hits[:limit]
	}
	byStream := map[string]map[string]any{}
	var order []string
	for _, h := range hits {
		k := labelKey(h.labels)
		if byStream[k] == nil {
			byStream[k] = map[string]any{"stream": h.labels, "values": [][2]string{}}
			order = append(order, k)
		}
		byStream[k]["values"] = append(byStream[k]["values"].([][2]string), [2]string{strconv.FormatInt(h.e.ns, 10), h.e.line})
	}
	var result []map[string]any
	for _, k := range order {
		result = append(result, byStream[k])
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"status": "success", "data": map[string]any{"resultType": "streams", "result": result}})
}

// lines returns every entry of the streams whose labels include want, hidden
// ones included: what Loki holds, not what it answers for yet.
func (f *fakeLoki) lines(want map[string]string) []fakeLokiEntry {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []fakeLokiEntry
	for _, st := range f.streams {
		ok := true
		for k, v := range want {
			if st.labels[k] != v {
				ok = false
			}
		}
		if ok {
			out = append(out, st.entries...)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ns < out[j].ns })
	return out
}

func (f *fakeLoki) pushCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.pushes
}

// queriesAbout counts the queries from the index-th on that name the host.
func (f *fakeLoki) queriesAbout(hostID string, from int) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, q := range f.queries[from:] {
		if strings.Contains(q, hostID) {
			n++
		}
	}
	return n
}

func (f *fakeLoki) queryCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.queries)
}

func (f *fakeLoki) cyclePushLog() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.cyclePushes...)
}

// dedupeCycleOrder reads one host's cycles out of a push log in first-write
// order. A cycle's running and final lines land in the same stream, so its
// first push is its position.
func dedupeCycleOrder(log []string, hostID string) []string {
	seen := map[string]bool{}
	var out []string
	prefix := hostID + "|"
	for _, entry := range log {
		key, ok := strings.CutPrefix(entry, prefix)
		if !ok || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, key)
	}
	return out
}

// assertNewestFirst fails unless the cycles were written strictly newest
// first -- the order that refills the dashboard backwards from the rebuild
// moment: the cycles just before it, then yesterday's, then older -- and
// returns the oldest start among them.
func assertNewestFirst(t *testing.T, hostID string, order []string) time.Time {
	t.Helper()
	if len(order) == 0 {
		t.Fatalf("host %s: no backfilled cycles to check the order of", hostID)
	}
	var prev time.Time
	for i, key := range order {
		at, ok := parseUTC(key)
		if !ok {
			t.Fatalf("host %s: unreadable cycle key %q in the push order", hostID, key)
		}
		if i > 0 && !at.Before(prev) {
			t.Fatalf("host %s: cycle %s was written after the older %s; the backfill must write newest first", hostID, key, formatUTC(prev))
		}
		prev = at
	}
	return prev
}

// --- REGION: Prometheus remote-write fixture
type fakeProm struct {
	mu         sync.Mutex
	samples    map[string]map[int64]float64 // label key -> ms -> value
	labels     map[string]map[string]string
	backfilled map[string]map[int64]bool
	writes     int
	now        func() time.Time
	t          *testing.T
}

func newFakeProm(t *testing.T, now func() time.Time) *fakeProm {
	return &fakeProm{samples: map[string]map[int64]float64{}, labels: map[string]map[string]string{}, backfilled: map[string]map[int64]bool{}, now: now, t: t}
}

func (p *fakeProm) add(labels map[string]string, ms int64, v float64, backfilled bool) error {
	k := labelKey(labels)
	if p.samples[k] == nil {
		p.samples[k] = map[int64]float64{}
		p.labels[k] = labels
		p.backfilled[k] = map[int64]bool{}
	}
	if old, ok := p.samples[k][ms]; ok && old != v {
		return fmt.Errorf("duplicate sample for timestamp %d", ms)
	}
	if ms < p.now().Add(-2208*time.Hour).UnixMilli() {
		return fmt.Errorf("out of bounds")
	}
	p.samples[k][ms] = v
	if backfilled {
		p.backfilled[k][ms] = true
	}
	return nil
}

var fakeCoverageRE = regexp.MustCompile(`^sum\(count_over_time\(yuruna_pool_host_status\{hostId="([0-9a-f]{32})"\}\[(\d+)s\]\)\)$`)

func (p *fakeProm) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/api/v1/write":
		if r.Header.Get("Content-Encoding") != "snappy" || r.Header.Get("Content-Type") != "application/x-protobuf" || r.Header.Get("X-Prometheus-Remote-Write-Version") != "0.1.0" {
			http.Error(w, "bad headers", http.StatusBadRequest)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		body, err := snappyDecodeBlock(raw)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		series, err := decodeWriteRequest(body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		p.mu.Lock()
		defer p.mu.Unlock()
		for _, s := range series {
			labels := map[string]string{}
			for _, l := range s.Labels {
				labels[l[0]] = l[1]
			}
			for _, sm := range s.Samples {
				if err := p.add(labels, sm.T, sm.V, true); err != nil {
					http.Error(w, err.Error(), http.StatusBadRequest)
					return
				}
			}
		}
		p.writes++
		w.WriteHeader(http.StatusNoContent)
	case "/api/v1/query_range":
		m := fakeCoverageRE.FindStringSubmatch(r.URL.Query().Get("query"))
		if m == nil {
			http.Error(w, "unsupported query", http.StatusBadRequest)
			return
		}
		win, _ := strconv.ParseInt(m[2], 10, 64)
		start, _ := strconv.ParseInt(r.URL.Query().Get("start"), 10, 64)
		end, _ := strconv.ParseInt(r.URL.Query().Get("end"), 10, 64)
		step, _ := strconv.ParseInt(r.URL.Query().Get("step"), 10, 64)
		if (end-start)/step > 11000 {
			http.Error(w, "exceeded maximum resolution of 11,000 points per timeseries", http.StatusBadRequest)
			return
		}
		p.mu.Lock()
		var all []int64
		for k, s := range p.samples {
			if p.labels[k]["hostId"] != m[1] || p.labels[k]["__name__"] != "yuruna_pool_host_status" {
				continue
			}
			for ms := range s {
				all = append(all, ms)
			}
		}
		p.mu.Unlock()
		sort.Slice(all, func(i, j int) bool { return all[i] < all[j] })
		var values [][]any
		for ts := start; ts <= end; ts += step {
			lo := sort.Search(len(all), func(i int) bool { return all[i] > (ts-win)*1000 })
			hi := sort.Search(len(all), func(i int) bool { return all[i] > ts*1000 })
			if n := hi - lo; n > 0 {
				values = append(values, []any{float64(ts), strconv.Itoa(n)})
			}
		}
		var result []map[string]any
		if len(values) > 0 {
			result = append(result, map[string]any{"metric": map[string]string{}, "values": values})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "success", "data": map[string]any{"resultType": "matrix", "result": result}})
	default:
		http.NotFound(w, r)
	}
}

func (p *fakeProm) writeCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.writes
}

// --- REGION: Host cycle fixtures
type fakeCycle struct {
	number    int
	start     time.Time
	end       time.Time
	outcome   string // "" = the process was killed: no cycle_end
	reason    string
	class     string
	parent    string // where the host lists it; "" = only the pool share has it
	hostless  bool   // the host lists it but cannot serve its event file
	shareCopy bool   // the pool share holds a committed copy
	current   bool
}

func (c fakeCycle) identity(host string) string {
	return fmt.Sprintf("%06d.%s.%s", c.number, c.start.Format("2006-01-02.15-04-05"), host)
}

func (c fakeCycle) leaf(host string) string {
	if c.current {
		return c.identity(host) + ".incomplete"
	}
	return c.identity(host)
}

func (c fakeCycle) status() string {
	if c.outcome == "" {
		return "fail"
	}
	return statusForOutcome(c.outcome, c.reason)
}

func (c fakeCycle) failClass() string {
	if c.status() != "fail" {
		return ""
	}
	if c.class == "" {
		return "unknown"
	}
	return c.class
}

func (c fakeCycle) events(host string) string {
	ts := func(t time.Time) string { return formatUTC(t) }
	lines := []string{
		fmt.Sprintf(`{"event":"cycle_start","timestamp":%q,"cycleStartUtc":%q,"cycleNumber":%d,"hostname":"secret-host","cycleFolder":%q,"hostId":%q}`, ts(c.start), ts(c.start), c.number, c.identity(host), host),
		`{"event":"step.start","name":"install"}`,
		fmt.Sprintf(`{"event":"step_end","timestamp":%q,"cycleStartUtc":%q,"step":"install"}`, ts(c.start.Add(time.Minute)), ts(c.start)),
	}
	if c.class != "" {
		lines = append(lines, fmt.Sprintf(`{"event":"step_failure","timestamp":%q,"cycleStartUtc":%q,"failureClass":%q,"severity":"error"}`, ts(c.start.Add(2*time.Minute)), ts(c.start), c.class))
	}
	if c.outcome != "" && !c.current {
		lines = append(lines, fmt.Sprintf(`{"event":"cycle_end","timestamp":%q,"cycleStartUtc":%q,"outcome":%q,"reason":%q}`, ts(c.end), ts(c.start), c.outcome, c.reason))
	}
	return strings.Join(lines, "\r\n") + "\r\n"
}

type fakeHost struct {
	id      string
	pool    string
	kind    string
	cycles  []fakeCycle // oldest first; the last is the current one
	mu      sync.Mutex
	hits    map[string]int
	srv     *httptest.Server
	watched time.Time // when the collector first saw the host
	// intercept, when set, sees every request first, and answers it itself by
	// returning true -- the way a test makes a listing slow or fail.
	intercept func(w http.ResponseWriter, r *http.Request) bool
}

func (h *fakeHost) current() fakeCycle { return h.cycles[len(h.cycles)-1] }

// setIntercept installs or removes the request hook between sweeps.
func (h *fakeHost) setIntercept(f func(w http.ResponseWriter, r *http.Request) bool) {
	h.mu.Lock()
	h.intercept = f
	h.mu.Unlock()
}

// hitsOf is how many times the host was asked for path.
func (h *fakeHost) hitsOf(path string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.hits[path]
}

func (h *fakeHost) requestCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for _, c := range h.hits {
		n += c
	}
	return n
}

func (h *fakeHost) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	h.hits[r.URL.Path]++
	intercept := h.intercept
	h.mu.Unlock()
	if intercept != nil && intercept(w, r) {
		return
	}
	dirs := map[string][]string{}
	for _, c := range h.cycles {
		if c.parent == "" {
			continue
		}
		dirs[c.parent] = append(dirs[c.parent], c.leaf(h.id))
		if strings.HasPrefix(c.parent, "log/history.") {
			bucket := strings.TrimSuffix(strings.TrimPrefix(c.parent, "log/"), "/")
			if !containsString(dirs["log/"], bucket) {
				dirs["log/"] = append(dirs["log/"], bucket)
			}
		}
		if r.URL.Path == "/"+c.parent+c.leaf(h.id)+"/"+eventsFile {
			if c.hostless {
				http.NotFound(w, r)
				return
			}
			fmt.Fprint(w, c.events(h.id))
			return
		}
	}
	if names, ok := dirs[strings.TrimPrefix(r.URL.Path, "/")]; ok {
		for _, n := range names {
			fmt.Fprintf(w, "<a href=\"%s/\">\u2068%s/\u2069</a>\n", n, n)
		}
		return
	}
	http.NotFound(w, r)
}

func containsInt(list []int, n int) bool {
	for _, x := range list {
		if x == n {
			return true
		}
	}
	return false
}

func containsString(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func (h *fakeHost) eventFileHits() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for p, c := range h.hits {
		if strings.HasSuffix(p, eventsFile) {
			n += c
		}
	}
	return n
}

func (h *fakeHost) statusOf(c fakeCycle, running bool) *hostStatus {
	st := &hostStatus{HostId: h.id, Host: h.kind, CycleStartUtc: formatUTC(c.start), StartedAt: formatUTC(c.start)}
	if running {
		st.OverallStatus = "running"
		st.CycleFolderUrl = "log/" + c.identity(h.id) + ".incomplete/"
		return st
	}
	st.OverallStatus = c.status()
	st.FinishedAt = formatUTC(c.end)
	st.CycleFolderUrl = "log/" + c.identity(h.id) + "/"
	st.LastFailure.FailureClass = c.failClass()
	return st
}

func (h *fakeHost) codeAt(t time.Time) float64 {
	code := 4.0
	for _, c := range h.cycles {
		if c.start.After(t) {
			break
		}
		if c.current || t.Before(c.end) {
			code = 1
		} else {
			code = float64(statusTimelineCode(c.status()))
		}
	}
	return code
}

// seedLive writes what the collector recorded while it watched the host: the
// transitions it saw (one stamped poll after each), the events it tailed, the
// presence beacon at first sight and the scraped status series.
func (h *fakeHost) seedLive(pushLoki func(map[string]any), writeProm func(map[string]string, []promSample), now time.Time, missFinalOf, missEventsOf int, notYetPolled ...int) {
	const poll = 15 * time.Second
	base := h.srv.URL
	pushLoki(map[string]any{"streams": []map[string]any{{
		"stream": map[string]string{"pool": h.pool, "hostId": h.id, "src": "presence"},
		"values": [][]string{{strconv.FormatInt(h.watched.UnixNano(), 10), fmt.Sprintf(`{"hostId":%q,"baseUrl":%q}`, h.id, base)}},
	}}})
	for _, c := range h.cycles {
		if !c.current && !c.end.After(h.watched) {
			continue
		}
		first := c.start
		if first.Before(h.watched) {
			first = h.watched
		}
		pushLoki(cycleTransitionPayload(h.pool, h.statusOf(c, true), base, first.Add(poll)))
		if !c.current && c.number != missFinalOf && !containsInt(notYetPolled, c.number) && !c.end.Add(poll).After(now) {
			pushLoki(cycleTransitionPayload(h.pool, h.statusOf(c, false), base, c.end.Add(poll)))
		}
		if c.number == missEventsOf {
			continue
		}
		cf, _ := cycleFolderFromLeaf(c.identity(h.id), h.id, "log/")
		rec := reconstructCycle(cf, []byte(c.events(h.id)))
		values := make([][]string, 0, len(rec.Lines))
		for i, ln := range rec.Lines {
			values = append(values, []string{strconv.FormatInt(rec.Stamps[i], 10), ln})
		}
		pushLoki(map[string]any{"streams": []map[string]any{{"stream": map[string]string{"pool": h.pool, "hostId": h.id, "src": "event"}, "values": values}}})
	}
	labels := map[string]string{}
	for _, l := range hostStatusLabels(h.pool, h.id) {
		labels[l[0]] = l[1]
	}
	var samples []promSample
	for t := h.watched.Truncate(poll).Add(poll); !t.After(now); t = t.Add(poll) {
		samples = append(samples, promSample{T: t.UnixMilli(), V: h.codeAt(t)})
	}
	writeProm(labels, samples)
}

func writeShareCopy(t *testing.T, root string, h *fakeHost, c fakeCycle) {
	t.Helper()
	dir := filepath.Join(root, h.id, "test-cycles", c.identity(h.id))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, eventsFile), []byte(c.events(h.id)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".yuruna-complete"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

// bfScenario is a rebuilt proxy's world: host A was watched for the last two
// days and keeps three weeks of cycles, rotated into buckets dated after them,
// one only on the pool share; host B joined an hour ago with two days of short
// cycles, a burst of failures long before it was seen and another just before.
type bfScenario struct {
	now          time.Time
	hostA, hostB *fakeHost
	shareRoot    string
	missedFinal  int       // the collector saw this cycle start, not end
	missedEvents int       // the collector saw this cycle's result but tailed no events
	pending      fakeCycle // host B: ended minutes ago; the collector has not polled it yet
	agg          *httptest.Server
}

// bfScenarioOptions shapes what the collector saw. A real Loki answers for a
// line stamped long before it arrived only many minutes later, so a test against
// one keeps the collector's history recent: host A watched briefly, and the
// cycles the collector half-saw on host B.
type bfScenarioOptions struct {
	watchedA    time.Duration // how long the collector has watched host A
	halfSeenOnB bool          // the half-seen cycles are host B's, not host A's
}

func newBackfillScenario(t *testing.T, now time.Time, idA, idB, poolA, poolB string, opts bfScenarioOptions) *bfScenario {
	t.Helper()
	if opts.watchedA == 0 {
		opts.watchedA = 48 * time.Hour
	}
	sc := &bfScenario{now: now, shareRoot: t.TempDir()}
	hostA := &fakeHost{id: idA, pool: poolA, kind: "host.windows.hyper-v", hits: map[string]int{}, watched: now.Add(-opts.watchedA)}
	for k := 85; k >= 1; k-- {
		if k > 80 && k != 85 {
			continue
		}
		c := fakeCycle{number: 1000 + 86 - k, start: now.Add(-time.Duration(k) * 6 * time.Hour), outcome: "pass"}
		c.end = c.start.Add(40 * time.Minute)
		switch {
		case k == 12:
			// Killed a minute in: its last event is the last anyone knew of it.
			c.outcome, c.end = "", c.start.Add(time.Minute)
		case k == 13:
			c.outcome, c.reason = "aborted", "host refresh"
		case k%5 == 0:
			c.outcome, c.class = "fail", "guest_boot"
		}
		switch {
		case k == 85:
			c.parent, c.shareCopy = "", true
		case k <= 8:
			c.parent = "log/"
		case k <= 40:
			c.parent = "log/history.2026-09-30/"
		default:
			c.parent = "log/history.2026-09-22/"
		}
		if k == 50 {
			c.hostless, c.shareCopy = true, true
		}
		if k == 60 {
			c.hostless = true
		}
		hostA.cycles = append(hostA.cycles, c)
	}
	hostA.cycles = append(hostA.cycles, fakeCycle{number: 1086, start: now.Add(-20 * time.Minute), parent: "log/", current: true})

	hostB := &fakeHost{id: idB, pool: poolB, kind: "host.macos.utm", hits: map[string]int{}, watched: now.Add(-time.Hour)}
	for k := 245; k >= 1; k-- {
		c := fakeCycle{number: 5000 + 246 - k, start: now.Add(-5*time.Minute - time.Duration(k)*12*time.Minute), outcome: "pass"}
		c.end = c.start.Add(10 * time.Minute)
		if (k >= 100 && k <= 102) || (k >= 6 && k <= 8) {
			// The first burst is long over when the collector arrives; the second
			// is still open then, so the collector never raised it.
			c.outcome, c.class = "fail", "network_timeout"
		}
		c.parent = "log/"
		if k > 60 {
			c.parent = "log/history.2026-10-01/"
		}
		hostB.cycles = append(hostB.cycles, c)
	}
	hostB.cycles = append(hostB.cycles, fakeCycle{number: 5246, start: now.Add(-5 * time.Minute), parent: "log/", current: true})

	for _, h := range []*fakeHost{hostA, hostB} {
		h.srv = httptest.NewServer(h)
		t.Cleanup(h.srv.Close)
		for _, c := range h.cycles {
			if c.shareCopy {
				writeShareCopy(t, sc.shareRoot, h, c)
			}
		}
	}
	sc.hostA, sc.hostB = hostA, hostB
	// Host B's two newest finished cycles are inside the settle margin, so its
	// half-seen ones are taken one further back.
	half, back := hostA, 0
	if opts.halfSeenOnB {
		half, back = hostB, 1
	}
	sc.missedFinal = half.cycles[len(half.cycles)-4-back].number
	sc.missedEvents = half.cycles[len(half.cycles)-3-back].number
	sc.pending = hostB.cycles[len(hostB.cycles)-2]
	sc.agg = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != routePoolStatus {
			http.NotFound(w, r)
			return
		}
		var hosts []map[string]any
		for _, h := range []*fakeHost{hostA, hostB} {
			hosts = append(hosts, map[string]any{"hostId": h.id, "baseUrl": h.srv.URL, "reachable": true, "poolId": h.pool, "status": h.statusOf(h.current(), true)})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"pool": "default", "hosts": hosts})
	}))
	t.Cleanup(sc.agg.Close)
	return sc
}

// seed writes what the collector recorded before the backfill runs. The cycle
// numbers of the two hosts do not overlap, so each host simply ignores the
// half-seen numbers that are not its own.
func (sc *bfScenario) seed(pushLoki func(map[string]any), writeProm func(map[string]string, []promSample)) {
	sc.hostA.seedLive(pushLoki, writeProm, sc.now, sc.missedFinal, sc.missedEvents)
	sc.hostB.seedLive(pushLoki, writeProm, sc.now, sc.missedFinal, sc.missedEvents, sc.pending.number)
}

// until is the newest start the backfill may take for the host.
func (sc *bfScenario) until(h *fakeHost, cfg backfillConfig) time.Time {
	until := sc.now.Add(-cfg.settle)
	if h.current().start.Before(until) {
		until = h.current().start
	}
	return until
}

// expectedEventLines is how many event lines the backfill must have written for
// a cycle in a stream of its own.
func (sc *bfScenario) expectedEventLines(h *fakeHost, c fakeCycle, cfg backfillConfig) (int, bool) {
	if c.current || !c.start.After(sc.now.Add(-cfg.eventHorizon)) || !c.start.Before(sc.now.Add(-cfg.settle)) {
		return 0, false
	}
	if (c.end.After(h.watched) && c.number != sc.missedEvents) || (c.hostless && !c.shareCopy) {
		return 0, true // tailed live into the host's own stream, or never readable
	}
	return len(strings.Split(strings.TrimSpace(c.events(h.id)), "\r\n")), true
}

// burst is host B's incident that the collector would have raised and resolved
// before it first saw the host.
func (sc *bfScenario) burst(t *testing.T) []fakeCycle {
	var burst []fakeCycle
	for _, c := range sc.hostB.cycles {
		if c.class != "" && c.end.Before(sc.hostB.watched.Add(-6*time.Hour)) {
			burst = append(burst, c)
		}
	}
	if len(burst) != 3 {
		t.Fatalf("scenario: want a three-fail burst, got %d", len(burst))
	}
	return burst
}

// TestBackfillSweepRestoresHistoryOnce runs the backfill against the scenario's
// rebuilt proxy until nothing is left, and then once more, which must write
// nothing at all.
func TestBackfillSweepRestoresHistoryOnce(t *testing.T) {
	// Off the five-minute grid on purpose: the coverage windows must not depend
	// on the moment a sweep runs.
	now := bfAt("2026-10-02T12:00:07Z")
	clock := func() time.Time { return now }
	loki := newFakeLoki(clock)
	prom := newFakeProm(t, clock)
	lokiSrv := httptest.NewServer(loki)
	defer lokiSrv.Close()
	promSrv := httptest.NewServer(prom)
	defer promSrv.Close()

	sc := newBackfillScenario(t, now, bfHostA, bfHostB, "red", "blue", bfScenarioOptions{})
	hostA, hostB := sc.hostA, sc.hostB
	sc.seed(loki.seed, func(labels map[string]string, samples []promSample) {
		prom.mu.Lock()
		defer prom.mu.Unlock()
		for _, s := range samples {
			_ = prom.add(labels, s.T, s.V, false)
		}
	})
	// Everything the backfill writes stays out of Loki's answers until the end:
	// the job must neither write a cycle twice nor build a wrong timeline or
	// incident because it cannot read back what it wrote.
	loki.lag = true

	cfg, err := parseBackfillFlags([]string{"-aggregator", sc.agg.URL, "-loki", lokiSrv.URL + "/loki/api/v1/push", "-prometheus", promSrv.URL,
		"-state-dir", t.TempDir(), "-archive-root", sc.shareRoot, "-once"})
	if err != nil {
		t.Fatal(err)
	}
	noSleep := func(ctx context.Context, _ time.Duration) bool { return ctx.Err() == nil }
	b := newBackfiller(cfg, &http.Client{Timeout: 10 * time.Second}, clock, noSleep)
	ctx := context.Background()

	// The first sweep must refill the board backwards: host B holds more
	// history than one pass writes, so the pass takes the newest cycles -- the
	// days just before the rebuild -- and leaves the older days for later.
	res := b.sweep(ctx)
	if res.More != 1 {
		t.Fatalf("first sweep: want exactly one host with history left, got %d", res.More)
	}
	firstB := dedupeCycleOrder(loki.cyclePushLog(), hostB.id)
	if len(firstB) != maxCyclesPerHostPass {
		t.Fatalf("first sweep wrote %d of host B's cycles, want the newest %d", len(firstB), maxCyclesPerHostPass)
	}
	oldestFirst := assertNewestFirst(t, hostB.id, firstB)
	// The timeline follows the same order: after one sweep it reaches back
	// exactly as far as the cycles written so far, never further.
	prom.mu.Lock()
	for k, backfilled := range prom.backfilled {
		if prom.labels[k]["hostId"] != hostB.id {
			continue
		}
		for ms := range backfilled {
			if time.UnixMilli(ms).UTC().Before(oldestFirst) {
				t.Errorf("a timeline sample at %v predates the oldest cycle of the first sweep (%v)", time.UnixMilli(ms).UTC(), oldestFirst)
			}
		}
	}
	prom.mu.Unlock()

	sweeps := 1
	for res.More != 0 {
		sweeps++
		res = b.sweep(ctx)
		if sweeps > 5 {
			t.Fatal("the backfill never finished")
		}
	}
	if sweeps != 2 {
		t.Errorf("host B's 240 unwatched cycles take two sweeps; took %d", sweeps)
	}
	// Across the whole run each host's cycles went newest first, so the board
	// grew backwards from the rebuild moment toward the horizon.
	for _, h := range []*fakeHost{hostA, hostB} {
		assertNewestFirst(t, h.id, dedupeCycleOrder(loki.cyclePushLog(), h.id))
	}

	horizonStart := now.Add(-cfg.horizon)
	for _, h := range []*fakeHost{hostA, hostB} {
		until := sc.until(h, cfg)
		for _, c := range h.cycles {
			if c.current || c.start.Before(horizonStart) || !c.start.Before(until) {
				continue
			}
			key := formatUTC(c.start)
			entries := loki.lines(map[string]string{"src": "cycle", "hostId": h.id, "cycleStartUtc": key})
			var finals, runnings []map[string]string
			for _, e := range entries {
				var body map[string]string
				if err := json.Unmarshal([]byte(e.line), &body); err != nil {
					t.Fatal(err)
				}
				if body["overallStatus"] == "running" {
					runnings = append(runnings, body)
				} else {
					finals = append(finals, body)
				}
			}
			if c.hostless && !c.shareCopy {
				if len(finals) != 0 {
					t.Errorf("%s: a cycle nothing can read must not be invented", c.identity(h.id))
				}
				continue
			}
			if len(finals) != 1 || len(runnings) != 1 {
				t.Errorf("%s: want one running and one final line, got %d and %d", c.identity(h.id), len(runnings), len(finals))
				continue
			}
			f := finals[0]
			if f["overallStatus"] != c.status() || f["failureClass"] != c.failClass() || f["finishedAt"] != formatUTC(c.end) || f["hostType"] != h.kind {
				t.Errorf("%s: final line %v does not match the cycle (%s %s)", c.identity(h.id), f, c.status(), c.failClass())
			}
		}
	}

	for _, e := range loki.lines(map[string]string{"src": "cycle", "hostId": hostB.id, "cycleStartUtc": formatUTC(sc.pending.start)}) {
		if !strings.Contains(e.line, `"overallStatus":"running"`) {
			t.Errorf("a cycle that ended minutes ago is the collector's to record: %s", e.line)
		}
	}

	for _, e := range loki.lines(map[string]string{}) {
		if strings.Contains(e.line, "secret-host") {
			t.Fatalf("a hostname reached Loki: %s", e.line)
		}
	}

	for _, h := range []*fakeHost{hostA, hostB} {
		for _, c := range h.cycles {
			want, ok := sc.expectedEventLines(h, c, cfg)
			if !ok {
				continue
			}
			if got := len(loki.lines(map[string]string{"src": "event", "hostId": h.id, "cycleStartUtc": formatUTC(c.start)})); got != want {
				t.Errorf("%s: %d backfilled event lines, want %d", c.identity(h.id), got, want)
			}
		}
	}

	burst := sc.burst(t)
	incidentStreams := map[string]bool{}
	for _, e := range loki.lines(map[string]string{"src": "incident", "hostId": hostB.id}) {
		var body map[string]any
		_ = json.Unmarshal([]byte(e.line), &body)
		incidentStreams[fmt.Sprint(body["incidentId"])] = true
	}
	if len(incidentStreams) != 1 {
		t.Errorf("only the incident that was over before the collector arrived may be replayed: %v", incidentStreams)
	}
	incID := incidentID(hostB.id, burst[0].end)
	inc := loki.lines(map[string]string{"src": "incident", "hostId": hostB.id, "incidentId": incID})
	if len(inc) != 2 || !strings.Contains(inc[0].line, `"event":"incident_open"`) || !strings.Contains(inc[1].line, `"event":"incident_resolved"`) ||
		inc[1].ns != burst[2].end.Add(defaultIncidentWin).UnixNano() {
		t.Errorf("host B's incident was not replayed as the collector would have raised it: %+v", inc)
	}
	if got := loki.lines(map[string]string{"src": "incident", "hostId": hostA.id}); len(got) != 0 {
		t.Errorf("host A's fails are six hours apart and raise no incident: %+v", got)
	}

	// The timeline: samples only where the live series had none, valued from the cycles.
	settled := now.Add(-cfg.settle).UnixMilli()
	prom.mu.Lock()
	for k, backfilled := range prom.backfilled {
		live := map[int64]bool{}
		for ms := range prom.samples[k] {
			if !backfilled[ms] {
				live[(ms+299999)/300000] = true
			}
		}
		host := hostA
		if prom.labels[k]["hostId"] == hostB.id {
			host = hostB
		}
		for ms := range backfilled {
			if live[(ms+299999)/300000] {
				t.Errorf("a sample was written at %v, inside a window the live series covers", time.UnixMilli(ms).UTC())
			}
			if ms > settled {
				t.Errorf("a sample at %v is newer than the settle margin", time.UnixMilli(ms).UTC())
			}
			at := time.UnixMilli(ms).UTC()
			if want := host.codeAt(at); prom.samples[k][ms] != want {
				t.Errorf("%s at %v: value %v, want %v", host.id, at, prom.samples[k][ms], want)
			}
		}
	}
	countBackfilled := func(h *fakeHost, from, to time.Time) int {
		n := 0
		for k, backfilled := range prom.backfilled {
			if prom.labels[k]["hostId"] != h.id {
				continue
			}
			for ms := range backfilled {
				if ms >= from.UnixMilli() && ms < to.UnixMilli() {
					n++
				}
			}
		}
		return n
	}
	old := hostA.cycles[len(hostA.cycles)-21] // twenty cycles back: five days before the rebuild
	if n := countBackfilled(hostA, old.start, old.end); n < 19 {
		t.Errorf("an old cycle's running stretch got %d samples", n)
	}
	if n := countBackfilled(hostA, old.end.Add(maxFinalHold+2*time.Minute), old.start.Add(6*time.Hour)); n != 0 {
		t.Errorf("%d samples painted into the gap between cycles", n)
	}
	if n := countBackfilled(hostB, hostB.cycles[10].start, hostB.cycles[11].start); n == 0 {
		t.Error("host B's history before it joined has no timeline")
	}
	keys := 0
	for k := range prom.samples {
		if prom.labels[k]["__name__"] == "yuruna_pool_host_status" {
			keys++
		}
	}
	prom.mu.Unlock()
	if keys != 2 {
		t.Errorf("backfilled samples must extend the live series, not add new ones: %d series", keys)
	}

	// The index places a click on a rotated cycle without asking the host.
	s := newPoolState("default", 8080)
	s.backfillStateDir = cfg.stateDir
	if got, want := s.resolveFolderByIndex(hostA.id, old.start.Add(10*time.Minute)), old.parent+old.identity(hostA.id)+"/"; got != want {
		t.Errorf("index answer %q, want %q", got, want)
	}

	// Once caught up, a sweep writes nothing, before or after Loki files the lines
	// away; the cycle no copy of can be read is tried three times in all and then
	// left alone.
	b.sweep(ctx)
	loki.reveal()
	pushes, writes := loki.pushCount(), prom.writeCount()
	hitsA, hitsB := hostA.eventFileHits(), hostB.eventFileHits()
	queries := loki.queryCount()
	for i := 0; i < 3; i++ {
		b.sweep(ctx)
	}
	if n := loki.queriesAbout(hostB.id, queries); n != 0 {
		t.Errorf("a host with nothing left to do was looked up in Loki %d times", n)
	}
	if loki.pushCount() != pushes || prom.writeCount() != writes {
		t.Errorf("a caught-up sweep wrote again: %d Loki pushes, %d remote writes", loki.pushCount()-pushes, prom.writeCount()-writes)
	}
	if got := hostB.eventFileHits() - hitsB; got != 0 {
		t.Errorf("host B was asked for %d event files after catching up", got)
	}
	if got := hostA.eventFileHits() - hitsA; got != 0 {
		t.Errorf("the unreadable cycle must be given up after three attempts; %d more requests", got)
	}
	for _, h := range []*fakeHost{hostA, hostB} {
		if _, err := os.Stat(hostStatePath(cfg.stateDir, h.id)); err != nil {
			t.Errorf("state not saved: %v", err)
		}
	}
	// A day later the whole window is checked again, and still nothing is written
	// once the collector has recorded the result it was about to poll.
	loki.seed(cycleTransitionPayload(hostB.pool, hostB.statusOf(sc.pending, false), hostB.srv.URL, sc.pending.end.Add(15*time.Second)))
	pushes = loki.pushCount()
	now = now.Add(derivedRefreshInterval)
	b.sweep(ctx)
	if loki.pushCount() != pushes {
		t.Errorf("the daily check rewrote %d pushes", loki.pushCount()-pushes)
	}
}

// testClock is a clock a fake host can move forward while it answers, the way
// real time passes while a slow status service builds a listing.
type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// newScenarioBackfiller is the backfiller TestBackfillSweepRestoresHistoryOnce
// runs, for a scenario: a fake Loki and Prometheus seeded with what the collector
// recorded, the scenario's pool share, and a sleep that never waits.
func newScenarioBackfiller(t *testing.T, sc *bfScenario, clock func() time.Time) (*backfiller, *fakeLoki) {
	t.Helper()
	loki := newFakeLoki(clock)
	prom := newFakeProm(t, clock)
	lokiSrv := httptest.NewServer(loki)
	t.Cleanup(lokiSrv.Close)
	promSrv := httptest.NewServer(prom)
	t.Cleanup(promSrv.Close)
	sc.seed(loki.seed, func(labels map[string]string, samples []promSample) {
		prom.mu.Lock()
		defer prom.mu.Unlock()
		for _, s := range samples {
			_ = prom.add(labels, s.T, s.V, false)
		}
	})
	cfg, err := parseBackfillFlags([]string{"-aggregator", sc.agg.URL, "-loki", lokiSrv.URL + "/loki/api/v1/push", "-prometheus", promSrv.URL,
		"-state-dir", t.TempDir(), "-archive-root", sc.shareRoot, "-once"})
	if err != nil {
		t.Fatal(err)
	}
	noSleep := func(ctx context.Context, _ time.Duration) bool { return ctx.Err() == nil }
	return newBackfiller(cfg, &http.Client{Timeout: 10 * time.Second}, clock, noSleep), loki
}

// hasFinalLine reports whether Loki holds the cycle's final transition line.
func hasFinalLine(loki *fakeLoki, h *fakeHost, c fakeCycle) bool {
	for _, e := range loki.lines(map[string]string{"src": "cycle", "hostId": h.id, "cycleStartUtc": formatUTC(c.start)}) {
		if !strings.Contains(e.line, `"overallStatus":"running"`) {
			return true
		}
	}
	return false
}

// unwatchedCycles splits the host's cycles that ended before the collector first
// saw it -- the ones only the backfill can restore -- into those the pool share
// holds and those only the host can serve.
func unwatchedCycles(h *fakeHost) (shared, hostOnly []fakeCycle) {
	for _, c := range h.cycles {
		switch {
		case c.current || !c.end.Before(h.watched):
		case c.shareCopy:
			shared = append(shared, c)
		case !c.hostless:
			hostOnly = append(hostOnly, c)
		}
	}
	return shared, hostOnly
}

// TestBackfillListsEachHostOncePerInterval: a host's log listing is read once,
// the passes after it work from the folders that listing found, and the next
// listing waits out the interval.
func TestBackfillListsEachHostOncePerInterval(t *testing.T) {
	clock := &testClock{now: bfAt("2026-10-02T12:00:07Z")}
	sc := newBackfillScenario(t, clock.Now(), bfHostA, bfHostB, "red", "blue", bfScenarioOptions{})
	b, _ := newScenarioBackfiller(t, sc, clock.Now)
	ctx := context.Background()

	if res := b.sweep(ctx); res.More != 1 {
		t.Fatalf("first sweep: want host B's older history left for a second pass, got More=%d", res.More)
	}
	if res := b.sweep(ctx); res.More != 0 {
		t.Fatalf("second sweep: want host B finished from the folders its first listing found, got More=%d", res.More)
	}
	for _, h := range []*fakeHost{sc.hostA, sc.hostB} {
		if got := h.hitsOf("/log/"); got != 1 {
			t.Errorf("%s: listed %d times inside one interval, want once", h.id, got)
		}
		hs := loadHostState(b.cfg.stateDir, h.id)
		if !hs.ListedAt.Equal(clock.Now()) || !hs.ListingDeferredUntil.IsZero() {
			t.Errorf("%s: state records listedAt=%v deferredUntil=%v", h.id, hs.ListedAt, hs.ListingDeferredUntil)
		}
	}
	clock.Advance(hostListingInterval)
	b.sweep(ctx)
	for _, h := range []*fakeHost{sc.hostA, sc.hostB} {
		if got := h.hitsOf("/log/"); got != 2 {
			t.Errorf("%s: listed %d times once the interval was over, want twice", h.id, got)
		}
	}
}

// TestBackfillLeavesASlowHostAloneAndRestoresItFromTheShare: a listing that held
// the host's status service past the threshold defers the host. Until the
// deferral ends the host is sent no request at all, its archived history still
// comes from the pool share, and the cycles only it holds wait without being
// charged and without keeping the sweeps busy.
func TestBackfillLeavesASlowHostAloneAndRestoresItFromTheShare(t *testing.T) {
	clock := &testClock{now: bfAt("2026-10-02T12:00:07Z")}
	sc := newBackfillScenario(t, clock.Now(), bfHostA, bfHostB, "red", "blue", bfScenarioOptions{})
	b, loki := newScenarioBackfiller(t, sc, clock.Now)
	ctx := context.Background()
	hostA := sc.hostA
	shared, hostOnly := unwatchedCycles(hostA)
	if len(shared) != 2 || len(hostOnly) == 0 {
		t.Fatalf("scenario: want two shared cycles and some only host A holds, got %d and %d", len(shared), len(hostOnly))
	}
	hostA.setIntercept(func(_ http.ResponseWriter, r *http.Request) bool {
		if r.URL.Path == "/log/" {
			// The order a Linux host takes to merge a large archive into its listing.
			clock.Advance(90 * time.Second)
		}
		return false
	})
	var logged strings.Builder
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	b.sweep(ctx)
	hs := loadHostState(b.cfg.stateDir, hostA.id)
	if !hs.hostDeferred(clock.Now()) {
		t.Fatalf("a slow listing must defer the host; state records deferredUntil=%v", hs.ListingDeferredUntil)
	}
	// The operator reads the deferral, and when it ends, in the job's log.
	want := "its log listing took 1m30s, so the host is asked for nothing before " + formatUTC(hs.ListingDeferredUntil)
	if out := logged.String(); !strings.Contains(out, hostA.id) || !strings.Contains(out, want) {
		t.Errorf("the log must name the deferred host and say until when; it reads:\n%s", out)
	}
	if got := hostA.eventFileHits(); got != 0 {
		t.Errorf("a host whose listing was slow was asked for %d event files in the same pass", got)
	}
	for _, c := range shared {
		if !hasFinalLine(loki, hostA, c) {
			t.Errorf("%s: a cycle the pool share holds must be restored while its host is left alone", c.identity(hostA.id))
		}
	}
	for _, c := range hostOnly {
		if hasFinalLine(loki, hostA, c) {
			t.Errorf("%s: only the host holds this cycle, and the host must not have been asked", c.identity(hostA.id))
		}
	}
	if len(hs.Failures) != 0 {
		t.Errorf("cycles waiting on a deferred host must not be charged: %v", hs.Failures)
	}

	asked := hostA.requestCount()
	clock.Advance(time.Hour)
	if res := b.sweep(ctx); res.More != 0 {
		t.Errorf("cycles waiting on a deferred host must not keep the sweeps busy: More=%d", res.More)
	}
	if got := hostA.requestCount() - asked; got != 0 {
		t.Errorf("a deferred host was sent %d requests", got)
	}

	hostA.setIntercept(nil)
	clock.Advance(listingDeferral)
	b.sweep(ctx)
	if got := hostA.hitsOf("/log/"); got != 2 {
		t.Errorf("once the deferral is over the host must be listed again; it was listed %d times", got)
	}
	for _, c := range hostOnly {
		if !hasFinalLine(loki, hostA, c) {
			t.Errorf("%s: once the deferral is over the host's own cycles must be restored", c.identity(hostA.id))
		}
	}
}

// TestBackfillRestoresTheShareWhenAListingFails: a host whose listing cannot be
// read still has its archived history restored, and the listing is tried again
// after the interval rather than on every sweep.
func TestBackfillRestoresTheShareWhenAListingFails(t *testing.T) {
	clock := &testClock{now: bfAt("2026-10-02T12:00:07Z")}
	sc := newBackfillScenario(t, clock.Now(), bfHostA, bfHostB, "red", "blue", bfScenarioOptions{})
	b, loki := newScenarioBackfiller(t, sc, clock.Now)
	ctx := context.Background()
	hostA := sc.hostA
	shared, hostOnly := unwatchedCycles(hostA)
	hostA.setIntercept(func(w http.ResponseWriter, r *http.Request) bool {
		if r.URL.Path != "/log/" {
			return false
		}
		http.Error(w, "listing unavailable", http.StatusInternalServerError)
		return true
	})

	b.sweep(ctx)
	for _, c := range shared {
		if !hasFinalLine(loki, hostA, c) {
			t.Errorf("%s: a failed listing must not keep the pool share's copy from being restored in the same pass", c.identity(hostA.id))
		}
	}
	b.sweep(ctx)
	if got := hostA.hitsOf("/log/"); got != 1 {
		t.Errorf("a listing that failed fast was retried %d times inside one interval, want once in all", got)
	}
	if hs := loadHostState(b.cfg.stateDir, hostA.id); hs.hostDeferred(clock.Now()) {
		t.Errorf("a listing that failed fast must not defer the host for a day: %v", hs.ListingDeferredUntil)
	}

	hostA.setIntercept(nil)
	clock.Advance(hostListingInterval)
	b.sweep(ctx)
	for _, c := range hostOnly {
		if !hasFinalLine(loki, hostA, c) {
			t.Errorf("%s: the next listing must restore the cycles only the host holds", c.identity(hostA.id))
		}
	}
}
