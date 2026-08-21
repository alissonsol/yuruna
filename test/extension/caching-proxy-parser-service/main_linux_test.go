// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// The half of the parser that can only be tested where it runs: following a
// file across a logrotate needs real inodes.
//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestInodeOfDistinguishesARotatedFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "yuruna_access.log")
	writeLines(t, path, goldenLine)

	first := inodeOfPath(t, path)
	if first == 0 {
		t.Fatal("inodeOf returned 0 for a real file; rotation would never be detected")
	}

	// What logrotate does: move the old file aside, create a new one at the
	// same path. The path is identical and the size may even match, so the
	// inode is the only thing that says "this is a different file".
	if err := os.Rename(path, path+".1"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	writeLines(t, path, goldenLine)

	if second := inodeOfPath(t, path); second == first {
		t.Fatal("a rotated file kept the same inode; the tailer would read the new file from the old offset")
	}
}

// TestFollowReadsBackfillAppendsAndRotation walks the three states the tailer
// has to handle in the order a running VM meets them: a log that already has
// content when the daemon starts (otherwise the panel is blank until the next
// request), lines appended while it watches, and a logrotate underneath it.
func TestFollowReadsBackfillAppendsAndRotation(t *testing.T) {
	// Not t.TempDir(): follow never returns, so it would keep polling a
	// directory the cleanup had already removed and log an error every second
	// for the rest of the test binary's life.
	dir, err := os.MkdirTemp("", "yrn-parser-follow-")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	path := filepath.Join(dir, "yuruna_access.log")
	writeLines(t, path, lineFor("192.0.2.1"))

	r, s := &ring{}, newStats()
	go follow(path, r, s)

	waitForParsed(t, s, 1, "the cold-start backfill must seed the ring from the existing log")
	if got := r.snapshot()[0].ClientIP; got != "192.0.2.1" {
		t.Fatalf("backfill entry is %q", got)
	}

	appendLines(t, path, lineFor("192.0.2.2"))
	waitForParsed(t, s, 2, "an appended line must reach the ring")

	if err := os.Rename(path, path+".1"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	writeLines(t, path, lineFor("192.0.2.3"))
	waitForParsed(t, s, 3, "a line written after a logrotate must reach the ring")

	if got := r.snapshot()[0].ClientIP; got != "192.0.2.3" {
		t.Fatalf("newest entry after rotation is %q, want the post-rotation line", got)
	}
	if n := s.skipped.Load(); n != 0 {
		t.Errorf("skipped = %d; every written line is in the logformat", n)
	}
	if openErr, _ := s.lastOpenErr.Load().(string); openErr != "" {
		t.Errorf("last_open_err = %q while the log was readable throughout", openErr)
	}
}

// A log the tailer cannot open must be visible on /healthz rather than looking
// like a healthy tailer with nothing to read.
func TestFollowRecordsAnUnreadableLog(t *testing.T) {
	dir, err := os.MkdirTemp("", "yrn-parser-missing-")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	s := newStats()
	go follow(filepath.Join(dir, "does-not-exist.log"), &ring{}, s)

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if openErr, _ := s.lastOpenErr.Load().(string); strings.Contains(openErr, "does-not-exist.log") {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("a missing log left last_open_err empty; /healthz would report a tailer that is fine")
}

func inodeOfPath(t *testing.T, path string) uint64 {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat %s: %v", path, err)
	}
	return inodeOf(fi)
}

func lineFor(clientIP string) string {
	return strings.Replace(goldenLine, "192.0.2.31", clientIP, 1)
}

func writeLines(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func appendLines(t *testing.T, path string, lines ...string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("append %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()
	if _, err := f.WriteString(strings.Join(lines, "\n") + "\n"); err != nil {
		t.Fatalf("append %s: %v", path, err)
	}
}

func waitForParsed(t *testing.T, s *stats, want int64, because string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if s.parsed.Load() >= want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("parsed reached %d, want %d: %s", s.parsed.Load(), want, because)
}
