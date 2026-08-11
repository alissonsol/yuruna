// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// DefaultPort is the host status service's listen port. Every Yuruna host
	// answers /livecheck here unless test.config.yml moved it, which is what
	// --scan-port is for.
	DefaultPort = 8080

	// DefaultInterval is how often the sweep runs.
	DefaultInterval = 15 * time.Minute

	// MaxAddresses caps one scan. A /24 is 254 probes and finishes in seconds;
	// this allows down to a /20 and refuses anything wider. The cap is not
	// about this daemon's ability to do the work -- it is that a mistyped
	// prefix (/8 is one keystroke away from /24) would put 16 million
	// connection attempts onto the lab network before anyone could stop it.
	MaxAddresses = 4096

	// statusServiceName is the value /livecheck self-identifies with. Checking
	// the VALUE, not just a 200, is what separates a Yuruna host from any other
	// web server that happens to hold this port.
	statusServiceName = "yuruna-status-service"

	// livecheckPath is the reachability probe; registrationPath is the record a
	// host serves about itself, and the only way a scan learns a host's own id.
	livecheckPath    = "/livecheck"
	registrationPath = "/runtime/host.registration.json"

	// probeTimeout bounds one address. Deliberately short: on a /24 most
	// addresses are empty, and the scan's wall-clock is dominated by how long
	// it waits for nothing. A LAN host that cannot answer in this window is
	// not in a state the pool could use anyway.
	probeTimeout = 1500 * time.Millisecond

	// registrationTimeout bounds the follow-up read. Longer than the probe: the
	// host has already proven it is there, and this is the read that decides
	// whether it can be identified by id rather than by address.
	registrationTimeout = 3 * time.Second

	// workers is how many addresses are in flight at once. Enough to finish a
	// /24 inside a few probe timeouts; low enough that a sweep is not itself a
	// burst of traffic every quarter hour.
	workers = 32

	// maxScanDuration is the backstop for one run: with the cap and the worker
	// count above, a full scan cannot legitimately take this long, so reaching
	// it means something is wedged and the run should end rather than hold the
	// "running" flag forever.
	maxScanDuration = 10 * time.Minute

	// recentAddresses is how many just-probed addresses the progress snapshot
	// carries. The page shows the sweep moving through the range; a handful is
	// what reads as motion without the poll turning into a log shipper.
	recentAddresses = 12

	// maxProbeBody bounds what a probed address can make this daemon read. The
	// scan talks to machines it has not yet identified, so an endpoint that
	// answers with an endless body must cost one truncated read, not memory.
	maxProbeBody = 64 << 10
)

// Prober decides whether one address is a Yuruna host. It takes a bare IP and
// owns the port, so the engine walks a range without knowing what is listening
// on it -- and so the addresses the page watches read as addresses. Injected so
// the engine can be tested against a table rather than a network.
type Prober func(ctx context.Context, ip string) (Host, bool)

// KnownFunc reports the hosts some OTHER registry already monitors, keyed the
// same way Host.Key is (host id, and address for good measure). A find that is
// already known there is not an addition -- the operator gains nothing from it,
// so the scan reports it as already-monitored and leaves the list alone.
type KnownFunc func(ctx context.Context) map[string]struct{}

// Progress is one snapshot of a scan, past or present. It is the whole contract
// the UI polls: a page that arrives mid-scan renders the same way as the one
// that started it, and a page that arrives after the fact still sees what the
// last run did.
type Progress struct {
	Running bool   `json:"running"`
	CIDR    string `json:"cidr,omitempty"`
	Trigger string `json:"trigger,omitempty"` // "scan" (an operator) or "sweep" (the timer)
	Total   int    `json:"total"`
	Done    int    `json:"done"`
	// Recent is the tail of the addresses probed, newest last.
	Recent []string `json:"recent,omitempty"`
	// Found is what this run ADDED to the monitored list, in the order found.
	Found []Host `json:"found"`
	// AlreadyMonitored counts Yuruna hosts the run confirmed but did not add,
	// because they were already on the list. Without it a scan that finds a
	// fully-enrolled lab reads as a scan that found nothing.
	AlreadyMonitored int    `json:"alreadyMonitored"`
	StartedUTC       string `json:"startedUtc,omitempty"`
	FinishedUTC      string `json:"finishedUtc,omitempty"`
	Error            string `json:"error,omitempty"`
}

