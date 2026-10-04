// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// A host serves recent cycles at the top level of /log/ and files older ones into
// history.<YYYY-MM-DD>/ buckets that the same index only LINKS. A cycle link that
// resolves against the top level alone therefore stops working the moment
// rotation moves its folder, and lands on the oldest retained cycle instead --
// indistinguishable, once followed, from the cycle that was asked for. A bucket is
// named for the day rotation ran, so the cycles inside it started days earlier.

const histHostID = "42af6f0d32ad41c48cffd47c91c16b2d"

func histAt(s string) time.Time {
	tm, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return tm.UTC()
}

// The index a rotating host serves: history buckets first, then the retained leaves.
func topLevelListing() string {
	return `<a href="history.2026-09-14/">history.2026-09-14/</a>
<a href="history.2026-09-15/">history.2026-09-15/</a>
<a href="001801.2026-09-15.09-50-29.` + histHostID + `/">x</a>
<a href="001802.2026-09-15.10-07-39.` + histHostID + `/">x</a>
<a href="001856.2026-09-16.01-30-30.` + histHostID + `.incomplete/">x</a>`
}

// Rotated on 2026-09-15: the cycles that ran from the 13th to that morning.
func historyListing() string {
	return `<a href="001790.2026-09-13.05-33-12.` + histHostID + `/">x</a>
<a href="001796.2026-09-15.07-19-58.` + histHostID + `/">x</a>
<a href="001797.2026-09-15.07-41-02.` + histHostID + `/">x</a>`
}

// Rotated on 2026-09-14: older cycles still.
func olderHistoryListing() string {
	return `<a href="001700.2026-09-11.00-00-00.` + histHostID + `/">x</a>
<a href="001789.2026-09-12.23-10-00.` + histHostID + `/">x</a>`
}

// scanListingForHost must separate a genuine at/before hit from the oldest leaf,
// because the caller treats them differently: only the miss may consult history.
func TestScanListingForHostSeparatesHitFromOldest(t *testing.T) {
	body := topLevelListing()
	best, earliest := scanListingForHost(body, histHostID, histAt("2026-09-15T10:10:00Z"))
	if best != "001802.2026-09-15.10-07-39."+histHostID+"/" {
		t.Errorf("wrong cycle for a covered click: %q", best)
	}
	if earliest != "001801.2026-09-15.09-50-29."+histHostID+"/" {
		t.Errorf("wrong earliest leaf: %q", earliest)
	}
	// A click older than everything retained has NO hit -- the caller needs to see
	// that so it can look in the history buckets rather than settle for the oldest.
	best, earliest = scanListingForHost(body, histHostID, histAt("2026-09-15T07:30:00Z"))
	if best != "" {
		t.Errorf("a click predating every retained leaf must report no hit, got %q", best)
	}
	if earliest == "" {
		t.Error("the oldest retained leaf must still be reported")
	}
}

func TestHistoryBucketsNewestFirst(t *testing.T) {
	if got := historyBucketsNewestFirst(topLevelListing(), 10); !reflect.DeepEqual(got, []string{"history.2026-09-15", "history.2026-09-14"}) {
		t.Errorf("got %q", got)
	}
	if got := historyBucketsNewestFirst(topLevelListing(), 1); !reflect.DeepEqual(got, []string{"history.2026-09-15"}) {
		t.Errorf("the limit keeps the newest: %q", got)
	}
	if got := historyBucketsNewestFirst("", 10); len(got) != 0 {
		t.Errorf("an empty index links no bucket: %q", got)
	}
}

// listingHost serves the three listings above and counts what it was asked for.
func listingHost(t *testing.T) (*httptest.Server, func() []string) {
	var mu sync.Mutex
	var asked []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		asked = append(asked, r.URL.Path)
		mu.Unlock()
		switch r.URL.Path {
		case "/log/":
			fmt.Fprint(w, topLevelListing())
		case "/log/history.2026-09-15/":
			fmt.Fprint(w, historyListing())
		case "/log/history.2026-09-14/":
			fmt.Fprint(w, olderHistoryListing())
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), asked...)
	}
}

