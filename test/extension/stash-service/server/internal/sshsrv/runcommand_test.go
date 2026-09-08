// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package sshsrv

import (
	"bytes"
	"database/sql"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"stash-service/internal/id"
	"stash-service/internal/meta"
	"stash-service/internal/store"
)

// The tests here drive runCommand itself rather than the ingest helpers under
// it. That is deliberate: an abort inside runCommand is the only one a scp
// client can be told about, and "the reason string is correct" and "the reason
// reached the channel before it closed" are different claims. A session that
// aborts without writing leaves scp printing its own generic lost-connection
// text, which names neither the upload nor the layer that refused.

// testChannel stands in for the ssh.Channel a session runs on: it replays a
// canned SCP stream, collects what the server writes back, keeps everything
// sent to the client's stderr, and records the exit status.
type testChannel struct {
	in       *bytes.Reader
	mu       sync.Mutex
	out      bytes.Buffer
	errOut   lockedBuffer
	closed   bool
	exitCode int
	exitSent bool
}

// lockedBuffer is the io.ReadWriter handed back as the channel's stderr. The
// interface allows a reader, so the buffer is guarded rather than handed out
// bare.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) Read(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Read(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

func (c *testChannel) Read(p []byte) (int, error) { return c.in.Read(p) }

func (c *testChannel) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return 0, io.ErrClosedPipe
	}
	return c.out.Write(p)
}

func (c *testChannel) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	return nil
}

func (c *testChannel) CloseWrite() error { return nil }

func (c *testChannel) SendRequest(name string, _ bool, payload []byte) (bool, error) {
	if name == "exit-status" && len(payload) == 4 {
		c.mu.Lock()
		c.exitCode = int(payload[3])
		c.exitSent = true
		c.mu.Unlock()
	}
	return true, nil
}

func (c *testChannel) Stderr() io.ReadWriter { return &c.errOut }

func (c *testChannel) exit() (int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.exitCode, c.exitSent
}

// scpChannel builds a channel carrying one file in the SCP wire form the
// session expects: a C control line, the bytes, then the zero status byte.
func scpChannel(name, body string) *testChannel {
	var b bytes.Buffer
	fmtC := "C0644 " + strconv.Itoa(len(body)) + " " + name + "\n"
	b.WriteString(fmtC)
	b.WriteString(body)
	b.WriteByte(0)
	return &testChannel{in: bytes.NewReader(b.Bytes())}
}

// serverAtDB is newTestServer with the index at a caller-chosen path, so a test
// can reach the database from a second connection.
func serverAtDB(t *testing.T, dbPath string) *Server {
	t.Helper()
	shareStore, err := store.New(t.TempDir())
	if err != nil {
		t.Fatalf("share store: %v", err)
	}
	bufStore, err := store.NewFilesOnly(t.TempDir())
	if err != nil {
		t.Fatalf("buffer store: %v", err)
	}
	m, err := meta.Open(dbPath)
	if err != nil {
		t.Fatalf("meta open: %v", err)
	}
	t.Cleanup(func() { _ = m.Close() })
	return &Server{
		Store:        shareStore,
		Buffer:       bufStore,
		Meta:         m,
		IDs:          id.New(m.Exists, shareStore.FilesRoot(), bufStore.FilesRoot()),
		ShareOnline:  func() bool { return true },
		flushTrigger: make(chan struct{}, 1),
	}
}

// announcedIDs pulls the ID markers out of what the client was shown, in the
// order it saw them.
func announcedIDs(stderr string) []string {
	var out []string
	for _, line := range strings.Split(stderr, "\n") {
		const marker = "YURUNA-STASH-ID: "
		if strings.HasPrefix(line, marker) {
			out = append(out, strings.TrimSpace(strings.TrimPrefix(line, marker)))
		}
	}
	return out
}

// blindTo makes the index lookup report one ID free however the index answers,
// narrowing the allocator's scope back to the day folders for that one ID. That
// moves the collision off the allocator and onto the index write, mid-session,
// with the client already told the ID -- the shape a real scp drop takes, and
// the only one that exercises the recovery end to end.
func blindTo(inner func(string) (bool, error), blind string) func(string) (bool, error) {
	return func(candidate string) (bool, error) {
		if candidate == blind {
			return false, nil
		}
		return inner(candidate)
	}
}

// firstThenReal hands back a pinned ID once, then defers to a real allocator.
// The pin is what makes the collision reachable: the generator is random, so a
// test that waited for one would not finish.
type firstThenReal struct {
	mu    sync.Mutex
	first string
	used  bool
	rest  *id.Allocator
}

func (f *firstThenReal) Allocate(t time.Time) (string, error) {
	f.mu.Lock()
	if !f.used {
		f.used = true
		f.mu.Unlock()
		return f.first, nil
	}
	f.mu.Unlock()
	return f.rest.Allocate(t)
}

