// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"download-agent-service/internal/config"
)

const rfc3339 = time.RFC3339

var fixedNow = time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)

func newTestAgent(t *testing.T, opts Options) *Agent {
	t.Helper()
	if opts.ScanInterval == 0 {
		opts.ScanInterval = 15 * time.Minute
	}
	if opts.Freshness == 0 {
		opts.Freshness = 24 * time.Hour
	}
	if opts.PrefetchLead == 0 {
		opts.PrefetchLead = 2 * time.Hour
	}
	if opts.Now == nil {
		opts.Now = func() time.Time { return fixedNow }
	}
	if opts.PoolDir != "" {
		// Stand in for a mounted pool share. Availability is stat-only by
		// design, so a pool dir with no images root reads as "not mounted" --
		// which is what the unmounted-share test below relies on.
		if err := os.MkdirAll(config.ImagesDirFor(opts.PoolDir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	a, err := NewAgent(ctx, opts)
	if err != nil {
		t.Fatalf("NewAgent: %v", err)
	}
	a.lease.ConfirmDelay = 0
	return a
}

// fixtureTransport routes every request to an in-process server regardless of
// the host the resolver named. It is what keeps the suite hermetic: without it a
// refresh reaches releases.ubuntu.com for real and pulls a multi-gigabyte ISO
// into the test's temp directory, and the suite fails on an offline build VM.
type fixtureTransport struct {
	base http.RoundTripper
	host string
}

func (f fixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	c := r.Clone(r.Context())
	c.URL.Scheme, c.URL.Host, c.Host = "http", f.host, ""
	return f.base.RoundTrip(c)
}

// failingTransport stands in for an origin that cannot be reached at all, and
// counts the attempts so a back-off can be asserted rather than assumed.
type failingTransport struct {
	err   error
	calls atomic.Int64
}

func (f *failingTransport) RoundTrip(*http.Request) (*http.Response, error) {
	f.calls.Add(1)
	return nil, f.err
}

func TestScannerWindowBoundaries(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Freshness: 24 * time.Hour, PrefetchLead: 2 * time.Hour})
	verified := time.Date(2026, 8, 3, 0, 0, 0, 0, time.UTC)
	sc := &Sidecar{LastVerifiedAt: verified.Format(rfc3339)}
	// The scanner acts at lastVerifiedAt + freshness - prefetchLead = +22h.
	boundary := verified.Add(22 * time.Hour)

	cases := []struct {
		name string
		now  time.Time
		want bool
	}{
		{"one hour inside the window", boundary.Add(-time.Hour), false},
		{"one second before the boundary", boundary.Add(-time.Second), false},
		{"exactly at the boundary", boundary, true},
		{"one second after the boundary", boundary.Add(time.Second), true},
		{"already expired", verified.Add(30 * time.Hour), true},
	}
	for _, tc := range cases {
		if got := a.DueForRefresh(sc, tc.now); got != tc.want {
			t.Errorf("%s: DueForRefresh = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestFreshnessBoundary(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Freshness: 24 * time.Hour, PrefetchLead: 2 * time.Hour})
	verified := time.Date(2026, 8, 3, 0, 0, 0, 0, time.UTC)
	sc := &Sidecar{LastVerifiedAt: verified.Format(rfc3339)}
	expiry := verified.Add(24 * time.Hour)

	if !a.IsFresh(sc, expiry.Add(-time.Second)) {
		t.Error("an entry one second before expiry is still fresh")
	}
	if a.IsFresh(sc, expiry) {
		t.Error("an entry at exactly lastVerifiedAt + freshness has expired")
	}
	if a.IsFresh(sc, expiry.Add(time.Second)) {
		t.Error("an entry past expiry is stale")
	}
}

func TestMissingOrUnparseableStampIsAlwaysDue(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	if !a.DueForRefresh(nil, fixedNow) {
		t.Error("an entry with no sidecar must be due")
	}
	if !a.DueForRefresh(&Sidecar{}, fixedNow) {
		t.Error("an entry with no lastVerifiedAt must be due")
	}
	if !a.DueForRefresh(&Sidecar{LastVerifiedAt: "not a timestamp"}, fixedNow) {
		t.Error("an unparseable stamp must be treated as due, never as fresh")
	}
	if a.IsFresh(&Sidecar{LastVerifiedAt: "not a timestamp"}, fixedNow) {
		t.Error("an unparseable stamp must never read as fresh")
	}
}

func TestSameOriginIsTheFourFieldComparison(t *testing.T) {
	base := &Sidecar{
		UpstreamFilename: "img.iso",
		SourceURL:        "https://example.invalid/a/img.iso",
		ByteCount:        1000,
		LastModified:     "Thu, 23 Jul 2026 09:14:02 GMT",
	}
	res := Resolved{UpstreamFilename: "img.iso", SourceURL: "https://example.invalid/a/img.iso"}

	if !sameOrigin(base, res, 1000, "Thu, 23 Jul 2026 09:14:02 GMT") {
		t.Error("an unchanged origin must compare equal")
	}
	if sameOrigin(base, Resolved{UpstreamFilename: "img2.iso", SourceURL: res.SourceURL}, 1000, base.LastModified) {
		t.Error("a changed filename must force a download")
	}
	if sameOrigin(base, Resolved{UpstreamFilename: "img.iso", SourceURL: "https://example.invalid/b/img.iso"}, 1000, base.LastModified) {
		t.Error("a changed URL must force a download")
	}
	if sameOrigin(base, res, 1001, base.LastModified) {
		t.Error("a changed Content-Length must force a download")
	}
	if sameOrigin(base, res, 1000, "Fri, 24 Jul 2026 00:00:00 GMT") {
		t.Error("a changed Last-Modified must force a download")
	}
	if !sameOrigin(base, res, 1000, "") {
		t.Error("Last-Modified is lenient when the origin omits it, mirroring the host guard")
	}
	if sameOrigin(base, res, -1, base.LastModified) {
		t.Error("a HEAD with no usable Content-Length must force a download")
	}
	if sameOrigin(nil, res, 1000, base.LastModified) {
		t.Error("no sidecar can never compare equal")
	}
}

// originServer serves one artifact plus a SHA256SUMS entry for it.
func originServer(t *testing.T, name string, body []byte, publishedSHA string, lastMod string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/" + name:
			if lastMod != "" {
				w.Header().Set("Last-Modified", lastMod)
			}
			if r.Method == http.MethodHead {
				w.Header().Set("Content-Length", itoa(len(body)))
				w.WriteHeader(http.StatusOK)
				return
			}
			_, _ = w.Write(body)
		case "/SHA256SUMS":
			if publishedSHA == "" {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			_, _ = w.Write([]byte(publishedSHA + " *" + name + "\n"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func TestDownloadVerifyPromoteCommitRoundTrip(t *testing.T) {
	body := []byte("an artifact that stands in for a multi-gigabyte ISO")
	sha := sha256Hex(body)
	srv := originServer(t, "img.iso", body, sha, "Thu, 23 Jul 2026 09:14:02 GMT")

	a := newTestAgent(t, Options{PoolDir: t.TempDir(), AgentVersion: "2026.08.06"})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	res := Resolved{
		Family: FamilyUbuntuISO, UpstreamFilename: "img.iso",
		SourceURL: srv.URL + "/img.iso", ChecksumURL: srv.URL + "/SHA256SUMS",
		ChecksumFormat: ChecksumSHA256SUMS, ChecksumTarget: "img.iso", Variant: VariantStable,
	}

	size, lastMod, err := a.probe(context.Background(), res.SourceURL)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if size != int64(len(body)) || lastMod == "" {
		t.Fatalf("probe returned size=%d lastMod=%q", size, lastMod)
	}

	staged, err := a.store.NewStagingPath(id, res.UpstreamFilename)
	if err != nil {
		t.Fatal(err)
	}
	p := &Progress{}
	gotSHA, written, err := a.downloadTo(context.Background(), res.SourceURL, staged, p)
	if err != nil {
		t.Fatalf("downloadTo: %v", err)
	}
	if gotSHA != sha || written != int64(len(body)) {
		t.Fatalf("download produced sha=%s bytes=%d", gotSHA, written)
	}
	if snap := p.Snapshot(); snap.Done != int64(len(body)) {
		t.Fatalf("progress counted %d bytes, want %d", snap.Done, len(body))
	}

	verdict, err := a.verifyChecksum(context.Background(), res, gotSHA)
	if err != nil {
		t.Fatalf("verifyChecksum: %v", err)
	}
	if verdict != VerdictVerified {
		t.Fatalf("verdict = %q, want verified", verdict)
	}

	gen := GenerationName(res.UpstreamFilename, gotSHA)
	if err := a.store.PromoteStaging(id, staged, gen); err != nil {
		t.Fatalf("PromoteStaging: %v", err)
	}
	stamp := fixedNow.UTC().Format(rfc3339)
	err = a.store.Commit(id, gen, Sidecar{
		ImageKey: id.ImageKey, HostType: id.HostType, Arch: id.Arch, Variant: id.Variant,
		SourceURL: res.SourceURL, UpstreamFilename: res.UpstreamFilename,
		ByteCount: written, LastModified: lastMod, SHA256: gotSHA,
		ChecksumVerdict: verdict, DownloadedAt: stamp, LastVerifiedAt: stamp,
		AgentVersion: a.opts.AgentVersion,
	})
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}

	entry, found := a.Entry(fixedNow, id)
	if !found {
		t.Fatal("the committed entry is not visible in the catalog")
	}
	if entry.State != StateFresh {
		t.Fatalf("state = %q, want fresh", entry.State)
	}
	// The advertised URL is the byte route for this generation and carries no
	// query string: the identity that names bytes is (hostType, imageKey,
	// generation), and a client is expected to fetch exactly what it is handed.
	if got, want := entry.FileURL, "/api/v1/images/"+id.HostType+"/"+id.ImageKey+"/file/"+url.PathEscape(gen); got != want {
		t.Fatalf("fileUrl = %q, want %q", got, want)
	}
	if strings.Contains(entry.FileURL, "?") {
		t.Fatalf("fileUrl %q carries a query string; the byte route must be fetchable verbatim", entry.FileURL)
	}
	if entry.ChecksumVerdict != VerdictVerified || entry.SHA256 != sha {
		t.Fatalf("entry metadata = %+v", entry)
	}
}

func TestChecksumMismatchIsARefusal(t *testing.T) {
	body := []byte("payload")
	srv := originServer(t, "img.iso", body, sha256Hex([]byte("something else entirely")), "")
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	res := Resolved{UpstreamFilename: "img.iso", SourceURL: srv.URL + "/img.iso",
		ChecksumURL: srv.URL + "/SHA256SUMS", ChecksumFormat: ChecksumSHA256SUMS, ChecksumTarget: "img.iso"}

	if _, err := a.verifyChecksum(context.Background(), res, sha256Hex(body)); err == nil {
		t.Fatal("a checksum mismatch must be an error so the generation is discarded")
	}
}

func TestUnpublishedChecksumIsASoftPass(t *testing.T) {
	srv := originServer(t, "img.iso", []byte("payload"), "", "")
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	res := Resolved{UpstreamFilename: "img.iso", SourceURL: srv.URL + "/img.iso",
		ChecksumURL: srv.URL + "/SHA256SUMS", ChecksumFormat: ChecksumSHA256SUMS, ChecksumTarget: "img.iso"}

	verdict, err := a.verifyChecksum(context.Background(), res, sha256Hex([]byte("payload")))
	if err != nil {
		t.Fatalf("a 404 on the checksum file is a soft pass: %v", err)
	}
	if verdict != VerdictUnpublished {
		t.Fatalf("verdict = %q, want unpublished", verdict)
	}

	noChecksum, err := a.verifyChecksum(context.Background(), Resolved{UpstreamFilename: "x"}, "abc")
	if err != nil || noChecksum != VerdictNone {
		t.Fatalf("a family with no checksum source: verdict=%q err=%v", noChecksum, err)
	}
}

func TestEnsureAnswersImmediatelyWhenTheHostAlreadyHoldsTheBytes(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	// Deliberately stamped stale, to prove the local-current answer is
	// independent of freshness age.
	mustCommit(t, a.store, id, "img.iso", "1111111111111111", 42, fixedNow.Add(-72*time.Hour))

	res := a.Ensure(fixedNow, id, Fingerprint{SHA256: "1111111111111111"})
	if res.HTTPStatus != http.StatusOK || res.State != StateReady || !res.LocalCurrent {
		t.Fatalf("ensure = %+v, want 200 ready localCurrent", res)
	}
	if a.flights.Len() != 0 {
		t.Fatal("a local-current answer must not start a refresh the host will never wait for")
	}
}

func TestEnsureMatchesOnFilenameAndSizeWhenNoHashIsSent(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	mustCommit(t, a.store, id, "img.iso", "2222222222222222", 42, fixedNow)

	res := a.Ensure(fixedNow, id, Fingerprint{Filename: "img.iso", ByteCount: 42})
	if !res.LocalCurrent {
		t.Fatalf("a filename + byte-count fingerprint must match: %+v", res)
	}
	miss := a.Ensure(fixedNow, id, Fingerprint{Filename: "img.iso", ByteCount: 43})
	if miss.LocalCurrent {
		t.Fatal("a differing byte count must not report localCurrent")
	}
}

func TestEnsureServesTheFreshEntryWithoutStartingWork(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	mustCommit(t, a.store, id, "img.iso", "3333333333333333", 42, fixedNow.Add(-time.Hour))

	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.HTTPStatus != http.StatusOK || res.State != StateReady || res.Stale {
		t.Fatalf("ensure = %+v, want a plain 200 ready", res)
	}
	if a.flights.Len() != 0 {
		t.Fatal("a fresh entry must not start a refresh")
	}
}

func TestEnsureServesThePreviousGenerationWhileStale(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	gen := mustCommit(t, a.store, id, "img.iso", "4444444444444444", 42, fixedNow.Add(-48*time.Hour))

	// A refresh that is already running is joined, never duplicated, and holding
	// it open here is what makes the answer deterministic: the pointer cannot
	// flip underneath the assertions, and no request leaves the process.
	release := make(chan struct{})
	defer close(release)
	running := make(chan struct{})
	a.flights.Start(id.Key(), false, func(ctx context.Context, p *Progress) error {
		close(running)
		<-release
		return nil
	})
	<-running

	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.HTTPStatus != http.StatusOK || res.State != StateReady || !res.Stale {
		t.Fatalf("ensure = %+v, want 200 ready stale", res)
	}
	if res.Image.Generation != gen {
		t.Fatalf("a stale answer must still name the previous verified generation, got %q", res.Image.Generation)
	}
	if !res.RefreshInFlight {
		t.Fatal("a stale answer must report the refresh it joined")
	}
	if a.flights.Len() != 1 {
		t.Fatalf("ensure started a second flight for one identity: %d live", a.flights.Len())
	}
}

func TestStaleEnsureInLeaseReadOnlyModeClaimsNoRefresh(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	mustCommit(t, a.store, id, "img.iso", "8888888888888888", 42, fixedNow.Add(-48*time.Hour))
	writeLease(t, a.lease.Path, Lease{HostID: "another-agent", RenewedAtUTC: fixedNow.UTC().Format(rfc3339)})
	if _, _, err := a.lease.Renew(fixedNow); err != nil {
		t.Fatal(err)
	}

	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.State != StateReady || !res.Stale {
		t.Fatalf("ensure = %+v, want the previous generation served", res)
	}
	if res.RefreshInFlight {
		t.Fatal("a follower must not announce a refresh it defers to the lease holder and will never run")
	}
	if res.Reason != ReasonLeaseReadOnly {
		t.Fatalf("reason = %q, want %q so a client can tell why nothing is refreshing", res.Reason, ReasonLeaseReadOnly)
	}
	if a.flights.Len() != 0 {
		t.Fatal("a read-only agent must not start the refresh")
	}
}

func TestAFailedFirstDownloadIsReportedFailedAndNotRestartedEveryPoll(t *testing.T) {
	ft := &failingTransport{err: errors.New("dial tcp: connection refused")}
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Transport: ft})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}

	drain := func() {
		if f, live := a.flights.Lookup(id.Key()); live {
			<-f.Done()
		}
	}
	a.Ensure(fixedNow, id, Fingerprint{})
	drain()
	attempts := ft.calls.Load()
	if attempts == 0 {
		t.Fatal("the first ensure must actually reach for the origin")
	}

	// The flight is gone, but the failure is remembered. A poll inside the
	// back-off window must say so rather than silently starting a fresh download
	// against a dead origin -- otherwise the client only ever sees 202 for its
	// whole budget and every host re-hammers the origin on every poll.
	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.State != StateFailed {
		t.Fatalf("second poll = %+v, want state failed", res)
	}
	if res.Error == "" {
		t.Fatal("a failed answer must carry the origin error so the host can log why it is falling back")
	}
	if a.flights.Len() != 0 {
		t.Fatalf("the poll started %d new download(s) inside the back-off window", a.flights.Len())
	}
	if got := ft.calls.Load(); got != attempts {
		t.Fatalf("a poll inside the back-off window made %d more origin request(s)", got-attempts)
	}

	// Past the window the agent tries again: a dead origin is not permanent.
	a.Ensure(fixedNow.Add(firstDownloadBackoff+time.Second), id, Fingerprint{})
	drain()
	if ft.calls.Load() <= attempts {
		t.Fatal("the back-off must expire; a later poll has to retry the origin")
	}
}

func TestUnmountedPoolIsUnavailableAndCreatesNothing(t *testing.T) {
	// A pool dir whose images root is absent is exactly what a failed CIFS mount
	// looks like from inside the guest: the mount point exists and is empty.
	poolDir := t.TempDir()
	a := newTestAgent(t, Options{PoolDir: poolDir})
	if err := os.Remove(config.ImagesDirFor(poolDir)); err != nil {
		t.Fatal(err)
	}

	if a.PoolAvailable() {
		t.Fatal("an unmounted share must report poolAvailable false")
	}
	if st := a.Status(fixedNow); st.PoolAvailable {
		t.Fatalf("status = %+v, want poolAvailable false", st)
	}
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.HTTPStatus != http.StatusServiceUnavailable || res.Reason != ReasonPoolUnavailable {
		t.Fatalf("ensure = %+v, want 503 pool-unavailable so hosts fall back", res)
	}
	// The availability probe must never create the images root: doing so on a
	// failed mount masks the mount point and sends multi-gigabyte artifacts to
	// the guest's own root filesystem.
	if _, err := os.Stat(config.ImagesDirFor(poolDir)); !os.IsNotExist(err) {
		t.Fatalf("the availability probe created the images root on the local disk: %v", err)
	}
}

func TestEnsureRefusesWhenThePoolIsUnavailable(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: ""})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.HTTPStatus != http.StatusServiceUnavailable || res.Reason != ReasonPoolUnavailable {
		t.Fatalf("ensure = %+v, want 503 pool-unavailable so hosts fall back", res)
	}
}

func TestEnsureRefusesAnUnsupportedFamily(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	id := ImageID{HostType: HostTypeKVM, ImageKey: "guest.no.such.family", Arch: ArchAMD64, Variant: VariantStable}
	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.HTTPStatus != http.StatusNotFound || res.Reason != ReasonUnsupported {
		t.Fatalf("ensure = %+v, want 404 unsupported-image", res)
	}
}

func TestEnsureDefersAFirstDownloadInLeaseReadOnlyMode(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	writeLease(t, a.lease.Path, Lease{HostID: "another-agent", RenewedAtUTC: fixedNow.UTC().Format(rfc3339)})
	if _, _, err := a.lease.Renew(fixedNow); err != nil {
		t.Fatal(err)
	}
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	res := a.Ensure(fixedNow, id, Fingerprint{})
	if res.HTTPStatus != http.StatusServiceUnavailable || res.Reason != ReasonLeaseReadOnly {
		t.Fatalf("ensure = %+v, want 503 lease-read-only", res)
	}
	if a.flights.Len() != 0 {
		t.Fatal("a read-only agent must defer downloads to the lease holder")
	}
}

func TestDeleteCancelsTheInFlightDownload(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	mustCommit(t, a.store, id, "img.iso", "5555555555555555", 8, fixedNow)

	observed := make(chan struct{})
	a.flights.Start(id.Key(), false, func(ctx context.Context, p *Progress) error {
		close(observed)
		<-ctx.Done()
		return ctx.Err()
	})
	<-observed

	if err := a.Delete(id); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if a.flights.Len() != 0 {
		t.Fatal("delete must cancel the download that would otherwise recreate what it removed")
	}
	if _, ok, _ := a.store.ReadPointer(id); ok {
		t.Fatal("delete must remove the pointer")
	}
}

func TestCatalogSynthesisesAbsentRowsForTheStableFamilies(t *testing.T) {
	// The Fido script is pinned at a path that does not exist, so the Windows
	// rows report the same thing on every machine rather than depending on
	// whether the one running the suite happens to have PowerShell installed.
	a := newTestAgent(t, Options{
		PoolDir: t.TempDir(),
		Fido:    FidoConfig{Script: filepath.Join(t.TempDir(), "Fido.ps1")},
	})
	images, totals := a.Catalog(fixedNow)
	// Three host types x four stable families, plus a row for every best-effort
	// family the host type can use, so the operator always has a row to act on
	// even before the first seed pass.
	want := len(CatalogTargets(HostTypes))
	if len(images) != want {
		t.Fatalf("catalog has %d rows, want %d", len(images), want)
	}
	for _, img := range images {
		switch {
		case img.ImageKey == KeyWindows11:
			if img.State != StateUnavailable || img.UnavailableReason == "" {
				t.Fatalf("row %s/%s = %q (%q), want an explained unavailable", img.HostType, img.ImageKey, img.State, img.UnavailableReason)
			}
		case img.State != StateAbsent:
			t.Fatalf("row %s/%s state = %q, want absent", img.HostType, img.ImageKey, img.State)
		}
	}
	if totals.Bytes != 0 || totals.Images != 0 {
		t.Fatalf("an empty pool must total zero: %+v", totals)
	}
}

func TestCatalogTotalsSplitCurrentAndPreviousPerHostType(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	mustCommit(t, a.store, id, "img.iso", "6666666666666666", 100, fixedNow.Add(-time.Hour))
	mustCommit(t, a.store, id, "img.iso", "7777777777777777", 250, fixedNow)

	_, totals := a.Catalog(fixedNow)
	if totals.CurrentBytes != 250 || totals.PreviousBytes != 100 || totals.Bytes != 350 {
		t.Fatalf("totals = %+v, want current=250 previous=100 bytes=350", totals)
	}
	if totals.ByHostType[HostTypeKVM] != 350 {
		t.Fatalf("per-hostType subtotal = %d, want 350", totals.ByHostType[HostTypeKVM])
	}
	if totals.Images != 1 {
		t.Fatalf("images = %d, want 1", totals.Images)
	}
}

func TestScanOnceSweepsStagingAndRecordsCadence(t *testing.T) {
	poolDir := t.TempDir()
	a := newTestAgent(t, Options{PoolDir: poolDir, AutoSeed: false, ScanInterval: 15 * time.Minute})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	staged, err := a.store.NewStagingPath(id, "img.iso")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staged, []byte("abandoned"), 0o644); err != nil {
		t.Fatal(err)
	}
	orphan := filepath.Join(filepath.Dir(staged), "amd64.stable.old.iso.999999")
	if err := os.WriteFile(orphan, []byte("abandoned"), 0o644); err != nil {
		t.Fatal(err)
	}

	a.ScanOnce(context.Background())

	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Error("the scan must sweep a dead-PID staging entry")
	}
	st := a.Status(fixedNow)
	if st.Scans != 1 {
		t.Fatalf("scans = %d, want 1", st.Scans)
	}
	if st.LastScanUTC != fixedNow.UTC().Format(rfc3339) {
		t.Fatalf("lastScanUtc = %q", st.LastScanUTC)
	}
	if st.NextScanUTC != fixedNow.Add(15*time.Minute).UTC().Format(rfc3339) {
		t.Fatalf("nextScanUtc = %q", st.NextScanUTC)
	}
	if st.ScanIntervalSeconds != 900 || st.FreshnessSeconds != 86400 || st.PrefetchLeadSeconds != 7200 {
		t.Fatalf("cadence = %+v, want the documented defaults", st)
	}
}

