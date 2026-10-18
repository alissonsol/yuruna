// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

const (
	bfHostA = "42a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
	bfHostB = "42b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
)

func bfAt(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t.UTC()
}

// The backfill works only on hosts the collector reaches now, under the pool label
// the collector stamps on their live data.
func TestParsePoolStatusKeepsReachableHostsUnderTheirLivePool(t *testing.T) {
	doc := `{"pool":"lab","hosts":[
	 {"hostId":"` + bfHostA + `","baseUrl":"http://192.0.2.10:8080/","reachable":true,"poolId":"red",
	  "status":{"host":"host.windows.hyper-v","cycleStartUtc":"2026-10-02T11:40:00Z","overallStatus":"running"}},
	 {"hostId":"` + bfHostB + `","baseUrl":"http://192.0.2.11:8080","reachable":true,
	  "status":{"host":"host.macos.utm","cycleStartUtc":"2026-10-02T11:00:00Z","overallStatus":"pass"}},
	 {"hostId":"42c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3","baseUrl":"http://192.0.2.12:8080","reachable":false,"status":{}},
	 {"hostId":"42d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4","baseUrl":"http://192.0.2.13:8080","reachable":true},
	 {"hostId":"42E5E5E5E5E5E5E5E5E5E5E5E5E5E5E5","baseUrl":"http://192.0.2.14:8080","reachable":true,"status":{}},
	 {"hostId":"42f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6","baseUrl":"","reachable":true,"status":{}}
	]}`
	hosts, err := parsePoolStatus([]byte(doc))
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 2 {
		t.Fatalf("want the two reachable, well-formed hosts; got %+v", hosts)
	}
	a, b := hosts[0], hosts[1]
	if a.HostID != bfHostA || a.BaseURL != "http://192.0.2.10:8080" || a.Pool != "red" || a.HostType != "host.windows.hyper-v" ||
		!a.CurrentStart.Equal(bfAt("2026-10-02T11:40:00Z")) || a.CurrentStatus != "running" {
		t.Errorf("host A read wrong: %+v", a)
	}
	if b.HostID != bfHostB || b.Pool != "lab" {
		t.Errorf("a host with no registered pool takes the collector's: %+v", b)
	}
	if _, err := parsePoolStatus([]byte("not json")); err == nil {
		t.Error("an unreadable document must be an error, not an empty pool")
	}
	none, err := parsePoolStatus([]byte(`{"hosts":[{"hostId":"` + bfHostA + `","baseUrl":"http://x","reachable":true,"status":{}}]}`))
	if err != nil || len(none) != 1 || none[0].Pool != defaultPool {
		t.Errorf("no pool anywhere must fall back to the default label: %+v %v", none, err)
	}
}

// Times are UTC both ways, and a time without a zone is refused rather than guessed.
func TestParseUTCRefusesZonelessTimes(t *testing.T) {
	if got, ok := parseUTC("2026-10-02T09:00:00-03:00"); !ok || !got.Equal(bfAt("2026-10-02T12:00:00Z")) || got.Location() != time.UTC {
		t.Errorf("offset time not converted to UTC: %v %v", got, ok)
	}
	if _, ok := parseUTC("2026-10-02T12:00:00"); ok {
		t.Error("a zoneless time must be refused")
	}
	if got, ok := parseUTC("2026-10-02T12:00:00.1234567Z"); !ok || got.Nanosecond() == 0 {
		t.Errorf("fractional seconds lost: %v %v", got, ok)
	}
	if formatUTC(bfAt("2026-10-02T09:00:00-03:00")) != "2026-10-02T12:00:00Z" {
		t.Error("formatUTC must write the host spelling")
	}
	if cycleKey("2026-10-02T09:00:00-03:00") != cycleKey("2026-10-02T12:00:00Z") {
		t.Error("two spellings of one instant must share a cycle key")
	}
}

