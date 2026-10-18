// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	// Loki answers presence questions in windows of this length. A window keeps
	// one query's series count well under Loki's per-query cap even for a host
	// that runs a short cycle every few minutes.
	lokiPresenceWindow = 7 * 24 * time.Hour
	// Lines per Loki read when paging through a host's cycle transitions.
	lokiPageLimit = 5000
	// Event lines per push, and their combined size: inside Loki's default
	// per-request limits with room to spare.
	maxEventLinesPerPush = 1000
	maxEventBytesPerPush = 3 << 20
)

// lokiBaseURL derives Loki's API root from its push URL.
func lokiBaseURL(pushURL string) string {
	return strings.TrimSuffix(pushURL, "/loki/api/v1/push")
}

// presenceWindows splits [from, to] into consecutive windows of at most
// lokiPresenceWindow.
func presenceWindows(from, to time.Time) [][2]time.Time {
	var out [][2]time.Time
	for a := from; a.Before(to); a = a.Add(lokiPresenceWindow) {
		b := a.Add(lokiPresenceWindow)
		if b.After(to) {
			b = to
		}
		out = append(out, [2]time.Time{a, b})
	}
	return out
}

// lokiCycleStreams returns the cycles of the host whose transition stream holds
// any line in [from, to]: the cycles the collector or an earlier sweep already
// wrote, if only the line that said they were running.
func (b *backfiller) lokiCycleStreams(ctx context.Context, hostID string, from, to time.Time) (map[string]bool, error) {
	return cycleKeys(b.lokiCountBy(ctx, "cycleStartUtc", fmt.Sprintf(`{src="cycle",hostId=%q}`, hostID), from, to))
}

// cycleKey is the form two spellings of one cycle start compare equal in: the
// same instant, written the way hosts write cycleStartUtc.
func cycleKey(s string) string {
	if t, ok := parseUTC(s); ok {
		return formatUTC(t)
	}
	return strings.TrimSpace(s)
}

// cycleKeys rewrites a set of cycleStartUtc values as cycle keys.
func cycleKeys(in map[string]bool, err error) (map[string]bool, error) {
	if err != nil {
		return nil, err
	}
	out := make(map[string]bool, len(in))
	for k := range in {
		out[cycleKey(k)] = true
	}
	return out, nil
}

// lokiCountBy runs `sum by (<label>) (count_over_time(<selector> [window]))` over
// [from, to], one instant query per presence window, and returns the label values
// that occur.
func (b *backfiller) lokiCountBy(ctx context.Context, label, selector string, from, to time.Time) (map[string]bool, error) {
	out := map[string]bool{}
	for _, w := range presenceWindows(from, to) {
		secs := int64(w[1].Sub(w[0]) / time.Second)
		if secs <= 0 {
			continue
		}
		q := url.Values{}
		q.Set("query", fmt.Sprintf(`sum by (%s) (count_over_time(%s [%ds]))`, label, selector, secs))
		q.Set("time", strconv.FormatInt(w[1].UnixNano(), 10))
		var vr lokiVectorResult
		if err := b.getJSON(ctx, lokiBaseURL(b.cfg.lokiPushURL)+"/loki/api/v1/query?"+q.Encode(), &vr); err != nil {
			return nil, err
		}
		for _, r := range vr.Data.Result {
			if v := r.Metric[label]; v != "" {
				out[v] = true
			}
		}
	}
	return out, nil
}

// lokiTerminalCycles returns the cycles of the host whose transition stream holds
// a final line. A stream with only its "running" line is a cycle the collector
// saw start and never saw end, typically because the proxy went down meanwhile.
func (b *backfiller) lokiTerminalCycles(ctx context.Context, hostID string, from, to time.Time) (map[string]bool, error) {
	sel := fmt.Sprintf(`{src="cycle",hostId=%q} | json | overallStatus=~"pass|fail|skipped"`, hostID)
	return cycleKeys(b.lokiCountBy(ctx, "cycleStartUtc", sel, from, to))
}

// lokiEventCycles returns the cycles of the host that already have event lines,
// whether the collector tailed them live or an earlier sweep wrote them. Live
// event streams carry cycleStartUtc only inside the line; backfilled ones carry it
// as a label too, and Loki keeps the label's value when both exist.
func (b *backfiller) lokiEventCycles(ctx context.Context, hostID string, from, to time.Time) (map[string]bool, error) {
	sel := fmt.Sprintf(`{src="event",hostId=%q} | json cycleStartUtc="cycleStartUtc"`, hostID)
	return cycleKeys(b.lokiCountBy(ctx, "cycleStartUtc", sel, from, to))
}

// lokiIncidentIDs returns the incident ids already recorded for the host.
func (b *backfiller) lokiIncidentIDs(ctx context.Context, hostID string, from, to time.Time) (map[string]bool, error) {
	sel := fmt.Sprintf(`{src="incident",hostId=%q} | json incidentId="incidentId"`, hostID)
	return b.lokiCountBy(ctx, "incidentId", sel, from, to)
}

// lokiEntry is one Loki line with its timestamp.
type lokiEntry struct {
	At   time.Time
	Line string
}

