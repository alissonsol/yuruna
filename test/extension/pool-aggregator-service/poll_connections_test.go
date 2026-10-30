// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42470739-88d4-4eda-97c3-f110aacce2fa

package main

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"sync"
	"testing"
	"time"
)

// A poll asks each host several questions in a row. They share one connection
// for the poll, and the poll closes it when it ends, so nothing pooled lives on
// into the next poll.
func TestAPollReusesOneConnectionPerHostAndClosesIt(t *testing.T) {
	const hid = "42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	now := time.Now().UTC()
	var mu sync.Mutex
	opened, closed, requests := 0, 0, 0
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		requests++
		mu.Unlock()
		switch r.URL.Path {
		case "/runtime/status.json":
			fmt.Fprintf(w, `{"hostId":%q,"host":"host.ubuntu.kvm","overallStatus":"pass"}`, hid)
		case "/control/control-status":
			fmt.Fprintf(w, `{"ok":true,"tokenConfigured":false,"tokenTag":"","utcNow":%q}`, now.Format(time.RFC3339))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	srv.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		mu.Lock()
		defer mu.Unlock()
		switch state {
		case http.StateNew:
			opened++
		case http.StateClosed, http.StateHijacked:
			closed++
		}
	}
	srv.Start()
	defer srv.Close()
	u, _ := url.Parse(srv.URL)
	port, _ := strconv.Atoi(u.Port())
	s := newPoolState("default", port)
	s.hosts[hid] = &hostView{HostId: hid, CurrentIP: u.Hostname(), LastSeenUnixMs: now.UnixMilli()}

	s.pollWithFreshConnections("no-such-squid.log", "", now)

	mu.Lock()
	gotOpened, gotRequests := opened, requests
	mu.Unlock()
	if gotRequests < 4 || gotOpened != 1 {
		t.Fatalf("one poll made %d request(s) over %d connection(s); want them on one", gotRequests, gotOpened)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		mu.Lock()
		done := closed == opened
		mu.Unlock()
		if done {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the poll's connection was still open after the poll ended")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
