// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The history backfill is a second mode of this binary, started as
// `pool-aggregator-service backfill` by its own unit. The collector records only
// what it watches happen, so a rebuilt proxy starts with an empty dashboard while
// every host still holds the cycles it ran. The backfill reads those cycles back
// from the hosts (or from the pool share) and writes them to Loki and Prometheus in
// the same shape the collector writes live data, for the hosts in the pool now.
// It reuses the collector's own line builders, so a backfilled cycle is
// indistinguishable from a watched one on every panel, and it never writes a
// cycle, an event line or a timeline sample that the stores already hold.
const (
	defaultBackfillStateDir = "/var/lib/pool-history-backfill"
	defaultBackfillHorizon  = 90 * 24 * time.Hour
	// Loki deletes src=event lines after 168h, so an older event would be written
	// only to be deleted at the next compaction.
	defaultBackfillEventHorizon    = 167 * time.Hour
	defaultBackfillSweep           = 15 * time.Minute
	defaultBackfillStartDelay      = 3 * time.Minute
	defaultBackfillHostInterval    = 2 * time.Second
	defaultBackfillHostConcurrency = 4
	defaultBackfillCyclesPerMinute = 120
	// A cycle that ended this recently may still be on its way to Loki through the
	// collector, which polls every 15s; the backfill leaves it to the collector.
	defaultBackfillSettle = 30 * time.Minute
	// A cycle that fails this many attempts in a row is left alone until its
	// host's state file is removed.
	maxCycleReadFailures = 3
	// The incidents and the timeline are rebuilt at least this often, and the
	// state of hosts gone from the pool is reviewed as often.
	derivedRefreshInterval = 24 * time.Hour
	// A host's SeenAt moves at most this often, so a pass with nothing to do does
	// not rewrite the host's state file.
	seenAtResolution = time.Hour
	// Bytes per second this job sends to Loki: a quarter of the ingestion limit,
	// so the collector's own pushes never queue behind a backfill burst.
	lokiBackfillBytesPerSecond = 1 << 20
	// Remote-write requests are at least this far apart.
	remoteWriteInterval = time.Second
	// The timeline holds a backfilled cycle's final status for at most this long
	// after the cycle ended. A host starts its next cycle within minutes; a longer
	// gap was a pause, a stopped runner or a host that was off, which the job
	// cannot tell apart, so it leaves the gap empty rather than paint it green.
	maxFinalHold = 30 * time.Minute
	// History buckets are named for a local date; this covers any time zone.
	bucketDateSlack = 48 * time.Hour
	// Answers from Loki and Prometheus are read up to this size.
	maxQueryBytes = 32 << 20
	// Cycles read per host per sweep. A host with months of history is filled in
	// slices, newest first, and the dashboard gains each slice as it lands
	// instead of waiting hours for the whole history.
	maxCyclesPerHostPass = 200
	// The pause before the next sweep while some host still has history left.
	busySweepPause = time.Minute
	indexDirName   = "index"
	// A host's log listing is read again at most this often. Between listings a
	// pass works from the folders the last one found and from the pool share,
	// neither of which costs the host anything, and the cycles that started
	// since are the collector's.
	hostListingInterval = time.Hour
	// A host's status service is one PowerShell listener that serves a single
	// request at a time, and a guest gives it a few seconds to answer a
	// livecheck. A listing request that took longer than this kept every guest
	// of that host waiting, so the host is asked for nothing at all for
	// listingDeferral after it. A request that timed out took longer.
	slowListingThreshold = 10 * time.Second
	listingDeferral      = 24 * time.Hour
)

// backfillConfig is the backfill's command line.
type backfillConfig struct {
	aggregatorURL   string
	lokiPushURL     string
	prometheusURL   string
	stateDir        string
	archiveRoot     string
	horizon         time.Duration
	eventHorizon    time.Duration
	sweepInterval   time.Duration
	startDelay      time.Duration
	hostInterval    time.Duration
	hostConcurrency int
	cyclesPerMinute int
	incidentN       int
	incidentWin     time.Duration
	sampleStep      time.Duration
	settle          time.Duration
	once            bool
}

