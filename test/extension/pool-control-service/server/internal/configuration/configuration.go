// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42ce2c4f-afca-4820-915e-107f63163bbf

// Package configuration is the pool-control-service write/read layer. Rather than reimplement
// the git-clone + YAML + schema-validation + commit/push/rebase-retry logic, it
// SHELLS OUT to the battle-tested PowerShell pool-admin CLIs under <repo>/test/
// (pool/New-Pool.ps1, pool/Set-PoolRepository.ps1, ...). That reuses one authoritative
// implementation of the configuration contract and keeps this service thin.
package configuration

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// stateScript is the one read-only CLI. Every other CLI changes the
// configuration store, so it invalidates the cached read.
const stateScript = "pool/Get-PoolConfiguration.ps1"

// stateTTL bounds how long one configuration read answers the open read
// routes. Each read starts pwsh and takes the admin clone's exclusive lock, so
// a read per request let any client of the board queue processes behind it.
const stateTTL = 15 * time.Second

// stateReadTimeout bounds the shared read. It runs detached from the request
// that started it, so one client disconnecting cannot fail every caller
// waiting on the same read.
const stateReadTimeout = 2 * time.Minute

// maxConcurrentCLI caps the pwsh processes the CLIs run at once.
const maxConcurrentCLI = 4

// mutationTimeout bounds a configuration change. A change runs detached from the
// request that asked for it: the CLI commits, pushes and rebases in the admin
// clone, and killing pwsh because a browser tab closed would leave that clone
// mid-rebase for the next caller to trip over.
const mutationTimeout = 5 * time.Minute

// credentialInURL matches the userinfo of a URL (scheme://user:secret@), which a
// configuration git URL may carry and which CLI output can echo.
var credentialInURL = regexp.MustCompile(`([A-Za-z][A-Za-z0-9+.-]*://)[^/\s@'"]+@`)

// redactCredentials replaces the userinfo of every URL in s, so a credential in
// the configuration git URL is not repeated by a reply, the diagnostics page or
// the audit log. The CLI itself still receives the URL as configured.
func redactCredentials(s string) string {
	return credentialInURL.ReplaceAllString(s, "${1}***@")
}

// stateFlight is one configuration read in progress; every caller that
// arrives while it runs receives its result.
type stateFlight struct {
	done   chan struct{}
	result Result
}

// stateCache holds the last successful configuration read. generation moves
// on every invalidation, so a read that started before a change is not cached
// over it.
type stateCache struct {
	mu         sync.Mutex
	result     Result
	at         time.Time
	valid      bool
	generation uint64
	flight     *stateFlight
}

// Runner invokes the pool-admin CLIs via pwsh. RepoDir is the yuruna framework
// checkout (the CLIs live at RepoDir/test/pool/). ConfigurationGitUrl, when set, is
// forwarded as -ConfigurationGitUrl so the service is not bound to test.config.yml.
type Runner struct {
	Pwsh                string
	RepoDir             string
	ConfigurationGitUrl string
	// ConfigPath is an optional environment file re-read before every
	// invocation. The configuration URL is otherwise fixed at cloud-init bake time, so
	// correcting a wrong one would mean rebuilding the VM; with this an operator
	// edits the file, restarts nothing, and the next request uses the new value.
	ConfigPath string

	cache     stateCache
	slots     chan struct{}
	slotsOnce sync.Once
}

// cliSlots is the semaphore exec acquires; created on first use because a
// Runner is built as a struct literal.
func (r *Runner) cliSlots() chan struct{} {
	r.slotsOnce.Do(func() { r.slots = make(chan struct{}, maxConcurrentCLI) })
	return r.slots
}

// invalidateState drops the cached configuration read after a CLI that may
// have changed the store.
func (r *Runner) invalidateState() {
	r.cache.mu.Lock()
	r.cache.valid = false
	r.cache.generation++
	r.cache.mu.Unlock()
}

// configurationURLKey is the assignment the config file is scanned for. It matches the
// name the guest bring-up script writes, so the file the systemd unit reads and
// the file re-read here are the same one.
const configurationURLKey = "POOL_CONTROL_CONFIGURATION_GIT_URL="

// legacyConfigurationURLKey is accepted only while reading an existing guest's
// environment file. Newly written configuration always uses configurationURLKey.
const legacyConfigurationURLKey = "POOL_CONTROL_INTENT_GIT_URL="

// resolveConfigurationURL returns the live configuration URL: the ConfigPath value when the
// file supplies a non-empty one, else the value fixed at startup. An unreadable
// or key-less file is not an error -- it just means nothing overrides startup.
func (r *Runner) resolveConfigurationURL() string {
	if r.ConfigPath == "" {
		return r.ConfigurationGitUrl
	}
	b, err := os.ReadFile(r.ConfigPath)
	if err != nil {
		return r.ConfigurationGitUrl
	}
	canonicalPresent := false
	legacyURL := ""
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		key := configurationURLKey
		if strings.HasPrefix(line, configurationURLKey) {
			canonicalPresent = true
		} else if strings.HasPrefix(line, legacyConfigurationURLKey) {
			key = legacyConfigurationURLKey
		} else {
			continue
		}
		// Tolerate shell-style quoting; the guest writes bare values but an
		// operator hand-editing the file may well add quotes.
		v := strings.TrimSpace(strings.TrimPrefix(line, key))
		v = strings.Trim(v, `"'`)
		if key == configurationURLKey && v != "" {
			return v
		}
		if key == legacyConfigurationURLKey && legacyURL == "" {
			legacyURL = v
		}
	}
	if !canonicalPresent && legacyURL != "" {
		return legacyURL
	}
	return r.ConfigurationGitUrl
}

