// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"download-agent-service/internal/config"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	return NewStore(t.TempDir())
}

func mustCommit(t *testing.T, s *Store, id ImageID, filename, sha string, size int64, verifiedAt time.Time) string {
	t.Helper()
	gen := GenerationName(filename, sha)
	if err := os.MkdirAll(s.Dir(id), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(s.Dir(id), gen), make([]byte, size), 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}
	sc := Sidecar{
		ImageKey: id.ImageKey, HostType: id.HostType, Arch: id.Arch, Variant: id.Variant,
		SourceURL: "https://example.invalid/" + filename, UpstreamFilename: filename,
		ByteCount: size, SHA256: sha, ChecksumVerdict: VerdictVerified,
		DownloadedAt: verifiedAt.UTC().Format(time.RFC3339), LastVerifiedAt: verifiedAt.UTC().Format(time.RFC3339),
	}
	if err := s.Commit(id, gen, sc); err != nil {
		t.Fatalf("commit: %v", err)
	}
	return gen
}

func TestGenerationNameIsUpstreamPlusShortHash(t *testing.T) {
	got := GenerationName("ubuntu-26.04.1-live-server-amd64.iso", "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90")
	want := "ubuntu-26.04.1-live-server-amd64.iso.a1b2c3d4e5f6"
	if got != want {
		t.Fatalf("generation name = %q, want %q", got, want)
	}
}

func TestValidGenerationNameRejectsMetadataAndTraversal(t *testing.T) {
	for _, bad := range []string{"", ".hidden", "a/b", `a\b`, "..", "x.meta.json", "current.amd64.stable.json"} {
		if ValidGenerationName(bad) {
			t.Errorf("ValidGenerationName(%q) = true, want false", bad)
		}
	}
	if !ValidGenerationName("ubuntu-26.04-live-server-amd64.iso.abc123def456") {
		t.Error("a plain generation name must be accepted")
	}
}

func TestCommitWritesSidecarBeforePointer(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	gen := "ubuntu-26.04-live-server-amd64.iso.aaaabbbbcccc"
	if err := os.MkdirAll(s.Dir(id), 0o755); err != nil {
		t.Fatal(err)
	}
	// Block the sidecar path with a directory so its write cannot succeed. If
	// Commit wrote the pointer first, the pool would advertise a generation
	// whose metadata never landed.
	if err := os.MkdirAll(filepath.Join(s.Dir(id), SidecarName(gen)), 0o755); err != nil {
		t.Fatal(err)
	}
	err := s.Commit(id, gen, Sidecar{UpstreamFilename: "ubuntu-26.04-live-server-amd64.iso", SHA256: "aaaabbbbcccc"})
	if err == nil {
		t.Fatal("Commit succeeded despite an unwritable sidecar")
	}
	if _, ok, _ := s.ReadPointer(id); ok {
		t.Fatal("pointer was written even though the sidecar write failed; the pointer must be written LAST")
	}
}

func TestCommitPromotesAndPointerNamesTheNewGeneration(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	now := time.Now()
	first := mustCommit(t, s, id, "ubuntu-26.04-live-server-amd64.iso", "1111111111111111", 10, now)

	p, ok, err := s.ReadPointer(id)
	if err != nil || !ok {
		t.Fatalf("ReadPointer: %v ok=%v", err, ok)
	}
	if p.GenerationFile != first {
		t.Fatalf("pointer names %q, want %q", p.GenerationFile, first)
	}

	// A staged second generation is promoted under its own content name; the
	// first artifact is untouched, so a reader streaming it keeps its handle.
	staged, err := s.NewStagingPath(id, "ubuntu-26.04.1-live-server-amd64.iso")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staged, make([]byte, 20), 0o644); err != nil {
		t.Fatal(err)
	}
	second := GenerationName("ubuntu-26.04.1-live-server-amd64.iso", "2222222222222222")
	if err := s.PromoteStaging(id, staged, second); err != nil {
		t.Fatalf("PromoteStaging: %v", err)
	}
	if _, err := os.Stat(filepath.Join(s.Dir(id), first)); err != nil {
		t.Fatalf("promote disturbed the previous generation: %v", err)
	}
	if _, err := os.Stat(staged); !os.IsNotExist(err) {
		t.Fatalf("staging entry survived promote: %v", err)
	}
}