// parseBackfillFlags reads the backfill's flags. The language switches are
// accepted because the unit passes them to every mode of the binary; the
// operator-message renderer reads them from the command line itself.
func parseBackfillFlags(args []string) (backfillConfig, error) {
	fs := flag.NewFlagSet("backfill", flag.ContinueOnError)
	cfg := backfillConfig{}
	fs.StringVar(&cfg.aggregatorURL, "aggregator", "http://127.0.0.1:9400", "")
	fs.StringVar(&cfg.lokiPushURL, "loki", defaultLokiURL, "")
	fs.StringVar(&cfg.prometheusURL, "prometheus", "http://127.0.0.1:9090", "")
	fs.StringVar(&cfg.stateDir, "state-dir", defaultBackfillStateDir, "")
	fs.StringVar(&cfg.archiveRoot, "archive-root", "", "")
	fs.DurationVar(&cfg.horizon, "horizon", defaultBackfillHorizon, "")
	fs.DurationVar(&cfg.eventHorizon, "event-horizon", defaultBackfillEventHorizon, "")
	fs.DurationVar(&cfg.sweepInterval, "sweep-interval", defaultBackfillSweep, "")
	fs.DurationVar(&cfg.startDelay, "start-delay", defaultBackfillStartDelay, "")
	fs.DurationVar(&cfg.hostInterval, "host-interval", defaultBackfillHostInterval, "")
	fs.IntVar(&cfg.hostConcurrency, "host-concurrency", defaultBackfillHostConcurrency, "")
	fs.IntVar(&cfg.cyclesPerMinute, "cycles-per-minute", defaultBackfillCyclesPerMinute, "")
	fs.IntVar(&cfg.incidentN, "incident-fails", defaultIncidentN, "")
	fs.DurationVar(&cfg.incidentWin, "incident-window", defaultIncidentWin, "")
	fs.DurationVar(&cfg.sampleStep, "sample-step", defaultSampleStep, "")
	fs.DurationVar(&cfg.settle, "settle", defaultBackfillSettle, "")
	fs.BoolVar(&cfg.once, "once", false, "")
	fs.String("language", "auto", "")
	fs.Bool("allow-pseudo-locale", false, "")
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return cfg, err
	}
	if fs.NArg() > 0 {
		return cfg, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	return cfg, cfg.validate()
}

// validate refuses a configuration the job cannot run safely with, naming the flag.
func (c backfillConfig) validate() error {
	switch {
	case strings.TrimSpace(c.aggregatorURL) == "":
		return errors.New("-aggregator is empty")
	case strings.TrimSpace(c.lokiPushURL) == "":
		return errors.New("-loki is empty")
	case strings.TrimSpace(c.prometheusURL) == "":
		return errors.New("-prometheus is empty")
	case strings.TrimSpace(c.stateDir) == "":
		return errors.New("-state-dir is empty")
	case c.horizon <= 0:
		return errors.New("-horizon must be positive")
	case c.eventHorizon < 0:
		return errors.New("-event-horizon must not be negative")
	case c.sweepInterval <= 0:
		return errors.New("-sweep-interval must be positive")
	case c.startDelay < 0:
		return errors.New("-start-delay must not be negative")
	case c.hostInterval < 0:
		return errors.New("-host-interval must not be negative")
	case c.hostConcurrency < 1:
		return errors.New("-host-concurrency must be at least 1")
	case c.cyclesPerMinute < 1:
		return errors.New("-cycles-per-minute must be at least 1")
	case c.incidentN < 1:
		return errors.New("-incident-fails must be at least 1")
	case c.incidentWin <= 0:
		return errors.New("-incident-window must be positive")
	case c.sampleStep <= 0 || c.sampleStep >= coverageStep:
		// A step as long as the coverage window would leave windows with no
		// sample, and the timeline would show them as gaps.
		return fmt.Errorf("-sample-step must be positive and shorter than %s", coverageStep)
	case c.settle < 0:
		return errors.New("-settle must not be negative")
	}
	return nil
}