// Engine owns the scanning. One scan at a time: two concurrent sweeps of the
// same range would double the traffic to say the same thing, and the progress
// the page polls has one current answer by construction.
type Engine struct {
	store   *Store
	probe   Prober
	known   KnownFunc
	mu      sync.Mutex
	running bool
	cur     Progress
}

// NewEngine builds an engine over a store. probe and known may be nil, which
// yields the HTTP prober on DefaultPort and "nothing else is monitored".
func NewEngine(store *Store, probe Prober, known KnownFunc) *Engine {
	if probe == nil {
		probe = NewHTTPProber(DefaultPort)
	}
	if known == nil {
		known = func(context.Context) map[string]struct{} { return nil }
	}
	return &Engine{store: store, probe: probe, known: known}
}

// ErrScanning is returned when a scan is asked for while one is running.
var ErrScanning = errors.New("a scan is already running")

// Start validates cidr, begins a scan in the background, and returns the
// opening snapshot. The scan is detached from ctx's cancellation on purpose:
// the caller is an HTTP request that returns as soon as the scan is under way,
// and the operator's page then follows it by polling Progress. It stays bounded
// by maxScanDuration instead.
func (e *Engine) Start(ctx context.Context, cidr, trigger string) (Progress, error) {
	prefix, err := ParseCIDR(cidr)
	if err != nil {
		return Progress{}, err
	}
	addrs := Addresses(prefix)
	if len(addrs) == 0 {
		return Progress{}, fmt.Errorf("%s contains no host addresses to scan", prefix)
	}

	e.mu.Lock()
	if e.running {
		e.mu.Unlock()
		return e.Progress(), ErrScanning
	}
	e.running = true
	e.cur = Progress{
		Running:    true,
		CIDR:       prefix.String(),
		Trigger:    trigger,
		Total:      len(addrs),
		Found:      []Host{},
		StartedUTC: time.Now().UTC().Format(time.RFC3339),
	}
	snapshot := e.cur
	e.mu.Unlock()

	runCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), maxScanDuration)
	go func() {
		defer cancel()
		e.run(runCtx, addrs)
	}()
	return snapshot, nil
}

// Progress returns the current (or last) snapshot.
func (e *Engine) Progress() Progress {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := e.cur
	out.Recent = append([]string(nil), e.cur.Recent...)
	out.Found = append([]Host(nil), e.cur.Found...)
	return out
}

// Running reports whether a scan is in flight.
func (e *Engine) Running() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.running
}

// run probes every address and records what it finds. It never returns an error
// to a caller -- there is no caller -- so a failure lands in the snapshot the
// page is already watching.
func (e *Engine) run(ctx context.Context, addrs []string) {
	// Read the other registry ONCE, before probing: a lookup per find would
	// hammer the aggregator with the same question, and a host cannot
	// meaningfully become "already monitored" during the seconds a scan takes.
	known := e.known(ctx)

	work := make(chan string)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for addr := range work {
				e.probeOne(ctx, addr, known)
			}
		}()
	}
feed:
	for _, addr := range addrs {
		select {
		case <-ctx.Done():
			break feed
		case work <- addr:
		}
	}
	close(work)
	wg.Wait()

	e.mu.Lock()
	e.running = false
	e.cur.Running = false
	e.cur.FinishedUTC = time.Now().UTC().Format(time.RFC3339)
	if err := ctx.Err(); err != nil && e.cur.Error == "" {
		// A run that ran out of time reports it: the counts would otherwise say
		// "finished" over a range that was never fully probed.
		e.cur.Error = "scan stopped early: " + err.Error()
	}
	e.mu.Unlock()
}

