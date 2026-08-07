// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"time"
)

// The diagnostics surface exists for one question the catalog cannot answer:
// "why does a best-effort family not work on THIS agent". The catalog collapses
// every resolver failure into one availability answer -- deliberately, so hosts
// have one behavior -- which leaves the operator with nothing to act on when
// the answer is "unavailable". This report is the other half: the environment
// the resolver runs in and the full capture of its last run, readable from the
// UI instead of from an SSH session into the guest.

// pwshProbeInterval bounds how often the interpreter version is re-probed. The
// probe starts a child (a .NET runtime), so it must not run per render; it also
// must not be probed once forever, because "pwsh was installed after boot" is a
// state worth noticing without a daemon restart.
const pwshProbeInterval = 5 * time.Minute

// pwshProbeTimeout bounds one version probe.
const pwshProbeTimeout = 15 * time.Second

// InterpreterDiagnostics reports the PowerShell interpreter as this agent sees
// it: what is configured, what that resolves to on PATH, and what it says it is.
type InterpreterDiagnostics struct {
	Argv         []string `json:"argv"`
	ResolvedPath string   `json:"resolvedPath,omitempty"`
	Error        string   `json:"error,omitempty"`
	Version      string   `json:"version,omitempty"`
	VersionError string   `json:"versionError,omitempty"`
}

// ScriptDiagnostics reports the vendored Fido.ps1 as installed on this agent.
// The SHA-256 is the load-bearing field: the host scripts pin the release by
// hash, so this is what lets an operator confirm the agent runs the same bytes.
type ScriptDiagnostics struct {
	Path        string `json:"path,omitempty"`
	Error       string `json:"error,omitempty"`
	SizeBytes   int64  `json:"sizeBytes,omitempty"`
	SHA256      string `json:"sha256,omitempty"`
	ModifiedUTC string `json:"modifiedUtc,omitempty"`
}

// RememberedFailure is the failure currently holding the Windows family
// unavailable, with when it expires -- the answer to "why is the family down
// NOW and when will it retry on its own".
type RememberedFailure struct {
	Error      string `json:"error"`
	AtUTC      string `json:"atUtc"`
	ExpiresUTC string `json:"expiresUtc"`
}

// ImageError is one remembered per-key refresh failure.
type ImageError struct {
	Key   string `json:"key"`
	Error string `json:"error"`
	AtUTC string `json:"atUtc"`
}

// DiagnosticsReport is everything the diagnostics page renders.
type DiagnosticsReport struct {
	AsOfUTC string `json:"asOfUtc"`
	// GOOS/GOARCH say what the daemon was built for; OS and Kernel say what the
	// guest actually runs. The distinction matters: the resolver's viability is
	// a property of the guest OS, not of the Go build.
	GOOS   string `json:"goos"`
	GOARCH string `json:"goarch"`
	OS     string `json:"os,omitempty"`
	Kernel string `json:"kernel,omitempty"`

	PoolDir       string `json:"poolDir"`
	PoolAvailable bool   `json:"poolAvailable"`
	ProxyHTTP     string `json:"proxyHttp,omitempty"`
	ProxyHTTPS    string `json:"proxyHttps,omitempty"`
	ProxyCASet    bool   `json:"proxyCaSet"`

	Interpreter InterpreterDiagnostics `json:"interpreter"`
	Script      ScriptDiagnostics      `json:"script"`

	BestEffort        []FamilyStatus     `json:"bestEffort"`
	RememberedFailure *RememberedFailure `json:"rememberedFailure,omitempty"`
	LastFidoAttempt   *FidoAttempt       `json:"lastFidoAttempt,omitempty"`
	RecentErrors      []ImageError       `json:"recentErrors,omitempty"`
}

// noteFidoAttempt remembers the most recent Fido run, whatever started it.
func (a *Agent) noteFidoAttempt(at FidoAttempt) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.lastFidoAttempt = &at
}

// FidoTest runs one real Fido resolve for a pool arch and returns the full
// capture. It mints a URL and downloads nothing, so it is safe to run while a
// download is in flight. The outcome ALSO feeds the family's remembered
// failure, in both directions: a failed test re-arms it, and a successful test
// clears it -- an operator who just fixed the guest should see the family come
// back on the spot, not after the failure TTL runs out.
func (a *Agent) FidoTest(ctx context.Context, arch string) (FidoAttempt, error) {
	fidoArch, ok := fidoArchFor(arch)
	if !ok {
		return FidoAttempt{}, fmt.Errorf("no Fido architecture for %q", arch)
	}
	at := a.resolver.Fido.Attempt(ctx, fidoArch)
	if at.Error != "" {
		a.noteFidoOutcome(fmt.Errorf("%s", at.Error))
	} else {
		a.noteFidoOutcome(nil)
	}
	return at, nil
}

