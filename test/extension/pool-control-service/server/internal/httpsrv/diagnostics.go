// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"yuruna.com/test/extension/extension-sdk/i18n"
)

// The pool-admin CLIs the daemon shells out to, each relative to <RepoDir>/test/.
// A missing script here means the framework checkout the daemon was pointed at is
// incomplete or stale, which otherwise surfaces only as a per-operation "file not
// found" from pwsh. Paths rather than bare names so a CLI that moves to another
// folder is one edit here rather than a silent per-operation failure.
var poolAdminCLIs = []string{
	"pool/Get-PoolIntent.ps1",
	"pool/New-Pool.ps1",
	"pool/Remove-Pool.ps1",
	"pool/Set-PoolDesiredState.ps1",
	"pool/Add-HostToPool.ps1",
	"pool/Remove-HostFromPool.ps1",
	"pool/Set-PoolTestSet.ps1",
	"pool/Set-PoolTestSetDefinition.ps1",
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
func (s *Server) collectDiagnostics(ctx context.Context, locales ...i18n.Context) Diagnostics {
	locale := diagnosticLocale(locales)
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
			Detail: firstNonEmpty(ver, errText(err), Translate(locale, "pool.diagnostic_no_output", nil)),
			Hint:   hintIf(err != nil, Translate(locale, "pool.diagnostic_pwsh_execution", map[string]any{"path": resolved})),
		})
	} else {
		d.Checks = append(d.Checks, Check{
			Name:   "pwsh",
			OK:     false,
			Detail: Translate(locale, "pool.diagnostic_pwsh_not_found", map[string]any{"detail": errText(lookErr)}),
			Hint:   Translate(locale, "pool.diagnostic_install_pwsh", nil),
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
			Detail: firstNonEmpty(out, errText(err), Translate(locale, "pool.diagnostic_no_output", nil)),
			Hint:   hintIf(!strings.Contains(out, "present"), "Install-Module powershell-yaml -Scope AllUsers -Force"),
		})
	}

	// 3. The framework checkout and the CLI scripts inside it.
	d.Checks = append(d.Checks, s.checkRepoDir(locale))
	if s.opts.RepoDir != "" {
		if b, err := os.ReadFile(filepath.Join(s.opts.RepoDir, "VERSION")); err == nil {
			env.FrameworkVersion = strings.TrimSpace(string(b))
		}
		rev, revCheck := s.frameworkRevision(ctx, locale)
		env.FrameworkRevision = rev
		d.Checks = append(d.Checks, revCheck)
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
			Detail: Translate(locale, "pool.diagnostic_git_not_found", map[string]any{"detail": errText(err)}),
			Hint:   Translate(locale, "pool.diagnostic_install_git", nil),
		})
	}

	// 5. Persistence. An unset state dir is a deliberate mode (no NAS), so it
	// reports OK with the reason rather than as a failure.
	d.Checks = append(d.Checks, s.checkStateDir(locale))

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
			Detail: Translate(locale, "pool.diagnostic_intent_empty", nil),
			Hint:   Translate(locale, "pool.diagnostic_intent_configure", nil),
		})
	} else {
		detail := redactURL(liveURL)
		if flag := strings.TrimSpace(s.opts.IntentGitURL); flag != liveURL {
			detail += Translate(locale, "pool.diagnostic_intent_override", map[string]any{"flag": redactURL(flag)})
		}
		d.Checks = append(d.Checks, Check{Name: "intent-git-url", OK: true, Detail: detail})
	}

	// 7. The store itself, when it is a local path (the pool NAS case). A URL the
	// daemon cannot write is the failure mode that only shows up on the first
	// mutation, long after the UI looked healthy, so probe it up front.
	d.Checks = append(d.Checks, checkIntentStore(liveURL, locale))

	// 8. End-to-end: the same call the Assign page makes on load. This is the
	// check that reproduces the operator-visible symptom directly.
	res := s.intent.State(ctx)
	d.Checks = append(d.Checks, Check{
		Name:   "intent-read",
		OK:     res.OK,
		Detail: firstNonEmpty(strings.TrimSpace(res.Error), strings.TrimSpace(res.Stderr), truncate(strings.TrimSpace(res.Stdout), 400), Translate(locale, "pool.diagnostic_no_output", nil)),
		Hint:   hintIf(!res.OK, Translate(locale, "pool.diagnostic_raw_invocation", nil)),
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

// frameworkRevisionSidecar is the file the status service's archive endpoint
// carries at tree root. `git archive` strips .git/, so a guest that was brought
// up from a tarball has no repository to interrogate and every `git rev-parse`
// there fails; the sidecar is the only thing that can still name the commit the
// checkout was cut from.
const frameworkRevisionSidecar = ".yuruna-revision"

// A revision is a full object name or it is not provenance: an abbreviated
// value cannot be compared against a candidate commit without ambiguity, and
// two different commits can share a short prefix.
var fullObjectName = regexp.MustCompile(`^[0-9a-f]{40}$`)

// readRevisionSidecar returns the recorded commit, or an error naming why the
// file that is present cannot be trusted. An absent sidecar is neither: a
// normal Git checkout carries no sidecar and does not need one.
func readRevisionSidecar(repoDir string) (string, error) {
	f, err := os.Open(filepath.Join(repoDir, frameworkRevisionSidecar))
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	defer f.Close()
	// Bounded: a diagnostics request must not be able to pull an arbitrarily
	// large file into memory because something else was left at that path. One
	// object name plus a line ending fits many times over, and anything longer
	// fails the shape check below rather than being read to its end.
	b, err := io.ReadAll(io.LimitReader(f, 4096))
	if err != nil {
		return "", err
	}
	rev := strings.ToLower(strings.TrimSpace(string(b)))
	if !fullObjectName.MatchString(rev) {
		return "", errors.New("malformed revision " + strconv.Quote(truncate(rev, 80)) +
			"; expected one 40-character object name")
	}
	return rev, nil
}

// repoDirIsItsOwnGitCheckout reports whether RepoDir is the root of the working
// tree git would answer for, rather than a plain directory sitting inside
// someone else's repository. Symbolic links are resolved on both sides because
// a temp or home path is routinely a link to the real one, and the string forms
// would then differ for two names of the same directory.
func (s *Server) repoDirIsItsOwnGitCheckout(ctx context.Context) bool {
	out, err := runProbe(ctx, "git", "-C", s.opts.RepoDir, "rev-parse", "--show-toplevel")
	if err != nil {
		return false
	}
	top, err := filepath.EvalSymlinks(strings.TrimSpace(out))
	if err != nil {
		return false
	}
	repo, err := filepath.EvalSymlinks(s.opts.RepoDir)
	if err != nil {
		return false
	}
	return filepath.Clean(top) == filepath.Clean(repo)
}

// frameworkRevision resolves the commit the framework checkout holds and the
// check that reports how it was established. Git is authoritative when it can
// run; the sidecar answers for an archive-only checkout. The two disagreeing
// means the tree was overwritten from a different source than the sidecar
// describes, and an unresolvable revision means the deployment cannot be tied to
// any commit at all -- both are reported as failures with no revision rather
// than as a value a reader would take for proof.
func (s *Server) frameworkRevision(ctx context.Context, locales ...i18n.Context) (string, Check) {
	locale := diagnosticLocale(locales)
	const name = "framework-revision"
	gitRev := ""
	// Only when the repository git finds IS this checkout. Repository discovery
	// walks upward, so an extracted archive placed anywhere beneath a working
	// tree gets that tree's HEAD -- a commit this checkout does not contain, and
	// one that would otherwise be reported as proof or collide with the sidecar
	// as a false "mix of sources".
	if s.repoDirIsItsOwnGitCheckout(ctx) {
		if out, err := runProbe(ctx, "git", "-C", s.opts.RepoDir, "rev-parse", "HEAD"); err == nil {
			if v := strings.ToLower(strings.TrimSpace(out)); fullObjectName.MatchString(v) {
				gitRev = v
			}
		}
	}
	sidecar, err := readRevisionSidecar(s.opts.RepoDir)
	switch {
	case err != nil:
		return "", Check{Name: name, OK: false,
			Detail: frameworkRevisionSidecar + ": " + err.Error(),
			Hint:   Translate(locale, "pool.diagnostic_revision_corrupt", nil)}
	case gitRev != "" && sidecar != "" && gitRev != sidecar:
		return "", Check{Name: name, OK: false,
			Detail: Translate(locale, "pool.diagnostic_revision_conflict", map[string]any{"git": gitRev, "file": frameworkRevisionSidecar, "sidecar": sidecar}),
			Hint:   Translate(locale, "pool.diagnostic_revision_mixed", nil)}
	case gitRev != "":
		return gitRev, Check{Name: name, OK: true, Detail: Translate(locale, "pool.diagnostic_revision_git", map[string]any{"revision": gitRev})}
	case sidecar != "":
		return sidecar, Check{Name: name, OK: true, Detail: Translate(locale, "pool.diagnostic_revision_archive", map[string]any{"revision": sidecar, "file": frameworkRevisionSidecar})}
	default:
		return "", Check{Name: name, OK: false,
			Detail: Translate(locale, "pool.diagnostic_revision_no_source", map[string]any{"file": frameworkRevisionSidecar}),
			Hint:   Translate(locale, "pool.diagnostic_revision_missing", nil)}
	}
}

func (s *Server) checkRepoDir(locales ...i18n.Context) Check {
	locale := diagnosticLocale(locales)
	if s.opts.RepoDir == "" {
		return Check{Name: "repo-dir", OK: false, Detail: Translate(locale, "pool.diagnostic_not_configured", nil), Hint: Translate(locale, "pool.diagnostic_configure_repo", nil)}
	}
	if _, err := os.Stat(s.opts.RepoDir); err != nil {
		return Check{Name: "repo-dir", OK: false, Detail: s.opts.RepoDir + ": " + errText(err),
			Hint: Translate(locale, "pool.diagnostic_repo_missing", nil)}
	}
	var missing []string
	for _, cli := range poolAdminCLIs {
		if _, err := os.Stat(filepath.Join(s.opts.RepoDir, "test", cli)); err != nil {
			missing = append(missing, cli)
		}
	}
	if len(missing) > 0 {
		return Check{Name: "repo-dir", OK: false,
			Detail: Translate(locale, "pool.diagnostic_repo_missing_files", map[string]any{"path": s.opts.RepoDir, "files": strings.Join(missing, ", ")}),
			Hint:   Translate(locale, "pool.diagnostic_repo_partial", nil)}
	}
	return Check{Name: "repo-dir", OK: true, Detail: Translate(locale, "pool.diagnostic_repo_complete", map[string]any{"path": s.opts.RepoDir, "count": strconv.Itoa(len(poolAdminCLIs))})}
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
func checkIntentStore(url string, locales ...i18n.Context) Check {
	locale := diagnosticLocale(locales)
	if url == "" {
		return Check{Name: "intent-store", OK: false, Detail: Translate(locale, "pool.diagnostic_intent_absent", nil)}
	}
	if strings.Contains(url, "://") {
		hint := ""
		if strings.HasPrefix(url, "http://") || strings.HasPrefix(url, "https://") {
			// The proxy publishes the store through a plain apache Alias, which
			// serves fetches but cannot accept a push.
			hint = Translate(locale, "pool.diagnostic_intent_pull_only", nil)
		}
		return Check{Name: "intent-store", OK: true, Detail: Translate(locale, "pool.diagnostic_intent_remote", nil), Hint: hint}
	}
	if _, err := os.Stat(filepath.Join(url, "refs")); err != nil {
		return Check{Name: "intent-store", OK: false, Detail: Translate(locale, "pool.diagnostic_intent_not_bare", map[string]any{"path": url, "detail": errText(err)}),
			Hint: Translate(locale, "pool.diagnostic_intent_initialize", nil)}
	}
	probe := filepath.Join(url, ".pool-control-service-write-probe")
	if err := os.WriteFile(probe, []byte("probe\n"), 0o600); err != nil {
		return Check{Name: "intent-store", OK: false, Detail: Translate(locale, "pool.diagnostic_intent_not_writable", map[string]any{"path": url, "detail": errText(err)}),
			Hint: Translate(locale, "pool.diagnostic_intent_permission", nil)}
	}
	_ = os.Remove(probe)
	return Check{Name: "intent-store", OK: true, Detail: Translate(locale, "pool.diagnostic_intent_writable", map[string]any{"path": url})}
}

func (s *Server) checkStateDir(locales ...i18n.Context) Check {
	locale := diagnosticLocale(locales)
	if s.state == nil || !s.state.Enabled() {
		return Check{Name: "state-dir", OK: true, Detail: Translate(locale, "pool.diagnostic_persistence_disabled", nil),
			Hint: Translate(locale, "pool.diagnostic_persistence_logs_missing", nil)}
	}
	dir := s.opts.StateDir
	if dir == "" {
		// The store is persisting somewhere the report was not told about, so
		// the path it names cannot be trusted -- say so rather than stat "".
		return Check{Name: "state-dir", OK: false, Detail: Translate(locale, "pool.diagnostic_persistence_unknown", nil),
			Hint: Translate(locale, "pool.diagnostic_persistence_configure", nil)}
	}
	if _, err := os.Stat(dir); err != nil {
		return Check{Name: "state-dir", OK: false, Detail: dir + ": " + errText(err),
			Hint: Translate(locale, "pool.diagnostic_persistence_nas_missing", nil)}
	}
	// Prove writability rather than inferring it from the mode: a cifs mount
	// maps ownership at mount time, so the mode alone can read as writable
	// while the server rejects the write.
	probe := filepath.Join(dir, ".pool-control-service-write-probe")
	if err := os.WriteFile(probe, []byte("probe\n"), 0o600); err != nil {
		return Check{Name: "state-dir", OK: false, Detail: Translate(locale, "pool.diagnostic_state_not_writable", map[string]any{"path": dir, "detail": errText(err)}),
			Hint: Translate(locale, "pool.diagnostic_persistence_permission", nil)}
	}
	_ = os.Remove(probe)
	return Check{Name: "state-dir", OK: true, Detail: Translate(locale, "pool.diagnostic_state_writable", map[string]any{"path": dir})}
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

func diagnosticLocale(locales []i18n.Context) i18n.Context {
	if len(locales) > 0 && locales[0].ResolvedTag != "" {
		return locales[0]
	}
	return i18n.Context{ResolvedTag: "en-US"}
}