func TestPromoteStagingDiscardsARedownloadOfIdenticalBytes(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	gen := mustCommit(t, s, id, "img.iso", "3333333333333333", 8, time.Now())

	staged, err := s.NewStagingPath(id, "img.iso")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staged, make([]byte, 8), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := s.PromoteStaging(id, staged, gen); err != nil {
		t.Fatalf("PromoteStaging: %v", err)
	}
	if _, err := os.Stat(staged); !os.IsNotExist(err) {
		t.Fatal("a duplicate promote must drop the staging copy rather than land over the served path")
	}
}

func TestPromoteStagingNeverReplacesAServedGeneration(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	gen := mustCommit(t, s, id, "img.iso", "4444444444444444", 8, time.Now())
	served := filepath.Join(s.Dir(id), gen)

	// A host is streaming the current generation while a second agent promotes
	// the same one. Landing on that path would tear the stream; the existing
	// file must survive byte for byte.
	reader, err := os.Open(served)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	before, err := reader.Stat()
	if err != nil {
		t.Fatal(err)
	}

	staged, err := s.NewStagingPath(id, "img.iso")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staged, make([]byte, 99), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := s.PromoteStaging(id, staged, gen); err != nil {
		t.Fatalf("PromoteStaging: %v", err)
	}
	after, err := os.Stat(served)
	if err != nil {
		t.Fatalf("the served generation disappeared: %v", err)
	}
	if after.Size() != before.Size() {
		t.Fatalf("the served generation is now %d bytes, was %d: promote landed over a path a reader holds open", after.Size(), before.Size())
	}
}

func TestTwoPreferencesSharingOneGenerationBothReportIt(t *testing.T) {
	s := testStore(t)
	stable := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	daily := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily}
	// When both preferences resolve to the same artifact, content addressing
	// collapses them onto ONE generation with ONE sidecar, and the second commit
	// overwrites that sidecar with its own variant. Attribution therefore cannot
	// come from the sidecar: it comes from the pointer, which is per-identity.
	gen := mustCommit(t, s, stable, "img.iso", "5555555555555555", 64, time.Now())
	if second := mustCommit(t, s, daily, "img.iso", "5555555555555555", 64, time.Now()); second != gen {
		t.Fatalf("identical bytes produced two generations (%q and %q); the premise of this test is gone", gen, second)
	}

	for _, id := range []ImageID{stable, daily} {
		e, err := s.Entry(id)
		if err != nil {
			t.Fatalf("Entry(%s): %v", id, err)
		}
		if e.Pointer == nil || e.Pointer.GenerationFile != gen {
			t.Fatalf("%s lost its pointer: %+v", id, e.Pointer)
		}
		if e.CurrentBytes != 64 {
			t.Fatalf("%s reports currentBytes %d, want 64: a shared generation must not vanish from the identity whose sidecar was overwritten", id, e.CurrentBytes)
		}
		if len(e.Generations) != 1 {
			t.Fatalf("%s lists %d generations, want 1", id, len(e.Generations))
		}
	}
}

func TestAnotherIdentitysCurrentGenerationIsNotCountedAsPrevious(t *testing.T) {
	s := testStore(t)
	stable := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	daily := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily}
	mustCommit(t, s, stable, "stable.iso", "1111111111111111", 10, time.Now())
	mustCommit(t, s, daily, "daily.iso", "2222222222222222", 20, time.Now())

	e, err := s.Entry(stable)
	if err != nil {
		t.Fatal(err)
	}
	if e.CurrentBytes != 10 || e.PreviousBytes != 0 {
		t.Fatalf("entry = current %d / previous %d, want 10 / 0: one directory holds every variant, and a sibling's current copy is not this identity's previous one",
			e.CurrentBytes, e.PreviousBytes)
	}
}