// probeOne probes a single address and folds the outcome into the snapshot.
func (e *Engine) probeOne(ctx context.Context, ip string, known map[string]struct{}) {
	e.noteProbing(ip)
	host, ok := e.probe(ctx, ip)
	if !ok {
		e.noteDone()
		return
	}
	host.Address = ip
	// BaseURL is left exactly as the prober reported it, empty included: only
	// the prober knows which port answered, and a base assembled here would be
	// a guess. The pages render a host with no base as plain text rather than
	// as a link, which is the better failure -- a link to the wrong port looks
	// like a host that is down.

	_, elsewhere := known[host.Key()]
	if !elsewhere {
		_, elsewhere = known[host.Address]
	}
	switch {
	case elsewhere:
		// Confirmed, but somebody else already monitors it. Still stamped into
		// the store when this daemon already knew it, so its last-seen stays
		// honest; never added as new.
		if e.store.Has(host.Key()) {
			e.store.Add(host, time.Now())
		}
		e.noteAlreadyMonitored()
	case e.store.Add(host, time.Now()):
		e.noteFound(host)
	default:
		e.noteAlreadyMonitored()
	}
	e.noteDone()
}

func (e *Engine) noteProbing(addr string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.cur.Recent = append(e.cur.Recent, addr)
	if len(e.cur.Recent) > recentAddresses {
		e.cur.Recent = e.cur.Recent[len(e.cur.Recent)-recentAddresses:]
	}
}

func (e *Engine) noteDone() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.cur.Done++
}

func (e *Engine) noteFound(h Host) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.cur.Found = append(e.cur.Found, h)
}

func (e *Engine) noteAlreadyMonitored() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.cur.AlreadyMonitored++
}

// RunSweep scans cidrFn()'s answer every interval until ctx is done, and once
// at startup so a freshly-restarted daemon does not wait out a whole interval
// before it knows what is on the network.
//
// cidrFn is a function, not a string: the default range is derived from this
// daemon's own address, and a DHCP lease that moves the service to another
// subnet must move the sweep with it rather than pin it to wherever it booted.
//
// A sweep that lands while an operator's scan is running is skipped, not
// queued: the next one is minutes away, and the operator's run is scanning the
// range they actually care about.
func (e *Engine) RunSweep(ctx context.Context, interval time.Duration, cidrFn func() string) {
	if interval <= 0 {
		return
	}
	sweep := func() {
		cidr := strings.TrimSpace(cidrFn())
		if cidr == "" {
			return
		}
		if _, err := e.Start(ctx, cidr, "sweep"); err != nil && !errors.Is(err, ErrScanning) {
			e.mu.Lock()
			e.cur.Error = err.Error()
			e.mu.Unlock()
		}
	}
	sweep()
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			sweep()
		}
	}
}

// ParseCIDR validates an operator-supplied range and returns it in normalized
// (masked) form. It accepts a host address with a prefix length -- 192.168.7.34/24
// is what an operator has to hand and means the same subnet as 192.168.7.0/24,
// so refusing it would be pedantry with a typing tax.
//
// IPv4 only: a v6 prefix small enough to walk is vanishingly rare and one that
// is not would be an unbounded scan wearing a valid-looking mask.
func ParseCIDR(s string) (netip.Prefix, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return netip.Prefix{}, errors.New("enter a network in CIDR notation, for example 192.168.7.0/24")
	}
	p, err := netip.ParsePrefix(s)
	if err != nil {
		return netip.Prefix{}, fmt.Errorf("%q is not a network in CIDR notation (expected something like 192.168.7.0/24)", s)
	}
	if !p.Addr().Is4() {
		return netip.Prefix{}, errors.New("only IPv4 networks can be scanned")
	}
	p = p.Masked()
	if n := prefixSize(p); n > MaxAddresses {
		return netip.Prefix{}, fmt.Errorf("%s covers %d addresses, more than the %d this service will scan; use a smaller network (a /%d or narrower)",
			p, n, MaxAddresses, minPrefixBits())
	}
	return p, nil
}

// prefixSize is how many addresses a v4 prefix covers, before the network and
// broadcast addresses are set aside.
func prefixSize(p netip.Prefix) int {
	bits := 32 - p.Bits()
	if bits >= 31 {
		// Wider than anything the cap allows; return something past it rather
		// than overflowing the shift.
		return MaxAddresses + 1
	}
	return 1 << bits
}

// minPrefixBits is the narrowest prefix length MaxAddresses permits, for the
// error message above.
func minPrefixBits() int {
	bits := 32
	for size := 1; size < MaxAddresses; size <<= 1 {
		bits--
	}
	return bits
}