// The listing parser reads only hrefs, unescaped, and sorts names into cycle
// leaves and history buckets.
func TestParseListingReadsHrefsOnly(t *testing.T) {
	body := `<html><body>
<a href="../">..</a>
<a href="history.2026-09-30/">` + "\u2068" + `history.2026-09-30/` + "\u2069" + `</a>
<a href="001900.2026-10-01.10-00-00.` + bfHostA + `/">` + "\u2068" + `x` + "\u2069" + `</a>
<a href="001901.2026-10-01.11-00-00.` + bfHostA + `.incomplete/">x</a>
<a href="001899.2026-10-01.09-00-00.` + bfHostA + `.aborted.2026-10-01T09-30-00Z/">x</a>
<a href="status.json">status.json</a>
<a href="notes%20folder/">notes folder/</a>
<a href="history.2026-09-29%2F..%2F/">trap</a>
</body></html>`
	leaves, buckets := parseListing(body)
	wantLeaves := []string{
		"001900.2026-10-01.10-00-00." + bfHostA,
		"001901.2026-10-01.11-00-00." + bfHostA + ".incomplete",
		"001899.2026-10-01.09-00-00." + bfHostA + ".aborted.2026-10-01T09-30-00Z",
	}
	if !reflect.DeepEqual(leaves, wantLeaves) {
		t.Errorf("leaves: got %q want %q", leaves, wantLeaves)
	}
	if !reflect.DeepEqual(buckets, []string{"history.2026-09-30"}) {
		t.Errorf("buckets: got %q", buckets)
	}
}

func TestCycleFolderFromLeaf(t *testing.T) {
	cf, ok := cycleFolderFromLeaf("001901.2026-10-01.11-00-00."+bfHostA+".incomplete", bfHostA, "log/history.2026-10-02/")
	if !ok || cf.Identity != "001901.2026-10-01.11-00-00."+bfHostA || !cf.Start.Equal(bfAt("2026-10-01T11:00:00Z")) ||
		cf.RelDir != "log/history.2026-10-02/001901.2026-10-01.11-00-00."+bfHostA+".incomplete/" {
		t.Errorf("leaf read wrong: %+v %v", cf, ok)
	}
	if _, ok := cycleFolderFromLeaf("001901.2026-10-01.11-00-00."+bfHostB, bfHostA, "log/"); ok {
		t.Error("another host's leaf must be refused")
	}
	if _, ok := cycleFolderFromLeaf("001901.2026-13-01.11-00-00."+bfHostA, bfHostA, "log/"); ok {
		t.Error("an impossible date must be refused")
	}
}

// On a host that copies to the pool share the top-level index can list a folder
// the host also keeps in a bucket; the bucket copy is the one it serves.
func TestMergeFolderPrefersTheBucketCopy(t *testing.T) {
	leaf := "001900.2026-10-01.10-00-00." + bfHostA
	m := map[string]cycleFolder{}
	top, _ := cycleFolderFromLeaf(leaf, bfHostA, "log/")
	bucket, _ := cycleFolderFromLeaf(leaf, bfHostA, "log/history.2026-10-02/")
	mergeFolder(m, top)
	mergeFolder(m, bucket)
	mergeFolder(m, top)
	if got := m[top.Identity].RelDir; got != bucket.RelDir {
		t.Errorf("bucket copy lost: %q", got)
	}
}

func TestStatusForOutcomeMatchesTheRunner(t *testing.T) {
	cases := map[[2]string]string{
		{"pass", ""}:                        "pass",
		{"fail", "step 3"}:                  "fail",
		{"aborted", "host refresh"}:         "skipped",
		{"aborted", "Host Refresh pending"}: "skipped",
		{"aborted", "watchdog"}:             "fail",
		{"unknown", ""}:                     "fail",
		{"", ""}:                            "fail",
	}
	for in, want := range cases {
		if got := statusForOutcome(in[0], in[1]); got != want {
			t.Errorf("statusForOutcome(%q,%q) = %q, want %q", in[0], in[1], got, want)
		}
	}
}

func eventsFileOf(lines ...string) []byte {
	return []byte(strings.Join(lines, "\r\n") + "\r\n")
}

