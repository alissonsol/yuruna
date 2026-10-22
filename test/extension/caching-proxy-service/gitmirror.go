// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func mirrorFlags() *mirrorOptions {
	o := &mirrorOptions{Limits: defaultMirrorLimits(), Now: time.Now, NoUpstreamPath: noUpstreamConfPath}
	flag.StringVar(&o.Role, "mirror-role", "management", "management, worker, reader, cgi or credential")
	flag.StringVar(&o.Root, "mirror-root", "/var/lib/yuruna/git", "published bare repositories")
	flag.StringVar(&o.StateRoot, "mirror-state-root", "/var/lib/yuruna/git-mirror", "mirror metadata and staging")
	flag.StringVar(&o.RuntimeRoot, "mirror-runtime-root", "/run/yuruna/git-mirror", "private worker runtime directory")
	flag.StringVar(&o.ReaderRoot, "mirror-reader-root", "/run/yuruna/git-mirror-readers", "reader barriers and use records")
	flag.StringVar(&o.RepositoriesFile, "mirror-repositories", "/etc/yuruna/git-mirror/repositories.yml", "JSON-encoded immutable repository list")
	flag.StringVar(&o.SigningKey, "mirror-signing-key", "/etc/yuruna/git-mirror/signing-key.pem", "provisioned RSA signing key")
	flag.StringVar(&o.Credentials, "mirror-credentials", "/etc/yuruna/git-mirror/credentials", "optional protected GitHub token file")
	flag.StringVar(&o.PoolStore, "mirror-pool-store", "/mnt/ypool-nas/pool-configuration.git", "read-only pool Git store; empty disables discovery")
	flag.StringVar(&o.PoolRef, "mirror-pool-ref", "main", "pool-store ref containing pools.yml")
	flag.DurationVar(&o.Limits.Refresh, "mirror-refresh-interval", time.Minute, "background mirror check interval")
	flag.StringVar(&o.BuildSource.Source, "mirror-build-source", "", "host or github")
	flag.StringVar(&o.BuildSource.Repository, "mirror-build-repository", "", "canonical build repository")
	flag.StringVar(&o.BuildSource.Commit, "mirror-build-commit", "", "immutable build commit")
	return o
}

func runMirrorRole(ctx context.Context, o mirrorOptions, httpAddr string) error {
	switch o.Role {
	case "credential":
		return mirrorCredential(o.Credentials, flag.Arg(0), os.Stdin, os.Stdout)
	case "cgi":
		return runMirrorCGI(ctx, o)
	case "reader":
		return mirrorServe(ctx, &http.Server{Addr: httpAddr, Handler: newMirrorReader(o).routes(), ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 120 * time.Second}, nil)
	case "worker":
		if o.Limits.Refresh < 10*time.Second || o.Limits.Refresh > time.Hour {
			return errors.New("mirror refresh interval outside 10..3600 seconds")
		}
		if !validMirrorRef("refs/heads/"+o.PoolRef) && !validMirrorRef(o.PoolRef) {
			return errors.New("invalid pool ref")
		}
		if err := os.MkdirAll(o.RuntimeRoot, 0700); err != nil {
			return err
		}
		if err := os.Chmod(o.RuntimeRoot, 0700); err != nil {
			return err
		}
		lock, err := os.OpenFile(filepath.Join(o.RuntimeRoot, "worker.lock"), os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return err
		}
		defer lock.Close()
		if err = mirrorTryLock(lock, true); err != nil {
			return errors.New("mirror worker already running")
		}
		defer mirrorUnlock(lock)
		c, err := newMirrorCoordinator(ctx, o)
		if err != nil {
			return err
		}
		defer c.close()
		socket := filepath.Join(o.RuntimeRoot, "worker.sock")
		if err = os.Remove(socket); err != nil && !os.IsNotExist(err) {
			return err
		}
		listener, err := net.Listen("unix", socket)
		if err != nil {
			return err
		}
		defer listener.Close()
		defer os.Remove(socket)
		if err = os.Chmod(socket, 0600); err != nil {
			return err
		}
		c.startTimer()
		return mirrorServe(ctx, &http.Server{Handler: c.routes(), ReadHeaderTimeout: 2 * time.Second, IdleTimeout: 30 * time.Second}, listener)
	default:
		return errors.New("invalid mirror role")
	}
}

func mirrorServe(ctx context.Context, server *http.Server, listener net.Listener) error {
	done := make(chan error, 1)
	go func() {
		if listener == nil {
			done <- server.ListenAndServe()
		} else {
			done <- server.Serve(listener)
		}
	}()
	select {
	case err := <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		err := server.Shutdown(shutdown)
		if err != nil {
			_ = server.Close()
		}
		return err
	}
}

