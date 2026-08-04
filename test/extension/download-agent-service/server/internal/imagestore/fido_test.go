// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// --- the stub that stands in for Fido ---------------------------------------

// The suite never runs the real Fido and never reaches Microsoft. What it does
// run is a real child process through the real spawn path, so exit codes, empty
// output, garbage output and a run that outlives its timeout are exercised the
// way production meets them. The interpreter is the platform's own shell rather
// than pwsh: the daemon ships to a Linux guest whose PowerShell is installed by
// cloud-init, and a test that needed PowerShell present would skip on exactly
// the machines that build it.
type stubKind int

const (
	stubEcho stubKind = iota // records its arguments, prints url.txt, exits 0
	stubFail                 // writes to stderr and exits non-zero
	stubHang                 // sleeps far past any timeout under test
)

type fidoStub struct {
	cfg FidoConfig
	dir string
}

var stubBodies = map[stubKind][2]string{
	// [windows .cmd, POSIX sh]
	stubEcho: {
		"@echo off\r\n> \"%~dp0args.txt\" echo %*\r\ntype \"%~dp0url.txt\" 2>nul\r\nexit /b 0\r\n",
		"#!/bin/sh\ndir=$(dirname \"$0\")\nprintf '%s\\n' \"$@\" > \"$dir/args.txt\"\ncat \"$dir/url.txt\" 2>/dev/null\nexit 0\n",
	},
	stubFail: {
		"@echo off\r\necho Fido: no matching ISO 1>&2\r\nexit /b 3\r\n",
		"#!/bin/sh\necho 'Fido: no matching ISO' >&2\nexit 3\n",
	},
	stubHang: {
		// A couple of seconds is plenty to outlast the sub-second timeout under
		// test, and short enough that the sleeping grandchild -- which inherits
		// the pipe handles on Windows whatever its own redirections say -- releases
		// them on its own instead of leaving the suite waiting out cmd.WaitDelay.
		"@echo off\r\nping -n 3 127.0.0.1 >nul 2>&1\r\nexit /b 0\r\n",
		"#!/bin/sh\nsleep 2 >/dev/null 2>&1\nexit 0\n",
	},
}

func newFidoStub(t *testing.T, kind stubKind) *fidoStub {
	t.Helper()
	dir := t.TempDir()
	bodies := stubBodies[kind]
	name, body, interp := "Fido-stub.sh", bodies[1], []string{"/bin/sh"}
	if runtime.GOOS == "windows" {
		name, body, interp = "Fido-stub.cmd", bodies[0], []string{"cmd.exe", "/c"}
	}
	script := filepath.Join(dir, name)
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	s := &fidoStub{dir: dir, cfg: FidoConfig{Interpreter: interp, Script: script, Timeout: 30 * time.Second}}
	s.setURL(t, "")
	return s
}

// setURL is what the stub prints on its next run. Rewriting it between resolves
// is how a signed URL that changes every time is reproduced.
func (s *fidoStub) setURL(t *testing.T, out string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(s.dir, "url.txt"), []byte(out), 0o644); err != nil {
		t.Fatal(err)
	}
}

// args is what the stub was actually invoked with, whitespace-normalised so the
// two platforms' recording formats compare the same.
func (s *fidoStub) args(t *testing.T) []string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(s.dir, "args.txt"))
	if err != nil {
		t.Fatalf("the stub recorded no arguments: %v", err)
	}
	return strings.Fields(string(b))
}

// Two resolves of the same ISO: same filename, same bytes, different signature
// and expiry in the query. This pair is the whole reason the Windows family
// drops the URL from its freshness comparison.
const (
	signedURL1 = "https://software.download.prss.microsoft.com/dbazure/Win11_26H2_English_x64.iso?t=SIGNATURE-ONE"
	signedURL2 = "https://software.download.prss.microsoft.com/dbazure/Win11_26H2_English_x64.iso?t=SIGNATURE-TWO"
	signedName = "Win11_26H2_English_x64.iso"
)

// --- invocation shape --------------------------------------------------------