// ConfigurationURL exposes the live resolved configuration URL so the diagnostics report shows
// what the NEXT invocation will actually use, not what startup was told.
func (r *Runner) ConfigurationURL() string { return r.resolveConfigurationURL() }

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
// ConfigurationGitUrl is set, appends -ConfigurationGitUrl. It never blocks on prompts.
// script is relative to test/ and names its subfolder ("pool/New-Pool.ps1"),
// so a CLI that changes folders is one edit at the call site.
func (r *Runner) exec(ctx context.Context, script string, args ...string) Result {
	slots := r.cliSlots()
	select {
	case slots <- struct{}{}:
		defer func() { <-slots }()
	case <-ctx.Done():
		return Result{Exit: 1, Error: ctx.Err().Error()}
	}
	if script != stateScript {
		// Invalidated whatever the outcome: a CLI that failed after its commit
		// still changed the store.
		defer r.invalidateState()
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.WithoutCancel(ctx), mutationTimeout)
		defer cancel()
	}
	full := append([]string{"-NoProfile", "-NonInteractive", "-File", r.RepoDir + "/test/" + script}, args...)
	// Resolved per invocation, not captured at construction: the operator fix for
	// a wrong configuration URL is a file edit, and it must take effect without a restart.
	if url := r.resolveConfigurationURL(); url != "" {
		full = append(full, "-ConfigurationGitUrl", url)
	}
	cmd := exec.CommandContext(ctx, r.Pwsh, full...)
	// os.Environ() as the base, NOT a bare append onto the nil cmd.Env: a
	// non-nil Env REPLACES the inherited environment rather than extending it,
	// so the one-element slice handed the CLIs an empty PATH and HOME. git then
	// resolves to nothing and every configuration read fails well after the process
	// started, which reads like a configuration-store outage rather than a bad env.
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	started := time.Now()
	err := cmd.Run()
	argv := make([]string, 0, len(full)+1)
	for _, a := range append([]string{r.Pwsh}, full...) {
		argv = append(argv, redactCredentials(a))
	}
	// Stdout is not redacted: it is the CLI's document, relayed and parsed as
	// data (the configuration read, which a page edits and saves back).
	res := Result{
		Stdout:   out.String(),
		Stderr:   redactCredentials(errb.String()),
		Argv:     argv,
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
	// pool-admin CLIs report every failure on stdout: "No configuration store URL..."
	// reaches the operator instead of "exit status 1".
	msg := cliErrorFromStdout(out.String())
	if msg == "" {
		msg = strings.TrimSpace(errb.String())
	}
	if msg == "" {
		msg = err.Error()
	}
	res.Error = redactCredentials(msg)
	return res
}

// State runs Get-PoolConfiguration.ps1 (read-only) which emits a single JSON object
// {ok, pools, autoEnrollment} on stdout. Returned verbatim so the handler can relay it.
//
// A successful read answers for stateTTL, and concurrent callers share one
// read in progress; any other CLI invalidates the cached result.
func (r *Runner) State(ctx context.Context) Result {
	r.cache.mu.Lock()
	if r.cache.valid && time.Since(r.cache.at) < stateTTL {
		cached := r.cache.result
		r.cache.mu.Unlock()
		return cached
	}
	if f := r.cache.flight; f != nil {
		r.cache.mu.Unlock()
		select {
		case <-f.done:
			return f.result
		case <-ctx.Done():
			return Result{Exit: 1, Error: ctx.Err().Error()}
		}
	}
	f := &stateFlight{done: make(chan struct{})}
	r.cache.flight = f
	generation := r.cache.generation
	r.cache.mu.Unlock()

	readCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), stateReadTimeout)
	f.result = r.exec(readCtx, stateScript)
	cancel()

	r.cache.mu.Lock()
	if f.result.OK && r.cache.generation == generation {
		r.cache.result = f.result
		r.cache.at = time.Now()
		r.cache.valid = true
	}
	r.cache.flight = nil
	r.cache.mu.Unlock()
	close(f.done)
	return f.result
}

func (r *Runner) NewPool(ctx context.Context, poolID, displayName, configuredState string) Result {
	args := []string{"-PoolId", poolID}
	if displayName != "" {
		args = append(args, "-DisplayName", displayName)
	}
	if configuredState != "" {
		args = append(args, "-ConfiguredState", configuredState)
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

func (r *Runner) SetConfiguredState(ctx context.Context, poolID, state string) Result {
	// -State, not -ConfiguredState: the CLI names the parameter after the value it
	// takes, while New-Pool.ps1 (which sets the same field as one of several
	// properties) names it -ConfiguredState. A mismatch here is invisible until an
	// operator flips a pool and pwsh rejects the parameter at bind time.
	return r.exec(ctx, "pool/Set-PoolConfiguredState.ps1", "-PoolId", poolID, "-State", state)
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
