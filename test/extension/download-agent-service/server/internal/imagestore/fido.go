// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path"
	"regexp"
	"strings"
	"time"
)

// FidoLanguage is the -Lang value every host guest.windows.11 script passes.
// It is a constant, not a setting: the pool exists to hand a host the artifact
// it would otherwise have fetched itself, and a per-agent language would serve
// a different edition than the one the host asked for.
const FidoLanguage = "English"

// fidoTimeout bounds one resolve. Fido walks Microsoft's session and product
// pages to mint a signed URL, so it is neither instant nor allowed to run
// unbounded -- a child that never returns would otherwise pin a scan pass and
// the ensure that started it for as long as the daemon lives.
const fidoTimeout = 3 * time.Minute

// fidoWaitDelay bounds the wait AFTER the timeout has killed the interpreter.
// A killed shell can leave a grandchild holding the write end of the stdout
// pipe, and the copy that feeds this process would then block long past the
// kill; the delay force-closes those pipes instead.
const fidoWaitDelay = 5 * time.Second

// fidoStdoutLimit caps what is kept from the child's streams. The answer wanted
// here is one URL on one line, so anything past the cap is not it, and a child
// that floods stdout must not grow the daemon's heap.
const fidoStdoutLimit = 64 << 10

// defaultInterpreter runs a PowerShell script non-interactively. -NoProfile and
// -NonInteractive keep a profile's banner and any prompt off stdout, which this
// resolve reads as a URL and nothing else. The prefix ends with the flag that
// takes the script path, because that is where the path is appended.
var defaultInterpreter = []string{"pwsh", "-NoProfile", "-NonInteractive", "-File"}

// fidoScriptCandidates are the standard install locations for the vendored,
// hash-pinned Fido.ps1. They are searched only when no explicit path is
// configured, so an agent VM that puts it elsewhere pins it with --fido-script
// rather than depending on this list.
var fidoScriptCandidates = []string{
	// Where the agent VM's cloud-init lands the verified copy, beside the rest of
	// the guest's Yuruna configuration.
	"/etc/yuruna/Fido.ps1",
	"/opt/yuruna/fido/Fido.ps1",
	"/opt/yuruna/Fido.ps1",
	"/usr/local/share/yuruna/Fido.ps1",
}

// FidoConfig locates the two pieces of the best-effort Windows 11 path: a
// PowerShell interpreter and the vendored Fido.ps1. Both are looked up rather
// than assumed, because an agent that cannot run the resolve has to read as
// "family unavailable" -- a state hosts step over silently -- and never as a
// daemon error.
type FidoConfig struct {
	// Interpreter is the argv prefix that runs a PowerShell script: the
	// interpreter followed by its own flags, with the script path appended after
	// it. Empty uses pwsh from PATH.
	Interpreter []string
	// Script is the Fido.ps1 path; empty searches fidoScriptCandidates.
	Script string
	// Timeout bounds one resolve; zero uses fidoTimeout.
	Timeout time.Duration
	// Observe, when set, receives every finished Attempt. It is how the agent
	// remembers the last run for the diagnostics surface without the resolve
	// path having to thread a second return value through every caller.
	Observe func(FidoAttempt)
}

// Check reports why this agent could not run a Windows 11 resolve, or nil when
// it could. It only looks things up and never starts a child, so the catalog can
// ask it on every render.
func (f FidoConfig) Check() error {
	if _, err := f.interpreter(); err != nil {
		return err
	}
	_, err := f.script()
	return err
}

// interpreter resolves the argv prefix, proving the interpreter exists and is
// executable. Proving it here is what lets a machine with no PowerShell answer
// "unavailable" before anything is attempted, instead of turning every Windows
// request into a failed download.
func (f FidoConfig) interpreter() ([]string, error) {
	argv := f.Interpreter
	if len(argv) == 0 {
		argv = defaultInterpreter
	}
	resolved, err := exec.LookPath(argv[0])
	if err != nil {
		return nil, fmt.Errorf("no PowerShell interpreter (%s): %w", argv[0], err)
	}
	return append([]string{resolved}, argv[1:]...), nil
}

