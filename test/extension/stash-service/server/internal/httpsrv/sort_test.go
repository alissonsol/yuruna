// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"stash-service/internal/config"
)

// t1 < t2 < t3, so "created" has an unambiguous direction to check.
var (
	sortT1 = time.Date(2026, 6, 1, 10, 0, 0, 0, time.UTC)
	sortT2 = time.Date(2026, 6, 2, 10, 0, 0, 0, time.UTC)
	sortT3 = time.Date(2026, 6, 3, 10, 0, 0, 0, time.UTC)
)

// sortFixture is three stashes whose every sortable column orders them
// differently, so a comparator that reads the wrong field cannot accidentally
// produce the expected sequence. "Alpha.txt" is capitalized on purpose: the
// name order is only correct if the comparison ignores case.
func sortFixture() []StashView {
	return []StashView{
		{ID: "aa01", OriginalFilename: "beta.txt", HostID: "h2", Username: "carol", SizeBytes: 300, CreatedAt: sortT2, Status: "complete", ContentClass: "text"},
		{ID: "bb02", OriginalFilename: "Alpha.txt", HostID: "h1", Username: "alice", SizeBytes: 100, CreatedAt: sortT3, Status: "partial", ContentClass: "image"},
		{ID: "cc03", OriginalFilename: "gamma.txt", HostID: "h3", Username: "bob", SizeBytes: 200, CreatedAt: sortT1, Status: "complete", ContentClass: "archive"},
	}
}

func idsOf(v []StashView) []string {
	out := make([]string, len(v))
	for i := range v {
		out[i] = v[i].ID
	}
	return out
}

