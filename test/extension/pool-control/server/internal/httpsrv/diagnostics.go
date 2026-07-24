// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// The pool-admin CLIs the daemon shells out to. A missing script here means the
// framework checkout the daemon was pointed at is incomplete or stale, which
// otherwise surfaces only as a per-operation "file not found" from pwsh.
var poolAdminCLIs = []string{
	"Get-PoolIntent.ps1",
	"New-Pool.ps1",
	"Remove-Pool.ps1",
	"Set-PoolDesiredState.ps1",
	"Add-HostToPool.ps1",
	"Remove-HostFromPool.ps1",
	"Set-PoolTestSet.ps1",
	"Set-PoolTestSetDefinition.ps1",
}

// Check is one pass/fail probe with the evidence that produced it.
type Check struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
	Hint   string `json:"hint,omitempty"`
}

// CommandProbe is the unabridged record of one CLI invocation: the exact argv,
// the exit code, and BOTH streams verbatim. The summary Check above compresses
// a failure to one line; this is what makes the failure actually debuggable,
// which is why stdout is kept even on success (the CLIs report their errors
// there, so a truncated stdout is a truncated error).
type CommandProbe struct {
	Argv     []string `json:"argv,omitempty"`
	ExitCode int      `json:"exitCode"`
	Duration string   `json:"duration,omitempty"`
	Stdout   string   `json:"stdout"`
	Stderr   string   `json:"stderr"`
}

// RuntimeReport is the daemon process itself: which build, running how long,
// listening where. Distinguishes "the fix was never deployed" from "the fix was
// deployed and did not work" -- the first thing to establish in a live outage.
type RuntimeReport struct {
	PID        int    `json:"pid"`
	Uptime     string `json:"uptime"`
	StartedAt  string `json:"startedAt"`
	ListenAddr string `json:"listenAddr"`
	OS         string `json:"os"`
	Arch       string `json:"arch"`
}

// Diagnostics is the whole-service report served at /api/diagnostics.
type Diagnostics struct {
	Version     string        `json:"version"`
	CollectedAt string        `json:"collectedAt"`
	Go          string        `json:"go"`
	OK          bool          `json:"ok"`
	Checks      []Check       `json:"checks"`
	Environment EnvReport     `json:"environment"`
	Runtime     RuntimeReport `json:"runtime"`
	// IntentProbe is the raw intent-read invocation behind the check of the
	// same name.
	IntentProbe CommandProbe `json:"intentProbe"`
	// Health is the persisted status the /healthz endpoint serves, folded in so
	// one fetch answers both "is the daemon working" and "was it ever working".
	Health any `json:"health,omitempty"`
}

// EnvReport is the daemon's own runtime context: the values it was launched
// with, plus the environment its child processes inherit. PATH is included
// because an empty one is invisible from outside yet breaks every CLI.
type EnvReport struct {
	PwshFlag      string `json:"pwshFlag"`
	PwshResolved  string `json:"pwshResolved,omitempty"`
	RepoDir       string `json:"repoDir"`
	StateDir      string `json:"stateDir"`
	AggregatorURL string `json:"aggregatorUrl"`
	HostID        string `json:"hostId"`
	IntentGitURL  string `json:"intentGitUrl"`
	User          string `json:"user"`
	PATH          string `json:"path"`
	HOME          string `json:"home"`
	// The checkout the CLIs are executed FROM, which can lag the daemon binary:
	// the binary is built once at bring-up while the checkout can be re-fetched
	// separately. Answers "is the fix actually deployed" for the script half.
	FrameworkVersion  string `json:"frameworkVersion,omitempty"`
	FrameworkRevision string `json:"frameworkRevision,omitempty"`
}

// redactURL strips any userinfo from a URL so a credential embedded in the
// intent git URL (https://user:token@host/repo) is not published by a page that
// has no authentication of its own. Non-URL values (a local path) pass through.
func redactURL(raw string) string {
	if raw == "" {
		return ""
	}
	at := strings.LastIndex(raw, "@")
	sep := strings.Index(raw, "://")
	if at < 0 || sep < 0 || at < sep {
		return raw
	}
	return raw[:sep+3] + "***@" + raw[at+1:]
}