func TestAPointerWriteIsNotBlockedByAnotherWritersTemp(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	if err := os.MkdirAll(s.Dir(id), 0o755); err != nil {
		t.Fatal(err)
	}
	// A temp name derived only from the target is a name two agents on one NAS
	// both use: one truncates it while the other's rename is pending, and the
	// pointer that gets published is torn. Standing a directory in that shared
	// path makes the collision observable without having to win a race.
	if err := os.MkdirAll(s.PointerPath(id)+".tmp", 0o755); err != nil {
		t.Fatal(err)
	}
	err := s.WritePointer(id, Pointer{
		UpstreamFilename: "img.iso",
		GenerationFile:   "img.iso.aaaabbbbcccc",
		SHA256:           "aaaabbbbcccc",
		UpdatedAt:        time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		t.Fatalf("the write used another writer's temp path: %v", err)
	}
	if _, ok, err := s.ReadPointer(id); err != nil || !ok {
		t.Fatalf("ReadPointer: %v ok=%v", err, ok)
	}
}

func TestConcurrentPointerWritesAlwaysPublishAValidPointer(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	if err := os.MkdirAll(s.Dir(id), 0o755); err != nil {
		t.Fatal(err)
	}
	// Two agents share one NAS by design. A temp name shared between them means
	// one truncates it while the other's rename is still pending, and what gets
	// published is a torn document -- which ReadPointer rejects and List drops,
	// so the image silently vanishes from the catalog. Last-writer-wins is only
	// permitted between valid states.
	// A write that loses the race is fine -- last-writer-wins is the contract.
	// What must never happen is a READ that lands on something invalid.
	const writers, rounds = 4, 150
	torn := make(chan string, 8)
	stop := make(chan struct{})
	var readers sync.WaitGroup
	readers.Add(1)
	go func() {
		defer readers.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			b, err := os.ReadFile(s.PointerPath(id))
			if err != nil {
				continue
			}
			var p Pointer
			if json.Unmarshal(b, &p) != nil || p.GenerationFile == "" {
				select {
				case torn <- string(b):
				default:
				}
				return
			}
		}
	}()

	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < rounds; i++ {
				_ = s.WritePointer(id, Pointer{
					UpstreamFilename: "img.iso",
					GenerationFile:   "img.iso.aaaabbbbcccc",
					SHA256:           strings.Repeat(strconv.Itoa(w), 16),
					UpdatedAt:        time.Now().UTC().Format(time.RFC3339),
				})
			}
		}(w)
	}
	wg.Wait()
	close(stop)
	readers.Wait()
	select {
	case body := <-torn:
		t.Fatalf("a reader observed a torn pointer, so the catalog would have dropped this image: %q", body)
	default:
	}

	if _, ok, err := s.ReadPointer(id); err != nil || !ok {
		t.Fatalf("the pointer is unreadable after concurrent writes: %v ok=%v", err, ok)
	}
	ents, err := os.ReadDir(s.Dir(id))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if e.Name() != config.PointerName(id.Arch, id.Variant) {
			t.Fatalf("the writes left %q behind", e.Name())
		}
	}
}

