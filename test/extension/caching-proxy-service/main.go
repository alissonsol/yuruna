// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// caching-proxy-service: the management plane for the Yuruna caching proxy.
//
// The proxy VM was the one Yuruna service outside the extension interface --
// no manifest, no beacon, nothing the pool could ask. This daemon gives it the
// same shape its siblings have without moving anything that serves traffic:
// squid, zot, Grafana, Prometheus, Loki and the exporters stay where they are,
// on the ports they already use. What it adds is a read surface over that VM's
// state and ownership of the two operator switches (offline mode, no upstream)
// that were previously flipped by hand over SSH.
//
// It is deliberately separable from squid's host. Everything it reads comes
// from squid's manager API, zot's HTTP API, or files on a share -- never from a
// local socket or a systemd call -- so the same binary runs either ON the proxy
// VM (--mode local, the default) or on another machine that can reach those
// (--mode remote). Remote mode is READ-ONLY: stock squid has no remote
// reconfigure, so a change made off the box could be written but never
// applied, and the mutating routes say so rather than pretending.
//
// Full design and operator guide: https://yuruna.link/caching-proxy-service.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"yuruna.com/test/extension/extension-sdk/beacon"
	"yuruna.com/test/extension/extension-sdk/labgate"
	"yuruna.com/test/extension/extension-sdk/pool"
)

// presenceArea is the extension-area token this service announces to the pool
// aggregator. It must equal the directory name under test/extension/, which is
// what the aggregator keys its Extension hosts row by.
const presenceArea = "caching-proxy-service"

// defaultPresenceInterval is the re-announce cadence for the beacon. Kept
// shorter than the aggregator's extension health grace: re-announcing is how a
// renumbered service tells the pool its new address, so a cadence slower than
// the grace leaves the area unresolvable between the moment the old address is
// refused and the next announce.
const defaultPresenceInterval = 2 * time.Minute

// maxRequestBytes caps a mutation body. Nothing this daemon accepts is larger
// than a small JSON object.
const maxRequestBytes = 1 << 20

type runMode string

const (
	modeLocal  runMode = "local"
	modeRemote runMode = "remote"
)

// version is overwritten at link time with -X main.version=<framework version>.
// A build that loses that flag still runs and reports "dev", which is why the
// suite asserts the field rather than only its presence.
var version = "dev"

type daemon struct {
	mode             runMode
	hostID           string
	squid            *squidClient
	registry         *registryReader
	gate             *labgate.Gate
	squidBinary      string
	noUpstreamHelper string
	// The two switch drop-ins, as fields rather than constants so a test can
	// point them at a temp dir and never write into a real /etc/squid.
	offlinePath    string
	noUpstreamPath string
	// run and readSwitches are indirected so the tests never touch a squid: the
	// wiring is what is covered here, and what the commands themselves do is
	// squid's business.
	run          func(name string, args ...string) (string, error)
	readSwitches func() SwitchState
	// parserURL is the sibling daemon on this VM that tails squid's access log.
	// It is read over HTTP rather than imported: the parser holds a live ring in
	// its own process, and it deliberately has no agent surface of its own.
	parserURL string
	// The three the landing page is built from. aggregatorURL and poolClient
	// answer where each extension service is; grafanaURL answers which
	// dashboards exist. All three are read over loopback at request time -- see
	// landing.go for why nothing there is cached.
	aggregatorURL string
	grafanaURL    string
	poolClient    *pool.Client
}

