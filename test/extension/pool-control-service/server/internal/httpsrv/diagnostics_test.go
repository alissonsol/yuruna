// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"pool-control-service/internal/intent"
)

func checkByName(t *testing.T, d Diagnostics, name string) Check {
	t.Helper()
	for _, c := range d.Checks {
		if c.Name == name {
			return c
		}
	}
	t.Fatalf("no %q check in report (have %d checks)", name, len(d.Checks))
	return Check{}
}

// A missing interpreter is the exact outage this page exists to explain, so the
// report has to render it as a failing check rather than failing to render.
func TestDiagnosticsReportsMissingPwsh(t *testing.T) {
	f := &fakeIntent{stateRes: intent.Result{OK: false, Error: "fork/exec: no such file or directory"}}
	s := New(f, Options{Version: "test", PwshPath: filepath.Join(t.TempDir(), "definitely-absent-pwsh")})

	d := s.collectDiagnostics(context.Background())
	if d.OK {
		t.Fatal("report OK with an absent pwsh; expected overall failure")
	}
	if c := checkByName(t, d, "pwsh"); c.OK {
		t.Errorf("pwsh check passed with an absent binary: %+v", c)
	} else if c.Hint == "" {
		t.Error("failing pwsh check carries no remediation hint")
	}
	// The end-to-end probe must still run and surface the CLI's own error.
	if c := checkByName(t, d, "intent-read"); c.OK {
		t.Error("intent-read passed while the interpreter is missing")
	}
}

// The endpoint answers 200 even when checks fail: the report IS the payload,
// and a non-200 would leave the page unable to render during an outage.
func TestDiagnosticsEndpointServes200WhenFailing(t *testing.T) {
	f := &fakeIntent{stateRes: intent.Result{OK: false, Error: "boom"}}
	srv := httptest.NewServer(New(f, Options{
		Version:  "test",
		PwshPath: filepath.Join(t.TempDir(), "absent"),
	}).Handler())
	defer srv.Close()

	resp, body := do(t, "GET", srv.URL+"/api/diagnostics", "")
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if body["ok"] != false {
		t.Errorf("ok = %v, want false", body["ok"])
	}
	if _, ok := body["checks"]; !ok {
		t.Error("payload carries no checks array")
	}
	if _, ok := body["environment"]; !ok {
		t.Error("payload carries no environment block")
	}
}

// repo-dir must fail when the checkout is missing the pool-admin CLIs, since a
// partial checkout otherwise surfaces only as a per-operation file-not-found.
func TestDiagnosticsRepoDirDetectsMissingCLIs(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "test"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Only one of the CLIs present -- the rest must be reported missing.
	writeCLI(t, dir, poolAdminCLIs[0])
	s := New(&fakeIntent{}, Options{Version: "test", RepoDir: dir})

	c := checkByName(t, s.collectDiagnostics(context.Background()), "repo-dir")
	if c.OK {
		t.Fatal("repo-dir passed with an incomplete checkout")
	}
	if !strings.Contains(c.Detail, "New-Pool.ps1") {
		t.Errorf("detail does not name a missing CLI: %q", c.Detail)
	}
}

