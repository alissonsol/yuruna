// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func mirrorReaderDir(options mirrorOptions, repo string) string {
	return filepath.Join(options.ReaderRoot, mirrorRepoKey(repo))
}
func (c *mirrorCoordinator) prepareReaderFiles(repo string) error {
	dir := mirrorReaderDir(c.options, repo)
	if err := os.MkdirAll(dir, 0750); err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(dir, "barrier"), os.O_CREATE|os.O_RDONLY, 0640)
	if err != nil {
		return err
	}
	_ = file.Close()
	uses := filepath.Join(dir, "uses")
	if err = os.MkdirAll(uses, 0770); err != nil {
		return err
	}
	return os.Chmod(uses, 0770|os.ModeSticky)
}

func mirrorReadLease(options mirrorOptions, repo string) (func(), error) {
	dir := mirrorReaderDir(options, repo)
	busy := func() bool { _, err := os.Stat(filepath.Join(dir, "maintenance")); return err == nil }
	if busy() {
		return nil, errMirrorBusy
	}
	file, err := os.Open(filepath.Join(dir, "barrier"))
	if err != nil {
		return nil, err
	}
	if err = mirrorTryLock(file, false); err != nil {
		file.Close()
		return nil, errMirrorBusy
	}
	if busy() {
		mirrorUnlock(file)
		file.Close()
		return nil, errMirrorBusy
	}
	return func() { mirrorUnlock(file); _ = file.Close() }, nil
}

func mirrorRecordUse(options mirrorOptions, repo, sha string) error {
	if !mirrorOID.MatchString(sha) {
		return errors.New("invalid pin")
	}
	var entropy [8]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return err
	}
	path := filepath.Join(mirrorReaderDir(options, repo), "uses", sha+"."+hex.EncodeToString(entropy[:]))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0640)
	if err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	now := time.Now()
	if options.Now != nil {
		now = options.Now()
	}
	return os.Chtimes(path, now, now)
}

