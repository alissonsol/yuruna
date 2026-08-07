// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package httpsrv

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"download-agent-service/internal/imagestore"
)

// fakeImages records what the handlers asked for and answers deterministically.
type fakeImages struct {
	mu        sync.Mutex
	available bool
	entry     imagestore.CatalogEntry
	found     bool
	ensure    imagestore.EnsureResult
	filePath  string

	refreshed  []imagestore.ImageID
	deleted    []imagestore.ImageID
	pruned     []imagestore.ImageID
	refreshAll int
	ensured    []imagestore.ImageID
	lastFP     imagestore.Fingerprint
	fidoTests  []string
	refreshErr error

	refreshAllErr error
}

func (f *fakeImages) PoolAvailable() bool { return f.available }

func (f *fakeImages) Status(time.Time) imagestore.Status {
	return imagestore.Status{PoolAvailable: f.available, ScanIntervalSeconds: 900}
}

func (f *fakeImages) Catalog(time.Time) ([]imagestore.CatalogEntry, imagestore.Totals) {
	return []imagestore.CatalogEntry{f.entry}, imagestore.Totals{Images: 1, Bytes: 10, ByHostType: map[string]int64{"ubuntu.kvm": 10}}
}

func (f *fakeImages) Entry(_ time.Time, id imagestore.ImageID) (imagestore.CatalogEntry, bool) {
	e := f.entry
	e.HostType, e.ImageKey, e.Arch, e.Variant = id.HostType, id.ImageKey, id.Arch, id.Variant
	return e, f.found
}

func (f *fakeImages) Ensure(_ time.Time, id imagestore.ImageID, fp imagestore.Fingerprint) imagestore.EnsureResult {
	f.mu.Lock()
	f.ensured = append(f.ensured, id)
	f.lastFP = fp
	f.mu.Unlock()
	return f.ensure
}

func (f *fakeImages) OpenGeneration(_ imagestore.ImageID, generation string) (*os.File, os.FileInfo, error) {
	fh, err := os.Open(f.filePath)
	if err != nil {
		return nil, nil, err
	}
	fi, err := fh.Stat()
	if err != nil {
		fh.Close()
		return nil, nil, err
	}
	return fh, fi, nil
}

func (f *fakeImages) ForceRefresh(id imagestore.ImageID) (bool, error) {
	if f.refreshErr != nil {
		return false, f.refreshErr
	}
	f.mu.Lock()
	f.refreshed = append(f.refreshed, id)
	f.mu.Unlock()
	return true, nil
}

func (f *fakeImages) RefreshAll() (int, error) {
	if f.refreshAllErr != nil {
		return 0, f.refreshAllErr
	}
	f.mu.Lock()
	f.refreshAll++
	f.mu.Unlock()
	return 3, nil
}

func (f *fakeImages) Delete(id imagestore.ImageID) error {
	f.mu.Lock()
	f.deleted = append(f.deleted, id)
	f.mu.Unlock()
	return nil
}

func (f *fakeImages) PrunePrevious(id imagestore.ImageID) (int, error) {
	f.mu.Lock()
	f.pruned = append(f.pruned, id)
	f.mu.Unlock()
	return 1, nil
}

func (f *fakeImages) Diagnostics(context.Context) imagestore.DiagnosticsReport {
	return imagestore.DiagnosticsReport{
		GOOS:   "linux",
		GOARCH: "amd64",
		BestEffort: []imagestore.FamilyStatus{
			{ImageKey: imagestore.KeyWindows11, Available: false, Reason: "Fido failed: exit status 147 (Error: This feature is not available on this platform.)"},
		},
	}
}

func (f *fakeImages) FidoTest(_ context.Context, arch string) (imagestore.FidoAttempt, error) {
	if arch != imagestore.ArchAMD64 && arch != imagestore.ArchARM64 {
		return imagestore.FidoAttempt{}, fmt.Errorf("no Fido architecture for %q", arch)
	}
	f.mu.Lock()
	f.fidoTests = append(f.fidoTests, arch)
	f.mu.Unlock()
	return imagestore.FidoAttempt{Arch: arch, ExitCode: 0, URL: "https://example.invalid/Win11.iso"}, nil
}

