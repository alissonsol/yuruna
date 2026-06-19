// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package sshsrv hosts the crypto/ssh server and the per-connection
// SCP session dispatch loop. Authentication is the §4.3 pass-through
// pattern, realized as the SSH "none" method: the daemon accepts the
// connection with NO credentials so a standard scp/sftp client connects
// with zero prompts. Public-key auth is intentionally NOT advertised --
// accepting any key makes clients prompt for their local keys'
// passphrases. The username is still captured (from the none/password
// callback) into the connection's Permissions for the SCP/SFTP handler
// to stamp on the metadata record.
package sshsrv

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"stash-server/internal/config"
	"stash-server/internal/detect"
	"stash-server/internal/id"
	"stash-server/internal/meta"
	"stash-server/internal/scp"
	"stash-server/internal/store"
)

// Server pulls together every layer the daemon needs: share + VM-local
// buffer storage, metadata DB, ID allocator, the SSH host key, the
// share-online probe, the flush trigger, and the network listener.
type Server struct {
	Store    *store.Store
	Buffer   *store.Store
	Meta     *meta.Store
	IDs      *id.Allocator
	Detector detect.Detector
	sshCfg   *ssh.ServerConfig
	listener net.Listener

	// ShareOnline reports whether the share is a live, writable network
	// mount (§8.4). Injectable so tests can drive the buffer/flush paths
	// without a real cifs mount.
	ShareOnline func() bool
	// flushTrigger nudges the flush worker after a buffered upload; a
	// buffered (cap 1) channel so a burst coalesces into one wake-up.
	flushTrigger chan struct{}

	// mutateMu serializes a per-artifact mutation (DeleteLocal) against the
	// flush worker's move-to-share (flushRecord). Without it, a delete that
	// snapshots a record as locallyBuffered can race a concurrent flush and
	// orphan the on-share artifact + sidecar (the DB row goes, the share
	// copy survives and is resurrected by the sidecar rebuild).
	mutateMu sync.Mutex
}

// New wires everything up. The host key is loaded from
// <StashFolder>/hostkey/ (durable, §4.4); if the share is offline at startup
// it falls back to a VM-local key so the daemon still comes up (§8.4).
func New(s *store.Store, buffer *store.Store, m *meta.Store, ids *id.Allocator) (*Server, error) {
	localHostKey := filepath.Join(buffer.Folder, config.HostKeyDirName, config.HostKeyFileName)
	hostKey, err := loadOrGenerateHostKey(s.HostKeyPath(), localHostKey)
	if err != nil {
		return nil, fmt.Errorf("host key: %w", err)
	}
	cfg := &ssh.ServerConfig{
		// §4.3: accept with NO credentials (SSH "none") so scp/sftp connect
		// prompt-free; still capture the username as metadata.
		NoClientAuth: true,
		NoClientAuthCallback: func(conn ssh.ConnMetadata) (*ssh.Permissions, error) {
			return permFor(conn), nil
		},
		// Fallback for a client that declines "none"; accepts any password.
		// Public-key auth is deliberately NOT advertised: accepting any key
		// makes clients prompt for their local keys' passphrases.
		PasswordCallback: func(conn ssh.ConnMetadata, _ []byte) (*ssh.Permissions, error) {
			return permFor(conn), nil
		},
	}
	cfg.AddHostKey(hostKey)
	return &Server{
		Store:        s,
		Buffer:       buffer,
		Meta:         m,
		IDs:          ids,
		Detector:     detect.New(),
		sshCfg:       cfg,
		ShareOnline:  func() bool { return store.ShareOnline(s.Folder) },
		flushTrigger: make(chan struct{}, 1),
	}, nil
}

func permFor(conn ssh.ConnMetadata) *ssh.Permissions {
	return &ssh.Permissions{
		Extensions: map[string]string{
			"captured-user": conn.User(),
		},
	}
}