func TestFidoParametersMirrorTheHostGetImageScripts(t *testing.T) {
	// Verbatim from host/{windows.hyper-v,macos.utm}/guest.windows.11/Get-Image.ps1:
	//   & $fidoScript -Win 11 -Lang $languageFilter -Arch x64 -GetUrl
	// The pool has to hold the artifact those scripts would have fetched; a
	// parameter that drifts here means hosts get an edition nobody asked for and
	// accept it, because they trust the image key rather than what produced it.
	want := []string{"-Win", "11", "-Lang", "English", "-Arch", "x64", "-GetUrl"}
	if got := fidoParams("x64"); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("fidoParams = %v, want %v", got, want)
	}
	if FidoLanguage != "English" {
		t.Fatalf("FidoLanguage = %q, want the host scripts' $languageFilter", FidoLanguage)
	}
}

func TestFidoArchMapsAmd64ToX64AndLeavesArm64Alone(t *testing.T) {
	for arch, want := range map[string]string{ArchAMD64: "x64", ArchARM64: "arm64"} {
		got, ok := fidoArchFor(arch)
		if !ok || got != want {
			t.Errorf("fidoArchFor(%q) = %q ok=%v, want %q", arch, got, ok, want)
		}
	}
	if _, ok := fidoArchFor("riscv64"); ok {
		t.Error("an architecture Fido does not build must have no mapping at all")
	}
}

func TestFidoSuccessParsesTheURLAndPassesTheHostParameters(t *testing.T) {
	stub := newFidoStub(t, stubEcho)
	stub.setURL(t, "Please wait...\n"+signedURL1+"\n")
	r := &Resolver{Fido: stub.cfg}

	got, err := r.Resolve(context.Background(), ImageID{
		HostType: HostTypeKVM, ImageKey: KeyWindows11, Arch: ArchAMD64, Variant: VariantStable})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.SourceURL != signedURL1 {
		t.Fatalf("SourceURL = %q, want the signed URL Fido printed", got.SourceURL)
	}
	// The query holds the signature and the expiry; carrying it into the filename
	// would make the name differ on every resolve, which is the one field the
	// freshness comparison still relies on for this family.
	if got.UpstreamFilename != signedName {
		t.Fatalf("UpstreamFilename = %q, want %q", got.UpstreamFilename, signedName)
	}
	if got.Family != FamilyWindows11 || got.Variant != VariantStable {
		t.Fatalf("resolved = %+v", got)
	}
	if got.ChecksumURL != "" {
		t.Fatalf("ChecksumURL = %q: Microsoft publishes none, and inventing one would be a claim the agent cannot back", got.ChecksumURL)
	}
	want := []string{"-Win", "11", "-Lang", "English", "-Arch", "x64", "-GetUrl"}
	if got := stub.args(t); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("Fido was invoked with %v, want %v", got, want)
	}

	stub.setURL(t, signedURL1)
	if _, err := r.Resolve(context.Background(), ImageID{
		HostType: HostTypeUTM, ImageKey: KeyWindows11, Arch: ArchARM64, Variant: VariantStable}); err != nil {
		t.Fatalf("arm64 Resolve: %v", err)
	}
	if got := stub.args(t); strings.Join(got, " ") != "-Win 11 -Lang English -Arch arm64 -GetUrl" {
		t.Fatalf("arm64 invocation = %v", got)
	}
}

// --- every failure mode is "unavailable", never an error the daemon raises ----

