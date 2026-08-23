// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"yuruna.com/test/extension/extension-sdk/pool"
)

// The landing page is what port 80 of this VM answers with, and what every
// host status page's "Dashboards" link now points at.
//
// It replaced a redirect straight into a Grafana dashboard. That redirect
// assumed the operator's browser could run Grafana, which is a single-page
// application: a browser that cannot lands on a blank screen with no way back
// and nothing saying why. This page is plain server-rendered HTML -- no script
// at all, so there is no version of it that fails to render -- and it names
// every destination rather than choosing one. An operator on an old tablet can
// at least see what exists and which parts of it are reachable.
//
// A link is present only where the thing behind it is: an absent Grafana
// dashboard and an extension service the pool cannot locate both render as
// plain text. That is the page's whole signal, so it must never link
// optimistically.

// landingDashboard is one Grafana board this page offers. The uid is the join
// key -- Grafana's search API answers with uid and canonical url, so the url is
// taken from the answer rather than built from a slug that can drift.
type landingDashboard struct {
	UID   string
	Title string
	What  string
}

// The three boards an operator opens by name. "Yuruna cache health" is
// deliberately absent: it is a registry-path canary read by the alerting rules,
// not a page anyone browses to, and listing it here would put a fourth entry in
// front of operators that answers a question they did not ask.
var landingDashboards = []landingDashboard{
	{UID: "yuruna-pool", Title: "Yuruna hosts", What: "Hosts and test execution progress"},
	{UID: "yuruna-squid", Title: "Yuruna caching-proxy service", What: "Caching proxy statistics"},
	{UID: "yuruna-zot-official", Title: "Zot (official, Grafana ID 20501)", What: "Community Zot statistics"},
}

// landingService is one extension service row. Area is the directory name under
// test/extension/, which is what the aggregator keys its registry by.
type landingService struct {
	Area  string
	Title string
	What  string
}

// Every extension service, listed whether or not the pool can locate one --
// an operator looking for the stash service needs to be told it is missing,
// which an omitted row does not do. Ordered as an operator reads them:
// alphabetically by title, which is also roughly least to most often used.
var landingServices = []landingService{
	{Area: "caching-proxy-service", Title: "Caching-proxy service", What: "Statistics summary"},
	{Area: "download-agent-service", Title: "Download-agent service", What: "Download agent control"},
	{Area: "pool-control-service", Title: "Pool-control service", What: "Assign hosts to pools and pools to test sequences"},
	{Area: "stash-service", Title: "Stash service", What: "Stash inspection and creating"},
}

// grafanaSearch is the shape of one entry in Grafana's /api/search answer. Only
// the two fields this page joins on are read; the rest of the record is
// Grafana's business and changes between releases.
type grafanaSearch struct {
	UID string `json:"uid"`
	URL string `json:"url"`
}

// dashboardURLs asks Grafana which of the boards it knows, and answers uid ->
// path. An unreachable or slow Grafana yields an empty map, which renders every
// dashboard row unlinked -- the honest answer, and the same one a browser would
// have discovered by following a link into nothing.
//
// Anonymous Viewer is enabled on this VM's Grafana, so no credential is needed;
// the read is over loopback and never leaves the machine.
func dashboardURLs(ctx context.Context, grafanaBase string) map[string]string {
	out := map[string]string{}
	if grafanaBase == "" {
		return out
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		strings.TrimRight(grafanaBase, "/")+"/api/search?type=dash-db&limit=200", nil)
	if err != nil {
		return out
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return out
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return out
	}
	var found []grafanaSearch
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&found); err != nil {
		return out
	}
	for _, f := range found {
		if f.UID != "" && f.URL != "" {
			out[f.UID] = f.URL
		}
	}
	return out
}

// aggregatorPort is where the aggregator answers when the configured URL names
// no port of its own. Fixed across the lab, and the value the host port-map set
// forwards.
const aggregatorPort = "9400"

