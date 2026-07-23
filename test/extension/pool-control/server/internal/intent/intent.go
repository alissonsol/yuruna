// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package intent is the pool-control write/read layer. Rather than reimplement
// the git-clone + YAML + schema-validation + commit/push/rebase-retry logic, it
// SHELLS OUT to the battle-tested PowerShell pool-admin CLIs under <repo>/test/
// (New-Pool.ps1, Set-PoolTestSet.ps1, ...). That reuses one authoritative
// implementation of the intent contract and keeps this service thin.
package intent

import (
	"context"
	"os/exec"
	"strings"
)

// Runner invokes the pool-admin CLIs via pwsh. RepoDir is the yuruna framework
// checkout (the CLIs live at RepoDir/test/*.ps1). IntentGitUrl, when set, is
// forwarded as -IntentGitUrl so the service is not bound to test.config.yml.
type Runner struct {
	Pwsh         string
	RepoDir      string
	IntentGitUrl string
}

// Result is the uniform outcome of a CLI invocation.
type Result struct {
	OK     bool   `json:"ok"`
	Exit   int    `json:"exit"`
	Stdout string `json:"stdout,omitempty"`
	Stderr string `json:"stderr,omitempty"`
	Error  string `json:"error,omitempty"`
}

// exec runs `pwsh -NoProfile -File <RepoDir>/test/<script> <args...>` and, when
// IntentGitUrl is set, appends -IntentGitUrl. It never blocks on prompts.
func (r *Runner) exec(ctx context.Context, script string, args ...string) Result {
	full := append([]string{"-NoProfile", "-NonInteractive", "-File", r.RepoDir + "/test/" + script}, args...)
	if r.IntentGitUrl != "" {
		full = append(full, "-IntentGitUrl", r.IntentGitUrl)
	}
	cmd := exec.CommandContext(ctx, r.Pwsh, full...)
	cmd.Env = append(cmd.Env, "GIT_TERMINAL_PROMPT=0")
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	res := Result{Stdout: out.String(), Stderr: errb.String()}
	if err == nil {
		res.OK = true
		return res
	}
	res.Exit = 1
	if ee, ok := err.(*exec.ExitError); ok {
		res.Exit = ee.ExitCode()
	}
	// Surface the CLI's own Write-Error text (stderr) as the client-facing error,
	// falling back to the process error.
	msg := strings.TrimSpace(errb.String())
	if msg == "" {
		msg = err.Error()
	}
	res.Error = msg
	return res
}

// State runs Get-PoolIntent.ps1 (read-only) which emits a single JSON object
// {ok, pools, testSets} on stdout. Returned verbatim so the handler can relay it.
func (r *Runner) State(ctx context.Context) Result { return r.exec(ctx, "Get-PoolIntent.ps1") }

func (r *Runner) NewPool(ctx context.Context, poolID, displayName, desiredState string) Result {
	args := []string{"-PoolId", poolID}
	if displayName != "" {
		args = append(args, "-DisplayName", displayName)
	}
	if desiredState != "" {
		args = append(args, "-DesiredState", desiredState)
	}
	return r.exec(ctx, "New-Pool.ps1", args...)
}

func (r *Runner) RemovePool(ctx context.Context, poolID string, force bool) Result {
	args := []string{"-PoolId", poolID}
	if force {
		args = append(args, "-Force")
	}
	return r.exec(ctx, "Remove-Pool.ps1", args...)
}

func (r *Runner) SetDesiredState(ctx context.Context, poolID, state string) Result {
	return r.exec(ctx, "Set-PoolDesiredState.ps1", "-PoolId", poolID, "-DesiredState", state)
}

func (r *Runner) AddHost(ctx context.Context, poolID, hostID string) Result {
	return r.exec(ctx, "Add-HostToPool.ps1", "-PoolId", poolID, "-HostId", hostID)
}

func (r *Runner) RemoveHost(ctx context.Context, poolID, hostID string) Result {
	return r.exec(ctx, "Remove-HostFromPool.ps1", "-PoolId", poolID, "-HostId", hostID)
}

// AssignTestSet copies a library test-set's triple into the pool's inline testSet.
func (r *Runner) AssignTestSet(ctx context.Context, poolID, name, frameworkURL, projectURL string) Result {
	return r.exec(ctx, "Set-PoolTestSet.ps1", "-PoolId", poolID, "-Name", name, "-FrameworkUrl", frameworkURL, "-ProjectUrl", projectURL)
}

func (r *Runner) SetTestSetDef(ctx context.Context, name, frameworkURL, projectURL string) Result {
	return r.exec(ctx, "Set-PoolTestSetDefinition.ps1", "-Name", name, "-FrameworkUrl", frameworkURL, "-ProjectUrl", projectURL)
}

func (r *Runner) DeleteTestSetDef(ctx context.Context, name string) Result {
	return r.exec(ctx, "Set-PoolTestSetDefinition.ps1", "-Name", name, "-Delete")
}