// lokiRange pages forward through every line matching query in [from, to), one
// presence window at a time so that no single read spans the whole horizon.
func (b *backfiller) lokiRange(ctx context.Context, query string, from, to time.Time) ([]lokiEntry, error) {
	var out []lokiEntry
	for _, w := range presenceWindows(from, to) {
		start := w[0]
		for start.Before(w[1]) {
			q := url.Values{}
			q.Set("query", query)
			q.Set("start", strconv.FormatInt(start.UnixNano(), 10))
			q.Set("end", strconv.FormatInt(w[1].UnixNano(), 10))
			q.Set("limit", strconv.Itoa(lokiPageLimit))
			q.Set("direction", "forward")
			var lr lokiStreamsResult
			if err := b.getJSON(ctx, lokiBaseURL(b.cfg.lokiPushURL)+"/loki/api/v1/query_range?"+q.Encode(), &lr); err != nil {
				return nil, err
			}
			var page []lokiEntry
			for _, st := range lr.Data.Result {
				for _, v := range st.Values {
					ns, err := strconv.ParseInt(v[0], 10, 64)
					if err != nil {
						continue
					}
					page = append(page, lokiEntry{At: time.Unix(0, ns).UTC(), Line: v[1]})
				}
			}
			out = append(out, page...)
			if len(page) < lokiPageLimit {
				break
			}
			latest := page[0].At
			for _, e := range page {
				if e.At.After(latest) {
					latest = e.At
				}
			}
			start = latest.Add(time.Nanosecond)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out, nil
}

// firstPresence returns when the collector first saw the host, from its earliest
// src=presence line in [from, to]. Before that moment no live incident could have
// been raised for the host; after it, the collector owns them. With no line in
// range the host has been watched for longer than the window, and from is
// returned so that nothing is replayed.
func (b *backfiller) firstPresence(ctx context.Context, hostID string, from, to time.Time) (time.Time, error) {
	q := url.Values{}
	q.Set("query", fmt.Sprintf(`{src="presence",hostId=%q}`, hostID))
	q.Set("start", strconv.FormatInt(from.UnixNano(), 10))
	q.Set("end", strconv.FormatInt(to.UnixNano(), 10))
	q.Set("limit", "1")
	q.Set("direction", "forward")
	var lr lokiStreamsResult
	if err := b.getJSON(ctx, lokiBaseURL(b.cfg.lokiPushURL)+"/loki/api/v1/query_range?"+q.Encode(), &lr); err != nil {
		return time.Time{}, err
	}
	earliest := time.Time{}
	for _, st := range lr.Data.Result {
		for _, v := range st.Values {
			if ns, err := strconv.ParseInt(v[0], 10, 64); err == nil {
				t := time.Unix(0, ns).UTC()
				if earliest.IsZero() || t.Before(earliest) {
					earliest = t
				}
			}
		}
	}
	if earliest.IsZero() {
		return from, nil
	}
	return earliest, nil
}

// cycleLinePayloads builds the transition lines the collector would have pushed
// for a cycle it watched from start to end: "running" at the start, then the final
// status at the end, through the same builder the live path uses. The folder URL
// is spelled as status.json spelled it at each moment.
func cycleLinePayloads(h activeHost, identity string, rec cycleRecord, wantRunning bool) []map[string]any {
	var out []map[string]any
	if wantRunning {
		running := &hostStatus{
			HostId: h.HostID, Host: h.HostType, CycleStartUtc: rec.CycleStartUtc, OverallStatus: "running",
			StartedAt: rec.CycleStartUtc, CycleFolderUrl: "log/" + identity + ".incomplete/",
		}
		out = append(out, cycleTransitionPayload(h.Pool, running, h.BaseURL, rec.Start))
	}
	final := &hostStatus{
		HostId: h.HostID, Host: h.HostType, CycleStartUtc: rec.CycleStartUtc, OverallStatus: rec.Status,
		StartedAt: rec.CycleStartUtc, FinishedAt: formatUTC(rec.End), CycleFolderUrl: "log/" + identity + "/",
	}
	final.LastFailure.FailureClass = rec.FailureClass
	out = append(out, cycleTransitionPayload(h.Pool, final, h.BaseURL, rec.End))
	return out
}

// eventPayloads splits a cycle's event lines into Loki pushes. Each cycle gets a
// stream of its own (the cycleStartUtc label): a host's live event stream only
// accepts entries up to about an hour older than its newest, and these are days
// older. The lines themselves are exactly what the live tail sends.
func eventPayloads(h activeHost, rec cycleRecord) []map[string]any {
	stream := map[string]string{"pool": h.Pool, "hostId": h.HostID, "src": "event", "cycleStartUtc": rec.CycleStartUtc}
	var out []map[string]any
	var values [][]string
	size := 0
	flush := func() {
		if len(values) == 0 {
			return
		}
		out = append(out, map[string]any{"streams": []map[string]any{{"stream": stream, "values": values}}})
		values, size = nil, 0
	}
	for i, ln := range rec.Lines {
		if len(values) >= maxEventLinesPerPush || size+len(ln) > maxEventBytesPerPush {
			flush()
		}
		values = append(values, []string{strconv.FormatInt(rec.Stamps[i], 10), ln})
		size += len(ln)
	}
	flush()
	return out
}

// replayHostIncidents applies the collector's per-host incident rule
// (evaluateIncidents) to a host's failed cycles after the fact. A fail joins the
// window at its own time and the window keeps the fails newer than that time
// minus win. An incident opens when a fail brings the window to n, and resolves
// when the newest fail in it ages out, at that fail's time plus win -- the
// first poll at which the live collector would have found the window empty. A
// fail arriving at exactly that moment keeps the incident open, as it does live:
// the collector counts a poll's fails before it evaluates the window.
// Pool-wide incidents are not replayed: they correlate hosts, and hosts are
// backfilled one at a time.
func replayHostIncidents(hostID, pool string, fails []failRec, n int, win time.Duration) []incidentEvent {
	sort.SliceStable(fails, func(i, j int) bool { return fails[i].t.Before(fails[j].t) })
	var events []incidentEvent
	var window []failRec
	var inc *incidentState
	resolve := func(at time.Time) {
		events = append(events, incidentEvent{hostId: hostID, id: inc.id, startedAt: inc.startedAt, peak: inc.peak, now: at, classHist: inc.peakClassHist, dominantClass: inc.dominantClass, poolLabel: pool})
		inc = nil
	}
	for _, f := range fails {
		if inc != nil && len(window) > 0 {
			if expiry := window[len(window)-1].t.Add(win); expiry.Before(f.t) {
				resolve(expiry)
			}
		}
		cutoff := f.t.Add(-win)
		kept := window[:0]
		for _, r := range window {
			if r.t.After(cutoff) {
				kept = append(kept, r)
			}
		}
		window = append(kept, f)
		count := len(window)
		switch {
		case inc == nil && count >= n:
			hist := classHistogram(window)
			dom := dominantClass(hist)
			if dom == "" {
				dom = "unknown"
			}
			inc = &incidentState{id: incidentID(hostID, window[0].t), startedAt: window[0].t, peak: count, peakClassHist: hist, dominantClass: dom}
			events = append(events, incidentEvent{open: true, hostId: hostID, id: inc.id, count: count, startedAt: window[0].t, now: f.t, classHist: hist, dominantClass: dom, poolLabel: pool})
		case inc != nil && count > inc.peak:
			inc.peak = count
			inc.peakClassHist = classHistogram(window)
			inc.dominantClass = dominantClass(inc.peakClassHist)
			if inc.dominantClass == "" {
				inc.dominantClass = "unknown"
			}
		}
	}
	if inc != nil && len(window) > 0 {
		resolve(window[len(window)-1].t.Add(win))
	}
	return events
}

// incidentPayload is one replayed incident line. Each incident gets a stream of
// its own (the incidentId label), for the same reason event lines do.
func incidentPayload(ev incidentEvent) map[string]any {
	stream, line := incidentStreamLine(ev.poolLabel, ev)
	stream["incidentId"] = ev.id
	return map[string]any{"streams": []map[string]any{{
		"stream": stream,
		"values": [][]string{{strconv.FormatInt(ev.now.UnixNano(), 10), string(line)}},
	}}}
}

// failsFromTransitions reads the failed cycles out of a host's transition lines,
// one per cycle key, timed when the line was written: the moment the collector
// counted the fail, which is the time its incident rule used.
func failsFromTransitions(entries []lokiEntry) map[string]failRec {
	out := map[string]failRec{}
	for _, e := range entries {
		var l struct {
			CycleStartUtc string `json:"cycleStartUtc"`
			OverallStatus string `json:"overallStatus"`
			FailureClass  string `json:"failureClass"`
		}
		if json.Unmarshal([]byte(e.Line), &l) != nil || l.OverallStatus != "fail" {
			continue
		}
		key := cycleKey(l.CycleStartUtc)
		if _, ok := out[key]; ok {
			continue
		}
		cls := l.FailureClass
		if cls == "" {
			cls = "unknown"
		}
		out[key] = failRec{t: e.At, class: cls}
	}
	return out
}

// mergeFails adds the failed cycles the index knows of to those Loki answered
// for, keeps the ones that failed before the given moment, and returns them in
// time order. A backfilled fail is timed at the cycle's end, the timestamp its
// line was written with.
func mergeFails(fromLoki map[string]failRec, outcomes map[string]cycleOutcome, before time.Time) []failRec {
	all := map[string]failRec{}
	for k, f := range fromLoki {
		all[k] = f
	}
	for _, o := range outcomes {
		key := cycleKey(o.CycleStartUtc)
		if _, ok := all[key]; ok || o.Status != "fail" {
			continue
		}
		cls := o.FailureClass
		if cls == "" {
			cls = "unknown"
		}
		all[key] = failRec{t: o.End, class: cls}
	}
	var out []failRec
	for _, f := range all {
		if f.t.Before(before) {
			out = append(out, f)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].t.Before(out[j].t) })
	return out
}