// ListenAndServe binds to addr and runs the accept loop until ctx is
// cancelled. Connections are handled in their own goroutines.
func (s *Server) ListenAndServe(ctx context.Context, addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	s.listener = ln
	log.Printf("stash-server listening on %s", addr)

	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	for {
		nc, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			log.Printf("accept: %v", err)
			continue
		}
		go s.handle(nc)
	}
}

func (s *Server) handle(nc net.Conn) {
	defer nc.Close()
	remote := nc.RemoteAddr().String()
	conn, chans, reqs, err := ssh.NewServerConn(nc, s.sshCfg)
	if err != nil {
		log.Printf("ssh handshake from %s: %v", remote, err)
		return
	}
	username := conn.User()
	if conn.Permissions != nil {
		if v, ok := conn.Permissions.Extensions["captured-user"]; ok && v != "" {
			username = v
		}
	}
	log.Printf("ssh handshake ok: user=%q remote=%s", username, remote)
	defer conn.Close()
	go ssh.DiscardRequests(reqs)

	for newCh := range chans {
		if newCh.ChannelType() != "session" {
			_ = newCh.Reject(ssh.UnknownChannelType, "only session channels supported")
			continue
		}
		ch, chReqs, err := newCh.Accept()
		if err != nil {
			log.Printf("accept channel: %v", err)
			continue
		}
		s.handleSession(ch, chReqs, username, remote)
	}
}

func (s *Server) handleSession(ch ssh.Channel, reqs <-chan *ssh.Request, username, remote string) {
	defer ch.Close()
	for req := range reqs {
		switch req.Type {
		case "exec":
			cmd := parseExecPayload(req.Payload)
			_ = req.Reply(true, nil)
			s.runCommand(ch, cmd, username, remote)
			return
		case "env":
			_ = req.Reply(true, nil)
		case "subsystem":
			// Modern OpenSSH scp (>= 9.0) defaults to the SFTP protocol and
			// does NOT fall back to legacy scp, so serve the sftp subsystem
			// too (routing writes into the stash). Any other subsystem is
			// rejected.
			if parseExecPayload(req.Payload) == "sftp" {
				_ = req.Reply(true, nil)
				s.serveSFTP(ch, username, remote)
				return
			}
			_ = req.Reply(false, nil)
			fmt.Fprintln(ch.Stderr(), "stash-server: only scp / sftp are supported.")
			writeExit(ch, 1)
			return
		case "pty-req", "shell":
			// §4.2: no GUI / interactive shell. Reject cleanly so a stray
			// `ssh` (no scp) gets a useful error instead of hanging.
			_ = req.Reply(false, nil)
			fmt.Fprintln(ch.Stderr(), "stash-server: only scp / sftp are supported (interactive shell rejected).")
			writeExit(ch, 1)
			return
		default:
			_ = req.Reply(false, nil)
		}
	}
}