func TestReconstructCycleFromItsEventFile(t *testing.T) {
	cf, _ := cycleFolderFromLeaf("001900.2026-10-01.10-00-00."+bfHostA, bfHostA, "log/")
	data := eventsFileOf(
		`{"event":"cycle_start","timestamp":"2026-10-01T10:00:00Z","cycleStartUtc":"2026-10-01T10:00:00Z","hostname":"lab-pc","cycleFolder":"x"}`,
		`{"event":"step.start","name":"install"}`,
		`{"event":"step_failure","timestamp":"2026-10-01T10:20:00.5Z","failureClass":"network_timeout","cycleStartUtc":"2026-10-01T10:00:00Z"}`,
		`not json at all`,
		``,
		`{"event":"step_failure","timestamp":"2026-10-01T10:30:00Z","failureClass":"guest_boot"}`,
		`{"event":"cycle_end","timestamp":"2026-10-01T10:40:00Z","outcome":"fail","reason":"step 4"}`,
	)
	rec := reconstructCycle(cf, data)
	if rec.CycleStartUtc != "2026-10-01T10:00:00Z" || !rec.Start.Equal(bfAt("2026-10-01T10:00:00Z")) || !rec.End.Equal(bfAt("2026-10-01T10:40:00Z")) {
		t.Errorf("times wrong: %+v", rec)
	}
	if rec.Status != "fail" || rec.FailureClass != "guest_boot" {
		t.Errorf("a failed cycle takes the class of its last step failure: %q %q", rec.Status, rec.FailureClass)
	}
	if len(rec.Lines) != 5 || len(rec.Stamps) != 5 {
		t.Fatalf("want the five JSON lines; got %d lines %d stamps", len(rec.Lines), len(rec.Stamps))
	}
	if strings.Contains(rec.Lines[0], "lab-pc") || strings.Contains(rec.Lines[0], "cycleFolder") || strings.Contains(rec.Lines[0], "\r") {
		t.Errorf("lines must be redacted and trimmed as the live tail sends them: %q", rec.Lines[0])
	}
	if rec.Stamps[1] != bfAt("2026-10-01T10:00:00Z").UnixNano() {
		t.Error("a line with no timestamp takes the previous line's")
	}
	if rec.Stamps[2] != bfAt("2026-10-01T10:20:00.5Z").UnixNano() {
		t.Error("an event's own timestamp is its Loki timestamp")
	}

	killed := reconstructCycle(cf, eventsFileOf(`{"event":"cycle_start","timestamp":"2026-10-01T10:00:00Z","cycleStartUtc":"2026-10-01T10:00:00Z"}`, `{"event":"step_end","timestamp":"2026-10-01T10:05:00Z"}`))
	if killed.Status != "fail" || killed.FailureClass != "unknown" || !killed.End.Equal(bfAt("2026-10-01T10:05:00Z")) {
		t.Errorf("a cycle with no cycle_end is a failure ending at its last event: %+v", killed)
	}

	refreshed := reconstructCycle(cf, eventsFileOf(`{"event":"cycle_end","timestamp":"2026-10-01T10:02:00Z","outcome":"aborted","reason":"host refresh"}`))
	if refreshed.Status != "skipped" || refreshed.FailureClass != "" || refreshed.CycleStartUtc != "2026-10-01T10:00:00Z" {
		t.Errorf("a refresh-aborted cycle is skipped and keyed by its folder: %+v", refreshed)
	}

	legacy := reconstructCycle(cf, eventsFileOf(`{"event":"cycle_start","timestamp":"2026-10-01T10:00:01Z","cycleId":"2026-10-01T10:00:00Z"}`, `{"event":"cycle_end","timestamp":"2026-10-01T10:30:00Z","outcome":"pass"}`))
	if legacy.CycleStartUtc != "2026-10-01T10:00:00Z" || legacy.Status != "pass" {
		t.Errorf("legacy cycleId must key the cycle: %+v", legacy)
	}

	backwards := reconstructCycle(cf, eventsFileOf(`{"event":"cycle_end","timestamp":"2026-10-01T09:00:00Z","outcome":"pass"}`))
	if backwards.End.Before(backwards.Start) {
		t.Error("a cycle must not end before it starts")
	}

	huge := reconstructCycle(cf, eventsFileOf(`{"event":"x","pad":"`+strings.Repeat("a", maxBackfillLineBytes)+`"}`, `{"event":"cycle_end","timestamp":"2026-10-01T10:30:00Z","outcome":"pass"}`))
	if len(huge.Lines) != 1 {
		t.Errorf("a line Loki would refuse must be dropped, not sent: %d lines", len(huge.Lines))
	}
}

