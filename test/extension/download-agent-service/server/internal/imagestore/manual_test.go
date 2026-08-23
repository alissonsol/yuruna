// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// dropFile writes a file into an identity's drop folder and dates it so the
// settle delay treats it as a finished copy, which is what an operator's
// completed drag-and-drop looks like a couple of minutes later.
func dropFile(t *testing.T, s *Store, id ImageID, name string, body []byte, age time.Duration) string {
	t.Helper()
	dir := s.ManualDir(id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
	stamp := fixedNow.Add(-age)
	if err := os.Chtimes(path, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	return path
}

// windowsID is the row the hand-download path exists for.
var windowsID = ImageID{HostType: HostTypeHyperV, ImageKey: KeyWindows11, Arch: ArchAMD64, Variant: VariantStable}

// brokenFido is a resolver configuration that cannot run at all, standing in
// for the state this whole path answers: Fido installed but refused, Fido
// missing, pwsh missing -- the row cannot resolve, and only a person can fetch
// the artifact.
func brokenFido(t *testing.T) FidoConfig {
	t.Helper()
	return FidoConfig{Script: filepath.Join(t.TempDir(), "Fido.ps1")}
}

func TestAHandPlacedISOBecomesTheServedArtifact(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: brokenFido(t), AgentVersion: "2026.08.23"})
	body := []byte("bytes an operator downloaded from Microsoft by hand")
	dropFile(t, a.store, windowsID, signedName, body, 10*time.Minute)

	// Through the ordinary refresh path, not a private helper: the drop folder
	// has to work with the button an operator actually presses.
	f, started := a.startRefresh(windowsID, false)
	if !started {
		t.Fatal("no refresh started")
	}
	<-f.Done()
	if err := f.Err(); err != nil {
		t.Fatalf("adoption failed: %v", err)
	}

	entry, found := a.Entry(fixedNow, windowsID)
	if !found {
		t.Fatal("the adopted artifact is not servable: the pool has no pointer for it")
	}
	if entry.State != StateFresh {
		t.Errorf("state = %q, want fresh -- an adopted artifact is as current as the pool can make it", entry.State)
	}
	if entry.UpstreamFilename != signedName || entry.ByteCount != int64(len(body)) {
		t.Errorf("entry = %+v, want the dropped file's name and size", entry)
	}
	if entry.SHA256 != sha256Hex(body) {
		t.Errorf("sha256 = %q, want the hash of the bytes on disk", entry.SHA256)
	}
	if entry.ChecksumVerdict != VerdictNone {
		t.Errorf("verdict = %q, want %q: nothing was proven about these bytes and the row must not claim otherwise",
			entry.ChecksumVerdict, VerdictNone)
	}
	if entry.SourceURL != windows11DownloadPage {
		t.Errorf("sourceUrl = %q, want the page it was fetched from", entry.SourceURL)
	}

	// The resolver is still broken, but this row no longer needs a way out: it
	// holds the artifact. Repeating the instructions on a row that is serving
	// bytes is how a page teaches an operator to ignore it.
	if entry.ManualFallback != nil {
		t.Error("a row serving an adopted artifact must not still be advertising the hand-download path")
	}

	// The file is moved, not copied: leaving it behind would double a
	// multi-gigabyte artifact on the share and re-adopt it on every scan.
	if _, _, ok := a.store.ManualCandidate(windowsID, fixedNow); ok {
		t.Error("the drop folder still holds the file after adoption")
	}
	// And a host asking for it gets the bytes, which is the entire point.
	res := a.Ensure(fixedNow, windowsID, Fingerprint{})
	if res.HTTPStatus != http.StatusOK || res.State != StateReady {
		t.Fatalf("ensure = %+v, want the adopted artifact served", res)
	}
}

func TestACopyStillInFlightIsNotAdopted(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: brokenFido(t)})
	// A copy onto the share advances the file's modification time as it writes,
	// so a file written a moment ago is one that may still be growing. Hashing
	// it now would publish a truncated ISO to every host as the real one.
	dropFile(t, a.store, windowsID, signedName, []byte("half an ISO"), 5*time.Second)

	if _, _, ok := a.store.ManualCandidate(windowsID, fixedNow); ok {
		t.Fatal("a file written seconds ago must not be treated as a finished copy")
	}
	adopted, err := a.adoptManual(context.Background(), windowsID, &Progress{})
	if err != nil || adopted {
		t.Fatalf("adoptManual = (%t, %v), want no adoption while the copy may still be running", adopted, err)
	}
	if _, found := a.Entry(fixedNow, windowsID); found {
		t.Error("a pointer was published for a file that is still being written")
	}
}