// countingIDSource counts how many IDs a session asked for, which is how a
// retry that should not have happened becomes visible.
type countingIDSource struct {
	inner IDSource
	mu    sync.Mutex
	calls int
}

func (c *countingIDSource) Allocate(t time.Time) (string, error) {
	c.mu.Lock()
	c.calls++
	c.mu.Unlock()
	return c.inner.Allocate(t)
}

func (c *countingIDSource) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls
}

// TestSCPSessionKeepsAnIDTheIndexAlreadyHolds is the regression case on the
// path that carries real uploads. An older row owns the drawn ID for all time;
// the session must land the artifact under a fresh one, tell the client which,
// and leave the older row alone.
func TestSCPSessionKeepsAnIDTheIndexAlreadyHolds(t *testing.T) {
	db := filepath.Join(t.TempDir(), "stash.sqlite")
	s := serverAtDB(t, db)
	if err := s.Meta.InsertPending(&meta.Record{
		ID:               "6tat",
		Username:         "amisad-poc",
		OriginalFilename: "amisad-x86_64-binaries.tgz",
		CreatedAt:        time.Now().UTC().Add(-24 * time.Hour),
		Status:           meta.StatusComplete,
	}); err != nil {
		t.Fatalf("seed the older row: %v", err)
	}
	s.IDs = &firstThenReal{
		first: "6tat",
		rest:  id.New(blindTo(s.Meta.Exists, "6tat"), s.Store.FilesRoot(), s.Buffer.FilesRoot()),
	}

	ch := scpChannel("amisad-x86_64-binaries.tgz", "BINARIES")
	s.runCommand(ch, "scp -t /amisad", "amisad-poc", "192.168.7.46:32881")

	stderr := ch.errOut.String()
	code, sent := ch.exit()
	if !sent {
		t.Fatal("the session ended without an exit status, so the client has only its own timeout to go on")
	}
	if code != 0 {
		t.Fatalf("session exited %d, want 0 -- a taken id still loses the upload\nclient saw:\n%s", code, stderr)
	}
	seen := announcedIDs(stderr)
	if len(seen) != 2 {
		t.Fatalf("client saw %d id marker(s) %v, want the losing draw and the one that was kept", len(seen), seen)
	}
	kept := seen[len(seen)-1]
	if kept == "6tat" {
		t.Fatal("the session kept the id an older row owns")
	}
	rec, err := s.Meta.Get(kept)
	if err != nil {
		t.Fatalf("no row for the last id the client was given (%q): %v", kept, err)
	}
	if rec.Status != meta.StatusComplete {
		t.Fatalf("row %q status = %q, want %q", kept, rec.Status, meta.StatusComplete)
	}
	body, err := os.ReadFile(rec.StoredPath)
	if err != nil {
		t.Fatalf("artifact missing at the recorded path: %v", err)
	}
	if string(body) != "BINARIES" {
		t.Fatalf("stored bytes = %q, want the uploaded payload", body)
	}
	older, err := s.Meta.Get("6tat")
	if err != nil {
		t.Fatalf("the older row is gone: %v", err)
	}
	if older.OriginalFilename != "amisad-x86_64-binaries.tgz" || older.Status != meta.StatusComplete {
		t.Fatalf("the older row was overwritten: %+v", older)
	}
	day := time.Now().UTC()
	orphan := filepath.Join(s.Store.FilesRoot(), day.Format("2006"), day.Format("01"), day.Format("02"), "6tat.staging")
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("the losing attempt left %s behind, which the day scan reads as a claim forever", orphan)
	}
}

// TestSCPSessionDoesNotRedrawOnAStorageFailure is the other half of the
// contract. A trigger abort carries SQLITE_CONSTRAINT_TRIGGER, which shares its
// primary code with a duplicate key: a classifier reading the primary code
// would walk the whole ladder over a failure no redraw can fix, burning ids and
// delaying the answer the client needs.
func TestSCPSessionDoesNotRedrawOnAStorageFailure(t *testing.T) {
	db := filepath.Join(t.TempDir(), "stash.sqlite")
	s := serverAtDB(t, db)
	raw, err := sql.Open("sqlite", db)
	if err != nil {
		t.Fatalf("open the index directly: %v", err)
	}
	if _, err := raw.Exec(`CREATE TRIGGER refuse_writes BEFORE INSERT ON uploads
BEGIN SELECT RAISE(ABORT, 'index refuses writes'); END`); err != nil {
		t.Fatalf("install the refusing trigger: %v", err)
	}
	_ = raw.Close()

	counted := &countingIDSource{inner: s.IDs}
	s.IDs = counted

	ch := scpChannel("payload.txt", "hello")
	s.runCommand(ch, "scp -t /amisad", "amisad-poc", "192.168.7.46:32881")

	stderr := ch.errOut.String()
	code, sent := ch.exit()
	if !sent || code == 0 {
		t.Fatalf("session exited %d (sent=%v), want a non-zero exit", code, sent)
	}
	if counted.count() != 1 {
		t.Fatalf("the session drew %d ids; a storage failure must not walk the collision ladder", counted.count())
	}
	if !strings.Contains(stderr, "stash-service: internal error (metadata index).") {
		t.Fatalf("the client was not told which layer refused:\n%s", stderr)
	}
	for _, leak := range []string{"sqlite", "uploads", "trigger", "RAISE"} {
		if strings.Contains(strings.ToLower(stderr), strings.ToLower(leak)) {
			t.Fatalf("server-side detail %q reached the client:\n%s", leak, stderr)
		}
	}
}

