// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func mirrorTestGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_TERMINAL_PROMPT=0",
		"GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.invalid", "GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.invalid")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}
func appendMirrorGitConfig(t *testing.T, key, value string) {
	t.Helper()
	count, _ := strconv.Atoi(os.Getenv("GIT_CONFIG_COUNT"))
	t.Setenv("GIT_CONFIG_KEY_"+strconv.Itoa(count), key)
	t.Setenv("GIT_CONFIG_VALUE_"+strconv.Itoa(count), value)
	t.Setenv("GIT_CONFIG_COUNT", strconv.Itoa(count+1))
}

type mirrorHarness struct {
	c              *mirrorCoordinator
	work, upstream string
	clock          atomic.Int64
}

func newMirrorHarness(t *testing.T) *mirrorHarness {
	t.Helper()
	base := t.TempDir()
	work := filepath.Join(base, "work")
	upstream := filepath.Join(base, "upstream.git")
	if err := os.MkdirAll(work, 0750); err != nil {
		t.Fatal(err)
	}
	mirrorTestGit(t, work, "init", "-q", "-b", "main")
	if err := os.WriteFile(filepath.Join(work, "payload.txt"), []byte("one\n"), 0640); err != nil {
		t.Fatal(err)
	}
	mirrorTestGit(t, work, "add", ".")
	mirrorTestGit(t, work, "commit", "-q", "-m", "initial")
	mirrorTestGit(t, work, "clone", "--bare", work, upstream)
	appendMirrorGitConfig(t, "url.file://"+filepath.ToSlash(upstream)+".insteadOf", "https://github.com/example/repo.git")
	appendMirrorGitConfig(t, "protocol.file.allow", "always")
	h := &mirrorHarness{work: work, upstream: upstream}
	h.clock.Store(time.Now().UTC().UnixNano())
	options := mirrorOptions{Root: filepath.Join(base, "published"), StateRoot: filepath.Join(base, "state"), ReaderRoot: filepath.Join(base, "readers"),
		SigningKey: mirrorFixtureKey(t), Limits: defaultMirrorLimits(), Now: func() time.Time { return time.Unix(0, h.clock.Load()).UTC() }}
	options.Limits.ReserveBytes = 0
	options.Limits.CapBytes = 0
	options.Limits.CancelGrace = 50 * time.Millisecond
	options.Limits.Query = 5 * time.Second
	options.Limits.Job = 10 * time.Second
	options.Limits.Population = 15 * time.Second
	options.Limits.Maintenance = 3 * time.Second
	options.Limits.StorageInterval = 10 * time.Millisecond
	if err := os.MkdirAll(options.StateRoot, 0750); err != nil {
		t.Fatal(err)
	}
	options.RepositoriesFile = filepath.Join(base, "repositories.json")
	b, _ := json.Marshal(mirrorRepositoryList{Repositories: []string{"example/repo"}})
	if err := os.WriteFile(options.RepositoriesFile, b, 0640); err != nil {
		t.Fatal(err)
	}
	c, err := newMirrorCoordinator(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	h.c = c
	t.Cleanup(c.close)
	return h
}
func (h *mirrorHarness) resolve(t *testing.T, ref string) mirrorReceipt {
	t.Helper()
	req := mirrorRequest{Repository: "example/repo", Ref: ref, Nonce: "AAAAAAAAAAAAAAAAAAAAAA"}
	j, reason := h.c.admit(req)
	if j == nil {
		t.Fatalf("admit: %s", reason)
	}
	select {
	case <-j.done:
	case <-time.After(20 * time.Second):
		t.Fatal("mirror job did not complete")
	}
	return h.c.receipt(req, j, reason)
}
func (h *mirrorHarness) advance(t *testing.T, content string) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(h.work, "payload.txt"), []byte(content), 0640); err != nil {
		t.Fatal(err)
	}
	mirrorTestGit(t, h.work, "add", ".")
	mirrorTestGit(t, h.work, "commit", "-q", "-m", content)
	mirrorTestGit(t, h.work, "push", h.upstream, "main")
	h.clock.Add(int64(time.Second))
	return mirrorTestGit(t, h.work, "rev-parse", "HEAD")
}
func TestMirrorInitialPublicationAndUnchangedCheck(t *testing.T) {
	h := newMirrorHarness(t)
	first := h.resolve(t, "HEAD")
	if first.Status != "ready" || !first.ObjectReady {
		t.Fatalf("initial: %+v", first)
	}
	h.c.mu.Lock()
	fetches := h.c.metrics["fetches"]
	updated := h.c.repositories["example/repo"].state.LastUpdatedAt
	h.c.mu.Unlock()
	h.clock.Add(int64(time.Second))
	second := h.resolve(t, "HEAD")
	if second.SelectedSHA != first.SelectedSHA || second.OriginCheckedAt == first.OriginCheckedAt {
		t.Fatalf("unchanged confirmation: %+v", second)
	}
	h.c.mu.Lock()
	defer h.c.mu.Unlock()
	if h.c.metrics["fetches"] != fetches {
		t.Fatal("unchanged refs fetched objects")
	}
	if !h.c.repositories["example/repo"].state.LastUpdatedAt.Equal(updated) {
		t.Fatal("unchanged check changed lastUpdatedAt")
	}
}

