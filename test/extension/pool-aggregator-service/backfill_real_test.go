// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// lokiPushLog is a proxy in front of a real Loki that keeps every push it passes
// on, with Loki's answer, so a test can tell what was written from what Loki
// already answers for.
type lokiPushLog struct {
	mu     sync.Mutex
	pushes []recordedPush
}

type recordedPush struct {
	status  int
	streams []struct {
		Stream map[string]string `json:"stream"`
		Values [][2]string       `json:"values"`
	}
}

func newLokiPushProxy(t *testing.T, target string) (*httptest.Server, *lokiPushLog) {
	u, err := url.Parse(target)
	if err != nil {
		t.Fatal(err)
	}
	rec := &lokiPushLog{}
	proxy := httputil.NewSingleHostReverseProxy(u)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/loki/api/v1/push" {
			proxy.ServeHTTP(w, r)
			return
		}
		body, _ := io.ReadAll(r.Body)
		r.Body = io.NopCloser(bytes.NewReader(body))
		var p recordedPush
		var doc struct {
			Streams []struct {
				Stream map[string]string `json:"stream"`
				Values [][2]string       `json:"values"`
			} `json:"streams"`
		}
		_ = json.Unmarshal(body, &doc)
		p.streams = doc.Streams
		cw := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		proxy.ServeHTTP(cw, r)
		p.status = cw.status
		rec.mu.Lock()
		rec.pushes = append(rec.pushes, p)
		rec.mu.Unlock()
	}))
	t.Cleanup(srv.Close)
	return srv, rec
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (l *lokiPushLog) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.pushes)
}

// cycleLog returns every accepted src=cycle push as "hostId|cycleStartUtc", in
// the order Loki accepted them.
func (l *lokiPushLog) cycleLog() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []string
	for _, p := range l.pushes {
		if p.status/100 != 2 {
			continue
		}
		for _, st := range p.streams {
			if st.Stream["src"] == "cycle" {
				out = append(out, st.Stream["hostId"]+"|"+st.Stream["cycleStartUtc"])
			}
		}
	}
	return out
}

// lines returns every pushed line of the streams whose labels include want, and
// how many pushes Loki refused.
func (l *lokiPushLog) lines(want map[string]string) (out []string, refused int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, p := range l.pushes {
		if p.status/100 != 2 {
			refused++
			continue
		}
		for _, st := range p.streams {
			ok := true
			for k, v := range want {
				if st.Stream[k] != v {
					ok = false
				}
			}
			if !ok {
				continue
			}
			for _, v := range st.Values {
				out = append(out, v[1])
			}
		}
	}
	return out, refused
}

