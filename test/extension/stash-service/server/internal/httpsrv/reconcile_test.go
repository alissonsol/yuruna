// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"stash-service/internal/config"
	"stash-service/internal/meta"
)

// The reconcile predicate is the only code here that removes index rows without
// anyone asking, so these cases are written from the failing side: what must
// SURVIVE. A false positive is not a stale listing, it is a stash the daemon
// forgets while its bytes are still on the share.

// A stash whose artifact and sidecar have both left the share -- a peer deleted
// it, or an operator did it by hand on the NAS -- is dropped from the index, so
// the listing stops advertising bytes that are gone.
func TestReconcileDropsOrphanedRow(t *testing.T) {
	ts, ui, _ := newTestUI(t)
	permalink := postText(t, ts.URL, "gone soon")
	id := lastSegment(permalink)

	rec, err := ui.meta().Get(id)
	if err != nil {
		t.Fatalf("index row missing right after create: %v", err)
	}
	// Reconcile must NOT touch it while the files are there.
	ui.reconcile()
	if _, err := ui.meta().Get(id); err != nil {
		t.Fatalf("reconcile dropped a row whose files are present: %v", err)
	}

	removeStashFiles(t, rec)
	ui.reconcile()
	if _, err := ui.meta().Get(id); err == nil {
		t.Fatal("reconcile kept a row whose artifact and sidecar are both gone")
	}
	// And it is out of the listing, not merely out of the table.
	var list struct {
		Total int `json:"total"`
	}
	getJSON(t, ts.URL+"/api/stashes?limit=50", &list)
	if list.Total != 0 {
		t.Fatalf("list after reconcile = %d rows, want 0", list.Total)
	}
}

// The share going away must not read as "everything was deleted". This is the
// case that would empty an entire index in one pass, so it is checked with the
// files genuinely absent -- the predicate has to be stopped by the mount check
// alone, not by anything it would find on disk.
func TestReconcileSkipsWhenShareOffline(t *testing.T) {
	ts, ui, _ := newTestUI(t)
	permalink := postText(t, ts.URL, "survives an outage")
	id := lastSegment(permalink)
	rec, err := ui.meta().Get(id)
	if err != nil {
		t.Fatal(err)
	}
	removeStashFiles(t, rec)

	ui.ssh.ShareOnline = func() bool { return false } // the mount has gone away
	ui.reconcile()
	if _, err := ui.meta().Get(id); err != nil {
		t.Fatalf("reconcile pruned while the share was offline: %v", err)
	}
	var list struct {
		Total int `json:"total"`
	}
	getJSON(t, ts.URL+"/api/stashes?limit=50", &list)
	if list.Total != 1 {
		t.Fatalf("list during an outage = %d rows, want the row kept", list.Total)
	}
}

// The record-state half of the predicate: which rows absence on the share says
// anything about at all. Both exclusions are rows whose files are legitimately
// not there yet, and reading either as a delete would erase a live upload.
func TestReconcilableSkipsRowsStillInFlight(t *testing.T) {
	cases := []struct {
		name string
		rec  *meta.Record
		want bool
	}{
		{"buffered row awaiting flush", &meta.Record{ID: "buff", StoredPath: "/x/buff.txt", Status: meta.StatusComplete, LocallyBuffered: true}, false},
		{"upload still arriving", &meta.Record{ID: "pend", StoredPath: "/x/pend.txt", Status: meta.StatusPending}, false},
		{"row with no path at all", &meta.Record{ID: "nopa", StoredPath: "", Status: meta.StatusComplete}, false},
		{"committed to the share", &meta.Record{ID: "done", StoredPath: "/x/done.txt", Status: meta.StatusComplete}, true},
		{"partial upload, terminal", &meta.Record{ID: "part", StoredPath: "/x/part.txt", Status: meta.StatusPartial}, true},
		{"truncated at the cap", &meta.Record{ID: "trun", StoredPath: "/x/trun.txt", Status: meta.StatusTruncated}, true},
	}
	for _, c := range cases {
		if got := reconcilable(c.rec); got != c.want {
			t.Fatalf("reconcilable(%s) = %v, want %v", c.name, got, c.want)
		}
	}
}