// script resolves the Fido.ps1 path.
func (f FidoConfig) script() (string, error) {
	if p := strings.TrimSpace(f.Script); p != "" {
		if fi, err := os.Stat(p); err != nil || fi.IsDir() {
			return "", fmt.Errorf("no Fido.ps1 at %s", p)
		}
		return p, nil
	}
	for _, cand := range fidoScriptCandidates {
		if fi, err := os.Stat(cand); err == nil && !fi.IsDir() {
			return cand, nil
		}
	}
	return "", fmt.Errorf("no Fido.ps1 found (searched %s)", strings.Join(fidoScriptCandidates, ", "))
}

// fidoParams is the parameter list the three host guest.windows.11 scripts pass
// to Fido.ps1, verbatim. Written once and asserted literally by the suite: a
// mismatch would have the pool hold an ISO -- a different edition, language or
// architecture -- that no host ever asked for, and the hosts would accept it
// because they trust the key, not the parameters behind it.
//
// -PlatformArch is load-bearing on this agent, not an optimization: without it
// Fido autodetects the CPU via Get-CimInstance (WMI), which exists only on
// Windows, so every resolve under Linux or macOS pwsh dies before reaching the
// network. Passing the requested arch also keeps Fido's default link selection
// aligned with the -Arch actually asked for.
func fidoParams(fidoArch string) []string {
	return []string{"-Win", "11", "-Lang", FidoLanguage, "-Arch", fidoArch, "-PlatformArch", fidoArch, "-GetUrl"}
}

// fidoArchFor maps a pool architecture onto Fido's -Arch value. Fido spells the
// x86-64 build "x64"; arm64 is spelled the same on both sides.
func fidoArchFor(arch string) (string, bool) {
	switch arch {
	case ArchAMD64:
		return "x64", true
	case ArchARM64:
		return ArchARM64, true
	default:
		return "", false
	}
}

// attemptStreamLimit caps how much of each stream one FidoAttempt retains for
// diagnosis. Refusals print in the first lines, so the head is the part worth
// keeping, and the cap keeps an attempt renderable as one JSON field rather
// than a page dump.
const attemptStreamLimit = 8 << 10

// FidoAttempt is one complete Fido run, captured for diagnosis: the exact argv,
// the exit code, both streams, and how long it ran. The one-line error the
// catalog carries answers "did it work"; this answers "what happened". It
// exists because Fido inside a guest VM is otherwise a black box -- the
// incident class that motivated it printed its refusal to stdout and exited
// 403 (reported as 147, exit codes being 8-bit), so an error quoting only
// stderr read as "exit status 147 ()" with the actual refusal discarded.
type FidoAttempt struct {
	AtUTC      string   `json:"atUtc"`
	Arch       string   `json:"arch"`
	Argv       []string `json:"argv,omitempty"`
	DurationMs int64    `json:"durationMs"`
	// ExitCode is the interpreter's exit status; -1 when no child ran at all
	// (missing interpreter or script) or the timeout killed it.
	ExitCode int    `json:"exitCode"`
	TimedOut bool   `json:"timedOut,omitempty"`
	Stdout   string `json:"stdout,omitempty"`
	Stderr   string `json:"stderr,omitempty"`
	// URL is the minted signed URL on success. It expires within hours, so it
	// is evidence the resolve works, never a value to store.
	URL   string `json:"url,omitempty"`
	Error string `json:"error,omitempty"`
}

