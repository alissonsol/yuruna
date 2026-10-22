// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	// coverageStep is both the step of the coverage query and the width of the
	// window each step looks back over, so every moment falls in exactly one
	// window and a window either holds live samples or holds none.
	coverageStep = 5 * time.Minute
	// Prometheus refuses a range query of more than 11,000 points per series; a
	// 30-day chunk at a 5-minute step is 8,640.
	coverageChunkSteps = int64(30 * 24 * time.Hour / coverageStep)
	// Samples per remote-write request.
	maxSamplesPerWrite = 2000
	// The state-timeline panel draws the last sample within Prometheus' 5-minute
	// lookback, so backfilled samples must be closer together than that.
	defaultSampleStep = 2 * time.Minute
)

// timelineCycle is one cycle as the timeline draws it: running from Start to End,
// then its final code until the next cycle starts. Key is its cycle key.
type timelineCycle struct {
	Key        string
	Start, End time.Time
	Code       int
	// A status summary establishes the completed interval, but does not say
	// what happened after it. Do not hold its final verdict into an unknown gap.
	NoFinalHold bool
}

// statusTimelineCode is the yuruna_pool_host_status value of a final status, the
// same mapping hostView.statusCode applies to a live host.
func statusTimelineCode(status string) int {
	switch status {
	case "pass":
		return 2
	case "fail":
		return 3
	default:
		return 4
	}
}

// timelineFromTransitions turns a host's final transition lines into timeline
// cycles, one per cycleStartUtc, ordered by start.
func timelineFromTransitions(entries []lokiEntry) []timelineCycle {
	seen := map[string]bool{}
	var out []timelineCycle
	for _, e := range entries {
		var l struct {
			CycleStartUtc string `json:"cycleStartUtc"`
			StartedAt     string `json:"startedAt"`
			FinishedAt    string `json:"finishedAt"`
			OverallStatus string `json:"overallStatus"`
		}
		if json.Unmarshal([]byte(e.Line), &l) != nil || seen[l.CycleStartUtc] {
			continue
		}
		start, ok := parseUTC(l.StartedAt)
		if !ok {
			if start, ok = parseUTC(l.CycleStartUtc); !ok {
				continue
			}
		}
		end, ok := parseUTC(l.FinishedAt)
		if !ok || end.Before(start) {
			end = start
		}
		seen[l.CycleStartUtc] = true
		out = append(out, timelineCycle{Key: cycleKey(l.CycleStartUtc), Start: start, End: end, Code: statusTimelineCode(l.OverallStatus)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Start.Before(out[j].Start) })
	return out
}

// mergeTimeline adds the cycles the index knows the outcome of to those Loki
// answered for. Loki's line wins where both have a cycle: it is what the panels
// show.
func mergeTimeline(fromLoki []timelineCycle, outcomes map[string]cycleOutcome) []timelineCycle {
	have := map[string]bool{}
	out := append([]timelineCycle(nil), fromLoki...)
	for _, c := range fromLoki {
		have[c.Key] = true
	}
	for _, o := range outcomes {
		key := cycleKey(o.CycleStartUtc)
		if have[key] {
			continue
		}
		have[key] = true
		out = append(out, timelineCycle{Key: key, Start: o.Start, End: o.End, Code: statusTimelineCode(o.Status)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Start.Before(out[j].Start) })
	return out
}

// timelineFromHistory accepts only completed, timestamped intervals. The
// collector's snapshot is sufficient to draw these intervals even when the
// host's log directories cannot be read, but cannot recreate its event log.
func timelineFromHistory(history []cycleVerdict, now time.Time) []timelineCycle {
	var out []timelineCycle
	seen := map[string]bool{}
	for _, row := range history {
		if row.OverallStatus != "pass" && row.OverallStatus != "fail" && row.OverallStatus != "skipped" {
			continue
		}
		start, startOK := parseUTC(row.CycleStartUtc)
		end, endOK := parseUTC(row.FinishedAt)
		key := cycleKey(row.CycleStartUtc)
		if !startOK || !endOK || end.Before(start) || end.After(now) || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, timelineCycle{Key: key, Start: start, End: end, Code: statusTimelineCode(row.OverallStatus), NoFinalHold: true})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Start.Before(out[j].Start) })
	return out
}

// mergeTimelineHistory fills only cycles missing from Loki and the local index;
// their reconstructed events remain authoritative when the summary disagrees.
func mergeTimelineHistory(cycles []timelineCycle, history []cycleVerdict, now time.Time) []timelineCycle {
	have := map[string]bool{}
	for _, cycle := range cycles {
		have[cycle.Key] = true
	}
	for _, cycle := range timelineFromHistory(history, now) {
		if !have[cycle.Key] {
			cycles = append(cycles, cycle)
		}
	}
	sort.Slice(cycles, func(i, j int) bool { return cycles[i].Start.Before(cycles[j].Start) })
	return cycles
}