// writeCLI plants one pool-admin CLI in a fake checkout. The list entries carry
// their subdirectory, so the parent has to be made rather than assumed.
func writeCLI(t *testing.T, repoDir, cli string) {
	t.Helper()
	path := filepath.Join(repoDir, "test", cli)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A complete checkout passes, so the check is not merely always-failing.
func TestDiagnosticsRepoDirPassesWhenComplete(t *testing.T) {
	dir := t.TempDir()
	for _, cli := range poolAdminCLIs {
		writeCLI(t, dir, cli)
	}
	s := New(&fakeIntent{}, Options{Version: "test", RepoDir: dir})

	if c := checkByName(t, s.collectDiagnostics(context.Background()), "repo-dir"); !c.OK {
		t.Errorf("repo-dir failed with a complete checkout: %+v", c)
	}
}

// An empty --intent-git-url fails every read and write identically, so it gets
// named as its own check rather than left to be inferred from CLI error text.
func TestDiagnosticsFlagsEmptyIntentGitURL(t *testing.T) {
	s := New(&fakeIntent{}, Options{Version: "test"})

	c := checkByName(t, s.collectDiagnostics(context.Background()), "intent-git-url")
	if c.OK {
		t.Fatal("intent-git-url passed while empty")
	}
	if !strings.Contains(c.Hint, "pool.intentGitUrl") {
		t.Errorf("hint does not name the config key to set: %q", c.Hint)
	}
}

// A credential embedded in the intent URL must not be published by a page that
// has no authentication of its own.
func TestDiagnosticsRedactsIntentURLCredentials(t *testing.T) {
	s := New(&fakeIntent{}, Options{
		Version:      "test",
		IntentGitURL: "https://alice:ghp_supersecrettoken@github.com/org/pool-intent.git",
	})
	d := s.collectDiagnostics(context.Background())

	if strings.Contains(d.Environment.IntentGitURL, "ghp_supersecrettoken") {
		t.Errorf("token leaked into the report: %q", d.Environment.IntentGitURL)
	}
	if !strings.Contains(d.Environment.IntentGitURL, "github.com/org/pool-intent.git") {
		t.Errorf("redaction destroyed the useful part: %q", d.Environment.IntentGitURL)
	}
	if c := checkByName(t, d, "intent-git-url"); strings.Contains(c.Detail, "ghp_supersecrettoken") {
		t.Errorf("token leaked into the check detail: %q", c.Detail)
	}
}

// A local path is not a URL and must survive redaction untouched.
func TestDiagnosticsLeavesLocalIntentPathIntact(t *testing.T) {
	const p = "/var/lib/yuruna/pool-intent.git"
	s := New(&fakeIntent{}, Options{Version: "test", IntentGitURL: p})

	if got := s.collectDiagnostics(context.Background()).Environment.IntentGitURL; got != p {
		t.Errorf("intentGitUrl = %q, want %q", got, p)
	}
}

// The raw probe is the page's reason to exist: argv and both streams verbatim,
// so a failure is debuggable rather than merely reported.
func TestDiagnosticsCarriesRawIntentProbe(t *testing.T) {
	f := &fakeIntent{stateRes: intent.Result{
		OK:       false,
		Exit:     1,
		Stdout:   `{"ok":false,"error":"No intent store URL."}`,
		Argv:     []string{"/usr/bin/pwsh", "-NoProfile", "-File", "/repo/test/pool/Get-PoolIntent.ps1"},
		Duration: "1.2s",
	}}
	d := New(f, Options{Version: "test"}).collectDiagnostics(context.Background())

	if d.IntentProbe.ExitCode != 1 {
		t.Errorf("exit code = %d, want 1", d.IntentProbe.ExitCode)
	}
	if !strings.Contains(d.IntentProbe.Stdout, "No intent store URL.") {
		t.Errorf("probe dropped the CLI's stdout: %q", d.IntentProbe.Stdout)
	}
	if len(d.IntentProbe.Argv) == 0 {
		t.Error("probe carries no argv")
	}
	if d.IntentProbe.Duration != "1.2s" {
		t.Errorf("duration = %q, want 1.2s", d.IntentProbe.Duration)
	}
}

// Runtime facts establish whether a fix was deployed at all.
func TestDiagnosticsReportsRuntimeFacts(t *testing.T) {
	d := New(&fakeIntent{}, Options{Version: "test", Addr: "0.0.0.0:80"}).
		collectDiagnostics(context.Background())

	if d.Runtime.PID == 0 {
		t.Error("no pid reported")
	}
	if d.Runtime.ListenAddr != "0.0.0.0:80" {
		t.Errorf("listenAddr = %q, want 0.0.0.0:80", d.Runtime.ListenAddr)
	}
	if d.Runtime.StartedAt == "" || d.Runtime.Uptime == "" {
		t.Error("no start time / uptime reported")
	}
}

// The pool NAS store is a local bare repo, so it can be validated directly --
// catching an unwritable store before the first mutation rather than after.
func TestCheckIntentStoreLocalBareRepo(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "pool-intent.git")
	if err := os.MkdirAll(filepath.Join(store, "refs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if c := checkIntentStore(store); !c.OK {
		t.Errorf("a writable bare repo failed the check: %+v", c)
	}

	missing := filepath.Join(dir, "absent.git")
	if c := checkIntentStore(missing); c.OK {
		t.Errorf("a nonexistent store passed the check: %+v", c)
	}
}

// An http(s) store is pull-only through the proxy's plain apache Alias, so the
// check has to say so -- reads succeeding is exactly what hides this until the
// first write.
func TestCheckIntentStoreWarnsOnPullOnlyHTTP(t *testing.T) {
	c := checkIntentStore("http://192.0.2.10/pool-intent.git")
	if !c.OK {
		t.Errorf("a remote URL should not fail locally: %+v", c)
	}
	if !strings.Contains(c.Hint, "pull-only") {
		t.Errorf("no pull-only warning for an http store: %q", c.Hint)
	}
}

// The report must show what the NEXT call will use, not what startup was told,
// because the runner re-resolves per invocation.
func TestDiagnosticsReportsLiveIntentURL(t *testing.T) {
	f := &fakeIntentWithURL{fakeIntent: fakeIntent{}, url: "/mnt/yuruna-pool/pool-intent.git"}
	d := New(f, Options{Version: "test", IntentGitURL: "/stale/from/launch.git"}).
		collectDiagnostics(context.Background())

	if d.Environment.IntentGitURL != "/mnt/yuruna-pool/pool-intent.git" {
		t.Errorf("intentGitUrl = %q, want the live resolved value", d.Environment.IntentGitURL)
	}
	c := checkByName(t, d, "intent-git-url")
	if !strings.Contains(c.Detail, "overrides the launch flag") {
		t.Errorf("detail does not flag the override: %q", c.Detail)
	}
}

// fakeIntentWithURL adds the optional IntentURL reporter that intent.Runner
// satisfies in production.
type fakeIntentWithURL struct {
	fakeIntent
	url string
}

func (f *fakeIntentWithURL) IntentURL() string { return f.url }

// With no state dir the daemon is deliberately non-persistent, so the check
// reports OK-with-reason instead of dragging the whole report to failed.
func TestDiagnosticsStateDirDisabledIsNotAFailure(t *testing.T) {
	s := New(&fakeIntent{}, Options{Version: "test"})

	c := checkByName(t, s.collectDiagnostics(context.Background()), "state-dir")
	if !c.OK {
		t.Errorf("state-dir reported failure when persistence is simply off: %+v", c)
	}
}

// initGitRepo makes dir a real repository with exactly one commit and returns
// that commit's full object name. A real repository rather than a fake .git/
// because the check runs `git rev-parse` and nothing else would exercise it.
func initGitRepo(t *testing.T, dir string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not on PATH")
	}
	run := func(args ...string) string {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.invalid",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.invalid")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	run("init", "--quiet")
	if err := os.WriteFile(filepath.Join(dir, "VERSION"), []byte("0.0.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", "VERSION")
	run("commit", "--quiet", "-m", "seed")
	return run("rev-parse", "HEAD")
}

func writeRevisionSidecar(t *testing.T, dir, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, frameworkRevisionSidecar), []byte(value), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A normal checkout answers from Git itself, and the reported value is the full
// object name a candidate commit can be compared against.
func TestFrameworkRevisionFromGitCheckout(t *testing.T) {
	dir := t.TempDir()
	want := initGitRepo(t, dir)
	s := New(&fakeIntent{}, Options{Version: "test", RepoDir: dir})

	d := s.collectDiagnostics(context.Background())
	if c := checkByName(t, d, "framework-revision"); !c.OK {
		t.Fatalf("framework-revision failed inside a real checkout: %+v", c)
	}
	if d.Environment.FrameworkRevision != want {
		t.Errorf("frameworkRevision = %q, want %q", d.Environment.FrameworkRevision, want)
	}
}

// The deployment this check exists for: the guest extracts a `git archive`
// tarball, so there is no .git/ to interrogate and the sidecar is the only
// remaining proof of which commit is running.
func TestFrameworkRevisionFallsBackToSidecarWithoutGit(t *testing.T) {
	dir := t.TempDir()
	want := "0123456789abcdef0123456789abcdef01234567"
	writeRevisionSidecar(t, dir, want+"\n")
	s := New(&fakeIntent{}, Options{Version: "test", RepoDir: dir})

	d := s.collectDiagnostics(context.Background())
	c := checkByName(t, d, "framework-revision")
	if !c.OK {
		t.Fatalf("archive-only checkout with a valid sidecar failed: %+v", c)
	}
	if d.Environment.FrameworkRevision != want {
		t.Errorf("frameworkRevision = %q, want %q", d.Environment.FrameworkRevision, want)
	}
	if !strings.Contains(c.Detail, frameworkRevisionSidecar) {
		t.Errorf("detail does not name the source of the value: %q", c.Detail)
	}
}

// A sidecar that is not a full object name is not weak evidence, it is no
// evidence: reporting it would let an unverifiable string pass as provenance.
func TestFrameworkRevisionRejectsMalformedSidecar(t *testing.T) {
	for _, bad := range []string{"", "not-a-revision", "0123456", "0123456789ABCDEF0123456789abcdef0123456789"} {
		dir := t.TempDir()
		writeRevisionSidecar(t, dir, bad)
		s := New(&fakeIntent{}, Options{Version: "test", RepoDir: dir})

		d := s.collectDiagnostics(context.Background())
		c := checkByName(t, d, "framework-revision")
		if c.OK {
			t.Errorf("sidecar %q passed the check: %+v", bad, c)
		}
		// Named as a corrupt record rather than as an absent one: the two need
		// different remediation, and only one of them says the tree was touched.
		if !strings.Contains(c.Detail, "malformed") {
			t.Errorf("sidecar %q was not reported as malformed: %q", bad, c.Detail)
		}
		if d.Environment.FrameworkRevision != "" {
			t.Errorf("sidecar %q was still reported as %q", bad, d.Environment.FrameworkRevision)
		}
	}
}

// A tree whose sidecar and .git/ name different commits is a mix of sources, so
// neither value describes what is actually deployed.
func TestFrameworkRevisionRejectsConflictingSidecar(t *testing.T) {
	dir := t.TempDir()
	head := initGitRepo(t, dir)
	writeRevisionSidecar(t, dir, "fedcba9876543210fedcba9876543210fedcba98\n")
	s := New(&fakeIntent{}, Options{Version: "test", RepoDir: dir})

	d := s.collectDiagnostics(context.Background())
	c := checkByName(t, d, "framework-revision")
	if c.OK {
		t.Fatalf("a contradicting sidecar passed the check: %+v", c)
	}
	if d.Environment.FrameworkRevision != "" {
		t.Errorf("a contradicted revision was still reported: %q", d.Environment.FrameworkRevision)
	}
	if !strings.Contains(c.Detail, head) {
		t.Errorf("detail does not name both revisions: %q", c.Detail)
	}
}

// A sidecar that agrees with Git is not a conflict; the check must not fail a
// checkout that simply carries both sources.
func TestFrameworkRevisionAcceptsAgreeingSidecar(t *testing.T) {
	dir := t.TempDir()
	head := initGitRepo(t, dir)
	writeRevisionSidecar(t, dir, strings.ToUpper(head)+"\n")
	s := New(&fakeIntent{}, Options{Version: "test", RepoDir: dir})

	d := s.collectDiagnostics(context.Background())
	if c := checkByName(t, d, "framework-revision"); !c.OK {
		t.Fatalf("an agreeing sidecar failed the check: %+v", c)
	}
	if d.Environment.FrameworkRevision != head {
		t.Errorf("frameworkRevision = %q, want %q", d.Environment.FrameworkRevision, head)
	}
}

// Neither source present means the deployment cannot be tied to any commit. It
// is reported as a failure rather than as an empty field, which a reader would
// otherwise have to interpret.
func TestFrameworkRevisionFailsWithNoSource(t *testing.T) {
	dir := t.TempDir()
	s := New(&fakeIntent{}, Options{Version: "test", RepoDir: dir})

	d := s.collectDiagnostics(context.Background())
	c := checkByName(t, d, "framework-revision")
	if c.OK {
		t.Fatalf("a checkout with no revision source passed: %+v", c)
	}
	if c.Hint == "" {
		t.Error("failing framework-revision check carries no remediation hint")
	}
	if d.Environment.FrameworkRevision != "" {
		t.Errorf("a revision was reported with no source: %q", d.Environment.FrameworkRevision)
	}
	if d.OK {
		t.Error("report is OK while the deployed revision is unprovable")
	}
}

// An extracted archive placed under some other working tree is still an
// archive-only checkout. Repository discovery walks upward, so without a
// toplevel comparison the enclosing tree's HEAD would be reported as this
// deployment's commit -- a revision the checkout does not contain.
func TestFrameworkRevisionIgnoresAnEnclosingRepository(t *testing.T) {
	outer := t.TempDir()
	enclosing := initGitRepo(t, outer)
	inner := filepath.Join(outer, "extracted")
	if err := os.MkdirAll(inner, 0o755); err != nil {
		t.Fatal(err)
	}
	want := "0123456789abcdef0123456789abcdef01234567"
	writeRevisionSidecar(t, inner, want+"\n")
	s := New(&fakeIntent{}, Options{Version: "test", RepoDir: inner})

	d := s.collectDiagnostics(context.Background())
	c := checkByName(t, d, "framework-revision")
	if !c.OK {
		t.Fatalf("an archive-only tree inside another repository failed: %+v", c)
	}
	if d.Environment.FrameworkRevision == enclosing {
		t.Fatalf("the enclosing repository's HEAD %q was reported as this checkout's revision", enclosing)
	}
	if d.Environment.FrameworkRevision != want {
		t.Errorf("frameworkRevision = %q, want the sidecar value %q", d.Environment.FrameworkRevision, want)
	}
}