// aggregatorLinkBase is the address the BROWSER should use to reach the
// aggregator, which is deliberately not the one this daemon reads it on.
//
// Plain http, ALWAYS, whatever scheme the daemon was configured with. The
// aggregator answers both schemes on one dual-protocol listener, and its TLS
// leaf is signed by the squid CA -- which this VM trusts and an operator's
// browser does not. An https link therefore puts a certificate warning in front
// of a redirect whose destination is a plain-http page anyway, so the operator
// is asked to accept a risk to reach somewhere TLS never protected. The
// dashboard's Extension hosts cell forces http for exactly this reason.
//
// The HOST comes from the request rather than from the configured URL: that URL
// names this VM's own LAN address, and the operator may have arrived through a
// port map on their own machine. The PORT does come from the configured URL, so
// a lab that moves the aggregator is followed rather than guessed at.
func aggregatorLinkBase(aggregatorURL, browserHost string) string {
	if aggregatorURL == "" || browserHost == "" {
		return ""
	}
	port := aggregatorPort
	if u, err := url.Parse(aggregatorURL); err == nil && u.Host != "" {
		if p := u.Port(); p != "" {
			port = p
		}
	}
	// browserHost keeps the brackets on an IPv6 literal, which is the form an
	// authority needs them in.
	return "http://" + browserHost + ":" + port
}