func TestEveryFidoFailureModeLeavesTheFamilyUnavailable(t *testing.T) {
	cases := []struct {
		name string
		cfg  func(t *testing.T) FidoConfig
	}{
		{"non-zero-exit", func(t *testing.T) FidoConfig { return newFidoStub(t, stubFail).cfg }},
		{"no-output", func(t *testing.T) FidoConfig {
			s := newFidoStub(t, stubEcho)
			s.setURL(t, "")
			return s.cfg
		}},
		{"output-that-is-not-a-url", func(t *testing.T) FidoConfig {
			s := newFidoStub(t, stubEcho)
			s.setURL(t, "Sorry, this ISO is not available in your region.\n")
			return s.cfg
		}},
		{"http-url-refused", func(t *testing.T) FidoConfig {
			s := newFidoStub(t, stubEcho)
			// An http URL for a 5.5 GB artifact nothing checksums is a downgrade,
			// not a resolve.
			s.setURL(t, "http://software.download.prss.microsoft.com/x/Win11.iso\n")
			return s.cfg
		}},
		{"missing-interpreter", func(t *testing.T) FidoConfig {
			cfg := newFidoStub(t, stubEcho).cfg
			cfg.Interpreter = []string{filepath.Join(t.TempDir(), "pwsh-not-installed")}
			return cfg
		}},
		{"missing-script", func(t *testing.T) FidoConfig {
			cfg := newFidoStub(t, stubEcho).cfg
			cfg.Script = filepath.Join(t.TempDir(), "Fido.ps1")
			return cfg
		}},
	}
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyWindows11, Arch: ArchAMD64, Variant: VariantStable}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pool := t.TempDir()
			a := newTestAgent(t, Options{PoolDir: pool, Fido: tc.cfg(t)})

			if _, err := a.resolver.Resolve(context.Background(), id); err == nil {
				t.Fatal("the resolver must refuse rather than invent a URL")
			}
			// One force refresh is what an operator or a first ensure would do;
			// after it the family has to read as unavailable, not as a failed
			// image, because hosts step over the first silently and warn on the
			// second.
			if err := a.refreshNow(context.Background(), id, &Progress{}); err == nil {
				t.Fatal("refreshNow must fail rather than commit an entry with no bytes")
			}
			if reason := a.familyUnavailable(id); reason == "" {
				t.Fatal("the family must read as unavailable so hosts fall through to their own path")
			}
			if res := a.Ensure(fixedNow, id, Fingerprint{}); res.HTTPStatus != http.StatusNotFound || res.Reason != ReasonUnsupported {
				t.Fatalf("ensure = %+v, want the same 404 unsupported-image any absent identity gets", res)
			}
			// Nothing may be left behind: a pointer or a staged part-file would be
			// a pool entry describing bytes that were never fetched.
			if _, ok, _ := a.store.ReadPointer(id); ok {
				t.Fatal("a failed resolve must leave no pointer")
			}
			if gens, _ := a.store.Generations(id); len(gens) != 0 {
				t.Fatalf("a failed resolve left %d generation(s) behind", len(gens))
			}
		})
	}
}

func TestFidoHangIsCutByTheTimeout(t *testing.T) {
	stub := newFidoStub(t, stubHang)
	stub.cfg.Timeout = 300 * time.Millisecond
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: stub.cfg})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyWindows11, Arch: ArchAMD64, Variant: VariantStable}

	start := time.Now()
	_, err := a.resolver.Resolve(context.Background(), id)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("a Fido that never answers must not resolve")
	}
	if !strings.Contains(err.Error(), "within") {
		t.Fatalf("error = %v, want one that names the timeout", err)
	}
	// The bound is the point: an unbounded child would hold a scan pass, and the
	// ensure that started it, for as long as the daemon lives.
	if elapsed > 15*time.Second {
		t.Fatalf("the resolve took %s; the timeout did not cut it", elapsed)
	}
	// The refresh that wraps it records the outcome, so the next ensure answers
	// "unavailable" instead of starting the same hang again.
	_ = a.refreshNow(context.Background(), id, &Progress{})
	if a.familyUnavailable(id) == "" {
		t.Fatal("a timed-out resolve must leave the family unavailable")
	}
}

// --- virtio-win --------------------------------------------------------------

func TestVirtioWinResolvesToThePinnedArchiveURLWithoutTouchingTheNetwork(t *testing.T) {
	// A transport that fails on use: the pin is a constant, so a resolve that
	// reached out at all would mean the redirect chain is back in play.
	r := NewResolver(&http.Client{Transport: refusingTransport{}})
	got, err := r.Resolve(context.Background(), ImageID{
		HostType: HostTypeKVM, ImageKey: KeyVirtioWin, Arch: ArchAMD64, Variant: VariantStable})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	const want = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"
	if got.SourceURL != want {
		t.Fatalf("SourceURL = %q, want the pinned archive URL %q", got.SourceURL, want)
	}
	if got.UpstreamFilename != "virtio-win-0.1.285.iso" {
		t.Fatalf("UpstreamFilename = %q", got.UpstreamFilename)
	}
	if !strings.Contains(got.SourceURL, "/archive-virtio/") {
		t.Fatal("the convenience stable-virtio path bounces https->http, which .NET clients and the ssl-bump port cannot follow")
	}
	if got.Family != FamilyVirtioWin || got.Variant != VariantStable {
		t.Fatalf("resolved = %+v", got)
	}
	if got.ChecksumURL != "" {
		t.Fatalf("ChecksumURL = %q: the publisher ships no sidecar beside the archived ISO", got.ChecksumURL)
	}
}

