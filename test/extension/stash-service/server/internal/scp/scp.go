// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package scp implements just enough of OpenSSH's SCP sink-mode wire
// protocol (section 5) to receive files from a standard `scp` client.
//
// Wire protocol summary (binaries-only path; T<time> lines are
// accepted and ignored):
//
//	server  -> \x00              (ready)
//	client  -> C<mode> <size> <name>\n
//	server  -> \x00              (ack)
//	client  -> <size> bytes of file content
//	client  -> \x00              (end-of-file marker)
//	server  -> \x00              (ack)
//	... more C/D/E ...
//	client closes EOF
//
// Recursive sessions (scp -r) bracket their C lines with D<mode> 0
// <dirname>\n and E\n. We push/pop a current-relative-path stack and
// place each C under it.
//
// Path safety: client-supplied names are stripped of slashes and
// .. components before joining. The trusted-network posture in section 11
// makes hostile clients out of scope, but path-traversal hygiene is
// cheap and worth keeping.
package scp

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"stash-service/internal/config"
	"stash-service/internal/fsutil"
)

// Result is what the SCP receive returned to the caller (sshsrv).
// FileNames lists the basenames received in order; FirstDirName is
// the first D-line dirname (used as originalFilename for recursive
// uploads per section 8.1). Truncated is true if any file hit the 100 MB cap.
// TotalBytes counts EVERY byte written to disk across the session
// (post-truncation), which feeds the sizeBytes field on partial /
// truncated outcomes.
type Result struct {
	FileNames    []string
	FirstDirName string
	Truncated    bool
	TotalBytes   int64
}

// Receive runs the SCP sink protocol against (in, out), staging files
// under stagingDir. It returns when the client sends EOF, when a
// protocol error occurs, or when the underlying connection breaks.
//
// Returns the Result so the caller can finalize. A non-nil error
// indicates the transfer ended abnormally (partial outcome per section 8.2
// step 5). The caller still gets the partial Result populated up to
// the point of failure.
func Receive(in io.Reader, out io.Writer, stagingDir string) (*Result, error) {
	br := bufio.NewReader(in)
	res := &Result{}
	// Server-ready signal (section 5 wire protocol).
	if _, err := out.Write([]byte{0}); err != nil {
		return res, fmt.Errorf("write ready: %w", err)
	}

	// Track relative path inside the staging dir as the client walks D/E.
	var relStack []string
	currentRel := func() string {
		if len(relStack) == 0 {
			return ""
		}
		return filepath.Join(relStack...)
	}

	for {
		line, err := readControlLine(br)
		if err != nil {
			if errors.Is(err, io.EOF) && len(relStack) == 0 {
				return res, nil
			}
			if errors.Is(err, io.EOF) {
				err = io.ErrUnexpectedEOF
			}
			return res, fmt.Errorf("read control: %w", err)
		}
		if len(line) == 0 {
			return res, fmt.Errorf("empty control line")
		}
		switch line[0] {
		case 'T':
			// Timestamp metadata; spec doesn't preserve mtime. Ack & ignore.
			if _, err := out.Write([]byte{0}); err != nil {
				return res, fmt.Errorf("ack T: %w", err)
			}
		case 'C':
			mode, size, name, err := parseCLine(line)
			if err != nil {
				return res, fmt.Errorf("parse C: %w", err)
			}
			_ = mode // discarded -- we always create 0o600
			safeName := sanitizeName(name)
			if _, err := out.Write([]byte{0}); err != nil {
				return res, fmt.Errorf("ack C: %w", err)
			}
			if safeName == "" {
				// section 5.5 empty-filename: ignored. Still must drain the
				// payload (size bytes + trailing \x00) so the protocol
				// stays in sync, but skip the disk write + the file-
				// name listing.
				if err := drainPayload(br, size); err != nil {
					return res, fmt.Errorf("drain empty-name payload: %w", err)
				}
				if err := finishFile(br, out); err != nil {
					return res, err
				}
				continue
			}
			target, err := fsutil.UniqueUploadPath(filepath.Join(stagingDir, currentRel()), safeName)
			if err != nil {
				return res, fmt.Errorf("choose upload name: %w", err)
			}
			safeName = filepath.Base(target)
			if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
				return res, fmt.Errorf("mkdir for %s: %w", safeName, err)
			}
			written, truncated, err := streamFile(br, target, size)
			res.TotalBytes += written
			if truncated {
				res.Truncated = true
			}
			if err != nil {
				return res, fmt.Errorf("stream file %s: %w", safeName, err)
			}
			res.FileNames = append(res.FileNames, safeName)
			if err := finishFile(br, out); err != nil {
				return res, err
			}
		case 'D':
			_, _, name, err := parseCLine(line) // same shape as C; size always 0
			if err != nil {
				return res, fmt.Errorf("parse D: %w", err)
			}
			safe := sanitizeName(name)
			if safe == "" {
				safe = "_"
			}
			if res.FirstDirName == "" {
				res.FirstDirName = safe
			}
			relStack = append(relStack, safe)
			if err := os.MkdirAll(filepath.Join(stagingDir, currentRel()), 0o700); err != nil {
				return res, fmt.Errorf("mkdir D: %w", err)
			}
			if _, err := out.Write([]byte{0}); err != nil {
				return res, fmt.Errorf("ack D: %w", err)
			}
		case 'E':
			if len(relStack) > 0 {
				relStack = relStack[:len(relStack)-1]
			}
			if _, err := out.Write([]byte{0}); err != nil {
				return res, fmt.Errorf("ack E: %w", err)
			}
		default:
			return res, fmt.Errorf("unknown control byte 0x%02x", line[0])
		}
	}
}