// runBackfill is the entry point of `pool-aggregator-service backfill`.
func runBackfill(args []string) int {
	cfg, err := parseBackfillFlags(args)
	if errors.Is(err, flag.ErrHelp) {
		return 0
	}
	if err != nil {
		log.Print(operatorMessage("aggregator.backfill_bad_flag", map[string]any{"value1": err.Error()}))
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	b := newBackfiller(cfg, newInternalHTTPClient(backfillRequestTimeout), func() time.Time { return time.Now().UTC() }, sleepCtx)
	b.run(ctx)
	return 0
}

// backfiller holds one running backfill. now and sleep are the only clock it
// reads, so a test drives a whole sweep without waiting.
type backfiller struct {
	cfg    backfillConfig
	client *http.Client
	now    func() time.Time
	sleep  func(ctx context.Context, d time.Duration) bool
	// cyclePacer spreads cycle reads over time across all hosts; lokiPacer keeps
	// this job's Loki pushes inside its byte budget; writePacer spaces the
	// Prometheus remote writes.
	cyclePacer *pacer
	lokiPacer  *pacer
	writePacer *pacer
	// prunedAt is when the files of hosts gone from the pool were last reviewed.
	prunedAt time.Time
}

func newBackfiller(cfg backfillConfig, client *http.Client, now func() time.Time, sleep func(context.Context, time.Duration) bool) *backfiller {
	b := &backfiller{cfg: cfg, client: client, now: now, sleep: sleep}
	b.cyclePacer = &pacer{interval: time.Minute / time.Duration(cfg.cyclesPerMinute), now: now, sleep: sleep}
	b.lokiPacer = &pacer{now: now, sleep: sleep}
	b.writePacer = &pacer{interval: remoteWriteInterval, now: now, sleep: sleep}
	return b
}

// run sweeps until ctx ends. The first sweep waits out the start delay, which
// gives the collector time to find the hosts after a boot: the pool-status
// document lists only the hosts the collector has reached.
func (b *backfiller) run(ctx context.Context) {
	log.Print(operatorMessage("aggregator.backfill_started", map[string]any{"value1": b.cfg.horizon.String(), "value2": b.cfg.sweepInterval.String()}))
	if !b.cfg.once && b.cfg.startDelay > 0 && !b.sleep(ctx, b.cfg.startDelay) {
		return
	}
	for {
		res := b.sweep(ctx)
		if b.cfg.once || ctx.Err() != nil {
			return
		}
		pause := b.cfg.sweepInterval
		if res.More > 0 && busySweepPause < pause {
			pause = busySweepPause
		}
		if !b.sleep(ctx, pause) {
			return
		}
	}
}

// hostResult counts what one host's pass wrote.
type hostResult struct {
	Cycles     int // cycles whose transition lines were written
	Events     int // cycles whose event lines were written
	Incidents  int // incidents replayed
	Samples    int // timeline samples written
	Unreadable int // cycles whose event file could not be read, or whose lines Loki refused
	More       int // hosts with cycles left for a later sweep
}

func (r *hostResult) add(o hostResult) {
	r.Cycles += o.Cycles
	r.Events += o.Events
	r.Incidents += o.Incidents
	r.Samples += o.Samples
	r.Unreadable += o.Unreadable
	r.More += o.More
}

// sweep backfills every host the collector reaches right now. A host that joins
// the pool later is picked up by the first sweep after it appears. Each host's
// pass loads and saves only that host's own state file, so passes run side by
// side without sharing anything but the pacers.
func (b *backfiller) sweep(ctx context.Context) hostResult {
	var total hostResult
	now := b.now()
	if now.Sub(b.prunedAt) >= derivedRefreshInterval {
		pruneHostFiles(b.cfg.stateDir, now.Add(-b.cfg.horizon))
		b.prunedAt = now
	}
	hosts, err := b.activeHosts(ctx)
	if err != nil {
		log.Print(operatorMessage("aggregator.backfill_pool_status_failed", map[string]any{"value1": err.Error()}))
		return total
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, b.cfg.hostConcurrency)
	for _, h := range hosts {
		select {
		case sem <- struct{}{}:
		case <-ctx.Done():
		}
		if ctx.Err() != nil {
			break
		}
		wg.Add(1)
		go func(h activeHost) {
			defer wg.Done()
			defer func() { <-sem }()
			res := b.hostPass(ctx, h)
			mu.Lock()
			total.add(res)
			mu.Unlock()
		}(h)
	}
	wg.Wait()
	log.Print(operatorMessage("aggregator.backfill_sweep_done", map[string]any{
		"value1": fmt.Sprintf("%d", len(hosts)), "value2": fmt.Sprintf("%d", total.Cycles), "value3": fmt.Sprintf("%d", total.Events),
		"value4": fmt.Sprintf("%d", total.Incidents), "value5": fmt.Sprintf("%d", total.Samples), "value6": fmt.Sprintf("%d", total.Unreadable),
		"value7": fmt.Sprintf("%d", total.More),
	}))
	return total
}

// hostPass runs one host's pass between loading its state and saving it. The
// state is saved even when the pass stopped part way: what it recorded as written
// is written, and forgetting that would write it again.
func (b *backfiller) hostPass(ctx context.Context, h activeHost) hostResult {
	hs := loadHostState(b.cfg.stateDir, h.HostID)
	before := hs.fingerprint()
	res, err := b.backfillHost(ctx, h, hs)
	if err != nil && ctx.Err() == nil {
		log.Print(operatorMessage("aggregator.backfill_host_failed", map[string]any{"value1": h.HostID, "value2": err.Error()}))
	}
	hs.prune(b.now().Add(-b.cfg.horizon))
	if hs.changedSince(before) {
		if err := hs.save(b.cfg.stateDir); err != nil {
			log.Print(operatorMessage("aggregator.backfill_state_failed", map[string]any{"value1": h.HostID, "value2": err.Error()}))
		}
	}
	return res
}

// activeHosts reads the collector's pool-status document.
func (b *backfiller) activeHosts(ctx context.Context) ([]activeHost, error) {
	body, err := getBounded(ctx, b.client, strings.TrimRight(b.cfg.aggregatorURL, "/")+routePoolStatus, maxListingBytes)
	if err != nil {
		return nil, err
	}
	return parsePoolStatus(body)
}

// getJSON reads a Loki or Prometheus answer.
func (b *backfiller) getJSON(ctx context.Context, u string, out any) error {
	body, err := getBounded(ctx, b.client, u, maxQueryBytes)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, out)
}