func (c *mirrorCoordinator) collectReaderUse(repo string, state *mirrorState) {
	dir := filepath.Join(mirrorReaderDir(c.options, repo), "uses")
	entries, _ := os.ReadDir(dir)
	now := c.options.Now()
	for _, entry := range entries {
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		parts := strings.Split(entry.Name(), ".")
		if len(parts) != 2 || !mirrorOID.MatchString(parts[0]) || len(parts[1]) != 16 {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if pin, ok := state.Pins[parts[0]]; ok {
			usedAt := info.ModTime()
			if usedAt.After(now) {
				usedAt = now
			}
			until := usedAt.Add(c.options.Limits.Retention + c.options.Limits.RetentionGrace)
			if until.After(pin.RetainUntil) {
				pin.RetainUntil = until
				state.Pins[parts[0]] = pin
			}
		}
		_ = os.Remove(filepath.Join(dir, entry.Name()))
	}
}

func waitMirrorLock(ctx context.Context, file *os.File, exclusive bool) error {
	for {
		if err := mirrorTryLock(file, exclusive); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func (c *mirrorCoordinator) maintain(parent context.Context, repo string) error {
	ctx, cancel := context.WithTimeout(parent, c.options.Limits.Maintenance)
	defer cancel()
	c.mu.Lock()
	r := c.repositories[repo]
	if r == nil || !r.published || r.maintenance {
		c.mu.Unlock()
		return nil
	}
	r.maintenance = true
	c.mu.Unlock()
	dir := mirrorReaderDir(c.options, repo)
	marker := filepath.Join(dir, "maintenance")
	defer func() { _ = os.Remove(marker); c.mu.Lock(); r.maintenance = false; c.mu.Unlock() }()
	if err := mirrorAtomicFile(marker, []byte("busy\n"), 0640); err != nil {
		return err
	}
	// Draining readers is outside the refresh worker semaphore.
	barrier, err := os.Open(filepath.Join(dir, "barrier"))
	if err != nil {
		return err
	}
	defer barrier.Close()
	if err = waitMirrorLock(ctx, barrier, true); err != nil {
		return err
	}
	defer mirrorUnlock(barrier)
	for !r.writer.TryLock() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
	defer r.writer.Unlock()
	c.mu.Lock()
	state := cloneMirrorState(r.state)
	c.mu.Unlock()
	c.collectReaderUse(repo, &state)
	path := mirrorRepoPath(c.options.Root, repo)
	if err = mirrorBeginMutation(path); err != nil {
		return err
	}
	for sha, pin := range state.Pins {
		if !c.options.Now().After(pin.RetainUntil) {
			continue
		}
		if _, err = c.git.command(ctx, path, nil, "update-ref", "-d", "refs/yuruna/pins/"+sha); err != nil {
			return err
		}
		delete(state.Pins, sha)
	}
	if err = mirrorCleanupTemporaryObjects(path); err != nil {
		return err
	}
	if err = c.withCapacity(ctx, func(jobCtx context.Context) error {
		_, jobErr := c.git.command(jobCtx, path, nil, "-c", "gc.autoDetach=false", "maintenance", "run", "--task=gc")
		return jobErr
	}); err != nil {
		return err
	}
	if err = c.persist(state); err != nil {
		return err
	}
	if err = mirrorEndMutation(path); err != nil {
		return err
	}
	c.mu.Lock()
	r.state = state
	c.metrics["maintenance"]++
	c.mu.Unlock()
	return nil
}

func mirrorCleanupTemporaryObjects(path string) error {
	for _, pattern := range []string{"objects/pack/tmp_pack_*", "objects/pack/tmp_idx_*", "objects/tmp_obj_*"} {
		paths, _ := filepath.Glob(filepath.Join(path, pattern))
		for _, temp := range paths {
			if err := os.Remove(temp); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
	}
	return nil
}

type mirrorReader struct {
	options mirrorOptions
	git     *mirrorGit
}

func newMirrorReader(options mirrorOptions) *mirrorReader {
	options.Credentials = ""
	return &mirrorReader{options: options, git: &mirrorGit{options: options}}
}
func (r *mirrorReader) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /git-raw/", r.raw)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "ok\n") })
	return mux
}
func (r *mirrorReader) raw(w http.ResponseWriter, request *http.Request) {
	controller := http.NewResponseController(w)
	_ = controller.SetWriteDeadline(time.Now().Add(r.options.Limits.Read))
	ctx, cancel := context.WithTimeout(request.Context(), r.options.Limits.Read)
	defer cancel()
	parts := strings.SplitN(strings.TrimPrefix(request.URL.Path, "/git-raw/"), "/", 4)
	if len(parts) != 4 || !mirrorOID.MatchString(parts[2]) {
		http.NotFound(w, request)
		return
	}
	repo, err := canonicalMirrorRepository(parts[0] + "/" + parts[1])
	if err != nil || repo != parts[0]+"/"+parts[1] || !validMirrorFile(parts[3]) {
		http.NotFound(w, request)
		return
	}
	release, err := mirrorReadLease(r.options, repo)
	if err != nil {
		http.Error(w, "mirror unavailable", 503)
		return
	}
	defer release()
	path := mirrorRepoPath(r.options.Root, repo)
	sha := parts[2]
	if actual, e := r.git.object(ctx, path, "refs/yuruna/pins/"+sha); e != nil || actual != sha {
		http.NotFound(w, request)
		return
	}
	spec := sha + ":" + parts[3]
	kind, err := r.git.command(ctx, path, nil, "cat-file", "-t", spec)
	if err != nil || strings.TrimSpace(kind) != "blob" {
		http.NotFound(w, request)
		return
	}
	sizeText, err := r.git.command(ctx, path, nil, "cat-file", "-s", spec)
	size, e := strconv.ParseInt(strings.TrimSpace(sizeText), 10, 64)
	if err != nil || e != nil || size < 0 {
		http.NotFound(w, request)
		return
	}
	if size > 16<<20 {
		http.Error(w, "raw object exceeds limit", 413)
		return
	}
	if err = mirrorRecordUse(r.options, repo, sha); err != nil {
		http.Error(w, "mirror unavailable", 503)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	stream := &mirrorCappedWriter{writer: w, remaining: size}
	if _, err = r.git.command(ctx, path, stream, "cat-file", "blob", spec); err != nil {
		return
	}
}
func validMirrorFile(path string) bool {
	if path == "" || len(path) > 2048 || strings.ContainsAny(path, "\x00\r\n\\") {
		return false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

type mirrorCappedWriter struct {
	writer    io.Writer
	remaining int64
}

func (w *mirrorCappedWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > w.remaining {
		return 0, errors.New("stream limit")
	}
	n, err := w.writer.Write(p)
	w.remaining -= int64(n)
	return n, err
}

var mirrorWant = regexp.MustCompile(`(?:want |want-ref refs/yuruna/pins/)([0-9a-f]{40})`)

type mirrorWantReader struct {
	reader io.Reader
	tail   string
	seen   map[string]bool
	record func(string) error
}

func (r *mirrorWantReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	text := r.tail + string(p[:n])
	for _, match := range mirrorWant.FindAllStringSubmatch(text, -1) {
		if !r.seen[match[1]] && len(r.seen) < 4096 {
			if e := r.record(match[1]); e != nil {
				return n, e
			}
			r.seen[match[1]] = true
		}
	}
	if len(text) > 128 {
		text = text[len(text)-128:]
	}
	r.tail = text
	return n, err
}

func runMirrorCGI(parent context.Context, options mirrorOptions) error {
	method := os.Getenv("REQUEST_METHOD")
	pathInfo := os.Getenv("PATH_INFO")
	parts := strings.Split(strings.TrimPrefix(pathInfo, "/"), "/")
	fail := func(status int) error {
		_, err := fmt.Fprintf(os.Stdout, "Status: %d\r\nContent-Type: text/plain\r\n\r\nmirror request refused\n", status)
		return err
	}
	if len(parts) < 3 {
		return fail(404)
	}
	repo, err := canonicalMirrorRepository(parts[0] + "/" + parts[1])
	if err != nil || parts[1] != strings.TrimSuffix(parts[1], ".git")+".git" {
		return fail(404)
	}
	tail := strings.Join(parts[2:], "/")
	allowed := method == "POST" && tail == "git-upload-pack" || method == "GET" && tail == "info/refs" && os.Getenv("QUERY_STRING") == "service=git-upload-pack"
	if !allowed {
		return fail(403)
	}
	release, err := mirrorReadLease(options, repo)
	if err != nil {
		return fail(503)
	}
	defer release()
	path := mirrorRepoPath(options.Root, repo)
	real, err := filepath.EvalSymlinks(path)
	if err != nil || filepath.Clean(real) != filepath.Clean(path) {
		return fail(404)
	}
	ctx, cancel := context.WithTimeout(parent, options.Limits.CGI)
	defer cancel()
	options.Credentials = ""
	input := &mirrorWantReader{reader: os.Stdin, seen: map[string]bool{}, record: func(sha string) error { return mirrorRecordUse(options, repo, sha) }}
	g := &mirrorGit{options: options, stdin: input, env: []string{"GIT_PROJECT_ROOT=" + options.Root, "GIT_HTTP_EXPORT_ALL=1", "GIT_PROTOCOL=" + os.Getenv("HTTP_GIT_PROTOCOL")}}
	_, err = g.command(ctx, path, os.Stdout, "http-backend")
	return err
}