// Diagnostics assembles the report. Cheap by design: the only child it can
// start is the rate-limited interpreter version probe; everything else is
// lookups and small file reads.
func (a *Agent) Diagnostics(ctx context.Context) DiagnosticsReport {
	now := a.now()
	rep := DiagnosticsReport{
		AsOfUTC:       now.UTC().Format(time.RFC3339),
		GOOS:          runtime.GOOS,
		GOARCH:        runtime.GOARCH,
		OS:            osPrettyName(),
		Kernel:        kernelRelease(),
		PoolDir:       a.opts.PoolDir,
		PoolAvailable: a.store.Available(),
		ProxyHTTP:     strings.TrimSpace(a.opts.ProxyHTTP),
		ProxyHTTPS:    strings.TrimSpace(a.opts.ProxyHTTPS),
		ProxyCASet:    strings.TrimSpace(a.opts.ProxyCA) != "",
		Interpreter:   a.interpreterDiagnostics(ctx),
		Script:        scriptDiagnostics(a.resolver.Fido),
		BestEffort:    a.BestEffortStatus(),
	}

	a.mu.Lock()
	if a.fidoErr != "" && now.Sub(a.fidoErrAt) < fidoFailureTTL {
		rep.RememberedFailure = &RememberedFailure{
			Error:      a.fidoErr,
			AtUTC:      a.fidoErrAt.UTC().Format(time.RFC3339),
			ExpiresUTC: a.fidoErrAt.Add(fidoFailureTTL).UTC().Format(time.RFC3339),
		}
	}
	if a.lastFidoAttempt != nil {
		at := *a.lastFidoAttempt
		rep.LastFidoAttempt = &at
	}
	for key, msg := range a.lastErr {
		rep.RecentErrors = append(rep.RecentErrors, ImageError{
			Key:   key,
			Error: msg,
			AtUTC: a.lastErrAt[key].UTC().Format(time.RFC3339),
		})
	}
	a.mu.Unlock()
	// Newest first: the row that explains the current symptom belongs on top.
	sort.Slice(rep.RecentErrors, func(i, j int) bool {
		if rep.RecentErrors[i].AtUTC != rep.RecentErrors[j].AtUTC {
			return rep.RecentErrors[i].AtUTC > rep.RecentErrors[j].AtUTC
		}
		return rep.RecentErrors[i].Key < rep.RecentErrors[j].Key
	})
	return rep
}

// interpreterDiagnostics resolves the configured interpreter and, rate-limited,
// asks it for its version. The version answer is cached on the agent because a
// .NET runtime startup is far too heavy to pay per page render.
func (a *Agent) interpreterDiagnostics(ctx context.Context) InterpreterDiagnostics {
	fido := a.resolver.Fido
	argv := fido.Interpreter
	if len(argv) == 0 {
		argv = defaultInterpreter
	}
	d := InterpreterDiagnostics{Argv: argv}
	resolved, err := exec.LookPath(argv[0])
	if err != nil {
		d.Error = err.Error()
		return d
	}
	d.ResolvedPath = resolved

	a.mu.Lock()
	fresh := !a.pwshProbedAt.IsZero() && a.now().Sub(a.pwshProbedAt) < pwshProbeInterval
	version, versionErr := a.pwshVersion, a.pwshVersionErr
	if !fresh {
		a.pwshProbedAt = a.now()
	}
	a.mu.Unlock()
	if fresh {
		d.Version, d.VersionError = version, versionErr
		return d
	}

	version, versionErr = probeInterpreterVersion(ctx, resolved)
	a.mu.Lock()
	a.pwshVersion, a.pwshVersionErr = version, versionErr
	a.mu.Unlock()
	d.Version, d.VersionError = version, versionErr
	return d
}

// probeInterpreterVersion runs `<interpreter> --version` and keeps the first
// line. --version rather than a script: it answers in one process with no
// profile, and every interpreter this agent would ever configure supports it.
func probeInterpreterVersion(ctx context.Context, path string) (version, probeErr string) {
	runCtx, cancel := context.WithTimeout(ctx, pwshProbeTimeout)
	defer cancel()
	out := &cappedBuffer{limit: 4 << 10}
	cmd := exec.CommandContext(runCtx, path, "--version")
	cmd.Stdout = out
	cmd.Stderr = io.Discard
	cmd.WaitDelay = fidoWaitDelay
	if err := cmd.Run(); err != nil {
		return "", err.Error()
	}
	return briefly(out.String()), ""
}

// scriptDiagnostics stats and hashes the vendored Fido.ps1. Hashing a ~1 MB
// script is cheap enough to do per request, and a live hash is the only answer
// that cannot go stale.
func scriptDiagnostics(fido FidoConfig) ScriptDiagnostics {
	path, err := fido.script()
	if err != nil {
		return ScriptDiagnostics{Error: err.Error()}
	}
	d := ScriptDiagnostics{Path: path}
	fi, err := os.Stat(path)
	if err != nil {
		d.Error = err.Error()
		return d
	}
	d.SizeBytes = fi.Size()
	d.ModifiedUTC = fi.ModTime().UTC().Format(time.RFC3339)
	f, err := os.Open(path)
	if err != nil {
		d.Error = err.Error()
		return d
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		d.Error = err.Error()
		return d
	}
	d.SHA256 = hex.EncodeToString(h.Sum(nil))
	return d
}

// osPrettyName reads the guest's os-release PRETTY_NAME; empty when the
// platform has none (or the daemon runs outside a guest, as in the suite).
func osPrettyName() string {
	b, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
			return strings.Trim(strings.TrimSpace(v), `"`)
		}
	}
	return ""
}

// kernelRelease reads the running kernel version; empty off Linux.
func kernelRelease() string {
	b, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}