func TestMirrorInitialMetadataFailureCanRetryWithoutRestart(t *testing.T) {
	h := newMirrorHarness(t)
	statePath := h.c.statePath("example/repo")
	if err := os.Mkdir(statePath, 0750); err != nil {
		t.Fatal(err)
	}
	failed := h.resolve(t, "HEAD")
	if failed.ObjectReady {
		t.Fatal("failed metadata publication issued a usable receipt")
	}
	if err := os.Remove(statePath); err != nil {
		t.Fatal(err)
	}
	h.clock.Add(int64(2 * time.Minute))
	retry := h.resolve(t, "HEAD")
	if retry.Status != "ready" || !retry.ObjectReady {
		t.Fatalf("retry requires worker restart: %+v", retry)
	}
}
func TestMirrorChangedRefsAndTransportStale(t *testing.T) {
	h := newMirrorHarness(t)
	first := h.resolve(t, "HEAD")
	next := h.advance(t, "two\n")
	ready := h.resolve(t, "HEAD")
	if ready.SelectedSHA != next || ready.SelectedSHA == first.SelectedSHA {
		t.Fatalf("advance: %+v", ready)
	}
	h.c.options.NoUpstreamPath = filepath.Join(t.TempDir(), "no-upstream")
	h.c.git.options.NoUpstreamPath = h.c.options.NoUpstreamPath
	if err := os.WriteFile(h.c.options.NoUpstreamPath, []byte("on"), 0640); err != nil {
		t.Fatal(err)
	}
	h.clock.Add(int64(time.Hour))
	stale := h.resolve(t, "HEAD")
	if stale.Status != "stale" || stale.SelectedSHA != next || stale.OriginCheckedAt != ready.OriginCheckedAt || stale.Detail != "upstream-blocked-by-switch" {
		t.Fatalf("stale: %+v", stale)
	}
}
func TestMirrorRefDeletionDoesNotResurrectPin(t *testing.T) {
	h := newMirrorHarness(t)
	ready := h.resolve(t, "refs/heads/main")
	mirrorTestGit(t, h.upstream, "update-ref", "-d", "refs/heads/main")
	h.clock.Add(int64(time.Second))
	missing := h.resolve(t, "refs/heads/main")
	if missing.Status != "error" || missing.Reason != "ref-missing-confirmed" || missing.ObjectReady {
		t.Fatalf("deletion: %+v", missing)
	}
	if got := mirrorTestGit(t, mirrorRepoPath(h.c.options.Root, "example/repo"), "rev-parse", "refs/yuruna/pins/"+ready.SelectedSHA); got != ready.SelectedSHA {
		t.Fatal("deletion removed retained pin")
	}
}
func TestMirrorCoalescesBeforeSnapshotAndRechecksLateJoin(t *testing.T) {
	h := newMirrorHarness(t)
	h.resolve(t, "HEAD")
	h.c.workers <- struct{}{}
	h.c.workers <- struct{}{}
	req := mirrorRequest{Repository: "example/repo", Ref: "HEAD", Nonce: "AAAAAAAAAAAAAAAAAAAAAA"}
	first, _ := h.c.admit(req)
	second, _ := h.c.admit(req)
	if first != second {
		t.Fatal("queued callers did not coalesce")
	}
	<-h.c.workers
	<-h.c.workers
	<-first.done
	h.advance(t, "later\n")
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	h.c.git.before = func(args []string) {
		if len(args) > 0 && args[0] == "fetch" {
			once.Do(func() { close(entered); <-release })
		}
	}
	first, _ = h.c.admit(req)
	<-entered
	second, _ = h.c.admit(req)
	if first == second {
		t.Fatal("late request reused earlier snapshot")
	}
	close(release)
	<-first.done
	<-second.done
	if first.state.LastCheckedAt.After(second.state.LastCheckedAt) {
		t.Fatal("second snapshot moved backward")
	}
}
func TestMirrorCapacityFailurePreservesPublishedState(t *testing.T) {
	h := newMirrorHarness(t)
	ready := h.resolve(t, "HEAD")
	stateBefore, err := os.ReadFile(h.c.statePath("example/repo"))
	if err != nil {
		t.Fatal(err)
	}
	h.advance(t, "requires-space\n")
	h.c.options.Limits.CapBytes = 1
	failed := h.resolve(t, "HEAD")
	if failed.Reason != "mirror-capacity-exhausted" || failed.ObjectReady {
		t.Fatalf("capacity: %+v", failed)
	}
	stateAfter, _ := os.ReadFile(h.c.statePath("example/repo"))
	if string(stateBefore) != string(stateAfter) {
		t.Fatal("capacity failure changed durable state")
	}
	if got := mirrorTestGit(t, mirrorRepoPath(h.c.options.Root, "example/repo"), "rev-parse", "refs/yuruna/pins/"+ready.SelectedSHA); got != ready.SelectedSHA {
		t.Fatal("capacity failure lost old pin")
	}
}
func TestMirrorRecoversPreMutationMarkerAndStaleLocks(t *testing.T) {
	h := newMirrorHarness(t)
	ready := h.resolve(t, "HEAD")
	h.c.close()
	path := mirrorRepoPath(h.c.options.Root, "example/repo")
	if err := mirrorBeginMutation(path); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"packed-refs.lock", "refs/heads/main.lock"} {
		if err := os.WriteFile(filepath.Join(path, name), nil, 0640); err != nil {
			t.Fatal(err)
		}
	}
	restarted, err := newMirrorCoordinator(context.Background(), h.c.options)
	if err != nil {
		t.Fatal(err)
	}
	h.c = restarted
	t.Cleanup(restarted.close)
	got := h.resolve(t, "HEAD")
	if got.SelectedSHA != ready.SelectedSHA {
		t.Fatalf("recovery: %+v", got)
	}
	for _, name := range []string{"yuruna-in-progress", "packed-refs.lock", "refs/heads/main.lock"} {
		if _, err = os.Stat(filepath.Join(path, name)); !os.IsNotExist(err) {
			t.Fatalf("stale %s survived", name)
		}
	}
}
func TestMirrorMaintenanceDrainsReadersWithoutRefreshSlot(t *testing.T) {
	h := newMirrorHarness(t)
	h.resolve(t, "HEAD")
	release, err := mirrorReadLease(h.c.options, "example/repo")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- h.c.maintain(context.Background(), "example/repo") }()
	marker := filepath.Join(mirrorReaderDir(h.c.options, "example/repo"), "maintenance")
	deadline := time.Now().Add(time.Second)
	for {
		if _, err = os.Stat(marker); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("maintenance did not close admission")
		}
		time.Sleep(time.Millisecond)
	}
	for i := 0; i < 10; i++ {
		if unlock, e := mirrorReadLease(h.c.options, "example/repo"); e == nil {
			unlock()
			t.Fatal("new reader bypassed drain")
		}
	}
	if len(h.c.workers) != 0 {
		t.Fatal("maintenance drain consumed refresh slot")
	}
	release()
	if err = <-done; err != nil {
		t.Fatal(err)
	}
	release, err = mirrorReadLease(h.c.options, "example/repo")
	if err != nil {
		t.Fatal("admission stayed closed")
	}
	release()
}
