// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"pool-control-service/internal/config"
	"pool-control-service/internal/hostctl"
	"pool-control-service/internal/state"
)

// Pool-wide host control: one selector drives every member of a pool the way
// the operator would drive one host from its own status page.
//
// The pool's desiredState in the intent store is a DIFFERENT mechanism and is
// deliberately not what this touches: that one is durable, reconciled at a
// cycle boundary from git, and `drain` ends the runner process. This acts on
// the live pause switches instead, which is what "pause the lab now, then let
// it carry on" means to an operator watching a cycle.
//
// Membership comes from the intent store and the addresses from the aggregator,
// for the same reason the board joins them that way: the aggregator's notion of
// a pool is a label a host self-advertises, so it cannot say who BELONGS.

// hostControlConcurrency bounds the fan-out. A pool is tens of hosts at most,
// and every call here is one short request, so this exists to keep a large pool
// from opening one socket per member at once rather than to pace anything.
const hostControlConcurrency = 8

// One budget for a whole fan-out, not per host: a lab where half the members
// are powered off must not hold the page (or the operator) for the sum of their
// timeouts. Whatever is still outstanding when the budget runs out is reported
// as a host that did not answer, which is what it is.
const (
	hostReadBudget  = 6 * time.Second
	hostApplyBudget = 30 * time.Second
)

// hostControlRow is one member's outcome, whether the call was a read or a
// write. Hosts are reported individually because they fail individually: a
// member that was never enrolled must not make the other nine look unset.
type hostControlRow struct {
	HostID string `json:"hostId"`
	State  string `json:"state,omitempty"`
	OK     bool   `json:"ok"`
	Error  string `json:"error,omitempty"`
}

// poolControlView is one pool's members and the single state they add up to.
type poolControlView struct {
	State string           `json:"state"`
	Hosts []hostControlRow `json:"hosts"`
}

// aggregate collapses member states into what the pool's selector shows.
//
// A pool speaks with one voice only when every member answered and every answer
// agreed. A silent member makes it "mixed", never the state the others are in:
// the selector's whole job is to say what the pool is doing, and a host nobody
// reached is not evidence of anything.
func aggregate(rows []hostControlRow) string {
	known, state := 0, ""
	for _, row := range rows {
		if !row.OK {
			continue
		}
		known++
		switch {
		case state == "":
			state = row.State
		case state != row.State:
			return hostctl.StateMixed
		}
	}
	switch {
	case known == 0:
		return hostctl.StateUnknown
	case known < len(rows):
		return hostctl.StateMixed
	}
	return state
}

// memberAddresses resolves every member of the named pools to the address the
// aggregator last saw it on. A member with no entry maps to "", which each call
// site reports as its own per-host failure rather than dropping the row --
// a member the pool cannot locate is exactly what an operator needs to see.
func (s *Server) memberAddresses(ctx context.Context, members []string) (map[string]string, string) {
	status, err := s.pool.Status(ctx)
	statusErr := ""
	if err != nil {
		statusErr = err.Error()
	}
	known := map[string]string{}
	for _, h := range status.Hosts {
		known[h.HostID] = h.BaseURL
	}
	addr := make(map[string]string, len(members))
	for _, m := range members {
		addr[m] = known[m]
	}
	return addr, statusErr
}

// eachMember runs work over members with bounded concurrency and returns the
// rows in members order, so a page's host list does not reshuffle between
// loads for no reason.
func eachMember(members []string, work func(hostID string) hostControlRow) []hostControlRow {
	rows := make([]hostControlRow, len(members))
	sem := make(chan struct{}, hostControlConcurrency)
	var wg sync.WaitGroup
	for i, hostID := range members {
		wg.Add(1)
		go func(i int, hostID string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			rows[i] = work(hostID)
		}(i, hostID)
	}
	wg.Wait()
	return rows
}