// The cycle under investigation ran at 07:19:58Z and sits in the bucket rotation
// made that day; one from the 12th sits in the bucket of the 14th, which no date
// arithmetic on the click could have named.
func TestHistoryListingResolvesRotatedCycles(t *testing.T) {
	srv, asked := listingHost(t)
	s := newPoolState("default", 8080)
	s.httpClient = srv.Client()
	if got := s.resolveFolderByListing(srv.URL, histHostID, histAt("2026-09-15T07:30:00Z")); got != "log/history.2026-09-15/001796.2026-09-15.07-19-58."+histHostID+"/" {
		t.Fatalf("rotated cycle not found: %q", got)
	}
	if got := s.resolveFolderByListing(srv.URL, histHostID, histAt("2026-09-13T01:00:00Z")); got != "log/history.2026-09-14/001789.2026-09-12.23-10-00."+histHostID+"/" {
		t.Fatalf("a cycle in a bucket dated after it ran was not found: %q", got)
	}
	// Newest first, stopping at the first bucket that answers.
	if got := asked(); !reflect.DeepEqual(got, []string{"/log/", "/log/history.2026-09-15/", "/log/", "/log/history.2026-09-15/", "/log/history.2026-09-14/"}) {
		t.Errorf("requests: %q", got)
	}
	// A click older than every bucket keeps the oldest-retained consolation prize.
	if got := s.resolveFolderByListing(srv.URL, histHostID, histAt("2026-08-01T00:00:00Z")); got != "log/001801.2026-09-15.09-50-29."+histHostID+"/" {
		t.Errorf("fallback changed: %q", got)
	}
}

// pickFolderFromListing keeps its oldest-retained consolation prize: it is the last
// resort once history has been consulted, and other callers still depend on a link
// landing somewhere real.
func TestPickFolderFromListingStillFallsBackToOldest(t *testing.T) {
	got := pickFolderFromListing(topLevelListing(), histHostID, histAt("2026-09-15T07:30:00Z"))
	want := fmt.Sprintf("log/001801.2026-09-15.09-50-29.%s/", histHostID)
	if got != want {
		t.Fatalf("fallback changed: got %q want %q", got, want)
	}
}

func writeTestIndex(t *testing.T, dir string, folders ...cycleFolder) {
	t.Helper()
	m := map[string]cycleFolder{}
	for _, cf := range folders {
		m[cf.Identity] = cf
	}
	if err := writeCycleIndex(dir, histHostID, m, nil); err != nil {
		t.Fatal(err)
	}
}

func folderAt(t *testing.T, leaf, parent string) cycleFolder {
	t.Helper()
	cf, ok := cycleFolderFromLeaf(leaf, histHostID, parent)
	if !ok {
		t.Fatalf("bad leaf %q", leaf)
	}
	return cf
}

func TestCycleIndexAnswersOnlyBetweenKnownStarts(t *testing.T) {
	dir := t.TempDir()
	a := folderAt(t, "001789.2026-09-12.23-10-00."+histHostID, "log/history.2026-09-14/")
	b := folderAt(t, "001796.2026-09-15.07-19-58."+histHostID, "log/history.2026-09-15/")
	c := folderAt(t, "001801.2026-09-15.09-50-29."+histHostID, "log/")
	shareOnly := cycleFolder{Identity: "001795.2026-09-15.06-00-00." + histHostID, Start: histAt("2026-09-15T06:00:00Z"), ArchiveDir: "/mnt/x"}
	writeTestIndex(t, dir, c, a, shareOnly, b)
	s := newPoolState("default", 8080)
	s.backfillStateDir = dir
	cases := []struct {
		at   string
		want string
	}{
		{"2026-09-12T23:00:00Z", ""},       // before the oldest start
		{"2026-09-12T23:10:00Z", a.RelDir}, // exactly at a start
		{"2026-09-14T12:00:00Z", a.RelDir}, // days into a long gap
		{"2026-09-15T06:30:00Z", ""},       // a cycle only the share holds
		{"2026-09-15T08:00:00Z", b.RelDir}, // in a bucket
		{"2026-09-15T10:00:00Z", ""},       // after the newest start: the listing decides
		{"0001-01-01T00:00:00Z", ""},       // no time
	}
	for _, tc := range cases {
		if got := s.resolveFolderByIndex(histHostID, histAt(tc.at)); got != tc.want {
			t.Errorf("%s: got %q want %q", tc.at, got, tc.want)
		}
	}
	if got := s.resolveFolderByIndex(strings.ToUpper(histHostID), histAt("2026-09-14T12:00:00Z")); got != a.RelDir {
		t.Errorf("the host id is matched without regard to case: %q", got)
	}
	s.backfillStateDir = ""
	if got := s.resolveFolderByIndex(histHostID, histAt("2026-09-14T12:00:00Z")); got != "" {
		t.Errorf("no state dir, no answer: %q", got)
	}
}

