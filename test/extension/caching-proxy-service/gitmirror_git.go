// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type mirrorBoundedBuffer struct {
	buffer  bytes.Buffer
	limit   int
	limited bool
	mu      sync.Mutex
}

func (b *mirrorBoundedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.buffer.Len()+len(p) > b.limit {
		b.limited = true
		return 0, errors.New("Git output limit")
	}
	return b.buffer.Write(p)
}

// Embedding bytes.Buffer would promote ReadFrom and let io.Copy bypass Write's cap.
func (b *mirrorBoundedBuffer) String() string { return b.buffer.String() }

// Diagnostics contain only fixed operation names and classifications. Git's
// stderr and arguments can contain credentials and never become diagnostic text.
type mirrorDiagnostic struct {
	Phase       string `json:"phase"`
	Operation   string `json:"operation,omitempty"`
	ExitCode    int    `json:"exitCode"`
	OutputLimit string `json:"outputLimit,omitempty"`
	Failure     string `json:"failure"`
}

type mirrorFailure struct {
	diagnostic mirrorDiagnostic
	cause      error
}

func (e *mirrorFailure) Error() string { return e.diagnostic.Failure }
func (e *mirrorFailure) Unwrap() error { return e.cause }

func mirrorWithPhase(phase string, err error) error {
	if err == nil {
		return nil
	}
	var failure *mirrorFailure
	if errors.As(err, &failure) {
		copy := *failure
		copy.diagnostic.Phase = phase
		return &copy
	}
	_, reason := mirrorOutcome(err)
	if os.IsPermission(err) {
		reason = "filesystem-permission-denied"
	} else if os.IsNotExist(err) {
		reason = "filesystem-not-found"
	}
	return &mirrorFailure{diagnostic: mirrorDiagnostic{Phase: phase, ExitCode: -1, Failure: reason}, cause: err}
}

func mirrorGitOperation(args []string) string {
	if len(args) == 0 {
		return "other"
	}
	operation := args[0]
	if operation == "-c" && len(args) > 2 {
		operation = args[2]
	}
	switch operation {
	case "ls-remote", "init", "config", "fetch", "rev-parse", "cat-file", "update-ref", "symbolic-ref", "fsck", "show", "maintenance", "http-backend":
		return operation
	default:
		return "other"
	}
}

type mirrorGit struct {
	options mirrorOptions
	before  func([]string)
	stdin   io.Reader
	env     []string
}

func (g *mirrorGit) command(ctx context.Context, dir string, output io.Writer, args ...string) (result string, failure error) {
	diagnostic := mirrorDiagnostic{Operation: mirrorGitOperation(args), ExitCode: -1}
	var cmd *exec.Cmd
	var stdout, stderr *mirrorBoundedBuffer
	defer func() {
		if failure == nil {
			return
		}
		if diagnostic.Failure == "" {
			_, diagnostic.Failure = mirrorOutcome(failure)
		}
		if cmd != nil && cmd.ProcessState != nil {
			diagnostic.ExitCode = cmd.ProcessState.ExitCode()
		}
		if stdout != nil && stdout.limited {
			diagnostic.OutputLimit = "stdout"
		}
		if stderr != nil && stderr.limited {
			if diagnostic.OutputLimit == "stdout" {
				diagnostic.OutputLimit = "stdout,stderr"
			} else {
				diagnostic.OutputLimit = "stderr"
			}
		}
		failure = &mirrorFailure{diagnostic: diagnostic, cause: failure}
	}()
	base := []string{"-c", "credential.helper=", "-c", "core.askPass=", "-c", "http.followRedirects=false", "-c", "maintenance.auto=false"}
	if g.options.Credentials != "" {
		executable, err := os.Executable()
		if err != nil {
			diagnostic.Failure = "credential-helper-unavailable"
			return "", errors.New("credential-helper-unavailable")
		}
		quote := func(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }
		helper := "!" + quote(executable) + " --mirror-role=credential --mirror-credentials=" + quote(g.options.Credentials)
		base = append(base, "-c", "credential.https://github.com.helper="+helper)
	}
	if dir != "" {
		base = append(base, "-c", "safe.directory="+dir, "-C", dir)
	}
	base = append(base, args...)
	if g.before != nil {
		g.before(args)
	}
	cmd = exec.Command("git", base...)
	cmd.Stdin = g.stdin
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GCM_INTERACTIVE=Never", "GIT_ASKPASS=", "GIT_OPTIONAL_LOCKS=0",
		"GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL="+os.DevNull, "LC_ALL=C")
	cmd.Env = append(cmd.Env, g.env...)
	cmd.WaitDelay = g.options.Limits.CancelGrace
	mirrorPrepareProcess(cmd)
	stderr = &mirrorBoundedBuffer{limit: 64 << 10}
	stdout = &mirrorBoundedBuffer{limit: 4 << 20}
	if output == nil {
		cmd.Stdout = stdout
	} else {
		cmd.Stdout = output
	}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		diagnostic.Failure = "git-start-failed"
		if errors.Is(err, exec.ErrNotFound) {
			diagnostic.Failure = "git-not-found"
		} else if os.IsPermission(err) {
			diagnostic.Failure = "git-start-permission-denied"
		}
		return "", errors.New("git-start-failed")
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			mirrorStopProcess(cmd, true)
			return stdout.String(), mirrorGitFailure(stderr.String(), err)
		}
		return stdout.String(), nil
	case <-ctx.Done():
		mirrorStopProcess(cmd, false)
		timer := time.NewTimer(g.options.Limits.CancelGrace)
		defer timer.Stop()
		select {
		case <-done:
			if mirrorProcessGroupAlive(cmd) {
				<-timer.C
				mirrorStopProcess(cmd, true)
			}
		case <-timer.C:
			mirrorStopProcess(cmd, true)
			<-done
		}
		return "", ctx.Err()
	}
}

