// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestMirrorRoutesReportUnavailableWithoutWorker(t *testing.T) {
	srv, _ := newDaemonWithGate(t, modeLocal, testBearer)
	for _, path := range []string{"/git-mirror/status.json", "/git-mirror/metrics"} {
		resp := get(t, srv, path)
		if resp.StatusCode != http.StatusServiceUnavailable {
			t.Errorf("%s: got %d, want unavailable", path, resp.StatusCode)
		}
	}
	resp := postJSON(t, srv, "/git-mirror/v1/resolve", `{"repository":"example/repo","ref":"HEAD","nonce":"AAAAAAAAAAAAAAAAAAAAAA"}`)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("resolve: got %d, want unavailable", resp.StatusCode)
	}
}

func TestMirrorPendingPollKeepsJobAndCallerNonce(t *testing.T) {
	h := newMirrorHarness(t)
	h.resolve(t, "HEAD")
	h.advance(t, "pending\n")
	h.c.options.Limits.Pending = 20 * time.Millisecond
	h.c.options.Limits.Handler = 200 * time.Millisecond
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	h.c.git.before = func(args []string) {
		if len(args) > 0 && args[0] == "fetch" {
			once.Do(func() { close(entered); <-release })
		}
	}
	server := mirrorTestHTTP(t, h)
	read := func(nonce, operation string) mirrorReceipt {
		t.Helper()
		body, _ := json.Marshal(mirrorRequest{Repository: "example/repo", Ref: "HEAD", Nonce: nonce, OperationID: operation})
		resp, err := server.Client().Post(server.URL+"/git-mirror/v1/resolve", "application/json", strings.NewReader(string(body)))
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		var envelope mirrorEnvelope
		if err = json.Unmarshal(b, &envelope); err != nil {
			t.Fatal(err)
		}
		payload, _ := base64.StdEncoding.DecodeString(envelope.Payload)
		var receipt mirrorReceipt
		if err = json.Unmarshal(payload, &receipt); err != nil {
			t.Fatalf("%s: %v", b, err)
		}
		return receipt
	}
	first := read("AAAAAAAAAAAAAAAAAAAAAA", "")
	<-entered
	second := read("BBBBBBBBBBBBBBBBBBBBBB", first.OperationID)
	if first.Status != "pending" || second.Status != "pending" || first.OperationID != second.OperationID || second.Nonce != "BBBBBBBBBBBBBBBBBBBBBB" {
		t.Fatalf("pending results %+v %+v", first, second)
	}
	if first.SelectedSHA != "" || first.OriginCheckedAt != "" || first.ObjectReady {
		t.Fatal("pending invented confirmed content")
	}
	close(release)
	h.c.mu.Lock()
	job := h.c.jobs[first.OperationID]
	h.c.mu.Unlock()
	<-job.done
	ready := read("CCCCCCCCCCCCCCCCCCCCCC", first.OperationID)
	if ready.Status != "ready" || ready.Nonce != "CCCCCCCCCCCCCCCCCCCCCC" {
		t.Fatalf("ready: %+v", ready)
	}
}

func TestMirrorResolverRejectsOversizeAndDuplicateRequests(t *testing.T) {
	h := newMirrorHarness(t)
	server := mirrorTestHTTP(t, h)
	for _, body := range []string{strings.Repeat(" ", 4097), `{"repository":"example/repo","repository":"other/repo","ref":"HEAD","nonce":"AAAAAAAAAAAAAAAAAAAAAA"}`} {
		resp, err := server.Client().Post(server.URL+"/git-mirror/v1/resolve", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 400 {
			t.Fatalf("invalid request status %d", resp.StatusCode)
		}
	}
}

func TestMirrorRegistrationRequiresExistingLabGate(t *testing.T) {
	srv, _ := newDaemonWithGate(t, modeLocal, testBearer)
	resp := postJSON(t, srv, "/api/git-mirror/repositories", `{"repository":"example/repo"}`)
	if resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden {
		t.Errorf("registration: got %d, want gate refusal", resp.StatusCode)
	}
}