func main() {
	httpAddr := flag.String("http-addr", "0.0.0.0:9310", "address to serve the management API on; empty disables it")
	mode := flag.String("mode", string(modeLocal), "local (on the proxy VM) or remote (reads only, over the squid and registry APIs)")
	squidAddr := flag.String("squid-addr", "127.0.0.1:3128", "host:port of the squid HTTP port whose manager pages are read")
	squidPassword := flag.String("squid-mgr-password-file", "", "file holding the cachemgr_passwd for the manager pages; empty for none")
	registryURL := flag.String("registry-url", "http://127.0.0.1:5000", "base URL of the zot registry; empty disables the registry read")
	metaURL := flag.String("meta-url", "http://127.0.0.1", "base URL serving /zot-meta, the metadata exporter's Prometheus text")
	shareRoot := flag.String("share-root", "/var/lib/yuruna", "directory holding the zot canary and prewarm records")
	aggregatorURL := flag.String("aggregator-url", "", "pool-aggregator base URL, for the presence beacon and the lab-token gate")
	hostID := flag.String("host-id", "", "this host's stable id; empty disables the beacon")
	presenceInterval := flag.Duration("presence-interval", defaultPresenceInterval, "re-announce cadence; 0 disables the beacon")
	authTokenFile := flag.String("auth-token-file", "", "file holding the internal authentication key; absent disables the bearer path")
	squidBinary := flag.String("squid-binary", "squid", "squid binary used for `-k reconfigure`")
	parserURL := flag.String("parser-url", "http://127.0.0.1:9302", "base URL of the caching-proxy-parser-service on this VM, whose recent-request tail this service republishes; empty disables it")
	grafanaURL := flag.String("grafana-url", "http://127.0.0.1:3000", "base URL of Grafana on this VM, asked which dashboards exist for the landing page; empty lists them all as unavailable")
	flag.Parse()

	d := &daemon{
		mode:             runMode(*mode),
		hostID:           *hostID,
		squidBinary:      *squidBinary,
		noUpstreamHelper: noUpstreamHelper,
		offlinePath:      offlineConfPath,
		noUpstreamPath:   noUpstreamConfPath,
		run:              runCommand,
		parserURL:        strings.TrimRight(*parserURL, "/"),
		aggregatorURL:    strings.TrimRight(*aggregatorURL, "/"),
		grafanaURL:       strings.TrimRight(*grafanaURL, "/"),
	}
	// The same read client the other services use, so the landing page resolves
	// an extension area exactly the way the dashboard's Extension hosts cell
	// does rather than inventing a second answer to the same question.
	d.poolClient = pool.New(pool.Options{BaseURL: *aggregatorURL})
	if d.mode != modeLocal && d.mode != modeRemote {
		log.Fatalf("--mode must be %q or %q, got %q", modeLocal, modeRemote, *mode)
	}

	d.squid = newSquidClient(*squidAddr, readTrimmedFile(*squidPassword), 5*time.Second)
	d.registry = newRegistryReader(*registryURL, *metaURL, *shareRoot, 5*time.Second)
	d.gate = labgate.New(labgate.Options{
		AggregatorURL: *aggregatorURL,
		BearerToken:   readTrimmedFile(*authTokenFile),
		CookieName:    "yuruna_caching_proxy_service",
		Audit: func(ip, outcome, detail string) {
			log.Printf("lab-token unlock from %s: %s %s", ip, outcome, detail)
		},
	})
	d.readSwitches = d.switchState

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	bcn := beacon.New(*aggregatorURL, *hostID, presenceArea, uiPort(*httpAddr), *presenceInterval)
	beaconDone := make(chan struct{})
	if bcn.Enabled() {
		go func() { bcn.Run(ctx); close(beaconDone) }()
	} else {
		close(beaconDone)
	}

	if *httpAddr == "" {
		log.Printf("caching-proxy-service %s (%s mode): no --http-addr, serving nothing", version, d.mode)
		<-ctx.Done()
		<-beaconDone
		return
	}

	srv := &http.Server{
		Addr:              *httpAddr,
		Handler:           d.routes(),
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	log.Printf("caching-proxy-service %s (%s mode) listening on %s, squid at %s", version, d.mode, *httpAddr, *squidAddr)

	errCh := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()
	select {
	case err := <-errCh:
		if err != nil {
			log.Fatalf("serve: %v", err)
		}
	case <-ctx.Done():
	}
	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)
	<-beaconDone
}

