// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestMirrorFailureMetricsUseValidNames(t *testing.T) {
	c := &mirrorCoordinator{metrics: map[string]uint64{"checks_local-error": 2, "checks_auth-denied": 3},
		repositories: map[string]*mirrorRepository{}, jobs: map[string]*mirrorJob{}, workers: make(chan struct{}, 1)}
	text := c.metricsText()
	namePattern := regexp.MustCompile(`^[a-zA-Z_:][a-zA-Z0-9_:]*$`)
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		separator := strings.LastIndexByte(line, ' ')
		if separator < 0 {
			t.Fatalf("metric has no value: %q", line)
		}
		name := strings.SplitN(line[:separator], "{", 2)[0]
		if !namePattern.MatchString(name) {
			t.Fatalf("invalid Prometheus metric name %q", name)
		}
		if _, err := strconv.ParseFloat(line[separator+1:], 64); err != nil {
			t.Fatalf("invalid metric value: %q", line)
		}
	}
	for _, expected := range []string{"yuruna_git_mirror_checks_local_error_total 2", "yuruna_git_mirror_checks_auth_denied_total 3"} {
		if !strings.Contains(text, expected+"\n") {
			t.Errorf("missing normalized metric %q", expected)
		}
	}
}

func TestMirrorCommandDiagnosticsExcludeArgumentsAndStderr(t *testing.T) {
	const secret = "SENSITIVE_GIT_TOKEN_NEVER_LOG"
	g := &mirrorGit{options: mirrorOptions{Limits: defaultMirrorLimits()}, stdin: strings.NewReader("fixture usage\n--\n")}
	_, err := g.command(context.Background(), "", nil, "rev-parse", "--parseopt", "--", "--"+secret)
	err = mirrorWithPhase("snapshot", err)
	var failure *mirrorFailure
	if !errors.As(err, &failure) {
		t.Fatalf("missing safe command diagnostics: %v", err)
	}
	if failure.diagnostic.Phase != "snapshot" || failure.diagnostic.Operation != "rev-parse" || failure.diagnostic.ExitCode != 129 {
		t.Fatalf("wrong command diagnostics: %+v", failure.diagnostic)
	}
	encoded, _ := json.Marshal(failure.diagnostic)
	if strings.Contains(string(encoded)+err.Error(), secret) {
		t.Fatal("command arguments or stderr leaked through diagnostics")
	}
	_, err = g.command(context.Background(), "", nil, secret)
	if !errors.As(err, &failure) || failure.diagnostic.Operation != "other" || strings.Contains(err.Error(), secret) {
		t.Fatal("unrecognized command name was exposed")
	}
}

func TestMirrorCommandDiagnosticsReportOutputLimits(t *testing.T) {
	for _, tc := range []struct {
		name, argument string
		limit          int
	}{
		{"stdout", "--help", 4 << 20},
		{"stderr", "--unrecognized", 64 << 10},
	} {
		t.Run(tc.name, func(t *testing.T) {
			const secret = "SENSITIVE_GIT_OUTPUT_NEVER_LOG"
			g := &mirrorGit{options: mirrorOptions{Limits: defaultMirrorLimits()},
				stdin: strings.NewReader(secret + strings.Repeat("x", tc.limit+512) + "\n--\n")}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_, err := g.command(ctx, "", nil, "rev-parse", "--parseopt", "--", tc.argument)
			var failure *mirrorFailure
			if !errors.As(err, &failure) {
				t.Fatalf("output cap has no diagnostics: %v", err)
			}
			if failure.diagnostic.OutputLimit != tc.name {
				t.Fatalf("output cap was not diagnosed: %+v", failure.diagnostic)
			}
			encoded, _ := json.Marshal(failure.diagnostic)
			if strings.Contains(string(encoded)+err.Error(), secret) {
				t.Fatal("capped output leaked through diagnostics")
			}
		})
	}
}

func TestMirrorCommandDiagnosticsReportStartFailures(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	g := &mirrorGit{options: mirrorOptions{Limits: defaultMirrorLimits()}}
	_, err := g.command(context.Background(), "", nil, "fetch")
	var failure *mirrorFailure
	if !errors.As(err, &failure) || failure.diagnostic.ExitCode != -1 || failure.diagnostic.Failure != "git-not-found" {
		t.Fatalf("missing executable was not diagnosed safely: %v", err)
	}
}

func TestMirrorDiagnosticsPreserveWireOutcomes(t *testing.T) {
	for _, tc := range []struct {
		err     error
		outcome string
		detail  string
	}{
		{errors.New("git-local-error"), "local-error", "git-local-error"},
		{errors.New("mirror-auth-denied"), "auth-denied", "mirror-auth-denied"},
		{errors.New("mirror-upstream-unreachable"), "transport", "mirror-upstream-unreachable"},
		{context.DeadlineExceeded, "transport", "mirror-budget-exhausted"},
		{errMirrorBusy, "capacity", "storage"},
	} {
		outcome, detail := mirrorOutcome(mirrorWithPhase("fetch", tc.err))
		if outcome != tc.outcome || detail != tc.detail {
			t.Errorf("diagnostics changed wire outcome: %s/%s", outcome, detail)
		}
	}
}

func TestMirrorWorkerReportsFailurePhaseAndClearsItOnRecovery(t *testing.T) {
	h := newMirrorHarness(t)
	statePath := h.c.statePath("example/repo")
	if err := os.Mkdir(statePath, 0750); err != nil {
		t.Fatal(err)
	}
	var captured bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&captured)
	defer log.SetOutput(previous)
	failed := h.resolve(t, "HEAD")
	if failed.UpstreamOutcome != "local-error" || failed.Reason != "mirror-unavailable" || failed.Detail != "" || failed.ObjectReady {
		t.Fatalf("failure changed the receipt contract: %+v", failed)
	}
	rows := h.c.status()["repositories"].([]map[string]any)
	diagnostic, ok := rows[0]["diagnostic"].(*mirrorDiagnostic)
	if !ok || diagnostic.Phase != "persist" || diagnostic.ExitCode != -1 {
		t.Fatalf("status does not identify the failed phase: %+v", rows[0])
	}
	if !strings.Contains(captured.String(), "phase=persist") || strings.Contains(captured.String(), statePath) {
		t.Fatal("worker log omitted the phase or exposed the raw filesystem error")
	}
	if err := os.Remove(statePath); err != nil {
		t.Fatal(err)
	}
	h.clock.Add(int64(2 * time.Minute))
	if ready := h.resolve(t, "HEAD"); ready.Status != "ready" {
		t.Fatalf("worker did not recover: %+v", ready)
	}
	rows = h.c.status()["repositories"].([]map[string]any)
	if _, present := rows[0]["diagnostic"]; present {
		t.Fatal("successful refresh retained old failure diagnostics")
	}
}
