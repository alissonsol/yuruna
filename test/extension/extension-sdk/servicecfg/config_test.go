// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
package servicecfg

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPortAndExplicitKeySelection(t *testing.T) {
	for _, tc := range []struct {
		addr string
		port int
	}{{"[::1]:9400", 9400}, {"0.0.0.0:80", 80}, {":-1", 0}, {":65536", 0}, {"bad", 0}} {
		if got := UIPort(tc.addr); got != tc.port {
			t.Fatalf("%q: %d", tc.addr, got)
		}
	}
	dir := t.TempDir()
	current := filepath.Join(dir, "current")
	legacy := filepath.Join(dir, "legacy")
	if err := os.WriteFile(legacy, []byte(" old-key\n"), 0600); err != nil {
		t.Fatal(err)
	}
	token, source, err := ReadAuthToken(current, current, legacy)
	if err != nil || token != "old-key" || source != legacy {
		t.Fatal(token, source, err)
	}
	if token, _, err = ReadAuthToken(filepath.Join(dir, "explicit"), current, legacy); err == nil || token != "" {
		t.Fatal("explicit path fell back")
	}
	if err := os.WriteFile(current, []byte(" new-key\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if token, source, err = ReadAuthToken(current, current, legacy); err != nil || token != "new-key" || source != current {
		t.Fatal(token, source, err)
	}
}