func TestVirtioWinIsRefusedOnArm64(t *testing.T) {
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyVirtioWin, Arch: ArchARM64, Variant: VariantStable}
	if Supported(id) {
		t.Fatal("virtio-win carries x86-64 drivers only; an arm64 identity must be unsupported")
	}
	r := NewResolver(&http.Client{Transport: refusingTransport{}})
	if _, err := r.Resolve(context.Background(), id); err == nil {
		t.Fatal("the resolver must refuse arm64 rather than hand back a driver bundle the guest cannot load")
	}
}

type refusingTransport struct{}

func (refusingTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return nil, &url.Error{Op: "Get", URL: r.URL.String(), Err: errRefused{}}
}

type errRefused struct{}

func (errRefused) Error() string { return "this resolver must not make requests" }

// --- Supported ---------------------------------------------------------------

func TestSupportedCoversTheNewFamilies(t *testing.T) {
	cases := []struct {
		id   ImageID
		want bool
		why  string
	}{
		{ImageID{HostTypeKVM, KeyWindows11, ArchAMD64, VariantStable}, true, "the KVM host gains a Windows ISO path it never had"},
		{ImageID{HostTypeUTM, KeyWindows11, ArchARM64, VariantStable}, true, "UTM installs the ARM64 build"},
		{ImageID{HostTypeHyperV, KeyWindows11, ArchAMD64, VariantStable}, true, "Hyper-V installs the x64 build"},
		{ImageID{HostTypeKVM, KeyWindows11, ArchAMD64, VariantDaily}, false, "Windows has no daily preference"},
		{ImageID{HostTypeKVM, KeyVirtioWin, ArchAMD64, VariantStable}, true, "the pinned archive is x86-64"},
		{ImageID{HostTypeKVM, KeyVirtioWin, ArchARM64, VariantStable}, false, "the bundle has no arm64 drivers"},
		{ImageID{HostTypeKVM, KeyVirtioWin, ArchAMD64, VariantDaily}, false, "virtio-win has no daily preference"},
	}
	for _, tc := range cases {
		if got := Supported(tc.id); got != tc.want {
			t.Errorf("Supported(%s) = %v, want %v: %s", tc.id, got, tc.want, tc.why)
		}
	}
	for _, key := range []string{KeyWindows11, KeyVirtioWin} {
		if !IsBestEffort(key) {
			t.Errorf("%s must be flagged best-effort", key)
		}
		if _, ok := CodenameFor(key); ok {
			t.Errorf("%s is not an Ubuntu release and must have no codename", key)
		}
	}
	for _, key := range []string{KeyUbuntuServer24, KeyUbuntuServer26, KeyUbuntuExtension, KeyAmazonLinux2023} {
		if IsBestEffort(key) {
			t.Errorf("%s is a seeded family and must not be best-effort", key)
		}
	}
}

// --- the signed-URL freshness exception --------------------------------------

func TestADifferentURLForTheSameArtifactIsFreshOnlyForTheWindowsFamily(t *testing.T) {
	// Same upstream filename, same Content-Length, a URL that changed. For a
	// normal family that is a new artifact; for the signed-URL family it is the
	// same ISO behind a new signature, and treating it as new would re-download
	// ~5.5 GB on every scan, forever.
	sc := &Sidecar{
		UpstreamFilename: signedName,
		SourceURL:        signedURL1,
		ByteCount:        5_500_000_000,
		LastModified:     "Thu, 23 Jul 2026 09:14:02 GMT",
	}
	windows := Resolved{Family: FamilyWindows11, UpstreamFilename: signedName, SourceURL: signedURL2}
	if !sameOrigin(sc, windows, sc.ByteCount, "Fri, 24 Jul 2026 11:00:00 GMT") {
		t.Fatal("a re-signed URL for identical bytes must compare as unchanged, or the agent re-downloads the ISO on every scan forever")
	}

	normal := Resolved{
		Family: FamilyUbuntuISO, UpstreamFilename: sc.UpstreamFilename, SourceURL: sc.SourceURL + "?tampered",
	}
	if sameOrigin(sc, normal, sc.ByteCount, sc.LastModified) {
		t.Fatal("for every other family a changed URL is how a new artifact announces itself and must trigger a download")
	}

	// The exception is not a free pass: the two fields it still compares have to
	// keep their teeth.
	renamed := Resolved{Family: FamilyWindows11, UpstreamFilename: "Win11_27H1_English_x64.iso", SourceURL: signedURL2}
	if sameOrigin(sc, renamed, sc.ByteCount, "") {
		t.Fatal("a new upstream filename is a new release and must download")
	}
	if sameOrigin(sc, windows, sc.ByteCount+1, "") {
		t.Fatal("a changed Content-Length must download")
	}
}