// serveArtifact answers the probe and the byte fetch for one fixture artifact.
// headSize overrides what HEAD reports, which is how an origin that lies about
// its own size is simulated.
func serveArtifact(w http.ResponseWriter, r *http.Request, body []byte, headSize int) {
	w.Header().Set("Last-Modified", "Thu, 23 Jul 2026 09:14:02 GMT")
	if r.Method == http.MethodHead {
		if headSize <= 0 {
			headSize = len(body)
		}
		w.Header().Set("Content-Length", itoa(headSize))
		w.WriteHeader(http.StatusOK)
		return
	}
	_, _ = w.Write(body)
}

// ubuntuFixture answers the whole Ubuntu-ISO pipeline in process: release index,
// daily probe, SHA256SUMS and bytes. daily=false makes the daily-live probe 404,
// which is what drives preference-with-fallback.
func ubuntuFixture(t *testing.T, body []byte, daily bool, headSize int) http.RoundTripper {
	t.Helper()
	const isoName = "ubuntu-26.04-live-server-amd64.iso"
	sum := sha256Hex(body)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.Contains(path, "/daily-live/"):
			if !daily {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			if strings.HasSuffix(path, "/SHA256SUMS") {
				_, _ = w.Write([]byte(sum + " *resolute-live-server-amd64.iso\n"))
				return
			}
			serveArtifact(w, r, body, headSize)
		case strings.HasSuffix(path, "/SHA256SUMS"):
			_, _ = w.Write([]byte(sum + " *" + isoName + "\n"))
		case strings.HasSuffix(path, "/"+isoName):
			serveArtifact(w, r, body, headSize)
		case strings.HasSuffix(path, "/"):
			_, _ = w.Write([]byte(`<a href="` + isoName + `">` + isoName + `</a>`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	return fixtureTransport{base: http.DefaultTransport, host: u.Host}
}

func TestRefreshRecordsTheProbedSizeAndTheResolvedVariant(t *testing.T) {
	body := []byte("a stand-in for the ISO the daily tree does not carry today")
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Transport: ubuntuFixture(t, body, false, 0), AgentVersion: "2026.08.06"})
	// daily was asked for; only stable resolves, so the fallback fires.
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily}

	if err := a.refreshNow(context.Background(), id, &Progress{}); err != nil {
		t.Fatalf("refreshNow: %v", err)
	}
	p, ok, err := a.store.ReadPointer(id)
	if err != nil || !ok {
		t.Fatalf("ReadPointer: %v ok=%v", err, ok)
	}
	sc, err := a.store.ReadSidecar(id, p.GenerationFile)
	if err != nil {
		t.Fatal(err)
	}
	if sc.Variant != VariantDaily {
		t.Fatalf("sidecar variant = %q; it is the identity-attribution key and must stay the REQUESTED preference", sc.Variant)
	}
	if sc.ResolvedVariant != VariantStable {
		t.Fatalf("resolvedVariant = %q, want stable: the metadata has to name the build the bytes came from", sc.ResolvedVariant)
	}
	if sc.ByteCount != int64(len(body)) {
		t.Fatalf("byteCount = %d, want the size the origin reported (%d) -- it is what sameOrigin compares on every later scan", sc.ByteCount, len(body))
	}
	ce, found := a.Entry(fixedNow, id)
	if !found || ce.ResolvedVariant != VariantStable {
		t.Fatalf("the catalog row must surface the resolved variant: %+v", ce)
	}

	// The unchanged origin is now recognised as unchanged: a byteCount that did
	// not match the probe would make this download all over again.
	if err := a.refreshNow(context.Background(), id, &Progress{}); err != nil {
		t.Fatalf("second refreshNow: %v", err)
	}
	gens, err := a.store.Generations(id)
	if err != nil {
		t.Fatal(err)
	}
	if len(gens) != 1 {
		t.Fatalf("an unchanged origin produced %d generations, want 1 (the still-the-same fast path)", len(gens))
	}
}