func TestAdoptionLeavesFamiliesWithAWorkingResolverAlone(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir()})
	// The Ubuntu families resolve on their own, and the next scan would replace
	// a hand-placed copy with the published one -- silently. Refusing to adopt
	// is what keeps that surprise from existing.
	ubuntu := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	dropFile(t, a.store, ubuntu, "ubuntu.iso", []byte("an ISO in the wrong folder"), 10*time.Minute)

	adopted, err := a.adoptManual(context.Background(), ubuntu, &Progress{})
	if err != nil {
		t.Fatalf("adoptManual: %v", err)
	}
	if adopted {
		t.Error("a family with a working resolver must not adopt hand-placed bytes")
	}
}

func TestTheScanAdoptsWithoutAnyonePressingAnything(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: brokenFido(t), AutoSeed: false})
	body := []byte("bytes an operator dropped and then walked away from")
	dropFile(t, a.store, windowsID, signedName, body, 10*time.Minute)

	a.ScanOnce(context.Background())
	// The scan starts the flight; wait for the one it started rather than
	// sleeping on a guess.
	if f, live := a.flights.Lookup(windowsID.Key()); live {
		<-f.Done()
	}
	entry, found := a.Entry(fixedNow, windowsID)
	if !found {
		t.Fatal("the scan did not adopt a finished drop, so an operator who copied the file sees nothing happen")
	}
	if entry.SHA256 != sha256Hex(body) {
		t.Errorf("adopted sha256 = %q, want the dropped bytes", entry.SHA256)
	}
}

func TestTheScanCreatesTheFolderTheUINames(t *testing.T) {
	a := newTestAgent(t, Options{PoolDir: t.TempDir(), Fido: brokenFido(t), AutoSeed: false})
	a.ScanOnce(context.Background())

	// The catalog offers the folder as a link the moment the family breaks, and
	// a link to a folder that does not exist reads as a typo.
	for _, id := range BestEffortTargets(HostTypes) {
		if FamilyOf(id.ImageKey) != FamilyWindows11 {
			continue
		}
		if fi, err := os.Stat(a.store.ManualDir(id)); err != nil || !fi.IsDir() {
			t.Errorf("no drop folder for %s: %v", id, err)
		}
	}
	// A best-effort family with no page to send anyone to gets no folder: an
	// empty invitation to copy bytes nobody can obtain is worse than nothing.
	virtio := ImageID{HostType: HostTypeKVM, ImageKey: KeyVirtioWin, Arch: ArchAMD64, Variant: VariantStable}
	if _, err := os.Stat(a.store.ManualDir(virtio)); err == nil {
		t.Error("virtio-win resolves from a plain URL; it must not advertise a hand-download folder")
	}
}