// Attempt runs Fido once and reports everything about the run. It never returns
// an error type: a failed attempt IS the result, with Error set, which is what
// lets the diagnostics surface render success and failure the same way. The
// Observe hook, when set, sees every finished attempt -- including ones that
// died before a child started.
func (f FidoConfig) Attempt(ctx context.Context, fidoArch string) FidoAttempt {
	at := FidoAttempt{
		AtUTC:    time.Now().UTC().Format(time.RFC3339),
		Arch:     fidoArch,
		ExitCode: -1,
	}
	defer func() {
		if f.Observe != nil {
			f.Observe(at)
		}
	}()
	argv, err := f.interpreter()
	if err != nil {
		at.Error = err.Error()
		return at
	}
	script, err := f.script()
	if err != nil {
		at.Error = err.Error()
		return at
	}
	timeout := f.Timeout
	if timeout <= 0 {
		timeout = fidoTimeout
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	argv = append(argv, script)
	argv = append(argv, fidoParams(fidoArch)...)
	at.Argv = argv
	stdout := &cappedBuffer{limit: fidoStdoutLimit}
	stderr := &cappedBuffer{limit: fidoStdoutLimit}
	cmd := exec.CommandContext(runCtx, argv[0], argv[1:]...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.WaitDelay = fidoWaitDelay
	started := time.Now()
	runErr := cmd.Run()
	at.DurationMs = time.Since(started).Milliseconds()
	at.Stdout = headOf(stripANSI(stdout.String()), attemptStreamLimit)
	at.Stderr = headOf(stripANSI(stderr.String()), attemptStreamLimit)
	if cmd.ProcessState != nil {
		at.ExitCode = cmd.ProcessState.ExitCode()
	}

	if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
		at.TimedOut = true
		at.ExitCode = -1
		at.Error = fmt.Sprintf("Fido did not answer within %s", timeout)
		return at
	}
	if runErr != nil {
		// The refusal often goes to stdout (Fido reports via Write-Host), so an
		// empty stderr must fall back to stdout or the error hides the reason.
		detail := briefly(at.Stderr)
		if detail == "" {
			detail = briefly(at.Stdout)
		}
		at.Error = fmt.Sprintf("Fido failed: %v (%s)", runErr, detail)
		return at
	}
	raw := firstHTTPSURL(stdout.String())
	if raw == "" {
		at.Error = fmt.Sprintf("Fido printed no download URL (%s)", briefly(at.Stdout))
		return at
	}
	at.URL = raw
	return at
}

// ResolveURL runs Fido and returns the short-lived signed Microsoft URL it
// prints. Every way this can go wrong -- no interpreter, no script, a non-zero
// exit, silence, output that is not a URL, or a run that outlives the timeout --
// comes back as an error, and the caller turns all of them into the same
// "family unavailable" answer rather than into a daemon failure or a pool entry
// pointing at something that was never downloaded.
func (f FidoConfig) ResolveURL(ctx context.Context, fidoArch string) (string, error) {
	at := f.Attempt(ctx, fidoArch)
	if at.Error != "" {
		return "", errors.New(at.Error)
	}
	return at.URL, nil
}

// ansiEscape matches the CSI color/formatting sequences PowerShell wraps its
// error stream in. Stripped from captured streams: the bytes are noise in a
// JSON field and turn "Get-CimInstance:" into "[31;1mGet-CimInstance:".
var ansiEscape = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

func stripANSI(s string) string { return ansiEscape.ReplaceAllString(s, "") }

// headOf keeps the first limit bytes on a rune boundary. The head, not the
// tail: refusals and startup failures print before anything else.
func headOf(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	r := []rune(s[:limit])
	return string(r[:len(r)-1]) + "…"
}

// firstHTTPSURL picks the download URL out of whatever the interpreter printed.
// Only https is accepted: Microsoft mints https URLs, and taking an http one
// would silently downgrade a multi-gigabyte transfer that nothing else verifies.
func firstHTTPSURL(out string) string {
	for _, line := range strings.Split(out, "\n") {
		for _, field := range strings.Fields(line) {
			if !strings.HasPrefix(field, "https://") {
				continue
			}
			u, err := url.Parse(field)
			if err != nil || u.Host == "" {
				continue
			}
			return field
		}
	}
	return ""
}

// filenameFromSignedURL takes the artifact name out of a signed URL: the path's
// last segment, with the query -- which is where the signature and the expiry
// live -- discarded. This name is half of the freshness comparison for the
// Windows family, so it must not carry anything that differs between two
// resolves of the same ISO.
func filenameFromSignedURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	name := path.Base(u.Path)
	if name == "." || name == "/" || name == "" {
		return ""
	}
	return name
}

// cappedBuffer keeps at most limit bytes and discards the rest. Writes always
// report full consumption: a short write would abort the child mid-run with an
// error describing the buffer rather than the resolve.
type cappedBuffer struct {
	buf   bytes.Buffer
	limit int
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	if room := c.limit - c.buf.Len(); room > 0 {
		if len(p) > room {
			c.buf.Write(p[:room])
		} else {
			c.buf.Write(p)
		}
	}
	return len(p), nil
}

func (c *cappedBuffer) String() string { return c.buf.String() }

// briefly reduces a child's stream to one short line for an error message. The
// whole stream can be pages of PowerShell formatting, and this ends up in a JSON
// field the UI renders as a single row of text.
func briefly(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = strings.TrimSpace(s[:i])
	}
	if r := []rune(s); len(r) > 200 {
		s = string(r[:200]) + "…"
	}
	return s
}