// A backfilled transition is built by the collector's own builder, so it carries
// exactly the labels and fields a watched cycle does.
func TestCycleLinePayloadsMatchTheLiveShape(t *testing.T) {
	h := activeHost{HostID: bfHostA, BaseURL: "http://192.0.2.10:8080", Pool: "red", HostType: "host.windows.hyper-v"}
	rec := cycleRecord{CycleStartUtc: "2026-10-01T10:00:00Z", Start: bfAt("2026-10-01T10:00:00Z"), End: bfAt("2026-10-01T10:40:00Z"), Status: "fail", FailureClass: "guest_boot"}
	identity := "001900.2026-10-01.10-00-00." + bfHostA
	payloads := cycleLinePayloads(h, identity, rec, true)
	if len(payloads) != 2 {
		t.Fatalf("want running + final; got %d", len(payloads))
	}
	type line struct {
		labels map[string]string
		ts     string
		body   map[string]string
	}
	read := func(p map[string]any) line {
		st := p["streams"].([]map[string]any)[0]
		v := st["values"].([][]string)[0]
		var body map[string]string
		if err := json.Unmarshal([]byte(v[1]), &body); err != nil {
			t.Fatal(err)
		}
		return line{labels: st["stream"].(map[string]string), ts: v[0], body: body}
	}
	running, final := read(payloads[0]), read(payloads[1])
	wantLabels := map[string]string{"pool": "red", "hostId": bfHostA, "cycleStartUtc": "2026-10-01T10:00:00Z", "src": "cycle"}
	if !reflect.DeepEqual(running.labels, wantLabels) || !reflect.DeepEqual(final.labels, wantLabels) {
		t.Errorf("labels differ from the live stream: %v / %v", running.labels, final.labels)
	}
	if running.ts != fmt.Sprint(rec.Start.UnixNano()) || final.ts != fmt.Sprint(rec.End.UnixNano()) {
		t.Errorf("running is stamped at the start and the result at the end: %s %s", running.ts, final.ts)
	}
	if running.body["overallStatus"] != "running" || running.body["finishedAt"] != "" || running.body["cycleFolderUrl"] != "log/"+identity+".incomplete/" {
		t.Errorf("running line wrong: %v", running.body)
	}
	if final.body["overallStatus"] != "fail" || final.body["failureClass"] != "guest_boot" || final.body["finishedAt"] != "2026-10-01T10:40:00Z" ||
		final.body["cycleFolderUrl"] != "log/"+identity+"/" || final.body["baseUrl"] != h.BaseURL || final.body["hostType"] != h.HostType ||
		final.body["startedAt"] != "2026-10-01T10:00:00Z" {
		t.Errorf("final line wrong: %v", final.body)
	}
	if _, ok := final.body["hostname"]; ok {
		t.Error("the pool view is hostname-free")
	}
	if got := cycleLinePayloads(h, identity, rec, false); len(got) != 1 {
		t.Errorf("a cycle the collector saw start gets only its result: %d", len(got))
	}
}

func TestEventPayloadsUseOneStreamPerCycleInBoundedPushes(t *testing.T) {
	h := activeHost{HostID: bfHostA, Pool: "red"}
	rec := cycleRecord{CycleStartUtc: "2026-10-01T10:00:00Z"}
	for i := 0; i < maxEventLinesPerPush+5; i++ {
		rec.Lines = append(rec.Lines, fmt.Sprintf(`{"event":"e","i":%d}`, i))
		rec.Stamps = append(rec.Stamps, int64(i))
	}
	payloads := eventPayloads(h, rec)
	if len(payloads) != 2 {
		t.Fatalf("want two pushes; got %d", len(payloads))
	}
	total := 0
	for _, p := range payloads {
		st := p["streams"].([]map[string]any)[0]
		if !reflect.DeepEqual(st["stream"], map[string]string{"pool": "red", "hostId": bfHostA, "src": "event", "cycleStartUtc": "2026-10-01T10:00:00Z"}) {
			t.Errorf("stream labels wrong: %v", st["stream"])
		}
		total += len(st["values"].([][]string))
	}
	if total != len(rec.Lines) {
		t.Errorf("lines lost across pushes: %d of %d", total, len(rec.Lines))
	}
	big := cycleRecord{CycleStartUtc: rec.CycleStartUtc}
	for i := 0; i < 40; i++ {
		big.Lines = append(big.Lines, strings.Repeat("x", 100<<10))
		big.Stamps = append(big.Stamps, int64(i))
	}
	for _, p := range eventPayloads(h, big) {
		size := 0
		for _, v := range p["streams"].([]map[string]any)[0]["values"].([][]string) {
			size += len(v[1])
		}
		if size > maxEventBytesPerPush {
			t.Errorf("a push exceeded the byte bound: %d", size)
		}
	}
}