func sameIDs(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestSortViewsColumns(t *testing.T) {
	cases := []struct {
		name string
		col  string
		asc  bool
		want []string
	}{
		{"created descending is the default view", sortCreated, false, []string{"bb02", "aa01", "cc03"}},
		{"created ascending", sortCreated, true, []string{"cc03", "aa01", "bb02"}},
		{"id ascending", sortID, true, []string{"aa01", "bb02", "cc03"}},
		{"id descending", sortID, false, []string{"cc03", "bb02", "aa01"}},
		{"name ignores case", sortName, true, []string{"bb02", "aa01", "cc03"}},
		{"host ascending", sortHost, true, []string{"bb02", "aa01", "cc03"}},
		{"user ascending", sortUser, true, []string{"bb02", "cc03", "aa01"}},
		{"size ascending orders by bytes, not by the rendered label", sortSize, true, []string{"bb02", "cc03", "aa01"}},
		{"size descending", sortSize, false, []string{"aa01", "cc03", "bb02"}},
		{"type ascending orders by the class behind the icon", sortType, true, []string{"cc03", "bb02", "aa01"}},
		// The two "complete" rows tie, so they fall to the tiebreak: newest
		// first. That is what makes a column most rows share still yield one
		// order rather than whatever the merge happened to produce.
		{"status ascending, ties newest first", sortStatus, true, []string{"aa01", "cc03", "bb02"}},
		// Reversing the column must NOT reverse the tiebreak: "partial" leads
		// now, but the two tied rows hold the same relative order as above.
		{"status descending keeps the tiebreak pointing the same way", sortStatus, false, []string{"bb02", "aa01", "cc03"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			v := sortFixture()
			sortViews(v, c.col, c.asc)
			if got := idsOf(v); !sameIDs(got, c.want) {
				t.Fatalf("sortViews(%s, asc=%v) = %v, want %v", c.col, c.asc, got, c.want)
			}
		})
	}
}

// An unknown column is a view preference nobody can get wrong enough to deserve
// an error, so it lands on the default ordering rather than on an empty list or
// a 400.
func TestSortColumnFallsBackToCreated(t *testing.T) {
	for _, in := range []string{"", "bogus", "SIZE", "created; drop", "path"} {
		if got := sortColumn(in); got != sortCreated {
			t.Fatalf("sortColumn(%q) = %q, want %q", in, got, sortCreated)
		}
	}
	if got := sortColumn(sortSize); got != sortSize {
		t.Fatalf("sortColumn(%q) = %q, want it preserved", sortSize, got)
	}
}

func TestParseSort(t *testing.T) {
	cases := []struct {
		query   string
		wantCol string
		wantAsc bool
	}{
		{"", sortCreated, false},
		{"?sort=size", sortSize, false},
		{"?sort=size&dir=asc", sortSize, true},
		{"?sort=size&dir=ASC", sortSize, true},
		{"?sort=size&dir=desc", sortSize, false},
		// Anything unreadable is descending, which is the direction the default
		// view is served in -- never the inverse of what was just on screen.
		{"?sort=name&dir=sideways", sortName, false},
		{"?sort=nope&dir=asc", sortCreated, true},
	}
	for _, c := range cases {
		r := httptest.NewRequest("GET", "/api/stashes"+c.query, nil)
		col, asc := parseSort(r)
		if col != c.wantCol || asc != c.wantAsc {
			t.Fatalf("parseSort(%q) = (%q, %v), want (%q, %v)", c.query, col, asc, c.wantCol, c.wantAsc)
		}
	}
}

// The wiring, end to end: a ?sort=/?dir= pair on the request has to reach the
// comparator and come back as an ordered page. Checked over stashes on a PEER
// host, because those arrive from the share rather than from the local index --
// the merge is where an ordering applied in the wrong place would show up.
func TestListSortQueryOrdersTheResponse(t *testing.T) {
	ts, ui, stashRoot := newTestUI(t)
	const peer = "99bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	y, mo, d := time.Now().UTC().Date()
	dir := filepath.Join(stashRoot, peer, config.FilesDirName, pad4(y), pad2(int(mo)), pad2(d))
	// Bodies of deliberately different lengths: size is the column here, and it
	// must not agree with id order, or the assertion would pass on either.
	for _, s := range []struct{ id, body string }{
		{"aa11", "xxxxxxxxxx"}, // 10
		{"bb22", "x"},          // 1
		{"cc33", "xxxxx"},      // 5
	} {
		if err := writeRemoteStash(dir, s.id, s.id+".txt", s.body); err != nil {
			t.Fatalf("seed %s: %v", s.id, err)
		}
	}
	ui.pool.Refresh()

	var list struct {
		Stashes []StashView `json:"stashes"`
		Sort    string      `json:"sort"`
		Dir     string      `json:"dir"`
	}
	cases := []struct {
		query    string
		wantSort string
		wantDir  string
		wantIDs  []string
	}{
		{"&sort=size&dir=asc", sortSize, "asc", []string{"bb22", "cc33", "aa11"}},
		{"&sort=size", sortSize, "desc", []string{"aa11", "cc33", "bb22"}},
		{"&sort=id&dir=asc", sortID, "asc", []string{"aa11", "bb22", "cc33"}},
		// No sort at all: the default view. Each seed is stamped as it is
		// written, so newest-first is the reverse of the order they were
		// created in -- which is the ordering this list has always had.
		{"", sortCreated, "desc", []string{"cc33", "bb22", "aa11"}},
	}
	for _, c := range cases {
		getJSON(t, ts.URL+"/api/stashes?limit=50"+c.query, &list)
		if list.Sort != c.wantSort || list.Dir != c.wantDir {
			t.Fatalf("%q echoed sort=%q dir=%q, want %q/%q", c.query, list.Sort, list.Dir, c.wantSort, c.wantDir)
		}
		if got := idsOf(list.Stashes); !sameIDs(got, c.wantIDs) {
			t.Fatalf("%q ordered %v, want %v", c.query, got, c.wantIDs)
		}
	}
}

// The property the tiebreak exists for. Paging is offset-based over a set that
// is re-sorted on every request, so if equal rows could settle in different
// orders between two requests, "Load more" would skip a stash or serve one
// twice. Every row here shares a status AND a timestamp -- the worst case the
// comparator can be handed -- and the assertion is that walking the pages still
// visits each stash exactly once, whatever order the merge delivered them in.
func TestSortViewsTotalOrderSurvivesPaging(t *testing.T) {
	const n, window = 25, 7
	build := func(rotate int) []StashView {
		v := make([]StashView, 0, n)
		for i := 0; i < n; i++ {
			k := (i + rotate) % n
			v = append(v, StashView{
				ID:        "s" + strconv.Itoa(100+k),
				Status:    "complete",
				CreatedAt: sortT1,
				SizeBytes: 42,
			})
		}
		return v
	}

	reference := build(0)
	sortViews(reference, sortStatus, true)

	seen := map[string]int{}
	for offset := 0; offset < n; offset += window {
		// A different merge order for every request, which is what a live pool
		// produces: the local index and each host's sidecars arrive in whatever
		// order the scan found them.
		v := build(offset * 3)
		sortViews(v, sortStatus, true)
		if got, want := idsOf(v), idsOf(reference); !sameIDs(got, want) {
			t.Fatalf("offset %d sorted to a different order than the reference:\n got  %v\n want %v", offset, got, want)
		}
		for _, sv := range page(v, offset, window) {
			seen[sv.ID]++
		}
	}
	if len(seen) != n {
		t.Fatalf("paging visited %d distinct stashes, want %d -- the order is not total", len(seen), n)
	}
	for id, count := range seen {
		if count != 1 {
			t.Fatalf("stash %s was served %d times across the pages, want exactly once", id, count)
		}
	}
}