func (s *Server) runCommand(ch ssh.Channel, rawCmd, username, remote string) {
	parsed, ok := parseSCPCommand(rawCmd)
	if !ok {
		fmt.Fprintf(ch.Stderr(), "stash-server: only scp is supported (got: %q).\n", rawCmd)
		writeExit(ch, 1)
		return
	}
	// §7: allocate ID before file content streams; §9: emit
	// YURUNA-STASH-ID to stderr at the start of the SCP exchange so
	// the client's terminal shows it even on a failed transfer.
	now := time.Now().UTC()
	allocated, err := s.IDs.Allocate(now)
	if err != nil {
		log.Printf("alloc id: %v", err)
		fmt.Fprintln(ch.Stderr(), "stash-server: internal error (ID allocation).")
		writeExit(ch, 1)
		return
	}
	fmt.Fprintf(ch.Stderr(), config.StderrIDFormat, allocated)

	// §8.4: stage on the share when it is a live writable network mount;
	// otherwise fall back to the VM-local buffer and flush later. The
	// target store is fixed before any bytes stream so a single upload
	// never straddles the two.
	target, buffered, err := s.chooseTarget(allocated)
	if err != nil {
		if errors.Is(err, errBufferFull) {
			fmt.Fprintln(ch.Stderr(), "stash-server: storage offline and local buffer full; upload rejected.")
		}
		writeExit(ch, 1)
		return
	}

	dayDir, err := target.DayDir(now)
	if err != nil {
		log.Printf("day dir: %v", err)
		writeExit(ch, 1)
		return
	}
	stagingDir, err := target.StagingDir(now, allocated)
	if err != nil {
		log.Printf("staging dir: %v", err)
		writeExit(ch, 1)
		return
	}

	// §8.2 step 2: pending record up front. storedPath and
	// originalFilename are placeholder until FinalizeStaging produces
	// the real values.
	clientIP := remote
	if h, _, splitErr := net.SplitHostPort(remote); splitErr == nil {
		clientIP = h
	}
	pendingRec := &meta.Record{
		ID:               allocated,
		StoredPath:       "",
		OriginalFilename: "",
		IsArchive:        false,
		Username:         username,
		PathMetadata:     parsed.DestPath,
		ClientAddress:    clientIP,
		CreatedAt:        now,
		Status:           meta.StatusPending,
		SizeBytes:        0,
		LocallyBuffered:  buffered,
		Source:           config.SourceSCP,
	}
	if err := s.Meta.InsertPending(pendingRec); err != nil {
		log.Printf("insert pending: %v", err)
		writeExit(ch, 1)
		return
	}

	res, scpErr := scp.Receive(ch, ch, stagingDir)
	if scpErr != nil {
		log.Printf("scp receive (id=%s, user=%s): %v", allocated, username, scpErr)
		_ = s.Meta.UpdateOnPartial(allocated, res.TotalBytes, time.Now().UTC())
		writeExit(ch, 1)
		return
	}
	if len(res.FileNames) == 0 && res.FirstDirName == "" {
		// §5.5: empty filename only — nothing stored, no record kept.
		if delErr := s.Meta.Delete(allocated); delErr != nil {
			log.Printf("delete empty-name pending row id=%s: %v", allocated, delErr)
		}
		_ = os.RemoveAll(stagingDir)
		log.Printf("scp session id=%s produced no files; pending row removed", allocated)
		writeExit(ch, 0)
		return
	}

	final, err := target.FinalizeStaging(stagingDir, dayDir, allocated, parsed.Recursive, res.FileNames, res.FirstDirName)
	if err != nil {
		log.Printf("finalize (id=%s): %v", allocated, err)
		_ = os.RemoveAll(stagingDir) // don't leave an orphan <id>.staging tree on finalize failure
		_ = s.Meta.UpdateOnPartial(allocated, res.TotalBytes, time.Now().UTC())
		writeExit(ch, 1)
		return
	}
	status := meta.StatusComplete
	if res.Truncated {
		status = meta.StatusTruncated
	}
	if err := s.commit(allocated, status, final, buffered, username); err != nil {
		log.Printf("commit (id=%s): %v", allocated, err)
		writeExit(ch, 1)
		return
	}
	writeExit(ch, 0)
}

// errBufferFull signals the VM-local buffer is at its ceiling while the
// share is offline (§8.4) — the upload must be rejected.
var errBufferFull = errors.New("local buffer full")

// chooseTarget returns the store an upload should stage into: the share
// when it is a live writable network mount, else the VM-local buffer
// (unless the buffer is at its ceiling, then errBufferFull). Shared by the
// legacy SCP and SFTP ingest paths so the share/buffer policy stays in one
// place (§8.4).
func (s *Server) chooseTarget(id string) (target *store.Store, buffered bool, err error) {
	if s.ShareOnline() {
		return s.Store, false, nil
	}
	used, _ := store.DirSize(s.Buffer.Folder)
	if used >= config.BufferCeilingBytes {
		log.Printf("buffer full (%d bytes >= ceiling): rejecting id=%s", used, id)
		return nil, false, errBufferFull
	}
	log.Printf("share offline; buffering id=%s locally", id)
	return s.Buffer, true, nil
}