func TestBackfillConfigRefusesUnsafeFlags(t *testing.T) {
	if _, err := parseBackfillFlags(nil); err != nil {
		t.Fatalf("the defaults must be valid: %v", err)
	}
	cfg, err := parseBackfillFlags([]string{"--language=pt-BR", "--allow-pseudo-locale=false", "-once", "-horizon", "48h"})
	if err != nil || !cfg.once || cfg.horizon != 48*time.Hour {
		t.Fatalf("flags not read: %+v %v", cfg, err)
	}
	for _, bad := range [][]string{
		{"-horizon", "0s"}, {"-sweep-interval", "0s"}, {"-host-concurrency", "0"}, {"-cycles-per-minute", "0"},
		{"-sample-step", "5m"}, {"-sample-step", "0s"}, {"-state-dir", " "}, {"-incident-fails", "0"}, {"stray"}, {"-no-such-flag"},
	} {
		if _, err := parseBackfillFlags(bad); err == nil {
			t.Errorf("flags %q must be refused", bad)
		}
	}
}

func TestPacerSpacesCallersAndHonorsSlowHosts(t *testing.T) {
	now := bfAt("2026-10-02T12:00:00Z")
	var slept []time.Duration
	p := &pacer{interval: 2 * time.Second, now: func() time.Time { return now }, sleep: func(_ context.Context, d time.Duration) bool {
		slept = append(slept, d)
		now = now.Add(d)
		return true
	}}
	ctx := context.Background()
	p.wait(ctx)
	p.wait(ctx)
	p.atLeast(10 * time.Second)
	p.wait(ctx)
	p.reserve(ctx, 5*time.Second)
	p.wait(ctx)
	want := []time.Duration{2 * time.Second, 10 * time.Second, 2 * time.Second, 5 * time.Second}
	if !reflect.DeepEqual(slept, want) {
		t.Errorf("sleeps: got %v want %v", slept, want)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	q := &pacer{interval: time.Second, now: func() time.Time { return now }, sleep: sleepCtx}
	if q.wait(cancelled) {
		t.Error("a cancelled context must stop the wait")
	}
}

// A host is listed when it never was, once the interval has passed, and when the
// recorded time is ahead of the clock; a deferral holds every listing back until
// it ends, unless it reaches further than one deferral from now.
func TestHostListingScheduleAndDeferral(t *testing.T) {
	now := bfAt("2026-10-02T12:00:00Z")
	hs := &backfillHostState{}
	if !hs.listingDue(now) || hs.hostDeferred(now) {
		t.Fatal("a host never listed must be listed, and is not deferred")
	}
	hs.ListedAt = now
	if hs.listingDue(now.Add(hostListingInterval - time.Second)) {
		t.Error("a host must not be listed again inside the interval")
	}
	if !hs.listingDue(now.Add(hostListingInterval)) {
		t.Error("a host must be listed again once the interval has passed")
	}
	if !hs.listingDue(now.Add(-time.Hour)) {
		t.Error("a listing time ahead of the clock must not hold the host back")
	}
	hs.ListingDeferredUntil = now.Add(listingDeferral)
	for _, at := range []time.Time{now.Add(hostListingInterval), now.Add(listingDeferral - time.Second)} {
		if hs.listingDue(at) || !hs.hostDeferred(at) {
			t.Errorf("at %v the deferral must hold the host back", at)
		}
	}
	if hs.hostDeferred(now.Add(listingDeferral)) || !hs.listingDue(now.Add(listingDeferral)) {
		t.Error("a host must be listed again once its deferral is over")
	}
	hs.ListingDeferredUntil = now.Add(3 * listingDeferral)
	if hs.hostDeferred(now) {
		t.Error("a deferral further away than one deferral was set under another clock and must not be honored")
	}
}
