// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"io"
	"net/http"
	"net/http/cgi"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func mirrorTestHTTP(t *testing.T, h *mirrorHarness) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.Handle("/git-mirror/", h.c.routes())
	mux.Handle("/git-raw/", newMirrorReader(h.c.options).routes())
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	mux.Handle("/git/", &cgi.Handler{Path: binary, Args: []string{"--mirror-role=cgi", "--mirror-root=" + h.c.options.Root, "--mirror-reader-root=" + h.c.options.ReaderRoot},
		Root: "/git", Env: []string{"GIT_PROJECT_ROOT=" + h.c.options.Root, "GIT_HTTP_EXPORT_ALL=1"}})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func TestMirrorSmartHTTPShallowExactPinAndDeniedPush(t *testing.T) {
	h := newMirrorHarness(t)
	ready := h.resolve(t, "HEAD")
	server := mirrorTestHTTP(t, h)
	for _, protocol := range []string{"0", "1", "2"} {
		t.Run("protocol-"+protocol, func(t *testing.T) {
			dir := t.TempDir()
			mirrorTestGit(t, dir, "init", "-q")
			mirrorTestGit(t, dir, "-c", "protocol.version="+protocol, "fetch", "--depth=1", server.URL+"/git/example/repo.git", ready.SelectedSHA)
			if got := mirrorTestGit(t, dir, "rev-parse", "FETCH_HEAD"); got != ready.SelectedSHA {
				t.Fatal("wrong pin fetched")
			}
			if got := mirrorTestGit(t, dir, "rev-list", "--count", "FETCH_HEAD"); got != "1" {
				t.Fatal("fetch was not shallow")
			}
		})
	}
	for _, test := range []struct{ method, path string }{
		{"GET", "/git/example/repo.git/info/refs?service=git-receive-pack"},
		{"POST", "/git/example/repo.git/git-receive-pack"},
		{"GET", "/git/example/repo.git/config"},
	} {
		req, _ := http.NewRequest(test.method, server.URL+test.path, nil)
		req.SetBasicAuth("authenticated", "reader")
		resp, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 403 {
			t.Fatalf("%s %s: %d", test.method, test.path, resp.StatusCode)
		}
	}
}

func TestMirrorRawUsesOnlyRetainedCommitAndRejectsLargeBlob(t *testing.T) {
	h := newMirrorHarness(t)
	ready := h.resolve(t, "HEAD")
	server := mirrorTestHTTP(t, h)
	resp, err := server.Client().Get(server.URL + "/git-raw/example/repo/" + ready.SelectedSHA + "/payload.txt")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || string(b) != "one\n" {
		t.Fatalf("raw: %d %q", resp.StatusCode, b)
	}
	unknown := strings.Repeat("b", 40)
	resp, err = server.Client().Get(server.URL + "/git-raw/example/repo/" + unknown + "/payload.txt")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("unretained object: %d", resp.StatusCode)
	}
	if err = os.WriteFile(filepath.Join(h.work, "large.bin"), make([]byte, (16<<20)+1), 0640); err != nil {
		t.Fatal(err)
	}
	mirrorTestGit(t, h.work, "add", ".")
	mirrorTestGit(t, h.work, "commit", "-q", "-m", "large")
	mirrorTestGit(t, h.work, "push", h.upstream, "main")
	h.clock.Add(int64(time.Second))
	ready = h.resolve(t, "HEAD")
	resp, err = server.Client().Get(server.URL + "/git-raw/example/repo/" + ready.SelectedSHA + "/large.bin")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 413 {
		t.Fatalf("large blob: %d", resp.StatusCode)
	}
}

func TestMirrorGitCancellationDoesNotWaitForSilentTransport(t *testing.T) {
	h := newMirrorHarness(t)
	silent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer silent.Close()
	appendMirrorGitConfig(t, "url."+silent.URL+"/.insteadOf", "https://github.com/timeout/")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := h.c.git.snapshot(ctx, "timeout/repo")
	if err == nil {
		t.Fatal("silent upstream succeeded")
	}
	if time.Since(start) > time.Second {
		t.Fatalf("cancellation exceeded bound: %s", time.Since(start))
	}
}

func TestMirrorCredentialHelperScopesAndDoesNotPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("sentinel-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, host := range []string{"github.com", "evil.example", "github.com:443", "github.com.evil"} {
		var out strings.Builder
		err := mirrorCredential(path, "get", strings.NewReader("protocol=https\nhost="+host+"\n\n"), &out)
		if err != nil {
			t.Fatal(err)
		}
		if host == "github.com" && !strings.Contains(out.String(), "password=sentinel-token") {
			t.Fatal("permitted credential missing")
		}
		if host != "github.com" && out.Len() != 0 {
			t.Fatal("credential leaked to another authority")
		}
	}
	var out strings.Builder
	if err := mirrorCredential(path, "store", strings.NewReader("password=replacement\n"), &out); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	if string(b) != "sentinel-token\n" {
		t.Fatal("helper changed operator credential")
	}
}

func TestMirrorUseExtendsRetentionWithoutRenewingConfirmation(t *testing.T) {
	h := newMirrorHarness(t)
	ready := h.resolve(t, "HEAD")
	h.clock.Add(int64(13 * 24 * time.Hour))
	if err := mirrorRecordUse(h.c.options, "example/repo", ready.SelectedSHA); err != nil {
		t.Fatal(err)
	}
	h.c.mu.Lock()
	state := cloneMirrorState(h.c.repositories["example/repo"].state)
	h.c.mu.Unlock()
	before := state.Pins[ready.SelectedSHA].RetainUntil
	h.c.collectReaderUse("example/repo", &state)
	if !state.Pins[ready.SelectedSHA].RetainUntil.After(before) {
		t.Fatal("reader use did not extend retention")
	}
	if mirrorStamp(state.Refs["HEAD"].ConfirmedAt) != ready.OriginCheckedAt {
		t.Fatal("reader use renewed upstream confirmation")
	}
}

func TestMirrorReadLeasePreventsMaintenancePruning(t *testing.T) {
	h := newMirrorHarness(t)
	ready := h.resolve(t, "HEAD")
	h.c.mu.Lock()
	pin := h.c.repositories["example/repo"].state.Pins[ready.SelectedSHA]
	pin.RetainUntil = h.c.options.Now().Add(-time.Hour)
	h.c.repositories["example/repo"].state.Pins[ready.SelectedSHA] = pin
	h.c.mu.Unlock()
	release, err := mirrorReadLease(h.c.options, "example/repo")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err = h.c.maintain(ctx, "example/repo"); err == nil {
		t.Fatal("maintenance pruned while reader active")
	}
	release()
	if got := mirrorTestGit(t, mirrorRepoPath(h.c.options.Root, "example/repo"), "rev-parse", "refs/yuruna/pins/"+ready.SelectedSHA); got != ready.SelectedSHA {
		t.Fatal("active pin removed")
	}
}

func TestMirrorRawBoundAcceptsExactLimit(t *testing.T) {
	for _, length := range []int64{0, 3} {
		var out strings.Builder
		writer := mirrorCappedWriter{writer: &out, remaining: length}
		data := strings.Repeat("x", int(length))
		if _, err := writer.Write([]byte(data)); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte("x")); err == nil {
			t.Fatal("cap exceeded " + strconv.FormatInt(length, 10))
		}
	}
}