func TestADownloadShorterThanTheProbeIsRefused(t *testing.T) {
	body := []byte("truncated")
	// The origin advertises more than it serves, so the promoted artifact would
	// be short and its byteCount would never match a later probe.
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Transport: ubuntuFixture(t, body, false, len(body)+4096)})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}

	if err := a.refreshNow(context.Background(), id, &Progress{}); err == nil {
		t.Fatal("a download shorter than the probed size must be refused, not promoted")
	}
	if _, ok, _ := a.store.ReadPointer(id); ok {
		t.Fatal("a refused download must leave no pointer behind")
	}
}

func TestAMidBodyProxyFailureFallsBackToADirectFetch(t *testing.T) {
	body := []byte(strings.Repeat("artifact bytes ", 500))
	origin := originServer(t, "img.iso", body, sha256Hex(body), "")

	// squid can hand back headers and then stop relaying part-way through -- a
	// peer that dies mid-transfer, an offline-mode switch. The header-phase
	// fallback never sees it, so without a mid-body retry the whole refresh
	// fails where a direct fetch would have worked.
	var proxyHits atomic.Int64
	broken := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proxyHits.Add(1)
		w.Header().Set("Content-Length", itoa(len(body)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body[:16])
		w.(http.Flusher).Flush()
		// Let the headers and the first bytes land before the stream dies, so
		// this is genuinely a mid-body failure and not a header-phase one the
		// existing fallback would have caught anyway.
		time.Sleep(50 * time.Millisecond)
		panic(http.ErrAbortHandler)
	}))
	t.Cleanup(broken.Close)
	bu, err := url.Parse(broken.URL)
	if err != nil {
		t.Fatal(err)
	}

	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	a.proxyBytes = &http.Client{Transport: fixtureTransport{base: http.DefaultTransport, host: bu.Host}}

	dst := filepath.Join(t.TempDir(), "artifact")
	p := &Progress{}
	sha, n, err := a.downloadTo(context.Background(), origin.URL+"/img.iso", dst, p)
	if err != nil {
		t.Fatalf("a mid-body proxy failure must fall back to direct rather than fail the refresh: %v", err)
	}
	if proxyHits.Load() == 0 {
		t.Fatal("the proxy was never tried, so this proves nothing about the fallback")
	}
	if n != int64(len(body)) || sha != sha256Hex(body) {
		t.Fatalf("direct retry produced %d bytes / sha %s", n, sha)
	}
	if snap := p.Snapshot(); snap.Done != int64(len(body)) {
		t.Fatalf("progress counted %d bytes, want %d: the retry must reset the counter rather than add to the proxy's partial count", snap.Done, len(body))
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, body) {
		t.Fatalf("the retry wrote %d bytes; it must restart the artifact, not append to the partial one", len(got))
	}
}