// handleHostControlState reports, per pool, what its members are currently
// doing. Open like every other read: it exposes no more than each host's own
// status page already serves to the LAN.
func (s *Server) handleHostControlState(w http.ResponseWriter, r *http.Request) {
	doc, err := s.readIntentDoc(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var all []string
	for _, p := range doc.Pools {
		all = append(all, p.Members...)
	}
	addr, statusErr := s.memberAddresses(r.Context(), all)
	ctx, cancel := context.WithTimeout(r.Context(), hostReadBudget)
	defer cancel()

	byHost := map[string]hostControlRow{}
	for _, row := range eachMember(all, func(hostID string) hostControlRow {
		st, err := s.hostctl.State(ctx, addr[hostID])
		if err != nil {
			return hostControlRow{HostID: hostID, State: hostctl.StateUnknown, Error: err.Error()}
		}
		return hostControlRow{HostID: hostID, State: st, OK: true}
	}) {
		byHost[row.HostID] = row
	}

	pools := map[string]poolControlView{}
	for _, p := range doc.Pools {
		rows := make([]hostControlRow, 0, len(p.Members))
		for _, m := range p.Members {
			rows = append(rows, byHost[m])
		}
		pools[p.PoolID] = poolControlView{State: aggregate(rows), Hosts: rows}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "pools": pools, "statusError": statusErr})
}

// handleHostControlApply drives every member of one pool into one state.
//
// The response is 200 with per-host rows even when hosts refused: the fan-out
// itself ran, and "3 of 4 hosts paused, this one is not enrolled" is the answer
// the operator needs. Only a failure to fan out AT ALL -- unreadable intent, an
// unknown pool, no way to prove control -- is an error status.
func (s *Server) handleHostControlApply(w http.ResponseWriter, r *http.Request) {
	var body struct{ PoolID, Action string }
	if !decode(w, r, &body) {
		return
	}
	if body.PoolID == "" || body.Action == "" {
		writeErr(w, http.StatusBadRequest, "poolId and action are required")
		return
	}
	if !hostctl.KnownAction(body.Action) {
		writeErr(w, http.StatusBadRequest, "action must be one of continue, pause-after-cycle, pause-after-step")
		return
	}
	doc, err := s.readIntentDoc(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	members, found := membersOf(doc, body.PoolID)
	if !found {
		writeErr(w, http.StatusNotFound, "pool '"+body.PoolID+"' not found")
		return
	}
	if len(members) == 0 {
		s.recordHostControl(body.PoolID, body.Action, 0, 0)
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "poolId": body.PoolID, "action": body.Action,
			"applied": 0, "failed": 0, "hosts": []hostControlRow{},
		})
		return
	}
	addr, statusErr := s.memberAddresses(r.Context(), members)
	ctx, cancel := context.WithTimeout(r.Context(), hostApplyBudget)
	defer cancel()

	// One proof for the whole fan-out: it is pool-wide by construction (an HMAC
	// over the shared token, with no host in the signed message), so minting per
	// host would buy nothing and, on the aggregator path, cost a round trip per
	// member.
	proof, perr := s.controlProof(ctx, members, addr)
	if perr != nil {
		writeErr(w, http.StatusServiceUnavailable, perr.Error())
		return
	}

	rows := eachMember(members, func(hostID string) hostControlRow {
		if err := s.hostctl.Apply(ctx, addr[hostID], body.Action, proof); err != nil {
			return hostControlRow{HostID: hostID, Error: err.Error()}
		}
		return hostControlRow{HostID: hostID, State: body.Action, OK: true}
	})
	applied, failed := 0, 0
	for _, row := range rows {
		if row.OK {
			applied++
		} else {
			failed++
		}
	}
	s.recordHostControl(body.PoolID, body.Action, applied, failed)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "poolId": body.PoolID, "action": body.Action,
		"applied": applied, "failed": failed, "hosts": rows, "statusError": statusErr,
	})
}