// Addresses lists the host addresses in a prefix as "ip:port"-less strings.
//
// The network and broadcast addresses are skipped for anything wider than a
// /31: they are not machines, and probing them is two guaranteed timeouts per
// scan. A /31 and a /32 have no such addresses to skip (RFC 3021 point-to-point
// and a single host), so every address in them is a host.
func Addresses(p netip.Prefix) []string {
	if !p.IsValid() || !p.Addr().Is4() {
		return nil
	}
	skipEnds := p.Bits() <= 30
	out := make([]string, 0, prefixSize(p))
	for a := p.Masked().Addr(); p.Contains(a); a = a.Next() {
		out = append(out, a.String())
		if !a.Next().IsValid() {
			break
		}
	}
	if skipEnds && len(out) > 2 {
		out = out[1 : len(out)-1]
	}
	return out
}

// DefaultCIDR is the /24 around this daemon's own address -- the network the
// service is on, which is the one an operator means when they have not said.
// Empty when no usable address can be found, which the caller reads as "no
// default range", never as a range to guess at.
func DefaultCIDR() string {
	ip := firstUnicastIPv4()
	if !ip.IsValid() {
		return ""
	}
	return netip.PrefixFrom(ip, 24).Masked().String()
}

// firstUnicastIPv4 picks this machine's own routable v4 address. Loopback and
// link-local are skipped: neither is a subnet with other Yuruna hosts on it.
// Lowest address wins when several qualify, so the choice is stable across
// restarts rather than dependent on interface enumeration order.
func firstUnicastIPv4() netip.Addr {
	ifaces, err := net.Interfaces()
	if err != nil {
		return netip.Addr{}
	}
	var best netip.Addr
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, aerr := ifc.Addrs()
		if aerr != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			v4 := ipnet.IP.To4()
			if v4 == nil {
				continue
			}
			addr, ok := netip.AddrFromSlice(v4)
			if !ok || addr.IsLoopback() || addr.IsLinkLocalUnicast() {
				continue
			}
			if !best.IsValid() || addr.Less(best) {
				best = addr
			}
		}
	}
	return best
}

// NewHTTPProber probes an address's status service: /livecheck to decide
// whether this is a Yuruna host at all, then its registration record for the
// identity that lets the find be matched against hosts the pool already knows.
//
// One client for every probe, so the whole scan shares a connection pool
// instead of standing up 254 of them. Redirects are refused: a status service
// answers this in place, and following a redirect would let an unrelated server
// hand the scan somebody else's identity.
func NewHTTPProber(port int) Prober {
	client := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Transport: &http.Transport{
			DialContext:         (&net.Dialer{Timeout: probeTimeout}).DialContext,
			MaxIdleConnsPerHost: workers,
			DisableKeepAlives:   false,
		},
	}
	return func(ctx context.Context, ip string) (Host, bool) {
		base := "http://" + net.JoinHostPort(ip, strconv.Itoa(port))
		var live struct {
			OK      bool   `json:"ok"`
			Service string `json:"service"`
		}
		if err := getJSON(ctx, client, base+livecheckPath, probeTimeout, &live); err != nil {
			return Host{}, false
		}
		if live.Service != statusServiceName {
			return Host{}, false
		}
		host := Host{Address: ip, BaseURL: base}
		// Best-effort: a host that answers /livecheck IS a Yuruna host whether
		// or not it will name itself, so a failed read here costs the id, not
		// the find.
		var reg struct {
			HostID   string `json:"hostId"`
			Hostname string `json:"hostname"`
			HostType string `json:"hostType"`
		}
		if err := getJSON(ctx, client, base+registrationPath, registrationTimeout, &reg); err == nil {
			host.HostID = strings.TrimSpace(reg.HostID)
			host.Hostname = strings.TrimSpace(reg.Hostname)
			host.HostType = strings.TrimPrefix(strings.TrimSpace(reg.HostType), "host.")
		}
		return host, true
	}
}

// getJSON reads one bounded JSON body, with its own deadline on top of the
// caller's so a single slow address cannot spend the whole scan's budget.
func getJSON(ctx context.Context, client *http.Client, url string, timeout time.Duration, into any) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxProbeBody))
	if err != nil {
		return err
	}
	return json.Unmarshal(body, into)
}
