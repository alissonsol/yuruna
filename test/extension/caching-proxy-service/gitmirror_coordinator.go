// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type mirrorRepository struct {
	state        mirrorState
	published    bool
	active, next *mirrorJob
	maintenance  bool
	retryAt      time.Time
	failures     int
	writer       sync.Mutex
	diagnostic   *mirrorDiagnostic
}
type mirrorJob struct {
	id, repository  string
	deadline        time.Time
	snapshotStarted bool
	population      bool
	done            chan struct{}
	state           mirrorState
	err             error
}
type mirrorCoordinator struct {
	options         mirrorOptions
	git             *mirrorGit
	registry        *mirrorRegistry
	signer          *mirrorSigner
	signingError    string
	ctx             context.Context
	cancel          context.CancelFunc
	mu              sync.Mutex
	storageMu       sync.Mutex
	repositories    map[string]*mirrorRepository
	jobs            map[string]*mirrorJob
	workers         chan struct{}
	wg              sync.WaitGroup
	metrics         map[string]uint64
	lastMaintenance string
	storageFree     uint64
	storageUsed     uint64
	storageError    error
}

func newMirrorCoordinator(ctx context.Context, options mirrorOptions) (*mirrorCoordinator, error) {
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Limits.Workers < 1 || options.Limits.Queue < 1 || options.Limits.Repositories < 1 ||
		options.Limits.Retention < 14*24*time.Hour {
		return nil, errors.New("invalid mirror limits")
	}
	for _, path := range []string{options.Root, options.StateRoot, filepath.Join(options.StateRoot, "state"), filepath.Join(options.StateRoot, "staging"), options.ReaderRoot} {
		if err := os.MkdirAll(path, 0750); err != nil {
			return nil, err
		}
	}
	runCtx, cancel := context.WithCancel(ctx)
	c := &mirrorCoordinator{options: options, ctx: runCtx, cancel: cancel, repositories: map[string]*mirrorRepository{},
		jobs: map[string]*mirrorJob{}, workers: make(chan struct{}, options.Limits.Workers), metrics: map[string]uint64{}}
	c.git = &mirrorGit{options: options}
	c.registry = newMirrorRegistry(options, c.git)
	c.signer, _ = loadMirrorSigner(options.SigningKey)
	if c.signer == nil {
		c.signingError = "signing-key-absent"
	}
	if err := c.registry.reload(ctx); err != nil {
		cancel()
		return nil, err
	}
	for _, repo := range c.registry.list() {
		r := &mirrorRepository{state: newMirrorState(repo)}
		path := mirrorRepoPath(options.Root, repo)
		if stat, err := os.Stat(path); err == nil && stat.IsDir() {
			r.published = true
			if b, err := os.ReadFile(c.statePath(repo)); err == nil {
				if json.Unmarshal(b, &r.state) != nil || r.state.Repository != repo || r.state.Refs == nil || r.state.Pins == nil {
					r.state = newMirrorState(repo)
					r.state.Outcome = "local-error"
				}
			}
			recoverCtx, stop := context.WithTimeout(ctx, options.Limits.Job)
			if err := c.recover(recoverCtx, repo, &r.state); err != nil {
				r.state.Outcome = "local-error"
				r.state.Detail = "recovery-failed"
			} else {
				_ = os.Remove(filepath.Join(mirrorReaderDir(options, repo), "maintenance"))
			}
			stop()
		}
		c.repositories[repo] = r
		if err := c.prepareReaderFiles(repo); err != nil {
			cancel()
			return nil, err
		}
	}
	_, _, _ = c.storage()
	return c, nil
}