func TestOnlyTheWindowsFamilyDropsTheURLFromTheComparison(t *testing.T) {
	// Enumerated over the whole family set on purpose: the exception exists for
	// one publisher's signing scheme, and a family added later must not inherit
	// it by sitting next to the code that grants it.
	for _, family := range AllFamilies {
		want := family != FamilyWindows11
		if got := ComparesSourceURL(family); got != want {
			t.Errorf("ComparesSourceURL(%q) = %v, want %v", family, got, want)
		}
	}
	// The zero value is the strict side, so a resolver that forgot to name its
	// family keeps the full comparison.
	if !ComparesSourceURL("") {
		t.Error("an unnamed family must keep comparing the URL")
	}
	for _, key := range []string{KeyUbuntuServer24, KeyUbuntuServer26, KeyUbuntuExtension, KeyAmazonLinux2023, KeyWindows11, KeyVirtioWin} {
		family := FamilyOf(key)
		found := false
		for _, known := range AllFamilies {
			found = found || known == family
		}
		if !found {
			t.Errorf("FamilyOf(%q) = %q, which is outside AllFamilies and so escapes the check above", key, family)
		}
	}
}

func TestASignedURLRefreshDoesNotRedownloadUnchangedBytes(t *testing.T) {
	body := []byte("a stand-in for the 5.5 GB Windows 11 ISO")
	var gets atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", itoa(len(body)))
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		gets.Add(1)
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}

	stub := newFidoStub(t, stubEcho)
	stub.setURL(t, signedURL1)
	a := newTestAgent(t, Options{
		PoolDir:   t.TempDir(),
		Transport: fixtureTransport{base: http.DefaultTransport, host: u.Host},
		Fido:      stub.cfg,
	})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyWindows11, Arch: ArchAMD64, Variant: VariantStable}

	if err := a.refreshNow(context.Background(), id, &Progress{}); err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	if gets.Load() != 1 {
		t.Fatalf("first refresh fetched %d time(s), want 1", gets.Load())
	}
	p, ok, err := a.store.ReadPointer(id)
	if err != nil || !ok {
		t.Fatalf("ReadPointer: %v ok=%v", err, ok)
	}
	sc, err := a.store.ReadSidecar(id, p.GenerationFile)
	if err != nil {
		t.Fatal(err)
	}
	if sc.SourceURL != signedURL1 || sc.UpstreamFilename != signedName {
		t.Fatalf("sidecar = %+v", sc)
	}
	if sc.ChecksumVerdict != VerdictNone {
		t.Fatalf("checksumVerdict = %q, want %q: no publisher checksum exists for this artifact", sc.ChecksumVerdict, VerdictNone)
	}

	// The next resolve mints a different URL for the same ISO, which is what
	// every real Fido run does.
	stub.setURL(t, signedURL2)
	if err := a.refreshNow(context.Background(), id, &Progress{}); err != nil {
		t.Fatalf("second refresh: %v", err)
	}
	if gets.Load() != 1 {
		t.Fatalf("the second refresh downloaded again (%d fetches): a signed URL that changes every time would re-pull the ISO on every scan forever", gets.Load())
	}
	gens, err := a.store.Generations(id)
	if err != nil {
		t.Fatal(err)
	}
	if len(gens) != 1 {
		t.Fatalf("%d generations on disk, want 1", len(gens))
	}
}

// --- best-effort surfacing ---------------------------------------------------

