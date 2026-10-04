// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"math"
	"math/rand"
	"reflect"
	"sort"
	"testing"
	"time"
)

// snappyDecodeBlock is an independent reader of the snappy block format covering
// every element type, so the encoder is checked against the format rather than
// against itself.
func snappyDecodeBlock(src []byte) ([]byte, error) {
	n, k := binary.Uvarint(src)
	if k <= 0 {
		return nil, errors.New("bad length")
	}
	src = src[k:]
	dst := make([]byte, 0, n)
	for len(src) > 0 {
		tag := src[0]
		switch tag & 3 {
		case 0:
			l := int(tag >> 2)
			src = src[1:]
			switch {
			case l < 60:
			case l == 60:
				l, src = int(src[0]), src[1:]
			case l == 61:
				l, src = int(src[0])|int(src[1])<<8, src[2:]
			case l == 62:
				l, src = int(src[0])|int(src[1])<<8|int(src[2])<<16, src[3:]
			default:
				l, src = int(src[0])|int(src[1])<<8|int(src[2])<<16|int(src[3])<<24, src[4:]
			}
			l++
			if l > len(src) {
				return nil, errors.New("literal overruns input")
			}
			dst = append(dst, src[:l]...)
			src = src[l:]
		default:
			return nil, errors.New("copy elements are never written by this encoder")
		}
	}
	if uint64(len(dst)) != n {
		return nil, errors.New("length mismatch")
	}
	return dst, nil
}

type pbField struct {
	num  int
	wire int
	v    uint64
	b    []byte
}

func pbParse(b []byte) ([]pbField, error) {
	var out []pbField
	for len(b) > 0 {
		key, k := binary.Uvarint(b)
		if k <= 0 {
			return nil, errors.New("bad key")
		}
		b = b[k:]
		f := pbField{num: int(key >> 3), wire: int(key & 7)}
		switch f.wire {
		case 0:
			v, k := binary.Uvarint(b)
			if k <= 0 {
				return nil, errors.New("bad varint")
			}
			f.v, b = v, b[k:]
		case 1:
			if len(b) < 8 {
				return nil, errors.New("short fixed64")
			}
			f.v, b = binary.LittleEndian.Uint64(b), b[8:]
		case 2:
			l, k := binary.Uvarint(b)
			if k <= 0 || int(l) > len(b)-k {
				return nil, errors.New("bad length")
			}
			f.b, b = b[k:k+int(l)], b[k+int(l):]
		default:
			return nil, errors.New("unexpected wire type")
		}
		out = append(out, f)
	}
	return out, nil
}

// decodeWriteRequest reads a prompb.WriteRequest back into series.
func decodeWriteRequest(b []byte) ([]promSeries, error) {
	top, err := pbParse(b)
	if err != nil {
		return nil, err
	}
	var out []promSeries
	for _, ts := range top {
		if ts.num != 1 || ts.wire != 2 {
			return nil, errors.New("WriteRequest holds only timeseries")
		}
		fields, err := pbParse(ts.b)
		if err != nil {
			return nil, err
		}
		var s promSeries
		for _, f := range fields {
			sub, err := pbParse(f.b)
			if err != nil {
				return nil, err
			}
			switch f.num {
			case 1:
				var l [2]string
				for _, x := range sub {
					l[x.num-1] = string(x.b)
				}
				s.Labels = append(s.Labels, l)
			case 2:
				var sm promSample
				for _, x := range sub {
					switch {
					case x.num == 1 && x.wire == 1:
						sm.V = math.Float64frombits(x.v)
					case x.num == 2 && x.wire == 0:
						sm.T = int64(x.v)
					default:
						return nil, errors.New("unexpected sample field")
					}
				}
				s.Samples = append(s.Samples, sm)
			}
		}
		out = append(out, s)
	}
	return out, nil
}

func TestSnappyLiteralBlocksDecode(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for _, n := range []int{0, 1, 59, 60, 61, 255, 256, 257, 65535, 65536, 65537, 200000} {
		src := make([]byte, n)
		rng.Read(src)
		got, err := snappyDecodeBlock(snappyEncodeLiteral(src))
		if err != nil || !bytes.Equal(got, src) {
			t.Fatalf("length %d: round trip failed: %v", n, err)
		}
	}
}

func TestWriteRequestEncodesPrompbFieldForField(t *testing.T) {
	in := []promSeries{{
		Labels:  hostStatusLabels("red", bfHostA),
		Samples: []promSample{{T: 1759406400000, V: 2}, {T: 1759406520000, V: 3}, {T: 0, V: 0}, {T: 1 << 40, V: 1.5}},
	}}
	got, err := decodeWriteRequest(encodeWriteRequest(in))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, in) {
		t.Errorf("round trip changed the request:\n got %+v\nwant %+v", got, in)
	}
}