func (c *mirrorCoordinator) close() { c.cancel(); c.wg.Wait() }
func (c *mirrorCoordinator) statePath(repo string) string {
	return filepath.Join(c.options.StateRoot, "state", mirrorRepoKey(repo)+".json")
}
func (c *mirrorCoordinator) persist(state mirrorState) error {
	b, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return mirrorAtomicFile(c.statePath(state.Repository), b, 0640)
}
func cloneMirrorState(state mirrorState) mirrorState {
	b, _ := json.Marshal(state)
	var out mirrorState
	_ = json.Unmarshal(b, &out)
	return out
}
func (c *mirrorCoordinator) recover(ctx context.Context, repo string, state *mirrorState) error {
	path := mirrorRepoPath(c.options.Root, repo)
	if err := mirrorCleanupLocks(path); err != nil {
		return err
	}
	if _, err := os.Stat(mirrorMarker(path)); err == nil {
		if _, err = c.git.command(ctx, path, nil, "fsck", "--connectivity-only", "--no-dangling"); err != nil {
			return err
		}
	}
	for sha, pin := range state.Pins {
		actual, err := c.git.object(ctx, path, "refs/yuruna/pins/"+sha)
		if err != nil || actual != sha || !c.git.hasCommit(ctx, path, sha) {
			delete(state.Pins, sha)
			for ref, known := range state.Refs {
				if known.CommitSHA == sha {
					delete(state.Refs, ref)
				}
			}
		} else {
			state.Pins[sha] = pin
		}
	}
	if err := c.persist(*state); err != nil {
		return err
	}
	return mirrorEndMutation(path)
}

func (c *mirrorCoordinator) admit(request mirrorRequest) (*mirrorJob, string) {
	if !c.registry.contains(request.Repository) {
		return nil, "repository-not-registered"
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.options.Now()
	for id, j := range c.jobs {
		if now.After(j.deadline) {
			select {
			case <-j.done:
				delete(c.jobs, id)
			default:
			}
		}
	}
	if request.OperationID != "" {
		j := c.jobs[request.OperationID]
		if j == nil || j.repository != request.Repository || now.After(j.deadline) {
			return nil, "mirror-budget-exhausted"
		}
		return j, ""
	}
	r := c.repositories[request.Repository]
	if r == nil {
		r = &mirrorRepository{state: newMirrorState(request.Repository)}
		c.repositories[request.Repository] = r
		if err := c.prepareReaderFiles(request.Repository); err != nil {
			return nil, "mirror-unavailable"
		}
	}
	if r.maintenance {
		c.metrics["queue_rejected"]++
		return nil, "mirror-capacity-exhausted"
	}
	if !r.published && now.Before(r.retryAt) {
		return nil, "mirror-populating"
	}
	if r.active != nil {
		if r.active.population || !r.active.snapshotStarted {
			return r.active, ""
		}
		if r.next != nil {
			return r.next, ""
		}
	}
	queued := 0
	for _, j := range c.jobs {
		select {
		case <-j.done:
		default:
			queued++
		}
	}
	if queued >= c.options.Limits.Queue+c.options.Limits.Workers {
		c.metrics["queue_rejected"]++
		return nil, "mirror-capacity-exhausted"
	}
	var entropy [16]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return nil, "mirror-unavailable"
	}
	budget := c.options.Limits.Job
	population := !r.published
	if population {
		budget = c.options.Limits.Population
	}
	j := &mirrorJob{id: base64.RawURLEncoding.EncodeToString(entropy[:]), repository: request.Repository,
		deadline: now.Add(budget), done: make(chan struct{}), population: population}
	var predecessor <-chan struct{}
	if r.active != nil {
		predecessor = r.active.done
		r.next = j
	} else {
		r.active = j
	}
	c.jobs[j.id] = j
	c.wg.Add(1)
	go c.run(r, j, predecessor, budget)
	return j, ""
}

