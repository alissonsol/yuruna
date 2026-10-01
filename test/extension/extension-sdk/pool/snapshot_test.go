// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.

package pool

import (
	"sync"
	"testing"
	"time"
)

func TestSnapshotOwnership(t *testing.T) {
	c := &Client{cacheTTL: time.Minute}
	s := Status{Hosts: []Host{{HostID: "original", ActiveExtensions: []string{"a"}, PreviousHostIDs: []string{"old"}, ExtensionTargets: map[string]string{"a": "url"}, Status: &HostStatus{Host: "kvm"}}}}
	c.cacheStatus(s)
	s.Hosts[0].HostID = "mutated"
	var wg sync.WaitGroup
	for range 20 {
		wg.Go(func() {
			a, _ := c.cachedStatus()
			a.Hosts[0].HostID = "changed"
			a.Hosts[0].ActiveExtensions[0] = "changed"
			a.Hosts[0].PreviousHostIDs[0] = "changed"
			a.Hosts[0].ExtensionTargets["a"] = "changed"
			a.Hosts[0].Status.Host = "changed"
		})
	}
	wg.Wait()
	a, _ := c.cachedStatus()
	h := a.Hosts[0]
	if h.HostID != "original" || h.ActiveExtensions[0] != "a" || h.PreviousHostIDs[0] != "old" || h.ExtensionTargets["a"] != "url" || h.Status.Host != "kvm" {
		t.Fatalf("mutated: %+v", h)
	}
}
func BenchmarkCloneStatus(b *testing.B) {
	s := Status{Hosts: make([]Host, 100)}
	for i := range s.Hosts {
		s.Hosts[i].ExtensionTargets = map[string]string{"stash": "http://localhost"}
	}
	b.ReportAllocs()
	for b.Loop() {
		cloneStatus(s)
	}
}