// timelineCodeAt is the host's status code at t: running inside a cycle, then
// the cycle's final code for at most hold after it ended. False before the first
// known cycle and once the hold has run out.
func timelineCodeAt(cycles []timelineCycle, t time.Time, hold time.Duration) (int, bool) {
	i := sort.Search(len(cycles), func(i int) bool { return cycles[i].Start.After(t) }) - 1
	if i < 0 {
		return 0, false
	}
	if t.Before(cycles[i].End) {
		return 1, true
	}
	if cycles[i].NoFinalHold {
		hold = 0
	}
	if t.After(cycles[i].End.Add(hold)) {
		return 0, false
	}
	return cycles[i].Code, true
}

// promSample is one sample: Unix milliseconds and a value.
type promSample struct {
	T int64
	V float64
}

// promSeries is one series: labels sorted by name, samples in time order.
type promSeries struct {
	Labels  [][2]string
	Samples []promSample
}

// hostStatusLabels are the labels of the live yuruna_pool_host_status series --
// the three the collector writes plus the job and instance the scrape adds -- so
// a backfilled sample continues the same series rather than starting a twin.
func hostStatusLabels(pool, hostID string) [][2]string {
	labels := [][2]string{
		{"__name__", "yuruna_pool_host_status"},
		{"hostId", hostID},
		{"hostIdDashed", dashedHostID(hostID)},
		{"instance", "localhost:9400"},
		{"job", "pool-aggregator-service"},
		{"pool", pool},
	}
	sort.Slice(labels, func(i, j int) bool { return labels[i][0] < labels[j][0] })
	return labels
}

// firstCoverageStep is the first evaluation time after from on the coverage grid:
// a multiple of coverageStep, so that the coverage query and uncoveredSteps name
// the same windows whatever moment from is.
func firstCoverageStep(from time.Time) int64 {
	step := int64(coverageStep / time.Second)
	return (from.Unix()/step + 1) * step
}

// uncoveredSteps returns the coverage-query evaluation times in [from, to] at which
// the host's series has no sample in the preceding window.
func uncoveredSteps(from, to time.Time, covered map[int64]bool) []int64 {
	step := int64(coverageStep / time.Second)
	var out []int64
	for t := firstCoverageStep(from); t <= to.Unix(); t += step {
		if !covered[t] {
			out = append(out, t)
		}
	}
	return out
}

// timelineSamples places a sample every sampleStep inside each uncovered window
// (t-coverageStep, t], valued from the host's cycles. The grid is aligned to the
// epoch, so a second run computes the same timestamps.
func timelineSamples(cycles []timelineCycle, uncovered []int64, sampleStep, hold time.Duration) []promSample {
	stepMs := sampleStep.Milliseconds()
	windowMs := coverageStep.Milliseconds()
	var out []promSample
	for _, end := range uncovered {
		endMs := end * 1000
		for t := ((endMs-windowMs)/stepMs + 1) * stepMs; t <= endMs; t += stepMs {
			code, ok := timelineCodeAt(cycles, time.UnixMilli(t).UTC(), hold)
			if !ok {
				continue
			}
			out = append(out, promSample{T: t, V: float64(code)})
		}
	}
	// A summary's final status is known only at its completion time, which
	// usually falls between grid points. Preserve that observation without
	// extending it into an unknown interval or a window the collector covers.
	for i, cycle := range cycles {
		if !cycle.NoFinalHold || (i+1 < len(cycles) && !cycles[i+1].Start.After(cycle.End)) {
			continue
		}
		at := cycle.End.UnixMilli()
		window := sort.Search(len(uncovered), func(i int) bool { return uncovered[i]*1000 >= at })
		if window == len(uncovered) || at <= uncovered[window]*1000-windowMs {
			continue
		}
		pos := sort.Search(len(out), func(i int) bool { return out[i].T >= at })
		if pos == len(out) || out[pos].T != at {
			out = append(out, promSample{})
			copy(out[pos+1:], out[pos:])
		}
		out[pos] = promSample{T: at, V: float64(cycle.Code)}
	}
	return out
}