func (c *mirrorCoordinator) run(r *mirrorRepository, j *mirrorJob, predecessor <-chan struct{}, budget time.Duration) {
	defer c.wg.Done()
	started := time.Now()
	ctx, cancel := context.WithTimeout(c.ctx, budget)
	defer cancel()
	var err error
	if predecessor != nil {
		select {
		case <-predecessor:
		case <-ctx.Done():
			err = ctx.Err()
		}
	}
	acquired := false
	writerAcquired := false
	if err == nil {
		for {
			c.mu.Lock()
			maintenance := r.maintenance
			c.mu.Unlock()
			if maintenance {
				err = errMirrorBusy
				break
			}
			if r.writer.TryLock() {
				writerAcquired = true
				break
			}
			select {
			case <-ctx.Done():
				err = ctx.Err()
			case <-time.After(time.Millisecond):
			}
			if err != nil {
				break
			}
		}
	}
	if writerAcquired {
		defer r.writer.Unlock()
	}
	if err == nil {
		select {
		case c.workers <- struct{}{}:
			acquired = true
		case <-ctx.Done():
			err = ctx.Err()
		}
	}
	if acquired {
		defer func() { <-c.workers }()
	}
	var state mirrorState
	if err == nil {
		c.mu.Lock()
		state = cloneMirrorState(r.state)
		j.snapshotStarted = true
		c.mu.Unlock()
		state, err = c.refresh(ctx, j.repository, state, j.population)
	} else {
		err = mirrorWithPhase("admission", err)
		c.mu.Lock()
		state = cloneMirrorState(r.state)
		c.mu.Unlock()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	r.diagnostic = nil
	if err != nil {
		var failure *mirrorFailure
		if errors.As(err, &failure) {
			diagnostic := failure.diagnostic
			r.diagnostic = &diagnostic
		}
		outcome, detail := mirrorOutcome(err)
		state.Outcome = outcome
		state.Detail = detail
		state.LastCheckedAt = c.options.Now()
		c.metrics["checks_"+outcome]++
		if j.population {
			r.failures++
			n := r.failures - 1
			if n > 4 {
				n = 4
			}
			backoff := time.Minute * time.Duration(1<<n)
			if backoff > 15*time.Minute {
				backoff = 15 * time.Minute
			}
			r.retryAt = c.options.Now().Add(backoff)
		}
	} else {
		r.published = true
		r.failures = 0
		r.retryAt = time.Time{}
		c.metrics["checks_confirmed"]++
	}
	r.state = state
	j.state = cloneMirrorState(state)
	j.err = err
	c.metrics["update_duration_nanoseconds"] += uint64(time.Since(started))
	diagnosticText := ""
	if d := r.diagnostic; d != nil {
		diagnosticText = fmt.Sprintf(" phase=%s operation=%s exitCode=%d outputLimit=%s failure=%s", d.Phase, d.Operation, d.ExitCode, d.OutputLimit, d.Failure)
	}
	log.Printf("git-mirror repository=%s outcome=%s detail=%s duration=%s%s", j.repository, state.Outcome, state.Detail, time.Since(started), diagnosticText)
	if r.active == j {
		r.active = r.next
		r.next = nil
	} else if r.next == j {
		r.next = nil
	}
	close(j.done)
}

func mirrorOutcome(err error) (string, string) {
	if err == nil {
		return "confirmed", ""
	}
	var failure *mirrorFailure
	if errors.As(err, &failure) {
		err = failure.cause
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return "transport", "mirror-budget-exhausted"
	}
	switch err.Error() {
	case "mirror-upstream-unreachable":
		return "transport", "mirror-upstream-unreachable"
	case "upstream-blocked-by-switch":
		return "transport", "upstream-blocked-by-switch"
	case "mirror-auth-denied":
		return "auth-denied", "mirror-auth-denied"
	case "mirror-capacity-exhausted":
		return "capacity", "storage"
	default:
		return "local-error", "git-local-error"
	}
}

func (c *mirrorCoordinator) refresh(ctx context.Context, repo string, previous mirrorState, population bool) (result mirrorState, failure error) {
	phase := "recover"
	defer func() { failure = mirrorWithPhase(phase, failure) }()
	path := mirrorRepoPath(c.options.Root, repo)
	if !population {
		if _, err := os.Stat(mirrorMarker(path)); err == nil {
			if err = c.recover(ctx, repo, &previous); err != nil {
				return previous, err
			}
			_ = os.Remove(filepath.Join(mirrorReaderDir(c.options, repo), "maintenance"))
		}
	}
	phase = "snapshot"
	snapshot, err := c.git.snapshot(ctx, repo)
	if err != nil {
		return previous, err
	}
	stage := ""
	if population {
		phase = "staging"
		stage, err = os.MkdirTemp(filepath.Join(c.options.StateRoot, "staging"), "population-")
		if err != nil {
			return previous, err
		}
		defer os.RemoveAll(stage)
		path = stage
		if err = mirrorBeginMutation(path); err != nil {
			return previous, err
		}
		phase = "initialize"
		if err = c.git.initialize(ctx, path); err != nil {
			return previous, err
		}
	}
	needsFetch := population || len(previous.Refs) != len(snapshot.Objects)
	if !needsFetch {
		for ref, oid := range snapshot.Objects {
			known, ok := previous.Refs[ref]
			if !ok || known.ObjectSHA != oid || !c.git.hasCommit(ctx, path, known.CommitSHA) {
				needsFetch = true
				break
			}
		}
	}
	if needsFetch {
		phase = "capacity"
		if err = c.checkCapacity(); err != nil {
			return previous, err
		}
		if !population {
			if err = mirrorBeginMutation(path); err != nil {
				return previous, err
			}
		}
		phase = "fetch"
		err = c.withCapacity(ctx, func(fetchCtx context.Context) error { return c.git.fetch(fetchCtx, path, repo) })
		c.mu.Lock()
		c.metrics["fetches"]++
		c.mu.Unlock()
		if err != nil {
			if !population {
				_ = mirrorCleanupLocks(path)
				_ = mirrorCleanupTemporaryObjects(path)
			}
			if c.checkCapacity() != nil {
				return previous, errMirrorBusy
			}
			return previous, err
		}
	} else {
		c.mu.Lock()
		c.metrics["unchanged"]++
		c.mu.Unlock()
	}
	// A force-push between observation and fetch cannot be attested as the
	// old observation. A second snapshot/fetch is the only allowed retry.
	if needsFetch && !c.snapshotAvailable(ctx, path, snapshot) {
		phase = "snapshot-recheck"
		snapshot, err = c.git.snapshot(ctx, repo)
		if err != nil {
			return previous, err
		}
		if !c.snapshotAvailable(ctx, path, snapshot) {
			phase = "fetch-recheck"
			if err = c.withCapacity(ctx, func(fetchCtx context.Context) error { return c.git.fetch(fetchCtx, path, repo) }); err != nil {
				return previous, err
			}
			c.mu.Lock()
			c.metrics["fetches"]++
			c.mu.Unlock()
		}
		if !c.snapshotAvailable(ctx, path, snapshot) {
			phase = "verify-snapshot"
			return previous, errors.New("upstream-ref-moving")
		}
	}
	next := cloneMirrorState(previous)
	next.Refs = map[string]mirrorRef{}
	next.LastCheckedAt = snapshot.CheckedAt
	next.Outcome = "confirmed"
	next.Detail = ""
	next.DefaultBranch = snapshot.DefaultBranch
	if needsFetch {
		next.LastUpdatedAt = c.options.Now()
	}
	for ref, oid := range snapshot.Objects {
		phase = "pin"
		sha := oid
		if peeled := snapshot.Peeled[ref]; peeled != "" {
			sha = peeled
		}
		if !c.git.hasCommit(ctx, path, sha) {
			continue
		}
		next.Refs[ref] = mirrorRef{ObjectSHA: oid, CommitSHA: sha, ConfirmedAt: snapshot.CheckedAt}
		pin := next.Pins[sha]
		if pin.Confirmations == nil {
			pin.Confirmations = map[string]time.Time{}
		}
		pin.Confirmations[ref] = snapshot.CheckedAt
		pin.RetainUntil = c.options.Now().Add(c.options.Limits.Retention + c.options.Limits.RetentionGrace)
		next.Pins[sha] = pin
		actual, _ := c.git.object(ctx, path, "refs/yuruna/pins/"+sha)
		if actual != sha {
			if !needsFetch {
				if err = mirrorBeginMutation(path); err != nil {
					return previous, err
				}
			}
			if _, err = c.git.command(ctx, path, nil, "update-ref", "refs/yuruna/pins/"+sha, sha); err != nil {
				return previous, err
			}
		}
	}
	if snapshot.DefaultBranch != "" {
		phase = "head"
		head, _ := c.git.command(ctx, path, nil, "symbolic-ref", "HEAD")
		if strings.TrimSpace(head) != snapshot.DefaultBranch {
			if !needsFetch {
				if err = mirrorBeginMutation(path); err != nil {
					return previous, err
				}
			}
			if _, err = c.git.command(ctx, path, nil, "symbolic-ref", "HEAD", snapshot.DefaultBranch); err != nil {
				return previous, err
			}
		}
	}
	if population {
		phase = "verify-repository"
		if _, err = c.git.command(ctx, path, nil, "fsck", "--connectivity-only", "--no-dangling"); err != nil {
			return previous, err
		}
		phase = "publish"
		if err = os.MkdirAll(filepath.Dir(mirrorRepoPath(c.options.Root, repo)), 0750); err != nil {
			return previous, err
		}
		if err = os.Rename(path, mirrorRepoPath(c.options.Root, repo)); err != nil {
			return previous, err
		}
		path = mirrorRepoPath(c.options.Root, repo)
	}
	phase = "persist"
	if err = c.persist(next); err != nil {
		if population {
			// A first publication with no durable confirmation must remain
			// retryable in this process as well as after a worker restart.
			_ = os.Rename(path, stage)
		}
		return previous, err
	}
	phase = "finish-mutation"
	if err = mirrorEndMutation(path); err != nil {
		return previous, err
	}
	return next, nil
}

func (c *mirrorCoordinator) snapshotAvailable(ctx context.Context, path string, s mirrorSnapshot) bool {
	for ref, oid := range s.Objects {
		if ref == "HEAD" {
			continue
		}
		actual, err := c.git.object(ctx, path, ref)
		if err != nil || actual != oid {
			return false
		}
	}
	return true
}

func (c *mirrorCoordinator) storage() (free, used uint64, err error) {
	defer func() {
		c.mu.Lock()
		c.storageFree, c.storageUsed, c.storageError = free, used, err
		c.mu.Unlock()
	}()
	free, err = mirrorFreeBytes(c.options.Root)
	if err != nil {
		return 0, 0, err
	}
	for _, root := range []string{c.options.Root, filepath.Join(c.options.StateRoot, "staging")} {
		err = filepath.WalkDir(root, func(path string, d fs.DirEntry, e error) error {
			if e != nil {
				if os.IsNotExist(e) {
					return nil
				}
				return e
			}
			if d.Type()&os.ModeSymlink != 0 {
				return errors.New("unexpected storage symlink")
			}
			if !d.IsDir() {
				info, e := d.Info()
				if e != nil {
					if os.IsNotExist(e) {
						return nil
					}
					return e
				}
				used += mirrorAllocatedBytes(info)
			}
			return nil
		})
		if err != nil {
			return free, used, err
		}
	}
	return free, used, nil
}
func (c *mirrorCoordinator) checkCapacity() error {
	c.storageMu.Lock()
	defer c.storageMu.Unlock()
	free, used, err := c.storage()
	if err != nil {
		return err
	}
	if free < c.options.Limits.ReserveBytes || (c.options.Limits.CapBytes > 0 && used >= c.options.Limits.CapBytes) {
		return errMirrorBusy
	}
	return nil
}

func (c *mirrorCoordinator) withCapacity(parent context.Context, work func(context.Context) error) error {
	if err := c.checkCapacity(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	monitor := make(chan error, 1)
	go func() {
		timer := time.NewTicker(c.options.Limits.StorageInterval)
		defer timer.Stop()
		for {
			select {
			case <-ctx.Done():
				monitor <- nil
				return
			case <-timer.C:
				if err := c.checkCapacity(); err != nil {
					cancel()
					monitor <- err
					return
				}
			}
		}
	}()
	err := work(ctx)
	cancel()
	if capacity := <-monitor; capacity != nil {
		return capacity
	}
	return err
}

func (c *mirrorCoordinator) receipt(request mirrorRequest, j *mirrorJob, reason string) mirrorReceipt {
	now := c.options.Now()
	out := mirrorReceipt{SchemaVersion: 1, Nonce: request.Nonce, Repository: request.Repository, Ref: request.Ref,
		IssuedAt: mirrorStamp(now), ExpiresAt: mirrorStamp(now.Add(5 * time.Minute)), Status: "error", Reason: reason, UpstreamOutcome: "not-checked"}
	if j == nil {
		return out
	}
	select {
	case <-j.done:
	default:
		out.Status = "pending"
		out.OperationID = j.id
		out.OperationExpiresAt = mirrorStamp(j.deadline)
		if j.population {
			out.Reason = "mirror-populating"
		}
		return out
	}
	state := j.state
	out.ResolvedDefaultBranch = state.DefaultBranch
	out.UpstreamOutcome = state.Outcome
	if j.err != nil {
		if state.Outcome != "transport" {
			out.Reason = state.Detail
			if state.Outcome == "local-error" {
				out.Reason = "mirror-unavailable"
			}
			if state.Outcome == "capacity" {
				out.Reason = "mirror-capacity-exhausted"
				out.Detail = "storage"
			}
			return out
		}
		out.Status = "stale"
		out.Reason = "mirror-upstream-unreachable"
		out.Detail = state.Detail
	} else {
		out.Status = "ready"
		out.Reason = ""
	}
	ref, ok := state.Refs[request.Ref]
	if mirrorOID.MatchString(request.Ref) {
		if pin, found := state.Pins[request.Ref]; found {
			for _, confirmed := range pin.Confirmations {
				if confirmed.After(ref.ConfirmedAt) {
					ref = mirrorRef{CommitSHA: request.Ref, ConfirmedAt: confirmed}
					ok = true
				}
			}
		}
	}
	if !ok {
		out.Status = "error"
		if j.err == nil {
			out.Reason = "ref-missing-confirmed"
			out.UpstreamOutcome = "ref-missing"
		} else {
			out.Reason = "mirror-stale-expired"
		}
		return out
	}
	pin, ok := state.Pins[ref.CommitSHA]
	if !ok || now.After(pin.RetainUntil) {
		out.Status = "error"
		out.Reason = "mirror-stale-expired"
		return out
	}
	out.SelectedSHA = ref.CommitSHA
	out.FetchRef = "refs/yuruna/pins/" + ref.CommitSHA
	out.ObjectReady = true
	out.OriginCheckedAt = mirrorStamp(ref.ConfirmedAt)
	// Keep use records separate from confirmation state: a response concurrent
	// with a newer refresh must not overwrite that refresh's durable snapshot.
	release, err := mirrorReadLease(c.options, request.Repository)
	if err == nil {
		err = mirrorRecordUse(c.options, request.Repository, ref.CommitSHA)
		release()
	}
	if err != nil {
		out.Status = "error"
		out.Reason = "mirror-unavailable"
		out.ObjectReady = false
		out.SelectedSHA = ""
		out.FetchRef = ""
		out.OriginCheckedAt = ""
	}
	return out
}

func (c *mirrorCoordinator) startTimer() {
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		timer := time.NewTimer(0)
		defer timer.Stop()
		for {
			select {
			case <-c.ctx.Done():
				return
			case <-timer.C:
			}
			discovery, cancel := context.WithTimeout(c.ctx, c.options.Limits.Query)
			_ = c.registry.reload(discovery)
			cancel()
			for _, repo := range c.registry.list() {
				c.mu.Lock()
				r := c.repositories[repo]
				busy := r != nil && (r.active != nil || r.next != nil || r.maintenance || c.options.Now().Before(r.retryAt))
				c.mu.Unlock()
				if !busy {
					_, _ = c.admit(mirrorRequest{Repository: repo, Ref: "HEAD"})
				}
			}
			now := c.options.Now()
			if now.Weekday() == time.Sunday && now.Hour() == 3 {
				key := now.Format("2006-01-02")
				if c.lastMaintenance != key {
					c.lastMaintenance = key
					for _, repo := range c.registry.list() {
						c.wg.Add(1)
						go func(repo string) { defer c.wg.Done(); _ = c.maintain(c.ctx, repo) }(repo)
					}
				}
			}
			var jitter [1]byte
			_, _ = rand.Read(jitter[:])
			timer.Reset(c.options.Limits.Refresh + time.Duration(jitter[0])*c.options.Limits.Refresh/2560)
		}
	}()
}

func (c *mirrorCoordinator) status() map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	rows := []map[string]any{}
	for _, repo := range c.registry.list() {
		r := c.repositories[repo]
		if r == nil {
			rows = append(rows, map[string]any{"name": repo, "state": "populating"})
			continue
		}
		state := "ready"
		if !r.published {
			state = "populating"
		} else if r.state.Outcome == "local-error" {
			state = "local-error"
		} else if r.state.Outcome != "confirmed" {
			state = "stale"
		}
		row := map[string]any{"name": repo, "state": state, "lastCheckedAt": mirrorStamp(r.state.LastCheckedAt), "lastUpdatedAt": mirrorStamp(r.state.LastUpdatedAt), "upstreamOutcome": r.state.Outcome, "detail": r.state.Detail}
		if r.diagnostic != nil {
			row["diagnostic"] = r.diagnostic
		}
		rows = append(rows, row)
	}
	keyID := ""
	if c.signer != nil {
		keyID = c.signer.keyID
	}
	detail := c.signingError
	if c.storageError != nil {
		detail = "storage-unavailable"
	}
	return map[string]any{"apiVersion": 1, "capabilities": []string{"resolve", "git", "raw"}, "keyId": keyID, "version": version,
		"buildSource": c.options.BuildSource, "refreshIntervalSeconds": c.options.Limits.Refresh.Seconds(),
		"pinRetentionDays": c.options.Limits.Retention.Hours() / 24, "pinRetentionGraceSeconds": c.options.Limits.RetentionGrace.Seconds(),
		"storage":      map[string]any{"freeBytes": c.storageFree, "usedBytes": c.storageUsed, "reserveBytes": c.options.Limits.ReserveBytes, "capBytes": c.options.Limits.CapBytes},
		"repositories": rows, "detail": detail}
}

