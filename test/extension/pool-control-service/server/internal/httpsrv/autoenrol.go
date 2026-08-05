// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"time"

	"pool-control-service/internal/yex/pool"
)

// The auto-enrolment sweep: a host that has enrolled its lab token, and is in no
// pool at all, joins the target pool automatically.
//
// SHIPPED OFF (--auto-enrol). Turn it on once the pieces it depends on are
// observed working.
//
// --- REGION: https://yuruna.link/pool-admin#auto-enrolment
//
// Two invariants the `inAPool || excluded` skip below encodes: a host already
// in a pool is never touched, which keeps "a host belongs to at most one pool"
// true by construction; and a host an operator removed from the target pool is
// never re-added, or the operator and a 60-second timer would fight forever.

// AutoEnrolOptions configures the sweep.
type AutoEnrolOptions struct {
	Enabled  bool
	Interval time.Duration
}

// RunAutoEnrolment sweeps until ctx is done. Safe to call when disabled: it
// returns immediately.
//
// Runs on its OWN ticker, started unconditionally by the caller, rather than
// riding the monitor goroutine -- that one is gated on --state-dir and simply
// does not run on the host-side launcher, which would make the sweep silently
// absent there.
func (s *Server) RunAutoEnrolment(ctx context.Context, opts AutoEnrolOptions) {
	if !opts.Enabled || opts.Interval <= 0 {
		return
	}
	tick := time.NewTicker(opts.Interval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			s.sweepOnce(ctx)
		}
	}
}

// sweepOnce performs one pass. Never panics out; every failure is a logged
// no-op so a transient aggregator outage cannot corrupt intent.
func (s *Server) sweepOnce(ctx context.Context) {
	if !s.pool.Configured() {
		return
	}
	status, err := s.pool.Status(ctx)
	if err != nil {
		log.Printf("auto-enrolment: aggregator unreachable (%v); skipping this tick", err)
		return
	}

	res := s.intent.State(ctx)
	if !res.OK {
		log.Printf("auto-enrolment: intent unreadable (%s); skipping this tick", firstNonEmpty(res.Error, res.Stderr, "unknown"))
		return
	}
	var doc intentDoc
	if err := json.Unmarshal([]byte(strings.TrimSpace(res.Stdout)), &doc); err != nil {
		log.Printf("auto-enrolment: could not parse intent (%v); skipping this tick", err)
		return
	}
	target := strings.TrimSpace(doc.AutoEnrollment.TargetPoolID)
	if !doc.AutoEnrollment.Enabled || target == "" {
		// The LAN has not opted in. Nothing to say every 60 seconds.
		return
	}

	inAPool := map[string]bool{}
	targetExists := false
	for _, p := range doc.Pools {
		if p.PoolID == target {
			targetExists = true
		}
		for _, m := range p.Members {
			inAPool[m] = true
		}
	}
	excluded := map[string]bool{}
	for _, h := range doc.AutoEnrollment.Excluded {
		excluded[h] = true
	}

	candidates := 0
	var toAdd []string
	for _, h := range status.Hosts {
		// The WIRE value. `ready` means the host holds the same lab-auth-token
		// the proxy mints proofs from AND its clock agrees; `none`, `mismatch`,
		// `skew`, `unknown` and an absent field (omitempty, which is what a
		// token-less proxy produces for every host) are all non-candidates, so a
		// proxy with no token makes this a no-op. Fail-closed, which is wanted.
		if h.Control != pool.ControlReady {
			continue
		}
		candidates++
		if inAPool[h.HostID] || excluded[h.HostID] {
			continue
		}
		toAdd = append(toAdd, h.HostID)
	}

	if len(toAdd) == 0 {
		// Logged even when empty: this line is how "the predicate is broken" is
		// told apart from "everything is already enrolled".
		log.Printf("auto-enrolment: %d ready host(s), 0 to add", candidates)
		return
	}

	if !targetExists {
		r := s.intent.NewPool(ctx, target, "", "")
		if !r.OK {
			log.Printf("auto-enrolment: could not create target pool %q (%s); skipping", target, firstNonEmpty(r.Error, r.Stderr, "unknown"))
			return
		}
		log.Printf("auto-enrolment: created target pool %q", target)
	}

	added := 0
	for _, hid := range toAdd {
		r := s.intent.AddHost(ctx, target, hid)
		if !r.OK {
			// Bounded, not atomic: stop here and let the next tick resume.
			// Enrolment is idempotent, so the hosts already added stay added.
			log.Printf("auto-enrolment: adding %s to %q failed (%s); %d added this tick, retrying next tick",
				hid, target, firstNonEmpty(r.Error, r.Stderr, "unknown"), added)
			return
		}
		added++
	}
	log.Printf("auto-enrolment: %d ready host(s), added %d to %q", candidates, added, target)
}