// serviceLinks asks the pool where each extension area is served and answers
// area -> the aggregator redirect that reaches it.
//
// The link goes through the aggregator's /go/stash rather than straight at the
// service's address, which is what the dashboard's Extension hosts cell does
// and for the same two reasons: the aggregator resolves the service's CURRENT
// address server-side, so the link survives a DHCP change, and it hands the
// browser a short-lived control proof so the service UI opens already unlocked.
//
// linkBase is what the browser will follow; the client reads the pool over
// whatever the daemon was configured with. Those are different addresses on
// purpose -- see aggregatorLinkBase.
//
// An area the pool cannot locate is simply absent from the map, and its row
// renders unlinked.
func serviceLinks(ctx context.Context, client *pool.Client, linkBase string) map[string]string {
	out := map[string]string{}
	if client == nil || !client.Configured() || linkBase == "" {
		return out
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	hosts, err := client.ExtensionHosts(ctx)
	if err != nil {
		return out
	}
	base := strings.TrimRight(linkBase, "/")
	for area, e := range hosts.Areas {
		// Suppressed means the pool knows of an address it has never reached or
		// has stopped reaching, and refuses to resolve through it. That is "not
		// available", so it must not become a link.
		if e.Suppressed || e.HostID == "" || e.Target == "" {
			continue
		}
		out[area] = base + "/go/stash?host=" + url.QueryEscape(e.HostID) + "&area=" + url.QueryEscape(area)
	}
	return out
}

// landingStyle is inline because this VM serves the page to a browser that may
// have no route off the lab network, so an external stylesheet would render a
// broken page on exactly the machine whose job is to make the network
// unnecessary.
//
// It is also held to the browser baseline in docs/definition.md: no flex gap,
// no grid, no logical properties, no custom properties. The whole page is one
// list and two headings, so none of those would buy anything worth the floor.
const landingStyle = `
  body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
         background: #111827; color: #e5e7eb; margin: 0; padding: 16px; }
  h1 { font-size: 18px; margin: 0 0 4px; font-weight: 600; }
  h2 { font-size: 13px; margin: 20px 0 6px; color: #9ca3af; font-weight: 600;
       text-transform: uppercase; letter-spacing: .04em; }
  p.lead { margin: 0 0 4px; color: #9ca3af; }
  ul { list-style: none; margin: 0; padding: 0; max-width: 90ch; }
  li { padding: 8px 0; border-bottom: 1px solid #1f2937; }
  a { color: #93c5fd; }
  a:hover { color: #bfdbfe; }
  /* 44px of touch target without moving the text: the row is the target on a
     phone, and an operator taps this page from one. */
  li a { display: inline-block; min-height: 24px; padding: 6px 0; font-weight: 600; }
  a:focus { outline: 2px solid #93c5fd; outline-offset: 2px; }
  .what { color: #9ca3af; }
  /* An entry with nothing behind it. Not color alone: the word "unavailable"
     is what a grayscale screen and a screen reader both get. */
  .off { color: #9ca3af; font-weight: 600; }
`

// landingRow renders one entry: linked when there is somewhere to go, and named
// plus "(unavailable)" when there is not.
func landingRow(b *strings.Builder, href, title, what string) {
	b.WriteString("    <li>")
	if href == "" {
		fmt.Fprintf(b, `<span class="off">%s</span> <span class="what">&mdash; %s (unavailable)</span>`,
			html.EscapeString(title), html.EscapeString(what))
	} else {
		fmt.Fprintf(b, `<a href="%s">%s</a> <span class="what">&mdash; %s</span>`,
			html.EscapeString(href), html.EscapeString(title), html.EscapeString(what))
	}
	b.WriteString("</li>\n")
}

// renderLanding builds the page. grafanaBase is the origin the BROWSER should
// use for dashboard links, which is not the loopback address the probe used:
// the operator reached this page on some address, and Grafana is behind the
// same one on :3000.
func renderLanding(grafanaBase string, dashboards map[string]string, services map[string]string) string {
	var b strings.Builder
	b.WriteString(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Yuruna</title>
<style>`)
	b.WriteString(landingStyle)
	b.WriteString(`</style>
</head><body>
  <h1>Yuruna</h1>
  <p class="lead">Everything this lab serves, and whether it is reachable right now.</p>

  <h2>Dashboards (may demand a compatible browser)</h2>
  <ul>
`)
	for _, d := range landingDashboards {
		href := ""
		if path, ok := dashboards[d.UID]; ok {
			href = strings.TrimRight(grafanaBase, "/") + path
		}
		landingRow(&b, href, d.Title, d.What)
	}
	b.WriteString(`  </ul>

  <h2>Extension hosts</h2>
  <ul>
`)
	for _, s := range landingServices {
		landingRow(&b, services[s.Area], s.Title, s.What)
	}
	b.WriteString(`  </ul>
</body></html>
`)
	return b.String()
}

// browserHost is the address the operator reached this page on, which is what
// every link has to be built from. The page is served through Apache on :80 of
// this VM, and that VM is reached either on its own LAN address or through a
// port map on the developer's machine -- so the request's own Host is the only
// value that is right in both cases. A literal Host with a port has the port
// stripped: the links carry their own.
func browserHost(r *http.Request) string {
	h := r.Host
	if fwd := strings.TrimSpace(r.Header.Get("X-Forwarded-Host")); fwd != "" {
		// Apache proxies this page from :80, so the client's Host arrives here.
		h = strings.TrimSpace(strings.Split(fwd, ",")[0])
	}
	if h == "" {
		return ""
	}
	if i := strings.LastIndex(h, "]"); i >= 0 {
		// Bracketed IPv6 literal: the port, if any, follows the bracket.
		return h[:i+1]
	}
	if i := strings.LastIndex(h, ":"); i >= 0 && !strings.Contains(h[:i], ":") {
		return h[:i]
	}
	return h
}

// handleLanding serves the page. Everything it reports is read at request time:
// the page is opened rarely and its whole value is being current about what is
// reachable, so a cached answer would be the one failure it cannot afford.
func (d *daemon) handleLanding(w http.ResponseWriter, r *http.Request) {
	host := browserHost(r)
	grafanaBase := ""
	if host != "" {
		grafanaBase = "http://" + host + ":3000"
	}
	// The probes go out over whatever this daemon is configured with -- loopback
	// for Grafana, the pool's own URL for the aggregator. The links are built
	// for the browser instead: same machines, different addresses, and for the
	// aggregator a different scheme too.
	dashboards := dashboardURLs(r.Context(), d.grafanaURL)
	services := serviceLinks(r.Context(), d.poolClient, aggregatorLinkBase(d.aggregatorURL, host))

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// No script at all on this page, so script-src can be 'none' outright --
	// the strongest form, and the one that stays true because there is nothing
	// here that could want to relax it. Links are navigation, not a fetch, so
	// connect-src stays closed too.
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	_, _ = io.WriteString(w, renderLanding(grafanaBase, dashboards, services))
}
