// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Linux-only half of caching-proxy-parser-service: following the squid log
// means noticing a logrotate, and the only reliable signal for that is the
// inode, which needs syscall.Stat_t. Everything the daemon does with a line
// once it has one is in parse.go and builds anywhere.
//go:build linux

package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"syscall"
	"time"
)

func inodeOf(fi os.FileInfo) uint64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return st.Ino
	}
	return 0
}

// follow tails the squid log forever. On first open it seeds the ring
// from the last ~64 KB of the file (so the panel is non-empty on cold
// start). It detects logrotate by stat'ing the path and comparing
// inodes; on rotation it closes the old fd and re-opens from byte 0.
func follow(path string, r *ring, s *stats) {
	var (
		f         *os.File
		rd        *bufio.Reader
		seenInode uint64
		firstOpen = true
	)
	for {
		if f == nil {
			fh, err := os.Open(path)
			if err != nil {
				s.lastOpenErr.Store(fmt.Sprintf("open %s: %v", path, err))
				log.Printf("open %s: %v", path, err)
				time.Sleep(time.Second)
				continue
			}
			st, statErr := fh.Stat()
			if statErr != nil {
				// A stat failure must be surfaced, not silently retried: an
				// unrecorded stat error is invisible on /healthz and
				// indistinguishable there from a healthy tailer that is merely
				// caught up. Record + log it like the open failure above.
				s.lastOpenErr.Store(fmt.Sprintf("stat %s: %v", path, statErr))
				log.Printf("stat %s: %v", path, statErr)
				_ = fh.Close()
				time.Sleep(time.Second)
				continue
			}
			s.lastOpenErr.Store("") // open+stat succeeded; clear any prior failure
			seenInode = inodeOf(st)
			if firstOpen {
				size := st.Size()
				if size > backfillBytes {
					_, _ = fh.Seek(size-backfillBytes, io.SeekStart)
				}
				br := bufio.NewReader(fh)
				if size > backfillBytes {
					// Skip the partial first line introduced by mid-line seek.
					_, _ = br.ReadString('\n')
				}
				rd = br
				firstOpen = false
			} else {
				rd = bufio.NewReader(fh)
			}
			f = fh
		}
		line, err := rd.ReadString('\n')
		if err == nil {
			s.lastReadUnixMs.Store(time.Now().UnixMilli())
			line = strings.TrimRight(line, "\n")
			if line == "" {
				continue // a blank line is not logformat drift; don't count it as skipped
			}
			if recordLine(line, r, s) {
				log.Printf("unmatched line (logformat drift?): %q", line)
			}
			continue
		}
		if err != io.EOF {
			// A non-EOF read error (bad fd, underlying I/O error) will not clear by waiting, so
			// close and force a reopen instead of spinning on / stalling behind a broken
			// descriptor. Only io.EOF means "caught up -- wait for more data / check rotation".
			_ = f.Close()
			f, rd = nil, nil
			continue
		}
		// io.EOF: caught up. If the file rotated (new inode) reopen; otherwise wait for new data.
		// Keep rd so the next read resumes where bufio left off.
		st, statErr := os.Stat(path)
		if statErr == nil && inodeOf(st) != seenInode {
			_ = f.Close()
			f, rd = nil, nil
			continue
		}
		time.Sleep(pollInterval)
	}
}

func main() {
	logPath := flag.String("log", defaultLogPath, "squid access log to tail")
	addr := flag.String("listen", defaultListenAddr, "address to listen on")
	flag.Parse()

	r := &ring{}
	s := newStats()
	go follow(*logPath, r, s)

	log.Printf("caching-proxy-parser-service listening on http://%s, tailing %s", *addr, *logPath)
	srv := &http.Server{
		Addr:         *addr,
		Handler:      newMux(r, s),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}