// TestBackfillAgainstRealLokiAndPrometheus runs the scenario against real servers
// configured as the proxy configures them. It checks what only the real servers
// can settle: that Loki accepts every line the backfill writes -- stamped weeks
// back, into streams of their own and into a stream the collector began -- that
// Loki parses every query the backfill sends and answers them for the lines the
// collector wrote, and that Prometheus takes old samples through remote write and
// answers for them at once. It skips unless both servers are named:
//
//	YURUNA_BACKFILL_LOKI=http://127.0.0.1:3100
//	YURUNA_BACKFILL_PROMETHEUS=http://127.0.0.1:9090
//
// Loki answers for a line stamped long before it arrived only once it has filed
// the line away, many minutes later. With YURUNA_BACKFILL_LOKI_WAIT=60m the test
// also waits up to that long for Loki to answer for every backfilled cycle, and
// then checks the dashboard's own counts.
//
// Prometheus needs --web.enable-remote-write-receiver and an out-of-order window
// of at least 30 days; Loki needs reject_old_samples_max_age of at least 30 days.
// Every run uses fresh host ids and pools, so runs against one pair of servers do
// not see each other's data.
func TestBackfillAgainstRealLokiAndPrometheus(t *testing.T) {
	lokiBase := strings.TrimRight(os.Getenv("YURUNA_BACKFILL_LOKI"), "/")
	promBase := strings.TrimRight(os.Getenv("YURUNA_BACKFILL_PROMETHEUS"), "/")
	if lokiBase == "" || promBase == "" {
		t.Skip("set YURUNA_BACKFILL_LOKI and YURUNA_BACKFILL_PROMETHEUS to run against real servers")
	}
	run := fmt.Sprintf("%08x", uint32(time.Now().UnixNano()))
	idA := "42" + run + strings.Repeat("a", 22)
	idB := "42" + run + strings.Repeat("b", 22)
	poolA, poolB := "red-"+run, "blue-"+run
	now := time.Now().UTC().Truncate(time.Second)
	sc := newBackfillScenario(t, now, idA, idB, poolA, poolB, bfScenarioOptions{watchedA: 90 * time.Minute, halfSeenOnB: true})
	client := &http.Client{Timeout: 2 * time.Minute}

	sc.seed(func(p map[string]any) {
		if err := postToLoki(client, lokiBase+"/loki/api/v1/push", p, "seed"); err != nil {
			t.Fatalf("seeding Loki: %v", err)
		}
	}, func(labels map[string]string, samples []promSample) {
		var ls [][2]string
		for k, v := range labels {
			ls = append(ls, [2]string{k, v})
		}
		sort.Slice(ls, func(i, j int) bool { return ls[i][0] < ls[j][0] })
		for len(samples) > 0 {
			n := min(len(samples), 5000)
			body := snappyEncodeLiteral(encodeWriteRequest([]promSeries{{Labels: ls, Samples: samples[:n]}}))
			req, _ := http.NewRequest(http.MethodPost, promBase+"/api/v1/write", bytes.NewReader(body))
			req.Header.Set("Content-Encoding", "snappy")
			req.Header.Set("Content-Type", "application/x-protobuf")
			req.Header.Set("X-Prometheus-Remote-Write-Version", "0.1.0")
			resp, err := client.Do(req)
			if err != nil {
				t.Fatalf("seeding Prometheus: %v", err)
			}
			msg, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode/100 != 2 {
				t.Fatalf("seeding Prometheus: HTTP %d: %s", resp.StatusCode, msg)
			}
			samples = samples[n:]
		}
	})

	lokiProxy, pushed := newLokiPushProxy(t, lokiBase)
	cfg, err := parseBackfillFlags([]string{"-aggregator", sc.agg.URL, "-loki", lokiProxy.URL + "/loki/api/v1/push", "-prometheus", promBase,
		"-state-dir", t.TempDir(), "-archive-root", sc.shareRoot, "-once"})
	if err != nil {
		t.Fatal(err)
	}
	noSleep := func(ctx context.Context, _ time.Duration) bool { return ctx.Err() == nil }
	b := newBackfiller(cfg, client, func() time.Time { return time.Now().UTC() }, noSleep)
	ctx := context.Background()
	for sweeps := 1; ; sweeps++ {
		res := b.sweep(ctx)
		if res.More == 0 {
			break
		}
		if sweeps > 5 {
			t.Fatal("the backfill never finished")
		}
	}
	// Two more: the unreadable cycle is tried a third time and given up on.
	b.sweep(ctx)
	b.sweep(ctx)

	// The refill ran backwards on the real stack too: every host's cycles were
	// pushed newest first, across sweeps.
	for _, h := range []*fakeHost{sc.hostA, sc.hostB} {
		assertNewestFirst(t, h.id, dedupeCycleOrder(pushed.cycleLog(), h.id))
	}

	// Every line was accepted, and every cycle written exactly once, counting the
	// lines the collector wrote and the ones the backfill wrote.
	horizonStart := now.Add(-cfg.horizon)
	for _, h := range []*fakeHost{sc.hostA, sc.hostB} {
		for _, c := range h.cycles {
			if c.current || c.start.Before(horizonStart) || !c.start.Before(sc.until(h, cfg)) {
				continue
			}
			key := formatUTC(c.start)
			lines, refused := pushed.lines(map[string]string{"src": "cycle", "hostId": h.id, "cycleStartUtc": key})
			if refused != 0 {
				t.Fatalf("Loki refused %d pushes", refused)
			}
			running, final := 0, 0
			for _, ln := range lines {
				if strings.Contains(ln, `"overallStatus":"running"`) {
					running++
				} else {
					final++
				}
			}
			watched := c.end.After(h.watched)
			wantRunning, wantFinal := 1, 1
			if watched {
				wantRunning = 0 // the collector wrote it
				if c.number != sc.missedFinal && c.number != sc.pending.number {
					wantFinal = 0
				}
			}
			if c.hostless && !c.shareCopy {
				wantRunning, wantFinal = 0, 0
			}
			if running != wantRunning || final != wantFinal {
				t.Errorf("%s: backfill wrote %d running and %d final lines, want %d and %d", c.identity(h.id), running, final, wantRunning, wantFinal)
			}
			if want, ok := sc.expectedEventLines(h, c, cfg); ok {
				events, _ := pushed.lines(map[string]string{"src": "event", "hostId": h.id, "cycleStartUtc": key})
				if len(events) != want {
					t.Errorf("%s: backfill wrote %d event lines, want %d", c.identity(h.id), len(events), want)
				}
			}
		}
	}
	burst := sc.burst(t)
	incLines, _ := pushed.lines(map[string]string{"src": "incident", "hostId": idB})
	if len(incLines) != 2 || !strings.Contains(incLines[0], incidentID(idB, burst[0].end)) {
		t.Errorf("host B's incident: %v", incLines)
	}

	// Loki parses every query the backfill sends; these answer for the
	// collector's own lines at once.
	if _, err := b.lokiCycleStreams(ctx, idA, horizonStart, time.Now().UTC()); err != nil {
		t.Errorf("cycle streams query: %v", err)
	}
	live, err := b.lokiEventCycles(ctx, idA, now.Add(-cfg.eventHorizon), time.Now().UTC())
	if err != nil {
		t.Errorf("event cycles query: %v", err)
	}
	liveB, err := b.lokiEventCycles(ctx, idB, now.Add(-cfg.eventHorizon), time.Now().UTC())
	if err != nil {
		t.Errorf("event cycles query: %v", err)
	}
	tailed := 0
	for _, h := range []*fakeHost{sc.hostA, sc.hostB} {
		seen := live
		if h == sc.hostB {
			seen = liveB
		}
		for _, c := range h.cycles {
			if !c.current && c.end.After(h.watched) && c.number != sc.missedEvents {
				tailed++
				if !seen[formatUTC(c.start)] {
					t.Errorf("%s: Loki does not report the events the collector tailed, so the backfill would write them twice", c.identity(h.id))
				}
			}
		}
	}
	if tailed == 0 {
		t.Error("scenario: the collector tailed no cycle's events")
	}
	if first, err := b.firstPresence(ctx, idB, horizonStart, time.Now().UTC()); err != nil || !first.Equal(sc.hostB.watched) {
		t.Errorf("first presence: %v %v, want %v", first, err, sc.hostB.watched)
	}
	if _, err := b.lokiIncidentIDs(ctx, idB, horizonStart, time.Now().UTC()); err != nil {
		t.Errorf("incident ids query: %v", err)
	}

	get := func(base, path string, q url.Values, out any) {
		t.Helper()
		resp, err := client.Get(base + path + "?" + q.Encode())
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s %s: HTTP %d: %s", path, q.Get("query"), resp.StatusCode, body)
		}
		if err := json.Unmarshal(body, out); err != nil {
			t.Fatal(err)
		}
	}

	// The timeline, read back from Prometheus at once.
	promAt := func(query string, when time.Time) []float64 {
		t.Helper()
		var doc struct {
			Data struct {
				Result []struct {
					Value [2]any `json:"value"`
				} `json:"result"`
			} `json:"data"`
		}
		get(promBase, "/api/v1/query", url.Values{"query": {query}, "time": {strconv.FormatInt(when.Unix(), 10)}}, &doc)
		var out []float64
		for _, r := range doc.Data.Result {
			v, _ := strconv.ParseFloat(fmt.Sprint(r.Value[1]), 64)
			out = append(out, v)
		}
		return out
	}
	old := sc.hostA.cycles[len(sc.hostA.cycles)-21]
	series := fmt.Sprintf(`yuruna_pool_host_status{hostId=%q}`, idA)
	if got := promAt(series, old.start.Add(11*time.Minute)); len(got) != 1 || got[0] != 1 {
		t.Errorf("inside an old cycle: %v, want running", got)
	}
	if got := promAt(series, old.end.Add(11*time.Minute)); len(got) != 1 || got[0] != float64(statusTimelineCode(old.status())) {
		t.Errorf("after an old cycle: %v, want %s", got, old.status())
	}
	if got := promAt(series, old.end.Add(maxFinalHold+10*time.Minute)); len(got) != 0 {
		t.Errorf("in the gap after an old cycle: %v, want nothing", got)
	}
	if got := promAt(fmt.Sprintf(`count(last_over_time(%s[2160h]))`, series), time.Now()); len(got) != 1 || got[0] != 1 {
		t.Errorf("backfilled samples must extend the live series: %v series", got)
	}
	// Prometheus 2 counts both ends of the range, so a window the live 15-second
	// scrape fills holds 21 samples; one more means a backfilled sample landed in it.
	if got := promAt(fmt.Sprintf(`max_over_time(count_over_time(%s[5m])[2160h:5m])`, series), time.Now()); len(got) != 1 || got[0] > 21 {
		t.Errorf("a five-minute window holds %v samples: live and backfilled samples were mixed", got)
	}
	if got := promAt(fmt.Sprintf(`count_over_time(yuruna_pool_host_status{hostId=%q}[2160h])`, idB), time.Now()); len(got) != 1 || got[0] < 1000 {
		t.Errorf("host B's two days before it joined: %v samples", got)
	}

	// A caught-up sweep writes nothing anywhere.
	samples := promAt(fmt.Sprintf(`sum(count_over_time(yuruna_pool_host_status{hostId=~%q}[2160h]))`, idA+"|"+idB), time.Now())
	pushes := pushed.count()
	b.sweep(ctx)
	if pushed.count() != pushes {
		t.Errorf("a caught-up sweep pushed %d times", pushed.count()-pushes)
	}
	if again := promAt(fmt.Sprintf(`sum(count_over_time(yuruna_pool_host_status{hostId=~%q}[2160h]))`, idA+"|"+idB), time.Now()); fmt.Sprint(again) != fmt.Sprint(samples) {
		t.Errorf("a caught-up sweep wrote samples: %v -> %v", samples, again)
	}

	wait, _ := time.ParseDuration(os.Getenv("YURUNA_BACKFILL_LOKI_WAIT"))
	if wait <= 0 {
		t.Logf("run %s: set YURUNA_BACKFILL_LOKI_WAIT to also wait for Loki to answer for the backfilled lines", run)
		return
	}
	countBy := func(label, query string) map[string]int {
		t.Helper()
		var vr struct {
			Data struct {
				Result []struct {
					Metric map[string]string `json:"metric"`
					Value  [2]any            `json:"value"`
				} `json:"result"`
			} `json:"data"`
		}
		at := strconv.FormatInt(time.Now().UTC().Add(time.Minute).UnixNano(), 10)
		get(lokiBase, "/loki/api/v1/query", url.Values{"query": {query}, "time": {at}}, &vr)
		out := map[string]int{}
		for _, r := range vr.Data.Result {
			n, _ := strconv.Atoi(fmt.Sprint(r.Value[1]))
			out[r.Metric[label]] += n
		}
		return out
	}
	expected := map[string]int{}
	for _, c := range sc.hostA.cycles {
		if !c.current && !c.start.Before(horizonStart) && c.start.Before(sc.until(sc.hostA, cfg)) && !(c.hostless && !c.shareCopy) {
			expected[formatUTC(c.start)] = 1
		}
	}
	started := time.Now()
	var finals map[string]int
	for {
		finals = countBy("cycleStartUtc", fmt.Sprintf(`sum by (cycleStartUtc) (count_over_time({src="cycle",hostId=%q} | json | overallStatus=~"pass|fail|skipped" [2200h]))`, idA))
		if len(finals) >= len(expected) || time.Since(started) > wait {
			break
		}
		time.Sleep(30 * time.Second)
	}
	t.Logf("Loki answered for %d of %d backfilled cycles of host A after %s", len(finals), len(expected), time.Since(started).Round(time.Second))
	for key := range expected {
		if finals[key] != 1 {
			t.Errorf("cycle %s: Loki counts %d final lines, want 1", key, finals[key])
		}
	}
	fixed := countBy("", fmt.Sprintf(`sum(count_over_time({pool=~%q, src="event"} | json | event="step_failure" [168h]))`, poolA+"|"+poolB))
	broken := countBy("", `sum(count_over_time({pool=".+", src="event"} | json | event="step_failure" [168h]))`)
	if fixed[""] == 0 || broken[""] != 0 {
		t.Errorf("pool matcher: =~ finds %d, = finds %d", fixed[""], broken[""])
	}
}