// routes registers everything this daemon serves. The five-block order is the
// one its siblings use: health, the ways into the gate, open reads, gated
// mutations, and the one page the dashboard links to.
func (d *daemon) routes() http.Handler {
	mux := http.NewServeMux()

	// /healthz stays OPEN and never gated: the launcher polls it to decide the
	// daemon is up, and the aggregator probes it before it will publish this
	// area's address at all.
	mux.HandleFunc("GET /healthz", d.handleHealth)

	// The session route must be open, or an operator could not discover that a
	// lab token is what they need.
	mux.HandleFunc("GET /api/session", d.handleSession)
	mux.HandleFunc("POST /api/login", d.gate.HandleLogin)
	mux.HandleFunc("POST /api/unlock-proof", d.gate.HandleProofUnlock)

	// Reads: unconditionally open on the trusted LAN, matching pool-status and
	// every other service's read surface.
	mux.HandleFunc("GET /api/hostinfo", d.handleHostInfo)
	mux.HandleFunc("GET /api/status", d.handleStatus)
	mux.HandleFunc("GET /api/switches", d.handleSwitches)
	mux.HandleFunc("GET "+routeRecentRequests, d.handleRecentRequests)

	// Mutations: the lab-token gate, and in remote mode a 501 underneath it.
	mux.HandleFunc("POST /api/switches/offline", d.gate.Require(d.handleSetOffline))
	mux.HandleFunc("POST /api/switches/no-upstream", d.gate.Require(d.handleSetNoUpstream))

	// MCP over the same surface, gated by the same gate. Not wrapped in
	// gate.Require: the protocol decides per TOOL, because its read-only tools
	// must stay as open as the routes they wrap.
	mux.HandleFunc("POST /mcp", d.mcpServer().Handler())

	// The page the dashboard's Extension hosts cell deep-links to. Open, like
	// the reads it renders: gating it would serve a 401 body a browser cannot
	// act on, to an operator who clicked a link the dashboard offered them.
	mux.HandleFunc("GET /{$}", handleIndex)
	mux.HandleFunc("GET /index.html", handleIndex)
	// The VM's landing page, which Apache proxies onto port 80 of this host --
	// so it keeps a URL an operator can type, and this daemon's own port stays
	// off the LAN. Distinct from the index above, which is this SERVICE's
	// statistics page and is what the landing page's own Caching-proxy row
	// links to.
	mux.HandleFunc("GET /landing", d.handleLanding)

	return mux
}

func (d *daemon) handleHealth(w http.ResponseWriter, _ *http.Request) {
	// Text, not JSON, and cheap: the launcher and the aggregator both poll it,
	// and neither should wait on squid to answer. What squid is doing is
	// /api/status's question.
	_, _ = io.WriteString(w, "ok\n")
}

func (d *daemon) handleHostInfo(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"localHostId": d.hostID,
		"version":     version,
		"mode":        string(d.mode),
		"serverIps":   serverIPLines(),
	})
}

func (d *daemon) handleSession(w http.ResponseWriter, r *http.Request) {
	s := d.gate.Session(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            s.OK,
		"labToken":      s.LabToken,
		"bearer":        s.Bearer,
		"authed":        s.Authed,
		"configured":    s.Configured,
		"mutationsOpen": s.MutationsOpen && d.mode == modeLocal,
		"mode":          string(d.mode),
		"version":       version,
	})
}

// handleStatus is the composite an operator or a dashboard reads. Each part
// reports its own failure rather than failing the whole response: a squid that
// is not answering is exactly what this endpoint exists to say, and the
// switches and registry beside it are usually still readable.
func (d *daemon) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":       true,
		"mode":     string(d.mode),
		"version":  version,
		"squid":    d.squid.summary(),
		"switches": d.readSwitches(),
		"registry": d.registry.state(),
	})
}

func (d *daemon) handleSwitches(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":       true,
		"mode":     string(d.mode),
		"switches": d.readSwitches(),
	})
}

// switchState answers from the drop-ins on the box, and from squid's running
// configuration when there is no box to read.
func (d *daemon) switchState() SwitchState {
	if d.mode == modeLocal {
		return d.readSwitchesLocal()
	}
	cfg, err := d.squid.page("config")
	if err != nil {
		return SwitchState{Source: "mgr:config", Detail: "could not read the running configuration: " + err.Error()}
	}
	return readSwitchesRemote(cfg)
}

func (d *daemon) handleSetOffline(w http.ResponseWriter, r *http.Request) {
	d.applySwitch(w, r, d.applyOffline, "offline mode")
}

func (d *daemon) handleSetNoUpstream(w http.ResponseWriter, r *http.Request) {
	d.applySwitch(w, r, d.applyNoUpstream, "no-upstream")
}

