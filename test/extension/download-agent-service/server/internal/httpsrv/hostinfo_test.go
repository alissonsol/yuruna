// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
)

const testHostID = "42512149deadbeef"

// TestHostInfo covers the chrome's host-facts endpoint: ok=true, the local
// hostId, the daemon version, and a serverIps STRING (newline-separated lines,
// possibly empty in a sandboxed CI with no non-loopback interface — the contract
// is the shape, not a specific address).
func TestHostInfo(t *testing.T) {
	srv, _ := newServer(t, Options{HostID: testHostID})

	resp := get(t, srv, "/api/hostinfo")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("hostinfo: status %d", resp.StatusCode)
	}
	var info struct {
		OK          bool   `json:"ok"`
		LocalHostID string `json:"localHostId"`
		Version     string `json:"version"`
		ServerIps   string `json:"serverIps"`
	}
	b, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(b, &info); err != nil {
		t.Fatalf("hostinfo: %v (body %s)", err, b)
	}
	if !info.OK || info.LocalHostID != testHostID || info.Version != "2026.08.05" {
		t.Fatalf("hostinfo should carry the host id and version; got %+v", info)
	}
	// Every reported line must be a comma-list of parseable IPs (no stray
	// whitespace, no link-local/loopback leaking through).
	if info.ServerIps != "" {
		for _, line := range strings.Split(info.ServerIps, "\n") {
			for _, addr := range strings.Split(line, ",") {
				ip := net.ParseIP(addr)
				if ip == nil {
					t.Fatalf("serverIps has non-IP token %q in %q", addr, info.ServerIps)
				}
				if ip.IsLoopback() || ip.IsLinkLocalUnicast() {
					t.Fatalf("serverIps leaked loopback/link-local %q", addr)
				}
			}
		}
	}
}

// TestPageServesChrome verifies the page carries the shared header and footer
// markup and that the module driving it ships in common.js — i.e. the chrome is
// wired end-to-end, not just defined.
func TestPageServesChrome(t *testing.T) {
	srv, _ := newServer(t, Options{})

	page := readBody(t, get(t, srv, "/"))
	for _, want := range []string{
		`id="header-version"`, `id="machine"`, `Yuruna Download Agent`,
		`id="footer-bar"`, `id="footer-ip-list"`, `id="last-loaded"`, `id="countdown"`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("page is missing chrome element %q", want)
		}
	}

	// The chrome only runs if the page's scripts actually load. A page that
	// references an asset the binary does not embed renders as a dead skeleton,
	// which no markup assertion above would catch.
	for _, asset := range []string{"/assets/common.js", "/assets/sort.js", "/assets/images.js", "/assets/style.css"} {
		if !strings.Contains(page, asset) {
			t.Errorf("page no longer references %s", asset)
			continue
		}
		if resp := get(t, srv, asset); resp.StatusCode != http.StatusOK {
			t.Errorf("page references %s, which is not served (status %d)", asset, resp.StatusCode)
		}
	}

	js := readBody(t, get(t, srv, "/assets/common.js"))
	if !strings.Contains(js, "initChrome") {
		t.Fatalf("common.js missing initChrome module")
	}
}

func readBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}