func (c *mirrorCoordinator) metricsText() string {
	c.mu.Lock()
	keys := make([]string, 0, len(c.metrics))
	for key := range c.metrics {
		if key != "update_duration_nanoseconds" {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, key := range keys {
		fmt.Fprintf(&b, "yuruna_git_mirror_%s_total %d\n", strings.ReplaceAll(key, "-", "_"), c.metrics[key])
	}
	fmt.Fprintf(&b, "yuruna_git_mirror_update_duration_seconds_total %.6f\n", float64(c.metrics["update_duration_nanoseconds"])/float64(time.Second))
	unfinished := 0
	for _, job := range c.jobs {
		select {
		case <-job.done:
		default:
			unfinished++
		}
	}
	fmt.Fprintf(&b, "yuruna_git_mirror_active_workers %d\nyuruna_git_mirror_pending_jobs %d\n", len(c.workers), unfinished)
	for repo, r := range c.repositories {
		if !c.registry.contains(repo) {
			continue
		}
		var oldest time.Time
		for _, ref := range r.state.Refs {
			if oldest.IsZero() || ref.ConfirmedAt.Before(oldest) {
				oldest = ref.ConfirmedAt
			}
		}
		if !oldest.IsZero() {
			age := c.options.Now().Sub(oldest).Seconds()
			if age < 0 {
				age = 0
			}
			fmt.Fprintf(&b, "yuruna_git_mirror_confirmation_age_seconds{repository=%q} %.3f\n", repo, age)
		}
		local := 0
		if r.state.Outcome == "local-error" {
			local = 1
		}
		fmt.Fprintf(&b, "yuruna_git_mirror_local_error{repository=%q} %d\n", repo, local)
	}
	if c.storageError == nil {
		fmt.Fprintf(&b, "yuruna_git_mirror_storage_free_bytes %d\nyuruna_git_mirror_storage_used_bytes %d\n", c.storageFree, c.storageUsed)
	}
	c.mu.Unlock()
	return b.String()
}
