// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package sshsrv hosts the crypto/ssh server and the per-connection
// SCP session dispatch loop. Authentication is the §4.3 pass-through
// pattern: any username, any password, any public key. The username
// is captured into the connection's Permissions for the SCP handler
// to read out and stamp on the metadata record.
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
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"stash-server/internal/config"
	"stash-server/internal/id"
	"stash-server/internal/meta"
	"stash-server/internal/scp"
	"stash-server/internal/store"
)

// Server pulls together every layer the daemon needs: storage paths,
// metadata DB, ID allocator, the SSH host key, and the network
// listener.
type Server struct {
	Store    *store.Store
	Meta     *meta.Store
	IDs      *id.Allocator
	sshCfg   *ssh.ServerConfig
	listener net.Listener
}

// New wires everything up. The host key is loaded from
// <StashFolder>/hostkey/, generated and persisted if missing.
func New(s *store.Store, m *meta.Store, ids *id.Allocator) (*Server, error) {
	hostKey, err := loadOrGenerateHostKey(s.HostKeyPath())
	if err != nil {
		return nil, fmt.Errorf("host key: %w", err)
	}
	cfg := &ssh.ServerConfig{
		PasswordCallback: func(conn ssh.ConnMetadata, _ []byte) (*ssh.Permissions, error) {
			return permFor(conn), nil
		},
		PublicKeyCallback: func(conn ssh.ConnMetadata, _ ssh.PublicKey) (*ssh.Permissions, error) {
			return permFor(conn), nil
		},
	}
	cfg.AddHostKey(hostKey)
	return &Server{Store: s, Meta: m, IDs: ids, sshCfg: cfg}, nil
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
		case "pty-req", "shell", "subsystem":
			// §4.2: no GUI / interactive shell. Reject cleanly so a
			// stray `ssh` (no scp) gets a useful error instead of
			// hanging.
			_ = req.Reply(false, nil)
			fmt.Fprintln(ch.Stderr(), "stash-server: only scp is supported (interactive shell rejected).")
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

	dayDir, err := s.Store.DayDir(now)
	if err != nil {
		log.Printf("day dir: %v", err)
		writeExit(ch, 1)
		return
	}
	stagingDir, err := s.Store.StagingDir(now, allocated)
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

	final, err := s.Store.FinalizeStaging(stagingDir, dayDir, allocated, parsed.Recursive, res.FileNames, res.FirstDirName)
	if err != nil {
		log.Printf("finalize (id=%s): %v", allocated, err)
		_ = s.Meta.UpdateOnPartial(allocated, res.TotalBytes, time.Now().UTC())
		writeExit(ch, 1)
		return
	}
	status := meta.StatusComplete
	if res.Truncated {
		status = meta.StatusTruncated
	}
	if err := s.Meta.UpdateOnComplete(allocated, final.StoredPath, final.OriginalFilename, final.IsArchive, status, final.SizeBytes, time.Now().UTC()); err != nil {
		log.Printf("update complete (id=%s): %v", allocated, err)
		writeExit(ch, 1)
		return
	}
	log.Printf("stash ok: id=%s user=%s path=%s archive=%v size=%d status=%s",
		allocated, username, final.StoredPath, final.IsArchive, final.SizeBytes, status)
	writeExit(ch, 0)
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

// loadOrGenerateHostKey returns the persistent SSH signer (§4.4). On
// first run it generates an ed25519 keypair and writes it out at 0600.
func loadOrGenerateHostKey(keyFile string) (ssh.Signer, error) {
	if data, err := os.ReadFile(keyFile); err == nil {
		return ssh.ParsePrivateKey(data)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("ed25519.GenerateKey: %w", err)
	}
	block, err := ssh.MarshalPrivateKey(priv, "stash-server host key")
	if err != nil {
		return nil, fmt.Errorf("MarshalPrivateKey: %w", err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(block), 0o600); err != nil {
		return nil, fmt.Errorf("write host key: %w", err)
	}
	return ssh.NewSignerFromKey(priv)
}

// Close stops the listener (used on graceful shutdown).
func (s *Server) Close() error {
	if s.listener != nil {
		return s.listener.Close()
	}
	return nil
}
