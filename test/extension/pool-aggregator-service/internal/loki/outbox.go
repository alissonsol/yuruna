// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 4201612f-10df-484f-ad26-85dc536a8c4d

package loki

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ErrFull is Enqueue's answer while the outbox holds its limit. A caller that
// can build the same line again (a cycle transition, an event file tail) keeps
// its own record unadvanced and tries again on its next pass.
var ErrFull = errors.New("loki outbox is full")

// Outbox limits. A day of a busy pool's lines fits well inside them; past them
// Loki has been away long enough that refusing new lines, rather than growing
// without bound on the proxy VM, is the right failure.
const (
	DefaultMaxItems       = 20000
	DefaultMaxBytes       = 256 << 20
	defaultMemoryMaxBytes = 64 << 20
)

// Outbox holds push payloads until Loki has accepted them and sends them, in
// the order they were queued, from one worker. With a directory each payload is
// a file there, synced before Enqueue returns, so a line the collector queued
// survives the collector's own restart; with none the queue lives in memory and
// survives only a Loki outage.
type Outbox struct {
	dir  string
	push func(context.Context, []byte) error
	logf func(event string, args map[string]any)

	maxItems int
	maxBytes int64
	// first and ceiling bound the retry backoff after a failed send.
	first, ceiling time.Duration

	mu         sync.Mutex
	items      []outboxItem // oldest first
	bytes      int64
	seq        uint64
	fullLogged bool
	wake       chan struct{}
}

type outboxItem struct {
	seq  uint64
	size int64
	data []byte // memory mode only; a directory item is read back when sent
}

// NewOutbox opens the outbox in dir, picking up what a previous run left there,
// or in memory when dir is empty or cannot be used (logged as "outbox_memory_only").
// push sends one payload and returns nil once Loki has accepted it; logf
// receives the outbox's events: outbox_memory_only, outbox_full,
// outbox_refused and outbox_unreadable.
func NewOutbox(dir string, push func(context.Context, []byte) error, logf func(event string, args map[string]any)) *Outbox {
	o := &Outbox{
		push: push, logf: logf,
		maxItems: DefaultMaxItems, maxBytes: defaultMemoryMaxBytes,
		first: time.Second, ceiling: time.Minute,
		wake: make(chan struct{}, 1),
	}
	if dir == "" {
		return o
	}
	if err := o.load(dir); err != nil {
		o.logf("outbox_memory_only", map[string]any{"dir": dir, "reason": err.Error()})
		o.items, o.bytes, o.seq = nil, 0, 0
		return o
	}
	o.dir, o.maxBytes = dir, DefaultMaxBytes
	return o
}

// load takes over the payloads a previous run queued in dir, oldest first, and
// discards temp files a crash left behind mid-write.
func (o *Outbox) load(dir string) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".tmp-") {
			_ = os.Remove(filepath.Join(dir, name))
			continue
		}
		seq, err := strconv.ParseUint(strings.TrimSuffix(name, ".json"), 10, 64)
		if err != nil || !strings.HasSuffix(name, ".json") || !e.Type().IsRegular() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		o.items = append(o.items, outboxItem{seq: seq, size: info.Size()})
		o.bytes += info.Size()
		if seq >= o.seq {
			o.seq = seq + 1
		}
	}
	sort.Slice(o.items, func(i, j int) bool { return o.items[i].seq < o.items[j].seq })
	// A probe write: a directory that lists but refuses a file would otherwise
	// fail every Enqueue instead of falling back to memory once, here.
	probe, err := os.CreateTemp(dir, ".tmp-probe-*")
	if err != nil {
		return err
	}
	probe.Close()
	return os.Remove(probe.Name())
}

// Durable reports whether queued payloads survive a restart.
func (o *Outbox) Durable() bool { return o.dir != "" }

// Pending is how many payloads wait for Loki.
func (o *Outbox) Pending() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return len(o.items)
}