// controlProof obtains the proof this fan-out presents to each host.
//
// Two sources, in order. The lab-auth-token this service already holds needs no
// round trip -- but it is opt-in on a service VM (nothing bakes that file into
// the seed), so without it the aggregator is asked for one through /go/host:
// the identical proof a browser gets by following a dashboard host link. That
// fallback is what lets pool-wide control work on a lab that never placed the
// token file by hand.
func (s *Server) controlProof(ctx context.Context, members []string, addr map[string]string) (string, error) {
	if proof := hostctl.Mint(s.opts.AuthToken, hostctl.ProofTTL); proof != "" {
		return proof, nil
	}
	base := s.pool.BaseURL()
	if base == "" {
		return "", fmt.Errorf("no control proof: this service holds no lab auth token (%s) and has no pool aggregator to ask for one", s.authTokenFile())
	}
	// Only the aggregator's own token signs the proof, so any host it can
	// resolve yields the same one; asking about a member it has never seen just
	// gets a 404, hence trying the ones with a known address first. A couple of
	// tries covers a member that has since gone away -- an aggregator that will
	// not mint for two hosts will not mint for the twentieth either, and an
	// operator should not wait out one round trip per member to be told so.
	var lastErr error
	for i, hostID := range orderByReachable(members, addr) {
		if i >= proofAttemptLimit {
			break
		}
		proof, err := s.hostctl.ProofFromAggregator(ctx, base, hostID)
		if err == nil {
			return proof, nil
		}
		lastErr = err
	}
	return "", fmt.Errorf("no control proof: this service holds no lab auth token (%s) and the pool aggregator would not mint one (%v)", s.authTokenFile(), lastErr)
}

// proofAttemptLimit caps how many members are asked about before the aggregator
// is taken at its word.
const proofAttemptLimit = 3

// authTokenFile names the file an operator drops the shared token into: the one
// this daemon was launched with, falling back to the documented default when it
// was launched without the flag at all.
func (s *Server) authTokenFile() string {
	if f := strings.TrimSpace(s.opts.AuthTokenFile); f != "" {
		return f
	}
	return config.DefaultAuthTokenFile
}

// orderByReachable puts the members the pool has an address for first.
func orderByReachable(members []string, addr map[string]string) []string {
	out := make([]string, 0, len(members))
	for _, m := range members {
		if strings.TrimSpace(addr[m]) != "" {
			out = append(out, m)
		}
	}
	for _, m := range members {
		if strings.TrimSpace(addr[m]) == "" {
			out = append(out, m)
		}
	}
	return out
}

// recordHostControl audits one fan-out. Every other mutation is audited through
// relay(); this one does not go through the intent CLIs, so it records its own.
func (s *Server) recordHostControl(poolID, action string, applied, failed int) {
	if s.state == nil {
		return
	}
	s.state.Record(time.Now(), state.AuditEntry{
		TimeUTC: time.Now().UTC().Format(time.RFC3339),
		Action:  "host-control", Target: poolID, OK: failed == 0,
		Detail: fmt.Sprintf("%s: %d applied, %d failed", action, applied, failed),
	})
}

// membersOf returns a pool's members and whether the pool exists at all. The
// two are distinct answers: an empty pool accepts the call and changes nothing,
// an unknown pool is a bad request.
func membersOf(doc intentDoc, poolID string) ([]string, bool) {
	for _, p := range doc.Pools {
		if p.PoolID == poolID {
			return p.Members, true
		}
	}
	return nil, false
}

// readIntentDoc runs the intent read and decodes it, with the messages every
// caller here surfaces verbatim.
func (s *Server) readIntentDoc(ctx context.Context) (intentDoc, error) {
	var doc intentDoc
	res := s.intent.State(ctx)
	if !res.OK {
		return doc, fmt.Errorf("%s", firstNonEmpty(res.Error, res.Stderr, "pool intent read failed"))
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(res.Stdout)), &doc); err != nil {
		return doc, fmt.Errorf("could not parse pool intent: %s", err.Error())
	}
	return doc, nil
}