// This helper is invoked by Git over a pipe, never over HTTP. It does not
// persist credentials, and answers only the one permitted upstream authority.
func mirrorCredential(path, operation string, input io.Reader, output io.Writer) error {
	if operation != "get" {
		return nil
	}
	b, err := io.ReadAll(io.LimitReader(input, 4097))
	if err != nil || len(b) > 4096 {
		return errors.New("invalid credential request")
	}
	fields := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		pair := strings.SplitN(line, "=", 2)
		if len(pair) == 2 {
			fields[pair[0]] = pair[1]
		}
	}
	if fields["protocol"] != "https" || fields["host"] != "github.com" {
		return nil
	}
	token, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return errors.New("credential unavailable")
	}
	value := strings.TrimSuffix(strings.TrimSuffix(string(token), "\n"), "\r")
	if value == "" {
		return nil
	}
	if len(value) > 4096 || strings.ContainsAny(value, "\x00\r\n\t\"'\\") {
		return errors.New("invalid credential")
	}
	_, err = fmt.Fprintf(output, "username=x-access-token\npassword=%s\n\n", value)
	return err
}

type mirrorRelay struct {
	options        mirrorOptions
	client         *http.Client
	registrationMu sync.Mutex
}

func newMirrorRelay(options mirrorOptions) *mirrorRelay {
	transport := &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		dialer := net.Dialer{Timeout: time.Second}
		return dialer.DialContext(ctx, "unix", filepath.Join(options.RuntimeRoot, "worker.sock"))
	}, ResponseHeaderTimeout: options.Limits.Handler}
	return &mirrorRelay{options: options, client: &http.Client{Transport: transport}}
}
func (d *daemon) mirrorProxy(w http.ResponseWriter, r *http.Request) {
	if d.mirror == nil || d.mode != modeLocal {
		writeJSON(w, 503, map[string]string{"reason": "mirror-unavailable"})
		return
	}
	d.mirror.proxy(w, r)
}
func (d *daemon) mirrorRegister(w http.ResponseWriter, r *http.Request) {
	if d.mirror == nil || d.mode != modeLocal {
		writeJSON(w, 503, map[string]string{"reason": "mirror-unavailable"})
		return
	}
	relay := d.mirror
	ctx, cancel := context.WithTimeout(r.Context(), relay.options.Limits.Handler)
	defer cancel()
	r = r.Clone(ctx)
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(relay.options.Limits.Handler))
	for !relay.registrationMu.TryLock() {
		select {
		case <-ctx.Done():
			writeJSON(w, 503, map[string]string{"reason": "mirror-budget-exhausted"})
			return
		case <-time.After(time.Millisecond):
		}
	}
	defer relay.registrationMu.Unlock()
	var registration struct {
		Repository string `json:"repository"`
	}
	b, err := mirrorReadBody(w, r, relay.options.Limits)
	if err != nil || strictMirrorJSON(b, &registration, 4096) != nil {
		writeJSON(w, 400, map[string]string{"reason": "invalid-request"})
		return
	}
	repo, err := canonicalMirrorRepository(registration.Repository)
	if err != nil {
		writeJSON(w, 400, map[string]string{"reason": "invalid-repository"})
		return
	}
	// Admission happens before persistence; the worker enforces the effective
	// union's limit, including immutable and pool-discovered repositories.
	req := r.Clone(r.Context())
	req.Body = io.NopCloser(strings.NewReader(`{"repository":` + strconvMirrorString(repo) + `}`))
	req.URL.Path = "/api/git-mirror/repositories"
	response, err := relay.request(req)
	if err != nil {
		writeJSON(w, 503, map[string]string{"reason": "mirror-unavailable"})
		return
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	if err != nil {
		writeJSON(w, 503, map[string]string{"reason": "mirror-unavailable"})
		return
	}
	if response.StatusCode == http.StatusOK {
		if err = persistMirrorRegistration(relay.options, repo); err != nil {
			writeJSON(w, 507, map[string]string{"reason": "mirror-capacity-exhausted", "detail": "storage"})
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(response.StatusCode)
	_, _ = w.Write(data)
}
func strconvMirrorString(value string) string { b, _ := json.Marshal(value); return string(b) }
func (r *mirrorRelay) request(request *http.Request) (*http.Response, error) {
	out, err := http.NewRequestWithContext(request.Context(), request.Method, "http://worker"+request.URL.Path, request.Body)
	if err != nil {
		return nil, err
	}
	out.Header.Set("Content-Type", "application/json")
	return r.client.Do(out)
}
func (r *mirrorRelay) proxy(w http.ResponseWriter, request *http.Request) {
	ctx, cancel := context.WithTimeout(request.Context(), r.options.Limits.Handler)
	defer cancel()
	controller := http.NewResponseController(w)
	_ = controller.SetWriteDeadline(time.Now().Add(r.options.Limits.Handler))
	if request.Method == "POST" {
		b, err := mirrorReadBody(w, request, r.options.Limits)
		if err != nil {
			writeJSON(w, 400, map[string]string{"reason": "invalid-request"})
			return
		}
		request = request.Clone(ctx)
		request.Body = io.NopCloser(strings.NewReader(string(b)))
	} else {
		request = request.Clone(ctx)
	}
	resp, err := r.request(request)
	if err != nil {
		writeJSON(w, 503, map[string]string{"reason": "mirror-unavailable"})
		return
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, (64<<10)+1))
	if err != nil || len(b) > 64<<10 {
		writeJSON(w, 503, map[string]string{"reason": "mirror-unavailable"})
		return
	}
	w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(b)
}
func mirrorReadBody(w http.ResponseWriter, r *http.Request, limits mirrorLimits) ([]byte, error) {
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(limits.BodyRead))
	return io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
}

