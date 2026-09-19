// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"fmt"
	"testing"
	"time"
)

// A host serves recent cycles at the top level of /log/ and files older ones into
// date-named history.<YYYY-MM-DD>/ buckets that the same index only LINKS. A cycle
// link that resolves against the top level alone therefore stops working the moment
// rotation moves its folder, and lands on the oldest retained cycle instead --
// indistinguishable, once followed, from the cycle that was asked for.

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

func historyListing() string {
	return `<a href="001790.2026-09-15.05-33-12.` + histHostID + `/">x</a>
<a href="001796.2026-09-15.07-19-58.` + histHostID + `/">x</a>
<a href="001797.2026-09-15.07-41-02.` + histHostID + `/">x</a>`
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
	// that so it can look in the history bucket rather than settle for the oldest.
	best, earliest = scanListingForHost(body, histHostID, histAt("2026-09-15T07:30:00Z"))
	if best != "" {
		t.Errorf("a click predating every retained leaf must report no hit, got %q", best)
	}
	if earliest == "" {
		t.Error("the oldest retained leaf must still be reported")
	}
}

// The cycle under investigation: 07:19:58Z, rotated into history.2026-09-15/.
func TestHistoryListingResolvesARotatedCycle(t *testing.T) {
	clicked := histAt("2026-09-15T07:30:00Z")
	if got := historyBucketFor(topLevelListing(), clicked); got != "history.2026-09-15/" {
		t.Fatalf("the bucket covering the click was not found: %q", got)
	}
	best, _ := scanListingForHost(historyListing(), histHostID, clicked)
	if best != "001796.2026-09-15.07-19-58."+histHostID+"/" {
		t.Fatalf("wrong cycle resolved from the history bucket: %q", best)
	}
}

// Only a bucket the index actually links is followed, and only the one covering the
// click: rotation files a cycle under the date it started.
func TestHistoryBucketForOnlyMatchesALinkedDate(t *testing.T) {
	body := topLevelListing()
	if got := historyBucketFor(body, histAt("2026-09-14T22:00:00Z")); got != "history.2026-09-14/" {
		t.Errorf("a linked bucket must be found: %q", got)
	}
	if got := historyBucketFor(body, histAt("2026-08-01T12:00:00Z")); got != "" {
		t.Errorf("an unlinked date must yield no bucket, got %q", got)
	}
	if got := historyBucketFor("", histAt("2026-09-15T07:30:00Z")); got != "" {
		t.Errorf("an empty index must yield no bucket, got %q", got)
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
