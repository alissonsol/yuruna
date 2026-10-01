// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package intent is the pool-control-service write/read layer. Rather than reimplement
// the git-clone + YAML + schema-validation + commit/push/rebase-retry logic, it
// SHELLS OUT to the battle-tested PowerShell pool-admin CLIs under <repo>/test/
// (pool/New-Pool.ps1, pool/Set-PoolRepository.ps1, ...). That reuses one authoritative
// implementation of the intent contract and keeps this service thin.
package intent

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Runner invokes the pool-admin CLIs via pwsh. RepoDir is the yuruna framework
// checkout (the CLIs live at RepoDir/test/pool/). IntentGitUrl, when set, is
// forwarded as -IntentGitUrl so the service is not bound to test.config.yml.
type Runner struct {
	Pwsh         string
	RepoDir      string
	IntentGitUrl string
	// ConfigPath is an optional environment file re-read before every
	// invocation. The intent URL is otherwise fixed at cloud-init bake time, so
	// correcting a wrong one would mean rebuilding the VM; with this an operator
	// edits the file, restarts nothing, and the next request uses the new value.
	ConfigPath string
}

// intentURLKey is the assignment the config file is scanned for. It matches the
// name the guest bring-up script writes, so the file the systemd unit reads and
// the file re-read here are the same one.
const intentURLKey = "POOL_CONTROL_INTENT_GIT_URL="

// resolveIntentURL returns the live intent URL: the ConfigPath value when the
// file supplies a non-empty one, else the value fixed at startup. An unreadable
// or key-less file is not an error -- it just means nothing overrides startup.
func (r *Runner) resolveIntentURL() string {
	if r.ConfigPath == "" {
		return r.IntentGitUrl
	}
	b, err := os.ReadFile(r.ConfigPath)
	if err != nil {
		return r.IntentGitUrl
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, intentURLKey) {
			continue
		}
		// Tolerate shell-style quoting; the guest writes bare values but an
		// operator hand-editing the file may well add quotes.
		v := strings.TrimSpace(strings.TrimPrefix(line, intentURLKey))
		v = strings.Trim(v, `"'`)
		if v != "" {
			return v
		}
	}
	return r.IntentGitUrl
}

// IntentURL exposes the live resolved intent URL so the diagnostics report shows
// what the NEXT invocation will actually use, not what startup was told.
func (r *Runner) IntentURL() string { return r.resolveIntentURL() }

// Result is the uniform outcome of a CLI invocation. Argv and Duration are
// carried for the diagnostics report: without the exact command line, a failing
// CLI is indistinguishable from a mis-assembled invocation.
type Result struct {
	OK       bool     `json:"ok"`
	Exit     int      `json:"exit"`
	Stdout   string   `json:"stdout,omitempty"`
	Stderr   string   `json:"stderr,omitempty"`
	Error    string   `json:"error,omitempty"`
	Argv     []string `json:"argv,omitempty"`
	Duration string   `json:"duration,omitempty"`
}