// applySwitch is the one place a switch change is decoded, refused or applied,
// so both switches answer identically -- including the remote refusal, which
// an operator has to be able to recognize without reading two error strings.
func (d *daemon) applySwitch(w http.ResponseWriter, r *http.Request, apply func(bool) error, what string) {
	var body struct {
		On *bool `json:"on"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, maxRequestBytes)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "body must be JSON with an \"on\" boolean")
		return
	}
	if body.On == nil {
		writeErr(w, http.StatusBadRequest, "body must name \"on\": true or false")
		return
	}
	if err := apply(*body.On); err != nil {
		if errors.Is(err, errRemoteReadOnly) {
			// 501, not 403: the operator is permitted, the capability does not
			// exist here. Stock squid has no remote reconfigure, so this
			// daemon can read the switch off the box but never apply one.
			writeReason(w, http.StatusNotImplemented, "caching-proxy-remote-readonly",
				"this daemon is in remote mode and cannot apply "+what+": squid has no remote reconfigure, so the change would be written and never loaded. Run the switch from the proxy VM's own daemon.")
			return
		}
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("could not apply %s: %v", what, err))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":       true,
		"switches": d.readSwitches(),
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "error": msg})
}

func writeReason(w http.ResponseWriter, status int, reason, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "reason": reason, "error": msg})
}

// readTrimmedFile returns a secret file's contents with surrounding whitespace
// removed, or "" when it cannot be read. Absent is a configuration state here,
// not an error: no token file means the bearer path is simply not offered.
func readTrimmedFile(path string) string {
	if path == "" {
		return ""
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(body))
}

// uiPort extracts the port the beacon should advertise. Any parse failure
// yields 0, which the beacon reads as "no deep-link" rather than guessing.
func uiPort(addr string) int {
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(port)
	if err != nil {
		return 0
	}
	return n
}

// serverIPLines returns this host's non-loopback, non-link-local unicast IPs as
// up to two newline-separated lines: IPv4 (comma-joined) then IPv6. Same shape
// as every other daemon's /api/hostinfo, so one reader handles all of them.
func serverIPLines() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	var v4, v6 []string
	for _, iface := range ifaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok || ipnet.IP.IsLoopback() || ipnet.IP.IsLinkLocalUnicast() || !ipnet.IP.IsGlobalUnicast() {
				continue
			}
			if ipnet.IP.To4() != nil {
				v4 = append(v4, ipnet.IP.String())
			} else {
				v6 = append(v6, ipnet.IP.String())
			}
		}
	}
	var lines []string
	if s := commaJoinUnique(v4); s != "" {
		lines = append(lines, s)
	}
	if s := commaJoinUnique(v6); s != "" {
		lines = append(lines, s)
	}
	return strings.Join(lines, "\n")
}

func commaJoinUnique(in []string) string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	if len(out) == 0 {
		return ""
	}
	sortStrings(out)
	return strings.Join(out, ",")
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// routeRecentRequests republishes the parser daemon's live tail of squid's
// access log. It exists on THIS service, not on the parser, because the parser
// is documented as having no agent surface and reversing that would contradict
// two shipped documents for no gain: both daemons run on this VM, so the hop is
// loopback, and this service already owns the caching_proxy_* namespace the data
// belongs to.
//
// The rows carry attacker-controlled fields (request URL and User-Agent, per the
// parser's own header comment) and are republished verbatim. That is not a new
// exposure -- the parser already serves the identical JSON to the whole LAN on
// its own port -- but it is a reason to treat the values as data, never as
// markup, in anything that renders them.
const routeRecentRequests = "/api/v1/recent-requests"

// defaultRecentLimit matches the panel this route gives a text equivalent for,
// which is titled "Recent 100 requests". A caller wanting less says so.
const defaultRecentLimit = 100

// handleRecentRequests proxies the parser's ring, newest first.
//
// A parser that is down is reported as a 503 naming it, not as an empty list: a
// caller cannot tell "the proxy served nothing" from "nothing answered", and the
// second is an operational fault worth surfacing rather than smoothing over.
func (d *daemon) handleRecentRequests(w http.ResponseWriter, r *http.Request) {
	if d.parserURL == "" {
		http.Error(w, `{"ok":false,"error":"no parser configured"}`, http.StatusServiceUnavailable)
		return
	}
	limit := defaultRecentLimit
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 {
			http.Error(w, `{"ok":false,"error":"limit must be a positive integer"}`, http.StatusBadRequest)
			return
		}
		limit = n
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, d.parserURL+"/recent-requests", nil)
	if err != nil {
		http.Error(w, `{"ok":false,"error":"cannot address the parser"}`, http.StatusInternalServerError)
		return
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		http.Error(w, `{"ok":false,"error":"caching-proxy-parser-service did not answer"}`, http.StatusServiceUnavailable)
		return
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		http.Error(w, `{"ok":false,"error":"caching-proxy-parser-service answered `+strconv.Itoa(resp.StatusCode)+`"}`,
			http.StatusBadGateway)
		return
	}

	var rows []map[string]any
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&rows); err != nil {
		http.Error(w, `{"ok":false,"error":"caching-proxy-parser-service returned unreadable JSON"}`, http.StatusBadGateway)
		return
	}
	if len(rows) > limit {
		rows = rows[:limit]
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":       true,
		"count":    len(rows),
		"limit":    limit,
		"requests": rows,
	})
}