// TestSCPSessionSpeaksBeforeItExits walks every abort that can follow the ID
// banner. Each one must put a reason on the channel while it is still open; a
// reason written after the close is no reason at all, and an abort that writes
// none leaves scp reporting its own generic "lost connection" instead.
func TestSCPSessionSpeaksBeforeItExits(t *testing.T) {
	t.Run("storage cannot be prepared", func(t *testing.T) {
		s := newTestServer(t, true)
		// Take write permission off the share's files root: the day directory
		// cannot be created, which is an abort reached after the ID banner.
		if err := os.Chmod(s.Store.FilesRoot(), 0o500); err != nil {
			t.Fatalf("chmod: %v", err)
		}
		t.Cleanup(func() { _ = os.Chmod(s.Store.FilesRoot(), 0o700) })
		ch := scpChannel("payload.txt", "hello")
		s.runCommand(ch, "scp -t /amisad", "u", "192.168.7.46:32881")
		stderr := ch.errOut.String()
		if code, sent := ch.exit(); !sent || code == 0 {
			t.Fatalf("session exited %d (sent=%v), want a non-zero exit", code, sent)
		}
		if !strings.Contains(stderr, "stash-service: storage unavailable") {
			t.Fatalf("an unwritable share told the client nothing:\n%s", stderr)
		}
	})

	t.Run("every drawn id is taken", func(t *testing.T) {
		s := newTestServer(t, true)
		if err := s.Meta.InsertPending(&meta.Record{
			ID: "6tat", Username: "u", CreatedAt: time.Now().UTC(), Status: meta.StatusComplete,
		}); err != nil {
			t.Fatalf("seed: %v", err)
		}
		s.IDs = &scriptedIDs{queue: []string{"6tat"}}
		ch := scpChannel("payload.txt", "hello")
		s.runCommand(ch, "scp -t /amisad", "u", "192.168.7.46:32881")
		stderr := ch.errOut.String()
		if code, sent := ch.exit(); !sent || code == 0 {
			t.Fatalf("session exited %d (sent=%v), want a non-zero exit", code, sent)
		}
		if !strings.Contains(stderr, "could not reserve an ID") {
			t.Fatalf("an exhausted ladder told the client nothing:\n%s", stderr)
		}
	})
}

// TestAllocatorAsWiredRefusesAnIDAnOlderRowOwns checks the wiring, not the
// allocator: a Server built the way the daemon builds one must reach the index
// on every draw. Without that the redraw ladder above carries the whole defense
// and every colliding upload pays a round of failed inserts for it.
func TestAllocatorAsWiredRefusesAnIDAnOlderRowOwns(t *testing.T) {
	s := newTestServer(t, true)
	if err := s.Meta.InsertPending(&meta.Record{
		ID: "6tat", Username: "amisad-poc", CreatedAt: time.Now().UTC().Add(-24 * time.Hour), Status: meta.StatusComplete,
	}); err != nil {
		t.Fatalf("seed the older row: %v", err)
	}
	// The day folder for now is empty, so the on-disk scan cannot know.
	held, err := s.Meta.Exists("6tat")
	if err != nil || !held {
		t.Fatalf("Exists(6tat) = %v, %v -- the claim is invisible to the index lookup itself", held, err)
	}
	asked := 0
	probe := id.New(func(candidate string) (bool, error) {
		asked++
		return s.Meta.Exists(candidate)
	}, s.Store.FilesRoot(), s.Buffer.FilesRoot())
	got, err := probe.Allocate(time.Now().UTC())
	if err != nil {
		t.Fatalf("allocate: %v", err)
	}
	if asked == 0 {
		t.Fatal("the allocator never reached the index, so its scope is still one day folder")
	}
	if got == "6tat" {
		t.Fatal("the allocator handed back an id an older row owns")
	}
}