func (c *mirrorCoordinator) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /git-mirror/status.json", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, c.status()) })
	mux.HandleFunc("GET /git-mirror/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		_, _ = io.WriteString(w, c.metricsText())
	})
	mux.HandleFunc("POST /git-mirror/v1/resolve", c.handleResolve)
	mux.HandleFunc("POST /api/git-mirror/repositories", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Repository string `json:"repository"`
		}
		b, err := mirrorReadBody(w, r, c.options.Limits)
		if err != nil || strictMirrorJSON(b, &body, 4096) != nil {
			writeJSON(w, 400, map[string]string{"reason": "invalid-request"})
			return
		}
		repo, err := canonicalMirrorRepository(body.Repository)
		if err != nil {
			writeJSON(w, 400, map[string]string{"reason": "invalid-repository"})
			return
		}
		c.registry.mu.Lock()
		if !c.registry.repositories[repo] && len(c.registry.repositories) >= c.options.Limits.Repositories {
			c.registry.mu.Unlock()
			writeJSON(w, 503, map[string]string{"reason": "mirror-capacity-exhausted", "detail": "queue"})
			return
		}
		c.registry.repositories[repo] = true
		c.registry.mu.Unlock()
		writeJSON(w, 200, map[string]string{"repository": repo, "status": "pending"})
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(c.options.Limits.Handler))
		writer := &mirrorStatusWriter{ResponseWriter: w, status: 200}
		mux.ServeHTTP(writer, r)
		route := "unknown"
		switch r.URL.Path {
		case "/git-mirror/status.json":
			route = "status"
		case "/git-mirror/metrics":
			route = "metrics"
		case "/git-mirror/v1/resolve":
			route = "resolve"
		case "/api/git-mirror/repositories":
			route = "register"
		}
		c.mu.Lock()
		c.metrics[fmt.Sprintf("requests_%s_%d", route, writer.status)]++
		c.mu.Unlock()
	})
}

type mirrorStatusWriter struct {
	http.ResponseWriter
	status int
}

func (w *mirrorStatusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
func (w *mirrorStatusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (c *mirrorCoordinator) handleResolve(w http.ResponseWriter, r *http.Request) {
	controller := http.NewResponseController(w)
	_ = controller.SetWriteDeadline(time.Now().Add(c.options.Limits.Handler))
	ctx, cancel := context.WithTimeout(r.Context(), c.options.Limits.Pending)
	defer cancel()
	if c.signer == nil {
		writeJSON(w, 503, map[string]string{"reason": "mirror-unavailable", "detail": c.signingError})
		return
	}
	b, err := mirrorReadBody(w, r, c.options.Limits)
	var request mirrorRequest
	if err != nil || strictMirrorJSON(b, &request, 4096) != nil {
		writeJSON(w, 400, map[string]string{"reason": "invalid-request"})
		return
	}
	repo, err := canonicalMirrorRepository(request.Repository)
	if err != nil || !validMirrorRef(request.Ref) || !mirrorNonce.MatchString(request.Nonce) || request.OperationID != "" && !mirrorNonce.MatchString(request.OperationID) {
		writeJSON(w, 400, map[string]string{"reason": "invalid-request"})
		return
	}
	request.Repository = repo
	job, reason := c.admit(request)
	if job != nil && !job.population {
		select {
		case <-job.done:
		case <-ctx.Done():
		}
	}
	receipt := c.receipt(request, job, reason)
	envelope, err := c.signer.sign(receipt)
	if err != nil {
		writeJSON(w, 503, map[string]string{"reason": "mirror-unavailable"})
		return
	}
	writeJSON(w, 200, envelope)
}