func finishFile(br *bufio.Reader, out io.Writer) error {
	// Read the trailing \x00 from the client (end-of-file
	// marker on the wire -- distinct from EOF on the stream).
	eof := make([]byte, 1)
	if _, err := io.ReadFull(br, eof); err != nil {
		return fmt.Errorf("read EOF marker: %w", err)
	}
	if eof[0] != 0 {
		return fmt.Errorf("expected 0 after file payload, got 0x%02x", eof[0])
	}
	if _, err := out.Write([]byte{0}); err != nil {
		return fmt.Errorf("ack file end: %w", err)
	}
	return nil
}

// readControlLine returns one \n-terminated line WITHOUT the trailing
// newline. The protocol guarantees ASCII for C/D/E/T headers.
func readControlLine(br *bufio.Reader) (string, error) {
	line, err := br.ReadString('\n')
	if err != nil {
		// EOF without a partial line is the natural session end.
		if errors.Is(err, io.EOF) {
			if line == "" {
				return "", io.EOF
			}
			return "", io.ErrUnexpectedEOF
		}
		return "", err
	}
	return strings.TrimRight(line, "\n"), nil
}

// parseCLine handles both C<mode> <size> <name> and D<mode> 0 <name>
// Directory headers require a zero size.
func parseCLine(line string) (mode string, size int64, name string, err error) {
	if len(line) < 1 || (line[0] != 'C' && line[0] != 'D') {
		return "", 0, "", fmt.Errorf("invalid control header")
	}
	// Drop the leading control byte.
	body := line[1:]
	// mode is everything up to the first space.
	sp1 := strings.IndexByte(body, ' ')
	if sp1 < 0 {
		return "", 0, "", fmt.Errorf("missing mode separator: %q", line)
	}
	mode = body[:sp1]
	if len(mode) != 4 || strings.IndexFunc(mode, func(r rune) bool { return r < '0' || r > '7' }) >= 0 {
		return "", 0, "", fmt.Errorf("invalid mode %q", mode)
	}
	rest := body[sp1+1:]
	sp2 := strings.IndexByte(rest, ' ')
	if sp2 < 0 {
		return "", 0, "", fmt.Errorf("missing size separator: %q", line)
	}
	sizeStr := rest[:sp2]
	name = rest[sp2+1:]
	if sizeStr == "" || strings.IndexFunc(sizeStr, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		return "", 0, "", fmt.Errorf("invalid size %q", sizeStr)
	}
	size, err = strconv.ParseInt(sizeStr, 10, 64)
	if err != nil {
		return "", 0, "", fmt.Errorf("parse size: %w", err)
	}
	if line[0] == 'D' && size != 0 {
		return "", 0, "", fmt.Errorf("directory size must be zero")
	}
	return mode, size, name, nil
}

// streamFile copies up to size bytes from br to target, returning the
// actual byte count and whether the 100 MB cap clipped the write.
// When clipped, the function still drains the remaining payload bytes
// from br so the wire stays in sync for the trailing \x00.
func streamFile(br *bufio.Reader, target string, size int64) (written int64, truncated bool, err error) {
	f, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, false, err
	}
	defer func() { err = errors.Join(err, fsutil.SyncClose(f)) }()
	cap := int64(config.PerFileSizeLimit)
	toWrite := size
	truncated = false
	if toWrite > cap {
		toWrite = cap
		truncated = true
	}
	written, err = io.CopyN(f, br, toWrite)
	if err != nil {
		return written, truncated, err
	}
	// If we truncated, drain the remaining unread bytes so the wire
	// stays in sync with the trailing \x00.
	if truncated {
		remaining := size - cap
		if err := drainPayload(br, remaining); err != nil {
			return written, true, err
		}
	}
	return written, truncated, nil
}

func drainPayload(br *bufio.Reader, n int64) error {
	if n <= 0 {
		return nil
	}
	_, err := io.CopyN(io.Discard, br, n)
	return err
}

// sanitizeName strips any path separators and "..", then trims. An
// empty result tells the caller to treat this as the section 5.5 empty-
// filename case (skip).
func sanitizeName(raw string) string { return fsutil.UploadName(raw) }