func TestTheRowCarriesTheWayOutOnlyWhileItNeedsOne(t *testing.T) {
	a := newTestAgent(t, Options{
		PoolDir:         t.TempDir(),
		PoolNetworkPath: "//ypool-nas/work/yuruna.pool",
		Fido:            brokenFido(t),
	})

	rows, _ := a.Catalog(fixedNow)
	var win, ubuntu *CatalogEntry
	for i := range rows {
		switch {
		case rows[i].ImageKey == KeyWindows11 && rows[i].HostType == HostTypeHyperV:
			win = &rows[i]
		case rows[i].ImageKey == KeyUbuntuServer26 && rows[i].HostType == HostTypeHyperV:
			ubuntu = &rows[i]
		}
	}
	if win == nil || ubuntu == nil {
		t.Fatal("the catalog is missing the rows under test")
	}
	if ubuntu.ManualFallback != nil {
		t.Error("a row whose resolver works has nothing to work around")
	}
	mf := win.ManualFallback
	if mf == nil {
		t.Fatal("a Windows row the agent cannot resolve must carry the hand-download path")
	}
	if mf.PageURL != windows11DownloadPage {
		t.Errorf("pageUrl = %q, want Microsoft's download page", mf.PageURL)
	}
	// The choices name the same artifact the automated resolve asks for, or the
	// operator fills the pool with an edition no host wanted.
	if len(mf.Selections) != 3 || !strings.Contains(mf.Selections[0], "x64") || mf.Selections[1] != FidoLanguage {
		t.Errorf("selections = %v, want the x64 multi-edition ISO in %s", mf.Selections, FidoLanguage)
	}
	// The folder is the one an operator's file manager can open, not the mount
	// point inside the guest.
	wantFolder := "//ypool-nas/work/yuruna.pool/images/" + HostTypeHyperV + "/" + KeyWindows11 + "/manual/amd64.stable"
	if mf.Folder != wantFolder {
		t.Errorf("folder = %q, want %q", mf.Folder, wantFolder)
	}
	if mf.FolderURL != "file://ypool-nas/work/yuruna.pool/images/"+HostTypeHyperV+"/"+KeyWindows11+"/manual/amd64.stable" {
		t.Errorf("folderUrl = %q is not the same folder as a link", mf.FolderURL)
	}
}

func TestAnArm64RowIsSentToTheArm64Download(t *testing.T) {
	arm := ImageID{HostType: HostTypeUTM, ImageKey: KeyWindows11, Arch: ArchARM64, Variant: VariantStable}
	mf := ManualFallbackFor(arm,
		"/mnt/yuruna-pool/images/macos.utm/guest.windows.11/manual/arm64.stable",
		"/mnt/yuruna-pool/images", "")
	if mf == nil {
		t.Fatal("the arm64 Windows row has a hand-download path too")
	}
	// Microsoft publishes the ARM64 media on a page of its own; sending an
	// arm64 host's operator to the x64 page ends in an ISO no UTM guest boots.
	if mf.PageURL != windows11ARM64DownloadPage {
		t.Errorf("pageUrl = %q, want the ARM64 download page", mf.PageURL)
	}
	if !strings.Contains(mf.Selections[0], "ARM64") || !strings.Contains(mf.Selections[2], "ARM64") {
		t.Errorf("selections = %v, want the ARM64 ISO and its download button", mf.Selections)
	}
	// With no network path configured the agent still names a real folder --
	// its own mount -- rather than nothing at all.
	if mf.Folder != "/mnt/yuruna-pool/images/macos.utm/guest.windows.11/manual/arm64.stable" {
		t.Errorf("folder = %q, want the agent's own path", mf.Folder)
	}
	if mf.FolderURL != "file:///mnt/yuruna-pool/images/macos.utm/guest.windows.11/manual/arm64.stable" {
		t.Errorf("folderUrl = %q, want the local path as a file URL", mf.FolderURL)
	}
}

func TestAFolderOutsideThePoolIsNeverRepublishedAsAShare(t *testing.T) {
	const images = "/mnt/yuruna-pool/images"
	// The share path is only usable for paths under the images root. Anything
	// else keeps the agent's own path, because a re-rooted guess would name a
	// folder on the NAS that has nothing to do with this pool.
	if got := shareFolder("//nas/share", images, "/var/tmp/elsewhere/guest.windows.11"); got != "" {
		t.Errorf("shareFolder = %q, want no share path for a directory outside the pool", got)
	}
	if got := shareFolder("", images, images+"/x/y"); got != "" {
		t.Errorf("shareFolder = %q, want nothing when no network path is configured", got)
	}
	// A Windows-style UNC is the same path; the pool config writes it either way.
	if got := shareFolder(`\\nas\share\`, images, images+"/x/y"); got != "//nas/share/images/x/y" {
		t.Errorf("shareFolder = %q, want the backslash form normalized", got)
	}
	// A mount point that happens to contain the images directory name must not
	// be cut at the wrong segment: the answer is derived from the images root
	// this agent actually uses, not from the first "/images/" in the string.
	if got := shareFolder("//nas/share", "/srv/images/pool/images", "/srv/images/pool/images/a/b"); got != "//nas/share/images/a/b" {
		t.Errorf("shareFolder = %q, want the path re-rooted at the images root, not at the first match", got)
	}
}