// commit writes the terminal metadata row and, for a share-side artifact,
// the durable sidecar LAST (§8.5); for a buffered artifact it nudges the
// flush worker instead (the sidecar lands on the share at flush time,
// §8.4). Shared by the legacy SCP and SFTP ingest paths.
func (s *Server) commit(id, status string, final *store.FinalizeResult, buffered bool, username string) error {
	if err := s.Meta.UpdateOnComplete(id, final.StoredPath, final.OriginalFilename, final.IsArchive, status, final.SizeBytes, time.Now().UTC()); err != nil {
		return err
	}
	// Detect the content type server-side, once, before the sidecar is
	// written so SCP- and UI-created stashes classify identically and the
	// type survives a reimage rebuild (stash-service-ui.md §6.1, §10). The
	// artifact exists locally now (share or buffer), so detection works in
	// both cases; for a buffered upload the type lands in the DB row here and
	// is carried onto the sidecar at flush time.
	s.detectAndStore(id, final)
	if buffered {
		s.triggerFlush()
	} else {
		if rec, gerr := s.Meta.Get(id); gerr != nil {
			log.Printf("sidecar: load record id=%s: %v", id, gerr)
		} else if serr := meta.WriteSidecar(rec); serr != nil {
			log.Printf("sidecar: write id=%s: %v", id, serr)
		}
	}
	log.Printf("stash ok: id=%s user=%s path=%s archive=%v size=%d status=%s buffered=%v",
		id, username, final.StoredPath, final.IsArchive, final.SizeBytes, status, buffered)
	return nil
}

// detectAndStore classifies final's artifact and writes the §10 type fields
// onto the row. An archive (our own ZIP) is classed directly without running
// the detector; everything else goes through the configured Detector. A
// detection or DB error is logged, not fatal — the upload still succeeds
// (the UI just shows it as unclassified until a later backfill).
func (s *Server) detectAndStore(id string, final *store.FinalizeResult) {
	if final.IsArchive {
		if err := s.Meta.UpdateType(id, "application/zip", config.ClassArchive, false, "", 0); err != nil {
			log.Printf("detect: store archive type id=%s: %v", id, err)
		}
		return
	}
	if s.Detector == nil {
		return
	}
	res := s.Detector.DetectFile(final.StoredPath, final.OriginalFilename)
	if err := s.Meta.UpdateType(id, res.MimeType, res.ContentClass, res.IsText, res.TypeLabel, res.TypeScore); err != nil {
		log.Printf("detect: store type id=%s: %v", id, err)
	}
}

// SCPCommand parses an `scp -t /dst`, `scp -r -t /dst`, `scp -d -t /dst`
// (and combinations like -rt) exec request.
type SCPCommand struct {
	Recursive bool
	DestPath  string
}

func parseSCPCommand(cmd string) (SCPCommand, bool) {
	fields := strings.Fields(cmd)
	if len(fields) == 0 || fields[0] != "scp" {
		return SCPCommand{}, false
	}
	out := SCPCommand{}
	sinkSeen := false
	for i := 1; i < len(fields); i++ {
		tok := fields[i]
		if strings.HasPrefix(tok, "-") && len(tok) > 1 {
			for _, r := range tok[1:] {
				switch r {
				case 'r':
					out.Recursive = true
				case 't':
					sinkSeen = true
				case 'f':
					// Source mode — we only implement sink.
					return SCPCommand{}, false
				}
				// Other flags (d, p, q, v, ...) are accepted silently.
			}
			continue
		}
		out.DestPath = tok
	}
	if !sinkSeen {
		return SCPCommand{}, false
	}
	return out, true
}