func TestTheCatalogExplainsAnUnavailableBestEffortFamily(t *testing.T) {
	cfg := newFidoStub(t, stubEcho).cfg
	cfg.Script = filepath.Join(t.TempDir(), "Fido.ps1") // never installed
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: cfg})

	rows, _ := a.Catalog(fixedNow)
	byKey := map[string]CatalogEntry{}
	for _, row := range rows {
		byKey[row.ImageKey+"/"+row.HostType] = row
	}

	win, ok := byKey[KeyWindows11+"/"+HostTypeKVM]
	if !ok {
		t.Fatal("a best-effort family must still have a row: a table that simply omits it reads as a feature that does not exist")
	}
	if !win.BestEffort {
		t.Error("the Windows row must be marked best-effort so an operator knows the scanner will never fill it on its own")
	}
	if win.State != StateUnavailable {
		t.Errorf("state = %q, want %q -- not %q, which reads as 'the download is pending'", win.State, StateUnavailable, StateAbsent)
	}
	if win.UnavailableReason == "" {
		t.Error("an unavailable row without a reason is the failure mode this row exists to avoid")
	}

	// virtio-win is best-effort too, but it needs no external tooling, so it is
	// simply not fetched yet. The two must not read the same.
	virtio, ok := byKey[KeyVirtioWin+"/"+HostTypeKVM]
	if !ok {
		t.Fatal("the KVM host type must carry a virtio-win row")
	}
	if !virtio.BestEffort || virtio.UnavailableReason != "" || virtio.State != StateAbsent {
		t.Errorf("virtio-win row = %+v, want best-effort, absent and unexplained-by-nothing", virtio)
	}

	st := a.Status(fixedNow)
	if len(st.BestEffort) != len(BestEffortKeys) {
		t.Fatalf("status reported %d best-effort families, want %d", len(st.BestEffort), len(BestEffortKeys))
	}
	for _, fs := range st.BestEffort {
		switch fs.ImageKey {
		case KeyWindows11:
			if fs.Available || fs.Reason == "" {
				t.Errorf("status for %s = %+v, want unavailable with a reason", fs.ImageKey, fs)
			}
		case KeyVirtioWin:
			if !fs.Available {
				t.Errorf("status for %s = %+v, want available", fs.ImageKey, fs)
			}
		default:
			t.Errorf("unexpected best-effort family %q", fs.ImageKey)
		}
	}
}

func TestBestEffortRowsExistWithoutConsumingSeedBandwidth(t *testing.T) {
	seeded := map[string]bool{}
	for _, id := range SeedTargets(HostTypes) {
		seeded[id.Key()] = true
	}
	catalogued := map[string]bool{}
	for _, id := range CatalogTargets(HostTypes) {
		catalogued[id.Key()] = true
	}
	want := []ImageID{
		{HostTypeHyperV, KeyWindows11, ArchAMD64, VariantStable},
		{HostTypeKVM, KeyWindows11, ArchAMD64, VariantStable},
		{HostTypeKVM, KeyVirtioWin, ArchAMD64, VariantStable},
		{HostTypeUTM, KeyWindows11, ArchARM64, VariantStable},
	}
	for _, id := range want {
		if seeded[id.Key()] {
			t.Errorf("%s is seeded; a multi-gigabyte artifact nobody asked for must stay demand-driven", id)
		}
		if !catalogued[id.Key()] {
			t.Errorf("%s has no catalog row, so an operator has nothing to act on", id)
		}
	}
	// UTM runs arm64, where the driver bundle does not exist, so no row is
	// offered rather than one that could only ever refuse.
	if catalogued[(ImageID{HostTypeUTM, KeyVirtioWin, ArchARM64, VariantStable}).Key()] {
		t.Error("virtio-win must not appear for an arm64 host type")
	}
	for _, id := range BestEffortTargets(HostTypes) {
		if !Supported(id) {
			t.Errorf("catalogued %s is not supported, so its row could only ever refuse", id)
		}
	}
}

func TestAServableWindowsEntrySurvivesFidoGoingAway(t *testing.T) {
	// The bytes are already in the pool from a run when Fido worked. Losing the
	// resolver must not make them unservable: hosts that need the ISO can still
	// have it, they just cannot get a fresher one.
	cfg := newFidoStub(t, stubEcho).cfg
	cfg.Script = filepath.Join(t.TempDir(), "Fido.ps1")
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: cfg})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyWindows11, Arch: ArchAMD64, Variant: VariantStable}
	mustCommit(t, a.store, id, signedName, "abcdef0123456789", 4096, fixedNow)

	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.HTTPStatus != http.StatusOK || res.State != StateReady {
		t.Fatalf("ensure = %+v, want the committed artifact served", res)
	}

	// The same entry gone stale must not start a refresh that has no way to run.
	stale := fixedNow.Add(48 * time.Hour)
	res = a.Ensure(stale, id, Fingerprint{})
	if res.HTTPStatus != http.StatusOK || !res.Stale {
		t.Fatalf("stale ensure = %+v, want the previous verified artifact served", res)
	}
	if res.RefreshInFlight || a.flights.Len() != 0 {
		t.Fatal("no refresh may be started for a family whose resolver cannot run")
	}
}