func TestPrefetchLeadIsClampedBelowFreshness(t *testing.T) {
	var logged []string
	a := newTestAgent(t, Options{
		PoolDir: t.TempDir(), Freshness: 24 * time.Hour, PrefetchLead: 48 * time.Hour,
		Logf: func(format string, args ...any) { logged = append(logged, fmt.Sprintf(format, args...)) },
	})
	if a.opts.PrefetchLead >= a.opts.Freshness {
		t.Fatalf("lead %s with freshness %s makes every entry due at every moment, forever", a.opts.PrefetchLead, a.opts.Freshness)
	}
	if a.DueForRefresh(&Sidecar{LastVerifiedAt: fixedNow.UTC().Format(rfc3339)}, fixedNow) {
		t.Fatal("an entry verified this instant must not already be due for refresh")
	}
	if len(logged) == 0 {
		t.Fatal("the clamp must say so: a silently ignored flag leaves the operator with no way to see it took no effect")
	}
}

func TestRunReleasesTheLeaseOnItsWayOut(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), AutoSeed: false, ScanInterval: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(a.lease.Path); err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := os.Stat(a.lease.Path); err != nil {
		t.Fatalf("the scanner never acquired the lease: %v", err)
	}

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after cancellation")
	}
	// A lease left behind holds every other agent read-only for three scan
	// intervals, which is why whoever starts Run must also wait for it.
	if _, err := os.Stat(a.lease.Path); !os.IsNotExist(err) {
		t.Fatalf("Run exited without releasing the lease: %v", err)
	}
}

func TestForceRefreshRefusesWhatItCannotDo(t *testing.T) {
	unavailable := newTestAgent(t, Options{PoolDir: ""})
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	if _, err := unavailable.ForceRefresh(id); err == nil {
		t.Error("force refresh with no pool must refuse")
	}

	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	bad := ImageID{HostType: HostTypeKVM, ImageKey: "guest.no.such.family", Arch: ArchAMD64, Variant: VariantStable}
	if _, err := a.ForceRefresh(bad); err == nil {
		t.Error("force refresh of a family with no resolver must refuse")
	}

	writeLease(t, a.lease.Path, Lease{HostID: "another-agent", RenewedAtUTC: fixedNow.UTC().Format(rfc3339)})
	if _, _, err := a.lease.Renew(fixedNow); err != nil {
		t.Fatal(err)
	}
	if _, err := a.ForceRefresh(id); err == nil {
		t.Error("force refresh in read-only mode must refuse rather than duplicate the holder's work")
	}
}
