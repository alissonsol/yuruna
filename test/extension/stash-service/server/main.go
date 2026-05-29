// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Yuruna Stash Service daemon. Spec: https://yuruna.link/stash-service.
//
// Single binary, single listener on TCP/22, no daemon supervision
// (§4.6: out of scope for v1; launch manually or via a future systemd
// unit). Operational logs go to stderr; journald captures them when
// the service is launched under systemd.
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"stash-server/internal/config"
	"stash-server/internal/id"
	"stash-server/internal/meta"
	"stash-server/internal/sshsrv"
	"stash-server/internal/store"
)

func main() {
	folder := flag.String("folder", defaultFolder(), "StashFolder path (§6.1)")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.LUTC | log.Lmicroseconds)
	log.Printf("stash-server starting; folder=%s", *folder)

	st, err := store.New(*folder)
	if err != nil {
		log.Fatalf("store.New: %v", err)
	}

	m, err := meta.Open(st.MetadataDBPath())
	if err != nil {
		log.Fatalf("meta.Open: %v", err)
	}
	defer m.Close()

	ids := id.New(st.FilesRoot())

	srv, err := sshsrv.New(st, m, ids)
	if err != nil {
		log.Fatalf("sshsrv.New: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := srv.ListenAndServe(ctx, config.ListenAddress); err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("stash-server stopped")
}

// defaultFolder returns $HOME/yuruna/test/status/stash, matching the
// path the Yuruna repo clone (cloned into $HOME/yuruna by
// ubuntu.server.24.update.sh) provides on the stash VM.
func defaultFolder() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return filepath.FromSlash("./" + config.DefaultFolderRelative)
	}
	return filepath.Join(home, filepath.FromSlash(config.DefaultFolderRelative))
}