// promCoverage returns the coverage-query evaluation times (Unix seconds) at which
// the host's yuruna_pool_host_status series has at least one sample in the window
// ending there. Evaluation times sit on the grid uncoveredSteps walks.
func (b *backfiller) promCoverage(ctx context.Context, hostID string, from, to time.Time) (map[int64]bool, error) {
	covered := map[int64]bool{}
	step := int64(coverageStep / time.Second)
	query := fmt.Sprintf(`sum(count_over_time(yuruna_pool_host_status{hostId=%q}[%ds]))`, hostID, step)
	for a := firstCoverageStep(from); a <= to.Unix(); a += coverageChunkSteps * step {
		last := a + (coverageChunkSteps-1)*step
		if last > to.Unix() {
			last = to.Unix()
		}
		q := url.Values{}
		q.Set("query", query)
		q.Set("start", strconv.FormatInt(a, 10))
		q.Set("end", strconv.FormatInt(last, 10))
		q.Set("step", strconv.FormatInt(step, 10))
		var doc struct {
			Status string `json:"status"`
			Data   struct {
				Result []struct {
					Values [][2]any `json:"values"`
				} `json:"result"`
			} `json:"data"`
		}
		if err := b.getJSON(ctx, strings.TrimRight(b.cfg.prometheusURL, "/")+"/api/v1/query_range?"+q.Encode(), &doc); err != nil {
			return nil, err
		}
		for _, r := range doc.Data.Result {
			for _, v := range r.Values {
				if ts, ok := v[0].(float64); ok {
					covered[int64(ts)] = true
				}
			}
		}
	}
	return covered, nil
}

// remoteWrite sends series to Prometheus' remote-write receiver in batches.
func (b *backfiller) remoteWrite(ctx context.Context, labels [][2]string, samples []promSample) error {
	for len(samples) > 0 {
		n := len(samples)
		if n > maxSamplesPerWrite {
			n = maxSamplesPerWrite
		}
		body := snappyEncodeLiteral(encodeWriteRequest([]promSeries{{Labels: labels, Samples: samples[:n]}}))
		if !b.writePacer.wait(ctx) {
			return ctx.Err()
		}
		if err := b.postRemoteWrite(ctx, body); err != nil {
			return err
		}
		samples = samples[n:]
	}
	return nil
}

func (b *backfiller) postRemoteWrite(ctx context.Context, body []byte) error {
	ctx, cancel := context.WithTimeout(ctx, backfillRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(b.cfg.prometheusURL, "/")+"/api/v1/write", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Encoding", "snappy")
	req.Header.Set("Content-Type", "application/x-protobuf")
	req.Header.Set("X-Prometheus-Remote-Write-Version", "0.1.0")
	resp, err := b.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("remote write: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	return nil
}

// The remote-write body is a protobuf WriteRequest (prompb):
//
//	WriteRequest { repeated TimeSeries timeseries = 1; }
//	TimeSeries   { repeated Label labels = 1; repeated Sample samples = 2; }
//	Label        { string name = 1; string value = 2; }
//	Sample       { double value = 1; int64 timestamp = 2; }
//
// encoded by hand, because the services build from the standard library alone.

func pbAppendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func pbAppendBytes(b []byte, field int, payload []byte) []byte {
	b = pbAppendVarint(b, uint64(field)<<3|2)
	b = pbAppendVarint(b, uint64(len(payload)))
	return append(b, payload...)
}

func pbLabel(name, value string) []byte {
	var b []byte
	b = pbAppendBytes(b, 1, []byte(name))
	return pbAppendBytes(b, 2, []byte(value))
}

func pbSample(s promSample) []byte {
	b := []byte{1<<3 | 1}
	bits := math.Float64bits(s.V)
	for i := 0; i < 8; i++ {
		b = append(b, byte(bits>>(8*i)))
	}
	b = pbAppendVarint(b, 2<<3|0)
	return pbAppendVarint(b, uint64(s.T))
}

func encodeWriteRequest(series []promSeries) []byte {
	var out []byte
	for _, s := range series {
		var ts []byte
		for _, l := range s.Labels {
			ts = pbAppendBytes(ts, 1, pbLabel(l[0], l[1]))
		}
		for _, sm := range s.Samples {
			ts = pbAppendBytes(ts, 2, pbSample(sm))
		}
		out = pbAppendBytes(out, 1, ts)
	}
	return out
}

// snappyEncodeLiteral frames src in the snappy block format as literal elements
// only. That is a valid snappy block -- any conforming decoder, Prometheus'
// included, reads it back -- and needs no compressor, at the cost of no
// compression on a body that is small anyway.
func snappyEncodeLiteral(src []byte) []byte {
	dst := pbAppendVarint(nil, uint64(len(src)))
	for len(src) > 0 {
		n := len(src)
		if n > 1<<16 {
			n = 1 << 16
		}
		l := n - 1
		switch {
		case l < 60:
			dst = append(dst, byte(l)<<2)
		case l < 1<<8:
			dst = append(dst, 60<<2, byte(l))
		default:
			dst = append(dst, 61<<2, byte(l), byte(l>>8))
		}
		dst = append(dst, src[:n]...)
		src = src[n:]
	}
	return dst
}