func newFake(t *testing.T) *fakeImages {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "artifact")
	if err := os.WriteFile(path, []byte("0123456789"), 0o644); err != nil {
		t.Fatal(err)
	}
	return &fakeImages{
		available: true,
		found:     true,
		filePath:  path,
		entry: imagestore.CatalogEntry{
			HostType: "ubuntu.kvm", ImageKey: "guest.ubuntu.server.26", Arch: "amd64", Variant: "stable",
			State: "fresh", Supported: true, Generation: "img.iso.aabbccddeeff", CurrentBytes: 10,
		},
		ensure: imagestore.EnsureResult{HTTPStatus: http.StatusOK, State: imagestore.StateReady},
	}
}

func newServer(t *testing.T, opts Options) (*httptest.Server, *fakeImages) {
	t.Helper()
	f := newFake(t)
	opts.Images = f
	if opts.Version == "" {
		opts.Version = "2026.08.07"
	}
	srv := httptest.NewServer(New(opts).Handler())
	t.Cleanup(srv.Close)
	return srv, f
}

func get(t *testing.T, srv *httptest.Server, path string) *http.Response {
	t.Helper()
	resp, err := srv.Client().Get(srv.URL + path)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func post(t *testing.T, srv *httptest.Server, path, bearer string, cookies []*http.Cookie) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, srv.URL+path, strings.NewReader(""))
	if err != nil {
		t.Fatal(err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	for _, c := range cookies {
		req.AddCookie(c)
	}
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func decodeBody(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	var m map[string]any
	b, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("body %q: %v", string(b), err)
	}
	return m
}

const (
	imgPath  = "/api/v1/images/ubuntu.kvm/guest.ubuntu.server.26"
	imgQuery = "?arch=amd64&variant=stable"
	labToken = "lab-auth-token-value"
	// labCode is a stand-in for what the dashboard's Lab token tile shows.
	labCode = "ab12cd"
)

func TestReadsAreOpenWithNoCredentialConfigured(t *testing.T) {
	srv, _ := newServer(t, Options{})
	for _, path := range []string{
		"/healthz",
		"/api/session",
		"/api/v1/status",
		"/api/v1/images",
		imgPath + imgQuery,
		// The byte route is fetched exactly as advertised: no query string. It
		// is identified by (hostType, imageKey, generation) and nothing else.
		imgPath + "/file/img.iso.aabbccddeeff",
	} {
		resp := get(t, srv, path)
		if resp.StatusCode != http.StatusOK {
			t.Errorf("GET %s = %d, want 200 (reads are unconditionally open)", path, resp.StatusCode)
		}
	}
}

func TestEnsureIsNeverGated(t *testing.T) {
	srv, f := newServer(t, Options{})
	resp := post(t, srv, imgPath+"/ensure"+imgQuery, "", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("ensure = %d, want 200: gating it would make a credential a prerequisite for fetching an image", resp.StatusCode)
	}
	if len(f.ensured) != 1 || f.ensured[0].ImageKey != "guest.ubuntu.server.26" {
		t.Fatalf("ensure did not reach the store: %+v", f.ensured)
	}
}

func TestEnsureAcceptsAFingerprintBodyAndAnEmptyOne(t *testing.T) {
	srv, f := newServer(t, Options{})
	req, _ := http.NewRequest(http.MethodPost, srv.URL+imgPath+"/ensure"+imgQuery,
		strings.NewReader(`{"filename":"img.iso","byteCount":42,"sha256":"abc"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("ensure with fingerprint = %d", resp.StatusCode)
	}
	if f.lastFP.Filename != "img.iso" || f.lastFP.ByteCount != 42 || f.lastFP.SHA256 != "abc" {
		t.Fatalf("fingerprint not decoded: %+v", f.lastFP)
	}
	// An empty body is how a host that holds nothing locally asks.
	if r := post(t, srv, imgPath+"/ensure"+imgQuery, "", nil); r.StatusCode != http.StatusOK {
		t.Fatalf("ensure with an empty body = %d", r.StatusCode)
	}
}

func TestMutationsAnswer503WhenNoCredentialIsConfigured(t *testing.T) {
	srv, f := newServer(t, Options{})
	for _, verb := range []string{"refresh", "delete", "prune"} {
		resp := post(t, srv, imgPath+"/"+verb+imgQuery, "", nil)
		if resp.StatusCode != http.StatusServiceUnavailable {
			t.Errorf("%s = %d, want 503", verb, resp.StatusCode)
		}
		body := decodeBody(t, resp)
		if body["reason"] != "auth-unconfigured" {
			t.Errorf("%s reason = %v, want auth-unconfigured", verb, body["reason"])
		}
		if body["ok"] != false {
			t.Errorf("%s ok = %v, want false", verb, body["ok"])
		}
	}
	if len(f.refreshed)+len(f.deleted)+len(f.pruned) != 0 {
		t.Fatal("an unconfigured gate must never let a mutation through")
	}
}

func TestPoolWideRefreshIsBearerOnly(t *testing.T) {
	// Lab-token unlock available, token absent: the pool-wide route still
	// refuses, because a phone session must not start a download for every entry
	// at once.
	srv, f := newServer(t, Options{AggregatorURL: "http://aggregator.invalid"})
	resp := post(t, srv, "/api/v1/refresh", "", nil)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("pool refresh with only the lab-token unlock = %d, want 503", resp.StatusCode)
	}
	if decodeBody(t, resp)["reason"] != "auth-unconfigured" {
		t.Fatal("the refusal must carry the machine-readable reason")
	}

	srv2, f2 := newServer(t, Options{AuthToken: labToken})
	if r := post(t, srv2, "/api/v1/refresh", "", nil); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("pool refresh with no bearer = %d, want 401", r.StatusCode)
	}
	if r := post(t, srv2, "/api/v1/refresh", labToken, nil); r.StatusCode != http.StatusAccepted {
		t.Fatalf("pool refresh with the bearer = %d, want 202", r.StatusCode)
	}
	if f2.refreshAll != 1 {
		t.Fatalf("RefreshAll called %d times, want 1", f2.refreshAll)
	}
	if f.refreshAll != 0 {
		t.Fatal("the refused call must not have reached the store")
	}
}

func TestBearerGatesThePerImageMutations(t *testing.T) {
	srv, f := newServer(t, Options{AuthToken: labToken})

	if r := post(t, srv, imgPath+"/refresh"+imgQuery, "", nil); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no bearer = %d, want 401", r.StatusCode)
	}
	if r := post(t, srv, imgPath+"/refresh"+imgQuery, "wrong-token", nil); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong bearer = %d, want 401", r.StatusCode)
	}
	if r := post(t, srv, imgPath+"/refresh"+imgQuery, labToken, nil); r.StatusCode != http.StatusAccepted {
		t.Fatalf("correct bearer = %d, want 202", r.StatusCode)
	}
	if r := post(t, srv, imgPath+"/delete"+imgQuery, labToken, nil); r.StatusCode != http.StatusOK {
		t.Fatalf("delete = %d, want 200", r.StatusCode)
	}
	if r := post(t, srv, imgPath+"/prune"+imgQuery, labToken, nil); r.StatusCode != http.StatusOK {
		t.Fatalf("prune = %d, want 200", r.StatusCode)
	}
	if len(f.refreshed) != 1 || len(f.deleted) != 1 || len(f.pruned) != 1 {
		t.Fatalf("mutations did not reach the store: %+v %+v %+v", f.refreshed, f.deleted, f.pruned)
	}
	want := imagestore.ImageID{HostType: "ubuntu.kvm", ImageKey: "guest.ubuntu.server.26", Arch: "amd64", Variant: "stable"}
	if f.refreshed[0] != want {
		t.Fatalf("identity = %+v, want %+v", f.refreshed[0], want)
	}
}

func TestSessionRouteReportsWhichGatesExist(t *testing.T) {
	// The UI renders one of three things from this: the lab token prompt, "only
	// automation can mutate", or "nothing is configured".
	srv, _ := newServer(t, Options{})
	body := decodeBody(t, get(t, srv, "/api/session"))
	if body["configured"] != false || body["labToken"] != false || body["bearer"] != false {
		t.Fatalf("unconfigured session = %+v", body)
	}

	srv2, _ := newServer(t, Options{AggregatorURL: "http://aggregator.invalid", AuthToken: labToken})
	body2 := decodeBody(t, get(t, srv2, "/api/session"))
	if body2["configured"] != true || body2["labToken"] != true || body2["bearer"] != true {
		t.Fatalf("configured session = %+v", body2)
	}
	if body2["authed"] != false {
		t.Fatal("a request with no credential must not report authed")
	}

	// Bearer alone: there is a gate, but nothing an operator can type.
	srv3, _ := newServer(t, Options{AuthToken: labToken})
	body3 := decodeBody(t, get(t, srv3, "/api/session"))
	if body3["configured"] != true || body3["labToken"] != false || body3["bearer"] != true {
		t.Fatalf("bearer-only session = %+v", body3)
	}
}

func TestIdentityValidationRefusesOutOfSetSegments(t *testing.T) {
	srv, _ := newServer(t, Options{AuthToken: labToken})
	cases := []string{
		"/api/v1/images/linux.qemu/guest.ubuntu.server.26?arch=amd64&variant=stable",
		imgPath + "?arch=riscv&variant=stable",
		imgPath + "?arch=amd64&variant=nightly",
		imgPath,
	}
	for _, path := range cases {
		if r := get(t, srv, path); r.StatusCode != http.StatusBadRequest {
			t.Errorf("GET %s = %d, want 400", path, r.StatusCode)
		}
	}
	// variant defaults to stable, so a client that does not care may omit it.
	if r := get(t, srv, imgPath+"?arch=amd64"); r.StatusCode != http.StatusOK {
		t.Errorf("omitted variant = %d, want 200 (defaults to stable)", r.StatusCode)
	}
}

func TestFileRouteServesRangesAndRefusesMetadataNames(t *testing.T) {
	srv, _ := newServer(t, Options{})
	req, _ := http.NewRequest(http.MethodGet, srv.URL+imgPath+"/file/img.iso.aabbccddeeff", nil)
	req.Header.Set("Range", "bytes=2-5")
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		t.Fatalf("ranged fetch = %d, want 206 (http.ServeContent gives hosts resume)", resp.StatusCode)
	}
	b, _ := io.ReadAll(resp.Body)
	if string(b) != "2345" {
		t.Fatalf("range body = %q, want 2345", string(b))
	}

	if r := get(t, srv, imgPath+"/file/img.iso.aabbccddeeff.meta.json"); r.StatusCode != http.StatusBadRequest {
		t.Fatalf("a sidecar name = %d, want 400: metadata is not servable as bytes", r.StatusCode)
	}
	if r := get(t, srv, "/api/v1/images/linux.qemu/guest.ubuntu.server.26/file/img.iso.aabbccddeeff"); r.StatusCode != http.StatusBadRequest {
		t.Fatalf("an out-of-set host type = %d, want 400", r.StatusCode)
	}
}

// TestTheAdvertisedFileUrlIsFetchableVerbatim drives the real pool engine, not
// the fake. What it guards is the seam between the URL the catalog mints and the
// route that answers it, and only fetching exactly what the API handed out
// exercises that seam -- a fake on either side would agree with itself.
func TestTheAdvertisedFileUrlIsFetchableVerbatim(t *testing.T) {
	poolDir := t.TempDir()
	id := imagestore.ImageID{HostType: "ubuntu.kvm", ImageKey: "guest.ubuntu.server.26", Arch: "amd64", Variant: "stable"}
	artifact := []byte("bytes standing in for a multi-gigabyte ISO")

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	agent, err := imagestore.NewAgent(ctx, imagestore.Options{PoolDir: poolDir, Now: time.Now})
	if err != nil {
		t.Fatalf("NewAgent: %v", err)
	}
	store := agent.Store()
	gen := imagestore.GenerationName("img.iso", "abcdef0123456789")
	if err := os.MkdirAll(store.Dir(id), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store.Dir(id), gen), artifact, 0o644); err != nil {
		t.Fatal(err)
	}
	stamp := time.Now().UTC().Format(time.RFC3339)
	err = store.Commit(id, gen, imagestore.Sidecar{
		ImageKey: id.ImageKey, HostType: id.HostType, Arch: id.Arch, Variant: id.Variant,
		UpstreamFilename: "img.iso", ByteCount: int64(len(artifact)), SHA256: "abcdef0123456789",
		DownloadedAt: stamp, LastVerifiedAt: stamp,
	})
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}

	srv := httptest.NewServer(New(Options{Images: agent, Version: "2026.08.07"}).Handler())
	t.Cleanup(srv.Close)

	catalog := decodeBody(t, get(t, srv, "/api/v1/images"))
	fileURL := ""
	for _, row := range catalog["images"].([]any) {
		if u, _ := row.(map[string]any)["fileUrl"].(string); u != "" {
			fileURL = u
		}
	}
	if fileURL == "" {
		t.Fatal("the catalog advertised no fileUrl for the committed generation")
	}

	resp := get(t, srv, fileURL)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s = %d, want 200: a client fetches the advertised URL verbatim", fileURL, resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if string(body) != string(artifact) {
		t.Fatalf("the advertised URL served %d bytes, want %d", len(body), len(artifact))
	}
}

func TestMetadataRouteAnswers404WhenTheEntryIsAbsent(t *testing.T) {
	srv, f := newServer(t, Options{})
	f.found = false
	if r := get(t, srv, imgPath+imgQuery); r.StatusCode != http.StatusNotFound {
		t.Fatalf("absent entry = %d, want 404", r.StatusCode)
	}
}

func TestRefreshRefusalRelaysTheReason(t *testing.T) {
	srv, f := newServer(t, Options{AuthToken: labToken})
	f.refreshErr = errLeaseReadOnly{}
	resp := post(t, srv, imgPath+"/refresh"+imgQuery, labToken, nil)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("refused refresh = %d, want 503", resp.StatusCode)
	}
	if decodeBody(t, resp)["reason"] != imagestore.ReasonLeaseReadOnly {
		t.Fatal("the refusal must carry a machine-readable reason")
	}
}

type errLeaseReadOnly struct{}

func (errLeaseReadOnly) Error() string { return imagestore.ReasonLeaseReadOnly }

func TestARefusalNeverRelaysARawFilesystemError(t *testing.T) {
	// The reason is a fixed machine-readable token. A raw error would break that
	// contract and echo the pool's UNC path from a route the caller reached with
	// only a bearer token.
	poolPath := `\\nas\yuruna-pool\images`
	srv, f := newServer(t, Options{AuthToken: labToken})
	f.refreshErr = errors.New("open " + poolPath + ": permission denied")
	f.refreshAllErr = errors.New("readdir " + poolPath + ": input/output error")

	for _, path := range []string{imgPath + "/refresh" + imgQuery, "/api/v1/refresh"} {
		resp := post(t, srv, path, labToken, nil)
		if resp.StatusCode != http.StatusServiceUnavailable {
			t.Errorf("POST %s = %d, want 503", path, resp.StatusCode)
		}
		body := decodeBody(t, resp)
		if body["reason"] != imagestore.ReasonPoolWalkFailed {
			t.Errorf("POST %s reason = %v, want %q", path, body["reason"], imagestore.ReasonPoolWalkFailed)
		}
		if msg, _ := body["error"].(string); strings.Contains(msg, poolPath) {
			t.Errorf("POST %s leaked the pool path in %q", path, msg)
		}
	}
}

func TestAnUnsupportedFamilyAnswersTheSameCodeEverywhere(t *testing.T) {
	// ensure answers 404 for a family the agent has no resolver for; a mutating
	// route answering 503 for the same cause makes a client tell one condition
	// apart from itself.
	srv, f := newServer(t, Options{AuthToken: labToken})
	f.refreshErr = errors.New(imagestore.ReasonUnsupported)
	resp := post(t, srv, imgPath+"/refresh"+imgQuery, labToken, nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("refresh of an unsupported family = %d, want 404 (ensure's answer for the same condition)", resp.StatusCode)
	}
	if decodeBody(t, resp)["reason"] != imagestore.ReasonUnsupported {
		t.Fatal("the refusal must still carry the machine-readable reason")
	}
}

func TestApiResponsesAreNotCached(t *testing.T) {
	srv, _ := newServer(t, Options{})
	for _, path := range []string{"/api/v1/status", "/api/v1/images", imgPath + imgQuery} {
		resp := get(t, srv, path)
		if got := resp.Header.Get("Cache-Control"); got != "no-store" {
			t.Errorf("GET %s Cache-Control = %q, want no-store", path, got)
		}
	}
}

func TestUIPageAndAssetsAreEmbedded(t *testing.T) {
	srv, _ := newServer(t, Options{})
	page := get(t, srv, "/")
	if page.StatusCode != http.StatusOK {
		t.Fatalf("GET / = %d", page.StatusCode)
	}
	csp := page.Header.Get("Content-Security-Policy")
	if !strings.Contains(csp, "script-src 'self'") {
		t.Fatalf("CSP = %q", csp)
	}
	if strings.Contains(csp, "'unsafe-inline'") {
		t.Fatalf("CSP = %q: nothing here needs inline anything, and the allowance only widens what an injection could do", csp)
	}
	body, _ := io.ReadAll(page.Body)
	if strings.Contains(string(body), "style=") {
		t.Fatal("the page carries an inline style attribute the CSP now blocks")
	}
	for _, want := range []string{"/assets/style.css", "/assets/common.js", "/assets/sort.js", "/assets/images.js"} {
		if !strings.Contains(string(body), want) {
			t.Errorf("the page does not reference %s", want)
		}
		r := get(t, srv, want)
		if r.StatusCode != http.StatusOK {
			t.Errorf("GET %s = %d, want 200 (assets must be embedded, never external)", want, r.StatusCode)
			continue
		}
		asset, _ := io.ReadAll(r.Body)
		// A style="" attribute set from script is governed by style-src just as
		// a literal one is; only a CSSOM assignment is not.
		if strings.Contains(string(asset), "{ style:") || strings.Contains(string(asset), "'style'") {
			t.Errorf("%s builds a style attribute, which style-src 'self' blocks", want)
		}
	}
}

// The ordering itself happens in the browser, so what is checkable here is the
// contract the two shipped files have to agree on: which columns sort, that each
// one is reachable by keyboard and announces its direction, and that the state
// order is severity rather than the alphabet.
var (
	tableHeaderRE = regexp.MustCompile(`(?s)<th\b([^>]*)>(.*?)</th>`)
	sortColumnRE  = regexp.MustCompile(`data-sort="([a-z]+)"`)
	jsColumnsRE   = regexp.MustCompile(`(?s)S\.columns\s*=\s*\[(.*?)\]`)
	jsStateRankRE = regexp.MustCompile(`(?s)S\.stateRank\s*=\s*\{(.*?)\}`)
	jsNameRE      = regexp.MustCompile(`'([a-z]+)'`)
	jsKeyRE       = regexp.MustCompile(`([a-z]+)\s*:`)
)

func TestEveryColumnButActionsSortsAndSaysSoAccessibly(t *testing.T) {
	srv, _ := newServer(t, Options{})
	page, _ := io.ReadAll(get(t, srv, "/").Body)

	want := []string{"state", "image", "artifact", "size", "verified", "checksum", "source"}
	var declared []string
	unsortable := 0
	for _, th := range tableHeaderRE.FindAllStringSubmatch(string(page), -1) {
		attrs, inner := th[1], th[2]
		col := sortColumnRE.FindStringSubmatch(attrs)
		if col == nil {
			unsortable++
			if !strings.Contains(inner, "Actions") {
				t.Errorf("header %q neither sorts nor is Actions", strings.TrimSpace(inner))
			}
			continue
		}
		declared = append(declared, col[1])
		if !strings.Contains(attrs, `aria-sort="none"`) {
			t.Errorf("column %q ships without an initial aria-sort", col[1])
		}
		// A real button, so Enter and Space work without this page
		// reimplementing key handling.
		if !strings.Contains(inner, "<button type=\"button\"") {
			t.Errorf("column %q header is not keyboard-activatable", col[1])
		}
	}
	if strings.Join(declared, ",") != strings.Join(want, ",") {
		t.Fatalf("sortable columns = %v, want %v", declared, want)
	}
	if unsortable != 1 {
		t.Fatalf("%d headers do not sort, want exactly 1 (Actions)", unsortable)
	}
}

func TestTheComparatorsCoverTheSameColumnsAndRankStatesBySeverity(t *testing.T) {
	srv, _ := newServer(t, Options{})
	asset, _ := io.ReadAll(get(t, srv, "/assets/sort.js").Body)
	js := string(asset)

	cols := jsColumnsRE.FindStringSubmatch(js)
	if cols == nil {
		t.Fatal("sort.js declares no column list")
	}
	var got []string
	for _, m := range jsNameRE.FindAllStringSubmatch(cols[1], -1) {
		got = append(got, m[1])
	}
	want := []string{"state", "image", "artifact", "size", "verified", "checksum", "source"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("sort.js columns = %v, want the table's %v", got, want)
	}

	rank := jsStateRankRE.FindStringSubmatch(js)
	if rank == nil {
		t.Fatal("sort.js declares no state ranking")
	}
	var states []string
	for _, m := range jsKeyRE.FindAllStringSubmatch(rank[1], -1) {
		states = append(states, m[1])
	}
	// Severity order: the row that needs an operator comes first.
	wantStates := []string{
		imagestore.StateFailed, imagestore.StateDownloading, imagestore.StateUnavailable,
		imagestore.StateAbsent, imagestore.StateStale, imagestore.StateFresh,
	}
	if strings.Join(states, ",") != strings.Join(wantStates, ",") {
		t.Fatalf("state ranking = %v, want %v", states, wantStates)
	}
}

// --- diagnostics -------------------------------------------------------------

func TestDiagnosticsRouteIsOpenAndCarriesTheFamilyEvidence(t *testing.T) {
	// The page exists to explain "family unavailable" without SSH, so the read
	// must work with no credential at all.
	srv, _ := newServer(t, Options{})
	resp := get(t, srv, "/api/v1/diagnostics")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/v1/diagnostics = %d, want 200 with no credential", resp.StatusCode)
	}
	var body struct {
		OK          bool `json:"ok"`
		Diagnostics struct {
			GOOS       string `json:"goos"`
			BestEffort []struct {
				ImageKey  string `json:"imageKey"`
				Available bool   `json:"available"`
				Reason    string `json:"reason"`
			} `json:"bestEffort"`
		} `json:"diagnostics"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if !body.OK || body.Diagnostics.GOOS == "" {
		t.Fatalf("body = %+v, want ok with the environment facts", body)
	}
	fam := body.Diagnostics.BestEffort[0]
	if fam.ImageKey != imagestore.KeyWindows11 || fam.Available || !strings.Contains(fam.Reason, "147") {
		t.Fatalf("family = %+v, want the unavailable reason relayed verbatim", fam)
	}
}

func TestFidoTestRouteIsGatedAndRunsOneResolve(t *testing.T) {
	srv, f := newServer(t, Options{AuthToken: labToken})

	if r := post(t, srv, "/api/v1/diagnostics/fido-test?arch=amd64", "", nil); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no credential = %d, want 401", r.StatusCode)
	}
	if r := post(t, srv, "/api/v1/diagnostics/fido-test?arch=amd64", "wrong-token", nil); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong bearer = %d, want 401", r.StatusCode)
	}
	if len(f.fidoTests) != 0 {
		t.Fatal("a refused call must not have run the resolver")
	}

	if r := post(t, srv, "/api/v1/diagnostics/fido-test", labToken, nil); r.StatusCode != http.StatusBadRequest {
		t.Fatalf("no arch = %d, want 400", r.StatusCode)
	}
	if r := post(t, srv, "/api/v1/diagnostics/fido-test?arch=x86", labToken, nil); r.StatusCode != http.StatusBadRequest {
		t.Fatalf("unknown arch = %d, want 400", r.StatusCode)
	}

	resp := post(t, srv, "/api/v1/diagnostics/fido-test?arch=amd64", labToken, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("authorized test = %d, want 200", resp.StatusCode)
	}
	var body struct {
		OK      bool `json:"ok"`
		Attempt struct {
			Arch string `json:"arch"`
			URL  string `json:"url"`
		} `json:"attempt"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if !body.OK || body.Attempt.URL == "" {
		t.Fatalf("body = %+v, want the attempt capture attached", body)
	}
	if len(f.fidoTests) != 1 || f.fidoTests[0] != imagestore.ArchAMD64 {
		t.Fatalf("resolver ran for %v, want exactly one amd64 run", f.fidoTests)
	}
}

func TestDiagnosticsPageServesWithTheMenuWiredBothWays(t *testing.T) {
	srv, _ := newServer(t, Options{})
	resp := get(t, srv, "/diagnostics")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /diagnostics = %d, want 200", resp.StatusCode)
	}
	page, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"/assets/diagnostics.js", "Resolver test"} {
		if !strings.Contains(string(page), want) {
			t.Fatalf("diagnostics.html misses %q", want)
		}
	}
	js := get(t, srv, "/assets/diagnostics.js")
	jb, err := io.ReadAll(js.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(jb), "/api/v1/diagnostics/fido-test") {
		t.Fatal("diagnostics.js does not drive the resolver-test route")
	}
	// Each page must link the other, or the only way between them is the URL bar.
	index := get(t, srv, "/")
	ib, err := io.ReadAll(index.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(ib), `href="/diagnostics"`) {
		t.Fatal("index.html has no menu link to the diagnostics page")
	}
	if !strings.Contains(string(page), `href="/"`) {
		t.Fatal("diagnostics.html has no menu link back to the pool page")
	}
}