// runProbe executes a short command purely to capture its output for the
// report. A probe never fails the request; its error becomes the detail.
func runProbe(ctx context.Context, name string, args ...string) (string, error) {
	pctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(pctx, name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// collectDiagnostics probes every dependency the daemon needs to serve a single
// UI request, in the order a request actually touches them: interpreter, then
// the CLI scripts, then git (the CLIs' own dependency), then persistence, then
// a live end-to-end intent read.
func (s *Server) collectDiagnostics(ctx context.Context) Diagnostics {
	d := Diagnostics{
		Version:     s.opts.Version,
		CollectedAt: time.Now().UTC().Format(time.RFC3339),
		Go:          runtime.Version(),
	}
	pwsh := s.opts.PwshPath
	if pwsh == "" {
		pwsh = "pwsh"
	}

	env := EnvReport{
		PwshFlag:      pwsh,
		RepoDir:       s.opts.RepoDir,
		StateDir:      s.opts.StateDir,
		AggregatorURL: s.opts.AggregatorURL,
		HostID:        s.opts.HostID,
		IntentGitURL:  redactURL(s.opts.IntentGitURL),
		PATH:          os.Getenv("PATH"),
		HOME:          os.Getenv("HOME"),
	}
	d.Runtime = RuntimeReport{
		PID:        os.Getpid(),
		Uptime:     time.Since(s.started).Round(time.Second).String(),
		StartedAt:  s.started.UTC().Format(time.RFC3339),
		ListenAddr: s.opts.Addr,
		OS:         runtime.GOOS,
		Arch:       runtime.GOARCH,
	}
	if s.state != nil && s.state.Enabled() {
		d.Health = s.state.Health()
	}
	// uid is always available; the name lookup needs /etc/passwd to be readable,
	// so it is additive rather than the only source.
	env.User = "uid " + strconv.Itoa(os.Getuid())
	if u, err := user.Current(); err == nil && u.Username != "" {
		env.User = u.Username + " (uid " + u.Uid + ")"
	}

	// 1. The interpreter. This is the check that catches an image whose package
	// feed carries no powershell build: the binary is simply absent and every
	// endpoint reports fork/exec ENOENT.
	resolved, lookErr := exec.LookPath(pwsh)
	if lookErr == nil {
		env.PwshResolved = resolved
		ver, err := runProbe(ctx, pwsh, "-NoProfile", "-NonInteractive", "-Command", "$PSVersionTable.PSVersion.ToString()")
		d.Checks = append(d.Checks, Check{
			Name:   "pwsh",
			OK:     err == nil,
			Detail: firstNonEmpty(ver, errText(err), "no output"),
			Hint:   hintIf(err != nil, "pwsh exists at "+resolved+" but did not run; check its shared-library dependencies."),
		})
	} else {
		d.Checks = append(d.Checks, Check{
			Name:   "pwsh",
			OK:     false,
			Detail: "not found: " + errText(lookErr),
			Hint:   "Install PowerShell in the guest. packages.microsoft.com has no powershell package for this Ubuntu release; use the GitHub-release tarball, then restart pool-control.service.",
		})
	}

	// 2. powershell-yaml -- the CLIs parse intent YAML with it, so its absence
	// fails every operation with a parse error rather than an import error.
	if lookErr == nil {
		out, err := runProbe(ctx, pwsh, "-NoProfile", "-NonInteractive", "-Command",
			"if (Get-Module -ListAvailable powershell-yaml) { 'present' } else { 'MISSING' }")
		d.Checks = append(d.Checks, Check{
			Name:   "powershell-yaml",
			OK:     err == nil && strings.Contains(out, "present"),
			Detail: firstNonEmpty(out, errText(err), "no output"),
			Hint:   hintIf(!strings.Contains(out, "present"), "Install-Module powershell-yaml -Scope AllUsers -Force"),
		})
	}

	// 3. The framework checkout and the CLI scripts inside it.
	d.Checks = append(d.Checks, s.checkRepoDir())
	if s.opts.RepoDir != "" {
		if b, err := os.ReadFile(filepath.Join(s.opts.RepoDir, "VERSION")); err == nil {
			env.FrameworkVersion = strings.TrimSpace(string(b))
		}
		if rev, err := runProbe(ctx, "git", "-C", s.opts.RepoDir, "rev-parse", "--short", "HEAD"); err == nil {
			env.FrameworkRevision = rev
		}
	}

	// 4. git -- the CLIs clone and push the pool-intent store through it.
	if gitPath, err := exec.LookPath("git"); err == nil {
		ver, verr := runProbe(ctx, "git", "--version")
		d.Checks = append(d.Checks, Check{
			Name: "git", OK: verr == nil,
			Detail: firstNonEmpty(ver, gitPath),
		})
	} else {
		d.Checks = append(d.Checks, Check{
			Name: "git", OK: false,
			Detail: "not found on PATH: " + errText(err),
			Hint:   "The pool-admin CLIs clone and push pool intent; install git in the guest.",
		})
	}

	// 5. Persistence. An unset state dir is a deliberate mode (no NAS), so it
	// reports OK with the reason rather than as a failure.
	d.Checks = append(d.Checks, s.checkStateDir())

	// 6. The intent store URL. Every read and write targets it, and an empty
	// value fails all of them identically -- so name it as its own check rather
	// than leaving it to be inferred from the CLI's error text. The LIVE value is
	// reported, not the launch flag: the runner re-reads its config file per
	// invocation, so the flag can be stale the moment an operator edits it.
	liveURL := strings.TrimSpace(s.liveIntentURL())
	env.IntentGitURL = redactURL(liveURL)
	if liveURL == "" {
		d.Checks = append(d.Checks, Check{
			Name: "intent-git-url", OK: false,
			Detail: "empty: no intent store resolved from the launch flag or the config file",
			Hint:   "The guest bring-up creates a writable store on the pool NAS when one is absent; an empty value here means the NAS was not mounted at bring-up. Set POOL_CONTROL_INTENT_GIT_URL in /etc/yuruna/pool-control.env (re-read per request, no restart needed), or pool.intentGitUrl in test/test.config.yml before rebuilding.",
		})
	} else {
		detail := redactURL(liveURL)
		if flag := strings.TrimSpace(s.opts.IntentGitURL); flag != liveURL {
			detail += "  (config file overrides the launch flag " + redactURL(flag) + ")"
		}
		d.Checks = append(d.Checks, Check{Name: "intent-git-url", OK: true, Detail: detail})
	}

	// 7. The store itself, when it is a local path (the pool NAS case). A URL the
	// daemon cannot write is the failure mode that only shows up on the first
	// mutation, long after the UI looked healthy, so probe it up front.
	d.Checks = append(d.Checks, checkIntentStore(liveURL))

	// 8. End-to-end: the same call the Assign page makes on load. This is the
	// check that reproduces the operator-visible symptom directly.
	res := s.intent.State(ctx)
	d.Checks = append(d.Checks, Check{
		Name:   "intent-read",
		OK:     res.OK,
		Detail: firstNonEmpty(strings.TrimSpace(res.Error), strings.TrimSpace(res.Stderr), truncate(strings.TrimSpace(res.Stdout), 400), "no output"),
		Hint:   hintIf(!res.OK, "See the raw invocation below for the CLI's own output; the checks above name any missing dependency."),
	})
	// The unabridged invocation. Argv and both streams are kept verbatim: the
	// summary line above is lossy by design, and this is the page's reason to
	// exist.
	d.IntentProbe = CommandProbe{
		Argv:     res.Argv,
		ExitCode: res.Exit,
		Duration: res.Duration,
		Stdout:   res.Stdout,
		Stderr:   res.Stderr,
	}

	d.Environment = env
	d.OK = true
	for _, c := range d.Checks {
		if !c.OK {
			d.OK = false
		}
	}
	return d
}

func (s *Server) checkRepoDir() Check {
	if s.opts.RepoDir == "" {
		return Check{Name: "repo-dir", OK: false, Detail: "not configured", Hint: "Pass --repo-dir pointing at the yuruna framework checkout."}
	}
	if _, err := os.Stat(s.opts.RepoDir); err != nil {
		return Check{Name: "repo-dir", OK: false, Detail: s.opts.RepoDir + ": " + errText(err),
			Hint: "The framework checkout is missing; re-run the guest bring-up script."}
	}
	var missing []string
	for _, cli := range poolAdminCLIs {
		if _, err := os.Stat(filepath.Join(s.opts.RepoDir, "test", cli)); err != nil {
			missing = append(missing, cli)
		}
	}
	if len(missing) > 0 {
		return Check{Name: "repo-dir", OK: false,
			Detail: s.opts.RepoDir + ": missing " + strings.Join(missing, ", "),
			Hint:   "The checkout is stale or partial; re-fetch the framework archive."}
	}
	return Check{Name: "repo-dir", OK: true, Detail: s.opts.RepoDir + ": all " + strconv.Itoa(len(poolAdminCLIs)) + " pool-admin CLIs present"}
}

// intentURLReporter is satisfied by intent.Runner. Declared as an optional
// interface rather than added to IntentAPI so a caller that only drives the
// pool-admin surface -- including the test fake -- is unaffected.
type intentURLReporter interface{ IntentURL() string }

// liveIntentURL is what the NEXT invocation will use: the runner's per-request
// resolution when it offers one, else the value startup was given.
func (s *Server) liveIntentURL() string {
	if r, ok := s.intent.(intentURLReporter); ok {
		if u := r.IntentURL(); u != "" {
			return u
		}
	}
	return s.opts.IntentGitURL
}

// checkIntentStore validates a LOCAL intent store (the pool NAS case). A remote
// URL is reported as not-locally-checkable rather than failed: reachability is
// then the intent-read check's job, and probing it here would just duplicate it.
func checkIntentStore(url string) Check {
	if url == "" {
		return Check{Name: "intent-store", OK: false, Detail: "no intent URL to check"}
	}
	if strings.Contains(url, "://") {
		hint := ""
		if strings.HasPrefix(url, "http://") || strings.HasPrefix(url, "https://") {
			// The proxy publishes the store through a plain apache Alias, which
			// serves fetches but cannot accept a push.
			hint = "An http(s) intent store is pull-only unless the server runs git-http-backend: reads will work and every write will fail at push. The writable store is the bare repo on the pool NAS."
		}
		return Check{Name: "intent-store", OK: true, Detail: "remote URL; reachability is covered by intent-read", Hint: hint}
	}
	if _, err := os.Stat(filepath.Join(url, "refs")); err != nil {
		return Check{Name: "intent-store", OK: false, Detail: url + ": not a bare git repo (" + errText(err) + ")",
			Hint: "The pool NAS store is created by the guest bring-up; if the NAS mounted late, re-run the bring-up script or git init --bare it."}
	}
	probe := filepath.Join(url, ".pool-control-write-probe")
	if err := os.WriteFile(probe, []byte("probe\n"), 0o600); err != nil {
		return Check{Name: "intent-store", OK: false, Detail: url + ": bare repo present but NOT writable: " + errText(err),
			Hint: "Writes will fail at push. Check the pool NAS mount's uid/gid against the service user."}
	}
	_ = os.Remove(probe)
	return Check{Name: "intent-store", OK: true, Detail: url + ": bare repo, writable"}
}

func (s *Server) checkStateDir() Check {
	if s.state == nil || !s.state.Enabled() {
		return Check{Name: "state-dir", OK: true, Detail: "persistence disabled (no state dir configured)",
			Hint: "The audit log and status.json are not being written; the pool NAS mount is what supplies this dir."}
	}
	dir := s.opts.StateDir
	if dir == "" {
		// The store is persisting somewhere the report was not told about, so
		// the path it names cannot be trusted -- say so rather than stat "".
		return Check{Name: "state-dir", OK: false, Detail: "store is enabled but no state dir was reported to the server",
			Hint: "Pass Options.StateDir alongside Options.Store so this check can probe the real path."}
	}
	if _, err := os.Stat(dir); err != nil {
		return Check{Name: "state-dir", OK: false, Detail: dir + ": " + errText(err),
			Hint: "The pool NAS mount is absent; the audit log is not durable."}
	}
	// Prove writability rather than inferring it from the mode: a cifs mount
	// maps ownership at mount time, so the mode alone can read as writable
	// while the server rejects the write.
	probe := filepath.Join(dir, ".pool-control-write-probe")
	if err := os.WriteFile(probe, []byte("probe\n"), 0o600); err != nil {
		return Check{Name: "state-dir", OK: false, Detail: dir + ": not writable: " + errText(err),
			Hint: "Check the mount's uid/gid options against the service user."}
	}
	_ = os.Remove(probe)
	return Check{Name: "state-dir", OK: true, Detail: dir + ": writable"}
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func hintIf(cond bool, hint string) string {
	if cond {
		return hint
	}
	return ""
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
