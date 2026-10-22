// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cgi"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// CGI and credential subprocesses use the production entry point even when
// their executable is this test binary. No fixture signer is shipped.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && strings.HasPrefix(os.Args[1], "--mirror-role=") {
		main()
		return
	}
	os.Exit(m.Run())
}

type mirrorProcessFixture struct {
	Root                        string   `json:"root"`
	StateRoot                   string   `json:"stateRoot"`
	ReaderRoot                  string   `json:"readerRoot"`
	SigningKey                  string   `json:"signingKey"`
	NoUpstreamPath              string   `json:"noUpstreamPath"`
	Repositories                []string `json:"repositories"`
	Now                         string   `json:"now"`
	RefreshIntervalMilliseconds int      `json:"refreshIntervalMilliseconds"`
	ReadMilliseconds            int      `json:"readMilliseconds"`
}

func TestGitMirrorFixtureProcess(t *testing.T) {
	config := os.Getenv("YURUNA_GIT_MIRROR_FIXTURE_CONFIG")
	if config == "" {
		return
	}
	b, err := os.ReadFile(config)
	if err != nil {
		t.Fatal(err)
	}
	var input mirrorProcessFixture
	if err = strictMirrorJSON(b, &input, 64<<10); err != nil {
		t.Fatal(err)
	}
	options := mirrorOptions{Root: input.Root, StateRoot: input.StateRoot, ReaderRoot: input.ReaderRoot, SigningKey: input.SigningKey, NoUpstreamPath: input.NoUpstreamPath,
		Limits: defaultMirrorLimits(), Now: time.Now}
	options.Limits.ReserveBytes = 0
	options.Limits.CapBytes = 0
	if input.ReadMilliseconds > 0 {
		options.Limits.Read = time.Duration(input.ReadMilliseconds) * time.Millisecond
	}
	if input.Now != "" {
		fixed, e := time.Parse(time.RFC3339Nano, input.Now)
		if e != nil {
			t.Fatal(e)
		}
		options.Now = func() time.Time { return fixed }
	}
	if err = os.MkdirAll(input.StateRoot, 0750); err != nil {
		t.Fatal(err)
	}
	options.RepositoriesFile = filepath.Join(input.StateRoot, "fixture-repositories.json")
	list, _ := json.Marshal(mirrorRepositoryList{Repositories: input.Repositories})
	if err = os.WriteFile(options.RepositoriesFile, list, 0640); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	coordinator, err := newMirrorCoordinator(ctx, options)
	if err != nil {
		t.Fatal(err)
	}
	defer coordinator.close()
	if input.RefreshIntervalMilliseconds > 0 {
		coordinator.options.Limits.Refresh = time.Duration(input.RefreshIntervalMilliseconds) * time.Millisecond
		coordinator.startTimer()
	}
	mux := http.NewServeMux()
	mux.Handle("/git-mirror/", coordinator.routes())
	mux.Handle("/api/git-mirror/", coordinator.routes())
	mux.Handle("/git-raw/", newMirrorReader(options).routes())
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	mux.Handle("/git/", &cgi.Handler{Path: executable, Args: []string{"--mirror-role=cgi", "--mirror-root=" + options.Root, "--mirror-reader-root=" + options.ReaderRoot},
		Root: "/git", Env: []string{"GIT_PROJECT_ROOT=" + options.Root, "GIT_HTTP_EXPORT_ALL=1"}})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("Proxy-Authorization") != "" {
			http.Error(w, "credential forwarded to mirror fixture", http.StatusForbidden)
			return
		}
		mux.ServeHTTP(w, r)
	}))
	defer server.Close()
	ready, _ := json.Marshal(map[string]string{"baseURL": server.URL})
	fmt.Println(string(ready))
	_, _ = io.Copy(io.Discard, os.Stdin)
}