// The index ends up in a redirect, so a folder of any other shape is ignored.
func TestCycleIndexRefusesFoldersOfAnyOtherShape(t *testing.T) {
	dir := t.TempDir()
	s := newPoolState("default", 8080)
	s.backfillStateDir = dir
	for _, rel := range []string{"https://elsewhere.example/", "log/../../etc/", "/log/x/", "log/history.2026-09-15/../x/", "log/001789.2026-09-12.23-10-00." + histHostID} {
		idx := cycleIndex{Version: cycleIndexVersion, HostID: histHostID, Cycles: []cycleIndexEntry{
			{Identity: "001789.2026-09-12.23-10-00." + histHostID, StartUtc: "2026-09-12T23:10:00Z", RelDir: rel},
			{Identity: "001790.2026-09-13.05-33-12." + histHostID, StartUtc: "2026-09-13T05:33:12Z", RelDir: "log/001790.2026-09-13.05-33-12." + histHostID + "/"},
		}}
		if err := writeJSONAtomic(cycleIndexPath(dir, histHostID), idx, 0o644); err != nil {
			t.Fatal(err)
		}
		if got := s.resolveFolderByIndex(histHostID, histAt("2026-09-13T00:00:00Z")); got != "" {
			t.Errorf("relDir %q must be refused, got %q", rel, got)
		}
	}
	idx := cycleIndex{Version: cycleIndexVersion + 1, HostID: histHostID}
	if err := writeJSONAtomic(cycleIndexPath(dir, histHostID), idx, 0o644); err != nil {
		t.Fatal(err)
	}
	if got := s.resolveFolderByIndex(histHostID, histAt("2026-09-13T00:00:00Z")); got != "" {
		t.Errorf("an index of another version is not read: %q", got)
	}
}

// A click on a weeks-old cycle resolves from the index without a request to the
// host, and the index outranks the host listing.
func TestGoCycleUsesTheIndexBeforeTheHost(t *testing.T) {
	srv, asked := listingHost(t)
	dir := t.TempDir()
	a := folderAt(t, "001789.2026-09-12.23-10-00."+histHostID, "log/history.2026-09-14/")
	b := folderAt(t, "001796.2026-09-15.07-19-58."+histHostID, "log/history.2026-09-15/")
	writeTestIndex(t, dir, a, b)
	s := newPoolState("default", 8080)
	s.httpClient = srv.Client()
	s.backfillStateDir = dir
	s.hosts[histHostID] = &hostView{HostId: histHostID, BaseURL: srv.URL, Reachable: true,
		Status: &hostStatus{CycleStartUtc: "2026-09-16T01:30:30Z", StartedAt: "2026-09-16T01:30:30Z", CycleFolderUrl: "log/001856.2026-09-16.01-30-30." + histHostID + ".incomplete/"}}
	click := histAt("2026-09-13T01:00:00Z").UnixMilli()
	req := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/go/cycle?host=%s&t=%d", histHostID, click), nil)
	w := httptest.NewRecorder()
	s.handleGoCycle(w, req)
	if w.Code != http.StatusFound || w.Header().Get("Location") != srv.URL+"/"+a.RelDir {
		t.Fatalf("code=%d location=%q", w.Code, w.Header().Get("Location"))
	}
	if got := asked(); len(got) != 0 {
		t.Errorf("the host was asked %q", got)
	}
}

func TestWriteCycleIndexSkipsAnUnchangedFile(t *testing.T) {
	dir := t.TempDir()
	a := folderAt(t, "001789.2026-09-12.23-10-00."+histHostID, "log/")
	writeTestIndex(t, dir, a)
	path := cycleIndexPath(dir, histHostID)
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	writeTestIndex(t, dir, a)
	if st, err := os.Stat(path); err != nil || st.ModTime().After(old.Add(time.Second)) {
		t.Errorf("unchanged index rewritten: %v %v", st.ModTime(), err)
	}
	b := folderAt(t, "001790.2026-09-13.05-33-12."+histHostID, "log/")
	writeTestIndex(t, dir, a, b)
	if st, err := os.Stat(path); err != nil || !st.ModTime().After(old.Add(time.Second)) {
		t.Errorf("changed index not rewritten: %v", err)
	}
}