func TestRetainKeepsCurrentPlusOnePrevious(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	base := time.Now()
	oldest := mustCommit(t, s, id, "img.iso", "aaaaaaaaaaaaaaaa", 4, base.Add(-72*time.Hour))
	middle := mustCommit(t, s, id, "img.iso", "bbbbbbbbbbbbbbbb", 5, base.Add(-48*time.Hour))
	newest := mustCommit(t, s, id, "img.iso", "cccccccccccccccc", 6, base)
	// Modification times decide which generation is "previous"; make them
	// unambiguous rather than relying on write order resolution.
	for name, age := range map[string]time.Duration{oldest: 72, middle: 48, newest: 0} {
		ts := base.Add(-age * time.Hour)
		if err := os.Chtimes(filepath.Join(s.Dir(id), name), ts, ts); err != nil {
			t.Fatal(err)
		}
	}

	n, err := s.Retain(id)
	if err != nil {
		t.Fatalf("Retain: %v", err)
	}
	if n != 1 {
		t.Fatalf("Retain removed %d generations, want 1", n)
	}
	if _, err := os.Stat(filepath.Join(s.Dir(id), oldest)); !os.IsNotExist(err) {
		t.Error("the oldest generation should have been reclaimed")
	}
	for _, keep := range []string{middle, newest} {
		if _, err := os.Stat(filepath.Join(s.Dir(id), keep)); err != nil {
			t.Errorf("generation %s should have been retained: %v", keep, err)
		}
	}
}

func TestPrunePreviousLeavesCurrentServable(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	prev := mustCommit(t, s, id, "img.iso", "dddddddddddddddd", 4, time.Now().Add(-time.Hour))
	cur := mustCommit(t, s, id, "img.iso", "eeeeeeeeeeeeeeee", 9, time.Now())

	n, err := s.PrunePrevious(id)
	if err != nil {
		t.Fatalf("PrunePrevious: %v", err)
	}
	if n != 1 {
		t.Fatalf("pruned %d, want 1", n)
	}
	if _, err := os.Stat(filepath.Join(s.Dir(id), prev)); !os.IsNotExist(err) {
		t.Error("the previous generation should be gone")
	}
	if _, err := os.Stat(filepath.Join(s.Dir(id), cur)); err != nil {
		t.Errorf("the current generation must stay servable: %v", err)
	}
	if _, ok, _ := s.ReadPointer(id); !ok {
		t.Error("prune must not remove the pointer")
	}
}

func TestDeleteRemovesPointerAndOwnGenerationsOnly(t *testing.T) {
	s := testStore(t)
	stable := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	daily := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily}
	stableGen := mustCommit(t, s, stable, "stable.iso", "1111111111111111", 4, time.Now())
	dailyGen := mustCommit(t, s, daily, "daily.iso", "2222222222222222", 4, time.Now())

	if _, err := s.Delete(stable); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, ok, _ := s.ReadPointer(stable); ok {
		t.Error("the deleted identity's pointer must be gone")
	}
	if _, err := os.Stat(filepath.Join(s.Dir(stable), stableGen)); !os.IsNotExist(err) {
		t.Error("the deleted identity's generation must be gone")
	}
	if _, ok, _ := s.ReadPointer(daily); !ok {
		t.Error("a sibling variant's pointer must survive")
	}
	if _, err := os.Stat(filepath.Join(s.Dir(daily), dailyGen)); err != nil {
		t.Errorf("a sibling variant's generation must survive: %v", err)
	}
}