// The labels are those of the live series, so a backfilled sample extends the
// host's existing timeline row instead of starting a second one.
func TestHostStatusLabelsAreTheScrapedSeries(t *testing.T) {
	got := hostStatusLabels("red", bfHostA)
	want := [][2]string{
		{"__name__", "yuruna_pool_host_status"},
		{"hostId", bfHostA},
		{"hostIdDashed", dashedHostID(bfHostA)},
		{"instance", "localhost:9400"},
		{"job", "pool-aggregator-service"},
		{"pool", "red"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v", got)
	}
	if !sort.SliceIsSorted(got, func(i, j int) bool { return got[i][0] < got[j][0] }) {
		t.Error("remote write requires labels sorted by name")
	}
}

func TestStatusTimelineCodeMatchesTheLivePanel(t *testing.T) {
	for status, want := range map[string]int{"pass": 2, "fail": 3, "skipped": 4, "": 4} {
		if got := statusTimelineCode(status); got != want {
			t.Errorf("%q: got %d want %d", status, got, want)
		}
	}
}

func TestTimelineFromTransitionsAndHold(t *testing.T) {
	base := bfAt("2026-09-01T00:00:00Z")
	entries := []lokiEntry{
		{At: base.Add(40 * time.Minute), Line: `{"cycleStartUtc":"2026-09-01T00:00:00Z","startedAt":"2026-09-01T00:00:00Z","finishedAt":"2026-09-01T00:40:00Z","overallStatus":"pass"}`},
		{At: base.Add(41 * time.Minute), Line: `{"cycleStartUtc":"2026-09-01T00:00:00Z","startedAt":"2026-09-01T00:00:00Z","finishedAt":"2026-09-01T00:40:00Z","overallStatus":"pass"}`},
		{At: base.Add(100 * time.Minute), Line: `{"cycleStartUtc":"2026-09-01T00:45:00Z","startedAt":"","finishedAt":"2026-09-01T01:40:00Z","overallStatus":"fail"}`},
		{At: base.Add(101 * time.Minute), Line: `{"cycleStartUtc":"garbage","overallStatus":"fail"}`},
	}
	cycles := timelineFromTransitions(entries)
	if len(cycles) != 2 || cycles[1].Code != 3 || !cycles[1].Start.Equal(base.Add(45*time.Minute)) {
		t.Fatalf("cycles: %+v", cycles)
	}
	hold := 30 * time.Minute
	check := func(min int, want int, ok bool) {
		t.Helper()
		got, gotOK := timelineCodeAt(cycles, base.Add(time.Duration(min)*time.Minute), hold)
		if got != want || gotOK != ok {
			t.Errorf("minute %d: got %d,%v want %d,%v", min, got, gotOK, want, ok)
		}
	}
	check(-1, 0, false) // before the first cycle
	check(0, 1, true)   // running
	check(39, 1, true)
	check(40, 2, true) // its result
	check(44, 2, true)
	check(45, 1, true) // the next cycle
	check(100, 3, true)
	check(130, 3, true)  // end of the hold
	check(131, 0, false) // a gap the job cannot explain stays empty
}

func TestUncoveredStepsAndSamplesStayOnTheGrid(t *testing.T) {
	from := bfAt("2026-09-01T00:02:00Z")
	to := bfAt("2026-09-01T00:30:00Z")
	step := int64(coverageStep / time.Second)
	covered := map[int64]bool{bfAt("2026-09-01T00:10:00Z").Unix(): true, bfAt("2026-09-01T00:15:00Z").Unix(): true}
	got := uncoveredSteps(from, to, covered)
	var want []int64
	for ts := bfAt("2026-09-01T00:05:00Z").Unix(); ts <= to.Unix(); ts += step {
		if !covered[ts] {
			want = append(want, ts)
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("uncovered: got %v want %v", got, want)
	}
	cycles := []timelineCycle{{Start: bfAt("2026-09-01T00:00:00Z"), End: bfAt("2026-09-01T00:20:00Z"), Code: 2}}
	samples := timelineSamples(cycles, got, 2*time.Minute, 30*time.Minute)
	if len(samples) == 0 {
		t.Fatal("no samples")
	}
	seen := map[int64]bool{}
	for _, s := range samples {
		if s.T%(2*60*1000) != 0 {
			t.Errorf("sample off the 2-minute grid: %d", s.T)
		}
		if seen[s.T] {
			t.Errorf("duplicate sample at %d", s.T)
		}
		seen[s.T] = true
		tm := time.UnixMilli(s.T).UTC()
		for c := range covered {
			if tm.After(time.Unix(c-step, 0)) && !tm.After(time.Unix(c, 0)) {
				t.Errorf("sample %v written into a covered window", tm)
			}
		}
		wantCode := 1.0
		if !tm.Before(cycles[0].End) {
			wantCode = 2
		}
		if s.V != wantCode {
			t.Errorf("sample %v: value %v want %v", tm, s.V, wantCode)
		}
	}
	// Every uncovered window that the cycles explain gets at least two samples,
	// so the state timeline has no hole inside it.
	for _, end := range got {
		n := 0
		for ts := range seen {
			if ts > (end-step)*1000 && ts <= end*1000 {
				n++
			}
		}
		if n < 2 {
			t.Errorf("window ending %v holds %d samples", time.Unix(end, 0).UTC(), n)
		}
	}
	again := timelineSamples(cycles, got, 2*time.Minute, 30*time.Minute)
	if !reflect.DeepEqual(samples, again) {
		t.Error("the same input must give the same samples")
	}
}