// The listing half: any surviving file for an id keeps its row. The test names
// each shape a stash's files take, because a prefix rule that missed one would
// drop a row whose bytes are still on the share.
func TestStashFilesPresentErrsTowardPresence(t *testing.T) {
	cases := []struct {
		name    string
		entries []string
		want    bool
	}{
		{"bare artifact", []string{"ab12"}, true},
		{"artifact with an extension", []string{"ab12.txt"}, true},
		{"multi-file archive", []string{"ab12" + config.ArchiveExtension}, true},
		{"sidecar alone", []string{"ab12" + config.SidecarExtension}, true},
		{"staging file from an upload in flight", []string{"ab12.staging"}, true},
		{"nothing for this id", []string{"zz99.txt", "zz99" + config.SidecarExtension}, false},
		{"empty day", nil, false},
		// A longer id that merely STARTS with this one is a different stash; its
		// files must not keep this row alive.
		{"a different id sharing the prefix", []string{"ab123.txt"}, false},
	}
	for _, c := range cases {
		if got := stashFilesPresent(dirEntries(c.entries), "ab12"); got != c.want {
			t.Fatalf("stashFilesPresent(%s) = %v, want %v", c.name, got, c.want)
		}
	}
}

// A day directory that cannot be listed reads as unknown, never as empty: one
// failed read must not condemn every stash filed under that day.
func TestReconcileKeepsRowsUnderAnUnreadableDay(t *testing.T) {
	ts, ui, _ := newTestUI(t)
	permalink := postText(t, ts.URL, "under a locked door")
	id := lastSegment(permalink)
	rec, err := ui.meta().Get(id)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Dir(rec.StoredPath)
	removeStashFiles(t, rec)
	if err := os.Chmod(dir, 0o000); err != nil {
		t.Skipf("cannot make the day directory unreadable here: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	if entries, rerr := os.ReadDir(dir); rerr == nil {
		t.Skipf("the day directory is still readable (%d entries) -- running as root?", len(entries))
	}

	ui.reconcile()
	if _, err := ui.meta().Get(id); err != nil {
		t.Fatalf("reconcile pruned a row whose day directory it could not read: %v", err)
	}
}

// The end-to-end shape the design turns on: host A deletes a stash B received,
// and B's index catches up on its own next pass -- without B having been asked,
// and without the two daemons talking to each other at all.
func TestPeerDeleteIsReconciledByOwner(t *testing.T) {
	// B is the owner: it received the stash and holds the only index row.
	tsB, uiB, rootB := newTestUI(t)
	permalink := postText(t, tsB.URL, "owned by B")
	id := lastSegment(permalink)

	// A is a second daemon on the same share, so its stashRoot is B's.
	uiA := New(uiB.ssh, Options{Addr: "127.0.0.1:0", PoolWindowDays: 30})
	uiA.stashRoot = rootB
	uiA.localHostID = "42dddddddddddddddddddddddddddddd" // any host that is not B

	k, ok := uiA.newPathKey(testHostID, segment(permalink, 1), segment(permalink, 2), segment(permalink, 3), id)
	if !ok {
		t.Fatalf("permalink %q did not parse as a path key", permalink)
	}
	if err := uiA.deleteStash(k); err != nil {
		t.Fatalf("A could not delete B's stash on the share: %v", err)
	}

	// B still lists it: nothing has told B anything yet.
	if _, err := uiB.meta().Get(id); err != nil {
		t.Fatalf("B's row vanished without a reconcile: %v", err)
	}
	uiB.reconcile()
	if _, err := uiB.meta().Get(id); err == nil {
		t.Fatal("B kept a row for a stash A deleted from the share")
	}
}

// removeStashFiles unlinks a record's artifact and sidecar, standing in for the
// peer delete or the hand-run rm this pass exists to notice.
func removeStashFiles(t *testing.T, rec *meta.Record) {
	t.Helper()
	if err := os.Remove(rec.StoredPath); err != nil {
		t.Fatalf("remove artifact: %v", err)
	}
	sidecar := filepath.Join(filepath.Dir(rec.StoredPath), rec.ID+config.SidecarExtension)
	if err := os.Remove(sidecar); err != nil && !os.IsNotExist(err) {
		t.Fatalf("remove sidecar: %v", err)
	}
}

// dirEntries turns names into the os.DirEntry slice stashFilesPresent reads.
func dirEntries(names []string) []os.DirEntry {
	out := make([]os.DirEntry, 0, len(names))
	for _, n := range names {
		out = append(out, nameOnlyEntry(n))
	}
	return out
}

// nameOnlyEntry is a DirEntry that carries just a name -- the only field the
// listing predicate reads.
type nameOnlyEntry string

func (e nameOnlyEntry) Name() string               { return string(e) }
func (e nameOnlyEntry) IsDir() bool                { return false }
func (e nameOnlyEntry) Type() os.FileMode          { return 0 }
func (e nameOnlyEntry) Info() (os.FileInfo, error) { return nil, nil }

func lastSegment(permalink string) string { return segment(permalink, 4) }

// segment returns the n-th part of a permalink's host/y/m/d/id tail.
func segment(permalink string, n int) string {
	parts := strings.Split(strings.TrimPrefix(permalink, "/s/"), "/")
	if n >= len(parts) {
		return ""
	}
	return parts[n]
}
