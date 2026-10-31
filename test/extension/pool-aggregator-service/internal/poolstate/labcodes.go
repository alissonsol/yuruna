// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 426b8f0c-19db-4532-9418-8f961491ee3c

package poolstate

import (
	"crypto/subtle"
	"time"
)

// labCodes is the lab connection token (dashboard enrollment code) state the
// rotation goroutine and the exchange route share.
type labCodes struct {
	codes    []string               // newest first: the current code, then the predecessors still accepted
	fails    map[string][]time.Time // throttle bucket -> recent failed exchange attempts
	outcomes map[string]int64       // exchange outcome ("ok"/"refused"/"throttled") -> count
}

func newLabCodes() labCodes {
	return labCodes{fails: map[string][]time.Time{}, outcomes: map[string]int64{}}
}

// RotateLabCode makes code the current lab connection code, keeps at most keep
// codes (newest first) for the exchange's grace window, and drops the failed
// attempts at or before cut.
func (v *View) RotateLabCode(code string, keep int, cut time.Time) {
	v.lab.codes = append([]string{code}, v.lab.codes...)
	if len(v.lab.codes) > keep {
		v.lab.codes = v.lab.codes[:keep]
	}
	v.pruneLabFailures(cut)
}

// LabCodes returns the accepted codes, newest first.
func (v *View) LabCodes() []string { return append([]string(nil), v.lab.codes...) }

// LabAttempt is the verdict on one redemption of a lab connection code.
type LabAttempt struct {
	Recent    int    // the bucket's failed attempts after cut, before this one
	Throttled bool   // Recent reached the limit, so the code was not compared
	Matched   bool   // the code is one of the accepted codes
	Outcome   string // "ok", "refused" or "throttled", as counted
}

// RedeemLabCode judges one redemption of code from throttle bucket key at now.
// A bucket with limit or more failed attempts after cut is throttled and its
// code is not compared. A code that matches none of the accepted codes is
// recorded against its bucket, unless the buckets already number maxBuckets
// after the expired ones are pruned: a full map then refuses new buckets
// rather than growing, and a correct code still redeems. The outcome is
// counted.
func (v *View) RedeemLabCode(key, code string, now, cut time.Time, limit, maxBuckets int) LabAttempt {
	var a LabAttempt
	for _, t := range v.lab.fails[key] {
		if t.After(cut) {
			a.Recent++
		}
	}
	a.Throttled = a.Recent >= limit
	if !a.Throttled {
		// No early break: every retained code is compared so the timing does
		// not reveal WHICH slot (if any) matched.
		for _, c := range v.lab.codes {
			if subtle.ConstantTimeCompare([]byte(code), []byte(c)) == 1 {
				a.Matched = true
			}
		}
		if !a.Matched {
			if len(v.lab.fails) >= maxBuckets {
				v.pruneLabFailures(cut)
			}
			if _, known := v.lab.fails[key]; known || len(v.lab.fails) < maxBuckets {
				v.lab.fails[key] = append(v.lab.fails[key], now)
			}
		}
	}
	a.Outcome = "ok"
	if a.Throttled {
		a.Outcome = "throttled"
	} else if !a.Matched {
		a.Outcome = "refused"
	}
	v.lab.outcomes[a.Outcome]++
	return a
}

// LabExchangeCount is how many exchanges ended with outcome.
func (v *View) LabExchangeCount(outcome string) int64 { return v.lab.outcomes[outcome] }

// LabFailures returns the failed attempts recorded against one throttle
// bucket, or nil when it holds none.
func (v *View) LabFailures(key string) []time.Time {
	if times, ok := v.lab.fails[key]; ok {
		return append([]time.Time(nil), times...)
	}
	return nil
}

// LabFailureBuckets is how many throttle buckets hold failed attempts.
func (v *View) LabFailureBuckets() int { return len(v.lab.fails) }

// pruneLabFailures drops the failed attempts at or before cut, and a bucket
// left with none.
func (v *View) pruneLabFailures(cut time.Time) {
	for key, times := range v.lab.fails {
		kept := times[:0]
		for _, t := range times {
			if t.After(cut) {
				kept = append(kept, t)
			}
		}
		if len(kept) == 0 {
			delete(v.lab.fails, key)
		} else {
			v.lab.fails[key] = kept
		}
	}
}