// lokiRefusal is Loki rejecting the content of a push -- an entry too old, or
// behind the newest one of a stream the collector wrote. Sending it again cannot
// succeed, so it is charged to the cycle rather than ending the host's pass.
type lokiRefusal struct {
	status int
	msg    string
}

func (e *lokiRefusal) Error() string {
	return fmt.Sprintf("loki push: HTTP %d: %s", e.status, e.msg)
}

func isLokiRefusal(err error) bool {
	var r *lokiRefusal
	return errors.As(err, &r)
}

// pushLoki sends one push body to Loki inside this job's byte budget.
func (b *backfiller) pushLoki(ctx context.Context, payload map[string]any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if !b.lokiPacer.reserve(ctx, time.Duration(len(body))*time.Second/lokiBackfillBytesPerSecond) {
		return ctx.Err()
	}
	ctx, cancel := context.WithTimeout(ctx, backfillRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.cfg.lokiPushURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := b.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	switch {
	case resp.StatusCode/100 == 2:
		return nil
	case resp.StatusCode == http.StatusBadRequest:
		return &lokiRefusal{status: resp.StatusCode, msg: strings.TrimSpace(string(msg))}
	default:
		// 429 and 5xx: Loki is busy or down, and the next sweep tries again.
		return fmt.Errorf("loki push: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
}

// pushAll sends payloads in order, stopping at the first that fails.
func (b *backfiller) pushAll(ctx context.Context, payloads []map[string]any) error {
	for _, payload := range payloads {
		if err := b.pushLoki(ctx, payload); err != nil {
			return err
		}
	}
	return nil
}

// hostGet is one paced request to a host's status service, and how long the host
// took to answer it. A host that was slow to answer is left alone for twice as
// long as the answer took.
func (b *backfiller) hostGet(ctx context.Context, p *pacer, u string, limit int64) ([]byte, time.Duration, error) {
	if !p.wait(ctx) {
		return nil, 0, ctx.Err()
	}
	started := b.now()
	body, err := getBounded(ctx, b.client, u, limit)
	took := b.now().Sub(started)
	p.atLeast(2 * took)
	return body, took, err
}

// discover finds the host's cycle folders. When a listing is due it reads the
// host's log listing; otherwise, or when that read fails, it takes the folders
// the cycle index recorded. The committed copies on the pool share are added
// either way, so a host whose listing cannot be read still has its archived
// history restored. fresh reports whether this pass listed the host. A listing
// that failed or deferred the host is returned as err, saying when the host is
// asked again, with whatever was found; it ends the pass only when nothing was.
func (b *backfiller) discover(ctx context.Context, h activeHost, hs *backfillHostState, p *pacer, from time.Time) (folders map[string]cycleFolder, fresh bool, err error) {
	folders = map[string]cycleFolder{}
	archived, archiveReadable := archiveFolders(b.cfg.archiveRoot, h.HostID)
	if hs.listingDue(b.now()) {
		slowest, lerr := b.listHost(ctx, h, hs, p, from, folders, archiveReadable)
		if lerr != nil && ctx.Err() != nil {
			return nil, false, lerr
		}
		fresh = lerr == nil
		switch {
		case hs.hostDeferred(b.now()) && lerr != nil:
			err = fmt.Errorf("%w; the host is asked for nothing before %s", lerr, formatUTC(hs.ListingDeferredUntil))
		case hs.hostDeferred(b.now()):
			err = fmt.Errorf("its log listing took %s, so the host is asked for nothing before %s", slowest.Round(time.Second), formatUTC(hs.ListingDeferredUntil))
		case lerr != nil:
			err = fmt.Errorf("%w; its log listing is read again after %s", lerr, formatUTC(hs.ListedAt.Add(hostListingInterval)))
		}
	}
	if !fresh {
		for identity, cf := range knownFolders(b.cfg.stateDir, h.HostID) {
			folders[identity] = cf
		}
	}
	for identity, dir := range archived {
		cf := folders[identity]
		if cf.Identity == "" {
			start, ok := cycleStartFromFolder(identity)
			if !ok {
				continue
			}
			cf = cycleFolder{Identity: identity, Start: start}
		}
		cf.ArchiveDir = dir
		folders[identity] = cf
	}
	if err != nil && len(folders) == 0 {
		return nil, false, err
	}
	return folders, fresh, err
}

// listHost reads the host's log listing into folders: the live log directory and
// the history buckets it links that can hold cycles inside the horizon. It
// records the attempt in hs, defers the host when any request of it was slow or
// timed out, and returns the slowest request's time. Only the live log directory
// is required; a bucket that cannot be read is left for the next listing.
func (b *backfiller) listHost(ctx context.Context, h activeHost, hs *backfillHostState, p *pacer, from time.Time, folders map[string]cycleFolder, archiveReadable bool) (slowest time.Duration, err error) {
	started := b.now()
	get := func(u string) ([]byte, error) {
		body, took, err := b.hostGet(ctx, p, u, maxListingBytes)
		if took > slowest {
			slowest = took
		}
		return body, err
	}
	defer func() {
		if ctx.Err() == nil {
			hs.ListedAt = started
		}
		if slowest >= slowListingThreshold {
			hs.ListingDeferredUntil = b.now().Add(listingDeferral)
		}
	}()
	listingURL := h.BaseURL + "/log/"
	if archiveReadable {
		// The proxy already read these archives. Asking the host to enumerate
		// their completion sentinels again can block its single status listener.
		// Keep the merged listing when only the host can reach the archive.
		listingURL += "?localOnly=true"
	}
	body, err := get(listingURL)
	if err != nil {
		return slowest, err
	}
	leaves, buckets := parseListing(string(body))
	for _, leaf := range leaves {
		if cf, ok := cycleFolderFromLeaf(leaf, h.HostID, "log/"); ok {
			mergeFolder(folders, cf)
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(buckets)))
	for i, bucket := range buckets {
		d, ok := bucketDate(bucket)
		if !ok || d.Add(bucketDateSlack).Before(from) {
			continue
		}
		// Only the newest bucket can still receive folders; the others are read
		// once and kept.
		cached, have := hs.Buckets[bucket]
		if i > 0 && have {
			leaves = cached
		} else {
			lb, err := get(h.BaseURL + "/log/" + bucket + "/")
			if err != nil {
				if ctx.Err() != nil {
					return slowest, err
				}
				continue
			}
			leaves, _ = parseListing(string(lb))
			if i > 0 {
				hs.Buckets[bucket] = leaves
			}
		}
		for _, leaf := range leaves {
			if cf, ok := cycleFolderFromLeaf(leaf, h.HostID, "log/"+bucket+"/"); ok {
				mergeFolder(folders, cf)
			}
		}
	}
	return slowest, nil
}

// hostReadable reports whether a pass may ask the host for a cycle's event file.
// A deferred host is asked for nothing. A folder an earlier listing saw while its
// cycle was running is renamed when the cycle ends, so only a listing made by
// this pass can name it.
func hostReadable(cf cycleFolder, hostUsable, fresh bool) bool {
	return hostUsable && (fresh || !strings.HasSuffix(cf.RelDir, ".incomplete/"))
}

// readCycle reads a cycle's event file, from the pool share when it holds a
// committed copy -- local disk here, and no request to the host -- else from the
// host when useHost allows it.
func (b *backfiller) readCycle(ctx context.Context, h activeHost, cf cycleFolder, p *pacer, useHost bool) ([]byte, error) {
	if cf.ArchiveDir != "" {
		if data, err := readFileBounded(filepath.Join(cf.ArchiveDir, eventsFile), maxEventsFileBytes); err == nil {
			return data, nil
		}
	}
	if cf.RelDir == "" {
		return nil, errNoCycleSource
	}
	if !useHost {
		return nil, errHostNotAsked
	}
	body, _, err := b.hostGet(ctx, p, h.BaseURL+"/"+cf.RelDir+eventsFile, maxEventsFileBytes)
	return body, err
}

// backfillHost brings one host's history into Loki and Prometheus.
func (b *backfiller) backfillHost(ctx context.Context, h activeHost, hs *backfillHostState) (hostResult, error) {
	var res hostResult
	now := b.now()
	if now.Sub(hs.SeenAt) >= seenAtResolution {
		hs.SeenAt = now
	}
	from := now.Add(-b.cfg.horizon)
	// The cycle the host is on belongs to the collector, and so does any cycle
	// that ended too recently for the collector to have finished with it.
	until := now.Add(-b.cfg.settle)
	if !h.CurrentStart.IsZero() && h.CurrentStart.Before(until) {
		until = h.CurrentStart
	}
	hostPacer := &pacer{interval: b.cfg.hostInterval, now: b.now, sleep: b.sleep}
	history := timelineFromHistory(h.History, now)

	// A listing that failed does not end the pass while anything else names the
	// host's cycles; it is reported once the pass has written what it could.
	folders, fresh, listErr := b.discover(ctx, h, hs, hostPacer, from)
	if folders == nil {
		if ctx.Err() != nil || len(history) == 0 {
			return res, listErr
		}
		folders = map[string]cycleFolder{}
	}
	hostUsable := !hs.hostDeferred(b.now())
	outcomes := loadCycleOutcomes(b.cfg.stateDir, h.HostID)
	var todo []cycleFolder
	for _, cf := range folders {
		if cf.Start.Before(from) || !cf.Start.Before(until) || hs.Done[cf.Identity] || hs.Failures[cf.Identity] >= maxCycleReadFailures {
			continue
		}
		// A cycle only the host holds waits, uncharged, for a pass that may ask
		// the host for it, and does not keep the sweeps in their busy pace.
		if cf.ArchiveDir == "" && !hostReadable(cf, hostUsable, fresh) {
			continue
		}
		todo = append(todo, cf)
	}
	// Newest first: the most recent days are what the dashboard opens on.
	sort.Slice(todo, func(i, j int) bool { return todo[i].Start.After(todo[j].Start) })

	wrote := false
	var err error
	if len(todo) > 0 {
		wrote, err = b.backfillCycles(ctx, h, hs, hostPacer, todo, now, outcomes, &res, hostUsable, fresh)
	}
	// Written even after a failed pass, so the outcomes of the cycles it did write
	// are not lost.
	if ierr := writeCycleIndex(b.cfg.stateDir, h.HostID, folders, outcomes); ierr != nil {
		log.Print(operatorMessage("aggregator.backfill_index_failed", map[string]any{"value1": h.HostID, "value2": ierr.Error()}))
	}
	if err != nil {
		return res, err
	}
	// Full derived history changes when cycles are written and is also checked
	// daily. The status snapshot can acquire recent verdicts while host reads
	// remain deferred, so check that smaller interval on the intervening passes.
	refreshDerived := wrote || hs.DerivedAt.IsZero() || now.Sub(hs.DerivedAt) >= derivedRefreshInterval
	if refreshDerived {
		n, err := b.replayIncidents(ctx, h, hs, from, now, outcomes)
		res.Incidents += n
		if err != nil {
			return res, err
		}
	} else {
		if len(history) == 0 {
			return res, listErr
		}
		if history[0].Start.After(from) {
			from = history[0].Start
		}
	}
	n, err := b.fillTimeline(ctx, h, from, now, outcomes)
	res.Samples += n
	if err != nil {
		return res, err
	}
	if refreshDerived {
		hs.DerivedAt = now
	}
	return res, listErr
}

// backfillCycles writes what Loki is missing of the given cycles, newest first.
// A cycle Loki already holds in full is marked Done without a read; of the rest,
// at most maxCyclesPerHostPass are read, and res.More says whether any were left.
// Every cycle it writes is marked Done and its outcome recorded in outcomes. It
// reports whether any transition line was written. hostUsable and fresh say
// whether the host may be asked for an event file, as hostReadable decides.
func (b *backfiller) backfillCycles(ctx context.Context, h activeHost, hs *backfillHostState, p *pacer, todo []cycleFolder, now time.Time, outcomes map[string]cycleOutcome, res *hostResult, hostUsable, fresh bool) (bool, error) {
	oldest := todo[len(todo)-1].Start
	// Every line of a cycle is stamped at or after its start, so Loki is asked
	// only about the stretch the candidates can occupy.
	qFrom := oldest.Add(-time.Minute)
	streams, err := b.lokiCycleStreams(ctx, h.HostID, qFrom, now)
	if err != nil {
		return false, err
	}
	terminal, err := b.lokiTerminalCycles(ctx, h.HostID, qFrom, now)
	if err != nil {
		return false, err
	}
	eventFrom := now.Add(-b.cfg.eventHorizon)
	events := map[string]bool{}
	if b.cfg.eventHorizon > 0 && todo[0].Start.After(eventFrom) {
		evFrom := qFrom
		if evFrom.Before(eventFrom) {
			evFrom = eventFrom
		}
		if events, err = b.lokiEventCycles(ctx, h.HostID, evFrom, now); err != nil {
			return false, err
		}
	}

	type job struct {
		cf         cycleFolder
		needEvents bool
	}
	var work []job
	for _, cf := range todo {
		key := formatUTC(cf.Start)
		needEvents := b.cfg.eventHorizon > 0 && cf.Start.After(eventFrom) && !events[key]
		if terminal[key] && !needEvents {
			hs.Done[cf.Identity] = true
			continue
		}
		work = append(work, job{cf: cf, needEvents: needEvents})
	}
	if len(work) > maxCyclesPerHostPass {
		work = work[:maxCyclesPerHostPass]
		res.More = 1
	}

	wrote := false
	for _, w := range work {
		cf, needEvents := w.cf, w.needEvents
		if !b.cyclePacer.wait(ctx) {
			return wrote, ctx.Err()
		}
		data, err := b.readCycle(ctx, h, cf, p, hostReadable(cf, hostUsable, fresh))
		if err != nil {
			if ctx.Err() != nil {
				return wrote, ctx.Err()
			}
			if errors.Is(err, errHostNotAsked) {
				continue
			}
			b.cycleFailed(h, hs, cf, err, res)
			continue
		}
		rec := reconstructCycle(cf, data)
		recKey := cycleKey(rec.CycleStartUtc)
		if !terminal[recKey] {
			if err := b.pushAll(ctx, cycleLinePayloads(h, cf.Identity, rec, !streams[recKey])); err != nil {
				if !isLokiRefusal(err) {
					return wrote, err
				}
				b.cycleFailed(h, hs, cf, err, res)
				continue
			}
			wrote = true
			res.Cycles++
			outcomes[cf.Identity] = outcomeOf(rec)
		}
		if needEvents && !events[recKey] && len(rec.Lines) > 0 {
			if err := b.pushAll(ctx, eventPayloads(h, rec)); err != nil {
				if !isLokiRefusal(err) {
					return wrote, err
				}
				b.cycleFailed(h, hs, cf, err, res)
				continue
			}
			res.Events++
		}
		delete(hs.Failures, cf.Identity)
		hs.Done[cf.Identity] = true
	}
	return wrote, nil
}

// cycleFailed counts one failed attempt at a cycle, and says so in the log once,
// on the attempt after which the cycle is given up on.
func (b *backfiller) cycleFailed(h activeHost, hs *backfillHostState, cf cycleFolder, err error, res *hostResult) {
	hs.Failures[cf.Identity]++
	res.Unreadable++
	if hs.Failures[cf.Identity] == maxCycleReadFailures {
		log.Print(operatorMessage("aggregator.backfill_cycle_unreadable", map[string]any{"value1": h.HostID, "value2": cf.Identity, "value3": err.Error()}))
	}
}

// replayIncidents writes the per-host incidents the collector would have raised
// before it first saw the host. From that moment on the collector raised them
// itself, so an incident is written only when it was over by then, and only once.
// The fails come from Loki's transition lines and from the outcomes of the cycles
// this job wrote, which Loki may not answer for yet.
func (b *backfiller) replayIncidents(ctx context.Context, h activeHost, hs *backfillHostState, from, now time.Time, outcomes map[string]cycleOutcome) (int, error) {
	boundary, err := b.firstPresence(ctx, h.HostID, from, now)
	if err != nil || !boundary.After(from) {
		return 0, err
	}
	entries, err := b.lokiRange(ctx, fmt.Sprintf(`{src="cycle",hostId=%q} | json | overallStatus="fail"`, h.HostID), from, boundary)
	if err != nil {
		return 0, err
	}
	fails := mergeFails(failsFromTransitions(entries), outcomes, boundary)
	events := replayHostIncidents(h.HostID, h.Pool, fails, b.cfg.incidentN, b.cfg.incidentWin)
	if len(events) == 0 {
		return 0, nil
	}
	have, err := b.lokiIncidentIDs(ctx, h.HostID, from, now)
	if err != nil {
		return 0, err
	}
	n := 0
	// replayHostIncidents emits each incident as its open line followed by its
	// resolve line.
	for i := 0; i+1 < len(events); i += 2 {
		open, resolved := events[i], events[i+1]
		if !open.open || resolved.open || open.id != resolved.id || resolved.now.After(boundary) || have[open.id] || hs.Incidents[open.id] {
			continue
		}
		for _, ev := range []incidentEvent{open, resolved} {
			if err := b.pushLoki(ctx, incidentPayload(ev)); err != nil {
				return n, err
			}
		}
		hs.Incidents[open.id] = true
		n++
	}
	return n, nil
}

// fillTimeline writes yuruna_pool_host_status samples where the host's series has
// none: the stretches before the collector first scraped the host, and any time
// the collector was down. A stretch the live series covers is never touched. The
// cycles come from Loki's transition lines and from the outcomes of the cycles
// this job wrote, which Loki may not answer for yet.
func (b *backfiller) fillTimeline(ctx context.Context, h activeHost, from, now time.Time, outcomes map[string]cycleOutcome) (int, error) {
	end := now.Add(-b.cfg.settle)
	if !end.After(from) {
		return 0, nil
	}
	covered, err := b.promCoverage(ctx, h.HostID, from, end)
	if err != nil {
		return 0, err
	}
	uncovered := uncoveredSteps(from, end, covered)
	if len(uncovered) == 0 {
		return 0, nil
	}
	// A cycle that started before the first uncovered stretch can still be the
	// one running in it, so the read reaches back past it.
	readFrom := time.Unix(uncovered[0], 0).UTC().Add(-coverageStep - 24*time.Hour)
	if readFrom.Before(from) {
		readFrom = from
	}
	entries, err := b.lokiRange(ctx, fmt.Sprintf(`{src="cycle",hostId=%q} | json | overallStatus=~"pass|fail|skipped"`, h.HostID), readFrom, now)
	if err != nil {
		return 0, err
	}
	cycles := mergeTimelineHistory(mergeTimeline(timelineFromTransitions(entries), outcomes), h.History, now)
	if h.CurrentStatus == "running" && !h.CurrentStart.IsZero() {
		// The cycle under way has no final line yet. It has been running since its
		// start, which matters when that start is earlier than the first live sample.
		cycles = append(cycles, timelineCycle{Key: formatUTC(h.CurrentStart), Start: h.CurrentStart, End: now, Code: 1})
		sort.Slice(cycles, func(i, j int) bool { return cycles[i].Start.Before(cycles[j].Start) })
	}
	samples := timelineSamples(cycles, uncovered, b.cfg.sampleStep, maxFinalHold)
	if len(samples) == 0 {
		return 0, nil
	}
	if err := b.remoteWrite(ctx, hostStatusLabels(h.Pool, h.HostID), samples); err != nil {
		log.Print(operatorMessage("aggregator.backfill_prometheus_failed", map[string]any{"value1": h.HostID, "value2": err.Error()}))
		return 0, err
	}
	return len(samples), nil
}