// parseExecPayload extracts the command string from an "exec" channel
// request payload. RFC 4254: uint32 length + command bytes.
func parseExecPayload(payload []byte) string {
	if len(payload) < 4 {
		return ""
	}
	n := binary.BigEndian.Uint32(payload[:4])
	if uint32(len(payload)-4) < n {
		return ""
	}
	return string(payload[4 : 4+n])
}

// writeExit sends an exit-status channel request so the client's scp
// reports a meaningful return code.
func writeExit(ch ssh.Channel, code int) {
	payload := make([]byte, 4)
	binary.BigEndian.PutUint32(payload, uint32(code))
	_, _ = ch.SendRequest("exit-status", false, payload)
}

// loadOrGenerateHostKey returns the persistent SSH signer (§4.4).
//
//   - If the durable SHARE key (primary) is PRESENT it must be usable: a
//     transient/corrupt read must NOT silently rotate the durable key, so
//     fail loud and let systemd retry (the daemon's original contract).
//   - If the share key is absent or the share is offline/unreachable (§8.4),
//     prefer an existing VM-local fallback key and PROMOTE it to the share as
//     soon as the share is back (so an offline-first key becomes durable and
//     a later reimage doesn't mint a new one, breaking client trust).
//   - Only when no key exists anywhere is a new ed25519 key generated and
//     persisted to the share when reachable, else to the VM-local fallback.
func loadOrGenerateHostKey(primary, fallback string) (ssh.Signer, error) {
	if fi, serr := os.Stat(primary); serr == nil && !fi.IsDir() {
		data, rerr := os.ReadFile(primary)
		if rerr != nil {
			return nil, fmt.Errorf("read share host key %s: %w", primary, rerr)
		}
		signer, perr := ssh.ParsePrivateKey(data)
		if perr != nil {
			return nil, fmt.Errorf("parse share host key %s (refusing to overwrite a present key): %w", primary, perr)
		}
		return signer, nil
	}
	// Primary absent or unreachable — try the VM-local fallback.
	if data, rerr := os.ReadFile(fallback); rerr == nil {
		if signer, perr := ssh.ParsePrivateKey(data); perr == nil {
			promoteHostKey(primary, data)
			return signer, nil
		}
		// A corrupt local fallback is ephemeral; regenerate below.
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("ed25519.GenerateKey: %w", err)
	}
	block, err := ssh.MarshalPrivateKey(priv, "stash-server host key")
	if err != nil {
		return nil, fmt.Errorf("MarshalPrivateKey: %w", err)
	}
	pemBytes := pem.EncodeToMemory(block)
	if werr := writeHostKey(primary, pemBytes); werr != nil {
		log.Printf("host key: share unavailable (%v); using VM-local key %s", werr, fallback)
		if ferr := writeHostKey(fallback, pemBytes); ferr != nil {
			return nil, fmt.Errorf("write host key (share: %v; local: %v)", werr, ferr)
		}
	}
	return ssh.NewSignerFromKey(priv)
}

// promoteHostKey best-effort writes the VM-local key to the durable share path
// once the share is reachable AND still keyless, so an offline-first key
// becomes durable on the first restart with the share back (§4.4). It never
// overwrites an existing share key, and is a silent no-op while the share is
// still offline (retried on the next restart).
func promoteHostKey(primary string, pemBytes []byte) {
	if _, err := os.Stat(primary); !errors.Is(err, os.ErrNotExist) {
		return
	}
	if err := writeHostKey(primary, pemBytes); err != nil {
		return
	}
	log.Printf("host key: promoted VM-local key to the durable share %s", primary)
}

// writeHostKey creates the parent dir and writes the PEM key 0600.
func writeHostKey(path string, pemBytes []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, pemBytes, 0o600)
}

// Close stops the listener (used on graceful shutdown).
func (s *Server) Close() error {
	if s.listener != nil {
		return s.listener.Close()
	}
	return nil
}