// Enqueue queues one payload. It returns once the payload is held -- synced to
// disk in a durable outbox -- or ErrFull, or the write error.
func (o *Outbox) Enqueue(payload []byte) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	size := int64(len(payload))
	if len(o.items) >= o.maxItems || o.bytes+size > o.maxBytes {
		if !o.fullLogged {
			o.fullLogged = true
			o.logf("outbox_full", map[string]any{"lines": len(o.items)})
		}
		return ErrFull
	}
	it := outboxItem{seq: o.seq, size: size}
	if o.dir == "" {
		it.data = append([]byte(nil), payload...)
	} else if err := writeSynced(o.dir, it.seq, payload); err != nil {
		return err
	}
	o.seq++
	o.items = append(o.items, it)
	o.bytes += size
	select {
	case o.wake <- struct{}{}:
	default:
	}
	return nil
}

// writeSynced lands one payload under its sequence name through a synced temp
// file and a rename, then syncs the directory so the rename itself survives.
func writeSynced(dir string, seq uint64, payload []byte) error {
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(payload); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, filepath.Join(dir, itemName(seq))); err != nil {
		os.Remove(name)
		return err
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
}

func itemName(seq uint64) string { return fmt.Sprintf("%020d.json", seq) }

// Run sends queued payloads until ctx ends: the oldest first, the next only once
// Loki has taken it, waiting out a failed send with a backoff that doubles from
// first to ceiling. A payload Loki refuses outright is dropped (logged as
// "outbox_refused"), since sending the same bytes again cannot succeed.
func (o *Outbox) Run(ctx context.Context) {
	delay := o.first
	for ctx.Err() == nil {
		sent, err := o.sendOldest(ctx)
		switch {
		case err != nil:
			select {
			case <-ctx.Done():
				return
			case <-time.After(delay):
			}
			delay *= 2
			if delay > o.ceiling {
				delay = o.ceiling
			}
		case sent:
			delay = o.first
		default:
			select {
			case <-ctx.Done():
				return
			case <-o.wake:
			}
		}
	}
}

// Flush sends queued payloads until the outbox is empty, a send fails, or ctx
// ends, and reports whether it emptied. The collector runs it before reading
// Loki back at startup, so lines queued before a restart are there to be read.
// It must not run while Run does: each would send the same oldest payload.
func (o *Outbox) Flush(ctx context.Context) bool {
	for ctx.Err() == nil {
		sent, err := o.sendOldest(ctx)
		if err != nil {
			return false
		}
		if !sent {
			return true
		}
	}
	return false
}

// sendOldest sends the oldest payload and reports whether one left the queue,
// or the error of a send Loki may still accept later.
func (o *Outbox) sendOldest(ctx context.Context) (bool, error) {
	o.mu.Lock()
	if len(o.items) == 0 {
		o.mu.Unlock()
		return false, nil
	}
	it := o.items[0]
	o.mu.Unlock()
	data := it.data
	if o.dir != "" {
		var err error
		if data, err = os.ReadFile(filepath.Join(o.dir, itemName(it.seq))); err != nil {
			o.logf("outbox_unreadable", map[string]any{"name": itemName(it.seq), "reason": err.Error()})
			o.remove(it)
			return true, nil
		}
	}
	if err := o.push(ctx, data); err != nil {
		if !Permanent(err) {
			return false, err
		}
		o.logf("outbox_refused", map[string]any{"reason": err.Error()})
	}
	o.remove(it)
	return true, nil
}

func (o *Outbox) remove(it outboxItem) {
	o.mu.Lock()
	if len(o.items) > 0 && o.items[0].seq == it.seq {
		o.items = o.items[1:]
		o.bytes -= it.size
		o.fullLogged = false
	}
	o.mu.Unlock()
	if o.dir != "" {
		_ = os.Remove(filepath.Join(o.dir, itemName(it.seq)))
	}
}