// cliErrorFromStdout extracts the message from the {ok:false,error:"..."}
// document the pool-admin CLIs print on STDOUT when they fail.
//
// Their contract is to report failure as that JSON plus a non-zero exit, and
// they write NOTHING to stderr. A caller that inspects only stderr therefore
// collapses every CLI-reported problem into the process-level "exit status 1"
// and discards the one string that says what to fix.
func cliErrorFromStdout(stdout string) string {
	s := strings.TrimSpace(stdout)
	if s == "" || !strings.HasPrefix(s, "{") {
		return ""
	}
	var doc struct {
		OK    *bool  `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(s), &doc); err != nil {
		return ""
	}
	if doc.OK != nil && *doc.OK {
		return ""
	}
	return strings.TrimSpace(doc.Error)
}

// exec runs `pwsh -NoProfile -File <RepoDir>/test/<script> <args...>` and, when
// IntentGitUrl is set, appends -IntentGitUrl. It never blocks on prompts.
// script is relative to test/ and names its subfolder ("pool/New-Pool.ps1"),
// so a CLI that changes folders is one edit at the call site.
func (r *Runner) exec(ctx context.Context, script string, args ...string) Result {
	full := append([]string{"-NoProfile", "-NonInteractive", "-File", r.RepoDir + "/test/" + script}, args...)
	// Resolved per invocation, not captured at construction: the operator fix for
	// a wrong intent URL is a file edit, and it must take effect without a restart.
	if url := r.resolveIntentURL(); url != "" {
		full = append(full, "-IntentGitUrl", url)
	}
	cmd := exec.CommandContext(ctx, r.Pwsh, full...)
	// os.Environ() as the base, NOT a bare append onto the nil cmd.Env: a
	// non-nil Env REPLACES the inherited environment rather than extending it,
	// so the one-element slice handed the CLIs an empty PATH and HOME. git then
	// resolves to nothing and every intent read fails well after the process
	// started, which reads like an intent-store outage rather than a bad env.
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	started := time.Now()
	err := cmd.Run()
	res := Result{
		Stdout:   out.String(),
		Stderr:   errb.String(),
		Argv:     append([]string{r.Pwsh}, full...),
		Duration: time.Since(started).Round(time.Millisecond).String(),
	}
	if err == nil {
		res.OK = true
		return res
	}
	res.Exit = 1
	if ee, ok := err.(*exec.ExitError); ok {
		res.Exit = ee.ExitCode()
	}
	// Prefer the CLI's own structured message (stdout), then any Write-Error
	// text (stderr), then the bare process error. Ordered this way because the
	// pool-admin CLIs report every failure on stdout: "No intent store URL..."
	// reaches the operator instead of "exit status 1".
	msg := cliErrorFromStdout(out.String())
	if msg == "" {
		msg = strings.TrimSpace(errb.String())
	}
	if msg == "" {
		msg = err.Error()
	}
	res.Error = msg
	return res
}

// State runs Get-PoolIntent.ps1 (read-only) which emits a single JSON object
// {ok, pools, autoEnrollment} on stdout. Returned verbatim so the handler can relay it.
func (r *Runner) State(ctx context.Context) Result { return r.exec(ctx, "pool/Get-PoolIntent.ps1") }

func (r *Runner) NewPool(ctx context.Context, poolID, displayName, desiredState string) Result {
	args := []string{"-PoolId", poolID}
	if displayName != "" {
		args = append(args, "-DisplayName", displayName)
	}
	if desiredState != "" {
		args = append(args, "-DesiredState", desiredState)
	}
	return r.exec(ctx, "pool/New-Pool.ps1", args...)
}

func (r *Runner) RemovePool(ctx context.Context, poolID string, force bool) Result {
	args := []string{"-PoolId", poolID}
	if force {
		args = append(args, "-Force")
	}
	return r.exec(ctx, "pool/Remove-Pool.ps1", args...)
}

func (r *Runner) SetDesiredState(ctx context.Context, poolID, state string) Result {
	// -State, not -DesiredState: the CLI names the parameter after the value it
	// takes, while New-Pool.ps1 (which sets the same field as one of several
	// properties) names it -DesiredState. A mismatch here is invisible until an
	// operator flips a pool and pwsh rejects the parameter at bind time.
	return r.exec(ctx, "pool/Set-PoolDesiredState.ps1", "-PoolId", poolID, "-State", state)
}

func (r *Runner) AddHost(ctx context.Context, poolID, hostID string, moveExisting ...bool) Result {
	args := []string{"-PoolId", poolID, "-HostId", hostID}
	if len(moveExisting) > 0 && moveExisting[0] {
		args = append(args, "-MoveExisting")
	}
	return r.exec(ctx, "pool/Add-HostToPool.ps1", args...)
}

func (r *Runner) RemoveHost(ctx context.Context, poolID, hostID string, exclude ...bool) Result {
	args := []string{"-HostId", hostID}
	if poolID != "" {
		args = append(args, "-PoolId", poolID)
	}
	if len(exclude) > 0 && exclude[0] {
		args = append(args, "-Exclude")
	}
	return r.exec(ctx, "pool/Remove-HostFromPool.ps1", args...)
}

func (r *Runner) MoveHostIdentity(ctx context.Context, oldID, newID string) Result {
	return r.exec(ctx, "pool/Move-PoolHostIdentity.ps1", "-OldHostId", oldID, "-NewHostId", newID)
}

// SetPoolRepositories points every member of the pool at one framework and
// project repository pair from its next cycle. Both URLs travel together: a
// runner that overrode only one of them would pair a framework with a project
// it was never tested against.
func (r *Runner) SetPoolRepositories(ctx context.Context, poolID, frameworkURL, projectURL string) Result {
	return r.exec(ctx, "pool/Set-PoolRepository.ps1", "-PoolId", poolID, "-FrameworkUrl", frameworkURL, "-ProjectUrl", projectURL)
}

// ClearPoolRepositories removes the pool's repository pair, so each member goes
// back to the repositories it configured for itself from its next cycle.
func (r *Runner) ClearPoolRepositories(ctx context.Context, poolID string) Result {
	return r.exec(ctx, "pool/Set-PoolRepository.ps1", "-PoolId", poolID, "-Clear")
}