func mirrorGitFailure(stderr string, cause error) error {
	text := strings.ToLower(stderr)
	for _, pattern := range []string{"authentication failed", "could not read username", "repository not found", "returned error: 401", "returned error: 403", "access denied", "permission denied"} {
		if strings.Contains(text, pattern) {
			return errors.New("mirror-auth-denied")
		}
	}
	for _, pattern := range []string{"could not resolve", "failed to connect", "connection refused", "connection reset", "timed out", "timeout", "network is unreachable", "returned error: 502", "returned error: 503", "returned error: 504", "tls", "ssl", "remote end hung up", "empty reply"} {
		if strings.Contains(text, pattern) {
			return errors.New("mirror-upstream-unreachable")
		}
	}
	if errors.Is(cause, context.DeadlineExceeded) || errors.Is(cause, context.Canceled) {
		return cause
	}
	return errors.New("git-local-error")
}

type mirrorSnapshot struct {
	Objects       map[string]string
	Peeled        map[string]string
	DefaultBranch string
	CheckedAt     time.Time
}

func (g *mirrorGit) snapshot(ctx context.Context, repo string) (mirrorSnapshot, error) {
	s := mirrorSnapshot{Objects: map[string]string{}, Peeled: map[string]string{}}
	if g.options.NoUpstreamPath != "" {
		if _, err := os.Stat(g.options.NoUpstreamPath); err == nil {
			return s, errors.New("upstream-blocked-by-switch")
		}
	}
	query, cancel := context.WithTimeout(ctx, g.options.Limits.Query)
	defer cancel()
	out, err := g.command(query, "", nil, "ls-remote", "--symref", "--", "https://github.com/"+repo+".git")
	if err != nil {
		return s, err
	}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 3 && fields[0] == "ref:" && fields[2] == "HEAD" {
			if !strings.HasPrefix(fields[1], "refs/heads/") || !validMirrorRef(fields[1]) {
				return s, errors.New("invalid-upstream-head")
			}
			s.DefaultBranch = fields[1]
			continue
		}
		if len(fields) != 2 {
			continue
		}
		sha, ref := fields[0], fields[1]
		if !mirrorOID.MatchString(sha) {
			return s, errors.New("invalid-upstream-object")
		}
		if strings.HasSuffix(ref, "^{}") {
			ref = strings.TrimSuffix(ref, "^{}")
			if validMirrorRef(ref) {
				s.Peeled[ref] = sha
			}
		} else if validMirrorRef(ref) && !mirrorOID.MatchString(ref) {
			s.Objects[ref] = sha
		}
	}
	s.CheckedAt = g.options.Now()
	return s, nil
}

func (g *mirrorGit) initialize(ctx context.Context, path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil {
		return err
	}
	if _, err := g.command(ctx, "", nil, "init", "--bare", path); err != nil {
		return err
	}
	for _, pair := range [][2]string{{"http.receivepack", "false"}, {"uploadpack.allowAnySHA1InWant", "true"}, {"gc.auto", "0"}, {"gc.pruneExpire", "14.days"}} {
		if _, err := g.command(ctx, path, nil, "config", pair[0], pair[1]); err != nil {
			return err
		}
	}
	return nil
}

func (g *mirrorGit) fetch(ctx context.Context, path, repo string) error {
	_, err := g.command(ctx, path, nil, "fetch", "--atomic", "--prune", "--no-tags", "--no-auto-maintenance", "--",
		"https://github.com/"+repo+".git", "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*")
	return err
}

func (g *mirrorGit) object(ctx context.Context, path, spec string) (string, error) {
	out, err := g.command(ctx, path, nil, "rev-parse", "--verify", spec)
	return strings.TrimSpace(out), err
}

func (g *mirrorGit) hasCommit(ctx context.Context, path, sha string) bool {
	if !mirrorOID.MatchString(sha) {
		return false
	}
	out, err := g.command(ctx, path, nil, "cat-file", "-t", sha)
	return err == nil && strings.TrimSpace(out) == "commit"
}

func mirrorAtomicFile(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".mirror-write-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = mirrorInheritGroup(f, filepath.Dir(path)); err == nil {
		err = f.Chmod(mode)
	}
	if err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(name, path)
	}
	if err == nil {
		err = mirrorSyncDirectory(filepath.Dir(path))
	}
	return err
}

func mirrorCleanupLocks(path string) error {
	if err := filepath.WalkDir(filepath.Join(path, "refs"), func(p string, d os.DirEntry, e error) error {
		if e != nil {
			if os.IsNotExist(e) {
				return nil
			}
			return e
		}
		if !d.IsDir() && strings.HasSuffix(d.Name(), ".lock") {
			return os.Remove(p)
		}
		return nil
	}); err != nil {
		return err
	}
	for _, name := range []string{"packed-refs.lock", "config.lock", "gc.pid"} {
		if err := os.Remove(filepath.Join(path, name)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func mirrorMarker(path string) string { return filepath.Join(path, "yuruna-in-progress") }
func mirrorBeginMutation(path string) error {
	return mirrorAtomicFile(mirrorMarker(path), []byte("in-progress\n"), 0640)
}
func mirrorEndMutation(path string) error {
	if err := os.Remove(mirrorMarker(path)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return mirrorSyncDirectory(path)
}