func TestDeleteClearsOnlyItsOwnStaging(t *testing.T) {
	s := testStore(t)
	stable := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	daily := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily}
	mustCommit(t, s, stable, "stable.iso", "1111111111111111", 4, time.Now())

	stableStage, _ := s.NewStagingPath(stable, "stable.iso")
	dailyStage, _ := s.NewStagingPath(daily, "daily.iso")
	for _, p := range []string{stableStage, dailyStage} {
		if err := os.WriteFile(p, []byte("partial"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Delete(stable); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := os.Stat(stableStage); !os.IsNotExist(err) {
		t.Error("delete must clear its own staging entry")
	}
	if _, err := os.Stat(dailyStage); err != nil {
		t.Errorf("delete must not touch another variant's in-flight staging: %v", err)
	}
}

func TestSweepStagingRemovesOldAndDeadPidEntries(t *testing.T) {
	s := testStore(t)
	id := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	dir := s.StagingDir(id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	live := filepath.Join(dir, "amd64.stable.img.iso."+strconv.Itoa(os.Getpid()))
	dead := filepath.Join(dir, "amd64.stable.img.iso.999999")
	aged := filepath.Join(dir, "amd64.stable.old.iso."+strconv.Itoa(os.Getpid()))
	for _, p := range []string{live, dead, aged} {
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old := now.Add(-config.StagingMaxAge - time.Hour)
	if err := os.Chtimes(aged, old, old); err != nil {
		t.Fatal(err)
	}

	alive := func(pid int) bool { return pid == os.Getpid() }
	n, err := s.SweepStaging(now, alive)
	if err != nil {
		t.Fatalf("SweepStaging: %v", err)
	}
	if n != 2 {
		t.Fatalf("swept %d entries, want 2", n)
	}
	if _, err := os.Stat(live); err != nil {
		t.Errorf("a live PID's staging entry must survive: %v", err)
	}
	for _, gone := range []string{dead, aged} {
		if _, err := os.Stat(gone); !os.IsNotExist(err) {
			t.Errorf("%s should have been swept", filepath.Base(gone))
		}
	}
}

func TestProcessAliveTreatsAnInconclusiveProbeAsAlive(t *testing.T) {
	if !ProcessAlive(os.Getpid()) {
		t.Fatal("the sweeping process must consider itself alive")
	}
	for _, bad := range []int{0, -1} {
		if ProcessAlive(bad) {
			t.Errorf("ProcessAlive(%d) = true", bad)
		}
	}
	// The parent is a live process whose signal probe cannot answer: on Windows
	// it is unimplemented, and on Linux another user's process answers EPERM.
	// Reading either as "dead" would let this sweep delete another agent's
	// in-flight multi-gigabyte download.
	ppid := os.Getppid()
	if ppid <= 0 {
		t.Skip("no parent process to probe")
	}
	if _, err := os.FindProcess(ppid); err != nil {
		t.Skipf("the parent is no longer probeable: %v", err)
	}
	if !ProcessAlive(ppid) {
		t.Fatal("a probe that cannot prove death must read as alive")
	}
}

func TestListFindsEveryPointerAndSkipsDotEntries(t *testing.T) {
	s := testStore(t)
	a := ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable}
	b := ImageID{HostType: HostTypeHyperV, ImageKey: KeyAmazonLinux2023, Arch: ArchAMD64, Variant: VariantStable}
	mustCommit(t, s, a, "a.iso", "1111111111111111", 3, time.Now())
	mustCommit(t, s, b, "b.zip", "2222222222222222", 3, time.Now())
	if err := os.WriteFile(filepath.Join(s.ImagesDir(), config.LeaseFileName), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	entries, err := s.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("List returned %d entries, want 2", len(entries))
	}
	for _, e := range entries {
		if e.Pointer == nil || e.Sidecar == nil {
			t.Errorf("entry %s missing pointer or sidecar", e.ID)
		}
	}
}

func TestValidateRejectsUnknownIdentities(t *testing.T) {
	cases := []ImageID{
		{HostType: "linux.qemu", ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable},
		{HostType: HostTypeKVM, ImageKey: "../escape", Arch: ArchAMD64, Variant: VariantStable},
		{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: "riscv", Variant: VariantStable},
		{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: "nightly"},
	}
	for _, id := range cases {
		if err := id.Validate(); err == nil {
			t.Errorf("Validate(%+v) accepted an out-of-set identity", id)
		}
	}
	ok := ImageID{HostType: HostTypeUTM, ImageKey: KeyUbuntuExtension, Arch: ArchARM64, Variant: VariantStable}
	if err := ok.Validate(); err != nil {
		t.Errorf("Validate rejected a valid identity: %v", err)
	}
}
